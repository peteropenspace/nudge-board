# Set up the shared board (free)

This puts your board online so the whole team sees the same cards. People sign in with a password, get desktop notifications while the board is open, and get calm emails that your Claude app sends from your own mailbox. It takes about 30 minutes the first time. Nothing here needs a credit card or an email service account.

You will use:

| What | Service | Why this one |
| --- | --- | --- |
| Data, sign-in, live updates, schedules | **Supabase** (Free plan) | One dashboard for all of it. |
| Email that goes out | **Your Claude app** with an email connector (for example Gmail) | No email service to sign up for. A scheduled task in Claude sends the waiting emails. |
| The website itself | **Cloudflare Pages** (recommended) or **GitHub Pages** | Free, and static files only. |

> **Not Vercel.** Vercel's free Hobby plan is for personal, non-commercial use only, and its own rules count a company's internal tool as commercial. Its paid plan needs a card. Everything below works on any static host, so use Cloudflare Pages or GitHub Pages instead.

Words used below: the **PM** is the project manager, who adds people and assigns tasks. A **member** is everyone else.

The steps are in the order you can do them top to bottom.

---

## Step 1. Create the Supabase project

1. Go to <https://supabase.com>, sign up, and choose **New project**.
2. Name it after your team. Save the **database password** somewhere safe. You will hardly ever need it.
3. Pick the **region** closest to your team. Wait about two minutes for it to finish.

## Step 2. Load the board's database

1. In the project, open **SQL Editor**, then **New query**.
2. Open `supabase/setup.sql` from this folder, copy everything, paste it in, and press **Run**.
3. If you see an error about `pg_cron` or `pg_net`, open **Database > Extensions**, switch both on, then run the file again. It is safe to run more than once.

## Step 3. Make yourself the project manager

1. Open `supabase/first_pm.sql`, change the five values (your name, your work email, the board name, a short card prefix like `CHK`, your time zone), and run it in the SQL Editor.
2. The result shows your **join code**, like `K7PM-3QXD`. Keep it for step 8. You will sign in with that email and a password you choose.

Already ran `first_pm.sql` before passwords existed? Run the whole of `setup.sql` again first (it is safe, and it adds the join codes), then run `supabase/join_codes.sql` to see your code.

If you typed your email wrong, run this with the right one (it fixes the PM row; running `first_pm.sql` again does nothing once the board has people):

```sql
update public.people set email = 'right@yourcompany.com' where role = 'pm';
```

## Step 4. (Skip) Email service

Nothing to do here. Emails go out through your Claude app (step 10), so you do not need Resend, Brevo or a domain.

<!-- Paused: sending straight from the database with Resend or Brevo. The code is still in setup.sql
     (private.send_email) and comes back by choosing that provider again.

1. Make a free account at <https://resend.com>, verify your domain, and create an API key with Sending access.
2. In Supabase open SQL Editor > New query and run, with your real key:
   select vault.create_secret('re_YOUR_KEY_HERE', 'email_api_key', 'Email provider API key');
   Do not save the key in a file in this folder.
3. Brevo works too, from a single verified sender address, with the same create_secret line.
-->

## Step 5. Point the website at your project

1. In Supabase open **Project Settings > API Keys** (the **Connect** button at the top also shows them).
2. Copy the **Project URL** and the **publishable key** (it starts with `sb_publishable_`).
3. Open `site/config.js` and paste them in:

   ```js
   window.NUDGE_CONFIG = {
     supabaseUrl: 'https://YOURPROJECT.supabase.co',
     supabaseKey: 'sb_publishable_...',
     google: false,
     appUrl: 'https://YOURNAME.github.io/REPO/'
   };
   ```

   `appUrl` is the board's web address from step 6. Email buttons and pause links point there. You can fill it in after step 6.

These values are **meant to be public**. They only work together with sign-in and the team list, which is what keeps your board private. Never put a key marked `secret` or `service_role` in this file.

## Step 6. Put the website online

Upload the **`site`** folder (it has `index.html` and `config.js`).

