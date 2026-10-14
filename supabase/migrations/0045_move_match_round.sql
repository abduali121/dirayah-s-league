-- دوري دراية: الإدارة تنقل المباراة من جولة لجولة (أي مباراة، حتى المنتهية)
-- نقل الجولة تصنيف فقط: ما يمس أي رصيد ولا نتيجة ولا مبلغ.
-- ============================================================

create or replace function admin_set_match_week(p_match_id uuid, p_week_id uuid)
returns matches
language plpgsql security definer set search_path = public as $$
declare
  v_before matches;
  v_after matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_before from matches where id = p_match_id for update;
  if not found then raise exception 'match not found'; end if;
  if not exists (select 1 from weeks where id = p_week_id) then raise exception 'round not found'; end if;
  if v_before.week_id = p_week_id then return v_before; end if;

  update matches set week_id = p_week_id where id = p_match_id returning * into v_after;
  perform log_audit('admin_set_match_week', 'matches', p_match_id::text, to_jsonb(v_before), to_jsonb(v_after));
  return v_after;
end; $$;
grant execute on function admin_set_match_week(uuid, uuid) to authenticated;
