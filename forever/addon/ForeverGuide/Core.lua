-- Forever Guide: core, settings and slash commands.
local ADDON, FG = ...
FG = FG or {}
_G.ForeverGuide = FG

FG.VERSION = "0.2.0"

local DEFAULTS = {
    autoRead = true,      -- read quest text automatically when an NPC shows it
    readGossip = true,    -- also read NPC gossip text
    mode = "both",        -- "voices" = only AI clips, "builtin" = only game TTS, "both" = clip first, TTS as fallback
    rate = 0,             -- built-in TTS rate, -10..10
    volume = 100,         -- built-in TTS volume, 0..100
    maleVoice = nil,      -- built-in TTS voice IDs; nil = pick automatically
    femaleVoice = nil,
    stripEmotes = true,   -- drop "<The dwarf grunts.>" before speaking
    collect = true,       -- queue unvoiced texts for the companion app
    tooltipIncludesSP = false, -- set true if spell tooltips already include spell power
    targetLevelDiff = 0,  -- simulator: target level minus your level
    ttsLegacy = false,    -- use the pre-12.0 C_VoiceChat.SpeakText signature
    voiceVariety = true,  -- each NPC gets its own built-in voice and speed
    theme = "orgrimmar",  -- "orgrimmar" (dark) or "stormwind" (light)
    colors = {},          -- your own colors per theme
    tooltip = true,       -- AH and vendor prices in item tooltips
    house = "auto",       -- "auto", "faction" or "neutral" auction house
    duration = "24",      -- auction length used in the advice: "2", "8" or "24" hours
    sellJunk = true,      -- merchant button sells grey items
    sellAdvised = false,  -- merchant button also sells trade goods the advice says to vendor
}

FG.events = CreateFrame("Frame")
FG.handlers = {}

function FG:On(event, fn)
    self.handlers[event] = self.handlers[event] or {}
    table.insert(self.handlers[event], fn)
    -- Events differ between client versions; registering an unknown one raises an error.
    pcall(self.events.RegisterEvent, self.events, event)
end

FG.events:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(FG.handlers[event] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then FG:Print("|cffff5555Error in " .. event .. ":|r " .. tostring(err)) end
    end
end)

function FG:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Forever Guide:|r " .. tostring(msg))
end

-- Forever runs with Midnight-style secret values. A secret cannot be read or
-- compared by addons, so treat it as "unknown".
function FG.Safe(v)
    if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
    return v
end

-- Call an API that may be missing or restricted on this client.
function FG.Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local res = { pcall(fn, ...) }
    if not res[1] then return nil end
    for i = 2, #res do res[i] = FG.Safe(res[i]) end
    return unpack(res, 2)
end

-- djb2 over the bytes, kept below 2^32 with plain arithmetic (no bit library needed).
function FG.Hash(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

function FG.Normalize(text)
    text = text or ""
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("%s+", " ")
    return (text:gsub("^ ", ""):gsub(" $", ""))
end

local function initDB()
    ForeverGuideDB = ForeverGuideDB or {}
    local db = ForeverGuideDB
    db.settings = db.settings or {}
    for k, v in pairs(DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    db.voiceQueue = db.voiceQueue or {}
    db.snapshots = db.snapshots or {}
    FG.db = db
    FG.settings = db.settings
end

FG:On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    initDB()
    if FG.Narrator then FG.Narrator:Init() end
    FG:Print("v" .. FG.VERSION .. " loaded. Type /fg for help.")
end)

local HELP = {
    "/fg read - read the selected quest in your quest log",
    "/fg stop - stop speaking",
    "/fg auto on|off - read quest text automatically",
    "/fg gossip on|off - also read NPC gossip",
    "/fg mode voices|builtin|both - which voice to use",
    "/fg rate <-10..10>, /fg volume <0..100>",
    "/fg voices - list built-in TTS voices",
    "/fg voice male|female <id> - choose built-in voice",
    "/fg queue - how many texts wait for AI voices",
    "/fg sim - stats and spell simulator",
    "/fg export - copy your character for the web simulator",
    "/fg sp on|off - tooltips already include spell power",
    "/fg target <0..3> - target is this many levels above you",
    "/fg legacy on|off - try this if built-in speech sounds wrong",
    "/fg variety on|off - a different built-in voice for each NPC",
    "/fg options - themes, colors and settings",
    "/fg ah - auction house: prices, advice, flips and sales",
    "/fg house auto|faction|neutral - which auction house prices to use",
    "/fg tooltip on|off - prices in item tooltips",
}

local function onOff(arg, key)
    if arg == "on" then FG.settings[key] = true elseif arg == "off" then FG.settings[key] = false end
    FG:Print(key .. " = " .. tostring(FG.settings[key]))
end

SLASH_FOREVERGUIDE1 = "/fg"
SLASH_FOREVERGUIDE2 = "/foreverguide"
SlashCmdList.FOREVERGUIDE = function(msg)
    local cmd, a, b = strsplit(" ", strtrim(msg or ""):lower())
    local s = FG.settings
    if cmd == "read" then
        FG.Narrator:ReadQuestLog()
    elseif cmd == "stop" then
        FG.Narrator:Stop()
    elseif cmd == "auto" then
        onOff(a, "autoRead")
    elseif cmd == "gossip" then
        onOff(a, "readGossip")
    elseif cmd == "sp" then
        onOff(a, "tooltipIncludesSP")
    elseif cmd == "legacy" then
        onOff(a, "ttsLegacy")
    elseif cmd == "variety" then
        onOff(a, "voiceVariety")
    elseif cmd == "tooltip" then
        onOff(a, "tooltip")
    elseif cmd == "house" and (a == "auto" or a == "faction" or a == "neutral") then
        s.house = a
        FG:Print("house = " .. a)
    elseif cmd == "options" or cmd == "theme" then
        FG.UI:ShowOptions()
    elseif cmd == "ah" then
        FG.UI:ShowAuction()
    elseif cmd == "mode" and (a == "voices" or a == "builtin" or a == "both") then
        s.mode = a
        FG:Print("mode = " .. a)
    elseif cmd == "rate" and tonumber(a) then
        s.rate = math.max(-10, math.min(10, tonumber(a)))
        FG:Print("rate = " .. s.rate)
    elseif cmd == "volume" and tonumber(a) then
        s.volume = math.max(0, math.min(100, tonumber(a)))
        FG:Print("volume = " .. s.volume)
    elseif cmd == "voices" then
        FG.Narrator:ListVoices()
    elseif cmd == "voice" and (a == "male" or a == "female") and tonumber(b) then
        s[a .. "Voice"] = tonumber(b)
        FG:Print(a .. " voice = " .. b)
    elseif cmd == "queue" then
        local n = 0
        for _ in pairs(FG.db.voiceQueue) do n = n + 1 end
        FG:Print(n .. " texts are waiting for the companion app. Log out, run forever_voice.py, then restart the game.")
    elseif cmd == "target" and tonumber(a) then
        s.targetLevelDiff = math.max(0, math.min(3, math.floor(tonumber(a))))
        FG:Print("target level difference = " .. s.targetLevelDiff)
    elseif cmd == "sim" then
        FG.UI:ShowSim()
    elseif cmd == "export" then
        FG.UI:ShowExport()
    else
        for _, line in ipairs(HELP) do FG:Print(line) end
    end
end
