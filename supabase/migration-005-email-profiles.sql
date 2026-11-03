-- =====================================================================
-- Migration 005: real email (own confirmation flow) + profiles.
-- Run in Supabase -> SQL Editor after migration-004. Safe to run again.
-- Does not touch queue entries. Existing profiles keep their data.
--
-- Why our own email confirmation: with "Confirm email" OFF (needed for the
-- fake username@queue.local signups), Supabase Auth applies updateUser({ email })
-- immediately, without any confirmation. With "Secure email change" ON it would
-- also mail the old (fake) address. So the Edge Function "email" sends its own
-- link (Brevo API), keeps only a SHA-256 hash of the token (24 h), and only after
-- the link is opened it writes the email into Auth and into account_emails.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- Confirmed emails. A row exists only for a confirmed email.
-- Visible only to the owner and admins. Written only by Edge Functions.
-- ---------------------------------------------------------------------
create table if not exists public.account_emails (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  email       text not null check (char_length(email) <= 254 and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  verified_at timestamptz not null default now()
);
create unique index if not exists account_emails_email_key on public.account_emails (lower(email));

-- Pending confirmations. Only the token hash is stored. No client access.
create table if not exists public.email_verifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  email      text not null,
  token_hash text not null unique,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz
);
create index if not exists email_verifications_user_idx on public.email_verifications (user_id);

-- Generic rate-limit log for Edge Functions (login, forgot password, email). No client access.
create table if not exists public.rate_events (
  id         bigint generated always as identity primary key,
  kind       text not null,
  key        text not null,
  created_at timestamptz not null default now()
);
create index if not exists rate_events_idx on public.rate_events (kind, key, created_at);

revoke all on public.account_emails      from anon, authenticated;
revoke all on public.email_verifications from anon, authenticated;
revoke all on public.rate_events         from anon, authenticated;
grant select on public.account_emails to authenticated;

alter table public.account_emails      enable row level security;
alter table public.email_verifications enable row level security;
alter table public.rate_events         enable row level security;

drop policy if exists "account_emails: owner or admin" on public.account_emails;
create policy "account_emails: owner or admin" on public.account_emails
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

-- The reliable "email confirmed" flag, used by points, trade and the game.
create or replace function public.email_verified(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.account_emails where user_id = uid);
$$;
revoke execute on function public.email_verified(uuid) from public, anon;
grant  execute on function public.email_verified(uuid) to authenticated, service_role;

-- Own email status for the profile page: confirmed email + pending one.
create or replace function public.my_email_status()
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'email',       (select email from public.account_emails where user_id = auth.uid()),
    'pending',     (select email from public.email_verifications
                    where user_id = auth.uid() and used_at is null and expires_at > now()
                    order by created_at desc limit 1)
  );
$$;
revoke execute on function public.my_email_status() from public, anon;
grant  execute on function public.my_email_status() to authenticated;

-- Rate limit helper for Edge Functions (service role only).
-- Returns true if fewer than p_max events happened in p_window.
-- p_record = true also records this event (p_record = false only checks).
create or replace function public.rate_limit_hit(
  p_kind text, p_key text, p_max int, p_window interval, p_record boolean default true)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_count int;
begin
  perform pg_advisory_xact_lock(hashtextextended('rate:' || p_kind || ':' || p_key, 0));
  delete from public.rate_events where created_at < now() - interval '1 day';
  select count(*) into v_count from public.rate_events
  where kind = p_kind and key = p_key and created_at > now() - p_window;
  if p_record then
    insert into public.rate_events (kind, key) values (p_kind, p_key);
  end if;
  return v_count < p_max;
end $$;
revoke execute on function public.rate_limit_hit(text, text, int, interval, boolean) from public, anon, authenticated;
grant  execute on function public.rate_limit_hit(text, text, int, interval, boolean) to service_role;

-- ---------------------------------------------------------------------
-- Profiles: new fields
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists bio text;
alter table public.profiles add column if not exists favorite_subject_id bigint references public.subjects(id) on delete set null;
alter table public.profiles add column if not exists favorite_subject_text text;
alter table public.profiles add column if not exists bg_preset text;
alter table public.profiles add column if not exists bg_path text;
alter table public.profiles add column if not exists name_changed_at timestamptz;

