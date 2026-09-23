-- دوري دراية: المزادات والمزايدات والإعارات
-- ===========================================
-- ملاحظة معمارية: الإعارة (match_loans) مرتبطة بمباراة واحدة فقط (match_id).
-- لا يوجد أي حقل "يعود بعده اللاعب" يحتاج تحديثًا - أي مباراة أخرى غير هذه
-- تقرأ ببساطة players.original_team_id لأنه لا يوجد صف match_loans لها.
-- هذا يجعل "العودة التلقائية بعد المباراة" خالية من أي منطق كتابة إضافي.

create type auction_status as enum ('scheduled', 'open', 'closing', 'closed', 'cancelled');

create table auctions (
  id                   uuid primary key default gen_random_uuid(),
  match_id             uuid not null references matches(id) on delete cascade,
  player_id            uuid not null references players(id),
  status               auction_status not null default 'scheduled',
  start_bid            integer not null default 50,
  bid_increment        integer not null default 25,
  duration_seconds     integer not null default 60,
  anti_snipe_seconds   integer not null default 15,
  extension_seconds    integer not null default 15,
  is_secret            boolean not null default false,
  opens_at             timestamptz,
  closes_at            timestamptz,
  current_high_bid_id  uuid,
  bid_count            integer not null default 0,
  current_amount       integer,
  winner_team_id       uuid references teams(id),
  created_at           timestamptz not null default now(),
  unique (match_id, player_id)
);

create table bids (
  id            uuid primary key default gen_random_uuid(),
  auction_id    uuid not null references auctions(id) on delete cascade,
  team_id       uuid not null references teams(id),
  amount        integer not null check (amount > 0),
  created_at    timestamptz not null default now()
);
create index idx_bids_auction on bids(auction_id, amount desc, created_at asc);

alter table auctions add constraint fk_current_high_bid
  foreign key (current_high_bid_id) references bids(id);

create table match_loans (
  id                  uuid primary key default gen_random_uuid(),
  match_id            uuid not null references matches(id) on delete cascade,
  player_id           uuid not null references players(id),
  original_team_id    uuid not null references teams(id),
  borrowing_team_id   uuid not null references teams(id),
  auction_id          uuid unique references auctions(id),
  winning_bid_amount  integer not null,
  fee_settled         boolean not null default false,
  created_at          timestamptz not null default now(),
  constraint chk_loan_teams_differ check (original_team_id <> borrowing_team_id),
  unique (match_id, player_id)
);

-- مشاهدة مقنّعة لهوية المزايد أثناء المزاد السري المفتوح (للاستخدام من العميل بدل bids مباشرة)
create view bids_public as
  select
    b.id, b.auction_id, b.amount, b.created_at,
    case when a.is_secret and a.status = 'open' and not is_admin()
         then null else b.team_id end as team_id
  from bids b
  join auctions a on a.id = b.auction_id;

alter table auctions enable row level security;
alter table bids enable row level security;
alter table match_loans enable row level security;
