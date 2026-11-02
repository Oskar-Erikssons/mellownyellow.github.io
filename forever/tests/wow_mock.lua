-- A small stand-in for the WoW: Forever client, enough to run Forever Guide end to end in tests.
-- Signatures follow the client's own code on the forever branch of wow-ui-source.
local mock = { printed = {}, calls = {}, timers = {}, frames = {}, hooks = {}, tooltipCalls = {} }
MOCK = mock
local function noop() end
local function record(name) return function(...) table.insert(mock.calls, { name = name, args = { ... } }) return true end end
function mock.Called(name)
    local n = 0
    for _, c in ipairs(mock.calls) do if c.name == name then n = n + 1 end end
    return n
end
function mock.LastArgs(name)
    for i = #mock.calls, 1, -1 do if mock.calls[i].name == name then return mock.calls[i].args end end
end

------------------------------------------------------------------------ widgets
local Widget = {}
local function newWidget(kind, parent, name, template)
    local w = setmetatable({ kind = kind, parent = parent, name = name, scripts = {}, events = {}, attrs = {},
        shown = true, template = template }, Widget)
    if name then _G[name] = w end
    mock.frames[w] = true
    if template and template:find("ContainerFrameItemButtonTemplate") then
        w.Cooldown = newWidget("Cooldown", w)
        function w:SetBagID(id) self:SetAttribute("bagid", id) end
        function w:GetBagID() return self.attrs.bagid or self.parent:GetID() end
    end
    if template and template:find("UIPanelButtonTemplate") then w.shown = true end
    return w
end
-- Like real frames: unknown methods (capitalised) do nothing, unknown fields are nil.
Widget.__index = function(_, k)
    local v = rawget(Widget, k)
    if v ~= nil then return v end
    if type(k) == "string" and k:match("^[A-Z]") then return noop end
end
function Widget:SetScript(n, fn) self.scripts[n] = fn end
function Widget:GetScript(n) return self.scripts[n] end
function Widget:HookScript(n, fn)
    local old = self.scripts[n]
    self.scripts[n] = function(...) if old then old(...) end fn(...) end
end
function Widget:RegisterEvent(e) self.events[e] = true end
function Widget:RegisterUnitEvent(e) self.events[e] = true end
function Widget:UnregisterEvent(e) self.events[e] = nil end
function Widget:UnregisterAllEvents() self.events = {} end
function Widget:Show() local was = self.shown self.shown = true if not was and self.scripts.OnShow then self.scripts.OnShow(self) end end
function Widget:Hide() self.shown = false end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:IsShown() return self.shown end
function Widget:IsVisible() return self.shown end
function Widget:SetID(id) self.id = id end
function Widget:GetID() return self.id or 0 end
function Widget:SetSize(w, h) self.w, self.h = w, h end
function Widget:SetWidth(w) self.w = w end
function Widget:SetHeight(h) self.h = h end
function Widget:GetWidth() return self.w or 100 end
function Widget:GetHeight() return self.h or 20 end
function Widget:GetStringHeight() return 12 end
function Widget:GetStringWidth() return 50 end
function Widget:SetText(t) self.text = t end
function Widget:SetFormattedText(f, ...) self.text = string.format(f, ...) end
function Widget:GetText() return self.text or "" end
function Widget:CreateFontString() return newWidget("FontString", self) end
function Widget:CreateTexture() return newWidget("Texture", self) end
function Widget:CreateAnimationGroup() return newWidget("AnimationGroup", self) end
function Widget:CreateAnimation() return newWidget("Animation", self) end
function Widget:GetParent() return self.parent end
function Widget:GetName() return self.name end
function Widget:SetChecked(v) self.checked = v end
function Widget:GetChecked() return self.checked end
function Widget:IsMouseOver() return false end
function Widget:GetObjectType() return self.kind end
function Widget:SetEnabled(v) self.enabled = v end
function Widget:IsEnabled() return self.enabled ~= false end
function Widget:SetAttribute(k, v) self.attrs[k] = v end
function Widget:GetAttribute(k) return self.attrs[k] end
function Widget:GetRight() return 100 end
function Widget:GetLeft() return 0 end
function Widget:GetTop() return 100 end
function Widget:GetEffectiveScale() return 1 end
function Widget:GetRegions() end
function Widget:GetChildren() end
function Widget:GetItem() return nil end
function Widget:GetColorRGB() return 1, 0, 0 end
function Widget:Click(button) if self.scripts.OnClick then self.scripts.OnClick(self, button or "LeftButton") end end

