-- Forever Guide: auction house prices, vendor-or-AH advice, vendor flips and sales history.
-- Forever has no public auction API, so all prices come from your own scans:
--   * a full scan (allowed once per 15 minutes per account)
--   * passive capture of every search you make in the auction house
-- Everything here only reads the AH and acts on your clicks, like other AH addons.
local _, FG = ...
local Auction = {}
FG.Auction = Auction

local NEUTRAL_ZONES = { ["Gadgetzan"] = true, ["Booty Bay"] = true, ["Everlook"] = true }

------------------------------------------------------------------------
-- Pure calculations (no game API, covered by tests)
------------------------------------------------------------------------

-- listings: array of { unit = copper per item, count = n, tl = 1..4 (time left), owner = name }
-- Market value: weighted average of the cheapest 30 % of items, ignoring listings priced far above
-- the 15th percentile. Similar in spirit to TSM's market value, but from your own scans.
function Auction.Aggregate(listings)
    local list, qty = {}, 0
    for _, l in ipairs(listings) do
        if l.unit and l.unit > 0 and l.count and l.count > 0 then
            table.insert(list, l)
            qty = qty + l.count
        end
    end
    if qty == 0 then return nil end
    table.sort(list, function(a, b) return a.unit < b.unit end)

    local function priceAt(share)
        local need, seen = qty * share, 0
        for _, l in ipairs(list) do
            seen = seen + l.count
            if seen >= need then return l.unit end
        end
        return list[#list].unit
    end
    local cap = priceAt(0.15) * 1.5
    local want, sum, used = math.max(1, qty * 0.3), 0, 0
    for _, l in ipairs(list) do
        if used >= want or (used > 0 and l.unit > cap) then break end
        local take = math.min(l.count, want - used)
        sum = sum + l.unit * take
        used = used + take
    end
    return math.floor(sum / used + 0.5), list[1].unit, qty, #list
end

local function signature(l)
    return string.format("%d:%d:%s", l.unit, l.count, l.owner or "")
end

-- Compares two full scans of one item. Listings that vanished while they still had time left
-- were most likely bought. Ones that were about to expire count as half sold.
function Auction.SaleEstimate(prev, cur)
    local still = {}
    for _, l in ipairs(cur) do
        local sig = signature(l)
        still[sig] = (still[sig] or 0) + 1
    end
    local sold, total = 0, 0
    for _, l in ipairs(prev) do
        total = total + 1
        local sig = signature(l)
        if (still[sig] or 0) > 0 then
            still[sig] = still[sig] - 1
        else
            sold = sold + ((l.tl or 4) <= 1 and 0.5 or 1)
        end
    end
    return sold, total
end

-- Mirrors decideSale() in app.js so the game and the web page give the same advice.
-- item: { vendor = copper, market = copper, saleRate = 0..1, count = n, bound = bool }
function Auction.Decide(item, house, duration)
    local A = FG.Data.auction
    house = house or "faction"
    duration = duration or A.defaultDuration
    local count = item.count or 1
    local vendorTotal = (item.vendor or 0) * count
    if item.bound then
        return { action = vendorTotal > 0 and "vendor" or "keep", vendorTotal = vendorTotal }
    end
    if not item.market or item.market <= 0 then
        return { action = vendorTotal > 0 and "vendor" or "keep", vendorTotal = vendorTotal, noPrice = true }
    end
    local sr = item.saleRate or A.defaultSaleRate
    local deposit = (item.vendor or 0) * count * A.deposit[house][duration]
    local net = item.market * count * (1 - A.cut[house])
    -- List up to A.relists times. Each failed listing loses the deposit; if it never sells, vendor it.
    local fail, lost = 1 - sr, 0
    for i = 1, A.relists do lost = lost + fail ^ i end
    local ahEV = (1 - fail ^ A.relists) * net - lost * deposit + fail ^ A.relists * vendorTotal
    local gain = ahEV - vendorTotal
    local needed = math.max(A.minProfitCopper, vendorTotal * A.ahMargin)
    local action
    if gain > needed then action = "ah" elseif vendorTotal > 0 then action = "vendor" else action = "ah" end
    return { action = action, ahEV = ahEV, vendorTotal = vendorTotal, gain = gain, deposit = deposit, net = net, saleRate = sr }
end

function Auction.Money(copper)
    copper = math.floor((copper or 0) + 0.5)
    local neg = copper < 0
    copper = math.abs(copper)
    local g, s, c = math.floor(copper / 10000), math.floor(copper % 10000 / 100), copper % 100
    local out = (g > 0 and (g .. "g ") or "") .. ((g > 0 or s > 0) and (s .. "s ") or "") .. c .. "c"
    return (neg and "-" or "") .. out
end

------------------------------------------------------------------------
-- Price database
------------------------------------------------------------------------

function Auction:DB()
    local db = FG.db
    db.auction = db.auction or {}
    local a = db.auction
    a.houses = a.houses or {}
    a.sales = a.sales or {}
    a.salesSeen = a.salesSeen or {}
    a.soldByHour = a.soldByHour or {}
    return a
end

function Auction:House()
    local s = FG.settings.house
    if s == "faction" or s == "neutral" then return s end
    return NEUTRAL_ZONES[GetMinimapZoneText and GetMinimapZoneText() or ""] and "neutral" or "faction"
end

function Auction:Items(house)
    local a = self:DB()
    house = house or self:House()
    a.houses[house] = a.houses[house] or { items = {}, prev = {} }
    return a.houses[house].items, a.houses[house]
end

function Auction:Price(itemID, house)
    local items = self:Items(house)
    return items[itemID]
end

local function vendorPrice(itemID)
    local get = C_Item and C_Item.GetItemInfo or GetItemInfo
    local name, _, _, _, _, _, _, _, _, _, sell, classID = get(itemID)
    return sell, name, classID
end

-- Stores a fresh price. Historical value is a slow moving average, so one odd scan does not swing it.
function Auction:Record(itemID, market, min, qty, n, now)
    local items = self:Items()
    local e = items[itemID] or {}
    e.m, e.min, e.q, e.n, e.t = market, min, qty, n, now
    e.h = e.h and math.floor(e.h * 0.8 + market * 0.2 + 0.5) or market
    local sell, name = vendorPrice(itemID)
    e.v = sell or e.v
    e.name = name or e.name
    items[itemID] = e
    return e
end

------------------------------------------------------------------------
-- Scanning
------------------------------------------------------------------------

local modern = C_AuctionHouse and C_AuctionHouse.ReplicateItems ~= nil
Auction.scanning = false

function Auction:CanFullScan()
    local a = self:DB()
    local wait = (a.lastFull or 0) + FG.Data.auction.fullScanCooldown - time()
    if wait > 0 then return false, string.format("Next full scan in %d min.", math.ceil(wait / 60)) end
    if not modern and CanSendAuctionQuery then
        local _, canAll = CanSendAuctionQuery()
        if not canAll then return false, "The server does not allow a full scan right now." end
    end
    return true
end

function Auction:FullScan()
    local ok, why = self:CanFullScan()
    if not ok then FG:Print(why) return end
    self.scanning = true
    self.scanStarted = GetTime()
    FG:Print("Full scan started. It can take a minute.")
    if modern then
        C_AuctionHouse.ReplicateItems()
    else
        QueryAuctionItems("", nil, nil, 0, nil, nil, true)
    end
end

-- Reads every listing from the finished full scan.
local function readFullScan()
    local byItem = {}
    local function add(itemID, count, buyout, tl, owner)
        if itemID and count and count > 0 and buyout and buyout > 0 then
            byItem[itemID] = byItem[itemID] or {}
            table.insert(byItem[itemID], { unit = math.floor(buyout / count), count = count, tl = tl, owner = FG.Safe(owner) })
        end
    end
    local total = 0
    if modern then
        total = C_AuctionHouse.GetNumReplicateItems()
        for i = 0, total - 1 do
            local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
            local tl = C_AuctionHouse.GetReplicateItemTimeLeft and C_AuctionHouse.GetReplicateItemTimeLeft(i)
            add(itemID, count, buyout, tl and tl + 1, owner)
        end
    else
        total = GetNumAuctionItems("list")
        for i = 1, total do
            local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID = GetAuctionItemInfo("list", i)
            add(itemID, count, buyout, GetAuctionItemTimeLeft("list", i), owner)
        end
    end
    return byItem, total
end

local function packListings(list)
    local parts = {}
    for _, l in ipairs(list) do parts[#parts + 1] = string.format("%d:%d:%d:%s", l.unit, l.count, l.tl or 4, l.owner or "") end
    return table.concat(parts, ";")
end

function Auction.UnpackListings(s)
    local list = {}
    for unit, count, tl, owner in (s or ""):gmatch("(%d+):(%d+):(%d+):([^;]*)") do
        list[#list + 1] = { unit = tonumber(unit), count = tonumber(count), tl = tonumber(tl), owner = owner ~= "" and owner or nil }
    end
    return list
end

function Auction:FinishFullScan()
    self.scanning = false
    local byItem, total = readFullScan()
    if total == 0 then
        -- Forever answers a throttled scan with an empty market instead of an error. Keep the old data.
        FG:Print("The scan came back empty, most likely throttled by the server. Your saved prices are kept. Try again in 15 minutes.")
        return
    end
    local now = time()
    local a = self:DB()
    local _, house = self:Items()
    local hour = tonumber(date("%H", now))
    local items, soldTotal = 0, 0
    for itemID, list in pairs(byItem) do
        local market, min, qty, n = Auction.Aggregate(list)
        if market then
            local e = self:Record(itemID, market, min, qty, n, now)
            local prev = house.prev[itemID]
            if prev then
                local sold, seen = Auction.SaleEstimate(Auction.UnpackListings(prev), list)
                if seen > 0 then
                    e.srN = (e.srN or 0) + seen
                    e.srS = (e.srS or 0) + sold
                    e.sr = e.srS / e.srN
                    soldTotal = soldTotal + sold
                end
            end
            house.prev[itemID] = packListings(list)
            items = items + 1
        end
    end
    -- Items that vanished completely were sold out (or cancelled).
    for itemID, prev in pairs(house.prev) do
        if not byItem[itemID] then
            local list = Auction.UnpackListings(prev)
            local e = self:Items()[itemID]
            if e and #list > 0 then
                e.srN, e.srS = (e.srN or 0) + #list, (e.srS or 0) + #list * 0.75
                e.sr = e.srS / e.srN
                e.q, e.n = 0, 0
            end
            house.prev[itemID] = nil
        end
    end
    a.soldByHour[hour] = (a.soldByHour[hour] or 0) + soldTotal
    a.lastFull = now
    FG:Print(string.format("Scan done: %d listings, %d items.", total, items))
    if FG.UI and FG.UI.RefreshAuction then FG.UI:RefreshAuction() end
end

-- Passive capture: every search you make updates prices for what you looked at.
function Auction:CaptureBrowse()
    if self.scanning then return end
    local now = time()
    if modern and C_AuctionHouse.GetBrowseResults then
        for _, r in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
            local id = r.itemKey and r.itemKey.itemID
            if id and r.minPrice and r.minPrice > 0 then
                local e = self:Items()[id]
                -- Browse results only give the lowest price, so keep an older market value if we have one.
                self:Record(id, e and e.m or r.minPrice, r.minPrice, r.totalQuantity or 0, e and e.n or 0, now)
            end
        end
    elseif GetNumAuctionItems then
        local byItem = {}
        for i = 1, GetNumAuctionItems("list") do
            local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = GetAuctionItemInfo("list", i)
            if itemID and buyout and buyout > 0 and count and count > 0 then
                byItem[itemID] = byItem[itemID] or {}
                table.insert(byItem[itemID], { unit = math.floor(buyout / count), count = count })
            end
        end
        for id, list in pairs(byItem) do
            local market, min, qty, n = Auction.Aggregate(list)
            if market then self:Record(id, market, min, qty, n, now) end
        end
    end
end

------------------------------------------------------------------------
-- Advice
------------------------------------------------------------------------

function Auction:Advice(itemID, count, bound)
    local e = self:Price(itemID) or {}
    local sell = vendorPrice(itemID) or e.v or 0
    return Auction.Decide({ vendor = sell, market = e.m, saleRate = e.sr, count = count or 1, bound = bound },
        self:House(), FG.settings.duration), e
end

local function eachBagItem(fn)
    local C = C_Container
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local slots = C and C.GetContainerNumSlots(bag) or GetContainerNumSlots(bag)
        for slot = 1, slots do
            local info = C and C.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                fn(bag, slot, info.itemID, info.stackCount or 1, info.quality, info.isBound, info.hyperlink)
            elseif not C then
                local _, count, _, quality, _, _, link, _, _, itemID = GetContainerItemInfo(bag, slot)
                if itemID then fn(bag, slot, itemID, count or 1, quality, false, link) end
            end
        end
    end
end

-- Everything in your bags, with a recommendation. Sorted by value.
function Auction:BagReport()
    local rows = {}
    eachBagItem(function(_, _, itemID, count, quality, bound, link)
        local d, e = self:Advice(itemID, count, bound)
        table.insert(rows, { itemID = itemID, link = link, count = count, quality = quality, advice = d, price = e })
    end)
    table.sort(rows, function(a, b)
        local va = math.max(a.advice.ahEV or 0, a.advice.vendorTotal or 0)
        local vb = math.max(b.advice.ahEV or 0, b.advice.vendorTotal or 0)
        return va > vb
    end)
    return rows
end

-- Listings below the vendor price: buy them and sell to a vendor for a sure profit.
function Auction:VendorFlips(limit)
    local out = {}
    for id, e in pairs(self:Items()) do
        if e.v and e.v > 0 and e.min and e.min > 0 and e.min < e.v and (e.q or 0) > 0 then
            table.insert(out, { itemID = id, name = e.name, min = e.min, vendor = e.v, profit = e.v - e.min })
        end
    end
    table.sort(out, function(a, b) return a.profit > b.profit end)
    while #out > (limit or 15) do table.remove(out) end
    return out
end

function Auction:BestHour()
    local best, bestN = nil, 0
    for h, n in pairs(self:DB().soldByHour) do
        if n > bestN then best, bestN = h, n end
    end
    return best
end

------------------------------------------------------------------------
-- Selling at a merchant (only on your click)
------------------------------------------------------------------------

local SELLABLE_CLASSES = { [7] = true, [15] = true } -- trade goods and miscellaneous

function Auction:VendorList()
    local list, total = {}, 0
    local s = FG.settings
    eachBagItem(function(bag, slot, itemID, count, quality, bound, link)
        local sell, _, classID = vendorPrice(itemID)
        if not sell or sell <= 0 then return end
        local take = s.sellJunk and quality == 0
        if not take and s.sellAdvised and SELLABLE_CLASSES[classID] then
            take = self:Advice(itemID, count, bound).action == "vendor"
        end
        if take then
            table.insert(list, { bag = bag, slot = slot, link = link, value = sell * count })
            total = total + sell * count
        end
    end)
    return list, total
end

function Auction:SellToVendor()
    if not (MerchantFrame and MerchantFrame:IsShown()) then return end
    local list, total = self:VendorList()
    local use = C_Container and C_Container.UseContainerItem or UseContainerItem
    for _, item in ipairs(list) do use(item.bag, item.slot) end
    if #list > 0 then FG:Print(string.format("Sold %d items for %s.", #list, Auction.Money(total))) end
end

------------------------------------------------------------------------
-- Sales history from auction mail
------------------------------------------------------------------------

function Auction:ReadMail()
    if not GetInboxNumItems then return end
    local a = self:DB()
    for i = 1, GetInboxNumItems() do
        local invoiceType, itemName, buyer, bid, _, _, consignment = GetInboxInvoiceInfo(i)
        if invoiceType == "seller" and itemName and bid then
            local daysLeft = select(7, GetInboxHeaderInfo(i)) or 0
            -- Auction mail lasts 30 days, so expiry minus 30 days is the sale time.
            local soldAt = time() + math.floor(daysLeft * 86400) - 30 * 86400
            local key = string.format("%s:%d:%d", itemName, bid, math.floor(soldAt / 3600))
            if not a.salesSeen[key] then
                a.salesSeen[key] = true
                table.insert(a.sales, { item = itemName, price = bid, net = bid - (consignment or 0), t = soldAt, buyer = FG.Safe(buyer) })
                local hour = tonumber(date("%H", soldAt))
                a.soldByHour[hour] = (a.soldByHour[hour] or 0) + 1
            end
        end
    end
end

function Auction:SalesSummary(days)
    local since, sum, n = time() - (days or 7) * 86400, 0, 0
    for _, s in ipairs(self:DB().sales) do
        if s.t >= since then sum, n = sum + s.net, n + 1 end
    end
    return sum, n
end

------------------------------------------------------------------------
-- Tooltip
------------------------------------------------------------------------

local ACTION_TEXT = { ah = "Sell on the AH", vendor = "Sell to a vendor", keep = "Keep" }

function Auction:TooltipLines(itemID, count)
    if not FG.settings.tooltip then return {} end
    local d, e = self:Advice(itemID, count or 1)
    local T = FG.Theme
    local lines = {}
    local function add(left, right) table.insert(lines, { left, right }) end
    if e.m then
        local sr = e.sr and string.format(" · sells %d%%", e.sr * 100 + 0.5) or ""
        add(T:Color("accent", "Forever AH"), Auction.Money(e.m) .. sr)
        if e.h and e.h ~= e.m then add("  Historical", Auction.Money(e.h)) end
    end
    if (d.vendorTotal or 0) > 0 then add(T:Color("accent", "Forever vendor"), Auction.Money(d.vendorTotal)) end
    if e.m or (d.vendorTotal or 0) > 0 then
        local extra = d.action == "ah" and d.gain and (" (+" .. Auction.Money(d.gain) .. ")") or ""
        add(T:Color(d.action == "ah" and "good" or "muted", "→ " .. ACTION_TEXT[d.action] .. extra), "")
    end
    return lines
end

local function hookTooltips()
    local function addLines(tooltip, itemID)
        if not itemID then return end
        for _, l in ipairs(Auction:TooltipLines(itemID)) do
            if l[2] ~= "" then tooltip:AddDoubleLine(l[1], l[2], 1, 1, 1, 1, 1, 1) else tooltip:AddLine(l[1]) end
        end
    end
    if TooltipDataProcessor and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            if tooltip == GameTooltip or tooltip == ItemRefTooltip then addLines(tooltip, data and data.id) end
        end)
    else
        GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
            local _, link = tooltip:GetItem()
            addLines(tooltip, link and tonumber(link:match("item:(%d+)")))
        end)
    end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

FG:On("PLAYER_LOGIN", function()
    Auction:DB()
    hookTooltips()
end)
FG:On("AUCTION_HOUSE_SHOW", function() if FG.UI then FG.UI:AttachAuction() end end)
FG:On("AUCTION_ITEM_LIST_UPDATE", function()
    if Auction.scanning and not modern then Auction:FinishFullScan() else Auction:CaptureBrowse() end
end)
FG:On("REPLICATE_ITEM_LIST_UPDATE", function()
    if Auction.scanning then Auction:FinishFullScan() end
end)
FG:On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function() Auction:CaptureBrowse() end)
FG:On("MAIL_INBOX_UPDATE", function() Auction:ReadMail() end)
FG:On("MERCHANT_SHOW", function() if FG.UI then FG.UI:AttachMerchant() end end)
