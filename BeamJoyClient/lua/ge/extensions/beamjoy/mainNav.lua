--- Controller support for the redesigned main window (windows/main : the edge rail, its panels and
--- the full window).
---
--- BJS's "Focus notification" control (core/input/actions/beamjoy.json bjFocusNotification ; RB + X,
--- Shift + J by default) walks a short focus order, notifications first :
---   * nothing focused       -> a convoy invite if there is one, otherwise the main window
---   * notification focused  -> the main window
---   * main window focused   -> a notification that turned up meanwhile, otherwise let go
--- While the main window is focused it borrows the pad's menu buttons (beamjoy/uiNav.lua, plus
--- LB / RB for the full window's tabs) and the Angular side (windows/main/app.js) moves through
--- the rail and panels. It lands on Happening now, or on your convoy (Activities > Jobs) while
--- you're in one. B on the rail, or the control again, lets go, which closes the panel (and the
--- rail too if it was hidden before).
---
--- Other features bring the main window up themselves : a depot prompt's "All depots" (focusOn),
--- and arriving at your convoy's depot (autoFocus, which lets go again when you drive off, and
--- doesn't grab again after you let go yourself until you've left and come back).

local M = {
    dependencies = { "beamjoy_uiNav", "beamjoy_communications_ui" },
    OWNER = "mainWindow",
    focused = false,
    -- the rail was hidden and got opened for the pad
    openedRail = false,
    --- autoFocus keys currently holding the pad, and those the player let go of
    ---@type table<string, true>
    autoHeld = {},
    ---@type table<string, true>
    autoDismissed = {},
}

--- where focusing lands when nothing asked for a place
---@return string panel, string? section
local function defaultTarget()
    if beamjoy_delivery and (beamjoy_delivery.lobby or beamjoy_delivery.job) then return "play", "jobs" end
    return "now", nil
end

---@param focused boolean
---@param panel string? rail panel to open (default : see defaultTarget)
---@param section string? Activities section, with panel "play"
local function setFocused(focused, panel, section)
    focused = focused == true
    if focused == M.focused then
        -- already focused : just go where asked
        if focused and panel then
            beamjoy_communications_ui.send("BJMainPad", { active = true, panel = panel, section = section })
        end
        return
    end
    M.focused = focused
    if focused then
        -- a hidden rail opens so there's something to drive, and hides again on letting go
        M.openedRail = beamjoy_communications_ui.windowStates.main == false
        beamjoy_communications_ui.requestOpenWindow("main")
        beamjoy_uiNav.acquire(M.OWNER, beamjoy_uiNav.TAB_ACTIONS)
        if not panel then panel, section = defaultTarget() end
    else
        beamjoy_uiNav.release(M.OWNER)
        if M.openedRail and not beamjoy_communications_ui.isMainForced() then
            beamjoy_communications_ui.closeWindow("main")
        end
        M.openedRail = false
        -- letting go while something auto-focused : don't grab again until it's re-armed
        for key in pairs(M.autoHeld) do M.autoDismissed[key] = true end
        M.autoHeld = {}
    end
    beamjoy_communications_ui.send("BJMainPad", { active = focused, panel = panel, section = section })
end

--- focus the main window on a given panel (a depot prompt's "All depots")
---@param panel string
---@param section string?
local function focusOn(panel, section)
    setFocused(true, panel, section)
end

--- a feature wanting the pad for as long as `want` holds (called every tick is fine)
---@param key string
---@param want boolean
---@param panel string?
---@param section string?
local function autoFocus(key, want, panel, section)
    if want then
        if M.autoHeld[key] or M.autoDismissed[key] then return end
        M.autoHeld[key] = true
        setFocused(true, panel, section)
    else
        -- re-armed for next time
        M.autoDismissed[key] = nil
        if not M.autoHeld[key] then return end
        M.autoHeld[key] = nil
        -- nothing else holds it : let go (not a dismissal, autoHeld is already clear)
        if M.focused and not next(M.autoHeld) then setFocused(false) end
    end
end

---@return boolean
local function notificationFocusable()
    return beamjoy_delivery ~= nil and beamjoy_delivery.notificationFocusable()
end

---@return boolean
local function notificationFocused()
    return beamjoy_delivery ~= nil and beamjoy_delivery.notificationFocused()
end

local function onBJFocusNotification()
    if M.focused then
        setFocused(false)
        if notificationFocusable() and not notificationFocused() then
            beamjoy_delivery.setNotificationFocus(true)
        end
    elseif notificationFocused() then
        beamjoy_delivery.setNotificationFocus(false)
        setFocused(true)
    elseif notificationFocusable() then
        beamjoy_delivery.setNotificationFocus(true)
    else
        setFocused(true)
    end
end

local function onInit()
    -- the UI lets go itself (B on the rail, hiding the rail) and re-asks after a reload
    beamjoy_communications_ui.addHandler("BJMainPadRelease", function() setFocused(false) end)
    beamjoy_communications_ui.addHandler("BJMainPadRequest", function()
        if M.focused then beamjoy_communications_ui.send("BJMainPad", { active = true }) end
    end)
end

local function onServerLeave()
    M.focused = false
    M.openedRail = false
    M.autoHeld = {}
    M.autoDismissed = {}
    beamjoy_uiNav.release(M.OWNER)
end

M.onInit = onInit
M.onBJFocusNotification = onBJFocusNotification
M.onServerLeave = onServerLeave
M.onExtensionUnloaded = onServerLeave
M.setFocused = setFocused
M.focusOn = focusOn
M.autoFocus = autoFocus

return M
