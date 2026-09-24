--- In-world editor for the Config > Freeroam tab. Owns the single `activityEditor.activeEditor`
--- slot for that tab and hosts two sections:
---   - "stations"  : energy stations (with their own pumps) + garages, via the dedicated
---                   `stationsEditor.lua` sub-module. Saves to `energyStationsSave` / `garagesSave`.
---   - "buslines"  : ordered line -> ordered stop editing, via `busLineEditor.lua` (a sub-module,
---                   NOT its own activityEditor slot). Saves to `busLinesSave`.
---
--- Energy stations + garages moved OUT of the shared, flat `pointListEditor.lua` instance and into
--- their own dedicated `stationsEditor.lua` sub-module (mirroring busLineEditor.lua's own split)
--- per direct request : a station can now carry individual pumps/chargers, each its own real
--- position with its own fuel type(s) - a 2-level shape (station -> unordered pump list) the flat
--- pointListEditor deliberately doesn't model. Garages moved along with it (not pumps-capable
--- themselves) purely so both keep sharing ONE shape.lua render/reset cycle - see
--- stationsEditor.lua's own file header for why that matters.
---
--- The Angular side (windows/config/freeroam) shows one section at a time and sends
--- `BJEditorFreeroamSection`. Only the live section mutates (each sub-editor guards on an isActive
--- predicate that checks both `activeEditor == M` AND the current section). Switching sections is
--- blocked Angular-side while there are unsaved changes, so only ever one section is dirty at once
--- and Save just saves the live one.
---
--- (Was `stationEditor.lua` - renamed when bus lines landed, since it's no longer stations-only.)

local stationsEditor = require("ge/extensions/beamjoy/ui/stationsEditor")
local busLineEditor = require("ge/extensions/beamjoy/ui/busLineEditor")

---@class BJActivityEditorFreeroam: BJActivityEditor
local M = {}
---@type BJActivityEditorCommon?
local parent
---@type "stations"|"buslines"
local section = "stations"

-- SECTION PLUMBING -----------------------------------------------------------------------

--- render whichever section is live ; the other one drops its gizmo and its world shapes get
--- cleared by the live section's own renderAll -> shape.reset
local function applySection()
    if section == "buslines" then
        stationsEditor.standDown()
        busLineEditor.standUp()
    else
        busLineEditor.standDown()
        stationsEditor.standUp()
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
    stationsEditor.refresh()
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
    stationsEditor.refresh()
    if section == "stations" then stationsEditor.standUp() end
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
        stationsEditor.save()
    end
end

---@param activityEditor BJActivityEditorCommon
local function onInit(activityEditor)
    parent = activityEditor
    stationsEditor.setActivePredicate(function()
        return parent ~= nil and parent.activeEditor == M and section == "stations"
    end)
    stationsEditor.onInit()
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
    stationsEditor.close()
    busLineEditor.close()
    extensions.hook("onBJStationEditorState", false)
end

---@param clickType string
---@param data table
local function onBJClick(clickType, data)
    if section == "buslines" then
        busLineEditor.onBJClick(clickType, data)
    else
        stationsEditor.onBJClick(clickType, data)
    end
end

M.onInit = onInit
M.onClose = onClose
M.onBJClick = onBJClick
M.onBJFreeroamDataChanged = onDataChanged
M.onBJBusLinesChanged = onBusLinesChanged

return M
