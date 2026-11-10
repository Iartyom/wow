// Builds docs/data/items.json: a name index of every wearable Classic Era item, for the page's
// "Try an item" search. Run once (or after a client patch): `node tools/item-index.mjs [build]`.
// Source: wago.tools DB2 CSVs (Item = class/subclass/slot, ItemSparse = name/quality/levels).
// Stats are NOT stored here: the page fetches the Wowhead tooltip for the one item you pick.
// Caveat: this is Classic Era data. Forever may have changed some items.
import { writeFileSync, mkdirSync } from "node:fs";

const BUILD = process.argv[2] || "1.15.9.70576";
const OUT = "docs/data/items.json";

// Minimal RFC 4180 parser: names contain commas and quotes, so a plain split(",") breaks.
function parseCSV(text) {
  const rows = []; let row = [], f = "", q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; continue; }
    if (c === '"') q = true;
    else if (c === ",") { row.push(f); f = ""; }
    else if (c === "\n") { row.push(f); rows.push(row); row = []; f = ""; }
    else if (c !== "\r") f += c;
  }
  if (f || row.length) { row.push(f); rows.push(row); }
  const [head, ...body] = rows;
  return body.map(r => Object.fromEntries(head.map((h, i) => [h, r[i]])));
}
async function table(name) {
  const r = await fetch(`https://wago.tools/db2/${name}/csv?build=${BUILD}`);
  if (!r.ok) throw new Error(`${name}: HTTP ${r.status}`);
  return parseCSV(await r.text());
}

// Classic InventoryType enum -> the INVTYPE_* names the page (and the addon) use. Unlisted = not wearable.
const INV = {1:"HEAD",2:"NECK",3:"SHOULDER",5:"CHEST",6:"WAIST",7:"LEGS",8:"FEET",9:"WRIST",10:"HAND",11:"FINGER",
  12:"TRINKET",13:"WEAPON",14:"SHIELD",15:"RANGED",16:"CLOAK",17:"2HWEAPON",20:"ROBE",21:"WEAPONMAINHAND",
  22:"WEAPONOFFHAND",23:"HOLDABLE",25:"THROWN",26:"RANGEDRIGHT",28:"RELIC"};
// Subclass names as GetItemInfo returns them, so the page's PROFS lists match.
const SUB = {
  2: {0:"One-Handed Axes",1:"Two-Handed Axes",2:"Bows",3:"Guns",4:"One-Handed Maces",5:"Two-Handed Maces",6:"Polearms",
      7:"One-Handed Swords",8:"Two-Handed Swords",10:"Staves",13:"Fist Weapons",14:"Miscellaneous",15:"Daggers",
      16:"Thrown",18:"Crossbows",19:"Wands",20:"Fishing Poles"},
  4: {0:"Miscellaneous",1:"Cloth",2:"Leather",3:"Mail",4:"Plate",6:"Shields",7:"Librams",8:"Idols",9:"Totems"}
};
// Internal/test items that exist in the DB but never drop.
const JUNK = /^(Monster - |OLD|TEST|Test |Deprecated|\[PH\]|DEBUG|zz|NPC Equip|Unused)/i;

const [items, sparse] = await Promise.all([table("Item"), table("ItemSparse")]);
const sp = new Map(sparse.map(r => [r.ID, r]));
const invList = Object.values(INV), subList = [...new Set([...Object.values(SUB[2]), ...Object.values(SUB[4])])];
const out = [];
for (const it of items) {
  const inv = INV[it.InventoryType], sub = SUB[it.ClassID]?.[it.SubclassID], s = sp.get(it.ID);
  if (!inv || !sub || !s) continue;
  const name = s.Display_lang; if (!name || JUNK.test(name)) continue;
  // Row: [id, name, quality, slot index, required level, item level, "W"eapon/"A"rmor, subclass index]
  out.push([+it.ID, name, +s.OverallQualityID || 0, invList.indexOf(inv), +s.RequiredLevel || 0, +s.ItemLevel || 0,
    it.ClassID === "2" ? "W" : "A", subList.indexOf(sub)]);
}
out.sort((a, b) => a[1].localeCompare(b[1]));
mkdirSync("docs/data", { recursive: true });
writeFileSync(OUT, JSON.stringify({ build: BUILD, inv: invList, sub: subList, items: out }));
console.log(`Wrote ${OUT}: ${out.length} items`);
