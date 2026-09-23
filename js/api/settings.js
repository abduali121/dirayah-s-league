async function getClaimsLocked(){
  const { data, error } = await sb.from("league_settings").select("claims_locked").eq("id", true).single();
  if(error) throw error;
  return data.claims_locked;
}

async function setClaimsLock(locked){
  const { data, error } = await sb.rpc("set_claims_lock", { p_locked: locked });
  if(error) throw error;
  return data;
}
