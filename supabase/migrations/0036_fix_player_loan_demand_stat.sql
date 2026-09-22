-- دوري وثاق: تصحيح — الرقم الثاني بجانب المبلغ يكون "كم مرة فاز بالإعارة" (نفس شرط
-- كسب مبلغ الإعارة بالضبط)، مو فوزه مع فريقه الأصلي (كان مو مرتبط بموضوع "الأكثر طلبًا" أصلًا).
-- =============================================================================

-- Postgres يمنع CREATE OR REPLACE VIEW من تغيير اسم عمود موجود (لازم حذف وإعادة إنشاء)
drop view if exists player_loan_demand;

create view player_loan_demand as
with loan_stats as (
  select fl.player_id, sum(fl.winning_bid_amount) as loan_earnings, count(*) as loan_wins
  from match_loans fl
  join matches m on m.id = fl.match_id
  where m.status = 'completed' and fl.borrowing_team_id = m.winner_team_id
  group by fl.player_id
)
select
  p.id as player_id, p.full_name, p.original_team_id,
  t.name as team_name, t.primary_color as team_color, t.logo_url as team_logo_url,
  coalesce(ls.loan_earnings, 0) as loan_earnings,
  coalesce(ls.loan_wins, 0) as loan_wins
from players p
join teams t on t.id = p.original_team_id
left join loan_stats ls on ls.player_id = p.id
where coalesce(ls.loan_earnings, 0) > 0;

grant select on player_loan_demand to anon, authenticated;
