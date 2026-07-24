-- Initialize addon
local addonName = "Farming_Tracker"
local addon = {}
local pendingItems = {} -- Items waiting for server response
local rateData = {}    -- In-memory rate tracking; resets every init/reload (never written to FTDB)

-- Colour codes used throughout the display
local COLOR_WHITE      = "|cffffffff"
local COLOR_GREY_LIGHT = "|cff999999"
local COLOR_GREY_MID   = "|cff888888"
local COLOR_BLUE_LIGHT = "|cffadd8e6"
local COLOR_RED        = "|cffff4444"
local COLOR_RED_BRIGHT = "|cffff0000"
local COLOR_GREEN      = "|cff00ff00"
local COLOR_RESET      = "|r"

-- Create main frame but don't show it yet
local mainFrame = CreateFrame("Frame", "MyAddonMainFrame", UIParent, "BackdropTemplate")
mainFrame:SetSize(220, 300)
mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
mainFrame:Hide()  -- Hide initially until addon loads

-- Set up backdrop with transparency
mainFrame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
mainFrame:SetBackdropColor(0, 0, 0, 0.85)
mainFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)

-- Create content area (no scroll frame)
local contentFrame = CreateFrame("Frame", "FarmingTrackerContentFrame", mainFrame)
contentFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -10)
contentFrame:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -10, -10)
contentFrame:SetSize(200, 300) -- Set initial size

mainFrame:EnableMouse(true)
mainFrame:SetMovable(true)
mainFrame:RegisterForDrag("LeftButton")
mainFrame:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)
mainFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Persist position relative to UIParent so it survives reload/relog
    local point, _, relativePoint, x, y = self:GetPoint()
    FTDB.position = { point = point, relativePoint = relativePoint, x = x, y = y }
end)

SLASH_FARMINGTRACKER1 = "/farmingtracker"
SLASH_FARMINGTRACKER2 = "/ft"
SlashCmdList["FARMINGTRACKER"] = function(msg)
    if not FTDB then return end  -- guard against nil FTDB on first load
    local command, arg = msg:match("^(%S*)%s*(.-)$")
    command = command:lower()
    
    if command == "add" then
        local itemID = tonumber(arg)
        if itemID then
            addon:AddItem(itemID)
        else
            print("Usage: /ft add <itemID>")
        end
    else
        -- Toggle window visibility
        if mainFrame:IsShown() then
            mainFrame:Hide()
            FTDB.visible = false
        else
            mainFrame:Show()
            FTDB.visible = true
        end
    end
end

-- Format a number to at most 1 decimal place, omitting a trailing ".0"
local function formatNumber(n)
    local rounded = math.floor(n * 10 + 0.5) / 10
    if rounded == math.floor(rounded) then
        return tostring(math.floor(rounded))
    end
    return tostring(rounded)
end

-- Addon loading and event handling
function addon:OnAddonLoaded(loadedAddonName)
    if loadedAddonName ~= addonName then
        return
    end
    
    -- Initialize saved variables after addon loads
    if not FTDB then
        FTDB = {
            visible = false,
            trackedItems = {}
        }
    end
    
    -- Ensure trackedItems table exists (for upgrades)
    if not FTDB.trackedItems then
        FTDB.trackedItems = {}
    end

    -- Ensure rate settings have defaults (for upgrades from older versions)
    if FTDB.showRate == nil then
        FTDB.showRate = true
    end
    if not FTDB.rateUnit then
        FTDB.rateUnit = "auto"
    end
    if FTDB.showSessionCount == nil then
        FTDB.showSessionCount = true
    end
    
    -- Restore saved frame position, or default to centre
    if FTDB.position and FTDB.position.point and FTDB.position.relativePoint
       and FTDB.position.x ~= nil and FTDB.position.y ~= nil then
        local p = FTDB.position
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint(p.point, UIParent, p.relativePoint, p.x, p.y)
    end

    -- Set initial frame visibility based on saved setting
    if FTDB.visible then
        mainFrame:Show()
    else
        mainFrame:Hide()
    end

    -- Register Addon Options panel
    addon:RegisterSettings()

    -- Update display
    addon:UpdateItemDisplay()

    -- Start live-refresh ticker (~5 s) so rates stay current between bag events
    C_Timer.NewTicker(5, function()
        addon:UpdateItemDisplay()
    end)