function CreateFrame(kind, name, parent, template) return newWidget(kind, parent, name, template) end

function mock.Fire(event, ...)
    local list = {}
    for f in pairs(mock.frames) do if f.events[event] and f.scripts.OnEvent then table.insert(list, f) end end
    for _, f in ipairs(list) do f.scripts.OnEvent(f, event, ...) end
end

function mock.RunTimers(limit)
    for _ = 1, limit or 50 do
        local pending = mock.timers
        if #pending == 0 then return end
        mock.timers = {}
        for _, fn in ipairs(pending) do fn() end
    end
end

------------------------------------------------------------------------ globals and helpers
UIParent = newWidget("Frame", nil, "UIParent")
GameTooltip = newWidget("GameTooltip", UIParent, "GameTooltip")
ItemRefTooltip = newWidget("GameTooltip", UIParent, "ItemRefTooltip")
ColorPickerFrame = newWidget("Frame", UIParent, "ColorPickerFrame")
QuestFrame = newWidget("Frame", UIParent, "QuestFrame")
QuestFrameDetailPanel = newWidget("Frame", QuestFrame, "QuestFrameDetailPanel")
MerchantFrame = newWidget("Frame", UIParent, "MerchantFrame")
AuctionHouseFrame = newWidget("Frame", UIParent, "AuctionHouseFrame")
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) table.insert(mock.printed, msg) end }
UISpecialFrames, SlashCmdList = {}, {}
ChatFontNormal = {}
NUM_BAG_SLOTS, NUM_REAGENTBAG_SLOTS, BANK_CONTAINER, NUM_BANKBAGSLOTS = 4, 0, -1, 6
WOW_PROJECT_ID = 18
unpack = unpack or table.unpack
time, date = os.time, os.date
tinsert, tremove = table.insert, table.remove
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strsplit(sep, s) local t = {} for p in (s .. sep):gmatch("(.-)" .. sep) do t[#t + 1] = p end return unpack(t) end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function issecretvalue() return false end
function hooksecurefunc(a, b, c)
    local tbl, name, fn = _G, a, b
    if type(a) == "table" then tbl, name, fn = a, b, c end
    local orig = tbl[name] or noop
    tbl[name] = function(...) local r = { orig(...) } fn(...) return unpack(r) end
end
local clock = 1000
function GetTime() clock = clock + 0.1 return clock end
C_Timer = {
    After = function(_, fn) table.insert(mock.timers, fn) end,
    NewTicker = function() return { Cancel = noop } end,
}
for _, n in ipairs({ "GameTooltip_Hide", "SearchBoxTemplate_OnTextChanged", "SetItemButtonTexture", "SetItemButtonCount",
    "SetItemButtonQuality", "SetItemButtonDesaturated", "CooldownFrame_Set", "ToggleAllBags", "OpenAllBags", "CloseAllBags",
    "ToggleBackpack", "OpenBackpack", "CloseBackpack" }) do _G[n] = noop end

function GetBuildInfo() return "1.6.0", "70338", "Oct 1 2026", 16001 end
function GetLocale() return "enUS" end
function InCombatLockdown() return false end
function GetMoney() return 123456 end
function GetNetStats() return 0, 0, 52, 61 end
function GetRealZoneText() return "Elwynn Forest" end
function GetMinimapZoneText() return "Goldshire" end
function GetNormalizedRealmName() return nil end
function UnitName() return "Oskar" end
function UnitFullName() return "Oskar", "Stormbringer" end
function UnitClass() return "Mage", "MAGE" end
function UnitRace() return "Gnome", "Gnome" end
function UnitLevel() return 20 end
function UnitSex() return 2 end
function UnitFactionGroup() return "Alliance" end
function UnitStat() return 20, 25, 0, 0 end
function UnitHealthMax() return 600 end
function UnitPowerMax() return 1200 end
function UnitAttackPower() return 40, 0, 0 end
function UnitRangedAttackPower() return 10, 0, 0 end
function UnitDamage() return 10, 20, 0, 0 end
function UnitAttackSpeed() return 2.5 end
function UnitRangedDamage() return 0 end
function GetCritChance() return 5 end
function GetRangedCritChance() return 5 end
function GetSpellCritChance() return 6 end
function GetSpellBonusDamage() return 20 end
function GetSpellBonusHealing() return 10 end
function GetHitModifier() return 0 end
function GetSpellHitModifier() return 0 end
function GetManaRegen() return 1, 2 end
function GetInventoryItemID(_, slot) return slot == 11 and 999 or nil end
function GetInventoryItemLink(_, slot) return slot == 11 and "|Hitem:999|h[Old Ring]|h" or nil end
PlaySoundFile = function() return true, 7 end
StopSound = record("StopSound")

Enum = {
    SpellBookSpellBank = { Player = 0 }, SpellBookItemType = { Spell = 1 }, ItemCommodityStatus = { Item = 1, Commodity = 2 },
    AuctionHouseSortOrder = { Price = 0 }, AuctionStatus = { Active = 0 }, TooltipDataType = { Item = 0 },
}
ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) mock.tooltipPost = fn end }

