// "يوم الإبراز": صورة يدفع فريق مقابلها عشان تظهر كإعلان يملأ الشاشة لأول مرة
// يدخل فيها أي زائر بذاك اليوم بالذات — لمدة 10 ثوانٍ وبدون إمكانية إغلاقها يدويًا.
// يُعرض مرة واحدة لكل جلسة متصفح (sessionStorage)، بغض النظر عن أي صفحة دخل منها الزائر.

async function initFeaturedTakeover(){
  try{
    const todayKey = `featured_shown_${new Date().toISOString().slice(0, 10)}`;
    if(sessionStorage.getItem(todayKey)) return;

    const { data, error } = await sb.from("featured_photo_public").select("*").limit(1);
    if(error || !data || !data.length) return;

    sessionStorage.setItem(todayKey, "1");

    const overlay = document.createElement("div");
    overlay.className = "featured-takeover";
    overlay.innerHTML = `<span class="ft-tag">إعلان اليوم</span><img src="${data[0].image_url}" alt=""/>`;
    document.body.appendChild(overlay);

    requestAnimationFrame(() => overlay.classList.add("show"));
    setTimeout(() => {
      overlay.classList.remove("show");
      setTimeout(() => overlay.remove(), 400);
    }, 10000);
  }catch(err){
    // فشل هذا العنصر الزخرفي ما يوقف باقي الصفحة
  }
}

document.addEventListener("DOMContentLoaded", initFeaturedTakeover);
