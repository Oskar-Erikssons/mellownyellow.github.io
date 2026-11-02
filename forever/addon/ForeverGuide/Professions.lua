-- Forever Guide: professions and training.
--   * Tells you when a profession can train its next rank.
--   * Lists the herbs and ores your skill can gather, by auction value, and names new ones as you unlock them.
--   * Remembers what your class trainer offers, so you know what the next visit costs.
local _, FG = ...
local Prof = {}
local Trainer = {}
FG.Professions, FG.Trainer = Prof, Trainer

------------------------------------------------------------------------
-- Pure helpers (covered by tests)
------------------------------------------------------------------------

-- The next rank to train, or nil. ready is true when skill and level allow it now.
function Prof.NextRank(skill, maxSkill, level, ranks)
    for _, r in ipairs(ranks) do
        if r.cap > maxSkill then
            return r, skill >= r.needSkill and level >= r.needLevel
        end
    end
end

-- Nodes you can gather at this skill, and the ones that open between oldSkill and newSkill.
function Prof.Gatherable(nodes, skill, oldSkill)
    local can, new = {}, {}
    for _, n in ipairs(nodes or {}) do
        if n.skill <= skill then
            table.insert(can, n)
            if oldSkill and n.skill > oldSkill then table.insert(new, n) end
        end
    end
    return can, new
end

-- What a trainer list says about your next visits: spells per level and their total cost.
-- spells: { { name, rank, level, cost, known } }
function Trainer.Plan(spells, level, ahead)
    local now, soon, costNow = {}, {}, 0
    for _, s in ipairs(spells or {}) do
        if not s.known then
            if s.level <= level then
                table.insert(now, s)
                costNow = costNow + (s.cost or 0)
            elseif s.level <= level + (ahead or 4) then
                table.insert(soon, s)
            end
        end
    end
    table.sort(soon, function(a, b) return a.level < b.level end)
    local nextLevel = soon[1] and soon[1].level
    local costNext, countNext = 0, 0
    for _, s in ipairs(soon) do
        if s.level == nextLevel then costNext, countNext = costNext + (s.cost or 0), countNext + 1 end
    end
    return { now = now, costNow = costNow, soon = soon, nextLevel = nextLevel, costNext = costNext, countNext = countNext }
end

------------------------------------------------------------------------
-- Professions in game
------------------------------------------------------------------------

-- Returns { name, skill, max } for each profession. Uses GetProfessions where it exists.
function Prof:Read()
    local out = {}
    if GetProfessions and GetProfessionInfo then
        -- Empty profession slots come back as nil, so walk every return value instead of using ipairs.
        local slots = { GetProfessions() }
        for i = 1, select("#", GetProfessions()) do
            local index = slots[i]
            if index then
                local name, _, skill, max = GetProfessionInfo(index)
                if name then table.insert(out, { name = name, skill = skill, max = max }) end
            end
        end
    elseif GetNumSkillLines then
        for i = 1, GetNumSkillLines() do
            local name, header, _, skill, _, _, max = GetSkillLineInfo(i)
            if not header and (FG.Data.gatherNodes[name] or (max and max >= 75 and max % 75 == 0)) then
                table.insert(out, { name = name, skill = skill, max = max })
            end
        end
    end
    return out
end

local function auctionValue(itemID)
    local e = FG.Auction:Price(itemID)
    return e and e.m or 0
end

function Prof:Check(announce)
    local known = FG.db.profSkill or {}
    FG.db.profSkill = known
    local level = UnitLevel("player")
    for _, p in ipairs(self:Read()) do
        local rank, ready = Prof.NextRank(p.skill, p.max, level, FG.Data.professionRanks)
        local flag = p.name .. ":" .. (rank and rank.name or "")
        if announce and rank and ready and not FG.db.profAnnounced[flag] then
            FG.db.profAnnounced[flag] = true
            FG:Print(string.format("%s can train %s now. Visit a trainer.", p.name, rank.name))
        end
        local nodes = FG.Data.gatherNodes[p.name]
        if nodes and announce and known[p.name] and p.skill > known[p.name] then
            local _, new = Prof.Gatherable(nodes, p.skill, known[p.name])
            for _, n in ipairs(new) do
                local v = auctionValue(n.item)
                FG:Print(string.format("New for %s: %s%s", p.name, n.name, v > 0 and (" (AH " .. FG.Auction.Money(v) .. ")") or ""))
            end
        end
        known[p.name] = p.skill
    end
