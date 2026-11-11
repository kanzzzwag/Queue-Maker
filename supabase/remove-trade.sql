-- =====================================================================
-- Remove trading completely (tables, functions, triggers, cron).
-- Points (wallets, ledger), the game and the queue stay.
-- Ledger rows of past trades stay too, so balances still match the ledger.
-- Run in Supabase -> SQL Editor. Safe to run again.
-- =====================================================================
begin;

-- Cron job
do $$
begin
  if exists (select 1 from cron.job where jobname = 'trade-expire') then
    perform cron.unschedule('trade-expire');
  end if;
end $$;

-- Triggers on entries
drop trigger if exists entries_trade_expire_del on public.entries;
drop trigger if exists entries_trade_expire_upd on public.entries;

-- Functions
drop function if exists public.buy_now(bigint);
drop function if exists public.place_bid(bigint, int);
drop function if exists public.cancel_bid(bigint);
drop function if exists public.decline_bid(bigint);
drop function if exists public.accept_bid(bigint);
drop function if exists public.create_offer(bigint, int);
drop function if exists public.cancel_offer(bigint);
drop function if exists public._execute_trade(bigint, uuid, int, bigint);
drop function if exists public.expire_trades();
drop function if exists public.entries_trade_expire();
drop function if exists public._expire_offers_of_entry(bigint);
drop function if exists public._trade_check();
drop function if exists public.trade_unseen_count();   -- "new in Trade" dot (migration 008)
drop function if exists public.mark_trade_seen();
drop table if exists public.trade_seen;

-- Tables (also removes them from Realtime)
drop table if exists public.trades;
drop table if exists public.trade_bids;
drop table if exists public.trade_offers;

-- Switch: keep the column (harmless) but force it off; pages hide the Trade link.
update public.settings set trade_enabled = false where id = 1;
create or replace function public.app_flags()
returns json language sql stable security definer set search_path = '' as $$
  select case when public.is_member() then json_build_object('trade_enabled', false) else null end;
$$;

commit;
