function renderAdminNav(activePage){
  const el = document.getElementById("appHeader");
  if(!el) return;
  const tabs = [
    { href: "index.html", label: "الرئيسية", key: "home" },
    { href: "teams.html", label: "الفرق", key: "teams" },
    { href: "players.html", label: "اللاعبون", key: "players" },
    { href: "matches.html", label: "المباريات", key: "matches" },
    { href: "loan-requests.html", label: "صفقات الإعارة", key: "loans" },
    { href: "announcements.html", label: "تصريحات الدوري", key: "announcements" },
    { href: "photos.html", label: "صور الدوري", key: "photos" },
    { href: "balances.html", label: "الأرصدة", key: "balances" },
    { href: "audit.html", label: "سجل التدقيق", key: "audit" },
  ];
  el.innerHTML = `
    <div class="brand">
      <span class="brand-logo">
        <img src="../assets/daraya-logo-light.png" alt="مجموعة دراية"/>
      </span>
      <div><h1>لوحة الإدارة</h1><p>دوري دراية</p></div>
    </div>
    <div style="display:flex;align-items:center;gap:8px;">
      <a href="../standings.html" class="btn" style="padding:8px 12px;font-size:12px;">الموقع</a>
      <button class="btn" style="padding:8px 12px;font-size:12px;" onclick="signOut()">خروج</button>
    </div>
  `;
  const tabsEl = document.getElementById("adminTabs");
  if(tabsEl){
    tabsEl.innerHTML = tabs.map(t => `
      <a href="${t.href}" class="btn ${t.key === activePage ? 'primary' : ''}" style="font-size:12px;padding:9px 12px;">${t.label}</a>
    `).join("");
  }
}
