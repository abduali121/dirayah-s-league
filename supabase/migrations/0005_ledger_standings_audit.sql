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
