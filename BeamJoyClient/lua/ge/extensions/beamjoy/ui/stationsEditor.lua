--- In-world editor for the Config > Freeroam tab's "Stations & Garages" section. NOT a standalone
--- `activityEditor` slot - a sub-module hosted by `freeroamEditor.lua`, same as `busLineEditor.lua`
--- is for the "Bus Lines" section.
---
--- Owns BOTH energy stations and garages together, in one render/state/save cycle - NOT split
--- across two independent renderers (an earlier draft tried that: one dedicated stations-only
--- module + the existing generic `pointListEditor.lua` instance for garages). Real, caught-before-
--- shipping problem with that split : `shape.lua` is one single global shape buffer, and every
--- renderer in this codebase clears it wholesale (`shape.reset()`) before drawing its own content.
--- Two independent renderers both wanting to stay visible AT THE SAME TIME (stations and garages
--- are shown side by side in one section, never tab-switched apart like Bus Lines is) would
--- constantly wipe each other's shapes out on every mutation, whichever one's gizmo/CRUD callback
--- happened to fire last. One owner, one shape.reset(), one combined draw pass avoids that
--- entirely - the same reason busLineEditor.lua and this module are never both live either (THAT
--- split is fine, because Bus Lines and Stations are genuinely tab-switched, never both visible).
---
--- Stations are a 2-level shape (a station, with an unordered sub-list of pumps/chargers - each
--- its own real position + fuel type(s), per direct request) `pointListEditor.lua` deliberately
--- doesn't model (flat lists only - see its own file header). Garages stay flat/plain (no pumps),
--- but get their own small dedicated CRUD here too now rather than pointListEditor.lua, for the
--- rendering reason above - the two lists share `GENERIC` helpers below so that duplication is
--- name/radius/position plumbing only, not gizmo/render/save logic repeated per list.
---
--- Server side: services/freeroamData.lua (`<map>_stations.json` / `<map>_garages.json>`).

---@class BJEnergyStationEdit
---@field id integer?
---@field name string
---@field pos {x:number, y:number, z:number}
---@field radius number
---@field types string[]
---@field pumps BJEnergyPumpEdit[]

---@class BJEnergyPumpEdit
---@field pos {x:number, y:number, z:number}
---@field radius number
---@field types string[]

---@class BJGarageEdit
---@field id integer?
---@field name string
---@field pos {x:number, y:number, z:number}
---@field radius number

local M = {}

local ACTIVE_COLOR = BJColor(1, 1, 1, .9)
local STATION_COLOR = BJColor(.2, 1, .3, .8)
local DIM_STATION_COLOR = BJColor(.2, 1, .3, .35)
local PUMP_COLOR = BJColor(.3, .8, 1, .8)
local GARAGE_COLOR = BJColor(1, .55, .1, .8)
local DIM_GARAGE_COLOR = BJColor(1, .55, .1, .35)
local TEXT_BG = BJColor(0, 0, 0, .3)

local DEFAULT_RADIUS = 5
local MIN_RADIUS = 1
local MAX_RADIUS = 50
local MAX_NAME_LEN = 40

--- freeroamEditor injects "is this section live right now" ; every mutation guards on it
---@type fun(): boolean
local isActive = function() return false end

local state = {
    ---@type BJEnergyStationEdit[]
    stations = {},
    ---@type BJGarageEdit[]
    garages = {},
    --- "stations"|"garages"|nil
    ---@type string?
    activeList = nil,
    ---@type integer?
    activeIndex = nil,
    --- only meaningful when activeList == "stations" ; nil = the station itself is selected
    --- (gizmo edits its own pos), an integer = that pump of the active station instead
    ---@type integer?
    activePump = nil,
    dirty = false,
    loaded = false,
    snapToGroundEnabled = true,
    ---@type "terrain"|"raycast"
    snapMethod = "terrain",
}

-- WIRE ------------------------------------------------------------------------------------------

local function pushLists()
    beamjoy_communications_ui.send("BJEditorStationsListUpdate",
        { stations = state.stations, garages = state.garages })
end

local function pushActive()
    beamjoy_communications_ui.send("BJEditorStationsActiveUpdate",
        { list = state.activeList, index = state.activeIndex, pump = state.activePump })
end

local function pushFullState()
    pushLists()
    pushActive()
    beamjoy_communications_ui.send("BJEditorDirty", state.dirty)
    beamjoy_communications_ui.send("BJEditorStationsSnapToGround", state.snapToGroundEnabled)
    beamjoy_communications_ui.send("BJEditorStationsSnapMethod", state.snapMethod)
