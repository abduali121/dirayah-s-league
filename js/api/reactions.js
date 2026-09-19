const REACTION_EMOJIS = ["❤️", "🔥", "👏", "😂"];

async function listReactions(contentType, contentIds){
  if(!contentIds.length) return [];
  const { data, error } = await sb
    .from("content_reactions")
    .select("*")
    .eq("content_type", contentType)
    .in("content_id", contentIds);
  if(error) throw error;
  return data;
}

async function toggleReaction(contentType, contentId, emoji, myUserId, mine){
  if(mine){
    const { error } = await sb.from("content_reactions").delete()
      .eq("content_type", contentType).eq("content_id", contentId)
      .eq("emoji", emoji).eq("reacted_by", myUserId);
    if(error) throw error;
  }else{
    const { error } = await sb.from("content_reactions").insert({
      content_type: contentType, content_id: contentId, emoji, reacted_by: myUserId,
    });
    if(error) throw error;
  }
}
