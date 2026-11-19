-- TransmogSweep
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Lists the transmog appearances on the auction house you have not collected yet, as a
-- tab of the auction house window. It asks the auction house only for weapons and armor
-- (one search, grouped by item), so a scan takes seconds and can run any time.
-- Collected is account-wide: a look learned on any character counts.
-- Every purchase needs a click of its own.

local ADDON, ns = ...
local L = setmetatable({}, { __index = function(_, key) return key end })
ns.L = L

local AH = C_AuctionHouse
local TC = C_TransmogCollection
local GetItemInfo = C_Item.GetItemInfo
local GetItemInfoInstant = C_Item.GetItemInfoInstant
local GetMetadata = C_AddOns and C_AddOns.GetAddOnMetadata
-- a global by name (game strings and frames that may not exist on every client)
local function Global(name) return _G[name] end
local floor, min, max = math.floor, math.min, math.max

local VERSION = GetMetadata and GetMetadata(ADDON, "Version") or ""
if VERSION == "" or VERSION:find("^@") then VERSION = "dev" end

local PREFIX = "|cffa335eeTransmogSweep:|r "
local BUG_URL = "https://github.com/Bencepo/TransmogSweep/issues/new/choose"
local SCAN_WAIT = 20            -- seconds a scan waits for an answer of the auction house
local INFO_WAIT = 15            -- seconds a scan waits for item data still loading
local KEEP_SCAN = 60 * 60       -- a saved scan is shown again for an hour
local KEEP_BOUGHT = 14 * 86400  -- bought appearances stay hidden this long (or until learned)
local ROW_HEIGHT = 22
local MAX_ROWS = 30
local BUY_WAIT = 6              -- seconds a price check waits for the auction house
local SORTS = { { sortOrder = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false } }

local defaults = {
	unique = true,       -- one row per appearance (cheapest item that has it)
	classOnly = false,   -- only items your class can wear
	aboveLevel = false,  -- hide items above your level
	hideBought = true,   -- hide appearances bought until they are learned
	slot = "all",
	color = "any",
	maxGold = 0,         -- 0: no price limit
	search = "",
}

local db
local items = {}        -- sourceID -> entry of the last scan
local view = {}         -- entries listed after filters and sorting
local listed = 0        -- transmog items in the last scan
local dataAt            -- time() the auctions were read
local scan = { active = false }
local buy = {}
local keyStyle = {}     -- itemID -> "plain": found with the plain item key
local selected
local offset = 0
local ahOpen = false
local dirty = true
local ui, settingsWin
local known = { src = {}, vis = {} } -- collected status, cleared when the collection changes
local statusText = ""

local function Print(msg) print(PREFIX .. tostring(msg)) end

