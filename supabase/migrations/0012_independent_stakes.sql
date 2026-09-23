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