------------------------------------------------------------------------ items and bags
local ITEMS = {
    [2589] = { "Linen Cloth", 1, 13, 7, "" }, [117] = { "Tough Jerky", 0, 1, 0, "" }, [999] = { "Old Ring", 2, 50, 4, "INVTYPE_FINGER" },
    [1001] = { "Band of Wisdom", 2, 80, 4, "INVTYPE_FINGER" },
}
local BAG = { [1] = { 2589, 20 }, [2] = { 2589, 7 }, [3] = { 117, 4 }, [4] = { 1001, 1 } }
local function link(id) return "|cffffffff|Hitem:" .. id .. "::|h[" .. ITEMS[id][1] .. "]|h|r" end
C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 16 or (bag >= 1 and bag <= 4) and 4 or (bag == -1 and 24 or 0) end,
    GetContainerNumFreeSlots = function() return 10 end,
    GetContainerItemInfo = function(bag, slot)
        local it = bag == 0 and BAG[slot] or (bag == -1 and slot == 1 and { 2589, 40 })
        if not it then return nil end
        local d = ITEMS[it[1]]
        return { itemID = it[1], stackCount = it[2], quality = d[2], iconFileID = 1, hyperlink = link(it[1]), isBound = false, isLocked = false }
    end,
    GetContainerItemCooldown = function() return 0, 0, 0 end,
    UseContainerItem = record("UseContainerItem"),
    SortBags = record("SortBags"),
}
C_Item = {
    GetItemInfo = function(id)
        local d = ITEMS[id] if not d then return nil end
        return d[1], link(id), d[2], 10, 1, "", "", 20, d[5], 1, d[3], d[4]
    end,
    GetItemInfoInstant = function(l) local id = tonumber(l:match("item:(%d+)")) return id, "", "", ITEMS[id] and ITEMS[id][5] or "" end,
    GetItemStats = function(l)
        local id = tonumber(l:match("item:(%d+)"))
        return id == 1001 and { ITEM_MOD_INTELLECT_SHORT = 8 } or { ITEM_MOD_INTELLECT_SHORT = 2 }
    end,
    GetItemCount = function() return 27 end,
    DoesItemExist = function() return true end,
    DoesItemExistByID = function(id) return ITEMS[id] ~= nil end,
    GetItemIconByID = function() return 1 end,
    GetItemNameByID = function(id) return ITEMS[id] and ITEMS[id][1] end,
}

