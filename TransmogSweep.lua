-- TransmogSweep
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Lists the transmog appearances on the auction house you have not collected yet, as a
-- tab of the auction house window. It asks the auction house only for weapons and armor
-- (one search, grouped by item), so a scan takes seconds and can run any time.
-- Collected is account-wide: a look learned on any character counts.
-- A second mode lists the recipes for this character's professions it has not learned yet.
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
local format = string.format
local tconcat, tremove, tsort = table.concat, table.remove, table.sort
local ipairs, pairs, pcall, tostring, type, unpack, wipe = ipairs, pairs, pcall, tostring, type, unpack, wipe
local GetTime = GetTime

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
	mode = "mog",        -- "mog": appearances, "recipe": recipes for this character's professions
	recipeProf = "all",  -- recipe subclass shown, or "all" professions of the character
	learnableOnly = true, -- recipes: only those the character can learn right now
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
local events
local known = { src = {}, vis = {} } -- collected status, cleared when the collection changes
local statusText = ""
local mode = "mog"      -- the list shown: "mog" appearances, "recipe" recipes
local store = { mog = { items = {}, listed = 0 }, recipe = { items = {}, listed = 0 } }
local ERR_DB_ERROR = Global("ERR_AUCTION_DATABASE_ERROR")

local function SyncTicker()
	local active = ahOpen and (scan.active or (buy.state ~= nil and buy.state ~= "ready"))
	if events then events:SetShown(active) end
	return active
end

local function Print(msg) print(PREFIX .. tostring(msg)) end

