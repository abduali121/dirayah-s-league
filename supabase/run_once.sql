-- دوري دراية: الأدوار والفرق
-- ==========================

create extension if not exists pgcrypto;

create type user_role as enum ('super_admin', 'team_captain');

create table teams (
  id               uuid primary key default gen_random_uuid(),
  name             text not null unique,
  logo_url         text,
  primary_color    text not null default '#1a3a5c',
  secondary_color  text not null default '#b8952a',
  balance_daraya   integer not null default 1000,
  created_at       timestamptz not null default now()
);
alter table teams add constraint chk_balance_nonnegative check (balance_daraya >= 0);

create table profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  role            user_role not null default 'team_captain',
  team_id         uuid references teams(id),
  display_name    text not null,
  created_at      timestamptz not null default now(),
  constraint chk_role_team_consistency check (
    (role = 'team_captain' and team_id is not null) or
    (role = 'super_admin' and team_id is null)
  )
);
create unique index uq_profiles_one_captain_per_team
  on profiles(team_id) where role = 'team_captain';

-- دوال مساعدة تُستخدم داخل سياسات RLS ودوال RPC
create or replace function is_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from profiles where id = auth.uid() and role = 'super_admin'
  );
$$;

create or replace function my_team_id()
returns uuid
language sql stable security definer set search_path = public as $$
  select team_id from profiles where id = auth.uid();
$$;

