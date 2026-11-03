// Edge Function "admin-reset-password": an admin sets a temporary password
// for a user (for people without an email). The password is returned once
// and is not stored anywhere.
// Deploy with JWT verification OFF (the function checks the caller itself).
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
const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

// 10 characters without look-alikes (no 0/o, 1/l/i).
function tempPassword() {
  const abc = 'abcdefghjkmnpqrstuvwxyz23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  return [...bytes].map((b) => abc[b % abc.length]).join('');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return fail('Method not allowed.', 405);

  // 1. Caller must be a logged-in admin.
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: auth } = token ? await admin.auth.getUser(token) : { data: null };
  const caller = auth?.user;
  if (!caller) return fail('Log in first.', 401);
  const { data: me } = await admin.from('profiles').select('is_admin').eq('id', caller.id).maybeSingle();
  if (!me?.is_admin) return fail('Not allowed.', 403);

  // 2. Target must be a member.
  let body: { user_id?: unknown };
  try { body = await req.json(); } catch { return fail('Bad request.'); }
  const userId = String(body.user_id ?? '');
  if (!/^[0-9a-f-]{36}$/i.test(userId)) return fail('Bad request.');
  const { data: target } = await admin.from('profiles').select('id').eq('id', userId).maybeSingle();
  if (!target) return fail('User not found.', 404);

  // 3. Set the new password.
  const password = tempPassword();
  const { error } = await admin.auth.admin.updateUserById(userId, { password });
  if (error) {
    console.error('password reset failed:', error.message);
    return fail('Something went wrong.', 500);
  }
  return json({ password });
});
