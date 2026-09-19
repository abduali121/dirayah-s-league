// شريط تفاعل صغير (إيموجي) قابل لإعادة الاستخدام على أي بطاقة تصريح أو صورة.
// يعتمد على window.currentUserId (يُضبط من الصفحة المستضيفة بعد تسجيل الدخول)
// ودالتي listReactions/toggleReaction من js/api/reactions.js.

function reactionButtonsHtml(contentType, itemId, rows, myUserId){
  return REACTION_EMOJIS.map(emoji => {
    const matches = rows.filter(r => r.content_type === contentType && r.content_id === itemId && r.emoji === emoji);
    const mine = !!myUserId && matches.some(r => r.reacted_by === myUserId);
    return `<button type="button" class="react-btn ${mine ? "mine" : ""}" onclick="onReactionClick('${contentType}','${itemId}','${emoji}',${mine})">${emoji}${matches.length ? `<span class="rcount">${matches.length}</span>` : ""}</button>`;
  }).join("");
}

function reactionBarHtml(contentType, itemId, rows, myUserId){
  return `<div class="reaction-bar" id="rx-${contentType}-${itemId}">${reactionButtonsHtml(contentType, itemId, rows, myUserId)}</div>`;
}

async function onReactionClick(contentType, itemId, emoji, mine){
  if(!window.currentUserId){ showToast("سجّل الدخول عشان تتفاعل", "error"); return; }
  try{
    await toggleReaction(contentType, itemId, emoji, window.currentUserId, mine);
    const rows = await listReactions(contentType, [itemId]);
    const el = document.getElementById(`rx-${contentType}-${itemId}`);
    if(el) el.innerHTML = reactionButtonsHtml(contentType, itemId, rows, window.currentUserId);
  }catch(err){ showToast(err.message, "error"); }
}
