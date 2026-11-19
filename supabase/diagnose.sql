-- Diagnose what is installed on this database: object listing plus one self-undoing behaviour test.
-- Run in Supabase > SQL Editor and share the whole result table. Safe to re-run.
--
-- The behaviour test lives in a function in the private schema "yoeval_check" (not exposed by the website's API,
-- executable only by the database owner). The report is one SELECT, so no temporary tables are needed.

create schema if not exists yoeval_check;
revoke all on schema yoeval_check from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema yoeval_check from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on schema yoeval_check from authenticated'; end if;
end $$;

create or replace function yoeval_check.demote_self_test() returns text
language plpgsql as $$
declare cnt integer; outcome text; me text := current_user;
begin
  begin
    insert into public.raters(email, rater_code, is_admin) values ('diag-admin@example.org', 'ZZDIAG', true);
    perform set_config('request.jwt.claims', '{"email":"diag-admin@example.org","role":"authenticated"}', true);
    perform set_config('role', 'authenticated', true);
    begin
      update public.raters set is_admin = false where rater_code = 'ZZDIAG';
      get diagnostics cnt = row_count;
      outcome := case when cnt = 1 then 'ALLOWED: admin removed own admin role (guard missing)'
                      else 'not applied (0 rows)' end;
    exception when others then outcome := 'BLOCKED: ' || sqlerrm;
    end;
    perform set_config('role', me, true);
    raise exception 'undo';
  exception when raise_exception then null;   -- rolls back the test evaluator and the role switch
  end;
  return outcome;
end $$;
revoke all on function yoeval_check.demote_self_test() from public;

select item, value from (
  select 1 as ord, 'function present: ' || p.oid::regprocedure::text as item,
         'security definer: ' || p.prosecdef || ', anon can call: ' || has_function_privilege('anon', p.oid, 'execute') as value
  from pg_proc p where p.pronamespace = 'public'::regnamespace
    and p.proname in ('current_rater_code', 'is_admin', 'touch_updated_at', 'raters_guard')
  union all
  select 2, 'trigger on ' || c.relname || ': ' || t.tgname, 'runs ' || t.tgfoid::regprocedure::text
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
  union all
  select 3, 'policy on ' || tablename || ': ' || policyname, cmd from pg_policies where schemaname = 'public'
  union all
  select 4, 'constraint: ' || conname, pg_get_constraintdef(oid) from pg_constraint
  where conrelid = 'public.raters'::regclass and contype = 'c'
  union all
  select 5, 'grant to authenticated on raters', string_agg(privilege_type || coalesce(' (' || column_name || ')', ''), ', '
                                                           order by privilege_type, column_name)
  from (select privilege_type::text, null::text column_name from information_schema.role_table_grants
        where table_schema = 'public' and table_name = 'raters' and grantee = 'authenticated'
        union all
        select privilege_type::text, column_name::text from information_schema.role_column_grants
        where table_schema = 'public' and table_name = 'raters' and grantee = 'authenticated'
          and privilege_type = 'UPDATE'
          and not exists (select 1 from information_schema.role_table_grants
                          where table_schema = 'public' and table_name = 'raters' and grantee = 'authenticated'
                            and privilege_type = 'UPDATE')) g
  union all
  select 6, 'behaviour: admin demotes self', yoeval_check.demote_self_test()
  union all
  select 7, 'data: items', count(*)::text from public.items
  union all
  select 8, 'data: evaluators (active / admins)',
         count(*) filter (where active) || ' / ' || count(*) filter (where active and is_admin)
  from public.raters where email not like 'diag-%@example.org'
) report
order by ord, item;
