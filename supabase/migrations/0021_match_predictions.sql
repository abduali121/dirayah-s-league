-- دوري دراية: توقعات المباريات — كباتن الفرق غير المشاركة بمباراة معيّنة يقدر أي
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

    update teams set balance_daraya = balance_daraya - v_loan.winning_bid_amount where id = v_loan.borrowing_team_id;

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
        (select balance_daraya from teams where id = v_prediction.predicting_team_id) + v_match.prediction_reward,
        'prediction_reward', p_match_id, auth.uid());

      update teams set balance_daraya = balance_daraya + v_match.prediction_reward where id = v_prediction.predicting_team_id;
    end loop;
  end if;

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
