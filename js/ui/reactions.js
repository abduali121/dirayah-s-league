// شريط تفاعل صغير (إيموجي) قابل لإعادة الاستخدام على أي بطاقة تصريح أو صورة.
// يشتغل لأي زائر حتى بدون تسجيل دخول (عبر guestKey من js/api/reactions.js)،
// ولحساب حقيقي عبر window.currentUserId. تفاعل واحد بس لكل هوية على نفس المحتوى —
// الضغط على إيموجي ثاني ينقل تفاعلك له بدل ما يضيف تفاعل زيادة.

function myCurrentEmoji(contentType, itemId, rows, myUserId){
  const myGuestKey = myUserId ? null : getGuestKey();
  const mine = rows.find(r => r.content_type === contentType && r.content_id === itemId &&
    (myUserId ? r.reacted_by === myUserId : r.guest_key === myGuestKey));
  return mine ? mine.emoji : null;
}

function reactionButtonsHtml(contentType, itemId, rows, myUserId){
  const current = myCurrentEmoji(contentType, itemId, rows, myUserId);
  return REACTION_EMOJIS.map(emoji => {
    const matches = rows.filter(r => r.content_type === contentType && r.content_id === itemId && r.emoji === emoji);
    const mine = current === emoji;
    return `<button type="button" class="react-btn ${mine ? "mine" : ""}" onclick="onReactionClick(this,'${contentType}','${itemId}','${emoji}','${current || ""}')">${emoji}${matches.length ? `<span class="rcount">${matches.length}</span>` : ""}</button>`;
  }).join("");
}

function reactionBarHtml(contentType, itemId, rows, myUserId){
  return `<div class="reaction-bar" id="rx-${contentType}-${itemId}">${reactionButtonsHtml(contentType, itemId, rows, myUserId)}</div>`;
}

async function onReactionClick(btn, contentType, itemId, emoji, currentEmoji){
  btn.classList.add("pop"); // نبضة فورية عند الضغط، قبل ما ننتظر رد الشبكة
  try{
    await setReaction(contentType, itemId, emoji, window.currentUserId || null, currentEmoji || null);
    const rows = await listReactions(contentType, [itemId]);
    const el = document.getElementById(`rx-${contentType}-${itemId}`);
    if(el) el.innerHTML = reactionButtonsHtml(contentType, itemId, rows, window.currentUserId || null);
  }catch(err){ showToast(err.message, "error"); }
}
