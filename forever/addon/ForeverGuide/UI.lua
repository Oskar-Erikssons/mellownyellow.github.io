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

-- Shared with Bags.lua and Market.lua.
UI.MakeWindow, UI.Button = makeWindow, button

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

-- Generic window with text you can copy (talent export).
function UI:ShowCopy(title, text)
    self.copies = self.copies or {}
    local f = self.copies[title]
    if not f then
        f = makeWindow(title, 520, 220)
        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 14, -40)
        scroll:SetPoint("BOTTOMRIGHT", -32, 14)
        f.edit = CreateFrame("EditBox", nil, scroll)
        f.edit:SetMultiLine(true)
        f.edit:SetFontObject(ChatFontNormal)
        f.edit:SetWidth(460)
        f.edit:SetAutoFocus(false)
        f.edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(f.edit)
        self.copies[title] = f
    end
    f:Show()
    f.edit:SetText(text)
    f.edit:SetFocus()
    f.edit:HighlightText()
end

function UI:ShowRoute()
    if not self.route then
        self.route = makeWindow("Forever Guide Route", 480, 400)
        addScrollText(self.route)
    end
    self.route:SetBody(FG.Route:Text())
    self.route:Show()
end

------------------------------------------------------------------------
-- Options: theme, colors and switches
------------------------------------------------------------------------

-- Each switch has a help text, shown when you hover it.
local SWITCHES = {
    { "autoRead", "Read quest text automatically", "Reads quest text aloud as soon as an NPC shows it." },
    { "readGossip", "Also read NPC gossip", "Reads what NPCs say when you talk to them, not only quests." },
    { "voiceVariety", "Different built-in voice per NPC", "Each NPC keeps its own voice and speed, picked from the voices on your computer." },
    { "stripEmotes", "Skip emotes like <The dwarf laughs.>", "Leaves out stage directions in angle brackets when reading." },
    { "tooltip", "AH and vendor prices in tooltips", "Market value, sale chance and whether to sell on the AH or to a vendor." },
    { "tooltipOwned", "What your characters own, in tooltips", "How many of the item each of your characters has, in bags, bank or worn." },
    { "tooltipUpgrade", "Upgrade or downgrade in tooltips", "The item's DPS change against what you wear, from your own stat weights." },
    { "sellJunk", "Merchant button sells grey items", "One click at a merchant sells all grey items." },
    { "sellAdvised", "Merchant button also sells trade goods worth more at a vendor", "Only trade goods and miscellaneous items the advice says to vendor." },
    { "replaceBags", "Use Forever Bags instead of the game's bags", "One window with sell advice, upgrades, value and your other characters' items." },
    { "bagBadges", "Sell advice on bag slots", "AH, V (vendor) or junk in the corner of each slot." },
    { "smartQueue", "Smart spell queue", "Keeps the Spell Queue Window matched to your latency and class, out of combat." },
}

