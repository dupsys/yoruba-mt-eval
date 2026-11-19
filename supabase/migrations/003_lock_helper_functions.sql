-- Migration 003: signed-out visitors may no longer call the helper functions.
-- Run once in the Supabase SQL editor (safe to re-run). Already included in supabase/schema.sql for new projects.
--
-- PostgreSQL lets everyone (PUBLIC) execute new functions by default, so revoking from 'anon' alone did not stop
-- signed-out calls to /rest/v1/rpc/is_admin (they only ever returned false or null, so nothing leaked).
-- Signed-in users keep EXECUTE, because the row-level-security policies call these functions on their behalf.
--
-- Each function is handled only if it exists, so a missing function cannot abort the whole migration.
-- The final SELECT reports the resulting permissions.

do $$
declare
  f text;
begin
  foreach f in array array['public.current_rater_code()', 'public.is_admin()'] loop
    if to_regprocedure(f) is not null then
      execute format('revoke execute on function %s from public, anon', f);
      execute format('grant execute on function %s to authenticated', f);
      raise notice 'locked %', f;
    else
      raise notice 'not found (skipped): %', f;
    end if;
  end loop;
  -- trigger functions are not meant to be called directly by anyone
  foreach f in array array['public.touch_updated_at()', 'public.raters_guard()'] loop
    if to_regprocedure(f) is not null then
      execute format('revoke execute on function %s from public, anon, authenticated', f);
      raise notice 'locked %', f;
    else
      raise notice 'not found (skipped): %', f;
    end if;
  end loop;
end $$;

select p.oid::regprocedure::text                                    as function,
       has_function_privilege('anon', p.oid, 'execute')             as anon_can_call,
       has_function_privilege('authenticated', p.oid, 'execute')    as signed_in_can_call
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname in ('current_rater_code', 'is_admin', 'touch_updated_at', 'raters_guard')
order by 1;
