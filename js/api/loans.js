// نظام "تسجيل صفقة الإعارة" — التفاوض يتم خارج التطبيق، والكابتن يسجّل هنا
// اللاعب والمبلغ. المبلغ مخفي إلا عن المدير والفريقين المعنيين (loan_claims_public).

async function listClaimsForMatch(matchId){
  const { data, error } = await sb
    .from("loan_claims_public")
    .select("*")
    .eq("match_id", matchId)
    .order("created_at", { ascending: false });
  if(error) throw error;
  return data;
}

async function claimPlayerLoan(matchId, playerId, amount, note){
  const { data, error } = await sb.rpc("claim_player_loan", {
    p_match_id: matchId, p_player_id: playerId, p_amount: amount, p_note: note || null,
  });
  if(error) throw error;
  return data;
}

async function approveLoanClaim(claimId){
  const { data, error } = await sb.rpc("approve_loan_claim", { p_claim_id: claimId });
  if(error) throw error;
  return data;
}

async function rejectLoanClaim(claimId){
  const { data, error } = await sb.rpc("reject_loan_claim", { p_claim_id: claimId });
  if(error) throw error;
  return data;
}

async function listAllPendingClaims(){
  const { data, error } = await sb
    .from("loan_claims_public")
    .select("*")
    .eq("status", "pending")
    .order("created_at");
  if(error) throw error;
  return data;
}

async function listLoansForMatch(matchId){
  const { data, error } = await sb
    .from("match_loans")
    .select("*, players:player_id(full_name), original:original_team_id(name), borrower:borrowing_team_id(name)")
    .eq("match_id", matchId);
  if(error) throw error;
  return data;
}
