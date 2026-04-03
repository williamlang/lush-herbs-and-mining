local ADDON_NAME = ...

-- ============================================================
-- Default config  (merged with SavedVariables on load)
-- ============================================================
local DEFAULTS = {
    glowR         = 0.2,    -- glow colour: red
    glowG         = 1.0,    --              green
    glowB         = 0.0,    --              blue
    glowAlpha     = 0.85,   -- peak opacity of the glow
    glowExtra     = 10,     -- pixels added beyond the icon edge
    pulseDuration = 0.9,    -- seconds for one half-pulse (BOUNCE doubles it)
    scanInterval  = 0.25,   -- seconds between periodic minimap scans
    debug         = false,  -- when true, prints atlas names of every new blip
}

-- Keywords matched (case-insensitive) against string atlas/texture names.
local LUSH_KEYWORDS = {
    "lush",
    "rich",
    "abundant",
    "bountiful",
}

-- Numeric fileIDs that indicate a Lush/Rich node blip.
-- Populate these once debug output confirms which ID is unique to lush nodes.
local LUSH_FILE_IDS = {}

-- ============================================================
-- Runtime state
-- ============================================================
local cfg           -- populated in OnEvent(ADDON_LOADED)
local scanTimer = 0
local knownBlips = {}   -- [frame] = true|false  (true = has glow)
local eventFrame = CreateFrame("Frame")

-- ============================================================
-- Texture / atlas helpers
-- ============================================================

--- Returns true when `s` (string) contains any LUSH_KEYWORDS entry.
local function IsLushString(s)
    if type(s) ~= "string" then return false end
    local lower = s:lower()
    for _, kw in ipairs(LUSH_KEYWORDS) do
        if lower:find(kw, 1, true) then return true end
    end
    return false
end

--- Returns true when any Texture region on `blip` signals a Lush/Rich node:
---   • atlas or string texture contains a LUSH_KEYWORDS entry, OR
---   • numeric texture fileID is in LUSH_FILE_IDS.
local function BlipIsLush(blip)
    for i = 1, blip:GetNumRegions() do
        local r = select(i, blip:GetRegions())
        if r and r:GetObjectType() == "Texture" then
            if IsLushString(r:GetAtlas()) then return true end
            local tex = r:GetTexture()
            if type(tex) == "string" and IsLushString(tex)  then return true end
            if type(tex) == "number" and LUSH_FILE_IDS[tex] then return true end
        end
    end
    return false
end

--- Prints every atlas/texture on `blip` plus its screen position (debug helper).
local function PrintBlipInfo(blip)
    local cx, cy = blip:GetCenter()
    print(string.format("|cffff8000[LHM Debug]|r   pos=(%.0f,%.0f)  regions=%d",
        cx or 0, cy or 0, blip:GetNumRegions()))

    local found = false
    for i = 1, blip:GetNumRegions() do
        local r = select(i, blip:GetRegions())
        if r and r:GetObjectType() == "Texture" then
            local atlas = r:GetAtlas()
            local tex   = r:GetTexture()
            if atlas then
                print(string.format("|cffff8000[LHM Debug]|r     atlas[%d]:   %s", i, atlas))
                found = true
            end
            if tex ~= nil and tex ~= "" then
                local lushFlag = (type(tex) == "number" and LUSH_FILE_IDS[tex]) and " <-- LUSH?" or ""
                print(string.format("|cffff8000[LHM Debug]|r     texture[%d]: %s%s",
                    i, tostring(tex), lushFlag))
                found = true
            end
        end
    end
    if not found then
        print("|cffff8000[LHM Debug]|r     (no atlas or texture found)")
    end
end

-- ============================================================
-- Glow creation / show / hide
-- ============================================================

--- Lazily creates the glow texture + animation on `blip`, then shows it.
local function ShowGlow(blip)
    -- Reuse existing glow if we already created one for this frame.
    if blip._lhm_glow then
        blip._lhm_glow:Show()
        blip._lhm_ag:Play()
        return
    end

    local w, h = blip:GetWidth(), blip:GetHeight()
    -- Fall back to a sensible size when the frame reports 0 (not yet laid out).
    local base = math.max(w, h, 8)
    local sz   = base + cfg.glowExtra

    -- Background ring / halo using the game's white square stretched to size.
    local glow = blip:CreateTexture(nil, "OVERLAY", nil, 7)
    glow:SetTexture("Interface\\Buttons\\WHITE8X8")
    glow:SetSize(sz, sz)
    glow:SetPoint("CENTER", blip, "CENTER", 0, 0)
    glow:SetVertexColor(cfg.glowR, cfg.glowG, cfg.glowB)
    glow:SetBlendMode("ADD")

    -- Pulse: BOUNCE automatically reverses the animation for a smooth throb.
    local ag = glow:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")

    local anim = ag:CreateAnimation("Alpha")
    anim:SetFromAlpha(0.10)
    anim:SetToAlpha(cfg.glowAlpha)
    anim:SetDuration(cfg.pulseDuration)
    anim:SetSmoothing("IN_OUT")

    ag:Play()

    blip._lhm_glow = glow
    blip._lhm_ag   = ag
