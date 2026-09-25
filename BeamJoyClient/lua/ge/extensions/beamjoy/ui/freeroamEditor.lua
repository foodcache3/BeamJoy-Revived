--- In-world editor for the Config > Freeroam tab. Owns the single `activityEditor.activeEditor`
--- slot for that tab and hosts two sections:
---   - "stations"  : energy stations (with their own pumps) + garages, via the dedicated
---                   `stationsEditor.lua` sub-module. Saves to `energyStationsSave` / `garagesSave`.
---   - "buslines"  : ordered line -> ordered stop editing, via `busLineEditor.lua` (a sub-module,
---                   NOT its own activityEditor slot). Saves to `busLinesSave`.
---   - "deliveries": delivery points + their vehicle start slots, via `deliveryEditor.lua`.
---                   Saves to `deliveryPointsSave` (after measuring route lengths).
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
local deliveryEditor = require("ge/extensions/beamjoy/ui/deliveryEditor")

---@class BJActivityEditorFreeroam: BJActivityEditor
local M = {}
---@type BJActivityEditorCommon?
local parent
---@type "stations"|"buslines"|"deliveries"
local section = "stations"

--- section name -> its sub-editor (the Angular side owns the display order)
local SECTIONS = {
    stations = stationsEditor,
    buslines = busLineEditor,
    deliveries = deliveryEditor,
}

-- SECTION PLUMBING -----------------------------------------------------------------------

--- render whichever section is live ; the other one drops its gizmo and its world shapes get
--- cleared by the live section's own renderAll -> shape.reset
local function applySection()
    for name, editor in pairs(SECTIONS) do
        if name ~= section then editor.standDown() end
    end
    SECTIONS[section].standUp()
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
    deliveryEditor.refresh()
    applySection()
end

---@param s string
local function onSetSection(s)
    if not parent or parent.activeEditor ~= M then return end
    section = SECTIONS[s] and s or "stations"
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

--- fired via onBJDeliveryPointsChanged (delivery points cache landed)
local function onDeliveryPointsChanged()
    if not parent or parent.activeEditor ~= M then return end
    deliveryEditor.refresh()
    if section == "deliveries" then deliveryEditor.standUp() end
end

local function onSave()
    if not parent then return end
    SECTIONS[section].save()
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
    deliveryEditor.setActivePredicate(function()
        return parent ~= nil and parent.activeEditor == M and section == "deliveries"
    end)
    deliveryEditor.onInit()

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
    deliveryEditor.close()
    -- real, confirmed bug : none of the sub-editors clear the world labels/markers on close
    -- (switching SECTIONS did, via the next section's own renderAll), so leaving the Freeroam tab
    -- for another config tab left every point's name floating in the world. The running bus line /
    -- delivery (which share this shape buffer) redraw their own target on the hook below.
    shape.reset()
    -- the Angular tab always reopens on its first section ; match it
    section = "stations"
    extensions.hook("onBJStationEditorState", false)
end

---@param clickType string
---@param data table
local function onBJClick(clickType, data)
    SECTIONS[section].onBJClick(clickType, data)
end

M.onInit = onInit
M.onClose = onClose
M.onBJClick = onBJClick
M.onBJFreeroamDataChanged = onDataChanged
M.onBJBusLinesChanged = onBusLinesChanged
M.onBJDeliveryPointsChanged = onDeliveryPointsChanged

return M
