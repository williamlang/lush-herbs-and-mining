local ADDON_NAME = ...

-- ============================================================
-- Default config  (merged with SavedVariables on load)
-- ============================================================
local DEFAULTS = {
    glowR         = 0.2,
    glowG         = 1.0,
    glowB         = 0.0,
    glowAlpha     = 0.85,
    pinSize       = 14,
    pulseDuration = 0.9,
    expirySeconds = 300,   -- pins disappear after 5 min
    debug         = false,
}

-- Tooltip keywords (case-insensitive) that mark a Lush / Rich node.
local LUSH_KEYWORDS = { "lush", "rich" }

-- ============================================================
-- Runtime state
-- ============================================================
local cfg
local eventFrame = CreateFrame("Frame")

-- Detected lush node positions (approx, based on player pos at detection).
-- { { x=worldX, y=worldY, instance=id, time=t, name=s }, ... }
local detectedNodes = {}

-- node-table → pin-frame mapping
local nodePins = {}

-- Recycled pin frames
local pinPool = {}

-- ============================================================
-- Helpers
-- ============================================================

local function IsLushString(s)
    if type(s) ~= "string" then return false end
    local lower = s:lower()
    for _, kw in ipairs(LUSH_KEYWORDS) do
        if lower:find(kw, 1, true) then return true end
    end
    return false
end

-- ============================================================
-- Pin pool
-- ============================================================

local function CreatePinFrame()
    local pin = CreateFrame("Frame", nil, Minimap)
    pin:SetSize(cfg.pinSize, cfg.pinSize)
    pin:SetFrameStrata("HIGH")
    pin:SetFrameLevel(10)

    local tex = pin:CreateTexture(nil, "OVERLAY", nil, 7)
    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    tex:SetAllPoints()
    tex:SetVertexColor(cfg.glowR, cfg.glowG, cfg.glowB)
    tex:SetBlendMode("ADD")
    pin.tex = tex

    local ag = tex:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local anim = ag:CreateAnimation("Alpha")
    anim:SetFromAlpha(0.10)
    anim:SetToAlpha(cfg.glowAlpha)
    anim:SetDuration(cfg.pulseDuration)
    anim:SetSmoothing("IN_OUT")
    pin.ag = ag

    return pin
end

local function AcquirePin()
    local pin = table.remove(pinPool)
    if not pin then pin = CreatePinFrame() end
    pin:Show()
    pin.ag:Play()
    return pin
end

local function ReleasePin(pin)
    pin.ag:Stop()
    pin:Hide()
    pin:ClearAllPoints()
    table.insert(pinPool, pin)
end

-- ============================================================
-- Minimap coordinate conversion
-- ============================================================

-- Outdoor minimap visible radius in yards (approximate, per zoom level).
local YARD_RADIUS = {
    [0] = 233, [1] = 200, [2] = 167, [3] = 133, [4] = 100, [5] = 67,
}

local function GetMinimapYardRadius()
    if C_Minimap and C_Minimap.GetViewRadius then
        return C_Minimap.GetViewRadius()
    end
    return YARD_RADIUS[Minimap:GetZoom()] or 150
end

--- Convert a world position to a pixel offset from Minimap center.
--- Returns px, py  or  nil, nil if the point is outside the minimap.
local function WorldToMinimapOffset(nodeX, nodeY)
    -- UnitPosition returns (y, x, z, instanceID);  y increases south, x increases east(?).
    local playerY, playerX = UnitPosition("player")
    if not playerY then return nil, nil end

    local dx = nodeX - playerX      -- east-west
    local dy = nodeY - playerY      -- north-south (positive = south)

    local yardRadius = GetMinimapYardRadius()
    local pixRadius  = Minimap:GetWidth() / 2
    local scale      = pixRadius / yardRadius

    local pixX =  dx * scale
    local pixY = -dy * scale         -- negate: south in world = down on screen

    -- Rotate when the minimap rotates with the player.
    if GetCVar("rotateMinimap") == "1" then
        local facing = GetPlayerFacing() or 0
        local s, c = math.sin(-facing), math.cos(-facing)
        pixX, pixY = pixX * c - pixY * s,
                     pixX * s + pixY * c
    end

    -- Clip to minimap circle.
    if (pixX * pixX + pixY * pixY) > (pixRadius * pixRadius) then
        return nil, nil
    end

    return pixX, pixY
end

-- ============================================================
-- Pin positioning (called every frame-ish)
-- ============================================================

