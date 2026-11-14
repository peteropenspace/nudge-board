-- Run this ONCE, after setup.sql. Change the five values, then press Run.
-- It creates the first project manager and names your board.
-- The result shows your join code. On the board, press "First time here", enter this email,
-- the code and a new password. Lost it? Run supabase/join_codes.sql.

select private.bootstrap(
  'Your Name',             -- your name, as your team should see it
  'you@yourcompany.com',   -- your work email
  'My board',              -- the board's name
  'TSK',                   -- 2 to 5 capital letters or numbers, used in card numbers like TSK-12
  'Africa/Lagos'           -- your time zone, for example Europe/London or America/New_York
);
