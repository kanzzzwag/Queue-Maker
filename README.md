# Defense Queue

A queue website for the study group's defenses, plus group chat, profiles, points, place trading and a daily word game.
Plain HTML/CSS/JS on GitHub Pages, Supabase for auth, database, storage and Edge Functions.

## Files

```
index.html            queue (current + next week)
chat.html             group chat
profile.html          profile (?u=username)
trade.html            buy / sell queue places for points
game.html             Daily Word game + weekly ranking
admin.html            admin: queue, subjects, users, auto-join, points, Daily Word, settings
login.html            log in + "Forgot password?"
register.html         register (needs group code)
reset-password.html   new password (opened from the reset email)
verify-email.html     email confirmation (opened from our own email)
config.js             Supabase URL + publishable key (public)
css/style.css         all styles
js/                   page scripts (common.js = shared helpers and header)
supabase/schema.sql                 full setup for a NEW project
supabase/migration-00X-*.sql        upgrades for the existing database
supabase/remove-trade.sql           removes trading only
supabase/functions/*/index.ts       Edge Functions: login, forgot-password, email, admin-reset-password
```

No secrets are in the repository. The service role key, SMTP key and Brevo API key live only in Supabase settings / Edge Function secrets.

---

## A. Upgrade the existing database (your live project)

Run these files **in this order** in **Supabase → SQL Editor → New query → paste → Run**. Each one is a single transaction, can be run again safely, and does not change existing queue entries.

1. `supabase/migration-003-auto-join.sql`
2. `supabase/migration-004-chat.sql`
3. `supabase/migration-005-email-profiles.sql`
4. `supabase/migration-006-points-trade.sql`
5. `supabase/migration-007-word-game.sql` (large: about 5000 dictionary words)

Do **not** run `schema.sql` on the live database. It is for a brand new project only (base schema + all migrations in one file).

## B. New project from scratch

1. https://supabase.com → **New project** (region Frankfurt or Singapore).
2. **Integrations → Cron** (or **Database → Extensions**): enable **pg_cron**.
3. **SQL Editor**: paste the whole `supabase/schema.sql` → **Run**.
4. Continue with sections C–G below.

---

## C. Edge Functions

Four functions. All are deployed with **JWT verification OFF**, because they check the caller themselves
(and `login`, `forgot-password` and email `confirm` are called by people who are not logged in).

| Function | What it does |
|---|---|
| `login` | username + password → session. Finds the email on the server. Same error for every failure. Max 10 failed tries per username / 15 min. |
| `forgot-password` | username → reset email if the user has a confirmed email. Same answer always. Max 3 per username / hour. |
| `email` | `start` (send confirmation link), `confirm` (token from the link), `remove` (back to `username@queue.local`). |
| `admin-reset-password` | admin only: sets a temporary password, shows it once. |

### Option 1: Supabase CLI