end

-- Register the Addon Options panel (Settings > Addons > Farming Tracker)
function addon:RegisterSettings()
    local category, layout = Settings.RegisterVerticalLayoutCategory("Farming Tracker")

    -- "Show Rate" checkbox
    local showRateSetting = Settings.RegisterProxySetting(
        category,
        "FARMING_TRACKER_SHOW_RATE",
        Settings.VarType.Boolean,
        "Show Rate",
        true,
        function() return FTDB.showRate end,
        function(value)
            FTDB.showRate = value
            addon:UpdateItemDisplay()
        end
    )
    Settings.CreateCheckbox(category, showRateSetting, "Display collection rate next to item counts")

    -- "Rate Unit" dropdown
    local rateUnitSetting = Settings.RegisterProxySetting(
        category,
        "FARMING_TRACKER_RATE_UNIT",
        Settings.VarType.String,
        "Rate Unit",
        "auto",
        function() return FTDB.rateUnit end,
        function(value)
            FTDB.rateUnit = value
            addon:UpdateItemDisplay()
        end
    )
    Settings.CreateDropdown(category, rateUnitSetting, function()
        local container = Settings.CreateControlTextContainer()
        container:Add("auto", "Auto")
        container:Add("hour", "Per Hour (/hr)")
        container:Add("min",  "Per Minute (/min)")
        container:Add("sec",  "Per Second (/sec)")
        return container:GetData()
    end, "Which unit to use when displaying the collection rate")

    -- "Show Session Count" checkbox
    local showSessionCountSetting = Settings.RegisterProxySetting(
        category,
        "FARMING_TRACKER_SHOW_SESSION_COUNT",
        Settings.VarType.Boolean,
        "Show Session Count",
        true,
        function() return FTDB.showSessionCount end,
        function(value)
            FTDB.showSessionCount = value
            addon:UpdateItemDisplay()
        end
    )
    Settings.CreateCheckbox(category, showSessionCountSetting, "Show items collected this session next to the current count")

    Settings.RegisterAddOnCategory(category)
end

-- Item tracking functions
function addon:AddItem(itemID)
    local itemName, itemLink = GetItemInfo(itemID)
    
    if itemName then
        -- Item is cached, add immediately
        return self:AddItemImmediate(itemID, itemName, itemLink)
    else
        -- Item not cached, request from server
        pendingItems[itemID] = true
        print("Looking up item ID " .. itemID .. "... please wait.")
        return true -- Don't show error yet
    end
end

function addon:AddItemImmediate(itemID, itemName, itemLink)
    -- Check if already tracked
    if FTDB.trackedItems[itemID] then
        print("Item '" .. itemName .. "' is already being tracked.")
        return false
    end
    
    -- Add to tracked items
    FTDB.trackedItems[itemID] = {
        name = itemName,
        link = itemLink
    }
    
    print("Added '" .. itemName .. "' to tracking list.")
    self:UpdateItemDisplay()
    return true
end

function addon:HandleItemInfoReceived(itemID)
    if pendingItems[itemID] then
        pendingItems[itemID] = nil -- Remove from pending
        
        local itemName, itemLink = GetItemInfo(itemID)
        if itemName then
            self:AddItemImmediate(itemID, itemName, itemLink)
        else
            print("Item ID " .. itemID .. " not found. Make sure it's a valid item ID.")
        end
    end
end

