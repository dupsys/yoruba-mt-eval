-- Check Task 2 (proverb meanings) after migration 004 and the item load, and refresh the API's table list.
-- Read-only apart from the refresh; safe to run any number of times. Paste into the Supabase SQL editor and run.

notify pgrst, 'reload schema';   -- make the website's API see newly created tables

create schema if not exists yoeval_check;
revoke all on schema yoeval_check from public, anon, authenticated;
create or replace function yoeval_check.count_rows(t text) returns bigint language plpgsql as $$
declare n bigint;
begin
  if to_regclass(t) is null then return null; end if;
  execute format('select count(*) from %s', t) into n;
  return n;
end $$;

select n, check_name, result from (
  select 1 as n, 'Task 2 tables exist' as check_name,
         case when to_regclass('public.meaning_items') is not null and to_regclass('public.meaning_ratings') is not null
              then 'PASS' else 'FAIL: run migrations/004_meaning_task.sql' end as result
  union all
  select 2, 'Task 2 items loaded',
         case when to_regclass('public.meaning_items') is null then 'FAIL: no table'
              else yoeval_check.count_rows('public.meaning_items')::text || ' items (expected 594)' end
  union all
  select 3, 'Task 1 untouched: comparison items',
         yoeval_check.count_rows('public.items')::text || ' items (expected 150, unchanged)'
  union all
  select 4, 'Task 1 untouched: comparison ratings',
         yoeval_check.count_rows('public.ratings')::text || ' ratings (unchanged)'
  union all
  select 5, 'Separate tables (no shared rows or links)',
         case when to_regclass('public.meaning_ratings') is null then 'FAIL: no table'
              when exists (select 1 from information_schema.referential_constraints rc
                           join information_schema.constraint_column_usage u on u.constraint_name = rc.unique_constraint_name
                           join information_schema.key_column_usage k on k.constraint_name = rc.constraint_name
                           where k.table_name = 'meaning_ratings' and u.table_name in ('items', 'ratings'))
              then 'FAIL: linked to Task 1 tables' else 'PASS: Task 2 only references meaning_items and raters' end
  union all
  select 6, 'Row-level security on Task 2 tables',
         case when (select bool_and(relrowsecurity) from pg_class
                    where oid in (to_regclass('public.meaning_items'), to_regclass('public.meaning_ratings'))) then 'PASS'
              else 'FAIL' end
  union all
  select 7, 'Signed-out visitors have no access to Task 2',
         case when to_regclass('public.meaning_ratings') is null then 'FAIL: no table'
              when has_table_privilege('anon', 'public.meaning_items', 'select')
                or has_table_privilege('anon', 'public.meaning_ratings', 'select') then 'FAIL' else 'PASS' end
  union all
  select 8, 'Task 2 access policies',
         (select count(*)::text from pg_policies where tablename in ('meaning_items', 'meaning_ratings'))
         || ' policies (expected 4)'
) t order by n;
