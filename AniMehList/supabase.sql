-- =====================================================================
-- AniMehList Supabase schema + Global Chat
-- =====================================================================

create extension if not exists "pgcrypto";
create extension if not exists "citext";
create extension if not exists "pg_cron";
do $$
begin
  if not exists (select 1 from pg_type where typname = 'media_kind') then
    create type public.media_kind as enum ('SERIES', 'MOVIE');
  end if;
  if not exists (select 1 from pg_type where typname = 'entry_status') then
    create type public.entry_status as enum ('WATCHING', 'PLAN', 'REWATCH', 'WAITING', 'COMPLETED');
  end if;
  if not exists (select 1 from pg_type where typname = 'title_pref') then
    create type public.title_pref as enum ('ROMAJI','ENGLISH','NATIVE');
  end if;
end
$$ language plpgsql;
-- =====================================================================
-- Updated-at trigger function
-- =====================================================================
create or replace function public.handle_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;
-- =====================================================================
-- Profanity table + sanitizer function + triggers
-- - profanity table stores words and their replacement
-- - sanitize_text(text) replaces whole-word matches case-insensitively
-- and also common suffixes (s|es|ed|ing|ers?|ies)
-- =====================================================================
create table if not exists public.profanity (
  word text primary key, -- stored lowercase
  replacement text not null -- what replaces the root word
);
-- Seed (idempotent)
insert into public.profanity (word, replacement) values
  ('shit', 'sh*t')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('fucking', 'f***ing')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('fuck', 'f**k')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('bitch', 'b***h')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('asshole', 'a**hole')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('cunt', 'c**t')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('bastard', 'b***ard')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('motherfucker', 'm********r')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('damn', 'd**n')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('nigga', 'n***a')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('nigger', 'n****r')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('dick', 'd**k')
on conflict (word) do nothing;
insert into public.profanity (word, replacement) values
  ('pussy', 'p***y')
on conflict (word) do nothing;
-- Sanitizer function:
-- * Matches whole word root + optional common suffix (keeps suffix)
-- * case-insensitive and global
create or replace function public.sanitize_text(p_text text)
returns text
language plpgsql
as $$
declare
  rec record;
  v_out text := coalesce(p_text, '');
begin
  if v_out = '' then
    return v_out;
  end if;
  for rec in select word, replacement from public.profanity loop
    -- \m and \M = word boundaries; capture suffix and append back
    -- suffix group: s|es|ed|ing|ers?|ies (expand as needed)
    v_out := regexp_replace(
      v_out,
      '\m(' || rec.word || ')(s|es|ed|ing|ers?|ies)?\M',
      rec.replacement || '\2',
      'gi'
    );
  end loop;
  return v_out;
end;
$$ security definer;
-- Trigger function for chat_messages
create or replace function public.chat_messages_sanitize_trigger()
returns trigger
language plpgsql
as $$
begin
  if new.content is not null then
    new.content := public.sanitize_text(new.content);
  end if;
  return new;
end;
$$;
-- Trigger function for entries.notes
create or replace function public.entries_notes_sanitize_trigger()
returns trigger
language plpgsql
as $$
begin
  if new.notes is not null then
    new.notes := public.sanitize_text(new.notes);
  end if;
  return new;
end;
$$;
-- =====================================================================
-- Entries table (with alt titles + AniList id)
-- =====================================================================
create table if not exists public.entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null check (user_id is not null),
  title text not null check (length(trim(title)) > 0),
  -- optional alt titles for display preferences
  title_romaji text,
  title_english text,
  title_native text,
  anilist_id integer,
  kind public.media_kind not null,
  status public.entry_status not null default 'PLAN',
  season integer,
  episode integer,
  absolute_episode integer,
  image_url text,
  notes text,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint season_non_negative check (season is null or season >= 0),
  constraint episode_non_negative check (episode is null or episode >= 0),
  constraint abs_episode_non_negative check (absolute_episode is null or absolute_episode >= 0),
  constraint mutually_exclusive_episode check (
    absolute_episode is null
    or (season is null and episode is null)
  ),
  constraint image_url_length check (image_url is null or length(image_url) <= 2048)
);
alter table public.entries
  alter column user_id set default auth.uid();
