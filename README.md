# Defense Queue

A queue website for the study group's defenses. Plain HTML/CSS/JS on GitHub Pages, with Supabase for login and the database.

## Files

```
index.html        queue (current + next week)
login.html        log in
register.html     register (needs group code)
admin.html        admin: queue, subjects, users, group code
config.js         Supabase URL + anon key
css/style.css     all styles
js/               page scripts
supabase/schema.sql   all SQL: tables, RLS, functions, cron job
```

## 1. Create the Supabase project

1. Go to https://supabase.com and click **New project**.
2. Choose a name, a database password and a region (Frankfurt or Singapore are close to Kazakhstan).
3. Wait until the project is ready.

## 2. Run the SQL

1. In the project, open **SQL Editor** and click **New query**.
2. Paste the whole content of `supabase/schema.sql` and click **Run**.
3. You should see "Success". This creates the tables, security rules (RLS), the signup check, Realtime and the nightly cleanup job.

If the `pg_cron` line fails, open **Integrations → Cron** (or **Database → Extensions**), enable **pg_cron**, then run the file again.

## 3. Auth settings

1. **Authentication → Sign In / Providers → Email**:
   - Keep **Email** provider **enabled**.
   - Turn **Confirm email** **OFF**. Click **Save**.
2. Optional: **Authentication → Rate Limits**. If many students register at the same time from the same Wi-Fi, raise the sign-up/sign-in limit.

Users log in with a username. Behind the scenes the site uses the fake email `username@queue.local`. Nobody gets real emails.

## 4. Set config.js

1. Open **Project Settings → API** (or **Data API / API Keys**).
2. Copy the **Project URL** and the **anon public** key.
3. Paste them into `config.js`:

```js
export const SUPABASE_URL = 'https://abcd1234.supabase.co';
export const SUPABASE_ANON_KEY = 'eyJhbGciOi...';
```

The anon key is meant to be public. The data is protected by RLS.

## 5. Deploy to GitHub Pages

1. Create a new GitHub repository (public, or private with GitHub Pro).
2. Push all files (the repo root must contain `index.html`):
   ```
   git init
   git add .
   git commit -m "Defense queue"
   git branch -M main
   git remote add origin https://github.com/YOUR-NAME/YOUR-REPO.git
   git push -u origin main
   ```
3. On GitHub: **Settings → Pages → Build and deployment → Source: Deploy from a branch**, branch **main**, folder **/ (root)**, click **Save**.
4. After 1–2 minutes the site is at `https://YOUR-NAME.github.io/YOUR-REPO/`.

## 6. Set the group code and make yourself admin

1. Open the site and **register** with the default code `change-me`.
2. In Supabase: **Table Editor → profiles**, find your row, set **is_admin** to `true`, save.
3. Log out and back in (or reload). The **Admin** link appears in the top bar.
4. In **Admin → Code**, set a new group code and share it with the group.
5. In **Admin → Subjects**, add the weekly schedule.

## Notes

- Timezone is Asia/Almaty (UTC+5) for "today", closed days and cleanup.
- Past days of the current week are visible but closed. Users can join from today until the end of next week. These rules are enforced in the database (RLS), not only in the page.
- The cleanup job runs every day at 00:00 Almaty time (19:00 UTC) and deletes entries from previous weeks. See jobs in **Integrations → Cron**.
- Removing a user in Admin deletes their account and all their entries.
- Usernames are case-insensitive (stored in lowercase).
- Accounts must be created through the register page. Users added from the Supabase dashboard are rejected by the signup check.
