-- دوري وثاق: (1) تفاعلات (إيموجي) على التصريحات والصور من أي كابتن أو الإدارة،
-- (2) اقتصاد صور جديد: صورة عادية بـ25 وثاق تُنشر فورًا باسم فريق الكابتن، وحجز
-- "يوم إبراز" بـ75 وثاق يُظهر صورة الفريق كإعلان يملأ الشاشة لأول من يفتح الموقع
-- ذاك اليوم، لمدة عشر ثوانٍ فقط وبدون إمكانية إغلاقه يدويًا — يحتاج اعتماد الإدارة
-- قبل ما يظهر فعليًا (خطورة أعلى من الصورة العادية لأنه يُفرض على الجميع).
-- =============================================================================

-- ============ 1) التفاعلات ============

create table content_reactions (
  id            uuid primary key default gen_random_uuid(),
  content_type  text not null check (content_type in ('announcement', 'photo')),
  content_id    uuid not null,
  emoji         text not null check (emoji in ('❤️', '🔥', '👏', '😂')),
  reacted_by    uuid not null references profiles(id),
  created_at    timestamptz not null default now(),
  unique (content_type, content_id, reacted_by, emoji)
);
create index idx_reactions_content on content_reactions(content_type, content_id);

alter table content_reactions enable row level security;
create policy sel_reactions on content_reactions for select to authenticated, anon using (true);
grant select on content_reactions to anon;

-- كتابة مباشرة بدون RPC: عملية غير حساسة ماليًا ولا تؤثر على حالة اللعبة، كل مستخدم
-- يتحكم بصفه هو فقط (reacted_by = خودو) — لا حاجة لدالة SECURITY DEFINER هنا.
create policy ins_reactions on content_reactions for insert to authenticated
  with check (reacted_by = auth.uid());
create policy del_reactions on content_reactions for delete to authenticated
  using (reacted_by = auth.uid());

grant select, insert, delete on content_reactions to authenticated;

-- ============ 2) توسعة أسباب السجل المالي ============

alter type ledger_reason add value if not exists 'photo_fee';
alter type ledger_reason add value if not exists 'featured_photo_fee';
alter type ledger_reason add value if not exists 'featured_photo_refund';

-- ============ 3) صورة عادية من كابتن — 25 وثاق، تُنشر فورًا بلا اعتماد ============

create or replace function submit_team_photo(p_image_url text, p_caption text default null)
returns league_photos
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_team teams;
  v_new_balance integer;
  v_row league_photos;
  v_cost constant integer := 25;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;
  if p_image_url is null or length(trim(p_image_url)) = 0 then raise exception 'image is required'; end if;

  select * into v_team from teams where id = v_team_id for update;
  v_new_balance := v_team.balance_wathaq - v_cost;
  if v_new_balance < 0 then
    raise exception 'insufficient balance: posting a photo costs % وثاق (current balance %)', v_cost, v_team.balance_wathaq;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_team_id, -v_cost, v_new_balance, 'photo_fee', 'نشر صورة فريق', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_team_id;

  insert into league_photos (image_url, caption, team_id, created_by)
  values (p_image_url, nullif(trim(coalesce(p_caption, '')), ''), v_team_id, auth.uid())
  returning * into v_row;

  perform log_audit('submit_team_photo', 'league_photos', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

grant execute on function submit_team_photo(text, text) to authenticated;

-- ============ 4) حجز "يوم الإبراز" — 75 وثاق، يحتاج اعتماد الإدارة ============

create table featured_photo_bookings (
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references teams(id),
  feature_date  date not null,
  image_url     text not null,
  cost_paid     integer not null default 75,
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_by    uuid references profiles(id),
  created_at    timestamptz not null default now()
);

-- تاريخ واحد يقبل حجز واحد فقط طالما لسه معلّق أو معتمد؛ لو رُفض يتحرر التاريخ من جديد
create unique index uq_featured_date_active on featured_photo_bookings(feature_date)
  where status in ('pending', 'approved');

alter table featured_photo_bookings enable row level security;

