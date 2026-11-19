// Yorùbá–English MT Evaluation: single-page app (no build step).
import { CONFIG } from "./config.js";
import { makeStore, isComplete } from "./store.js";
import { ADEQ, FLU, ORTH, ORTH_NA, PREF, ERR, EXPORT_COLUMNS } from "./scales.js";

const $ = (sel, el = document) => el.querySelector(sel);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const main = () => $("#main");
const state = { store: null, me: null, items: [], ratings: {}, pkg: null, idx: 0, consent: false };

// ---------------------------------------------------------------- boot and routing
async function boot() {
  document.title = CONFIG.title;
  $("#brand").innerHTML = `${esc(CONFIG.title)}<small>${esc(CONFIG.subtitle)}</small>`;
  state.store = await makeStore();
  if (state.store.isMock) $("#mode").innerHTML = `<span class="badge warn">Demo mode: synthetic items, saved only in this browser</span>`;
  state.store.onAuth?.(() => refreshUser().then(route));
  await refreshUser();
  window.addEventListener("hashchange", route);
  document.addEventListener("keydown", onKey);
  route();
  setInterval(retryPending, 15000);
}

async function refreshUser() {
  try {
    state.me = await state.store.me();
    if (state.me?.rater_code) {
      state.consent = await state.store.hasConsent(state.me.rater_code);
      if (state.consent && !state.items.length) await loadData();
    }
  } catch (e) { showError(e); }
  renderSide();
}

async function loadData() {
  state.items = await state.store.items();
  state.ratings = await state.store.myRatings(state.me.rater_code);
  const pkgs = [...new Set(state.items.map((i) => i.package))];
  if (!state.pkg || !pkgs.includes(state.pkg)) state.pkg = pkgs[0] || null;
  await retryPending();
}

function pkgItems() { return state.items.filter((i) => i.package === state.pkg); }

function route() {
  const h = location.hash.replace(/^#\/?/, "") || "home";
  const [page, arg] = h.split("/");
  renderSide(page);
  if (state.store.unconfigured) return renderUnconfigured();
  if (!state.me) return renderSignIn();
  if (!state.me.rater_code) return renderNotRegistered();
  if (!state.consent && page !== "guide") return renderConsent();
  ({ home: renderHome, guide: renderGuide, evaluate: () => renderEvaluate(arg), progress: renderProgress,
     admin: renderAdmin }[page] || renderHome)();
  main().focus?.();
}

function renderSide(active) {
  const links = [["home", "Overview"], ["guide", "Guide"], ["evaluate", "Evaluate"], ["progress", "My progress"]];
  if (state.me?.is_admin) links.push(["admin", "Admin"]);
  const signed = !!state.me;
  $("#menu").innerHTML = signed ? links.map(([k, v]) =>
    `<a href="#/${k}" class="${k === active ? "active" : ""}">${v}</a>`).join("") : "";
  $("#who").innerHTML = signed
    ? `<span>Signed in${state.me.rater_code ? ` as <b>${esc(state.me.rater_code)}</b>` : ""}</span><button id="signout">Sign out</button>`
    : "";
  $("#signout")?.addEventListener("click", async () => { await state.store.signOut(); state.me = null; state.items = []; location.hash = "#/home"; route(); });
  $("#contact").textContent = CONFIG.contact ? `Questions: ${CONFIG.contact}` : "";
}

// ---------------------------------------------------------------- simple pages
function renderUnconfigured() {
  main().innerHTML = `<h1>Not configured yet</h1><p class="lede">This site has no database connection yet. The organiser
  must add the Supabase project URL and anon key to <code>assets/config.js</code>.</p>
  <p><a href="?demo">Open the demo</a> to try the interface with synthetic items.</p>`;
}

function renderSignIn() {
  main().innerHTML = `<h1>${esc(CONFIG.title)}</h1>
  <p class="lede">Thank you for helping evaluate machine translation between English and Yorùbá. Sign in with the
  email address the organisers registered for you.</p>
  <div class="card" style="max-width:28rem"><form id="f"><label class="field" for="email">Email address</label>
  <input id="email" type="email" required autocomplete="email" placeholder="you@example.org">
  <div class="row" style="margin-top:14px"><button class="primary" type="submit">${state.store.isMock ? "Continue (demo)" : "Send me a sign-in link"}</button></div>
  <p class="status" id="st" role="status"></p></form></div>`;
  $("#f").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const st = $("#st"); st.className = "status"; st.textContent = "Sending…";
    try {
      await state.store.signIn($("#email").value);
      if (state.store.isMock) { await refreshUser(); route(); return; }
      st.textContent = "Check your email and open the sign-in link on this device. You can close this tab.";
    } catch (e) { st.className = "status err"; st.textContent = "Could not send the link: " + (e.message || e); }
  });
}