alter table public.profiles drop constraint if exists profiles_bio_check;
alter table public.profiles add constraint profiles_bio_check check (bio is null or char_length(bio) <= 160);
alter table public.profiles drop constraint if exists profiles_fav_text_check;
alter table public.profiles add constraint profiles_fav_text_check
  check (favorite_subject_text is null or char_length(favorite_subject_text) between 1 and 40);
alter table public.profiles drop constraint if exists profiles_fav_one_check;
alter table public.profiles add constraint profiles_fav_one_check
  check (favorite_subject_id is null or favorite_subject_text is null);
alter table public.profiles drop constraint if exists profiles_bg_preset_check;
alter table public.profiles add constraint profiles_bg_preset_check
  check (bg_preset is null or bg_preset in ('plain', 'sand', 'sage', 'sky', 'stone', 'lilac', 'clay', 'dots', 'grid', 'lines'));

-- Guard: name once per 7 days (admins: no limit), clean text, own storage paths only.
create or replace function public.profiles_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.display_name := regexp_replace(btrim(coalesce(new.display_name, '')), '\s+', ' ', 'g');
  if char_length(new.display_name) not between 1 and 60 then
    raise exception 'Name must be 1 to 60 characters.';
  end if;
  if new.display_name is distinct from old.display_name then
    if not public.is_admin()
       and old.name_changed_at is not null
       and old.name_changed_at > now() - interval '7 days' then
      raise exception 'You can change your name once every 7 days.';
    end if;
    new.name_changed_at := now();
  else
    new.name_changed_at := old.name_changed_at;
  end if;

  new.bio := nullif(btrim(new.bio), '');
  if char_length(new.bio) > 160 then raise exception 'Bio is too long (max 160).'; end if;

  new.favorite_subject_text := nullif(btrim(new.favorite_subject_text), '');
  if char_length(new.favorite_subject_text) > 40 then raise exception 'Subject is too long (max 40).'; end if;
  if new.favorite_subject_id is not null and new.favorite_subject_text is not null then
    raise exception 'Pick a subject or type one, not both.';
  end if;

  -- Files must be in the user's own folder: "{user_id}/..."
  if new.avatar_path is not null and split_part(new.avatar_path, '/', 1) <> new.id::text then
    raise exception 'Invalid avatar.';
  end if;
  if new.bg_path is not null and split_part(new.bg_path, '/', 1) <> new.id::text then
    raise exception 'Invalid background.';
  end if;
  return new;
end $$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard
  before update on public.profiles
  for each row execute function public.profiles_guard();

-- Users can update only these columns, only on their own row.
-- (username, is_admin, created_at stay read-only.)
revoke update on public.profiles from anon, authenticated;
grant update (display_name, bio, avatar_path, favorite_subject_id, favorite_subject_text, bg_preset, bg_path)
  on public.profiles to authenticated;

drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update to authenticated
  using (public.is_member() and id = auth.uid())
  with check (id = auth.uid());

-- ---------------------------------------------------------------------
-- Storage: avatars + backgrounds. Public buckets, random file names.
-- Path "{user_id}/{random}.webp". Only the owner can upload/replace/delete.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',     'avatars',     true, 204800, array['image/webp', 'image/jpeg', 'image/png']),
  ('backgrounds', 'backgrounds', true, 819200, array['image/webp', 'image/jpeg', 'image/png'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "media: members read" on storage.objects;
create policy "media: members read" on storage.objects
  for select to authenticated
  using (bucket_id in ('avatars', 'backgrounds') and public.is_member());

drop policy if exists "media: owner insert" on storage.objects;
create policy "media: owner insert" on storage.objects
  for insert to authenticated
  with check (bucket_id in ('avatars', 'backgrounds') and public.is_member()
              and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "media: owner update" on storage.objects;
create policy "media: owner update" on storage.objects
  for update to authenticated
  using      (bucket_id in ('avatars', 'backgrounds') and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id in ('avatars', 'backgrounds') and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "media: owner delete" on storage.objects;
create policy "media: owner delete" on storage.objects
  for delete to authenticated
  using (bucket_id in ('avatars', 'backgrounds') and (storage.foldername(name))[1] = auth.uid()::text);

commit;
