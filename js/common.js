// Shared helpers: Supabase client, header/menu, theme, dates, errors, auth guard.
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY, EMAIL_DOMAIN } from '../config.js';

export const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ---------- Usernames ----------
export const USERNAME_RE = /^[a-z0-9_]{3,20}$/;
export const toEmail = (username) => `${username}@${EMAIL_DOMAIN}`;

// ---------- Escaping (use for every piece of user text put into HTML) ----------
const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ESC[c]);

// ---------- Theme ----------
function currentTheme() {
  const t = document.documentElement.dataset.theme;
  if (t) return t;
  return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

export function initThemeToggle(btn) {
  if (!btn) return;
  const label = () => { btn.textContent = currentTheme() === 'dark' ? 'Light theme' : 'Dark theme'; };
  label();
  btn.addEventListener('click', () => {
    const next = currentTheme() === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem('theme', next); } catch (e) { /* ignore */ }
    label();
  });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', label);
}

// ---------- Toast messages ----------
let toastTimer;
export function toast(text, kind = 'error') {
  let el = document.getElementById('toast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'toast';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    document.body.append(el);
  }
  el.textContent = text;
  el.className = `toast show ${kind}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.className = 'toast'; }, 3500);
}

// ---------- Error messages (short, human) ----------
// notAllowed: text for permission errors (RLS), depends on the page.
export function errMsg(err, notAllowed = 'Not allowed.') {
  if (!err) return 'Something went wrong.';
  // Errors from different libraries carry the text in different fields.
  const raw = [err.message, err.error_description, err.msg, err.error].find((x) => typeof x === 'string' && x);
  const m = raw || (typeof err === 'string' ? err : 'Something went wrong.');
  if (err.code === '23505') {
    if (/entries_slot_place_key/.test(m)) return 'Place taken. Pick another.';
    if (/entries_/.test(m)) return 'Already in this queue.';
    return 'Already exists.';
  }
  if (err.code === '22023') return m;   // "Place must be from 1 to N."
  if (err.code === '42501' || /row-level security|not allowed|permission denied/i.test(m)) return notAllowed;
  if (/failed to fetch|networkerror|network request|load failed/i.test(m)) return 'Network error. Try again.';
  if (/invalid login credentials/i.test(m)) return 'Wrong username or password.';
  if (/already registered|already exists/i.test(m)) return 'Username taken.';
  if (/database error saving new user/i.test(m)) return 'Registration failed. Check the group code.';
  if (/password should be/i.test(m)) return 'Password must be at least 6 characters.';
  if (/rate limit/i.test(m)) return 'Too many attempts. Wait a few minutes.';
  return m.length <= 120 ? m : 'Something went wrong.';
}

// ---------- Edge Functions ----------
// Returns { data, error }. error is an Error with a short message.
export async function callFn(name, body = {}) {
  const { data: { session } } = await sb.auth.getSession();
  const headers = { 'Content-Type': 'application/json', apikey: SUPABASE_ANON_KEY };
  if (session) headers.Authorization = `Bearer ${session.access_token}`;
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/${name}`, {
      method: 'POST', headers, body: JSON.stringify(body),
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) return { data: null, error: new Error(json.error || 'Something went wrong.') };
    return { data: json, error: null };
  } catch (e) {
    return { data: null, error: new Error('Network error. Try again.') };
  }
}

// ---------- Dates (all "today" logic uses Asia/Almaty) ----------
// Dates are handled as 'YYYY-MM-DD' strings; math is done in UTC to avoid DST/offset issues.
export const TZ = 'Asia/Almaty';
export const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

export function todayStr() {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(new Date());
  const get = (t) => parts.find((p) => p.type === t).value;
  return `${get('year')}-${get('month')}-${get('day')}`;
}

const toDate = (s) => new Date(`${s}T00:00:00Z`);

export function addDays(s, n) {
  const d = toDate(s);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

// 1 = Monday ... 7 = Sunday
export function isoWeekday(s) {
  const d = toDate(s).getUTCDay();
  return d === 0 ? 7 : d;
}

export const weekStart = (s) => addDays(s, 1 - isoWeekday(s));

export const fmtDate = (s, opts = { day: 'numeric', month: 'short' }) =>
  toDate(s).toLocaleDateString('en-GB', { timeZone: 'UTC', ...opts });

export const fmtTime = (t) => (t || '').slice(0, 5);

// Current Almaty date-time as 'YYYY-MM-DDTHH:MM:SS' (sortable string).
export function nowLocalStr() {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date());
  const get = (t) => parts.find((p) => p.type === t).value;
  return `${get('year')}-${get('month')}-${get('day')}T${get('hour')}:${get('minute')}:${get('second')}`;
}

