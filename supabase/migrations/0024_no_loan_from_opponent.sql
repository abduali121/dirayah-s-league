-- دوري دراية: منع تعاقد فريق مع لاعب خصمه بنفس المباراة — الإعارة تكون فقط من فرق
-- ثالثة غير مشاركة بهذي المباراة، مو من الفريق اللي تلاعبه هذا الأسبوع تحديدًا.
-- =============================================================================

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
