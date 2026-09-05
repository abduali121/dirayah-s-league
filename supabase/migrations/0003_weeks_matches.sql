-- دوري دراية: الأسابيع والمباريات
-- ================================

create table weeks (
  id            uuid primary key default gen_random_uuid(),
  week_number   integer not null unique check (week_number between 1 and 15),
  starts_at     timestamptz,
  ends_at       timestamptz
);

create type match_status as enum ('scheduled', 'live', 'awaiting_result', 'completed', 'cancelled');

create table matches (
  id                     uuid primary key default gen_random_uuid(),
  week_id                uuid not null unique references weeks(id),
  team_a_id              uuid not null references teams(id),
  team_b_id              uuid not null references teams(id),
  stake_daraya           integer not null check (stake_daraya > 0),
  status                 match_status not null default 'scheduled',
  winner_team_id         uuid references teams(id),
  team_a_balance_before  integer,
  team_b_balance_before  integer,
  team_a_balance_after   integer,
  team_b_balance_after   integer,
  confirmed_at           timestamptz,
  confirmed_by           uuid references profiles(id),
  created_at             timestamptz not null default now(),
  constraint chk_teams_differ check (team_a_id <> team_b_id),
  constraint chk_winner_is_participant check (
    winner_team_id is null or winner_team_id in (team_a_id, team_b_id)
  )
);
create index idx_matches_status on matches(status);

create table match_events (
  id           bigint generated always as identity primary key,
  match_id     uuid not null references matches(id) on delete cascade,
  minute       integer,
  event_type   text not null default 'note',
  description  text not null,
  created_by   uuid references profiles(id),
  created_at   timestamptz not null default now()
);

create table match_lineups (
  id           uuid primary key default gen_random_uuid(),
  match_id     uuid not null references matches(id) on delete cascade,
  team_id      uuid not null references teams(id),
  player_id    uuid not null references players(id),
  is_starting  boolean not null default true,
  created_at   timestamptz not null default now(),
  unique (match_id, player_id)
);

alter table weeks enable row level security;
alter table matches enable row level security;
alter table match_events enable row level security;
alter table match_lineups enable row level security;
