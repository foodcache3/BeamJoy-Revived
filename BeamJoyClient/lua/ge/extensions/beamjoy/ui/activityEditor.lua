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

M.onInit = onInit
M.onUpdate = onUpdate
M.onBJClick = onBJClick
M.onClose = onClose
M.onBJHunterArenaChanged = onBJHunterArenaChanged

return M
