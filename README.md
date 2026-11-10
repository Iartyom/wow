# Forsaken Grimoire

A personal leveling guide for an **Undead Demonology Warlock** in *World of Warcraft: Forever*. It covers your racials, the class changes, a 1–60 quest-and-dungeon route, an interactive map, class quests, and a progress tracker. The **Grimoire Sync** addon fills the tracker in from the game.

A second character, an **Undead Retribution Paladin** who levels alongside the warlock, has its own tab. Use the Warlock/Paladin switch in the top bar, or open `?char=pal`. Each character keeps separate progress, notes and game data, and the addon stores one snapshot per class.

**Site:** https://iartyom.github.io/wow/

## Layout

| Path | What it is |
|---|---|
| `index.html` | Page source. It is also published as a Claude artifact, so it has no `<head>`. |
| `docs/` | GitHub Pages output, built by `tools/build.ps1`. Don't edit it by hand. |
| `docs/sync/GrimoireSync.lua` | Latest addon snapshot, pushed by `tools/sync.ps1`. Character name (`who`) and realm are removed first. |
| `addon/GrimoireSync/` | The WoW addon. |
| `tools/` | `install-addon.ps1`, `sync.ps1`, `build.ps1` |

## Sync from the game

1. Install Forever, then run `.\tools\install-addon.ps1`. Use `-Flavor <folder>` if it can't find the Forever folder.
2. In game, enable **Grimoire Sync**. It records level, zone, gold, demons, professions, talents, spells, equipped gear, bags and bank (after you open it once). The page uses these for the talent/trainer progress and the **Item worth** calculator. Type `/grimoire` to check what it recorded.
3. Log out or `/reload`. WoW only writes the SavedVariables file at those moments.
4. Run `.\tools\sync.ps1 -Watch`. It pushes each new snapshot, and the site picks it up after GitHub Pages redeploys.

On the Claude artifact version, use **Load GrimoireSync.lua** on the page instead.

### Armory sync
The **Armory sync** GitHub Action (`.github/workflows/armory-sync.yml`) runs hourly. It reads the public Forever Armory page for the character and writes `docs/sync/armory.json`, which includes level, gear, specs/talents, professions, stats and PvP. It needs no API key. Blizzard's developer API has no Forever namespace yet (it returns 404), so the script parses the profile JSON embedded in the Armory page. The Armory only refreshes after you log out. To change the character, edit `ARMORY_REGION` and `ARMORY_SLUG` in the workflow. The slug is the last part of the Armory URL.

## Credits
The world maps are hotlinked from [Warcraft Wiki](https://warcraft.wiki.gg/wiki/Forever_map_comparison) and © Blizzard Entertainment. They are not stored in this repo. Content is based on beta-era data, so check it against live game info after the Nov 4, 2026 launch.
