// مساعدات المصادقة: تسجيل الدخول/الخروج، وجلب الدور والفريق من profiles

// صفحات admin/*.html أعمق بمستوى واحد من جذر الموقع؛ هذا يحسب البادئة الصحيحة للتوجيه
function rootPath(file){
  return (window.location.pathname.includes("/admin/") ? "../" : "") + file;
}

async function getSession(){
  const { data } = await sb.auth.getSession();
  return data.session;
}

async function getMyProfile(){
  const session = await getSession();
  if(!session) return null;
  const { data, error } = await sb
    .from("profiles")
    .select("id, role, team_id, display_name, teams(name, logo_url, primary_color, secondary_color)")
    .eq("id", session.user.id)
    .single();
  if(error){ console.error(error); return null; }
  return data;
}

// يحوّل الأرقام العربية (٠-٩) والفارسية (۰-۹) لأرقام إنجليزية عادية،
// حتى يقدر المستخدم يكتب رقم جواله بأي لوحة مفاتيح عربية بدون مشاكل.
function toWesternDigits(input){
  return input.replace(/[٠-٩۰-۹]/g, (d) => {
    const code = d.charCodeAt(0);
    if(code >= 0x0660 && code <= 0x0669) return String(code - 0x0660);
    return String(code - 0x06F0);
  });
}

// Supabase Auth يتطلب بريدًا إلكترونيًا تقنيًا، فنحوّل رقم الجوال داخليًا لصيغة
// بريد وهمي ثابتة (بدون أي إرسال رسائل تحقق فعلية) — المستخدم لا يرى هذا التفصيل إطلاقًا.
// يقبل أيضًا بريدًا حقيقيًا كما هو (لحسابات مثل المدير التي أُنشئت ببريد فعلي).
function normalizeLoginIdentifier(input){
  const trimmed = toWesternDigits(input.trim());
  if(trimmed.includes("@")) return trimmed.toLowerCase();
  let digits = trimmed.replace(/\D/g, "");
  if(digits.startsWith("966")) digits = digits.slice(3);
  if(digits.startsWith("0")) digits = digits.slice(1);
  return `${digits}@dawri.local`;
}

// كلمة المرور عندنا دائمًا أرقام فقط، فنحوّلها هي كذلك للأرقام الإنجليزية —
// وإلا لوحة مفاتيح عربية تكتب "٤٨٢٩١٥" وهذا نص مختلف تمامًا عن "482915" بالنسبة لقاعدة البيانات.
async function signIn(identifier, password){
  const email = normalizeLoginIdentifier(identifier);
  const { data, error } = await sb.auth.signInWithPassword({ email, password: toWesternDigits(password) });
  if(error) throw error;
  return data;
}

// تسجيل ذاتي عبر Edge Function (وليس supabase.auth.signUp() مباشرة) لأن Supabase
// يفرض تأكيد بريد إلكتروني حتى لو كان وهميًا @dawri.local (بريد لا يمكن الوصول له أصلًا)،
// فتفشل العملية بخطأ "email rate limit". الدالة الخادمية تُنشئ الحساب مؤكَّدًا مباشرة
// عبر Admin API (بمفتاح service_role الذي يبقى على الخادم ولا يصل للمتصفح إطلاقًا)،
// ثم نسجّل الدخول تلقائيًا بعدها. الدور والفريق لا يُشتقان من أي شيء يرسله العميل —
// يحددهما trigger داخل قاعدة البيانات حسب رقم الجوال المسجَّل مسبقًا من المدير على الفريق.
async function signUp(identifier, password, displayName){
  const email = normalizeLoginIdentifier(identifier);
  const cleanPassword = toWesternDigits(password);

  const resp = await fetch(`${SUPABASE_URL}/functions/v1/register-captain`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "apikey": SUPABASE_ANON_KEY, "Authorization": `Bearer ${SUPABASE_ANON_KEY}` },
    body: JSON.stringify({ email, password: cleanPassword, display_name: displayName || null }),
  });
  const result = await resp.json();
  if(!resp.ok) throw new Error(result.error || "تعذّر إنشاء الحساب");

  return await signIn(identifier, cleanPassword);
}

// يتحقق قبل عرض نموذج الدخول: هل الرقم مسجَّل من الإدارة على فريق؟ وإذا كان
// مسجَّلًا، هل صاحبه فعّل حسابه من قبل (يدخل برمزه) أو هذه أول مرة (يختار رمزًا)؟
async function checkCaptainPhone(identifier){
  const email = normalizeLoginIdentifier(identifier);
  const phone = email.split("@")[0];
  const { data, error } = await sb.rpc("check_captain_phone", { p_phone: phone });
  if(error) throw error;
  return data;
}

// زر "حذف الرمز" بلوحة الإدارة: يحذف حساب دخول الكابتن بالكامل عبر دالة خادمية
// (تتحقق هي بنفسها أن المتصل مدير فعليًا)، ليرجع الفريق لحالة "لم يُفعّل بعد".
async function deleteCaptainAccount(teamId){
  const session = await getSession();
  const resp = await fetch(`${SUPABASE_URL}/functions/v1/delete-captain-account`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json", "apikey": SUPABASE_ANON_KEY,
      "Authorization": `Bearer ${session?.access_token || SUPABASE_ANON_KEY}`,
    },
    body: JSON.stringify({ team_id: teamId }),
  });
  const result = await resp.json();
  if(!resp.ok) throw new Error(result.error || "تعذّر حذف الرمز");
  return result;
}

async function signOut(){
  await sb.auth.signOut();
  window.location.href = rootPath("login.html");
}

// يحمي صفحة معيّنة: يعيد التوجيه لتسجيل الدخول إن لم توجد جلسة،
// أو للصفحة الرئيسية إن كانت الصفحة تتطلب صلاحية مدير ولا يملكها المستخدم.
async function requireAuth({ adminOnly = false } = {}){
  const profile = await getMyProfile();
  if(!profile){
    window.location.href = rootPath("login.html");
    return null;
  }
  if(adminOnly && profile.role !== "super_admin"){
    window.location.href = rootPath("index.html");
    return null;
  }
  return profile;
}

// للصفحات القابلة للمشاهدة العامة: لا يعيد توجيه أحد، فقط يرجع الملف الشخصي
// إن وُجد (null للزائر غير المسجّل، وهذا مسموح تمامًا في هذه الصفحات).
async function optionalAuth(){
  return await getMyProfile();
}