function UI:ShowOptions()
    if self.options then self.options:Show() return end
    local f = makeWindow("Forever Guide Options", 460, 690)
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
        cb:SetScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
            GameTooltip:SetText(sw[2], 1, 1, 1)
            GameTooltip:AddLine(sw[3], nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
        y = y - 28
    end
    local privacy = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    privacy:SetPoint("BOTTOMLEFT", 16, 14)
    privacy:SetPoint("BOTTOMRIGHT", -16, 14)
    privacy:SetJustifyH("LEFT")
    privacy:SetText(FG.PRIVACY)
    T:Register(privacy, function(l, th) l:SetTextColor(th:Get("muted")) end)
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
        local scan = button(f, "Full scan", 100, function() FG.Auction:FullScan() end)
        scan:SetPoint("BOTTOMLEFT", 14, 12)
        local quick = button(f, "Quick scan", 100, function() FG.Auction:QuickScan() end)
        quick:SetPoint("LEFT", scan, "RIGHT", 8, 0)
        local refresh = button(f, "Refresh", 90, function() UI:RefreshAuction() end)
        refresh:SetPoint("LEFT", quick, "RIGHT", 8, 0)
        local opts = button(f, "Options", 100, function() UI:ShowOptions() end)
        opts:SetPoint("LEFT", refresh, "RIGHT", 8, 0)
        self.auction = f
    end
    self:RefreshAuction()
    self.auction:Show()
end

------------------------------------------------------------------------
-- Inventory across characters
------------------------------------------------------------------------

function UI:InventoryText(search)
    local Inv, T, A = FG.Inventory, FG.Theme, FG.Auction
    local lines = {}
    local function add(t) table.insert(lines, t) end
    if search and search ~= "" then
        add(T:Color("title", "Search: " .. search))
        local hits = Inv:Find(search)
        for i, h in ipairs(hits) do
            if i > 20 then break end
            add(string.format("%s  x%d", h.name, h.total))
            for _, r in ipairs(h.rows) do add("    " .. r.key .. ": " .. r.where) end
        end
        if #hits == 0 then add(T:Color("muted", "Nothing found. Open each character's bags and bank once so they are saved.")) end
        return table.concat(lines, "\n")
    end
    local rows, total = Inv:Summary()
    add(T:Color("title", "All characters: " .. A.Money(total)))
    add(T:Color("muted", "Gold plus items at what you would get for them (AH or vendor, whichever is better)."))
    add(" ")
    for _, r in ipairs(rows) do
        local c = r.c
        add(string.format("%s  %s", T:Color("accent", r.key), A.Money(r.worth)))
        add(string.format("    level %s %s · gold %s · items %s%s", c.level or "?", (c.class or ""):lower(),
            A.Money(c.money or 0), A.Money(r.items), c.bank and "" or T:Color("muted", " · bank not seen yet")))
    end
    add(" ")
    add(T:Color("muted", "Search with /fg find <name>. " .. FG.PRIVACY))
    return table.concat(lines, "\n")
end

function UI:ShowInventory(search)
    if not self.inventory then
        self.inventory = makeWindow("Forever Guide Inventory", 540, 460)
        addScrollText(self.inventory)
    end
    FG.Inventory:SaveBags()
    self.inventory:SetBody(self:InventoryText(search))
    self.inventory:Show()
end

function UI:ShowAtlas()
    if not self.atlas then
        self.atlas = makeWindow("Forever Guide Atlas", 560, 440)
        addScrollText(self.atlas)
    end
    self.atlas:SetBody(FG.Atlas:Text())
    self.atlas:Show()
end

function UI:ShowProfessions()
    if not self.professions then
        self.professions = makeWindow("Forever Guide Professions", 460, 420)
        addScrollText(self.professions)
    end
    self.professions:SetBody(FG.Professions:Text())
    self.professions:Show()
end

function UI:RefreshAuction()
    if self.auction then self.auction:SetBody(self:AuctionText()) end
end

-- Small panel on the AH frame with the scan button.
function UI:AttachAuction()
    -- The modern auction house gets the full Forever Market panel.
    if AuctionHouseFrame and FG.Market then return FG.Market:Attach() end
    local host = AuctionFrame
    if not host or self.ahPanel then return end
    local p = CreateFrame("Frame", nil, host, "BackdropTemplate")
    p:SetSize(200, 70)
    p:SetPoint("TOPLEFT", host, "TOPRIGHT", 4, 0)
    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.title:SetPoint("TOP", 0, -8)
    p.title:SetText("Forever Guide")
    FG.Theme:Register(p, function(frame, T) T:SkinWindow(frame) end)
    p:SetHeight(96)
    local scan = button(p, "Full scan", 90, function() FG.Auction:FullScan() end)
    scan:SetPoint("BOTTOMLEFT", 8, 36)
    local quick = button(p, "Quick scan", 90, function() FG.Auction:QuickScan() end)
    quick:SetPoint("BOTTOMRIGHT", -8, 36)
    local open = button(p, "Advice", 184, function() UI:ShowAuction() end)
    open:SetPoint("BOTTOM", 0, 10)
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
