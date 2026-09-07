-- دوري دراية: حذف فريق — مسموح فقط لو ما عنده لاعبون ولا مباريات بعد (حماية من فقد بيانات حقيقية)
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
