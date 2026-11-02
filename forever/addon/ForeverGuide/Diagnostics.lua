-- Forever Guide: checks itself in the real game, and keeps a local log of errors.
--   /fg selftest  checks every function, event and template the addon uses (list in ApiList.lua,
--                 generated from the code, so it never goes out of date)
--   /fg report    text to copy if something goes wrong; nothing is ever sent anywhere
local _, FG = ...
local Diag = {}
FG.Diag = Diag

local MAX_ERRORS = 30

-- Pure: looks up "C_AuctionHouse.PostItem" or "PlaySoundFile" in a table of globals.
function Diag.Resolve(path, env)
    local value = env
    for part in path:gmatch("[^%.]+") do
        if type(value) ~= "table" then return nil end
        value = value[part]
    end
    return value
end

-- Pure: which of the listed functions are missing. Returns required and optional misses.
function Diag.MissingFunctions(list, env)
    local optional, missing, missingOptional = {}, {}, {}
    for _, name in ipairs(list.optional or {}) do optional[name] = true end
    for _, name in ipairs(list.functions or {}) do
        if type(Diag.Resolve(name, env)) ~= "function" then
            table.insert(optional[name] and missingOptional or missing, name)
        end
    end
    return missing, missingOptional
end

function Diag:Log(where, message)
    local db = FG.db
    if not db then return end
    db.errors = db.errors or {}
    table.insert(db.errors, { t = time(), where = where, msg = tostring(message):sub(1, 300), v = FG.VERSION })
    while #db.errors > MAX_ERRORS do table.remove(db.errors, 1) end
end

function Diag:SelfTest()
    local list = FG.API_USED or {}
    local missing, missingOptional = Diag.MissingFunctions(list, _G)
    local badEvents = {}
    local probe = CreateFrame("Frame")
    for _, event in ipairs(list.events or {}) do
        if not pcall(probe.RegisterEvent, probe, event) then table.insert(badEvents, event) end
    end
    probe:UnregisterAllEvents()
    local badTemplates = {}
    if not InCombatLockdown() then
        for _, template in ipairs(list.templates or {}) do
            local ok = pcall(CreateFrame, "Frame", nil, nil, template)
            if not ok then ok = pcall(CreateFrame, "Button", nil, nil, template) end
            if not ok then ok = pcall(CreateFrame, "ItemButton", nil, nil, template) end
            if not ok then ok = pcall(CreateFrame, "EditBox", nil, nil, template) end
            if not ok then ok = pcall(CreateFrame, "ScrollFrame", nil, nil, template) end
            if not ok then table.insert(badTemplates, template) end
        end
    end
    local result = {
        t = time(), version = FG.VERSION, build = select(2, GetBuildInfo()), interface = select(4, GetBuildInfo()),
        project = WOW_PROJECT_ID, forever = FG.IsForever, functions = #(list.functions or {}),
        missing = missing, missingOptional = missingOptional, badEvents = badEvents, badTemplates = badTemplates,
    }
    FG.db.selftest = result
    return result
end

function Diag:SelfTestText(r)
    local T = FG.Theme
    local lines = {}
    local function add(t) table.insert(lines, t) end
    local ok = #r.missing == 0 and #r.badEvents == 0 and #r.badTemplates == 0
    add(T:Color(ok and "good" or "bad", ok and "Everything Forever Guide needs is here." or "Something is missing:"))
    add(string.format("%d functions, %d events and %d templates checked on build %s (interface %s, project %s).",
        r.functions, #(FG.API_USED.events or {}), #(FG.API_USED.templates or {}), tostring(r.build), tostring(r.interface), tostring(r.project)))
    for _, n in ipairs(r.missing) do add(T:Color("bad", "  missing function " .. n)) end
    for _, n in ipairs(r.badEvents) do add(T:Color("bad", "  unknown event " .. n)) end
    for _, n in ipairs(r.badTemplates) do add(T:Color("bad", "  missing template " .. n)) end
    for _, n in ipairs(r.missingOptional) do add(T:Color("muted", "  not available (a fallback is used): " .. n)) end
    return table.concat(lines, "\n")
end

-- Plain text with version, self test and recent errors, for you to copy if you want help.
function Diag:Report()
    local r = FG.db.selftest or self:SelfTest()
    local out = {
        "Forever Guide " .. FG.VERSION .. " · build " .. tostring(r.build) .. " · interface " .. tostring(r.interface),
        "Missing: " .. (#r.missing > 0 and table.concat(r.missing, ", ") or "none"),
        "Unknown events: " .. (#r.badEvents > 0 and table.concat(r.badEvents, ", ") or "none"),
        "Missing templates: " .. (#r.badTemplates > 0 and table.concat(r.badTemplates, ", ") or "none"),
        "Fallbacks: " .. (#r.missingOptional > 0 and table.concat(r.missingOptional, ", ") or "none"),
        "Errors:",
    }
    for i = #(FG.db.errors or {}), 1, -1 do
        local e = FG.db.errors[i]
        table.insert(out, string.format("  %s %s [%s] %s", date("%m-%d %H:%M", e.t), e.v or "?", e.where, e.msg))
    end
    if #(FG.db.errors or {}) == 0 then table.insert(out, "  none") end
    return table.concat(out, "\n")
end

-- Run the self test quietly once per version; only speak up if something is wrong.
FG:On("PLAYER_LOGIN", function()
    C_Timer.After(20, function()
        if FG.db.selftest and FG.db.selftest.version == FG.VERSION and FG.db.selftest.build == select(2, GetBuildInfo()) then return end
        local r = Diag:SelfTest()
        if #r.missing > 0 or #r.badEvents > 0 or #r.badTemplates > 0 then
            FG:Print("Self test found problems after a game update. Type /fg selftest for details.")
        end
    end)
end)