Install the CLI (Windows: `scoop install supabase`, or download from https://github.com/supabase/cli/releases), then in the project folder:

```
supabase login
supabase functions deploy login                --project-ref kotpngwjleurdzjkjbnz --no-verify-jwt
supabase functions deploy forgot-password      --project-ref kotpngwjleurdzjkjbnz --no-verify-jwt
supabase functions deploy email                --project-ref kotpngwjleurdzjkjbnz --no-verify-jwt
supabase functions deploy admin-reset-password --project-ref kotpngwjleurdzjkjbnz --no-verify-jwt
```

### Option 2: Dashboard (no CLI)

Each function is one self-contained file. For each of the four:

1. **Edge Functions → Deploy a new function → Via Editor**.
2. Name it exactly: `login`, `forgot-password`, `email`, `admin-reset-password`.
3. Paste the content of `supabase/functions/<name>/index.ts` → **Deploy**.
4. Open the function → **Details / Settings** → turn **Enforce JWT verification** (Verify JWT) **OFF** → Save.

### Secrets

**Edge Functions → Secrets** (or `supabase secrets set NAME=value --project-ref kotpngwjleurdzjkjbnz`):

| Name | Value |
|---|---|
| `BREVO_API_KEY` | Brevo API key (section F) |
| `MAIL_FROM` | the verified sender email in Brevo, e.g. `queue@yourdomain.com` |
| `MAIL_FROM_NAME` | optional, default `Defense Queue` |
| `SITE_URL` | `https://kanzzzwag.github.io/Queue-Maker` (no trailing slash). For local tests: `http://127.0.0.1:5500` |

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are provided to Edge Functions automatically. Do not add them and never put them in the repo.

---

## D. Supabase settings

### Authentication → Sign In / Providers → Email
- **Email** provider: **ON**.
- **Confirm email**: **OFF** (registration still uses `username@queue.local`, which has no mailbox).
- **Secure email change**: does not matter (we never call `updateUser({ email })` from the browser). Leave it ON.

Why our own email confirmation: with "Confirm email" OFF, Supabase Auth applies `updateUser({ email })` immediately with no confirmation at all, and with "Secure email change" ON it also mails the old (fake) address. Neither can guarantee "confirmed only after clicking the link". So the `email` function sends its own link through the Brevo API (one-time token, only its SHA-256 hash is stored, valid 24 h), and only after the link is opened it writes the email into Auth and into `account_emails`. `public.email_verified(uid)` checks that table.

### Authentication → Emails → SMTP Settings (Custom SMTP, for the password reset email)
- **Enable Custom SMTP**: ON
- Sender email: your verified Brevo sender (same as `MAIL_FROM`)
- Sender name: `Defense Queue`
- Host: `smtp-relay.brevo.com`
- Port: `587`
- Username: your Brevo SMTP login (looks like `xxxxxx@smtp-brevo.com`)
- Password: your Brevo **SMTP key** (not the account password)
- Save.

### Authentication → Emails → Templates → Reset Password
Subject: `Reset your password`
Body:
```html
<p>Open this link to set a new password for Defense Queue:</p>
<p><a href="{{ .ConfirmationURL }}">Set a new password</a></p>
<p>If you did not ask for this, ignore this email.</p>
```

### Authentication → URL Configuration
- **Site URL**: `https://kanzzzwag.github.io/Queue-Maker/`
- **Redirect URLs** (Add URL):
  - `https://kanzzzwag.github.io/Queue-Maker/reset-password.html`
  - `http://127.0.0.1:5500/**` (Live Server, for local tests)
  - `http://localhost:5500/**`

### Authentication → Rate Limits
All logins now go through the `login` Edge Function. Raise **sign-ups and sign-ins** to e.g. 100 per 5 minutes so a whole group can log in at once. Raise **emails sent** if needed (Custom SMTP is required for more than a few per hour).

### Storage
`migration-005` creates two public buckets: `avatars` (200 KB max) and `backgrounds` (800 KB max), images only, with policies: anyone in the group can read, only the owner can upload/replace/delete files in `{user_id}/...`. Check under **Storage** that both exist. Nothing to click.

### Realtime
The migrations add `entries`, `messages`, `trade_offers` and `trade_bids` to the `supabase_realtime` publication. Check under **Database → Publications → supabase_realtime**. Nothing to click.

### Cron jobs
All run in UTC. 19:00 UTC = 00:00 Asia/Almaty.

| Job | Schedule (UTC) | Does |
|---|---|---|
| `queue-cleanup` | `0 19 * * *` | deletes entries from past weeks |
| `auto-join` | `0 19 * * *` | admin auto-join for tomorrow |
| `word-pick` | `0 19 * * *` | fixes the new day's word |
| `trade-expire` | `5 19 * * *` | expires stale offers and bids |
| `chat-cleanup` | `15 19 * * *` | deletes messages older than 30 days |
| `game-week` | `0 19 * * 0` | Monday 00:00 Almaty: weekly results, prizes, badges |

The order of jobs at 19:00 does not matter: they touch different rows.

Did a job run? **SQL Editor**:
```sql
select j.jobname, d.status, d.return_message, d.start_time
from cron.job_run_details d join cron.job j on j.jobid = d.jobid
order by d.start_time desc limit 20;
```
The auto-join result is also in **Admin → Auto-join → Log**.

---

## E. config.js and GitHub Pages

`config.js` already has the project URL and publishable key. It is public by design; data is protected by RLS.

1. Test locally first with VS Code **Live Server** (`http://127.0.0.1:5500/index.html`).
2. When everything works: commit and push to `main`.
3. GitHub: **Settings → Pages → Source: Deploy from a branch → main / (root)**.
4. Site: `https://kanzzzwag.github.io/Queue-Maker/`.

## F. Brevo

1. Sign up at https://www.brevo.com (free plan: 300 emails per day).
2. **Senders, Domains & Dedicated IPs → Senders → Add a sender**: name `Defense Queue`, your email. Confirm the email Brevo sends you.
   Better delivery: **Domains → Add a domain** and add the DKIM/SPF/DMARC DNS records Brevo shows (only if you own a domain).
3. **SMTP & API → SMTP** tab: copy the **SMTP server/login** and **Generate a new SMTP key** → use in Supabase Custom SMTP (section D).
4. **SMTP & API → API Keys** tab: **Generate a new API key** → save as Edge Function secret `BREVO_API_KEY`.
5. If Brevo asks to activate transactional email or to whitelist IPs: **Security → Authorised IPs** → turn the IP restriction off (Edge Functions have changing IPs).

## G. Admin

- Make yourself admin: **Table Editor → profiles → your row → is_admin = true**.
- **Admin → Settings**: group code, and the **Trading** switch (off by default).
- **Admin → Users**: email (if confirmed), **Reset password** (temporary password shown once), Remove.
- **Admin → Points**: balances, add/remove points with a reason, last movements.
- **Admin → Auto-join**: subjects + place; **Run now** to test.
- **Admin → Daily Word**: add answer words, upcoming list, warning when fewer than 7, **Reveal** today's word.

---

## Rules (all enforced in the database or Edge Functions, not only in the page)

- **Queue**: join opens at 00:00 Almaty the day before the slot. Pick a free place (1..number of users). Past days are closed.
- **Auto-join**: at 00:00 the cron job tries to insert the admin at the chosen place. If the place is taken or anything fails, that subject is skipped and logged (`joined / place_taken / already_in / error`). It never takes another place and never touches other entries. Log kept 30 days.
- **Chat**: members only, 1–500 characters, max 1 message per 2 seconds and 20 per minute. Delete own (admin: any). No editing. Messages older than 30 days are deleted.
- **Email**: optional, visible only to the owner and admin. Login always by username.
- **Profile**: name change once per 7 days (admin: no limit). Bio 160, favorite subject (from the schedule or own text, 40). Photo 256×256 WebP, background 1200 px WebP, max 5 MB source.
- **Points**: balance changes only through database functions and is logged in `point_ledger`. 1000 welcome points once, after the first confirmed email (never again, even after removing and adding an email). No points without a confirmed email.
- **Trade**: only your own, not done, open entry; one open offer per entry; buyer and seller need confirmed emails. Buy now or make an offer; the seller accepts or declines. If the buyer is not in that queue, the place moves to them; if they are, the two swap places. Everything else on that entry expires.
- **Daily Word**: one word per day for everyone, 6 tries, checked on the server. 100/80/60/40/25/10 points (+20 for the first solver), paid only with a confirmed email. Weekly top 3 (with email) get 300/200/100 and a badge.

## Manual tests

Use two accounts (A and B) in two browsers (or one normal + one private window).

**Auto-join**
1. Admin → Auto-join: tick a subject that is **tomorrow**, place 3 → Save → **Run now** → toast "Joined", log row "Joined".
2. Run now again → "Already in".
3. Place already taken: cancel your entry, let B join tomorrow's slot at place 3, then Run now → log "Place taken". B's entry is unchanged, you are not added at another place.
4. Next morning: `cron.job_run_details` shows `auto-join` succeeded.

**Chat**
1. A sends a message → it appears in B's window without reload.
2. Send 2 messages very fast → "Slow down. Wait 2 seconds."
3. B cannot delete A's message (no button; API call is blocked by RLS). Admin can.
4. Send `<b>hi</b> https://x.com` → shown as plain text, no link.

**Login and password**
1. Log in with username + password → works (old users too).
2. Wrong password → "Wrong username or password."; unknown username → the same text.
3. **Reset without email**: Forgot password → username of a user with no email → "If this account has an email, we sent a link." No email arrives. Admin → Users → Reset password → log in with the temporary password.
4. **Reset with email**: A adds and confirms an email (Profile) → log out → Forgot password → same message → email arrives → link opens reset-password.html → new password → log in with the new password.
5. Ask 4 times within an hour → the 4th sends nothing (same message).

**Email + welcome bonus**
1. A: Profile → Email → Send link → open the link → "Email confirmed." → Profile shows 1000 points.
2. **No second bonus**: Remove email → add it again (or another email) and confirm → still 1000, ledger has only one "Welcome" row (Admin → Points).
3. Open the same confirmation link again → "This link is invalid or expired."
4. B opens A's profile → no email visible anywhere. In the browser console on B: `await (await import('./js/common.js')).sb.from('account_emails').select('*')` → empty list.

**Trade**
1. Admin → Settings → Trading on. A and B have confirmed emails (1000 each).
2. A: queue → Sell on own entry → price 100 → Market shows it.
3. B: Buy → confirm → B owns the place, A is out of that queue, balances 900 / 1100.
4. Swap: both in the same queue; A sells, B buys → they swap places.
5. **Same lot from two accounts at once**: A sells; B and C (or B in two windows) click Buy at the same time → one gets "Bought", the other "This offer is no longer available." Only one ledger pair.
6. Offer price: B offers 50 → A sees it in My offers → Accept → place moves. Decline → B sees "Declined".
7. A cancels own entry while it is on sale → the offer becomes Expired.
8. Trading off → Trade link hidden, `sb.rpc('buy_now', …)` returns "Trading is off".

**Daily Word**
1. Play: each guess shows colors; refresh → the game is restored; after finishing, no new guesses are accepted.
2. Repeated letters: if the answer has one E and you guess two Es, only one is colored.
3. Not a word (e.g. `abcde`) → "Not in word list."
4. **Reading the answer through the API**: as a normal user in the console:
   `const { sb } = await import('./js/common.js'); await sb.from('daily_words').select('*')` → empty list;
   `await sb.rpc('admin_reveal_today')` → "Not allowed."; `await sb.rpc('game_state')` → `answer: null` until you finish.
5. Without email: you can play, the ranking shows "no rewards", no points are paid.
6. Admin → Daily Word: add words (wrong ones are rejected), fewer than 7 → warning, Reveal shows today's word.
7. Weekly close (test): in SQL Editor `select public.close_game_week('2026-11-02');` (a past Monday) twice → prizes paid once, "Past weeks" tab shows the results, winners have a "Weekly #N" badge in their profile.

## Remove trading

Run `supabase/remove-trade.sql`. Tables, functions, triggers and the cron job of trading are removed. Points, ledger, game and queue stay.

## Notes

- Timezone is Asia/Almaty (UTC+5) for "today", closed days, game days and all cron jobs.
- Removing a user in Admin deletes their account, entries, messages, wallet and games.
- Usernames are case-insensitive (stored in lowercase).
- Accounts must be created through the register page. Users added from the Supabase dashboard are rejected by the signup check.
