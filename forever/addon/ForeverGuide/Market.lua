-- Forever Guide: Forever Market. Sell, cancel and buy at the auction house with one button.
--   Sell:   your bags' AH items in order of value; each click posts the next one at a price that
--           undercuts the cheapest other seller, but never below a floor from your market history.
--           When others dump below that floor, Market tells you to wait or vendor instead.
--   Cancel: finds your auctions that someone undercut; each click cancels the next.
--   Flips:  auctions below the vendor price; check, buy, confirm, then vend them for a sure profit.
-- The game requires one click per post, cancel and purchase, so nothing happens without you.
local _, FG = ...
local Market = {}
FG.Market = Market

------------------------------------------------------------------------
-- Pure helpers (covered by tests)
------------------------------------------------------------------------

-- The cheapest unit price among other sellers. results: { { unit, quantity, own } } in price order.
function Market.LowestOther(results)
    for _, r in ipairs(results or {}) do
        if not r.own and r.unit and r.unit > 0 then return r.unit end
    end
end

-- Price for one unit. Returns price, reason and whether posting is advised.
-- reason: "under" (just below the cheapest), "market" (no competition), "dumped" (others sell below
-- your floor), "guess" (no price data at all) or "nodata".
function Market.PickPrice(lowest, market, vendor, opt)
    opt = opt or {}
    vendor = vendor or 0
    local floor = math.max(1, math.floor(vendor * (opt.vendorMargin or 1.1) + 0.5),
        market and math.floor(market * (opt.floorShare or 0.7)) or 0)
    if lowest then
        local p = lowest - (opt.undercut or 1)
        if p >= floor then return p, "under", true end
        return floor, "dumped", false
    end
    if market then return math.max(market, floor), "market", true end
    if vendor > 0 then return math.max(floor, vendor * 3), "guess", true end
    return nil, "nodata", false
end

-- Forever's auction lengths (2, 8 and 24 hours) as the API's duration index.
function Market.DurationIndex(hours)
    return ({ ["2"] = 1, ["8"] = 2, ["24"] = 3 })[tostring(hours)] or 3
end

-- Waiting list for auction house queries: the server only takes one at a time.
-- A query the server drops never answers, so the list moves on after `timeout` seconds.
function Market.NewQueue(isReady, now, timeout)
    local q = { items = {}, busy = false, since = 0 }
    timeout = timeout or 5
    function q:Push(fn) table.insert(self.items, fn) self:Pump() end
    function q:Done() self.busy = false self:Pump() end
    function q:Pump()
        if self.busy and now() - self.since > timeout then self.busy = false end
        if self.busy or #self.items == 0 or not isReady() then return end
        self.busy, self.since = true, now()
        table.remove(self.items, 1)()
    end
    return q
end

------------------------------------------------------------------------
-- Searching
------------------------------------------------------------------------

local function ready()
    return not (C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady) or C_AuctionHouse.IsThrottledMessageSystemReady()
end

local function clock() return GetTime() end
Market.queue = Market.NewQueue(ready, clock)
Market.waiting = {}

local function priceSort()
    local order = Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
    return { { sortOrder = order, reverseSort = false } }
end

-- Looks up the current listings of one item and calls done(results, isCommodity).
function Market:Search(itemKey, isCommodity, done)
    local key = (isCommodity and "c" or "i") .. itemKey.itemID
    self.waiting[key] = function(results) done(results, isCommodity) end
    self.queue:Push(function() C_AuctionHouse.SendSearchQuery(itemKey, priceSort(), true) end)
end

local function commodityResults(itemID)
    local out = {}
    for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if r then table.insert(out, { unit = r.unitPrice, quantity = r.quantity, own = r.containsOwnerItem }) end
    end
    return out
end

local function itemResults(itemKey)
    local out = {}
    for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
        local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if r and r.buyoutAmount then
            table.insert(out, { unit = math.floor(r.buyoutAmount / math.max(1, r.quantity or 1)), quantity = r.quantity,
                own = r.containsOwnerItem, auctionID = r.auctionID, buyout = r.buyoutAmount })
        end
    end
    return out
end

-- Only answers to our own searches release the queue; the game's own searches use the same events.
local function deliver(key, results)
    local cb = Market.waiting[key]
    if not cb then return end
    Market.waiting[key] = nil
    Market.queue:Done()
    cb(results)
end

FG:On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID) deliver("c" .. itemID, commodityResults(itemID)) end)
FG:On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey) deliver("i" .. itemKey.itemID, itemResults(itemKey)) end)
FG:On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() Market.queue:Pump() end)
FG:On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function() Market.queue:Done() end)

------------------------------------------------------------------------
-- Sell
------------------------------------------------------------------------

