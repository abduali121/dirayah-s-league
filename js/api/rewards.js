// جداول درجات مكافأة التفاعل — لازم تطابق القيم المكتوبة داخل دالة grant_reaction_reward بالضبط
const REACTION_REWARD_TIERS = {
  announcement: [{ tier: 10, amount: 20 }, { tier: 25, amount: 50 }, { tier: 50, amount: 100 }],
  photo: [{ tier: 10, amount: 40 }, { tier: 25, amount: 100 }, { tier: 50, amount: 200 }],
};

async function listGrantedReactionRewards(contentType, contentIds){
  if(!contentIds.length) return [];
  const { data, error } = await sb
    .from("content_reaction_rewards")
    .select("content_id, tier_threshold, amount")
    .eq("content_type", contentType)
    .in("content_id", contentIds);
  if(error) throw error;
  return data;
}

async function grantReactionReward(contentType, contentId, tier){
  const { data, error } = await sb.rpc("grant_reaction_reward", {
    p_content_type: contentType, p_content_id: contentId, p_tier: tier,
  });
  if(error) throw error;
  return data;
}
