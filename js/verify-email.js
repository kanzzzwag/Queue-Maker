// Email confirmation page, opened from the link in the email.
// The token is in the URL hash, so it is never sent to GitHub Pages.
import { callFn, initThemeToggle } from './common.js';

initThemeToggle(document.getElementById('theme'));

const msg = document.getElementById('verify-msg');
const token = new URLSearchParams(location.hash.slice(1)).get('token');
history.replaceState(null, '', location.pathname);   // remove the token from the address bar

if (!token) {
  msg.textContent = 'This link is invalid or expired.';
} else {
  const { data, error } = await callFn('email', { action: 'confirm', token });
  msg.textContent = error ? error.message : data.message;
  msg.className = error ? 'muted' : '';
}