local function options()
    local s = FG.settings
    return { undercut = s.marketUndercut, floorShare = s.marketFloor, vendorMargin = 1.1 }
end

-- Bag items worth selling on the AH, most valuable first. Commodities are posted all at once.
function Market:BuildSellList()
    local list, seen = {}, {}
    for _, r in ipairs(FG.Auction:BagReport()) do
        if r.advice.action == "ah" and r.bag and not seen[r.itemID] then
            local loc = ItemLocation:CreateFromBagAndSlot(r.bag, r.slot)
            if C_Item.DoesItemExist(loc) and C_AuctionHouse.IsSellItemValid(loc, false) then
                local commodity = C_AuctionHouse.GetItemCommodityStatus(loc) == Enum.ItemCommodityStatus.Commodity
                if commodity then seen[r.itemID] = true end
                table.insert(list, { itemID = r.itemID, link = r.link, loc = loc, commodity = commodity,
                    count = commodity and C_Item.GetItemCount(r.itemID) or r.count })
            end
        end
    end
    self.sell = list
    self:PrepareSell()
end

-- Looks up the live price of the first item in the list and works out the post.
function Market:PrepareSell()
    local row = self.sell and self.sell[1]
    self:Redraw()
    if not row or row.price or row.searching then return end
    row.searching = true
    local itemKey = C_AuctionHouse.GetItemKeyFromItem(row.loc)
    self:Search(itemKey, row.commodity, function(results)
        row.searching = false
        local e = FG.Auction:Price(row.itemID) or {}
        local _, _, _, _, _, _, _, _, _, _, vendor = (C_Item.GetItemInfo or GetItemInfo)(row.itemID)
        row.lowest = Market.LowestOther(results)
        row.price, row.reason, row.ok = Market.PickPrice(row.lowest, e.m, vendor, options())
        local dur = Market.DurationIndex(FG.settings.duration)
        row.deposit = row.commodity and C_AuctionHouse.CalculateCommodityDeposit(row.itemID, dur, row.count)
            or C_AuctionHouse.CalculateItemDeposit(row.loc, dur, row.count) or 0
        self:Redraw()
    end)
end

-- Click: post the prepared item.
function Market:PostNext()
    local row = self.sell and self.sell[1]
    if not (row and row.price) then return end
    if not C_Item.DoesItemExist(row.loc) then table.remove(self.sell, 1) return self:PrepareSell() end
    local dur = Market.DurationIndex(FG.settings.duration)
    if row.commodity then
        C_AuctionHouse.PostCommodity(row.loc, dur, row.count, row.price)
    else
        C_AuctionHouse.PostItem(row.loc, dur, row.count, nil, row.price * row.count)
    end
    table.remove(self.sell, 1)
    self:PrepareSell()
end

function Market:SkipSell()
    if self.sell and #self.sell > 0 then table.remove(self.sell, 1) end
    self:PrepareSell()
end

------------------------------------------------------------------------
-- Cancel undercut auctions
------------------------------------------------------------------------

function Market:ScanOwned()
    self.undercut, self.checking = {}, 0
    self:Redraw()
    self.queue:Push(function()
        Market.ownedPending = true
        C_AuctionHouse.QueryOwnedAuctions({})
    end)
end

FG:On("OWNED_AUCTIONS_UPDATED", function()
    if not Market.ownedPending then return end
    Market.ownedPending = false
    Market.queue:Done()
    local active = Enum.AuctionStatus and Enum.AuctionStatus.Active or 0
    for i = 1, C_AuctionHouse.GetNumOwnedAuctions() do
        local a = C_AuctionHouse.GetOwnedAuctionInfo(i)
        if a and a.status == active and a.buyoutAmount and a.itemKey then
            local info = C_AuctionHouse.GetItemKeyInfo(a.itemKey)
            local commodity = info and info.isCommodity
            -- Commodity auctions report a unit price; item auctions the whole buyout.
            local unit = commodity and a.buyoutAmount or math.floor(a.buyoutAmount / math.max(1, a.quantity or 1))
            Market.checking = Market.checking + 1
            Market:Search(a.itemKey, commodity, function(results)
                Market.checking = Market.checking - 1
                local lowest = Market.LowestOther(results)
                if lowest and lowest < unit then
                    table.insert(Market.undercut, { auctionID = a.auctionID, itemID = a.itemKey.itemID, mine = unit, lowest = lowest })
                end
                Market:Redraw()
            end)
        end
    end
    Market:Redraw()
end)

-- Click: cancel the next undercut auction.
function Market:CancelNext()
    local a = self.undercut and table.remove(self.undercut, 1)
    if a then C_AuctionHouse.CancelAuction(a.auctionID) end
    self:Redraw()
end