end

local function markDirty()
    if not state.dirty then
        state.dirty = true
        beamjoy_communications_ui.send("BJEditorDirty", true)
    end
end

-- GEOMETRY HELPERS ----------------------------------------------------------------------------

---@param pos vec3
---@return number
local function groundHeightAt(pos)
    if state.snapMethod ~= "raycast" then
        local h = core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(pos)
        if h then return h end
    end
    return be:getSurfaceHeightBelow(pos + vec3(0, 0, 10))
end

--- mirrors busLineEditor.lua's own currentPosition (no facing needed for a station/garage/pump)
---@return vec3?
local function currentPosition()
    local currVeh = beamjoy_vehicles.getCurrent()
    local pos
    if not currVeh or camera.getCamera() == camera.CAMERAS.FREE then
        pos = camera.getPositionRotation(false)
    else
        pos = beamjoy_vehicles.getVehiclePositionRotation(currVeh.veh)
    end
    if not pos then return nil end
    if state.snapToGroundEnabled then
        pos = vec3(pos.x, pos.y, groundHeightAt(pos))
    end
    return pos
end

---@param list string "stations"|"garages"
---@return table[]
local function listOf(list) return state[list] end

-- RENDER ------------------------------------------------------------------------------------

local function renderAll()
    shape.reset()

    for gi, garage in ipairs(state.garages) do
        local active = state.activeList == "garages" and state.activeIndex == gi
        local label = (type(garage.name) == "string" and #garage.name > 0)
            and garage.name or string.format("%s %d", beamjoy_lang.translate("beamjoy.window.config.tabs.freeroam.garage"), gi)
        local color = active and ACTIVE_COLOR or (state.activeList == "garages" and GARAGE_COLOR or DIM_GARAGE_COLOR)
        local p = vec3(garage.pos.x, garage.pos.y, garage.pos.z)
        local radius = math.max(MIN_RADIUS, tonumber(garage.radius) or DEFAULT_RADIUS)
        shape.addSphere(p, radius, color)
        shape.addText(label, p + vec3(0, 0, radius + 1), color, TEXT_BG)
    end

    for si, station in ipairs(state.stations) do
        local activeStation = state.activeList == "stations" and state.activeIndex == si
        local label = (type(station.name) == "string" and #station.name > 0)
            and station.name or string.format("%s %d", beamjoy_lang.translate("beamjoy.window.config.tabs.freeroam.station"), si)

        if not activeStation then
            local p = vec3(station.pos.x, station.pos.y, station.pos.z)
            shape.addSphere(p, 1, DIM_STATION_COLOR)
            shape.addText(label, p + vec3(0, 0, 2), DIM_STATION_COLOR, TEXT_BG)
        else
            local stationSelected = state.activePump == nil
            local color = stationSelected and ACTIVE_COLOR or STATION_COLOR
            local p = vec3(station.pos.x, station.pos.y, station.pos.z)
            local radius = math.max(MIN_RADIUS, tonumber(station.radius) or DEFAULT_RADIUS)
            shape.addSphere(p, radius, color)
            shape.addText(label, p + vec3(0, 0, radius + 1), color, TEXT_BG)

            for pi, pump in ipairs(station.pumps or {}) do
                local pumpSelected = state.activePump == pi
                local pumpColor = pumpSelected and ACTIVE_COLOR or PUMP_COLOR
                local pp = vec3(pump.pos.x, pump.pos.y, pump.pos.z)
                local pumpRadius = math.max(MIN_RADIUS, tonumber(pump.radius) or DEFAULT_RADIUS)
                shape.addSphere(pp, pumpRadius, pumpColor)
                shape.addText(string.format("%s %d", beamjoy_lang.translate("beamjoy.stations.pump"), pi),
                    pp + vec3(0, 0, pumpRadius + 1), pumpColor, TEXT_BG)
                shape.addLine(p + vec3(0, 0, .3), .2, pp + vec3(0, 0, .3), .2, pumpColor)
            end
        end
    end
end

local function updateGizmo()
    gizmo.hide()
    if not state.activeList then return end
    local item = state[state.activeList][state.activeIndex]
    if not item then return end
    local target = item
    if state.activeList == "stations" and state.activePump then
        target = item.pumps[state.activePump]
        if not target then return end
    end
    gizmo.show({
        pos = vec3(target.pos.x, target.pos.y, target.pos.z),
        dir = vec3(1, 0, 0), -- no facing on a station/garage/pump - fixed, unused visually
        up = vec3(0, 0, 1),
        scales = vec3(1, 1, 1), -- radius is Angular-side, not the native scale tool
    }, function(updated)
        if not isActive() then return end
        target.pos = { x = updated.pos.x, y = updated.pos.y, z = updated.pos.z }
        renderAll()
        markDirty()
    end, function()
        if state.snapToGroundEnabled then
            target.pos.z = groundHeightAt(vec3(target.pos.x, target.pos.y, target.pos.z))
            renderAll()
            updateGizmo()
        end
        pushLists()
    end)
end

-- SELECTION -----------------------------------------------------------------------------

---@param list string?
---@param index integer?
local function onSelectItem(list, index)
    if not isActive() then return end
    index = tonumber(index)
    if list == "stations" or list == "garages" then
        if index and listOf(list)[index] then
            if state.activeList == list and state.activeIndex == index then
                state.activeList, state.activeIndex = nil, nil
            else
                state.activeList, state.activeIndex = list, index
            end
        else
            state.activeList, state.activeIndex = nil, nil
        end
    else
        state.activeList, state.activeIndex = nil, nil
    end
    state.activePump = nil
    renderAll()
    updateGizmo()
    pushActive()
end

---@param si integer
---@param pi integer
local function onSelectPump(si, pi)
    if not isActive() then return end
    si, pi = tonumber(si), tonumber(pi)
    local station = si and state.stations[si]
    if not station or not station.pumps[pi] then return end
    state.activeList, state.activeIndex = "stations", si
    state.activePump = (state.activePump == pi) and nil or pi
    renderAll()
    updateGizmo()
    pushActive()
end

-- GENERIC STATION/GARAGE CRUD ------------------------------------------------------------

---@param list string
local function onAddItem(list)
    if not isActive() then return end
    if list ~= "stations" and list ~= "garages" then return end
    local pos = currentPosition()
    if not pos then return end
    local item = { name = "", pos = { x = pos.x, y = pos.y, z = pos.z }, radius = DEFAULT_RADIUS }
    if list == "stations" then
        item.types, item.pumps = {}, {}
    end
    table.insert(listOf(list), item)
    state.activeList, state.activeIndex, state.activePump = list, #listOf(list), nil
    renderAll()
    updateGizmo()
    pushLists()
    pushActive()
    markDirty()
end

---@param list string
---@param index integer
local function onDeleteItem(list, index)
    if not isActive() then return end
    index = tonumber(index)
    if (list ~= "stations" and list ~= "garages") or not index or not listOf(list)[index] then return end
    table.remove(listOf(list), index)
    if state.activeList == list then
        state.activeList, state.activeIndex, state.activePump = nil, nil, nil
    end
    renderAll()
    updateGizmo()
    pushLists()
    pushActive()
    markDirty()
end

---@param list string
---@param index integer
---@param name string
local function onSetItemName(list, index, name)
    if not isActive() then return end
    index = tonumber(index)
    local item = index and (list == "stations" or list == "garages") and listOf(list)[index]
    if not item then return end
    name = type(name) == "string" and name or ""
    if #name > MAX_NAME_LEN then name = name:sub(1, MAX_NAME_LEN) end
    item.name = name
    renderAll()
    markDirty()
end

---@param list string
---@param index integer
---@param radius number
local function onSetItemRadius(list, index, radius)
    if not isActive() then return end
    index = tonumber(index)
    local item = index and (list == "stations" or list == "garages") and listOf(list)[index]
    if not item then return end
    item.radius = math.max(MIN_RADIUS, math.min(MAX_RADIUS, tonumber(radius) or item.radius))
    renderAll()
    if state.activeList == list and state.activeIndex == index and state.activePump == nil then
        updateGizmo()
    end
    markDirty()
end

---@param list string
---@param index integer
local function onSetItemToVehicle(list, index)
    if not isActive() then return end
    index = tonumber(index)
    local item = index and (list == "stations" or list == "garages") and listOf(list)[index]
    if not item then return end
    local pos = currentPosition()
    if not pos then return end
    item.pos = { x = pos.x, y = pos.y, z = pos.z }
    renderAll()
    if state.activeList == list and state.activeIndex == index and state.activePump == nil then
        updateGizmo()
    end
    pushLists()
    markDirty()
end

---@param list string
---@param index integer
local function onTeleportToItem(list, index)
    if not isActive() then return end
    index = tonumber(index)
    local item = index and (list == "stations" or list == "garages") and listOf(list)[index]
    if not item then return end
    local current = beamjoy_vehicles.getCurrentOwn()
    if not current then return end
    beamjoy_vehicles.setVehiclePositionRotation(current.veh,
        vec3(item.pos.x, item.pos.y, item.pos.z), vec3(1, 0, 0), vec3(0, 0, 1))
end

---@param index integer
---@param types string[]
local function onSetStationTypes(index, types)
    if not isActive() then return end
    index = tonumber(index)
    local station = index and state.stations[index]
    if not station then return end
    station.types = table.isArray(types) and types or {}
    pushLists()
    markDirty()
end

-- PUMP CRUD -----------------------------------------------------------------------------

---@param si integer
local function onAddPump(si)
    if not isActive() then return end
    si = tonumber(si)
    local station = si and state.stations[si]
    if not station then return end
    local pos = currentPosition()
    if not pos then return end
    station.pumps = station.pumps or {}
    table.insert(station.pumps, { pos = { x = pos.x, y = pos.y, z = pos.z }, radius = DEFAULT_RADIUS, types = {} })
    state.activeList, state.activeIndex, state.activePump = "stations", si, #station.pumps
    renderAll()
    updateGizmo()
    pushLists()
    pushActive()
    markDirty()
end

---@param si integer
---@param pi integer
local function onDeletePump(si, pi)
    if not isActive() then return end
    si, pi = tonumber(si), tonumber(pi)
    local station = si and state.stations[si]
    if not station or not station.pumps[pi] then return end
    table.remove(station.pumps, pi)
    if state.activeList == "stations" and state.activeIndex == si then state.activePump = nil end
    renderAll()
    updateGizmo()
    pushLists()
    pushActive()
    markDirty()
end

---@param si integer
---@param pi integer
---@param radius number
local function onSetPumpRadius(si, pi, radius)
    if not isActive() then return end
    si, pi = tonumber(si), tonumber(pi)
    local station = si and state.stations[si]
    local pump = station and station.pumps[pi]
    if not pump then return end
    pump.radius = math.max(MIN_RADIUS, math.min(MAX_RADIUS, tonumber(radius) or pump.radius))
    renderAll()
    if state.activeList == "stations" and state.activeIndex == si and state.activePump == pi then
        updateGizmo()
    end
    markDirty()
end

---@param si integer
---@param pi integer
---@param types string[]
local function onSetPumpTypes(si, pi, types)
    if not isActive() then return end
    si, pi = tonumber(si), tonumber(pi)
    local station = si and state.stations[si]
    local pump = station and station.pumps[pi]
    if not pump then return end
    pump.types = table.isArray(types) and types or {}
    pushLists()
    markDirty()
end

---@param si integer
---@param pi integer
local function onSetPumpToVehicle(si, pi)
    if not isActive() then return end
    si, pi = tonumber(si), tonumber(pi)
    local station = si and state.stations[si]
    local pump = station and station.pumps[pi]
    if not pump then return end
    local pos = currentPosition()
    if not pos then return end
    pump.pos = { x = pos.x, y = pos.y, z = pos.z }
    renderAll()
    if state.activeList == "stations" and state.activeIndex == si and state.activePump == pi then
        updateGizmo()
    end
    pushLists()
    markDirty()
end

---@param si integer
---@param pi integer
local function onTeleportToPump(si, pi)
    if not isActive() then return end
    si, pi = tonumber(si), tonumber(pi)
    local station = si and state.stations[si]
    local pump = station and station.pumps[pi]
    if not pump then return end
    local current = beamjoy_vehicles.getCurrentOwn()
    if not current then return end
    beamjoy_vehicles.setVehiclePositionRotation(current.veh,
        vec3(pump.pos.x, pump.pos.y, pump.pos.z), vec3(1, 0, 0), vec3(0, 0, 1))
end

---@param enabled boolean
local function onSetSnapToGround(enabled)
    state.snapToGroundEnabled = enabled == true
    beamjoy_communications_ui.send("BJEditorStationsSnapToGround", state.snapToGroundEnabled)
end

---@param method string
local function onSetSnapMethod(method)
    state.snapMethod = method == "raycast" and "raycast" or "terrain"
    beamjoy_communications_ui.send("BJEditorStationsSnapMethod", state.snapMethod)
end

-- WORLD CLICK -----------------------------------------------------------------------------

--- click any station/garage to select it, or (only for the already-active station) one of ITS
--- pumps - mirrors busLineEditor.lua's own onBJClick (stations/garages here play the "lines" role,
--- pumps the "stops" role - always-clickable top-level items, pumps restricted to the active
--- station same as stops are restricted to the active line)
---@param clickType string
---@param data table
local function onBJClick(clickType, data)
    if clickType ~= "left" or not isActive() then return end
    local camPos, rayDir = camera.mouseRay()
    if not camPos then return end

    local bestList, bestIndex, bestAlong
    for _, list in ipairs({ "stations", "garages" }) do
        for i, item in ipairs(listOf(list)) do
            local p = vec3(item.pos.x, item.pos.y, item.pos.z)
            local along = (p - camPos):dot(rayDir)
            if along > 0 then
                local closest = camPos + rayDir * along
                local r = math.max(1.5, tonumber(item.radius) or DEFAULT_RADIUS)
                if closest:distance(p) <= r and (not bestAlong or along < bestAlong) then
                    bestList, bestIndex, bestAlong = list, i, along
                end
            end
        end
    end
    if bestList and not (bestList == state.activeList and bestIndex == state.activeIndex) then
        onSelectItem(bestList, bestIndex)
        return
    end

    if state.activeList ~= "stations" then return end
    local station = state.stations[state.activeIndex]
    if not station then return end
    local bestPump
    bestAlong = nil
    for pi, pump in ipairs(station.pumps or {}) do
        local p = vec3(pump.pos.x, pump.pos.y, pump.pos.z)
        local along = (p - camPos):dot(rayDir)
        if along > 0 then
            local closest = camPos + rayDir * along
            local r = math.max(1.5, tonumber(pump.radius) or DEFAULT_RADIUS)
            if closest:distance(p) <= r and (not bestAlong or along < bestAlong) then
                bestPump, bestAlong = pi, along
            end
        end
    end
    if bestPump and bestPump ~= state.activePump then
        onSelectPump(state.activeIndex, bestPump)
    end
end

-- HOST INTERFACE (called by freeroamEditor) ---------------------------------------------

---@param fn fun(): boolean
local function setActivePredicate(fn)
    isActive = fn or isActive
end

--- (re)load both lists from the synced cache. Keeps selection if still valid.
local function refresh()
    local data = beamjoy_freeroamData.data or {}
    state.stations = {}
    for _, s in ipairs(data.stations or {}) do
        local pumps = {}
        for _, p in ipairs(s.pumps or {}) do
            pumps[#pumps + 1] = {
                pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z },
                radius = p.radius or DEFAULT_RADIUS,
                types = table.isArray(p.types) and p.types or {},
            }
        end
        state.stations[#state.stations + 1] = {
            id = s.id,
            name = s.name or "",
            pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z },
            radius = s.radius or DEFAULT_RADIUS,
            types = table.isArray(s.types) and s.types or {},
            pumps = pumps,
        }
    end
    state.garages = {}
    for _, g in ipairs(data.garages or {}) do
        state.garages[#state.garages + 1] = {
            id = g.id,
            name = g.name or "",
            pos = { x = g.pos.x, y = g.pos.y, z = g.pos.z },
            radius = g.radius or DEFAULT_RADIUS,
        }
    end

    if not state.activeList or not listOf(state.activeList)[state.activeIndex] then
        state.activeList, state.activeIndex, state.activePump = nil, nil, nil
    elseif state.activeList == "stations" and state.activePump
        and not state.stations[state.activeIndex].pumps[state.activePump] then
        state.activePump = nil
    end
    state.dirty = false
    state.loaded = true
