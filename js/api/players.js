async function listPlayers(){
  const { data, error } = await sb
    .from("players")
    .select("*, teams:original_team_id(name, primary_color)")
    .order("full_name");
  if(error) throw error;
  return data;
}

async function createPlayer({ full_name, original_team_id, position, photo_url }){
  const { data, error } = await sb.rpc("create_player", {
    p_full_name: full_name, p_original_team_id: original_team_id,
    p_position: position || null, p_photo_url: photo_url || null,
  });
  if(error) throw error;
  return data;
}

async function updatePlayer(playerId, { full_name, position, photo_url, is_active }){
  const { data, error } = await sb.rpc("update_player", {
    p_player_id: playerId, p_full_name: full_name, p_position: position || null,
    p_photo_url: photo_url || null, p_is_active: is_active,
  });
  if(error) throw error;
  return data;
}