-- Update per-item rate tracking state (in-memory only, never touches FTDB)
function addon:UpdateRates()
    if not FTDB or not FTDB.trackedItems then return end

    for itemID, _ in pairs(FTDB.trackedItems) do
        local id = tonumber(itemID)
        local currentCount = GetItemCount(id)

        if not rateData[itemID] then
            -- ONLY seed baseline if the API has actually loaded item data (currentCount > 0)
            -- If currentCount is 0, leave rateData[itemID] uninitialized until bags load!
            if currentCount > 0 then
                rateData[itemID] = { 
                    lastCount = currentCount, 
                    collected = 0, 
                    startTime = nil,
                    initialized = true 
                }
            end
        else
            local data = rateData[itemID]
            local delta = currentCount - data.lastCount

            if delta > 0 then
                -- Standard gain logic
                if not data.startTime then
                    data.startTime = GetTime()
                end
                data.collected = data.collected + delta
                data.lastCount = currentCount
            elseif delta < 0 then
                -- Item consumed or moved
                data.lastCount = currentCount
            end
        end
    end
end

function addon:UpdateItemDisplay()
    if not FTDB or not FTDB.trackedItems then return end
    self:UpdateRates()

    -- Clear existing display - need to clear both frames and font strings
    for i, child in ipairs({contentFrame:GetChildren()}) do
        child:Hide()
        child:SetParent(nil)
    end
    
    for i, region in ipairs({contentFrame:GetRegions()}) do
        if region:GetObjectType() == "FontString" then
            region:Hide()
            region:SetParent(nil)
        end
    end
    
    local yOffset = 0
    local lineHeight = 18
    local itemCount = 0
    
    -- Count items first
    for _ in pairs(FTDB.trackedItems) do
        itemCount = itemCount + 1
    end
    
    if itemCount == 0 then
        -- Show empty state message
        local emptyText = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        emptyText:SetPoint("CENTER", mainFrame, "CENTER", 0, 0)
        emptyText:SetText(COLOR_GREY_LIGHT .. "Alt-click items to track" .. COLOR_RESET)
        emptyText:SetFontObject("GameFontNormalSmall")
        local font, size, flags = emptyText:GetFont()
        emptyText:SetFont(font, size, "ITALIC")
        
        -- Set minimum size for empty state
        mainFrame:SetSize(220, 50)
    else
        -- Display tracked items
        for itemID, itemData in pairs(FTDB.trackedItems) do
            local currentCount = GetItemCount(tonumber(itemID))

            -- Build rate string if rates are enabled and this item has gained anything since init
            local rateStr = nil
            local rd = rateData[itemID]
            if FTDB.showRate and rd and rd.collected > 0 and rd.startTime then
                local elapsed = GetTime() - rd.startTime
                if elapsed > 0 then
                    local perSecond = rd.collected / elapsed
                    local perMinute = perSecond * 60
                    local perHour   = perSecond * 3600
                    local unit = FTDB.rateUnit or "auto"
                    if unit == "hour" then
                        rateStr = formatNumber(perHour) .. "/hr"
                    elseif unit == "min" then
                        rateStr = formatNumber(perMinute) .. "/min"
                    elseif unit == "sec" then
                        rateStr = formatNumber(perSecond) .. "/sec"
                    else -- auto: < 10/min → /hr; 10–59/min → /min; ≥ 60/min → /sec
                        if perMinute < 10 then
                            rateStr = formatNumber(perHour) .. "/hr"
                        elseif perMinute < 60 then
                            rateStr = formatNumber(perMinute) .. "/min"
                        else
                            rateStr = formatNumber(perSecond) .. "/sec"
                        end
                    end
                end
            end

            -- Build item text: name, current count, and optional session count
            local sessionStr = nil
            if FTDB.showSessionCount and rd and rd.collected > 0 then
                sessionStr = COLOR_BLUE_LIGHT .. "(" .. rd.collected .. ")" .. COLOR_RESET
            end
            local countText = COLOR_WHITE .. currentCount .. COLOR_RESET
                .. (sessionStr and " " .. sessionStr or "")

            -- Create item display frame
            local itemFrame = CreateFrame("Frame", nil, contentFrame)
            itemFrame:SetSize(200, lineHeight)
            itemFrame:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, -yOffset)
            
            -- Item name and count text; narrowed slightly when a rate label is present
            local itemText = itemFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            itemText:SetPoint("LEFT", itemFrame, "LEFT", 0, 0)
            itemText:SetText(itemData.name .. ": " .. countText)
            itemText:SetJustifyH("LEFT")
            itemText:SetWidth(rateStr and 130 or 165)

            -- Rate label (right-aligned, mid-grey, left of the × button)
            if rateStr then
                local rateLabel = itemFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                rateLabel:SetPoint("RIGHT", itemFrame, "RIGHT", -22, 0)
                rateLabel:SetWidth(55)
                rateLabel:SetJustifyH("RIGHT")
                rateLabel:SetText(COLOR_GREY_MID .. rateStr .. COLOR_RESET)
            end

            -- Remove button (smaller, simpler)
            local removeBtn = CreateFrame("Button", nil, itemFrame)
            removeBtn:SetSize(20, 20)
            removeBtn:SetPoint("RIGHT", itemFrame, "RIGHT", 0, 0)
            
            local removeBtnText = removeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            removeBtnText:SetPoint("CENTER")
            removeBtnText:SetText(COLOR_RED .. "×" .. COLOR_RESET)
            
            removeBtn:SetScript("OnEnter", function(self)
                removeBtnText:SetText(COLOR_RED_BRIGHT .. "×" .. COLOR_RESET)
            end)
            removeBtn:SetScript("OnLeave", function(self)
                removeBtnText:SetText(COLOR_RED .. "×" .. COLOR_RESET)
            end)
            removeBtn:SetScript("OnClick", function()
                addon:RemoveItem(itemID)
            end)
            
            yOffset = yOffset + lineHeight + 1
        end
        
        -- Resize main frame based on content (padding top and bottom)
        local frameHeight = yOffset + 20
        mainFrame:SetSize(220, frameHeight)
    end
