-- Forever Guide: windows (simulator, export, options, auction house), merchant and AH panels,
-- and a "Read aloud" button on the quest frame. All windows follow the selected theme.
local _, FG = ...
local UI = {}
FG.UI = UI

local function money(c) return FG.Auction.Money(c) end

------------------------------------------------------------------------
-- Building blocks
------------------------------------------------------------------------

local function makeWindow(title, width, height)
    local name = "ForeverGuide" .. title:gsub("%W", "")
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, name) -- Escape closes the window

    f.headerBar = f:CreateTexture(nil, "ARTWORK")
    f.headerBar:SetPoint("TOPLEFT", 1, -1)
    f.headerBar:SetPoint("TOPRIGHT", -1, -1)
    f.headerBar:SetHeight(30)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 12, -8)
    f.title:SetText(title)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    FG.Theme:Register(f, function(frame, T) T:SkinWindow(frame) end)
    return f
end

-- A scrolling text area that follows the theme's text color.
local function addScrollText(f, top, bottom)
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, top or -40)
    scroll:SetPoint("BOTTOMRIGHT", -32, bottom or 14)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(f:GetWidth() - 60, 10)
    local fs = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("TOPLEFT")
    fs:SetWidth(f:GetWidth() - 60)
    fs:SetJustifyH("LEFT")
    fs:SetSpacing(2)
    scroll:SetScrollChild(child)
    FG.Theme:Register(fs, function(text, T) text:SetTextColor(T:Get("text")) end)
    function f:SetBody(text)
        fs:SetText(text)
        child:SetHeight(fs:GetStringHeight() + 10)
    end
    return scroll
end

local function button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 120, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function heading(T, text) return T:Color("accent", text) end

------------------------------------------------------------------------
-- Simulator
------------------------------------------------------------------------

local function fmt(v, d)
    if v == nil then return "?" end
    return string.format("%." .. (d or 0) .. "f", v)
end

function UI:SimText(s)
    local T = FG.Theme
    local lines = {}
    local function add(t) table.insert(lines, t) end
    add(T:Color("title", string.format("%s %s, level %d", s.raceName or "?", s.className or "?", s.level or 0)))
    add(string.format("Str %s  Agi %s  Sta %s  Int %s  Spi %s", fmt(s.str), fmt(s.agi), fmt(s.sta), fmt(s.int), fmt(s.spi)))
    add(string.format("Health %s  Mana %s  AP %s  Spell power %s  Healing %s", fmt(s.hp), fmt(s.mana), fmt(s.ap), fmt(s.sp), fmt(s.healing)))
    add(string.format("Melee crit %s%%  Spell crit %s%%  Hit +%s%%  Spell hit +%s%%", fmt(s.crit, 2), fmt(s.spellCrit, 2), fmt(s.hit), fmt(s.spellHit)))
    add(string.format("Target: %d level(s) above you (change with /fg target)", FG.settings.targetLevelDiff or 0))
    add(" ")

    local results, melee, weights = FG.Sim:Run(s)
    if melee > 0 then
        add(heading(T, "Auto attack: ") .. string.format("%.1f DPS", melee))
    end
    if #results > 0 then
        add(heading(T, "Spells, best per second first:"))
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
    add(heading(T, "What helps you most right now:"))
    local function gain(label, v) if v then add(label .. ": " .. T:Color("good", string.format("+%.2f DPS", v))) end end
    gain("+10 spell power (best spell)", weights.sp10)
    gain("+1% spell crit (best spell)", weights.crit1)
    gain("+14 attack power (auto attack)", weights.ap14)
    gain("+1% melee crit (auto attack)", weights.meleeCrit1)
    gain("+1% hit (auto attack)", weights.hit1)
    add(" ")
    add(T:Color("muted", "Estimates with 2004-era rules. Use /fg export for the web simulator and race comparison."))
    return table.concat(lines, "\n")
end

function UI:ShowSim()
    local s, err = FG.Sim:Snapshot()
    if not s then FG:Print(err) return end
    FG.db.snapshots.last = s
    if not self.sim then
        self.sim = makeWindow("Forever Guide Simulator", 580, 480)
        addScrollText(self.sim)
    end
    self.sim:SetBody(self:SimText(s))
    self.sim:Show()
end

------------------------------------------------------------------------
-- Export
------------------------------------------------------------------------

