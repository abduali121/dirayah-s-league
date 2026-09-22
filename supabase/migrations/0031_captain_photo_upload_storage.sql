-- دوري وثاق: سياسة رفع "announcement-images" كانت محصورة بالإدارة فقط (0018) — من يوم
-- صار الكابتن يرفع صوره هو بنفسه (صورة عادية بـ25 أو حجز يوم إبراز بـ75)، لازم يقدر
-- يرفع للـ bucket نفسه، مو بس الإدارة. الحذف يبقى للإدارة فقط.
-- =============================================================================

create policy "captains can upload photos"
on storage.objects for insert to authenticated
with check (bucket_id = 'announcement-images' and my_team_id() is not null);
