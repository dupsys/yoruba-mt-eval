-- Yorùbá–English MT human evaluation: database schema and access rules (Supabase / PostgreSQL).
-- Run once in the Supabase SQL editor (Project > SQL Editor > New query > paste > Run).
--
-- Access model
--   * Only emails listed in public.raters (an allowlist kept by the organiser) can read items or save ratings.
--   * Each rater can read and write only their own ratings and consent; admins (is_admin) can read everything.
--   * Signed-out visitors (the public "anon" key) can read nothing.
--   * The answer key (which system is A or B) is never stored here.

-- ---------------------------------------------------------------- tables
create table if not exists public.raters (
  email       text primary key,                       -- lower-case sign-in email
  rater_code  text unique not null,                   -- e.g. R01; used in exports instead of names
  is_admin    boolean not null default false,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.items (
  item_id     text primary key,                       -- matches the workbook / answer key
  package     text not null,                          -- 'focus' or 'full'
  position    integer not null,                       -- display order within the package (1 = first)
  comparison  text,
  direction   text,                                   -- 'English → Yorùbá' or 'Yorùbá → English'
  domain      text,
  source      text not null,
  output_a    text not null,
  output_b    text not null,
  unique (package, position)
);

create table if not exists public.ratings (
  rater_code      text not null references public.raters (rater_code) on update cascade,
  item_id         text not null references public.items (item_id),
  adequacy_a      text check (adequacy_a in ('5 - all meaning preserved','4 - most meaning','3 - much meaning','2 - little meaning','1 - none')),
  adequacy_b      text check (adequacy_b in ('5 - all meaning preserved','4 - most meaning','3 - much meaning','2 - little meaning','1 - none')),
  fluency_a       text check (fluency_a in ('5 - flawless','4 - good','3 - non-native','2 - disfluent','1 - incomprehensible')),
  fluency_b       text check (fluency_b in ('5 - flawless','4 - good','3 - non-native','2 - disfluent','1 - incomprehensible')),
  orthography_a   text check (orthography_a in ('Correct','Minor diacritic errors','Major diacritic errors','Not applicable (English output)')),
  orthography_b   text check (orthography_b in ('Correct','Minor diacritic errors','Major diacritic errors','Not applicable (English output)')),
  preference      text check (preference in ('A better','B better','Equal','Cannot judge')),
  main_error      text check (main_error in ('None','Mistranslation','Omission','Addition / hallucination',
                    'Untranslated / wrong language','Name or number','Terminology','Idiom or proverb meaning',
                    'Register / honorific','Diacritics / orthography','Grammar / fluency','Repetition / malformed')),
  comment         text check (char_length(comment) <= 2000),
  display_problem boolean not null default false,
  updated_at      timestamptz not null default now(),
  primary key (rater_code, item_id)
);

create table if not exists public.consents (
  rater_code     text primary key references public.raters (rater_code) on update cascade,
  guide_version  text not null,
  consented_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------- helpers (security definer: read the allowlist)
create or replace function public.current_rater_code() returns text
language sql stable security definer set search_path = public as $$
  select rater_code from public.raters
  where email = lower(coalesce(auth.jwt() ->> 'email', '')) and active
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.raters
                   where email = lower(coalesce(auth.jwt() ->> 'email', '')) and active), false)
$$;

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

drop trigger if exists ratings_touch on public.ratings;
create trigger ratings_touch before update on public.ratings
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------- privileges and row-level security
revoke all on public.raters, public.items, public.ratings, public.consents from anon, authenticated;  -- then grant only what is needed
grant select on public.raters, public.items to authenticated;
grant select, insert, update on public.ratings to authenticated;
grant select, insert on public.consents to authenticated;
revoke execute on function public.current_rater_code(), public.is_admin() from anon;
grant execute on function public.current_rater_code(), public.is_admin() to authenticated;

alter table public.raters   enable row level security;
alter table public.items    enable row level security;
alter table public.ratings  enable row level security;
alter table public.consents enable row level security;

drop policy if exists raters_read on public.raters;
create policy raters_read on public.raters for select to authenticated
  using (email = lower(coalesce(auth.jwt() ->> 'email', '')) or public.is_admin());

