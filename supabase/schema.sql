-- =====================================================================
-- Defense Queue - full database setup.
-- Paste this whole file into Supabase -> SQL Editor -> New query -> Run.
-- Safe to run again (uses "if not exists" / "or replace" / drop+create).
-- =====================================================================


-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

-- One row per registered user. Created automatically by a trigger on signup.
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  username     text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (char_length(display_name) between 1 and 60),
  is_admin     boolean not null default false,
  created_at   timestamptz not null default now()
);

-- Single-row settings table (id is always 1). Only admins can read/change it.
create table if not exists public.settings (
  id         int primary key default 1 check (id = 1),
  group_code text not null check (char_length(group_code) between 1 and 100)
);
insert into public.settings (id, group_code) values (1, 'change-me')
on conflict (id) do nothing;

-- Weekly schedule. weekday: 1 = Monday ... 7 = Sunday.
create table if not exists public.subjects (
  id         bigint generated always as identity primary key,
  name       text not null check (char_length(name) between 1 and 100),
  weekday    smallint not null check (weekday between 1 and 7),
  start_time time not null,
  end_time   time not null,
  created_at timestamptz not null default now(),
  check (end_time > start_time)
);

-- Queue entries. A "slot" is (subject_id, slot_date).
create table if not exists public.entries (
  id         bigint generated always as identity primary key,
  subject_id bigint not null references public.subjects(id) on delete cascade,
  slot_date  date not null,
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  comment    text check (comment is null or char_length(comment) <= 200),
  done       boolean not null default false,
  created_at timestamptz not null default now(),
  unique (subject_id, slot_date, user_id)   -- one entry per user per slot
);
create index if not exists entries_slot_idx on public.entries (slot_date, subject_id, created_at);


-- ---------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------

-- True if the current user has a profile (= is a valid group member).
create or replace function public.is_member()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid());
$$;

-- True if the current user is an admin.
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- "Today" in Asia/Almaty.
create or replace function public.app_today()
returns date language sql stable set search_path = '' as $$
  select (now() at time zone 'Asia/Almaty')::date;
$$;

-- Monday of the current week in Asia/Almaty.
create or replace function public.app_week_start()
returns date language sql stable set search_path = '' as $$
  select public.app_today() - (extract(isodow from public.app_today())::int - 1);
$$;


-- ---------------------------------------------------------------------
-- Registration (group code checked server-side)
-- ---------------------------------------------------------------------

-- Public pre-checks used by the register page for friendly error messages.
-- The real enforcement is the trigger below.
create or replace function public.check_group_code(code text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.settings where id = 1 and group_code = code);
$$;

create or replace function public.username_available(name text)
returns boolean language sql stable security definer set search_path = '' as $$
  select not exists (select 1 from public.profiles where username = lower(name));
$$;

grant execute on function public.check_group_code(text)   to anon, authenticated;
grant execute on function public.username_available(text) to anon, authenticated;

-- BEFORE insert on auth.users: reject signup if code/username/name are invalid.
-- Raising an exception here makes the whole signup fail, so no account is created.
create or replace function public.before_auth_user_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_username text := lower(coalesce(new.raw_user_meta_data->>'username', ''));
  v_name     text := btrim(coalesce(new.raw_user_meta_data->>'display_name', ''));
  v_code     text := coalesce(new.raw_user_meta_data->>'group_code', '');
begin
  if v_code = '' or v_code is distinct from (select group_code from public.settings where id = 1) then
    raise exception 'invalid group code';
  end if;
  if v_username !~ '^[a-z0-9_]{3,20}$'
     or split_part(lower(new.email), '@', 1) <> v_username then
    raise exception 'invalid username';
  end if;
  if char_length(v_name) not between 1 and 60 then
    raise exception 'invalid display name';
  end if;
  -- Do not keep the group code in the user's metadata.
  new.raw_user_meta_data := new.raw_user_meta_data - 'group_code';
  return new;
end $$;

-- AFTER insert on auth.users: create the profile row.
create or replace function public.after_auth_user_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, username, display_name)
  values (new.id,
          lower(new.raw_user_meta_data->>'username'),
          btrim(new.raw_user_meta_data->>'display_name'));
  return new;
end $$;

drop trigger if exists on_auth_user_before_insert on auth.users;
create trigger on_auth_user_before_insert
  before insert on auth.users
  for each row execute function public.before_auth_user_insert();

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.after_auth_user_insert();


