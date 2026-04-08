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
    probeInterval = 1.0,    -- seconds between checks for new blips
    reprobeInterval = 8.0,  -- seconds between full re-probes (handles frame recycling)
    debug         = false,
}

-- Tooltip keywords (case-insensitive) that mark a Lush / Rich node.
local LUSH_KEYWORDS = {
    "lush",
    "rich",
}

-- ============================================================
-- Runtime state
-- ============================================================
local cfg                   -- populated in ADDON_LOADED
local probeTimer   = 0
local reprobeTimer = 0
local lushBlips    = {}     -- [frame] = true  (highlighted frames)
local probedBlips  = {}     -- [frame] = true  (already tooltip-checked)
local eventFrame   = CreateFrame("Frame")

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

--- Returns true if the frame looks like a tracking blip we can probe.
--- We check for an OnEnter script (tooltip-capable) rather than size,
--- because WoW may size blip frames at 0x0 or larger than expected.
local function IsProbeableBlip(frame)
    return frame:IsShown() and frame:GetScript("OnEnter") ~= nil
end

-- ============================================================
-- Glow creation / show / hide
-- ============================================================

local function ShowGlow(blip)
    if blip._lhm_glow then
        blip._lhm_glow:Show()
        blip._lhm_ag:Play()
        return
    end

    local w, h = blip:GetWidth(), blip:GetHeight()
    local base = math.max(w, h, 8)
    local sz   = base + cfg.glowExtra

    local glow = blip:CreateTexture(nil, "OVERLAY", nil, 7)
    glow:SetTexture("Interface\\Buttons\\WHITE8X8")
    glow:SetSize(sz, sz)
    glow:SetPoint("CENTER", blip, "CENTER", 0, 0)
    glow:SetVertexColor(cfg.glowR, cfg.glowG, cfg.glowB)
    glow:SetBlendMode("ADD")

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

local function HideGlow(blip)
    if blip._lhm_ag   then blip._lhm_ag:Stop()  end
    if blip._lhm_glow then blip._lhm_glow:Hide() end
end

-- ============================================================
-- Tooltip probing
-- ============================================================
-- Programmatically fire each blip's OnEnter with the tooltip
-- invisible, read the first line, then hide it.

local function ProbeBlipTooltip(blip)
    local onEnter = blip:GetScript("OnEnter")
    if not onEnter then return nil end

    -- Make tooltip invisible during probe so nothing flickers.
    local prevAlpha = GameTooltip:GetAlpha()
    GameTooltip:SetAlpha(0)

    local ok = pcall(onEnter, blip)

    local text = ok and GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()

    GameTooltip:Hide()
    GameTooltip:SetAlpha(prevAlpha)

    if cfg.debug and text then
        print(string.format("|cffff8000[LHM Debug]|r Probed: '%s' → lush=%s",
            text, tostring(IsLushString(text))))
    end

    if text then return IsLushString(text) end
    return nil   -- couldn't determine
end

-- ============================================================
-- Scanning
-- ============================================================

--- Remove glows on frames that have disappeared.
local function Cleanup()
    for blip in pairs(lushBlips) do
        if not blip:IsShown() then
            HideGlow(blip)
            lushBlips[blip]   = nil
            probedBlips[blip] = nil
        end
    end
    -- Also drop stale probed entries for hidden frames.
    for blip in pairs(probedBlips) do
        if not blip:IsShown() then
            probedBlips[blip] = nil
        end
    end
end

--- Probe blips we haven't checked yet (runs frequently).
local function ProbeNewBlips()
    for _, child in ipairs({Minimap:GetChildren()}) do
        if child:IsShown() and not probedBlips[child] then
            probedBlips[child] = true

            local w, h = child:GetWidth(), child:GetHeight()
            local hasOnEnter = child:GetScript("OnEnter") ~= nil

            if cfg.debug then
                print(string.format(
                    "|cffff8000[LHM Debug]|r Child: size=%.0fx%.0f  OnEnter=%s  regions=%d  name=%s",
                    w, h, tostring(hasOnEnter), child:GetNumRegions(),
                    child:GetName() or "(nil)"))
            end

            if hasOnEnter then
                local isLush = ProbeBlipTooltip(child)
                if isLush then
                    ShowGlow(child)
                    lushBlips[child] = true
                end
            end
        end
    end
