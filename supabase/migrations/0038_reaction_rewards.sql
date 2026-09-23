-- دوري دراية: مكافأة دراية للفريق صاحب التصريح/الصورة كلما وصل عدد التفاعلات عليه
-- (من الكل، حتى الزوار) درجة معيّنة. الإدارة توافق يدويًا (حماية من تفاعلات وهمية)،
-- وكل درجة تُمنح مرة واحدة أبدًا لكل محتوى — حتى لو نقص عدد التفاعلات ورجع زاد،
-- ما تُمنح ثانية لنفس الدرجة (قيد UNIQUE يمنع هذا تمامًا).
--
-- جدول التصريحات:  10 تفاعل → 20 دراية · 25 → 50 · 50 → 100
-- جدول الصور (ضِعف): 10 تفاعل → 40 دراية · 25 → 100 · 50 → 200
-- =============================================================================

alter type ledger_reason add value if not exists 'reaction_reward';

create table content_reaction_rewards (
  id             uuid primary key default gen_random_uuid(),
  content_type   text not null check (content_type in ('announcement', 'photo')),
  content_id     uuid not null,
  tier_threshold integer not null,
  amount         integer not null,
  team_id        uuid not null references teams(id),
  granted_by     uuid references profiles(id),
  created_at     timestamptz not null default now(),
  unique (content_type, content_id, tier_threshold)
);

alter table content_reaction_rewards enable row level security;
create policy sel_reaction_rewards on content_reaction_rewards for select to authenticated, anon using (true);
grant select on content_reaction_rewards to anon, authenticated;

create or replace function grant_reaction_reward(p_content_type text, p_content_id uuid, p_tier integer)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_reaction_count integer;
  v_amount integer;
  v_team teams;
  v_new_balance integer;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  if p_content_type = 'announcement' then
    select team_id into v_team_id from league_announcements where id = p_content_id;
  elsif p_content_type = 'photo' then
    select team_id into v_team_id from league_photos where id = p_content_id;
  else
    raise exception 'invalid content type';
  end if;

  if not found then raise exception 'content not found'; end if;
  if v_team_id is null then raise exception 'لا يوجد فريق مستفيد — هذا المحتوى منشور باسم الإدارة'; end if;

  select count(*) into v_reaction_count from content_reactions
    where content_type = p_content_type and content_id = p_content_id;
  if v_reaction_count < p_tier then
    raise exception 'عدد التفاعلات الحالي (%) أقل من الدرجة المطلوبة (%)', v_reaction_count, p_tier;
  end if;

  v_amount := case
    when p_content_type = 'announcement' and p_tier = 10 then 20
    when p_content_type = 'announcement' and p_tier = 25 then 50
    when p_content_type = 'announcement' and p_tier = 50 then 100
    when p_content_type = 'photo' and p_tier = 10 then 40
    when p_content_type = 'photo' and p_tier = 25 then 100
    when p_content_type = 'photo' and p_tier = 50 then 200
    else null
  end;
  if v_amount is null then raise exception 'invalid tier'; end if;

  select * into v_team from teams where id = v_team_id for update;
  v_new_balance := v_team.balance_daraya + v_amount;

  insert into content_reaction_rewards (content_type, content_id, tier_threshold, amount, team_id, granted_by)
  values (p_content_type, p_content_id, p_tier, v_amount, v_team_id, auth.uid());

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_team_id, v_amount, v_new_balance, 'reaction_reward',
    (case when p_content_type = 'announcement' then 'مكافأة تفاعل تصريح' else 'مكافأة تفاعل صورة' end) || ' — ' || v_reaction_count || ' تفاعل',
    auth.uid());
  update teams set balance_daraya = v_new_balance where id = v_team_id;

  perform log_audit('grant_reaction_reward', 'content_reaction_rewards', p_content_id::text,
    null, jsonb_build_object('content_type', p_content_type, 'tier', p_tier, 'amount', v_amount));
exception
  when unique_violation then
    raise exception 'هذي الدرجة اتمنحت مسبقًا لهذا المحتوى';
end; $$;

grant execute on function grant_reaction_reward(text, uuid, integer) to authenticated;
