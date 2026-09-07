-- دوري دراية: يسمح لكابتن الفريق ينشر تصريح باسم فريقه هو بس (لا يقدر ينتحل فريق
-- ثاني ولا ينشر باسم "الإدارة")، عشان يرجع للموقع بشكل متكرر. الإدارة تبقى تقدر
-- تنشر باسم أي فريق أو باسمها هي كما هو. نفس القاعدة على الحذف: كل طرف يحذف بس اللي نشره.
-- =============================================================================

create or replace function create_announcement(p_body text, p_team_id uuid default null)
returns league_announcements
language plpgsql security definer set search_path = public as $$
declare
  v_row league_announcements;
  v_caller_team_id uuid;
begin
  if not is_admin() then
    v_caller_team_id := my_team_id();
    if v_caller_team_id is null then
      raise exception 'forbidden: admins or team captains only';
    end if;
    if p_team_id is distinct from v_caller_team_id then
      raise exception 'captains can only publish on behalf of their own team';
    end if;
  end if;

  if p_body is null or length(trim(p_body)) = 0 then raise exception 'body is required'; end if;

  insert into league_announcements (body, team_id, created_by)
  values (trim(p_body), p_team_id, auth.uid())
  returning * into v_row;
  perform log_audit('create_announcement', 'league_announcements', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

create or replace function delete_announcement(p_announcement_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_row league_announcements;
  v_caller_team_id uuid;
begin
  select * into v_row from league_announcements where id = p_announcement_id;
  if not found then raise exception 'announcement not found'; end if;

  if not is_admin() then
    v_caller_team_id := my_team_id();
    if v_caller_team_id is null or v_row.team_id is distinct from v_caller_team_id then
      raise exception 'forbidden: you can only delete your own team''s announcements';
    end if;
  end if;

  delete from league_announcements where id = p_announcement_id;
  perform log_audit('delete_announcement', 'league_announcements', p_announcement_id::text, to_jsonb(v_row), null);
end; $$;
