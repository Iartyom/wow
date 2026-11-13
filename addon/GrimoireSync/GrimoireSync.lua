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

-- pcall wrapper that passes back EVERY return value. The old version kept only three, which silently
-- dropped GetSpellTabInfo's slot count (4th) and GetSkillLineInfo's rank (7th): that's why demons and
-- professions always came back empty. GetItemInfo needs 11 values.
local function safe(fn, ...)
  local r = { pcall(fn, ...) }
  if r[1] then return unpack(r, 2, table.maxn(r)) end
end


-- Spellbook iterator that works on both API generations: Classic globals (GetSpellTabInfo /
-- GetSpellBookItemName) and the modern C_SpellBook. The level-14 snapshot came back with zero demons,
-- which points at the Classic globals being missing or different on the Forever client.
local function eachBookSpell(fn)
  if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookSkillLineInfo then
    local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
    for t = 1, safe(C_SpellBook.GetNumSpellBookSkillLines) or 0 do
      local info = safe(C_SpellBook.GetSpellBookSkillLineInfo, t)
      if info then
        for i = (info.itemIndexOffset or 0) + 1, (info.itemIndexOffset or 0) + (info.numSpellBookItems or 0) do
          local name, sub = safe(C_SpellBook.GetSpellBookItemName, i, bank)
          if name then fn(name, sub) end
        end
      end
    end
    return
  end
  local getName = GetSpellBookItemName or GetSpellName
  for t = 1, safe(GetNumSpellTabs) or 0 do
    local _, _, offset, num = safe(GetSpellTabInfo, t)
    for i = (offset or 0) + 1, (offset or 0) + (num or 0) do
      local name, sub = safe(getName, i, BOOKTYPE_SPELL or "spell")
      if name then fn(name, sub) end
    end
  end
end