local function UpdatePins()
    local _, _, _, currentInstance = UnitPosition("player")
    if not currentInstance then return end

    local now = GetTime()

    for i = #detectedNodes, 1, -1 do
        local node = detectedNodes[i]
        local pin  = nodePins[node]

        -- Expire old entries or wrong-instance entries.
        if now - node.time > cfg.expirySeconds
           or node.instance ~= currentInstance then
            if pin then ReleasePin(pin); nodePins[node] = nil end
            table.remove(detectedNodes, i)
        else
            -- Ensure a pin exists for this node.
            if not pin then
                pin = AcquirePin()
                nodePins[node] = pin
            end

            -- Reposition.
            local px, py = WorldToMinimapOffset(node.x, node.y)
            if px then
                pin:ClearAllPoints()
                pin:SetPoint("CENTER", Minimap, "CENTER", px, py)
                if not pin:IsShown() then pin:Show() end
            else
                pin:Hide()
            end
        end
    end
end

-- ============================================================
-- Tooltip hook  (detects Lush/Rich on world-object mouseover)
-- ============================================================

local function SetupTooltipHook()
    GameTooltip:HookScript("OnShow", function()
        local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        if not text or not IsLushString(text) then return end

        -- UnitPosition returns (y, x, z, instanceID).
        local uy, ux, _, instanceID = UnitPosition("player")
        if not uy then return end

        -- Deduplicate: refresh timestamp if we already track a node within 15 yd.
        for _, node in ipairs(detectedNodes) do
            if node.instance == instanceID then
                local d = (node.x - ux) ^ 2 + (node.y - uy) ^ 2
                if d < 225 then          -- 15^2
                    node.time = GetTime() -- keep it alive
                    return
                end
            end
        end

        -- New lush node.
        table.insert(detectedNodes, {
            x        = ux,
            y        = uy,
            instance = instanceID,
            time     = GetTime(),
            name     = text,
        })

        if cfg.debug then
            print(string.format(
                "|cffff8000[LHM Debug]|r Lush detected: '%s' at world (%.0f, %.0f)",
                text, ux, uy))
        end
    end)
end

-- ============================================================
-- Events & OnUpdate
-- ============================================================

eventFrame:RegisterEvent("ADDON_LOADED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        LHM_Config = LHM_Config or {}
        for k, v in pairs(DEFAULTS) do
            if LHM_Config[k] == nil then LHM_Config[k] = v end
        end
        cfg = LHM_Config
        SetupTooltipHook()
        print("|cff00cc44[Lush Herbs & Mining]|r loaded.  Hover over world nodes to detect Lush/Rich.")
        print("  Type |cffffff00/lhm help|r for commands.")
    end
end)

local updateThrottle = 0
eventFrame:SetScript("OnUpdate", function(self, elapsed)
    if not cfg then return end
    updateThrottle = updateThrottle + elapsed
    if updateThrottle < 0.05 then return end   -- ~20 updates/sec
    updateThrottle = 0
    UpdatePins()
end)

-- ============================================================
-- Slash commands
-- ============================================================

SLASH_LHM1 = "/lhm"
SlashCmdList["LHM"] = function(msg)
    if not cfg then return end
    local cmd = msg:match("^%s*(.-)%s*$"):lower()

    if cmd == "debug" then
        cfg.debug = not cfg.debug
        print(string.format("|cff00cc44[LHM]|r Debug mode |cffffffff%s|r.",
            cfg.debug and "ON" or "OFF"))

    elseif cmd == "clear" then
        for _, pin in pairs(nodePins) do ReleasePin(pin) end
        wipe(nodePins)
        wipe(detectedNodes)
        print("|cff00cc44[LHM]|r Cleared all tracked Lush positions.")

    elseif cmd:match("^color%s+") then
        local r, g, b = cmd:match("color%s+([%d.]+)%s+([%d.]+)%s+([%d.]+)")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b then
            cfg.glowR, cfg.glowG, cfg.glowB = r, g, b
            for _, pin in pairs(nodePins) do
                if pin.tex then pin.tex:SetVertexColor(r, g, b) end
            end
            print(string.format("|cff00cc44[LHM]|r Glow colour set to (%.2f, %.2f, %.2f).", r, g, b))
        else
            print("|cff00cc44[LHM]|r Usage: /lhm color <R> <G> <B>  (0–1 each)")
        end

    elseif cmd == "count" then
        print(string.format("|cff00cc44[LHM]|r Tracking %d Lush/Rich node(s).", #detectedNodes))

    elseif cmd == "help" or cmd == "" then
        print("|cff00cc44[LHM] Lush Herbs & Mining|r – commands:")
        print("  |cffffff00/lhm debug|r            toggle debug output")
        print("  |cffffff00/lhm clear|r            clear all tracked positions")
        print("  |cffffff00/lhm color <R> <G> <B>|r set pin colour (0–1 each)")
        print("  |cffffff00/lhm count|r            how many nodes are tracked")
        print("  |cffffff00/lhm help|r              show this message")
    else
        print("|cff00cc44[LHM]|r Unknown command. Type |cffffff00/lhm help|r for options.")
    end
end
