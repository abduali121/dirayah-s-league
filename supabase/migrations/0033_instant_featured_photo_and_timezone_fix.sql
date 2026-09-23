-- دوري دراية: (1) يوم الإبراز يصير فوري بلا اعتماد إداري، زي الصورة العادية بالضبط —
-- الإدارة تقدر بس تلغي حجز قائم وترجع مبلغه لو احتاجت (بعد النشر، مو قبله).
-- (2) إصلاح فرق التوقيت: current_date بالسيرفر UTC، بينما "اليوم" عند المستخدم بتوقيت
-- السعودية (UTC+3) — كان يسبب اختفاء إعلان اليوم لين توقيت السيرفر يتزامن فجرًا.
-- كل مقارنات التاريخ صارت بتوقيت الرياض بالضبط، بما يطابق حساب العميل تمامًا.
-- =============================================================================

create or replace function book_featured_photo(p_feature_date date, p_image_url text)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_team teams;
  v_new_balance integer;
  v_row featured_photo_bookings;
  v_cost constant integer := 75;
  v_today_riyadh date := (now() at time zone 'Asia/Riyadh')::date;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;
  if p_image_url is null or length(trim(p_image_url)) = 0 then raise exception 'image is required'; end if;
  if p_feature_date < v_today_riyadh or p_feature_date > v_today_riyadh + 6 then
    raise exception 'feature_date must be within the next 7 days (today included)';
  end if;

  select * into v_team from teams where id = v_team_id for update;
  v_new_balance := v_team.balance_daraya - v_cost;
  if v_new_balance < 0 then
    raise exception 'insufficient balance: featuring a photo costs % دراية (current balance %)', v_cost, v_team.balance_daraya;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_team_id, -v_cost, v_new_balance, 'featured_photo_fee', 'حجز يوم إبراز', auth.uid());
  update teams set balance_daraya = v_new_balance where id = v_team_id;

  -- فوري: يُعتمد تلقائيًا لحظة الحجز، بدون انتظار الإدارة
  insert into featured_photo_bookings (team_id, feature_date, image_url, cost_paid, status, created_by)
  values (v_team_id, p_feature_date, p_image_url, v_cost, 'approved', auth.uid())
  returning * into v_row;

  perform log_audit('book_featured_photo', 'featured_photo_bookings', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
exception
  when unique_violation then
    raise exception 'هذا اليوم محجوز مسبقًا من فريق ثاني';
end; $$;

-- الإدارة تقدر تلغي أي حجز (معتمد أو معلّق) وترجع مبلغه — أداة تدخّل بعدي، مو بوابة قبلية
create or replace function reject_featured_photo(p_booking_id uuid)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare
  v_row featured_photo_bookings;
  v_team teams;
  v_new_balance integer;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from featured_photo_bookings where id = p_booking_id;
  if not found then raise exception 'booking not found'; end if;
  if v_row.status = 'rejected' then raise exception 'booking already cancelled'; end if;

  select * into v_team from teams where id = v_row.team_id for update;
  v_new_balance := v_team.balance_daraya + v_row.cost_paid;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_row.team_id, v_row.cost_paid, v_new_balance, 'featured_photo_refund', 'استرجاع رسم يوم إبراز مُلغى', auth.uid());
  update teams set balance_daraya = v_new_balance where id = v_row.team_id;

  update featured_photo_bookings set status = 'rejected' where id = p_booking_id returning * into v_row;
  perform log_audit('reject_featured_photo', 'featured_photo_bookings', p_booking_id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

create or replace view featured_photo_public as
  select id, feature_date, image_url from featured_photo_bookings
  where status = 'approved' and feature_date = (now() at time zone 'Asia/Riyadh')::date;
