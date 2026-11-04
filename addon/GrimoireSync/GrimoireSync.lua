-- Grimoire Sync: snapshots the current character into GrimoireSyncDB.last so the
-- Forsaken Grimoire page can import it. WoW only writes SavedVariables to disk on
-- logout or /reload, so the page sees changes after one of those.
-- Every API call is wrapped in pcall: Forever is a new client and Classic APIs may differ.

GrimoireSyncDB = GrimoireSyncDB or {}

-- Spellbook names that mean a class quest / milestone is done. Values match the page's checklist ids
-- (each class has its own checklist, so ids only need to be unique within a class).
-- English client only; other locales simply won't auto-tick these. The field is still called
-- `demons` in the snapshot so older page versions keep reading it.
local DEMON_SPELLS = {
  -- Warlock
  ["Summon Imp"] = "cq-imp",
  ["Summon Voidwalker"] = "cq-vw",
  ["Summon Succubus"] = "cq-succ",
  ["Summon Incubus"] = "cq-succ",
  ["Summon Felhunter"] = "cq-fh",
  ["Summon Felsteed"] = "cq-felsteed",
  ["Summon Dreadsteed"] = "cq-dread",
  ["Inferno"] = "cq-inferno",
  -- Paladin (Forsaken mount names are from beta guides; both spellings are listed)
  ["Holy Strike"] = "pm-hs",
  ["Consecration"] = "pm-cons",
  ["Redemption"] = "pq-redemp",
  ["Summon Warhorse"] = "pq-warhorse",
  ["Summon Forsaken Warhorse"] = "pq-warhorse",
  ["Summon Charger"] = "pq-charger",
  ["Summon Forsaken Charger"] = "pq-charger",
}

local function safe(fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
end

-- Walk the spellbook tabs; returns a list of checklist ids for known demons.
local function scanDemons()
  local found, seen = {}, {}
  local tabs = safe(GetNumSpellTabs) or 0
  for t = 1, tabs do
    local _, _, offset, num = safe(GetSpellTabInfo, t)
    for i = (offset or 0) + 1, (offset or 0) + (num or 0) do
      local name = safe(GetSpellBookItemName, i, BOOKTYPE_SPELL or "spell")
      local id = name and DEMON_SPELLS[name]
      if id and not seen[id] then seen[id] = true; found[#found + 1] = id end
    end
  end
  return found
end

-- Primary + secondary profession ranks from the skill pane (Classic-style API).
local function scanProfessions()
  local out = {}
  local n = safe(GetNumSkillLines) or 0
  for i = 1, n do
    local name, isHeader, _, rank, _, _, maxRank = safe(GetSkillLineInfo, i)
    if name and not isHeader and rank and maxRank and maxRank > 1 then
      out[name] = rank
    end
  end
  return out
end

local function countCompletedQuests()
  local t = safe(GetQuestsCompleted)
  if type(t) ~= "table" then return nil end
  local c = 0
  for _ in pairs(t) do c = c + 1 end
  return c
end

local pendingLevel -- PLAYER_LEVEL_UP passes the new level before UnitLevel updates

local function snapshot()
  local _, classFile = safe(UnitClass, "player")
  local _, raceFile = safe(UnitRace, "player")
  local level = pendingLevel or safe(UnitLevel, "player")
  GrimoireSyncDB.last = {
    v = 1,
    -- name/realm are stripped by tools/sync.ps1 before anything is pushed to the public repo
    name = safe(UnitName, "player"),
    realm = safe(GetRealmName),
    class = classFile,
    race = raceFile,
    level = level,
    xp = safe(UnitXP, "player"),
    xpMax = safe(UnitXPMax, "player"),
    zone = safe(GetRealZoneText),
    subzone = safe(GetSubZoneText),
    money = safe(GetMoney),
    quests = countCompletedQuests(),
    demons = scanDemons(),
    profs = scanProfessions(),
    time = time(),
  }
  -- SavedVariables are account-wide, so `last` gets overwritten by whichever character logged in last.
  -- Keep a copy per class too, so the Warlock and the Paladin each keep their own snapshot on the page.
  if classFile then
    GrimoireSyncDB.byClass = GrimoireSyncDB.byClass or {}
    GrimoireSyncDB.byClass[classFile] = GrimoireSyncDB.last
  end
end

local f = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LEVEL_UP", "PLAYER_LOGOUT", "ZONE_CHANGED_NEW_AREA",
                     "SKILL_LINES_CHANGED", "LEARNED_SPELL_IN_TAB", "QUEST_TURNED_IN" }) do
  pcall(f.RegisterEvent, f, e)
end
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_LEVEL_UP" then pendingLevel = arg1 else pendingLevel = nil end
  snapshot()
end)

SLASH_GRIMOIRESYNC1 = "/grimoire"
SlashCmdList.GRIMOIRESYNC = function()
  snapshot()
  local s = GrimoireSyncDB.last
  print(("|cff8fdc5aGrimoire Sync|r %s level %s in %s, %d class milestone(s). Type /reload to write the file now.")
    :format(tostring(s.class), tostring(s.level), tostring(s.zone), #s.demons))
end
