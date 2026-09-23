// اتصال Supabase — يحتوي فقط على anon public key (آمن للنشر في كود الواجهة).
// لا تضع service_role key هنا أبدًا تحت أي ظرف.

const SUPABASE_URL = "https://qixybynryzcxxmqlcyow.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFpeHlieW5yeXpjeHhtcWxjeW93Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg1NDMyNjIsImV4cCI6MjEwNDExOTI2Mn0.f9YQYh1qV4G-Q--24pY_1Rw7M9xrjafZ1AVpRqBb6-s";

// اسم المتغيّر "sb" (وليس "supabase") عمدًا: مكتبة supabase-js تحجز الاسم العام
// "supabase" لنفسها (window.supabase)، وإعادة استخدامه هنا كـ const يسبب تعارضًا.
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
