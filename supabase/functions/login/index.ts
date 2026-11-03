// Edge Function "login": username + password -> session tokens.
// The user's email (real or username@queue.local) is looked up on the server
// and never sent to the browser. Any failure returns the same message.
// Deploy with JWT verification OFF (the user is not logged in yet).
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
const WRONG = 'Wrong username or password.';
const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed.' }, 405);

  let body: { username?: unknown; password?: unknown };
  try { body = await req.json(); } catch { return json({ error: WRONG }, 400); }
  const username = String(body.username ?? '').trim().toLowerCase();
  const password = String(body.password ?? '');
  if (!/^[a-z0-9_]{3,20}$/.test(username) || !password || password.length > 200) {
    return json({ error: WRONG }, 400);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_KEY, noSession);

  // Max 10 failed attempts per username in 15 minutes.
  const { data: allowed } = await admin.rpc('rate_limit_hit', {
    p_kind: 'login_fail', p_key: username, p_max: 10, p_window: '15 minutes', p_record: false,
  });
  if (allowed === false) return json({ error: 'Too many attempts. Wait 15 minutes.' }, 429);

  const fail = async () => {
    await admin.rpc('rate_limit_hit', {
      p_kind: 'login_fail', p_key: username, p_max: 10, p_window: '15 minutes', p_record: true,
    });
    return json({ error: WRONG }, 400);
  };

  const { data: prof } = await admin.from('profiles').select('id').eq('username', username).maybeSingle();
  if (!prof) return fail();

  const { data: found, error: findErr } = await admin.auth.admin.getUserById(prof.id);
  const email = found?.user?.email;
  if (findErr || !email) return fail();

  // Sign in as the user. Forward the client IP so Auth rate limits are per person.
  const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim();
  const client = createClient(SUPABASE_URL, ANON_KEY, {
    ...noSession,
    global: { headers: ip ? { 'X-Forwarded-For': ip } : {} },
  });
  const { data, error } = await client.auth.signInWithPassword({ email, password });
  if (error || !data.session) {
    if (error && /rate limit/i.test(error.message)) {
      return json({ error: 'Too many attempts. Wait a few minutes.' }, 429);
    }
    return fail();
  }

  return json({
    access_token: data.session.access_token,
    refresh_token: data.session.refresh_token,
  });
});