drop policy if exists items_read on public.items;
create policy items_read on public.items for select to authenticated
  using (public.current_rater_code() is not null);

drop policy if exists ratings_read on public.ratings;
create policy ratings_read on public.ratings for select to authenticated
  using (rater_code = public.current_rater_code() or public.is_admin());

drop policy if exists ratings_insert on public.ratings;
create policy ratings_insert on public.ratings for insert to authenticated
  with check (rater_code = public.current_rater_code());

drop policy if exists ratings_update on public.ratings;
create policy ratings_update on public.ratings for update to authenticated
  using (rater_code = public.current_rater_code())
  with check (rater_code = public.current_rater_code());

drop policy if exists consents_read on public.consents;
create policy consents_read on public.consents for select to authenticated
  using (rater_code = public.current_rater_code() or public.is_admin());

drop policy if exists consents_insert on public.consents;
create policy consents_insert on public.consents for insert to authenticated
  with check (rater_code = public.current_rater_code());

-- ---------------------------------------------------------------- admin management of evaluators (migration 002)
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

-- ---------------------------------------------------------------- lock helper functions (migration 003)
revoke execute on function public.current_rater_code() from public, anon;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.current_rater_code() to authenticated;
grant execute on function public.is_admin() to authenticated;

-- Trigger functions are not meant to be called directly by anyone.
revoke execute on function public.touch_updated_at() from public, anon, authenticated;
revoke execute on function public.raters_guard() from public, anon, authenticated;

-- ---------------------------------------------------------------- migration 004 (Task 2: proverb meanings)
-- 004: Task 2, "proverb meanings" (2026-11-21). Raters judge whether a model's explanation of a Yorùbá proverb
-- conveys its meaning. Items show the proverb, its literal translation, the stated meaning and ONE explanation;
-- which model and condition produced it is NOT stored here (the answer key stays offline).
-- Safe to run more than once. Run after schema.sql, 002 and 003.

create table if not exists public.meaning_items (
  item_id         text primary key,                  -- e.g. M001; random order, model/condition hidden
  position        integer not null unique,           -- display order (1 = first)
  proverb         text not null,
  literal         text not null,                     -- the collection's literal English translation
  stated_meaning  text not null,                     -- the collection's stated meaning ("wisdom")
  explanation     text not null                      -- the model's explanation being judged
);

create table if not exists public.meaning_ratings (
  rater_code   text not null references public.raters (rater_code) on update cascade,
  item_id      text not null references public.meaning_items (item_id),
  judgement    text check (judgement in ('Correct', 'Different but valid', 'Partly correct', 'Literal only',
                                         'Wrong', 'Cannot judge')),
  comment      text check (char_length(comment) <= 2000),
  updated_at   timestamptz not null default now(),
  primary key (rater_code, item_id)
);

drop trigger if exists meaning_ratings_touch on public.meaning_ratings;
create trigger meaning_ratings_touch before update on public.meaning_ratings
  for each row execute function public.touch_updated_at();

revoke all on public.meaning_items, public.meaning_ratings from anon, authenticated;
grant select on public.meaning_items to authenticated;
grant select, insert, update on public.meaning_ratings to authenticated;

alter table public.meaning_items   enable row level security;
alter table public.meaning_ratings enable row level security;

drop policy if exists meaning_items_read on public.meaning_items;
create policy meaning_items_read on public.meaning_items for select to authenticated
  using (public.current_rater_code() is not null);

drop policy if exists meaning_ratings_read on public.meaning_ratings;
create policy meaning_ratings_read on public.meaning_ratings for select to authenticated
  using (rater_code = public.current_rater_code() or public.is_admin());

drop policy if exists meaning_ratings_insert on public.meaning_ratings;
create policy meaning_ratings_insert on public.meaning_ratings for insert to authenticated
  with check (rater_code = public.current_rater_code());

drop policy if exists meaning_ratings_update on public.meaning_ratings;
create policy meaning_ratings_update on public.meaning_ratings for update to authenticated
  using (rater_code = public.current_rater_code())
  with check (rater_code = public.current_rater_code());

