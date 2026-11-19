// Data access. SupabaseStore talks to the real database; MockStore keeps everything in this browser and serves
// synthetic demo items (never real evaluation data) for testing the interface.
import { CONFIG } from "./config.js";
import { REQUIRED } from "./scales.js";

const RATING_FIELDS = ["adequacy_a", "adequacy_b", "fluency_a", "fluency_b", "orthography_a", "orthography_b",
  "preference", "main_error", "comment", "display_problem"];

export function isComplete(r) { return !!r && REQUIRED.every((k) => r[k]); }

function clean(fields) {
  const out = {};
  for (const k of RATING_FIELDS) if (k in fields) out[k] = fields[k] === "" ? null : fields[k];
  return out;
}

// ---------------------------------------------------------------- Supabase
class SupabaseStore {
  async init() {
    const { createClient } = await import("https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm");
    this.db = createClient(CONFIG.supabaseUrl, CONFIG.supabaseAnonKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } });
    this.pendingKey = "yoeval-pending";
  }
  async session() { const { data } = await this.db.auth.getSession(); return data.session; }
  onAuth(cb) { this.db.auth.onAuthStateChange((_e, s) => cb(s)); }
  async signIn(email) {
    const { error } = await this.db.auth.signInWithOtp({ email: email.trim().toLowerCase(),
      options: { emailRedirectTo: location.origin + location.pathname } });
    if (error) throw error;
  }
  async signOut() { await this.db.auth.signOut(); }
  async me() {
    const s = await this.session(); if (!s) return null;
    const { data, error } = await this.db.from("raters").select("rater_code,is_admin")
      .eq("email", s.user.email.toLowerCase()).maybeSingle();
    if (error) throw error;
    return data ? { ...data, email: s.user.email } : { email: s.user.email, rater_code: null };
  }
  async hasConsent(code) {
    const { data, error } = await this.db.from("consents").select("rater_code").eq("rater_code", code).maybeSingle();
    if (error) throw error; return !!data;
  }
  async giveConsent(code) {
    const { error } = await this.db.from("consents").insert({ rater_code: code, guide_version: CONFIG.guideVersion });
    if (error && !String(error.message).includes("duplicate")) throw error;
  }
  async items() {
    const all = []; let from = 0;
    for (;;) {   // paginate (PostgREST returns at most 1000 rows per request)
      const { data, error } = await this.db.from("items").select("*").order("package").order("position")
        .range(from, from + 999);
      if (error) throw error; all.push(...data); if (data.length < 1000) break; from += 1000;
    }
    return all;
  }
  async myRatings(code) {
    const { data, error } = await this.db.from("ratings").select("*").eq("rater_code", code);
    if (error) throw error; return Object.fromEntries(data.map((r) => [r.item_id, r]));
  }
  async save(code, itemId, fields) {
    const row = { rater_code: code, item_id: itemId, ...clean(fields) };
    try {
      const { error } = await this.db.from("ratings").upsert(row, { onConflict: "rater_code,item_id" });
      if (error) throw error;
      this.dropPending(itemId);
    } catch (e) { this.addPending(row); throw e; }
  }
  // ratings that could not be saved are kept in this browser and retried, so nothing is lost offline
  pending() { try { return JSON.parse(localStorage.getItem(this.pendingKey) || "{}"); } catch { return {}; } }
  addPending(row) { try { const p = this.pending(); p[row.item_id] = row; localStorage.setItem(this.pendingKey, JSON.stringify(p)); } catch {} }
  dropPending(id) { try { const p = this.pending(); delete p[id]; localStorage.setItem(this.pendingKey, JSON.stringify(p)); } catch {} }
  async flushPending(code) {
    const p = Object.values(this.pending()).filter((r) => r.rater_code === code);
    for (const r of p) { const { item_id, rater_code, ...f } = r; await this.save(rater_code, item_id, f); }
    return p.length;
  }
  async allRatings() {
    const all = []; let from = 0;
    for (;;) {
      const { data, error } = await this.db.from("ratings").select("*").range(from, from + 999);
      if (error) throw error; all.push(...data); if (data.length < 1000) break; from += 1000;
    }
    return all;
  }
  async allRaters() {
    const { data, error } = await this.db.from("raters").select("rater_code,is_admin,active").order("rater_code");
    if (error) throw error; return data;
  }
}

