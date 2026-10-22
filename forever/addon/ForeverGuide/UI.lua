-- Forever Guide: simulator window, export window and a "Read aloud" button on the quest frame.
local _, FG = ...
local UI = {}
FG.UI = UI

local function makeWindow(title, width, height)
    local name = "ForeverGuide" .. title:gsub("%W", "")
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, name) -- Escape closes the window

    local header = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOP", 0, -18)
    header:SetText(title)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -46)
    scroll:SetPoint("BOTTOMRIGHT", -36, 20)
    f.scroll = scroll
    return f
end

local function fmt(v, d)
    if v == nil then return "?" end
    return string.format("%." .. (d or 0) .. "f", v)
end

function UI:SimText(s)
    local lines = {}
    local function add(t) table.insert(lines, t) end
    add(string.format("|cffffd200%s %s, level %d|r", s.raceName or "?", s.className or "?", s.level or 0))
    add(string.format("Str %s  Agi %s  Sta %s  Int %s  Spi %s", fmt(s.str), fmt(s.agi), fmt(s.sta), fmt(s.int), fmt(s.spi)))
    add(string.format("Health %s  Mana %s  AP %s  Spell power %s  Healing %s", fmt(s.hp), fmt(s.mana), fmt(s.ap), fmt(s.sp), fmt(s.healing)))
    add(string.format("Melee crit %s%%  Spell crit %s%%  Hit +%s%%  Spell hit +%s%%", fmt(s.crit, 2), fmt(s.spellCrit, 2), fmt(s.hit), fmt(s.spellHit)))
    add(string.format("Target: %d level(s) above you (change with /fg target)", FG.settings.targetLevelDiff or 0))
    add(" ")

    local results, melee, weights = FG.Sim:Run(s)
    if melee > 0 then
        add(string.format("|cff88ccffAuto attack:|r %.1f DPS", melee))
    end
    if #results > 0 then
        add("|cff88ccffSpells, best damage/healing per second first:|r")
        for i, r in ipairs(results) do
            if i > 12 then break end
            local sp = r.spell
            add(string.format("%2d. %s - %.0f per cast, %.1f per sec%s%s",
                i, sp.name, r.perCast, r.dps,
                r.dpm and string.format(", %.2f per mana", r.dpm) or "",
                r.castsToOOM and string.format(", %d casts from full mana", r.castsToOOM) or ""))
        end
    else
        add("No damage or healing spells found in your spellbook.")
    end
    add(" ")
    add("|cff88ccffWhat helps you most right now:|r")
    if weights.sp10 then add(string.format("+10 spell power: +%.2f DPS on your best spell", weights.sp10)) end
    if weights.crit1 then add(string.format("+1%% spell crit: +%.2f DPS on your best spell", weights.crit1)) end
    if weights.ap14 then add(string.format("+14 attack power: +%.2f auto attack DPS", weights.ap14)) end
    if weights.meleeCrit1 then add(string.format("+1%% melee crit: +%.2f auto attack DPS", weights.meleeCrit1)) end
    if weights.hit1 then add(string.format("+1%% hit: +%.2f auto attack DPS", weights.hit1)) end
    add(" ")
    add("|cff999999Estimates with 2004-era rules. Use /fg export for the web simulator and race comparison.|r")
    return table.concat(lines, "\n")
end

function UI:ShowSim()
    local s, err = FG.Sim:Snapshot()
    if not s then FG:Print(err) return end
    FG.db.snapshots.last = s

    if not self.sim then
        local f = makeWindow("Forever Guide Simulator", 560, 460)
        local text = CreateFrame("Frame", nil, f.scroll)
        text:SetSize(500, 10)
        local fs = text:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("TOPLEFT")
        fs:SetWidth(500)
        fs:SetJustifyH("LEFT")
        f.scroll:SetScrollChild(text)
        f.fs, f.child = fs, text
        self.sim = f
    end
    self.sim.fs:SetText(self:SimText(s))
    self.sim.child:SetHeight(self.sim.fs:GetStringHeight() + 10)
    self.sim:Show()
end

function UI:ShowExport()
    local s, err = FG.Sim:Snapshot()
    if not s then FG:Print(err) return end
    FG.db.snapshots.last = s

    if not self.export then
        local f = makeWindow("Forever Guide Export", 520, 260)
        local edit = CreateFrame("EditBox", nil, f.scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(460)
        edit:SetAutoFocus(false)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        f.scroll:SetScrollChild(edit)
        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("BOTTOM", 0, 8)
        hint:SetText("Ctrl+C to copy, then paste into the web simulator.")
        f.edit = edit
        self.export = f
    end
    self.export:Show()
    self.export.edit:SetText(FG.Sim:Export(s))
    self.export.edit:SetFocus()
    self.export.edit:HighlightText()
end

-- "Read aloud" button on the NPC quest window.
local function addQuestButton()
    if not QuestFrame or UI.questButton then return end
    local b = CreateFrame("Button", nil, QuestFrame, "UIPanelButtonTemplate")
    b:SetSize(90, 22)
    b:SetText("Read aloud")
    b:SetPoint("TOPRIGHT", QuestFrame, "TOPRIGHT", -30, -30)
    b:SetScript("OnClick", function()
        if QuestFrameDetailPanel and QuestFrameDetailPanel:IsShown() then
            FG.Narrator:Speak("detail", (GetTitleText() or "") .. ". " .. (GetQuestText() or "") .. " " .. (GetObjectiveText() or ""))
        elseif QuestFrameProgressPanel and QuestFrameProgressPanel:IsShown() then
            FG.Narrator:Speak("progress", GetProgressText())
        elseif QuestFrameRewardPanel and QuestFrameRewardPanel:IsShown() then
            FG.Narrator:Speak("complete", GetRewardText())
        elseif QuestFrameGreetingPanel and QuestFrameGreetingPanel:IsShown() then
            FG.Narrator:Speak("greeting", GetGreetingText())
        end
    end)
    UI.questButton = b
end

FG:On("PLAYER_LOGIN", addQuestButton)
