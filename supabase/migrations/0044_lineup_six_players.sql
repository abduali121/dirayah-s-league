-- دوري دراية: التشكيلة 6 لاعبين بالضبط
-- ============================================================
-- • التشكيلة 6 لاعبين بالضبط: ما تنحفظ بأقل ولا بأكثر (كابتن أو إدارة).
-- • الكابتن ما يثبّت مبلغ المباراة إلا لو تشكيلة فريقه 6 بالضبط.
-- يستبدل set_lineup (0007) و set_match_stake (0042/0043) بنفس التواقيع، فيصلح اللصق بأي ترتيب.
-- ============================================================

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

  if coalesce(array_length(p_player_ids, 1), 0) <> 6 then
    raise exception 'التشكيلة لازم تكون 6 لاعبين بالضبط (اخترت %)', coalesce(array_length(p_player_ids, 1), 0);
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

create or replace function set_match_stake(p_match_id uuid, p_amount integer)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_team_id uuid;
  v_floor integer;
  v_balance integer;
  v_revealed boolean := false;
  v_lineup_count integer;
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

  select count(*) into v_lineup_count from match_lineups where match_id = p_match_id and team_id = v_team_id;
  if v_lineup_count <> 6 then
    raise exception 'لازم تدخل تشكيلة من 6 لاعبين بالضبط قبل ما تثبّت المبلغ (الحالي: %)', v_lineup_count;
  end if;

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