-- Ensure absolute_episode exists (fix schema cache error)
alter table public.entries add column if not exists absolute_episode integer;
-- Drop + recreate trigger
drop trigger if exists entries_updated_at on public.entries;
create trigger entries_updated_at
before update on public.entries
for each row execute function public.handle_updated_at();
-- Add sanitize trigger for entries.notes (before insert and update)
drop trigger if exists entries_notes_sanitize on public.entries;
create trigger entries_notes_sanitize
before insert or update on public.entries
for each row execute function public.entries_notes_sanitize_trigger();
create index if not exists entries_user_id_idx on public.entries(user_id);
create index if not exists entries_user_status_idx on public.entries(user_id, status);
create index if not exists entries_created_at_idx on public.entries(created_at desc);
create unique index if not exists entries_unique_title_per_user_idx
  on public.entries (user_id, lower(title));
-- =====================================================================
-- Row-Level Security
-- =====================================================================
alter table public.entries enable row level security;
-- Drop + recreate all policies for entries
drop policy if exists "Users can view their own entries" on public.entries;
drop policy if exists "Users can insert their own entries" on public.entries;
drop policy if exists "Users can update their own entries" on public.entries;
drop policy if exists "Users can delete their own entries" on public.entries;
create policy "Users can view their own entries"
on public.entries
for select
using (auth.uid() = user_id);
create policy "Users can insert their own entries"
on public.entries
for insert
with check (auth.uid() = user_id);
create policy "Users can update their own entries"
on public.entries
for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);
create policy "Users can delete their own entries"
on public.entries
for delete
using (auth.uid() = user_id);
-- =====================================================================
-- Profiles table (with title preference)
-- =====================================================================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username citext not null,
  title_pref public.title_pref not null default 'ROMAJI',
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint username_non_empty check (length(trim(username::text)) >= 3)
);
create unique index if not exists profiles_username_unique_idx
  on public.profiles (username);
-- Drop + recreate profiles trigger
drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at
before update on public.profiles
for each row execute function public.handle_updated_at();
alter table public.profiles enable row level security;
-- Drop + recreate all policies for profiles
drop policy if exists "Users can view their profile" on public.profiles;
drop policy if exists "Users can insert their profile" on public.profiles;
drop policy if exists "Users can update their profile" on public.profiles;
create policy "Users can view their profile"
on public.profiles
for select
using (auth.uid() = id);
create policy "Users can insert their profile"
on public.profiles
for insert
with check (auth.uid() = id);
create policy "Users can update their profile"
on public.profiles
for update
using (auth.uid() = id)
with check (auth.uid() = id);
-- =====================================================================
-- Sync Profile Function (links auth.users → profiles)
-- =====================================================================
create or replace function public.sync_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text;
begin
  v_username := coalesce(nullif(trim(new.raw_user_meta_data ->> 'username'), ''), split_part(new.email, '@', 1));
  if v_username is null then
    v_username := split_part(new.email, '@', 1);
  end if;
  if length(trim(v_username)) < 3 then
    v_username := 'user_' || substring(md5(new.id::text), 1, 8); -- Fallback unique username
  end if;
  insert into public.profiles (id, username)
  values (new.id, v_username)
  on conflict (id) do update
    set username = excluded.username,
        updated_at = timezone('utc', now());
  return new;
end;
$$;
-- Drop + recreate auth.users triggers
drop trigger if exists on_auth_user_created on auth.users;
drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.sync_profile();
create trigger on_auth_user_updated
after update on auth.users
for each row execute function public.sync_profile();
-- =====================================================================
-- Email lookup by username or email
-- =====================================================================
drop function if exists public.email_for_username(text);
create or replace function public.email_for_username(p_identifier text)
returns json
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text;
begin
  select u.email into v_email
  from auth.users u
  left join public.profiles p on p.id = u.id
  where lower(u.email) = lower(p_identifier)
     or (p.username is not null and lower(p.username::text) = lower(p_identifier))
     or lower(u.raw_user_meta_data ->> 'username') = lower(p_identifier)
  limit 1;
 
  return json_build_object('email', v_email);
