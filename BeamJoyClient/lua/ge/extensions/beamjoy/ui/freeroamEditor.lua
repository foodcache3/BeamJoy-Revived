--- In-world editor for the Config > Freeroam tab. Owns the single `activityEditor.activeEditor`
--- slot for that tab and hosts two sections:
---   - "stations"  : energy stations + garages, via the shared `pointListEditor.lua` toolkit
---                   (two named, radius-only point lists). Saves to `energyStationsSave` /
---                   `garagesSave`.
---   - "buslines"  : ordered line -> ordered stop editing, via `busLineEditor.lua` (a sub-module,
---                   NOT its own activityEditor slot). Saves to `busLinesSave`.
---
--- The Angular side (windows/config/freeroam) shows one section at a time and sends
--- `BJEditorFreeroamSection`. Only the live section mutates (each sub-editor guards on an isActive
--- predicate that checks both `activeEditor == M` AND the current section). Switching sections is
--- blocked Angular-side while there are unsaved changes, so only ever one section is dirty at once
--- and Save just saves the live one.
---
--- (Was `stationEditor.lua` - renamed when bus lines landed, since it's no longer stations-only.)

local pointListEditor = require("ge/extensions/beamjoy/ui/pointListEditor")
local busLineEditor = require("ge/extensions/beamjoy/ui/busLineEditor")

---@class BJActivityEditorFreeroam: BJActivityEditor
local M = {}
---@type BJActivityEditorCommon?
local parent
---@type "stations"|"buslines"
local section = "stations"

local stationsList = pointListEditor.new({
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
    isActive = function() return parent ~= nil and parent.activeEditor == M and section == "stations" end,
})

-- STATIONS SECTION ------------------------------------------------------------------------

--- (re)loads both station point lists from beamjoy_freeroamData's current snapshot
local function refreshStations()
    local data = beamjoy_freeroamData.data or {}
    stationsList.open({
        energyStations = table.map(data.stations or {}, function(s)
            return { pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z }, radius = s.radius,
                name = s.name, types = s.types }
        end),
        garages = table.map(data.garages or {}, function(g)
            return { pos = { x = g.pos.x, y = g.pos.y, z = g.pos.z }, radius = g.radius, name = g.name }
        end),
    })
end

---@param item table {pos, radius, name?, types?}
---@return table
local function prepStation(item)
    local rounded = math.roundPosRotDirUp({ pos = vec3(item.pos.x, item.pos.y, item.pos.z) })
    return {
        pos = { x = rounded.pos.x, y = rounded.pos.y, z = rounded.pos.z },
        radius = math.round(item.radius or 5, 2),
        name = item.name,
        types = item.types,
    }
end

local function saveStations()
    local lists = stationsList.getLists()

    beamjoy_communications.send("energyStationsSave", table.map(lists.energyStations or {}, prepStation))
    beamjoy_communications.addOneUseHandler("energyStationsSaved", function(status, err)
        if not status then
            refreshStations()
            toast.error(err or "Failed to save stations")
        end
    end, 5000)

    beamjoy_communications.send("garagesSave", table.map(lists.garages or {}, prepStation))
    beamjoy_communications.addOneUseHandler("garagesSaved", function(status, err)
        if not status then
            refreshStations()
            toast.error(err or "Failed to save garages")
        end
    end, 5000)

    stationsList.clearDirty()
end

-- SECTION PLUMBING -----------------------------------------------------------------------

--- render whichever section is live ; the other one drops its gizmo and its world shapes get
--- cleared by the live section's own renderAll -> shape.reset
local function applySection()
    if section == "buslines" then
        busLineEditor.standUp()
    else
        busLineEditor.standDown()
        stationsList.reassert()
    end
end

local function onOpen()
    if not parent then return end
    if parent.activeEditor and parent.activeEditor ~= M then
        parent.activeEditor.onClose()
    end
    parent.activeEditor = M
    beamjoy_communications_ui.send("BJEditorChangeTool", gizmo.tool)
    -- suppress the live in-world station markers + prompt while the Freeroam editor is open
    -- (beamjoy_stations listens), regardless of which section
    extensions.hook("onBJStationEditorState", true)
    refreshStations()
    busLineEditor.refresh()
    applySection()
end

---@param s string
local function onSetSection(s)
    if not parent or parent.activeEditor ~= M then return end
    section = (s == "buslines") and "buslines" or "stations"
    applySection()
end

--- fired via onBJFreeroamDataChanged (stations/garages cache landed)
local function onDataChanged()
    if not parent or parent.activeEditor ~= M then return end
    refreshStations()
    applySection()
end

--- fired via onBJBusLinesChanged (bus-lines cache landed)
local function onBusLinesChanged()
    if not parent or parent.activeEditor ~= M then return end
    busLineEditor.refresh()
    if section == "buslines" then busLineEditor.standUp() end
end

local function onSave()
    if not parent then return end
    if section == "buslines" then
        busLineEditor.save()
    else
        saveStations()
    end
end

---@param activityEditor BJActivityEditorCommon
local function onInit(activityEditor)
    parent = activityEditor
    stationsList.onInit()
    busLineEditor.setActivePredicate(function()
        return parent ~= nil and parent.activeEditor == M and section == "buslines"
    end)
    busLineEditor.onInit()

    beamjoy_communications_ui.addHandler("BJEditorFreeroamOpen", onOpen)
    beamjoy_communications_ui.addHandler("BJEditorFreeroamClose", M.onClose)
    beamjoy_communications_ui.addHandler("BJEditorFreeroamSave", onSave)
    beamjoy_communications_ui.addHandler("BJEditorFreeroamSection", onSetSection)
end

local function onClose()
    if not parent then return end
    if parent.activeEditor == M then parent.activeEditor = nil end
    stationsList.close()
    busLineEditor.close()
    extensions.hook("onBJStationEditorState", false)
end

---@param clickType string
---@param data table
local function onBJClick(clickType, data)
    if section == "buslines" then
        busLineEditor.onBJClick(clickType, data)
    else
        stationsList.onBJClick(clickType, data)
    end
end

M.onInit = onInit
M.onClose = onClose
M.onBJClick = onBJClick
M.onBJFreeroamDataChanged = onDataChanged
M.onBJBusLinesChanged = onBusLinesChanged

return M
