-- Forever Guide: where to level next, and talent advice from a template.
-- Talents are only suggested; you still click them yourself.
local _, FG = ...
local Route = {}
local Talents = {}
FG.Route, FG.Talents = Route, Talents

------------------------------------------------------------------------
-- Leveling route (same rules as planRoute() in app.js)
------------------------------------------------------------------------

local function fits(z, faction) return z.faction == "Both" or z.faction == faction end

-- Zones and dungeons for a level, sorted so the current continent comes first.
function Route.ForLevel(level, faction, race, continent)
    local D = FG.Data
    local zones, dungeons = {}, {}
    if level < 10 and D.startZones[race] then
        for _, z in ipairs(D.zones) do
            if z.name == D.startZones[race] then table.insert(zones, z) end
        end
    else
        for _, z in ipairs(D.zones) do
            if fits(z, faction) and z.min > 1 and z.min <= level and z.max >= level then table.insert(zones, z) end
        end
        table.sort(zones, function(a, b)
            local ca, cb = a.continent == continent, b.continent == continent
            if ca ~= cb then return ca end
            return math.abs((a.min + a.max) / 2 - level) < math.abs((b.min + b.max) / 2 - level)
        end)
    end
    for _, d in ipairs(D.dungeons) do
        if fits(d, faction) and d.min <= level + 2 and d.max >= level then table.insert(dungeons, d) end
    end
    return zones, dungeons
end

function Route.Milestones(level, classToken, ahead)
    local out = {}
    for _, m in ipairs(FG.Data.milestones) do
        if m.level >= level and m.level <= level + (ahead or 5) and (m.class == "ALL" or m.class == classToken) then
            table.insert(out, m)
        end
    end
    table.sort(out, function(a, b) return a.level < b.level end)
    return out
end

local function continentOf(zoneName)
    for _, z in ipairs(FG.Data.zones) do
        if z.name == zoneName then return z.continent end
    end
end

function Route:Text()
    local T = FG.Theme
    local level = UnitLevel("player")
    local _, race = UnitRace("player")
    local _, classToken = UnitClass("player")
    local faction = UnitFactionGroup("player")
    local here = GetRealZoneText and GetRealZoneText() or ""
    local zones, dungeons = Route.ForLevel(level, faction, race, continentOf(here))
    local lines = { T:Color("title", string.format("Level %d · you are in %s", level, here)), " " }
    local function add(t) table.insert(lines, t) end
    add(T:Color("accent", "Quest here:"))
    for i, z in ipairs(zones) do
        if i > 3 then break end
        local mark = z.name == here and T:Color("good", "  (you are here)") or ""
        add(string.format("  %s  %d-%d%s", z.name, z.min, z.max, mark))
    end
    if #dungeons > 0 then
        add(" ")
        add(T:Color("accent", "Dungeons for your level:"))
        for _, d in ipairs(dungeons) do add(string.format("  %s  %d-%d", d.name, d.min, d.max)) end
    end
    local ms = Route.Milestones(level, classToken, 6)
    if #ms > 0 then
        add(" ")
        add(T:Color("accent", "Coming up:"))
        for _, m in ipairs(ms) do add(string.format("  Level %d: %s", m.level, m.text)) end
    end
    local next = Talents:Next()
    if next then
        add(" ")
        add(T:Color("accent", "Next talent point: ") .. string.format("%s (rank %d)", next.name, next.rank))
    end
    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Talents
------------------------------------------------------------------------

-- Reads the talent tree from the game. Uses the classic talent API, which Forever's 2004 trees need.
function Talents:Read()
    if not (GetNumTalentTabs and GetTalentInfo) then return nil end
    local tree = { tabs = {}, talents = {} }
    for tab = 1, GetNumTalentTabs() do
        local name = GetTalentTabInfo(tab)
        tree.tabs[tab] = type(name) == "string" and name or select(2, GetTalentTabInfo(tab)) or ("Tree " .. tab)
        for i = 1, GetNumTalents(tab) do
            local tname, _, tier, col, rank, maxRank = GetTalentInfo(tab, i)
            if tname then
                local preTier, preCol = 0, 0
                if GetTalentPrereqs then preTier, preCol = GetTalentPrereqs(tab, i) end
                table.insert(tree.talents, { tab = tab, index = i, tier = tier, col = col, rank = rank or 0, max = maxRank,
                    preTier = preTier or 0, preCol = preCol or 0, name = tname })
            end
        end
    end
    return tree
end

function Talents:Export()
    local tree = self:Read()
    if not tree then return nil end
    local _, classToken = UnitClass("player")
    local rows = {}
    for _, t in ipairs(tree.talents) do
        table.insert(rows, table.concat({ t.tab, t.tier, t.col, t.max, t.preTier, t.preCol, t.rank, (t.name:gsub("[;&|]", "")) }, ":"))
    end
    return "FGT1&class=" .. classToken .. "&tabs=" .. table.concat(tree.tabs, "|") .. "&t=" .. table.concat(rows, ";")
end

function Talents:Template()
    local _, classToken = UnitClass("player")
    local list = FG.Data.talentTemplates[classToken]
    return list and list[FG.settings.talentTemplate or 1]
end

-- Pure: the first point in the template that is not spent yet. ranks = { [name] = rank }.
function Talents.NextFromTemplate(template, ranks)
    local wanted = {}
    for _, pick in ipairs(template.picks) do
        local name, n = pick[1], pick[2]
        wanted[name] = (wanted[name] or 0) + n
        if (ranks[name] or 0) < wanted[name] then
            return { name = name, rank = (ranks[name] or 0) + 1 }
        end
    end
end

function Talents:Next()
    local template, tree = self:Template(), self:Read()
    if not (template and tree) then return nil end
    local ranks = {}
    for _, t in ipairs(tree.talents) do ranks[t.name] = t.rank end
    return Talents.NextFromTemplate(template, ranks)
end

local function announce()
    local free = UnitCharacterPoints and UnitCharacterPoints("player") or 0
    if (free or 0) <= 0 then return end
    local n = Talents:Next()
    if n then FG:Print(string.format("You have a talent point. Template suggests: %s (rank %d).", n.name, n.rank)) end
end

FG:On("PLAYER_LEVEL_UP", function() C_Timer.After(1, announce) end)
FG:On("CHARACTER_POINTS_CHANGED", announce)
