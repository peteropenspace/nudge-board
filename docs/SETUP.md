# Set up the shared board (free)

This puts your board online so the whole team sees the same cards, and it emails people, calmly, when a task needs them. It takes about 45 minutes the first time. Nothing here needs a credit card.

You will use three free services:

| What | Service | Why this one |
| --- | --- | --- |
| Data, sign-in, live updates, schedules | **Supabase** (Free plan) | One dashboard for all of it. |
| Email that goes out | **Resend** (Free plan) | Simple and free. It needs a domain you own, such as `yourcompany.com`. |
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
2. You will sign in with that email.

If you typed your email wrong, run this with the right one (it fixes the PM row; running `first_pm.sql` again does nothing once the board has people):

```sql
update public.people set email = 'right@yourcompany.com' where role = 'pm';
```

## Step 4. Set up email sending

You need this for the sign-in codes and for the notification emails.

1. Make a free account at <https://resend.com>. Under **Domains**, add your domain and add the DNS records it shows you, where your domain is managed. Wait until it says **Verified**.
2. Under **API Keys**, create a key with **Sending access**, and copy it (it starts with `re_`).
3. Save the key in your database's vault, where it is stored encrypted:
   1. In Supabase open **SQL Editor > New query**.
   2. Type this line, put your real key inside the quotes, and press **Run**:

      ```sql
      select vault.create_secret('re_YOUR_KEY_HERE', 'email_api_key', 'Email provider API key');
      ```

   **Do not save your key into a file in this folder.** If you push this folder to GitHub (step 6, option B) a saved key would be public. (The file `supabase/email_key.sql` is only a copy of the line above for reference.)

**No domain?** Resend cannot email anyone except you until a domain is verified. Brevo can send from a single verified address instead. Make a free Brevo account, verify a sender address (not a `gmail.com` one, which Brevo may rewrite), and create an API key. Then use the same `create_secret` line with that key, and choose **Brevo** in step 8. Brevo may ask to approve your account before its first email, and may add its own footer. For sign-in codes (step 7) use Brevo's SMTP relay (host `smtp-relay.brevo.com`, port `587`, with the login and SMTP key shown in Brevo's SMTP settings). We could not confirm these details on Brevo's own pages, so check them there.

## Step 5. Point the website at your project

1. In Supabase open **Project Settings > API Keys** (the **Connect** button at the top also shows them).
2. Copy the **Project URL** and the **publishable key** (it starts with `sb_publishable_`).
3. Open `site/config.js` and paste them in:

   ```js
   window.NUDGE_CONFIG = {
     supabaseUrl: 'https://YOURPROJECT.supabase.co',
     supabaseKey: 'sb_publishable_...',
     google: false
   };
   ```

These two values are **meant to be public**. They only work together with sign-in and the team list, which is what keeps your board private. Never put a key marked `secret` or `service_role` in this file.

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

Write down your address. You need it in the next step.

## Step 7. Let people sign in

The app signs people in with a 6-digit code sent to their email. Supabase's built-in email sender only emails your own Supabase team and only twice an hour, so connect a real sender.

1. **Sender.** Supabase: **Authentication > Emails > SMTP Settings** (older dashboards: **Authentication > SMTP Settings**). Turn on **Enable custom SMTP** and enter:
   * Host `smtp.resend.com`, port `465`, username `resend`, password = your Resend API key
   * Sender email = an address on your verified domain, such as `board@yourcompany.com`, and the sender name `Nudge Board`
2. **Show the code in the email.** **Authentication > Emails > Templates.** Open **Magic Link** and **Confirm signup**. In each, replace the body with a short message that contains `Your code is: {{ .Token }}`, and **remove the link**. (A link can be opened by an email scanner, which can use up the code.)
3. **Allow the website address.** Open **Authentication > URL Configuration**. Set **Site URL** to your address from step 6, and add the same address under **Redirect URLs** (write it exactly, for example `https://yourcompany.github.io/board/` or `https://board.pages.dev/`).
4. **Keep it safe.** Leave **Confirm email** switched on (it is by default), and do not switch on any other sign-in method that uses passwords. The app ignores password sessions anyway.
5. **Optional: stop strangers requesting codes.** Open **Authentication > Hooks**, add a **Before User Created** hook of type **Postgres function**, and choose `public.hook_before_user_created`. Then only people on the team list can even get a code. (If your dashboard does not offer this hook on the free plan, skip it. The board stays private without it, because nobody sees anything unless their email is on the team list.)
6. **Optional: Google sign-in.** If your team uses Google accounts you can add a "Continue with Google" button. Create an OAuth client in Google Cloud Console (type Web application, redirect URI `https://YOURPROJECT.supabase.co/auth/v1/callback`), paste its ID and secret in **Authentication > Sign In / Providers > Google**, and set `google: true` in `config.js`. Upload the site again afterwards.