-- عند إنشاء مستخدم جديد في Supabase Auth (يُنشئه المدير من لوحة Supabase أو عبر دعوة)،
-- تُنشأ صف profile تلقائيًا اعتمادًا على بيانات وصفية (raw_user_meta_data) يمررها المدير:
-- { "role": "team_captain", "team_id": "...", "display_name": "..." }
create or replace function handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, role, team_id, display_name)
  values (
    new.id,
    coalesce((new.raw_user_meta_data->>'role')::user_role, 'team_captain'),
    nullif(new.raw_user_meta_data->>'team_id', '')::uuid,
    coalesce(new.raw_user_meta_data->>'display_name', new.email)
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

alter table teams enable row level security;
alter table profiles enable row level security;
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
-- دوري دراية: السجل المالي والترتيب والتدقيق
-- =============================================

create type ledger_reason as enum ('match_result', 'loan_fee', 'admin_adjustment', 'admin_reversal', 'season_init');

create table balance_ledger (
  id              bigint generated always as identity primary key,
  team_id         uuid not null references teams(id),
  delta           integer not null,
  balance_after   integer not null,
  reason          ledger_reason not null,
  match_id        uuid references matches(id),
  loan_id         uuid references match_loans(id),
  note            text,
  created_by      uuid references profiles(id),
  created_at      timestamptz not null default now()
);

-- ملاحظة تصميم: لا يوجد قيد UNIQUE على (match_id, team_id) لسبب match_result، عمدًا.
-- منع التكرار يتم عبر: قفل صف matches (FOR UPDATE) الذي يسلسل أي استدعاءات متزامنة،
-- والتحقق من matches.status <> 'completed' قبل أي تسوية جديدة، وmatch_loans.fee_settled
-- لرسوم الإعارة. لو استُخدم قيد UNIQUE هنا لكان يمنع إعادة التسوية الشرعية بعد
-- undo_match_result (تصحيح خطأ ثم اعتماد نتيجة صحيحة)، لأن الصفوف الأصلية تبقى
-- محفوظة دائمًا لسلامة سجل التدقيق ولا تُحذف أبدًا.
create index idx_ledger_match on balance_ledger(match_id);
create index idx_ledger_loan on balance_ledger(loan_id);

create table standings_snapshots (
  id              bigint generated always as identity primary key,
  week_id         uuid not null references weeks(id),
  team_id         uuid not null references teams(id),
  balance_daraya  integer not null,
  wins            integer not null default 0,
  losses          integer not null default 0,
  rank            integer not null,
  created_at      timestamptz not null default now(),
  unique (week_id, team_id)
);

create table audit_log (
  id            bigint generated always as identity primary key,
  actor_id      uuid references profiles(id),
  action        text not null,
  entity_table  text not null,
  entity_id     text not null,
  before_data   jsonb,
  after_data    jsonb,
  created_at    timestamptz not null default now()
);
create index idx_audit_entity on audit_log(entity_table, entity_id);

alter table balance_ledger enable row level security;
alter table standings_snapshots enable row level security;
alter table audit_log enable row level security;

-- دالة مساعدة مشتركة يستدعيها كل RPC حساس لتسجيل التدقيق
create or replace function log_audit(
  p_action text, p_entity_table text, p_entity_id text,
  p_before jsonb, p_after jsonb
) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (actor_id, action, entity_table, entity_id, before_data, after_data)
  values (auth.uid(), p_action, p_entity_table, p_entity_id, p_before, p_after);
end;
$$;
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
-- دوري دراية: دوال العمليات (RPC) — كل منطق العمليات الحساسة والمالية هنا
-- =========================================================================
-- كل دالة SECURITY DEFINER (تعمل بصلاحية مالك الجدول فتتجاوز RLS تلقائيًا)
-- بعد أن تتحقق داخليًا من الصلاحية والشروط بنفسها. أي استدعاء من العميل
-- (عبر supabase.rpc(...)) يمر إجباريًا من هنا لأن RLS يمنع أي كتابة مباشرة.
--
-- افتراض معماري مهم بخصوص المزايدة (لم يُذكر صراحة في المواصفات، ويحتاج
-- تأكيد المستخدم): يمكن لأي فريق أن يكون صاحب اللاعب المطروح للمزاد (حتى لو
-- كان من الفريقين المتقابلين)، لكن المزايدة على لاعب في مزاد مباراة معينة
-- مقصورة على الفريقين المشاركين في تلك المباراة فقط (team_a_id / team_b_id)
-- لأن اللاعب المُعار يمثل أحدهما في تلك المباراة تحديدًا.

-- ============ فرق ولاعبون (إدارة) ============

create or replace function create_team(
  p_name text, p_logo_url text default null,
  p_primary_color text default '#1a3a5c', p_secondary_color text default '#b8952a'
) returns teams
language plpgsql security definer set search_path = public as $$
declare v_team teams;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  insert into teams (name, logo_url, primary_color, secondary_color)
  values (p_name, p_logo_url, p_primary_color, p_secondary_color)
  returning * into v_team;
  perform log_audit('create_team', 'teams', v_team.id::text, null, to_jsonb(v_team));
  return v_team;
end; $$;

create or replace function update_team(
  p_team_id uuid, p_name text, p_logo_url text,
  p_primary_color text, p_secondary_color text
) returns teams
language plpgsql security definer set search_path = public as $$
declare v_before teams; v_after teams;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from teams where id = p_team_id;
  if not found then raise exception 'team not found'; end if;
  update teams set name = p_name, logo_url = p_logo_url,
    primary_color = p_primary_color, secondary_color = p_secondary_color
  where id = p_team_id
  returning * into v_after;
  perform log_audit('update_team', 'teams', p_team_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

create or replace function create_player(
  p_full_name text, p_original_team_id uuid,
  p_position text default null, p_photo_url text default null
) returns players
language plpgsql security definer set search_path = public as $$
declare v_player players;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  insert into players (full_name, original_team_id, position, photo_url)
  values (p_full_name, p_original_team_id, p_position, p_photo_url)
  returning * into v_player;
  perform log_audit('create_player', 'players', v_player.id::text, null, to_jsonb(v_player));
  return v_player;
end; $$;

create or replace function update_player(
  p_player_id uuid, p_full_name text, p_position text,
  p_photo_url text, p_is_active boolean
) returns players
language plpgsql security definer set search_path = public as $$
declare v_before players; v_after players;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from players where id = p_player_id;
  if not found then raise exception 'player not found'; end if;
  -- original_team_id ثابت عمدًا: لا يظهر في معاملات هذه الدالة، لا يمكن تغييره أبدًا بعد الإنشاء
  update players set full_name = p_full_name, position = p_position,
    photo_url = p_photo_url, is_active = p_is_active
  where id = p_player_id
  returning * into v_after;
  perform log_audit('update_player', 'players', p_player_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

-- ============ المباريات ============

create or replace function create_match(
  p_week_id uuid, p_team_a_id uuid, p_team_b_id uuid, p_stake_daraya integer
) returns matches
language plpgsql security definer set search_path = public as $$
declare v_match matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_team_a_id = p_team_b_id then raise exception 'team cannot play itself'; end if;
  insert into matches (week_id, team_a_id, team_b_id, stake_daraya)
  values (p_week_id, p_team_a_id, p_team_b_id, p_stake_daraya)
  returning * into v_match;
  perform log_audit('create_match', 'matches', v_match.id::text, null, to_jsonb(v_match));
  return v_match;
end; $$;

create or replace function edit_match(
  p_match_id uuid, p_team_a_id uuid, p_team_b_id uuid, p_stake_daraya integer
) returns matches
language plpgsql security definer set search_path = public as $$
declare v_before matches; v_after matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from matches where id = p_match_id for update;
  if not found then raise exception 'match not found'; end if;
  if v_before.status <> 'scheduled' then
    raise exception 'cannot edit a match that is not scheduled (status=%)', v_before.status;
  end if;
  if p_team_a_id = p_team_b_id then raise exception 'team cannot play itself'; end if;
  update matches set team_a_id = p_team_a_id, team_b_id = p_team_b_id, stake_daraya = p_stake_daraya
  where id = p_match_id
  returning * into v_after;
  perform log_audit('edit_match', 'matches', p_match_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

create or replace function add_match_event(
  p_match_id uuid, p_description text, p_event_type text default 'note', p_minute integer default null
) returns match_events
language plpgsql security definer set search_path = public as $$
declare v_event match_events;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  insert into match_events (match_id, description, event_type, minute, created_by)
  values (p_match_id, p_description, p_event_type, p_minute, auth.uid())
  returning * into v_event;
  return v_event;
end; $$;

create or replace function set_lineup(
  p_match_id uuid, p_team_id uuid, p_player_ids uuid[]
) returns setof match_lineups
language plpgsql security definer set search_path = public as $$
declare
  v_player_id uuid;
  v_eligible boolean;
begin
  if not (is_admin() or (my_team_id() = p_team_id)) then
    raise exception 'forbidden: not this team''s captain';
  end if;

  delete from match_lineups where match_id = p_match_id and team_id = p_team_id;

  foreach v_player_id in array p_player_ids loop
    select exists(
      select 1 from players where id = v_player_id and original_team_id = p_team_id
      union
      select 1 from match_loans where match_id = p_match_id and player_id = v_player_id and borrowing_team_id = p_team_id
    ) into v_eligible;

    if not v_eligible then
      raise exception 'player % is not eligible to represent team % in this match', v_player_id, p_team_id;
    end if;

    insert into match_lineups (match_id, team_id, player_id) values (p_match_id, p_team_id, v_player_id);
  end loop;

  return query select * from match_lineups where match_id = p_match_id and team_id = p_team_id;
end; $$;

-- ============ السجل المالي ============

create or replace function adjust_balance(
  p_team_id uuid, p_delta integer, p_reason text
) returns teams
language plpgsql security definer set search_path = public as $$
declare v_team teams; v_new_balance integer;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'reason is required for a manual balance adjustment';
  end if;

  select * into v_team from teams where id = p_team_id for update;
  if not found then raise exception 'team not found'; end if;

  v_new_balance := v_team.balance_daraya + p_delta;
  if v_new_balance < 0 then
    raise exception 'adjustment would make balance negative (current=%, delta=%)', v_team.balance_daraya, p_delta;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (p_team_id, p_delta, v_new_balance, 'admin_adjustment', p_reason, auth.uid());

  update teams set balance_daraya = v_new_balance where id = p_team_id returning * into v_team;

  perform log_audit('adjust_balance', 'teams', p_team_id::text,
    jsonb_build_object('balance_daraya', v_team.balance_daraya - p_delta),
    jsonb_build_object('balance_daraya', v_team.balance_daraya, 'reason', p_reason));

  return v_team;
end; $$;

-- ============ اعتماد نتيجة المباراة (القلب المالي للنظام) ============

create or replace function confirm_match_result(
  p_match_id uuid, p_winner_team_id uuid
) returns matches
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_loser_team_id uuid;
  v_team_a teams; v_team_b teams;
  v_winner teams; v_loser teams;
  v_loan record;
  v_week_number integer;
  v_rank integer;
  v_team record;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_match from matches where id = p_match_id for update;
  if not found then raise exception 'match not found'; end if;
  if v_match.status = 'completed' then raise exception 'match already completed'; end if;
  if v_match.status = 'cancelled' then raise exception 'match is cancelled'; end if;
  if p_winner_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'winner must be one of the two participating teams';
  end if;

  v_loser_team_id := case when p_winner_team_id = v_match.team_a_id then v_match.team_b_id else v_match.team_a_id end;

  -- قفل الفريقين بترتيب ثابت (بالمعرّف) لمنع تعارض الأقفال (deadlock) عند تسويات متزامنة
  select * into v_team_a from teams where id = least(v_match.team_a_id, v_match.team_b_id) for update;
  select * into v_team_b from teams where id = greatest(v_match.team_a_id, v_match.team_b_id) for update;
  v_winner := case when v_team_a.id = p_winner_team_id then v_team_a else v_team_b end;
  v_loser  := case when v_team_a.id = v_loser_team_id then v_team_a else v_team_b end;

  -- قاعدة صريحة من المستخدم: لا يجوز أن تتجاوز المداخلة رصيد أي فريق حاليًا
  if v_match.stake_daraya > v_loser.balance_daraya then
    raise exception 'stake (%) exceeds the losing team''s current balance (%) — reduce the stake before confirming',
      v_match.stake_daraya, v_loser.balance_daraya;
  end if;

  -- تطبيق المداخلة: +للفائز / -للخاسر
  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_winner.id, v_match.stake_daraya, v_winner.balance_daraya + v_match.stake_daraya, 'match_result', p_match_id, auth.uid());
  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_loser.id, -v_match.stake_daraya, v_loser.balance_daraya - v_match.stake_daraya, 'match_result', p_match_id, auth.uid());

  update teams set balance_daraya = balance_daraya + v_match.stake_daraya where id = v_winner.id;
  update teams set balance_daraya = balance_daraya - v_match.stake_daraya where id = v_loser.id;

  -- رسم الإعارة الشرطي: يُخصم من المستعير فقط إذا فاز بالمباراة، ويُضاف لصاحب اللاعب الأصلي.
  -- لاعبو الفريق الخاسر المُعارون: لا خصم عليهم إطلاقًا.
  for v_loan in
    select * from match_loans
    where match_id = p_match_id and borrowing_team_id = p_winner_team_id and not fee_settled
  loop
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, created_by)
    values (v_loan.borrowing_team_id, -v_loan.winning_bid_amount,
      (select balance_daraya from teams where id = v_loan.borrowing_team_id) - v_loan.winning_bid_amount,
      'loan_fee', p_match_id, v_loan.id, auth.uid());
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, created_by)
    values (v_loan.original_team_id, v_loan.winning_bid_amount,
      (select balance_daraya from teams where id = v_loan.original_team_id) + v_loan.winning_bid_amount,
      'loan_fee', p_match_id, v_loan.id, auth.uid());

    update teams set balance_daraya = balance_daraya - v_loan.winning_bid_amount where id = v_loan.borrowing_team_id;
    update teams set balance_daraya = balance_daraya + v_loan.winning_bid_amount where id = v_loan.original_team_id;

    update match_loans set fee_settled = true where id = v_loan.id;
  end loop;

  -- تحديث المباراة (قبل/بعد لكل فريق)
  update matches set
    status = 'completed',
    winner_team_id = p_winner_team_id,
    team_a_balance_before = v_team_a.balance_daraya,
    team_b_balance_before = v_team_b.balance_daraya,
    team_a_balance_after = (select balance_daraya from teams where id = v_team_a.id),
    team_b_balance_after = (select balance_daraya from teams where id = v_team_b.id),
    confirmed_at = now(),
    confirmed_by = auth.uid()
  where id = p_match_id
  returning * into v_match;

  -- لقطة ترتيب الأسبوع (standings snapshot)
  select week_number into v_week_number from weeks where id = v_match.week_id;

  v_rank := 0;
  for v_team in
    select t.id, t.balance_daraya,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id = t.id) as wins,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id <> t.id and t.id in (m.team_a_id, m.team_b_id)) as losses
    from teams t
    order by t.balance_daraya desc, t.name asc
  loop
    v_rank := v_rank + 1;
    insert into standings_snapshots (week_id, team_id, balance_daraya, wins, losses, rank)
    values (v_match.week_id, v_team.id, v_team.balance_daraya, v_team.wins, v_team.losses, v_rank)
    on conflict (week_id, team_id) do update
      set balance_daraya = excluded.balance_daraya, wins = excluded.wins,
          losses = excluded.losses, rank = excluded.rank;
  end loop;

  perform log_audit('confirm_match_result', 'matches', p_match_id::text,
    jsonb_build_object('status', 'scheduled'), to_jsonb(v_match));

  return v_match;
