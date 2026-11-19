"""Test supabase/schema.sql access rules on a throwaway PostgreSQL server (no Supabase account needed).

Mimics Supabase: roles 'anon' and 'authenticated', auth.jwt() reading request.jwt.claims, and Supabase's default
grants of all table privileges to both roles (so the schema's own revocations are tested too).
Usage:  pip install pgserver psycopg2-binary;  python tests/test_rls.py
(pgserver runs a real PostgreSQL 16 in user space; no Docker or root needed.)
"""
import sys
import tempfile
from pathlib import Path

import pgserver
import psycopg2

HERE = Path(__file__).resolve().parent.parent
SCHEMA = (HERE / "supabase" / "schema.sql").read_text()

STUB = """
create role anon nologin; create role authenticated nologin;
create schema auth;
create function auth.jwt() returns jsonb language sql stable as
  $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
grant usage on schema public, auth to anon, authenticated;
grant execute on function auth.jwt() to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;
"""
SEED = """
insert into public.raters(email, rater_code, is_admin) values
  ('r1@example.org','R01',false), ('r2@example.org','R02',false), ('admin@example.org','ADM',true);
insert into public.raters(email, rater_code, active) values ('gone@example.org','R09',false);
insert into public.items(item_id, package, position, direction, source, output_a, output_b) values
  ('T-1','focus',1,'English → Yorùbá','demo source 1','demo A 1','demo B 1'),
  ('T-2','focus',2,'English → Yorùbá','demo source 2','demo A 2','demo B 2'),
  ('T-3','focus',3,'Yorùbá → English','demo source 3','demo A 3','demo B 3');
insert into public.ratings(rater_code, item_id, preference) values ('R02','T-1','B better');
"""


CONN = None


def psql(sql, role=None, email=None):
    """Run sql (optionally as a Supabase role with JWT claims); return (rc, last value or '', error)."""
    cur = CONN.cursor()
    try:
        if role:
            claims = '{"email":"%s","role":"%s"}' % (email, role) if email else '{"role":"%s"}' % role
            cur.execute(f"set role {role}; select set_config('request.jwt.claims', %s, false);", (claims,))
        cur.execute(sql)
        out = ""
        if cur.description:
            rows = cur.fetchall()
            out = "" if not rows else str(rows[-1][0])
        return 0, out, ""
    except psycopg2.Error as e:
        return 1, "", str(e).strip()
    finally:
        cur.execute("reset role; select set_config('request.jwt.claims', '', false);")
        cur.close()


