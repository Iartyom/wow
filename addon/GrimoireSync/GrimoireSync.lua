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
-- Caps go in profMax (separate table so older page versions still read `profs` as name -> rank);
-- a skill sitting at its cap means "visit the trainer for the next tier".
local profMax = {}
local function scanProfessions()
  local out = {}
  local n = safe(GetNumSkillLines) or 0
  for i = 1, n do
    local name, isHeader, _, rank, _, _, maxRank = safe(GetSkillLineInfo, i)
    if name and not isHeader and rank and maxRank and maxRank > 1 then
      out[name] = rank; profMax[name] = maxRank
    end
  end
  if next(out) == nil and GetProfessions then
    local list = { safe(GetProfessions) }
    for i = 1, 6 do
      local idx = list[i]
      if idx then
        local pname, _, rank, maxRank = safe(GetProfessionInfo, idx)
        if pname then out[pname] = rank; profMax[pname] = maxRank end
      end
    end
  end
  return out
end

-- Recipe difficulty -> one letter. o/y/g give skill (orange always, yellow usually, green rarely), x = grey.
-- Old API returns strings; C_TradeSkillUI returns Enum.TradeskillRelativeDifficulty (0 optimal .. 3 trivial).
local DIFF = { optimal = "o", medium = "y", easy = "g", trivial = "x", [0] = "o", [1] = "y", [2] = "g", [3] = "x" }
local function itemIdOf(link) return link and tonumber(link:match("item:(%d+)")) end