end; $$;

create or replace function undo_match_result(p_match_id uuid) returns matches
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_row record;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_match from matches where id = p_match_id for update;
  if not found then raise exception 'match not found'; end if;
  if v_match.status <> 'completed' then raise exception 'match is not completed, nothing to undo'; end if;

  -- عكس كل صفوف السجل المالي المرتبطة بهذه المباراة (تسوية + رسوم إعارة) بقيود معاكسة،
  -- دون حذف أي صف أصلي — حفاظًا على سلامة التدقيق الكاملة
  for v_row in select * from balance_ledger where match_id = p_match_id loop
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, note, created_by)
    values (v_row.team_id, -v_row.delta,
      (select balance_daraya from teams where id = v_row.team_id) - v_row.delta,
      'admin_reversal', p_match_id, v_row.loan_id, 'reversal of ledger #' || v_row.id, auth.uid());
    update teams set balance_daraya = balance_daraya - v_row.delta where id = v_row.team_id;
  end loop;

  update match_loans set fee_settled = false where match_id = p_match_id;

  update matches set
    status = 'scheduled', winner_team_id = null,
    team_a_balance_before = null, team_b_balance_before = null,
    team_a_balance_after = null, team_b_balance_after = null,
    confirmed_at = null, confirmed_by = null
  where id = p_match_id
  returning * into v_match;

  delete from standings_snapshots where week_id = v_match.week_id;

  perform log_audit('undo_match_result', 'matches', p_match_id::text, null, to_jsonb(v_match));
  return v_match;
