-- Forever Guide: is this item an upgrade? Values an item's stats with your own stat weights
-- (from the simulator) and compares it with what you wear in the same slot.
local _, FG = ...
local Gear = {}
FG.Gear = Gear

-- Item stat keys as the game names them, mapped to the simulator's stats. Unknown keys are ignored.
Gear.STAT_KEYS = {
    ITEM_MOD_STRENGTH_SHORT = "str", ITEM_MOD_AGILITY_SHORT = "agi", ITEM_MOD_INTELLECT_SHORT = "int",
    ITEM_MOD_ATTACK_POWER_SHORT = "ap", ITEM_MOD_MELEE_ATTACK_POWER_SHORT = "ap",
    ITEM_MOD_SPELL_POWER_SHORT = "sp", ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "sp", ITEM_MOD_SPELL_DAMAGE_DONE = "sp",
    ITEM_MOD_CRIT_RATING_SHORT = "crit", ITEM_MOD_CRIT_MELEE_RATING_SHORT = "crit", ITEM_MOD_CRIT_SPELL_RATING_SHORT = "spellCrit",
    ITEM_MOD_HIT_RATING_SHORT = "hit", ITEM_MOD_HIT_MELEE_RATING_SHORT = "hit",
    ITEM_MOD_DAMAGE_PER_SECOND_SHORT = "weaponDps",
}

-- Slots an equip location can go in. Rings and trinkets compare against your weaker one.
Gear.SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}

-- DPS per one point of each stat, from the simulator's weights and the class's conversion rates.
-- weights: { sp10, crit1, ap14, meleeCrit1, hit1 }; rates: { apStr, apAgi, agiCrit, intCrit }
function Gear.StatValues(weights, rates)
    local v = {}
    v.sp = (weights.sp10 or 0) / 10
    v.spellCrit = weights.crit1 or 0
    v.ap = (weights.ap14 or 0) / 14
    v.crit = weights.meleeCrit1 or 0
    v.hit = weights.hit1 or 0
    v.str = (rates.apStr or 0) * v.ap
    v.agi = (rates.apAgi or 0) * v.ap + ((rates.agiCrit or 0) > 0 and v.crit / rates.agiCrit or 0)
    v.int = (rates.intCrit or 0) > 0 and v.spellCrit / rates.intCrit or 0
    -- One point of weapon DPS adds about one point of auto attack DPS before misses.
    v.weaponDps = v.ap > 0 and 0.85 or 0
    return v
end

function Gear.Score(stats, values)
    local score = 0
    for key, amount in pairs(stats or {}) do
        local stat = Gear.STAT_KEYS[key]
        if stat and values[stat] then score = score + amount * values[stat] end
    end
    return score
end

------------------------------------------------------------------------
-- Game side
------------------------------------------------------------------------

local function itemStats(link)
    if not link then return nil end
    if C_Item and C_Item.GetItemStats then return C_Item.GetItemStats(link) end
    return GetItemStats and GetItemStats(link)
end

-- Stat weights change with gear and level, so refresh them out of combat.
function Gear:Refresh()
    local s = FG.Sim:Snapshot()
    if not s then return end
    local _, _, weights = FG.Sim:Run(s)
    local rates = (FG.Data.rates or {})[s.class] or {}
    self.values = Gear.StatValues(weights, rates)
    FG.db.snapshots.weights = weights
end

function Gear:Compare(link)
    if not (self.values and link) then return nil end
    local equipLoc = select(4, C_Item.GetItemInfoInstant(link))
    local slots = Gear.SLOTS[equipLoc or ""]
    if not slots then return nil end
    local new = Gear.Score(itemStats(link), self.values)
    local worst, worstSlot
    for _, slot in ipairs(slots) do
        local current = Gear.Score(itemStats(GetInventoryItemLink("player", slot)), self.values)
        if not worst or current < worst then worst, worstSlot = current, slot end
    end
    return new - worst, worstSlot
end

function Gear:TooltipLines(_, link)
    if not FG.settings.tooltipUpgrade then return {} end
    local delta = self:Compare(link)
    if not delta or math.abs(delta) < 0.05 then return {} end
    local T = FG.Theme
    local text = string.format("%+.1f DPS vs. what you wear", delta)
    return { { T:Color(delta > 0 and "good" or "bad", (delta > 0 and "Upgrade " or "Downgrade ") .. text), "" } }
end

FG:On("PLAYER_LOGIN", function() C_Timer.After(3, function() Gear:Refresh() end) end)
FG:On("PLAYER_EQUIPMENT_CHANGED", function() if not InCombatLockdown() then Gear:Refresh() end end)
FG:On("PLAYER_LEVEL_UP", function() C_Timer.After(2, function() Gear:Refresh() end) end)
FG:On("PLAYER_REGEN_ENABLED", function() if not Gear.values then Gear:Refresh() end end)
