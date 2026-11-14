# Nudge Board

A small board like Jira or Trello that does its own admin: cards sort themselves by deadline, quiet cards get flagged, unfinished work rolls into the next cycle, and your standup writes itself.

It runs two ways:

* **Just you, in one browser.** Open `nudge-board.html` (or `site/index.html`). Data stays in that browser. Nothing to set up.
* **A whole team, shared.** Everyone sees the same board live and signs in with a password. The project manager adds people by name and email and gives each one a join code. When a task lands with someone they get a desktop notification, and a short, friendly email that the PM's Claude app sends, without a flood. Follow **[docs/SETUP.md](docs/SETUP.md)**. It is free and needs no credit card or email service.

## What is in this folder

| Path | What it is |
| --- | --- |
| `site/index.html`, `site/config.js` | The app. Upload the `site` folder to a static host. Leave `config.js` empty for single-browser mode. |
| `nudge-board.html` | A copy of `site/index.html` for opening on its own. |
| `supabase/setup.sql` | Creates the shared database, the team rules, and the calm notification system. Paste it into Supabase once. |
| `supabase/first_pm.sql`, `check.sql` | Small helpers: create the first PM (it prints your join code), check that everything is running. `email_key.sql` is only for the paused Resend/Brevo route. |
| `github/nudge-board.yml` | The GitHub workflow that moves cards when people push and merge (docs/SETUP.md, step 11). |
| `supabase/join_codes.sql`, `demo_accounts.sql` | List everyone's join code. Add a demo PM and two demo developers for trying each view (remove them afterwards). |
| `mailer/outbox.mjs` | What the Claude email task runs to pick up waiting emails and report them sent. |
| `docs/SETUP.md` | Step-by-step setup for a non-expert. |
| `docs/NOTIFICATIONS.md` | Exactly who is emailed what, when, and the rules that keep it quiet. |
| `.github/workflows/` | Optional: publish to GitHub Pages, and keep the free database awake. |
| `tests/` | Automated tests for the database and a small server for trying the team screens without a Supabase project. |

## The free stack

| Job | Service |
| --- | --- |
| Shared data, sign-in, live updates, schedules | Supabase (Free plan) |
| Email | Your Claude app with an email connector (Resend and Brevo are still in the code, paused) |
| Website | Cloudflare Pages (recommended) or GitHub Pages |

Vercel's free plan is personal and non-commercial only, so it is not recommended for a company tool.

## Testing status

Run the database tests with `cd tests && npm install && npm run test:sql`. They start a real Postgres (no Docker) with a controllable clock and check team access rules, the PM-only assignment rule, the debounce, merging, quiet hours, caps, retries, digests, weekends, pauses, cycle roll-over, password sign-in with join codes, Claude's email outbox, and each fix from the review below (303 checks).

The team screens were exercised in a browser against `tests/dev-config.js`, a stand-in for the server: signing in, members and PMs, live changes from other people, version conflicts, undo, edits made while a save is in flight, and the mute links.

An independent review of the database rules, the notification logic, the app's sync code and the docs found real defects. The confirmed ones are fixed and have tests: a leaking "trusted caller" flag, an error that would have stopped the every-minute worker when the daily cap was reached, digest items expiring before Monday, undo touching other people's cards, save replies overwriting newer edits, reloads discarding unsaved work, and several smaller ones. `docs/NOTIFICATIONS.md` lists the few known limits that remain.

Not run here: the parts that only exist on Supabase itself, meaning real Supabase sign-up and password sign-in, deleting an old sign-in account (`start_join`), live updates over websockets, the every-minute schedule, the optional sign-up hook, real desktop notifications (the logic was checked with a stand-in), and real sending by Claude through Gmail. Step 10 of the setup guide has you send a test email so you can confirm delivery on your own project.