end; $$;

-- ============ المزادات والمزايدات (الإعارة) ============

create or replace function create_auction(
  p_match_id uuid, p_player_id uuid, p_is_secret boolean default false,
  p_duration_seconds integer default 60, p_start_bid integer default 50, p_bid_increment integer default 25
) returns auctions
language plpgsql security definer set search_path = public as $$
declare v_auction auctions;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  insert into auctions (match_id, player_id, is_secret, duration_seconds, start_bid, bid_increment)
  values (p_match_id, p_player_id, p_is_secret, p_duration_seconds, p_start_bid, p_bid_increment)
  returning * into v_auction;
  perform log_audit('create_auction', 'auctions', v_auction.id::text, null, to_jsonb(v_auction));
  return v_auction;
end; $$;

create or replace function open_auction(p_auction_id uuid) returns auctions
language plpgsql security definer set search_path = public as $$
declare v_auction auctions;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_auction from auctions where id = p_auction_id for update;
  if not found then raise exception 'auction not found'; end if;
  if v_auction.status <> 'scheduled' then raise exception 'auction is not in scheduled state'; end if;

  update auctions set status = 'open', opens_at = now(),
    closes_at = now() + make_interval(secs => v_auction.duration_seconds)
  where id = p_auction_id
  returning * into v_auction;

  perform log_audit('open_auction', 'auctions', p_auction_id::text, null, to_jsonb(v_auction));
  return v_auction;
end; $$;

create or replace function place_bid(
  p_auction_id uuid, p_team_id uuid, p_amount integer
) returns bids
language plpgsql security definer set search_path = public as $$
declare
  v_auction auctions;
  v_match matches;
  v_player players;
  v_team teams;
  v_current_amount integer;
  v_expected_amount integer;
  v_bid bids;
begin
  select * into v_auction from auctions where id = p_auction_id for update;
  if not found then raise exception 'auction not found'; end if;

  if not (my_team_id() = p_team_id) then
    raise exception 'forbidden: you can only bid on behalf of your own team';
  end if;

  if v_auction.status <> 'open' then raise exception 'auction is not open'; end if;
  if now() >= v_auction.closes_at then raise exception 'auction has already closed'; end if;

  select * into v_match from matches where id = v_auction.match_id;
  if p_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'only the two teams playing this match may bid on this loan';
  end if;

  select * into v_player from players where id = v_auction.player_id;
  if p_team_id = v_player.original_team_id then
    raise exception 'a team cannot bid on its own player';
  end if;

  select amount into v_current_amount from bids where id = v_auction.current_high_bid_id;
  v_expected_amount := coalesce(v_current_amount + v_auction.bid_increment, v_auction.start_bid);
  if p_amount <> v_expected_amount then
    raise exception 'bid must be exactly % (start=%, increment=%)', v_expected_amount, v_auction.start_bid, v_auction.bid_increment;
  end if;

  select * into v_team from teams where id = p_team_id for update;
  if p_amount > v_team.balance_daraya then
    raise exception 'bid (%) exceeds your team''s current balance (%)', p_amount, v_team.balance_daraya;
  end if;

  insert into bids (auction_id, team_id, amount) values (p_auction_id, p_team_id, p_amount)
  returning * into v_bid;

  update auctions set
    current_high_bid_id = v_bid.id,
    bid_count = bid_count + 1,
    current_amount = p_amount,
    closes_at = case
      when extract(epoch from (closes_at - now())) <= anti_snipe_seconds
      then closes_at + make_interval(secs => extension_seconds)
      else closes_at
    end
  where id = p_auction_id;

  perform log_audit('place_bid', 'bids', v_bid.id::text, null, to_jsonb(v_bid));
  return v_bid;
