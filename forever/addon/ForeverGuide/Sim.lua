-- Forever Guide: reads your current stats and spells and estimates damage.
-- Uses 2004-era (1.12) combat rules. Results are estimates, not a full combat log sim.
-- Stats can be secret in combat, so take snapshots out of combat.
local _, FG = ...
local Sim = {}
FG.Sim = Sim

local GCD = 1.5
local SPELL_SCHOOLS = { 2, 3, 4, 5, 6, 7 } -- holy, fire, nature, frost, shadow, arcane
local STAT_KEYS = { "str", "agi", "sta", "int", "spi" }

local function num(v) return tonumber(FG.Safe(v)) end

local function maxOverSchools(fn)
    local best
    for _, school in ipairs(SPELL_SCHOOLS) do
        local v = num(FG.Try(fn, school))
        if v and (not best or v > best) then best = v end
    end
    return best
end

function Sim:Snapshot()
    if InCombatLockdown() then
        return nil, "Leave combat first: stats are hidden from addons in combat."
    end
    local s = {}
    s.level = UnitLevel("player")
    s.className, s.class = UnitClass("player")
    s.raceName, s.race = UnitRace("player")
    for i, key in ipairs(STAT_KEYS) do
        local _, effective = FG.Try(UnitStat, "player", i)
        s[key] = num(effective)
    end
    s.hp = num(FG.Try(UnitHealthMax, "player"))
    s.mana = num(FG.Try(UnitPowerMax, "player", 0))

    local apBase, apPos, apNeg = FG.Try(UnitAttackPower, "player")
    if apBase then s.ap = apBase + (apPos or 0) + (apNeg or 0) end
    local rapBase, rapPos, rapNeg = FG.Try(UnitRangedAttackPower, "player")
    if rapBase then s.rap = rapBase + (rapPos or 0) + (rapNeg or 0) end

    local minMH, maxMH, minOH, maxOH = FG.Try(UnitDamage, "player")
    local speedMH, speedOH = FG.Try(UnitAttackSpeed, "player")
    if minMH and speedMH then s.mh = { min = minMH, max = maxMH, speed = speedMH } end
    if minOH and speedOH and maxOH and maxOH > 0 then s.oh = { min = minOH, max = maxOH, speed = speedOH } end
    local rSpeed, rMin, rMax = FG.Try(UnitRangedDamage, "player")
    if rSpeed and rSpeed > 0 and rMin then s.ranged = { min = rMin, max = rMax, speed = rSpeed } end

    s.crit = num(FG.Try(GetCritChance))
    s.rangedCrit = num(FG.Try(GetRangedCritChance))
    s.spellCrit = maxOverSchools(GetSpellCritChance)
    s.sp = maxOverSchools(GetSpellBonusDamage) or 0
    s.healing = num(FG.Try(GetSpellBonusHealing)) or 0
    s.hit = num(FG.Try(GetHitModifier)) or 0
    s.spellHit = num(FG.Try(GetSpellHitModifier)) or 0
    local regenBase, regenCasting = FG.Try(GetManaRegen)
    s.regen = num(regenBase)
    s.regenCasting = num(regenCasting)
    s.spells = self:ReadSpells()
    s.time = time()
    return s
end

-- Iterates the spellbook. Supports the modern C_SpellBook API and the old one.
local function eachSpell(fn)
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        local bank = Enum.SpellBookSpellBank.Player
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if info and not info.shouldHide then
                for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(slot, bank)
                    if item and item.itemType == Enum.SpellBookItemType.Spell and not item.isPassive and item.spellID then
                        fn(item.spellID)
                    end
                end
            end
        end
    elseif GetNumSpellTabs then
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, count = GetSpellTabInfo(tab)
            for slot = offset + 1, offset + count do
                local kind, id = GetSpellBookItemInfo(slot, BOOKTYPE_SPELL)
                if kind == "SPELL" and id and not IsPassiveSpell(slot, BOOKTYPE_SPELL) then fn(id) end
            end
        end
    end
end