### Option A. Cloudflare Pages (recommended)

1. Sign up at <https://dash.cloudflare.com>. Open **Workers & Pages > Create application > Pages > Upload assets**.
2. Name the project (for example `board`), drag in the **`site`** folder, and press **Deploy**.
3. Your address is `https://board.pages.dev` (with your project name). To update later, upload the folder again.

Cloudflare's free plan allows commercial use and does not need a public repository.

### Option B. GitHub Pages

1. Create a GitHub repository and choose **Settings > Pages > Build and deployment > Source: GitHub Actions**. **Do this first**, before pushing anything. **On a free GitHub plan the repository must be public**, so anyone can read the code and `config.js`. That is fine here because the keys in `config.js` are public by design, but GitHub's terms bar using Pages for a business's commercial site, so an internal tool is a grey area. Choose Cloudflare if in doubt.
2. Put this folder in the repository and push it to the `main` branch. The file `.github/workflows/pages.yml` publishes the `site` folder each time you push. If the first run failed because Pages was not switched on yet, open the **Actions** tab and re-run it.
3. Your address will be `https://YOURNAME.github.io/REPO/`.

**Seeing this README instead of the board?** Pages is set to **Deploy from a branch**, which publishes the whole repository and shows the README. Either switch **Source** to **GitHub Actions** (best: the address then opens the board directly), or leave it: the `index.html` at the top of this folder forwards visitors to `site/`, so the board still opens.

Write down your address. You need it in the next step.

## Step 7. Let people sign in with a password

People sign in with their email and a password. Nobody needs an email to arrive: the first time (and after a forgotten password) they use a **join code** that you give them.

1. **Switch off email confirmation.** In Supabase open **Authentication > Sign In / Providers > Email** and switch **Confirm email** off. Leave **Allow new users to sign up** on. Press **Save**. (With confirmation on, Supabase would try to email every new person, and its built-in sender only reaches your own Supabase team.)
2. **Allow the website address.** Open **Authentication > URL Configuration**. Set **Site URL** to your address from step 6, and add the same address under **Redirect URLs**.
3. **Optional: stop strangers making accounts.** Open **Authentication > Hooks**, add a **Before User Created** hook of type **Postgres function**, and choose `public.hook_before_user_created`. Then only emails on your team list can create a sign-in. If your plan does not offer this hook, skip it: an account without the join code sees nothing.
4. **Optional: Google sign-in.** Create an OAuth client in Google Cloud Console (type Web application, redirect URI `https://YOURPROJECT.supabase.co/auth/v1/callback`), paste its ID and secret in **Authentication > Sign In / Providers > Google**, and set `google: true` in `config.js`. Upload the site again afterwards.

**Why passwords are safe here.** Anyone can type any email into a sign-up form, so a password account only opens the board once it has been linked with that person's join code. Codes are 8 characters, work once, and lock after 10 wrong tries. Changing someone's email in **Team** gives them a new code too.

<!-- Paused: 6-digit sign-in codes by email. They need an email sender in Supabase
     (Authentication > Emails > SMTP Settings) and a Magic Link template showing {{ .Token }}. -->

## Step 8. Sign in for the first time

1. Open your board's address and press **First time here, or forgot your password?**
2. Enter your email, the join code from step 3, and a new password (8 characters or more). Press **Set password and sign in**.
3. Open **Settings** (the gear, top right) and choose **Desktop notifications** (see below).

## Step 9. Add your team

1. In **Team > People** enter each person's name and work email and press **Add** (or press Enter). Choose **PM** only for people who should manage the team.
2. The board shows their **join code**. Send it to them with the website address, by chat or in person (not by email to an address you are unsure of: the code is the key). They press **First time here**, enter their email, the code and a new password. Their time zone is taken from their browser.
3. **Forgot a password?** In **Team**, press **Reset password** next to the person. They get a new code; their old password stops opening the board straight away.

To give someone a task, open a card and choose the **Owner**, or type `@sam` when you add a task. Only a PM can give tasks to other people. Members can claim unassigned cards for themselves.

