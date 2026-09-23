-- دوري دراية: السماح بأكثر من مباراة في نفس الأسبوع
-- =============================================================================

alter table matches drop constraint if exists matches_week_id_key;
create index if not exists idx_matches_week_id on matches(week_id);