function renderNotRegistered() {
  main().innerHTML = `<h1>Email not registered</h1><p class="lede">You are signed in as <b>${esc(state.me.email)}</b>,
  but this address is not on the list of evaluators. Please contact the organisers${CONFIG.contact ? ` (${esc(CONFIG.contact)})` : ""}
  or sign out and use the address they registered.</p>`;
}

function renderConsent() {
  main().innerHTML = `<h1>Before you start</h1>
  <p class="lede">Please read the <a href="#/guide">guide</a> (about 10 minutes). It explains the task, the rating scales and the rules.</p>
  <div class="card"><h2>Information and consent</h2>
  <ul><li>You will compare machine translations between English and Yorùbá and rate them.</li>
  <li>Your ratings are stored under a code (${esc(state.me.rater_code)}), not your name, and are reported only as anonymous aggregate results in a research paper.</li>
  <li>The sentences come from a research dataset licensed for non-commercial use: please do not copy or share them.</li>
  <li>Do not use machine translation or search for the sentences online, and work on your own.</li>
  <li>You can stop at any time; your ratings are saved as you go.</li></ul>
  <label class="check"><input type="checkbox" id="agree"><span>I have read the guide and agree to take part.</span></label>
  <div class="row" style="margin-top:14px"><button class="primary" id="go" disabled>Start</button></div>
  <p class="status" id="st" role="status"></p></div>`;
  $("#agree").addEventListener("change", (e) => { $("#go").disabled = !e.target.checked; });
  $("#go").addEventListener("click", async () => {
    try { await state.store.giveConsent(state.me.rater_code); state.consent = true; await loadData(); location.hash = "#/evaluate"; route(); }
    catch (e) { $("#st").className = "status err"; $("#st").textContent = "Could not save: " + (e.message || e); }
  });
}

function counts(items = pkgItems()) {
  const done = items.filter((i) => isComplete(state.ratings[i.item_id])).length;
  return { done, total: items.length, pct: items.length ? Math.round(100 * done / items.length) : 0 };
}

function renderHome() {
  const c = counts();
  const pkgs = [...new Set(state.items.map((i) => i.package))];
  main().innerHTML = `<h1>Welcome, ${esc(state.me.rater_code)}</h1>
  <p class="lede">Compare two translations of each sentence and rate them. Your work is saved automatically after every
  change, so you can stop and come back at any time.</p>
  <div class="card"><div class="row" style="justify-content:space-between"><h2 style="margin:0">Your progress</h2>
  <span class="badge ${c.done === c.total && c.total ? "ok" : ""}">${c.done} of ${c.total} items</span></div>
  <div class="progress" style="margin:12px 0" aria-label="progress"><div style="width:${c.pct}%"></div></div>
  ${pkgs.length > 1 ? `<label class="field" for="pkg">Package</label><select id="pkg">${pkgs.map((p) => `<option ${p === state.pkg ? "selected" : ""}>${esc(p)}</option>`).join("")}</select>` : ""}
  <div class="row" style="margin-top:14px"><button class="primary" id="cont">${c.done ? "Continue" : "Start evaluating"}</button>
  <a href="#/guide">Read the guide</a></div></div>
  <div class="grid2"><div class="card soft"><h2>First 20 items: calibration</h2><p class="small">The first 20 items are discussed
  with the team before you continue alone, so that everyone uses the scales in the same way.</p></div>
  <div class="card soft"><h2>Judge against the source</h2><p class="small">There is no reference translation. A translation can be
  correct even if it is worded differently from how you would say it.</p></div></div>`;
  $("#pkg")?.addEventListener("change", (e) => { state.pkg = e.target.value; renderHome(); });
  $("#cont").addEventListener("click", () => { location.hash = `#/evaluate/${firstOpen() + 1}`; });
}

function firstOpen() { const it = pkgItems(); const i = it.findIndex((x) => !isComplete(state.ratings[x.item_id])); return i < 0 ? 0 : i; }