end; $$;

create or replace function close_auction(p_auction_id uuid) returns match_loans
language plpgsql security definer set search_path = public as $$
declare
  v_auction auctions;
  v_winning_bid record;
  v_player players;
  v_loan match_loans;
begin
  select * into v_auction from auctions where id = p_auction_id for update;
  if not found then raise exception 'auction not found'; end if;

  if v_auction.status = 'closed' then
    return (select * from match_loans where auction_id = p_auction_id);
  end if;
  if v_auction.status <> 'open' then raise exception 'auction is not open'; end if;
  if not (is_admin() or now() >= v_auction.closes_at) then
    raise exception 'auction has not closed yet';
  end if;

  select * into v_player from players where id = v_auction.player_id;

  -- أعلى مزايدة صالحة (يعيد التحقق من الرصيد وقت الإغلاق احتياطًا لأي تعديل رصيد لاحق)
  select b.* into v_winning_bid
  from bids b
  join teams t on t.id = b.team_id
  where b.auction_id = p_auction_id and b.amount <= t.balance_daraya
  order by b.amount desc, b.created_at asc
  limit 1;

  if not found then
    update auctions set status = 'closed', winner_team_id = null where id = p_auction_id;
    perform log_audit('close_auction', 'auctions', p_auction_id::text, null, jsonb_build_object('winner', null));
    return null;
  end if;

  insert into match_loans (match_id, player_id, original_team_id, borrowing_team_id, auction_id, winning_bid_amount)
  values (v_auction.match_id, v_auction.player_id, v_player.original_team_id, v_winning_bid.team_id, p_auction_id, v_winning_bid.amount)
  returning * into v_loan;

  update auctions set status = 'closed', winner_team_id = v_winning_bid.team_id where id = p_auction_id;

  perform log_audit('close_auction', 'auctions', p_auction_id::text, null, to_jsonb(v_loan));
  return v_loan;
end; $$;

-- ============ صلاحيات التنفيذ ============
-- منح الإذن بتنفيذ هذه الدوال لأي مستخدم مسجّل دخول؛ كل دالة تتحقق من
-- الدور/الملكية بنفسها في أول سطر (is_admin() أو my_team_id()).
grant execute on all functions in schema public to authenticated;

-- استثناءان: لا يجوز لأي مستخدم استدعاءهما مباشرة عبر rpc() —
-- log_audit قد تُستخدم لتزوير صفوف تدقيق وهمية، وhandle_new_user دالة Trigger داخلية فقط.
-- الدوال الأخرى (SECURITY DEFINER) تظل قادرة على استدعائهما داخليًا لأنها تُنفَّذ بصلاحية
-- المالك (postgres) وليس بصلاحية المستخدم المتصل.
revoke execute on function log_audit(text, text, text, jsonb, jsonb) from authenticated;
revoke execute on function handle_new_user() from authenticated;
-- دوري دراية: زرع الأسابيع الخمسة عشر الثابتة (بنية الدوري، وليست بيانات قابلة للحذف)
-- =====================================================================================

insert into weeks (week_number)
select generate_series(1, 15)
on conflict (week_number) do nothing;
-- إصلاح: نافذة "Create user" في لوحة Supabase لا تسمح بتحديد role/team_id عند الإنشاء،
-- فيُنشأ الحساب بالقيم الافتراضية (team_captain بدون team_id) مما يخالف القيد الصارم
-- السابق ويفشل إنشاء الحساب بالكامل ("Database error creating new user").
-- الحل: السماح بحساب "كابتن بلا فريق مؤقتًا" (يُعيَّن فريقه لاحقًا)، مع منع الحالة
-- غير المنطقية الوحيدة فعليًا: مدير (super_admin) مرتبط بفريق.

alter table profiles drop constraint chk_role_team_consistency;
alter table profiles add constraint chk_admin_has_no_team check (
  role <> 'super_admin' or team_id is null
);

-- دالة لتعيين الدور/الفريق لحساب موجود (تُستخدم لترقية أول مدير، ولاحقًا لتعيين كباتن الفرق)
create or replace function assign_profile_role(
  p_profile_id uuid, p_role user_role, p_team_id uuid default null, p_display_name text default null
) returns profiles
language plpgsql security definer set search_path = public as $$
declare v_before profiles; v_after profiles;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from profiles where id = p_profile_id;
  if not found then raise exception 'profile not found'; end if;

  update profiles set
    role = p_role,
    team_id = case when p_role = 'super_admin' then null else p_team_id end,
    display_name = coalesce(p_display_name, display_name)
  where id = p_profile_id
  returning * into v_after;

  perform log_audit('assign_profile_role', 'profiles', p_profile_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

grant execute on function assign_profile_role(uuid, user_role, uuid, text) to authenticated;
-- دوري دراية: تسجيل ذاتي برقم الجوال + مشاهدة عامة بدون تسجيل دخول
-- ========================================================================

-- 1) رقم جوال الكابتن يُسجَّل مسبقًا على الفريق من لوحة الإدارة، ليُستخدم
--    لمطابقة الحساب تلقائيًا بفريقه الصحيح وقت التسجيل الذاتي.
alter table teams add column captain_phone text unique;

