// دالة خادمية: تحذف حساب دخول كابتن فريق بالكامل (Supabase Auth)، تُستخدم من
// لوحة الإدارة كزر "حذف الرمز" — إذا نسى الكابتن رمزه، يحذفه المدير هنا فيرجع
// الفريق لحالة "لم يُفعّل بعد"، ويقدر الكابتن يفعّل حسابه من جديد برمز جديد.
// يتحقق هذا الملف بنفسه أن المتصل مدير فعليًا (وليس فقط يملك anon key)، لأن
// مفتاح service_role هنا قوي جدًا ولازم يبقى محميًا حتى لو تسرّب رابط الدالة.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if(req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try{
    const { team_id } = await req.json();
    if(!team_id){
      return new Response(JSON.stringify({ error: "team_id is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: callerData, error: callerErr } = await supabaseAdmin.auth.getUser(token);
    if(callerErr || !callerData?.user){
      return new Response(JSON.stringify({ error: "unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const { data: callerProfile } = await supabaseAdmin
      .from("profiles").select("role").eq("id", callerData.user.id).single();
    if(!callerProfile || callerProfile.role !== "super_admin"){
      return new Response(JSON.stringify({ error: "forbidden: admin only" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const { data: captainProfile } = await supabaseAdmin
      .from("profiles").select("id").eq("team_id", team_id).single();
    if(!captainProfile){
      return new Response(JSON.stringify({ error: "لا يوجد حساب مُفعّل لهذا الفريق أصلًا" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const { error: delErr } = await supabaseAdmin.auth.admin.deleteUser(captainProfile.id);
    if(delErr){
      return new Response(JSON.stringify({ error: delErr.message }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    return new Response(JSON.stringify({ success: true }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }catch(e){
    return new Response(JSON.stringify({ error: String(e) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
