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

async function get(path, namespace = ns, host = api) {
  const r = await fetch(`${host}${path}?locale=en_US`, {
    headers: { Authorization: `Bearer ${access_token}`, "Battlenet-Namespace": namespace },
  });
  // Keep Blizzard's error text: it says whether the namespace or the resource is the problem.
  return r.ok ? { status: r.status, data: await r.json() } : { status: r.status, data: null, err: (await r.text()).slice(0, 200) };
}

// User is fine publishing character details, so only self-links are dropped (they're just API noise).
const scrub = (o) => o && Object.fromEntries(Object.entries(o).filter(([k]) => k !== "_links"));

const base = `/profile/wow/character/${encodeURIComponent(realm)}/${encodeURIComponent(name)}`;
const endpoints = {
  summary: "", equipment: "/equipment", statistics: "/statistics",
  specializations: "/specializations", professions: "/professions", media: "/character-media",
};
console.log(`Character ${name} @ ${realm}, namespace ${ns}`);
const results = {};
for (const [key, suffix] of Object.entries(endpoints)) {
  const { status, data, err } = await get(base + suffix);
  results[key] = { status, data: scrub(data) };
  console.log(`${key.padEnd(16)} HTTP ${status}${err ? "  " + err : ""}`);
}

// Diagnostic: on a 404, find which namespace/region actually serves realms and whether ours is listed.
// Forever's namespace is undocumented, so try the community-reported one plus the Classic families.
if (results.summary.status === 404) {
  for (const reg of ["us", "eu", "kr", "tw"]) {
    for (const fam of ["forever", "classic", "classic1x", "classicann"]) {
      const dns = `dynamic-${fam}-${reg}`;
      const r = await get("/data/wow/realm/index", dns, `https://${reg}.api.blizzard.com`);
      const slugs = r.data?.realms?.map((x) => x.slug) ?? [];
      const hit = slugs.includes(realm) ? "  <-- YOUR REALM IS HERE" : "";
      console.log(`probe ${dns.padEnd(24)} HTTP ${r.status}  ${slugs.length} realms${hit}`);
      if (hit) console.log(`  -> set repo variable BNET_REGION=${reg}, BNET_NAMESPACE=profile-${fam}-${reg}`);
    }
  }
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
