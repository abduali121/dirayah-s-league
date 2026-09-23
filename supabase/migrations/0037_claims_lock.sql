-- دوري دراية: يسمح للإدارة تقفل باب التعاقدات/صفقات الإعارة بالكامل بضغطة، بأي وقت
-- تحدده هي (مثلاً قبل بداية مباريات الأسبوع بشوي)، عشان كباتن متأخرين ما يقدرون
-- يسجّلون صفقات بعد فوات الأوان. قفل واحد يشمل كل الدوري، ترفعه الإدارة يدويًا.
-- =============================================================================

create table league_settings (
  id            boolean primary key default true,
  claims_locked boolean not null default false,
  constraint league_settings_singleton check (id)
);
insert into league_settings (id, claims_locked) values (true, false);

alter table league_settings enable row level security;
create policy sel_league_settings on league_settings for select to authenticated, anon using (true);
grant select on league_settings to anon, authenticated;

create or replace function set_claims_lock(p_locked boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  update league_settings set claims_locked = p_locked where id = true;
  perform log_audit('set_claims_lock', 'league_settings', 'singleton', null, jsonb_build_object('claims_locked', p_locked));
end; $$;
grant execute on function set_claims_lock(boolean) to authenticated;

-- نفس claim_player_loan بالضبط (من 0024) + فحص القفل كأول شرط
create or replace function claim_player_loan(
  p_match_id uuid, p_player_id uuid, p_amount integer, p_note text default null
) returns loan_claims
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_player players;
  v_team_id uuid;
  v_opponent_id uuid;
  v_existing loan_claims;
  v_claim loan_claims;
begin
  if (select claims_locked from league_settings where id = true) then
    raise exception 'الإدارة أغلقت باب التعاقدات مؤقتًا';
  end if;

  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;

  select * into v_match from matches where id = p_match_id;
  if not found then raise exception 'match not found'; end if;
  if v_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'only the two teams playing this match may sign a loan for it';
  end if;

  select * into v_player from players where id = p_player_id;
  if v_team_id = v_player.original_team_id then
    raise exception 'a team cannot sign its own player';
  end if;

  v_opponent_id := case when v_team_id = v_match.team_a_id then v_match.team_b_id else v_match.team_a_id end;
  if v_player.original_team_id = v_opponent_id then
    raise exception 'cannot sign a player from the team you are facing this match';
  end if;

  select * into v_existing from loan_claims
    where match_id = p_match_id and player_id = p_player_id and status = 'approved';
  if found then raise exception 'this player is already signed by another team for this match'; end if;

  insert into loan_claims (match_id, player_id, claiming_team_id, original_team_id, amount, note)
  values (p_match_id, p_player_id, v_team_id, v_player.original_team_id, p_amount, p_note)
  returning * into v_claim;

  perform log_audit('claim_player_loan', 'loan_claims', v_claim.id::text, null, to_jsonb(v_claim));
  return v_claim;
end; $$;
