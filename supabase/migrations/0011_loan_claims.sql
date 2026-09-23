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
