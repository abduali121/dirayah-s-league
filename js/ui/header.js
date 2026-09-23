// يبني رأس الصفحة المشترك (الشعار فقط) + بار تنقل سفلي ثابت شبيه بتطبيقات الجوال
// تسجيل الدخول متاح فقط من الصفحة الرئيسية index.html، لذا لا يظهر هنا أي زر دخول
function renderHeader(profile, activePage){
  const el = document.getElementById("appHeader");
  if(!el) return;

  const inAdmin = window.location.pathname.includes("/admin/");
  const rootPrefix = inAdmin ? "../" : "";
  const assetsPrefix = inAdmin ? "../assets/" : "assets/";

  el.innerHTML = `
    <a class="brand" href="${rootPrefix}index.html" style="text-decoration:none;color:inherit;">
      <span class="brand-logo">
        <img src="${assetsPrefix}daraya-logo-light.png" alt="مجموعة دراية"/>
      </span>
      <div>
        <h1>دوري دراية</h1>
        <p>${profile ? profile.display_name : ""}</p>
      </div>
    </a>
    ${profile
      ? `<button class="btn" style="padding:8px 12px;font-size:12px;" onclick="signOut()">خروج</button>`
      : `<a class="btn" style="padding:8px 12px;font-size:12px;" href="${rootPrefix}index.html">تسجيل الدخول</a>`}
  `;

  const tabs = [
    { href: `${rootPrefix}standings.html`, label: "الرئيسية", icon: "🏠", key: "standings" },
    { href: `${rootPrefix}scoreboard.html`, label: "عدّاد النقاط", icon: "🔢", key: "scoreboard" },
  ];
  if(profile && profile.team_id){
    tabs.push({ href: `${rootPrefix}team-room.html?id=${profile.team_id}`, label: "غرفتي", icon: "🎽", key: "team-room" });
  }
  if(profile && profile.role === "super_admin"){
    tabs.push({ href: `${rootPrefix}admin/index.html`, label: "الإدارة", icon: "👑", key: "admin" });
  }

  let bar = document.getElementById("bottomTabBar");
  if(!bar){
    bar = document.createElement("nav");
    bar.id = "bottomTabBar";
    bar.className = "bottom-tabbar";
    document.body.appendChild(bar);
    document.body.classList.add("has-tabbar");
  }
  bar.innerHTML = tabs.map(t => `
    <a href="${t.href}" class="tab-item ${t.key === activePage ? 'active' : ''}">
      <span class="tab-icon">${t.icon}</span>
      <span class="tab-label">${t.label}</span>
    </a>
  `).join("");
}
