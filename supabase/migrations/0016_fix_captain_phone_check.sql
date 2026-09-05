-- إصلاح: check_captain_phone كانت تفحص فقط جدول teams.captain_phone، فترفض حتى
-- أرقام الحسابات الموجودة أصلًا (مثل رقم المدير نفسه، غير المسجَّل كـ"كابتن" لأي فريق) —
-- ما يمنع المدير من تسجيل الدخول إطلاقًا. الترتيب الصحيح: أولًا هل الحساب موجود
-- أصلًا (أي نوع حساب)؟ إذا نعم، دخول عادي دائمًا. إذا لا، عندها فقط نفحص هل الرقم
-- مسجَّل كابتن من الإدارة (للسماح بالتفعيل لأول مرة) أو نرفضه.
-- =============================================================================

create or replace function check_captain_phone(p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := p_phone || '@dawri.local';
  v_user_exists boolean;
  v_team_id uuid;
  v_team_name text;
begin
  select exists(select 1 from auth.users where email = v_email) into v_user_exists;
  if v_user_exists then
    return jsonb_build_object('registered', true, 'activated', true);
  end if;

  select id, name into v_team_id, v_team_name from teams where captain_phone = p_phone;
  if v_team_id is null then
    return jsonb_build_object('registered', false);
  end if;

  return jsonb_build_object('registered', true, 'activated', false, 'team_name', v_team_name);
end; $$;
