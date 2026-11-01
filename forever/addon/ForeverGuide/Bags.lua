-- Forever Guide: Forever Bags. One bag window that knows what everything is worth.
--   * every slot shows its sell advice (AH, vendor, junk) and a green arrow on upgrades
--   * the header shows what your bags are worth, free slots and gold
--   * smart search: type a name, or ah, vendor, junk, upgrade, quest, bound
--   * view any of your characters' items, even when they are logged out
--   * sorting uses the game's own sort, so nothing is moved behind your back
local _, FG = ...
local Bags = {}
FG.Bags = Bags

local SIZE, GAP, PAD, HEADER, FOOTER = 37, 4, 12, 70, 30
local QUEST_CLASS = 12

------------------------------------------------------------------------
-- Pure helpers (covered by tests)
------------------------------------------------------------------------

local FILTERS = {
    ah = function(it) return it.action == "ah" end,
    vendor = function(it) return it.action == "vendor" end,
    junk = function(it) return it.quality == 0 end,
    upgrade = function(it) return (it.upgrade or 0) > 0 end,
    quest = function(it) return it.classID == QUEST_CLASS end,
    bound = function(it) return it.bound == true end,
}
-- Swedish words work too.
FILTERS["sälj"], FILTERS["handlare"], FILTERS["skräp"], FILTERS["uppgradering"], FILTERS["bunden"] =
    FILTERS.vendor, FILTERS.vendor, FILTERS.junk, FILTERS.upgrade, FILTERS.bound

-- Does an item match the search? Each word must match: a filter word or part of the name.
function Bags.Matches(query, item)
    query = (query or ""):lower()
    if query == "" then return true end
    for word in query:gmatch("%S+") do
        local filter = FILTERS[word]
        if filter then
            if not filter(item) then return false end
        elseif not (item.name or ""):lower():find(word, 1, true) then
            return false
        end
    end
    return true
end

-- Rows and window size for a number of slots.
function Bags.Layout(count, cols)
    local rows = math.max(1, math.ceil(count / cols))
    return rows, PAD * 2 + cols * SIZE + (cols - 1) * GAP, HEADER + FOOTER + rows * SIZE + (rows - 1) * GAP
end

-- Corner badge for a slot: text and theme color key, or nil.
function Bags.Badge(item)
    if item.quality == 0 and (item.vendor or 0) > 0 then return "junk", "muted" end
    if item.action == "ah" then return "AH", "good" end
    if item.action == "vendor" and (item.vendor or 0) > 0 and item.market then return "V", "accent" end
end

------------------------------------------------------------------------
-- Live bags
------------------------------------------------------------------------

local function bagIDs()
    local ids = {}
    local last = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0)
    for bag = 0, last do table.insert(ids, bag) end
    return ids
end

