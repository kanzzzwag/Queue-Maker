-- =====================================================================
-- Migration 003: admin auto-join.
-- Run in Supabase -> SQL Editor after migration-002. Safe to run again.
--
-- When joining opens for a slot (00:00 Asia/Almaty, the day before the slot),
-- a cron job joins the admin to the chosen subjects at the chosen place.
-- If the place is already taken, the subject is skipped and logged.
-- Existing entries are not touched.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- Rules: which subjects to auto-join and at which place (admins only)
-- ---------------------------------------------------------------------
create table if not exists public.auto_join_rules (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  subject_id bigint not null references public.subjects(id) on delete cascade,
  place      int not null default 3 check (place >= 1),
  enabled    boolean not null default true,
  updated_at timestamptz not null default now(),
  unique (user_id, subject_id)
);

-- ---------------------------------------------------------------------
-- Log of every auto-join attempt (kept 30 days)
-- ---------------------------------------------------------------------
create table if not exists public.auto_join_log (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  user_id      uuid references public.profiles(id) on delete cascade,
  subject_id   bigint references public.subjects(id) on delete set null,
  subject_name text,
  slot_date    date not null,
  place        int,
  status       text not null check (status in ('joined', 'place_taken', 'already_in', 'error')),
  error        text
);
create index if not exists auto_join_log_time_idx on public.auto_join_log (created_at desc);

-- Rules: only admins, only their own rules. updated_at is set by the server.
-- No user (Supabase dashboard / SQL editor) is allowed; anon has no grants on this table.
create or replace function public.auto_join_rules_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists auto_join_rules_guard on public.auto_join_rules;
create trigger auto_join_rules_guard
  before insert or update on public.auto_join_rules
  for each row execute function public.auto_join_rules_guard();

-- ---------------------------------------------------------------------
-- run_auto_join(): called by cron at 00:00 Almaty, or by "Run now" (admin).
-- For each enabled rule of an admin: take tomorrow's slot if the subject is
-- on that weekday, skip if already in, else try to insert at the chosen place.
-- Every insert has its own exception block: a failure never stops the loop,
-- never retries, never picks another place, never touches other entries.
-- ---------------------------------------------------------------------
create or replace function public.run_auto_join()
returns setof public.auto_join_log
language plpgsql security definer set search_path = '' as $$
declare
  v_date       date := public.app_today() + 1;
  r            record;
  v_status     text;
  v_error      text;
  v_constraint text;
  v_log        public.auto_join_log;
begin
  -- Cron runs without a user (auth.uid() is null). Users must be admins.
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  -- Keep the log for 30 days.
  delete from public.auto_join_log where created_at < now() - interval '30 days';

  for r in
    select a.user_id, a.subject_id, a.place, s.name
    from public.auto_join_rules a
    join public.subjects s on s.id = a.subject_id
    join public.profiles p on p.id = a.user_id and p.is_admin
    where a.enabled
      and s.weekday = extract(isodow from v_date)
    order by s.start_time, s.id
  loop
    v_error := null;

    if exists (
      select 1 from public.entries e
      where e.subject_id = r.subject_id and e.slot_date = v_date and e.user_id = r.user_id
    ) then
      v_status := 'already_in';
    else
      begin
        insert into public.entries (subject_id, slot_date, user_id, place)
        values (r.subject_id, v_date, r.user_id, r.place);
        v_status := 'joined';
      exception
        when unique_violation then
          get stacked diagnostics v_constraint = constraint_name;
          if v_constraint = 'entries_slot_place_key' then
            v_status := 'place_taken';
          else
            v_status := 'already_in';
          end if;
        when others then
          v_status := 'error';
          v_error := left(sqlerrm, 300);
      end;
    end if;

    insert into public.auto_join_log (user_id, subject_id, subject_name, slot_date, place, status, error)
    values (r.user_id, r.subject_id, r.name, v_date, r.place, v_status, v_error)
    returning * into v_log;
    return next v_log;
  end loop;
end $$;

revoke execute on function public.run_auto_join() from public, anon;
grant  execute on function public.run_auto_join() to authenticated;

-- ---------------------------------------------------------------------
-- Grants + RLS (admins only)
-- ---------------------------------------------------------------------
revoke all on public.auto_join_rules from anon, authenticated;
revoke all on public.auto_join_log   from anon, authenticated;
grant select, insert, update, delete on public.auto_join_rules to authenticated;
grant select                         on public.auto_join_log   to authenticated;

alter table public.auto_join_rules enable row level security;
alter table public.auto_join_log   enable row level security;

drop policy if exists "auto_join_rules: admin own" on public.auto_join_rules;
create policy "auto_join_rules: admin own" on public.auto_join_rules
  for all to authenticated
  using      (public.is_admin() and user_id = auth.uid())
  with check (public.is_admin() and user_id = auth.uid());

drop policy if exists "auto_join_log: admin read" on public.auto_join_log;
create policy "auto_join_log: admin read" on public.auto_join_log
  for select to authenticated using (public.is_admin());

-- ---------------------------------------------------------------------
-- Cron: 19:00 UTC = 00:00 Asia/Almaty. Separate from queue-cleanup.
-- Order does not matter: cleanup deletes past weeks, auto-join adds tomorrow.
-- ---------------------------------------------------------------------
select cron.schedule('auto-join', '0 19 * * *', $$ select public.run_auto_join() $$);

commit;