create or replace function create_team(
  p_name text, p_logo_url text default null,
  p_primary_color text default '#1a3a5c', p_secondary_color text default '#b8952a',
  p_captain_phone text default null
) returns teams
language plpgsql security definer set search_path = public as $$
declare v_team teams;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  insert into teams (name, logo_url, primary_color, secondary_color, captain_phone)
  values (p_name, p_logo_url, p_primary_color, p_secondary_color, nullif(p_captain_phone, ''))
  returning * into v_team;
  perform log_audit('create_team', 'teams', v_team.id::text, null, to_jsonb(v_team));
  return v_team;
end; $$;

create or replace function update_team(
  p_team_id uuid, p_name text, p_logo_url text,
  p_primary_color text, p_secondary_color text, p_captain_phone text default null
) returns teams
language plpgsql security definer set search_path = public as $$
declare v_before teams; v_after teams;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from teams where id = p_team_id;
  if not found then raise exception 'team not found'; end if;
  update teams set name = p_name, logo_url = p_logo_url,
    primary_color = p_primary_color, secondary_color = p_secondary_color,
    captain_phone = nullif(p_captain_phone, '')
  where id = p_team_id
  returning * into v_after;
  perform log_audit('update_team', 'teams', p_team_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

-- 2) إصلاح جذري لدالة إنشاء الحساب: لا تثق أبدًا ببيانات الدور القادمة من العميل
--    (تسجيل ذاتي مفتوح الآن، ولازم منع أي طرف من ادّعاء "super_admin" لنفسه).
--    الدور دائمًا "team_captain" افتراضيًا، والفريق يُشتق فقط من مطابقة رقم الجوال
--    (المستخرج من البريد الوهمي المحلي@dawri.local) مع ما سجّله المدير مسبقًا على الفريق.
create or replace function handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_phone text;
  v_team_id uuid;
begin
  if new.email like '%@dawri.local' then
    v_phone := split_part(new.email, '@', 1);
    select id into v_team_id from teams where captain_phone = v_phone;
  end if;

  insert into profiles (id, role, team_id, display_name)
  values (
    new.id,
    'team_captain',
    v_team_id,
    coalesce(new.raw_user_meta_data->>'display_name', new.email)
  );
  return new;
end;
$$;

-- 3) مشاهدة عامة بدون تسجيل دخول: الجداول اللازمة لعرض الترتيب ومباراة الأسبوع
--    تصير مقروءة لأي زائر (anon)، أما الكتابة فتبقى محصورة كما هي عبر RPC فقط.
alter policy sel_teams on teams to authenticated, anon;
alter policy sel_players on players to authenticated, anon;
alter policy sel_weeks on weeks to authenticated, anon;
alter policy sel_matches on matches to authenticated, anon;
alter policy sel_match_events on match_events to authenticated, anon;
alter policy sel_match_lineups on match_lineups to authenticated, anon;
alter policy sel_auctions on auctions to authenticated, anon;
alter policy sel_match_loans on match_loans to authenticated, anon;
alter policy sel_standings on standings_snapshots to authenticated, anon;
alter policy sel_bids on bids to authenticated, anon;

grant select on teams, players, weeks, matches, match_events, match_lineups,
  auctions, match_loans, standings_snapshots, bids, bids_public to anon;
-- دوري دراية: استبدال نظام المزايدة التنافسية بنظام "تسجيل صفقة" بسيط
-- =========================================================================
-- التفاوض الفعلي يصير خارج التطبيق (واتساب/مباشرة). الكابتن بعد ما يتفق مع
-- لاعب يسجّل الصفقة هنا (لاعب + مبلغ). يظهر للجميع "من أخذ اللاعب"، لكن
-- المبلغ يبقى مخفيًا إلا عن: المدير، الفريق المستعير، والفريق الأصلي صاحب
-- اللاعب. لو أكثر من فريق سجّل نفس اللاعب لنفس المباراة، المدير يقرر
-- أيهما يُعتمد (بدل معيار "الأسبقية" الآلي).

-- إزالة بنية المزايدة القديمة غير المستخدمة بالكامل
drop function if exists place_bid(uuid, uuid, integer);
drop function if exists open_auction(uuid);
drop function if exists close_auction(uuid);
drop function if exists create_auction(uuid, uuid, boolean, integer, integer, integer);
drop view if exists bids_public;
alter table match_loans drop constraint if exists match_loans_auction_id_fkey;
alter table match_loans drop column if exists auction_id;
drop table if exists auctions cascade;
drop table if exists bids cascade;
drop type if exists auction_status;

-- ============ طلبات/صفقات الإعارة ============
create type loan_claim_status as enum ('pending', 'approved', 'rejected');

create table loan_claims (
  id                 uuid primary key default gen_random_uuid(),
  match_id           uuid not null references matches(id) on delete cascade,
  player_id          uuid not null references players(id),
  claiming_team_id   uuid not null references teams(id),
  original_team_id   uuid not null references teams(id),
  amount             integer not null check (amount > 0),
  status             loan_claim_status not null default 'pending',
  note               text,
  reviewed_by        uuid references profiles(id),
  reviewed_at        timestamptz,
  created_at         timestamptz not null default now(),
  constraint chk_claim_teams_differ check (claiming_team_id <> original_team_id)
);
create index idx_loan_claims_match on loan_claims(match_id);

-- صف واحد "معتمد" فقط لكل (مباراة، لاعب) — يمنع اعتماد نفس اللاعب مرتين لنفس المباراة
create unique index uq_loan_claims_approved on loan_claims(match_id, player_id) where status = 'approved';

alter table match_loans add column claim_id uuid references loan_claims(id);

alter table loan_claims enable row level security;

