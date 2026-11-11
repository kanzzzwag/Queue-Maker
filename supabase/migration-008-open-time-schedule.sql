-- =====================================================================
-- Migration 008: open time per subject, schedule changes by week,
-- "new trade" notification.
-- Run in Supabase -> SQL Editor after migration-007. Safe to run again.
-- Existing subjects keep working exactly as before (open 1 day before at
-- 00:00, valid every week). Existing queue entries are not changed.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Subjects: when the queue opens + which weeks the subject is used
-- ---------------------------------------------------------------------
alter table public.subjects add column if not exists open_days_before smallint not null default 1;
alter table public.subjects add column if not exists open_time  time not null default '00:00';
alter table public.subjects add column if not exists valid_from  date;   -- null = no start limit
alter table public.subjects add column if not exists valid_until date;   -- null = no end

alter table public.subjects drop constraint if exists subjects_open_days_check;
alter table public.subjects add constraint subjects_open_days_check check (open_days_before between 0 and 7);
alter table public.subjects drop constraint if exists subjects_valid_check;
alter table public.subjects add constraint subjects_valid_check
  check (valid_from is null or valid_until is null or valid_until >= valid_from);

-- Current date-time in Asia/Almaty (no time zone).
create or replace function public.app_now_local()
returns timestamp language sql stable set search_path = '' as $$
  select (now() at time zone 'Asia/Almaty');
$$;

-- Is the subject on the schedule on this date (weekday + start/end dates)?
create or replace function public.subject_active_on(p_subject bigint, p_date date)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.subjects s
    where s.id = p_subject
      and s.weekday = extract(isodow from p_date)
      and (s.valid_from  is null or p_date >= s.valid_from)
      and (s.valid_until is null or p_date <= s.valid_until)
  );
$$;

-- Moment (Almaty time) when joining opens for a slot.
create or replace function public.join_opens_at(p_subject bigint, p_date date)
returns timestamp language sql stable security definer set search_path = '' as $$
  select (p_date - s.open_days_before) + s.open_time from public.subjects s where s.id = p_subject;
$$;

-- Can people join this slot right now?
create or replace function public.join_is_open(p_subject bigint, p_date date)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_date >= public.app_today()
     and p_date <= public.app_week_start() + 13            -- not beyond next week
     and public.subject_active_on(p_subject, p_date)
     and public.app_now_local() >= public.join_opens_at(p_subject, p_date);
$$;

revoke execute on function public.subject_active_on(bigint, date) from public, anon;
revoke execute on function public.join_opens_at(bigint, date)     from public, anon;
revoke execute on function public.join_is_open(bigint, date)      from public, anon;
grant  execute on function public.subject_active_on(bigint, date) to authenticated;
grant  execute on function public.join_opens_at(bigint, date)     to authenticated;
grant  execute on function public.join_is_open(bigint, date)      to authenticated;

-- Join rule now uses the subject's own open time (enforced here, not only in the page).
drop policy if exists "entries: join" on public.entries;
create policy "entries: join" on public.entries
  for insert to authenticated with check (
    public.is_member()
    and user_id = auth.uid()
    and public.join_is_open(subject_id, slot_date)
  );

-- Admin: "apply from next week". The subject ends this Sunday and a copy
-- with the new values starts next Monday. Next-week entries move with it
-- (or are removed if the weekday changes). Auto-join rules move too.
create or replace function public.admin_change_subject_next_week(
  p_id bigint, p_name text, p_weekday smallint, p_start time, p_end time,
  p_open_days smallint, p_open_time time)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  s      public.subjects;
  v_next date := public.app_week_start() + 7;
  v_new  bigint;
begin
  if not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into s from public.subjects where id = p_id for update;
  if not found then raise exception 'Subject not found.'; end if;
  if s.valid_until is not null and s.valid_until < v_next then
    raise exception 'This subject already ends this week.';
  end if;

  -- Starts next week or later anyway: just edit it.
  if s.valid_from is not null and s.valid_from >= v_next then
    update public.subjects
    set name = p_name, weekday = p_weekday, start_time = p_start, end_time = p_end,
        open_days_before = p_open_days, open_time = p_open_time
    where id = p_id;
    if p_weekday <> s.weekday then
      delete from public.entries where subject_id = p_id;
    end if;
    return p_id;
  end if;

  insert into public.subjects (name, weekday, start_time, end_time, open_days_before, open_time, valid_from, valid_until)
  values (p_name, p_weekday, p_start, p_end, p_open_days, p_open_time, v_next, s.valid_until)
  returning id into v_new;
  update public.subjects set valid_until = v_next - 1 where id = p_id;

  if p_weekday = s.weekday then
    update public.entries set subject_id = v_new where subject_id = p_id and slot_date >= v_next;
  else
    delete from public.entries where subject_id = p_id and slot_date >= v_next;
  end if;
  update public.auto_join_rules set subject_id = v_new where subject_id = p_id;
  return v_new;
end $$;