------------------------------------------------------------------------
-- Vendor flips
------------------------------------------------------------------------

function Market:CheckFlip()
    local flip = FG.Auction:VendorFlips(1)[1]
    if not flip then self.flip = nil return self:Redraw() end
    self.flip = { itemID = flip.itemID, name = flip.name, vendor = flip.vendor, stage = "checking" }
    self:Redraw()
    local itemKey = C_AuctionHouse.MakeItemKey(flip.itemID)
    local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
    self:Search(itemKey, info and info.isCommodity, function(results, commodity)
        local f = self.flip
        if not f then return end
        f.commodity, f.qty, f.cost = commodity, 0, 0
        for _, r in ipairs(results) do
            if r.own or r.unit >= f.vendor then break end
            if commodity then
                f.qty, f.cost = f.qty + r.quantity, f.cost + r.quantity * r.unit
            elseif not f.auctionID then
                f.auctionID, f.qty, f.cost = r.auctionID, r.quantity or 1, r.buyout
            end
        end
        f.profit = f.qty * f.vendor - f.cost
        f.stage = f.qty > 0 and "found" or "gone"
        self:Redraw()
    end)
end

-- Click: buy. Commodities need a second click to confirm the final price.
function Market:BuyFlip()
    local f = self.flip
    if not f then return end
    if f.stage == "found" and f.commodity then
        f.stage = "pricing"
        C_AuctionHouse.StartCommoditiesPurchase(f.itemID, f.qty)
    elseif f.stage == "found" then
        C_AuctionHouse.PlaceBid(f.auctionID, f.cost)
        self.flip = nil
    elseif f.stage == "confirm" then
        C_AuctionHouse.ConfirmCommoditiesPurchase(f.itemID, f.qty)
        self.flip = nil
    end
    self:Redraw()
end

FG:On("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
    local f = Market.flip
    if not (f and f.stage == "pricing") then return end
    f.cost, f.profit = totalPrice, f.qty * f.vendor - totalPrice
    -- The price can change between check and purchase; only confirm if it still pays.
    f.stage = f.profit > 0 and "confirm" or "gone"
    if f.stage == "gone" then C_AuctionHouse.CancelCommoditiesPurchase() end
    Market:Redraw()
end)

------------------------------------------------------------------------
-- Panel
------------------------------------------------------------------------

local REASONS = {
    under = "1 copper under the cheapest seller",
    market = "No other sellers: your market price",
    dumped = "Others sell below your floor. Wait, or vendor it.",
    guess = "No price data yet: three times the vendor price",
}

function Market:Attach()
    local host = AuctionHouseFrame
    if not host or self.panel then
        if self.panel then self.panel:Show() self:SetTab(self.tab or "sell") end
        return
    end
    local p = CreateFrame("Frame", nil, host, "BackdropTemplate")
    p:SetPoint("TOPLEFT", host, "TOPRIGHT", 4, 0)
    p:SetPoint("BOTTOMLEFT", host, "BOTTOMRIGHT", 4, 0)
    p:SetWidth(300)
    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.title:SetPoint("TOPLEFT", 12, -10)
    p.title:SetText("Forever Market")
    p.headerBar = p:CreateTexture(nil, "ARTWORK")
    p.headerBar:SetPoint("TOPLEFT", 1, -1)
    p.headerBar:SetPoint("TOPRIGHT", -1, -1)
    p.headerBar:SetHeight(30)
    FG.Theme:Register(p, function(frame, T) T:SkinWindow(frame) end)

    local x = 10
    for _, tab in ipairs({ { "sell", "Sell" }, { "cancel", "Cancel" }, { "flips", "Flips" }, { "scan", "Scan" } }) do
        local b = FG.UI.Button(p, tab[2], 68, function() Market:SetTab(tab[1]) end)
        b:SetPoint("TOPLEFT", x, -38)
        x = x + 70
    end

    p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.text:SetPoint("TOPLEFT", 12, -70)
    p.text:SetPoint("BOTTOMRIGHT", -12, 80)
    p.text:SetJustifyH("LEFT")
    p.text:SetJustifyV("TOP")
    p.text:SetSpacing(3)
    FG.Theme:Register(p.text, function(fs, T) fs:SetTextColor(T:Get("text")) end)

    p.main = FG.UI.Button(p, "", 276, function() Market:Main() end)
    p.main:SetHeight(32)
    p.main:SetPoint("BOTTOM", 0, 44)
    p.second = FG.UI.Button(p, "", 276, function() Market:Second() end)
    p.second:SetPoint("BOTTOM", 0, 14)
    self.panel = p
    self:SetTab("sell")
end

