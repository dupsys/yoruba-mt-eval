# Yorùbá–English MT Evaluation dashboard

A small web app for the human evaluation of machine translation between English and Yorùbá. Evaluators sign in
with an emailed link, read the guide, give consent, and rate pairs of translations; their ratings are saved
automatically. Organisers see progress and export each evaluator's ratings as a TSV file that
`reports/human_eval/analyze_human_eval.py` reads unchanged.

* **Frontend:** static HTML, CSS and JavaScript (no build step), hosted on GitHub Pages.
* **Backend:** [Supabase](https://supabase.com) (PostgreSQL with sign-in). Access is enforced by the database:
  only registered evaluators can read items, each evaluator reads and writes only their own ratings, and signed-out
  visitors can read nothing (`supabase/schema.sql`, tested by `tests/test_rls.py`).
* **Privacy and blinding:** the evaluation sentences are stored only in the database, never in this repository;
  the answer key (which system is A or B) is never uploaded anywhere. Ratings are stored under evaluator codes.

Try the interface without any setup: open `index.html?demo` (synthetic items, stored only in your browser).

## Setup (organiser, about 30 minutes)

1. **Create a Supabase project** (free tier) at https://supabase.com.
2. **Create the tables and access rules:** *SQL Editor → New query*, paste `supabase/schema.sql`, *Run*.
3. **Load the items:** run `python eval_dashboard/tools/make_items_sql.py` in the research project (add `--full`
   for the 300-item workbook). It writes `eval_dashboard/private/items_focus.sql` (git-ignored, because it contains
   the test sentences); paste it into the SQL editor and run it.
4. **Register yourself as admin:** edit `private/raters_template.sql` with your email and `is_admin = true` and run
   it. After that, add and manage evaluators from the dashboard's *Admin → Evaluators* section (email, rater code,
   role); they can sign in immediately. Only registered, active emails can see items.
   *Projects created before 2026-11-19* must also run the files in `supabase/migrations/` once, in order (002
   enables that section; 003 stops signed-out calls to the helper functions); new projects get both from
   `schema.sql`. `supabase/verify_admin.sql` checks the live rules and undoes its own test changes.
5. **Configure sign-in:** *Authentication → URL Configuration*: set *Site URL* and add a *Redirect URL* equal to the
   site address (e.g. `https://dupsys.github.io/yoruba-mt-eval/`). Supabase's built-in email sender has a low hourly
   limit, which is fine for a few evaluators; for more, add your own SMTP server under *Authentication → Emails*.
6. **Connect the site:** put the *Project URL* and the *anon public* key (*Project Settings → API*) in
   `assets/config.js`, and fill in `contact`. The anon key is meant to be public; **never** use the `service_role`
   key in this site.
7. **Publish** the repository with GitHub Pages (*Settings → Pages → Deploy from branch → main / root*).

## Running the evaluation

* Send each evaluator the site address and `RATER_GUIDE.md`. They sign in with their registered email.
* The first 20 items are marked *Calibration*: discuss them together before evaluators continue alone.
* The *Admin* page (admins only) shows progress per evaluator, comments and display problems, and exports
  `<code>_<package>_evaluation.tsv` files. Save them in `reports/human_eval/filled_focus/` and run
  `analyze_human_eval.py --key reports/human_eval/menyo_focus_afrique_vs_nllb13_KEY.xlsx reports/human_eval/filled_focus/*_evaluation.tsv`.
* To end someone's access, use *Deactivate* in *Admin → Evaluators* (ratings are kept).
* After the study, export a final backup (Supabase *Table Editor → ratings → Export to CSV*) and consider deleting
  the items and evaluator emails.

## Tests

```bash
pip install pgserver psycopg2-binary pandas openpyxl "playwright==1.56.0" && playwright install chromium
python tests/test_rls.py     # 46 access-rule checks on a throwaway PostgreSQL
python tests/test_ui.py      # 30 end-to-end interface checks in demo mode
```

## Notes

* The guide's worked example and some demo items use MENYO-20k training sentences (CC BY-NC 4.0, Adelani et al.,
  2021); other demo items are synthetic and were not checked by a fluent speaker.
* Fonts: Exo 2 (interface) and Noto Sans (evaluation text, chosen for its support of Yorùbá combining diacritics),
  loaded from Google Fonts.
* `noindex` is set so search engines do not list the site.