-- الجدول الخام: الإدارة فقط، أو الفريق صاحب الحجز نفسه (يشوف حالة حجوزاته)
create policy sel_featured_raw on featured_photo_bookings for select to authenticated using (
  is_admin() or team_id = my_team_id()
);

-- عرض عام للتوفّر (بدون كشف الصورة ولا صاحب الحجز) — يستخدمه أي كابتن يختار يوم فاضي
create view featured_photo_availability as
  select feature_date from featured_photo_bookings where status in ('pending', 'approved');
grant select on featured_photo_availability to authenticated;

-- عرض عام لإعلان اليوم المعتمد فقط — هذا اللي يقرأه شاشة الدخول الكاملة
create view featured_photo_public as
  select id, feature_date, image_url from featured_photo_bookings
  where status = 'approved' and feature_date = current_date;
grant select on featured_photo_public to anon, authenticated;

create or replace function book_featured_photo(p_feature_date date, p_image_url text)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare
  v_team_id uuid;
  v_team teams;
  v_new_balance integer;
  v_row featured_photo_bookings;
  v_cost constant integer := 75;
begin
  v_team_id := my_team_id();
  if v_team_id is null then raise exception 'forbidden: team captains only'; end if;
  if p_image_url is null or length(trim(p_image_url)) = 0 then raise exception 'image is required'; end if;
  if p_feature_date < current_date or p_feature_date > current_date + 6 then
    raise exception 'feature_date must be within the next 7 days (today included)';
  end if;

  select * into v_team from teams where id = v_team_id for update;
  v_new_balance := v_team.balance_wathaq - v_cost;
  if v_new_balance < 0 then
    raise exception 'insufficient balance: featuring a photo costs % وثاق (current balance %)', v_cost, v_team.balance_wathaq;
  end if;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_team_id, -v_cost, v_new_balance, 'featured_photo_fee', 'حجز يوم إبراز', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_team_id;

  insert into featured_photo_bookings (team_id, feature_date, image_url, cost_paid, created_by)
  values (v_team_id, p_feature_date, p_image_url, v_cost, auth.uid())
  returning * into v_row;

  perform log_audit('book_featured_photo', 'featured_photo_bookings', v_row.id::text, null, to_jsonb(v_row));
  return v_row;
exception
  when unique_violation then
    raise exception 'هذا اليوم محجوز مسبقًا من فريق ثاني';
end; $$;

create or replace function approve_featured_photo(p_booking_id uuid)
returns featured_photo_bookings
language plpgsql security definer set search_path = public as $$
declare v_row featured_photo_bookings;
begin
  if not is_admin() then raise exception 'forbidden: admin only'; end if;
  select * into v_row from featured_photo_bookings where id = p_booking_id;
  if not found then raise exception 'booking not found'; end if;
  if v_row.status <> 'pending' then raise exception 'booking already % ', v_row.status; end if;

  update featured_photo_bookings set status = 'approved' where id = p_booking_id returning * into v_row;
  perform log_audit('approve_featured_photo', 'featured_photo_bookings', p_booking_id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

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
  if v_row.status <> 'pending' then raise exception 'booking already %', v_row.status; end if;

  select * into v_team from teams where id = v_row.team_id for update;
  v_new_balance := v_team.balance_wathaq + v_row.cost_paid;

  insert into balance_ledger (team_id, delta, balance_after, reason, note, created_by)
  values (v_row.team_id, v_row.cost_paid, v_new_balance, 'featured_photo_refund', 'استرجاع رسم يوم إبراز مرفوض', auth.uid());
  update teams set balance_wathaq = v_new_balance where id = v_row.team_id;

  update featured_photo_bookings set status = 'rejected' where id = p_booking_id returning * into v_row;
  perform log_audit('reject_featured_photo', 'featured_photo_bookings', p_booking_id::text, null, to_jsonb(v_row));
  return v_row;
end; $$;

grant execute on function book_featured_photo(date, text) to authenticated;
grant execute on function approve_featured_photo(uuid) to authenticated;
grant execute on function reject_featured_photo(uuid) to authenticated;
