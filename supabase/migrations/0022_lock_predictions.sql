-- دوري دراية: التوقع نهائي بعد تسجيله — ما يقدر الكابتن يغيّره أو يستبدله
-- =============================================================================

create or replace function submit_prediction(p_match_id uuid, p_predicted_team_id uuid)
returns match_predictions
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_team_id uuid;
  v_row match_predictions;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: captains only'; end if;

  select * into v_match from matches where id = p_match_id;
  if not found then raise exception 'match not found'; end if;
  if not v_match.prediction_enabled then raise exception 'predictions are not open for this match'; end if;
  if v_match.status = 'completed' then raise exception 'match already completed'; end if;
  if v_team_id in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'cannot predict a match your own team is playing in';
  end if;
  if p_predicted_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'predicted team must be one of the two participating teams';
  end if;
  if exists(select 1 from match_predictions where match_id = p_match_id and predicting_team_id = v_team_id) then
    raise exception 'already predicted this match — predictions are final';
  end if;

  insert into match_predictions (match_id, predicting_team_id, predicted_winner_team_id, created_by)
  values (p_match_id, v_team_id, p_predicted_team_id, auth.uid())
  returning * into v_row;

  return v_row;
end; $$;
