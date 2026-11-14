-- Demo sign-ins for trying each view: one extra project manager and two developers.
--
-- 1. Change base_email below to your own work email. The demos become you+demo-pm@..., you+demo-dev1@...
--    and you+demo-dev2@..., so no new mailboxes are needed and nothing is ever emailed to them.
-- 2. Paste this whole file into Supabase > SQL Editor > New query and press Run.
--    The result lists each demo email with its join code. Codes are random, so nobody can guess them.
-- 3. On the board press "First time here, or forgot your password?", enter a demo email, its code
--    and any password of 8 or more characters. Sign out (Settings > Sign out) to switch accounts.
--
-- These are real people on your board. Remove them when you are done (the block at the bottom).
-- Running this file again does not add them twice. It just lists their codes again.

do $$
declare
  base_email text := 'you@yourcompany.com';   -- <- change this to your own work email
  local_part text := split_part(base_email, '@', 1);
  domain text := split_part(base_email, '@', 2);
  tz text := (select timezone from public.board where id = 1);
begin
  if base_email = 'you@yourcompany.com' or domain = '' then
    raise exception 'Change base_email at the top of this file to your own work email first.';
  end if;
  insert into public.people (name, email, role, timezone) values
    ('Demo PM',       local_part || '+demo-pm@'   || domain, 'pm',     tz),
    ('Demo Dev One',  local_part || '+demo-dev1@' || domain, 'member', tz),
    ('Demo Dev Two',  local_part || '+demo-dev2@' || domain, 'member', tz)
  on conflict do nothing;
end $$;

select name, email, role,
       case when join_code is null then '(already has a password)'
            else substr(private.clean_code(join_code), 1, 4) || '-' || substr(private.clean_code(join_code), 5) end as join_code
  from public.people
 where email like '%+demo-%'
 order by role desc, name;

-- Remove the demo people when you are done (cards they owned become unassigned).
-- Remove the two dashes in front of each line below, then press Run.
-- delete from public.people where email like '%+demo-%';
-- delete from auth.users where email like '%+demo-%';
