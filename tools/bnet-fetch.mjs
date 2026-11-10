// Pulls the character's Battle.net Profile API data into docs/sync/bnet.json for the Pages site.
// Run by .github/workflows/bnet-sync.yml; the client secret lives only in GitHub Actions secrets,
// never in the published page. Inputs (env): BNET_CLIENT_ID, BNET_CLIENT_SECRET, BNET_REALM (slug),
// BNET_CHARACTER, BNET_REGION (default "us"). Output: docs/sync/bnet.json, rewritten only when data changes.
//
// Forever's namespace (profile-forever-{region}) is not in Blizzard's official docs yet; it comes from
// a community report, which also saw 404s on the character route. So every endpoint is probed and its
// HTTP status recorded instead of failing the run, so we can see what actually works.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";

const env = (k, d) => (process.env[k] ?? "").trim() || d;
const id = env("BNET_CLIENT_ID"), secret = env("BNET_CLIENT_SECRET");
const region = env("BNET_REGION", "us").toLowerCase();
const realm = env("BNET_REALM", "").toLowerCase();
const name = env("BNET_CHARACTER", "").toLowerCase(); // API requires lowercase names
if (!id || !secret || !realm || !name) {
  console.error("Missing secret(s): need BNET_CLIENT_ID, BNET_CLIENT_SECRET, BNET_REALM, BNET_CHARACTER.");
  process.exit(1);
}
const ns = env("BNET_NAMESPACE", `profile-forever-${region}`);
const api = `https://${region}.api.blizzard.com`;
const OUT = "docs/sync/bnet.json";

// Client-credentials token: enough for public character endpoints (no user login needed).
const tok = await fetch("https://oauth.battle.net/token", {
  method: "POST",
  headers: { Authorization: "Basic " + Buffer.from(`${id}:${secret}`).toString("base64") },
  body: new URLSearchParams({ grant_type: "client_credentials" }),
});
if (!tok.ok) { console.error(`Token request failed: HTTP ${tok.status}. Check the client ID/secret.`); process.exit(1); }
const { access_token } = await tok.json();

async function get(path, namespace = ns) {
  const r = await fetch(`${api}${path}?locale=en_US`, {
    headers: { Authorization: `Bearer ${access_token}`, "Battlenet-Namespace": namespace },
  });
  return { status: r.status, data: r.ok ? await r.json() : null };
}

// Repo is public: drop anything that names the character, realm or guild, plus self-links (they embed both).
const SCRUB = new Set(["_links", "character", "name", "realm", "guild", "id"]);
const scrub = (o) => o && Object.fromEntries(Object.entries(o).filter(([k]) => !SCRUB.has(k)));

const base = `/profile/wow/character/${encodeURIComponent(realm)}/${encodeURIComponent(name)}`;
const endpoints = {
  summary: "", equipment: "/equipment", statistics: "/statistics",
  specializations: "/specializations", professions: "/professions",
  // character-media left out: its render URLs embed realm + character IDs, which identify you.
};
const results = {};
for (const [key, suffix] of Object.entries(endpoints)) {
  const { status, data } = await get(base + suffix);
  results[key] = { status, data: scrub(data) };
  console.log(`${key.padEnd(16)} HTTP ${status}`);
}

// Diagnostic only (not published): a 404 on summary is often a wrong realm slug, so list the valid ones.
if (results.summary.status === 404) {
  const realms = await get("/data/wow/realm/index", ns.replace(/^profile-/, "dynamic-"));
  const slugs = realms.data?.realms?.map((r) => r.slug).join(", ");
  console.log(`Realm index (${ns.replace(/^profile-/, "dynamic-")}) HTTP ${realms.status}${slugs ? ": " + slugs : ""}`);
}

const payload = { region, namespace: ns, endpoints: results };
// Skip the write when only the timestamp would change, so the hourly cron doesn't spam commits.
if (existsSync(OUT)) {
  try {
    const { fetched, ...prev } = JSON.parse(readFileSync(OUT, "utf8"));
    if (JSON.stringify(prev) === JSON.stringify(payload)) { console.log("No changes."); process.exit(0); }
  } catch { /* unreadable old file: overwrite */ }
}
mkdirSync("docs/sync", { recursive: true });
writeFileSync(OUT, JSON.stringify({ fetched: new Date().toISOString(), ...payload }, null, 1) + "\n");
console.log(`Wrote ${OUT}`);