To change a PM's email, first make them a member, change the email, then make them a PM again.

**Bringing your existing work over.** In **Team › Moving in › Bring in cards**, choose an export from Trello (JSON), Notion (CSV), GitHub Issues (JSON from `gh issue list --limit 500 --json number,title,body,labels,assignees,state,url`) or any CSV with a title column. You see a preview first. Finished cards stay behind unless you tick the box, and people who are not on the team are left unassigned. Tip: bring only what is still open, and archive the old tool.

## Step 10. Notifications

### Desktop notifications (each person, in their own browser)

**Settings > Desktop notifications** shows a system pop-up, like the Claude desktop app does, when something lands with you. Choose **Things that need me** (a new task, a review, a card sent back, a block) or **Every update on my cards**. The browser asks once for permission.

* They appear while the board is open in a tab or window, even in the background or minimised. They do not arrive when every board tab is closed.
* For a dock or taskbar icon, open the board in Chrome or Edge and choose **Install** (the icon in the address bar, or **Cast, save and share > Install page as app**). It then runs in its own window like a desktop app. Keep that window open.
* The bell in the app keeps a list of everything either way.

### Emails, sent by your Claude app

The board decides who gets what and when (the calm rules in `docs/NOTIFICATIONS.md`). The emails then wait in an outbox. A scheduled task in your Claude app picks them up and sends them through your email connector, from your own address.

1. **Connect your mailbox to Claude.** In the Claude app open **Settings > Connectors** and connect **Gmail** (or another email connector that can send).
2. **Give the board's Claude key to this folder.** On the board open **Team > Email**, press **Copy key**, and paste it into a new file `mailer/claude-key.txt` in this folder. (The file is never committed. The key only lets someone read and tick off the outbox.)
3. Check it: in a terminal in this folder run `node mailer/outbox.mjs take`. It prints `[]` when nothing is waiting.
4. **The scheduled task.** In the Claude app, **Scheduled** in the sidebar lists **Nudge Board: send waiting emails** (task id `nudge-board-email`). It runs every 30 minutes on weekdays from 08:00 to 18:30, runs `node mailer/outbox.mjs take`, sends each email with Gmail's send tool exactly as written, and reports each one back with `done` or `fail`. Until the key file from item 2 exists, each run just stops and says so. If the task is missing on a new computer, ask Claude in this folder to "create the Nudge Board email task" with those steps.
5. On the board, in **Team > Email**, check that **Email service** says **Claude**, the **Board web address** is right, and press **Save email settings**. Press **Send me a test email**. It goes out on the task's next run. When it arrives, tick **Send emails**.

Things to know:

* Scheduled tasks run while the Claude app is open on your computer. If it is closed, emails wait, and a task that was due runs when the app next opens. Emails nobody picked up within a day are dropped (late news is noise); the bell still has them.
* Each run uses some of your Claude usage, even when there is nothing to send. Change the schedule in the Claude app's scheduled tasks if you want fewer runs.
* **Team > Email** shows when Claude last checked the outbox and how many emails are waiting.

## Step 11. Connect GitHub (optional, recommended)

Cards then move on their own: pushes, new branches, opened pull requests and "Fixes CHK-12" move a card to **Doing**, and a merged pull request moves it to **QA Test**. Nothing moves straight to Done: after QA Test a card goes to **Security** for the cyber-security sign-off (tick **Security reviewer** next to those people in **Team**), then to Done. Cards never move backwards, and moves made this way name the GitHub user.

1. On the board open **Team › GitHub**. It shows three values with Copy buttons.
2. In each code repository on GitHub: **Settings › Secrets and variables › Actions › New repository secret**. Add `NUDGE_SUPABASE_URL`, `NUDGE_PUBLISHABLE_KEY` and `NUDGE_GITHUB_KEY` with those values. The GitHub key only lets GitHub move cards; keep it in secrets, never in code.
3. Add the workflow file shown there (a copy is in `github/nudge-board.yml` in this folder) to the repository as `.github/workflows/nudge-board.yml`, and commit it.
4. Name branches after cards. Every card shows its branch name, like `chk-12-fix-login`. **Team › GitHub** shows when GitHub last reported in.