-- مشاهدة عامة تُخفي المبلغ إلا عن المدير والفريقين المعنيين مباشرة بالصفقة
create view loan_claims_public as
  select
    lc.id, lc.match_id, lc.player_id, lc.claiming_team_id, lc.original_team_id,
    lc.status, lc.note, lc.created_at,
    case when is_admin() or my_team_id() = lc.claiming_team_id or my_team_id() = lc.original_team_id
         then lc.amount else null end as amount
  from loan_claims lc;

grant select on loan_claims_public to authenticated, anon;

-- RLS على الجدول الخام: RLS يمنع/يسمح بصفوف كاملة فقط (لا يقدر يُخفي عمودًا واحدًا)،
-- فلضمان إخفاء amount فعليًا نقصر قراءة الجدول الخام على المعنيين مباشرة فقط؛
-- أي طرف آخر يُحرم من الجدول الخام تمامًا ويُجبر على loan_claims_public
-- (التي تتجاوز RLS بصلاحية مالكها وتُخفي amount عمليًا بمنطق CASE بدل الاعتماد على الصفوف).
create policy sel_loan_claims on loan_claims for select to authenticated using (
  is_admin() or my_team_id() = claiming_team_id or my_team_id() = original_team_id
);

-- ============ دوال العمليات ============

create or replace function claim_player_loan(
  p_match_id uuid, p_player_id uuid, p_amount integer, p_note text default null
) returns loan_claims
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_player players;
  v_team_id uuid;
  v_existing loan_claims;
  v_claim loan_claims;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;

  select * into v_match from matches where id = p_match_id;
  if not found then raise exception 'match not found'; end if;
  if v_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'only the two teams playing this match may sign a loan for it';
  end if;

  select * into v_player from players where id = p_player_id;
  if v_team_id = v_player.original_team_id then
    raise exception 'a team cannot sign its own player';
  end if;

  select * into v_existing from loan_claims
    where match_id = p_match_id and player_id = p_player_id and status = 'approved';
  if found then raise exception 'this player is already signed by another team for this match'; end if;

  insert into loan_claims (match_id, player_id, claiming_team_id, original_team_id, amount, note)
  values (p_match_id, p_player_id, v_team_id, v_player.original_team_id, p_amount, p_note)
  returning * into v_claim;

  perform log_audit('claim_player_loan', 'loan_claims', v_claim.id::text, null, to_jsonb(v_claim));
  return v_claim;
end; $$;

create or replace function approve_loan_claim(p_claim_id uuid) returns match_loans
language plpgsql security definer set search_path = public as $$
declare
  v_claim loan_claims;
  v_loan match_loans;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_claim from loan_claims where id = p_claim_id for update;
  if not found then raise exception 'claim not found'; end if;
  if v_claim.status <> 'pending' then raise exception 'claim is not pending'; end if;

  -- يرفض تلقائيًا أي طلب آخر منافس على نفس اللاعب لنفس المباراة
  update loan_claims set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
  where match_id = v_claim.match_id and player_id = v_claim.player_id
    and id <> p_claim_id and status = 'pending';

  update loan_claims set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_claim_id;

  insert into match_loans (match_id, player_id, original_team_id, borrowing_team_id, claim_id, winning_bid_amount)
  values (v_claim.match_id, v_claim.player_id, v_claim.original_team_id, v_claim.claiming_team_id, v_claim.id, v_claim.amount)
  returning * into v_loan;

  perform log_audit('approve_loan_claim', 'loan_claims', p_claim_id::text, null, to_jsonb(v_claim));
  return v_loan;
end; $$;

create or replace function reject_loan_claim(p_claim_id uuid) returns loan_claims
language plpgsql security definer set search_path = public as $$
declare v_claim loan_claims;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  update loan_claims set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_claim_id and status = 'pending'
  returning * into v_claim;
  if not found then raise exception 'claim not found or not pending'; end if;
  perform log_audit('reject_loan_claim', 'loan_claims', p_claim_id::text, null, to_jsonb(v_claim));
  return v_claim;
end; $$;

grant execute on function claim_player_loan(uuid, uuid, integer, text) to authenticated;
grant execute on function approve_loan_claim(uuid) to authenticated;
grant execute on function reject_loan_claim(uuid) to authenticated;
-- دوري دراية: مداخلة مستقلة لكل فريق (بدل رقم مشترك واحد)
-- ============================================================
-- كل فريق يدخل المباراة برقمه الخاص. الفائز يكسب رقمه هو، والخاسر يخسر رقمه هو
-- (مو رقم الطرف الآخر) — يعني المجموع الكلي للدراية بالدوري يتغيّر صعودًا أو
-- نزولاً حسب مين فاز، وليس بالضرورة ثابتًا.

alter table matches add column team_a_stake integer;
alter table matches add column team_b_stake integer;
update matches set team_a_stake = stake_daraya, team_b_stake = stake_daraya;
alter table matches alter column team_a_stake set not null;
alter table matches alter column team_b_stake set not null;
alter table matches add constraint chk_team_a_stake_positive check (team_a_stake > 0);
alter table matches add constraint chk_team_b_stake_positive check (team_b_stake > 0);
alter table matches drop column stake_daraya;

create or replace function create_match(
  p_week_id uuid, p_team_a_id uuid, p_team_b_id uuid, p_team_a_stake integer, p_team_b_stake integer
) returns matches
language plpgsql security definer set search_path = public as $$
declare v_match matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_team_a_id = p_team_b_id then raise exception 'team cannot play itself'; end if;
  insert into matches (week_id, team_a_id, team_b_id, team_a_stake, team_b_stake)
  values (p_week_id, p_team_a_id, p_team_b_id, p_team_a_stake, p_team_b_stake)
  returning * into v_match;
  perform log_audit('create_match', 'matches', v_match.id::text, null, to_jsonb(v_match));
  return v_match;
