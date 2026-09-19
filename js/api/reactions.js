const REACTION_EMOJIS = ["❤️", "🔥", "👏", "😂"];

// هوية بسيطة لزائر بدون تسجيل دخول — رقم عشوائي يُخزَّن بمتصفحه فقط، يميّزه عن باقي
// الزوار دون ما يحتاج حساب حقيقي، عشان يقدر يتفاعل مثل أي كابتن بالضبط.
function getGuestKey(){
  try{
    let key = localStorage.getItem("dawri_guest_key");
    if(!key){
      key = crypto.randomUUID();
      localStorage.setItem("dawri_guest_key", key);
    }
    return key;
  }catch(err){
    return null; // متصفح يمنع localStorage (خصوصية صارمة) — التفاعل كضيف يتعطل بهدوء
  }
}

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
  const identity = myUserId
    ? { column: "reacted_by", value: myUserId, row: { reacted_by: myUserId } }
    : { column: "guest_key", value: getGuestKey(), row: { guest_key: getGuestKey() } };
  if(!identity.value) throw new Error("تعذّر تحديد هويتك للتفاعل بهذا المتصفح");

  if(mine){
    const { error } = await sb.from("content_reactions").delete()
      .eq("content_type", contentType).eq("content_id", contentId)
      .eq("emoji", emoji).eq(identity.column, identity.value);
    if(error) throw error;
  }else{
    const { error } = await sb.from("content_reactions").insert({
      content_type: contentType, content_id: contentId, emoji, ...identity.row,
    });
    if(error) throw error;
  }
}
