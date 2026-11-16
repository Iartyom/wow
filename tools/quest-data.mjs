// quest-data.mjs: builds docs/sync/quests.json for the quests in your synced quest log.
// Source: Questie's Forever database (github.com/Questie/QuestieDB, GPL-3.0), cached in tools/.questdb
// (git-ignored; fetch with `node tools/quest-data.mjs --fetch`). Only the quests in the log are written,
// so the published file stays small. Coordinates are already Forever map percentages (QuestieDB converts them).
// Usage: node tools/quest-data.mjs [--fetch]
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CACHE = path.join(ROOT, "tools", ".questdb");
const SV = path.join(ROOT, "docs", "sync", "GrimoireSync.lua");
const OUT = path.join(ROOT, "docs", "sync", "quests.json");
const RAW = "https://raw.githubusercontent.com/Questie/QuestieDB/HEAD/";
const FILES = {
  "foreverQuestDB.lua": "data/Forever/foreverQuestDB.lua", "foreverNpcDB.lua": "data/Forever/foreverNpcDB.lua",
  "foreverObjectDB.lua": "data/Forever/foreverObjectDB.lua", "foreverItemDB.lua": "data/Forever/foreverItemDB.lua",
  "conversion.json": "data/Forever/conversion.json", "xpDB-classic.lua": "support/Forever/QuestXP/xpDB-classic.lua",
  "dungeons.lua": "support/Forever/Zones/dungeons.lua"
};

