-- Extensions
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- Profile for each auth user
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, username, display_name)
  values (new.id, new.email, split_part(new.email,'@',1))
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Enums
do $$ begin
  create type public.media_kind as enum ('SERIES','MOVIE');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.list_status as enum ('WATCHING','PLAN','REWATCH','WAITING','COMPLETED');
exception when duplicate_object then null; end $$;

-- Anime entries per user
create table if not exists public.entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  kind public.media_kind not null default 'SERIES',
  status public.list_status not null,
  season int,
  episode int,
  absolute_episode int,
  notes text,
  tags text[] not null default '{}',
  rating smallint check (rating between 1 and 10),
  image_url text,                    -- cover image URL (preferred by app)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Updated_at trigger
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

drop trigger if exists t_entries_updated on public.entries;
create trigger t_entries_updated
before update on public.entries
for each row execute procedure public.set_updated_at();

-- Helpful indexes
create index if not exists idx_entries_user on public.entries(user_id);
create index if not exists idx_entries_user_status on public.entries(user_id, status);
create index if not exists idx_entries_user_title on public.entries(lower(title), user_id);
create index if not exists idx_entries_updated on public.entries(user_id, updated_at desc);

-- Enable RLS
alter table public.profiles enable row level security;
alter table public.entries  enable row level security;

-- Profiles policies: user can see/update self
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
on public.profiles for select
using (id = auth.uid());

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
on public.profiles for update
using (id = auth.uid())
with check (id = auth.uid());

-- Entries policies: CRUD only for owner
drop policy if exists "entries_read_own" on public.entries;
create policy "entries_read_own"
on public.entries for select
using (user_id = auth.uid());

drop policy if exists "entries_insert_own" on public.entries;
create policy "entries_insert_own"
on public.entries for insert
with check (user_id = auth.uid());

drop policy if exists "entries_update_own" on public.entries;
create policy "entries_update_own"
on public.entries for update
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "entries_delete_own" on public.entries;
create policy "entries_delete_own"
on public.entries for delete
using (user_id = auth.uid());

-- Realtime: add 'entries' table to publication
do $$
begin
  perform 1 from pg_publication where pubname = 'supabase_realtime';
  if not found then
    create publication supabase_realtime;
  end if;
end$$;

alter publication supabase_realtime add table public.entries;

-- Note: Removed banner storage bucket policies and banner_key/cover_url fields per requirements.