-- دوري وثاق: إلغاء ميزة "يوم الإبراز" (٧٥ وثاق) بالكامل بقرار من الإدارة — الشكل
-- والتعقيد ما يستاهل. يسترجع أولًا أي مبلغ مدفوع على حجوزات لسه فعّالة (تعويضًا عادلًا
-- للفريق، لأن الحذف قرارنا احنا مو تقصير منهم)، ثم يحذف كل ما يخص الميزة.
-- الصورة العادية بـ25 وثاق (submit_team_photo) ما لها علاقة، تبقى شغالة زي ما هي.
-- =============================================================================

do $$
declare
  v_row featured_photo_bookings;
  v_team teams;
  v_new_balance integer;
begin
  for v_row in select * from featured_photo_bookings where status in ('pending', 'approved') loop
    select * into v_team from teams where id = v_row.team_id for update;
    v_new_balance := v_team.balance_wathaq + v_row.cost_paid;
    insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
    values (v_row.team_id, v_row.cost_paid, v_new_balance, 'featured_photo_refund', 'استرجاع كامل — تم إلغاء ميزة يوم الإبراز نهائيًا', v_row.created_by);
    update teams set balance_wathaq = v_new_balance where id = v_row.team_id;
  end loop;
end $$;

drop view if exists featured_photo_public;
drop view if exists featured_photo_availability;
drop function if exists book_featured_photo(date, text);
drop function if exists approve_featured_photo(uuid);
drop function if exists reject_featured_photo(uuid);
drop table if exists featured_photo_bookings;
