--- In-world editor for freeroam energy stations + garages. A thin wrapper around the shared
--- `pointListEditor.lua` toolkit (exactly like hunterEditor / infectedEditor), for two
--- named, radius-only point lists. No enabled toggle, no gameplay defaults - a station or garage
--- is simply present or not. Per-station fuel-type overrides aren't editable here yet (an empty
--- type list means the standard pump set - see services/freeroamData.lua) ; `types` on an existing
--- point rides through untouched.
---
--- Registered as a slot in `activityEditor.lua`'s `editors` array. Saves the two lists to their
--- own server activity types (`energyStationsSave` / `garagesSave`).

local pointListEditor = require("ge/extensions/beamjoy/ui/pointListEditor")

---@class BJActivityEditorStation: BJActivityEditor
local M = {}
---@type BJActivityEditorCommon?
local parent

local listEditor = pointListEditor.new({
    lists = {
        {
            key = "energyStations",
            labelKey = "beamjoy.window.config.tabs.freeroam.station",
            color = BJColor(.2, 1, .3, .8),
            hasRadius = true,
            hasName = true,
            defaultRadius = 5,
        },
        {
            key = "garages",
            labelKey = "beamjoy.window.config.tabs.freeroam.garage",
            color = BJColor(1, .55, .1, .8),
            hasRadius = true,
            hasName = true,
            defaultRadius = 5,
        },
    },
    events = {
        listsUpdate = "BJEditorFreeroamListsUpdate",
        activeUpdate = "BJEditorFreeroamActiveUpdate",
        select = "BJEditorFreeroamSelect",
        create = "BJEditorFreeroamCreate",
        delete = "BJEditorFreeroamDelete",
        setToVehicle = "BJEditorFreeroamSetToVehicle",
        teleportTo = "BJEditorFreeroamTeleportTo",
        setRadius = "BJEditorFreeroamSetRadius",
        setName = "BJEditorFreeroamSetName",
        snapToGround = "BJEditorFreeroamSnapToGround",
        snapMethod = "BJEditorFreeroamSnapMethod",
        setSnapToGround = "BJEditorFreeroamSetSnapToGround",
        setSnapMethod = "BJEditorFreeroamSetSnapMethod",
        requestState = "BJEditorFreeroamRequestState",
    },
    isActive = function() return parent ~= nil and parent.activeEditor == M end,
})

--- (re)loads both point lists from beamjoy_freeroamData's current snapshot. Shared by onOpen and
--- onDataChanged (a save landing, or a server-side write while this editor is already up).
local function refresh()
    local data = beamjoy_freeroamData.data or {}
    listEditor.open({
        energyStations = table.map(data.stations or {}, function(s)
            return { pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z }, radius = s.radius,
                name = s.name, types = s.types }
        end),
        garages = table.map(data.garages or {}, function(g)
            return { pos = { x = g.pos.x, y = g.pos.y, z = g.pos.z }, radius = g.radius, name = g.name }
        end),
    })
end

local function onOpen()
    if not parent then return end
    if parent.activeEditor and parent.activeEditor ~= M then
        parent.activeEditor.onClose()
    end
    parent.activeEditor = M
    beamjoy_communications_ui.send("BJEditorChangeTool", gizmo.tool)
    -- suppress the live in-world markers + prompt while editing (beamjoy_stations listens)
    extensions.hook("onBJStationEditorState", true)
    refresh()
end

--- fired via extensions.hook("onBJFreeroamDataChanged") whenever a fresh stations/garages cache
--- lands. Only refreshes while this editor is the one on screen. Same "never asks, accepted rare
--- edge case for a truly in-progress edit" reasoning as hunterEditor.onArenaChanged.
local function onDataChanged()
    if not parent or parent.activeEditor ~= M then return end
    refresh()
end

---@param item table {pos, radius, name?, types?}
---@return table
local function prep(item)
    local rounded = math.roundPosRotDirUp({ pos = vec3(item.pos.x, item.pos.y, item.pos.z) })
    return {
        pos = { x = rounded.pos.x, y = rounded.pos.y, z = rounded.pos.z },
        radius = math.round(item.radius or 5, 2),
        name = item.name,
        types = item.types,
    }
end

local function onSave()
    if not parent then return end
    local lists = listEditor.getLists()

    beamjoy_communications.send("energyStationsSave", table.map(lists.energyStations or {}, prep))
    beamjoy_communications.addOneUseHandler("energyStationsSaved", function(status, err)
        if not status then
            refresh()
            toast.error(err or "Failed to save stations")
        end
    end, 5000)

    beamjoy_communications.send("garagesSave", table.map(lists.garages or {}, prep))
    beamjoy_communications.addOneUseHandler("garagesSaved", function(status, err)
        if not status then
            refresh()
            toast.error(err or "Failed to save garages")
        end
    end, 5000)

    -- optimistic : a rejected save's own ack above calls refresh(), which re-opens the list editor
    -- clean against the real synced data (and resets its dirty flag), so this is safe to clear now
    listEditor.clearDirty()
end

---@param activityEditor BJActivityEditorCommon
local function onInit(activityEditor)
    parent = activityEditor
    listEditor.onInit()

    beamjoy_communications_ui.addHandler("BJEditorFreeroamOpen", onOpen)
    beamjoy_communications_ui.addHandler("BJEditorFreeroamClose", parent.onClose)
    beamjoy_communications_ui.addHandler("BJEditorFreeroamSave", onSave)
end

local function onClose()
    if not parent then return end
    if parent.activeEditor == M then
        listEditor.close()
        extensions.hook("onBJStationEditorState", false)
    end
end

M.onInit = onInit
M.onClose = onClose
M.onBJClick = listEditor.onBJClick
M.onBJFreeroamDataChanged = onDataChanged

return M
