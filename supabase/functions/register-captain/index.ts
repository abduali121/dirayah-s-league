// دالة خادمية: تنشئ حساب Supabase Auth مؤكَّدًا مباشرة (بدون بريد تحقق فعلي)،
// لأن حسابات دوري دراية تستخدم بريدًا وهميًا (رقم_الجوال@dawri.local) لا يمكن
// لأي خدمة بريد الوصول له أصلًا. مفتاح service_role يبقى هنا على الخادم فقط
// (Supabase يوفّره تلقائيًا كمتغيّر بيئة داخل كل Edge Function) ولا يصل للمتصفح إطلاقًا.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if(req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try{
    const { email, password, display_name } = await req.json();

    if(!email || !password){
      return new Response(JSON.stringify({ error: "email and password are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }
    if(String(password).length < 6){
      return new Response(JSON.stringify({ error: "كلمة المرور لازم تكون 6 أرقام على الأقل" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { data, error } = await supabaseAdmin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { display_name: display_name || null },
    });

    if(error){
      const msg = error.message.includes("already been registered") || error.message.includes("already registered")
        ? "هذا الرقم مسجّل مسبقًا — سجّل الدخول بدل إنشاء حساب جديد"
        : error.message;
      return new Response(JSON.stringify({ error: msg }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    return new Response(JSON.stringify({ success: true, id: data.user.id }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }catch(e){
    return new Response(JSON.stringify({ error: String(e) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
