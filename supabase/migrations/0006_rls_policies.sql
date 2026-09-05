-- دوري دراية: سياسات الأمان (RLS)
-- =================================
-- المبدأ العام: القراءة مفتوحة لأي مستخدم مسجّل دخول (دوري داخلي مغلق).
-- الكتابة: لا صلاحية مباشرة لأي مستخدم (لا admin ولا captain) على أي جدول أدناه.
-- كل تعديل يمر حصرًا عبر دوال RPC (SECURITY DEFINER) في 0007 التي تعمل بصلاحية
-- مالك الجدول (postgres) فتتجاوز RLS تلقائيًا بعد أن تتحقق من الشروط بنفسها.
-- هذا يمنع فعليًا -على مستوى قاعدة البيانات- أي فريق (أو حتى خطأ في واجهة الإدارة)
-- من تعديل الرصيد أو نتيجة المباراة أو ملكية اللاعبين مباشرة.

-- إزالة أي صلاحيات افتراضية قد يمنحها Supabase على public schema
revoke insert, update, delete on all tables in schema public from authenticated, anon;

-- ============ القراءة (SELECT) ============

create policy sel_teams on teams for select to authenticated using (true);
create policy sel_profiles on profiles for select to authenticated using (true);
create policy sel_players on players for select to authenticated using (true);
create policy sel_weeks on weeks for select to authenticated using (true);
create policy sel_matches on matches for select to authenticated using (true);
create policy sel_match_events on match_events for select to authenticated using (true);
create policy sel_match_lineups on match_lineups for select to authenticated using (true);
create policy sel_auctions on auctions for select to authenticated using (true);
create policy sel_match_loans on match_loans for select to authenticated using (true);
create policy sel_balance_ledger on balance_ledger for select to authenticated using (true);
create policy sel_standings on standings_snapshots for select to authenticated using (true);

-- bids: تُخفى هوية المزايد أثناء المزاد السري المفتوح (يُفضَّل قراءة bids_public من العميل
-- لأنها تُخفي team_id تلقائيًا؛ هذه السياسة حماية إضافية للجدول الخام نفسه)
create policy sel_bids on bids for select to authenticated using (
  is_admin()
  or team_id = my_team_id()
  or not exists (
    select 1 from auctions a
    where a.id = bids.auction_id and a.is_secret and a.status = 'open'
  )
);

-- audit_log: للمدير فقط
create policy sel_audit_log on audit_log for select to authenticated using (is_admin());

grant select on bids_public to authenticated;