def main():
    global CONN
    tmp = tempfile.mkdtemp(prefix="yoeval_pg_")
    srv = pgserver.get_server(tmp, cleanup_mode="delete")
    CONN = psycopg2.connect(srv.get_uri())
    CONN.autocommit = True
    try:
        for block in (STUB, SCHEMA, SEED):
            rc, _, err = psql(block)
            assert rc == 0, err
        results = []

        def check(name, ok, detail=""):
            results.append(ok)
            print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   [{detail}]"))

        # signed-out visitor
        for t in ("items", "ratings", "raters", "consents"):
            rc, out, err = psql(f"select count(*) from public.{t};", "anon")
            check(f"anon cannot read {t}", rc != 0 or out == "0", out + err[:80])
        rc, out, err = psql("insert into public.ratings(rater_code,item_id) values ('R01','T-2');", "anon")
        check("anon cannot write ratings", rc != 0, out)
        for fn in ("is_admin", "current_rater_code", "touch_updated_at", "raters_guard"):
            rc, out, err = psql(f"select public.{fn}();", "anon")
            check(f"anon cannot call {fn}()", rc != 0, out + err[:60])
        rc, out, err = psql("select public.raters_guard();", "authenticated", "admin@example.org")
        check("signed-in users cannot call trigger functions directly", rc != 0, out)
        # signed in but not on the allowlist / deactivated
        for em in ("stranger@example.org", "gone@example.org"):
            rc, out, err = psql("select count(*) from public.items;", "authenticated", em)
            check(f"unregistered/inactive {em} sees no items", rc == 0 and out == "0", out + err[:80])
            rc, out, err = psql("insert into public.ratings(rater_code,item_id) values ('R09','T-2');", "authenticated", em)
            check(f"unregistered/inactive {em} cannot save", rc != 0, out)
        # registered rater
        rc, out, _ = psql("select count(*) from public.items;", "authenticated", "R1@Example.org")
        check("rater sees all items (email case-insensitive)", out == "3", out)
        rc, out, err = psql("insert into public.ratings(rater_code,item_id,adequacy_a,preference) values "
                            "('R01','T-1','5 - all meaning preserved','A better');", "authenticated", "r1@example.org")
        check("rater can save own rating", rc == 0, err[:120])
        rc, out, err = psql("update public.ratings set preference='Equal' where rater_code='R01' and item_id='T-1' "
                            "returning preference;", "authenticated", "r1@example.org")
        check("rater can update own rating", rc == 0 and out == "Equal", out + err[:80])
        rc, out, _ = psql("select count(*) from public.ratings;", "authenticated", "r1@example.org")
        check("rater sees only own ratings", out == "1", out)
        rc, out, err = psql("insert into public.ratings(rater_code,item_id) values ('R02','T-2');", "authenticated", "r1@example.org")
        check("rater cannot save as another rater", rc != 0, out)
        rc, out, err = psql("update public.ratings set preference='A better' where rater_code='R02' returning 1;",
                            "authenticated", "r1@example.org")
        check("rater cannot change another rater's rating", out == "", out)
        rc, out, err = psql("update public.ratings set rater_code='R02' where rater_code='R01' returning 1;",
                            "authenticated", "r1@example.org")
        check("rater cannot move own rating to another rater", rc != 0, out)
        rc, out, err = psql("delete from public.ratings where rater_code='R01';", "authenticated", "r1@example.org")
        check("rater cannot delete ratings", rc != 0, out)
        rc, out, err = psql("update public.raters set is_admin=true where rater_code='R01' returning 1;", "authenticated", "r1@example.org")
        check("rater cannot make themselves admin", rc != 0 or out == "", out + err[:80])
        rc, out, err = psql("insert into public.raters(email, rater_code) values ('evil@example.org','R66');", "authenticated", "r1@example.org")
        check("rater cannot add evaluators", rc != 0, out)
        rc, out, err = psql("insert into public.items(item_id,package,position,source,output_a,output_b) values "
                            "('X','focus',9,'s','a','b');", "authenticated", "r1@example.org")
        check("rater cannot add items", rc != 0, out)
        rc, out, err = psql("select count(*) from public.raters;", "authenticated", "r1@example.org")
        check("rater sees only own allowlist row", out == "1", out)
        rc, out, err = psql("insert into public.ratings(rater_code,item_id,preference) values ('R01','T-3','Maybe');",
                            "authenticated", "r1@example.org")
        check("invalid rating value is rejected", rc != 0 and "check" in err.lower(), err[:80])
        rc, out, err = psql("insert into public.consents(rater_code,guide_version) values ('R01','v1');", "authenticated", "r1@example.org")
        check("rater can record own consent", rc == 0, err[:80])
        rc, out, err = psql("insert into public.consents(rater_code,guide_version) values ('R02','v1');", "authenticated", "r1@example.org")
        check("rater cannot record consent for another", rc != 0, out)
        rc, out, _ = psql("select count(*) from public.ratings where rater_code='R01';")
        check("after the attempts, R01's rating still exists", out == "1", out)
        rc, out, _ = psql("select is_admin::text from public.raters where rater_code='R01';")
        check("after the attempts, R01 is still not admin", out == "false", out)
        rc, out, _ = psql("select preference from public.ratings where rater_code='R02' and item_id='T-1';")
        check("after the attempts, R02's rating is unchanged", out == "B better", out)
        # admin
        rc, out, _ = psql("select count(*) from public.ratings;", "authenticated", "admin@example.org")
        check("admin sees all ratings", out == "2", out)
        rc, out, err = psql("insert into public.ratings(rater_code,item_id) values ('R01','T-2');", "authenticated", "admin@example.org")
        check("admin cannot write ratings for a rater", rc != 0, out)
        # admin management of evaluators (migration 002)
        rc, out, err = psql("insert into public.raters(email, rater_code, is_admin) values ('new@example.org','R05',false);",
                            "authenticated", "admin@example.org")
        check("admin can add an evaluator", rc == 0, err[:120])
        rc, out, _ = psql("select count(*) from public.items;", "authenticated", "new@example.org")
        check("new evaluator sees items immediately", out == "3", out)
        rc, out, err = psql("update public.raters set is_admin=true where rater_code='R05' returning is_admin::text;",
                            "authenticated", "admin@example.org")
        check("admin can change a role", rc == 0 and out == "true", out + err[:80])
        rc, out, err = psql("update public.raters set active=false where rater_code='R05' returning active::text;",
                            "authenticated", "admin@example.org")
        check("admin can deactivate an evaluator", rc == 0 and out == "false", out + err[:80])
        rc, out, _ = psql("select count(*) from public.items;", "authenticated", "new@example.org")
        check("deactivated evaluator loses access immediately", out == "0", out)
        rc, out, err = psql("update public.raters set is_admin=false where rater_code='ADM';", "authenticated", "admin@example.org")
        check("admin cannot demote themselves", rc != 0, out)
        rc, out, err = psql("update public.raters set active=false where rater_code='ADM';", "authenticated", "admin@example.org")
        check("admin cannot deactivate themselves", rc != 0, out)
        rc, out, err = psql("update public.raters set rater_code='R99' where rater_code='R02';", "authenticated", "admin@example.org")
        check("rater codes cannot be changed", rc != 0, out)
        rc, out, err = psql("delete from public.raters where rater_code='R02';", "authenticated", "admin@example.org")
        check("evaluators cannot be deleted (deactivate instead)", rc != 0, out)
        rc, out, err = psql("insert into public.raters(email, rater_code) values ('Not An Email','R07');", "authenticated", "admin@example.org")
        check("invalid email rejected", rc != 0, out)
        rc, out, err = psql("insert into public.raters(email, rater_code) values ('Upper@Example.org','R08');", "authenticated", "admin@example.org")
        check("upper-case email rejected (the app lower-cases it)", rc != 0, out)
        rc, out, err = psql("insert into public.raters(email, rater_code) values ('ok@example.org','bad code!');", "authenticated", "admin@example.org")
        check("invalid rater code rejected", rc != 0, out)
        print(f"\n{sum(results)}/{len(results)} access-rule checks passed")
        return 0 if all(results) else 1
    finally:
        CONN.close()
        srv.cleanup()


if __name__ == "__main__":
    sys.exit(main())
