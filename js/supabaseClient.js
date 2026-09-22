// اتصال Supabase — يحتوي فقط على anon public key (آمن للنشر في كود الواجهة).
// لا تضع service_role key هنا أبدًا تحت أي ظرف.

const SUPABASE_URL = "https://usnmytayztztmucqhejm.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVzbm15dGF5enR6dG11Y3FoZWptIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAwOTQ1MDAsImV4cCI6MjEwNTY3MDUwMH0.Q9RsuggwclVk2JmUWm-dnoQ53PHgcVXsgsulew62tjs";

// اسم المتغيّر "sb" (وليس "supabase") عمدًا: مكتبة supabase-js تحجز الاسم العام
// "supabase" لنفسها (window.supabase)، وإعادة استخدامه هنا كـ const يسبب تعارضًا.
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
