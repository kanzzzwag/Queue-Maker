-- =====================================================================
-- Migration 002: pick a place in the queue + join window.
-- Run ONCE in Supabase -> SQL Editor (after schema.sql was already run).
--
-- - Each entry gets a "place" (1..number of users). A place can be taken once per slot.
-- - Joining is allowed only on the day before the slot or on the slot day.
--
-- Existing entries are KEPT. They get places 1, 2, 3... in their current order.
-- Everything runs in one transaction: if anything fails, nothing changes.
-- =====================================================================
begin;

-- 1. New column + keep existing queues in their current order.
alter table public.entries add column if not exists place int;

update public.entries e
set place = r.rn
from (
  select id, row_number() over (partition by subject_id, slot_date order by created_at, id) as rn
  from public.entries
) r
where e.id = r.id and e.place is null;

alter table public.entries alter column place set not null;

alter table public.entries drop constraint if exists entries_place_check;
alter table public.entries add constraint entries_place_check check (place >= 1);

alter table public.entries drop constraint if exists entries_slot_place_key;
alter table public.entries add constraint entries_slot_place_key unique (subject_id, slot_date, place);

-- 2. Number of registered users = highest place you can pick.
create or replace function public.member_count()
returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.profiles;
$$;
revoke execute on function public.member_count() from public, anon;
grant  execute on function public.member_count() to authenticated;

-- 3. Guard: users may change only comment and place; place must be 1..member_count.
create or replace function public.entries_guard()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_max int;
begin
  new.comment := nullif(btrim(new.comment), '');
  if tg_op = 'INSERT' then
    new.created_at := now();
    if not public.is_admin() then
      new.done := false;
    end if;
  else
    new.created_at := old.created_at;
    if not public.is_admin() then         -- users can only change comment and place
      new.subject_id := old.subject_id;
      new.slot_date  := old.slot_date;
      new.user_id    := old.user_id;
      new.done       := old.done;
    end if;
  end if;

  -- Check the place range when it is set or changed.
  if tg_op = 'INSERT' or new.place is distinct from old.place then
    v_max := public.member_count();
    if new.place is null or new.place < 1 or new.place > v_max then
      raise exception 'Place must be from 1 to %.', v_max using errcode = '22023';
    end if;
  end if;
  return new;
end $$;

-- 4. Join only on the day before the slot or on the slot day.
drop policy if exists "entries: join" on public.entries;
create policy "entries: join" on public.entries
  for insert to authenticated with check (
    public.is_member()
    and user_id = auth.uid()
    and slot_date >= public.app_today()
    and slot_date <= public.app_today() + 1
    and exists (
      select 1 from public.subjects s
      where s.id = subject_id
        and s.weekday = extract(isodow from slot_date)
    )
  );

commit;
