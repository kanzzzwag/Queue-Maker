// Login page.
import { sb, toEmail, toast, errMsg, busy, initThemeToggle } from './common.js';

initThemeToggle(document.getElementById('theme'));

// Already logged in -> go to the queue.
const { data: { session } } = await sb.auth.getSession();
if (session) location.replace('index.html');

if (new URLSearchParams(location.search).get('m') === 'noprofile') {
  toast('Account not found. Register again.');
}

const form = document.getElementById('login-form');
form.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const username = form.username.value.trim().toLowerCase();
  const password = form.password.value;
  if (!username || !password) return toast('Enter username and password.');

  await busy(form.querySelector('button[type=submit]'), async () => {
    const { error } = await sb.auth.signInWithPassword({ email: toEmail(username), password });
    if (error) return toast(errMsg(error));
    location.replace('index.html');
  });
});
