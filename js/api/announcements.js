async function listAnnouncements(limit = 20){
  const { data, error } = await sb
    .from("league_announcements")
    .select("*, team:team_id(name, primary_color, logo_url)")
    .order("created_at", { ascending: false })
    .limit(limit);
  if(error) throw error;
  return data;
}

async function createAnnouncement(body, teamId = null){
  const { data, error } = await sb.rpc("create_announcement", { p_body: body, p_team_id: teamId });
  if(error) throw error;
  return data;
}

async function deleteAnnouncement(id){
  const { data, error } = await sb.rpc("delete_announcement", { p_announcement_id: id });
  if(error) throw error;
  return data;
}