-- Admin: "End after this week". Queue stays until Sunday; later entries go.
-- A subject that has not started yet is simply deleted.
create or replace function public.admin_end_subject(p_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  s      public.subjects;
  v_last date := public.app_week_start() + 6;
begin
  if not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into s from public.subjects where id = p_id for update;
  if not found then raise exception 'Subject not found.'; end if;
  if s.valid_from is not null and s.valid_from > v_last then
    delete from public.subjects where id = p_id;
    return;
  end if;
  update public.subjects set valid_until = least(coalesce(valid_until, v_last), v_last) where id = p_id;
  delete from public.entries where subject_id = p_id and slot_date > v_last;
end $$;

revoke execute on function public.admin_change_subject_next_week(bigint, text, smallint, time, time, smallint, time) from public, anon;
revoke execute on function public.admin_end_subject(bigint) from public, anon;
grant  execute on function public.admin_change_subject_next_week(bigint, text, smallint, time, time, smallint, time) to authenticated;
grant  execute on function public.admin_end_subject(bigint) to authenticated;

-- Subjects that ended before this week are no longer shown anywhere: delete them.
create or replace function public.cleanup_subjects()
returns void language sql security definer set search_path = '' as $$
  delete from public.subjects where valid_until is not null and valid_until < public.app_week_start();
$$;
revoke execute on function public.cleanup_subjects() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Auto-join at each subject's own open time
-- Runs every minute. Each rule is tried ONCE per slot (the log remembers it);
-- "Run now" (p_force) tries again. Same safety as before: own exception
-- block per insert, never another place, never other people's entries.
-- ---------------------------------------------------------------------
create index if not exists auto_join_log_slot_idx on public.auto_join_log (user_id, subject_id, slot_date);

drop function if exists public.run_auto_join();
create or replace function public.run_auto_join(p_force boolean default false)
returns setof public.auto_join_log
language plpgsql security definer set search_path = '' as $$
declare
  r            record;
  v_status     text;
  v_error      text;
  v_constraint text;
  v_log        public.auto_join_log;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  delete from public.auto_join_log where created_at < now() - interval '30 days';

  for r in
    select a.user_id, a.subject_id, a.place, s.name, d::date as day
    from public.auto_join_rules a
    join public.subjects s on s.id = a.subject_id
    join public.profiles p on p.id = a.user_id and p.is_admin
    cross join generate_series(public.app_today(), public.app_today() + 7, interval '1 day') d
    where a.enabled
      and public.join_is_open(s.id, d::date)
      and (p_force or not exists (
        select 1 from public.auto_join_log l
        where l.user_id = a.user_id and l.subject_id = a.subject_id and l.slot_date = d::date))
    order by d, s.start_time, s.id
  loop
    v_error := null;
    if exists (
      select 1 from public.entries e
      where e.subject_id = r.subject_id and e.slot_date = r.day and e.user_id = r.user_id
    ) then
      v_status := 'already_in';
    else
      begin
        insert into public.entries (subject_id, slot_date, user_id, place)
        values (r.subject_id, r.day, r.user_id, r.place);
        v_status := 'joined';
      exception
        when unique_violation then
          get stacked diagnostics v_constraint = constraint_name;
          v_status := case when v_constraint = 'entries_slot_place_key' then 'place_taken' else 'already_in' end;
        when others then
          v_status := 'error';
          v_error := left(sqlerrm, 300);
      end;
    end if;

    insert into public.auto_join_log (user_id, subject_id, subject_name, slot_date, place, status, error)
    values (r.user_id, r.subject_id, r.name, r.day, r.place, v_status, v_error)
    returning * into v_log;
    return next v_log;
  end loop;
end $$;

revoke execute on function public.run_auto_join(boolean) from public, anon;
grant  execute on function public.run_auto_join(boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 3. "New in Trade" dot: when did the user last open the Trade page?
-- ---------------------------------------------------------------------
create table if not exists public.trade_seen (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  seen_at timestamptz not null default now()
);
revoke all on public.trade_seen from anon, authenticated;
grant select on public.trade_seen to authenticated;
alter table public.trade_seen enable row level security;
drop policy if exists "trade_seen: own" on public.trade_seen;
create policy "trade_seen: own" on public.trade_seen
  for select to authenticated using (user_id = auth.uid());

create or replace function public.mark_trade_seen()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_member() then return; end if;
  insert into public.trade_seen (user_id, seen_at) values (auth.uid(), now())
  on conflict (user_id) do update set seen_at = now();
end $$;

-- New open offers from others + new offers (bids) on my lots since my last visit.
create or replace function public.trade_unseen_count()
returns int language sql stable security definer set search_path = '' as $$
  with me as (
    select coalesce((select seen_at from public.trade_seen where user_id = auth.uid()), '-infinity'::timestamptz) as t
  )
  select case
    when not public.is_member()
      or not coalesce((select trade_enabled from public.settings where id = 1), false) then 0
    else (
      (select count(*) from public.trade_offers o, me
        where o.status = 'open' and o.seller_id <> auth.uid() and o.created_at > me.t)
      + (select count(*) from public.trade_bids b join public.trade_offers o on o.id = b.offer_id, me
        where o.seller_id = auth.uid() and b.status = 'pending' and b.created_at > me.t)
    )::int
  end;
$$;

revoke execute on function public.mark_trade_seen()    from public, anon;
revoke execute on function public.trade_unseen_count() from public, anon;
grant  execute on function public.mark_trade_seen()    to authenticated;
grant  execute on function public.trade_unseen_count() to authenticated;

-- ---------------------------------------------------------------------
-- Cron (UTC)
--   auto-join:            every minute (each subject has its own open time)
--   subjects-cleanup:     00:20 Almaty, removes subjects that ended last week
--   cron-history-cleanup: keeps cron.job_run_details small (auto-join runs often)
-- ---------------------------------------------------------------------
select cron.schedule('auto-join', '* * * * *', $$ select public.run_auto_join() $$);
select cron.schedule('subjects-cleanup', '20 19 * * *', $$ select public.cleanup_subjects() $$);
select cron.schedule('cron-history-cleanup', '30 19 * * *',
  $$ delete from cron.job_run_details where end_time < now() - interval '7 days' $$);

commit;
