-- دوري دراية: اللاعبون
-- ====================

create table players (
  id                 uuid primary key default gen_random_uuid(),
  full_name          text not null,
  original_team_id   uuid not null references teams(id),
  position           text,
  photo_url          text,
  is_active          boolean not null default true,
  created_at         timestamptz not null default now()
);
create index idx_players_original_team on players(original_team_id);

alter table players enable row level security;
