-- دوري وثاق: الأدوار والفرق
-- ==========================

create extension if not exists pgcrypto;

create type user_role as enum ('super_admin', 'team_captain');

create table teams (
  id               uuid primary key default gen_random_uuid(),
  name             text not null unique,
  logo_url         text,
  primary_color    text not null default '#1a3a5c',
  secondary_color  text not null default '#b8952a',
  balance_wathaq   integer not null default 1000,
  created_at       timestamptz not null default now()
);
alter table teams add constraint chk_balance_nonnegative check (balance_wathaq >= 0);

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

-- دوري وثاق: اللاعبون
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

-- دوري وثاق: الأسابيع والمباريات
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
  stake_wathaq           integer not null check (stake_wathaq > 0),
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

-- دوري وثاق: المزادات والمزايدات والإعارات
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

-- دوري وثاق: السجل المالي والترتيب والتدقيق
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
  balance_wathaq  integer not null,
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

-- دوري وثاق: سياسات الأمان (RLS)
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

-- دوري وثاق: دوال العمليات (RPC) — كل منطق العمليات الحساسة والمالية هنا
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
  p_week_id uuid, p_team_a_id uuid, p_team_b_id uuid, p_stake_wathaq integer
) returns matches
language plpgsql security definer set search_path = public as $$
declare v_match matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_team_a_id = p_team_b_id then raise exception 'team cannot play itself'; end if;
  insert into matches (week_id, team_a_id, team_b_id, stake_wathaq)
  values (p_week_id, p_team_a_id, p_team_b_id, p_stake_wathaq)
  returning * into v_match;
  perform log_audit('create_match', 'matches', v_match.id::text, null, to_jsonb(v_match));
  return v_match;
end; $$;

create or replace function edit_match(
  p_match_id uuid, p_team_a_id uuid, p_team_b_id uuid, p_stake_wathaq integer
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
  update matches set team_a_id = p_team_a_id, team_b_id = p_team_b_id, stake_wathaq = p_stake_wathaq
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

  v_new_balance := v_team.balance_wathaq + p_delta;
  if v_new_balance < 0 then
    raise exception 'adjustment would make balance negative (current=%, delta=%)', v_team.balance_wathaq, p_delta;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (p_team_id, p_delta, v_new_balance, 'admin_adjustment', p_reason, auth.uid());

  update teams set balance_wathaq = v_new_balance where id = p_team_id returning * into v_team;

  perform log_audit('adjust_balance', 'teams', p_team_id::text,
    jsonb_build_object('balance_wathaq', v_team.balance_wathaq - p_delta),
    jsonb_build_object('balance_wathaq', v_team.balance_wathaq, 'reason', p_reason));

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
  if v_match.stake_wathaq > v_loser.balance_wathaq then
    raise exception 'stake (%) exceeds the losing team''s current balance (%) — reduce the stake before confirming',
      v_match.stake_wathaq, v_loser.balance_wathaq;
  end if;

  -- تطبيق المداخلة: +للفائز / -للخاسر
  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_winner.id, v_match.stake_wathaq, v_winner.balance_wathaq + v_match.stake_wathaq, 'match_result', p_match_id, auth.uid());
  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_loser.id, -v_match.stake_wathaq, v_loser.balance_wathaq - v_match.stake_wathaq, 'match_result', p_match_id, auth.uid());

  update teams set balance_wathaq = balance_wathaq + v_match.stake_wathaq where id = v_winner.id;
  update teams set balance_wathaq = balance_wathaq - v_match.stake_wathaq where id = v_loser.id;

  -- رسم الإعارة الشرطي: يُخصم من المستعير فقط إذا فاز بالمباراة، ويُضاف لصاحب اللاعب الأصلي.
  -- لاعبو الفريق الخاسر المُعارون: لا خصم عليهم إطلاقًا.
  for v_loan in
    select * from match_loans
    where match_id = p_match_id and borrowing_team_id = p_winner_team_id and not fee_settled
  loop
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, created_by)
    values (v_loan.borrowing_team_id, -v_loan.winning_bid_amount,
      (select balance_wathaq from teams where id = v_loan.borrowing_team_id) - v_loan.winning_bid_amount,
      'loan_fee', p_match_id, v_loan.id, auth.uid());
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, created_by)
    values (v_loan.original_team_id, v_loan.winning_bid_amount,
      (select balance_wathaq from teams where id = v_loan.original_team_id) + v_loan.winning_bid_amount,
      'loan_fee', p_match_id, v_loan.id, auth.uid());

    update teams set balance_wathaq = balance_wathaq - v_loan.winning_bid_amount where id = v_loan.borrowing_team_id;
    update teams set balance_wathaq = balance_wathaq + v_loan.winning_bid_amount where id = v_loan.original_team_id;

    update match_loans set fee_settled = true where id = v_loan.id;
  end loop;

  -- تحديث المباراة (قبل/بعد لكل فريق)
  update matches set
    status = 'completed',
    winner_team_id = p_winner_team_id,
    team_a_balance_before = v_team_a.balance_wathaq,
    team_b_balance_before = v_team_b.balance_wathaq,
    team_a_balance_after = (select balance_wathaq from teams where id = v_team_a.id),
    team_b_balance_after = (select balance_wathaq from teams where id = v_team_b.id),
    confirmed_at = now(),
    confirmed_by = auth.uid()
  where id = p_match_id
  returning * into v_match;

  -- لقطة ترتيب الأسبوع (standings snapshot)
  select week_number into v_week_number from weeks where id = v_match.week_id;

  v_rank := 0;
  for v_team in
    select t.id, t.balance_wathaq,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id = t.id) as wins,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id <> t.id and t.id in (m.team_a_id, m.team_b_id)) as losses
    from teams t
    order by t.balance_wathaq desc, t.name asc
  loop
    v_rank := v_rank + 1;
    insert into standings_snapshots (week_id, team_id, balance_wathaq, wins, losses, rank)
    values (v_match.week_id, v_team.id, v_team.balance_wathaq, v_team.wins, v_team.losses, v_rank)
    on conflict (week_id, team_id) do update
      set balance_wathaq = excluded.balance_wathaq, wins = excluded.wins,
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
      (select balance_wathaq from teams where id = v_row.team_id) - v_row.delta,
      'admin_reversal', p_match_id, v_row.loan_id, 'reversal of ledger #' || v_row.id, auth.uid());
    update teams set balance_wathaq = balance_wathaq - v_row.delta where id = v_row.team_id;
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
  if p_amount > v_team.balance_wathaq then
    raise exception 'bid (%) exceeds your team''s current balance (%)', p_amount, v_team.balance_wathaq;
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
  where b.auction_id = p_auction_id and b.amount <= t.balance_wathaq
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

-- دوري وثاق: زرع الأسابيع الخمسة عشر الثابتة (بنية الدوري، وليست بيانات قابلة للحذف)
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

-- دوري وثاق: تسجيل ذاتي برقم الجوال + مشاهدة عامة بدون تسجيل دخول
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
--    (المستخرج من البريد الوهمي المحلي@wathaq.local) مع ما سجّله المدير مسبقًا على الفريق.
create or replace function handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_phone text;
  v_team_id uuid;
begin
  if new.email like '%@wathaq.local' then
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

-- دوري وثاق: استبدال نظام المزايدة التنافسية بنظام "تسجيل صفقة" بسيط
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

-- دوري وثاق: مداخلة مستقلة لكل فريق (بدل رقم مشترك واحد)
-- ============================================================
-- كل فريق يدخل المباراة برقمه الخاص. الفائز يكسب رقمه هو، والخاسر يخسر رقمه هو
-- (مو رقم الطرف الآخر) — يعني المجموع الكلي للوثاق بالدوري يتغيّر صعودًا أو
-- نزولاً حسب مين فاز، وليس بالضرورة ثابتًا.

