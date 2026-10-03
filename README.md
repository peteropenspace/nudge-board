# Nudge Board

A small board like Jira or Trello that does its own admin: cards sort themselves by deadline, quiet cards get flagged, unfinished work rolls into the next cycle, and your standup writes itself.

It runs two ways:

* **Just you, in one browser.** Open `nudge-board.html` (or `site/index.html`). Data stays in that browser. Nothing to set up.
* **A whole team, shared.** Everyone sees the same board live. The project manager adds people by name and email, assigns tasks, and the right person gets a short, friendly email when a task lands with them, without a flood. Follow **[docs/SETUP.md](docs/SETUP.md)**. It is free and needs no credit card.

## What is in this folder

| Path | What it is |
| --- | --- |
| `site/index.html`, `site/config.js` | The app. Upload the `site` folder to a static host. Leave `config.js` empty for single-browser mode. |
| `nudge-board.html` | A copy of `site/index.html` for opening on its own. |
| `supabase/setup.sql` | Creates the shared database, the team rules, and the calm notification system. Paste it into Supabase once. |
| `supabase/first_pm.sql`, `email_key.sql`, `check.sql` | Small helpers: create the first PM, save the email key, check that everything is running. |
| `docs/SETUP.md` | Step-by-step setup for a non-expert. |
| `docs/NOTIFICATIONS.md` | Exactly who is emailed what, when, and the rules that keep it quiet. |
| `.github/workflows/` | Optional: publish to GitHub Pages, and keep the free database awake. |
| `tests/` | Automated tests for the database and a small server for trying the team screens without a Supabase project. |

## The free stack

| Job | Service |
| --- | --- |
| Shared data, sign-in, live updates, schedules | Supabase (Free plan) |
| Email | Resend (needs your own domain) or Brevo |
| Website | Cloudflare Pages (recommended) or GitHub Pages |

Vercel's free plan is personal and non-commercial only, so it is not recommended for a company tool.

## Testing status

Run the database tests with `cd tests && npm install && npm run test:sql`. They start a real Postgres (no Docker) with a controllable clock and check team access rules, the PM-only assignment rule, the debounce, merging, quiet hours, caps, retries, digests, weekends, pauses, cycle roll-over, and each fix from the review below (264 checks).

The team screens were exercised in a browser against `tests/dev-config.js`, a stand-in for the server: signing in, members and PMs, live changes from other people, version conflicts, undo, edits made while a save is in flight, and the mute links.

An independent review of the database rules, the notification logic, the app's sync code and the docs found real defects. The confirmed ones are fixed and have tests: a leaking "trusted caller" flag, an error that would have stopped the every-minute worker when the daily cap was reached, digest items expiring before Monday, undo touching other people's cards, save replies overwriting newer edits, reloads discarding unsaved work, and several smaller ones. `docs/NOTIFICATIONS.md` lists the few known limits that remain.

Not run here: the parts that only exist on Supabase itself, meaning real sign-in emails, live updates over websockets, the every-minute schedule, the vault, the optional sign-up hook, and real email delivery. Step 8 of the setup guide has you send a test email so you can confirm delivery on your own project in a minute.
