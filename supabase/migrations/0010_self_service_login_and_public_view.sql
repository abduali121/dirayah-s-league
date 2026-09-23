-- دوري دراية: تسجيل ذاتي برقم الجوال + مشاهدة عامة بدون تسجيل دخول
-- ========================================================================

-- 1) رقم جوال الكابتن يُسجَّل مسبقًا على الفريق من لوحة الإدارة، ليُستخدم
--    لمطابقة الحساب تلقائيًا بفريقه الصحيح وقت التسجيل الذاتي.
alter table teams add column captain_phone text unique;

create or replace function create_team(
  p_name text, p_logo_url text default null,
  p_primary_color text default '#1a3a5c', p_secondary_color text default '#b8952a',
  p_captain_phone text default null
) returns teams
language plpgsql security definer set search_path = public as $$
declare v_team teams;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  insert into teams (name, logo_url, primary_color, secondary_color, captain_phone)
  values (p_name, p_logo_url, p_primary_color, p_secondary_color, nullif(p_captain_phone, ''))
  returning * into v_team;
  perform log_audit('create_team', 'teams', v_team.id::text, null, to_jsonb(v_team));
  return v_team;
end; $$;

create or replace function update_team(
  p_team_id uuid, p_name text, p_logo_url text,
  p_primary_color text, p_secondary_color text, p_captain_phone text default null
) returns teams
language plpgsql security definer set search_path = public as $$
declare v_before teams; v_after teams;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from teams where id = p_team_id;
  if not found then raise exception 'team not found'; end if;
  update teams set name = p_name, logo_url = p_logo_url,
    primary_color = p_primary_color, secondary_color = p_secondary_color,
    captain_phone = nullif(p_captain_phone, '')
  where id = p_team_id
  returning * into v_after;
  perform log_audit('update_team', 'teams', p_team_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

-- 2) إصلاح جذري لدالة إنشاء الحساب: لا تثق أبدًا ببيانات الدور القادمة من العميل
--    (تسجيل ذاتي مفتوح الآن، ولازم منع أي طرف من ادّعاء "super_admin" لنفسه).
--    الدور دائمًا "team_captain" افتراضيًا، والفريق يُشتق فقط من مطابقة رقم الجوال
--    (المستخرج من البريد الوهمي المحلي@dawri.local) مع ما سجّله المدير مسبقًا على الفريق.
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

-- 3) مشاهدة عامة بدون تسجيل دخول: الجداول اللازمة لعرض الترتيب ومباراة الأسبوع
--    تصير مقروءة لأي زائر (anon)، أما الكتابة فتبقى محصورة كما هي عبر RPC فقط.
alter policy sel_teams on teams to authenticated, anon;
alter policy sel_players on players to authenticated, anon;
alter policy sel_weeks on weeks to authenticated, anon;
alter policy sel_matches on matches to authenticated, anon;
alter policy sel_match_events on match_events to authenticated, anon;
alter policy sel_match_lineups on match_lineups to authenticated, anon;
alter policy sel_auctions on auctions to authenticated, anon;
alter policy sel_match_loans on match_loans to authenticated, anon;
alter policy sel_standings on standings_snapshots to authenticated, anon;
alter policy sel_bids on bids to authenticated, anon;

grant select on teams, players, weeks, matches, match_events, match_lineups,
  auctions, match_loans, standings_snapshots, bids, bids_public to anon;
