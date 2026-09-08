--- In-world Infected arena editor. A thin host wrapper around the shared `pointListEditor.lua`
--- toolkit, exactly mirroring `hunterEditor.lua`'s own shape for the two point-lists (survivor
--- spawns, infected spawns). Owns only what's genuinely Infected-specific on top of that : the
--- `enabled` toggle, gameplay `defaults`, and the final combined save payload. Registered as a
--- slot in `activityEditor.lua`'s `editors` array.
---
--- One arena per map (no name, no browse list), same reasoning as hunterEditor.lua's own doc
--- comment ; only individual points within the two lists are created/duplicated/deleted, via the
--- shared list editor.

local pointListEditor = require("ge/extensions/beamjoy/ui/pointListEditor")

---@class BJActivityEditorInfected: BJActivityEditor
local M = {
    enabled = false,
    ---@type BJInfectedDefaults
    defaults = {},
}
---@type BJActivityEditorCommon?
local parent

local listEditor = pointListEditor.new({
    lists = {
        {
            key = "survivorSpawns",
            labelKey = "beamjoy.window.config.tabs.infectedArena.survivorSpawn",
            color = BJColor(.33, 1, .33, .8),
            hasDir = true,
        },
        {
            key = "infectedSpawns",
            labelKey = "beamjoy.window.config.tabs.infectedArena.infectedSpawn",
            color = BJColor(1, 0, 0, .8),
            hasDir = true,
        },
    },
    events = {
        listsUpdate = "BJEditorInfectedArenaListsUpdate",
        activeUpdate = "BJEditorInfectedArenaActiveUpdate",
        select = "BJEditorInfectedArenaSelect",
        create = "BJEditorInfectedArenaCreate",
        delete = "BJEditorInfectedArenaDelete",
        setToVehicle = "BJEditorInfectedArenaSetToVehicle",
        teleportTo = "BJEditorInfectedArenaTeleportTo",
        setRadius = "BJEditorInfectedArenaSetWaypointRadius",
        snapToGround = "BJEditorInfectedArenaSnapToGround",
        snapMethod = "BJEditorInfectedArenaSnapMethod",
        setSnapToGround = "BJEditorInfectedArenaSetSnapToGround",
        setSnapMethod = "BJEditorInfectedArenaSetSnapMethod",
        requestState = "BJEditorInfectedArenaRequestState",
    },
    isActive = function() return parent ~= nil and parent.activeEditor == M end,
})

local function pushMeta()
    beamjoy_communications_ui.send("BJEditorInfectedArenaMetaUpdate", {
        enabled = M.enabled,
        defaults = M.defaults,
    })
end

--- (re)loads M.enabled/defaults + the point lists from beamjoy_infected.data's current snapshot.
--- shared by onOpen (first mount) and onArenaChanged (a legacy import, or any other server-side
--- write, landing while this editor is already the active one)
local function refresh()
    local arena = beamjoy_infected.data or {}
    M.enabled = arena.enabled == true
    M.defaults = table.clone(arena.defaults or {})
    listEditor.open({
        survivorSpawns = arena.survivorSpawns,
        infectedSpawns = arena.infectedSpawns,
    })
    pushMeta()
end

local function onOpen()
    if not parent then return end
    if parent.activeEditor and parent.activeEditor ~= M then
        parent.activeEditor.onClose()
    end
    parent.activeEditor = M
    beamjoy_communications_ui.send("BJEditorChangeTool", gizmo.tool)
    refresh()
end

--- fired via extensions.hook("onBJInfectedArenaChanged") (see infected.lua's retrieveCache)
--- whenever a fresh arena cache lands from the server, e.g. right after a legacy import completes
--- for the current map. Same "never asks, no unsaved-changes prompt" reasoning as hunterEditor.lua's
--- own onArenaChanged.
local function onArenaChanged()
    if not parent or parent.activeEditor ~= M then return end
    refresh()
end

---@param enabled boolean
local function onSetEnabled(enabled)
    if not parent or parent.activeEditor ~= M then return end
    M.enabled = enabled == true
    pushMeta()
    listEditor.markDirty()
end

---@param defaults BJInfectedDefaults
local function onSetDefaults(defaults)
    if not parent or parent.activeEditor ~= M then return end
    M.defaults = defaults or {}
    pushMeta()
    listEditor.markDirty()
end

local function onSave()
    if not parent then return end
    local lists = listEditor.getLists()
    local payload = {
        enabled = M.enabled,
        survivorSpawns = table.map(lists.survivorSpawns, math.roundPosRotDirUp),
        infectedSpawns = table.map(lists.infectedSpawns, math.roundPosRotDirUp),
        defaults = M.defaults,
    }
    beamjoy_communications.send("infectedArenaSave", payload)
    beamjoy_communications.addOneUseHandler("infectedArenaSaved", function(status, err)
        if status then
            listEditor.clearDirty()
        else
            -- Real bug: a rejected save (e.g. enabling with too few spawns) used to leave this
            -- editor showing the attempted, never-actually-committed edit forever - the server
            -- keeps its last valid arena untouched on rejection, but nothing here reflected that,
            -- so the editor could show an impossible "enabled" + empty-spawn-list combination that
            -- never actually existed server-side. refresh() re-pulls enabled/defaults/both spawn
            -- lists straight from the real synced arena (beamjoy_infected.data), making this
            -- editor honest again instead of just stuck dirty.
            refresh()
            toast.error(err or "Failed to save data")
        end
    end, 5000)
end

---@param activityEditor BJActivityEditorCommon
local function onInit(activityEditor)
    parent = activityEditor
    listEditor.onInit()

    beamjoy_communications_ui.addHandler("BJEditorInfectedArenaOpen", onOpen)
    beamjoy_communications_ui.addHandler("BJEditorInfectedArenaClose", parent.onClose)
    beamjoy_communications_ui.addHandler("BJEditorInfectedArenaSetEnabled", onSetEnabled)
    beamjoy_communications_ui.addHandler("BJEditorInfectedArenaSetDefaults", onSetDefaults)
    beamjoy_communications_ui.addHandler("BJEditorInfectedArenaSave", onSave)
end

local function onClose()
    if not parent then return end
    if parent.activeEditor == M then
        listEditor.close()
    end
end

M.onInit = onInit
M.onClose = onClose
M.onBJClick = listEditor.onBJClick
M.onBJInfectedArenaChanged = onArenaChanged

return M
