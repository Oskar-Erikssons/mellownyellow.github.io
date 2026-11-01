-- Forever Guide: what every character owns (bags, bank, equipped) and what it is worth.
-- Everything is stored in your own SavedVariables file and never leaves your computer.
local _, FG = ...
local Inventory = {}
FG.Inventory = Inventory

local PLACES = { "bags", "bank", "equip" }
local PLACE_TEXT = { bags = "bags", bank = "bank", equip = "worn" }

------------------------------------------------------------------------
-- Pure helpers (covered by tests)
------------------------------------------------------------------------

-- Forever has no realms; characters are told apart by name and surname.
function Inventory.Key(name, surname, realm, isForever)
    if isForever then
        return (surname and surname ~= "") and (name .. " " .. surname) or name
    end
    return name .. "-" .. (realm or "")
end

-- How many of an item each character has. Returns total and a sorted list of { key, count, where }.
function Inventory.Count(characters, itemID)
    local total, rows = 0, {}
    for key, c in pairs(characters or {}) do
        local n, where = 0, {}
        for _, place in ipairs(PLACES) do
            local k = (c[place] or {})[itemID]
            if k and k > 0 then
                n = n + k
                table.insert(where, k .. " " .. PLACE_TEXT[place])
            end
        end
        if n > 0 then
            total = total + n
            table.insert(rows, { key = key, count = n, where = table.concat(where, ", ") })
        end
    end
    table.sort(rows, function(a, b) return a.count > b.count end)
    return total, rows
end

-- Total worth of one character: gold plus each item at what you would actually get for it.
-- valueOf(itemID, count) returns copper.
function Inventory.Worth(c, valueOf)
    local items = 0
    for _, place in ipairs({ "bags", "bank" }) do
        for itemID, n in pairs(c[place] or {}) do
            items = items + (valueOf(itemID, n) or 0)
        end
    end
    return (c.money or 0) + items, items
end

------------------------------------------------------------------------
-- Saving
------------------------------------------------------------------------

function Inventory:All()
    FG.db.characters = FG.db.characters or {}
    return FG.db.characters
end

function Inventory:Me()
    if self.me then return self.me end
    local name, surname = UnitFullName("player")
    name, surname = FG.Safe(name), FG.Safe(surname)
    if not name then return nil end
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    self.key = Inventory.Key(name, surname, realm, FG.IsForever)
    local all = self:All()
    all[self.key] = all[self.key] or {}
    local c = all[self.key]
    c.name = name
    c.class = select(2, UnitClass("player"))
    c.faction = UnitFactionGroup("player")
    self.me = c
    return c
end

local function readContainers(list)
    local items, names = {}, FG.db.itemNames
    local C = C_Container
    for _, bag in ipairs(list) do
        local slots = C and C.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                items[info.itemID] = (items[info.itemID] or 0) + (info.stackCount or 1)
                if info.hyperlink then names[info.itemID] = info.hyperlink:match("%[(.-)%]") or names[info.itemID] end
            end
        end
    end
    return items
end

local function bagList()
    local list = {}
    for bag = 0, NUM_BAG_SLOTS or 4 do table.insert(list, bag) end
    return list
end

-- The bank differs between client versions: classic bank bags, or modern bank tabs.
local function bankList()
    local list = {}
    if Enum.BagIndex and Enum.BagIndex.CharacterBankTab_1 then
        for i = 0, 5 do
            local id = Enum.BagIndex.CharacterBankTab_1 + i
            if id <= (Enum.BagIndex.CharacterBankTab_6 or id) then table.insert(list, id) end
        end
    else
        table.insert(list, BANK_CONTAINER or -1)
        local first = (NUM_BAG_SLOTS or 4) + 1
        for bag = first, first + (NUM_BANKBAGSLOTS or 6) - 1 do table.insert(list, bag) end
    end
    return list
end

function Inventory:SaveBags()
    local c = self:Me()
    if not c then return end
    c.bags = readContainers(bagList())
    c.money = GetMoney()
    c.level = UnitLevel("player")
    c.t = time()
end

function Inventory:SaveBank()
    local c = self:Me()
    if c and self.bankOpen then
        c.bank = readContainers(bankList())
        c.bankT = time()
    end
end

function Inventory:SaveEquip()
    local c = self:Me()
    if not c then return end
    local worn = {}
    for slot = 1, 19 do
        local id = GetInventoryItemID("player", slot)
        if id then worn[id] = (worn[id] or 0) + 1 end
    end
    c.equip = worn
end

------------------------------------------------------------------------
-- Value and tooltip
------------------------------------------------------------------------

function Inventory.ValueOf(itemID, count)
    local d = FG.Auction:Advice(itemID, count)
    if d.action == "ah" then return d.ahEV end
    return d.vendorTotal or 0
end

function Inventory:Summary()
    local rows, total = {}, 0
    for key, c in pairs(self:All()) do
        local worth, items = Inventory.Worth(c, Inventory.ValueOf)
        table.insert(rows, { key = key, c = c, worth = worth, items = items })
        total = total + worth
    end
    table.sort(rows, function(a, b) return a.worth > b.worth end)
    return rows, total
end

-- Finds items by name across all characters.
function Inventory:Find(text)
    text = text:lower()
    local hits = {}
    for itemID, name in pairs(FG.db.itemNames) do
        if name:lower():find(text, 1, true) then
            local total, rows = Inventory.Count(self:All(), itemID)
            if total > 0 then table.insert(hits, { itemID = itemID, name = name, total = total, rows = rows }) end
        end
    end
    table.sort(hits, function(a, b) return a.total > b.total end)
    return hits
end

function Inventory:TooltipLines(itemID)
    if not FG.settings.tooltipOwned then return {} end
    local total, rows = Inventory.Count(self:All(), itemID)
    if total == 0 then return {} end
    local T = FG.Theme
    local lines = { { T:Color("accent", "Owned"), tostring(total) } }
    for i, r in ipairs(rows) do
        if i > 5 then break end
        table.insert(lines, { "  " .. r.key, r.where })
    end
    return lines
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

FG:On("PLAYER_LOGIN", function()
    FG.db.itemNames = FG.db.itemNames or {}
    Inventory:SaveBags()
    Inventory:SaveEquip()
end)
FG:On("BAG_UPDATE_DELAYED", function() Inventory:SaveBags() Inventory:SaveBank() end)
FG:On("PLAYER_MONEY", function() local c = Inventory:Me() if c then c.money = GetMoney() end end)
FG:On("PLAYER_EQUIPMENT_CHANGED", function() Inventory:SaveEquip() end)
FG:On("BANKFRAME_OPENED", function()
    Inventory.bankOpen = true
    C_Timer.After(0.5, function() Inventory:SaveBank() end)
end)
FG:On("PLAYERBANKSLOTS_CHANGED", function() Inventory:SaveBank() end)
FG:On("BANKFRAME_CLOSED", function()
    Inventory:SaveBank()
    Inventory.bankOpen = false
end)