Signing in never gives access on its own. Only people whose email is on the team list can see anything.

## Step 8. Turn on notifications

1. Open your board's address and sign in with your email. (You will get a code by email.)
2. Press **Team** (top right, PM only) and scroll to **Email**.
3. Set **From email** to an address on your verified domain (for example `board@yourcompany.com`). The **Board web address** is filled in for you. It makes the buttons and the pause links in every email work. Press **Save email settings**.
4. Press **Send me a test email**. It should arrive within a minute. The lines under the button show whether the key is saved and how many emails went out today.
5. When the test arrives, tick **Send emails**. Until you do, nobody gets email, though the bell in the app works.

## Step 9. Add your team

1. In **Team > People** enter each person's name and work email and press **Add** (or press Enter). Choose **PM** only for people who should manage the team.
2. Send them the website address. They sign in with their email and a code. Their time zone is taken from their browser.

To give someone a task, open a card and choose the **Owner**, or type `@sam` when you add a task. Only a PM can give tasks to other people. Members can claim unassigned cards for themselves.

To change a PM's email, first make them a member, change the email, then make them a PM again.

## Step 10. Keep the free database awake

Supabase pauses free projects after about a week with little activity, and you get a warning email a week earlier. A paused project can be restored from the dashboard. A team using the board every day never hits this, but holidays can. Two free safety nets:

* **GitHub.** Add the two secrets named in `.github/workflows/keepalive.yml` and it pings the database twice a week. GitHub can run late and switches schedules off after 60 days without a commit in a public repository.
* **cron-job.org** (free). Create a job that sends a `POST` to `https://YOURPROJECT.supabase.co/rest/v1/rpc/mute_by_token` every 3 days, with headers `apikey: YOUR_PUBLISHABLE_KEY` and `Content-Type: application/json`, and body `{"p_token":"00000000-0000-0000-0000-000000000000","p_mode":"off"}`.

## Step 11. Keep a copy

The free Supabase plan has no automatic backups. As PM, **Settings > Keep a copy > Copy card list** gives you a readable list of the cards. It is for your records and is not a one-click restore. For a full copy, open **Table Editor** in Supabase and export the tables `cards`, `people`, `board`, `card_events` and `cycle_history` as CSV now and then.

---

## If something is off

| What you see | What to do |
| --- | --- |
| The site opens with example cards and no sign-in, plus a yellow "Team mode is off" note | `config.js` still has empty values. Redo step 5 and upload again. |
| "Cannot reach the server" | The URL or key in `config.js` has a typo, or your connection dropped. |
| Signed in, but "Not on the team yet" | The email you signed in with is not in the **Team** list. Add it, or use the same email. |
| No sign-in code arrives | Step 7 items 1 and 2. Check spam. Wait 60 seconds between tries. |
| "This email is not on the team" when asking for a code | The optional hook from step 7 is on and the email is not in the Team list. Add it first. |
| Test email says "No email API key yet" | Run the `create_secret` line from step 4. |
| Test email says the provider rejected it | The From address must be on a domain that shows **Verified** in Resend. |
| Test email says to set the web address or From email | Fill both in and press **Save email settings** (step 8). |
| Nobody gets task emails | Tick **Send emails** in Team. Emails go out 08:00 to 18:00 on weekdays in each person's time zone, about 3 minutes after the change. |
| Anything else | Run the blocks in `supabase/check.sql`. It shows whether the schedule is running and what was sent. |

## What the free plans allow (checked 29 September 2026)

| Service | Free allowance that matters | Watch out for |
| --- | --- | --- |
| Supabase | 500 MB database, 50,000 monthly users, 200 live connections, 2 million live messages a month | Pauses after about a week of low activity. No automatic backups. |
| Resend | 3,000 emails a month and 100 a day, 3 domains | Needs a verified domain. The app stops at 80 a day so you never hit the cap. Sign-in codes share this allowance. |
| Brevo | About 300 emails a day (reported, not confirmed on Brevo's own page) | May need account approval. |
| Cloudflare Pages | No stated bandwidth cap for static files, 500 builds a month | Choosing Git or drag-and-drop upload is permanent for that project. |
| GitHub Pages | 100 GB a month, public repository on a free plan | Terms bar commercial sites as a main purpose. |

Free plans change. Supabase's and Resend's pricing pages are the source of truth. Supabase's own pages did not state whether a card is needed or whether commercial use of the free plan is allowed. Read <https://supabase.com/terms> before you rely on it for company work.
