// Edge Function "email": our own email confirmation.
//   { action: "start", email }  (logged in)  -> mails a link with a one-time token (Brevo API)
//   { action: "confirm", token }             -> confirms: sets the email in Auth + account_emails
//   { action: "remove" }        (logged in)  -> back to username@queue.local
// Only a SHA-256 hash of the token is stored; the link works for 24 hours, once.
// Deploy with JWT verification OFF ("confirm" is opened from the email, maybe not logged in).
// Secrets: BREVO_API_KEY, MAIL_FROM, optional MAIL_FROM_NAME, SITE_URL.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const fail = (error: string, status = 400) => json({ error }, status);

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SITE_URL = (Deno.env.get('SITE_URL') || 'https://kanzzzwag.github.io/Queue-Maker').replace(/\/+$/, '');
const BREVO_API_KEY = Deno.env.get('BREVO_API_KEY') || '';
const MAIL_FROM = Deno.env.get('MAIL_FROM') || '';
const MAIL_FROM_NAME = Deno.env.get('MAIL_FROM_NAME') || 'Defense Queue';
const FAKE_DOMAIN = '@queue.local';
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

async function sha256(text: string) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// Logged-in user from the Authorization header, or null.
async function currentUser(req: Request) {
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  return error ? null : data.user;
}

async function sendMail(to: string, subject: string, text: string, html: string) {
  if (!BREVO_API_KEY || !MAIL_FROM) return false;
  const res = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: { 'api-key': BREVO_API_KEY, 'Content-Type': 'application/json', accept: 'application/json' },
    body: JSON.stringify({
      sender: { email: MAIL_FROM, name: MAIL_FROM_NAME },
      to: [{ email: to }],
      subject,
      textContent: text,
      htmlContent: html,
    }),
  });
  if (!res.ok) console.error('Brevo error', res.status, await res.text());
  return res.ok;
}

// ---------- start ----------
async function start(req: Request, body: Record<string, unknown>) {
  const user = await currentUser(req);
  if (!user) return fail('Log in first.', 401);

  const email = String(body.email ?? '').trim().toLowerCase();
  if (!EMAIL_RE.test(email) || email.length > 254 || email.endsWith(FAKE_DOMAIN)) {
    return fail('Enter a valid email.');
  }

  const { data: prof } = await admin.from('profiles').select('id').eq('id', user.id).maybeSingle();
  if (!prof) return fail('Not allowed.', 403);

  const { data: allowed } = await admin.rpc('rate_limit_hit', {
    p_kind: 'email_start', p_key: user.id, p_max: 5, p_window: '1 hour',
  });
  if (allowed === false) return fail('Too many emails. Try again later.', 429);

  const { data: mine } = await admin.from('account_emails').select('email').eq('user_id', user.id).maybeSingle();
  if (mine && mine.email === email) return fail('This email is already confirmed.');

  const { data: taken } = await admin.from('account_emails').select('user_id').eq('email', email).maybeSingle();
  if (taken && taken.user_id !== user.id) return fail('This email is used by another account.');

  // Only the newest link works.
  await admin.from('email_verifications').update({ used_at: new Date().toISOString() })
    .eq('user_id', user.id).is('used_at', null);

  const token = randomToken();
  const { data: row, error } = await admin.from('email_verifications').insert({
    user_id: user.id,
    email,
    token_hash: await sha256(token),
    expires_at: new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
  }).select('id').single();
  if (error) return fail('Something went wrong.', 500);

  const link = `${SITE_URL}/verify-email.html#token=${token}`;
  const sent = await sendMail(
    email,
    'Confirm your email',
    `Open this link to confirm your email for Defense Queue:\n${link}\n\nThe link works for 24 hours. If you did not ask for this, ignore this email.`,
    `<p>Open this link to confirm your email for Defense Queue:</p>
     <p><a href="${link}">Confirm email</a></p>
     <p>The link works for 24 hours. If you did not ask for this, ignore this email.</p>`,
  );
  if (!sent) {
    await admin.from('email_verifications').delete().eq('id', row.id);
    return fail('Could not send the email. Try again later.', 502);
  }
  return json({ message: 'Check your inbox.' });
}

// ---------- confirm ----------
async function confirm(body: Record<string, unknown>) {
  const token = String(body.token ?? '');
  if (!/^[A-Za-z0-9_-]{20,100}$/.test(token)) return fail('This link is invalid or expired.');

  // Use the token once: mark it used in the same statement that finds it.
  const { data: v } = await admin.from('email_verifications')
    .update({ used_at: new Date().toISOString() })
    .eq('token_hash', await sha256(token))
    .is('used_at', null)
    .gt('expires_at', new Date().toISOString())
    .select('user_id, email')
    .maybeSingle();
  if (!v) return fail('This link is invalid or expired.');

  const { data: taken } = await admin.from('account_emails').select('user_id').eq('email', v.email).maybeSingle();
  if (taken && taken.user_id !== v.user_id) return fail('This email is used by another account.');

  const { error: authErr } = await admin.auth.admin.updateUserById(v.user_id, { email: v.email, email_confirm: true });
  if (authErr) {
    console.error('auth update failed:', authErr.message);
    return fail(/already|exists|registered/i.test(authErr.message)
      ? 'This email is used by another account.' : 'Something went wrong.');
  }

  // A row here = confirmed. The welcome bonus trigger (migration 006) fires on this.
  const { error } = await admin.from('account_emails')
    .upsert({ user_id: v.user_id, email: v.email, verified_at: new Date().toISOString() }, { onConflict: 'user_id' });
  if (error) {
    console.error('account_emails upsert failed:', error.message);
    return fail('Something went wrong.', 500);
  }
  return json({ message: 'Email confirmed.' });
}

// ---------- remove ----------
async function remove(req: Request) {
  const user = await currentUser(req);
  if (!user) return fail('Log in first.', 401);
  const { data: prof } = await admin.from('profiles').select('username').eq('id', user.id).maybeSingle();
  if (!prof) return fail('Not allowed.', 403);

  const { error } = await admin.auth.admin.updateUserById(user.id, {
    email: `${prof.username}${FAKE_DOMAIN}`, email_confirm: true,
  });
  if (error) {
    console.error('auth reset failed:', error.message);
    return fail('Something went wrong.', 500);
  }
  await admin.from('account_emails').delete().eq('user_id', user.id);
  await admin.from('email_verifications').update({ used_at: new Date().toISOString() })
    .eq('user_id', user.id).is('used_at', null);
  return json({ message: 'Email removed.' });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return fail('Method not allowed.', 405);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail('Bad request.'); }
  try {
    switch (body.action) {
      case 'start': return await start(req, body);
      case 'confirm': return await confirm(body);
      case 'remove': return await remove(req);
      default: return fail('Bad request.');
    }
  } catch (e) {
    console.error('email function error:', e);
    return fail('Something went wrong.', 500);
  }
});