// ---------- Subjects: schedule by week + open time (same rules as the database) ----------
export const subjectActiveOn = (s, date) =>
  s.weekday === isoWeekday(date)
  && (!s.valid_from || date >= s.valid_from)
  && (!s.valid_until || date <= s.valid_until);

// Moment joining opens, 'YYYY-MM-DDTHH:MM:SS' in Almaty time.
export const opensAt = (s, date) =>
  `${addDays(date, -(s.open_days_before ?? 1))}T${(s.open_time || '00:00:00').padEnd(8, ':00').slice(0, 8)}`;

// Timestamp -> "14:05" (today) or "3 Nov, 14:05", in Asia/Almaty.
export function fmtStamp(iso, { alwaysDate = false } = {}) {
  const d = new Date(iso);
  const time = d.toLocaleTimeString('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit' });
  const day = new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(d);
  if (!alwaysDate && day === todayStr()) return time;
  return `${fmtDate(day)}, ${time}`;
}

// ---------- Profiles: links and avatars ----------
export const profileUrl = (username) => `profile.html?u=${encodeURIComponent(username)}`;

// <a> with the display name, linking to the profile. p = { username, display_name }.
export function nameLink(p, cls = 'name') {
  if (!p) return `<span class="${cls}">Unknown</span>`;
  return `<a class="${cls} plain-link" href="${esc(profileUrl(p.username))}">${esc(p.display_name)}</a>`;
}

export const mediaUrl = (bucket, path) =>
  path ? sb.storage.from(bucket).getPublicUrl(path).data.publicUrl : '';

function initials(name) {
  const parts = String(name || '?').trim().split(/\s+/).filter(Boolean);
  return ((parts[0]?.[0] || '?') + (parts.length > 1 ? parts[parts.length - 1][0] : '')).toUpperCase();
}

// Round avatar: the uploaded picture, or a circle with initials.
export function avatarHtml(p, size = 32) {
  const style = `width:${size}px;height:${size}px;font-size:${Math.round(size * 0.4)}px`;
  if (p?.avatar_path) {
    return `<img class="avatar" style="${style}" src="${esc(mediaUrl('avatars', p.avatar_path))}" alt="" loading="lazy">`;
  }
  return `<span class="avatar avatar-initials" style="${style}" aria-hidden="true">${esc(initials(p?.display_name))}</span>`;
}

// ---------- Feature flags (trade on/off) ----------
export async function getFlags() {
  const { data, error } = await sb.rpc('app_flags');
  if (error || !data) return { trade_enabled: false };
  return data;
}

export async function getBalance(userId) {
  const { data, error } = await sb.from('wallets').select('balance').eq('user_id', userId).maybeSingle();
  if (error) return null;
  return data ? data.balance : 0;
}

export const fmtPoints = (n) => `${Number(n || 0).toLocaleString('en-US')} pts`;

// ---------- Auth guard ----------
// Returns the current user's profile, or redirects to login.
export async function requireProfile({ admin = false } = {}) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { location.replace('login.html'); return null; }

  const { data, error } = await sb.from('profiles').select('*').eq('id', session.user.id).maybeSingle();
  if (error) { toast(errMsg(error)); return null; }
  if (!data) {
    // Account exists but has no profile (e.g. removed by admin).
    await sb.auth.signOut();
    location.replace('login.html?m=noprofile');
    return null;
  }
  if (admin && !data.is_admin) { location.replace('index.html'); return null; }
  return data;
}

// ---------- Page header with compact menu ----------
const NAV = [
  ['queue', 'index.html', 'Queue'],
  ['chat', 'chat.html', 'Chat'],
  ['trade', 'trade.html', 'Trade'],
  ['game', 'game.html', 'Daily Word'],
  ['profile', 'profile.html', 'Profile'],
  ['admin', 'admin.html', 'Admin'],
];

