-- Health check. Paste into SQL Editor and Run one block at a time when something seems off.

-- 1. Are the three scheduled jobs there and active? (expect 3 rows, username postgres)
select jobname, schedule, username, active from cron.job where jobname like 'nudge-%' order by jobname;

-- 2. Did the every-minute worker run recently, and did it succeed?
select j.jobname, r.status, r.start_time, left(r.return_message, 120) as message
  from cron.job_run_details r join cron.job j on j.jobid = r.jobid
 where j.jobname = 'nudge-notify' order by r.start_time desc limit 5;

-- 3. What has been emailed, and how did it go?
select created_at, kind, to_email, subject, status, detail
  from private.email_log order by created_at desc limit 20;

-- 4. What is waiting to go out?
select status, delivery, count(*) from private.notify_queue group by 1, 2 order by 1, 2;

-- 5. Is the API key saved? (true / false; the key itself is never shown)
select exists (select 1 from vault.decrypted_secrets where name = 'email_api_key') as api_key_saved;

-- 6. Email settings
select emails_enabled, provider, from_email, app_url, hide_titles, debounce_min, min_gap_min, instant_daily_cap, daily_cap
  from public.notify_settings;

-- Optional tuning (edit the number, then run). Defaults in brackets.
-- update public.notify_settings set debounce_min = 3;        -- minutes to wait before a "your turn" email [3]
-- update public.notify_settings set debounce_max_min = 10;   -- never wait longer than this [10]
-- update public.notify_settings set min_gap_min = 15;        -- minutes between emails to the same person [15]
-- update public.notify_settings set instant_daily_cap = 5;   -- "your turn" emails per person per day [5]
-- update public.notify_settings set daily_cap = 80;          -- emails for the whole team per day [80, under Resend's free 100]
-- update public.notify_settings set work_start = 8, work_end = 18;  -- instant emails only arrive between these hours on weekdays [8 and 18]. Digests always go at 09:00, 13:00 and 17:00.
