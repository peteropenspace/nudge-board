-- REFERENCE ONLY. Do not put your real key in this file, and do not save it anywhere in this folder:
-- if the folder is pushed to GitHub, a saved key would be public.
--
-- Type the line below straight into Supabase > SQL Editor > New query, put your real key inside the
-- quotes (Resend keys start with re_), and press Run. The key is stored encrypted in Supabase Vault.
-- It is never put in the website or in the app's settings screen.

-- select vault.create_secret('re_YOUR_KEY_HERE', 'email_api_key', 'Email provider API key');

-- To change the key later, type this instead (one line, with the new key):
-- select vault.update_secret((select id from vault.secrets where name = 'email_api_key'), 'NEW_KEY_HERE');
