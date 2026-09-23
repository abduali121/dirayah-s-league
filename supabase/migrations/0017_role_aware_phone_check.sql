-- إصلاح: الدخول عبر "دخول الكباتن" أو "دخول الإدارة" لازم يرفض أي رقم ينتمي
-- لحساب من النوع التاني (مثلًا: كتابة رقم المدير من صفحة دخول الكباتن) بدل ما
-- يدخّله بصمت من الباب الغلط. نضيف "role" لرد الدالة عشان الواجهة تقارنه بنوع
-- الدخول المطلوب (?as=admin|captain) وترفض أي تعارض بوضوح.
-- =============================================================================

create or replace function check_captain_phone(p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := p_phone || '@dawri.local';
  v_user_id uuid;
  v_role user_role;
  v_team_id uuid;
  v_team_name text;
begin
  select id into v_user_id from auth.users where email = v_email;
  if v_user_id is not null then
    select role into v_role from profiles where id = v_user_id;
    return jsonb_build_object('registered', true, 'activated', true, 'role', v_role);
  end if;

  select id, name into v_team_id, v_team_name from teams where captain_phone = p_phone;
  if v_team_id is null then
    return jsonb_build_object('registered', false);
  end if;

  return jsonb_build_object('registered', true, 'activated', false, 'team_name', v_team_name, 'role', 'team_captain');
end; $$;
