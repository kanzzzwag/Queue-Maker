// Login page. Login goes through the "login" Edge Function, which finds the
// user's email on the server (real or username@queue.local).
import { sb, callFn, toast, busy, initThemeToggle } from './common.js';

initThemeToggle(document.getElementById('theme'));

// Already logged in -> go to the queue.
const { data: { session } } = await sb.auth.getSession();
if (session) location.replace('index.html');

if (new URLSearchParams(location.search).get('m') === 'noprofile') {
  toast('Account not found. Register again.');
}

const form = document.getElementById('login-form');
const forgot = document.getElementById('forgot-form');

form.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const username = form.username.value.trim().toLowerCase();
  const password = form.password.value;
  if (!username || !password) return toast('Enter username and password.');

  await busy(form.querySelector('button[type=submit]'), async () => {
    const { data, error } = await callFn('login', { username, password });
    if (error) return toast(error.message);
    const { error: setErr } = await sb.auth.setSession({
      access_token: data.access_token, refresh_token: data.refresh_token,
    });
    if (setErr) return toast('Something went wrong.');
    location.replace('index.html');
  });
});

// ---------- Forgot password ----------
function showForgot(show) {
  form.hidden = show;
  forgot.hidden = !show;
  if (show) {
    forgot.username.value = form.username.value.trim();
    forgot.username.focus();
  }
}
document.getElementById('forgot-link').addEventListener('click', (ev) => { ev.preventDefault(); showForgot(true); });
document.getElementById('back-link').addEventListener('click', (ev) => { ev.preventDefault(); showForgot(false); });
if (location.hash === '#forgot') showForgot(true);

forgot.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const username = forgot.username.value.trim().toLowerCase();
  if (!username) return toast('Enter your username.');
  await busy(forgot.querySelector('button[type=submit]'), async () => {
    const { data, error } = await callFn('forgot-password', { username });
    if (error) return toast(error.message);
    const done = document.getElementById('forgot-done');
    done.textContent = data.message;   // always the same text
    done.hidden = false;
  });
});