alter table matches add column team_a_stake integer;
alter table matches add column team_b_stake integer;
update matches set team_a_stake = stake_wathaq, team_b_stake = stake_wathaq;
alter table matches alter column team_a_stake set not null;
alter table matches alter column team_b_stake set not null;
alter table matches add constraint chk_team_a_stake_positive check (team_a_stake > 0);
alter table matches add constraint chk_team_b_stake_positive check (team_b_stake > 0);
alter table matches drop column stake_wathaq;

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
  if v_loser_stake > v_loser.balance_wathaq then
    raise exception 'the losing team''s own stake (%) exceeds its current balance (%)', v_loser_stake, v_loser.balance_wathaq;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_winner.id, v_winner_stake, v_winner.balance_wathaq + v_winner_stake, 'match_result', p_match_id, auth.uid());
  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_loser.id, -v_loser_stake, v_loser.balance_wathaq - v_loser_stake, 'match_result', p_match_id, auth.uid());

  update teams set balance_wathaq = balance_wathaq + v_winner_stake where id = v_winner.id;
  update teams set balance_wathaq = balance_wathaq - v_loser_stake where id = v_loser.id;

  for v_loan in
    select * from match_loans
    where match_id = p_match_id and borrowing_team_id = p_winner_team_id and not fee_settled
  loop
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, created_by)
    values (v_loan.borrowing_team_id, -v_loan.winning_bid_amount,
      (select balance_wathaq from teams where id = v_loan.borrowing_team_id) - v_loan.winning_bid_amount,
      'loan_fee', p_match_id, v_loan.id, auth.uid());
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, created_by)
    values (v_loan.original_team_id, v_loan.winning_bid_amount,
      (select balance_wathaq from teams where id = v_loan.original_team_id) + v_loan.winning_bid_amount,
      'loan_fee', p_match_id, v_loan.id, auth.uid());

    update teams set balance_wathaq = balance_wathaq - v_loan.winning_bid_amount where id = v_loan.borrowing_team_id;
    update teams set balance_wathaq = balance_wathaq + v_loan.winning_bid_amount where id = v_loan.original_team_id;

    update match_loans set fee_settled = true where id = v_loan.id;
  end loop;

  update matches set
    status = 'completed',
    winner_team_id = p_winner_team_id,
    team_a_balance_before = v_team_a.balance_wathaq,
    team_b_balance_before = v_team_b.balance_wathaq,
    team_a_balance_after = (select balance_wathaq from teams where id = v_team_a.id),
    team_b_balance_after = (select balance_wathaq from teams where id = v_team_b.id),
    confirmed_at = now(),
    confirmed_by = auth.uid()
  where id = p_match_id
  returning * into v_match;

  select week_number into v_week_number from weeks where id = v_match.week_id;

  v_rank := 0;
  for v_team in
    select t.id, t.balance_wathaq,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id = t.id) as wins,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id <> t.id and t.id in (m.team_a_id, m.team_b_id)) as losses
    from teams t
    order by t.balance_wathaq desc, t.name asc
  loop
    v_rank := v_rank + 1;
    insert into standings_snapshots (week_id, team_id, balance_wathaq, wins, losses, rank)
    values (v_match.week_id, v_team.id, v_team.balance_wathaq, v_team.wins, v_team.losses, v_rank)
    on conflict (week_id, team_id) do update
      set balance_wathaq = excluded.balance_wathaq, wins = excluded.wins,
          losses = excluded.losses, rank = excluded.rank;
  end loop;

  perform log_audit('confirm_match_result', 'matches', p_match_id::text,
    jsonb_build_object('status', 'scheduled'), to_jsonb(v_match));

  return v_match;
end; $$;

-- دوري وثاق: تصريحات الدوري (إعلانات تحمّس الشباب، يتحكم فيها المدير)
-- =============================================================================

create table league_announcements (
  id           uuid primary key default gen_random_uuid(),
  body         text not null,
  team_id      uuid references teams(id),   -- null = تصريح عام باسم "الإدارة"، وإلا منسوب لفريق
  created_by   uuid references profiles(id),
  created_at   timestamptz not null default now()
);
create index idx_announcements_created on league_announcements(created_at desc);

alter table league_announcements enable row level security;

-- القراءة مفتوحة للجميع (حتى الزوار بدون تسجيل دخول) — هذا محتوى تحفيزي عام
create policy sel_announcements on league_announcements for select to authenticated, anon using (true);
grant select on league_announcements to anon;

