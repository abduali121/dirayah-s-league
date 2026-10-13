-- دوري دراية: الكابتن هو اللي يحط مبلغ فريقه بالمباراة (التحدّي)
-- ============================================================
-- • الإدارة تنشئ المباراة بدون مبالغ (team_a_stake / team_b_stake = null).
-- • كل كابتن يثبّت مبلغ فريقه من صفحة المباراة: ما يقل عن مجموع تعاقدات فريقه بالمباراة،
--   وما يزيد عن رصيده الحالي. مبلغه يبقى سريًا (جدول خاص) لين يثبّت الكابتنان.
-- • أول ما يثبّتون الاثنين ينكشف الرقمان معًا وينتقلان لأعمدة المباراة (اللي يقرأها بقية الموقع).
-- • ما تنعتمد نتيجة مباراة قبل ما ينكشف الرقمان.
-- • المباريات القديمة اللي لها مبالغ جاهزة ما تتأثر.

alter table matches alter column team_a_stake drop not null;
alter table matches alter column team_b_stake drop not null;

create table match_stake_offers (
  match_id   uuid not null references matches(id) on delete cascade,
  team_id    uuid not null references teams(id),
  amount     integer not null check (amount > 0),
  updated_at timestamptz not null default now(),
  primary key (match_id, team_id)
);
alter table match_stake_offers enable row level security;
-- المبلغ المخفي يشوفه فقط كابتن الفريق نفسه والإدارة؛ الكتابة بس عبر الدالة
create policy sel_stake_offers on match_stake_offers for select to authenticated
  using (is_admin() or team_id = my_team_id());

-- حالة فقط (مين ثبّت)، بدون المبلغ — للعرض العام "ثبّت / ينتظر"
create view match_stake_status as select match_id, team_id from match_stake_offers;
grant select on match_stake_status to anon, authenticated;

create or replace function set_match_stake(p_match_id uuid, p_amount integer)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_team_id uuid;
  v_floor integer;
  v_balance integer;
  v_revealed boolean := false;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;

  select * into v_match from matches where id = p_match_id for update;
  if not found then raise exception 'match not found'; end if;
  if v_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'only the two teams playing this match may set its stake';
  end if;
  if v_match.status <> 'scheduled' then
    raise exception 'المباراة ما عادت مجدولة، ما تقدر تغيّر المبلغ';
  end if;
  if (v_team_id = v_match.team_a_id and v_match.team_a_stake is not null)
     or (v_team_id = v_match.team_b_id and v_match.team_b_stake is not null) then
    raise exception 'المبلغ انكشف وتثبّت، تواصل مع الإدارة لو تبي تعدّل';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'اكتب مبلغ صحيح'; end if;

  select coalesce(sum(winning_bid_amount), 0) into v_floor
  from match_loans where match_id = p_match_id and borrowing_team_id = v_team_id;
  if p_amount < v_floor then
    raise exception 'الحد الأدنى % دراية (مجموع تعاقدات فريقك بهذي المباراة)', v_floor;
  end if;

  select balance_daraya into v_balance from teams where id = v_team_id;
  if p_amount > v_balance then
    raise exception 'المبلغ أكبر من رصيد فريقك (% دراية)', v_balance;
  end if;

  insert into match_stake_offers (match_id, team_id, amount) values (p_match_id, v_team_id, p_amount)
  on conflict (match_id, team_id) do update set amount = excluded.amount, updated_at = now();

  if (select count(*) from match_stake_offers where match_id = p_match_id) = 2 then
    update matches set
      team_a_stake = (select amount from match_stake_offers where match_id = p_match_id and team_id = v_match.team_a_id),
      team_b_stake = (select amount from match_stake_offers where match_id = p_match_id and team_id = v_match.team_b_id)
    where id = p_match_id;
    v_revealed := true;
  end if;

  perform log_audit('set_match_stake', 'matches', p_match_id::text, null,
    jsonb_build_object('team_id', v_team_id, 'revealed', v_revealed));
  return jsonb_build_object('revealed', v_revealed);
end; $$;
grant execute on function set_match_stake(uuid, integer) to authenticated;

-- تعديل الإدارة للمباراة: المبالغ اختيارية (فاضية = الكباتن يحطونها)، وأي تعديل يصفّر مبالغ الكباتن المخفية
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
  delete from match_stake_offers where match_id = p_match_id;
  update matches set team_a_id = p_team_a_id, team_b_id = p_team_b_id,
    team_a_stake = p_team_a_stake, team_b_stake = p_team_b_stake
  where id = p_match_id
  returning * into v_after;
  perform log_audit('edit_match', 'matches', p_match_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

-- حارس: ما تنعتمد نتيجة قبل ما ينكشف المبلغان
create or replace function guard_match_stakes_before_complete() returns trigger
language plpgsql as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed'
     and (new.team_a_stake is null or new.team_b_stake is null) then
    raise exception 'ما تنعتمد النتيجة قبل ما يثبّت الكابتنان مبلغيهما';
  end if;
  return new;
end; $$;
create trigger trg_guard_match_stakes before update on matches
  for each row execute function guard_match_stakes_before_complete();
