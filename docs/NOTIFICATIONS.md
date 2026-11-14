# How notifications work (and why they stay calm)

The aim: the person who has to act hears about it quickly, everyone else stays informed without being interrupted, and nobody gets a flood.

Three channels:

* **The bell** in the app, always.
* **Desktop notifications**, per person and per browser (**Settings > Desktop notifications**): a system pop-up for anything that lands in the bell, while the board is open in a tab or window. "Things that need me" covers the rows below marked *Bell right away*; "Every update" adds the rest.
* **Email**, decided by the rules below, then sent by the PM's Claude app from their own mailbox (docs/SETUP.md, step 10). "Sent" in this page means "handed to Claude": it goes out on Claude's next run. The task runs every 2 hours, Monday to Saturday, so an email can take up to 2 hours to arrive. Anything Claude has not picked up within a day is dropped.
* **Cycle summaries** are not covered by these rules. A project manager sends one when they choose, from their own Gmail, and it goes out straight away (docs/SETUP.md, "Sending a cycle summary").

## Who is told what

Each of the **QA Test** and **Security** columns has a default reviewer. A project manager chooses it by clicking **Reviewer** under the column's name on the board.

| Something happens | Who | How |
| --- | --- | --- |
| The PM assigns a card to Sam (in any column except Done) | Sam | Bell right away. One short email about 3 minutes later, unless Sam has already picked the card up. |
| A card moves to **QA Test** (or is created there) | The card's reviewer, else QA Test's default reviewer, else the first active PM. Inactive people are skipped. | Bell right away. One short email about 3 minutes later. |
| A card moves to **Security** (or is created there) | Security's default reviewer, else everyone ticked as **Security reviewer** in Team | Bell right away. One short email about 3 minutes later ("Security sign-off: …"). |
| A reviewer sends a card back to To do or Doing (from QA Test or Security) | The card's owner | Same ("Back with you"). |
| A card is sent back to QA Test (from Security or Done), or reopened into Security | That column's reviewer, as in the two rows above | Same ("Back with you"). |
| Someone pulls Sam's card into To do or Doing from Backlog or Done, or reopens it | Sam | Same, because it has just landed in Sam's court. |
| Someone else shuffles Sam's card between To do and Doing | Sam | Bell only, plus Sam's next morning digest. |
| Someone else moves Sam's card anywhere else (for example to Done) | Sam | Bell, plus Sam's next morning digest. |
| Any move by a member | Each PM | Bell. Included in the PM's digest. No instant email. |
| A card is marked **Blocked** | Each PM, and, for a card in QA Test or Security, that column's reviewer | Bell. One short email about 3 minutes later. |
| A card is unblocked | Each PM | Bell only. |
| A card is marked blocked and waiting on Sam | Sam | Bell and desktop notification right away. One short email about 3 minutes later ("Waiting on you: …"), only while the card is still blocked on Sam. |
| Someone @mentions Sam in a comment | Sam | Bell and desktop notification right away. One short email about 3 minutes later ("Mentioned: …"). |
| Someone comments on Sam's card without mentioning Sam | Sam | Bell only. |

Nobody is ever told about their own move.

## Digests

* **PMs** get up to three weekday digests, at 09:00, 13:00 and 17:00 in their own time zone. A digest is only sent when there is something new, and never says "no updates". The 09:00 one also lists cards that are blocked or due within a day. Each such card is listed at most once every 3 days, so a card that stays blocked does not fill every morning. A PM who was just emailed about a block is not told again in the digest.
* **Members** get one digest each weekday at 09:00, only when something is waiting: moves on their cards, anything held back by a limit or a pause, and (for people on "Calm") everything that would otherwise have been an instant email.
* Digest items stay good for five days, so something from Friday afternoon still reaches Monday's digest.

## The calming rules

These are built into the database, in `supabase/setup.sql`, and tested in `tests/sql.test.mjs`.

1. **Wait 3 minutes, never more than 10.** Every change resets the timer, up to a 10-minute cap. An accidental drag that is undone within a few minutes never becomes an email, and a move that ends where it began sends nothing.
2. **Check that it is still true when sending.** If a card was moved on before the email goes out, the email is dropped, not sent late.
3. **One email per person.** Several cards that are due at once go out as one message ("3 cards are waiting for you").
4. **At least 15 minutes between instant emails** to the same person. Anything held back merges into the next one.
5. **At most 5 "your turn" emails per person per day.** The rest go into the next digest.
6. **At most 80 emails a day for the whole team.** When it is reached, the rest wait for the next digest.
7. **Working hours only.** Instant emails arrive 08:00 to 18:00 on weekdays in the recipient's own time zone, and digests come at 09:00, 13:00 and 17:00 on weekdays. Anything due outside those hours is held until the next work morning, not dropped.
8. **Nothing repeats.** The same card in the same state never emails twice.
9. **Failures are retried a little, then stop.** A rejected send is retried up to three times. Errors that will not get better by repeating (for example a rejected address) are not retried.
10. **A kill switch.** In **Team > Email**, untick **Send emails** and instant emails and digests stop at once. The bell and desktop notifications keep working, and the test-email button still works.

## What each person can choose

In **Settings > Your emails**:

* **Normal.** A short email when a task is with you.
* **Calm.** No instant emails. One digest each weekday morning.
* **No email.** The bell only.
* **Pause until Monday,** for holidays. Things that arrive during a pause wait for the first digest afterwards. (Clicked on a Monday, it pauses until Tuesday morning.)

Every email also ends with links to pause until Monday, switch to daily digest only, or turn emails off. They ask you to confirm, and they work without signing in.

PMs who really want an email for every move can tick **Email me every move** next to their name in **Team**. It is off by default because it is the setting most likely to become noise.

## The messages

Short, friendly, one action, and no card details beyond the title. Examples:

* **Your turn: Apple Pay button**. "Sam moved CHK-4 "Apple Pay button" to QA Test. It's with you now, whenever you're ready."
* **New for you: Order receipt email**. "Peter gave you CHK-3 "Order receipt email". Due Fri Oct 2. It's waiting in To do whenever you're ready."
* **Blocked: Load test payment API**. "Priya marked CHK-9 "Load test payment API" as blocked. It might be worth a quick word."

If card titles are sensitive, tick **Keep card titles out of emails** in **Team > Email**. Emails then show only the card number.

## Changing the numbers

The defaults are listed at the bottom of `supabase/check.sql`. For example, to wait 5 minutes instead of 3:

```sql
update public.notify_settings set debounce_min = 5;
```

## Where the numbers come from

Waiting 3 minutes with a 10-minute cap is the same rule Jira Cloud documents for its own notifications, and Slack and Trello also bundle their emails instead of sending each change separately. The other numbers (15 minutes between emails, 5 "your turn" emails a day, 80 a day for the team, three PM digests) are this project's own choices, sized for a team of 3 to 15 people. They are easy to change, and they are tested in `tests/sql.test.mjs`.

## Known limits

* A digest can arrive close to an instant email for the same person, because the 15-minute gap only counts instant emails.
* If a card bounces between columns the bell can show several lines for it. Emails are merged, the bell is not.
* If Claude sends an email but its run stops before it reports back, that email is marked failed after two hours and is not sent again.
* Desktop notifications only appear while the board is open in a tab or window (installing it as an app keeps a window around).
