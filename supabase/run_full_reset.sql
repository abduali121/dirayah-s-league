-- دوري دراية: تصفير كامل لبداية موسم حقيقي — يحذف كل شيء إلا حساب الإدارة
-- =============================================================================

-- 1) حذف كل البيانات التشغيلية (بترتيب صحيح يحترم الروابط بين الجداول:
--    balance_ledger يشير لـ match_loans، وmatch_loans يشير لـ loan_claims،
--    فلازم الاثنين ينحذفون قبل الجدول اللي يشيرون له)
delete from match_predictions;
delete from balance_ledger;
delete from match_lineups;
delete from match_events;
delete from match_loans;
delete from loan_claims;
delete from standings_snapshots;
delete from league_announcements;
delete from league_photos;
delete from audit_log;
delete from matches;
delete from players;

-- 2) حذف حسابات الكباتن المفعّلة فقط (حساب الإدارة محفوظ لأن دوره super_admin،
--    والحذف هنا يحذف صف profiles تلقائيًا معه لأنه مربوط بـ on delete cascade)
delete from auth.users where id in (select id from profiles where role = 'team_captain');

-- 3) حذف الفرق نفسها بالكامل — جاهزة تضيف فرقك الحقيقية من admin/teams.html
delete from teams;