function renderGuide() {
  const rows = (vals) => vals.map((v) => `<li>${esc(v)}</li>`).join("");
  main().innerHTML = `<h1>Guide for evaluators</h1>
  <p class="lede">Each item shows one source sentence and two translations, A and B, produced by two different systems.
  The systems are hidden and their order is random.</p>
  <div class="card"><h2>For each item</h2><ol>
  <li><b>Adequacy A and B</b>: how much of the meaning of the source does the translation keep?<ul>${rows(ADEQ)}</ul></li>
  <li><b>Fluency A and B</b>: how natural is the translation as a sentence of the target language?<ul>${rows(FLU)}</ul></li>
  <li><b>Orthography A and B</b> (Yorùbá output only): <i>Correct</i>; <i>Minor diacritic errors</i> (a few marks wrong, meaning still
  clear); <i>Major diacritic errors</i> (marks missing or wrong enough to change or obscure the meaning). Set automatically to
  <i>Not applicable</i> for English output.</li>
  <li><b>Preference</b>: A better, B better, Equal, or Cannot judge (only if you truly cannot decide).</li>
  <li><b>Main error</b> of the worse translation (or of both, if equal); <i>None</i> if both are fine.</li>
  <li><b>Comment</b> (optional), and tick <b>Display problem</b> if the Yorùbá letters look broken.</li></ol></div>
  <div class="card"><h2>Example</h2><div class="label">Source (English)</div><p class="text-block">Be careful when choosing a profile photo or image.</p>
  <div class="grid2"><div><div class="label">A</div><p class="text-block">Ṣọ́ra bí o bá ń yan àwòrán ìdánimọ̀.</p></div>
  <div><div class="label">B</div><p class="text-block">Sora bi o ba n yan aworan idanimo.</p></div></div>
  <p class="small">Adequacy A 5, B 4 · Fluency A 5, B 4 · Orthography A <i>Correct</i>, B <i>Major diacritic errors</i> ·
  Preference <i>A better</i> · Main error <i>Diacritics / orthography</i>. (A is a MENYO-20k training sentence, CC BY-NC 4.0;
  B is the same text with its diacritics removed.)</p></div>
  <div class="card"><h2>Error types</h2><ul>${ERR.slice(1).map((e) => `<li>${esc(e)}</li>`).join("")}</ul></div>
  <div class="card"><h2>Rules</h2><ul><li>Work alone; do not discuss items with other evaluators until everyone has finished.</li>
  <li>Do not use machine translation or search for the sentences online.</li>
  <li>Keep the sentences confidential (non-commercial research data).</li>
  <li>Take breaks: ratings made while tired are less reliable.</li></ul>
  <p class="small muted">Keyboard: <b>Alt+→</b> next item, <b>Alt+←</b> previous item.</p></div>`;
}

// ---------------------------------------------------------------- evaluation screen
function choiceGroup(field, values, current, disabled = false) {
  return `<div class="choices" role="group" data-field="${field}">${values.map((v) =>
    `<button type="button" data-v="${esc(v)}" aria-pressed="${v === current}" ${disabled ? "disabled" : ""}>${esc(v)}</button>`).join("")}</div>`;
}

