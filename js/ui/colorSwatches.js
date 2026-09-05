// لوحة ألوان محدودة (10 ألوان رياضية) بدل منتقي الألوان المفتوح
const TEAM_COLORS = [
  { name: "كحلي",    hex: "#1a3a5c" },
  { name: "أحمر",    hex: "#b91c1c" },
  { name: "أخضر",    hex: "#15803d" },
  { name: "ذهبي",    hex: "#b8952a" },
  { name: "أسود",    hex: "#1c1c1c" },
  { name: "رمادي",   hex: "#4b5563" },
  { name: "برتقالي", hex: "#c2410c" },
  { name: "أزرق",    hex: "#1d4ed8" },
  { name: "عنابي",   hex: "#7f1d1d" },
  { name: "تركواز",  hex: "#0f766e" },
];

function renderColorSwatches(pickerId, selectedHex){
  const sel = selectedHex || TEAM_COLORS[0].hex;
  return `
    <input type="hidden" id="${pickerId}" value="${sel}"/>
    <div class="swatch-picker" id="${pickerId}-wrap">
      ${TEAM_COLORS.map(c => `
        <button type="button" class="swatch-btn ${c.hex.toLowerCase() === sel.toLowerCase() ? 'active' : ''}"
          style="background:${c.hex}" title="${c.name}"
          onclick="selectSwatch('${pickerId}', '${c.hex}', this)"></button>
      `).join("")}
    </div>
  `;
}

function selectSwatch(pickerId, hex, btnEl){
  document.getElementById(pickerId).value = hex;
  const wrap = document.getElementById(`${pickerId}-wrap`);
  wrap.querySelectorAll(".swatch-btn").forEach(b => b.classList.remove("active"));
  btnEl.classList.add("active");
}
