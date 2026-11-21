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

-- report
select 'meaning_items' as table_name, count(*) as rows from public.meaning_items
union all select 'meaning_ratings', count(*) from public.meaning_ratings;