function renderEvaluate(arg) {
  const items = pkgItems();
  if (!items.length) { main().innerHTML = `<h1>No items</h1><p class="lede">No items have been loaded yet.</p>`; return; }
  state.idx = Math.min(Math.max((parseInt(arg, 10) || firstOpen() + 1) - 1, 0), items.length - 1);
  const it = items[state.idx];
  const toEnglish = /→\s*English/.test(it.direction || "");
  const r = { ...(state.ratings[it.item_id] || {}) };
  if (toEnglish) { r.orthography_a = r.orthography_a || ORTH_NA; r.orthography_b = r.orthography_b || ORTH_NA; }
  const c = counts(items);
  const srcLang = toEnglish ? "Yorùbá" : "English", tgtLang = toEnglish ? "English" : "Yorùbá";
  const out = (side, text) => `<div class="card"><div class="label">Translation ${side} (${tgtLang})</div>
    <p class="text-block" lang="${toEnglish ? "en" : "yo"}">${esc(text)}</p>
    <label class="field">Adequacy ${side} <span class="hint">how much meaning is kept</span></label>${choiceGroup(`adequacy_${side.toLowerCase()}`, ADEQ, r[`adequacy_${side.toLowerCase()}`])}
    <label class="field">Fluency ${side} <span class="hint">how natural it reads</span></label>${choiceGroup(`fluency_${side.toLowerCase()}`, FLU, r[`fluency_${side.toLowerCase()}`])}
    <label class="field">Orthography ${side}</label>${choiceGroup(`orthography_${side.toLowerCase()}`, toEnglish ? [ORTH_NA] : ORTH.slice(0, 3), r[`orthography_${side.toLowerCase()}`], toEnglish)}</div>`;
  main().innerHTML = `<div class="row" style="justify-content:space-between">
    <h1 style="margin:0">Item ${state.idx + 1} of ${items.length}</h1>
    <span>${state.idx < 20 ? `<span class="badge warn">Calibration</span> ` : ""}<span class="badge">${esc(it.direction)}</span> <span class="badge">${esc(it.domain || "")}</span></span></div>
    <div class="progress" style="margin:12px 0 20px" aria-label="${c.done} of ${c.total} complete"><div style="width:${c.pct}%"></div></div>
    <div class="card soft"><div class="label">Source (${srcLang})</div><p class="text-block" lang="${toEnglish ? "yo" : "en"}">${esc(it.source)}</p></div>
    <div class="grid2">${out("A", it.output_a)}${out("B", it.output_b)}</div>
    <div class="card"><label class="field" style="margin-top:0">Which translation is better?</label>${choiceGroup("preference", PREF, r.preference)}
    <label class="field" for="err">Main error of the worse translation</label>
    <select id="err"><option value="">Choose…</option>${ERR.map((e) => `<option ${e === r.main_error ? "selected" : ""}>${esc(e)}</option>`).join("")}</select>
    <label class="field" for="cmt">Comment <span class="hint">optional</span></label>
    <textarea id="cmt" maxlength="2000">${esc(r.comment || "")}</textarea>
    <label class="check small"><input type="checkbox" id="disp" ${r.display_problem ? "checked" : ""}><span>Display problem: the text looks broken or unreadable</span></label></div>
    <div class="sticky-nav row" style="justify-content:space-between">
    <div class="row"><button id="prev" ${state.idx === 0 ? "disabled" : ""}>← Previous</button>
    <button class="primary" id="next">${state.idx === items.length - 1 ? "Finish" : "Next →"}</button>
    <button id="open">Next unrated</button></div>
    <span class="status" id="st" role="status">${isComplete(state.ratings[it.item_id]) ? "Complete · saved" : "Not complete yet"}</span></div>`;

  const save = debounce(async (fields) => {
    const st = $("#st"); if (!st) return;
    st.className = "status"; st.textContent = "Saving…";
    state.ratings[it.item_id] = { ...(state.ratings[it.item_id] || {}), ...fields, item_id: it.item_id };
    try {
      await state.store.save(state.me.rater_code, it.item_id, state.ratings[it.item_id]);
      st.textContent = (isComplete(state.ratings[it.item_id]) ? "Complete · saved " : "Saved ") + new Date().toLocaleTimeString();
    } catch (e) { st.className = "status err"; st.textContent = "Not saved yet (kept in this browser, will retry): " + (e.message || e); }
  }, 350);
  if (toEnglish && !(state.ratings[it.item_id]?.orthography_a)) save({ orthography_a: ORTH_NA, orthography_b: ORTH_NA });
  main().querySelectorAll(".choices").forEach((g) => g.addEventListener("click", (e) => {
    const b = e.target.closest("button"); if (!b || b.disabled) return;
    g.querySelectorAll("button").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    save({ [g.dataset.field]: b.dataset.v });
  }));
  $("#err").addEventListener("change", (e) => save({ main_error: e.target.value }));
  $("#cmt").addEventListener("input", (e) => save({ comment: e.target.value }));
  $("#disp").addEventListener("change", (e) => save({ display_problem: e.target.checked }));
  $("#prev").addEventListener("click", () => go(state.idx));
  $("#next").addEventListener("click", () => state.idx === items.length - 1 ? (location.hash = "#/progress") : go(state.idx + 2));
  $("#open").addEventListener("click", () => go(firstOpen() + 1));
}

function go(n) { location.hash = `#/evaluate/${n}`; }
function onKey(e) {
  if (!location.hash.startsWith("#/evaluate") || !e.altKey) return;
  if (e.key === "ArrowRight") { e.preventDefault(); $("#next")?.click(); }
  if (e.key === "ArrowLeft") { e.preventDefault(); $("#prev")?.click(); }
}
function debounce(fn, ms) {
  let t, acc = {};
  return (fields) => { acc = { ...acc, ...fields }; clearTimeout(t); t = setTimeout(() => { const a = acc; acc = {}; fn(a); }, ms); };
}
async function retryPending() {
  if (!state.me?.rater_code || state.store.isMock) return;
  try { await state.store.flushPending(state.me.rater_code); } catch { /* still offline; try again later */ }
}

