// Edge Function "forgot-password": takes a username. If the user has a
// confirmed email, Supabase Auth sends a reset link (through Custom SMTP / Brevo).
// The answer is always the same, so nobody can learn who has an email.
// Max 3 requests per hour per username.
// Deploy with JWT verification OFF.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SITE_URL = (Deno.env.get('SITE_URL') || 'https://kanzzzwag.github.io/Queue-Maker').replace(/\/+$/, '');
const SAME = { message: 'If this account has an email, we sent a link.' };
const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed.' }, 405);

  let body: { username?: unknown };
  try { body = await req.json(); } catch { return json(SAME); }
  const username = String(body.username ?? '').trim().toLowerCase();
  if (!/^[a-z0-9_]{3,20}$/.test(username)) return json(SAME);

  const admin = createClient(SUPABASE_URL, SERVICE_KEY, noSession);
  try {
    const { data: allowed } = await admin.rpc('rate_limit_hit', {
      p_kind: 'forgot', p_key: username, p_max: 3, p_window: '1 hour',
    });
    if (allowed === false) return json(SAME);

    const { data: prof } = await admin.from('profiles').select('id').eq('username', username).maybeSingle();
    if (!prof) return json(SAME);

    // Only a confirmed email counts.
    const { data: row } = await admin.from('account_emails').select('email').eq('user_id', prof.id).maybeSingle();
    if (!row) return json(SAME);

    // Use the email Auth has (the same one, set when it was confirmed).
    const { data: found } = await admin.auth.admin.getUserById(prof.id);
    const email = found?.user?.email;
    if (!email || email.endsWith('@queue.local')) return json(SAME);

    // Implicit flow: the link opens reset-password.html with the session in the URL hash.
    const client = createClient(SUPABASE_URL, ANON_KEY, { auth: { ...noSession.auth, flowType: 'implicit' } });
    const { error } = await client.auth.resetPasswordForEmail(email, {
      redirectTo: `${SITE_URL}/reset-password.html`,
    });
    if (error) console.error('reset email failed:', error.message);
  } catch (e) {
    console.error('forgot-password error:', e);
  }
  return json(SAME);
});
