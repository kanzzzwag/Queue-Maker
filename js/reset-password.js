// Reset password page. Opened from the email link: supabase-js reads the
// recovery session from the URL hash, then we set the new password.
import { sb, toast, errMsg, busy, initThemeToggle } from './common.js';

initThemeToggle(document.getElementById('theme'));

const form = document.getElementById('reset-form');
const wait = document.getElementById('reset-wait');
const bad = document.getElementById('reset-bad');

// supabase-js may already have read and cleared the hash; errors stay in it.
const linkError = new URLSearchParams(location.hash.slice(1)).get('error_description');

function ready(ok) {
  wait.hidden = true;
  form.hidden = !ok;
  bad.hidden = ok;
}

let decided = false;
sb.auth.onAuthStateChange((event) => {
  if (!decided && event === 'PASSWORD_RECOVERY') {
    decided = true;
    ready(true);
  }
});

// If no recovery session shows up, the link is broken or expired.
setTimeout(async () => {
  if (decided) return;
  const { data: { session } } = await sb.auth.getSession();
  decided = true;
  ready(!!session && !linkError);
}, 1500);

form.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const password = form.password.value;
  if (password.length < 6) return toast('Password must be at least 6 characters.');
  if (password !== form.password2.value) return toast('Passwords do not match.');
  await busy(form.querySelector('button[type=submit]'), async () => {
    const { error } = await sb.auth.updateUser({ password });
    if (error) return toast(errMsg(error));
    toast('Password saved.', 'ok');
    setTimeout(() => location.replace('index.html'), 800);
  });
});
