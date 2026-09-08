--- In-world Hunter arena editor. A thin host wrapper around the shared `pointListEditor.lua`
--- toolkit (see its own header for why safe zones deliberately don't share this same module) for
--- the four point-lists (hunter spawns, prey spawns, waypoints, respawn hubs). Owns only what's
--- genuinely Hunter-specific on top of that : the `enabled` toggle, gameplay `defaults`, and the
--- final combined save payload. Registered as a 4th slot in `activityEditor.lua`'s `editors` array.
---
--- One arena per map (no name, no browse list, see the plan's design decision), so this editor
--- has no id/create-new/delete-whole-arena concept the way the race editor does ; only individual
--- points within the lists are created/duplicated/deleted, via the shared list editor.
---
--- respawnHubs is deliberately optional (no minimum count, unlike the other three lists). It's
--- only ever consulted when a host explicitly picks `hunterRespawnStrategy == "hubs"`, and even
--- then hunterRunner.lua gracefully falls back to hunterSpawns if it's empty.

local pointListEditor = require("ge/extensions/beamjoy/ui/pointListEditor")

---@class BJActivityEditorHunter: BJActivityEditor
local M = {
    enabled = false,
    ---@type BJHunterDefaults
    defaults = {},
}
---@type BJActivityEditorCommon?
local parent

local listEditor = pointListEditor.new({
    lists = {
        {
            key = "hunterSpawns",
            labelKey = "beamjoy.window.config.tabs.hunterArena.hunterSpawn",
            color = BJColor(1, .85, 0, .8),
            hasDir = true,
        },
        {
            key = "preySpawns",
            labelKey = "beamjoy.window.config.tabs.hunterArena.preySpawn",
            color = BJColor(1, 0, 0, .8),
            hasDir = true,
        },
        {
            key = "waypoints",
            labelKey = "beamjoy.window.config.tabs.hunterArena.waypoint",
            color = BJColor(0, .6, 1, .5),
            hasRadius = true,
            defaultRadius = 5,
        },
        {
            key = "respawnHubs",
            labelKey = "beamjoy.window.config.tabs.hunterArena.respawnHub",
            color = BJColor(0, .8, .6, .8),
            hasDir = true,
        },
    },
    events = {
        listsUpdate = "BJEditorHunterArenaListsUpdate",
        activeUpdate = "BJEditorHunterArenaActiveUpdate",
        select = "BJEditorHunterArenaSelect",
        create = "BJEditorHunterArenaCreate",
        delete = "BJEditorHunterArenaDelete",
        setToVehicle = "BJEditorHunterArenaSetToVehicle",
        teleportTo = "BJEditorHunterArenaTeleportTo",
        setRadius = "BJEditorHunterArenaSetWaypointRadius",
        snapToGround = "BJEditorHunterArenaSnapToGround",
        snapMethod = "BJEditorHunterArenaSnapMethod",
        setSnapToGround = "BJEditorHunterArenaSetSnapToGround",
        setSnapMethod = "BJEditorHunterArenaSetSnapMethod",
        requestState = "BJEditorHunterArenaRequestState",
    },
    isActive = function() return parent ~= nil and parent.activeEditor == M end,
})

local function pushMeta()
    beamjoy_communications_ui.send("BJEditorHunterArenaMetaUpdate", {
        enabled = M.enabled,
        defaults = M.defaults,
    })
end

--- (re)loads M.enabled/defaults + the point lists from beamjoy_hunter.data's current snapshot.
--- shared by onOpen (first mount) and onArenaChanged (a legacy import, or any other server-side
--- write, landing while this editor is already the active one)
local function refresh()
    local arena = beamjoy_hunter.data or {}
    M.enabled = arena.enabled == true
    M.defaults = table.clone(arena.defaults or {})
    listEditor.open({
        hunterSpawns = arena.hunterSpawns,
        preySpawns = arena.preySpawns,
        waypoints = arena.waypoints,
        respawnHubs = arena.respawnHubs,
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

--- fired via extensions.hook("onBJHunterArenaChanged") (see hunter.lua's retrieveCache) whenever
--- a fresh arena cache lands from the server, e.g. right after a legacy import completes for the
--- current map. Only actually refreshes while this editor is the one on screen ; this is a pure
--- Lua-side re-open of the same data (listEditor.open() resets its own dirty flag, no Angular
--- beamjoyNavGuard round-trip involved), so there's no discard-changes prompt to dodge here. It
--- simply never asks. Any truly in-progress unsaved edit at the exact moment an import lands for
--- the same map is an accepted, rare edge case, not guarded against.
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

---@param defaults BJHunterDefaults
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
        hunterSpawns = table.map(lists.hunterSpawns, math.roundPosRotDirUp),
        preySpawns = table.map(lists.preySpawns, math.roundPosRotDirUp),
        waypoints = table.map(lists.waypoints, function(w)
            local rounded = math.roundPosRotDirUp(w)
            rounded.radius = math.round(rounded.radius, 2)
            return rounded
        end),
        respawnHubs = table.map(lists.respawnHubs, math.roundPosRotDirUp),
        defaults = M.defaults,
    }
    beamjoy_communications.send("hunterArenaSave", payload)
    beamjoy_communications.addOneUseHandler("hunterArenaSaved", function(status, err)
        if status then
            listEditor.clearDirty()
        else
            -- Real bug (same fix as infectedEditor.lua's own onSave): a rejected save used to
            -- leave this editor showing the attempted, never-actually-committed edit forever - the
            -- server keeps its last valid arena untouched on rejection, but nothing here reflected
            -- that. refresh() re-pulls enabled/defaults/every point list straight from the real
            -- synced arena (beamjoy_hunter.data), making this editor honest again instead of just
            -- stuck dirty.
            refresh()
            toast.error(err or "Failed to save data")
        end
    end, 5000)
end

---@param activityEditor BJActivityEditorCommon
local function onInit(activityEditor)
    parent = activityEditor
    listEditor.onInit()

    beamjoy_communications_ui.addHandler("BJEditorHunterArenaOpen", onOpen)
    beamjoy_communications_ui.addHandler("BJEditorHunterArenaClose", parent.onClose)
    beamjoy_communications_ui.addHandler("BJEditorHunterArenaSetEnabled", onSetEnabled)
    beamjoy_communications_ui.addHandler("BJEditorHunterArenaSetDefaults", onSetDefaults)
    beamjoy_communications_ui.addHandler("BJEditorHunterArenaSave", onSave)
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
M.onBJHunterArenaChanged = onArenaChanged

return M