end; $$;

create or replace function edit_match(
  p_match_id uuid, p_team_a_id uuid, p_team_b_id uuid, p_team_a_stake integer, p_team_b_stake integer
) returns matches
language plpgsql security definer set search_path = public as $$
declare v_before matches; v_after matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from matches where id = p_match_id for update;
  if not found then raise exception 'match not found'; end if;
  if v_before.status <> 'scheduled' then
    raise exception 'cannot edit a match that is not scheduled (status=%)', v_before.status;
  end if;
  if p_team_a_id = p_team_b_id then raise exception 'team cannot play itself'; end if;
  update matches set team_a_id = p_team_a_id, team_b_id = p_team_b_id,
    team_a_stake = p_team_a_stake, team_b_stake = p_team_b_stake
  where id = p_match_id
  returning * into v_after;
  perform log_audit('edit_match', 'matches', p_match_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

create or replace function confirm_match_result(
  p_match_id uuid, p_winner_team_id uuid
) returns matches
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_loser_team_id uuid;
  v_team_a teams; v_team_b teams;
  v_winner teams; v_loser teams;
  v_winner_stake integer; v_loser_stake integer;
  v_loan record;
  v_week_number integer;
  v_rank integer;
  v_team record;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_match from matches where id = p_match_id for update;
  if not found then raise exception 'match not found'; end if;
  if v_match.status = 'completed' then raise exception 'match already completed'; end if;
  if v_match.status = 'cancelled' then raise exception 'match is cancelled'; end if;
  if p_winner_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'winner must be one of the two participating teams';
  end if;

  v_loser_team_id := case when p_winner_team_id = v_match.team_a_id then v_match.team_b_id else v_match.team_a_id end;

  select * into v_team_a from teams where id = least(v_match.team_a_id, v_match.team_b_id) for update;
  select * into v_team_b from teams where id = greatest(v_match.team_a_id, v_match.team_b_id) for update;
  v_winner := case when v_team_a.id = p_winner_team_id then v_team_a else v_team_b end;
  v_loser  := case when v_team_a.id = v_loser_team_id then v_team_a else v_team_b end;

  v_winner_stake := case when p_winner_team_id = v_match.team_a_id then v_match.team_a_stake else v_match.team_b_stake end;
  v_loser_stake  := case when v_loser_team_id  = v_match.team_a_id then v_match.team_a_stake else v_match.team_b_stake end;

  -- كل فريق يخسر رقمه المستقل هو فقط — القاعدة: ما يجوز يهبط رصيده تحت الصفر
  if v_loser_stake > v_loser.balance_daraya then
    raise exception 'the losing team''s own stake (%) exceeds its current balance (%)', v_loser_stake, v_loser.balance_daraya;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_winner.id, v_winner_stake, v_winner.balance_daraya + v_winner_stake, 'match_result', p_match_id, auth.uid());
  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_loser.id, -v_loser_stake, v_loser.balance_daraya - v_loser_stake, 'match_result', p_match_id, auth.uid());

  update teams set balance_daraya = balance_daraya + v_winner_stake where id = v_winner.id;
  update teams set balance_daraya = balance_daraya - v_loser_stake where id = v_loser.id;

  for v_loan in
    select * from match_loans
    where match_id = p_match_id and borrowing_team_id = p_winner_team_id and not fee_settled
  loop
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, created_by)
    values (v_loan.borrowing_team_id, -v_loan.winning_bid_amount,
      (select balance_daraya from teams where id = v_loan.borrowing_team_id) - v_loan.winning_bid_amount,
      'loan_fee', p_match_id, v_loan.id, auth.uid());
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, created_by)
    values (v_loan.original_team_id, v_loan.winning_bid_amount,
      (select balance_daraya from teams where id = v_loan.original_team_id) + v_loan.winning_bid_amount,
      'loan_fee', p_match_id, v_loan.id, auth.uid());

    update teams set balance_daraya = balance_daraya - v_loan.winning_bid_amount where id = v_loan.borrowing_team_id;
    update teams set balance_daraya = balance_daraya + v_loan.winning_bid_amount where id = v_loan.original_team_id;

    update match_loans set fee_settled = true where id = v_loan.id;
  end loop;

  update matches set
    status = 'completed',
    winner_team_id = p_winner_team_id,
    team_a_balance_before = v_team_a.balance_daraya,
    team_b_balance_before = v_team_b.balance_daraya,
    team_a_balance_after = (select balance_daraya from teams where id = v_team_a.id),
    team_b_balance_after = (select balance_daraya from teams where id = v_team_b.id),
    confirmed_at = now(),
    confirmed_by = auth.uid()
  where id = p_match_id
  returning * into v_match;

  select week_number into v_week_number from weeks where id = v_match.week_id;

  v_rank := 0;
  for v_team in
    select t.id, t.balance_daraya,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id = t.id) as wins,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id <> t.id and t.id in (m.team_a_id, m.team_b_id)) as losses
    from teams t
    order by t.balance_daraya desc, t.name asc
  loop
    v_rank := v_rank + 1;
    insert into standings_snapshots (week_id, team_id, balance_daraya, wins, losses, rank)
    values (v_match.week_id, v_team.id, v_team.balance_daraya, v_team.wins, v_team.losses, v_rank)
    on conflict (week_id, team_id) do update
      set balance_daraya = excluded.balance_daraya, wins = excluded.wins,
          losses = excluded.losses, rank = excluded.rank;
  end loop;

  perform log_audit('confirm_match_result', 'matches', p_match_id::text,
    jsonb_build_object('status', 'scheduled'), to_jsonb(v_match));

  return v_match;
end; $$;