end

function addon:RemoveItem(itemID)
    if FTDB.trackedItems[itemID] then
        local itemName = FTDB.trackedItems[itemID].name
        FTDB.trackedItems[itemID] = nil
        rateData[itemID] = nil  -- clear in-memory rate state for this item
        print("Removed '" .. itemName .. "' from tracking list.")
        self:UpdateItemDisplay()
    end
end

function addon:OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        self:OnAddonLoaded(...)
    elseif event == "ITEM_COUNT_CHANGED" or event == "BAG_UPDATE_DELAYED" then
        self:UpdateItemDisplay()
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        local itemID = ...
        if itemID then
            self:HandleItemInfoReceived(itemID)
        end
    end
end

local eventListenerFrame = CreateFrame("Frame", "MyAddonEventListenerFrame", UIParent)
eventListenerFrame:SetScript("OnEvent", function(self, event, ...) addon:OnEvent(event, ...) end)
eventListenerFrame:RegisterEvent("ADDON_LOADED")
eventListenerFrame:RegisterEvent("ITEM_COUNT_CHANGED")
eventListenerFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventListenerFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")

-- Inventory click integration
-- Hook into the modified item click handler
local originalHandleModifiedItemClick = HandleModifiedItemClick
function HandleModifiedItemClick(link)
    if IsAltKeyDown() and link then
        -- Extract item ID from the link
        local itemID = tonumber(link:match("item:(%d+)"))
        if itemID then
            addon:AddItem(itemID)
            return -- Don't pass to original handler
        end
    end
    
    -- Call original function for other cases
    return originalHandleModifiedItemClick(link)
end

print(COLOR_GREEN .. "Farming Tracker loaded!" .. COLOR_RESET .. " Alt-click items to track them, or use /ft to toggle the window.")
