-- =====================================================================
-- Migration 006: points (wallet + ledger) and trading queue places.
-- Run in Supabase -> SQL Editor after migration-005. Safe to run again.
-- Existing queue entries are not changed.
--
-- Balances change ONLY through security definer functions below
-- (no insert/update grants, no write policies on wallets or the ledger).
-- To remove trading later: supabase/remove-trade.sql (points stay).
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- Settings: trading switch + public flags for the pages
-- ---------------------------------------------------------------------
alter table public.settings add column if not exists trade_enabled boolean not null default false;

create or replace function public.app_flags()
returns json language sql stable security definer set search_path = '' as $$
  select case when public.is_member()
    then json_build_object('trade_enabled', coalesce((select trade_enabled from public.settings where id = 1), false))
    else null end;
$$;
revoke execute on function public.app_flags() from public, anon;
grant  execute on function public.app_flags() to authenticated;

-- ---------------------------------------------------------------------
-- Entry guard: trusted server operations (trade) may change user_id/place.
-- Only code running as the function owner can switch this on; clients
-- (roles anon/authenticated) cannot, even if they set the setting.
-- ---------------------------------------------------------------------
create or replace function public.is_trusted_op()
returns boolean language sql stable set search_path = '' as $$
  select coalesce(current_setting('app.trusted_op', true), '') = 'on'
     and current_user not in ('anon', 'authenticated');
$$;
revoke execute on function public.is_trusted_op() from public, anon;
grant  execute on function public.is_trusted_op() to authenticated;

create or replace function public.entries_guard()
returns trigger language plpgsql set search_path = '' as $$
declare
  v_max int;
begin
  new.comment := nullif(btrim(new.comment), '');
  if tg_op = 'UPDATE' and public.is_trusted_op() then
    new.created_at := old.created_at;
    return new;                            -- trade functions: move/swap entries as they need
  end if;

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

-- ---------------------------------------------------------------------
-- Wallets + ledger
-- ---------------------------------------------------------------------
create table if not exists public.wallets (
  user_id          uuid primary key references public.profiles(id) on delete cascade,
  balance          int not null default 0 check (balance >= 0),
  welcome_bonus_at timestamptz,          -- set once, never cleared: no second welcome bonus
  updated_at       timestamptz not null default now()
);

create table if not exists public.point_ledger (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  amount          int not null check (amount <> 0),
  balance_after   int not null,
  kind            text not null check (kind in ('welcome_bonus', 'trade', 'game_reward', 'weekly_prize', 'admin_adjust')),
  counterparty_id uuid references public.profiles(id) on delete set null,
  reason          text,
  ref_type        text,
  ref_id          bigint,
  created_at      timestamptz not null default now()
);
create index if not exists point_ledger_user_idx on public.point_ledger (user_id, id desc);
-- Hard stops against double payouts.
create unique index if not exists point_ledger_one_welcome on public.point_ledger (user_id) where kind = 'welcome_bonus';
create unique index if not exists point_ledger_one_reward
  on public.point_ledger (user_id, kind, ref_type, ref_id) where kind in ('game_reward', 'weekly_prize');

insert into public.wallets (user_id) select id from public.profiles on conflict do nothing;