end

--- become the visible section : draw + push everything
local function standUp()
    renderAll()
    updateGizmo()
    pushFullState()
end

--- section switched away : drop the gizmo (shapes get cleared by the next section's own
--- renderAll -> shape.reset)
local function standDown()
    gizmo.hide()
end

local function close()
    gizmo.hide()
    state.stations, state.garages = {}, {}
    state.activeList, state.activeIndex, state.activePump = nil, nil, nil
    state.dirty = false
    state.loaded = false
end

---@param onDone fun(ok: boolean)?
local function save(onDone)
    local stationsPayload = {}
    for _, station in ipairs(state.stations) do
        local pumps = {}
        for _, p in ipairs(station.pumps or {}) do
            local rounded = math.roundPosRotDirUp({ pos = vec3(p.pos.x, p.pos.y, p.pos.z) })
            pumps[#pumps + 1] = {
                pos = { x = rounded.pos.x, y = rounded.pos.y, z = rounded.pos.z },
                radius = math.round(p.radius or DEFAULT_RADIUS, 2),
                types = p.types,
            }
        end
        local rounded = math.roundPosRotDirUp({ pos = vec3(station.pos.x, station.pos.y, station.pos.z) })
        stationsPayload[#stationsPayload + 1] = {
            id = station.id,
            name = station.name,
            pos = { x = rounded.pos.x, y = rounded.pos.y, z = rounded.pos.z },
            radius = math.round(station.radius or DEFAULT_RADIUS, 2),
            types = station.types,
            pumps = pumps,
        }
    end
    local garagesPayload = {}
    for _, garage in ipairs(state.garages) do
        local rounded = math.roundPosRotDirUp({ pos = vec3(garage.pos.x, garage.pos.y, garage.pos.z) })
        garagesPayload[#garagesPayload + 1] = {
            id = garage.id,
            name = garage.name,
            pos = { x = rounded.pos.x, y = rounded.pos.y, z = rounded.pos.z },
            radius = math.round(garage.radius or DEFAULT_RADIUS, 2),
        }
    end

    local pending, failed = 2, false
    local function checkDone(ok)
        if not ok then failed = true end
        pending = pending - 1
        if pending > 0 then return end
        if failed then
            refresh()
            standUp()
        elseif state.dirty then
            state.dirty = false
            beamjoy_communications_ui.send("BJEditorDirty", false)
        end
        if onDone then onDone(not failed) end
    end

    beamjoy_communications.send("energyStationsSave", stationsPayload)
    beamjoy_communications.addOneUseHandler("energyStationsSaved", function(status, err)
        if not status then toast.error(err or "Failed to save stations") end
        checkDone(status == true)
    end, 5000)

    beamjoy_communications.send("garagesSave", garagesPayload)
    beamjoy_communications.addOneUseHandler("garagesSaved", function(status, err)
        if not status then toast.error(err or "Failed to save garages") end
        checkDone(status == true)
    end, 5000)