end

--- Hides the glow on `blip` without destroying it (can be shown again cheaply).
local function HideGlow(blip)
    if blip._lhm_ag   then blip._lhm_ag:Stop()  end
    if blip._lhm_glow then blip._lhm_glow:Hide() end
end

-- ============================================================
-- Minimap scan
-- ============================================================
local function ScanMinimap()
    -- 1. Clean up blips that are no longer visible.
    for blip, wasLush in pairs(knownBlips) do
        if not blip:IsShown() then
            if wasLush then HideGlow(blip) end
            knownBlips[blip] = nil
        end
    end

    -- 2. Inspect every child of the Minimap frame.
    for _, child in ipairs({Minimap:GetChildren()}) do
        local w, h = child:GetWidth(), child:GetHeight()
        -- Skip frames that are too large to be tracking blips (UI chrome, borders, etc.)
        -- Real blips are roughly 10-16 px; anything over 30 px is not a blip.
        local isBlipSized = (w > 0 and w <= 30) and (h > 0 and h <= 30)
        if isBlipSized and child:IsShown() and child:GetNumRegions() > 0 then
            local isNew  = knownBlips[child] == nil
            local isLush = BlipIsLush(child)

            -- Debug: print atlas info the first time we see this frame.
            if cfg.debug and isNew then
                print(string.format(
                    "|cffff8000[LHM Debug]|r New minimap child (lush=%s):",
                    tostring(isLush)))
                PrintBlipInfo(child)
            end

            if isLush then
                ShowGlow(child)
                knownBlips[child] = true
            else
                -- Hide any leftover glow if this frame was previously lush.
                if knownBlips[child] == true then HideGlow(child) end
                knownBlips[child] = false
            end
        end
    end
end

-- ============================================================
-- Events
-- ============================================================
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("MINIMAP_UPDATE_TRACKING")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        -- Merge saved variables with defaults.
        LHM_Config = LHM_Config or {}
        for k, v in pairs(DEFAULTS) do
            if LHM_Config[k] == nil then LHM_Config[k] = v end
        end
        cfg = LHM_Config
        print("|cff00cc44[Lush Herbs & Mining]|r loaded. Type |cffffff00/lhm help|r for commands.")

    elseif event == "PLAYER_ENTERING_WORLD" or event == "MINIMAP_UPDATE_TRACKING" then
        wipe(knownBlips)    -- full rescan when world state changes
        ScanMinimap()
    end
end)

-- Periodic scan to catch blips that appear/disappear between events.
eventFrame:SetScript("OnUpdate", function(self, elapsed)
    scanTimer = scanTimer + elapsed
    if scanTimer >= cfg.scanInterval then
        scanTimer = 0
        ScanMinimap()
    end
end)

-- ============================================================
-- Slash commands
-- ============================================================
SLASH_LHM1 = "/lhm"
SlashCmdList["LHM"] = function(msg)
    if not cfg then return end          -- safety: loaded before cfg is set
    local cmd = msg:match("^%s*(.-)%s*$"):lower()

    if cmd == "debug" then
        cfg.debug = not cfg.debug
        wipe(knownBlips)                -- so every blip gets re-printed
        print(string.format(
            "|cff00cc44[LHM]|r Debug mode |cffffffff%s|r. "
            .. "Move around to trigger scans, then hover over minimap icons.",
            cfg.debug and "ON" or "OFF"))

    elseif cmd == "scan" then
        wipe(knownBlips)
        ScanMinimap()
        print("|cff00cc44[LHM]|r Manual scan complete.")

    elseif cmd:match("^color%s+") then
        -- /lhm color R G B   (values 0-1)
        local r, g, b = cmd:match("color%s+([%d.]+)%s+([%d.]+)%s+([%d.]+)")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b then
            cfg.glowR, cfg.glowG, cfg.glowB = r, g, b
            -- Reapply colour to existing glows.
            for blip, wasLush in pairs(knownBlips) do
                if wasLush and blip._lhm_glow then
                    blip._lhm_glow:SetVertexColor(cfg.glowR, cfg.glowG, cfg.glowB)
                end
            end
            print(string.format("|cff00cc44[LHM]|r Glow colour set to (%.2f, %.2f, %.2f).", r, g, b))
        else
            print("|cff00cc44[LHM]|r Usage: /lhm color <R> <G> <B>  (values 0–1, e.g. /lhm color 0.2 1 0)")
        end

    elseif cmd == "help" or cmd == "" then
        print("|cff00cc44[LHM] Lush Herbs & Mining|r – commands:")
        print("  |cffffff00/lhm debug|r            toggle debug mode (prints atlas + texture info)")
        print("  |cffffff00/lhm scan|r              force a full minimap rescan")
        print("  |cffffff00/lhm color <R> <G> <B>|r set glow colour (0–1 each)")
        print("  |cffffff00/lhm help|r              show this message")
    else
        print("|cff00cc44[LHM]|r Unknown command. Type |cffffff00/lhm help|r for options.")
    end
end