// ---------------------------------------------------------------- progress and admin
function renderProgress() {
  const items = pkgItems(), c = counts(items);
  main().innerHTML = `<h1>My progress</h1><p class="lede">${c.done} of ${c.total} items complete. Click a number to open that item.
  Green: complete; orange: started but incomplete.</p>
  <div class="card"><div class="cells">${items.map((it, i) => {
    const r = state.ratings[it.item_id];
    return `<a href="#/evaluate/${i + 1}" class="${isComplete(r) ? "done" : r ? "partial" : ""}" title="${esc(it.item_id)}">${i + 1}</a>`; }).join("")}</div></div>
  ${c.done === c.total && c.total ? `<div class="card soft"><h2>All done, thank you!</h2><p>Your ratings are saved. You can still
  revise any item. Please let the organisers know that you have finished.</p></div>` : ""}`;
}

async function renderAdmin() {
  if (!state.me.is_admin) return renderHome();
  main().innerHTML = `<h1>Admin</h1><p class="lede">Progress of all evaluators and exports for the analysis script.</p><div id="adm">Loading…</div>`;
  try {
    const [ratings, raters] = await Promise.all([state.store.allRatings(), state.store.allRaters()]);
    const byRater = {}; for (const r of ratings) (byRater[r.rater_code] ||= []).push(r);
    const pkgs = [...new Set(state.items.map((i) => i.package))];
    const rows = raters.filter((x) => !x.is_admin || byRater[x.rater_code]).map((x) => {
      const rs = byRater[x.rater_code] || [];
      const per = pkgs.map((p) => { const ids = new Set(state.items.filter((i) => i.package === p).map((i) => i.item_id));
        return `${p}: ${rs.filter((r) => ids.has(r.item_id) && isComplete(r)).length}/${ids.size}`; }).join("<br>");
      const last = rs.map((r) => r.updated_at).sort().pop();
      const flags = rs.filter((r) => r.display_problem).length;
      return `<tr><td><b>${esc(x.rater_code)}</b>${x.active ? "" : " (inactive)"}</td><td>${per}</td>
        <td>${last ? new Date(last).toLocaleString() : "—"}</td><td>${flags || ""}</td>
        <td>${pkgs.map((p) => `<button data-r="${esc(x.rater_code)}" data-p="${esc(p)}">TSV ${esc(p)}</button>`).join(" ")}</td></tr>`;
    }).join("");
    const flagged = ratings.filter((r) => r.display_problem || (r.comment && r.comment.trim()));
    $("#adm").innerHTML = `<div class="card"><table class="data"><thead><tr><th>Rater</th><th>Complete</th><th>Last activity</th>
      <th>Display problems</th><th>Export</th></tr></thead><tbody>${rows || `<tr><td colspan="5">No evaluators yet.</td></tr>`}</tbody></table>
      <p class="small muted">Each TSV matches the workbook columns. Save them in <code>reports/human_eval/filled_focus/</code> (or <code>filled/</code>)
      and run <code>analyze_human_eval.py --key …_KEY.xlsx …/*_evaluation.tsv</code>.</p></div>
      <div class="card"><h2>Comments and display problems (${flagged.length})</h2><table class="data"><thead><tr><th>Rater</th><th>Item</th>
      <th>Display</th><th>Comment</th></tr></thead><tbody>${flagged.map((r) => `<tr><td>${esc(r.rater_code)}</td><td>${esc(r.item_id)}</td>
      <td>${r.display_problem ? "yes" : ""}</td><td>${esc(r.comment || "")}</td></tr>`).join("")}</tbody></table></div>`;
    $("#adm").querySelectorAll("button[data-r]").forEach((b) => b.addEventListener("click", () =>
      downloadTsv(b.dataset.r, b.dataset.p, byRater[b.dataset.r] || [])));
  } catch (e) { $("#adm").innerHTML = `<p class="status err">Could not load: ${esc(e.message || e)}</p>`; }
}

function downloadTsv(code, pkg, ratings) {
  const byItem = Object.fromEntries(ratings.map((r) => [r.item_id, r]));
  const clean = (v) => String(v ?? "").replace(/[\t\r\n]+/g, " ");
  const lines = [EXPORT_COLUMNS.map(([h]) => h).join("\t")];
  for (const it of state.items.filter((i) => i.package === pkg)) {
    const row = { ...it, ...(byItem[it.item_id] || {}) };
    lines.push(EXPORT_COLUMNS.map(([, k]) => clean(row[k])).join("\t"));
  }
  const blob = new Blob(["﻿" + lines.join("\n") + "\n"], { type: "text/tab-separated-values;charset=utf-8" });
  const a = Object.assign(document.createElement("a"), { href: URL.createObjectURL(blob), download: `${code}_${pkg}_evaluation.tsv` });
  document.body.appendChild(a); a.click(); a.remove();
}

function showError(e) { console.error(e); const m = main(); if (m) m.innerHTML = `<p class="status err">Something went wrong: ${esc(e.message || e)}</p>`; }

boot().catch(showError);
