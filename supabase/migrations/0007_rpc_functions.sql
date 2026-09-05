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
