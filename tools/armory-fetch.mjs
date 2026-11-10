// Pulls the character's public Forever Armory profile into docs/sync/armory.json for the Pages site.
// Run by .github/workflows/armory-sync.yml. No API key: the Battle.net developer API has no Forever
// namespace (all 404 as of 2026-11-10), but the Armory web page embeds the full profile as JSON in
// `var characterProfileInitialState = {...}` (gear, specs/talents, professions, stats, pvp).
// Inputs (env): ARMORY_REGION (default eu), ARMORY_SLUG (character slug from the Armory URL, e.g. dark-bober).
// Output: docs/sync/armory.json, rewritten only when the profile changes.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";

const region = (process.env.ARMORY_REGION || "eu").trim().toLowerCase();
const slug = (process.env.ARMORY_SLUG || "").trim().toLowerCase();
if (!slug) { console.error("Set ARMORY_SLUG (the last part of your Armory URL)."); process.exit(1); }
const OUT = "docs/sync/armory.json";
// Forever characters have realmless URLs; the realm isn't part of the path.
const url = `https://worldofwarcraft.blizzard.com/en-gb/forever/${region}/armory/character/${encodeURIComponent(slug)}`;

const r = await fetch(url, { headers: { "User-Agent": "Mozilla/5.0 (compatible; grimoire-sync)", "Accept-Language": "en-GB" } });
if (!r.ok) { console.error(`Armory returned HTTP ${r.status} for ${url}`); process.exit(1); }
const html = await r.text();

// Brace-walk the object literal instead of regexing it: item descriptions contain braces and quotes.
const marker = "var characterProfileInitialState = ";
const start = html.indexOf(marker);
if (start < 0) { console.error("Profile JSON not found; Blizzard may have changed the page layout."); process.exit(1); }
let i = start + marker.length, depth = 0, inStr = false, end = -1;
for (let k = i; k < html.length; k++) {
  const c = html[k];
  if (inStr) { if (c === "\\") k++; else if (c === '"') inStr = false; continue; }
  if (c === '"') inStr = true;
  else if (c === "{") depth++;
  else if (c === "}" && --depth === 0) { end = k + 1; break; }
}
const state = JSON.parse(html.slice(i, end));
const ch = state.character;
console.log(`${ch.name}: level ${ch.level} ${ch.race?.name} ${ch.class?.name}, ilvl ${ch.averageItemLevel}, armory updated ${ch.lastUpdatedTimestamp?.iso8601}`);

const payload = { source: url, character: ch };
// Skip the write when only the fetch time would change, so the hourly cron doesn't spam commits.
if (existsSync(OUT)) {
  try {
    const { fetched, ...prev } = JSON.parse(readFileSync(OUT, "utf8"));
    if (JSON.stringify(prev) === JSON.stringify(payload)) { console.log("No changes."); process.exit(0); }
  } catch { /* unreadable old file: overwrite */ }
}
mkdirSync("docs/sync", { recursive: true });
writeFileSync(OUT, JSON.stringify({ fetched: new Date().toISOString(), ...payload }, null, 1) + "\n");
console.log(`Wrote ${OUT}`);