------------------------------------------------------------------------ spells, talents, trainer, professions
C_SpellBook = {
    GetNumSpellBookSkillLines = function() return 1 end,
    GetSpellBookSkillLineInfo = function() return { itemIndexOffset = 0, numSpellBookItems = 2 } end,
    GetSpellBookItemInfo = function(slot) return { spellID = 100 + slot, itemType = 1, isPassive = false } end,
}
local SPELL_NAMES = { [101] = "Fireball", [102] = "Fire Blast", [1001] = "Improved Frostbolt", [1002] = "Ice Shards", [1003] = "Shatter" }
C_Spell = {
    GetSpellInfo = function(id) return { name = SPELL_NAMES[id] or ("Spell " .. id), castTime = id == 101 and 2500 or 0 } end,
    GetSpellName = function(id) return SPELL_NAMES[id] end,
    GetSpellDescription = function(id) return id == 101 and "Causes 14 to 22 Fire damage." or "Blasts the enemy for 24 to 32 Fire damage." end,
    GetSpellPowerCost = function() return { { type = 0, cost = 30 } } end,
}
C_TooltipInfo = { GetSpellByID = function(id) return { lines = { { leftText = "x", rightText = id == 102 and "8 sec cooldown" or nil } } } end }
C_ClassTalents = { GetActiveConfigID = function() return 1 end }
C_Traits = {
    GetConfigInfo = function() return { treeIDs = { 10 } } end,
    GetTreeNodes = function() return { 1, 2, 3 } end,
    GetNodeInfo = function(_, id)
        local pos = { [1] = { 1200, 600 }, [2] = { 1800, 600 }, [3] = { 1200, 1200 } }
        return { posX = pos[id][1], posY = pos[id][2], maxRanks = id == 3 and 1 or 5, ranksPurchased = id == 1 and 2 or 0,
            isVisible = true, entryIDs = { id }, visibleEdges = id == 1 and { { targetNode = 3 } } or {} }
    end,
    GetEntryInfo = function(_, id) return { definitionID = id } end,
    GetDefinitionInfo = function(id) return { spellID = 1000 + id } end,
    GetTreeCurrencyInfo = function() return { { quantity = 1 } } end,
}
function GetNumTrainerServices() return 2 end
function GetTrainerServiceInfo(i) return i == 1 and "Fireball" or "Frost Nova", i == 1 and "used" or "available", 1, i == 1 and 1 or 22, "Rank " .. i end
function GetTrainerServiceCost(i) return i * 100 end
function IsTradeskillTrainer() return false end
function GetProfessions() return 1, nil, nil, nil, nil end
function GetProfessionInfo() return "Mining", 1, 130, 150 end

------------------------------------------------------------------------ quests, gossip, mail, maps, voice
function GetTitleText() return "A Threat Within" end
function GetQuestText() return "I hope you strike quickly, Oskar. <He nods.>" end
function GetObjectiveText() return "Speak with Marshal McBride." end
function GetProgressText() return "Well, Oskar?" end
function GetRewardText() return "Well done." end
function GetGreetingText() return "Greetings." end
function GetQuestID() return 783 end
function GetQuestLogQuestText() return "Description", "Objectives" end
C_GossipInfo = { GetText = function() return "Welcome to Goldshire." end }
C_QuestLog = { GetSelectedQuest = function() return 783 end, SetSelectedQuest = noop, GetTitleForQuestID = function() return "A Threat Within" end,
    GetNumQuestLogEntries = function() return 1 end, GetInfo = function() return { questID = 783 } end }