-- What happened during the last purchases, for the diagnosis and bug reports.
local log = {}
local function Log(fmt, ...)
	local ok, text = pcall(string.format, fmt, ...)
	log[#log + 1] = ("%.2f  %s"):format(GetTime(), ok and text or fmt)
	if #log > 60 then table.remove(log, 1) end
end
ns.log = log

local function Money(copper)
	copper = floor((copper or 0) + 0.5)
	if GetMoneyString then return GetMoneyString(copper, true) end
	local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
	return (g > 0 and (g .. "g ") or "") .. ((g > 0 or s > 0) and (s .. "s ") or "") .. c .. "c"
end

local function Ago(t)
	local s = time() - (t or 0)
	if s < 60 then return L["just now"] end
	if s < 3600 then return L["%d min ago"]:format(floor(s / 60)) end
	return L["%d h ago"]:format(floor(s / 3600))
end

local Redraw
local function SetStatus(msg)
	statusText = msg or ""
	if ui then ui.status:SetText(statusText) end
end

---------------------------------------------------------------------------
-- Slots, armor and weapon types
---------------------------------------------------------------------------

local SLOT_OF = {
	INVTYPE_HEAD = "head", INVTYPE_SHOULDER = "shoulder", INVTYPE_CLOAK = "back",
	INVTYPE_CHEST = "chest", INVTYPE_ROBE = "chest", INVTYPE_BODY = "shirt", INVTYPE_TABARD = "tabard",
	INVTYPE_WRIST = "wrist", INVTYPE_HAND = "hands", INVTYPE_WAIST = "waist", INVTYPE_LEGS = "legs",
	INVTYPE_FEET = "feet",
	INVTYPE_WEAPON = "weapon", INVTYPE_2HWEAPON = "weapon", INVTYPE_WEAPONMAINHAND = "weapon",
	INVTYPE_RANGED = "weapon", INVTYPE_RANGEDRIGHT = "weapon", INVTYPE_THROWN = "weapon",
	INVTYPE_WEAPONOFFHAND = "offhand", INVTYPE_SHIELD = "offhand", INVTYPE_HOLDABLE = "offhand",
}
local SLOTS = {
	{ "all", L["All slots"] }, { "head", L["Head"] }, { "shoulder", L["Shoulder"] }, { "back", L["Back"] },
	{ "chest", L["Chest"] }, { "shirt", L["Shirt"] }, { "tabard", L["Tabard"] }, { "wrist", L["Wrist"] },
	{ "hands", L["Hands"] }, { "waist", L["Waist"] }, { "legs", L["Legs"] }, { "feet", L["Feet"] },
	{ "weapon", L["Weapons"] }, { "offhand", L["Off-hands & shields"] },
}

-- Armor types a class wears (1 cloth, 2 leather, 3 mail, 4 plate): the classes that
-- change at level 40 keep both, so you can collect for later.
local ARMOR = {
	WARRIOR = { [3] = true, [4] = true }, PALADIN = { [3] = true, [4] = true },
	HUNTER = { [2] = true, [3] = true }, SHAMAN = { [2] = true, [3] = true },
	ROGUE = { [2] = true }, DRUID = { [2] = true },
	PRIEST = { [1] = true }, MAGE = { [1] = true }, WARLOCK = { [1] = true },
}
local SHIELD = { WARRIOR = true, PALADIN = true, SHAMAN = true }
-- Weapon subclasses: 0 1h axe, 1 2h axe, 2 bow, 3 gun, 4 1h mace, 5 2h mace, 6 polearm,
-- 7 1h sword, 8 2h sword, 10 staff, 13 fist, 15 dagger, 16 thrown, 18 crossbow, 19 wand
local function set(...)
	local t = {}
	for _, v in ipairs({ ... }) do t[v] = true end
	return t
end
local WEAPONS = {
	WARRIOR = set(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 13, 15, 16, 18),
	PALADIN = set(0, 1, 4, 5, 6, 7, 8),
	HUNTER = set(0, 1, 2, 3, 6, 7, 8, 10, 13, 15, 16, 18),
	ROGUE = set(2, 3, 4, 7, 13, 15, 16, 18),
	PRIEST = set(4, 10, 15, 19),
	SHAMAN = set(0, 1, 4, 5, 10, 13, 15),
	MAGE = set(7, 10, 15, 19),
	WARLOCK = set(7, 10, 15, 19),
	DRUID = set(4, 5, 10, 13, 15),
}

local function ClassFits(e)
	local _, class = UnitClass("player")
	if TC.PlayerCanCollectSource then
		local ok, hasData, can = pcall(TC.PlayerCanCollectSource, e.source)
		if ok and hasData and not can then return false end
	end
	if e.class == 4 then
		-- cloaks, shirts, tabards, off-hand frills and cosmetics fit everyone
		if e.inv == "INVTYPE_CLOAK" or e.sub == 0 or e.sub == 5 then return true end
		if not ARMOR[class] then return true end -- a class this table does not know
		if e.sub == 6 then return SHIELD[class] or false end
		return ARMOR[class][e.sub] or false
	elseif e.class == 2 then
		local w = WEAPONS[class]
		if not w then return true end
		return w[e.sub] or e.sub == 20 or false -- fishing poles fit everyone
	end
	return true
end

---------------------------------------------------------------------------
-- Collected or not
---------------------------------------------------------------------------

-- Can your account collect this source at all? The game says no for looks that are
-- already settled for you (the tooltip then shows no collection line). nil: data not loaded.
local collectable = {}
local function Collectable(source)
	local c = collectable[source]
	if c ~= nil then return c end
	if not TC.AccountCanCollectSource then return true end
	local ok, hasData, can = pcall(TC.AccountCanCollectSource, source)
	if not ok then return true end
	if not hasData then return nil end
	collectable[source] = can and true or false
	return collectable[source]
end

local function SourceKnown(source)
	local c = known.src[source]
	if c ~= nil then return c end
	local k = false
	local ok, info = pcall(TC.GetSourceInfo, source)
	if ok and type(info) == "table" and info.isCollected then k = true end
	if not k and TC.PlayerHasTransmogItemModifiedAppearance then
		local ok2, has = pcall(TC.PlayerHasTransmogItemModifiedAppearance, source)
		if ok2 and has then k = true end
	end
	if not k and type(info) == "table" and info.itemID then
		if TC.PlayerHasTransmog then
			local ok3, has = pcall(TC.PlayerHasTransmog, info.itemID, info.itemModID or 0)
			if ok3 and has then k = true end
		end
		if not k and TC.PlayerHasTransmogByItemInfo then
			local ok4, has = pcall(TC.PlayerHasTransmogByItemInfo, info.itemID)
			if ok4 and has then k = true end
		end
	end
	known.src[source] = k
	return k
end

-- Is the look known through any item that has it?
local function VisualKnown(e)
	local v = e.visual
	if not v then return SourceKnown(e.source) end
	local c = known.vis[v]
	if c ~= nil then return c end
	local k = SourceKnown(e.source)
	if not k and TC.GetAppearanceInfoBySource then
		local ok, a = pcall(TC.GetAppearanceInfoBySource, e.source)
		if ok and type(a) == "table" and a.appearanceIsCollected then k = true end
	end
	if not k then
		local ok, sources = pcall(TC.GetAllAppearanceSources, v)
		if ok and type(sources) == "table" then
			for _, s in ipairs(sources) do
				if SourceKnown(s) then
					k = true
					break
				end
			end
		end
	end
	known.vis[v] = k
	return k
end

-- The game's own verdict, read from the item tooltip (the lines every player sees):
-- "unknown" look not collected, "other" look known through another item, "known".
-- nil: the tooltip had no say (data not loaded), the collection API decides.
local TIP_UNKNOWN = Global("TRANSMOGRIFY_TOOLTIP_APPEARANCE_UNKNOWN") or "You haven't collected this appearance"
local TIP_OTHER = Global("TRANSMOGRIFY_TOOLTIP_ITEM_UNKNOWN_APPEARANCE_KNOWN") or "You've collected this appearance, but not from this item"
local TIP_KNOWN = Global("TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN")
---@type GameTooltip
local scanTip

local function TipLines(itemID)
	local lines = {}
	if C_TooltipInfo and C_TooltipInfo.GetItemByID then
		local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
		if ok and data and data.lines then
			for _, line in ipairs(data.lines) do
				if TooltipUtil and TooltipUtil.SurfaceArgs and not line.leftText then pcall(TooltipUtil.SurfaceArgs, line) end
				if line.leftText then lines[#lines + 1] = line.leftText end
			end
			if lines[1] then return lines end
		end
	end
	if not scanTip then
		scanTip = CreateFrame("GameTooltip", "TransmogSweepScanTip", nil, "GameTooltipTemplate") --[[@as GameTooltip]]
	end
	scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	scanTip:ClearLines()
	scanTip:SetItemByID(itemID)
	for i = 1, scanTip:NumLines() do
		local fs = _G["TransmogSweepScanTipTextLeft" .. i]
		local text = fs and fs:GetText()
		if text then lines[#lines + 1] = text end
	end
	scanTip:Hide()
	return lines
end

local function TipState(itemID)
	local lines = TipLines(itemID)
	if not lines[1] or lines[1] == "" or lines[1] == RETRIEVING_ITEM_INFO then return nil end
	for _, text in ipairs(lines) do
		if text == TIP_UNKNOWN then return "unknown" end
		if text == TIP_OTHER then return "other" end
		if TIP_KNOWN and text == TIP_KNOWN then return "known" end
	end
	return "known" -- loaded tooltip without a "not collected" line
end

-- items whose tooltip was not ready during the scan are asked again while the list is
-- built, a few hundred per build so the frame rate holds
local tipBudget = 0
local function AskTip(e)
	if e.tip == nil and tipBudget > 0 and not db.tipFallback then
		tipBudget = tipBudget - 1
		e.tip = TipState(e.id)
	end
end

local function LookMissing(e)
	if Collectable(e.source) == false then return false end
	AskTip(e)
	if e.tip then return e.tip == "unknown" end
	return not VisualKnown(e)
end

local function SourceMissing(e)
	if Collectable(e.source) == false then return false end
	AskTip(e)
	if e.tip then return e.tip ~= "known" end
	return not SourceKnown(e.source)
end

local function HideKey(e) return e.visual and ("v" .. e.visual) or ("s" .. e.source) end

local function Bought(e)
	if not db.hideBought then return false end
	return db.bought[e.source] or (db.unique and e.visual and db.bought["v" .. e.visual]) or false
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

local SORT_FIELDS = {
	name = function(e) return (e.name or ""):lower() end,
	slot = function(e) return e.inv or "" end,
	type = function(e) return e.subName or "" end,
	level = function(e) return e.req or 0 end,
	count = function(e) return e.n or 0 end,
	price = function(e) return e.price or 0 end,
}

local function SortView()
	local s = db.sort or { key = "price" }
	local get = SORT_FIELDS[s.key] or SORT_FIELDS.price
	table.sort(view, function(a, b)
		local x, y = get(a), get(b)
		if x == y then
			-- a fixed order for ties (same price, same slot …): the list must not reshuffle
			-- between two builds, or "the next row" changes under the cursor
			if (a.price or 0) ~= (b.price or 0) then return (a.price or 0) < (b.price or 0) end
			if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
			return a.source < b.source
		end
		if s.desc then return x > y end
		return x < y
	end)
end

-- WoW gives addons no colour of an item. The names do: "Crimson Silk Robe", "Black Mageweave
-- Leggings". A colour matches when the name of the item, or of any item with the same look,
-- holds one of its words.
local COLORS = {
	{ "any", L["Any colour"] },
	{ "red", L["Red"], { "red", "crimson", "scarlet", "blood", "ruby", "flame", "fire", "burning", "cardinal" } },
	{ "blue", L["Blue"], { "blue", "azure", "sapphire", "frost", "ice", "sky", "tide", "cobalt", "ocean" } },
	{ "green", L["Green"], { "green", "emerald", "jade", "verdant", "forest", "moss", "nature" } },
	{ "black", L["Black"], { "black", "shadow", "dark", "ebon", "night", "obsidian", "midnight", "onyx" } },
	{ "white", L["White"], { "white", "silver", "pale", "frost", "moonlight", "ivory", "snow", "holy" } },
	{ "gold", L["Gold & yellow"], { "gold", "golden", "yellow", "sun", "amber", "bronze", "brass" } },
	{ "purple", L["Purple"], { "purple", "violet", "amethyst", "arcane", "twilight", "royal", "felcloth" } },
	{ "brown", L["Brown"], { "brown", "leather", "hide", "earth", "russet", "tanned", "bark" } },
	{ "gray", L["Gray"], { "gray", "grey", "iron", "steel", "stone", "ashen", "silver" } },
}
local lookNames = {} -- look -> the names of all items with it, lower case

local function LookText(e)
	local key = e.visual or e.source
	local t = lookNames[key]
	if t then return t end
	local parts = { (e.name or ""):lower() }
	if e.visual then
		local ok, sources = pcall(TC.GetAllAppearanceSources, e.visual)
		if ok and type(sources) == "table" then
			for i, src in ipairs(sources) do
				if i > 30 then break end
				local ok2, info = pcall(TC.GetSourceInfo, src)
				if ok2 and type(info) == "table" and info.name then parts[#parts + 1] = info.name:lower() end
			end
		end
	end
	t = table.concat(parts, " | ")
	lookNames[key] = t
	return t
end

local function ColorFits(e)
	if not db.color or db.color == "any" then return true end
	for _, c in ipairs(COLORS) do
		if c[1] == db.color then
			local text = " " .. LookText(e):gsub("[^%a]", " ") .. " "
			for _, w in ipairs(c[3]) do
				if text:find(" " .. w .. " ", 1, true) then return true end
			end
			return false
		end
	end
	return true
end
ns.ColorFits = ColorFits

local function BuildView()
	wipe(view)
	tipBudget = 300
	local level = UnitLevel("player") or 0
	local search = (db.search or ""):lower()
	local maxPrice = (db.maxGold or 0) * 10000
	local best, sameLook = {}, {}
	for _, e in pairs(items) do
		local slot = not e.pending and SLOT_OF[e.inv]
		if slot and (db.slot == "all" or slot == db.slot)
			and (maxPrice <= 0 or e.price <= maxPrice)
			and not (db.aboveLevel and (e.req or 0) > level)
			and not db.hidden[HideKey(e)]
			and (search == "" or (e.name or ""):lower():find(search, 1, true) or LookText(e):find(search, 1, true))
			and ColorFits(e)
			and not Bought(e)
			and (not db.classOnly or ClassFits(e)) then
			if db.unique then
				if LookMissing(e) then
					local k = HideKey(e)
					sameLook[k] = (sameLook[k] or 0) + 1
					if not best[k] or e.price < best[k].price then best[k] = e end
				end
			elseif SourceMissing(e) then
				e.alts = nil
				view[#view + 1] = e
			end
		end
	end
	for k, e in pairs(best) do
		e.alts = sameLook[k] - 1
		view[#view + 1] = e
	end
	SortView()
	dirty = false
end

local function Changed()
	dirty = true
	offset = 0
	if Redraw then Redraw() end
	if settingsWin then settingsWin:Refresh() end
end
ns.Changed = Changed

---------------------------------------------------------------------------
-- Scan: one browse search for weapons and armor, grouped by item
---------------------------------------------------------------------------

local function BrowseQuery()
	local filters = {}
	for _, name in ipairs({ "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality", "EpicQuality", "LegendaryQuality" }) do
		local v = Enum.AuctionHouseFilter and Enum.AuctionHouseFilter[name]
		if v ~= nil then filters[#filters + 1] = v end
	end
	return { searchString = "", minLevel = 0, maxLevel = 0, filters = filters,
		itemClassFilters = { { classID = 2 }, { classID = 4 } }, sorts = SORTS }
end

local function KeyString(key)
	return (key.itemID or 0) .. ":" .. (key.itemLevel or 0) .. ":" .. (key.itemSuffix or 0)
end

-- The appearance source of an auction key: from the auction house's own item data (it
-- knows random suffixes), else from the item.
local function SourceOf(key, info)
	local _, source = TC.GetItemInfo(key.itemID)
	if source then return source end
	local link = info and info.appearanceLink
	local id = link and tonumber(link:match("transmogappearance:(%d+)"))
	if id and id > 0 then
		local ok, sInfo = pcall(TC.GetSourceInfo, id)
		if ok and type(sInfo) == "table" and sInfo.itemID == key.itemID then return id end
	end
	return nil
end

-- One browse result. Returns false while its item data is still loading.
local function Record(result)
	local key, price = result.itemKey, result.minPrice
	if not key or not key.itemID or not price or price <= 0 then return true end
	local _, _, subName, inv, icon, classID, subID = GetItemInfoInstant(key.itemID)
	if (classID ~= 2 and classID ~= 4) or not SLOT_OF[inv] then return true end
	local info = AH.GetItemKeyInfo and AH.GetItemKeyInfo(key)
	if not info then return false end
	local source = SourceOf(key, info)
	if not source then
		if not GetItemInfo(key.itemID) then return false end
		return true -- no appearance of its own
	end
	local can = Collectable(source)
	if can == nil then return false end -- still loading
	if not can then return true end    -- nothing to collect for you
	local sInfo = select(2, pcall(TC.GetSourceInfo, source))
	local visual = type(sInfo) == "table" and sInfo.visualID or select(1, TC.GetItemInfo(key.itemID))
	local _, link, q, _, req, _, _, _, _, tex = GetItemInfo(key.itemID)
	req = (AH.GetItemKeyRequiredLevel and AH.GetItemKeyRequiredLevel(key)) or req or 0
	local n = result.totalQuantity or 1
	scan.listed = scan.listed + n
	local e = scan.items[source]
	if not e then
		e = { source = source, visual = visual, id = key.itemID, key = key, link = link,
			name = info.itemName or (link and link:match("%[(.-)%]")), icon = info.iconFileID or tex or icon,
			quality = q or info.quality, inv = inv, class = classID, sub = subID, subName = subName,
			req = req, price = price, n = 0 }
		scan.items[source] = e
	end
	e.n = e.n + n
	if price < e.price then e.price, e.key, e.req = price, key, req end
	return true
end

local function Process(results)
	if type(results) ~= "table" then return end
	for _, result in ipairs(results) do
		local k = result.itemKey and KeyString(result.itemKey)
		if k and not scan.seen[k] then
			scan.seen[k] = true
			scan.read = scan.read + 1
			if not Record(result) then
				scan.pending[#scan.pending + 1] = result
				if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(result.itemKey.itemID) end
			end
		end
	end
end

local function SaveScan()
	db.last = { v = 2, at = dataAt, listed = listed, items = items }
end

local function FinishScan(failed)
	scan.active = false
	if failed then
		SetStatus(L["The auction house did not answer. Try again in a moment."])
		Redraw()
		return
	end
	items, listed, dataAt = scan.items, scan.listed, time()
	scan.items, scan.pending, scan.seen, scan.verify = nil, nil, nil, nil
	SaveScan()
	if buy.state or selected then
		-- buying is under way: keep the list where it is
		dirty = true
		Redraw()
	else
		Changed()
	end
	SetStatus(L["Scan done: %d uncollected appearances among %d items of gear."]:format(#view, listed))
end

local function StartScan()
	if not ahOpen or scan.active or buy.state == "buying" then return end
	wipe(buy)
	wipe(scan)
	scan.active, scan.phase, scan.t = true, "send", GetTime()
	scan.items, scan.pending, scan.seen, scan.listed, scan.read = {}, {}, {}, 0, 0
	SetStatus(L["Scanning weapons and armor …"])
	Redraw()
end

-- the browse list is complete: ask for the next part, or finish
local function Continue()
	scan.t = GetTime()
	if AH.HasFullBrowseResults() then
		scan.phase, scan.loadT, scan.progressT = "loading", GetTime(), GetTime()
	else
		scan.phase = "more"
	end
	SetStatus(L["Scanning … %d items read"]:format(scan.read))
end

local function ScanTick(now)
	local ready = AH.IsThrottledMessageSystemReady()
	if scan.phase == "send" then
		if ready or now - scan.t > 10 then
			scan.phase, scan.t = "wait", now
			AH.SendBrowseQuery(BrowseQuery())
		end
	elseif scan.phase == "more" then
		if ready or now - scan.t > 10 then
			scan.phase, scan.t = "wait", now
			AH.RequestMoreBrowseResults()
		end
	elseif scan.phase == "wait" then
		if now - scan.t > SCAN_WAIT then
			-- no answer: use what arrived, if anything
			if scan.read > 0 then scan.phase, scan.loadT, scan.progressT = "loading", now, now else FinishScan(true) end
		end
	elseif scan.phase == "loading" then
		-- items whose data had not loaded yet
		local still = {}
		for _, result in ipairs(scan.pending) do
			if not Record(result) then still[#still + 1] = result end
		end
		if #still < #scan.pending then scan.progressT = now end
		scan.pending = still
		if still[1] and now - scan.loadT < 60 and now - scan.progressT < INFO_WAIT then
			SetStatus(L["Loading item data (%d left) …"]:format(#still))
		else
			-- Looks the tooltip already called known (or known through another item) stay
			-- so: only the rest is asked. The list shows up right away and fills while
			-- the check runs; rows still being checked are left out until they are done.
			scan.phase, scan.verify, scan.vi, scan.cached = "verify", {}, 0, 0
			for _, e in pairs(scan.items) do
				local c = db.tipCache[e.id]
				if c then
					e.tip, scan.cached = c, scan.cached + 1
				else
					e.pending = true
					scan.verify[#scan.verify + 1] = e
				end
			end
			items, listed, dataAt = scan.items, scan.listed, time()
			scan.shownAt = now
			dirty = true
		end
	elseif scan.phase == "verify" then
		-- ask the game's tooltip, about 8 ms per tick so the frame rate holds
		local stop = debugprofilestop() + 8
		local list = scan.verify
		while scan.vi < #list and debugprofilestop() < stop do
			scan.vi = scan.vi + 1
			local e = list[scan.vi]
			e.tip, e.pending = TipState(e.id), nil
		end
		if not buy.state then SetStatus(L["Checking your collection (%d of %d) … you can start buying"]:format(scan.vi, #list)) end
		if now - (scan.shownAt or 0) > 0.5 then
			-- the list grows while the check runs, without moving the row being bought
			scan.shownAt = now
			dirty = true
			Redraw()
		end
		if scan.vi >= #list then
			-- no tooltip says "not collected" at all: the client shows no transmog lines
			-- (e.g. transmog switched off for this character). Then the collection API decides.
			local said = 0
			for _, e in ipairs(list) do
				if e.tip == "unknown" or e.tip == "other" then said = said + 1 end
			end
			db.tipFallback = nil
			if said == 0 and #list > 20 and scan.cached == 0 then
				for _, e in ipairs(list) do e.tip = nil end
				db.tipFallback = true
			else
				-- remember the settled verdicts: a collected look never becomes uncollected
				for _, e in ipairs(list) do
					if e.tip == "known" or e.tip == "other" then db.tipCache[e.id] = e.tip end
				end
			end
			FinishScan()
		end
	end
end

---------------------------------------------------------------------------
-- Price check and purchase
---------------------------------------------------------------------------

local function ItemKey(e, plain)
	local make = AH.MakeItemKey
	if not plain and e.key then return e.key end
	if not make then return { itemID = e.id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end
	return make(e.id)
end

local function Check(e, pause, tried)
	if not ahOpen or (scan.active and scan.phase ~= "verify") or buy.state == "buying" then return end
	selected = e
	wipe(buy)
	buy.pause, buy.keepTried = pause, tried
	buy.e, buy.state, buy.t, buy.tried = e, "send", GetTime(), buy.keepTried or {}
	buy.notBefore = buy.pause and (GetTime() + buy.pause) or nil
	buy.keepTried, buy.pause = nil, nil
	buy.plain = keyStyle[e.id] == "plain" or not e.key
	buy.key = ItemKey(e, buy.plain)
	SetStatus(L["Checking %s …"]:format(e.link or e.name or "?"))
	Redraw()
end

-- Removes an item from the list and returns the row that moves up into its place
-- (the one shown right below it), or the last row if it was the last.
local function RemoveAndNext(e)
	local pos
	for i, x in ipairs(view) do
		if x == e then
			pos = i
			break
		end
	end
	-- only this row leaves: the order of the others stays, no rebuild needed
	items[e.source] = nil
	if selected == e then selected = nil end
	if not pos then
		dirty = true
		BuildView()
		return view[1]
	end
	table.remove(view, pos)
	return view[pos] or view[#view]
end

local scrollTo = false

local function ReadOffer()
	local e, key = buy.e, buy.key
	local best
	local total = AH.GetNumItemSearchResults(key)
	-- an empty answer is asked once more before the item counts as gone
	if total == 0 and not buy.retried then
		buy.retried, buy.state, buy.t, buy.notBefore = true, "send", GetTime(), GetTime() + 1.5
		Log("no results for %s, asking again", tostring(e.name))
		return
	end
	for i = 1, total do
		local info = AH.GetItemSearchResultInfo(key, i)
		if info and info.auctionID and (info.buyoutAmount or 0) > 0 and not info.containsOwnerItem
			and not buy.tried[info.auctionID] then
			local _, source = TC.GetItemInfo(info.itemLink or e.id)
			local visual = source and source ~= e.source and db.unique and select(2, pcall(TC.GetSourceInfo, source))
			visual = type(visual) == "table" and visual.visualID
			local sameItem = info.itemKey and info.itemKey.itemID == e.id
			if sameItem or source == e.source or (visual and visual == e.visual) then
				if not best or info.buyoutAmount < best.buyoutAmount then best = info end
			end
		end
	end
	Log("results %s: %d auctions, best %s", tostring(e.name), total, best and (best.auctionID .. " @ " .. best.buyoutAmount) or "none")
	if best then
		if buy.plain then keyStyle[e.id] = "plain" end
		buy.state, buy.auctionID, buy.price, buy.link = "ready", best.auctionID, best.buyoutAmount, best.itemLink or e.link
		-- the list keeps the scanned price: changing it here would re-sort the list and
		-- move the row being bought away from the cursor
		SetStatus(L["%s for %s. Click Buy."]:format(buy.link, Money(buy.price)))
	elseif not buy.plain then
		-- the key built from the item link found nothing: the plain item key may be the one in use
		buy.plain, buy.key, buy.state, buy.t, buy.retried = true, ItemKey(e, true), "send", GetTime(), nil
		return
	else
		-- gone: on to the next item of the list
		local nextOne = RemoveAndNext(e)
		wipe(buy)
		Log("skipped %s", tostring(e.name))
		Print(L["Skipped %s: no auction with a buyout left."]:format(e.link or e.name or "?"))
		SetStatus(L["%s is no longer listed."]:format(e.link or e.name or "?"))
		if nextOne then
			scrollTo = true
			Check(nextOne)
			return
		end
	end
	Redraw()
end

local function BuyTick(now)
	if buy.state == "send" then
		if buy.notBefore and now < buy.notBefore then return end
		if AH.IsThrottledMessageSystemReady() or now - buy.t > 10 then
			buy.state, buy.t, buy.gotAt = "wait", now, nil
			Log("search %s (key %s:%s:%s)", tostring(buy.e.name), tostring(buy.key.itemID), tostring(buy.key.itemLevel), tostring(buy.key.itemSuffix))
			AH.SendSearchQuery(buy.key, SORTS, true)
		end
	elseif buy.state == "wait" then
		-- Only fresh results: the auction house may still hold the list of an earlier search,
		-- with auctions sold since ("Internal auction error"). Read once the answer to this
		-- search has come in, or after 2.5 seconds without one.
		local has = AH.HasSearchResults(buy.key)
		if has and ((buy.gotAt and now - buy.gotAt > 0.3) or now - buy.t > 2.5) then
			ReadOffer()
		elseif now - buy.t > BUY_WAIT then
			ReadOffer()
		end
	elseif buy.state == "buying" and buy.dbErrorAt and now - buy.dbErrorAt > 2 then
		-- the "Internal auction error" was real this time: no confirmation came
		ns.ShowError(Global("ERR_AUCTION_DATABASE_ERROR"))
		ns.PurchaseFailed(Global("ERR_AUCTION_DATABASE_ERROR"), true)
	elseif buy.state == "buying" and now - buy.t > 8 then
		wipe(buy)
		SetStatus(L["No confirmation from the auction house. Check your mail before buying again."])
		Redraw()
	end
end

local function Action()
	if buy.state == "ready" then
		if GetMoney() < buy.price then
			SetStatus(L["Not enough gold."])
			return
		end
		buy.tried[buy.auctionID] = true
		Log("PlaceBid %s @ %s (%s), throttle ready: %s", tostring(buy.auctionID), tostring(buy.price), tostring(buy.e.name),
			tostring(AH.IsThrottledMessageSystemReady()))
		if ns.ExpectDbError then ns.ExpectDbError() end
		AH.PlaceBid(buy.auctionID, buy.price)
		buy.state, buy.t = "buying", GetTime()
		SetStatus(L["Buying %s …"]:format(buy.link))
		Redraw()
	elseif not buy.state then
		-- nothing picked: start at the top of the list
		if dirty then BuildView() end
		local e = selected or view[1]
		if e then
			scrollTo = true
			Check(e)
		end
	end
end

local function Purchased(auctionID)
	Log("purchase completed %s (waiting for %s, state %s)", tostring(auctionID), tostring(buy.auctionID), tostring(buy.state))
	if buy.state ~= "buying" or buy.auctionID ~= auctionID then return end
	local e = buy.e
	db.bought[e.source] = time()
	if e.visual then db.bought["v" .. e.visual] = time() end
	Print(L["Bought %s for %s. Wear it or sell it to a vendor to learn the appearance."]:format(buy.link, Money(buy.price)))
	local nextOne = RemoveAndNext(e)
	wipe(buy)
	SaveScan()
	Redraw()
	if nextOne then
		scrollTo = true
		Check(nextOne, 0.5)
	end
end

-- A purchase the auction house refused: try the next auction of the same item.
local AUCTION_ERRORS = {}
-- "Internal auction error" is left out: Forever's auction house sends it with purchases that
-- go through. It counts only if no confirmation follows (BuyTick).
for _, key in ipairs({ "ERR_ITEM_NOT_FOUND", "ERR_AUCTION_HIGHER_BID", "ERR_AUCTION_MIN_BID",
	"ERR_AUCTION_BID_OWN" }) do
	if _G[key] then AUCTION_ERRORS[_G[key]] = true end
end
local function PurchaseFailed(msg, confirmed)
	if confirmed then
		Log("no confirmation after the auction error: counted as failed")
	elseif msg and AUCTION_ERRORS[msg] then Log("error \"%s\" (state %s, auction %s)", msg, tostring(buy.state), tostring(buy.auctionID)) end
	if buy.state ~= "buying" or not (msg and (confirmed or AUCTION_ERRORS[msg])) then return end
	local e, tried = buy.e, buy.tried
	tried[buy.auctionID] = true
	buy.state = nil
	SetStatus(L["Purchase failed (%s). Trying the next auction …"]:format(msg))
	Check(e, 1.5, tried)
end

ns.PurchaseFailed = PurchaseFailed

-- In case the client sends no purchase event: the "You won an auction for ..." line.
local WON_PATTERN = ERR_AUCTION_WON_S and ("^" .. ERR_AUCTION_WON_S:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$")
local function WonMessage(msg)
	if buy.state ~= "buying" or not WON_PATTERN or type(msg) ~= "string" then return end
	if issecretvalue and issecretvalue(msg) then return end
	local name = msg:match(WON_PATTERN)
	if name then Log("chat: won %s", name) end
	if name and buy.e and (name == buy.e.name or (buy.link and buy.link:find(name, 1, true))) then
		Purchased(buy.auctionID)
	end
end

---------------------------------------------------------------------------
-- Look: warlock / void theme, Blizzard tooltip borders tinted fel violet
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local C = {
	bg = { 0.050, 0.030, 0.072, 0.97 },
	panel = { 0.110, 0.060, 0.160, 1 },
	line = { 0.360, 0.200, 0.500, 1 },
	well = { 0.025, 0.015, 0.040, 0.92 },
	accent = { 0.640, 0.208, 0.933, 1 },   -- #a335ee, the epic purple
	accentDim = { 0.200, 0.080, 0.300, 1 },
	text = { 0.950, 0.920, 0.980, 1 },
	muted = { 0.640, 0.570, 0.720, 1 },
	gold = { 1, 0.820, 0, 1 },             -- Blizzard's header yellow
	dark = { 1, 1, 1, 1 },
}
local FLAT = { bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 } }

local function Flat(f, bg, border)
	if not f.SetBackdrop then Mixin(f, BackdropTemplateMixin) end
	if not f.tsFlat then
		f:SetBackdrop(FLAT)
		f.tsFlat = true
	end
	f:SetBackdropColor(unpack(bg or C.panel))
	f:SetBackdropBorderColor(unpack(border or C.line))
end

local function Tip(frame, title, text)
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText(title, 1, 1, 1)
		if text then GameTooltip:AddLine(text, nil, nil, nil, true) end
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- A flat button. primary: violet with dark text (the main action).
local function FlatButton(parent, width, height, primary)
	local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
	b:SetSize(width, height)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("CENTER")
	b:SetFontString(fs)
	b.on = false
	function b:Restyle()
		local bg, border, text
		if primary then
			bg, border, text = C.accent, C.accent, C.dark
		elseif self.on then
			bg, border, text = C.accentDim, C.accent, C.accent
		else
			bg, border, text = C.panel, self.hover and C.accent or C.line, C.text
		end
		Flat(self, bg, border)
		fs:SetTextColor(unpack(text))

		self:SetAlpha(self:IsEnabled() and 1 or 0.45)
		if primary then self:SetBackdropBorderColor(0.85, 0.55, 1, 1) end
		if primary and self.hover and self:IsEnabled() then self:SetBackdropColor(0.74, 0.34, 1, 1) end
	end
	if primary then
		local setText = b.SetText
		function b:SetText(text)
			-- money colours would vanish on purple: drop them, white text throughout
			if text then text = "|cffffffff" .. tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r" end
			setText(self, text)
		end
	end
	function b:SetOn(on)
		self.on = on and true or false
		self:Restyle()
	end
	b:HookScript("OnEnter", function(self) self.hover = true self:Restyle() end)
	b:HookScript("OnLeave", function(self) self.hover = false self:Restyle() end)
	b:HookScript("OnEnable", function(self) self:Restyle() end)
	b:HookScript("OnDisable", function(self) self:Restyle() end)
	b:Restyle()
	return b
end

-- A switch: on shows a tick and the accent colour.
local function FlatToggle(parent, label, width, get, setter, tip)
	local b = FlatButton(parent, width, 22)
	function b:Sync()
		local v = get()
		self:SetText((v and "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t " or "") .. label)
		self:SetOn(v)
	end
	b:SetScript("OnClick", function(self)
		setter(not get())
		self:Sync()
		Changed()
	end)
	Tip(b, label, tip)
	b:Sync()
	return b
end

local function SmallTab()
	if db.smallTab ~= nil then return db.smallTab end
	local vf = Global("VendorFloorDB")
	if vf and vf.smallTab ~= nil then return vf.smallTab end
	local A = _G["Auctionator"]
	local ok, small = pcall(function() return A.Config.Get(A.Config.Options.SMALL_TABS) end)
	return ok and small and true or false
end

local tabButton
local function SizeTab()
	if not tabButton or not PanelTemplates_TabResize then return end
	if SmallTab() then PanelTemplates_TabResize(tabButton, 0, nil, 36) else PanelTemplates_TabResize(tabButton, 20, nil, 70) end
end
ns.SizeTab = SizeTab

---------------------------------------------------------------------------
-- The window inside the auction house
---------------------------------------------------------------------------

local BOTTOM = 40  -- room under the list
local rowsShown = 12


local function SlotName(key)
	for _, s in ipairs(SLOTS) do
		if s[1] == key then return s[2] end
	end
	return SLOTS[1][2]
end

-- A list to pick from under a button (our own: Blizzard's menu API did not open in Forever).
local pick
local function ShowPick(owner, list, current, onPick)
	if not pick then
		pick = CreateFrame("Frame", "TransmogSweepPick", UIParent, "BackdropTemplate")
		pick:SetFrameStrata("FULLSCREEN_DIALOG")
		pick:SetClampedToScreen(true)
		pick:EnableMouse(true)
		Flat(pick, C.bg, C.line)
		pick.rows = {}
		pick:SetScript("OnUpdate", function(self)
			if not self:IsMouseOver(40, -40, -40, 40) and not (self.owner and self.owner:IsMouseOver()) then self:Hide() end
		end)
		tinsert(UISpecialFrames, "TransmogSweepPick")
	end
	if pick:IsShown() and pick.owner == owner then
		pick:Hide()
		return
	end
	pick.owner = owner
	for i, item in ipairs(list) do
		local b = pick.rows[i]
		if not b then
			b = CreateFrame("Button", nil, pick)
			b:SetHeight(20)
			b.hl = b:CreateTexture(nil, "BACKGROUND")
			b.hl:SetAllPoints()
			b.hl:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.25)
			b.hl:Hide()
			b.fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			b.fs:SetPoint("LEFT", 10, 0)
			b:SetScript("OnEnter", function(self) self.hl:Show() end)
			b:SetScript("OnLeave", function(self) self.hl:Hide() end)
			pick.rows[i] = b
		end
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 20)
		b:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 20)
		b.fs:SetText(item[2])
		b.fs:SetTextColor(unpack(item[1] == current and C.accent or C.text))
		b:SetScript("OnClick", function()
			pick:Hide()
			onPick(item[1])
		end)
		b:Show()
	end
	for i = #list + 1, #pick.rows do pick.rows[i]:Hide() end
	pick:SetSize(math.max(owner:GetWidth(), 170), #list * 20 + 8)
	pick:ClearAllPoints()
	pick:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
	pick:Show()
end

local function ShowSlotMenu(owner)
	ShowPick(owner, SLOTS, db.slot, function(key)
		db.slot = key
		Changed()
	end)
end

local function ColorName(key)
	for _, c in ipairs(COLORS) do
		if c[1] == key then return c[2] end
	end
	return COLORS[1][2]
end

local function HideAppearance(e)
	db.hidden[HideKey(e)] = true
	if selected == e then
		selected = nil
		wipe(buy)
	end
	Changed()
	SetStatus(L["%s hidden. Settings bring hidden appearances back."]:format(e.link or e.name or "?"))
end

-- Everything the game says about one item, in a box to copy (Ctrl+C) for a bug report.
local function Diagnose(e)
	local out = {}
	local function add(fmt, ...) out[#out + 1] = fmt:format(...) end
	local function call(fn, ...)
		if not fn then return "n/a" end
		local res = { pcall(fn, ...) }
		if not res[1] then return "error" end
		local parts = {}
		for i = 2, #res do
			local v = res[i]
			local text = tostring(v)
			if type(v) == "table" then
				local t = {}
				for k, x in pairs(v) do
					if type(x) ~= "table" then t[#t + 1] = k .. "=" .. tostring(x) end
				end
				table.sort(t)
				text = "{" .. table.concat(t, ", ") .. "}"
			end
			parts[#parts + 1] = text
		end
		return #parts > 0 and table.concat(parts, " | ") or "nil"
	end
	add("TransmogSweep %s  ·  %s", VERSION, (GetLocale and GetLocale()) or "?")
	add("item %s  %s", tostring(e.id), tostring(e.name))
	add("entry source=%s visual=%s tip=%s tipFallback=%s unique=%s", tostring(e.source), tostring(e.visual), tostring(e.tip), tostring(db.tipFallback), tostring(db.unique))
	add("GetItemInfo(id): %s", call(TC.GetItemInfo, e.id))
	if e.link then add("GetItemInfo(link): %s", call(TC.GetItemInfo, e.link)) end
	add("GetSourceInfo: %s", call(TC.GetSourceInfo, e.source))
	add("GetAppearanceInfoBySource: %s", call(TC.GetAppearanceInfoBySource, e.source))
	add("PlayerHasTransmogItemModifiedAppearance: %s", call(TC.PlayerHasTransmogItemModifiedAppearance, e.source))
	add("PlayerHasTransmog(id): %s", call(TC.PlayerHasTransmog, e.id))
	add("PlayerHasTransmogByItemInfo(id): %s", call(TC.PlayerHasTransmogByItemInfo, e.id))
	add("AccountCanCollectSource: %s", call(TC.AccountCanCollectSource, e.source))
	add("listed because: %s", e.tip and ("tooltip " .. e.tip) or "collection API (no tooltip verdict)")
	add("PlayerCanCollectSource: %s", call(TC.PlayerCanCollectSource, e.source))
	if e.visual then
		local ok, sources = pcall(TC.GetAllAppearanceSources, e.visual)
		if ok and type(sources) == "table" then
			add("GetAllAppearanceSources(%s): %d", e.visual, #sources)
			for i, src in ipairs(sources) do
				if i > 12 then break end
				local ok2, info = pcall(TC.GetSourceInfo, src)
				add("  %s item=%s collected=%s", src, ok2 and info and tostring(info.itemID) or "?", ok2 and info and tostring(info.isCollected) or "?")
			end
		else
			add("GetAllAppearanceSources: %s", tostring(sources))
		end
	end
	add("API says: source %s, look %s", SourceKnown(e.source) and "known" or "missing", VisualKnown(e) and "known" or "missing")
	add("tooltip now: %s", tostring(TipState(e.id)))
	add("global UNKNOWN=%s", tostring(Global("TRANSMOGRIFY_TOOLTIP_APPEARANCE_UNKNOWN")))
	add("global OTHER=%s", tostring(Global("TRANSMOGRIFY_TOOLTIP_ITEM_UNKNOWN_APPEARANCE_KNOWN")))
	add("global KNOWN=%s", tostring(Global("TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN")))
	add("tooltip lines:")
	for _, line in ipairs(TipLines(e.id)) do add("  %s", line:gsub("|", "||")) end
	add("purchase log:")
	for _, line in ipairs(log) do add("  %s", line) end
	local text = table.concat(out, "\n")

	local f = Global("TransmogSweepDiag")
	if not f then
		f = CreateFrame("Frame", "TransmogSweepDiag", UIParent, "BackdropTemplate")
		f:SetSize(620, 420)
		f:SetPoint("CENTER")
		f:SetFrameStrata("DIALOG")
		f:SetMovable(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		Flat(f, C.bg, C.line)
		local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOPLEFT", 12, -10)
		title:SetText(L["TransmogSweep diagnosis  ·  Ctrl+A, Ctrl+C to copy"])
		local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -2, -2)
		local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
		sf:SetPoint("TOPLEFT", 12, -34)
		sf:SetPoint("BOTTOMRIGHT", -32, 12)
		local eb = CreateFrame("EditBox", nil, sf)
		eb:SetMultiLine(true)
		eb:SetFontObject(ChatFontNormal)
		eb:SetWidth(570)
		eb:SetAutoFocus(false)
		eb:SetScript("OnEscapePressed", function() f:Hide() end)
		sf:SetScrollChild(eb)
		f.eb = eb
		tinsert(UISpecialFrames, "TransmogSweepDiag")
	end
	f.eb:SetText(text)
	f:Show()
	f.eb:SetFocus()
	f.eb:HighlightText()
end

-- Right-click menu of a row: a small popup of our own (no dependence on the menu API).
local rowMenu
local function RowMenu(_, e)
	if not rowMenu then
		rowMenu = CreateFrame("Frame", "TransmogSweepRowMenu", UIParent, "BackdropTemplate")
		rowMenu:SetFrameStrata("FULLSCREEN_DIALOG")
		rowMenu:SetClampedToScreen(true)
		rowMenu:EnableMouse(true)
		Flat(rowMenu, C.bg, C.line)
		rowMenu.title = rowMenu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		rowMenu.title:SetPoint("TOPLEFT", 10, -8)
		rowMenu.title:SetPoint("RIGHT", -10, 0)
		rowMenu.title:SetJustifyH("LEFT")
		rowMenu.title:SetWordWrap(false)
		rowMenu.buttons = {}
		local entries = {
			{ L["Preview"], function(x) DressUpItemLink(x.link) end },
			{ L["Hide this appearance"], function(x) HideAppearance(x) end },
			{ L["Wrong? Show diagnosis"], function(x) Diagnose(x) end },
		}
		for i, en in ipairs(entries) do
			local b = FlatButton(rowMenu, 200, 22)
			b:SetPoint("TOPLEFT", 8, -28 - (i - 1) * 26)
			b:SetText(en[1])
			b:SetScript("OnClick", function()
				rowMenu:Hide()
				if rowMenu.e then en[2](rowMenu.e) end
			end)
			rowMenu.buttons[i] = b
		end
		rowMenu:SetSize(216, 36 + #entries * 26)
		rowMenu:SetScript("OnUpdate", function(self)
			-- close when the mouse is far away
			if not self:IsMouseOver(30, -30, -30, 30) then self:Hide() end
		end)
		tinsert(UISpecialFrames, "TransmogSweepRowMenu")
	end
	rowMenu.e = e
	rowMenu.title:SetText(e.name or "?")
	local x, y = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	rowMenu:ClearAllPoints()
	rowMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale - 10, y / scale + 10)
	rowMenu:Show()
end

local function UpdateScroll()
	local sb = ui.scrollBar
	local maxOffset = max(#view - rowsShown, 0)
	offset = max(0, min(offset, maxOffset))
	sb.updating = true
	sb:SetMinMaxValues(0, maxOffset)
	sb:SetValue(offset)
	sb.updating = false
	sb:SetShown(maxOffset > 0)
end

local function UpdateScanButton()
	local b = ui.scan
	if scan.active then
		b:SetText(L["Scanning …"])
		b:Disable()
	else
		b:SetText(L["Scan"])
		b:Enable()
	end
end

local function UpdateBuyButton()
	local b = ui.buy
	if buy.state == "ready" then
		b:SetText(L["Buy for %s"]:format(Money(buy.price)))
		b:Enable()
	elseif buy.state == "send" or buy.state == "wait" then
		b:SetText(L["Checking …"])
		b:Disable()
	elseif buy.state == "buying" then
		b:SetText(L["Buying …"])
		b:Disable()
	else
		b:SetText(selected and L["Check price"] or L["Start buying"])
		b:SetEnabled((selected ~= nil or #view > 0) and not (scan.active and scan.phase ~= "verify"))
	end
end

Redraw = function()
	if not ui or not ui:IsShown() then return end
	if dirty then BuildView() end
	if scrollTo and selected then
		-- keep the item being bought in sight
		scrollTo = false
		for i, e in ipairs(view) do
			if e == selected then
				if i <= offset then offset = i - 1 elseif i > offset + rowsShown then offset = i - rowsShown end
				break
			end
		end
	end
	UpdateScroll()
	for i, row in ipairs(ui.rows) do
		local e = i <= rowsShown and view[offset + i]
		row.e = e or nil
		if e then
			row.icon:SetTexture(e.icon)
			local r, g, b = 1, 1, 1
			local q = select(3, GetItemInfo(e.id)) or e.quality
			local qc = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
			if qc then r, g, b = qc.r, qc.g, qc.b end
			row.name:SetText(e.name or e.link or "?")
			row.name:SetTextColor(r or 1, g or 1, b or 1)
			row.slot:SetText(_G[e.inv] or "")
			row.type:SetText(e.subName or "")
			row.level:SetText((e.req or 0) > 1 and e.req or "")
			local count = tostring(e.n or 1)
			if e.alts and e.alts > 0 then count = count .. " |cffa38fb8+" .. e.alts .. "|r" end
			row.count:SetText(count)
			row.price:SetText(Money(e.price))
			row.sel:SetShown(e == selected)
			row:Show()
		else
			row:Hide()
		end
	end
	local s = db.sort or { key = "price" }
	for key, h in pairs(ui.headers) do
		h.label:SetTextColor(unpack(key == s.key and C.accent or C.gold))
		h.arrow:Hide()
		if key == s.key then
			local arrow = s.desc and "|TInterface\\Buttons\\Arrow-Down-Up:12:12:0:-2|t" or "|TInterface\\Buttons\\Arrow-Up-Up:12:12:0:2|t"
			h.label:SetText(h.text .. " " .. arrow)
		else
			h.label:SetText(h.text)
		end
	end
	if not next(items) and not scan.active then
		ui.info:SetText(L["No scan yet. Click Scan: it reads weapons and armor only and takes a few seconds."])
	elseif dataAt then
		ui.info:SetText(L["%d appearances listed · %d items of gear in the scan · scanned %s"]:format(#view, listed, Ago(dataAt)))
	else
		ui.info:SetText("")
	end
	ui.empty:SetShown(next(items) ~= nil and #view == 0 and not scan.active)
	ui.slot:SetText(SlotName(db.slot) .. "  |cffa335eev|r")
	ui.color:SetText(ColorName(db.color or "any") .. "  |cffa335eev|r")
	ui.unique:Sync()
	ui.class:Sync()
	UpdateScanButton()
	UpdateBuyButton()
end
ns.Redraw = function() Redraw() end

local function Layout()
	local h = ui.list:GetHeight()
	rowsShown = max(3, min(MAX_ROWS, floor((h - 30) / ROW_HEIGHT)))
end

local COLUMNS = {
	-- key, header, right offset, width, justify
	{ "price", L["Price"], -22, 120, "RIGHT" },
	{ "count", L["Auctions"], -150, 64, "RIGHT" },
	{ "level", L["Level"], -222, 40, "RIGHT" },
	{ "type", L["Type"], -270, 100, "LEFT" },
	{ "slot", L["Slot"], -378, 100, "LEFT" },
}

local function BuildUI()
	if ui then return end
	ui = CreateFrame("Frame", "TransmogSweepFrame", AuctionHouseFrame)
	ui:Hide()
	ui:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 4, -24)
	ui:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -4, 27)
	ui:SetFrameLevel(AuctionHouseFrame:GetFrameLevel() + 5)
	ui:EnableMouse(true)
	local bg = ui:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 1)
	-- void: violet at the top, fading to black
	if not (CreateColor and pcall(bg.SetGradient, bg, "VERTICAL", CreateColor(0.02, 0.01, 0.03, 0.96), CreateColor(0.13, 0.05, 0.20, 0.96))) then
		bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.95)
	end

	-- top row: scan, search, slot, price limit, settings
	ui.scan = FlatButton(ui, 120, 24, true)
	ui.scan:SetPoint("TOPLEFT", 64, -8)
	ui.scan:SetScript("OnClick", StartScan)
	Tip(ui.scan, L["Scan"], L["Reads all weapons and armor on the auction house, grouped by item. Takes a few seconds and can be repeated any time."])

	local search = CreateFrame("EditBox", nil, ui, "SearchBoxTemplate")
	search:SetSize(170, 22)
	Tip(search, L["Search"], L["Item names. Also finds a look through the names of all other items that share it."])
	search:SetPoint("LEFT", ui.scan, "RIGHT", 14, 0)
	search:SetAutoFocus(false)
	search:SetText(db.search or "")
	search:HookScript("OnTextChanged", function(self)
		local text = self:GetText() or ""
		if text ~= db.search then
			db.search = text
			Changed()
		end
	end)
	ui.search = search

	ui.slot = FlatButton(ui, 150, 22)
	ui.slot:SetPoint("LEFT", search, "RIGHT", 10, 0)
	ui.slot:SetScript("OnClick", function(self) ShowSlotMenu(self) end)

	local maxLabel = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	maxLabel:SetPoint("LEFT", ui.slot, "RIGHT", 14, 0)
	maxLabel:SetText(L["Max gold"])
	maxLabel:SetTextColor(unpack(C.muted))
	local maxBox = CreateFrame("EditBox", nil, ui, "InputBoxTemplate")
	maxBox:SetSize(56, 20)
	maxBox:SetPoint("LEFT", maxLabel, "RIGHT", 8, 0)
	maxBox:SetAutoFocus(false)
	maxBox:SetNumeric(true)
	maxBox:SetMaxLetters(6)
	maxBox:SetText((db.maxGold or 0) > 0 and tostring(db.maxGold) or "")
	maxBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	maxBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	maxBox:HookScript("OnTextChanged", function(self)
		local v = tonumber(self:GetText()) or 0
		if v ~= db.maxGold then
			db.maxGold = v
			Changed()
		end
	end)
	Tip(maxBox, L["Max gold"], L["Hides items that cost more. Empty: no limit."])

	local gear = FlatButton(ui, 24, 24)
	gear:SetPoint("TOPRIGHT", -10, -8)
	local gi = gear:CreateTexture(nil, "ARTWORK")
	gi:SetSize(14, 14)
	gi:SetPoint("CENTER")
	gi:SetTexture("Interface\\Buttons\\UI-OptionsButton")
	gear:SetScript("OnClick", function() ns.ToggleSettings() end)
	Tip(gear, L["Settings"], nil)

	-- second row: the two main filters and the status line
	ui.unique = FlatToggle(ui, L["Unique appearances"], 170, function() return db.unique end,
		function(v) db.unique = v end,
		L["One row per look: many items share an appearance. Shows the cheapest item for each look you do not have, and hides looks you already know through another item. Off: every item whose own appearance source you lack (completionist)."])
	ui.unique:SetPoint("TOPLEFT", 64, -40)
	ui.class = FlatToggle(ui, L["Usable by my class"], 160, function() return db.classOnly end,
		function(v) db.classOnly = v end,
		L["Only armor types and weapons your class can wear. Warriors, paladins, hunters and shamans keep both armor types of their level range. Off: everything, e.g. to collect for your alts."])
	ui.class:SetPoint("LEFT", ui.unique, "RIGHT", 8, 0)
	ui.status = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.color = FlatButton(ui, 140, 22)
	ui.color:SetPoint("LEFT", ui.class, "RIGHT", 8, 0)
	ui.color:SetScript("OnClick", function(self)
		ShowPick(self, COLORS, db.color or "any", function(key)
			db.color = key
			Changed()
		end)
	end)
	Tip(ui.color, L["Colour"], L["Looks whose item names suggest a colour, e.g. Crimson, Ebon or Azure. The names of all items with the same look count. WoW gives addons no colour data, so this is a good guess, not exact."])
	ui.status:SetPoint("LEFT", ui.color, "RIGHT", 14, 0)
	ui.status:SetPoint("RIGHT", ui, "RIGHT", -12, 0)
	ui.status:SetJustifyH("LEFT")
	ui.status:SetWordWrap(false)
	ui.status:SetTextColor(unpack(C.muted))
	ui.status:SetText(statusText)

	-- the list
	local list = CreateFrame("Frame", nil, ui, "BackdropTemplate")
	list:SetPoint("TOPLEFT", 8, -74)
	list:SetPoint("BOTTOMRIGHT", -8, BOTTOM)
	Flat(list, C.well, C.line)
	ui.list = list

	ui.headers = {}
	local function Header(key, text, anchor)
		local h = CreateFrame("Button", nil, list)
		h:SetHeight(20)
		anchor(h)
		h.label = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		h.label:SetAllPoints()
		h.label:SetText(text)
		h.text = text
		h.arrow = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		h.arrow:SetTextColor(unpack(C.accent))
		h:SetScript("OnClick", function()
			local s = db.sort or {}
			if s.key == key then
				s.desc = not s.desc
			else
				db.sort = { key = key, desc = key == "count" or key == "level" }
			end
			Changed()
		end)
		ui.headers[key] = h
		return h
	end
	local nameHead = Header("name", L["Item"], function(h)
		h:SetPoint("TOPLEFT", 32, -4)
		h:SetPoint("RIGHT", list, "RIGHT", -486, 0)
	end)
	nameHead.label:SetJustifyH("LEFT")
	for _, c in ipairs(COLUMNS) do
		local h = Header(c[1], c[2], function(h)
			h:SetWidth(c[4])
			h:SetPoint("TOPRIGHT", c[3], -4)
		end)
		h.label:SetJustifyH(c[5])
		if c[5] == "RIGHT" then h.arrow:SetPoint("RIGHT", h, "LEFT", -2, 0) else h.arrow:SetPoint("LEFT", h, "LEFT", 44, 0) end
	end
	nameHead.arrow:ClearAllPoints()
	nameHead.arrow:SetPoint("LEFT", nameHead, "LEFT", 34, 0)
	local sep = list:CreateTexture(nil, "ARTWORK")
	sep:SetColorTexture(C.line[1], C.line[2], C.line[3], 0.6)
	sep:SetHeight(1)
	sep:SetPoint("TOPLEFT", 6, -25)
	sep:SetPoint("TOPRIGHT", -6, -25)

	ui.rows = {}
	for i = 1, MAX_ROWS do
		local row = CreateFrame("Button", nil, list)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 4, -28 - (i - 1) * ROW_HEIGHT)
		row:SetPoint("RIGHT", list, "RIGHT", -18, 0)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		local hl = row:CreateTexture(nil, "BACKGROUND")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.05)
		hl:Hide()
		row.sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
		row.sel:SetAllPoints()
		row.sel:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.18)
		row.sel:Hide()
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(18, 18)
		row.icon:SetPoint("LEFT", 6, 0)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.name:SetPoint("LEFT", 28, 0)
		row.name:SetPoint("RIGHT", row, "RIGHT", -470, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		for _, c in ipairs(COLUMNS) do
			local fs = row:CreateFontString(nil, "OVERLAY", c[1] == "price" and "GameFontHighlight" or "GameFontHighlightSmall")
			fs:SetWidth(c[4])
			fs:SetPoint("RIGHT", row, "RIGHT", c[3] + 18, 0)
			fs:SetJustifyH(c[5])
			fs:SetWordWrap(false)
			if c[1] ~= "price" then fs:SetTextColor(unpack(C.muted)) end
			row[c[1]] = fs
		end
		row:SetScript("OnEnter", function(self)
			hl:Show()
			local e = self.e
			if not e then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(e.link)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(L["Appearance not collected"], 0.80, 0.50, 1)
			if e.alts and e.alts > 0 then
				GameTooltip:AddLine(L["%d more listed items have this look."]:format(e.alts), 0.8, 0.8, 0.8)
			end
			GameTooltip:AddLine(L["Click: check price  ·  Ctrl+click: preview  ·  Alt+click: diagnosis  ·  Right-click: more"], 0.55, 0.59, 0.65)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function()
			hl:Hide()
			GameTooltip:Hide()
		end)
		row:SetScript("OnClick", function(self, button)
			local e = self.e
			if not e then return end
			if button == "RightButton" then
				RowMenu(self, e)
			elseif IsAltKeyDown() then
				Diagnose(e)
			elseif IsModifiedClick("DRESSUP") then
				DressUpItemLink(e.link)
			elseif IsModifiedClick("CHATLINK") then
				ChatEdit_InsertLink(e.link)
			else
				Check(e)
			end
		end)
		ui.rows[i] = row
	end
	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function(_, delta)
		offset = offset - delta * 3
		Redraw()
	end)

	local sb = CreateFrame("Slider", nil, list)
	sb:SetOrientation("VERTICAL")
	sb:SetWidth(8)
	sb:SetPoint("TOPRIGHT", -5, -30)
	sb:SetPoint("BOTTOMRIGHT", -5, 6)
	sb:SetValueStep(1)
	sb:SetObeyStepOnDrag(true)
	local track = sb:CreateTexture(nil, "BACKGROUND")
	track:SetAllPoints()
	track:SetColorTexture(C.panel[1], C.panel[2], C.panel[3], 0.8)
	local thumb = sb:CreateTexture(nil, "OVERLAY")
	thumb:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.8)
	thumb:SetSize(8, 36)
	sb:SetThumbTexture(thumb)
	sb:SetScript("OnValueChanged", function(self, value)
		if self.updating then return end
		offset = floor(value + 0.5)
		Redraw()
	end)
	ui.scrollBar = sb

	ui.empty = list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	ui.empty:SetPoint("CENTER")
	ui.empty:SetTextColor(unpack(C.muted))
	ui.empty:SetText(L["Nothing left to collect with these filters."])

	-- bottom: info and the buy button
	ui.buy = FlatButton(ui, 200, 26, true)
	ui.buy:SetPoint("BOTTOMRIGHT", -10, 8)
	ui.buy:SetScript("OnClick", Action)
	Tip(ui.buy, L["Buy"], L["Starts at the top of the list. Each click checks the next item's price or buys it; after a purchase the next item is checked by itself, so you just keep clicking."])
	ui.info = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ui.info:SetPoint("BOTTOMLEFT", 12, 15)
	ui.info:SetPoint("RIGHT", ui.buy, "LEFT", -12, 0)
	ui.info:SetJustifyH("LEFT")
	ui.info:SetTextColor(unpack(C.muted))

	ui:SetScript("OnShow", function()
		Layout()
		Redraw()
	end)
	ui:SetScript("OnSizeChanged", function()
		Layout()
		Redraw()
	end)
end

local function CreateTab()
	local lib = _G.LibStub and _G.LibStub("LibAHTab-1-0", true)
	if not lib or not AuctionHouseFrame then return end
	BuildUI()
	if not tabButton then
		if not lib:DoesIDExist("TransmogSweep") then lib:CreateTab("TransmogSweep", ui, "TransmogSweep", "TransmogSweep") end
		tabButton = lib:GetButton("TransmogSweep")
		if tabButton then tabButton:HookScript("OnShow", SizeTab) end
	end
	SizeTab()
end

---------------------------------------------------------------------------
-- Settings: a window of its own, live while you play
---------------------------------------------------------------------------

local function CountKeys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function BuildSettings()
	local UI = _G.LibStub("BencepoUI-1.0")
	settingsWin = UI:CreateWindow({
		name = "TransmogSweepSettingsFrame", title = L["TransmogSweep Settings"],
		subtitle = VERSION, width = 470, height = 360, theme = C, accent = C.accent,
		db = db, posKey = "settingsPoint", hint = L["drag to move, changes apply live"],
		bugUrl = BUG_URL,
	})
	local w = settingsWin
	local X = 16
	w:Header(X, -48, L["List"])
	w:Check(X, -72, L["Unique appearances"], L["One row per look, the cheapest item that has it. Looks you know through another item are hidden."],
		function() return db.unique end, function(v) db.unique = v and true or false Changed() end)
	w:Check(X, -96, L["Usable by my class"], L["Only armor types and weapons your class can wear."],
		function() return db.classOnly end, function(v) db.classOnly = v and true or false Changed() end)
	w:Check(X, -120, L["Hide items above my level"], L["Hides items your character cannot wear yet. Off by default: buying and selling to a vendor learns the look at any level."],
		function() return db.aboveLevel end, function(v) db.aboveLevel = v and true or false Changed() end)
	w:Check(X, -144, L["Hide what I bought"], L["Bought appearances stay hidden until you learn them (wear the item or sell it to a vendor), at most two weeks."],
		function() return db.hideBought end, function(v) db.hideBought = v and true or false Changed() end)

	w:Header(X, -184, L["Auction house"])
	w:Check(X, -208, L["Small tab"], L["Makes the TransmogSweep tab as narrow as its text. Unset, it follows VendorFloor or Auctionator."],
		function() return SmallTab() end, function(v)
			db.smallTab = v and true or false
			SizeTab()
		end)

	local unhide = w:Button(L["Show hidden appearances"], 200, function()
		wipe(db.hidden)
		Changed()
	end, L["Brings back every appearance you hid with a right-click."])
	unhide:SetPoint("TOPLEFT", 250, -72)
	local forget = w:Button(L["Forget purchases"], 200, function()
		wipe(db.bought)
		Changed()
	end, L["Lists bought appearances again, e.g. if you sold an item before learning it."])
	forget:SetPoint("TOPLEFT", 250, -106)
	w:OnRefresh(function()
		unhide:SetText(L["Show hidden appearances"] .. " (" .. CountKeys(db.hidden) .. ")")
	end)

	w:Text(X, -250, L["Collected counts account-wide: a look learned on any of your characters is known. TransmogSweep reads weapons and armor only. Buying is always a click of your own."], 430)
end

function ns.ToggleSettings()
	if not settingsWin then BuildSettings() end
	settingsWin:Refresh()
	settingsWin:Toggle()
end

function TransmogSweep_OnCompartmentClick()
	ns.ToggleSettings()
end

local function RegisterSettings()
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnCategory) then return end
	local category, layout = Settings.RegisterVerticalLayoutCategory("TransmogSweep")
	if layout and CreateSettingsButtonInitializer then
		layout:AddInitializer(CreateSettingsButtonInitializer(L["TransmogSweep has its own settings window"], L["Open"], function()
			if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
			if not settingsWin then BuildSettings() end
			settingsWin:Refresh()
			settingsWin:Show()
		end, L["The window can be dragged anywhere and stays open while you play."], true))
	end
	Settings.RegisterAddOnCategory(category)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}

-- Forever's auction house shows "Internal auction error" with purchases that go through.
-- Right after our own bid that message is taken off the screen again; should the purchase
-- really fail, it is shown after all (BuyTick).
local hideDbErrorUntil = 0
ns.ShowError = function(msg)
	if UIErrorsFrame and msg then UIErrorsFrame:AddMessage(msg, 1, 0.1, 0.1, 1) end
end
local function OnErrorShown(_, msg)
	if msg == Global("ERR_AUCTION_DATABASE_ERROR") and GetTime() < hideDbErrorUntil and buy.state == "buying" then
		hideDbErrorUntil = 0
		UIErrorsFrame:Clear()
	end
end
if UIErrorsFrame then
	if UIErrorsFrame.AddExternalErrorMessage then hooksecurefunc(UIErrorsFrame, "AddExternalErrorMessage", OnErrorShown) end
	hooksecurefunc(UIErrorsFrame, "AddMessage", OnErrorShown)
end
ns.ExpectDbError = function() hideDbErrorUntil = GetTime() + 1.5 end

function handlers.ADDON_LOADED(name)
	if name ~= ADDON then return end
	TransmogSweepDB = TransmogSweepDB or {}
	db = TransmogSweepDB
	for k, v in pairs(defaults) do
		if db[k] == nil then db[k] = v end
	end
	db.hidden = db.hidden or {}
	db.bought = db.bought or {}
	db.tipCache = db.tipCache or {}  -- itemID -> "known" / "other": settled tooltip verdicts
	db.lastFull = nil
	local now = time()
	for k, t in pairs(db.bought) do
		if now - t > KEEP_BOUGHT then db.bought[k] = nil end
	end
	-- the last scan comes back for an hour, so the tab is not empty until the next one
	local last = db.last
	if last and last.v == 2 and last.items and now - (last.at or 0) < KEEP_SCAN then
		items, listed, dataAt = last.items, last.listed or 0, last.at
		for _, e in pairs(items) do e.pending = nil end
	else
		db.last = nil
	end
	local ok, err = pcall(RegisterSettings)
	if not ok then Print(err) end
end

function handlers.AUCTION_HOUSE_SHOW()
	ahOpen = true
	if dataAt and time() - dataAt >= KEEP_SCAN then
		items, listed, dataAt = {}, 0, nil
		db.last = nil
		dirty = true
	end
	C_Timer.After(0, CreateTab)
	C_Timer.After(0.3, CreateTab)
end

function handlers.AUCTION_HOUSE_CLOSED()
	ahOpen = false
	wipe(buy)
	selected = nil
	if scan.active then
		wipe(scan)
		scan.active = false
		SetStatus(L["Scan stopped: the auction house was closed."])
	end
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
	if not (scan.active and scan.phase == "wait") then return end
	Process(AH.GetBrowseResults())
	Continue()
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_ADDED(added)
	if not (scan.active and scan.phase == "wait") then return end
	Process(added)
	Continue()
end

function handlers.AUCTION_HOUSE_BROWSE_FAILURE()
	if scan.active then FinishScan(true) end
end

function handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
	-- the query was dropped: send it again
	if scan.active and scan.phase == "wait" then scan.phase, scan.t = scan.read > 0 and "more" or "send", GetTime() end
	if buy.state == "wait" then buy.state, buy.t = "send", GetTime() end
end

function handlers.ITEM_SEARCH_RESULTS_UPDATED(key)
	-- answers to an earlier search can arrive late: only ours counts
	if buy.state == "wait" and (not key or not buy.key or key.itemID == buy.key.itemID) then
		buy.gotAt = buy.gotAt or GetTime()
	end
end
handlers.ITEM_SEARCH_RESULTS_ADDED = handlers.ITEM_SEARCH_RESULTS_UPDATED

function handlers.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
	Purchased(auctionID)
end

function handlers.UI_ERROR_MESSAGE(msgType, msg)
	if issecretvalue and issecretvalue(msg) then return end
	if ahOpen then Log("UI error %s: %s", tostring(msgType), tostring(msg)) end
	PurchaseFailed(msg)
end

function handlers.CHAT_MSG_SYSTEM(msg)
	if issecretvalue and issecretvalue(msg) then return end
	if ahOpen and type(msg) == "string" and msg:lower():find("auction") then Log("chat: %s", msg) end
	WonMessage(msg)
end

-- the auction house's own error channel (the red message in its window)
local DB_ERROR = Enum and Enum.AuctionHouseError and Enum.AuctionHouseError.DatabaseError or 10
function handlers.AUCTION_HOUSE_SHOW_ERROR(err)
	Log("AH error %s", tostring(err))
	if err == DB_ERROR and buy.state == "buying" then buy.dbErrorAt = GetTime() end
end
function handlers.AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION(note, text)
	Log("AH notice %s: %s", tostring(note), tostring(text))
end
function handlers.AUCTION_HOUSE_SHOW_NOTIFICATION(note)
	Log("AH notice %s", tostring(note))
end

local function CollectionChanged()
	wipe(known.src)
	wipe(known.vis)
	dirty = true
	if ui and ui:IsShown() then Redraw() end
end
handlers.TRANSMOG_COLLECTION_UPDATED = CollectionChanged
function handlers.TRANSMOG_COLLECTION_SOURCE_ADDED(source)
	local learnedItem = source and items[source]
	if db and learnedItem then db.tipCache[learnedItem.id] = "known" end
	if db and source then db.bought[source] = nil end
	local learned = source and items[source]
	if learned then
		learned.tip = "known"
		for _, e in pairs(items) do
			if e ~= learned and e.visual and e.visual == learned.visual and e.tip == "unknown" then e.tip = "other" end
		end
	end
	CollectionChanged()
end

local events = CreateFrame("Frame")
for event in pairs(handlers) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, ...)
	local ok, err = pcall(handlers[event], ...)
	if not ok then Print(err) end
end)

-- clock: ten ticks a second
local elapsed, second = 0, 0
events:SetScript("OnUpdate", function(_, dt)
	elapsed = elapsed + dt
	if elapsed < 0.1 then return end
	second = second + elapsed
	elapsed = 0
	if not ahOpen then return end
	local now = GetTime()
	local ok, err = pcall(function()
		if scan.active then
			ScanTick(now)
			if ui and ui:IsShown() then UpdateScanButton() end
		end
		if buy.state then BuyTick(now) end
		if second >= 1 then
			second = 0
			if ui and ui:IsShown() then
				UpdateScanButton()
				UpdateBuyButton()
			end
		end
	end)
	if not ok then
		Print(err)
		wipe(scan)
		scan.active = false
		wipe(buy)
	end
end)