-- ---------------------------------------------------------------------
-- Entry guard: server sets created_at; non-admins may only edit comment
-- ---------------------------------------------------------------------
create or replace function public.entries_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.comment := nullif(btrim(new.comment), '');
  if tg_op = 'INSERT' then
    new.created_at := now();              -- queue order cannot be faked
    if not public.is_admin() then
      new.done := false;
    end if;
  else
    new.created_at := old.created_at;
    if not public.is_admin() then         -- users can only change the comment
      new.subject_id := old.subject_id;
      new.slot_date  := old.slot_date;
      new.user_id    := old.user_id;
      new.done       := old.done;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists entries_guard on public.entries;
create trigger entries_guard
  before insert or update on public.entries
  for each row execute function public.entries_guard();


-- ---------------------------------------------------------------------
-- Admin: remove a user (deletes auth user -> profile -> entries cascade)
-- ---------------------------------------------------------------------
create or replace function public.admin_delete_user(target uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if target = auth.uid() then
    raise exception 'You cannot remove yourself.';
  end if;
  delete from auth.users where id = target;
end $$;

revoke execute on function public.admin_delete_user(uuid) from public, anon;
grant  execute on function public.admin_delete_user(uuid) to authenticated;


-- ---------------------------------------------------------------------
-- Grants (RLS below decides which rows)
-- ---------------------------------------------------------------------
grant select                         on public.profiles to authenticated;
grant select, update                 on public.settings to authenticated;
grant select, insert, update, delete on public.subjects to authenticated;
grant select, insert, update, delete on public.entries  to authenticated;


-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.settings enable row level security;
alter table public.subjects enable row level security;
alter table public.entries  enable row level security;

-- profiles: members can read. Inserts only via trigger, deletes only via admin_delete_user.
drop policy if exists "profiles: members read" on public.profiles;
create policy "profiles: members read" on public.profiles
  for select to authenticated using (public.is_member());

-- settings: admin only.
drop policy if exists "settings: admin read" on public.settings;
create policy "settings: admin read" on public.settings
  for select to authenticated using (public.is_admin());

drop policy if exists "settings: admin update" on public.settings;
create policy "settings: admin update" on public.settings
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- subjects: members read, admin writes.
drop policy if exists "subjects: members read" on public.subjects;
create policy "subjects: members read" on public.subjects
  for select to authenticated using (public.is_member());

drop policy if exists "subjects: admin insert" on public.subjects;
create policy "subjects: admin insert" on public.subjects
  for insert to authenticated with check (public.is_admin());

drop policy if exists "subjects: admin update" on public.subjects;
create policy "subjects: admin update" on public.subjects
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "subjects: admin delete" on public.subjects;
create policy "subjects: admin delete" on public.subjects
  for delete to authenticated using (public.is_admin());

-- entries: members read.
drop policy if exists "entries: members read" on public.entries;
create policy "entries: members read" on public.entries
  for select to authenticated using (public.is_member());

-- entries: join only for yourself, only today..end of next week,
-- and only on the subject's weekday.
drop policy if exists "entries: join" on public.entries;
create policy "entries: join" on public.entries
  for insert to authenticated with check (
    public.is_member()
    and user_id = auth.uid()
    and slot_date >= public.app_today()
    and slot_date <= public.app_week_start() + 13
    and exists (
      select 1 from public.subjects s
      where s.id = subject_id
        and s.weekday = extract(isodow from slot_date)
    )
  );

-- entries: edit own comment, only while the day is not closed.
drop policy if exists "entries: edit own" on public.entries;
create policy "entries: edit own" on public.entries
  for update to authenticated
  using      (public.is_member() and user_id = auth.uid() and slot_date >= public.app_today())
  with check (public.is_member() and user_id = auth.uid() and slot_date >= public.app_today());

-- entries: cancel own, only while the day is not closed.
drop policy if exists "entries: cancel own" on public.entries;
create policy "entries: cancel own" on public.entries
  for delete to authenticated
  using (public.is_member() and user_id = auth.uid() and slot_date >= public.app_today());

-- entries: admin can update (mark done) and delete anything.
drop policy if exists "entries: admin update" on public.entries;
create policy "entries: admin update" on public.entries
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "entries: admin delete" on public.entries;
create policy "entries: admin delete" on public.entries
  for delete to authenticated using (public.is_admin());


-- ---------------------------------------------------------------------
-- Realtime: broadcast changes to entries
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'entries'
  ) then
    alter publication supabase_realtime add table public.entries;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- Cleanup job (pg_cron)
-- pg_cron runs in UTC. 19:00 UTC = 00:00 in Asia/Almaty (UTC+5).
-- Deletes entries dated before Monday of the current week.
-- ---------------------------------------------------------------------
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;

select cron.schedule(
  'queue-cleanup',
  '0 19 * * *',
  $$ delete from public.entries where slot_date < public.app_week_start() $$
);