end

--- Clear the probed cache and re-check everything (handles frame recycling).
local function FullReprobe()
    -- Hide existing glows — they'll be re-applied if still lush.
    for blip in pairs(lushBlips) do
        HideGlow(blip)
    end
    wipe(lushBlips)
    wipe(probedBlips)

    for _, child in ipairs({Minimap:GetChildren()}) do
        if IsProbeableBlip(child) then
            probedBlips[child] = true
            local isLush = ProbeBlipTooltip(child)
            if isLush then
                ShowGlow(child)
                lushBlips[child] = true
            end
        end
    end
end

-- ============================================================
-- Events
-- ============================================================
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        LHM_Config = LHM_Config or {}
        for k, v in pairs(DEFAULTS) do
            if LHM_Config[k] == nil then LHM_Config[k] = v end
        end
        cfg = LHM_Config
        print("|cff00cc44[Lush Herbs & Mining]|r loaded. Type |cffffff00/lhm help|r for commands.")

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        -- Full reset on zone change.
        for blip in pairs(lushBlips) do HideGlow(blip) end
        wipe(lushBlips)
        wipe(probedBlips)
    end
end)

-- Timers: quick probe for new blips, periodic full re-probe, cleanup.
eventFrame:SetScript("OnUpdate", function(self, elapsed)
    if not cfg then return end

    probeTimer   = probeTimer + elapsed
    reprobeTimer = reprobeTimer + elapsed

    -- Cleanup hidden frames every probe cycle.
    if probeTimer >= cfg.probeInterval then
        probeTimer = 0
        Cleanup()
        ProbeNewBlips()
    end

    -- Full re-probe (handles WoW recycling blip frames for different nodes).
    if reprobeTimer >= cfg.reprobeInterval then
        reprobeTimer = 0
        FullReprobe()
    end
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
        print(string.format(
            "|cff00cc44[LHM]|r Debug mode |cffffffff%s|r.",
            cfg.debug and "ON" or "OFF"))

    elseif cmd == "scan" then
        FullReprobe()
        print("|cff00cc44[LHM]|r Full re-probe complete.")

    elseif cmd == "clear" then
        for blip in pairs(lushBlips) do HideGlow(blip) end
        wipe(lushBlips)
        wipe(probedBlips)
        print("|cff00cc44[LHM]|r Cleared all highlights.")

    elseif cmd:match("^color%s+") then
        local r, g, b = cmd:match("color%s+([%d.]+)%s+([%d.]+)%s+([%d.]+)")
        r, g, b = tonumber(r), tonumber(g), tonumber(b)
        if r and g and b then
            cfg.glowR, cfg.glowG, cfg.glowB = r, g, b
            for blip in pairs(lushBlips) do
                if blip._lhm_glow then
                    blip._lhm_glow:SetVertexColor(r, g, b)
                end
            end
            print(string.format("|cff00cc44[LHM]|r Glow colour set to (%.2f, %.2f, %.2f).", r, g, b))
        else
            print("|cff00cc44[LHM]|r Usage: /lhm color <R> <G> <B>  (0–1 each)")
        end

    elseif cmd == "help" or cmd == "" then
        print("|cff00cc44[LHM] Lush Herbs & Mining|r – commands:")
        print("  |cffffff00/lhm debug|r            toggle debug (prints tooltip probe results)")
        print("  |cffffff00/lhm scan|r              force a full re-probe now")
        print("  |cffffff00/lhm clear|r            clear all highlights")
        print("  |cffffff00/lhm color <R> <G> <B>|r set glow colour (0–1 each)")
        print("  |cffffff00/lhm help|r              show this message")
    else
        print("|cff00cc44[LHM]|r Unknown command. Type |cffffff00/lhm help|r for options.")
    end
end
