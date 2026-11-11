// Trade page: sell queue places for points, buy now or make an offer.
// All checks and the transfer itself happen in database functions (RPC).
import {
  sb, esc, toast, errMsg, busy, initPage, setupTabs, showBalance, nameLink,
  todayStr, fmtDate, fmtTime, fmtStamp, fmtPoints,
} from './common.js';

const ctx = await initPage('trade', { balance: true });
if (ctx) init(ctx.profile, ctx.flags);

const OFFER_SEL = `id, price, status, created_at, closed_at, seller_id,
  seller:profiles!trade_offers_seller_id_fkey(username, display_name),
  entry:entries(id, place, slot_date, done, user_id, subject:subjects(name, start_time))`;

// "Math · Tue 5 Nov · place 3"
function slotText(entry) {
  if (!entry) return '<span class="muted">Entry removed</span>';
  return `<strong>${esc(entry.subject?.name || 'Subject')}</strong>
    <span class="muted">${esc(fmtDate(entry.slot_date, { weekday: 'short', day: 'numeric', month: 'short' }))}
    ${entry.subject?.start_time ? esc(fmtTime(entry.subject.start_time)) : ''}</span>
    <span class="tag">Place ${entry.place}</span>`;
}

const STATUS_TAG = {
  open: '', sold: '<span class="tag tag-ok">Sold</span>', cancelled: '<span class="tag">Cancelled</span>',
  expired: '<span class="tag">Expired</span>', pending: '<span class="tag">Pending</span>',
  accepted: '<span class="tag tag-ok">Accepted</span>', declined: '<span class="tag tag-bad">Declined</span>',
};

