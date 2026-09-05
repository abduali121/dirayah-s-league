-- إصلاح: نافذة "Create user" في لوحة Supabase لا تسمح بتحديد role/team_id عند الإنشاء،
-- فيُنشأ الحساب بالقيم الافتراضية (team_captain بدون team_id) مما يخالف القيد الصارم
-- السابق ويفشل إنشاء الحساب بالكامل ("Database error creating new user").
-- الحل: السماح بحساب "كابتن بلا فريق مؤقتًا" (يُعيَّن فريقه لاحقًا)، مع منع الحالة
-- غير المنطقية الوحيدة فعليًا: مدير (super_admin) مرتبط بفريق.

alter table profiles drop constraint chk_role_team_consistency;
alter table profiles add constraint chk_admin_has_no_team check (
  role <> 'super_admin' or team_id is null
);

-- دالة لتعيين الدور/الفريق لحساب موجود (تُستخدم لترقية أول مدير، ولاحقًا لتعيين كباتن الفرق)
create or replace function assign_profile_role(
  p_profile_id uuid, p_role user_role, p_team_id uuid default null, p_display_name text default null
) returns profiles
language plpgsql security definer set search_path = public as $$
declare v_before profiles; v_after profiles;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from profiles where id = p_profile_id;
  if not found then raise exception 'profile not found'; end if;

  update profiles set
    role = p_role,
    team_id = case when p_role = 'super_admin' then null else p_team_id end,
    display_name = coalesce(p_display_name, display_name)
  where id = p_profile_id
  returning * into v_after;

  perform log_audit('assign_profile_role', 'profiles', p_profile_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

grant execute on function assign_profile_role(uuid, user_role, uuid, text) to authenticated;
