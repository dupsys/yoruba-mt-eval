-- Migration 002: let admins add evaluators and change their role / access from the dashboard's Admin page.
-- Run once in the Supabase SQL editor (safe to re-run). Already included in supabase/schema.sql for new projects.
--
--   * Admins may INSERT new evaluators and UPDATE is_admin / active; nobody else can change public.raters.
--   * No one can delete evaluators (deactivate instead), so ratings are never orphaned.
--   * An admin cannot demote or deactivate themselves, so at least one admin always remains.
--   * Emails are stored in lower case and must look like an email; rater codes are short letters/digits.

-- Existing rows must satisfy the new checks: normalise emails (sign-in already ignores case and spaces), then stop
-- with a clear message if any email or code is still invalid, instead of failing on the constraint below.
update public.raters set email = lower(btrim(email)) where email <> lower(btrim(email));
do $$
declare bad text;
begin
  select string_agg(format('%s (code %s)', email, rater_code), '; ') into bad from public.raters
  where email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or rater_code !~ '^[A-Za-z0-9_-]{1,20}$';
  if bad is not null then
    raise exception 'Fix these evaluators first (invalid email or rater code), then run this migration again: %', bad;
  end if;
end $$;

alter table public.raters drop constraint if exists raters_email_format;
alter table public.raters add constraint raters_email_format
  check (email = lower(email) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$');
alter table public.raters drop constraint if exists raters_code_format;
alter table public.raters add constraint raters_code_format check (rater_code ~ '^[A-Za-z0-9_-]{1,20}$');

create or replace function public.raters_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare me text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if tg_op = 'UPDATE' then
    if new.email <> old.email or new.rater_code <> old.rater_code then
      raise exception 'email and rater code cannot be changed; deactivate and add a new evaluator instead';
    end if;
    if old.email = me and (not new.is_admin or not new.active) then
      raise exception 'you cannot remove your own admin role or access';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists raters_guard on public.raters;
create trigger raters_guard before update on public.raters
  for each row execute function public.raters_guard();

grant insert, update (is_admin, active) on public.raters to authenticated;

drop policy if exists raters_admin_insert on public.raters;
create policy raters_admin_insert on public.raters for insert to authenticated
  with check (public.is_admin());

drop policy if exists raters_admin_update on public.raters;
create policy raters_admin_update on public.raters for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
