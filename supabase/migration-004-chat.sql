-- =====================================================================
-- Migration 004: group chat.
-- Run in Supabase -> SQL Editor after migration-003. Safe to run again.
-- Does not touch queue entries.
-- =====================================================================
begin;

create table if not exists public.messages (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists messages_user_time_idx on public.messages (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- Guard: trim text, server time, anti-spam
-- (max 1 message per 2 seconds and 20 per minute per user).
-- ---------------------------------------------------------------------
create or replace function public.messages_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.body := regexp_replace(coalesce(new.body, ''), '^\s+|\s+$', '', 'g');
  if char_length(new.body) = 0 then
    raise exception 'Message is empty.';
  end if;
  if char_length(new.body) > 500 then
    raise exception 'Message is too long (max 500).';
  end if;
  new.created_at := now();

  -- One sender at a time per user, so two fast requests cannot both pass.
  perform pg_advisory_xact_lock(hashtextextended('chat:' || new.user_id::text, 0));

  if exists (
    select 1 from public.messages
    where user_id = new.user_id and created_at > clock_timestamp() - interval '2 seconds'
  ) then
    raise exception 'Slow down. Wait 2 seconds.';
  end if;
  if (
    select count(*) from public.messages
    where user_id = new.user_id and created_at > clock_timestamp() - interval '1 minute'
  ) >= 20 then
    raise exception 'Too many messages. Wait a minute.';
  end if;
  return new;
end $$;

drop trigger if exists messages_guard on public.messages;
create trigger messages_guard
  before insert on public.messages
  for each row execute function public.messages_guard();

-- ---------------------------------------------------------------------
-- Grants + RLS. No editing. Users can only send the body (user_id = default).
-- ---------------------------------------------------------------------
revoke all on public.messages from anon, authenticated;
grant select, delete   on public.messages to authenticated;
grant insert (body)    on public.messages to authenticated;

alter table public.messages enable row level security;

drop policy if exists "messages: members read" on public.messages;
create policy "messages: members read" on public.messages
  for select to authenticated using (public.is_member());

drop policy if exists "messages: members send" on public.messages;
create policy "messages: members send" on public.messages
  for insert to authenticated with check (public.is_member() and user_id = auth.uid());

drop policy if exists "messages: delete own or admin" on public.messages;
create policy "messages: delete own or admin" on public.messages
  for delete to authenticated
  using (public.is_member() and (user_id = auth.uid() or public.is_admin()));

-- ---------------------------------------------------------------------
-- Realtime (insert + delete)
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Cron: delete messages older than 30 days (00:15 Almaty).
-- ---------------------------------------------------------------------
select cron.schedule('chat-cleanup', '15 19 * * *',
  $$ delete from public.messages where created_at < now() - interval '30 days' $$);

commit;
