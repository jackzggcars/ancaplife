-- ANCAP LIFE · sign-ups without confirmation emails
-- Run this ONCE in Supabase > SQL Editor, AFTER turning off "Confirm email" (Authentication > Sign In / Providers > Email).
-- It lets anyone who signed up while emails were rate-limited (and never got their link) sign in normally.
-- Accounts that are already confirmed are not touched.
update auth.users
set email_confirmed_at = now()
where email_confirmed_at is null
  and deleted_at is null;