function ItemTextGetText() return "Page one of an old book." end
function GetInboxNumItems() return 1 end
function GetInboxInvoiceInfo() return "seller", "Linen Cloth", "Buyer", 1700, 0, 0, 85 end
function GetInboxHeaderInfo() return nil, nil, "Auction House", "Sold", 1700, 0, 29.5 end
C_Map = {
    GetMapInfo = function(id)
        local maps = { [1415] = { name = "Eastern Kingdoms", mapType = 2 }, [1429] = { name = "Elwynn Forest", mapType = 3, parentMapID = 1415 },
            [2521] = { name = "The Riverglades", mapType = 3, parentMapID = 1415 } }
        return maps[id]
    end,
    GetMapLevels = function(id) if id == 2521 then return 36, 44 end if id == 1429 then return 1, 10 end end,
}
C_VoiceChat = { GetTtsVoices = function() return { { voiceID = 0, name = "Microsoft David" }, { voiceID = 1, name = "Microsoft Zira" } } end,
    SpeakText = record("SpeakText"), StopSpeakingText = noop }
C_CVar = { GetCVar = function() return "400" end, SetCVar = record("SetCVar") }
C_AddOns = { IsAddOnLoaded = function() return false end }

------------------------------------------------------------------------ auction house
C_AuctionHouse = {
    ReplicateItems = record("ReplicateItems"),
    GetNumReplicateItems = function() return 3 end,
    GetReplicateItemInfo = function(i)
        local id = i == 2 and 117 or 2589
        return "x", 1, 5, 1, true, 1, "", 0, 0, 500 + i * 10, 0, false, nil, "Bob", nil, 0, id, true
    end,
    GetReplicateItemTimeLeft = function() return 3 end,
    IsThrottledMessageSystemReady = function() return true end,
    SendSearchQuery = record("SendSearchQuery"),
    SendBrowseQuery = record("SendBrowseQuery"),
    GetBrowseResults = function() return { { itemKey = { itemID = 2589 }, minPrice = 33, totalQuantity = 50 } } end,
    HasFullBrowseResults = function() return true end,
    RequestMoreBrowseResults = noop,
    GetNumCommoditySearchResults = function() return 2 end,
    GetCommoditySearchResultInfo = function(_, i) return { unitPrice = (mock.lowest or 30) + i, quantity = 10, containsOwnerItem = false } end,
    GetNumItemSearchResults = function() return 0 end,
    GetItemSearchResultInfo = function() return nil end,
    GetItemCommodityStatus = function(loc)
        local info = C_Container.GetContainerItemInfo(loc.bag, loc.slot)
        return (info and info.itemID == 1001) and 1 or 2
    end,
    GetItemKeyFromItem = function(loc)
        local info = C_Container.GetContainerItemInfo(loc.bag, loc.slot)
        return { itemID = info and info.itemID or 0 }
    end,
    MakeItemKey = function(id) return { itemID = id } end,
    GetItemKeyInfo = function() return { isCommodity = true } end,
    IsSellItemValid = function() return true end,
    CalculateCommodityDeposit = function() return 15 end,
    CalculateItemDeposit = function() return 15 end,
    PostCommodity = record("PostCommodity"),
    PostItem = record("PostItem"),
    QueryOwnedAuctions = record("QueryOwnedAuctions"),
    GetNumOwnedAuctions = function() return 1 end,
    GetOwnedAuctionInfo = function() return { auctionID = 77, itemKey = { itemID = 2589 }, buyoutAmount = 40, quantity = 10, status = 0 } end,
    CancelAuction = record("CancelAuction"),
    StartCommoditiesPurchase = record("StartCommoditiesPurchase"),
    ConfirmCommoditiesPurchase = record("ConfirmCommoditiesPurchase"),
    CancelCommoditiesPurchase = record("CancelCommoditiesPurchase"),
    PlaceBid = record("PlaceBid"),
}
