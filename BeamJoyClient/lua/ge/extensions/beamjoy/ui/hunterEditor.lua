--- In-world Hunter arena editor. A thin host wrapper around the shared `pointListEditor.lua`
--- toolkit (see its own header for why safe zones deliberately don't share this same module) for
--- the four point-lists (hunter spawns, prey spawns, waypoints, respawn hubs). Owns only what's
--- genuinely Hunter-specific on top of that : the `enabled` toggle, gameplay `defaults`, and the
--- final combined save payload. Registered as a 4th slot in `activityEditor.lua`'s `editors` array.
---
--- A map holds several arenas, so this edits one of them at a time (picked from a list, or a new
--- one), each saved and deleted on its own, exactly as derbyEditor.lua already does.
---
--- respawnHubs is deliberately optional (no minimum count, unlike the other three lists). It's
--- only ever consulted when a host explicitly picks `hunterRespawnStrategy == "hubs"`, and even
--- then hunterRunner.lua gracefully falls back to hunterSpawns if it's empty.

local pointListEditor = require("ge/extensions/beamjoy/ui/pointListEditor")

---@class BJActivityEditorHunter: BJActivityEditor
local M = {
    ---@type integer? the arena being edited ; nil for a new one not saved yet
    arenaId = nil,
    name = "",
    enabled = false,
    ---@type BJHunterDefaults
    defaults = {},
    --- the arena's props (direct request : props in Hunter as in races), edited by the props
    --- editor (ui/propEditor.lua) through the list editor
    ---@type table[]
    props = {},
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
    props = function() return M.props end,
})

local function pushMeta()
    beamjoy_communications_ui.send("BJEditorHunterArenaMetaUpdate", {
        arenas = table.map(beamjoy_hunter.data or {}, function(a)
            return { id = a.id, name = a.name, enabled = a.enabled == true }
        end),
        arenaId = M.arenaId,
        isNew = M.arenaId == nil,
        blank = M.blank == true,
        name = M.name,
        enabled = M.enabled,
        defaults = M.defaults,
    })
end

--- loads one arena (or a blank new one) into the editor, dropping unsaved edits
---@param arena BJHunterArena?
---@param keepSelection boolean? the same arena again (it was just saved) : the selected point stays
local function load(arena, keepSelection)
    -- nothing to edit (a map without arenas) : the UI shows its empty state
    M.blank = arena == nil
    arena = arena or {}
    M.arenaId = arena.id
    M.name = arena.name or ""
    M.enabled = arena.enabled == true
    M.defaults = table.clone(arena.defaults or {})
    M.props = table.isArray(arena.props) and table.clone(arena.props) or {}
    listEditor.open({
        hunterSpawns = arena.hunterSpawns,
        preySpawns = arena.preySpawns,
        waypoints = arena.waypoints,
        respawnHubs = arena.respawnHubs,
    }, keepSelection)
    pushMeta()
end

local function onOpen()
    if not parent then return end
    if parent.activeEditor and parent.activeEditor ~= M then
        parent.activeEditor.onClose()
    end
    parent.activeEditor = M
    beamjoy_communications_ui.send("BJEditorChangeTool", gizmo.tool)
    -- the arena last edited, or the first one
    local arena = M.arenaId and beamjoy_hunter.getArena(M.arenaId) or (beamjoy_hunter.data or {})[1]
    load(arena)
end

--- fired via extensions.hook("onBJHunterArenaChanged") (see hunter.lua's retrieveCache) whenever
--- a fresh arena list lands from the server (a save of this or another arena, a delete, a legacy
--- import). The list itself always refreshes ; the arena being edited only when it has no unsaved
--- changes, so an edit in progress is never silently thrown away. Same shape as derbyEditor.lua's
--- own onArenasChanged.
local function onArenaChanged()
    if not parent or parent.activeEditor ~= M then return end
    if listEditor.isDirty() then return pushMeta() end
    local arena = M.arenaId and beamjoy_hunter.getArena(M.arenaId)
    if arena then
        load(arena, true)
    elseif M.arenaId then
        load((beamjoy_hunter.data or {})[1])
    else
        pushMeta()
    end
end

---@param id integer
local function onSelectArena(id)
    if not parent or parent.activeEditor ~= M then return end
    load(beamjoy_hunter.getArena(tonumber(id)))
end

local function onNewArena()
    if not parent or parent.activeEditor ~= M then return end
    -- no defaults of its own : the server fills in every one it doesn't get (sanitizeArena), and
    -- the config panel shows those same fallbacks until something is actually changed
    load({ name = beamjoy_lang.translate("beamjoy.window.config.tabs.hunterArena.newName") })
    listEditor.markDirty()
end

local function onDeleteArena()
    if not parent or parent.activeEditor ~= M then return end
    if not M.arenaId then
        -- a new arena that was never saved : just drop it
        return load((beamjoy_hunter.data or {})[1])
    end
    local deleted = M.arenaId
    beamjoy_communications.send("hunterArenaDelete", deleted)
    -- on to another arena right away (the list itself refreshes when the server answers)
    load(table.find(beamjoy_hunter.data or {}, function(a) return a.id ~= deleted end))
end

---@param meta {name: string?, enabled: boolean?}
local function onSetMeta(meta)
    if not parent or parent.activeEditor ~= M or type(meta) ~= "table" then return end
    if type(meta.name) == "string" then M.name = meta.name:sub(1, 40) end
    if meta.enabled ~= nil then M.enabled = meta.enabled == true end
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
        id = M.arenaId,
        name = M.name,
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
        props = M.props,
    }
    beamjoy_communications.send("hunterArenaSave", payload)
    beamjoy_communications.addOneUseHandler("hunterArenaSaved", function(status, err, id)
        if status then
            -- a brand-new arena is told which id it got, so the next save replaces it instead of
            -- adding another copy
            M.arenaId = tonumber(id) or M.arenaId
            listEditor.clearDirty()
            pushMeta()
        else
            -- Real bug (same fix as infectedEditor.lua's own onSave): a rejected save used to
            -- leave this editor showing the attempted, never-actually-committed edit forever - the
            -- server keeps its last valid arena untouched on rejection, but nothing here reflected
            -- that. refresh() re-pulls enabled/defaults/every point list straight from the real
            -- synced arena (beamjoy_hunter.getArena), making this editor honest again instead of
            -- just stuck dirty. A new arena the server refused has nothing saved to fall back to,
            -- so it stays on screen with its edits (and its name problem) to be fixed.
            if M.arenaId then load(beamjoy_hunter.getArena(M.arenaId)) end
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
    beamjoy_communications_ui.addHandler("BJEditorHunterArenaPick", onSelectArena)
    beamjoy_communications_ui.addHandler("BJEditorHunterArenaNew", onNewArena)
    beamjoy_communications_ui.addHandler("BJEditorHunterArenaRemove", onDeleteArena)
    beamjoy_communications_ui.addHandler("BJEditorHunterArenaSetMeta", onSetMeta)
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
-- the props' placing (per frame) and the Delete key
M.onUpdate = listEditor.onUpdate
M.onBJEditorDeleteKey = listEditor.onDeleteKey
M.onBJHunterArenaChanged = onArenaChanged

return M
