-- دوري دراية: تفاعل واحد بس لكل شخص (حساب أو ضيف) على نفس التصريح/الصورة — قبل كذا
-- كان يقدر يضغط الأربع إيموجيات مع بعض على نفس المحتوى، يعني شخص وحد يسجّل كأربع
-- تفاعلات! هذا كان يسهّل الوصول لدرجات مكافأة التفاعل بشكل مصطنع. الحين: يضغط إيموجي
-- ثاني ينقل تفاعله له (يشيل القديم)، ويضغط نفس إيموجيه الحالي يشيل تفاعله بالكامل.
-- =============================================================================

-- تنظيف البيانات القديمة أول: لو نفس الشخص عنده أكثر من تفاعل على نفس المحتوى
-- (بسبب الثغرة)، نحتفظ بأقدم واحد بس ونحذف الباقي، قبل ما نضيف القيد الأصرم
delete from content_reactions where id in (
  select id from (
    select id, row_number() over (
      partition by content_type, content_id, coalesce(reacted_by::text, guest_key)
      order by created_at asc, id asc
    ) as rn
    from content_reactions
  ) ranked where rn > 1
);

drop index if exists uq_reaction_identity;
create unique index uq_reaction_identity on content_reactions(
  content_type, content_id, coalesce(reacted_by::text, guest_key)
);

-- يحتاج تحديث سطر تفاعله الحالي (يبدّل الإيموجي) بدل حذف وإدراج من جديد
create policy upd_reactions_auth on content_reactions for update to authenticated
  using (reacted_by = auth.uid())
  with check (reacted_by = auth.uid() and guest_key is null);
create policy upd_reactions_guest on content_reactions for update to anon
  using (reacted_by is null and guest_key is not null)
  with check (reacted_by is null and guest_key is not null);

grant update on content_reactions to anon, authenticated;
