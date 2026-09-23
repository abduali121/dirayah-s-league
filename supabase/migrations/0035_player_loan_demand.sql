-- دوري دراية: لوحة "الأكثر طلبًا" — أعلى 5 لاعبين حسب إجمالي مبالغ الإعارة اللي فازوا
-- فيها فعليًا (يستعار ويفوز الفريق المستعير، بالضبط نفس شرط تحصيل رسم الإعارة الحقيقي).
-- "الفوز مع فريقه" رقم معلوماتي بجانبه فقط، ما يدخل بالترتيب.
-- =============================================================================

create or replace view player_loan_demand as
with loan_earnings as (
  select fl.player_id, sum(fl.winning_bid_amount) as loan_earnings
  from match_loans fl
  join matches m on m.id = fl.match_id
  where m.status = 'completed' and fl.borrowing_team_id = m.winner_team_id
  group by fl.player_id
),
team_wins as (
  select ml.player_id, count(*) as team_wins
  from match_lineups ml
  join matches m on m.id = ml.match_id
  join players p on p.id = ml.player_id
  where m.status = 'completed' and ml.team_id = m.winner_team_id and ml.team_id = p.original_team_id
  group by ml.player_id
)
select
  p.id as player_id, p.full_name, p.original_team_id,
  t.name as team_name, t.primary_color as team_color, t.logo_url as team_logo_url,
  coalesce(le.loan_earnings, 0) as loan_earnings,
  coalesce(tw.team_wins, 0) as team_wins
from players p
join teams t on t.id = p.original_team_id
left join loan_earnings le on le.player_id = p.id
left join team_wins tw on tw.player_id = p.id
where coalesce(le.loan_earnings, 0) > 0;

grant select on player_loan_demand to anon, authenticated;
