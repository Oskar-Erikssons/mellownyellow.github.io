-- Forever Guide: small helpers that make play smoother.
--   Smart spell queue: keeps the game's Spell Queue Window matched to your latency and class,
--   and adjusts it again when your connection changes. A slider leaves that to you; this does not.
local _, FG = ...
local QoL = {}
FG.QoL = QoL

-- Melee wants a tight window, casters and hunters a wider one to cover latency.
local EXTRA = { WARRIOR = 100, ROGUE = 100, PALADIN = 125, SHAMAN = 125, DRUID = 125,
    HUNTER = 150, MAGE = 150, WARLOCK = 150, PRIEST = 150 }

-- Pure: the window in milliseconds for a latency and class, in steps of 10 between 100 and 400.
function QoL.SpellQueueFor(latency, class)
    local ms = (latency or 0) + (EXTRA[class] or 125)
    ms = math.floor(ms / 10 + 0.5) * 10
    return math.max(100, math.min(400, ms))
end

function QoL:Latency()
    local _, _, home, world = GetNetStats()
    return math.max(home or 0, world or 0)
end

function QoL:Recommended()
    return QoL.SpellQueueFor(self:Latency(), select(2, UnitClass("player")))
end

-- Sets the window when it is off by 20 ms or more. Never in combat.
function QoL:ApplySpellQueue(announce)
    if not FG.settings.smartQueue or InCombatLockdown() then return end
    local want = self:Recommended()
    local now = tonumber(C_CVar.GetCVar("SpellQueueWindow")) or 400
    if math.abs(want - now) >= 20 then
        C_CVar.SetCVar("SpellQueueWindow", want)
        if announce then FG:Print(string.format("Spell queue set to %d ms (latency %d ms).", want, self:Latency())) end
    end
end

FG:On("PLAYER_LOGIN", function()
    C_Timer.After(10, function() QoL:ApplySpellQueue(true) end)
    C_Timer.NewTicker(120, function() QoL:ApplySpellQueue(false) end)
end)
