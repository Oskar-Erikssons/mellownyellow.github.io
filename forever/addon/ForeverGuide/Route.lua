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
    local plan = FG.Trainer and FG.Trainer:PlanText()
    if plan then
        add(" ")
        add(T:Color("accent", "Class trainer:"))
        add(plan)
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

-- Forever's talents use the modern trait system (C_ClassTalents and C_Traits), as the client's own
-- code on the forever branch shows; the 2004 talent functions do not exist there. Trait nodes have
-- a position, so trees, tiers and columns are worked out from where the nodes sit.

local function round(v, step) return math.floor(v / step + 0.5) * step end

-- Pure: nodes { id, x, y, rank, max, name, edges = { target node IDs } } to { tabs, talents } with
-- tab, tier, column and prerequisite, like the 2004 trees. Columns far apart form separate trees.
function Talents.Layout(nodes)
    local xs, seen = {}, {}
    for _, n in ipairs(nodes) do
        n.gx, n.gy = round(n.x, 50), round(n.y, 50)
        if not seen[n.gx] then seen[n.gx] = true table.insert(xs, n.gx) end
    end
    table.sort(xs)
    local gaps = {}
    for i = 2, #xs do table.insert(gaps, xs[i] - xs[i - 1]) end
    table.sort(gaps)
    local step = gaps[math.max(1, math.ceil(#gaps / 2))] or 1
    local tabOf, colOf, tab, col = {}, {}, 1, 0
    for i, x in ipairs(xs) do
        if i > 1 and x - xs[i - 1] > step * 2.5 then tab, col = tab + 1, 0 end
        col = col + 1
        tabOf[x], colOf[x] = tab, col
    end
    local ys = {}
    for _, n in ipairs(nodes) do
        local t = tabOf[n.gx]
        ys[t] = ys[t] or {}
        ys[t][n.gy] = true
    end
    local tierOf = {}
    for t, set in pairs(ys) do
        local list = {}
        for y in pairs(set) do table.insert(list, y) end
        table.sort(list)
        tierOf[t] = {}
        for i, y in ipairs(list) do tierOf[t][y] = i end
    end
    local out, byID = { tabs = {}, talents = {} }, {}
    for i = 1, tab do out.tabs[i] = "Tree " .. i end
    for _, n in ipairs(nodes) do
        local t = tabOf[n.gx]
        local entry = { id = n.id, tab = t, tier = tierOf[t][n.gy], col = colOf[n.gx], rank = n.rank or 0,
            max = n.max, name = n.name, preTier = 0, preCol = 0 }
        byID[n.id] = entry
        table.insert(out.talents, entry)
    end
    -- An edge from one node to another means the second needs the first.
    for _, n in ipairs(nodes) do
        local from = byID[n.id]
        for _, target in ipairs(n.edges or {}) do
            local to = byID[target]
            if to and to.tab == from.tab then to.preTier, to.preCol = from.tier, from.col end
        end
    end
    table.sort(out.talents, function(a, b)
        if a.tab ~= b.tab then return a.tab < b.tab end
        if a.tier ~= b.tier then return a.tier < b.tier end
        return a.col < b.col
    end)
    return out
end

-- The active talent config and tree.
function Talents:Active()
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits) then return nil end
    local configID = C_ClassTalents.GetActiveConfigID()
    local config = configID and C_Traits.GetConfigInfo(configID)
    local treeID = config and config.treeIDs and config.treeIDs[1]
    if treeID then return configID, treeID end
end

-- Reads every visible talent node with its name, rank and links.
function Talents:Nodes()
    local configID, treeID = self:Active()
    if not configID then return nil end
    local nodes = {}
    for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
        local n = C_Traits.GetNodeInfo(configID, nodeID)
        if n and n.isVisible ~= false and (n.maxRanks or 0) > 0 then
            local entryID = (n.activeEntry and n.activeEntry.entryID) or (n.entryIDs and n.entryIDs[1])
            local entry = entryID and C_Traits.GetEntryInfo(configID, entryID)
            local def = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
            local name = def and ((def.overrideName and def.overrideName ~= "" and def.overrideName)
                or (def.spellID and C_Spell.GetSpellName(def.spellID)))
            if name then
                local edges = {}
                for _, e in ipairs(n.visibleEdges or {}) do table.insert(edges, e.targetNode) end
                table.insert(nodes, { id = nodeID, x = n.posX or 0, y = n.posY or 0, max = n.maxRanks,
                    rank = n.ranksPurchased or n.currentRank or 0, name = name, edges = edges })
            end
        end
    end
    return nodes
end

function Talents:Read()
    local nodes = self:Nodes()
    if not nodes or #nodes == 0 then return nil end
    return Talents.Layout(nodes)
end

-- Unspent talent points, from the tree's currency.
function Talents:Unspent()
    local configID, treeID = self:Active()
    if not configID or not C_Traits.GetTreeCurrencyInfo then return 0 end
    local currencies = C_Traits.GetTreeCurrencyInfo(configID, treeID, false) or {}
    return currencies[1] and currencies[1].quantity or 0
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
    if Talents:Unspent() <= 0 then return end
    local n = Talents:Next()
    if n then FG:Print(string.format("You have a talent point. Template suggests: %s (rank %d).", n.name, n.rank)) end
end

FG:On("PLAYER_LEVEL_UP", function() C_Timer.After(1, announce) end)
FG:On("TRAIT_CONFIG_UPDATED", announce)
