# Moe's Songbook – prototype setup

## 1. Try it now (demo mode, no server)
Open the app, tap **Sign in**, pick a test user. Demo mode keeps a pretend server on the phone:
- **Soe (admin)** – Admin screen: approve payments, review queue, reports, mark songs Premium, wallet details.
- **Aung Aung / Mya Mya** – normal users in Myanmar (KBZPay / WavePay prices).
- **Ko Ko (new user)** – Thailand prices; his first public song waits in the review queue.
Switch users from the account button. Admin → "Reset demo data" starts over.

## 2. Host on GitHub Pages
Upload index.html, sw.js, manifest.json, icon.svg, songs.json to the repo (same as before).

## 3. Connect the real server (Supabase, free plan)
1. Create a free project at supabase.com (choose the Singapore region).
2. SQL Editor → paste **schema.sql** → Run.
3. Authentication → URL Configuration → Site URL = your GitHub Pages address (for example https://moe-sg.github.io/songbook/).
4. Project Settings → API → copy the **Project URL** and the **anon public key**.
5. In the app: ⚙ → Accounts server → Supabase → paste both → Apply.
6. Sign in with your email once, then in SQL Editor run:
   update public.profiles set role = 'admin' where id = (select id from auth.users where email = 'YOUR EMAIL');

The anon key is meant to be public; all rules (premium access, sharing slots, ratings) are enforced in the database by schema.sql.
Stripe card payments and Google Play billing are not connected yet (Phase 3 / Phase 4).