end

function Prof:Text()
    local T = FG.Theme
    local lines = {}
    local level = UnitLevel("player")
    for _, p in ipairs(self:Read()) do
        table.insert(lines, T:Color("title", string.format("%s %d/%d", p.name, p.skill, p.max)))
        local rank, ready = Prof.NextRank(p.skill, p.max, level, FG.Data.professionRanks)
        if rank then
            table.insert(lines, ready and T:Color("good", "  Ready to train " .. rank.name)
                or string.format("  %s at skill %d and level %d", rank.name, rank.needSkill, rank.needLevel))
        end
        local nodes = FG.Data.gatherNodes[p.name]
        if nodes then
            local can = Prof.Gatherable(nodes, p.skill)
            table.sort(can, function(a, b) return auctionValue(a.item) > auctionValue(b.item) end)
            for i, n in ipairs(can) do
                if i > 6 then break end
                local v = auctionValue(n.item)
                table.insert(lines, string.format("  %s%s", n.name, v > 0 and ("  " .. FG.Auction.Money(v)) or ""))
            end
        end
        table.insert(lines, " ")
    end
    if #lines == 0 then return "No professions learned yet." end
    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Trainer in game: learns what the trainer offers when you visit
------------------------------------------------------------------------

function Trainer:Record()
    if not (GetNumTrainerServices and GetTrainerServiceInfo) then return end
    local _, class = UnitClass("player")
    local list = {}
    for i = 1, GetNumTrainerServices() do
        -- Forever's client returns: name, type ("available", "unavailable", "used" or "header"),
        -- icon, required level and rank text (checked against Blizzard_TrainerUI on the forever branch).
        local name, serviceType, _, reqLevel, rank = GetTrainerServiceInfo(i)
        if name and serviceType ~= "header" then
            table.insert(list, {
                name = name, rank = rank, level = reqLevel or 0,
                cost = GetTrainerServiceCost and GetTrainerServiceCost(i) or 0,
                known = serviceType == "used",
            })
        end
    end
    -- Only keep class trainer lists; profession trainers have their own window.
    if #list > 0 and not (IsTradeskillTrainer and IsTradeskillTrainer()) then
        FG.db.trainer = FG.db.trainer or {}
        FG.db.trainer[class] = { spells = list, t = time() }
    end
end

function Trainer:PlanText()
    local _, class = UnitClass("player")
    local saved = FG.db.trainer and FG.db.trainer[class]
    if not saved then return nil end
    local plan = Trainer.Plan(saved.spells, UnitLevel("player"), 6)
    local money = GetMoney()
    local T = FG.Theme
    local lines = {}
    if #plan.now > 0 then
        local afford = money >= plan.costNow
        table.insert(lines, string.format("Train now: %d spells for %s%s", #plan.now, FG.Auction.Money(plan.costNow),
            afford and "" or T:Color("bad", " (you are short of gold)")))
    end
    if plan.nextLevel then
        table.insert(lines, string.format("Level %d: %d new spells for %s", plan.nextLevel, plan.countNext,
            FG.Auction.Money(plan.costNext)))
    end
    return #lines > 0 and table.concat(lines, "\n") or nil
end

FG:On("PLAYER_LOGIN", function()
    FG.db.profAnnounced = FG.db.profAnnounced or {}
    C_Timer.After(5, function() Prof:Check(false) end)
end)
FG:On("SKILL_LINES_CHANGED", function() Prof:Check(true) end)
FG:On("PLAYER_LEVEL_UP", function() C_Timer.After(2, function() Prof:Check(true) end) end)
FG:On("TRAINER_SHOW", function() C_Timer.After(0.3, function() Trainer:Record() end) end)
FG:On("TRAINER_UPDATE", function() Trainer:Record() end)