end;
$$;
grant execute on function public.email_for_username(text) to authenticated, anon;
-- =====================================================================
-- Global Chat table
-- =====================================================================
create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  username text not null,
  content text not null check (length(trim(content)) > 0 and length(content) <= 2000),
  created_at timestamptz not null default timezone('utc', now())
);
alter table public.chat_messages enable row level security;
-- RLS: anyone authenticated can read; only poster can insert
drop policy if exists "Anyone authenticated can read chat" on public.chat_messages;
drop policy if exists "Users can post messages" on public.chat_messages;
create policy "Anyone authenticated can read chat"
on public.chat_messages
for select
to authenticated
using (true);
create policy "Users can post messages"
on public.chat_messages
for insert
to authenticated
with check (auth.uid() = user_id);
create index if not exists chat_messages_user_created_idx on public.chat_messages(user_id, created_at desc);
create index if not exists chat_messages_created_at_idx on public.chat_messages(created_at desc);
-- Add sanitize trigger for chat_messages.content (before insert and update)
drop trigger if exists chat_messages_sanitize on public.chat_messages;
create trigger chat_messages_sanitize
before insert or update on public.chat_messages
for each row execute function public.chat_messages_sanitize_trigger();
-- =====================================================================
-- Chat rate-limit + temp ban (server-side)
-- =====================================================================
create table if not exists public.chat_bans (
  user_id uuid primary key references auth.users(id) on delete cascade,
  until timestamptz not null,
  reason text,
  created_at timestamptz not null default timezone('utc', now())
);
alter table public.chat_bans enable row level security;
-- Users can only see their own ban (optional)
drop policy if exists "Users can view own ban" on public.chat_bans;
create policy "Users can view own ban"
on public.chat_bans
for select
to authenticated
using (auth.uid() = user_id);
create or replace function public.chat_enforce_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_last timestamptz;
  v_recent_count int;
  v_ban public.chat_bans%rowtype;
begin
  -- active ban?
  select * into v_ban from public.chat_bans where user_id = auth.uid() and until > timezone('utc', now()) limit 1;
  if found then
    raise exception 'You are temporarily banned until %', to_char(v_ban.until, 'YYYY-MM-DD HH24:MI:SS UTC');
  end if;
  -- too fast? (3s)
  select max(created_at) into v_last from public.chat_messages where user_id = auth.uid();
  if v_last is not null and (timezone('utc', now()) - v_last) < interval '3 seconds' then
    raise exception 'Rate limited. Please wait a few seconds.';
  end if;
  -- spam window: 30s
  select count(*) into v_recent_count
  from public.chat_messages
  where user_id = auth.uid() and created_at > timezone('utc', now()) - interval '30 seconds';
  if v_recent_count >= 8 then
    insert into public.chat_bans(user_id, until, reason)
    values (auth.uid(), timezone('utc', now()) + interval '10 minutes', 'spam')
    on conflict (user_id) do update
      set until = excluded.until,
          reason = excluded.reason,
          created_at = timezone('utc', now());
    raise exception 'You are temporarily banned for spam (10 minutes).';
  end if;
  return new;
end;
$$;
drop trigger if exists chat_messages_rate_limit on public.chat_messages;
create trigger chat_messages_rate_limit
before insert on public.chat_messages
for each row execute function public.chat_enforce_rate_limit();
-- Purge function for 3-day retention
create or replace function public.purge_old_chat_messages()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  delete from public.chat_messages
   where created_at < timezone('utc', now()) - interval '3 days';
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
-- Schedule purge hourly via pg_cron (if not already scheduled)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'purge_old_chat_messages') then
      perform cron.schedule(
        'purge_old_chat_messages',
        '0 * * * *',
        'SELECT public.purge_old_chat_messages();'
      );
    end if;
  end if;
end$$;
-- =====================================================================
-- Realtime publication
-- =====================================================================
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'entries'
  ) then
    alter publication supabase_realtime add table public.entries;
  end if;
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_messages'
  ) then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
end$$;
-- =====================================================================
-- One-time fix for missing profiles
-- =====================================================================
do $$
declare
  rec record;
  v_username text;
begin
  for rec in
    select u.*
    from auth.users u
    left join public.profiles p on p.id = u.id
    where p.id is null
  loop
    v_username := coalesce(nullif(trim(rec.raw_user_meta_data ->> 'username'), ''), split_part(rec.email, '@', 1));
    if length(trim(v_username)) < 3 then
      v_username := 'user_' || substring(md5(rec.id::text), 1, 8); -- Generate a valid username if too short
    end if;
    insert into public.profiles (id, username, created_at, updated_at)
    values (rec.id, v_username, rec.created_at, timezone('utc', now()))
    on conflict (id) do nothing;
  end loop;
end $$;
-- =====================================================================
-- RPC: Clear all entries for current user (reliable)
-- =====================================================================
create or replace function public.delete_all_entries()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.entries where user_id = auth.uid();
end;
$$;
grant execute on function public.delete_all_entries() to authenticated;
-- =====================================================================
-- End of schema
-- =====================================================================