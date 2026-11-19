// Site configuration. The Supabase URL and anon key are public by design: what a signed-in user may read or
// write is enforced by the database's row-level security (supabase/schema.sql), not by keeping these secret.
// NEVER put the service_role key here.
export const CONFIG = {
  supabaseUrl: "https://lhvicztwqfgaagddxrce.supabase.co",
  supabaseAnonKey: "sb_publishable_4H6NoWMYqEJCf8RZ7uWpUg_dm0rH1Yr",   // publishable (public) key; never the secret key
  guideVersion: "2026-11-19",
  title: "Yorùbá–English MT Evaluation",
  subtitle: "Human evaluation of machine translation",
  contact: "",              // shown to raters, e.g. "Organiser name, email"
  // Mock mode stores everything in this browser and shows synthetic demo items: for testing only.
  mock: new URLSearchParams(location.search).has("demo"),
};
