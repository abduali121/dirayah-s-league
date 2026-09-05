// يبني رأس الصفحة المشترك (الشعار + التنقل حسب الدور) داخل عنصر #appHeader
// تسجيل الدخول متاح فقط من الصفحة الرئيسية index.html، لذا لا يظهر هنا أي زر دخول
function renderHeader(profile, activePage){
  const el = document.getElementById("appHeader");
  if(!el) return;

  const inAdmin = window.location.pathname.includes("/admin/");
  const rootPrefix = inAdmin ? "../" : "";

  const navLinks = [
    { href: `${rootPrefix}index.html`, label: "→ الرئيسية", key: "home" },
    { href: `${rootPrefix}standings.html`, label: "الترتيب", key: "standings" },
  ];
  if(profile && profile.team_id){
    navLinks.push({ href: `${rootPrefix}team-room.html?id=${profile.team_id}`, label: "غرفتي", key: "team-room" });
  }
  if(profile && profile.role === "super_admin"){
    navLinks.push({ href: `${rootPrefix}admin/index.html`, label: "الإدارة", key: "admin" });
  }

  const assetsPrefix = inAdmin ? "../assets/" : "assets/";
  el.innerHTML = `
    <div class="brand">
      <span class="brand-logo">
        <img class="logo-light" src="${assetsPrefix}daraya-logo-light.png" alt="مجموعة دراية"/>
        <img class="logo-dark" src="${assetsPrefix}daraya-logo-dark.png" alt="مجموعة دراية"/>
      </span>
      <div>
        <h1>دوري دراية</h1>
        <p>${profile ? profile.display_name : ""}</p>
      </div>
    </div>
    <div style="display:flex;align-items:center;gap:8px;">
      <nav style="display:flex;gap:10px;">
        ${navLinks.map(l => `<a href="${l.href}" style="font-size:13px;font-weight:700;${l.key===activePage?'color:var(--gold);':'color:var(--text2);'}">${l.label}</a>`).join("")}
      </nav>
      ${profile ? `<button class="btn" style="padding:8px 12px;font-size:12px;" onclick="signOut()">خروج</button>` : ``}
    </div>
  `;
}