function UI:ShowExport()
    local s, err = FG.Sim:Snapshot()
    if not s then FG:Print(err) return end
    FG.db.snapshots.last = s
    if not self.export then
        local f = makeWindow("Forever Guide Export", 520, 260)
        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 14, -40)
        scroll:SetPoint("BOTTOMRIGHT", -32, 30)
        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(460)
        edit:SetAutoFocus(false)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)
        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("BOTTOM", 0, 10)
        hint:SetText("Ctrl+C to copy, then paste into the web simulator.")
        FG.Theme:Register(hint, function(h, T) h:SetTextColor(T:Get("muted")) end)
        f.edit = edit
        self.export = f
    end
    self.export:Show()
    self.export.edit:SetText(FG.Sim:Export(s))
    self.export.edit:SetFocus()
    self.export.edit:HighlightText()
end

------------------------------------------------------------------------
-- Options: theme, colors and switches
------------------------------------------------------------------------

local SWITCHES = {
    { "autoRead", "Read quest text automatically" },
    { "readGossip", "Also read NPC gossip" },
    { "voiceVariety", "Different built-in voice per NPC" },
    { "stripEmotes", "Skip emotes like <The dwarf laughs.>" },
    { "tooltip", "Show AH and vendor prices in tooltips" },
    { "sellJunk", "Merchant button sells grey items" },
    { "sellAdvised", "Merchant button also sells trade goods worth more at a vendor" },
}

function UI:ShowOptions()
    if self.options then self.options:Show() return end
    local f = makeWindow("Forever Guide Options", 460, 520)
    local T = FG.Theme
    local y = -44

    local themeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    themeLabel:SetPoint("TOPLEFT", 16, y)
    themeLabel:SetText("Theme")
    T:Register(themeLabel, function(l, th) l:SetTextColor(th:Get("accent")) end)
    y = y - 22
    local x = 16
    for _, key in ipairs({ "orgrimmar", "stormwind" }) do
        local b = button(f, T.THEMES[key].name, 160, function() T:Set(key) end)
        b:SetPoint("TOPLEFT", x, y)
        x = x + 170
    end
    y = y - 36

    local colorsLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colorsLabel:SetPoint("TOPLEFT", 16, y)
    colorsLabel:SetText("Colors (saved per theme, click to change)")
    T:Register(colorsLabel, function(l, th) l:SetTextColor(th:Get("accent")) end)
    y = y - 24
    for i, key in ipairs(T.KEYS) do
        local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
        local sw = CreateFrame("Button", nil, f, "BackdropTemplate")
        sw:SetSize(18, 18)
        sw:SetPoint("TOPLEFT", 16 + col * 145, y - row * 26)
        sw:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        sw:SetScript("OnClick", function() T:PickColor(key) end)
        local label = sw:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("LEFT", sw, "RIGHT", 6, 0)
        label:SetText(T.LABELS[key])
        T:Register(sw, function(s, th)
            s:SetBackdropColor(th:Get(key))
            s:SetBackdropBorderColor(th:Get("border"))
            label:SetTextColor(th:Get("text"))
        end)
    end
    y = y - math.ceil(#T.KEYS / 3) * 26 - 6
    local reset = button(f, "Reset colors", 140, function() T:Reset() end)
    reset:SetPoint("TOPLEFT", 16, y)
    y = y - 36

    for _, sw in ipairs(SWITCHES) do
        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 12, y)
        cb:SetChecked(FG.settings[sw[1]])
        cb:SetScript("OnClick", function(b) FG.settings[sw[1]] = b:GetChecked() and true or false end)
        local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        label:SetText(sw[2])
        T:Register(label, function(l, th) l:SetTextColor(th:Get("text")) end)
        y = y - 28
    end
    self.options = f
end

------------------------------------------------------------------------
-- Auction house window
------------------------------------------------------------------------

local ACTION = { ah = "AH", vendor = "Vendor", keep = "Keep" }

