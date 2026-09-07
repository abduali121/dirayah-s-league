-- دوري دراية: نقل ملكية لاعب بين الفرق بشكل دائم (مختلف عن الإعارة المؤقتة لمباراة
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