function Market:SetTab(tab)
    self.tab = tab
    if tab == "sell" then self:BuildSellList()
    elseif tab == "cancel" then self:ScanOwned()
    elseif tab == "flips" then self:CheckFlip()
    else self:Redraw() end
end

function Market:Main()
    if self.tab == "sell" then self:PostNext()
    elseif self.tab == "cancel" then self:CancelNext()
    elseif self.tab == "flips" then self:BuyFlip()
    else FG.Auction:FullScan() end
end

function Market:Second()
    if self.tab == "sell" then self:SkipSell()
    elseif self.tab == "cancel" then self:ScanOwned()
    elseif self.tab == "flips" then self:CheckFlip()
    else FG.Auction:QuickScan() end
end

local function itemName(itemID, link)
    return link or (C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or FG.db.itemNames[itemID] or ("item " .. itemID)
end

function Market:Redraw()
    local p = self.panel
    if not (p and p:IsShown()) then return end
    local T, M = FG.Theme, FG.Auction.Money
    local lines = {}
    local function add(t) table.insert(lines, t) end
    local main, second, canMain = "", "", false

    if self.tab == "sell" then
        local row = self.sell and self.sell[1]
        add(T:Color("accent", string.format("%d items to sell on the AH", self.sell and #self.sell or 0)))
        if row then
            add(" ")
            add(string.format("%s x%d", itemName(row.itemID, row.link), row.count))
            if row.price then
                add(string.format("Price %s each, %s in total", M(row.price), M(row.price * row.count)))
                add(T:Color(row.ok and "good" or "bad", REASONS[row.reason] or ""))
                if row.lowest then add(T:Color("muted", "Cheapest other seller: " .. M(row.lowest))) end
                add(T:Color("muted", "Deposit: " .. M(row.deposit or 0)))
                main, canMain = row.ok and "Post" or "Post anyway", true
            else
                add(T:Color("muted", "Checking the current price..."))
                main = "Checking..."
            end
            for i = 2, math.min(#self.sell, 7) do add(T:Color("muted", "  next: " .. itemName(self.sell[i].itemID, self.sell[i].link))) end
            second = "Skip"
        else
            add(T:Color("muted", "Nothing in your bags is worth more on the AH right now."))
        end
    elseif self.tab == "cancel" then
        local n = self.undercut and #self.undercut or 0
        add(T:Color("accent", string.format("%d of your auctions are undercut", n)))
        if (self.checking or 0) > 0 then add(T:Color("muted", string.format("Checking %d more...", self.checking))) end
        for i = 1, math.min(n, 10) do
            local a = self.undercut[i]
            add(string.format("%s: yours %s, cheapest %s", itemName(a.itemID), M(a.mine), M(a.lowest)))
        end
        main, canMain, second = n > 0 and "Cancel next" or "Nothing to cancel", n > 0, "Check again"
    elseif self.tab == "flips" then
        local f = self.flip
        add(T:Color("accent", "Buy below the vendor price, sell to a vendor"))
        if not f then
            add(T:Color("muted", "No flips known. Run a scan first."))
        elseif f.stage == "checking" or f.stage == "pricing" then
            add(T:Color("muted", "Checking " .. itemName(f.itemID) .. "..."))
        elseif f.stage == "gone" then
            add(T:Color("muted", "That deal is gone. Check the next one."))
        else
            add(string.format("%s x%d for %s", itemName(f.itemID), f.qty, M(f.cost)))
            add(T:Color("good", "Vendor pays " .. M(f.qty * f.vendor) .. ", profit " .. M(f.profit)))
            main, canMain = f.stage == "confirm" and ("Confirm " .. M(f.cost)) or "Buy", true
        end
        second = "Check next"
    else
        local a = FG.Auction:DB()
        add(T:Color("accent", "Prices"))
        add("Last full scan: " .. (a.lastFull and date("%H:%M", a.lastFull) or "never"))
        add("Last quick scan: " .. (a.lastQuick and date("%H:%M", a.lastQuick) or "never"))
        add(T:Color("muted", "A full scan gives sale chances and is allowed every 15 minutes. A quick scan gives lowest prices any time."))
        main, canMain, second = "Full scan", true, "Quick scan"
    end
    p.text:SetText(table.concat(lines, "\n"))
    p.main:SetText(main)
    p.main:SetEnabled(canMain)
    p.second:SetText(second)
    p.second:SetShown(second ~= "")
end

FG:On("AUCTION_HOUSE_AUCTION_CREATED", function() Market:Redraw() end)
FG:On("AUCTION_CANCELED", function() Market:Redraw() end)
FG:On("AUCTION_HOUSE_CLOSED", function()
    Market.queue = Market.NewQueue(ready, clock)
    Market.waiting, Market.flip, Market.ownedPending = {}, nil, false
end)
