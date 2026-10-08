---@class BJActivityEditorCommon
local M = {
    ---@type BJActivityEditor?
    activeEditor = nil,

}

---@type tablelib<integer, BJActivityEditor>
local editors = Table({
    require("ge/extensions/beamjoy/ui/activityEditorSafeZone"),
    require("ge/extensions/beamjoy/ui/raceEditor"),
    require("ge/extensions/beamjoy/ui/hunterEditor"),
    require("ge/extensions/beamjoy/ui/infectedEditor"),
    require("ge/extensions/beamjoy/ui/derbyEditor"),
    require("ge/extensions/beamjoy/ui/freeroamEditor"),
})

local function onInit()
    editors:forEach(function(editor) editor.onInit(M) end)
    beamjoy_communications_ui.addHandler("BJCloseWindow", function(windowName)
        if windowName == "config" then
            M.onClose()
        end
    end)
end

local function onUpdate()
    if M.activeEditor and M.activeEditor.onUpdate then
        M.activeEditor.onUpdate()
    end
end

--- delegates the generic world-click hook (`inputs.lua`'s onBJClick, already fired on every
--- in-viewport click with a world-space hit point) to whichever editor is active, same pattern
--- as onUpdate above. Lets an editor support click-to-select in world space without needing to
--- be its own top-level registered extension
---@param clickType "left"|"middle"|"right"
---@param data onBJClickData
local function onBJClick(clickType, data)
    if M.activeEditor and M.activeEditor.onBJClick then
        M.activeEditor.onBJClick(clickType, data)
    end
end

local function onClose()
    if M.activeEditor and M.activeEditor.onClose then
        M.activeEditor.onClose()
    end
    M.activeEditor = nil
end

--- delegates hunter.lua's own extensions.hook("onBJHunterArenaChanged") (fired whenever a fresh
--- arena cache lands, e.g. right after a legacy import) to the active editor, same forwarding
--- pattern as onUpdate/onBJClick above. Only hunterEditor.lua actually defines this hook
local function onBJHunterArenaChanged()
    if M.activeEditor and M.activeEditor.onBJHunterArenaChanged then
        M.activeEditor.onBJHunterArenaChanged()
    end
end

--- same forwarding pattern as onBJHunterArenaChanged above, for infected.lua's own
--- extensions.hook("onBJInfectedArenaChanged")
local function onBJInfectedArenaChanged()
    if M.activeEditor and M.activeEditor.onBJInfectedArenaChanged then
        M.activeEditor.onBJInfectedArenaChanged()
    end
end

--- same forwarding pattern, for derby.lua's own extensions.hook("onBJDerbyArenasChanged")
local function onBJDerbyArenasChanged()
    if M.activeEditor and M.activeEditor.onBJDerbyArenasChanged then
        M.activeEditor.onBJDerbyArenasChanged()
    end
end

--- same forwarding pattern, for freeroamData.lua's own extensions.hook("onBJFreeroamDataChanged")
--- (only freeroamEditor.lua defines this)
local function onBJFreeroamDataChanged()
    if M.activeEditor and M.activeEditor.onBJFreeroamDataChanged then
        M.activeEditor.onBJFreeroamDataChanged()
    end
end

--- same forwarding pattern, for busLines.lua's own extensions.hook("onBJBusLinesChanged")
--- (only freeroamEditor.lua defines this)
local function onBJBusLinesChanged()
    if M.activeEditor and M.activeEditor.onBJBusLinesChanged then
        M.activeEditor.onBJBusLinesChanged()
    end
end

--- same forwarding pattern, for deliveryPoints.lua's own extensions.hook("onBJDeliveryPointsChanged")
--- (only freeroamEditor.lua defines this)
local function onBJDeliveryPointsChanged()
    if M.activeEditor and M.activeEditor.onBJDeliveryPointsChanged then
        M.activeEditor.onBJDeliveryPointsChanged()
    end
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onBJClick = onBJClick
-- the "Editor : delete selected" key binding (core/input/actions/beamjoy.json), same forwarding
M.onBJEditorDeleteKey = function()
    if M.activeEditor and M.activeEditor.onBJEditorDeleteKey then
        M.activeEditor.onBJEditorDeleteKey()
    end
end
M.onClose = onClose
M.onBJHunterArenaChanged = onBJHunterArenaChanged
M.onBJInfectedArenaChanged = onBJInfectedArenaChanged
M.onBJDerbyArenasChanged = onBJDerbyArenasChanged
M.onBJFreeroamDataChanged = onBJFreeroamDataChanged
M.onBJBusLinesChanged = onBJBusLinesChanged
M.onBJDeliveryPointsChanged = onBJDeliveryPointsChanged

--- same forwarding pattern, for driftZones.lua's own extensions.hook("onBJDriftZonesChanged")
--- (only freeroamEditor.lua defines this)
M.onBJDriftZonesChanged = function()
    if M.activeEditor and M.activeEditor.onBJDriftZonesChanged then
        M.activeEditor.onBJDriftZonesChanged()
    end
end

--- same forwarding pattern, for dragStrips.lua's own extensions.hook("onBJDragStripsChanged")
--- (only freeroamEditor.lua defines this)
M.onBJDragStripsChanged = function()
    if M.activeEditor and M.activeEditor.onBJDragStripsChanged then
        M.activeEditor.onBJDragStripsChanged()
    end
end

return M