end

local function onInit()
    beamjoy_communications_ui.addHandler("BJEditorStationsSelectItem", onSelectItem)
    beamjoy_communications_ui.addHandler("BJEditorStationsSelectPump", onSelectPump)
    beamjoy_communications_ui.addHandler("BJEditorStationsAddItem", onAddItem)
    beamjoy_communications_ui.addHandler("BJEditorStationsDeleteItem", onDeleteItem)
    beamjoy_communications_ui.addHandler("BJEditorStationsSetItemName", onSetItemName)
    beamjoy_communications_ui.addHandler("BJEditorStationsSetItemRadius", onSetItemRadius)
    beamjoy_communications_ui.addHandler("BJEditorStationsSetItemToVehicle", onSetItemToVehicle)
    beamjoy_communications_ui.addHandler("BJEditorStationsTeleportToItem", onTeleportToItem)
    beamjoy_communications_ui.addHandler("BJEditorStationsSetStationTypes", onSetStationTypes)
    beamjoy_communications_ui.addHandler("BJEditorStationsAddPump", onAddPump)
    beamjoy_communications_ui.addHandler("BJEditorStationsDeletePump", onDeletePump)
    beamjoy_communications_ui.addHandler("BJEditorStationsSetPumpRadius", onSetPumpRadius)
    beamjoy_communications_ui.addHandler("BJEditorStationsSetPumpTypes", onSetPumpTypes)
    beamjoy_communications_ui.addHandler("BJEditorStationsSetPumpToVehicle", onSetPumpToVehicle)
    beamjoy_communications_ui.addHandler("BJEditorStationsTeleportToPump", onTeleportToPump)
    beamjoy_communications_ui.addHandler("BJEditorStationsSetSnapToGround", onSetSnapToGround)
    beamjoy_communications_ui.addHandler("BJEditorStationsSetSnapMethod", onSetSnapMethod)
    beamjoy_communications_ui.addHandler("BJEditorStationsRequestState", pushFullState)
end

M.setActivePredicate = setActivePredicate
M.onInit = onInit
M.refresh = refresh
M.standUp = standUp
M.standDown = standDown
M.close = close
M.save = save
M.onBJClick = onBJClick
M.isDirty = function() return state.dirty end
M.isLoaded = function() return state.loaded end

return M
