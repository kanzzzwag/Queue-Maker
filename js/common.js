// Shared helpers: Supabase client, theme, dates, errors, auth guard.
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
  const label = () => { btn.textContent = currentTheme() === 'dark' ? 'Light' : 'Dark'; };
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
export function errMsg(err) {
  if (!err) return 'Something went wrong.';
  const m = err.message || String(err);
  if (err.code === '23505') return 'Already in this queue.';
  if (err.code === '42501' || /row-level security/i.test(m)) return 'Not allowed. The day may be closed.';
  if (/failed to fetch|networkerror|network request|load failed/i.test(m)) return 'Network error. Try again.';
  if (/invalid login credentials/i.test(m)) return 'Wrong username or password.';
  if (/already registered|already exists/i.test(m)) return 'Username taken.';
  if (/database error saving new user/i.test(m)) return 'Registration failed. Check the group code.';
  if (/password should be/i.test(m)) return 'Password must be at least 6 characters.';
  if (/rate limit/i.test(m)) return 'Too many attempts. Wait a few minutes.';
  return m.length <= 100 ? m : 'Something went wrong.';
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

// Fills the top bar shared by index.html and admin.html.
export function setupHeader(profile) {
  const who = document.getElementById('who');
  if (who) who.textContent = profile.display_name;
  const adminLink = document.getElementById('admin-link');
  if (adminLink) adminLink.hidden = !profile.is_admin;
  document.getElementById('logout')?.addEventListener('click', async () => {
    await sb.auth.signOut();
    location.replace('login.html');
  });
}

// Disables a button while an async action runs.
export async function busy(btn, fn) {
  if (btn) btn.disabled = true;
  try { return await fn(); } finally { if (btn) btn.disabled = false; }
}