create or replace function create_announcement(p_body text, p_team_id uuid default null)
returns league_announcements
language plpgsql security definer set search_path = public as $$
declare v_row league_announcements;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_body is null or length(trim(p_body)) = 0 then raise exception 'body is required'; end if;
  insert into league_announcements (body, team_id, created_by)
  values (trim(p_body), p_team_id, auth.uid())
  returning * into v_row;
  perform log_audit('create_announcement', 'league_announcements', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

create or replace function delete_announcement(p_announcement_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_row league_announcements;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from league_announcements where id = p_announcement_id;
  if not found then raise exception 'announcement not found'; end if;
  delete from league_announcements where id = p_announcement_id;
  perform log_audit('delete_announcement', 'league_announcements', p_announcement_id::text, to_jsonb(v_row), null);
end; $$;

grant execute on function create_announcement(text, uuid) to authenticated;
grant execute on function delete_announcement(uuid) to authenticated;

-- دوري وثاق: السماح بأكثر من مباراة في نفس الأسبوع
-- =============================================================================

alter table matches drop constraint if exists matches_week_id_key;
create index if not exists idx_matches_week_id on matches(week_id);

-- دوري وثاق: لا تسجيل ذاتي مفتوح — فقط الأرقام اللي سجّلتها الإدارة مسبقًا على فريق
-- يقدر صاحبها "يُفعّل" حسابه (يختار رمز دخول لأول مرة). أي رقم غير مسجَّل يُرفض من
-- قاعدة البيانات نفسها (وليس فقط من الواجهة).
-- =============================================================================

create or replace function handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_phone text;
  v_team_id uuid;
  v_is_bootstrap boolean;
begin
  -- أول حساب على الإطلاق (ما فيه ولا صف profiles بعد) يُعتبر تمهيد المدير الأول،
  -- فيمر بدون تحقق من تسجيله كابتن على فريق — بعده يرجع القيد يشتغل عادي.
  select not exists(select 1 from profiles) into v_is_bootstrap;

  if new.email like '%@wathaq.local' and not v_is_bootstrap then
    v_phone := split_part(new.email, '@', 1);
    select id into v_team_id from teams where captain_phone = v_phone;
    if v_team_id is null then
      raise exception 'هذا الرقم غير مسجَّل من الإدارة — تواصل مع إدارة الدوري';
    end if;
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

-- يستخدمها login.html قبل عرض النموذج: هل الرقم مسجَّل أصلًا من الإدارة؟
-- وإذا كان مسجَّلًا، هل صاحبه فعّل حسابه (اختار رمزًا) من قبل أو لا (أول مرة)؟
create or replace function check_captain_phone(p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_team_name text;
  v_activated boolean;
begin
  select id, name into v_team_id, v_team_name from teams where captain_phone = p_phone;
  if v_team_id is null then
    return jsonb_build_object('registered', false);
  end if;
  select exists(select 1 from profiles where team_id = v_team_id) into v_activated;
  return jsonb_build_object('registered', true, 'activated', v_activated, 'team_name', v_team_name);
end; $$;

grant execute on function check_captain_phone(text) to authenticated, anon;

-- إصلاح: check_captain_phone كانت تفحص فقط جدول teams.captain_phone، فترفض حتى
-- أرقام الحسابات الموجودة أصلًا (مثل رقم المدير نفسه، غير المسجَّل كـ"كابتن" لأي فريق) —
-- ما يمنع المدير من تسجيل الدخول إطلاقًا. الترتيب الصحيح: أولًا هل الحساب موجود
-- أصلًا (أي نوع حساب)؟ إذا نعم، دخول عادي دائمًا. إذا لا، عندها فقط نفحص هل الرقم
-- مسجَّل كابتن من الإدارة (للسماح بالتفعيل لأول مرة) أو نرفضه.
-- =============================================================================

create or replace function check_captain_phone(p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := p_phone || '@wathaq.local';
  v_user_exists boolean;
  v_team_id uuid;
  v_team_name text;
begin
  select exists(select 1 from auth.users where email = v_email) into v_user_exists;
  if v_user_exists then
    return jsonb_build_object('registered', true, 'activated', true);
  end if;

  select id, name into v_team_id, v_team_name from teams where captain_phone = p_phone;
  if v_team_id is null then
    return jsonb_build_object('registered', false);
  end if;

  return jsonb_build_object('registered', true, 'activated', false, 'team_name', v_team_name);
end; $$;

-- إصلاح: الدخول عبر "دخول الكباتن" أو "دخول الإدارة" لازم يرفض أي رقم ينتمي
-- لحساب من النوع التاني (مثلًا: كتابة رقم المدير من صفحة دخول الكباتن) بدل ما
-- يدخّله بصمت من الباب الغلط. نضيف "role" لرد الدالة عشان الواجهة تقارنه بنوع
-- الدخول المطلوب (?as=admin|captain) وترفض أي تعارض بوضوح.
-- =============================================================================

create or replace function check_captain_phone(p_phone text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := p_phone || '@wathaq.local';
  v_user_id uuid;
  v_role user_role;
  v_team_id uuid;
  v_team_name text;
begin
  select id into v_user_id from auth.users where email = v_email;
  if v_user_id is not null then
    select role into v_role from profiles where id = v_user_id;
    return jsonb_build_object('registered', true, 'activated', true, 'role', v_role);
  end if;

  select id, name into v_team_id, v_team_name from teams where captain_phone = p_phone;
  if v_team_id is null then
    return jsonb_build_object('registered', false);
  end if;

  return jsonb_build_object('registered', true, 'activated', false, 'team_name', v_team_name, 'role', 'team_captain');
end; $$;

-- دوري وثاق: صور بالتصريحات — الإدارة ترفع صورة من المباراة مع كل تصريح
-- =============================================================================

alter table league_announcements add column image_url text;

create or replace function create_announcement(p_body text, p_team_id uuid default null, p_image_url text default null)
returns league_announcements
language plpgsql security definer set search_path = public as $$
declare v_row league_announcements;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_body is null or length(trim(p_body)) = 0 then raise exception 'body is required'; end if;
  insert into league_announcements (body, team_id, image_url, created_by)
  values (trim(p_body), p_team_id, nullif(p_image_url, ''), auth.uid())
  returning * into v_row;
  perform log_audit('create_announcement', 'league_announcements', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

-- تخزين ملفات: bucket عام للقراءة (الصور تظهر حتى للزوار بدون تسجيل دخول)،
-- والرفع/الحذف محصور بالإدارة فقط عبر سياسات storage.objects
insert into storage.buckets (id, name, public)
values ('announcement-images', 'announcement-images', true)
on conflict (id) do nothing;

create policy "admin uploads announcement images"
on storage.objects for insert to authenticated
with check (bucket_id = 'announcement-images' and is_admin());

create policy "admin deletes announcement images"
on storage.objects for delete to authenticated
using (bucket_id = 'announcement-images' and is_admin());

-- دوري وثاق: فصل الصور عن التصريحات النصية — قسمان مختلفان تمامًا
-- =============================================================================

-- 1) رجوع "تصريحات الدوري" نصًا فقط (تراجع عن إضافة صورة داخلها)
alter table league_announcements drop column if exists image_url;

create or replace function create_announcement(p_body text, p_team_id uuid default null)
returns league_announcements
language plpgsql security definer set search_path = public as $$
declare v_row league_announcements;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_body is null or length(trim(p_body)) = 0 then raise exception 'body is required'; end if;
  insert into league_announcements (body, team_id, created_by)
  values (trim(p_body), p_team_id, auth.uid())
  returning * into v_row;
  perform log_audit('create_announcement', 'league_announcements', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

-- 2) "صور الدوري" — قسم مستقل تمامًا: صورة + تعليق فقط، بلا نص طويل ولا شارة فريق ملزمة
create table league_photos (
  id           uuid primary key default gen_random_uuid(),
  image_url    text not null,
  caption      text,
  team_id      uuid references teams(id),
  created_by   uuid references profiles(id),
  created_at   timestamptz not null default now()
);
create index idx_photos_created on league_photos(created_at desc);

alter table league_photos enable row level security;
create policy sel_photos on league_photos for select to authenticated, anon using (true);
grant select on league_photos to anon;

create or replace function create_photo(p_image_url text, p_caption text default null, p_team_id uuid default null)
returns league_photos
language plpgsql security definer set search_path = public as $$
declare v_row league_photos;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  if p_image_url is null or length(trim(p_image_url)) = 0 then raise exception 'image is required'; end if;
  insert into league_photos (image_url, caption, team_id, created_by)
  values (p_image_url, nullif(trim(coalesce(p_caption, '')), ''), p_team_id, auth.uid())
  returning * into v_row;
  perform log_audit('create_photo', 'league_photos', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

create or replace function delete_photo(p_photo_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_row league_photos;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from league_photos where id = p_photo_id;
  if not found then raise exception 'photo not found'; end if;
  delete from league_photos where id = p_photo_id;
  perform log_audit('delete_photo', 'league_photos', p_photo_id::text, to_jsonb(v_row), null);
end; $$;

grant execute on function create_photo(text, text, uuid) to authenticated;
grant execute on function delete_photo(uuid) to authenticated;

-- دوري وثاق: رسم الإعارة يُخصم من الفريق المستعير عند الفوز ثم "يختفي" من الاقتصاد
-- بالكامل، بدل ما يُضاف لرصيد الفريق الأصلي صاحب اللاعب.
-- ============================================================

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
  if v_loser_stake > v_loser.balance_wathaq then
    raise exception 'the losing team''s own stake (%) exceeds its current balance (%)', v_loser_stake, v_loser.balance_wathaq;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_winner.id, v_winner_stake, v_winner.balance_wathaq + v_winner_stake, 'match_result', p_match_id, auth.uid());
  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_loser.id, -v_loser_stake, v_loser.balance_wathaq - v_loser_stake, 'match_result', p_match_id, auth.uid());

  update teams set balance_wathaq = balance_wathaq + v_winner_stake where id = v_winner.id;
  update teams set balance_wathaq = balance_wathaq - v_loser_stake where id = v_loser.id;

  -- رسم الإعارة: يُخصم من الفريق المستعير الفائز فقط، ولا يُضاف لأي فريق آخر
  for v_loan in
    select * from match_loans
    where match_id = p_match_id and borrowing_team_id = p_winner_team_id and not fee_settled
  loop
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, created_by)
    values (v_loan.borrowing_team_id, -v_loan.winning_bid_amount,
      (select balance_wathaq from teams where id = v_loan.borrowing_team_id) - v_loan.winning_bid_amount,
      'loan_fee', p_match_id, v_loan.id, auth.uid());

    update teams set balance_wathaq = balance_wathaq - v_loan.winning_bid_amount where id = v_loan.borrowing_team_id;

    update match_loans set fee_settled = true where id = v_loan.id;
  end loop;

  update matches set
    status = 'completed',
    winner_team_id = p_winner_team_id,
    team_a_balance_before = v_team_a.balance_wathaq,
    team_b_balance_before = v_team_b.balance_wathaq,
    team_a_balance_after = (select balance_wathaq from teams where id = v_team_a.id),
    team_b_balance_after = (select balance_wathaq from teams where id = v_team_b.id),
    confirmed_at = now(),
    confirmed_by = auth.uid()
  where id = p_match_id
  returning * into v_match;

  select week_number into v_week_number from weeks where id = v_match.week_id;

  v_rank := 0;
  for v_team in
    select t.id, t.balance_wathaq,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id = t.id) as wins,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id <> t.id and t.id in (m.team_a_id, m.team_b_id)) as losses
    from teams t
    order by t.balance_wathaq desc, t.name asc
  loop
    v_rank := v_rank + 1;
    insert into standings_snapshots (week_id, team_id, balance_wathaq, wins, losses, rank)
    values (v_match.week_id, v_team.id, v_team.balance_wathaq, v_team.wins, v_team.losses, v_rank)
    on conflict (week_id, team_id) do update
      set balance_wathaq = excluded.balance_wathaq, wins = excluded.wins,
          losses = excluded.losses, rank = excluded.rank;
  end loop;

  perform log_audit('confirm_match_result', 'matches', p_match_id::text,
    jsonb_build_object('status', 'scheduled'), to_jsonb(v_match));

  return v_match;
end; $$;

-- دوري وثاق: توقعات المباريات — كباتن الفرق غير المشاركة بمباراة معيّنة يقدر أي
-- واحد منهم يتوقع الفائز، وإذا صحّ توقعه ياخذ مبلغًا تحدده الإدارة لكل مباراة على حدة.
-- لا خسارة على توقع خاطئ — فقط لا يربح شيء.
-- =============================================================================

alter type ledger_reason add value if not exists 'prediction_reward';

alter table matches add column prediction_enabled boolean not null default false;
alter table matches add column prediction_reward integer;
alter table matches add constraint chk_prediction_reward_positive check (prediction_reward is null or prediction_reward > 0);

create table match_predictions (
  id                       uuid primary key default gen_random_uuid(),
  match_id                 uuid not null references matches(id) on delete cascade,
  predicting_team_id       uuid not null references teams(id),
  predicted_winner_team_id uuid not null references teams(id),
  created_by               uuid references profiles(id),
  created_at               timestamptz not null default now(),
  unique (match_id, predicting_team_id)
);
alter table match_predictions enable row level security;
create policy sel_match_predictions on match_predictions for select to authenticated, anon using (true);
grant select on match_predictions to anon;

-- الإدارة تفتح التوقع لمباراة معيّنة وتحدد مبلغ الجائزة
create or replace function set_match_prediction(p_match_id uuid, p_reward integer)
returns matches
language plpgsql security definer set search_path = public as $$
declare v_before matches; v_after matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from matches where id = p_match_id;
  if not found then raise exception 'match not found'; end if;
  if v_before.status = 'completed' then raise exception 'match already completed'; end if;
  if p_reward is null or p_reward <= 0 then raise exception 'reward must be a positive number'; end if;
  update matches set prediction_enabled = true, prediction_reward = p_reward where id = p_match_id
  returning * into v_after;
  perform log_audit('set_match_prediction', 'matches', p_match_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

create or replace function close_prediction(p_match_id uuid)
returns matches
language plpgsql security definer set search_path = public as $$
declare v_before matches; v_after matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from matches where id = p_match_id;
  if not found then raise exception 'match not found'; end if;
  update matches set prediction_enabled = false where id = p_match_id
  returning * into v_after;
  perform log_audit('close_prediction', 'matches', p_match_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

-- كابتن فريق غير مشارك بهذي المباراة يسجّل توقعه (يقدر يغيّره لين تُعتمد النتيجة)
create or replace function submit_prediction(p_match_id uuid, p_predicted_team_id uuid)
returns match_predictions
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_team_id uuid;
  v_row match_predictions;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: captains only'; end if;

  select * into v_match from matches where id = p_match_id;
  if not found then raise exception 'match not found'; end if;
  if not v_match.prediction_enabled then raise exception 'predictions are not open for this match'; end if;
  if v_match.status = 'completed' then raise exception 'match already completed'; end if;
  if v_team_id in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'cannot predict a match your own team is playing in';
  end if;
  if p_predicted_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'predicted team must be one of the two participating teams';
  end if;

  insert into match_predictions (match_id, predicting_team_id, predicted_winner_team_id, created_by)
  values (p_match_id, v_team_id, p_predicted_team_id, auth.uid())
  on conflict (match_id, predicting_team_id)
    do update set predicted_winner_team_id = excluded.predicted_winner_team_id
  returning * into v_row;

  return v_row;
end; $$;

grant execute on function set_match_prediction(uuid, integer) to authenticated;
grant execute on function close_prediction(uuid) to authenticated;
grant execute on function submit_prediction(uuid, uuid) to authenticated;

-- تحديث اعتماد نتيجة المباراة: يدفع جائزة التوقع لكل كابتن توقّع صح
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
  v_prediction record;
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

  if v_loser_stake > v_loser.balance_wathaq then
    raise exception 'the losing team''s own stake (%) exceeds its current balance (%)', v_loser_stake, v_loser.balance_wathaq;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_winner.id, v_winner_stake, v_winner.balance_wathaq + v_winner_stake, 'match_result', p_match_id, auth.uid());
  insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
  values (v_loser.id, -v_loser_stake, v_loser.balance_wathaq - v_loser_stake, 'match_result', p_match_id, auth.uid());

  update teams set balance_wathaq = balance_wathaq + v_winner_stake where id = v_winner.id;
  update teams set balance_wathaq = balance_wathaq - v_loser_stake where id = v_loser.id;

  for v_loan in
    select * from match_loans
    where match_id = p_match_id and borrowing_team_id = p_winner_team_id and not fee_settled
  loop
    insert into balance_ledger (team_id, delta, balance_after, reason, match_id, loan_id, created_by)
    values (v_loan.borrowing_team_id, -v_loan.winning_bid_amount,
      (select balance_wathaq from teams where id = v_loan.borrowing_team_id) - v_loan.winning_bid_amount,
      'loan_fee', p_match_id, v_loan.id, auth.uid());

    update teams set balance_wathaq = balance_wathaq - v_loan.winning_bid_amount where id = v_loan.borrowing_team_id;

    update match_loans set fee_settled = true where id = v_loan.id;
  end loop;

  -- توقعات صحيحة: كل كابتن توقّع الفريق الفائز ياخذ مبلغ الجائزة كامل (بلا تقسيم)
  if v_match.prediction_enabled and v_match.prediction_reward is not null then
    for v_prediction in
      select * from match_predictions
      where match_id = p_match_id and predicted_winner_team_id = p_winner_team_id
    loop
      insert into balance_ledger (team_id, delta, balance_after, reason, match_id, created_by)
      values (v_prediction.predicting_team_id, v_match.prediction_reward,
        (select balance_wathaq from teams where id = v_prediction.predicting_team_id) + v_match.prediction_reward,
        'prediction_reward', p_match_id, auth.uid());

      update teams set balance_wathaq = balance_wathaq + v_match.prediction_reward where id = v_prediction.predicting_team_id;
    end loop;
  end if;

  update matches set
    status = 'completed',
    winner_team_id = p_winner_team_id,
    team_a_balance_before = v_team_a.balance_wathaq,
    team_b_balance_before = v_team_b.balance_wathaq,
    team_a_balance_after = (select balance_wathaq from teams where id = v_team_a.id),
    team_b_balance_after = (select balance_wathaq from teams where id = v_team_b.id),
    confirmed_at = now(),
    confirmed_by = auth.uid()
  where id = p_match_id
  returning * into v_match;

  select week_number into v_week_number from weeks where id = v_match.week_id;

  v_rank := 0;
  for v_team in
    select t.id, t.balance_wathaq,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id = t.id) as wins,
      (select count(*) from matches m where m.status='completed' and m.winner_team_id <> t.id and t.id in (m.team_a_id, m.team_b_id)) as losses
    from teams t
    order by t.balance_wathaq desc, t.name asc
  loop
    v_rank := v_rank + 1;
    insert into standings_snapshots (week_id, team_id, balance_wathaq, wins, losses, rank)
    values (v_match.week_id, v_team.id, v_team.balance_wathaq, v_team.wins, v_team.losses, v_rank)
    on conflict (week_id, team_id) do update
      set balance_wathaq = excluded.balance_wathaq, wins = excluded.wins,
          losses = excluded.losses, rank = excluded.rank;
  end loop;

  perform log_audit('confirm_match_result', 'matches', p_match_id::text,
    jsonb_build_object('status', 'scheduled'), to_jsonb(v_match));

  return v_match;
end; $$;

-- دوري وثاق: التوقع نهائي بعد تسجيله — ما يقدر الكابتن يغيّره أو يستبدله
-- =============================================================================

create or replace function submit_prediction(p_match_id uuid, p_predicted_team_id uuid)
returns match_predictions
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_team_id uuid;
  v_row match_predictions;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: captains only'; end if;

  select * into v_match from matches where id = p_match_id;
  if not found then raise exception 'match not found'; end if;
  if not v_match.prediction_enabled then raise exception 'predictions are not open for this match'; end if;
  if v_match.status = 'completed' then raise exception 'match already completed'; end if;
  if v_team_id in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'cannot predict a match your own team is playing in';
  end if;
  if p_predicted_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'predicted team must be one of the two participating teams';
  end if;
  if exists(select 1 from match_predictions where match_id = p_match_id and predicting_team_id = v_team_id) then
    raise exception 'already predicted this match — predictions are final';
  end if;

  insert into match_predictions (match_id, predicting_team_id, predicted_winner_team_id, created_by)
  values (p_match_id, v_team_id, p_predicted_team_id, auth.uid())
  returning * into v_row;

  return v_row;
end; $$;

-- إصلاح: لما رجّعنا "تصريحات الدوري" نصًا فقط (0019)، استخدمنا create or replace
-- بنسختها القديمة (بمعاملين)، لكن Postgres يعتبر الاختلاف بعدد/نوع المعاملات دالة
-- منفصلة تمامًا عن نسخة الصورة القديمة (0018، بثلاثة معاملات) — فصار عندنا نسختان
-- تعملان بنفس الاسم، وأي استدعاء بمعاملين يصير غامضًا (Postgres ما يقدر يختار بينهما
-- لأن p_image_url له قيمة افتراضية، فتصلح للاستدعاء بمعاملين هي كمان).
-- الحل: حذف النسخة القديمة الثلاثية صراحةً.
-- =============================================================================

drop function if exists create_announcement(text, uuid, text);

-- دوري وثاق: منع تعاقد فريق مع لاعب خصمه بنفس المباراة — الإعارة تكون فقط من فرق
-- ثالثة غير مشاركة بهذي المباراة، مو من الفريق اللي تلاعبه هذا الأسبوع تحديدًا.
-- =============================================================================

create or replace function claim_player_loan(
  p_match_id uuid, p_player_id uuid, p_amount integer, p_note text default null
) returns loan_claims
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_player players;
  v_team_id uuid;
  v_opponent_id uuid;
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

  v_opponent_id := case when v_team_id = v_match.team_a_id then v_match.team_b_id else v_match.team_a_id end;
  if v_player.original_team_id = v_opponent_id then
    raise exception 'cannot sign a player from the team you are facing this match';
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

-- دوري وثاق: حذف فريق — مسموح فقط لو ما عنده لاعبون ولا مباريات بعد (حماية من فقد بيانات حقيقية)
-- =============================================================================

create or replace function delete_team(p_team_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_team teams;
  v_player_count integer;
  v_match_count integer;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_team from teams where id = p_team_id;
  if not found then raise exception 'team not found'; end if;

  select count(*) into v_player_count from players where original_team_id = p_team_id;
  if v_player_count > 0 then
    raise exception 'cannot delete a team that still has players — remove them first';
  end if;

  select count(*) into v_match_count from matches where team_a_id = p_team_id or team_b_id = p_team_id;
  if v_match_count > 0 then
    raise exception 'cannot delete a team that already has matches — remove them first';
  end if;

  -- يحذف حساب الكابتن المفعّل معه إن وجد (نفس أثر "حذف رمز الكابتن")
  delete from auth.users where id in (select id from profiles where team_id = p_team_id);

  delete from teams where id = p_team_id;
  perform log_audit('delete_team', 'teams', p_team_id::text, to_jsonb(v_team), null);
end; $$;

grant execute on function delete_team(uuid) to authenticated;

-- دوري وثاق: يسمح لكابتن الفريق ينشر تصريح باسم فريقه هو بس (لا يقدر ينتحل فريق
-- ثاني ولا ينشر باسم "الإدارة")، عشان يرجع للموقع بشكل متكرر. الإدارة تبقى تقدر
-- تنشر باسم أي فريق أو باسمها هي كما هو. نفس القاعدة على الحذف: كل طرف يحذف بس اللي نشره.
-- =============================================================================

create or replace function create_announcement(p_body text, p_team_id uuid default null)
returns league_announcements
language plpgsql security definer set search_path = public as $$
declare
  v_row league_announcements;
  v_caller_team_id uuid;
begin
  if not is_admin() then
    v_caller_team_id := my_team_id();
    if v_caller_team_id is null then
      raise exception 'forbidden: admins or team captains only';
    end if;
    if p_team_id is distinct from v_caller_team_id then
      raise exception 'captains can only publish on behalf of their own team';
    end if;
  end if;

  if p_body is null or length(trim(p_body)) = 0 then raise exception 'body is required'; end if;

  insert into league_announcements (body, team_id, created_by)
  values (trim(p_body), p_team_id, auth.uid())
  returning * into v_row;
  perform log_audit('create_announcement', 'league_announcements', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

create or replace function delete_announcement(p_announcement_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_row league_announcements;
  v_caller_team_id uuid;
begin
  select * into v_row from league_announcements where id = p_announcement_id;
  if not found then raise exception 'announcement not found'; end if;

  if not is_admin() then
    v_caller_team_id := my_team_id();
    if v_caller_team_id is null or v_row.team_id is distinct from v_caller_team_id then
      raise exception 'forbidden: you can only delete your own team''s announcements';
    end if;
  end if;

  delete from league_announcements where id = p_announcement_id;
  perform log_audit('delete_announcement', 'league_announcements', p_announcement_id::text, to_jsonb(v_row), null);
end; $$;

-- دوري وثاق: حذف مباراة أُضيفت بالغلط — ممنوع على المباريات المُعتمدة (فيها أثر مالي
-- حقيقي بالفعل) — لازم "تصحيح/إلغاء الاعتماد" أولًا، وبعدها تقدر تحذفها. أي مباراة
-- لسه غير معتمدة يُحذف معها كل ما يرتبط بها (توقعات، صفقات إعارة، تشكيلات، أحداث).
-- =============================================================================

create or replace function delete_match(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_match matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_match from matches where id = p_match_id;
  if not found then raise exception 'match not found'; end if;
  if v_match.status = 'completed' then
    raise exception 'cannot delete a completed match — undo its result first, then delete it';
  end if;

  delete from match_predictions where match_id = p_match_id;
  delete from loan_claims where match_id = p_match_id;
  delete from match_loans where match_id = p_match_id;
  delete from match_lineups where match_id = p_match_id;
  delete from match_events where match_id = p_match_id;
  delete from balance_ledger where match_id = p_match_id;
  delete from matches where id = p_match_id;

  perform log_audit('delete_match', 'matches', p_match_id::text, to_jsonb(v_match), null);
end; $$;

grant execute on function delete_match(uuid) to authenticated;

-- دوري وثاق: نقل ملكية لاعب بين الفرق بشكل دائم (مختلف عن الإعارة المؤقتة لمباراة
-- واحدة) — يُستخدم لتصحيح خطأ أو انتقال حقيقي بين المواسم. السجلات المالية والتاريخية
-- (match_lineups/match_loans/loan_claims) تحفظ لقطتها الخاصة من الفريق وقت الحدث، لذلك
-- تغيير original_team_id لاحقًا لا يُغيّر أي تاريخ محسوم.
-- كذلك حذف لاعب نهائيًا — يُمنع لو له أي تاريخ فعلي (تشكيلة/إعارة/صفقة) حماية من فقد بيانات حقيقية.
-- =============================================================================

create or replace function transfer_player(p_player_id uuid, p_new_team_id uuid)
returns players
language plpgsql security definer set search_path = public as $$
declare v_before players; v_after players; v_team teams;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_before from players where id = p_player_id;
  if not found then raise exception 'player not found'; end if;

  select * into v_team from teams where id = p_new_team_id;
  if not found then raise exception 'team not found'; end if;

  if v_before.original_team_id = p_new_team_id then
    raise exception 'player is already on this team';
  end if;

  update players set original_team_id = p_new_team_id
  where id = p_player_id
  returning * into v_after;

  perform log_audit('transfer_player', 'players', p_player_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

create or replace function delete_player(p_player_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_player players;
  v_lineup_count integer;
  v_loan_count integer;
  v_claim_count integer;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_player from players where id = p_player_id;
  if not found then raise exception 'player not found'; end if;

  select count(*) into v_lineup_count from match_lineups where player_id = p_player_id;
  if v_lineup_count > 0 then
    raise exception 'cannot delete a player who already appears in a match lineup';
  end if;

  select count(*) into v_loan_count from match_loans where player_id = p_player_id;
  if v_loan_count > 0 then
    raise exception 'cannot delete a player who has an existing loan record';
  end if;

  select count(*) into v_claim_count from loan_claims where player_id = p_player_id;
  if v_claim_count > 0 then
    raise exception 'cannot delete a player who has an existing loan claim';
  end if;

  delete from auctions where player_id = p_player_id;
  delete from players where id = p_player_id;
  perform log_audit('delete_player', 'players', p_player_id::text, to_jsonb(v_player), null);
end; $$;

grant execute on function transfer_player(uuid, uuid) to authenticated;
grant execute on function delete_player(uuid) to authenticated;

-- دوري وثاق: (1) تفاعلات (إيموجي) على التصريحات والصور من أي كابتن أو الإدارة،
-- (2) اقتصاد صور جديد: صورة عادية بـ25 وثاق تُنشر فورًا باسم فريق الكابتن، وحجز
-- "يوم إبراز" بـ75 وثاق يُظهر صورة الفريق كإعلان يملأ الشاشة لأول من يفتح الموقع
-- ذاك اليوم، لمدة عشر ثوانٍ فقط وبدون إمكانية إغلاقه يدويًا — يحتاج اعتماد الإدارة
-- قبل ما يظهر فعليًا (خطورة أعلى من الصورة العادية لأنه يُفرض على الجميع).
-- =============================================================================

-- ============ 1) التفاعلات ============

create table content_reactions (
  id            uuid primary key default gen_random_uuid(),
  content_type  text not null check (content_type in ('announcement', 'photo')),
  content_id    uuid not null,
  emoji         text not null check (emoji in ('❤️', '🔥', '👏', '😂')),
  reacted_by    uuid not null references profiles(id),
  created_at    timestamptz not null default now(),
  unique (content_type, content_id, reacted_by, emoji)
);
create index idx_reactions_content on content_reactions(content_type, content_id);

alter table content_reactions enable row level security;
create policy sel_reactions on content_reactions for select to authenticated, anon using (true);
grant select on content_reactions to anon;

-- كتابة مباشرة بدون RPC: عملية غير حساسة ماليًا ولا تؤثر على حالة اللعبة، كل مستخدم
-- يتحكم بصفه هو فقط (reacted_by = خودو) — لا حاجة لدالة SECURITY DEFINER هنا.
create policy ins_reactions on content_reactions for insert to authenticated
  with check (reacted_by = auth.uid());
create policy del_reactions on content_reactions for delete to authenticated
  using (reacted_by = auth.uid());

grant select, insert, delete on content_reactions to authenticated;

-- ============ 2) توسعة أسباب السجل المالي ============

alter type ledger_reason add value if not exists 'photo_fee';
alter type ledger_reason add value if not exists 'featured_photo_fee';
alter type ledger_reason add value if not exists 'featured_photo_refund';

-- ============ 3) صورة عادية من كابتن — 25 وثاق، تُنشر فورًا بلا اعتماد ============

create or replace function submit_team_photo(p_image_url text, p_caption text default null)
returns league_photos
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_team teams;
  v_new_balance integer;
  v_row league_photos;
  v_cost constant integer := 25;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;
  if p_image_url is null or length(trim(p_image_url)) = 0 then raise exception 'image is required'; end if;

  select * into v_team from teams where id = v_team_id for update;
  v_new_balance := v_team.balance_wathaq - v_cost;
  if v_new_balance < 0 then
    raise exception 'insufficient balance: posting a photo costs % وثاق (current balance %)', v_cost, v_team.balance_wathaq;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_team_id, -v_cost, v_new_balance, 'photo_fee', 'نشر صورة فريق', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_team_id;

  insert into league_photos (image_url, caption, team_id, created_by)
  values (p_image_url, nullif(trim(coalesce(p_caption, '')), ''), v_team_id, auth.uid())
  returning * into v_row;

  perform log_audit('submit_team_photo', 'league_photos', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

grant execute on function submit_team_photo(text, text) to authenticated;

-- ============ 4) حجز "يوم الإبراز" — 75 وثاق، يحتاج اعتماد الإدارة ============

create table featured_photo_bookings (
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references teams(id),
  feature_date  date not null,
  image_url     text not null,
  cost_paid     integer not null default 75,
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_by    uuid references profiles(id),
  created_at    timestamptz not null default now()
);

-- تاريخ واحد يقبل حجز واحد فقط طالما لسه معلّق أو معتمد؛ لو رُفض يتحرر التاريخ من جديد
create unique index uq_featured_date_active on featured_photo_bookings(feature_date)
  where status in ('pending', 'approved');

alter table featured_photo_bookings enable row level security;

-- الجدول الخام: الإدارة فقط، أو الفريق صاحب الحجز نفسه (يشوف حالة حجوزاته)
create policy sel_featured_raw on featured_photo_bookings for select to authenticated using (
  is_admin() or team_id = my_team_id()
);

-- عرض عام للتوفّر (بدون كشف الصورة ولا صاحب الحجز) — يستخدمه أي كابتن يختار يوم فاضي
create view featured_photo_availability as
  select feature_date from featured_photo_bookings where status in ('pending', 'approved');
grant select on featured_photo_availability to authenticated;

-- عرض عام لإعلان اليوم المعتمد فقط — هذا اللي يقرأه شاشة الدخول الكاملة
create view featured_photo_public as
  select id, feature_date, image_url from featured_photo_bookings
  where status = 'approved' and feature_date = current_date;
grant select on featured_photo_public to anon, authenticated;

create or replace function book_featured_photo(p_feature_date date, p_image_url text)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_team teams;
  v_new_balance integer;
  v_row featured_photo_bookings;
  v_cost constant integer := 75;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;
  if p_image_url is null or length(trim(p_image_url)) = 0 then raise exception 'image is required'; end if;
  if p_feature_date < current_date or p_feature_date > current_date + 6 then
    raise exception 'feature_date must be within the next 7 days (today included)';
  end if;

  select * into v_team from teams where id = v_team_id for update;
  v_new_balance := v_team.balance_wathaq - v_cost;
  if v_new_balance < 0 then
    raise exception 'insufficient balance: featuring a photo costs % وثاق (current balance %)', v_cost, v_team.balance_wathaq;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_team_id, -v_cost, v_new_balance, 'featured_photo_fee', 'حجز يوم إبراز', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_team_id;

  insert into featured_photo_bookings (team_id, feature_date, image_url, cost_paid, created_by)
  values (v_team_id, p_feature_date, p_image_url, v_cost, auth.uid())
  returning * into v_row;

  perform log_audit('book_featured_photo', 'featured_photo_bookings', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
exception
  when unique_violation then
    raise exception 'هذا اليوم محجوز مسبقًا من فريق ثاني';
end; $$;

create or replace function approve_featured_photo(p_booking_id uuid)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare v_row featured_photo_bookings;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from featured_photo_bookings where id = p_booking_id;
  if not found then raise exception 'booking not found'; end if;
  if v_row.status <> 'pending' then raise exception 'booking already % ', v_row.status; end if;

  update featured_photo_bookings set status = 'approved' where id = p_booking_id returning * into v_row;
  perform log_audit('approve_featured_photo', 'featured_photo_bookings', p_booking_id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

create or replace function reject_featured_photo(p_booking_id uuid)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare
  v_row featured_photo_bookings;
  v_team teams;
  v_new_balance integer;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from featured_photo_bookings where id = p_booking_id;
  if not found then raise exception 'booking not found'; end if;
  if v_row.status <> 'pending' then raise exception 'booking already %', v_row.status; end if;

  select * into v_team from teams where id = v_row.team_id for update;
  v_new_balance := v_team.balance_wathaq + v_row.cost_paid;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_row.team_id, v_row.cost_paid, v_new_balance, 'featured_photo_refund', 'استرجاع رسم يوم إبراز مرفوض', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_row.team_id;

  update featured_photo_bookings set status = 'rejected' where id = p_booking_id returning * into v_row;
  perform log_audit('reject_featured_photo', 'featured_photo_bookings', p_booking_id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

grant execute on function book_featured_photo(date, text) to authenticated;
grant execute on function approve_featured_photo(uuid) to authenticated;
grant execute on function reject_featured_photo(uuid) to authenticated;

-- دوري وثاق: يسمح لأي زائر (حتى بدون تسجيل دخول) يتفاعل، مو بس الكباتن/الإدارة —
-- عبر معرّف عشوائي يُخزَّن بمتصفحه (guest_key) بدل حساب حقيقي. مُعاد إنشاء الجدول
-- بالكامل لأن محاولة الإنشاء الأولى (0029) لم تكتمل على قاعدة البيانات.
-- =============================================================================

drop table if exists content_reactions cascade;

create table content_reactions (
  id            uuid primary key default gen_random_uuid(),
  content_type  text not null check (content_type in ('announcement', 'photo')),
  content_id    uuid not null,
  emoji         text not null check (emoji in ('❤️', '🔥', '👏', '😂')),
  reacted_by    uuid references profiles(id),   -- تسجيل دخول حقيقي
  guest_key     text,                            -- زائر بدون تسجيل دخول
  created_at    timestamptz not null default now(),
  check (reacted_by is not null or guest_key is not null)
);
create index idx_reactions_content on content_reactions(content_type, content_id);

-- هوية واحدة (حساب حقيقي أو ضيف) تقدر تحط نفس الإيموجي مرة وحدة بس على نفس العنصر
create unique index uq_reaction_identity on content_reactions(
  content_type, content_id, emoji, coalesce(reacted_by::text, guest_key)
);

alter table content_reactions enable row level security;

create policy sel_reactions on content_reactions for select to authenticated, anon using (true);

-- تسجيل دخول حقيقي: يتحكم بصفه هو بس (reacted_by = هويته الموثّقة)
create policy ins_reactions_auth on content_reactions for insert to authenticated
  with check (reacted_by = auth.uid() and guest_key is null);
create policy del_reactions_auth on content_reactions for delete to authenticated
  using (reacted_by = auth.uid());

-- زائر بدون تسجيل دخول: ما فيه هوية موثّقة أصلًا، فقط يضمن إنه ما ينتحل صف حساب حقيقي
create policy ins_reactions_guest on content_reactions for insert to anon
  with check (reacted_by is null and guest_key is not null);
create policy del_reactions_guest on content_reactions for delete to anon
  using (reacted_by is null and guest_key is not null);

grant select, insert, delete on content_reactions to anon, authenticated;

-- دوري وثاق: سياسة رفع "announcement-images" كانت محصورة بالإدارة فقط (0018) — من يوم
-- صار الكابتن يرفع صوره هو بنفسه (صورة عادية بـ25 أو حجز يوم إبراز بـ75)، لازم يقدر
-- يرفع للـ bucket نفسه، مو بس الإدارة. الحذف يبقى للإدارة فقط.
-- =============================================================================

create policy "captains can upload photos"
on storage.objects for insert to authenticated
with check (bucket_id = 'announcement-images' and my_team_id() is not null);

-- دوري وثاق: إعادة محاولة الجزء اللي لم يُطبَّق من 0029 (صورة عادية بـ25 وثاق، وحجز
-- "يوم إبراز" بـ75 وثاق يحتاج اعتماد الإدارة) — التفاعلات انتقلت لملف 0030 المستقل.
-- =============================================================================

-- ============ توسعة أسباب السجل المالي ============

alter type ledger_reason add value if not exists 'photo_fee';
alter type ledger_reason add value if not exists 'featured_photo_fee';
alter type ledger_reason add value if not exists 'featured_photo_refund';

-- ============ صورة عادية من كابتن — 25 وثاق، تُنشر فورًا بلا اعتماد ============

create or replace function submit_team_photo(p_image_url text, p_caption text default null)
returns league_photos
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_team teams;
  v_new_balance integer;
  v_row league_photos;
  v_cost constant integer := 25;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;
  if p_image_url is null or length(trim(p_image_url)) = 0 then raise exception 'image is required'; end if;

  select * into v_team from teams where id = v_team_id for update;
  v_new_balance := v_team.balance_wathaq - v_cost;
  if v_new_balance < 0 then
    raise exception 'insufficient balance: posting a photo costs % وثاق (current balance %)', v_cost, v_team.balance_wathaq;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_team_id, -v_cost, v_new_balance, 'photo_fee', 'نشر صورة فريق', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_team_id;

  insert into league_photos (image_url, caption, team_id, created_by)
  values (p_image_url, nullif(trim(coalesce(p_caption, '')), ''), v_team_id, auth.uid())
  returning * into v_row;

  perform log_audit('submit_team_photo', 'league_photos', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

grant execute on function submit_team_photo(text, text) to authenticated;

-- ============ حجز "يوم الإبراز" — 75 وثاق، يحتاج اعتماد الإدارة ============

create table if not exists featured_photo_bookings (
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references teams(id),
  feature_date  date not null,
  image_url     text not null,
  cost_paid     integer not null default 75,
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_by    uuid references profiles(id),
  created_at    timestamptz not null default now()
);

create unique index if not exists uq_featured_date_active on featured_photo_bookings(feature_date)
  where status in ('pending', 'approved');

alter table featured_photo_bookings enable row level security;

drop policy if exists sel_featured_raw on featured_photo_bookings;
create policy sel_featured_raw on featured_photo_bookings for select to authenticated using (
  is_admin() or team_id = my_team_id()
);

drop view if exists featured_photo_availability;
create view featured_photo_availability as
  select feature_date from featured_photo_bookings where status in ('pending', 'approved');
grant select on featured_photo_availability to authenticated;

drop view if exists featured_photo_public;
create view featured_photo_public as
  select id, feature_date, image_url from featured_photo_bookings
  where status = 'approved' and feature_date = current_date;
grant select on featured_photo_public to anon, authenticated;

create or replace function book_featured_photo(p_feature_date date, p_image_url text)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_team teams;
  v_new_balance integer;
  v_row featured_photo_bookings;
  v_cost constant integer := 75;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;
  if p_image_url is null or length(trim(p_image_url)) = 0 then raise exception 'image is required'; end if;
  if p_feature_date < current_date or p_feature_date > current_date + 6 then
    raise exception 'feature_date must be within the next 7 days (today included)';
  end if;

  select * into v_team from teams where id = v_team_id for update;
  v_new_balance := v_team.balance_wathaq - v_cost;
  if v_new_balance < 0 then
    raise exception 'insufficient balance: featuring a photo costs % وثاق (current balance %)', v_cost, v_team.balance_wathaq;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_team_id, -v_cost, v_new_balance, 'featured_photo_fee', 'حجز يوم إبراز', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_team_id;

  insert into featured_photo_bookings (team_id, feature_date, image_url, cost_paid, created_by)
  values (v_team_id, p_feature_date, p_image_url, v_cost, auth.uid())
  returning * into v_row;

  perform log_audit('book_featured_photo', 'featured_photo_bookings', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
exception
  when unique_violation then
    raise exception 'هذا اليوم محجوز مسبقًا من فريق ثاني';
end; $$;

create or replace function approve_featured_photo(p_booking_id uuid)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare v_row featured_photo_bookings;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from featured_photo_bookings where id = p_booking_id;
  if not found then raise exception 'booking not found'; end if;
  if v_row.status <> 'pending' then raise exception 'booking already % ', v_row.status; end if;

  update featured_photo_bookings set status = 'approved' where id = p_booking_id returning * into v_row;
  perform log_audit('approve_featured_photo', 'featured_photo_bookings', p_booking_id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

create or replace function reject_featured_photo(p_booking_id uuid)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare
  v_row featured_photo_bookings;
  v_team teams;
  v_new_balance integer;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from featured_photo_bookings where id = p_booking_id;
  if not found then raise exception 'booking not found'; end if;
  if v_row.status <> 'pending' then raise exception 'booking already %', v_row.status; end if;

  select * into v_team from teams where id = v_row.team_id for update;
  v_new_balance := v_team.balance_wathaq + v_row.cost_paid;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_row.team_id, v_row.cost_paid, v_new_balance, 'featured_photo_refund', 'استرجاع رسم يوم إبراز مرفوض', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_row.team_id;

  update featured_photo_bookings set status = 'rejected' where id = p_booking_id returning * into v_row;
  perform log_audit('reject_featured_photo', 'featured_photo_bookings', p_booking_id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

grant execute on function book_featured_photo(date, text) to authenticated;
grant execute on function approve_featured_photo(uuid) to authenticated;
grant execute on function reject_featured_photo(uuid) to authenticated;

-- دوري وثاق: (1) يوم الإبراز يصير فوري بلا اعتماد إداري، زي الصورة العادية بالضبط —
-- الإدارة تقدر بس تلغي حجز قائم وترجع مبلغه لو احتاجت (بعد النشر، مو قبله).
-- (2) إصلاح فرق التوقيت: current_date بالسيرفر UTC، بينما "اليوم" عند المستخدم بتوقيت
-- السعودية (UTC+3) — كان يسبب اختفاء إعلان اليوم لين توقيت السيرفر يتزامن فجرًا.
-- كل مقارنات التاريخ صارت بتوقيت الرياض بالضبط، بما يطابق حساب العميل تمامًا.
-- =============================================================================

create or replace function book_featured_photo(p_feature_date date, p_image_url text)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_team teams;
  v_new_balance integer;
  v_row featured_photo_bookings;
  v_cost constant integer := 75;
  v_today_riyadh date := (now() at time zone 'Asia/Riyadh')::date;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;
  if p_image_url is null or length(trim(p_image_url)) = 0 then raise exception 'image is required'; end if;
  if p_feature_date < v_today_riyadh or p_feature_date > v_today_riyadh + 6 then
    raise exception 'feature_date must be within the next 7 days (today included)';
  end if;

  select * into v_team from teams where id = v_team_id for update;
  v_new_balance := v_team.balance_wathaq - v_cost;
  if v_new_balance < 0 then
    raise exception 'insufficient balance: featuring a photo costs % وثاق (current balance %)', v_cost, v_team.balance_wathaq;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_team_id, -v_cost, v_new_balance, 'featured_photo_fee', 'حجز يوم إبراز', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_team_id;

  -- فوري: يُعتمد تلقائيًا لحظة الحجز، بدون انتظار الإدارة
  insert into featured_photo_bookings (team_id, feature_date, image_url, cost_paid, status, created_by)
  values (v_team_id, p_feature_date, p_image_url, v_cost, 'approved', auth.uid())
  returning * into v_row;

  perform log_audit('book_featured_photo', 'featured_photo_bookings', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
exception
  when unique_violation then
    raise exception 'هذا اليوم محجوز مسبقًا من فريق ثاني';
end; $$;

-- الإدارة تقدر تلغي أي حجز (معتمد أو معلّق) وترجع مبلغه — أداة تدخّل بعدي، مو بوابة قبلية
create or replace function reject_featured_photo(p_booking_id uuid)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare
  v_row featured_photo_bookings;
  v_team teams;
  v_new_balance integer;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from featured_photo_bookings where id = p_booking_id;
  if not found then raise exception 'booking not found'; end if;
  if v_row.status = 'rejected' then raise exception 'booking already cancelled'; end if;

  select * into v_team from teams where id = v_row.team_id for update;
  v_new_balance := v_team.balance_wathaq + v_row.cost_paid;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_row.team_id, v_row.cost_paid, v_new_balance, 'featured_photo_refund', 'استرجاع رسم يوم إبراز مُلغى', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_row.team_id;

  update featured_photo_bookings set status = 'rejected' where id = p_booking_id returning * into v_row;
  perform log_audit('reject_featured_photo', 'featured_photo_bookings', p_booking_id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

create or replace view featured_photo_public as
  select id, feature_date, image_url from featured_photo_bookings
  where status = 'approved' and feature_date = (now() at time zone 'Asia/Riyadh')::date;

-- دوري وثاق: إلغاء ميزة "يوم الإبراز" (٧٥ وثاق) بالكامل بقرار من الإدارة — الشكل
-- والتعقيد ما يستاهل. يسترجع أولًا أي مبلغ مدفوع على حجوزات لسه فعّالة (تعويضًا عادلًا
-- للفريق، لأن الحذف قرارنا احنا مو تقصير منهم)، ثم يحذف كل ما يخص الميزة.
-- الصورة العادية بـ25 وثاق (submit_team_photo) ما لها علاقة، تبقى شغالة زي ما هي.
-- =============================================================================

do $$
declare
  v_row featured_photo_bookings;
  v_team teams;
  v_new_balance integer;
begin
  for v_row in select * from featured_photo_bookings where status in ('pending', 'approved') loop
    select * into v_team from teams where id = v_row.team_id for update;
    v_new_balance := v_team.balance_wathaq + v_row.cost_paid;
    insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
    values (v_row.team_id, v_row.cost_paid, v_new_balance, 'featured_photo_refund', 'استرجاع كامل — تم إلغاء ميزة يوم الإبراز نهائيًا', v_row.created_by);
    update teams set balance_wathaq = v_new_balance where id = v_row.team_id;
  end loop;
end $$;

drop view if exists featured_photo_public;
drop view if exists featured_photo_availability;
drop function if exists book_featured_photo(date, text);
drop function if exists approve_featured_photo(uuid);
drop function if exists reject_featured_photo(uuid);
drop table if exists featured_photo_bookings;

-- دوري وثاق: لوحة "الأكثر طلبًا" — أعلى 5 لاعبين حسب إجمالي مبالغ الإعارة اللي فازوا
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
