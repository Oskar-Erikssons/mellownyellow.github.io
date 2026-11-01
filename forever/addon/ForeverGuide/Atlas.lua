-- Forever Guide: the atlas. Reads every zone and dungeon from the game itself (name, continent and,
-- where the client tells, level range), and lists what Forever Guide's data does not know yet.
-- This is how new Forever zones and instances get into the leveling route without outside sources.
local _, FG = ...
local Atlas = {}
FG.Atlas = Atlas

local MAX_MAP_ID = 4000 -- uiMap IDs seen in Forever so far go up to about 3000
local BATCH = 250
local TYPE_ZONE, TYPE_DUNGEON, TYPE_CONTINENT = 3, 4, 2
local CONTINENT_CODES = { [1414] = "KAL", [1415] = "EK" }

------------------------------------------------------------------------
-- Pure helpers (covered by tests)
------------------------------------------------------------------------

local function norm(name) return (name or ""):lower():gsub("^the ", "") end

-- Every name Forever Guide's data already knows: zones, dungeons, raids and other maps.
function Atlas.KnownNames(data)
    local known = {}
    for _, list in ipairs({ data.zones or {}, data.dungeons or {}, data.raids or {} }) do
        for _, z in ipairs(list) do known[norm(z.name)] = z end
    end
    for _, name in ipairs(data.otherMaps or {}) do known[norm(name)] = true end
    return known
end

-- Maps the game knows that the data does not, and known zones whose levels differ from the game's.
function Atlas.Diff(maps, data)
    local known = Atlas.KnownNames(data)
    local missing, changed = {}, {}
    for id, m in pairs(maps) do
        if m.type == TYPE_ZONE or m.type == TYPE_DUNGEON then
            local k = known[norm(m.name)]
            if not k then
                table.insert(missing, { id = id, m = m })
            elseif type(k) == "table" and m.min and m.min > 0 and (k.min ~= m.min or k.max ~= m.max) then
                table.insert(changed, { id = id, m = m, data = k })
            end
        end
    end
    table.sort(missing, function(a, b) return (a.m.min or 99) < (b.m.min or 99) end)
    return missing, changed
end

-- Compact text for companion/atlas_import.py: id:type:parent:min:max:name
function Atlas.Export(maps)
    local rows = {}
    for id, m in pairs(maps) do
        if m.type == TYPE_ZONE or m.type == TYPE_DUNGEON or m.type == TYPE_CONTINENT then
            table.insert(rows, table.concat({ id, m.type, m.parent or 0, m.min or 0, m.max or 0,
                (m.name:gsub("[;:&]", "")) }, ":"))
        end
    end
    table.sort(rows)
    return "FGZ1&build=" .. tostring(select(2, GetBuildInfo()) or "") .. "&m=" .. table.concat(rows, ";")
end

function Atlas.ContinentCode(parentID)
    return CONTINENT_CODES[parentID]
end

------------------------------------------------------------------------
-- Reading the game's maps
------------------------------------------------------------------------

local function levelsOf(id)
    if not (C_Map and C_Map.GetMapLevels) then return nil end
    local ok, min, max = pcall(C_Map.GetMapLevels, id)
    if ok and min and min > 0 then return min, max end
end

-- Walks all uiMap IDs a few hundred per frame and calls done(maps) at the end.
function Atlas:Scan(done)
    if not (C_Map and C_Map.GetMapInfo) then return end
    local maps, id = {}, 1
    local function step()
        if InCombatLockdown() then FG.Defer(step) return end
        for n = id, math.min(MAX_MAP_ID, id + BATCH - 1) do
            local info = C_Map.GetMapInfo(n)
            if info and info.name and info.name ~= "" and
                (info.mapType == TYPE_ZONE or info.mapType == TYPE_DUNGEON or info.mapType == TYPE_CONTINENT) then
                local min, max = levelsOf(n)
                maps[n] = { name = info.name, type = info.mapType, parent = info.parentMapID, min = min, max = max }
            end
        end
        id = id + BATCH
        if id > MAX_MAP_ID then
            FG.db.atlas = { t = time(), version = FG.VERSION, maps = maps }
            if done then done(maps) end
        else
            FG.Defer(step)
        end
    end
    step()
end

function Atlas:Text()
    local T = FG.Theme
    local a = FG.db.atlas
    if not a then return "Scanning the game's maps, try again in a few seconds." end
    local missing, changed = Atlas.Diff(a.maps, FG.Data)
    local lines = {}
    local function add(t) table.insert(lines, t) end
    local function where(m)
        local p = a.maps[m.parent or 0]
        return p and p.name or "?"
    end
    local function levels(m) return m.min and string.format("%d-%d", m.min, m.max) or "levels unknown" end
    add(T:Color("title", string.format("%d zones and dungeons the game knows that Forever Guide does not:", #missing)))
    for _, x in ipairs(missing) do
        add(string.format("  %s  %s · %s · map %d%s", x.m.name, levels(x.m), where(x.m), x.id,
            x.m.type == TYPE_DUNGEON and " · dungeon" or ""))
    end
    if #changed > 0 then
        add(" ")
        add(T:Color("title", "Levels that differ from the game:"))
        for _, x in ipairs(changed) do
            add(string.format("  %s: data %d-%d, game %s", x.m.name, x.data.min, x.data.max, levels(x.m)))
        end
    end
    add(" ")
    add(T:Color("muted", "Use /fg atlas export and companion/atlas_import.py to add these to the leveling route."))
    return table.concat(lines, "\n")
end

-- Scan once per addon version, a while after login, out of combat.
FG:On("PLAYER_LOGIN", function()
    local a = FG.db.atlas
    if not a or a.version ~= FG.VERSION then
        C_Timer.After(15, function() Atlas:Scan() end)
    end
end)
