Build a defense-queue website for my university study group.

## Stack
- Plain HTML, CSS, vanilla JS (ES modules). No React, no build step.
- Frontend hosted on GitHub Pages.
- Supabase for auth + Postgres database (use supabase-js from CDN).
- Put Supabase URL and anon key in one config.js file.
- Write all SQL (tables, RLS policies, functions, cron job) in supabase/schema.sql so I can paste it into the Supabase SQL editor.
- Write a short README.md: how to create the Supabase project, run the SQL, set config, deploy to GitHub Pages, and make myself admin.

## Accounts
- Login with username + password (no email for users). Use Supabase Auth with a fake email like `username@queue.local`. Tell me to disable email confirmation in Supabase settings.
- Registration needs a group code. Store the code in a settings table only admin can read/change. Check the code server-side (security definer function or similar), not only in JS.
- A user without a valid profile cannot read or write anything (RLS).
- Usernames unique, 3–20 chars, letters/digits/underscore.
- profiles table: id, username, display_name (full name shown in queue), is_admin, created_at.
- I will make myself admin manually in the Supabase dashboard.

## Schedule
- Same schedule every week.
- Admin can add/edit/delete subjects: subject name, weekday (Mon–Sun), start time, end time. Several subjects per day allowed.
- Sort by time inside each day.

## Queue
- Show two weeks: current week and next week (week starts Monday). Tabs or toggle to switch weeks.
- Each day shows its subjects; each subject (a "slot" = subject + date) shows its queue.
- Queue order = sign-up time (first come first).
- A user can join each slot only once (unique constraint on slot + user).
- No limit on queue size.
- Optional comment when joining (max 200 chars), visible to everyone. User can edit own comment.
- User can cancel own entry.
- Timezone: Asia/Almaty (UTC+5). Use it everywhere for "today".
- Past days of the current week stay visible but are closed: no join, no cancel, no edit (enforce with RLS, not only UI). Show a small "Closed" label.
- No sign-up for dates beyond the end of next week.
- Cleanup: pg_cron job at 00:00 Asia/Almaty deletes entries with date before the start of the current week.
- Queue updates live (Supabase Realtime) or at least on refresh.

## Admin
- Admin page: manage subjects, change group code, remove any queue entry, mark an entry as "done" (defended). Done entries appear greyed out but stay in the list.
- Admin can see the list of users and remove a user.

## Design
- Clean, simple, mobile-first. Must work well on phones and laptops.
- Light and dark theme, toggle saved in localStorage, default = system theme.
- No emojis, no neon, no gradients, no heavy animations.
- Short UI text only. All text in English.
- Use CSS variables for colors. One CSS file.
- Readable font (system font stack), good contrast, large tap targets on mobile.
- Today's day highlighted. Show user's own entry highlighted in the queue with position number.

## Pages
- login.html, register.html, index.html (queue), admin.html. Or one page with views — your choice, keep it simple.

## Extra features (added later, see README for setup)
- Pages: chat.html, profile.html, trade.html, game.html, calc.html, reset-password.html, verify-email.html.
- Grade calculator (calc.html, js/calc.js): browser only, no database; subjects saved in localStorage.
- Shared header/menu is rendered by `initPage()` in js/common.js (dropdown under "Menu" on narrow screens).
- Auto-join (admin): `auto_join_rules`, `auto_join_log`, `run_auto_join(p_force)`, cron `auto-join` every minute, each slot tried once (log), Run now = force.
- Subjects: `open_days_before` (0–7) + `open_time` = when the queue opens (`join_is_open()` in the join RLS policy); `valid_from` / `valid_until` = which weeks a subject is used (`admin_end_subject`, `admin_change_subject_next_week`, cron `subjects-cleanup`). Never delete a running subject when the schedule changes: end it after this week.
- Trade dot: `trade_seen` + `mark_trade_seen()` / `trade_unseen_count()`; header shows a red dot (`[data-dot]`).
- Favicon: `favicon.svg` + `apple-touch-icon.png`, linked in every page.
- Chat: `messages`, anti-spam trigger, Realtime, cron `chat-cleanup`.
- Email: own confirmation flow (Edge Function `email` + Brevo API, token hash, 24 h). Confirmed = row in `account_emails`; check with `public.email_verified(uid)`. Login by username via Edge Function `login`; reset via `forgot-password`; admin temp password via `admin-reset-password`.
- Profiles: avatar/background in Storage buckets `avatars`/`backgrounds` (`{user_id}/...`), name change once per 7 days.
- Points: `wallets` + `point_ledger`, changed only by `_points_add()`. Welcome bonus 1000 once after first confirmed email.
- Trade: `trade_offers`, `trade_bids`, `trades`, RPCs only, switch `settings.trade_enabled`. `supabase/remove-trade.sql` removes it.
- Daily Word: `word_dictionary`, `word_answer_queue`, `daily_words` (admin only), `game_plays`, `game_guesses`, `weekly_results`; `submit_guess()`, cron `word-pick` and `game-week`.

## Database rules (live database with real data)
- Never drop or recreate tables with data. Every change is a new `supabase/migration-NNN-*.sql`: one transaction, safe to re-run, does not touch existing entries.
- Keep `supabase/schema.sql` = base + all migrations (final state for a fresh install).
- Money, places and permissions are checked only on the server (RLS, security definer functions with `set search_path = ''`, Edge Functions). Revoke default grants on new tables (`revoke all ... from anon, authenticated`).
- `entries_guard` allows user_id/place changes only when `app.trusted_op` is on AND `current_user` is not anon/authenticated (trade functions).
- Secrets (service role, SMTP, Brevo) never go into the repo.
- pg_cron runs in UTC: 19:00 UTC = 00:00 Asia/Almaty.

## Quality
- Handle errors with short messages (wrong code, username taken, network error).
- Escape user text (no XSS in comments/names).
- Keep code readable with small comments.
- When done, list exactly what I must click/configure in Supabase and GitHub.