-- Shows everyone's join code. Paste into Supabase > SQL Editor > New query and press Run.
-- A blank code means that person has already set a password.
--
-- "column join_code does not exist"? Run supabase/setup.sql first (the whole file). It adds the column.

select name, email, role,
       substr(private.clean_code(join_code), 1, 4) || '-' || substr(private.clean_code(join_code), 5) as join_code
  from public.people
 order by role desc, name;