-- Reads the open profession window: every learned recipe with its colour, what it makes and its reagents.
-- Stored per profession in GrimoireSyncDB.crafts so the page can say what to craft for skill-ups.
-- Tries the Classic globals first, then C_TradeSkillUI (the Forever client has the C_ table).
local function scanTradeSkill()
  local prof, rank, maxRank, list = nil, nil, nil, {}
  if GetNumTradeSkills and GetTradeSkillLine then
    prof, rank, maxRank = safe(GetTradeSkillLine)
    for i = 1, safe(GetNumTradeSkills) or 0 do
      local name, kind, avail = safe(GetTradeSkillInfo, i)
      if name and kind ~= "header" and kind ~= "subheader" then
        local r = {}
        for j = 1, safe(GetTradeSkillNumReagents, i) or 0 do
          local rn, _, cnt = safe(GetTradeSkillReagentInfo, i, j)
          r[#r + 1] = { name = rn, id = itemIdOf(safe(GetTradeSkillReagentItemLink, i, j)), n = cnt }
        end
        list[#list + 1] = { name = name, d = DIFF[kind] or kind, can = avail, id = itemIdOf(safe(GetTradeSkillItemLink, i)), r = r }
      end
    end
  end
  if #list == 0 and C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
    local line = C_TradeSkillUI.GetBaseProfessionInfo and safe(C_TradeSkillUI.GetBaseProfessionInfo)
    if line then prof, rank, maxRank = line.professionName, line.skillLevel, line.maxSkillLevel end
    for _, rid in ipairs(safe(C_TradeSkillUI.GetAllRecipeIDs) or {}) do
      local ri = safe(C_TradeSkillUI.GetRecipeInfo, rid)
      if ri and ri.learned ~= false then
        local sch = C_TradeSkillUI.GetRecipeSchematic and safe(C_TradeSkillUI.GetRecipeSchematic, rid, false)
        local r = {}
        for _, slot in ipairs((sch and sch.reagentSlotSchematics) or {}) do
          local rg = slot.reagents and slot.reagents[1]
          if rg and rg.itemID and slot.reagentType ~= 0 then   -- 0 = optional/modifying slot (retail); Classic has none
            r[#r + 1] = { id = rg.itemID, name = safe(GetItemInfo, rg.itemID), n = slot.quantityRequired }
          end
        end
        local d = ri.relativeDifficulty; if d == nil then d = ri.difficulty end
        list[#list + 1] = { name = ri.name, d = DIFF[d] or tostring(d), can = ri.numAvailable,
                            id = sch and sch.outputItemID, r = r }
      end
    end
  end
  if not prof or #list == 0 then return end
  GrimoireSyncDB.crafts = GrimoireSyncDB.crafts or {}
  GrimoireSyncDB.crafts[prof] = { rank = rank, max = maxRank, t = time(), list = list }
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
-- Forever (1.60) only has the C_Item version of this one; without the fallback the shopping list silently did nothing.
local GetItemInfoInstant = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
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

-- ---- Auction House prices (0.7) ----
-- GrimoireSyncDB.ah = { full = time of last full scan, t = last update, n = items priced,
--                       p = { [itemID] = lowest buyout per unit, copper }, at = { [itemID] = when that price was seen } }
-- READ-ONLY by design: it only reads listings Blizzard already sends to the AH window. Nothing here bids,
-- buys, posts or cancels (those need a hardware click anyway). Two sources:
--   1. /grimoire scan with the AH open: Blizzard's own full-scan call (ReplicateItems on the modern AH,
--      QueryAuctionItems getAll on the old one). The server throttles it to about once per 15 min.
--   2. Passive: whatever you browse or search in the AH window is recorded too.
local function ahDB()
  GrimoireSyncDB.ah = GrimoireSyncDB.ah or {}
  local db = GrimoireSyncDB.ah
  db.p = db.p or {}; db.at = db.at or {}
  return db
end
-- Store a batch of {itemID = unit price}. Each batch is the current market for those items, so it replaces older prices.
local function ahStore(mins)
  local db, now, n = ahDB(), time(), 0
  for id, u in pairs(mins) do db.p[id] = math.floor(u + 0.5); db.at[id] = now; n = n + 1 end
  if n > 0 then
    db.t = now
    local c = 0; for _ in pairs(db.p) do c = c + 1 end
    db.n = c
  end
  return n
end
local function ahMin(mins, id, total, count)
  if not id or not total or total <= 0 then return end
  local u = total / math.max(count or 1, 1)
  if not mins[id] or u < mins[id] then mins[id] = u end
end

local ahOpen, ahScanning = false, nil   -- ahScanning = "modern" | "classic" while a full scan is pending
local function ahSay(msg) print("|cff8fdc5aGrimoire Sync|r " .. msg) end

-- Full-scan results: both APIs return the same fields (count 3rd, buyout 10th, itemID 17th).
-- Modern indexes from 0, the old "list" API from 1.
local function ahReadAll(kind)
  local mins, n = {}, 0
  if kind == "modern" then
    n = safe(C_AuctionHouse.GetNumReplicateItems) or 0
    for i = 0, n - 1 do
      local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, id = safe(C_AuctionHouse.GetReplicateItemInfo, i)
      ahMin(mins, id, buyout, count)
    end
  else
    n = safe(GetNumAuctionItems, "list") or 0
    for i = 1, n do
      local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, id = safe(GetAuctionItemInfo, "list", i)
      ahMin(mins, id, buyout, count)
    end
  end
  return mins, n
end

local ahShopCollect   -- assigned after itemRec (it builds full item records)
local function ahFinishScan()
  local kind = ahScanning; ahScanning = nil
  local mins, n = ahReadAll(kind)
  if n == 0 then ahSay("the scan came back empty. Blizzard allows one full scan about every 15 minutes; try again later.") return end
  local items = ahStore(mins)
  ahDB().full = time()
  local ok, err = pcall(ahShopCollect, kind, n)
  if not ok then GrimoireSyncDB.ahShopDbg = { t = time(), err = tostring(err) }; ahSay("shopping list failed: " .. tostring(err)) end
  ahSay(("scanned %d auctions, %d items priced. Building your shopping list, a few seconds..."):format(n, items))
end

local function ahStartScan()
  if not ahOpen then ahSay("open the Auction House first, then type /grimoire scan.") return end
  if ahScanning then ahSay("a scan is already running.") return end
  if C_AuctionHouse and C_AuctionHouse.ReplicateItems then
    ahScanning = "modern"
    if not pcall(C_AuctionHouse.ReplicateItems) then ahScanning = nil; ahSay("this client refused the full scan.") return end
  elseif QueryAuctionItems and CanSendAuctionQuery then
    local _, canAll = safe(CanSendAuctionQuery)
    if not canAll then ahSay("full scan is on cooldown (Blizzard allows one about every 15 minutes). Browsing still records prices.") return end
    ahScanning = "classic"
    if not pcall(QueryAuctionItems, "", nil, nil, 0, nil, nil, true) then ahScanning = nil; ahSay("this client refused the full scan.") return end
  else
    ahSay("this client has no full-scan API. Prices from what you browse are still recorded.") return
  end
  ahSay("scanning the Auction House, keep the window open (can take up to a minute)...")
  -- No answer at all usually means the server throttle: give up quietly after 90s.
  if C_Timer and C_Timer.After then
    C_Timer.After(90, function() if ahScanning then ahScanning = nil; ahSay("no answer from the AH, probably the 15-minute limit. Try again later.") end end)
  end
end

-- Passive capture from normal browsing/searching on the modern AH.
local function ahBrowse()
  local res = safe(C_AuctionHouse.GetBrowseResults); if type(res) ~= "table" then return end
  local mins = {}
  for _, r in ipairs(res) do
    local id = r.itemKey and r.itemKey.itemID
    if id and r.minPrice and r.minPrice > 0 then ahMin(mins, id, r.minPrice, 1) end
  end
  ahStore(mins)
end
local function ahCommodity(id)
  local r = id and safe(C_AuctionHouse.GetCommoditySearchResultInfo, id, 1)   -- results come sorted, cheapest first
  if r and r.unitPrice then ahStore({ [id] = r.unitPrice }) end
end
local function ahItemSearch(key)
  if type(key) ~= "table" or not key.itemID then return end
  local n, best = safe(C_AuctionHouse.GetNumItemSearchResults, key) or 0, nil
  for i = 1, math.min(n, 50) do
    local r = safe(C_AuctionHouse.GetItemSearchResultInfo, key, i)
    local b = r and r.buyoutAmount
    if b and b > 0 and (not best or b < best) then best = b end
  end
  if best then ahStore({ [key.itemID] = best }) end
end

local AH_EVENTS = { REPLICATE_ITEM_LIST_UPDATE = true, AUCTION_ITEM_LIST_UPDATE = true,
                    AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = true, AUCTION_HOUSE_BROWSE_RESULTS_ADDED = true,
                    COMMODITY_SEARCH_RESULTS_UPDATED = true, ITEM_SEARCH_RESULTS_UPDATED = true }
local function ahEvent(event, arg1)
  if event == "AUCTION_HOUSE_SHOW" then ahOpen = true return end
  if event == "AUCTION_HOUSE_CLOSED" then ahOpen = false; ahScanning = nil return end
  if event == "REPLICATE_ITEM_LIST_UPDATE" then if ahScanning == "modern" then ahFinishScan() end return end
  if event == "AUCTION_ITEM_LIST_UPDATE" then
    if ahScanning == "classic" then ahFinishScan() return end
    -- Old AH, normal search: one page of results is the current market for those items.
    local mins = ahReadAll("classic"); ahStore(mins) return
  end
  if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then ahCommodity(arg1) return end
  if event == "ITEM_SEARCH_RESULTS_UPDATED" then ahItemSearch(arg1) return end
  ahBrowse()
end

-- Scanned price for one item (copper per unit) and when it was seen, for itemRec().
local function ahPriceOf(id)
  local db = GrimoireSyncDB.ah
  if id and db and db.p and db.p[id] then return db.p[id], db.at and db.at[id] end
end

-- One item record. bound comes from the container API (Soulbound isn't in a hyperlink tooltip).
local function itemRec(link, count, bound)
  local name, _, quality, ilvl, reqLevel, itype, subType, _, equipLoc, tex, sellPrice = safe(GetItemInfo, link)
  local id = tonumber(link:match("item:(%d+)"))
  local r = { id = id, n = count or 1, name = name, q = quality, ilvl = ilvl, req = reqLevel,
              type = itype, sub = subType, loc = equipLoc, sell = sellPrice, bound = bound and true or nil,
              tex = tonumber(tex),   -- icon file id: the page builds the icon URL from it (Wowhead lacks Forever items)
              tip = tipLines(link) }
  -- Auction price per unit (copper): our own AH scan first (aht = when seen), else Auctionator or TSM if installed.
  r.ah, r.aht = ahPriceOf(id)
  if not r.ah and id and Auctionator and Auctionator.API and Auctionator.API.v1 then
    r.ah = safe(Auctionator.API.v1.GetAuctionPriceByItemLink, "GrimoireSync", link)
        or safe(Auctionator.API.v1.GetAuctionPriceByItemID, "GrimoireSync", id)
  end
  if not r.ah and TSM_API and TSM_API.GetCustomPriceValue and TSM_API.ToItemString then
    local is = safe(TSM_API.ToItemString, link)
    r.ah = is and safe(TSM_API.GetCustomPriceValue, "DBMarket", is) or nil
  end
  return r
end

-- ---- AH shopping data (0.8) ----
-- After a full scan, keep full item records (name, tooltip, icon, exact listing price) for what the page's
-- Market card can recommend: gear this class can wear near its level (cheapest listing per exact link, so
-- "of the Owl" and "of the Bear" stay separate), bags (tooltip says the slot count), potions and herbs.
-- Stored per class in GrimoireSyncDB.ahShop[classFile] = { t, lvl, items = { itemRec + cat } }.
-- Item data may not be cached yet: pass 1 picks candidates via GetItemInfoInstant (always answers) and asks
-- the client to load them; pass 2, 6 seconds later, builds the records with tooltips.
-- classID/subclassID: 0 Consumable (1 potion), 1 Container (0 bag, 1 soul bag), 2 Weapon, 4 Armor, 7 Tradeskill (9 herb).
local GEAR_OK = {
  WARLOCK = { [4] = { [0] = true, [1] = true }, [2] = { [7] = true, [10] = true, [15] = true, [19] = true } },
  PALADIN = { [4] = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [6] = true, [7] = true },
              [2] = { [0] = true, [1] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true } },
}
local SKIP_LOC = { [""] = true, INVTYPE_BODY = true, INVTYPE_TABARD = true, INVTYPE_AMMO = true, INVTYPE_QUIVER = true, INVTYPE_BAG = true }
local SHOP_MAX = 400   -- size cap for the saved file (it is pushed to the public repo on every sync)

local function shopCat(id, cls)
  local _, _, _, loc, _, classID, subID = safe(GetItemInfoInstant, id)
  if not classID then return end
  if classID == 1 and (subID == 0 or subID == 1) then return "b" end
  if classID == 0 and subID == 1 then return "p" end
  if classID == 7 and subID == 9 then return "h" end
  local ok = GEAR_OK[cls] and GEAR_OK[cls][classID]
  if ok and ok[subID] and not SKIP_LOC[loc or ""] then return "g" end
end

ahShopCollect = function(kind, n)
  if not GetItemInfoInstant then ahSay("shopping list: this client has no GetItemInfoInstant."); return end
  local _, cls = safe(UnitClass, "player")
  local L = safe(UnitLevel, "player") or 1
  local best = {}   -- link -> { cat, price }
  for i = (kind == "modern" and 0 or 1), (kind == "modern" and n - 1 or n) do
    local count, buyout, id, lvl
    if kind == "modern" then
      local r = { safe(C_AuctionHouse.GetReplicateItemInfo, i) }; count, lvl, buyout, id = r[3], r[6], r[10], r[17]
    else
      local r = { safe(GetAuctionItemInfo, "list", i) }; count, lvl, buyout, id = r[3], r[6], r[10], r[17]
    end
    -- lvl is the listing's level field (required level on the old AH); a loose window, pass 2 checks the real one.
    if id and buyout and buyout > 0 and (not lvl or lvl == 0 or (lvl <= L + 10 and lvl >= L - 12)) then
      local cat = shopCat(id, cls)
      if cat then
        local link = kind == "modern" and safe(C_AuctionHouse.GetReplicateItemLink, i) or safe(GetAuctionItemLink, "list", i)
        if link then
          local unit = buyout / math.max(count or 1, 1)
          local b = best[link]
          if not b or unit < b.p then best[link] = { cat = cat, p = unit } end
        end
      end
    end
  end
  for link in pairs(best) do safe(GetItemInfo, link) end   -- start loading item data for pass 2
  local function pass2()
    local items = {}
    for link, b in pairs(best) do
      local r = itemRec(link, 1)
      local req = r.req or 0
      -- Gear: required level up to 3 above you (buy ahead), and not junk from 6+ levels ago.
      local keep = r.name and (b.cat ~= "g" or (req <= L + 3 and (req >= L - 6 or (r.ilvl or 0) >= L)))
      if keep and b.cat == "p" and req > L + 3 then keep = false end
      if keep then r.cat = b.cat; r.ah = math.floor(b.p + 0.5); r.aht = time(); items[#items + 1] = r end
    end
    -- Over the cap: keep every bag/potion/herb, then the cheapest gear.
    if #items > SHOP_MAX then
      table.sort(items, function(a, c) if (a.cat == "g") ~= (c.cat == "g") then return c.cat == "g" end return a.ah < c.ah end)
      for i = #items, SHOP_MAX + 1, -1 do items[i] = nil end
    end
    GrimoireSyncDB.ahShop = GrimoireSyncDB.ahShop or {}
    if cls then GrimoireSyncDB.ahShop[cls] = { t = time(), lvl = L, items = items } end
    ahSay(("shopping list ready: %d items (gear, bags, potions, herbs). Type /reload to send it to the site."):format(#items))
  end
  local nCand = 0; for _ in pairs(best) do nCand = nCand + 1 end
  GrimoireSyncDB.ahShopDbg = { t = time(), cand = nCand }
  local function run()
    local ok, err = pcall(pass2)
    if not ok then GrimoireSyncDB.ahShopDbg.err = tostring(err); ahSay("shopping list failed: " .. tostring(err)) end
  end
  if C_Timer and C_Timer.After then C_Timer.After(6, run) else run() end
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
  local bagInfo = {}
  for _, b in ipairs(bags) do
    local name = b == 0 and "Backpack" or (C_Container and C_Container.GetBagName and safe(C_Container.GetBagName, b)) or (GetBagName and safe(GetBagName, b))
    local free, fam
    if C_Container and C_Container.GetContainerNumFreeSlots then free, fam = safe(C_Container.GetContainerNumFreeSlots, b)
    else free, fam = safe(GetContainerNumFreeSlots, b) end
    local size = numSlots(b)
    if size > 0 then bagInfo[#bagInfo + 1] = { bag = b, name = name, size = size, free = free, fam = fam } end
  end
  invState = { time = time(), bags = scanBags(bags), gear = scanGear(), bagInfo = bagInfo }
end

local pendingLevel -- PLAYER_LEVEL_UP passes the new level before UnitLevel updates

-- Where the player stands: uiMapID, its name ("Orgrimmar") and x/y in 0-100 map coords (1 decimal).
-- nil inside instances, where the map API has no position.
local function playerPos()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
  local id = safe(C_Map.GetBestMapForUnit, "player"); if not id then return nil end
  local p = safe(C_Map.GetPlayerMapPosition, id, "player"); if not p then return nil end
  local x, y = p.x, p.y
  if (not x) and p.GetXY then x, y = p:GetXY() end
  if not x or (x == 0 and y == 0) then return nil end
  local info = safe(C_Map.GetMapInfo, id)
  return { map = id, name = info and info.name, x = math.floor(x * 1000 + 0.5) / 10, y = math.floor(y * 1000 + 0.5) / 10 }
end

-- NPCs you interact with (trainer, vendor, bank, flight master, AH, stable, titled gossip NPCs), so the page
-- can pin their real Forever positions on the city/zone maps. Account-wide: both characters fill one list.
local npcTip
local function npcTitle()
  if C_TooltipInfo and C_TooltipInfo.GetUnit then
    local d = safe(C_TooltipInfo.GetUnit, "npc")
    local l = d and d.lines and d.lines[2]
    if l and l.leftText then return l.leftText end
  end
  npcTip = npcTip or CreateFrame("GameTooltip", "GrimoireSyncNpcTip", nil, "GameTooltipTemplate")
  npcTip:SetOwner(WorldFrame, "ANCHOR_NONE"); npcTip:ClearLines(); pcall(npcTip.SetUnit, npcTip, "npc")
  local fs = _G["GrimoireSyncNpcTipTextLeft2"]
  return fs and fs:GetText()
end
local NPC_EVENTS = { TRAINER_SHOW = "t", MERCHANT_SHOW = "v", BANKFRAME_OPENED = "b", TAXIMAP_OPENED = "f",
                     AUCTION_HOUSE_SHOW = "a", PET_STABLE_SHOW = "s", GOSSIP_SHOW = "n" }
local function noteNpc(event)
  local name = safe(UnitName, "npc"); if not name then return end
  local pos = playerPos(); if not pos or not pos.name then return end   -- you stand next to them: close enough
  local title = npcTitle()
  if title and (title:match("^Level ") or title:match("^%?%?")) then title = nil end   -- no <title> line
  local kind = NPC_EVENTS[event]
  if kind == "n" and not title then return end   -- plain quest givers would only clutter the map
  GrimoireSyncDB.npcs = GrimoireSyncDB.npcs or {}
  GrimoireSyncDB.npcs[name .. "@" .. pos.name] = { name = name, title = title, k = kind, map = pos.name, x = pos.x, y = pos.y, t = time() }
end

-- ---- Quest log (0.6) ----
-- scanQuestLog(): every quest in the log with its level, zone header, done state and objective progress.
-- Positions come from what you did, so they are real Forever coordinates:
--   qpos[id].got  = where you stood when you accepted it (the giver; often also the turn-in)
--   qpos[id].prog = up to 8 spots where an objective counter went up (where the mobs/items are)
-- If Questie is loaded, its database adds the turn-in NPC and objective spawns (Classic data, may be off).
local function questObjectives(qid, idx)
  local out = {}
  if C_QuestLog and C_QuestLog.GetQuestObjectives and qid then
    for _, o in ipairs(safe(C_QuestLog.GetQuestObjectives, qid) or {}) do
      out[#out + 1] = { text = o.text, done = o.finished and true or false, have = o.numFulfilled, need = o.numRequired, type = o.type }
    end
  end
  if #out == 0 and GetNumQuestLeaderBoards and idx then
    for j = 1, safe(GetNumQuestLeaderBoards, idx) or 0 do
      local text, typ, done = safe(GetQuestLogLeaderBoard, j, idx)
      if text then
        local have, need = text:match("(%d+)%s*/%s*(%d+)")
        out[#out + 1] = { text = text, done = done and true or false, have = tonumber(have), need = tonumber(need), type = typ }
      end
    end
  end
  return out
end

-- Questie (optional). Module and query names are from Questie's source; everything is pcall'd, so a
-- different Questie version just means no extra data.
local function questieDB()
  if not (QuestieLoader and QuestieLoader.ImportModule) then return end
  local db = safe(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
  local zdb = safe(QuestieLoader.ImportModule, QuestieLoader, "ZoneDB")
  if db and db.QueryNPCSingle and db.QueryQuestSingle then return db, zdb end
end
-- Questie spawns are {[areaId] = {{x, y}, ...}}; keep up to `max` points from the zone with the most.
local function spawnPts(zdb, spawns, max, out)
  if type(spawns) ~= "table" then return end
  local bestA, bestN = nil, 0
  for a, pts in pairs(spawns) do if type(pts) == "table" and #pts > bestN then bestA, bestN = a, #pts end end
  if not bestA then return end
  local ui = zdb and zdb.GetUiMapIdByAreaId and safe(zdb.GetUiMapIdByAreaId, zdb, bestA)
  local info = ui and safe(C_Map.GetMapInfo, ui)
  if not (info and info.name) then return end
  local pts, step, n = spawns[bestA], math.max(1, math.floor(bestN / max)), 0
  for i = 1, #pts, step do
    local p = pts[i]
    if p and p[1] and p[1] >= 0 then
      out[#out + 1] = { map = info.name, x = math.floor(p[1] * 10 + 0.5) / 10, y = math.floor(p[2] * 10 + 0.5) / 10 }
      n = n + 1; if n >= max then break end
    end
  end
end
local function questieInfo(db, zdb, qid)
  local r = {}
  local fin = safe(db.QueryQuestSingle, qid, "finishedBy")
  local npc = fin and fin[1] and fin[1][1]
  if npc then
    local pts = {}
    spawnPts(zdb, safe(db.QueryNPCSingle, npc, "spawns"), 1, pts)
    if pts[1] then r.to = pts[1]; r.to.name = safe(db.QueryNPCSingle, npc, "name") end
  end
  local obj = safe(db.QueryQuestSingle, qid, "objectives")
  if type(obj) == "table" then
    local pts = {}
    for _, c in ipairs(obj[1] or {}) do spawnPts(zdb, safe(db.QueryNPCSingle, c[1], "spawns"), 4, pts) end
    for _, o in ipairs(obj[2] or {}) do if db.QueryObjectSingle then spawnPts(zdb, safe(db.QueryObjectSingle, o[1], "spawns"), 4, pts) end end
    for _, it in ipairs(obj[3] or {}) do
      if db.QueryItemSingle then
        for _, npcId in ipairs(safe(db.QueryItemSingle, it[1], "npcDrops") or {}) do
          spawnPts(zdb, safe(db.QueryNPCSingle, npcId, "spawns"), 3, pts); if #pts >= 10 then break end
        end
      end
    end
    if #pts > 0 then r.pts = pts end
  end
  return r
end

local questState, lastProgress = nil, {}
local function scanQuestLog()
  local list, header, collapsed = {}, nil, 0
  local n = (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and safe(C_QuestLog.GetNumQuestLogEntries))
            or safe(GetNumQuestLogEntries) or 0
  local db, zdb = questieDB()
  GrimoireSyncDB.qpos = GrimoireSyncDB.qpos or {}
  local here = playerPos()
  for i = 1, n do
    local title, level, isHeader, isCollapsed, complete, qid
    local info = C_QuestLog and C_QuestLog.GetInfo and safe(C_QuestLog.GetInfo, i)
    if info then
      title, level, isHeader, isCollapsed, qid = info.title, info.level, info.isHeader, info.isCollapsed, info.questID
      if not isHeader and qid and C_QuestLog.IsComplete then complete = safe(C_QuestLog.IsComplete, qid) and 1 or nil end
      if not isHeader and qid and C_QuestLog.IsFailed and safe(C_QuestLog.IsFailed, qid) then complete = -1 end
    else
      local _
      title, level, _, isHeader, isCollapsed, complete, _, qid = safe(GetQuestLogTitle, i)
    end
    if isHeader then
      header = title
      if isCollapsed then collapsed = collapsed + 1 end   -- quests under a collapsed header aren't listed
    elseif title then
      local obj = questObjectives(qid, i)
      local q = { id = qid, title = title, level = level, zone = header, obj = obj,
                  done = complete == 1 or complete == true, failed = complete == -1 }
      -- Objective counter went up since the last scan: remember where you were (that's where it drops/spawns).
      if qid and here then
        local sum = 0; for _, o in ipairs(obj) do sum = sum + (tonumber(o.have) or 0) + (o.done and 1 or 0) end
        local qp = GrimoireSyncDB.qpos[qid] or {}
        if lastProgress[qid] and sum > lastProgress[qid] then
          qp.prog = qp.prog or {}
          table.insert(qp.prog, { map = here.name, x = here.x, y = here.y })
          if #qp.prog > 8 then table.remove(qp.prog, 1) end
        end
        lastProgress[qid] = sum
        GrimoireSyncDB.qpos[qid] = qp
      end
      if db and qid then
        local ok, qi = pcall(questieInfo, db, zdb, qid)
        if ok and qi then q.to, q.pts = qi.to, qi.pts end
      end
      list[#list + 1] = q
    end
  end
  -- Forget positions of quests that left the log (turned in or abandoned) so the file doesn't grow forever.
  local inLog = {}; for _, q in ipairs(list) do if q.id then inLog[q.id] = true end end
  for id in pairs(GrimoireSyncDB.qpos) do if not inLog[id] then GrimoireSyncDB.qpos[id] = nil end end
  for _, q in ipairs(list) do if q.id then q.pos = GrimoireSyncDB.qpos[q.id] end end
  questState = { t = time(), list = list, collapsed = collapsed, questie = db and true or false }
end
-- QUEST_ACCEPTED: you're standing at the giver. arg is questID on modern clients, log index on old ones.
local function noteQuestAccepted(a1, a2)
  local qid = (type(a2) == "number" and a2) or a1
  if not qid then return end
  if not a2 and GetQuestLogTitle and a1 and a1 < 100 then qid = select(8, safe(GetQuestLogTitle, a1)) or qid end
  local here = playerPos(); if not here then return end
  GrimoireSyncDB.qpos = GrimoireSyncDB.qpos or {}
  local qp = GrimoireSyncDB.qpos[qid] or {}
  qp.got = { map = here.name, x = here.x, y = here.y, npc = safe(UnitName, "npc") }
  GrimoireSyncDB.qpos[qid] = qp
end

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
    pos = playerPos(),
    npcs = GrimoireSyncDB.npcs,
    money = safe(GetMoney),
    quests = countCompletedQuests(),
    demons = scanDemons(),
    profs = scanProfessions(),
    profMax = profMax,
    crafts = GrimoireSyncDB.crafts,
    qlog = questState,
    talents = scanTalents(),
    spells = scanSpells(),
    time = time(),
    inv = invState,
    -- AH scan summary only; the full price table stays in GrimoireSyncDB.ah (account-wide, read by the page too).
    ahInfo = GrimoireSyncDB.ah and { full = GrimoireSyncDB.ah.full, t = GrimoireSyncDB.ah.t, n = GrimoireSyncDB.ah.n } or nil,
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
for e in pairs(NPC_EVENTS) do pcall(f.RegisterEvent, f, e) end
-- Profession window: LIST_UPDATE fires again once recipes load and after each craft (colours change).
local CRAFT_EVENTS = { TRADE_SKILL_SHOW = true, TRADE_SKILL_LIST_UPDATE = true, TRADE_SKILL_UPDATE = true }
for e in pairs(CRAFT_EVENTS) do pcall(f.RegisterEvent, f, e) end
-- Quest log: QUEST_LOG_UPDATE fires in bursts (every kill, every loot), so the rescan is debounced to 1s.
local QUEST_EVENTS = { QUEST_LOG_UPDATE = true, QUEST_ACCEPTED = true, QUEST_REMOVED = true }
for e in pairs(QUEST_EVENTS) do pcall(f.RegisterEvent, f, e) end
local questPending = false
local function queueQuest()
  if questPending then return end
  questPending = true
  local run = function() questPending = false; pcall(scanQuestLog); pcall(snapshot, "quests") end
  if C_Timer and C_Timer.After then C_Timer.After(1, run) else run() end
end
pcall(f.RegisterEvent, f, "GET_ITEM_INFO_RECEIVED")
-- AH price events; pcall because each client has only one of the two AH APIs.
for e in pairs(AH_EVENTS) do pcall(f.RegisterEvent, f, e) end
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
f:SetScript("OnEvent", function(_, event, arg1, arg2)
  if AH_EVENTS[event] then pcall(ahEvent, event, arg1) return end
  -- AH open/close also feed the NPC map and the bag rescan below, so they fall through.
  if event == "AUCTION_HOUSE_SHOW" or event == "AUCTION_HOUSE_CLOSED" then pcall(ahEvent, event) end
  if QUEST_EVENTS[event] then
    if event == "QUEST_ACCEPTED" then pcall(noteQuestAccepted, arg1, arg2) end
    queueQuest(); return
  end
  if CRAFT_EVENTS[event] then pcall(scanTradeSkill); pcall(snapshot, event); return end
  if NPC_EVENTS[event] then pcall(noteNpc, event) end
  if event ~= "BANKFRAME_OPENED" and NPC_EVENTS[event] then return end
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
  if event == "PLAYER_ENTERING_WORLD" and C_Timer and C_Timer.After then C_Timer.After(4, queueInv); C_Timer.After(5, queueQuest) end
  snapshot(event)
end)

SLASH_GRIMOIRESYNC1 = "/grimoire"
SlashCmdList.GRIMOIRESYNC = function(msg)
  if msg and msg:lower():match("^%s*scan") then ahStartScan() return end
  snapshot()
  local s = GrimoireSyncDB.last
  if not s then print("|cff8fdc5aGrimoire Sync|r no data yet, try again in a few seconds.") return end
  local nInv = s.inv and #s.inv.bags or 0
  print(("|cff8fdc5aGrimoire Sync|r %s level %s in %s, %d class milestone(s), %d bag item(s). Type /reload to write the file now.")
    :format(tostring(s.class), tostring(s.level), tostring(s.zone), #s.demons, nInv))
  local ah = GrimoireSyncDB.ah
  print(ah and ah.n and ("  AH prices: %d items. Open the AH and type /grimoire scan to refresh."):format(ah.n)
        or "  No AH prices yet: open the Auction House and type /grimoire scan.")
end