// ---- tiny Lua literal parser (tables, strings, numbers, nil/true/false); never executes anything ----
// Tables with only positional values become arrays (nil -> null, 0-based); any [key]= makes an object.
function parseLua(src, i = 0){
  const ws = () => { while(i < src.length && /\s/.test(src[i])) i++; };
  function val(){
    ws(); const c = src[i];
    if(c === "{") return table();
    if(c === "'" || c === '"'){
      let s = "", q = c; i++;
      while(src[i] !== q){ if(src[i] === "\\"){ i++; const e = src[i]; s += e === "n" ? "\n" : e; } else s += src[i]; i++; }
      i++; return s;
    }
    const m = /^(-?\d+(?:\.\d+)?(?:e-?\d+)?|nil|true|false)/.exec(src.slice(i, i + 40));
    if(!m) throw new Error("Lua parse error at " + i + ": " + src.slice(i, i + 30));
    i += m[0].length;
    return m[0] === "nil" ? null : m[0] === "true" ? true : m[0] === "false" ? false : +m[0];
  }
  function table(){
    i++; const arr = []; let obj = null;
    for(;;){
      ws();
      if(src[i] === "}"){ i++; break; }
      if(src[i] === ","){ i++; continue; }
      if(src[i] === "["){ i++; const k = val(); ws(); i++; ws(); i++; const v = val(); (obj ||= {})[k] = v; continue; }
      arr.push(val());
    }
    if(obj){ arr.forEach((v, n) => { obj[n + 1] = v; }); return obj; }
    return arr;
  }
  const v = val();
  return { v, end: i };
}
// One-line entries `[id] = {...},` for the wanted ids only (the DB files keep one entity per line).
function entries(file, ids){
  const want = new Set([...ids].map(Number)), out = {};
  if(!want.size) return out;
  for(const line of fs.readFileSync(path.join(CACHE, file), "utf8").split("\n")){
    const m = /^\s*\[(\d+)\]\s*=\s*\{/.exec(line); if(!m || !want.has(+m[1])) continue;
    out[m[1]] = parseLua(line, line.indexOf("{")).v;
  }
  return out;
}

async function fetchAll(){
  fs.mkdirSync(CACHE, { recursive: true });
  for(const [name, rel] of Object.entries(FILES)){
    const r = await fetch(RAW + rel); if(!r.ok) throw new Error(`${rel}: HTTP ${r.status}`);
    fs.writeFileSync(path.join(CACHE, name), Buffer.from(await r.arrayBuffer()));
    console.log("fetched", rel);
  }
}

// Quest ids in every qlog block of the synced file (both characters).
function logQuestIds(){
  const ids = new Set(); let depth = 0, inQ = 0;
  for(const line of fs.readFileSync(SV, "utf8").split("\n")){
    if(!inQ && /^\s*\["qlog"\]\s*=\s*\{/.test(line)){ inQ = depth + 1; }
    const m = inQ && /^\s*\["id"\]\s*=\s*(\d+)/.exec(line); if(m) ids.add(+m[1]);
    depth += (line.match(/\{/g) || []).length - (line.match(/\}/g) || []).length;
    if(inQ && depth < inQ) inQ = 0;
  }
  return ids;
}

async function main(){
  if(process.argv.includes("--fetch") || !fs.existsSync(path.join(CACHE, "foreverQuestDB.lua"))) await fetchAll();
  const ids = logQuestIds();
  if(!ids.size){ console.log("No quest log in the synced file (needs addon 0.6)."); return; }

  // Area id -> zone/city name as the page knows it; dungeon areas -> {name, parent zone, entrance}.
  const area = {};
  for(const t of JSON.parse(fs.readFileSync(path.join(CACHE, "conversion.json"), "utf8")).geometry.transforms) area[t.area_id] = t.target_name;
  const dung = {};
  for(const line of fs.readFileSync(path.join(CACHE, "dungeons.lua"), "utf8").split("\n")){
    const m = /^\s*\[(\d+)\]\s*=\s*\{/.exec(line); if(!m) continue;
    // A few entries are Lua expressions (faction-dependent entrances); skip those rather than evaluate them.
    let d; try{ d = parseLua(line, line.indexOf("{")).v; }catch(e){ continue; }
    const e = d[3] && d[3][0];
    dung[m[1]] = { name: d[0], parent: area[d[2]] || null, door: e ? { map: area[e[0]] || null, x: e[1], y: e[2] } : null };
    for(const alt of d[1] || []) dung[alt] = dung[m[1]];
  }
  const areaName = a => area[a] || (dung[a] && dung[a].name) || null;
  const xpDB = {};
  for(const line of fs.readFileSync(path.join(CACHE, "xpDB-classic.lua"), "utf8").split("\n")){
    const m = /^\s*\[(\d+)\]\s*=\s*\{(\d+),\s*(\d+)\}/.exec(line); if(m && ids.has(+m[1])) xpDB[m[1]] = +m[3];
  }

  const quests = entries("foreverQuestDB.lua", ids);
  // Collect every NPC/object/item the quests reference, then load just those.
  const npcIds = new Set(), objIds = new Set(), itemIds = new Set(), nextIds = new Set();
  for(const q of Object.values(quests)){
    const [st, fin, obj] = [q[1] || [], q[2] || [], q[9] || []];
    (st[0] || []).forEach(x => npcIds.add(x)); (st[1] || []).forEach(x => objIds.add(x));
    (fin[0] || []).forEach(x => npcIds.add(x)); (fin[1] || []).forEach(x => objIds.add(x));
    (obj[0] || []).forEach(o => npcIds.add(o[0])); (obj[1] || []).forEach(o => objIds.add(o[0]));
    (obj[2] || []).forEach(o => itemIds.add(o[0]));
    (obj[4] || []).forEach(k => (k[0] || []).forEach(x => npcIds.add(x)));
    if(q[21]) nextIds.add(q[21]);
  }
  const items = entries("foreverItemDB.lua", itemIds);
  for(const it of Object.values(items)){ (it[1] || []).slice(0, 12).forEach(x => npcIds.add(x)); (it[2] || []).slice(0, 12).forEach(x => objIds.add(x)); }
  const npcs = entries("foreverNpcDB.lua", npcIds), objs = entries("foreverObjectDB.lua", objIds);
  const nextQ = entries("foreverQuestDB.lua", nextIds);

  // Spawns {areaId: [[x,y],...]} -> where to go. Picks the area with most spawns; dungeon areas report the dungeon.
  function place(spawns){
    if(!spawns || typeof spawns !== "object") return null;
    // Open-world spawns win; dungeon spawns are stored as (-1,-1), so a dungeon is only the fallback.
    let best = null, n = 0, dun = null;
    for(const [a, pts] of Object.entries(spawns)){
      if(!Array.isArray(pts)) continue;
      if(dung[a]){ dun = dun || a; continue; }
      const ok = pts.filter(p => p && p[0] >= 0).length;
      if(ok > n){ best = a; n = ok; }
    }
    if(!best && dun) return { map: dung[dun].name, dungeon: dung[dun].name, door: dung[dun].door, pts: [] };
    if(!best) return null;
    const pts = spawns[best].filter(p => p && p[0] >= 0);
    if(dung[best]) return { map: dung[best].name, dungeon: dung[best].name, door: dung[best].door, pts: [] };
    const name = areaName(best); if(!name) return null;
    return { map: name, pts };
  }
  // Densest spot: the point with most neighbours within 6 map-% units, averaged with them. "Go here" pin.
  function centre(pts){
    if(!pts.length) return null;
    let bi = 0, bn = -1;
    pts.forEach((p, k) => { const c = pts.filter(q => Math.hypot(q[0] - p[0], q[1] - p[1]) < 6).length; if(c > bn){ bn = c; bi = k; } });
    const near = pts.filter(q => Math.hypot(q[0] - pts[bi][0], q[1] - pts[bi][1]) < 6);
    const r = v => Math.round(v * 10) / 10;
    return [r(near.reduce((s, q) => s + q[0], 0) / near.length), r(near.reduce((s, q) => s + q[1], 0) / near.length)];
  }
  const thin = (pts, max) => { const step = Math.max(1, Math.ceil(pts.length / max)); return pts.filter((_, k) => k % step === 0).map(p => [Math.round(p[0] * 10) / 10, Math.round(p[1] * 10) / 10]); };
  const RANK = { 1: "elite", 2: "rare elite", 3: "boss", 4: "rare" };
  const who = (kind, id) => {
    const e = kind === "npc" ? npcs[id] : objs[id]; if(!e) return null;
    const p = place(kind === "npc" ? e[6] : e[3]);
    const c = p && p.pts.length ? centre(p.pts) : null;
    return { kind, id, name: e[0], title: kind === "npc" ? e[13] || null : null, map: p && p.map, dungeon: p && p.dungeon || null,
             door: p && p.door || null, x: c && c[0], y: c && c[1], lvl: kind === "npc" ? [e[3], e[4]] : null, rank: kind === "npc" ? RANK[e[5]] || null : null };
  };
  // One objective target (mob or object) with its spawn dots, thinned to keep the JSON small.
  const target = (kind, id) => {
    const e = kind === "npc" ? npcs[id] : objs[id]; if(!e) return null;
    const p = place(kind === "npc" ? e[6] : e[3]); const base = who(kind, id);
    return { ...base, pts: p ? thin(p.pts, 40) : [] };
  };

  const out = {};
  for(const [id, q] of Object.entries(quests)){
    const st = q[1] || [], fin = q[2] || [], ob = q[9] || [];
    const objectives = [];
    for(const o of ob[0] || []) objectives.push({ type: "kill", text: o[1] || null, targets: [target("npc", o[0])].filter(Boolean) });
    for(const o of ob[1] || []) objectives.push({ type: "object", text: o[1] || null, targets: [target("obj", o[0])].filter(Boolean) });
    for(const o of ob[2] || []){
      const it = items[o[0]] || [];
      const from = [...(it[1] || []).slice(0, 6).map(n => target("npc", n)), ...(it[2] || []).slice(0, 6).map(n => target("obj", n))].filter(Boolean);
      objectives.push({ type: "item", item: it[0] || null, itemId: o[0], text: o[1] || null, targets: from });
    }
    for(const k of ob[4] || []) objectives.push({ type: "kill", text: k[2] || null, targets: (k[0] || []).slice(0, 4).map(n => target("npc", n)).filter(Boolean) });
    // triggerEnd = "go to this place" objectives: {text, {[area] = {{x,y}}}}
    if(q[8] && q[8][1]){ const p = place(q[8][1]); if(p) objectives.push({ type: "explore", text: q[8][0], targets: [{ kind: "spot", name: q[8][0], map: p.map, pts: thin(p.pts, 5), x: p.pts[0] && p.pts[0][0], y: p.pts[0] && p.pts[0][1] }] }); }
    const ender = (fin[0] || [])[0] != null ? who("npc", fin[0][0]) : (fin[1] || [])[0] != null ? who("obj", fin[1][0]) : null;
    const starter = (st[0] || [])[0] != null ? who("npc", st[0][0]) : (st[1] || [])[0] != null ? who("obj", st[1][0]) : null;
    const zs = q[16];
    out[id] = {
      name: q[0], lvl: q[4], req: q[3], xp: xpDB[id] || null, text: (q[7] || []).filter(Boolean).join(" ") || null,
      zone: zs > 0 ? areaName(zs) : null, dungeon: zs > 0 && dung[zs] ? dung[zs].name : null,
      start: starter, end: ender, objectives,
      next: q[21] && nextQ[q[21]] ? { id: q[21], name: nextQ[q[21]][0] } : null
    };
  }
  const json = JSON.stringify({ built: Math.floor(Date.now() / 1000), source: "QuestieDB Forever (GPL-3.0)", quests: out });
  const prev = fs.existsSync(OUT) ? fs.readFileSync(OUT, "utf8") : "";
  // Same quests, same data: don't touch the file (keeps sync commits quiet).
  if(prev && prev.replace(/"built":\d+,/, "") === json.replace(/"built":\d+,/, "")){ console.log("quests.json unchanged"); return; }
  fs.writeFileSync(OUT, json);
  console.log(`quests.json: ${Object.keys(out).length}/${ids.size} quests found, ${(json.length / 1024).toFixed(0)} KB`);
}
main().catch(e => { console.error(e.message); process.exit(1); });