create or replace function public.profiles_create_wallet()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.wallets (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;
drop trigger if exists profiles_create_wallet on public.profiles;
create trigger profiles_create_wallet
  after insert on public.profiles
  for each row execute function public.profiles_create_wallet();

revoke all on public.wallets      from anon, authenticated;
revoke all on public.point_ledger from anon, authenticated;
grant select on public.wallets      to authenticated;
grant select on public.point_ledger to authenticated;

alter table public.wallets      enable row level security;
alter table public.point_ledger enable row level security;

drop policy if exists "wallets: members read" on public.wallets;
create policy "wallets: members read" on public.wallets
  for select to authenticated using (public.is_member());

drop policy if exists "ledger: own or admin" on public.point_ledger;
create policy "ledger: own or admin" on public.point_ledger
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

-- The only way to move points. Locks the wallet row, writes the ledger.
-- Internal: not callable by clients.
create or replace function public._points_add(
  p_user uuid, p_amount int, p_kind text, p_counterparty uuid,
  p_reason text, p_ref_type text, p_ref_id bigint)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_balance int;
  v_id bigint;
begin
  insert into public.wallets (user_id) values (p_user) on conflict do nothing;
  select balance into v_balance from public.wallets where user_id = p_user for update;
  if v_balance + p_amount < 0 then
    raise exception 'Not enough points.';
  end if;
  update public.wallets set balance = v_balance + p_amount, updated_at = now() where user_id = p_user;
  insert into public.point_ledger (user_id, amount, balance_after, kind, counterparty_id, reason, ref_type, ref_id)
  values (p_user, p_amount, v_balance + p_amount, p_kind, p_counterparty, p_reason, p_ref_type, p_ref_id)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public._points_add(uuid, int, text, uuid, text, text, bigint) from public, anon, authenticated;

-- Welcome bonus: 1000 points, once per account, on the first confirmed email.
create or replace function public._grant_welcome_bonus(p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_at timestamptz;
begin
  insert into public.wallets (user_id) values (p_user) on conflict do nothing;
  select welcome_bonus_at into v_at from public.wallets where user_id = p_user for update;
  if v_at is not null or not public.email_verified(p_user)
     or exists (select 1 from public.point_ledger where user_id = p_user and kind = 'welcome_bonus') then
    return;
  end if;
  update public.wallets set welcome_bonus_at = now() where user_id = p_user;
  perform public._points_add(p_user, 1000, 'welcome_bonus', null, 'Welcome bonus', null, null);
end $$;
revoke execute on function public._grant_welcome_bonus(uuid) from public, anon, authenticated;

create or replace function public.account_emails_bonus()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public._grant_welcome_bonus(new.user_id);
  return new;
end $$;
drop trigger if exists account_emails_bonus on public.account_emails;
create trigger account_emails_bonus
  after insert or update on public.account_emails
  for each row execute function public.account_emails_bonus();

-- People who confirmed an email before this migration also get the bonus (once).
do $$
declare r record;
begin
  for r in select user_id from public.account_emails loop
    perform public._grant_welcome_bonus(r.user_id);
  end loop;
end $$;

-- Admin: add or remove points (through the ledger).
create or replace function public.admin_adjust_points(target uuid, amount int, reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_reason text := btrim(coalesce(reason, ''));
begin
  if not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if amount is null or amount = 0 or abs(amount) > 1000000 then
    raise exception 'Amount must be from -1000000 to 1000000, not 0.';
  end if;
  if char_length(v_reason) not between 1 and 200 then
    raise exception 'Enter a reason (max 200).';
  end if;
  if not exists (select 1 from public.profiles where id = target) then
    raise exception 'User not found.';
  end if;
  if amount > 0 and not public.email_verified(target) then
    raise exception 'This user has no confirmed email.';
  end if;
  perform public._points_add(target, amount, 'admin_adjust', auth.uid(), v_reason, null, null);
end $$;
revoke execute on function public.admin_adjust_points(uuid, int, text) from public, anon;
grant  execute on function public.admin_adjust_points(uuid, int, text) to authenticated;


-- =====================================================================
-- TRADING (experiment). Everything below is removed by remove-trade.sql.
-- =====================================================================

-- Offers: subject, date and place come from the entry (not copied).
create table if not exists public.trade_offers (
  id         bigint generated always as identity primary key,
  seller_id  uuid not null references public.profiles(id) on delete cascade,
  entry_id   bigint references public.entries(id) on delete set null,
  price      int not null check (price between 1 and 1000000),
  status     text not null default 'open' check (status in ('open', 'sold', 'cancelled', 'expired')),
  created_at timestamptz not null default now(),
  closed_at  timestamptz
);
create unique index if not exists trade_offers_one_open on public.trade_offers (entry_id) where status = 'open';
create index if not exists trade_offers_status_idx on public.trade_offers (status);

create table if not exists public.trade_bids (
  id         bigint generated always as identity primary key,
  offer_id   bigint not null references public.trade_offers(id) on delete cascade,
  buyer_id   uuid not null references public.profiles(id) on delete cascade,
  price      int not null check (price between 1 and 1000000),
  status     text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'cancelled', 'expired')),
  created_at timestamptz not null default now(),
  closed_at  timestamptz
);
create unique index if not exists trade_bids_one_pending on public.trade_bids (offer_id, buyer_id) where status = 'pending';
create index if not exists trade_bids_buyer_idx on public.trade_bids (buyer_id);

-- Completed deals (history). A snapshot, because entries are cleaned up weekly.
create table if not exists public.trades (
  id           bigint generated always as identity primary key,
  offer_id     bigint references public.trade_offers(id) on delete set null,
  bid_id       bigint references public.trade_bids(id) on delete set null,
  seller_id    uuid references public.profiles(id) on delete set null,
  buyer_id     uuid references public.profiles(id) on delete set null,
  price        int not null,
  subject_name text,
  slot_date    date,
  place        int,              -- the place the buyer got
  seller_place int,              -- swap: the place the seller got (null if the seller left)
  created_at   timestamptz not null default now()
);
create index if not exists trades_seller_idx on public.trades (seller_id);
create index if not exists trades_buyer_idx  on public.trades (buyer_id);

revoke all on public.trade_offers from anon, authenticated;
revoke all on public.trade_bids   from anon, authenticated;
revoke all on public.trades       from anon, authenticated;
grant select on public.trade_offers to authenticated;
grant select on public.trade_bids   to authenticated;
grant select on public.trades       to authenticated;

alter table public.trade_offers enable row level security;
alter table public.trade_bids   enable row level security;
alter table public.trades       enable row level security;

drop policy if exists "trade_offers: members read" on public.trade_offers;
create policy "trade_offers: members read" on public.trade_offers
  for select to authenticated using (public.is_member());

-- Bids: visible to the buyer, the seller of the offer, and admins.
drop policy if exists "trade_bids: parties read" on public.trade_bids;
create policy "trade_bids: parties read" on public.trade_bids
  for select to authenticated using (
    public.is_member() and (
      buyer_id = auth.uid()
      or public.is_admin()
      or exists (select 1 from public.trade_offers o where o.id = offer_id and o.seller_id = auth.uid())
    )
  );

drop policy if exists "trades: members read" on public.trades;
create policy "trades: members read" on public.trades
  for select to authenticated using (public.is_member());

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function public._trade_check()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce((select trade_enabled from public.settings where id = 1), false) then
    raise exception 'Trading is off';
  end if;
  if not public.is_member() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
end $$;
revoke execute on function public._trade_check() from public, anon, authenticated;

-- Expire open offers of an entry (and their pending bids).
create or replace function public._expire_offers_of_entry(p_entry bigint)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.trade_bids b set status = 'expired', closed_at = now()
  where b.status = 'pending'
    and b.offer_id in (select o.id from public.trade_offers o where o.entry_id = p_entry and o.status = 'open');
  update public.trade_offers set status = 'expired', closed_at = now()
  where entry_id = p_entry and status = 'open';
end $$;
revoke execute on function public._expire_offers_of_entry(bigint) from public, anon, authenticated;

-- Entry deleted, marked done, moved or changed hands -> its open offers expire.
create or replace function public.entries_trade_expire()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform public._expire_offers_of_entry(old.id);
    return old;
  end if;
  if new.done and not old.done
     or new.user_id is distinct from old.user_id
     or new.place is distinct from old.place
     or new.slot_date is distinct from old.slot_date
     or new.subject_id is distinct from old.subject_id then
    perform public._expire_offers_of_entry(new.id);
  end if;
  return new;
end $$;

drop trigger if exists entries_trade_expire_del on public.entries;
create trigger entries_trade_expire_del
  before delete on public.entries
  for each row execute function public.entries_trade_expire();

drop trigger if exists entries_trade_expire_upd on public.entries;
create trigger entries_trade_expire_upd
  after update on public.entries
  for each row execute function public.entries_trade_expire();

-- Cron + safety net: expire anything that is no longer valid.
create or replace function public.expire_trades()
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.trade_offers o set status = 'expired', closed_at = now()
  where o.status = 'open' and not exists (
    select 1 from public.entries e
    where e.id = o.entry_id and e.user_id = o.seller_id and not e.done and e.slot_date >= public.app_today()
  );
  update public.trade_bids b set status = 'expired', closed_at = now()
  where b.status = 'pending'
    and exists (select 1 from public.trade_offers o where o.id = b.offer_id and o.status <> 'open');
end $$;
revoke execute on function public.expire_trades() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Offers
-- ---------------------------------------------------------------------
create or replace function public.create_offer(p_entry_id bigint, p_price int)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  e public.entries;
  v_id bigint;
begin
  perform public._trade_check();
  if not public.email_verified(auth.uid()) then
    raise exception 'Confirm your email first.';
  end if;
  if p_price is null or p_price < 1 or p_price > 1000000 then
    raise exception 'Price must be from 1 to 1000000.';
  end if;
  select * into e from public.entries where id = p_entry_id for update;
  if not found or e.user_id <> auth.uid() then
    raise exception 'You can sell only your own place.';
  end if;
  if e.done then raise exception 'This entry is done.'; end if;
  if e.slot_date < public.app_today() then raise exception 'This day is closed.'; end if;
  if exists (select 1 from public.trade_offers where entry_id = e.id and status = 'open') then
    raise exception 'This place is already for sale.';
  end if;
  insert into public.trade_offers (seller_id, entry_id, price)
  values (auth.uid(), e.id, p_price) returning id into v_id;
  return v_id;
end $$;

create or replace function public.cancel_offer(p_offer_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  o public.trade_offers;
begin
  perform public._trade_check();
  select * into o from public.trade_offers where id = p_offer_id for update;
  if not found or o.seller_id <> auth.uid() then raise exception 'Offer not found.'; end if;
  if o.status <> 'open' then raise exception 'This offer is closed.'; end if;
  update public.trade_offers set status = 'cancelled', closed_at = now() where id = o.id;
  update public.trade_bids set status = 'expired', closed_at = now() where offer_id = o.id and status = 'pending';
end $$;

-- ---------------------------------------------------------------------
-- The deal itself. Locks offer, entries and both wallets (fixed order).
-- Buyer not in this queue -> the entry moves to the buyer (same place).
-- Buyer already in this queue -> the two swap places.
-- ---------------------------------------------------------------------
create or replace function public._execute_trade(p_offer_id bigint, p_buyer uuid, p_price int, p_bid_id bigint)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  o        public.trade_offers;
  e        public.entries;
  b        public.entries;
  v_has_b  boolean;
  v_bal    int;
  v_subj   text;
  v_trade  bigint;
begin
  select * into o from public.trade_offers where id = p_offer_id for update;
  if not found then raise exception 'Offer not found.'; end if;
  if o.status <> 'open' then raise exception 'This offer is no longer available.'; end if;
  if p_buyer = o.seller_id then raise exception 'You cannot buy your own place.'; end if;

  select * into e from public.entries where id = o.entry_id for update;
  if not found or e.user_id <> o.seller_id or e.done or e.slot_date < public.app_today() then
    raise exception 'This offer is no longer available.';
  end if;

  if not public.email_verified(p_buyer) then raise exception 'Confirm your email first.'; end if;
  if not public.email_verified(o.seller_id) then raise exception 'The seller has no confirmed email.'; end if;

  -- Lock both wallets in a fixed order (no deadlocks), then check the money.
  insert into public.wallets (user_id) values (p_buyer), (o.seller_id) on conflict do nothing;
  perform 1 from public.wallets where user_id in (p_buyer, o.seller_id) order by user_id for update;
  select balance into v_bal from public.wallets where user_id = p_buyer;
  if v_bal < p_price then raise exception 'Not enough points.'; end if;

  select * into b from public.entries
  where subject_id = e.subject_id and slot_date = e.slot_date and user_id = p_buyer
  for update;
  v_has_b := found;
  if v_has_b and b.done then raise exception 'Your entry in this queue is done.'; end if;

  -- Close the offer and bids first (the entry triggers expire only OPEN offers).
  update public.trade_offers set status = 'sold', closed_at = now() where id = o.id;
  if p_bid_id is not null then
    update public.trade_bids set status = 'accepted', closed_at = now() where id = p_bid_id;
  end if;
  update public.trade_bids set status = 'expired', closed_at = now() where offer_id = o.id and status = 'pending';

  -- Move the place. Trusted mode lets entries_guard accept the change.
  perform set_config('app.trusted_op', 'on', true);
  if not v_has_b then
    update public.entries set user_id = p_buyer, comment = null where id = e.id;
  else
    -- Swap through a temporary place (the unique constraint is checked per row).
    update public.entries set place = 2147483647 where id = b.id;
    update public.entries set place = b.place    where id = e.id;
    update public.entries set place = e.place    where id = b.id;
  end if;
  perform set_config('app.trusted_op', 'off', true);

  select name into v_subj from public.subjects where id = e.subject_id;
  insert into public.trades (offer_id, bid_id, seller_id, buyer_id, price, subject_name, slot_date, place, seller_place)
  values (o.id, p_bid_id, o.seller_id, p_buyer, p_price, v_subj, e.slot_date, e.place,
          case when v_has_b then b.place end)
  returning id into v_trade;

  perform public._points_add(p_buyer,     -p_price, 'trade', o.seller_id, 'Bought a place', 'trades', v_trade);
  perform public._points_add(o.seller_id,  p_price, 'trade', p_buyer,     'Sold a place',   'trades', v_trade);
  return v_trade;
end $$;
revoke execute on function public._execute_trade(bigint, uuid, int, bigint) from public, anon, authenticated;

create or replace function public.buy_now(p_offer_id bigint)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_price int;
begin
  perform public._trade_check();
  select price into v_price from public.trade_offers where id = p_offer_id;
  if v_price is null then raise exception 'Offer not found.'; end if;
  return public._execute_trade(p_offer_id, auth.uid(), v_price, null);
end $$;

-- ---------------------------------------------------------------------
-- Bids
-- ---------------------------------------------------------------------
create or replace function public.place_bid(p_offer_id bigint, p_price int)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  o public.trade_offers;
  v_id bigint;
begin
  perform public._trade_check();
  if not public.email_verified(auth.uid()) then raise exception 'Confirm your email first.'; end if;
  if p_price is null or p_price < 1 or p_price > 1000000 then
    raise exception 'Price must be from 1 to 1000000.';
  end if;
  select * into o from public.trade_offers where id = p_offer_id for update;
  if not found or o.status <> 'open' then raise exception 'This offer is no longer available.'; end if;
  if o.seller_id = auth.uid() then raise exception 'This is your own offer.'; end if;
  if not exists (
    select 1 from public.entries e
    where e.id = o.entry_id and not e.done and e.slot_date >= public.app_today()
  ) then
    raise exception 'This offer is no longer available.';
  end if;
  if coalesce((select balance from public.wallets where user_id = auth.uid()), 0) < p_price then
    raise exception 'Not enough points.';
  end if;
  if exists (select 1 from public.trade_bids where offer_id = o.id and buyer_id = auth.uid() and status = 'pending') then
    raise exception 'You already made an offer. Cancel it first.';
  end if;
  insert into public.trade_bids (offer_id, buyer_id, price) values (o.id, auth.uid(), p_price)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.cancel_bid(p_bid_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._trade_check();
  update public.trade_bids set status = 'cancelled', closed_at = now()
  where id = p_bid_id and buyer_id = auth.uid() and status = 'pending';
  if not found then raise exception 'Offer not found.'; end if;
end $$;

create or replace function public.decline_bid(p_bid_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public._trade_check();
  update public.trade_bids b set status = 'declined', closed_at = now()
  where b.id = p_bid_id and b.status = 'pending'
    and exists (select 1 from public.trade_offers o where o.id = b.offer_id and o.seller_id = auth.uid());
  if not found then raise exception 'Offer not found.'; end if;
end $$;

create or replace function public.accept_bid(p_bid_id bigint)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  bd public.trade_bids;
begin
  perform public._trade_check();
  select * into bd from public.trade_bids where id = p_bid_id for update;
  if not found or not exists (
    select 1 from public.trade_offers o where o.id = bd.offer_id and o.seller_id = auth.uid()
  ) then
    raise exception 'Offer not found.';
  end if;
  if bd.status <> 'pending' then raise exception 'This offer is no longer available.'; end if;
  return public._execute_trade(bd.offer_id, bd.buyer_id, bd.price, bd.id);
end $$;

revoke execute on function public.create_offer(bigint, int)  from public, anon;
revoke execute on function public.cancel_offer(bigint)       from public, anon;
revoke execute on function public.buy_now(bigint)            from public, anon;
revoke execute on function public.place_bid(bigint, int)     from public, anon;
revoke execute on function public.cancel_bid(bigint)         from public, anon;
revoke execute on function public.decline_bid(bigint)        from public, anon;
revoke execute on function public.accept_bid(bigint)         from public, anon;
grant  execute on function public.create_offer(bigint, int)  to authenticated;
grant  execute on function public.cancel_offer(bigint)       to authenticated;
grant  execute on function public.buy_now(bigint)            to authenticated;
grant  execute on function public.place_bid(bigint, int)     to authenticated;
grant  execute on function public.cancel_bid(bigint)         to authenticated;
grant  execute on function public.decline_bid(bigint)        to authenticated;
grant  execute on function public.accept_bid(bigint)         to authenticated;

-- ---------------------------------------------------------------------
-- Realtime on offers and bids
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['trade_offers', 'trade_bids'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Cron: expire stale offers/bids every day at 00:05 Almaty (and the triggers do it live).
select cron.schedule('trade-expire', '5 19 * * *', $$ select public.expire_trades() $$);

commit;
