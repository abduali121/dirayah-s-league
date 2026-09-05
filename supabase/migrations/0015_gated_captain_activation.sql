-- دوري دراية: لا تسجيل ذاتي مفتوح — فقط الأرقام اللي سجّلتها الإدارة مسبقًا على فريق
-- يقدر صاحبها "يُفعّل" حسابه (يختار رمز دخول لأول مرة). أي رقم غير مسجَّل يُرفض من
-- قاعدة البيانات نفسها (وليس فقط من الواجهة).
-- =============================================================================

create or replace function handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_phone text;
  v_team_id uuid;
begin
  if new.email like '%@dawri.local' then
    v_phone := split_part(new.email, '@', 1);
    select id into v_team_id from teams where captain_phone = v_phone;
    if v_team_id is null then
      raise exception 'هذا الرقم غير مسجَّل من الإدارة — تواصل مع إدارة الدوري';
    end if;
  end if;

  insert into profiles (id, role, team_id, display_name)
  values (
    new.id,
    'team_captain',
    v_team_id,
    coalesce(new.raw_user_meta_data->>'display_name', new.email)
  );
  return new;
end;
$$;

-- يستخدمها login.html قبل عرض النموذج: هل الرقم مسجَّل أصلًا من الإدارة؟
-- وإذا كان مسجَّلًا، هل صاحبه فعّل حسابه (اختار رمزًا) من قبل أو لا (أول مرة)؟
create or replace function check_captain_phone(p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_team_name text;
  v_activated boolean;
begin
  select id, name into v_team_id, v_team_name from teams where captain_phone = p_phone;
  if v_team_id is null then
    return jsonb_build_object('registered', false);
  end if;
  select exists(select 1 from profiles where team_id = v_team_id) into v_activated;
  return jsonb_build_object('registered', true, 'activated', v_activated, 'team_name', v_team_name);
end; $$;

grant execute on function check_captain_phone(text) to authenticated, anon;
