-- دوري دراية: تحكم كامل للإدارة بالتعاقدات — إضافة تعاقد مباشر (بدون طلب كابتن)،
-- تعديل تعاقد موجود (الفريق المستعير/اللاعب/المبلغ)، وحذفه. كلها محصورة بمباريات لسه
-- ما اتعتمدت نتيجتها (جدولة/جارية)؛ المباراة المعتمدة فيها أثر مالي فعلي، لازم "تراجع
-- عن النتيجة" أولًا زي حذف المباراة. الإدارة تتجاوز قفل التعاقدات (القفل للكباتن بس).
-- =============================================================================

create or replace function admin_create_loan(
  p_match_id uuid, p_player_id uuid, p_borrowing_team_id uuid, p_amount integer
) returns match_loans
language plpgsql security definer set search_path = public as $$
declare
  v_match matches;
  v_player players;
  v_claim loan_claims;
  v_loan match_loans;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_match from matches where id = p_match_id for update;
  if not found then raise exception 'match not found'; end if;
  if v_match.status in ('completed', 'cancelled') then
    raise exception 'cannot edit loans of a % match — undo its result first', v_match.status;
  end if;
  if p_borrowing_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'the borrowing team must be one of the two teams in this match';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;

  select * into v_player from players where id = p_player_id;
  if not found then raise exception 'player not found'; end if;
  if v_player.original_team_id = p_borrowing_team_id then
    raise exception 'a team cannot borrow its own player';
  end if;
  if exists (select 1 from match_loans where match_id = p_match_id and player_id = p_player_id) then
    raise exception 'this player is already loaned for this match';
  end if;

  -- لا يوجد تعاقد فعلي لهذا اللاعب بهذي المباراة، فأي طلب معلّق/معتمد قديم عنه يُرفض (يتجنب تعارض الفهرس الفريد)
  update loan_claims set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
  where match_id = p_match_id and player_id = p_player_id and status in ('pending', 'approved');

  insert into loan_claims (match_id, player_id, claiming_team_id, original_team_id, amount, status, note, reviewed_by, reviewed_at)
  values (p_match_id, p_player_id, p_borrowing_team_id, v_player.original_team_id, p_amount, 'approved', 'تعاقد مباشر من الإدارة', auth.uid(), now())
  returning * into v_claim;

  insert into match_loans (match_id, player_id, original_team_id, borrowing_team_id, claim_id, winning_bid_amount)
  values (p_match_id, p_player_id, v_player.original_team_id, p_borrowing_team_id, v_claim.id, p_amount)
  returning * into v_loan;

  perform log_audit('admin_create_loan', 'match_loans', v_loan.id::text, null, to_jsonb(v_loan));
  return v_loan;
end; $$;

create or replace function admin_update_loan(
  p_loan_id uuid, p_player_id uuid, p_borrowing_team_id uuid, p_amount integer
) returns match_loans
language plpgsql security definer set search_path = public as $$
declare
  v_before match_loans;
  v_after match_loans;
  v_match matches;
  v_player players;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_before from match_loans where id = p_loan_id for update;
  if not found then raise exception 'loan not found'; end if;

  select * into v_match from matches where id = v_before.match_id for update;
  if v_match.status in ('completed', 'cancelled') then
    raise exception 'cannot edit loans of a % match — undo its result first', v_match.status;
  end if;
  if p_borrowing_team_id not in (v_match.team_a_id, v_match.team_b_id) then
    raise exception 'the borrowing team must be one of the two teams in this match';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;

  select * into v_player from players where id = p_player_id;
  if not found then raise exception 'player not found'; end if;
  if v_player.original_team_id = p_borrowing_team_id then
    raise exception 'a team cannot borrow its own player';
  end if;
  if exists (select 1 from match_loans where match_id = v_before.match_id and player_id = p_player_id and id <> p_loan_id) then
    raise exception 'this player is already loaned for this match';
  end if;

  -- تغيّر اللاعب أو الفريق المستعير: التشكيلة القديمة ما تنطبق، نشيل اللاعب القديم منها
  if v_before.player_id <> p_player_id or v_before.borrowing_team_id <> p_borrowing_team_id then
    delete from match_lineups
    where match_id = v_before.match_id and player_id = v_before.player_id and team_id = v_before.borrowing_team_id;
  end if;

  update loan_claims set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
  where match_id = v_before.match_id and player_id = p_player_id and status in ('pending', 'approved')
    and id is distinct from v_before.claim_id;

  update match_loans set
    player_id = p_player_id, original_team_id = v_player.original_team_id,
    borrowing_team_id = p_borrowing_team_id, winning_bid_amount = p_amount
  where id = p_loan_id
  returning * into v_after;

  if v_after.claim_id is not null then
    update loan_claims set
      player_id = p_player_id, original_team_id = v_player.original_team_id,
      claiming_team_id = p_borrowing_team_id, amount = p_amount
    where id = v_after.claim_id;
  end if;

  perform log_audit('admin_update_loan', 'match_loans', p_loan_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;

create or replace function admin_delete_loan(p_loan_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_loan match_loans;
  v_match matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_loan from match_loans where id = p_loan_id for update;
  if not found then raise exception 'loan not found'; end if;

  select * into v_match from matches where id = v_loan.match_id for update;
  if v_match.status in ('completed', 'cancelled') then
    raise exception 'cannot delete loans of a % match — undo its result first', v_match.status;
  end if;

  delete from match_lineups
  where match_id = v_loan.match_id and player_id = v_loan.player_id and team_id = v_loan.borrowing_team_id;

  delete from match_loans where id = p_loan_id;

  -- نرفض الطلب المرتبط عشان ما يبقى "معتمد" بدون تعاقد فعلي (يمنع تسجيل اللاعب من جديد)
  if v_loan.claim_id is not null then
    update loan_claims set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
    where id = v_loan.claim_id;
  end if;

  perform log_audit('admin_delete_loan', 'match_loans', p_loan_id::text, to_jsonb(v_loan), null);
end; $$;

grant execute on function admin_create_loan(uuid, uuid, uuid, integer) to authenticated;
grant execute on function admin_update_loan(uuid, uuid, uuid, integer) to authenticated;
grant execute on function admin_delete_loan(uuid) to authenticated;