function UI:AuctionText()
    local A, T = FG.Auction, FG.Theme
    local db = A:DB()
    local items = A:Items()
    local n = 0
    for _ in pairs(items) do n = n + 1 end
    local lines = {}
    local function add(t) table.insert(lines, t) end

    local last = db.lastFull and date("%Y-%m-%d %H:%M", db.lastFull) or "never"
    add(string.format("House: %s · %d items priced · last full scan: %s", A:House(), n, last))
    local sum, count = A:SalesSummary(7)
    if count > 0 then add(string.format("Your sales the last 7 days: %s from %d auctions", T:Color("good", money(sum)), count)) end
    local hour = A:BestHour()
    if hour then add(string.format("Most sales happen around %02d:00, a good time to post.", hour)) end
    add(" ")

    add(heading(T, "Your bags: sell where?"))
    local shown = 0
    for _, r in ipairs(A:BagReport()) do
        local d = r.advice
        if (d.vendorTotal or 0) > 0 or d.ahEV then
            shown = shown + 1
            if shown > 25 then break end
            local value = d.action == "ah" and d.ahEV or d.vendorTotal
            local tag = T:Color(d.action == "ah" and "good" or "muted", ACTION[d.action])
            local extra = d.noPrice and T:Color("muted", " (no AH price yet)") or ""
            add(string.format("%s x%d - %s %s%s", r.link or ("item " .. r.itemID), r.count, tag, money(value or 0), extra))
        end
    end
    if shown == 0 then add(T:Color("muted", "Nothing with a price in your bags.")) end
    add(" ")

    add(heading(T, "Vendor flips: buy on the AH, sell to a vendor"))
    local flips = A:VendorFlips(15)
    for _, x in ipairs(flips) do
        add(string.format("%s - buy %s, vendor pays %s, %s each",
            x.name or ("item " .. x.itemID), money(x.min), money(x.vendor), T:Color("good", "+" .. money(x.profit))))
    end
    if #flips == 0 then add(T:Color("muted", "No flips found. Run a full scan at the auction house.")) end
    add(" ")
    add(T:Color("muted", "Sale chance comes from comparing your full scans. It gets better with every scan."))
    return table.concat(lines, "\n")
end

function UI:ShowAuction()
    if not self.auction then
        local f = makeWindow("Forever Guide Auction House", 620, 520)
        addScrollText(f, -40, 44)
        local scan = button(f, "Full scan", 120, function() FG.Auction:FullScan() end)
        scan:SetPoint("BOTTOMLEFT", 14, 12)
        local refresh = button(f, "Refresh", 100, function() UI:RefreshAuction() end)
        refresh:SetPoint("LEFT", scan, "RIGHT", 8, 0)
        local opts = button(f, "Options", 100, function() UI:ShowOptions() end)
        opts:SetPoint("LEFT", refresh, "RIGHT", 8, 0)
        self.auction = f
    end
    self:RefreshAuction()
    self.auction:Show()
end

function UI:RefreshAuction()
    if self.auction then self.auction:SetBody(self:AuctionText()) end
end

-- Small panel on the AH frame with the scan button.
function UI:AttachAuction()
    local host = AuctionHouseFrame or AuctionFrame
    if not host or self.ahPanel then return end
    local p = CreateFrame("Frame", nil, host, "BackdropTemplate")
    p:SetSize(200, 70)
    p:SetPoint("TOPLEFT", host, "TOPRIGHT", 4, 0)
    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.title:SetPoint("TOP", 0, -8)
    p.title:SetText("Forever Guide")
    FG.Theme:Register(p, function(frame, T) T:SkinWindow(frame) end)
    local scan = button(p, "Full scan", 90, function() FG.Auction:FullScan() end)
    scan:SetPoint("BOTTOMLEFT", 8, 10)
    local open = button(p, "Advice", 90, function() UI:ShowAuction() end)
    open:SetPoint("BOTTOMRIGHT", -8, 10)
    self.ahPanel = p
end

------------------------------------------------------------------------
-- Merchant panel: one click sells junk (and, if you want, advised trade goods)
------------------------------------------------------------------------

function UI:AttachMerchant()
    if not MerchantFrame then return end
    if not self.merchant then
        local p = CreateFrame("Frame", nil, MerchantFrame, "BackdropTemplate")
        p:SetSize(220, 64)
        p:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 4, 0)
        p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        p.text:SetPoint("TOPLEFT", 10, -10)
        p.text:SetWidth(200)
        p.text:SetJustifyH("LEFT")
        FG.Theme:Register(p, function(frame, T)
            T:SkinWindow(frame)
            frame.text:SetTextColor(T:Get("text"))
        end)
        p.sell = button(p, "Sell", 90, function()
            FG.Auction:SellToVendor()
            C_Timer.After(0.5, function() UI:AttachMerchant() end)
        end)
        p.sell:SetPoint("BOTTOMLEFT", 10, 8)
        self.merchant = p
    end
    local list, total = FG.Auction:VendorList()
    self.merchant.text:SetText(#list > 0
        and string.format("Forever Guide: sell %d items for %s", #list, money(total))
        or "Forever Guide: nothing to sell")
    self.merchant.sell:SetEnabled(#list > 0)
end

------------------------------------------------------------------------
-- "Read aloud" button on the NPC quest window
------------------------------------------------------------------------

local function addQuestButton()
    if not QuestFrame or UI.questButton then return end
    local b = button(QuestFrame, "Read aloud", 90, function()
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
    b:SetPoint("TOPRIGHT", QuestFrame, "TOPRIGHT", -30, -30)
    UI.questButton = b
end

FG:On("PLAYER_LOGIN", addQuestButton)