function renderHeader(active) {
  const bar = document.getElementById('topbar');
  if (!bar) return;
  bar.innerHTML = `
    <div class="wrap wrap-wide topbar-inner">
      <a class="brand" href="index.html">Defense Queue</a>
      <span id="balance" class="chip" hidden></span>
      <button type="button" id="menu-btn" class="btn ghost menu-btn" aria-expanded="false" aria-controls="nav">Menu<span class="dot" data-dot hidden></span></button>
      <nav id="nav" class="nav">
        ${NAV.map(([key, href, label]) => `
          <a class="nav-link" href="${href}" data-nav="${key}"${key === active ? ' aria-current="page"' : ''}
             ${key === 'trade' || key === 'admin' ? 'hidden' : ''}>${label}${key === 'trade' ? '<span class="dot" data-dot hidden></span>' : ''}</a>`).join('')}
        <button type="button" id="theme" class="nav-link nav-btn">Dark theme</button>
        <button type="button" id="logout" class="nav-link nav-btn">Log out</button>
      </nav>
    </div>`;

  const btn = bar.querySelector('#menu-btn');
  const nav = bar.querySelector('#nav');
  btn.addEventListener('click', () => {
    const open = nav.classList.toggle('open');
    btn.setAttribute('aria-expanded', String(open));
  });
  // Close the menu when clicking outside it.
  document.addEventListener('click', (ev) => {
    if (nav.classList.contains('open') && !bar.contains(ev.target)) {
      nav.classList.remove('open');
      btn.setAttribute('aria-expanded', 'false');
    }
  });
  initThemeToggle(bar.querySelector('#theme'));
  bar.querySelector('#logout').addEventListener('click', async () => {
    await sb.auth.signOut();
    location.replace('login.html');
  });
}

// Shows the points balance in the header.
export async function showBalance(profile) {
  const el = document.getElementById('balance');
  if (!el) return;
  const bal = await getBalance(profile.id);
  if (bal === null) return;
  el.textContent = fmtPoints(bal);
  el.hidden = false;
}

// Every logged-in page starts with this. Returns { profile, flags } or null.
export async function initPage(active, { admin = false, balance = false } = {}) {
  renderHeader(active);
  const profile = await requireProfile({ admin });
  if (!profile) return null;
  const flags = await getFlags();
  document.querySelector('[data-nav="admin"]')?.toggleAttribute('hidden', !profile.is_admin);
  document.querySelector('[data-nav="trade"]')?.toggleAttribute('hidden', !flags.trade_enabled);
  const me = document.querySelector('[data-nav="profile"]');
  if (me) me.href = profileUrl(profile.username);
  if (balance) showBalance(profile);
  // Red dot on "Trade" when there is something new (the Trade page itself clears it).
  if (flags.trade_enabled && active !== 'trade') watchTradeDot();
  return { profile, flags };
}

// ---------- "New in Trade" dot ----------
export function setTradeDot(show) {
  document.querySelectorAll('[data-dot]').forEach((d) => { d.hidden = !show; });
  document.querySelector('[data-nav="trade"]')?.setAttribute('aria-label', show ? 'Trade (new)' : 'Trade');
}

async function refreshTradeDot() {
  const { data, error } = await sb.rpc('trade_unseen_count');
  if (!error) setTradeDot(data > 0);
}

function watchTradeDot() {
  refreshTradeDot();
  let t;
  const later = () => { clearTimeout(t); t = setTimeout(refreshTradeDot, 500); };
  sb.channel('trade-dot')
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'trade_offers' }, later)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'trade_bids' }, later)
    .subscribe();
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') refreshTradeDot(); });
}

// Disables a button while an async action runs.
export async function busy(btn, fn) {
  if (btn) btn.disabled = true;
  try { return await fn(); } finally { if (btn) btn.disabled = false; }
}

// Simple tab strip: buttons with data-tab, panels with data-panel. Remembers the tab in the URL hash.
export function setupTabs(stripId, fallback, onShow) {
  const tabs = document.querySelectorAll(`#${stripId} button[data-tab]`);
  const show = (name) => {
    tabs.forEach((b) => b.setAttribute('aria-selected', String(b.dataset.tab === name)));
    document.querySelectorAll('[data-panel]').forEach((p) => { p.hidden = p.dataset.panel !== name; });
    onShow?.(name);
  };
  tabs.forEach((b) => b.addEventListener('click', () => {
    history.replaceState(null, '', `${location.search}#${b.dataset.tab}`);
    show(b.dataset.tab);
  }));
  const fromHash = location.hash.slice(1);
  show([...tabs].some((b) => b.dataset.tab === fromHash) ? fromHash : fallback);
  return show;
}