On the shared board the paste-in **Git sync** button is hidden, because GitHub does this for you. (Press `g` if you ever need it.)

## Step 12. Keep the free database awake

Supabase pauses free projects after about a week with little activity, and you get a warning email a week earlier. A paused project can be restored from the dashboard. A team using the board every day never hits this, but holidays can. Two free safety nets:

* **GitHub.** Add the two secrets named in `.github/workflows/keepalive.yml` and it pings the database twice a week. GitHub can run late and switches schedules off after 60 days without a commit in a public repository.
* **cron-job.org** (free). Create a job that sends a `POST` to `https://YOURPROJECT.supabase.co/rest/v1/rpc/mute_by_token` every 3 days, with headers `apikey: YOUR_PUBLISHABLE_KEY` and `Content-Type: application/json`, and body `{"p_token":"00000000-0000-0000-0000-000000000000","p_mode":"off"}`.

## Step 13. Keep a copy

The free Supabase plan has no automatic backups. As PM, **Settings > Keep a copy > Copy card list** gives you a readable list of the cards. It is for your records and is not a one-click restore. For a full copy, open **Table Editor** in Supabase and export the tables `cards`, `people`, `board`, `card_events` and `cycle_history` as CSV now and then.

---

## If something is off

| What you see | What to do |
| --- | --- |
| The site opens with example cards and no sign-in, plus a yellow "Team mode is off" note | `config.js` still has empty values. Redo step 5 and upload again. |
| "Cannot reach the server" | The URL or key in `config.js` has a typo, or your connection dropped. |
| "Not on the team yet" after signing in | That password account is not linked yet. Enter the join code on that screen, or ask the PM for one. |
| "That email and password do not match" | Use **First time here, or forgot your password?** with a join code. The PM can make a new one with **Reset password**. |
| "Supabase wants to confirm this email" | Switch off **Confirm email** (step 7, item 1), then use the same code again. |
| "Too many wrong tries for this code" | The PM presses **Reset password** next to that person for a new code. |
| "This email is not on the team" when setting a password | The optional hook from step 7 is on and the email is not in the Team list. Add it first. |
| No desktop notifications | **Settings > Desktop notifications** is on, the browser allows notifications for the site, and the board is open in a tab or window. Check the computer's own notification settings for the browser too. |
| Team > Email says Claude has not picked up email yet | Step 10: the Gmail connector, `mailer/claude-key.txt`, and the scheduled task. Is the Claude app open? |
| `outbox.mjs` says "Wrong Claude key" | Copy the key again from **Team > Email** into `mailer/claude-key.txt`. |
| Test email says to set the web address | Fill in **Board web address** and press **Save email settings**. |
| Nobody gets task emails | Tick **Send emails** in Team. Emails are queued 08:00 to 17:00 on weekdays in each person's time zone, about 3 minutes after the change, and go out on Claude's next run. |
| Anything else | Run the blocks in `supabase/check.sql`. It shows whether the schedule is running and what was sent. |

## What the free plans allow (checked 29 September 2026)

| Service | Free allowance that matters | Watch out for |
| --- | --- | --- |
| Supabase | 500 MB database, 50,000 monthly users, 200 live connections, 2 million live messages a month | Pauses after about a week of low activity. No automatic backups. |
| Gmail through Claude | Gmail's own sending limits for your account | The board stops at 80 emails a day for the whole team. Each Claude task run uses some of your Claude usage. |
| Cloudflare Pages | No stated bandwidth cap for static files, 500 builds a month | Choosing Git or drag-and-drop upload is permanent for that project. |
| GitHub Pages | 100 GB a month, public repository on a free plan | Terms bar commercial sites as a main purpose. |

Free plans change. Supabase's and Resend's pricing pages are the source of truth. Supabase's own pages did not state whether a card is needed or whether commercial use of the free plan is allowed. Read <https://supabase.com/terms> before you rely on it for company work.
