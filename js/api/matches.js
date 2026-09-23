async function listWeeks(){
  const { data, error } = await sb.from("weeks").select("*").order("week_number");
  if(error) throw error;
  return data;
}

async function listMatches(){
  const { data, error } = await sb
    .from("matches")
    .select("*, week:week_id(week_number), team_a:team_a_id(name, logo_url, primary_color), team_b:team_b_id(name, logo_url, primary_color), winner:winner_team_id(name)")
    .order("created_at");
  if(error) throw error;
  return data;
}

async function getMatch(matchId){
  const { data, error } = await sb
    .from("matches")
    .select("*, week:week_id(week_number), team_a:team_a_id(name, logo_url, primary_color, balance_daraya), team_b:team_b_id(name, logo_url, primary_color, balance_daraya)")
    .eq("id", matchId)
    .single();
  if(error) throw error;
  return data;
}

async function createMatch({ week_id, team_a_id, team_b_id, team_a_stake, team_b_stake }){
  const { data, error } = await sb.rpc("create_match", {
    p_week_id: week_id, p_team_a_id: team_a_id, p_team_b_id: team_b_id,
    p_team_a_stake: team_a_stake, p_team_b_stake: team_b_stake,
  });
  if(error) throw error;
  return data;
}

async function editMatch(matchId, { team_a_id, team_b_id, team_a_stake, team_b_stake }){
  const { data, error } = await sb.rpc("edit_match", {
    p_match_id: matchId, p_team_a_id: team_a_id, p_team_b_id: team_b_id,
    p_team_a_stake: team_a_stake, p_team_b_stake: team_b_stake,
  });
  if(error) throw error;
  return data;
}

async function confirmMatchResult(matchId, winnerTeamId){
  const { data, error } = await sb.rpc("confirm_match_result", {
    p_match_id: matchId, p_winner_team_id: winnerTeamId,
  });
  if(error) throw error;
  return data;
}

async function deleteMatch(matchId){
  const { data, error } = await sb.rpc("delete_match", { p_match_id: matchId });
  if(error) throw error;
  return data;
}

async function undoMatchResult(matchId){
  const { data, error } = await sb.rpc("undo_match_result", { p_match_id: matchId });
  if(error) throw error;
  return data;
}

async function addMatchEvent(matchId, description, eventType = "note", minute = null){
  const { data, error } = await sb.rpc("add_match_event", {
    p_match_id: matchId, p_description: description, p_event_type: eventType, p_minute: minute,
  });
  if(error) throw error;
  return data;
}

async function setMatchPrediction(matchId, reward){
  const { data, error } = await sb.rpc("set_match_prediction", { p_match_id: matchId, p_reward: reward });
  if(error) throw error;
  return data;
}

async function closePrediction(matchId){
  const { data, error } = await sb.rpc("close_prediction", { p_match_id: matchId });
  if(error) throw error;
  return data;
}

async function submitPrediction(matchId, predictedTeamId){
  const { data, error } = await sb.rpc("submit_prediction", { p_match_id: matchId, p_predicted_team_id: predictedTeamId });
  if(error) throw error;
  return data;
}

async function listPredictionsForMatch(matchId){
  const { data, error } = await sb
    .from("match_predictions")
    .select("*, team:predicting_team_id(name)")
    .eq("match_id", matchId);
  if(error) throw error;
  return data;
}

async function setLineup(matchId, teamId, playerIds){
  const { data, error } = await sb.rpc("set_lineup", {
    p_match_id: matchId, p_team_id: teamId, p_player_ids: playerIds,
  });
  if(error) throw error;
  return data;
}

async function listMatchEvents(matchId){
  const { data, error } = await sb
    .from("match_events")
    .select("*")
    .eq("match_id", matchId)
    .order("created_at");
  if(error) throw error;
  return data;
}