-- What happened during the last purchases, for the diagnosis and bug reports.
local log = {}
local function Log(fmt, ...)
	local ok, text = pcall(format, fmt, ...)
	log[#log + 1] = ("%.2f  %s"):format(GetTime(), ok and text or fmt)
	if #log > 60 then tremove(log, 1) end
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

local Redraw, UpdateBuyButton
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
local SLOT_NAMES = {}
for _, s in ipairs(SLOTS) do SLOT_NAMES[s[1]] = s[2] end

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
local WEAPONS
do
	local function set(...)
		local t = {}
		for i = 1, select("#", ...) do t[select(i, ...)] = true end
		return t
	end
	WEAPONS = {
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
end

local classCache = { class = select(2, UnitClass("player")), can = {} }

local function ClassFits(e)
	local class = classCache.class
	if not class then
		class = select(2, UnitClass("player"))
		classCache.class = class
	end
	local can = classCache.can[e.source]
	if can == nil and TC.PlayerCanCollectSource then
		local ok, hasData, okCan = pcall(TC.PlayerCanCollectSource, e.source)
		if ok and hasData then
			can = okCan and true or false
			classCache.can[e.source] = can
		end
	end
	if can == false then return false end
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
local OpenScanTip, GetScanTipLeft
do
	---@type GameTooltip
	local scanTip
	local scanTipLeft = {}

	OpenScanTip = function(itemID)
		if not scanTip then
			scanTip = CreateFrame("GameTooltip", "TransmogSweepScanTip", nil, "GameTooltipTemplate") --[[@as GameTooltip]]
		end
		scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
		scanTip:ClearLines()
		scanTip:SetItemByID(itemID)
		return scanTip
	end

	GetScanTipLeft = function(i)
		local fs = scanTipLeft[i]
		if not fs then
			fs = _G["TransmogSweepScanTipTextLeft" .. i]
			scanTipLeft[i] = fs
		end
		return fs
	end
end

local function IsRed(r, g, b) return (r and r > 0.9 and g < 0.25 and b < 0.25) and true or false end

local function LineIsRed(c)
	if type(c) ~= "table" then return false end
	if c.GetRGB then return IsRed(c:GetRGB()) end
	return IsRed(c.r, c.g, c.b)
end

-- The lines of an item's tooltip with their colour: { text, red }. Used by Diagnose.
local function ScanTipLines(itemID)
	local lines = {}
	local getByID = C_TooltipInfo and C_TooltipInfo.GetItemByID
	if getByID then
		local ok, data = pcall(getByID, itemID)
		local raw = ok and data and data.lines
		if raw then
			local surface = TooltipUtil and TooltipUtil.SurfaceArgs
			for i = 1, #raw do
				local line = raw[i]
				if surface and not line.leftText then pcall(surface, line) end
				if line.leftText then
					lines[#lines + 1] = { line.leftText, LineIsRed(line.leftColor) }
				end
			end
			if lines[1] then return lines end
		end
	end
	local tip = OpenScanTip(itemID)
	for i = 1, tip:NumLines() do
		local fs = GetScanTipLeft(i)
		local text = fs and fs:GetText()
		if text then lines[#lines + 1] = { text, IsRed(fs:GetTextColor()) } end
	end
	tip:Hide()
	return lines
end

-- the texts only (used by Diagnose)
local function TipLines(itemID)
	local out = {}
	for i, l in ipairs(ScanTipLines(itemID)) do out[i] = l[1] end
	return out
end

-- Read the tooltip verdict directly with early return and zero intermediate tables.
local function TipState(itemID)
	local getByID = C_TooltipInfo and C_TooltipInfo.GetItemByID
	if getByID then
		local ok, data = pcall(getByID, itemID)
		local raw = ok and data and data.lines
		if raw and raw[1] then
			local surface = TooltipUtil and TooltipUtil.SurfaceArgs
			local first
			for i = 1, #raw do
				local line = raw[i]
				if surface and not line.leftText then pcall(surface, line) end
				local text = line.leftText
				if text then
					if not first then
						first = text
						if first == "" or first == RETRIEVING_ITEM_INFO then return nil end
					end
					if text == TIP_UNKNOWN then return "unknown" end
					if text == TIP_OTHER then return "other" end
					if TIP_KNOWN and text == TIP_KNOWN then return "known" end
				end
			end
			if first then return "known" end
		end
	end
	local tip = OpenScanTip(itemID)
	local result, first
	for i = 1, tip:NumLines() do
		local fs = GetScanTipLeft(i)
		local text = fs and fs:GetText()
		if text then
			if not first then
				first = text
				if first == "" or first == RETRIEVING_ITEM_INFO then break end
			end
			if text == TIP_UNKNOWN then
				result = "unknown"
				break
			end
			if text == TIP_OTHER then
				result = "other"
				break
			end
			if TIP_KNOWN and text == TIP_KNOWN then
				result = "known"
				break
			end
		end
	end
	tip:Hide()
	if result then return result end
	if not first or first == "" or first == RETRIEVING_ITEM_INFO then return nil end
	return "known" -- loaded tooltip without a "not collected" line
end

local function LookMissing(e)
	if Collectable(e.source) == false then return false end
	if e.tip then return e.tip == "unknown" end
	return not VisualKnown(e)
end

local function SourceMissing(e)
	if Collectable(e.source) == false then return false end
	if e.tip then return e.tip ~= "known" end
	return not SourceKnown(e.source)
end

local function HideKey(e) return e.visual and ("v" .. e.visual) or ("s" .. e.source) end

local charKey
local function CharKey()
	if not charKey then
		local name = UnitName("player")
		if not name or name == UNKNOWNOBJECT then return "?" end
		charKey = name .. "-" .. (GetRealmName() or "")
	end
	return charKey
end

-- recipes are learned per character, appearances per account
local function BoughtKey(e)
	if e.kind == "recipe" then return e.source .. "@" .. CharKey() end
	return e.source
end

local function Bought(e)
	if not db.hideBought then return false end
	if e.kind == "recipe" then return db.bought[BoughtKey(e)] or false end
	return db.bought[e.source] or (db.unique and e.visual and db.bought["v" .. e.visual]) or false
end

---------------------------------------------------------------------------
-- Recipes: the professions of this character, and what a recipe's tooltip says
---------------------------------------------------------------------------

local RECIPE_CLASS = Enum and Enum.ItemClass and Enum.ItemClass.Recipe or 9
local profCache -- recipe subclass -> { name, rank, max }
local MyProfessions
do
	-- recipe subclass (item class 9) of a profession skill line
	local SUB_OF_SKILL = { [165] = 1, [197] = 2, [202] = 3, [164] = 4, [185] = 5, [171] = 6, [129] = 7,
		[333] = 8, [356] = 9, [755] = 10, [773] = 11 }

	local function AddProfessions(mine, byName, ...)
		for i = 1, select("#", ...) do
			local idx = select(i, ...)
			if idx ~= nil then
				local ok, name, _, rank, maxRank, _, _, skillLine = pcall(GetProfessionInfo, idx)
				local sub = ok and (SUB_OF_SKILL[skillLine] or byName[name])
				if sub then mine[sub] = { name = name, rank = rank or 0, max = maxRank or 0 } end
			end
		end
	end

	MyProfessions = function()
		if profCache then return profCache end
		local mine = {}
		local byName = {}
		local getSub = (C_Item and C_Item.GetItemSubClassInfo) or Global("GetItemSubClassInfo")
		if getSub then
			for sub = 1, 11 do
				local name = getSub(RECIPE_CLASS, sub)
				if name then byName[name] = sub end
			end
		end
		if GetProfessions and GetProfessionInfo then
			AddProfessions(mine, byName, GetProfessions())
		end
		if not next(mine) and GetNumSkillLines and GetSkillLineInfo then
			for i = 1, GetNumSkillLines() do
				local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
				local sub = name and not isHeader and byName[name]
				if sub then mine[sub] = { name = name, rank = rank or 0, max = maxRank or 0 } end
			end
		end
		profCache = mine
		return mine
	end
end

local KNOWN_TEXT = Global("ITEM_SPELL_KNOWN") or "Already known"
local SKILL_PATTERN
do
	local fmt = Global("ITEM_MIN_SKILL") or "Requires %s (%d)"
	fmt = fmt:gsub("%%%d%$", "%%")
	SKILL_PATTERN = "^" .. fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)") .. "$"
end

-- "Requires " in the client's language, for lines the full pattern misses
local SKILL_PREFIX = ((Global("ITEM_MIN_SKILL") or "Requires %s (%d)"):match("^(.-)%%") or "Requires ")

-- What a recipe's tooltip says for this character. nil: data not loaded.
-- known: "Already known". skill: required skill. canLearn: its requirements are not red.
-- Recipes that make an item show that item's tooltip in between (with its own "Requires
-- Level"), so only requirement lines count: the last "Requires <profession> (n)" is the
-- recipe's own; specialisation and reputation lines count when red.
local REQ_PATTERNS = {}
for _, name in ipairs({ "ITEM_REQ_SKILL", "ITEM_REQ_REPUTATION" }) do
	local fmt = Global(name)
	if fmt then
		fmt = fmt:gsub("%%%d%$", "%%")
		REQ_PATTERNS[#REQ_PATTERNS + 1] = "^" .. fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", ".+") .. "$"
	end
end
local LEVEL_PATTERN
do
	local fmt = Global("ITEM_MIN_LEVEL") or "Requires Level %d"
	fmt = fmt:gsub("%%%d%$", "%%")
	LEVEL_PATTERN = "^" .. fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%d", "%%d+") .. "$"
end

local function ParseRecipeLine(rawText, red, lineIdx, st)
	local text = rawText
	if text:find("|", 1, true) then
		text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	end
	if text:find("^%s") or text:find("%s$") then
		text = text:gsub("^%s+", ""):gsub("%s+$", "")
	end
	if text == KNOWN_TEXT then
		st.known = true
	elseif lineIdx > 1 and not text:find(LEVEL_PATTERN) then
		local _, skill = text:match(SKILL_PATTERN)
		if not skill and text:find(SKILL_PREFIX, 1, true) == 1 then skill = text:match("%((%d+)%)$") end
		if skill then
			st.skill = tonumber(skill)
			return red, nil -- the last one wins: the recipe's own
		elseif red then
			for j = 1, #REQ_PATTERNS do
				if text:find(REQ_PATTERNS[j]) then return nil, true end
			end
		end
	end
	return nil, nil
end

local function RecipeState(itemID)
	local st
	local skillRed, otherRed = false, false
	local lineIdx = 0
	local getByID = C_TooltipInfo and C_TooltipInfo.GetItemByID
	if getByID then
		local ok, data = pcall(getByID, itemID)
		local raw = ok and data and data.lines
		if raw and raw[1] then
			local surface = TooltipUtil and TooltipUtil.SurfaceArgs
			for i = 1, #raw do
				local line = raw[i]
				if surface and not line.leftText then pcall(surface, line) end
				local text = line.leftText
				if text then
					lineIdx = lineIdx + 1
					if lineIdx == 1 then
						if text == "" or text == RETRIEVING_ITEM_INFO then return nil end
						st = { known = false, canLearn = true }
					end
					local sr, orr = ParseRecipeLine(text, lineIdx > 1 and LineIsRed(line.leftColor) or false, lineIdx, st)
					if sr ~= nil then skillRed = sr end
					if orr then otherRed = true end
				end
			end
			if st then
				st.canLearn = not skillRed and not otherRed
				return st
			end
		end
	end
	local tip = OpenScanTip(itemID)
	for i = 1, tip:NumLines() do
		local fs = GetScanTipLeft(i)
		local text = fs and fs:GetText()
		if text then
			lineIdx = lineIdx + 1
			if lineIdx == 1 then
				if text == "" or text == RETRIEVING_ITEM_INFO then
					st = nil
					break
				end
				st = { known = false, canLearn = true }
			end
			local sr, orr = ParseRecipeLine(text, lineIdx > 1 and IsRed(fs:GetTextColor()) or false, lineIdx, st)
			if sr ~= nil then skillRed = sr end
			if orr then otherRed = true end
		end
	end
	tip:Hide()
	if not st then return nil end
	st.canLearn = not skillRed and not otherRed
	return st
end

local function RecipeKnownCache()
	local key = CharKey()
	db.recipeKnown[key] = db.recipeKnown[key] or {}
	return db.recipeKnown[key]
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

local SortView
do
	local SORT_FIELDS = {
		name = function(e) return e.nameLower or (e.name or ""):lower() end,
		slot = function(e) return e.inv or e.profName or "" end,
		type = function(e)
			if e.kind == "recipe" then return e.rs and e.rs.skill or 0 end
			return e.subName or ""
		end,
		level = function(e) return e.req or 0 end,
		count = function(e) return e.n or 0 end,
		price = function(e) return e.price or 0 end,
	}
	local sortGet = SORT_FIELDS.price
	local sortDesc = false

	local function CompareView(a, b)
		local x, y = sortGet(a), sortGet(b)
		if x == y then
			-- a fixed order for ties (same price, same slot …): the list must not reshuffle
			-- between two builds, or "the next row" changes under the cursor
			if (a.price or 0) ~= (b.price or 0) then return (a.price or 0) < (b.price or 0) end
			if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
			return a.source < b.source
		end
		if sortDesc then return x > y end
		return x < y
	end

	SortView = function()
		local s = db.sort
		local sKey = s and s.key or (not s and "price")
		sortGet = SORT_FIELDS[sKey] or SORT_FIELDS.price
		sortDesc = (s and s.desc) and true or false
		tsort(view, CompareView)
	end
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
local COLORS_BY_KEY = {}
local COLOR_NAMES = {}
for _, c in ipairs(COLORS) do
	COLOR_NAMES[c[1]] = c[2]
	if c[3] then
		local padded = {}
		for i, w in ipairs(c[3]) do padded[i] = " " .. w .. " " end
		COLORS_BY_KEY[c[1]] = padded
	end
end
local lookNames = {} -- look -> normalized " word1 word2 " of all items sharing the look

local function LookText(e)
	local key = e.visual or e.source
	local t = lookNames[key]
	if t then return t end
	local parts = { e.nameLower or (e.name or ""):lower() }
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
	t = " " .. tconcat(parts, " "):gsub("[^%a]", " ") .. " "
	lookNames[key] = t
	return t
end

local function ColorFits(e)
	local words = db.color and COLORS_BY_KEY[db.color]
	if not words then return true end
	local text = LookText(e)
	for i = 1, #words do
		if text:find(words[i], 1, true) then return true end
	end
	return false
end
ns.ColorFits = ColorFits

-- Frame-budgeted async verification for entries missing tooltip verdicts (e.g. recipes after
-- login/skill gain, or items whose tooltip was still loading during the scan).
local asyncVerify = { active = false, mode = nil, list = {}, failed = {}, i = 0, lastRedraw = 0, hadNil = false, retryAfter = 0, setStatus = false }

function asyncVerify.Cancel()
	asyncVerify.active = false
	asyncVerify.mode = nil
	asyncVerify.i = 0
	asyncVerify.hadNil = false
	asyncVerify.setStatus = false
	wipe(asyncVerify.list)
end

function asyncVerify.Tick()
	if not asyncVerify.active then return end
	if scan.active or not ahOpen or asyncVerify.mode ~= mode or not (ui and ui:IsShown()) then
		asyncVerify.Cancel()
		dirty = true
		return
	end
	local list = asyncVerify.list
	local failed = asyncVerify.failed
	local isRecipe = asyncVerify.mode == "recipe"
	local knownCache = isRecipe and RecipeKnownCache() or nil
	local stop = debugprofilestop() + 3.5
	local reqLoad = C_Item and C_Item.RequestLoadItemDataByID
	while asyncVerify.i < #list and debugprofilestop() < stop do
		asyncVerify.i = asyncVerify.i + 1
		local e = list[asyncVerify.i]
		if isRecipe then
			if e.rs == nil then
				local rs = RecipeState(e.id)
				if rs then
					e.rs = rs
					failed[e.id] = nil
					if rs.known and knownCache then
						knownCache[e.id] = true
						items[e.source] = nil
					end
				else
					failed[e.id] = (failed[e.id] or 0) + 1
					asyncVerify.hadNil = true
					if reqLoad then reqLoad(e.id) end
				end
			end
		else
			if e.tip == nil and not db.tipFallback then
				local tip = TipState(e.id)
				if tip then
					e.tip = tip
					failed[e.id] = nil
					if tip == "known" then
						db.tipCache[e.id] = "known"
						items[e.source] = nil
					end
				else
					failed[e.id] = (failed[e.id] or 0) + 1
					asyncVerify.hadNil = true
					if reqLoad then reqLoad(e.id) end
				end
			end
		end
	end
	local now = GetTime()
	if asyncVerify.i < #list then
		if not buy.state then
			asyncVerify.setStatus = true
			SetStatus((isRecipe and L["Checking your recipes (%d of %d) …"]
				or L["Checking your collection (%d of %d) …"]):format(asyncVerify.i, #list))
		end
		if now - asyncVerify.lastRedraw > 0.35 then
			asyncVerify.lastRedraw = now
			dirty = true
			if not buy.state and Redraw then Redraw() end
		end
		C_Timer.After(0, asyncVerify.Tick)
	else
		local hadNil = asyncVerify.hadNil
		local clearStatus = asyncVerify.setStatus
		asyncVerify.Cancel()
		asyncVerify.retryAfter = hadNil and (now + 0.35) or 0
		dirty = true
		if clearStatus and not buy.state then SetStatus("") end
		if not buy.state and Redraw then Redraw() end
	end
end

function asyncVerify.Start()
	if asyncVerify.active or not asyncVerify.list[1] or scan.active or not ahOpen then return end
	asyncVerify.active = true
	asyncVerify.mode = mode
	asyncVerify.i = 0
	asyncVerify.lastRedraw = GetTime()
	asyncVerify.hadNil = false
	asyncVerify.setStatus = false
	local delay = max(0, (asyncVerify.retryAfter or 0) - GetTime())
	C_Timer.After(delay, asyncVerify.Tick)
end

local function BuildRecipeView(queue)
	local mine = MyProfessions()
	local search = (db.search or ""):lower()
	local maxPrice = (db.maxGold or 0) * 10000
	local knownCache = RecipeKnownCache()
	local failed = asyncVerify.failed
	for _, e in pairs(items) do
		local prof = mine[e.sub]
		if prof and not e.pending
			and (db.recipeProf == "all" or db.recipeProf == e.sub)
			and (maxPrice <= 0 or e.price <= maxPrice)
			and not db.hidden[HideKey(e)]
			and not knownCache[e.id]
			and (search == "" or (e.nameLower or (e.name or ""):lower()):find(search, 1, true))
			and not Bought(e) then
			e.profName = prof.name
			local rs = e.rs
			if rs == nil then
				if queue and (failed[e.id] or 0) < 3 then queue[#queue + 1] = e end
			else
				-- the tooltip's red colour, and the skill compared with your own rank
				e.learnable = rs.canLearn and not (rs.skill and (prof.rank or 0) < rs.skill) or false
				if rs.known then
					knownCache[e.id] = true
				elseif e.learnable or not db.learnableOnly then
					view[#view + 1] = e
				end
			end
		end
	end
end

local viewScratch = { best = {}, same = {} }

local function BuildView()
	wipe(view)
	local queue = (not scan.active and not asyncVerify.active) and asyncVerify.list or nil
	if queue then wipe(queue) end
	if mode == "recipe" then
		BuildRecipeView(queue)
		SortView()
		dirty = false
		if queue and queue[1] then asyncVerify.Start() end
		return
	end
	local level = UnitLevel("player") or 0
	local search = (db.search or ""):lower()
	local searchDeep = #search >= 2
	local maxPrice = (db.maxGold or 0) * 10000
	local wantTip = queue and not db.tipFallback
	local failed = asyncVerify.failed
	local best, sameLook = viewScratch.best, viewScratch.same
	wipe(best)
	wipe(sameLook)
	for _, e in pairs(items) do
		local slot = not e.pending and SLOT_OF[e.inv]
		if slot and (db.slot == "all" or slot == db.slot)
			and (maxPrice <= 0 or e.price <= maxPrice)
			and not (db.aboveLevel and (e.req or 0) > level) then
			local hk = HideKey(e)
			if not db.hidden[hk]
				and not Bought(e)
				and (not db.classOnly or ClassFits(e)) then
				if wantTip and e.tip == nil and (failed[e.id] or 0) < 3 then
					queue[#queue + 1] = e
				end
				if db.unique then
					if LookMissing(e)
						and (search == "" or (e.nameLower or (e.name or ""):lower()):find(search, 1, true)
							or (searchDeep and LookText(e):find(search, 1, true)))
						and ColorFits(e) then
						sameLook[hk] = (sameLook[hk] or 0) + 1
						if not best[hk] or e.price < best[hk].price then best[hk] = e end
					end
				elseif SourceMissing(e)
					and (search == "" or (e.nameLower or (e.name or ""):lower()):find(search, 1, true)
						or (searchDeep and LookText(e):find(search, 1, true)))
					and ColorFits(e) then
					e.alts = nil
					view[#view + 1] = e
				end
			end
		end
	end
	for k, e in pairs(best) do
		e.alts = sameLook[k] - 1
		view[#view + 1] = e
	end
	wipe(best)
	wipe(sameLook)
	SortView()
	dirty = false
	if queue and queue[1] then asyncVerify.Start() end
end

local function Changed()
	if buy.state and buy.state ~= "buying" then
		wipe(buy)
		SyncTicker()
	end
	dirty = true
	offset = 0
	if Redraw then Redraw() end
	if settingsWin then settingsWin:Refresh() end
end
ns.Changed = Changed

---------------------------------------------------------------------------
-- Scan: one browse search for weapons and armor, grouped by item
---------------------------------------------------------------------------

local BrowseQuery
do
	local BROWSE_FILTERS = {}
	for _, name in ipairs({ "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality", "EpicQuality", "LegendaryQuality" }) do
		local v = Enum and Enum.AuctionHouseFilter and Enum.AuctionHouseFilter[name]
		if v ~= nil then BROWSE_FILTERS[#BROWSE_FILTERS + 1] = v end
	end
	local MOG_CLASSES = { { classID = 2 }, { classID = 4 } }

	BrowseQuery = function()
		local classes = MOG_CLASSES
		if scan.mode == "recipe" then
			classes = {}
			for sub in pairs(MyProfessions()) do classes[#classes + 1] = { classID = RECIPE_CLASS, subClassID = sub } end
		end
		return { searchString = "", minLevel = 0, maxLevel = 0, filters = BROWSE_FILTERS,
			itemClassFilters = classes, sorts = SORTS }
	end
end

local function KeyString(key)
	return (key.itemID or 0) .. ":" .. (key.itemLevel or 0) .. ":" .. (key.itemSuffix or 0)
end

-- The appearance source and visual ID of an auction key: from the item, else from
-- the auction house's own item data (random suffixes).
local function SourceOf(key, info)
	local visual, source = TC.GetItemInfo(key.itemID)
	if source then return source, visual end
	local link = info and info.appearanceLink
	local id = link and tonumber(link:match("transmogappearance:(%d+)"))
	if id and id > 0 then
		local ok, sInfo = pcall(TC.GetSourceInfo, id)
		if ok and type(sInfo) == "table" and sInfo.itemID == key.itemID then return id, sInfo.visualID end
	end
	return nil, nil
end

-- One recipe of the browse results. Returns false while its item data is still loading.
local function RecordRecipe(result)
	local key, price = result.itemKey, result.minPrice
	if not key or not key.itemID or not price or price <= 0 then return true end
	local _, _, _, _, icon, classID, subID = GetItemInfoInstant(key.itemID)
	if classID ~= RECIPE_CLASS or not MyProfessions()[subID] then return true end
	local info = AH.GetItemKeyInfo and AH.GetItemKeyInfo(key)
	if not info then return false end
	local name, link, q, _, req, _, _, _, _, tex = GetItemInfo(key.itemID)
	if not name or not link then return false end
	local n = result.totalQuantity or 1
	scan.listed = scan.listed + n
	local id = "r" .. key.itemID
	local e = scan.items[id]
	if not e then
		local itemName = info.itemName or name
		e = { kind = "recipe", source = id, id = key.itemID, key = key, link = link,
			name = itemName, nameLower = itemName and itemName:lower() or "",
			icon = info.iconFileID or tex or icon, quality = q or info.quality,
			class = classID, sub = subID, req = req or 0, price = price, n = 0 }
		scan.items[id] = e
	end
	e.n = e.n + n
	if price < e.price then e.price, e.key = price, key end
	return true
end

-- One browse result. Returns false while its item data is still loading.
local function Record(result)
	if scan.mode == "recipe" then return RecordRecipe(result) end
	local key, price = result.itemKey, result.minPrice
	if not key or not key.itemID or not price or price <= 0 then return true end
	local _, _, subName, inv, icon, classID, subID = GetItemInfoInstant(key.itemID)
	if (classID ~= 2 and classID ~= 4) or not SLOT_OF[inv] then return true end
	local info = AH.GetItemKeyInfo and AH.GetItemKeyInfo(key)
	if not info then return false end
	local source, visual = SourceOf(key, info)
	if not source then
		if not GetItemInfo(key.itemID) then return false end
		return true -- no appearance of its own
	end
	local can = Collectable(source)
	if can == nil then return false end -- still loading
	if not can then return true end    -- nothing to collect for you
	local _, link, q, _, req, _, _, _, _, tex = GetItemInfo(key.itemID)
	if not link then return false end
	if not visual then
		local ok, sInfo = pcall(TC.GetSourceInfo, source)
		if ok and type(sInfo) == "table" then visual = sInfo.visualID end
	end
	req = (AH.GetItemKeyRequiredLevel and AH.GetItemKeyRequiredLevel(key)) or req or 0
	local n = result.totalQuantity or 1
	scan.listed = scan.listed + n
	local e = scan.items[source]
	if not e then
		local itemName = info.itemName or link:match("%[(.-)%]")
		e = { source = source, visual = visual, id = key.itemID, key = key, link = link,
			name = itemName, nameLower = itemName and itemName:lower() or "",
			icon = info.iconFileID or tex or icon,
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
	if mode == "recipe" then
		db.lastRecipe = { v = 1, at = dataAt, listed = listed, items = items, char = CharKey() }
	else
		db.last = { v = 2, at = dataAt, listed = listed, items = items }
	end
end

local function FinishScan(failed)
	scan.active = false
	SyncTicker()
	if failed then
		scan.items, scan.pending, scan.scratch, scan.seen, scan.verify = nil, nil, nil, nil, nil
		SetStatus(L["The auction house did not answer. Try again in a moment."])
		Redraw()
		return
	end
	items, listed, dataAt = scan.items, scan.listed, time()
	scan.items, scan.pending, scan.scratch, scan.seen, scan.verify = nil, nil, nil, nil, nil
	SaveScan()
	if buy.state then
		-- buying is under way: keep the list where it is until buying finishes
		dirty = true
		Redraw()
	else
		Changed()
		if mode == "recipe" then
			SetStatus(L["Scan done: %d recipes to learn among %d recipes listed."]:format(#view, listed))
		else
			SetStatus(L["Scan done: %d uncollected appearances among %d items of gear."]:format(#view, listed))
		end
	end
end

local function StartScan()
	if not ahOpen or scan.active or buy.state == "buying" then return end
	if mode == "recipe" then
		profCache = nil
		if not next(MyProfessions()) then
			SetStatus(L["This character has no profession with recipes."])
			return
		end
	end
	asyncVerify.Cancel()
	wipe(asyncVerify.failed)
	wipe(buy)
	wipe(scan)
	scan.active, scan.phase, scan.t, scan.mode = true, "send", GetTime(), mode
	scan.items, scan.pending, scan.scratch, scan.seen, scan.listed, scan.read = {}, {}, {}, {}, 0, 0
	SetStatus(mode == "recipe" and L["Scanning recipes …"] or L["Scanning weapons and armor …"])
	SyncTicker()
	Redraw()
end

-- the browse list is complete: ask for the next part, or finish
local function Continue()
	local now = GetTime()
	scan.t = now
	if AH.HasFullBrowseResults() then
		scan.phase, scan.loadT, scan.progressT, scan.loadNextT = "loading", now, now, 0
	else
		scan.phase = "more"
	end
	SetStatus(L["Scanning … %d items read"]:format(scan.read))
end

local function ScanTick(now)
	if scan.phase == "send" then
		if AH.IsThrottledMessageSystemReady() or now - scan.t > 10 then
			scan.phase, scan.t = "wait", now
			AH.SendBrowseQuery(BrowseQuery())
		end
	elseif scan.phase == "more" then
		if AH.IsThrottledMessageSystemReady() or now - scan.t > 10 then
			scan.phase, scan.t = "wait", now
			AH.RequestMoreBrowseResults()
		end
	elseif scan.phase == "wait" then
		if now - scan.t > SCAN_WAIT then
			-- no answer: use what arrived, if anything
			if scan.read > 0 then
				scan.phase, scan.loadT, scan.progressT, scan.loadNextT = "loading", now, now, 0
			else
				FinishScan(true)
			end
		end
	elseif scan.phase == "loading" then
		-- items whose data had not loaded yet, throttled and frame-budgeted
		if scan.pending[1] then
			if now < (scan.loadNextT or 0) then return end
			local pending = scan.pending
			local still = scan.scratch
			wipe(still)
			local stop = debugprofilestop() + 4
			local n = #pending
			local finishedPass = true
			for i = 1, n do
				if i > 1 and debugprofilestop() >= stop then
					for j = i, n do still[#still + 1] = pending[j] end
					finishedPass = false
					break
				end
				if not Record(pending[i]) then still[#still + 1] = pending[i] end
			end
			if #still < n then scan.progressT = now end
			scan.pending, scan.scratch = still, pending
			wipe(pending)
			if finishedPass and still[1] then scan.loadNextT = now + 0.35 end
			if still[1] and now - scan.loadT < 60 and now - scan.progressT < INFO_WAIT then
				SetStatus(L["Loading item data (%d left) …"]:format(#still))
				return
			end
		end
		if scan.mode == "recipe" then
			-- recipes: ask each tooltip whether it is known and can be learned
			scan.phase, scan.verify, scan.vi = "verify", {}, 0
			local knownCache = RecipeKnownCache()
			for _, e in pairs(scan.items) do
				if not knownCache[e.id] then
					e.pending = true
					scan.verify[#scan.verify + 1] = e
				end
			end
			items, listed, dataAt = scan.items, scan.listed, time()
			scan.shownAt = now
			dirty = true
		else
			-- Items the tooltip already called known stay so: only the rest is asked.
			-- The list shows up right away and fills while the check runs; rows still
			-- being checked are left out until they are done.
			scan.phase, scan.verify, scan.vi, scan.cached = "verify", {}, 0, 0
			for _, e in pairs(scan.items) do
				if db.tipCache[e.id] == "known" then
					e.tip, scan.cached = "known", scan.cached + 1
				else
					e.pending = true
					scan.verify[#scan.verify + 1] = e
				end
			end
			items, listed, dataAt = scan.items, scan.listed, time()
			scan.shownAt = now
			dirty = true
		end
		if ui and ui:IsShown() and UpdateBuyButton then UpdateBuyButton() end
	elseif scan.phase == "verify" then
		-- ask the game's tooltip, about 3.5 ms per frame so frame pacing stays smooth
		local stop = debugprofilestop() + 3.5
		local list = scan.verify
		local recipes = scan.mode == "recipe"
		while scan.vi < #list and debugprofilestop() < stop do
			scan.vi = scan.vi + 1
			local e = list[scan.vi]
			if recipes then
				e.rs, e.pending = RecipeState(e.id), nil
			else
				e.tip, e.pending = TipState(e.id), nil
			end
		end
		if not buy.state then
			SetStatus((recipes and L["Checking your recipes (%d of %d) … you can start buying"]
				or L["Checking your collection (%d of %d) … you can start buying"]):format(scan.vi, #list))
		end
		if now - (scan.shownAt or 0) > 0.5 then
			-- the list grows while the check runs, without moving the row being bought
			scan.shownAt = now
			dirty = true
			if not buy.state then Redraw() end
		end
		if scan.vi >= #list and recipes then
			local knownCache = RecipeKnownCache()
			for _, e in ipairs(list) do
				if e.rs and e.rs.known then knownCache[e.id] = true end
			end
			for k, e in pairs(scan.items) do
				if knownCache[e.id] or (e.rs and e.rs.known) then scan.items[k] = nil end
			end
			FinishScan()
		elseif scan.vi >= #list then
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
				-- remember only settled "known" verdicts (never permanently cache "other")
				for _, e in ipairs(list) do
					if e.tip == "known" then db.tipCache[e.id] = "known" end
				end
				-- prune already-known items (keep "other" for completionist mode)
				for k, e in pairs(scan.items) do
					if e.tip == "known" then scan.items[k] = nil end
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
	local now = GetTime()
	wipe(buy)
	buy.e, buy.state, buy.t, buy.tried = e, "send", now, tried or {}
	buy.notBefore = pause and (now + pause) or nil
	buy.plain = keyStyle[e.id] == "plain" or not e.key
	buy.key = ItemKey(e, buy.plain)
	SetStatus(L["Checking %s …"]:format(e.link or e.name or "?"))
	SyncTicker()
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
	tremove(view, pos)
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
	local recipe = e.kind == "recipe"
	for i = 1, total do
		local info = AH.GetItemSearchResultInfo(key, i)
		local buyout = info and info.buyoutAmount or 0
		if info and info.auctionID and buyout > 0 and (not best or buyout < best.buyoutAmount)
			and not info.containsOwnerItem and not buy.tried[info.auctionID] then
			local sameItem = info.itemKey and info.itemKey.itemID == e.id
			if sameItem then
				best = info
			elseif not recipe then
				local _, source = TC.GetItemInfo(info.itemLink or e.id)
				if source then
					if source == e.source then
						best = info
					elseif db.unique and e.visual then
						local ok, sInfo = pcall(TC.GetSourceInfo, source)
						if ok and type(sInfo) == "table" and sInfo.visualID == e.visual then best = info end
					end
				end
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
		SyncTicker()
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
		SyncTicker()
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
		ns.ShowError(ERR_DB_ERROR)
		ns.PurchaseFailed(ERR_DB_ERROR, true)
	elseif buy.state == "buying" and now - buy.t > 8 then
		wipe(buy)
		SyncTicker()
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
		SyncTicker()
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
	db.bought[BoughtKey(e)] = time()
	if e.visual then db.bought["v" .. e.visual] = time() end
	if e.kind == "recipe" then
		Print(L["Bought %s for %s. Use it to learn the recipe."]:format(buy.link, Money(buy.price)))
	else
		Print(L["Bought %s for %s. Wear it or sell it to a vendor to learn the appearance."]:format(buy.link, Money(buy.price)))
	end
	local nextOne = RemoveAndNext(e)
	wipe(buy)
	SaveScan()
	if nextOne then
		scrollTo = true
		Check(nextOne, 0.5)
	else
		SyncTicker()
		Redraw()
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

local SmallTab
do
	local function AuctionatorSmallTab(A)
		return A.Config.Get(A.Config.Options.SMALL_TABS)
	end

	SmallTab = function()
		if db.smallTab ~= nil then return db.smallTab end
		local vf = Global("VendorFloorDB")
		if vf and vf.smallTab ~= nil then return vf.smallTab end
		local A = _G["Auctionator"]
		if not A then return false end
		local ok, small = pcall(AuctionatorSmallTab, A)
		return ok and small and true or false
	end
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

local BOTTOM = 48  -- room under the list
local rowsShown = 12

local function SlotName(key)
	return SLOT_NAMES[key] or SLOTS[1][2]
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
		pick.onEnter = function(self) self.hl:Show() end
		pick.onLeave = function(self) self.hl:Hide() end
		pick.onClick = function(self)
			pick:Hide()
			if pick.onPick then pick.onPick(self.key) end
		end
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
	pick.onPick = onPick
	for i, item in ipairs(list) do
		local b = pick.rows[i]
		if not b then
			b = CreateFrame("Button", nil, pick)
			b:SetHeight(20)
			b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 20)
			b:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * 20)
			b.hl = b:CreateTexture(nil, "BACKGROUND")
			b.hl:SetAllPoints()
			b.hl:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.25)
			b.hl:Hide()
			b.fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			b.fs:SetPoint("LEFT", 10, 0)
			b:SetScript("OnEnter", pick.onEnter)
			b:SetScript("OnLeave", pick.onLeave)
			b:SetScript("OnClick", pick.onClick)
			pick.rows[i] = b
		end
		b.key = item[1]
		b.fs:SetText(item[2])
		b.fs:SetTextColor(unpack(item[1] == current and C.accent or C.text))
		b:Show()
	end
	for i = #list + 1, #pick.rows do pick.rows[i]:Hide() end
	pick:SetSize(max(owner:GetWidth(), 170), #list * 20 + 8)
	pick:ClearAllPoints()
	pick:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
	pick:Show()
end

local function ProfList()
	local list = { { "all", L["All my professions"] } }
	local mine = MyProfessions()
	for sub = 1, 11 do
		if mine[sub] then list[#list + 1] = { sub, mine[sub].name } end
	end
	return list
end

local function ProfName(key)
	if key == "all" then return L["All my professions"] end
	local p = MyProfessions()[key]
	return (p and p.name) or L["All my professions"]
end

local function ShowSlotMenu(owner)
	if mode == "recipe" then
		ShowPick(owner, ProfList(), db.recipeProf, function(key)
			db.recipeProf = key
			Changed()
		end)
		return
	end
	ShowPick(owner, SLOTS, db.slot, function(key)
		db.slot = key
		Changed()
	end)
end

-- Switch between the appearance list and the recipe list. Each keeps its own scan.
local function SetMode(m)
	if m == mode or scan.active or buy.state == "buying" then return end
	asyncVerify.Cancel()
	wipe(asyncVerify.failed)
	store[mode].items, store[mode].listed, store[mode].dataAt = items, listed, dataAt
	mode, db.mode = m, m
	items, listed, dataAt = store[m].items, store[m].listed, store[m].dataAt
	wipe(buy)
	SyncTicker()
	selected = nil
	profCache = nil
	if m == "recipe" and db.recipeProf ~= "all" and not MyProfessions()[db.recipeProf] then db.recipeProf = "all" end
	SetStatus("")
	Changed()
end
ns.SetMode = SetMode

local function ColorName(key)
	return COLOR_NAMES[key] or COLORS[1][2]
end

local function HideAppearance(e)
	db.hidden[HideKey(e)] = true
	if selected == e then
		selected = nil
		wipe(buy)
		SyncTicker()
	end
	Changed()
	SetStatus(L["%s hidden. Settings bring hidden items back."]:format(e.link or e.name or "?"))
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
				tsort(t)
				text = "{" .. tconcat(t, ", ") .. "}"
			end
			parts[#parts + 1] = text
		end
		return #parts > 0 and tconcat(parts, " | ") or "nil"
	end
	add("TransmogSweep %s  ·  %s", VERSION, (GetLocale and GetLocale()) or "?")
	add("item %s  %s", tostring(e.id), tostring(e.name))
	if e.kind == "recipe" then
		local mine = MyProfessions()
		add("recipe subclass=%s profession=%s rank=%s", tostring(e.sub), tostring(mine[e.sub] and mine[e.sub].name),
			tostring(mine[e.sub] and mine[e.sub].rank))
		local st = RecipeState(e.id)
		add("state now: known=%s canLearn=%s skill=%s", tostring(st and st.known), tostring(st and st.canLearn), tostring(st and st.skill))
		add("cached known=%s learnableOnly=%s learnable=%s", tostring(RecipeKnownCache()[e.id]), tostring(db.learnableOnly), tostring(e.learnable))
		add("parser 3  KNOWN=%s  SKILL=%s  PREFIX=%s", KNOWN_TEXT, SKILL_PATTERN, SKILL_PREFIX)
		add("tooltip lines (red marked with !):")
		for _, l in ipairs(ScanTipLines(e.id)) do
			add("  %s[%s]", l[2] and "! " or "", (l[1]:gsub("|", "||"):gsub("\r", "\\r"):gsub("\n", "\\n")))
		end
		add("purchase log:")
		for _, line in ipairs(log) do add("  %s", line) end
		return ns.ShowDiag(tconcat(out, "\n"))
	end
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
	ns.ShowDiag(tconcat(out, "\n"))
end

function ns.ShowDiag(text)
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
			{ L["Preview"], function(x) if x.link then DressUpItemLink(x.link) end end },
			{ L["Hide this appearance"], function(x) HideAppearance(x) end, L["Hide this recipe"] },
			{ L["Wrong? Show diagnosis"], function(x) Diagnose(x) end },
		}
		for i, en in ipairs(entries) do
			local b = FlatButton(rowMenu, 200, 22)
			b:SetPoint("TOPLEFT", 8, -28 - (i - 1) * 26)
			b:SetText(en[1])
			b.labels = { en[1], en[3] or en[1] }
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
	for _, b in ipairs(rowMenu.buttons) do b:SetText(b.labels[e.kind == "recipe" and 2 or 1]) end
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

UpdateBuyButton = function()
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

local HEADS = {
	mog = { name = L["Item"], price = L["Price"], count = L["Auctions"], level = L["Level"], type = L["Type"], slot = L["Slot"] },
	recipe = { name = L["Recipe"], price = L["Price"], count = L["Auctions"], level = L["Level"], type = L["Skill"], slot = L["Profession"] },
}

local function RedrawRows()
	if not ui or not ui:IsShown() then return end
	UpdateScroll()
	for i, row in ipairs(ui.rows) do
		local e = i <= rowsShown and view[offset + i]
		row.e = e or nil
		if e then
			row.icon:SetTexture(e.icon)
			local r, g, b = 1, 1, 1
			local q = e.quality
			if not q then
				q = select(3, GetItemInfo(e.id))
				e.quality = q
			end
			local qc = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
			if qc then r, g, b = qc.r, qc.g, qc.b end
			row.name:SetText(e.name or e.link or "?")
			row.name:SetTextColor(r or 1, g or 1, b or 1)
			if e.kind == "recipe" then
				row.slot:SetText(e.profName or "")
				local skill = e.rs and e.rs.skill
				row.type:SetText(skill and (e.learnable and tostring(skill) or ("|cffff4040" .. skill .. "|r")) or "")
			else
				row.slot:SetText(_G[e.inv] or "")
				row.type:SetText(e.subName or "")
			end
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
end

local function RedrawChrome()
	local s = db.sort
	local sKey = s and s.key or (not s and "price")
	local sDesc = s and s.desc
	local heads = HEADS[mode]
	for key, h in pairs(ui.headers) do
		h.text = heads[key] or h.text
		h.label:SetTextColor(unpack(key == sKey and C.accent or C.gold))
		if key == sKey then
			local arrow = sDesc and "|TInterface\\Buttons\\Arrow-Down-Up:12:12:0:-2|t" or "|TInterface\\Buttons\\Arrow-Up-Up:12:12:0:2|t"
			h.label:SetText(h.text .. " " .. arrow)
		else
			h.label:SetText(h.text)
		end
	end
	local recipes = mode == "recipe"
	if not dataAt and not scan.active then
		ui.info:SetText(recipes and L["No scan yet. Click Scan: it reads the recipes of your professions only and takes a few seconds."]
			or L["No scan yet. Click Scan: it reads weapons and armor only and takes a few seconds."])
	elseif dataAt then
		ui.info:SetText((recipes and L["%d recipes listed · %d recipes in the scan · scanned %s"]
			or L["%d appearances listed · %d items of gear in the scan · scanned %s"]):format(#view, listed, Ago(dataAt)))
	else
		ui.info:SetText("")
	end
	ui.empty:SetText(recipes and L["No recipe left to learn with these filters."] or L["Nothing left to collect with these filters."])
	ui.empty:SetShown(dataAt ~= nil and #view == 0 and not scan.active)
	ui.slot:SetText((recipes and ProfName(db.recipeProf) or SlotName(db.slot)) .. "  |cffa335eev|r")
	ui.color:SetText(ColorName(db.color or "any") .. "  |cffa335eev|r")
	ui.unique:Sync()
	ui.class:Sync()
	ui.learnable:Sync()
	ui.unique:SetShown(not recipes)
	ui.class:SetShown(not recipes)
	ui.color:SetShown(not recipes)
	ui.learnable:SetShown(recipes)
	-- the chosen list: tick and accent colour, like the switches
	local tick = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t "
	ui.modeMog:SetText((recipes and "" or tick) .. L["Appearances"])
	ui.modeRecipe:SetText((recipes and tick or "") .. L["Recipes"])
	ui.modeMog:SetOn(not recipes)
	ui.modeRecipe:SetOn(recipes)
	local locked = scan.active or buy.state == "buying"
	ui.modeMog:SetEnabled(not locked or not recipes)
	ui.modeRecipe:SetEnabled(not locked or recipes)
	UpdateScanButton()
	UpdateBuyButton()
end

Redraw = function()
	if not ui or not ui:IsShown() then return end
	if dirty and not buy.state then BuildView() end
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
	RedrawRows()
	RedrawChrome()
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

-- Debounce typing in search and max-gold boxes (~0.18s) without per-keystroke closures.
local debounce = { searchDue = 0, searchActive = false, maxDue = 0, maxActive = false }
function debounce.ApplySearch()
	debounce.searchDue = 0
	if not ui or not ui.search then return end
	local text = ui.search:GetText() or ""
	if text ~= db.search then
		db.search = text
		Changed()
	end
end
function debounce.OnSearch()
	local left = debounce.searchDue - GetTime()
	if left > 0.01 then
		C_Timer.After(left, debounce.OnSearch)
		return
	end
	debounce.searchActive = false
	if debounce.searchDue > 0 then debounce.ApplySearch() end
end
function debounce.ApplyMax()
	debounce.maxDue = 0
	if not ui or not ui.maxBox then return end
	local v = tonumber(ui.maxBox:GetText()) or 0
	if v ~= db.maxGold then
		db.maxGold = v
		Changed()
	end
end
function debounce.OnMax()
	local left = debounce.maxDue - GetTime()
	if left > 0.01 then
		C_Timer.After(left, debounce.OnMax)
		return
	end
	debounce.maxActive = false
	if debounce.maxDue > 0 then debounce.ApplyMax() end
end

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
	search:HookScript("OnEnterPressed", debounce.ApplySearch)
	search:HookScript("OnTextChanged", function(self)
		local text = self:GetText() or ""
		if text == "" then
			debounce.ApplySearch()
			return
		end
		if text == db.search then
			debounce.searchDue = 0
			return
		end
		debounce.searchDue = GetTime() + 0.18
		if not debounce.searchActive then
			debounce.searchActive = true
			C_Timer.After(0.18, debounce.OnSearch)
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
	maxBox:SetScript("OnEnterPressed", function(self)
		debounce.ApplyMax()
		self:ClearFocus()
	end)
	maxBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	maxBox:HookScript("OnTextChanged", function(self)
		local text = self:GetText() or ""
		if text == "" then
			debounce.ApplyMax()
			return
		end
		local v = tonumber(text) or 0
		if v == db.maxGold then
			debounce.maxDue = 0
			return
		end
		debounce.maxDue = GetTime() + 0.18
		if not debounce.maxActive then
			debounce.maxActive = true
			C_Timer.After(0.18, debounce.OnMax)
		end
	end)
	ui.maxBox = maxBox
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
	-- mode switch: appearances or recipes
	ui.modeMog = FlatButton(ui, 112, 22)
	ui.modeMog:SetPoint("TOPLEFT", 64, -40)
	ui.modeMog:SetText(L["Appearances"])
	ui.modeMog:SetScript("OnClick", function() SetMode("mog") end)
	Tip(ui.modeMog, L["Appearances"], L["Transmog appearances you have not collected yet."])
	ui.modeRecipe = FlatButton(ui, 94, 22)
	ui.modeRecipe:SetPoint("LEFT", ui.modeMog, "RIGHT", 2, 0)
	ui.modeRecipe:SetText(L["Recipes"])
	ui.modeRecipe:SetScript("OnClick", function() SetMode("recipe") end)
	Tip(ui.modeRecipe, L["Recipes"], L["Recipes for this character's professions it has not learned yet, cheapest first."])

	ui.unique = FlatToggle(ui, L["Unique appearances"], 170, function() return db.unique end,
		function(v) db.unique = v end,
		L["One row per look: many items share an appearance. Shows the cheapest item for each look you do not have, and hides looks you already know through another item. Off: every item whose own appearance source you lack (completionist)."])
	ui.unique:SetPoint("LEFT", ui.modeRecipe, "RIGHT", 12, 0)
	ui.learnable = FlatToggle(ui, L["Learnable now"], 150, function() return db.learnableOnly end,
		function(v) db.learnableOnly = v end,
		L["Only recipes your character can learn right now: skill, level and other requirements met. Off: also recipes for later, their required skill shown in red."])
	ui.learnable:SetPoint("LEFT", ui.modeRecipe, "RIGHT", 12, 0)
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
	end
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
			if e.link then
				GameTooltip:SetHyperlink(e.link)
			else
				GameTooltip:SetItemByID(e.id)
			end
			GameTooltip:AddLine(" ")
			if e.kind == "recipe" then
				GameTooltip:AddLine(L["Recipe not learned"], 0.80, 0.50, 1)
				if not e.learnable then GameTooltip:AddLine(L["You cannot learn it yet."], 1, 0.25, 0.25) end
			else
				GameTooltip:AddLine(L["Appearance not collected"], 0.80, 0.50, 1)
			end
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
				if e.link then DressUpItemLink(e.link) end
			elseif IsModifiedClick("CHATLINK") then
				if e.link then ChatEdit_InsertLink(e.link) end
			else
				Check(e)
			end
		end)
		ui.rows[i] = row
	end
	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function(_, delta)
		local maxOffset = max(#view - rowsShown, 0)
		local nextOffset = max(0, min(offset - delta * 3, maxOffset))
		if nextOffset == offset then return end
		offset = nextOffset
		RedrawRows()
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
		local maxOffset = max(#view - rowsShown, 0)
		local nextOffset = max(0, min(floor(value + 0.5), maxOffset))
		if nextOffset == offset then return end
		offset = nextOffset
		RedrawRows()
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
	ui.info:SetPoint("BOTTOMLEFT", 12, 9)
	ui.info:SetPoint("RIGHT", ui.buy, "LEFT", -12, 0)
	ui.status:SetPoint("BOTTOMLEFT", 12, 25)
	ui.status:SetPoint("RIGHT", ui.buy, "LEFT", -12, 0)
	ui.status:SetTextColor(unpack(C.text))
	ui.info:SetJustifyH("LEFT")
	ui.info:SetTextColor(unpack(C.muted))

	ui:SetScript("OnShow", function()
		Layout()
		Redraw()
	end)
	ui:SetScript("OnHide", function()
		if pick then pick:Hide() end
		if rowMenu then rowMenu:Hide() end
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

local RegisterSettings
do
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

		w:Header(250, -150, L["Recipes"])
		w:Check(250, -174, L["Learnable now"], L["Only recipes your character can learn right now: skill, level and other requirements met."],
			function() return db.learnableOnly end, function(v) db.learnableOnly = v and true or false Changed() end)

		w:Text(X, -250, L["Appearances count account-wide: a look learned on any of your characters is known. Recipes count per character, for the professions it has. Buying is always a click of your own."], 430)
	end

	local function EnsureSettings()
		if not settingsWin then BuildSettings() end
		settingsWin:Refresh()
		return settingsWin
	end

	function ns.ToggleSettings()
		EnsureSettings():Toggle()
	end

	function TransmogSweep_OnCompartmentClick()
		ns.ToggleSettings()
	end

	RegisterSettings = function()
		if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnCategory) then return end
		local category, layout = Settings.RegisterVerticalLayoutCategory("TransmogSweep")
		if layout and CreateSettingsButtonInitializer then
			layout:AddInitializer(CreateSettingsButtonInitializer(L["TransmogSweep has its own settings window"], L["Open"], function()
				if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
				EnsureSettings():Show()
			end, L["The window can be dragged anywhere and stays open while you play."], true))
		end
		Settings.RegisterAddOnCategory(category)
	end
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
	if buy.state ~= "buying" then return end
	if issecretvalue and issecretvalue(msg) then return end -- lines the game hides from addons
	if ERR_DB_ERROR and msg == ERR_DB_ERROR and GetTime() < hideDbErrorUntil then
		hideDbErrorUntil = 0
		UIErrorsFrame:Clear()
	end
end
if UIErrorsFrame then
	if UIErrorsFrame.AddExternalErrorMessage then hooksecurefunc(UIErrorsFrame, "AddExternalErrorMessage", OnErrorShown) end
	hooksecurefunc(UIErrorsFrame, "AddMessage", OnErrorShown)
end
ns.ExpectDbError = function() hideDbErrorUntil = GetTime() + 1.5 end

local function ClearPending(t)
	if not t then return end
	for _, e in pairs(t) do e.pending = nil end
end

local coalesce = { collection = false, recipes = false }
function coalesce.FlushCollection()
	coalesce.collection = false
	wipe(known.src)
	wipe(known.vis)
	dirty = true
	if ui and ui:IsShown() and not buy.state then Redraw() end
end
local function CollectionChanged()
	if coalesce.collection then return end
	coalesce.collection = true
	C_Timer.After(0, coalesce.FlushCollection)
end

-- A recipe learned or a skill point gained: the recipes are asked again.
function coalesce.FlushRecipes()
	coalesce.recipes = false
	profCache = nil
	wipe(asyncVerify.failed)
	local recipeItems = mode == "recipe" and items or store.recipe.items or {}
	for _, e in pairs(recipeItems) do e.rs = nil end
	if mode == "recipe" then
		if asyncVerify.active and asyncVerify.mode == "recipe" then asyncVerify.Cancel() end
		dirty = true
		if ui and ui:IsShown() and not buy.state then Redraw() end
	end
end
local function RecipesChanged()
	if coalesce.recipes then return end
	coalesce.recipes = true
	C_Timer.After(0, coalesce.FlushRecipes)
end
ns.RecipesChanged = RecipesChanged

function handlers.ADDON_LOADED(name)
	if name ~= ADDON then return end
	TransmogSweepDB = TransmogSweepDB or {}
	db = TransmogSweepDB
	for k, v in pairs(defaults) do
		if db[k] == nil then db[k] = v end
	end
	db.hidden = db.hidden or {}
	db.bought = db.bought or {}
	db.tipCache = db.tipCache or {}  -- itemID -> "known": settled tooltip verdicts
	for id, v in pairs(db.tipCache) do
		if v ~= "known" then db.tipCache[id] = nil end
	end
	db.recipeKnown = db.recipeKnown or {} -- character -> itemID -> true: recipes already learned
	db.lastFull = nil
	local now = time()
	for k, t in pairs(db.bought) do
		if now - t > KEEP_BOUGHT then db.bought[k] = nil end
	end
	-- the last scan comes back for an hour, so the tab is not empty until the next one
	local last = db.last
	if last and last.v == 2 and last.items and now - (last.at or 0) < KEEP_SCAN then
		items, listed, dataAt = last.items, last.listed or 0, last.at
		for _, e in pairs(items) do
			e.pending = nil
			e.nameLower = e.nameLower or (e.name or ""):lower()
		end
	else
		db.last = nil
	end
	store.mog.items, store.mog.listed, store.mog.dataAt = items, listed, dataAt
	-- the last recipe scan, if it was this character's
	local lr = db.lastRecipe
	if lr and lr.v == 1 and lr.items and lr.char == CharKey() and now - (lr.at or 0) < KEEP_SCAN then
		for _, e in pairs(lr.items) do
			e.pending, e.rs = nil, nil -- asked again: skill may have changed
			e.nameLower = e.nameLower or (e.name or ""):lower()
		end
		store.recipe.items, store.recipe.listed, store.recipe.dataAt = lr.items, lr.listed or 0, lr.at
	else
		db.lastRecipe = nil
	end
	if db.mode == "recipe" then
		mode = "recipe"
		items, listed, dataAt = store.recipe.items, store.recipe.listed, store.recipe.dataAt
	else
		db.mode = "mog"
	end
	local ok, err = pcall(RegisterSettings)
	if not ok then Print(err) end
	if events then events:UnregisterEvent("ADDON_LOADED") end
end

function handlers.AUCTION_HOUSE_SHOW()
	ahOpen = true
	if events then pcall(events.RegisterEvent, events, "UI_ERROR_MESSAGE") end
	wipe(asyncVerify.failed)
	store[mode].items, store[mode].listed, store[mode].dataAt = items, listed, dataAt
	for m, st in pairs(store) do
		if st.dataAt and time() - st.dataAt >= KEEP_SCAN then
			st.items, st.listed, st.dataAt = {}, 0, nil
			if m == "recipe" then db.lastRecipe = nil else db.last = nil end
			dirty = true
		end
	end
	items, listed, dataAt = store[mode].items, store[mode].listed, store[mode].dataAt
	C_Timer.After(0, CreateTab)
	C_Timer.After(0.3, CreateTab)
end

function handlers.AUCTION_HOUSE_CLOSED()
	ahOpen = false
	if events then pcall(events.UnregisterEvent, events, "UI_ERROR_MESSAGE") end
	asyncVerify.Cancel()
	debounce.searchDue, debounce.maxDue = 0, 0
	wipe(buy)
	selected = nil
	ClearPending(items)
	ClearPending(scan.items)
	ClearPending(store.mog.items)
	ClearPending(store.recipe.items)
	if pick then pick:Hide() end
	if rowMenu then rowMenu:Hide() end
	if scan.active then
		wipe(scan)
		scan.active = false
		dirty = true
		SetStatus(L["Scan stopped: the auction house was closed."])
	end
	SyncTicker()
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

local LEARN_PATTERN = ERR_LEARN_RECIPE_S and ("^" .. ERR_LEARN_RECIPE_S:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", ".+") .. "$")
function handlers.CHAT_MSG_SYSTEM(msg)
	if issecretvalue and issecretvalue(msg) then return end
	if LEARN_PATTERN and type(msg) == "string" and msg:find(LEARN_PATTERN) then C_Timer.After(0.5, RecipesChanged) end
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

handlers.TRANSMOG_COLLECTION_UPDATED = CollectionChanged
function handlers.TRANSMOG_COLLECTION_SOURCE_ADDED(source)
	local mogItems = mode == "mog" and items or store.mog.items or {}
	local learned = source and mogItems[source]
	local itemID = learned and learned.id
	local visualID = learned and learned.visual
	if source and (not itemID or not visualID) then
		local ok, info = pcall(TC.GetSourceInfo, source)
		if ok and type(info) == "table" then
			itemID = itemID or info.itemID
			visualID = visualID or info.visualID
		end
	end
	if db and source then
		db.bought[source] = nil
		if visualID then db.bought["v" .. visualID] = nil end
		if itemID then db.tipCache[itemID] = "known" end
	end
	if learned then
		learned.tip = "known"
		if not db.tipFallback and not buy.state then mogItems[source] = nil end
	end
	if visualID then
		for _, e in pairs(mogItems) do
			if e.visual and e.visual == visualID and e.tip == "unknown" then e.tip = "other" end
		end
	end
	CollectionChanged()
end

handlers.NEW_RECIPE_LEARNED = RecipesChanged
handlers.LEARNED_SPELL_IN_TAB = RecipesChanged
handlers.SKILL_LINES_CHANGED = RecipesChanged

do
	events = CreateFrame("Frame")
	events:Hide()
	for event in pairs(handlers) do
		if event ~= "UI_ERROR_MESSAGE" then pcall(events.RegisterEvent, events, event) end
	end
	events:SetScript("OnEvent", function(_, event, ...)
		local ok, err = pcall(handlers[event], ...)
		if not ok then Print(err) end
	end)

	local elapsed = 0
	local function Tick(now, runBuy)
		if scan.active then ScanTick(now) end
		if runBuy and buy.state then BuyTick(now) end
	end

	events:SetScript("OnUpdate", function(_, dt)
		if not SyncTicker() then
			elapsed = 0
			return
		end
		elapsed = elapsed + dt
		local verify = scan.active and scan.phase == "verify"
		local tick10 = elapsed >= 0.1
		if not verify and not tick10 then return end
		if tick10 then elapsed = 0 end
		local now = GetTime()
		local ok, err = pcall(Tick, now, tick10)
		if not ok then
			Print(err)
			ClearPending(scan.items)
			ClearPending(items)
			wipe(scan)
			scan.active = false
			wipe(buy)
			dirty = true
			if ui and ui:IsShown() then Redraw() end
		end
		if not SyncTicker() then elapsed = 0 end
	end)
end
