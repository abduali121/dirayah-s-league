-- دوري دراية: الأدوار والفرق
-- ==========================

create extension if not exists pgcrypto;

create type user_role as enum ('super_admin', 'team_captain');

create table teams (
  id               uuid primary key default gen_random_uuid(),
  name             text not null unique,
  logo_url         text,
  primary_color    text not null default '#1a3a5c',
  secondary_color  text not null default '#b8952a',
  balance_daraya   integer not null default 1000,
  created_at       timestamptz not null default now()
);
alter table teams add constraint chk_balance_nonnegative check (balance_daraya >= 0);

create table profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  role            user_role not null default 'team_captain',
  team_id         uuid references teams(id),
  display_name    text not null,
  created_at      timestamptz not null default now(),
  constraint chk_role_team_consistency check (
    (role = 'team_captain' and team_id is not null) or
    (role = 'super_admin' and team_id is null)
  )
);
create unique index uq_profiles_one_captain_per_team
  on profiles(team_id) where role = 'team_captain';

-- دوال مساعدة تُستخدم داخل سياسات RLS ودوال RPC
create or replace function is_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from profiles where id = auth.uid() and role = 'super_admin'
  );
$$;

create or replace function my_team_id()
returns uuid
language sql stable security definer set search_path = public as $$
  select team_id from profiles where id = auth.uid();
$$;

-- عند إنشاء مستخدم جديد في Supabase Auth (يُنشئه المدير من لوحة Supabase أو عبر دعوة)،
-- تُنشأ صف profile تلقائيًا اعتمادًا على بيانات وصفية (raw_user_meta_data) يمررها المدير:
-- { "role": "team_captain", "team_id": "...", "display_name": "..." }
create or replace function handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, role, team_id, display_name)
  values (
    new.id,
    coalesce((new.raw_user_meta_data->>'role')::user_role, 'team_captain'),
    nullif(new.raw_user_meta_data->>'team_id', '')::uuid,
    coalesce(new.raw_user_meta_data->>'display_name', new.email)
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

alter table teams enable row level security;
alter table profiles enable row level security;