local function spellInfo(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        if info then return info.name, info.castTime end
    else
        local name, _, _, castTime = GetSpellInfo(id)
        return name, castTime
    end
end

local function spellDescription(id)
    if C_Spell and C_Spell.GetSpellDescription then return C_Spell.GetSpellDescription(id) end
    return GetSpellDescription and GetSpellDescription(id)
end

local function manaCost(id)
    local costs = C_Spell and C_Spell.GetSpellPowerCost and C_Spell.GetSpellPowerCost(id)
        or GetSpellPowerCost and GetSpellPowerCost(id)
    for _, c in ipairs(costs or {}) do
        if c.type == 0 then return c.cost end -- 0 = mana
    end
    return 0
end

local function toNumber(s) return tonumber((s:gsub(",", ""))) end

-- Pulls damage or healing numbers out of a tooltip text.
-- Returns kind ("damage"/"heal"), min, max, dot (over time amount), dotDuration.
function Sim.ParseDescription(desc)
    if not desc or desc == "" then return nil end
    local lower = desc:lower()
    local kind = lower:find("heal") and not lower:find("damage") and "heal" or "damage"
    if not lower:find("damage") and not lower:find("heal") then return nil end

    local lo, hi = lower:match("(%d[%d,]*) to (%d[%d,]*)")
    local dot, dur = lower:match("(%d[%d,]*)%s+%a*%s*damage over (%d+) sec")
    if not dot then dot, dur = lower:match("(%d[%d,]*) over (%d+) sec") end
    if not lo and not dot then
        local single = lower:match("for (%d[%d,]*)") or lower:match("causing (%d[%d,]*)") or lower:match("deals (%d[%d,]*)")
        if not single then return nil end
        lo, hi = single, single
    end
    return kind, lo and toNumber(lo) or 0, hi and toNumber(hi) or 0, dot and toNumber(dot) or 0, dur and tonumber(dur) or 0
end

function Sim:ReadSpells()
    local list, seen = {}, {}
    eachSpell(function(id)
        local name, castTime = spellInfo(id)
        if not name or seen[name] then return end
        local kind, lo, hi, dot, dur = Sim.ParseDescription(spellDescription(id))
        if not kind then return end
        seen[name] = true
        table.insert(list, {
            id = id,
            name = name,
            kind = kind,
            min = lo, max = hi,
            dot = dot, dur = dur,
            cast = (castTime or 0) / 1000,
            cd = (GetSpellBaseCooldown and GetSpellBaseCooldown(id) or 0) / 1000,
            cost = manaCost(id),
        })
    end)
    return list
end

-- 1.12 rules: base spell miss vs. equal level 4%, +1% per level up to +2, then +11% at +3.
local SPELL_MISS = { [0] = 4, 5, 6, 17 }
-- Melee miss vs. equal level 5%, roughly +0.5% per level (+1% at +3 for weapon skill gap).
local MELEE_MISS = { [0] = 5, 5.5, 6, 8 }
local GLANCE_CHANCE = { [0] = 0.1, 0.2, 0.3, 0.4 }
local GLANCE_MULT = { [0] = 0.95, 0.95, 0.85, 0.65 }

function Sim:SpellResult(spell, s, extraSP, extraCrit)
    local settings = FG.settings
    local diff = settings.targetLevelDiff or 0
    local sp = spell.kind == "heal" and (s.healing or 0) or (s.sp or 0)
    sp = sp + (extraSP or 0)
    local crit = ((s.spellCrit or 0) + (extraCrit or 0)) / 100
    local hit = spell.kind == "heal" and 1 or math.min(0.99, 1 - math.max(1, SPELL_MISS[diff] - (s.spellHit or 0)) / 100)

    local cast = math.max(spell.cast, GCD)
    -- Spell power coefficient: cast time / 3.5 for direct, duration / 15 for over-time.
    local direct = (spell.min + spell.max) / 2
    local coefDirect = math.min(1, math.max(spell.cast, GCD) / 3.5)
    local coefDot = math.min(1, (spell.dur or 0) / 15)
    if direct > 0 and spell.dot > 0 then
        -- Hybrid spells split the coefficient.
        coefDirect, coefDot = coefDirect * 0.5, coefDot * 0.5
    end
    if settings.tooltipIncludesSP then coefDirect, coefDot = 0, 0 end

    local perCast = 0
    if direct > 0 then perCast = (direct + sp * coefDirect) * (1 + crit * 0.5) end
    if spell.dot > 0 then perCast = perCast + spell.dot + sp * coefDot end
    perCast = perCast * hit

    local time = math.max(cast, spell.cd > 0 and spell.cd or 0)
    return {
        perCast = perCast,
        dps = perCast / time,
        dpm = spell.cost > 0 and perCast / spell.cost or nil,
        castsToOOM = spell.cost > 0 and s.mana and math.floor(s.mana / spell.cost) or nil,
    }
end

function Sim:MeleeDPS(s, extraAP, extraCrit, extraHit)
    if not s.mh then return 0 end
    local diff = FG.settings.targetLevelDiff or 0
    local apBonus = (extraAP or 0) / 14
    local crit = ((s.crit or 0) + (extraCrit or 0)) / 100
    local missBase = MELEE_MISS[diff] + (s.oh and 19 or 0)
    local miss = math.max(0, missBase - (s.hit or 0) - (extraHit or 0)) / 100
    local dodge = (5 + diff * 0.5) / 100
    -- Glancing blows: rough 1.12 values, 10% of white hits at equal level up to 40% vs. bosses.
    local glanceChance = GLANCE_CHANCE[diff]
    local glanceMult = GLANCE_MULT[diff]
    local landed = math.max(0, 1 - miss - dodge - glanceChance)
    crit = math.min(crit, landed)
    -- One attack table roll: normal hit, crit (x2) or glancing blow.
    local tableMult = (landed - crit) + 2 * crit + glanceChance * glanceMult

    local function hand(h, mult)
        if not h then return 0 end
        local avg = (h.min + h.max) / 2 + apBonus * h.speed
        return avg / h.speed * mult * tableMult
    end
    return hand(s.mh, 1) + hand(s.oh, 0.5)
end

-- Returns a sorted list of spell results plus stat weights.
function Sim:Run(s)
    local results = {}
    for _, spell in ipairs(s.spells or {}) do
        local r = self:SpellResult(spell, s)
        r.spell = spell
        table.insert(results, r)
    end
    table.sort(results, function(a, b) return a.dps > b.dps end)

    local weights = {}
    local top = results[1]
    if top and top.spell.kind == "damage" then
        local base = top.dps
        weights.sp10 = self:SpellResult(top.spell, s, 10).dps - base
        weights.crit1 = self:SpellResult(top.spell, s, 0, 1).dps - base
    end
    local melee = self:MeleeDPS(s)
    if melee > 0 then
        weights.ap14 = self:MeleeDPS(s, 14) - melee
        weights.meleeCrit1 = self:MeleeDPS(s, 0, 1) - melee
        weights.hit1 = self:MeleeDPS(s, 0, 0, 1) - melee
    end
    return results, melee, weights
end

-- Compact text the web page (forever/index.html) can import.
-- Fields are separated by "&" since "|" is an escape character in WoW edit boxes.
function Sim:Export(s)
    local parts = { "FG1" }
    local function add(k, v) if v ~= nil then table.insert(parts, k .. "=" .. tostring(v)) end end
    local function hand(h) return h and string.format("%.1f-%.1f@%.2f", h.min, h.max, h.speed) or nil end
    add("class", s.class); add("race", s.race); add("lvl", s.level)
    for _, k in ipairs(STAT_KEYS) do add(k, s[k]) end
    add("hp", s.hp); add("mana", s.mana); add("ap", s.ap); add("rap", s.rap)
    add("crit", s.crit and string.format("%.2f", s.crit)); add("scrit", s.spellCrit and string.format("%.2f", s.spellCrit))
    add("sp", s.sp); add("heal", s.healing); add("hit", s.hit); add("shit", s.spellHit)
    add("regen", s.regen and string.format("%.2f", s.regen))
    add("mh", hand(s.mh)); add("oh", hand(s.oh)); add("rng", hand(s.ranged))
    local spells = {}
    for _, sp in ipairs(s.spells or {}) do
        local name = sp.name:gsub("[|;:=&]", "")
        table.insert(spells, table.concat({ name, sp.kind:sub(1, 1), sp.min, sp.max, sp.dot, sp.dur, sp.cast, sp.cd, sp.cost }, ":"))
    end
    add("spells", table.concat(spells, ";"))
    return table.concat(parts, "&")
end