-- Everything Forever Guide knows about one slot.
local function describe(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or not info.itemID then return nil end
    local name, _, _, _, _, _, _, _, _, _, sell, classID = (C_Item and C_Item.GetItemInfo or GetItemInfo)(info.itemID)
    local d = FG.Auction:Advice(info.itemID, info.stackCount or 1, info.isBound)
    local upgrade = FG.Gear and info.hyperlink and FG.Gear:Compare(info.hyperlink) or nil
    local price = FG.Auction:Price(info.itemID) or {}
    return {
        info = info, itemID = info.itemID, name = name or (info.hyperlink or ""):match("%[(.-)%]"),
        quality = info.quality, bound = info.isBound, classID = classID, vendor = sell, market = price.m,
        action = d.action, value = (d.action == "ah" and d.ahEV or d.vendorTotal) or 0, upgrade = upgrade,
    }
end

function Bags:Build()
    local f = FG.UI.MakeWindow("Forever Bags", 420, 300)
    f:ClearAllPoints()
    f:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -80, 120)
    f:SetFrameStrata("MEDIUM")
    self.frame = f

    local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    search:SetSize(170, 20)
    search:SetPoint("TOPLEFT", PAD + 4, -38)
    search:SetScript("OnTextChanged", function(box)
        SearchBoxTemplate_OnTextChanged(box)
        Bags.query = box:GetText()
        Bags:Refresh()
    end)
    search:SetScript("OnEnter", function(box)
        GameTooltip:SetOwner(box, "ANCHOR_TOP")
        GameTooltip:SetText("Search", 1, 1, 1)
        GameTooltip:AddLine("A name, or: ah, vendor, junk, upgrade, quest, bound. Words can be combined.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    search:SetScript("OnLeave", GameTooltip_Hide)
    self.search = search

    local sort = FG.UI.Button(f, "Sort", 54, function()
        if C_Container.SortBags then C_Container.SortBags() end
    end)
    sort:SetPoint("LEFT", search, "RIGHT", 6, 0)

    local who = FG.UI.Button(f, "", 130, function() Bags:NextCharacter() end)
    who:SetPoint("TOPRIGHT", -PAD, -36)
    who:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_TOP")
        GameTooltip:SetText("Click to see another character's items", 1, 1, 1)
        GameTooltip:Show()
    end)
    who:SetScript("OnLeave", GameTooltip_Hide)
    self.who = who

    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.footer:SetPoint("BOTTOMLEFT", PAD, 10)
    f.footer:SetPoint("BOTTOMRIGHT", -PAD, 10)
    f.footer:SetJustifyH("LEFT")
    FG.Theme:Register(f.footer, function(fs, T) fs:SetTextColor(T:Get("text")) end)

    self.holders, self.buttons, self.offline = {}, {}, {}
    f:SetScript("OnShow", function() Bags:Refresh() end)
    f:Hide()
end

-- Slot buttons use the game's own bag button template, so clicking, dragging, using and
-- tooltips work exactly as in the normal bags. The parent frame carries the bag ID.
function Bags:Button(bag, slot)
    self.buttons[bag] = self.buttons[bag] or {}
    local b = self.buttons[bag][slot]
    if b then return b end
    local holder = self.holders[bag]
    if not holder then
        holder = CreateFrame("Frame", nil, self.frame)
        holder:SetAllPoints()
        holder:SetID(bag)
        self.holders[bag] = holder
    end
    local name = string.format("ForeverGuideBag%dSlot%d", bag + 1, slot)
    local ok
    ok, b = pcall(CreateFrame, "ItemButton", name, holder, "ContainerFrameItemButtonTemplate")
    if not ok then b = CreateFrame("Button", name, holder, "ContainerFrameItemButtonTemplate") end
    b:SetID(slot)
    b.bagID = bag
    b:SetSize(SIZE, SIZE)
    b.badge = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.badge:SetPoint("TOPLEFT", 2, -2)
    b.arrow = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.arrow:SetPoint("TOPRIGHT", -1, -1)
    b.arrow:SetText("▲")
    b.arrow:Hide()
    b.Cooldown = b.Cooldown or _G[name .. "Cooldown"]
    self.buttons[bag][slot] = b
    return b
end

-- A plain button for a logged-out character's item: icon, count and tooltip, nothing to click.
function Bags:OfflineButton(i)
    local b = self.offline[i]
    if b then return b end
    b = CreateFrame("Button", nil, self.frame)
    b:SetSize(SIZE, SIZE)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b.where = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.where:SetPoint("TOPLEFT", 2, -2)
    b:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(btn.itemID)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    self.offline[i] = b
    return b
end

local function place(b, index, cols)
    local col, row = (index - 1) % cols, math.floor((index - 1) / cols)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", Bags.frame, "TOPLEFT", PAD + col * (SIZE + GAP), -HEADER - row * (SIZE + GAP))
end

function Bags:Characters()
    local list = {}
    for key in pairs(FG.db.characters or {}) do table.insert(list, key) end
    table.sort(list)
    return list
end

function Bags:NextCharacter()
    local list, me = self:Characters(), FG.Inventory.key
    local current = self.viewing or me
    for i, key in ipairs(list) do
        if key == current then
            self.viewing = list[i % #list + 1]
            break
        end
    end
    if self.viewing == me then self.viewing = nil end
    self:Refresh()
end

function Bags:Refresh()
    local f = self.frame
    if not (f and f:IsShown()) then return end
    if InCombatLockdown() and not self.ready then return end
    local T, cols = FG.Theme, FG.settings.bagColumns or 10
    local me = FG.Inventory.key or "?"
    self.who:SetText((self.viewing or me):sub(1, 18))
    for _, list in pairs(self.buttons) do for _, b in pairs(list) do b:Hide() end end
    for _, b in ipairs(self.offline) do b:Hide() end
    if self.viewing then return self:RefreshOffline(cols) end

    local index, total, free, slots = 0, 0, 0, 0
    for _, bag in ipairs(bagIDs()) do
        local n = C_Container.GetContainerNumSlots(bag)
        free = free + (C_Container.GetContainerNumFreeSlots(bag) or 0)
        slots = slots + n
        for slot = 1, n do
            index = index + 1
            local b = self:Button(bag, slot)
            place(b, index, cols)
            local it = describe(bag, slot)
            local info = it and it.info
            SetItemButtonTexture(b, info and info.iconFileID)
            SetItemButtonCount(b, info and info.stackCount or 0)
            if SetItemButtonQuality then SetItemButtonQuality(b, info and info.quality, info and info.hyperlink) end
            SetItemButtonDesaturated(b, info and info.isLocked)
            if b.Cooldown and C_Container.GetContainerItemCooldown then
                local start, duration, enable = C_Container.GetContainerItemCooldown(bag, slot)
                CooldownFrame_Set(b.Cooldown, start, duration, enable)
            end
            local text, color
            if it and FG.settings.bagBadges then text, color = Bags.Badge(it) end
            b.badge:SetText(text and T:Color(color, text) or "")
            b.arrow:SetShown(it ~= nil and (it.upgrade or 0) > 0.05)
            b.arrow:SetTextColor(T:Get("good"))
            b:SetAlpha((not it or Bags.Matches(self.query, it)) and 1 or 0.25)
            if it then total = total + it.value end
            b:Show()
        end
    end
    local _, w, h = Bags.Layout(index, cols)
    f:SetSize(w, h)
    f.footer:SetText(string.format("Worth %s  ·  %d/%d free  ·  Gold %s", FG.Auction.Money(total), free, slots,
        FG.Auction.Money(GetMoney())))
end

-- A logged-out character: every item once, most valuable first.
function Bags:RefreshOffline(cols)
    local c = FG.db.characters[self.viewing] or {}
    local items = {}
    for _, where in ipairs({ "bags", "bank" }) do
        for itemID, n in pairs(c[where] or {}) do
            table.insert(items, { itemID = itemID, count = n, where = where,
                value = FG.Inventory.ValueOf(itemID, n), name = FG.db.itemNames[itemID] })
        end
    end
    table.sort(items, function(a, b) return a.value > b.value end)
    local shown = 0
    for _, it in ipairs(items) do
        if Bags.Matches(self.query, it) then
            shown = shown + 1
            local b = self:OfflineButton(shown)
            place(b, shown, cols)
            b.itemID = it.itemID
            b.icon:SetTexture(C_Item.GetItemIconByID(it.itemID))
            b.count:SetText(it.count > 1 and it.count or "")
            b.where:SetText(it.where == "bank" and FG.Theme:Color("muted", "bank") or "")
            b:Show()
        end
    end
    local worth = FG.Inventory.Worth(c, FG.Inventory.ValueOf)
    local _, w, h = Bags.Layout(math.max(shown, cols), cols)
    self.frame:SetSize(w, h)
    self.frame.footer:SetText(string.format("%s (logged out) · worth %s · gold %s", self.viewing,
        FG.Auction.Money(worth), FG.Auction.Money(c.money or 0)))
end

function Bags:Toggle(show)
    if not self.frame then self:Build() end
    if show == nil then show = not self.frame:IsShown() end
    self.viewing = nil
    self.frame:SetShown(show)
end

------------------------------------------------------------------------
-- Taking over from the game's bags (can be switched off with /fg bags off)
------------------------------------------------------------------------

local function hideBlizzardBags()
    if ContainerFrameCombinedBags and ContainerFrameCombinedBags:IsShown() then ContainerFrameCombinedBags:Hide() end
    for i = 1, NUM_CONTAINER_FRAMES or 13 do
        local cf = _G["ContainerFrame" .. i]
        if cf and cf:IsShown() and (cf:GetID() or 0) <= ((NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0)) then cf:Hide() end
    end
end

-- Other bag addons win: if one is running, Forever Bags only opens with /fg bags.
local OTHER_BAG_ADDONS = { "Bagnon", "Baganator", "AdiBags", "ArkInventory", "BetterBags", "Combuctor" }

function Bags.OtherBagAddon(isLoaded)
    for _, name in ipairs(OTHER_BAG_ADDONS) do
        if isLoaded(name) then return name end
    end
end

local function takeOver(show)
    return function()
        if not FG.settings.replaceBags or Bags.other then return end
        hideBlizzardBags()
        if show == "toggle" then Bags:Toggle() else Bags:Toggle(show) end
    end
end

FG:On("PLAYER_LOGIN", function()
    Bags:Build()
    -- Make the buttons now, out of combat, so opening the bags in a fight needs nothing new.
    for _, bag in ipairs(bagIDs()) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do Bags:Button(bag, slot) end
    end
    Bags.ready = true
    local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    Bags.other = isLoaded and Bags.OtherBagAddon(isLoaded)
    if Bags.other and FG.settings.replaceBags then
        FG:Print(Bags.other .. " handles your bags, so Forever Bags stays out of the way. Open it with /fg bags.")
    end
    for name, show in pairs({ ToggleAllBags = "toggle", ToggleBackpack = "toggle", OpenAllBags = true,
        OpenBackpack = true, CloseAllBags = false, CloseBackpack = false }) do
        if _G[name] then hooksecurefunc(name, takeOver(show)) end
    end
end)
-- The game sends many updates in a row (moving a stack, item data arriving); redraw once after them.
function Bags:Soon()
    if self.pending or not (self.frame and self.frame:IsShown()) then return end
    self.pending = true
    C_Timer.After(0.1, function()
        Bags.pending = false
        Bags:Refresh()
    end)
end

for _, event in ipairs({ "BAG_UPDATE_DELAYED", "ITEM_LOCK_CHANGED", "BAG_UPDATE_COOLDOWN", "PLAYER_MONEY",
    "GET_ITEM_INFO_RECEIVED" }) do
    FG:On(event, function() Bags:Soon() end)
end
