-- دوري دراية: فصل الصور عن التصريحات النصية — قسمان مختلفان تمامًا
-- =============================================================================

-- 1) رجوع "تصريحات الدوري" نصًا فقط (تراجع عن إضافة صورة داخلها)
alter table league_announcements drop column if exists image_url;

create or replace function create_announcement(p_body text, p_team_id uuid default null)
returns league_announcements
language plpgsql security definer set search_path = public as $$
declare v_row league_announcements;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_body is null or length(trim(p_body)) = 0 then raise exception 'body is required'; end if;
  insert into league_announcements (body, team_id, created_by)
  values (trim(p_body), p_team_id, auth.uid())
  returning * into v_row;
  perform log_audit('create_announcement', 'league_announcements', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

-- 2) "صور الدوري" — قسم مستقل تمامًا: صورة + تعليق فقط، بلا نص طويل ولا شارة فريق ملزمة
create table league_photos (
  id           uuid primary key default gen_random_uuid(),
  image_url    text not null,
  caption      text,
  team_id      uuid references teams(id),
  created_by   uuid references profiles(id),
  created_at   timestamptz not null default now()
);
create index idx_photos_created on league_photos(created_at desc);

alter table league_photos enable row level security;
create policy sel_photos on league_photos for select to authenticated, anon using (true);
grant select on league_photos to anon;

create or replace function create_photo(p_image_url text, p_caption text default null, p_team_id uuid default null)
returns league_photos
language plpgsql security definer set search_path = public as $$
declare v_row league_photos;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_image_url is null or length(trim(p_image_url)) = 0 then raise exception 'image is required'; end if;
  insert into league_photos (image_url, caption, team_id, created_by)
  values (p_image_url, nullif(trim(coalesce(p_caption, '')), ''), p_team_id, auth.uid())
  returning * into v_row;
  perform log_audit('create_photo', 'league_photos', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

create or replace function delete_photo(p_photo_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_row league_photos;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from league_photos where id = p_photo_id;
  if not found then raise exception 'photo not found'; end if;
  delete from league_photos where id = p_photo_id;
  perform log_audit('delete_photo', 'league_photos', p_photo_id::text, to_jsonb(v_row), null);
end; $$;

grant execute on function create_photo(text, text, uuid) to authenticated;
grant execute on function delete_photo(uuid) to authenticated;
