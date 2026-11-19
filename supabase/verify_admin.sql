-- Verify the access rules on the live database, including migration 002 (admin management of evaluators).
-- Run in Supabase > SQL Editor. It creates temporary test evaluators, acts as each of them under the real
-- row-level-security rules, records PASS/FAIL for every check, and UNDOES every change it makes
-- (each check runs in a sub-transaction that is rolled back). Your data is not modified.

-- The checks live in a function in the private schema "yoeval_check" (not exposed by the website's API, executable
-- only by the database owner), and the report is one SELECT, so no temporary tables are needed.

create schema if not exists yoeval_check;
revoke all on schema yoeval_check from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema yoeval_check from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on schema yoeval_check from authenticated'; end if;
end $$;

create or replace function yoeval_check.verify() returns table (n integer, check_name text, result text, detail text)
language plpgsql as $$
#variable_conflict use_column
declare
  me text := current_user;
  res text[] := '{}';
  ok boolean; cnt integer; msg text;
  adm constant text := '{"email":"verify-admin@example.org","role":"authenticated"}';
  rat constant text := '{"email":"verify-rater@example.org","role":"authenticated"}';
  neu constant text := '{"email":"verify-new@example.org","role":"authenticated"}';
begin
  -- 0. migration objects present
  select count(*) into cnt from pg_policies where schemaname = 'public' and tablename = 'raters'
    and policyname in ('raters_admin_insert', 'raters_admin_update');
  res := res || array['migration 002 policies installed', case when cnt = 2 then 'PASS' else 'FAIL' end, cnt || ' of 2'];
  select count(*) into cnt from pg_trigger where tgname = 'raters_guard' and not tgisinternal;
  res := res || array['self-demotion guard installed', case when cnt = 1 then 'PASS' else 'FAIL' end, ''];
  select count(*) into cnt from pg_constraint where conname in ('raters_email_format', 'raters_code_format');
  res := res || array['email and code checks installed', case when cnt = 2 then 'PASS' else 'FAIL' end, cnt || ' of 2'];

  -- helper: every check below first creates its test evaluators as the table owner, then switches to the
  -- signed-in role with a test email, and finally raises 'undo' so that all of its changes are rolled back.

  -- 1. admin can add an evaluator, who immediately counts as registered
  begin
    insert into public.raters(email, rater_code, is_admin) values ('verify-admin@example.org', 'ZZVADM', true);
    perform set_config('request.jwt.claims', adm, true); perform set_config('role', 'authenticated', true);
    begin
      insert into public.raters(email, rater_code) values ('verify-new@example.org', 'ZZVNEW');
      ok := true; msg := '';
    exception when others then ok := false; msg := sqlerrm; end;
    res := res || array['admin can add an evaluator', case when ok then 'PASS' else 'FAIL' end, msg];
    if ok then
      perform set_config('request.jwt.claims', neu, true);
      res := res || array['new evaluator is registered immediately',
                          case when public.current_rater_code() = 'ZZVNEW' then 'PASS' else 'FAIL' end, ''];
      select count(*) into cnt from public.items;
      res := res || array['new evaluator can read items', case when cnt > 0 then 'PASS' else 'CHECK' end,
                          case when cnt > 0 then cnt || ' items visible' else 'no items loaded yet (run private/items_focus.sql)' end];
    end if;
    raise exception 'undo';
  exception when raise_exception then null; end;

  -- 2. admin can change a role and deactivate; deactivated evaluator loses access
  begin
    insert into public.raters(email, rater_code, is_admin) values ('verify-admin@example.org', 'ZZVADM', true),
      ('verify-rater@example.org', 'ZZVRAT', false);
    perform set_config('request.jwt.claims', adm, true); perform set_config('role', 'authenticated', true);
    begin update public.raters set is_admin = true where rater_code = 'ZZVRAT'; get diagnostics cnt = row_count; msg := cnt || ' row(s)';
    exception when others then cnt := 0; msg := sqlerrm; end;
    res := res || array['admin can change a role', case when cnt = 1 then 'PASS' else 'FAIL' end, msg];
    begin update public.raters set active = false where rater_code = 'ZZVRAT'; get diagnostics cnt = row_count; msg := cnt || ' row(s)';
    exception when others then cnt := 0; msg := sqlerrm; end;
    res := res || array['admin can deactivate an evaluator', case when cnt = 1 then 'PASS' else 'FAIL' end, msg];
    perform set_config('request.jwt.claims', rat, true);
    res := res || array['deactivated evaluator loses access',
                        case when public.current_rater_code() is null then 'PASS' else 'FAIL' end, ''];
    raise exception 'undo';
  exception when raise_exception then null; end;

  -- 3. admin cannot demote or deactivate themselves; codes cannot change; evaluators cannot be deleted
  begin
    insert into public.raters(email, rater_code, is_admin) values ('verify-admin@example.org', 'ZZVADM', true),
      ('verify-rater@example.org', 'ZZVRAT', false);
    perform set_config('request.jwt.claims', adm, true); perform set_config('role', 'authenticated', true);
    begin update public.raters set is_admin = false where rater_code = 'ZZVADM'; ok := false;
    exception when others then ok := true; end;
    res := res || array['admin cannot demote themselves', case when ok then 'PASS' else 'FAIL' end, ''];
    begin update public.raters set active = false where rater_code = 'ZZVADM'; ok := false;
    exception when others then ok := true; end;
    res := res || array['admin cannot deactivate themselves', case when ok then 'PASS' else 'FAIL' end, ''];
    begin update public.raters set rater_code = 'ZZVX' where rater_code = 'ZZVRAT'; ok := false;
    exception when others then ok := true; end;
    res := res || array['rater codes cannot be changed', case when ok then 'PASS' else 'FAIL' end, ''];
    begin delete from public.raters where rater_code = 'ZZVRAT'; ok := false;
    exception when others then ok := true; end;
    res := res || array['evaluators cannot be deleted', case when ok then 'PASS' else 'FAIL' end, ''];
    begin insert into public.raters(email, rater_code) values ('not an email', 'ZZVBAD'); ok := false;
    exception when others then ok := true; end;
    res := res || array['invalid email rejected', case when ok then 'PASS' else 'FAIL' end, ''];
    raise exception 'undo';
  exception when raise_exception then null; end;

  -- 4. an ordinary rater cannot add evaluators or promote themselves
  begin
    insert into public.raters(email, rater_code, is_admin) values ('verify-rater@example.org', 'ZZVRAT', false);
    perform set_config('request.jwt.claims', rat, true); perform set_config('role', 'authenticated', true);
    begin insert into public.raters(email, rater_code) values ('verify-new@example.org', 'ZZVNEW'); ok := false;
    exception when others then ok := true; end;
    res := res || array['rater cannot add evaluators', case when ok then 'PASS' else 'FAIL' end, ''];
    begin update public.raters set is_admin = true where rater_code = 'ZZVRAT'; get diagnostics cnt = row_count;
      ok := (cnt = 0);
    exception when others then ok := true; end;
    res := res || array['rater cannot promote themselves', case when ok then 'PASS' else 'FAIL' end, ''];
    raise exception 'undo';
  exception when raise_exception then null; end;

  -- 5. signed-out visitor
  begin
    perform set_config('request.jwt.claims', '{"role":"anon"}', true); perform set_config('role', 'anon', true);
    begin select count(*) into cnt from public.raters; ok := (cnt = 0);
    exception when others then ok := true; end;
    res := res || array['signed-out visitor cannot read evaluators', case when ok then 'PASS' else 'FAIL' end, ''];
    begin perform public.is_admin(); ok := false;
    exception when others then ok := true; end;
    res := res || array['signed-out visitor cannot call is_admin() (migration 003)', case when ok then 'PASS' else 'FAIL' end, ''];
    begin perform public.current_rater_code(); ok := false;
    exception when others then ok := true; end;
    res := res || array['signed-out visitor cannot call current_rater_code() (migration 003)', case when ok then 'PASS' else 'FAIL' end, ''];
    raise exception 'undo';
  exception when raise_exception then null; end;

  perform set_config('role', me, true);
  return query select i, res[3*i-2], res[3*i-1], res[3*i] from generate_series(1, array_length(res, 1) / 3) as i;
end $$;
revoke all on function yoeval_check.verify() from public;

-- The check results, then a summary of your real setup (counts only).
select check_name, result, detail from (
  select n, check_name, result, detail from yoeval_check.verify()
  union all
  select 1000, 'setup: items loaded', case when count(*) > 0 then 'INFO' else 'CHECK' end,
         coalesce(string_agg(package || ': ' || k, ', '), 'none')
  from (select package, count(*) k from public.items group by package) t
  union all
  select 1001, 'setup: evaluators registered', 'INFO',
         count(*) filter (where active) || ' active, ' || count(*) filter (where is_admin and active) || ' admin(s)'
  from public.raters where email not like 'verify-%@example.org'
) report order by n;
