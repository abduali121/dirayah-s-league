-- دوري دراية: صور بالتصريحات — الإدارة ترفع صورة من المباراة مع كل تصريح
-- =============================================================================

alter table league_announcements add column image_url text;

create or replace function create_announcement(p_body text, p_team_id uuid default null, p_image_url text default null)
returns league_announcements
language plpgsql security definer set search_path = public as $$
declare v_row league_announcements;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_body is null or length(trim(p_body)) = 0 then raise exception 'body is required'; end if;
  insert into league_announcements (body, team_id, image_url, created_by)
  values (trim(p_body), p_team_id, nullif(p_image_url, ''), auth.uid())
  returning * into v_row;
  perform log_audit('create_announcement', 'league_announcements', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

-- تخزين ملفات: bucket عام للقراءة (الصور تظهر حتى للزوار بدون تسجيل دخول)،
-- والرفع/الحذف محصور بالإدارة فقط عبر سياسات storage.objects
insert into storage.buckets (id, name, public)
values ('announcement-images', 'announcement-images', true)
on conflict (id) do nothing;

create policy "admin uploads announcement images"
on storage.objects for insert to authenticated
with check (bucket_id = 'announcement-images' and is_admin());

create policy "admin deletes announcement images"
on storage.objects for delete to authenticated
using (bucket_id = 'announcement-images' and is_admin());