-- Walk the spellbook tabs; returns a list of checklist ids for known demons.
local function scanDemons()
  local found, seen = {}, {}
  eachBookSpell(function(name)
    local id = DEMON_SPELLS[name]
    if id and not seen[id] then seen[id] = true; found[#found + 1] = id end
  end)
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
  if next(out) == nil and GetProfessions then
    local list = { safe(GetProfessions) }
    for i = 1, 6 do
      local idx = list[i]
      if idx then
        local pname, _, rank = safe(GetProfessionInfo, idx)
        if pname then out[pname] = rank end
      end
    end
  end
  return out
end

-- One-off API probe: which talent/profession functions exist on this client and what they return.
-- Written to GrimoireSyncDB.probe so the right scanner can be picked (Forever's talents came back empty).
local function probe()
  local out = {}
  for _, k in ipairs({ "GetNumTalentTabs", "GetTalentTabInfo", "GetNumTalents", "GetTalentInfo", "UnitCharacterPoints",
                       "GetUnspentTalentPoints", "GetActiveTalentGroup", "GetNumSkillLines", "GetSkillLineInfo",
                       "GetProfessions", "GetProfessionInfo", "C_SpecializationInfo", "C_ClassTalents", "C_Traits",
                       "C_SpellBook", "C_TradeSkillUI", "C_Container", "C_Item", "C_TooltipInfo", "C_Talent" }) do
    out[k] = type(_G[k])
  end
  out.numTalentTabs = safe(GetNumTalentTabs)
  out.numTalentTabsInspectFalse = safe(GetNumTalentTabs, false, false)
  out.tab1 = { safe(GetTalentTabInfo, 1) }
  out.talent11 = { safe(GetTalentInfo, 1, 1) }
  out.numSkillLines = safe(GetNumSkillLines)
  out.skill1 = { safe(GetSkillLineInfo, 1) }
  out.profs = { safe(GetProfessions) }
  out.charPoints = { safe(UnitCharacterPoints, "player") }
  if C_ClassTalents and C_ClassTalents.GetActiveConfigID then out.configID = safe(C_ClassTalents.GetActiveConfigID) end
  -- list members of the talent namespaces that exist, so the right call can be written without guessing
  for _, ns in ipairs({ "C_ClassTalents", "C_Traits", "C_SpecializationInfo", "C_Talent" }) do
    if type(_G[ns]) == "table" then
      local names = {}
      for k in pairs(_G[ns]) do names[#names + 1] = k end
      table.sort(names); out[ns .. "_fns"] = table.concat(names, ",")
    end
  end
  GrimoireSyncDB.probe = out
end



-- Forever has no Classic talent API (probe, Nov 7: GetTalentTabInfo = nil); talents live in the modern
-- trait system. Walk the active config's tree(s): node -> active entry -> definition -> spell name.
-- Tabs are grouped by subtree when the client uses them, else everything is one "Talents" tab.
local function spellName(id)
  if not id then return end
  if C_Spell and C_Spell.GetSpellName then return safe(C_Spell.GetSpellName, id) end
  if C_Spell and C_Spell.GetSpellInfo then local i = safe(C_Spell.GetSpellInfo, id); return i and i.name end
  if GetSpellInfo then return (safe(GetSpellInfo, id)) end
end
local function scanTraits()
  if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetConfigInfo) then return end
  local configID = safe(C_ClassTalents.GetActiveConfigID)
  local cfg = configID and safe(C_Traits.GetConfigInfo, configID)
  if not cfg or not cfg.treeIDs then return end
  local out, groups, order, sample = { tabs = {}, ranks = {}, free = 0 }, {}, {}, nil
  -- Full tree as the client has it (every talent, not just spent ones), so the page's talent plan can be
  -- checked against Forever's real names, max ranks, positions and tooltips instead of Classic memory.
  local tree = {}
  for _, treeID in ipairs(cfg.treeIDs) do
    for _, nodeID in ipairs(safe(C_Traits.GetTreeNodes, treeID) or {}) do
      local node = safe(C_Traits.GetNodeInfo, configID, nodeID)
      if node and not sample then
        -- keep one node's field names in the probe, to refine tab grouping later
        local keys = {}; for k in pairs(node) do keys[#keys + 1] = k end; table.sort(keys)
        sample = table.concat(keys, ",")
      end
      local rank = node and (node.activeRank or node.currentRank or 0) or 0
      local entryID = node and ((node.activeEntry and node.activeEntry.entryID) or (node.entryIDs and node.entryIDs[1]))
      if node and node.isVisible ~= false and entryID then
        local e = safe(C_Traits.GetEntryInfo, configID, entryID)
        local d = e and e.definitionID and safe(C_Traits.GetDefinitionInfo, e.definitionID)
        local sid = d and (d.spellID or d.overriddenSpellID)
        local nm = d and (d.overrideName or spellName(sid))
        if nm then
          local req = {}
          for _, edge in ipairs(node.visibleEdges or {}) do req[#req + 1] = edge.targetNode end
          local desc = C_Traits.GetTraitDescription and safe(C_Traits.GetTraitDescription, entryID, math.max(1, rank))
          tree[#tree + 1] = { id = nodeID, name = nm, spell = sid, max = node.maxRanks, rank = rank,
                              x = node.posX, y = node.posY, to = req, desc = desc }
        end
      end
      if rank > 0 and entryID then
        local entry = safe(C_Traits.GetEntryInfo, configID, entryID)
        local def = entry and entry.definitionID and safe(C_Traits.GetDefinitionInfo, entry.definitionID)
        local name = def and (def.overrideName or spellName(def.spellID or def.overriddenSpellID))
        if name then out.ranks[name] = (out.ranks[name] or 0) + rank end
        local g = (node.subTreeID and node.subTreeID ~= 0) and node.subTreeID or "all"
        if not groups[g] then groups[g] = 0; order[#order + 1] = g end
        groups[g] = groups[g] + rank
      end
    end
    -- unspent points: the tree's currency (quantity = what's left to spend)
    for _, cur in ipairs(safe(C_Traits.GetTreeCurrencyInfo, configID, treeID, false) or {}) do
      out.free = out.free + (cur.quantity or 0)
    end
  end
  for _, g in ipairs(order) do
    local nm = "Talents"
    if g ~= "all" and C_Traits.GetSubTreeInfo then
      local st = safe(C_Traits.GetSubTreeInfo, configID, g); nm = st and st.name or ("Tree " .. g)
    end
    out.tabs[#out.tabs + 1] = { name = nm, spent = groups[g] }
  end
  if #out.tabs == 0 then out.tabs[1] = { name = "Talents", spent = 0 } end
  local _, cls = safe(UnitClass, "player")
  if cls and #tree > 0 then
    GrimoireSyncDB.tree = GrimoireSyncDB.tree or {}
    GrimoireSyncDB.tree[cls] = { time = time(), nodes = tree }
  end
  GrimoireSyncDB.probe = GrimoireSyncDB.probe or {}
  GrimoireSyncDB.probe.traitNodeFields = sample
  GrimoireSyncDB.probe.traitTrees = #cfg.treeIDs
  return out
end

-- Talents: { tabs = { {name=, spent=} ... }, ranks = { ["Talent Name"] = rank }, free = unspent points }.
-- Only talents with at least one point are listed, to keep the file small.
local function scanTalents()
  local out = { tabs = {}, ranks = {} }
  local nTabs = safe(GetNumTalentTabs) or 0
  for t = 1, nTabs do
    local a, b, c = safe(GetTalentTabInfo, t)
    -- Classic returns (name, icon, pointsSpent); newer clients return (id, name, desc, icon, pointsSpent).
    local tabName, spent = a, c
    if type(a) == "number" then tabName = b; spent = select(5, safe(GetTalentTabInfo, t)) end
    out.tabs[#out.tabs + 1] = { name = tabName, spent = tonumber(spent) or 0 }
    for i = 1, safe(GetNumTalents, t) or 0 do
      local name, _, _, _, rank = safe(GetTalentInfo, t, i)
      if name and (rank or 0) > 0 then out.ranks[name] = rank end
    end
  end
  out.free = safe(UnitCharacterPoints, "player")
  if nTabs == 0 then return scanTraits() or out end
  return out
end

-- Every spell in the spellbook with its highest known rank ("Rank 3" -> 3; no rank -> 1).
local function scanSpells()
  local out = {}
  eachBookSpell(function(name, sub)
    local r = tonumber(sub and sub:match("(%d+)")) or 1
    if r > (out[name] or 0) then out[name] = r end
  end)
  return out
end

local function countCompletedQuests()
  -- Forever may only ship the modern API; try the old global first, then C_QuestLog.
  local t = safe(GetQuestsCompleted)
  if type(t) ~= "table" and C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
    t = safe(C_QuestLog.GetAllCompletedQuestIDs)
  end
  if type(t) ~= "table" then return nil end
  local c = 0
  for _ in pairs(t) do c = c + 1 end
  return c
end


-- ---------- inventory (for the page's Item worth calculator) ----------
-- Each item is recorded with its tooltip lines, so the page parses stats itself (easier to fix the
-- parser on the page than to ship a new addon). Red tooltip text (wrong class, armor type, level)
-- is prefixed with "!" so the page knows what this character can't use. A right-hand column
-- (armor type, weapon speed) follows a tab.
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
local tip
local tipCache = {}   -- link -> lines; item links are stable within a session
local function tipLines(link)
  if tipCache[link] then return tipCache[link] end
  if not tip then
    tip = CreateFrame("GameTooltip", "GrimoireSyncTip", nil, "GameTooltipTemplate")
  end
  tip:SetOwner(WorldFrame, "ANCHOR_NONE")
  tip:ClearLines()
  if not pcall(tip.SetHyperlink, tip, link) then return {} end
  local out = {}
  local function red(fs) local r, g, b = fs:GetTextColor(); return r > .9 and g < .3 and b < .3 end
  for i = 2, math.min(tip:NumLines() or 0, 30) do
    local L, R = _G["GrimoireSyncTipTextLeft" .. i], _G["GrimoireSyncTipTextRight" .. i]
    local lt = L and L:GetText()
    if lt and lt ~= "" then
      local line = (red(L) and "!" or "") .. lt
      local rt = R and R:IsShown() and R:GetText()
      if rt and rt ~= "" then line = line .. "\t" .. (red(R) and "!" or "") .. rt end
      out[#out + 1] = line
    end
  end
  tip:Hide()
  -- Only cache once the item data is in (an uncached item shows a near-empty tooltip).
  if #out > 0 and GetItemInfo(link) then tipCache[link] = out end
  return out
end

-- One item record. bound comes from the container API (Soulbound isn't in a hyperlink tooltip).
local function itemRec(link, count, bound)
  local name, _, quality, ilvl, reqLevel, itype, subType, _, equipLoc, tex, sellPrice = safe(GetItemInfo, link)
  local id = tonumber(link:match("item:(%d+)"))
  local r = { id = id, n = count or 1, name = name, q = quality, ilvl = ilvl, req = reqLevel,
              type = itype, sub = subType, loc = equipLoc, sell = sellPrice, bound = bound and true or nil,
              tex = tonumber(tex),   -- icon file id: the page builds the icon URL from it (Wowhead lacks Forever items)
              tip = tipLines(link) }
  -- Auction price per unit (copper) if Auctionator or TSM is installed; both are optional.
  if id and Auctionator and Auctionator.API and Auctionator.API.v1 then
    r.ah = safe(Auctionator.API.v1.GetAuctionPriceByItemLink, "GrimoireSync", link)
        or safe(Auctionator.API.v1.GetAuctionPriceByItemID, "GrimoireSync", id)
  end
  if not r.ah and TSM_API and TSM_API.GetCustomPriceValue and TSM_API.ToItemString then
    local is = safe(TSM_API.ToItemString, link)
    r.ah = is and safe(TSM_API.GetCustomPriceValue, "DBMarket", is) or nil
  end
  return r
end

-- Container API moved into C_Container in newer clients; support both shapes.
local function slotInfo(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local t = safe(C_Container.GetContainerItemInfo, bag, slot)
    if t then return t.hyperlink, t.stackCount, t.isBound end
    return
  end
  local _, count, _, _, _, _, link, _, _, _, bound = safe(GetContainerItemInfo, bag, slot)
  return link, count, bound
end
local function numSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return safe(C_Container.GetContainerNumSlots, bag) or 0 end
  return safe(GetContainerNumSlots, bag) or 0
end

local function scanBags(bags)
  local out = {}
  for _, bag in ipairs(bags) do
    for slot = 1, numSlots(bag) do
      local link, count, bound = slotInfo(bag, slot)
      if link then
        local r = itemRec(link, count, bound); r.bag = bag
        out[#out + 1] = r
      end
    end
  end
  return out
end

local function scanGear()
  local out = {}
  for slot = 1, 19 do
    local link = safe(GetInventoryItemLink, "player", slot)
    if link then out[tostring(slot)] = itemRec(link, 1, true) end
  end
  return out
end

-- Bank is only readable while the bank window is open, so it's kept per class between visits.
local function scanBank()
  local _, classFile = safe(UnitClass, "player")
  if not classFile then return end
  local bags = { -1 }
  for b = (NUM_BAG_SLOTS or 4) + 1, (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 6) do bags[#bags + 1] = b end
  GrimoireSyncDB.bank = GrimoireSyncDB.bank or {}
  GrimoireSyncDB.bank[classFile] = { time = time(), items = scanBags(bags) }
end

local invState
local probed
local function scanInventory()
  if not probed then probed = true; pcall(probe) end
  local bags = {}
  for b = 0, NUM_BAG_SLOTS or 4 do bags[#bags + 1] = b end
  invState = { time = time(), bags = scanBags(bags), gear = scanGear() }
end

local pendingLevel -- PLAYER_LEVEL_UP passes the new level before UnitLevel updates

local function snapshot(event)
  local _, classFile = safe(UnitClass, "player")
  local _, raceFile = safe(UnitRace, "player")
  local level = pendingLevel or safe(UnitLevel, "player")
  -- During logout (and sometimes very early at login) unit data reads as 0/empty. A snapshot taken then
  -- would overwrite good values with zeros, so skip it: the file still gets the last good snapshot.
  local xpMax = safe(UnitXPMax, "player")
  if (not xpMax or xpMax == 0) and (level or 0) < 60 then return end
  GrimoireSyncDB.last = {
    v = 1,
    -- name/realm are stripped by tools/sync.ps1 before anything is pushed to the public repo
    who = safe(UnitName, "player"),
    realm = safe(GetRealmName),
    class = classFile,
    race = raceFile,
    level = level,
    xp = safe(UnitXP, "player"),
    xpMax = xpMax,
    zone = safe(GetRealZoneText),
    subzone = safe(GetSubZoneText),
    money = safe(GetMoney),
    quests = countCompletedQuests(),
    demons = scanDemons(),
    profs = scanProfessions(),
    talents = scanTalents(),
    spells = scanSpells(),
    time = time(),
    inv = invState,
  }
  -- SavedVariables are account-wide, so `last` gets overwritten by whichever character logged in last.
  -- Keep a copy per class too, so the Warlock and the Paladin each keep their own snapshot on the page.
  if classFile then
    GrimoireSyncDB.byClass = GrimoireSyncDB.byClass or {}
    GrimoireSyncDB.byClass[classFile] = GrimoireSyncDB.last
  end
end

local f = CreateFrame("Frame")
-- PLAYER_ENTERING_WORLD instead of LOGIN: unit data is ready by then. XP/money events keep the
-- snapshot current, so nothing needs to be read at logout (when the values are already gone).
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "ZONE_CHANGED_NEW_AREA", "PLAYER_XP_UPDATE",
                     "PLAYER_MONEY", "SKILL_LINES_CHANGED", "LEARNED_SPELL_IN_TAB", "QUEST_TURNED_IN",
                     "CHARACTER_POINTS_CHANGED", "SPELLS_CHANGED",
                     "TRAIT_CONFIG_UPDATED", "PLAYER_TALENT_UPDATE" }) do
  pcall(f.RegisterEvent, f, e)
end
-- Inventory events fire in bursts while looting, so the rescan is debounced to once per second.
-- AUCTION_HOUSE_CLOSED / MERCHANT_CLOSED: re-read Auctionator prices after a scan, and bags after selling.
local INV_EVENTS = { BAG_UPDATE_DELAYED = true, PLAYER_EQUIPMENT_CHANGED = true, BANKFRAME_OPENED = true,
                     PLAYERBANKSLOTS_CHANGED = true, AUCTION_HOUSE_CLOSED = true, MERCHANT_CLOSED = true }
for e in pairs(INV_EVENTS) do pcall(f.RegisterEvent, f, e) end
pcall(f.RegisterEvent, f, "BANKFRAME_CLOSED")
pcall(f.RegisterEvent, f, "GET_ITEM_INFO_RECEIVED")
local bankOpen, invPending = false, false
-- pcall: one odd item must not throw a Lua error popup from a timer callback.
local function invRescan()
  invPending = false
  pcall(scanInventory)
  if bankOpen then pcall(scanBank) end
  pcall(snapshot, "inventory")
end
local function queueInv()
  if invPending then return end
  invPending = true
  if C_Timer and C_Timer.After then C_Timer.After(1, invRescan) else invRescan() end
end
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "BANKFRAME_CLOSED" then
    if bankOpen then pcall(scanBank) end   -- catch a deposit made in the last second
    bankOpen = false
    return
  end
  if event == "GET_ITEM_INFO_RECEIVED" then if invState then queueInv() end return end
  if event == "BANKFRAME_OPENED" then bankOpen = true end
  if INV_EVENTS[event] then queueInv() return end
  if event == "PLAYER_LEVEL_UP" then pendingLevel = arg1 else pendingLevel = nil end
  -- First scan a few seconds after login: item data for bag contents may still be loading.
  if event == "PLAYER_ENTERING_WORLD" and C_Timer and C_Timer.After then C_Timer.After(4, queueInv) end
  snapshot(event)
end)

SLASH_GRIMOIRESYNC1 = "/grimoire"
SlashCmdList.GRIMOIRESYNC = function()
  snapshot()
  local s = GrimoireSyncDB.last
  if not s then print("|cff8fdc5aGrimoire Sync|r no data yet, try again in a few seconds.") return end
  local nInv = s.inv and #s.inv.bags or 0
  print(("|cff8fdc5aGrimoire Sync|r %s level %s in %s, %d class milestone(s), %d bag item(s). Type /reload to write the file now.")
    :format(tostring(s.class), tostring(s.level), tostring(s.zone), #s.demons, nInv))
end
