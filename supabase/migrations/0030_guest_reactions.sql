-- دوري وثاق: يسمح لأي زائر (حتى بدون تسجيل دخول) يتفاعل، مو بس الكباتن/الإدارة —
-- عبر معرّف عشوائي يُخزَّن بمتصفحه (guest_key) بدل حساب حقيقي. مُعاد إنشاء الجدول
-- بالكامل لأن محاولة الإنشاء الأولى (0029) لم تكتمل على قاعدة البيانات.
-- =============================================================================

drop table if exists content_reactions cascade;

create table content_reactions (
  id            uuid primary key default gen_random_uuid(),
  content_type  text not null check (content_type in ('announcement', 'photo')),
  content_id    uuid not null,
  emoji         text not null check (emoji in ('❤️', '🔥', '👏', '😂')),
  reacted_by    uuid references profiles(id),   -- تسجيل دخول حقيقي
  guest_key     text,                            -- زائر بدون تسجيل دخول
  created_at    timestamptz not null default now(),
  check (reacted_by is not null or guest_key is not null)
);
create index idx_reactions_content on content_reactions(content_type, content_id);

-- هوية واحدة (حساب حقيقي أو ضيف) تقدر تحط نفس الإيموجي مرة وحدة بس على نفس العنصر
create unique index uq_reaction_identity on content_reactions(
  content_type, content_id, emoji, coalesce(reacted_by::text, guest_key)
);

alter table content_reactions enable row level security;

create policy sel_reactions on content_reactions for select to authenticated, anon using (true);

-- تسجيل دخول حقيقي: يتحكم بصفه هو بس (reacted_by = هويته الموثّقة)
create policy ins_reactions_auth on content_reactions for insert to authenticated
  with check (reacted_by = auth.uid() and guest_key is null);
create policy del_reactions_auth on content_reactions for delete to authenticated
  using (reacted_by = auth.uid());

-- زائر بدون تسجيل دخول: ما فيه هوية موثّقة أصلًا، فقط يضمن إنه ما ينتحل صف حساب حقيقي
create policy ins_reactions_guest on content_reactions for insert to anon
  with check (reacted_by is null and guest_key is not null);
create policy del_reactions_guest on content_reactions for delete to anon
  using (reacted_by is null and guest_key is not null);

grant select, insert, delete on content_reactions to anon, authenticated;
