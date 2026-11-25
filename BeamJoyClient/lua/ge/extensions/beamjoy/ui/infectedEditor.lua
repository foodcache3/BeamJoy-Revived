--- In-world Infected arena editor. A thin host wrapper around the shared `pointListEditor.lua`
--- toolkit, exactly mirroring `hunterEditor.lua`'s own shape for the two point-lists (survivor
--- spawns, infected spawns). Owns only what's genuinely Infected-specific on top of that : the
--- `enabled` toggle, gameplay `defaults`, and the final combined save payload. Registered as a
--- slot in `activityEditor.lua`'s `editors` array.
---
--- A map holds several arenas, so this edits one of them at a time (picked from a list, or a new
--- one), each saved and deleted on its own, same as hunterEditor.lua and derbyEditor.lua.

local pointListEditor = require("ge/extensions/beamjoy/ui/pointListEditor")

---@class BJActivityEditorInfected: BJActivityEditor
local M = {
    ---@type integer? the arena being edited ; nil for a new one not saved yet
    arenaId = nil,
    name = "",
    enabled = false,
    ---@type BJInfectedDefaults
    defaults = {},
    --- the arena's props (direct request : props in Infected as in races), edited by the props
    --- editor (ui/propEditor.lua) through the list editor
    ---@type table[]
    props = {},
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
    props = function() return M.props end,
})

local function pushMeta()
    beamjoy_communications_ui.send("BJEditorInfectedArenaMetaUpdate", {
        arenas = table.map(beamjoy_infected.data or {}, function(a)
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
---@param arena BJInfectedArena?
---@param keepSelection boolean? the same arena again (it was just saved) : the selected point stays
local function load(arena, keepSelection)
    M.blank = arena == nil
    arena = arena or {}
    M.arenaId = arena.id
    M.name = arena.name or ""
    M.enabled = arena.enabled == true
    M.defaults = table.clone(arena.defaults or {})
    M.props = table.isArray(arena.props) and table.clone(arena.props) or {}
    listEditor.open({
        survivorSpawns = arena.survivorSpawns,
        infectedSpawns = arena.infectedSpawns,
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
    local arena = M.arenaId and beamjoy_infected.getArena(M.arenaId) or (beamjoy_infected.data or {})[1]
    load(arena)
end

--- fired via extensions.hook("onBJInfectedArenaChanged") (see infected.lua's retrieveCache)
--- whenever a fresh arena list lands from the server. Same shape as hunterEditor.lua's own
--- onArenaChanged : the list always refreshes, the arena being edited only when it's clean.
local function onArenaChanged()
    if not parent or parent.activeEditor ~= M then return end
    if listEditor.isDirty() then return pushMeta() end
    local arena = M.arenaId and beamjoy_infected.getArena(M.arenaId)
    if arena then
        load(arena, true)
    elseif M.arenaId then
        load((beamjoy_infected.data or {})[1])
    else
        pushMeta()
    end
end

---@param id integer
local function onSelectArena(id)
    if not parent or parent.activeEditor ~= M then return end
    load(beamjoy_infected.getArena(tonumber(id)))
end

local function onNewArena()
    if not parent or parent.activeEditor ~= M then return end
    load({ name = beamjoy_lang.translate("beamjoy.window.config.tabs.infectedArena.newName") })
    listEditor.markDirty()
end

local function onDeleteArena()
    if not parent or parent.activeEditor ~= M then return end
    if not M.arenaId then
        return load((beamjoy_infected.data or {})[1])
    end
    local deleted = M.arenaId
    beamjoy_communications.send("infectedArenaDelete", deleted)
    load(table.find(beamjoy_infected.data or {}, function(a) return a.id ~= deleted end))
end

---@param meta {name: string?, enabled: boolean?}
local function onSetMeta(meta)
    if not parent or parent.activeEditor ~= M or type(meta) ~= "table" then return end
    if type(meta.name) == "string" then M.name = meta.name:sub(1, 40) end
    if meta.enabled ~= nil then M.enabled = meta.enabled == true end
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
        id = M.arenaId,
        name = M.name,
        enabled = M.enabled,
        survivorSpawns = table.map(lists.survivorSpawns, math.roundPosRotDirUp),
        infectedSpawns = table.map(lists.infectedSpawns, math.roundPosRotDirUp),
        defaults = M.defaults,
        props = M.props,
    }
    beamjoy_communications.send("infectedArenaSave", payload)
    beamjoy_communications.addOneUseHandler("infectedArenaSaved", function(status, err, id)
        if status then
            -- a brand-new arena is told which id it got, so the next save replaces it
            M.arenaId = tonumber(id) or M.arenaId
            listEditor.clearDirty()
            pushMeta()
        else
            -- Real bug: a rejected save (e.g. enabling with too few spawns) used to leave this
            -- editor showing the attempted, never-actually-committed edit forever - the server
            -- keeps its last valid arena untouched on rejection, but nothing here reflected that,
            -- so the editor could show an impossible "enabled" + empty-spawn-list combination that
            -- never actually existed server-side. refresh() re-pulls enabled/defaults/both spawn
            -- lists straight from the real synced arena (beamjoy_infected.getArena), making
            -- this editor honest again instead of just stuck dirty. A new arena the server refused
            -- has nothing saved to fall back to, so it stays on screen with its edits.
            if M.arenaId then load(beamjoy_infected.getArena(M.arenaId)) end
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
    beamjoy_communications_ui.addHandler("BJEditorInfectedArenaPick", onSelectArena)
    beamjoy_communications_ui.addHandler("BJEditorInfectedArenaNew", onNewArena)
    beamjoy_communications_ui.addHandler("BJEditorInfectedArenaRemove", onDeleteArena)
    beamjoy_communications_ui.addHandler("BJEditorInfectedArenaSetMeta", onSetMeta)
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
-- the props' placing (per frame) and the Delete key
M.onUpdate = listEditor.onUpdate
M.onBJEditorDeleteKey = listEditor.onDeleteKey
M.onBJInfectedArenaChanged = onArenaChanged

return M
