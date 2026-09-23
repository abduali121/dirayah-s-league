-- دوري دراية: حذف مباراة أُضيفت بالغلط — ممنوع على المباريات المُعتمدة (فيها أثر مالي
-- حقيقي بالفعل) — لازم "تصحيح/إلغاء الاعتماد" أولًا، وبعدها تقدر تحذفها. أي مباراة
-- لسه غير معتمدة يُحذف معها كل ما يرتبط بها (توقعات، صفقات إعارة، تشكيلات، أحداث).
-- =============================================================================

create or replace function delete_match(p_match_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_match matches;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;

  select * into v_match from matches where id = p_match_id;
  if not found then raise exception 'match not found'; end if;
  if v_match.status = 'completed' then
    raise exception 'cannot delete a completed match — undo its result first, then delete it';
  end if;

  delete from match_predictions where match_id = p_match_id;
  delete from loan_claims where match_id = p_match_id;
  delete from match_loans where match_id = p_match_id;
  delete from match_lineups where match_id = p_match_id;
  delete from match_events where match_id = p_match_id;
  delete from balance_ledger where match_id = p_match_id;
  delete from matches where id = p_match_id;

  perform log_audit('delete_match', 'matches', p_match_id::text, to_jsonb(v_match), null);
end; $$;

grant execute on function delete_match(uuid) to authenticated;
