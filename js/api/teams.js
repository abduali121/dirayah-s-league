// يطابق تحويل رقم الجوال في auth.js حرفيًا، حتى يُسجَّل بنفس الصيغة اللي سيُشتق
// بها لاحقًا من بريد التسجيل الذاتي الوهمي (المحلي@dawri.local)
function normalizePhone(input){
  if(!input) return null;
  let digits = toWesternDigits(String(input).trim()).replace(/\D/g, "");
  if(!digits) return null;
  if(digits.startsWith("966")) digits = digits.slice(3);
  if(digits.startsWith("0")) digits = digits.slice(1);
  return digits;
}

async function listTeams(){
  const { data, error } = await sb.from("teams").select("*").order("name");
  if(error) throw error;
  return data;
}

// مجموعة معرّفات الفرق اللي كباتنها فعّلوا حسابهم (عندهم صف profile مرتبط)
async function listActivatedTeamIds(){
  const { data, error } = await sb.from("profiles").select("team_id").not("team_id", "is", null);
  if(error) throw error;
  return new Set(data.map(p => p.team_id));
}

// اللون الثانوي غير مستخدم بصريًا في التطبيق حاليًا، فنثبّته تلقائيًا (ذهبي)
// بدل ما نزيد اختيارًا إضافيًا على المستخدم في نموذج الفريق.
const DEFAULT_SECONDARY_COLOR = "#b8952a";

async function createTeam({ name, logo_url, primary_color, captain_phone }){
  const { data, error } = await sb.rpc("create_team", {
    p_name: name, p_logo_url: logo_url || null,
    p_primary_color: primary_color || "#1a3a5c", p_secondary_color: DEFAULT_SECONDARY_COLOR,
    p_captain_phone: normalizePhone(captain_phone),
  });
  if(error) throw error;
  return data;
}

async function updateTeam(teamId, { name, logo_url, primary_color, captain_phone }){
  const { data, error } = await sb.rpc("update_team", {
    p_team_id: teamId, p_name: name, p_logo_url: logo_url || null,
    p_primary_color: primary_color, p_secondary_color: DEFAULT_SECONDARY_COLOR,
    p_captain_phone: normalizePhone(captain_phone),
  });
  if(error) throw error;
  return data;
}
