-- Diagnose what is installed on this database (read-only, plus one self-undoing behaviour test).
-- Run in Supabase > SQL Editor and share the whole result table.

create temp table if not exists yoeval_diag (n serial, item text, value text);
truncate yoeval_diag;

insert into yoeval_diag(item, value)
select 'function present: ' || p.oid::regprocedure::text,
       'security definer: ' || p.prosecdef || ', anon can call: ' || has_function_privilege('anon', p.oid, 'execute')
from pg_proc p where p.pronamespace = 'public'::regnamespace
  and p.proname in ('current_rater_code', 'is_admin', 'touch_updated_at', 'raters_guard');

insert into yoeval_diag(item, value)
select 'trigger on ' || c.relname || ': ' || t.tgname, 'runs ' || t.tgfoid::regprocedure::text
from pg_trigger t join pg_class c on c.oid = t.tgrelid
where c.relnamespace = 'public'::regnamespace and not t.tgisinternal;

insert into yoeval_diag(item, value)
select 'policy on ' || tablename || ': ' || policyname, cmd from pg_policies where schemaname = 'public';

insert into yoeval_diag(item, value)
select 'constraint: ' || conname, pg_get_constraintdef(oid) from pg_constraint
where conrelid = 'public.raters'::regclass and contype = 'c';

insert into yoeval_diag(item, value)
select 'grant to authenticated on raters', string_agg(privilege_type || coalesce(' (' || column_name || ')', ''), ', ')
from (select privilege_type, null::text column_name from information_schema.role_table_grants
      where table_schema = 'public' and table_name = 'raters' and grantee = 'authenticated'
      union all
      select privilege_type, column_name from information_schema.role_column_grants
      where table_schema = 'public' and table_name = 'raters' and grantee = 'authenticated'
        and privilege_type = 'UPDATE') g;

-- behaviour test: can an admin remove their own admin role? (changes are rolled back)
do $$
declare cnt integer; outcome text;
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
    perform set_config('role', current_user, true);
    raise exception 'undo';
  exception when raise_exception then null;
  end;
  insert into yoeval_diag(item, value) values ('behaviour: admin demotes self', outcome);
end $$;

insert into yoeval_diag(item, value)
select 'data: items', count(*)::text from public.items
union all select 'data: evaluators (active / admins)',
  count(*) filter (where active) || ' / ' || count(*) filter (where active and is_admin)
  from public.raters where email not like 'diag-%@example.org';

select item, value from yoeval_diag order by n;
