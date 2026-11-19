-- Migration 003: signed-out visitors may no longer call the helper functions.
-- Run once in the Supabase SQL editor (safe to re-run). Already included in supabase/schema.sql for new projects.
--
-- PostgreSQL lets everyone (PUBLIC) execute new functions by default, so revoking from 'anon' alone did not stop
-- signed-out calls to /rest/v1/rpc/is_admin (they only ever returned false or null, so nothing leaked).
-- Signed-in users keep EXECUTE, because the row-level-security policies call these functions on their behalf.

revoke execute on function public.current_rater_code() from public, anon;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.current_rater_code() to authenticated;
grant execute on function public.is_admin() to authenticated;

-- Trigger functions are not meant to be called directly by anyone.
revoke execute on function public.touch_updated_at() from public, anon, authenticated;
revoke execute on function public.raters_guard() from public, anon, authenticated;
