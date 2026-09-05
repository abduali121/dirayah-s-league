async function adjustBalance(teamId, delta, reason){
  const { data, error } = await sb.rpc("adjust_balance", {
    p_team_id: teamId, p_delta: delta, p_reason: reason,
  });
  if(error) throw error;
  return data;
}

async function listLedger(teamId = null){
  let q = sb.from("balance_ledger").select("*, teams:team_id(name)").order("created_at", { ascending: false });
  if(teamId) q = q.eq("team_id", teamId);
  const { data, error } = await q;
  if(error) throw error;
  return data;
}

async function listAuditLog(){
  const { data, error } = await sb
    .from("audit_log")
    .select("*, profiles:actor_id(display_name)")
    .order("created_at", { ascending: false })
    .limit(200);
  if(error) throw error;
  return data;
}