async function init(me, flags) {
  const off = !flags.trade_enabled;
  document.getElementById('trade-off').hidden = !off;

  const { data: verified } = await sb.rpc('email_verified', { uid: me.id });
  document.getElementById('email-hint').hidden = !!verified;

  const el = {
    market: document.getElementById('market'),
    offers: document.getElementById('my-offers'),
    bids: document.getElementById('my-bids'),
    history: document.getElementById('history'),
  };
  let tab = 'market';
  let bidFor = null;     // offer id with the open "Offer price" form

  // ---------- Market ----------
  async function loadMarket() {
    const { data, error } = await sb.from('trade_offers').select(OFFER_SEL)
      .eq('status', 'open').order('created_at', { ascending: false });
    if (error) return toast(errMsg(error));
    const today = todayStr();
    const list = data.filter((o) => o.entry && !o.entry.done && o.entry.slot_date >= today)
      .sort((a, b) => a.entry.slot_date.localeCompare(b.entry.slot_date)
        || (a.entry.subject?.start_time || '').localeCompare(b.entry.subject?.start_time || '')
        || a.entry.place - b.entry.place);
    el.market.innerHTML = list.length ? `<ul class="rows card">${list.map((o) => {
      const mine = o.seller_id === me.id;
      return `
        <li class="row-item trade-row">
          <div class="trade-main">
            <div>${slotText(o.entry)}</div>
            <div class="muted small-text">Seller: ${nameLink(o.seller, 'plain-link')}</div>
          </div>
          <div class="trade-side">
            <strong class="price">${esc(fmtPoints(o.price))}</strong>
            ${mine ? '<span class="tag tag-you">Yours</span>' : `
              <div class="entry-actions">
                <button type="button" class="btn small primary" data-action="buy" data-id="${o.id}"
                        data-price="${o.price}">Buy</button>
                <button type="button" class="btn small" data-action="bid-form" data-id="${o.id}">Offer price</button>
              </div>`}
          </div>
          ${bidFor === o.id ? `
            <form class="inline-form bid-form" data-offer="${o.id}">
              <input name="price" type="number" min="1" max="1000000" step="1" inputmode="numeric"
                     placeholder="Your price" aria-label="Your price" required>
              <button class="btn small primary">Send</button>
              <button type="button" class="btn small" data-action="bid-close">Back</button>
            </form>` : ''}
        </li>`;
    }).join('')}</ul>` : '<p class="muted center">Nothing for sale.</p>';
  }

  // ---------- My offers (with incoming bids) ----------
  async function loadOffers() {
    const { data, error } = await sb.from('trade_offers').select(OFFER_SEL)
      .eq('seller_id', me.id).order('created_at', { ascending: false }).limit(30);
    if (error) return toast(errMsg(error));
    const openIds = data.filter((o) => o.status === 'open').map((o) => o.id);
    let bids = [];
    if (openIds.length) {
      const res = await sb.from('trade_bids')
        .select('id, offer_id, price, status, created_at, buyer:profiles!trade_bids_buyer_id_fkey(username, display_name)')
        .in('offer_id', openIds).eq('status', 'pending').order('price', { ascending: false });
      if (res.error) return toast(errMsg(res.error));
      bids = res.data;
    }
    el.offers.innerHTML = data.length ? `<ul class="rows card">${data.map((o) => {
      const incoming = bids.filter((b) => b.offer_id === o.id);
      return `
        <li class="row-item trade-row${o.status === 'open' ? '' : ' closed-row'}">
          <div class="trade-main"><div>${slotText(o.entry)}</div></div>
          <div class="trade-side">
            <strong class="price">${esc(fmtPoints(o.price))}</strong>
            ${STATUS_TAG[o.status]}
            ${o.status === 'open' ? `<button type="button" class="btn small" data-action="cancel-offer" data-id="${o.id}">Cancel</button>` : ''}
          </div>
          ${incoming.length ? `<ul class="bids">${incoming.map((b) => `
            <li>
              <span>${nameLink(b.buyer, 'plain-link')} offers <strong>${esc(fmtPoints(b.price))}</strong></span>
              <span class="entry-actions">
                <button type="button" class="btn small primary" data-action="accept" data-id="${b.id}"
                        data-price="${b.price}">Accept</button>
                <button type="button" class="btn small" data-action="decline" data-id="${b.id}">Decline</button>
              </span>
            </li>`).join('')}</ul>` : ''}
        </li>`;
    }).join('')}</ul>` : '<p class="muted center">No offers yet. Use "Sell" on your entry in the queue.</p>';
  }

  // ---------- My bids ----------
  async function loadBids() {
    const { data, error } = await sb.from('trade_bids')
      .select(`id, price, status, created_at, offer:trade_offers(id, price, status,
        seller:profiles!trade_offers_seller_id_fkey(username, display_name),
        entry:entries(place, slot_date, subject:subjects(name, start_time)))`)
      .eq('buyer_id', me.id).order('created_at', { ascending: false }).limit(50);
    if (error) return toast(errMsg(error));
    el.bids.innerHTML = data.length ? `<ul class="rows card">${data.map((b) => `
      <li class="row-item trade-row${b.status === 'pending' ? '' : ' closed-row'}">
        <div class="trade-main">
          <div>${slotText(b.offer?.entry)}</div>
          <div class="muted small-text">Seller: ${nameLink(b.offer?.seller, 'plain-link')} · asks ${esc(fmtPoints(b.offer?.price))}</div>
        </div>
        <div class="trade-side">
          <strong class="price">${esc(fmtPoints(b.price))}</strong>
          ${STATUS_TAG[b.status]}
          ${b.status === 'pending' ? `<button type="button" class="btn small" data-action="cancel-bid" data-id="${b.id}">Cancel</button>` : ''}
        </div>
      </li>`).join('')}</ul>` : '<p class="muted center">No bids yet.</p>';
  }

  // ---------- History ----------
  async function loadHistory() {
    const { data, error } = await sb.from('trades')
      .select(`*, seller:profiles!trades_seller_id_fkey(username, display_name),
        buyer:profiles!trades_buyer_id_fkey(username, display_name)`)
      .or(`seller_id.eq.${me.id},buyer_id.eq.${me.id}`)
      .order('created_at', { ascending: false }).limit(50);
    if (error) return toast(errMsg(error));
    el.history.innerHTML = data.length ? `<ul class="rows card">${data.map((t) => {
      const sold = t.seller_id === me.id;
      return `
        <li class="row-item trade-row">
          <div class="trade-main">
            <div><strong>${esc(t.subject_name || 'Subject')}</strong>
              <span class="muted">${t.slot_date ? esc(fmtDate(t.slot_date)) : ''}</span>
              <span class="tag">Place ${t.place}</span></div>
            <div class="muted small-text">
              ${sold ? `Sold to ${nameLink(t.buyer, 'plain-link')}` : `Bought from ${nameLink(t.seller, 'plain-link')}`}
              ${t.seller_place ? ` · swapped (${sold ? 'you got' : 'seller got'} place ${t.seller_place})` : ''}
              · ${esc(fmtStamp(t.created_at, { alwaysDate: true }))}
            </div>
          </div>
          <div class="trade-side">
            <strong class="price ${sold ? 'plus' : 'minus'}">${sold ? '+' : '−'}${esc(fmtPoints(t.price))}</strong>
          </div>
        </li>`;
    }).join('')}</ul>` : '<p class="muted center">No trades yet.</p>';
  }

  const loaders = { market: loadMarket, offers: loadOffers, bids: loadBids, history: loadHistory };
  // The user is looking at Trade: everything up to now counts as seen (clears the red dot).
  const markSeen = () => { if (document.visibilityState === 'visible') sb.rpc('mark_trade_seen').then(() => {}); };
  const reload = () => { loaders[tab](); showBalance(me); markSeen(); };
  markSeen();

  setupTabs('trade-tabs', 'market', (name) => { tab = name; loaders[name](); });

  // ---------- Actions ----------
  async function rpc(btn, fn, args, okText) {
    return busy(btn, async () => {
      const { error } = await sb.rpc(fn, args);
      if (error) { toast(errMsg(error)); reload(); return false; }
      if (okText) toast(okText, 'ok');
      reload();
      return true;
    });
  }

  document.querySelector('main').addEventListener('click', async (ev) => {
    const btn = ev.target.closest('button[data-action]');
    if (!btn) return;
    const id = Number(btn.dataset.id);
    switch (btn.dataset.action) {
      case 'buy':
        if (!confirm(`Buy this place for ${fmtPoints(btn.dataset.price)}?`)) return;
        await rpc(btn, 'buy_now', { p_offer_id: id }, 'Bought. The place is yours.');
        break;
      case 'bid-form':
        bidFor = id;
        await loadMarket();
        document.querySelector(`form[data-offer="${id}"] input`)?.focus();
        break;
      case 'bid-close':
        bidFor = null;
        loadMarket();
        break;
      case 'cancel-offer':
        if (!confirm('Take this place off the market?')) return;
        await rpc(btn, 'cancel_offer', { p_offer_id: id }, 'Cancelled.');
        break;
      case 'accept':
        if (!confirm(`Sell for ${fmtPoints(btn.dataset.price)}? Your place goes to the buyer.`)) return;
        await rpc(btn, 'accept_bid', { p_bid_id: id }, 'Sold.');
        break;
      case 'decline':
        await rpc(btn, 'decline_bid', { p_bid_id: id }, 'Declined.');
        break;
      case 'cancel-bid':
        await rpc(btn, 'cancel_bid', { p_bid_id: id }, 'Cancelled.');
        break;
    }
  });

  el.market.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const form = ev.target;
    const price = Math.trunc(Number(form.price.value));
    if (!(price >= 1 && price <= 1000000)) return toast('Price must be from 1 to 1000000.');
    const ok = await rpc(form.querySelector('button:not([type=button])'), 'place_bid',
      { p_offer_id: Number(form.dataset.offer), p_price: price }, 'Offer sent.');
    if (ok) { bidFor = null; loadMarket(); }
  });

  // ---------- Sell form (from the queue's "Sell" button) ----------
  const sellId = Number(new URLSearchParams(location.search).get('sell'));
  if (sellId && !off) {
    const form = document.getElementById('sell-form');
    const { data: entry } = await sb.from('entries')
      .select('id, place, slot_date, done, user_id, subject:subjects(name, start_time)').eq('id', sellId).maybeSingle();
    if (entry && entry.user_id === me.id) {
      document.getElementById('sell-info').innerHTML = slotText(entry);
      form.hidden = false;
      form.price.focus();
      form.addEventListener('submit', async (ev) => {
        ev.preventDefault();
        const price = Math.trunc(Number(form.price.value));
        if (!(price >= 1 && price <= 1000000)) return toast('Price must be from 1 to 1000000.');
        await busy(form.querySelector('button[type=submit]'), async () => {
          const { error } = await sb.rpc('create_offer', { p_entry_id: entry.id, p_price: price });
          if (error) return toast(errMsg(error));
          toast('On sale.', 'ok');
          form.hidden = true;
          history.replaceState(null, '', 'trade.html#offers');
          document.querySelector('#trade-tabs [data-tab="offers"]').click();
        });
      });
    }
  }

  // ---------- Live updates ----------
  let timer;
  const later = () => { clearTimeout(timer); timer = setTimeout(reload, 300); };
  sb.channel('trade-live')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'trade_offers' }, later)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'trade_bids' }, later)
    .subscribe();
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') reload(); });
}