// ---------------------------------------------------------------- Mock (browser only, synthetic data)
const DEMO_ITEMS = [
  ["DEMO-enyo-1", "English → Yorùbá", "health", "Be careful when choosing a profile photo or image.",
   "Ṣọ́ra bí o bá ń yan àwòrán ìdánimọ̀.", "Sora bi o ba n yan aworan idanimo."],
  ["DEMO-enyo-2", "English → Yorùbá", "family", "The children went to the market with their mother.",
   "Àwọn ọmọ lọ sí ọjà pẹ̀lú ìyá wọn.", "Àwọn ọmọdé lọ sí ọjà pẹ̀lú ìyá wọn ní àná."],
  ["DEMO-yoen-3", "Yorùbá → English", "education", "Ọgbọ́n la fi ń gbé ayé.",
   "One needs wisdom to live in this world.", "We live in the world with knowledge."],
  ["DEMO-enyo-4", "English → Yorùbá", "market", "How much is this basket of tomatoes?",
   "Èló ni apẹ̀rẹ̀ tòmátì yìí?", "Elo ni apere tomati yii?"],
  ["DEMO-yoen-5", "Yorùbá → English", "health", "Mo ti ní kí o yé sọ̀rọ̀ báyìí mọ́.",
   "I told you to stop talking like this.", "I said you should talk like this."],
  ["DEMO-enyo-6", "English → Yorùbá", "news", "The meeting will start at ten o'clock.",
   "Ìpàdé náà yóò bẹ̀rẹ̀ ní agogo mẹ́wàá.", "Ìpàdé náà yóò bẹ̀rẹ̀ ní agogo mẹ́wàá òwúrọ̀ òwúrọ̀ òwúrọ̀."],
].map(([item_id, direction, domain, source, output_a, output_b], i) =>
  ({ item_id, package: "demo", position: i + 1, comparison: "DEMO", direction, domain, source, output_a, output_b }));

class MockStore {
  async init() { this.k = "yoeval-mock"; }
  st() { try { return JSON.parse(localStorage.getItem(this.k) || "{}"); } catch { return {}; } }
  put(s) { try { localStorage.setItem(this.k, JSON.stringify(s)); } catch {} }
  async session() { const s = this.st(); return s.email ? { user: { email: s.email } } : null; }
  onAuth() {}
  async signIn(email) { const s = this.st(); s.email = email.trim().toLowerCase(); this.put(s); }
  async signOut() { const s = this.st(); delete s.email; this.put(s); }
  async me() { const s = this.st(); return s.email ? { email: s.email, rater_code: "DEMO", is_admin: true } : null; }
  async hasConsent() { return !!this.st().consent; }
  async giveConsent() { const s = this.st(); s.consent = new Date().toISOString(); this.put(s); }
  async items() { return DEMO_ITEMS; }
  async myRatings() { return this.st().ratings || {}; }
  async save(code, itemId, fields) {
    const s = this.st(); s.ratings = s.ratings || {};
    s.ratings[itemId] = { ...(s.ratings[itemId] || {}), ...clean(fields), rater_code: code, item_id: itemId,
      updated_at: new Date().toISOString() };
    this.put(s);
  }
  pending() { return {}; }
  async flushPending() { return 0; }
  async allRatings() { return Object.values(this.st().ratings || {}); }
  async allRaters() { return [{ rater_code: "DEMO", is_admin: true, active: true }]; }
}

export async function makeStore() {
  const configured = CONFIG.supabaseUrl && CONFIG.supabaseAnonKey;
  const s = CONFIG.mock || !configured ? new MockStore() : new SupabaseStore();
  s.isMock = s instanceof MockStore;
  s.unconfigured = !configured && !CONFIG.mock;
  await s.init();
  return s;
}
