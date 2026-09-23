-- دوري دراية: تصريحات الدوري (إعلانات تحمّس الشباب، يتحكم فيها المدير)
-- =============================================================================

create table league_announcements (
  id           uuid primary key default gen_random_uuid(),
  body         text not null,
  team_id      uuid references teams(id),   -- null = تصريح عام باسم "الإدارة"، وإلا منسوب لفريق
  created_by   uuid references profiles(id),
  created_at   timestamptz not null default now()
);
create index idx_announcements_created on league_announcements(created_at desc);

alter table league_announcements enable row level security;

-- القراءة مفتوحة للجميع (حتى الزوار بدون تسجيل دخول) — هذا محتوى تحفيزي عام
create policy sel_announcements on league_announcements for select to authenticated, anon using (true);
grant select on league_announcements to anon;

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

create or replace function delete_announcement(p_announcement_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_row league_announcements;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from league_announcements where id = p_announcement_id;
  if not found then raise exception 'announcement not found'; end if;
  delete from league_announcements where id = p_announcement_id;
  perform log_audit('delete_announcement', 'league_announcements', p_announcement_id::text, to_jsonb(v_row), null);
end; $$;

grant execute on function create_announcement(text, uuid) to authenticated;
grant execute on function delete_announcement(uuid) to authenticated;
