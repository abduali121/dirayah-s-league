// شريط تفاعل صغير (إيموجي) قابل لإعادة الاستخدام على أي بطاقة تصريح أو صورة.
// يشتغل لأي زائر حتى بدون تسجيل دخول (عبر guestKey من js/api/reactions.js)،
// ولحساب حقيقي عبر window.currentUserId (يُضبط من الصفحة المستضيفة بعد تسجيل الدخول).

function reactionButtonsHtml(contentType, itemId, rows, myUserId){
  const myGuestKey = myUserId ? null : getGuestKey();
  return REACTION_EMOJIS.map(emoji => {
    const matches = rows.filter(r => r.content_type === contentType && r.content_id === itemId && r.emoji === emoji);
    const mine = myUserId
      ? matches.some(r => r.reacted_by === myUserId)
      : matches.some(r => r.guest_key === myGuestKey);
    return `<button type="button" class="react-btn ${mine ? "mine" : ""}" onclick="onReactionClick(this,'${contentType}','${itemId}','${emoji}',${mine})">${emoji}${matches.length ? `<span class="rcount">${matches.length}</span>` : ""}</button>`;
  }).join("");
}

function reactionBarHtml(contentType, itemId, rows, myUserId){
  return `<div class="reaction-bar" id="rx-${contentType}-${itemId}">${reactionButtonsHtml(contentType, itemId, rows, myUserId)}</div>`;
}

async function onReactionClick(btn, contentType, itemId, emoji, mine){
  btn.classList.add("pop"); // نبضة فورية عند الضغط، قبل ما ننتظر رد الشبكة
  try{
    await toggleReaction(contentType, itemId, emoji, window.currentUserId || null, mine);
    const rows = await listReactions(contentType, [itemId]);
    const el = document.getElementById(`rx-${contentType}-${itemId}`);
    if(el) el.innerHTML = reactionButtonsHtml(contentType, itemId, rows, window.currentUserId || null);
  }catch(err){ showToast(err.message, "error"); }
}
