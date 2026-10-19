// Registration page. The group code is checked again by a database trigger.
import { sb, toEmail, USERNAME_RE, toast, errMsg, busy, initThemeToggle } from './common.js';

initThemeToggle(document.getElementById('theme'));

const { data: { session } } = await sb.auth.getSession();
if (session) location.replace('index.html');

const form = document.getElementById('register-form');
form.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const username = form.username.value.trim().toLowerCase();
  const displayName = form.display_name.value.trim().replace(/\s+/g, ' ');
  const password = form.password.value;
  const code = form.code.value.trim();

  // Quick client checks (server checks again).
  if (!USERNAME_RE.test(username)) return toast('Username: 3–20 letters, digits or _.');
  if (!displayName || displayName.length > 60) return toast('Enter your full name (max 60).');
  if (password.length < 6) return toast('Password must be at least 6 characters.');
  if (password !== form.password2.value) return toast('Passwords do not match.');
  if (!code) return toast('Enter the group code.');

  await busy(form.querySelector('button[type=submit]'), async () => {
    // Friendly pre-checks; the trigger in schema.sql is the real gate.
    const [codeRes, nameRes] = await Promise.all([
      sb.rpc('check_group_code', { code }),
      sb.rpc('username_available', { name: username }),
    ]);
    if (codeRes.error || nameRes.error) return toast(errMsg(codeRes.error || nameRes.error));
    if (!codeRes.data) return toast('Wrong group code.');
    if (!nameRes.data) return toast('Username taken.');

    const { data, error } = await sb.auth.signUp({
      email: toEmail(username),
      password,
      options: { data: { username, display_name: displayName, group_code: code } },
    });
    if (error) return toast(errMsg(error));
    if (!data.session) {
      // Happens when "Confirm email" is still enabled in Supabase.
      return toast('Account created, but login is blocked. Ask the admin to disable email confirmation.');
    }
    location.replace('index.html');
  });
});
