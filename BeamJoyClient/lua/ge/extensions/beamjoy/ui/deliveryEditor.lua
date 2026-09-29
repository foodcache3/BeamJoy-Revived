--- In-world editor for the Config > Freeroam tab's "Deliveries" section. A sub-module hosted by
--- `freeroamEditor.lua`, same as `stationsEditor.lua` and `busLineEditor.lua`.
---
--- Delivery points are a 2-level shape like stations : a point (zone center + radius + what it
--- sends/receives), with an ordered sub-list of vehicle start slots (pos + facing, where a
--- vehicle-delivery job spawns each convoy member's delivery vehicle). Slots only matter when the
--- point sends vehicles.
---
--- Two extras over the stations editor :
---   - Save first measures the road length of every pair a job could use (the server has no road
---     graph, see services/deliveryPoints.lua). Runs as a background job with progress, reusing any
---     length already measured between the same two positions, so only moved/new points cost
---     anything. The editor seeds that cache from the server's stored routes when it opens.
---   - "Import from map" adds the current level's own delivery facilities (West Coast USA ships
---     ~65) as points : their parking spots give real positions, their logistic types give the
---     tags, and vehicle-providing spots become start slots. Additive, skips names already used.

local M = {}

local ACTIVE_COLOR = BJColor(1, 1, 1, .9)
local DEPOT_COLOR = BJColor(1, .45, 0, .8)
local DIM_DEPOT_COLOR = BJColor(1, .45, 0, .35)
local DROP_COLOR = BJColor(.3, .7, 1, .8)
local DIM_DROP_COLOR = BJColor(.3, .7, 1, .35)
local SLOT_COLOR = BJColor(1, .85, .2, .85)
local TEXT_BG = BJColor(0, 0, 0, .3)

-- kept in sync with services/deliveryPoints.lua
local DEFAULT_RADIUS = 8
local MIN_RADIUS = 3
local MAX_RADIUS = 30
local MAX_NAME_LEN = 40
local MAX_SLOTS = 4
local PROVIDE_TYPES = { packages = true, vehicles = true }
local RECEIVE_TYPES = { packages = true, cars = true, trucks = true }

-- the level's own delivery facility logistic types, mapped onto BJS's three cargo kinds. Anything
-- else (trailers, fluids, soil...) has no BJS equivalent yet and is ignored.
local LOGISTIC_KIND = {
    parcel = "packages", shopSupplies = "packages", officeSupplies = "packages",
    mechanicalParts = "packages", rareMechanicalParts = "packages", foodSupplies = "packages",
    food = "packages", industrial = "packages",
    vehForPrivate = "cars", vehNeedsRepair = "cars", vehRepairFinished = "cars",
    vehDeliveryPolice = "cars", vehDeliveryAmbulance = "cars",
    vehLargeTruck = "trucks", vehLargeTruckNeedsRepair = "trucks",
}

---@type fun(): boolean
local isActive = function() return false end

local state = {
    ---@type table[] editable copies of BJDeliveryPoint
    points = {},
    ---@type integer?
    activeIndex = nil,
    --- nil = the point itself is selected, an integer = that slot of the active point
    ---@type integer?
    activeSlot = nil,
    dirty = false,
    snapToGroundEnabled = true,
    ---@type "terrain"|"raycast"
    snapMethod = "terrain",
    --- set while Save is measuring routes : {done, total}
    ---@type {done: integer, total: integer}?
    measuring = nil,
}

--- "x,y,z>x,y,z" (positions rounded to the decimetre) -> metres. Lives for the whole session so
--- repeated saves only measure what actually moved.
---@type table<string, number>
local routeCache = {}

-- WIRE ------------------------------------------------------------------------------------------

local function pushLists()
    beamjoy_communications_ui.send("BJEditorDeliveriesListUpdate", { points = state.points })
end

local function pushActive()
    beamjoy_communications_ui.send("BJEditorDeliveriesActiveUpdate",
        { index = state.activeIndex, slot = state.activeSlot })
end

local function pushMeasuring()
    beamjoy_communications_ui.send("BJEditorDeliveriesMeasuring", state.measuring or false)
end

local function pushFullState()
    pushLists()
    pushActive()
    pushMeasuring()
    beamjoy_communications_ui.send("BJEditorDirty", state.dirty)
    beamjoy_communications_ui.send("BJEditorDeliveriesSnapToGround", state.snapToGroundEnabled)
    beamjoy_communications_ui.send("BJEditorDeliveriesSnapMethod", state.snapMethod)
end

local function markDirty()
    if not state.dirty then
        state.dirty = true
        beamjoy_communications_ui.send("BJEditorDirty", true)
    end
end

-- HELPERS ---------------------------------------------------------------------------------------

---@param pos vec3
---@return number
local function groundHeightAt(pos)
    if state.snapMethod ~= "raycast" then
        local h = core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(pos)
        if h then return h end
    end
    return be:getSurfaceHeightBelow(pos + vec3(0, 0, 10))
end

--- same as pointListEditor's currentPositionDirection : the free camera, or the current vehicle
---@return vec3? pos, vec3? dir
local function currentPositionDirection()
    local currVeh = beamjoy_vehicles.getCurrent()
    local pos, dir
    if not currVeh or camera.getCamera() == camera.CAMERAS.FREE then
        pos, dir = camera.getPositionRotation(false)
    else
        pos, dir = beamjoy_vehicles.getVehiclePositionRotation(currVeh.veh)
    end
    if not pos then return nil end
    if state.snapToGroundEnabled then
        pos = vec3(pos.x, pos.y, groundHeightAt(pos))
    end
    return pos, dir
end

---@param dir any
---@return {x: number, y: number, z: number}
local function flatDir(dir)
    local d = vec3(dir and dir.x or 1, dir and dir.y or 0, 0)
    if d:length() < 1e-4 then d = vec3(1, 0, 0) end
    d = d:normalized()
    return { x = d.x, y = d.y, z = 0 }
end

---@param list any
---@param tag string
---@return boolean
local function hasTag(list, tag)
    return type(list) == "table" and table.includes(list, tag)
end

---@param p table
---@return boolean
local function isDepot(p)
    return type(p.provides) == "table" and #p.provides > 0
end

---@param p table
---@param index integer
---@return string
local function labelOf(p, index)
    if type(p.name) == "string" and #p.name > 0 then return p.name end
    return string.format("%s %d", beamjoy_lang.translate("beamjoy.window.config.tabs.freeroam.deliveries.point"), index)
end

---@param pos table {x,y,z}
---@return vec3
local function v3(pos) return vec3(pos.x, pos.y, pos.z) end

-- RENDER ----------------------------------------------------------------------------------------

local function renderAll()
    shape.reset()
    for i, p in ipairs(state.points) do
        local depot = isDepot(p)
        local active = state.activeIndex == i
        local pos = v3(p.pos)
        local radius = math.max(MIN_RADIUS, tonumber(p.radius) or DEFAULT_RADIUS)
        local color
        if active then
            color = state.activeSlot == nil and ACTIVE_COLOR or (depot and DEPOT_COLOR or DROP_COLOR)
        else
            color = depot and DIM_DEPOT_COLOR or DIM_DROP_COLOR
        end
        if active then
            shape.addSphere(pos, radius, color)
            shape.addText(labelOf(p, i), pos + vec3(0, 0, radius + 1), color, TEXT_BG)
            for si, slot in ipairs(p.slots or {}) do
                local selected = state.activeSlot == si
                local sColor = selected and ACTIVE_COLOR or SLOT_COLOR
                local sp = v3(slot.pos)
                shape.addSphere(sp, .5, sColor)
                shape.addArrow(sp + vec3(0, 0, .5), v3(slot.dir):normalized(), 2.5, sColor)
                shape.addText(string.format("%s %d",
                    beamjoy_lang.translate("beamjoy.window.config.tabs.freeroam.deliveries.slot"), si),
                    sp + vec3(0, 0, 1.8), sColor, TEXT_BG)
                shape.addLine(pos + vec3(0, 0, .3), .2, sp + vec3(0, 0, .3), .2, sColor)
            end
        else
            shape.addSphere(pos, 1, color)
            shape.addText(labelOf(p, i), pos + vec3(0, 0, 2), color, TEXT_BG)
        end
    end
end

local function updateGizmo()
    gizmo.hide()
    local point = state.activeIndex and state.points[state.activeIndex]
    if not point then return end
    local slot = state.activeSlot and point.slots and point.slots[state.activeSlot]
    if state.activeSlot and not slot then return end
    local target = slot or point
    gizmo.show({
        pos = v3(target.pos),
        dir = slot and v3(slot.dir) or vec3(1, 0, 0),
        up = vec3(0, 0, 1),
        scales = vec3(1, 1, 1), -- radius is Angular-side, not the native scale tool
    }, function(updated)
        if not isActive() then return end
        target.pos = { x = updated.pos.x, y = updated.pos.y, z = updated.pos.z }
        if slot then
            local d = vec3(updated.dir.x, updated.dir.y, 0)
            if d:length() >= 1e-4 then slot.dir = flatDir(d) end
        end
        renderAll()
        markDirty()
    end, function()
        if state.snapToGroundEnabled then
            target.pos.z = groundHeightAt(v3(target.pos))
            renderAll()
            updateGizmo()
        end
        pushLists()
    end)
end

-- SELECTION -------------------------------------------------------------------------------------

---@param index integer?
local function onSelectPoint(index)
    if not isActive() then return end
    -- clicking the selected depot while one of its start slots is selected goes back to editing the
    -- depot itself ; only a click on the depot alone deselects it
    index = tonumber(index)
    if index and state.points[index] and (state.activeIndex ~= index or state.activeSlot) then
        state.activeIndex = index
    else
        state.activeIndex = nil
    end
    state.activeSlot = nil
    renderAll()
    updateGizmo()
    pushActive()
end

---@param pi integer
---@param si integer
local function onSelectSlot(pi, si)
    if not isActive() then return end
    pi, si = tonumber(pi), tonumber(si)
    local point = pi and state.points[pi]
    if not point or not point.slots or not point.slots[si] then return end
    state.activeIndex = pi
    state.activeSlot = (state.activeSlot == si) and nil or si
    renderAll()
    updateGizmo()
    pushActive()
end

-- POINT CRUD ------------------------------------------------------------------------------------

local function onAddPoint()
    if not isActive() then return end
    local pos = currentPositionDirection()
    if not pos then return end
    table.insert(state.points, {
        name = "",
        pos = { x = pos.x, y = pos.y, z = pos.z },
        radius = DEFAULT_RADIUS,
        provides = {},
        receives = { "packages" },
        slots = {},
    })
    state.activeIndex, state.activeSlot = #state.points, nil
    renderAll()
    updateGizmo()
    pushLists()
    pushActive()
    markDirty()
end

---@param index integer
local function onDeletePoint(index)
    if not isActive() then return end
    index = tonumber(index)
    if not index or not state.points[index] then return end
    table.remove(state.points, index)
    if state.activeIndex == index then
        state.activeIndex, state.activeSlot = nil, nil
    elseif state.activeIndex and state.activeIndex > index then
        state.activeIndex = state.activeIndex - 1
    end
    renderAll()
    updateGizmo()
    pushLists()
    pushActive()
    markDirty()
end

---@param index integer
---@param name string
local function onSetName(index, name)
    if not isActive() then return end
    local point = state.points[tonumber(index) or 0]
    if not point then return end
    name = type(name) == "string" and name or ""
    if #name > MAX_NAME_LEN then name = name:sub(1, MAX_NAME_LEN) end
    point.name = name
    renderAll()
    markDirty()
end

---@param index integer
---@param radius number
local function onSetRadius(index, radius)
    if not isActive() then return end
    local point = state.points[tonumber(index) or 0]
    if not point then return end
    point.radius = math.max(MIN_RADIUS, math.min(MAX_RADIUS, tonumber(radius) or point.radius))
    renderAll()
    markDirty()
end

--- `field` is "provides" or "receives" ; the Angular side sends the whole new list
---@param index integer
---@param field string
---@param tags string[]
local function onSetTags(index, field, tags)
    if not isActive() then return end
    local point = state.points[tonumber(index) or 0]
    local allowed = field == "provides" and PROVIDE_TYPES or field == "receives" and RECEIVE_TYPES
    if not point or not allowed then return end
    local clean, seen = {}, {}
    for _, t in ipairs(table.isArray(tags) and tags or {}) do
        if allowed[t] and not seen[t] then
            seen[t] = true
            clean[#clean + 1] = t
        end
    end
    point[field] = clean
    renderAll() -- depot vs drop-off color
    pushLists()
    markDirty()
end

---@param index integer
local function onSetToVehicle(index)
    if not isActive() then return end
    index = tonumber(index)
    local point = index and state.points[index]
    if not point then return end
    local pos = currentPositionDirection()
    if not pos then return end
    point.pos = { x = pos.x, y = pos.y, z = pos.z }
    renderAll()
    if state.activeIndex == index and state.activeSlot == nil then updateGizmo() end
    pushLists()
    markDirty()
end

---@param index integer
local function onTeleportTo(index)
    if not isActive() then return end
    local point = state.points[tonumber(index) or 0]
    local current = beamjoy_vehicles.getCurrentOwn()
    if not point or not current then return end
    beamjoy_vehicles.setVehiclePositionRotation(current.veh, v3(point.pos), vec3(1, 0, 0), vec3(0, 0, 1))
end

-- SLOT CRUD -------------------------------------------------------------------------------------

---@param pi integer
local function onAddSlot(pi)
    if not isActive() then return end
    pi = tonumber(pi)
    local point = pi and state.points[pi]
    if not point then return end
    point.slots = point.slots or {}
    if #point.slots >= MAX_SLOTS then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    table.insert(point.slots, { pos = { x = pos.x, y = pos.y, z = pos.z }, dir = flatDir(dir) })
    state.activeIndex, state.activeSlot = pi, #point.slots
    renderAll()
    updateGizmo()
    pushLists()
    pushActive()
    markDirty()
end

---@param pi integer
---@param si integer
local function onDeleteSlot(pi, si)
    if not isActive() then return end
    pi, si = tonumber(pi), tonumber(si)
    local point = pi and state.points[pi]
    if not point or not point.slots or not point.slots[si] then return end
    table.remove(point.slots, si)
    if state.activeIndex == pi then state.activeSlot = nil end
    renderAll()
    updateGizmo()
    pushLists()
    pushActive()
    markDirty()
end

---@param pi integer
---@param si integer
local function onSetSlotToVehicle(pi, si)
    if not isActive() then return end
    pi, si = tonumber(pi), tonumber(si)
    local point = pi and state.points[pi]
    local slot = point and point.slots and point.slots[si]
    if not slot then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    slot.pos = { x = pos.x, y = pos.y, z = pos.z }
    slot.dir = flatDir(dir)
    renderAll()
    if state.activeIndex == pi and state.activeSlot == si then updateGizmo() end
    pushLists()
    markDirty()
end

---@param pi integer
---@param si integer
local function onTeleportToSlot(pi, si)
    if not isActive() then return end
    pi, si = tonumber(pi), tonumber(si)
    local point = pi and state.points[pi]
    local slot = point and point.slots and point.slots[si]
    local current = beamjoy_vehicles.getCurrentOwn()
    if not slot or not current then return end
    beamjoy_vehicles.setVehiclePositionRotation(current.veh, v3(slot.pos), v3(slot.dir), vec3(0, 0, 1))
end

---@param enabled boolean
local function onSetSnapToGround(enabled)
    state.snapToGroundEnabled = enabled == true
    beamjoy_communications_ui.send("BJEditorDeliveriesSnapToGround", state.snapToGroundEnabled)
end

---@param method string
local function onSetSnapMethod(method)
    state.snapMethod = method == "raycast" and "raycast" or "terrain"
    beamjoy_communications_ui.send("BJEditorDeliveriesSnapMethod", state.snapMethod)
end

-- WORLD CLICK -----------------------------------------------------------------------------------

--- any point is clickable ; slots only on the already-active point (same as stations' pumps)
---@param clickType string
---@param data table
local function onBJClick(clickType, data)
    if clickType ~= "left" or not isActive() then return end
    local camPos, rayDir = camera.mouseRay()
    if not camPos then return end

    local function hit(pos, radius)
        local along = (pos - camPos):dot(rayDir)
        if along <= 0 then return nil end
        return (camPos + rayDir * along):distance(pos) <= radius and along or nil
    end

    local best, bestAlong
    for i, p in ipairs(state.points) do
        local r = state.activeIndex == i and math.max(1.5, tonumber(p.radius) or DEFAULT_RADIUS) or 1.5
        local along = hit(v3(p.pos), r)
        if along and (not bestAlong or along < bestAlong) then best, bestAlong = i, along end
    end
    if best and best ~= state.activeIndex then
        onSelectPoint(best)
        return
    end

    local point = state.activeIndex and state.points[state.activeIndex]
    if not point then return end
    local bestSlot
    bestAlong = nil
    for si, slot in ipairs(point.slots or {}) do
        local along = hit(v3(slot.pos), 1.5)
        if along and (not bestAlong or along < bestAlong) then bestSlot, bestAlong = si, along end
    end
    if bestSlot and bestSlot ~= state.activeSlot then
        onSelectSlot(state.activeIndex, bestSlot)
    end
end

-- IMPORT FROM MAP -------------------------------------------------------------------------------

---@param sites table[] loaded sites objects
---@param name string
---@return table? parking spot
local function findSpot(sites, name)
    for _, s in ipairs(sites) do
        local spot = s.parkingSpots and s.parkingSpots.byName and s.parkingSpots.byName[name]
        if spot and not spot.missing then return spot end
    end
end

---@param types any logistic type list
---@return table<string, true> BJS kinds present
local function kindsOf(types)
    local kinds = {}
    for _, t in ipairs(type(types) == "table" and types or {}) do
        local k = LOGISTIC_KIND[t]
        if k then kinds[k] = true end
    end
    return kinds
end

-- slot filling : a spot must fit a car (or a truck, for truck-only depots), sit within
-- SLOT_SEARCH_RADIUS of the depot's own vehicle spot, and keep SLOT_MIN_GAP from slots already taken
local SLOT_SEARCH_RADIUS = 60
local SLOT_MIN_GAP = 4
local CAR_SPOT = { width = 2.2, length = 4.5 }
local TRUCK_SPOT = { width = 3, length = 7.5 }

--- every single parking spot the level defines, from all of its sites files (street parking in
--- city.sites.json, facility spots, delivery spots...). The level's delivery facilities each list
--- only ONE vehicle spot (career spawns one vehicle at a time), so convoy slots 2-4 come from here.
---@param sm table gameplay_sites_sitesManager
---@param level string
---@return table[] parking spot objects
local function allLevelSpots(sm, level)
    local info = core_levels and core_levels.getLevelByName(level)
    if not info or not info.dir then return {} end
    local spots, seen = {}, {}
    for _, file in ipairs(FS:findFiles(info.dir, "*.sites.json", -1, false, true)) do
        local ok, sites = pcall(sm.loadSites, file)
        if ok and sites and sites.parkingSpots and sites.parkingSpots.sorted then
            for _, spot in ipairs(sites.parkingSpots.sorted) do
                if not spot.missing and spot.pos and spot.rot and spot.scl and not seen[spot] then
                    seen[spot] = true
                    spots[#spots + 1] = spot
                end
            end
        end
    end
    return spots
end

---@param spot table parking spot
---@return {pos: table, dir: table}
local function slotFromSpot(spot)
    -- a spot's forward is its rotation applied to +Y (parkingSpot.lua)
    local fwd = quat(spot.rot) * vec3(0, 1, 0)
    return { pos = { x = spot.pos.x, y = spot.pos.y, z = spot.pos.z }, dir = flatDir(fwd) }
end

--- up to MAX_SLOTS start slots : the facility's own vehicle spots first, then its other spots,
--- then the nearest suitable level parking spots around the first of those
---@param access table[] the facility's access points
---@param anchor vec3 where to search around when the facility lists no vehicle spot
---@param trucksOnly boolean
---@param levelSpots table[]
---@return table[] slots
local function buildSlots(access, anchor, trucksOnly, levelSpots)
    local size = trucksOnly and TRUCK_SPOT or CAR_SPOT
    local chosen, slots = {}, {}
    local function fits(spot)
        return spot.scl.x >= size.width and spot.scl.y >= size.length
    end
    local function tryAdd(spot, force)
        if #slots >= MAX_SLOTS or chosen[spot] then return end
        if not force and not fits(spot) then return end
        for _, s in ipairs(slots) do
            if spot.pos:distance(v3(s.pos)) < SLOT_MIN_GAP then return end
        end
        chosen[spot] = true
        slots[#slots + 1] = slotFromSpot(spot)
    end

    -- the level's own vehicle spot is always kept, whatever its size : it's where career spawns
    for _, ap in ipairs(access) do
        if ap.provided.cars or ap.provided.trucks then tryAdd(ap.spot, true) end
    end
    if slots[1] then anchor = v3(slots[1].pos) end
    for _, ap in ipairs(access) do tryAdd(ap.spot, false) end

    local nearby = {}
    for _, spot in ipairs(levelSpots) do
        local d = spot.pos:distance(anchor)
        if d <= SLOT_SEARCH_RADIUS and not chosen[spot] then nearby[#nearby + 1] = { spot = spot, d = d } end
    end
    table.sort(nearby, function(a, b) return a.d < b.d end)
    for _, n in ipairs(nearby) do
        if #slots >= MAX_SLOTS then break end
        tryAdd(n.spot, false)
    end
    return slots
end

--- one BJS point per delivery facility of the current level
---@return table[] points, integer skipped facilities with no usable spot or cargo
local function buildImport()
    local level = getCurrentLevelIdentifier()
    local fac = extensions.freeroam_facilities
    local sm = extensions.gameplay_sites_sitesManager
    if not level or not fac or not sm then return {}, 0 end
    local providers = fac.getFacilitiesByType("deliveryProvider", level) or {}
    local levelSpots

    local points, skipped = {}, 0
    for _, f in ipairs(providers) do
        local sites = {}
        local files = type(f.sitesFile) == "table" and f.sitesFile or { f.sitesFile }
        for _, file in ipairs(files) do
            local ok, s = pcall(sm.loadSites, file)
            if ok and s then sites[#sites + 1] = s end
        end

        -- normalize both schemas into access points {spot, provided, received}
        local access = {}
        if type(f.manualAccessPoints) == "table" then
            for _, ap in ipairs(f.manualAccessPoints) do
                local spot = ap.psName and findSpot(sites, ap.psName)
                if spot then
                    access[#access + 1] = { spot = spot, provided = kindsOf(ap.logisticTypesProvided),
                        received = kindsOf(ap.logisticTypesReceived) }
                end
            end
        end
        for _, n in ipairs(f.dropOffSpotNames or {}) do
            local spot = findSpot(sites, n)
            if spot then access[#access + 1] = { spot = spot, provided = {}, received = kindsOf(f.logisticTypesReceived) } end
        end
        for _, n in ipairs(f.pickUpSpotNames or {}) do
            local spot = findSpot(sites, n)
            if spot then access[#access + 1] = { spot = spot, provided = kindsOf(f.logisticTypesProvided), received = {} } end
        end

        local provided, received = kindsOf(f.logisticTypesProvided), kindsOf(f.logisticTypesReceived)
        local provides, receives = {}, {}
        if provided.packages then provides[#provides + 1] = "packages" end
        if provided.cars or provided.trucks then provides[#provides + 1] = "vehicles" end
        for _, k in ipairs({ "packages", "cars", "trucks" }) do
            if received[k] then receives[#receives + 1] = k end
        end

        -- the zone sits on a spot that receives something (the drop-off), else any spot
        local center
        for _, ap in ipairs(access) do
            if next(ap.received) then center = ap.spot break end
        end
        center = center or (access[1] and access[1].spot)

        if not center or (#provides == 0 and #receives == 0) then
            skipped = skipped + 1
        else
            local slots = {}
            if provided.cars or provided.trucks then
                levelSpots = levelSpots or allLevelSpots(sm, level)
                slots = buildSlots(access, vec3(center.pos), provided.trucks and not provided.cars, levelSpots)
            end
            local name = translateLanguage(f.name or "", f.id or "", true)
            if type(name) ~= "string" or #name == 0 then name = tostring(f.id) end
            if #name > MAX_NAME_LEN then name = name:sub(1, MAX_NAME_LEN) end
            points[#points + 1] = {
                name = name,
                pos = { x = center.pos.x, y = center.pos.y, z = center.pos.z },
                radius = DEFAULT_RADIUS,
                provides = provides,
                receives = receives,
                slots = slots,
            }
        end
    end
    return points, skipped
end

local function onImportFromMap()
    if not isActive() or state.measuring then return end
    local ok, imported, skipped = pcall(buildImport)
    if not ok then
        LogError("delivery import failed: " .. tostring(imported))
        toast.error(beamjoy_lang.translate("beamjoy.window.config.tabs.freeroam.deliveries.import.failed"))
        return
    end
    local existing = {}
    for _, p in ipairs(state.points) do existing[p.name] = true end
    local added, duplicates = 0, 0
    for _, p in ipairs(imported) do
        if existing[p.name] then
            duplicates = duplicates + 1
        else
            existing[p.name] = true
            table.insert(state.points, p)
            added = added + 1
        end
    end
    toast.info(string.var(beamjoy_lang.translate("beamjoy.window.config.tabs.freeroam.deliveries.import.done"),
        { added, duplicates, skipped }), nil, 8)
    if added > 0 then
        renderAll()
        pushLists()
        markDirty()
    end
end

-- ROUTES ----------------------------------------------------------------------------------------

---@param pos table
---@return string
local function posKey(pos)
    return string.format("%.1f,%.1f,%.1f", pos.x, pos.y, pos.z)
end

---@param from table
---@param to table
---@return boolean
local function isJobPair(from, to)
    if from == to then return false end
    if hasTag(from.provides, "packages") and hasTag(to.receives, "packages") then return true end
    return hasTag(from.provides, "vehicles") and (hasTag(to.receives, "cars") or hasTag(to.receives, "trucks"))
end

--- a leg of a multi-stop job : between two package drop-offs. Every such pair is measured, not
--- only the ones fitting today's route distances, so changing Deliveries.Min/MaxRouteDistance
--- later never leaves legs unmeasured (the server picks legs by those settings at offer time).
--- Costs a longer first save ; later saves reuse the cache.
---@param from table
---@param to table
---@return boolean
local function isStopPair(from, to)
    return from ~= to and hasTag(from.receives, "packages") and hasTag(to.receives, "packages")
end

--- road length between two positions over the level's AI road graph, plus the off-road stubs to
--- and from the nearest nodes ; falls back to the straight line when there's no graph path
---@param a vec3
---@param b vec3
---@return number
local function measure(a, b)
    local ok, path = pcall(map.getPointToPointPath, a, b)
    local nodes = map.getMap().nodes
    if not ok or type(path) ~= "table" or #path == 0 or not nodes[path[1]] then
        return a:distance(b)
    end
    local len = a:distance(nodes[path[1]].pos)
    for i = 2, #path do
        len = len + nodes[path[i - 1]].pos:distance(nodes[path[i]].pos)
    end
    return len + nodes[path[#path]].pos:distance(b)
end

--- seed the cache from what the server already stored (keyed by the ids in the synced cache, so
--- only valid while those points haven't moved - exactly the pairs we'd otherwise re-measure)
---@param flat table[] [[fromId, toId, metres], ...]
local function onRoutesReceived(flat)
    local byId = {}
    for _, p in ipairs(beamjoy_deliveryPoints.data.points or {}) do byId[p.id] = p end
    for _, r in ipairs(table.isArray(flat) and flat or {}) do
        local from, to = byId[r[1]], byId[r[2]]
        if from and to and tonumber(r[3]) then
            routeCache[posKey(from.pos) .. ">" .. posKey(to.pos)] = tonumber(r[3])
        end
    end
end

-- HOST INTERFACE (called by freeroamEditor) -----------------------------------------------------

---@param fn fun(): boolean
local function setActivePredicate(fn)
    isActive = fn or isActive
end

--- (re)load from the synced cache ; keeps selection if still valid
local function refresh()
    state.points = {}
    for _, p in ipairs(beamjoy_deliveryPoints.data.points or {}) do
        local slots = {}
        for _, s in ipairs(p.slots or {}) do
            slots[#slots + 1] = { pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z }, dir = flatDir(s.dir) }
        end
        state.points[#state.points + 1] = {
            id = p.id,
            name = p.name or "",
            pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z },
            radius = p.radius or DEFAULT_RADIUS,
            provides = table.isArray(p.provides) and table.clone(p.provides) or {},
            receives = table.isArray(p.receives) and table.clone(p.receives) or {},
            slots = slots,
        }
    end
    if not state.activeIndex or not state.points[state.activeIndex] then
        state.activeIndex, state.activeSlot = nil, nil
    elseif state.activeSlot and not state.points[state.activeIndex].slots[state.activeSlot] then
        state.activeSlot = nil
    end
    state.dirty = false
    beamjoy_communications.send("deliveryRoutesRequest")
end

local function standUp()
    renderAll()
    updateGizmo()
    pushFullState()
end

local function standDown()
    gizmo.hide()
end

local function close()
    gizmo.hide()
    state.points = {}
    state.activeIndex, state.activeSlot = nil, nil
    state.dirty = false
end

local function sendSave(payload)
    beamjoy_communications.send("deliveryPointsSave", payload)
    beamjoy_communications.addOneUseHandler("deliveryPointsSaved", function(status, err)
        if not status then
            toast.error(err or "Failed to save delivery points")
            refresh()
            standUp()
        elseif state.dirty then
            state.dirty = false
            beamjoy_communications_ui.send("BJEditorDirty", false)
        end
    end, 5000)
end

--- measures every job pair not already in the cache (background job, progress pushed to the
--- sidebar), then sends points + routes in one save
local function save()
    if state.measuring then return end
    local points = {}
    for _, p in ipairs(state.points) do
        local rounded = math.roundPosRotDirUp({ pos = v3(p.pos) })
        local slots = {}
        if hasTag(p.provides, "vehicles") then
            for _, s in ipairs(p.slots or {}) do
                local rs = math.roundPosRotDirUp({ pos = v3(s.pos) })
                slots[#slots + 1] = {
                    pos = { x = rs.pos.x, y = rs.pos.y, z = rs.pos.z },
                    dir = { x = math.round(s.dir.x, 4), y = math.round(s.dir.y, 4), z = 0 },
                }
            end
        end
        points[#points + 1] = {
            id = p.id,
            name = p.name,
            pos = { x = rounded.pos.x, y = rounded.pos.y, z = rounded.pos.z },
            radius = math.round(p.radius or DEFAULT_RADIUS, 1),
            provides = p.provides,
            receives = p.receives,
            slots = slots,
        }
    end

    local pairsToSend, missing = {}, {}
    for i, from in ipairs(points) do
        for j, to in ipairs(points) do
            if isJobPair(from, to) or isStopPair(from, to) then
                local key = posKey(from.pos) .. ">" .. posKey(to.pos)
                local pair = { i, j, key }
                pairsToSend[#pairsToSend + 1] = pair
                if not routeCache[key] then missing[#missing + 1] = { from = from.pos, to = to.pos, key = key } end
            end
        end
    end

    local function finish()
        local routes = {}
        for _, pair in ipairs(pairsToSend) do
            local meters = routeCache[pair[3]]
            if meters then routes[#routes + 1] = { pair[1], pair[2], math.round(meters) } end
        end
        sendSave({ points = points, routes = routes })
    end

    if #missing == 0 then return finish() end

    state.measuring = { done = 0, total = #missing }
    pushMeasuring()
    core_jobsystem.create(function(job)
        for n, m in ipairs(missing) do
            routeCache[m.key] = measure(v3(m.from), v3(m.to))
            state.measuring.done = n
            if n % 10 == 0 then pushMeasuring() end
            job.yield()
        end
        state.measuring = nil
        pushMeasuring()
        finish()
    end)
end

local function onInit()
    beamjoy_communications.addHandler("deliveryRoutes", onRoutesReceived)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesSelectPoint", onSelectPoint)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesSelectSlot", onSelectSlot)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesAddPoint", onAddPoint)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesDeletePoint", onDeletePoint)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesSetName", onSetName)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesSetRadius", onSetRadius)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesSetTags", onSetTags)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesSetToVehicle", onSetToVehicle)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesTeleportTo", onTeleportTo)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesAddSlot", onAddSlot)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesDeleteSlot", onDeleteSlot)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesSetSlotToVehicle", onSetSlotToVehicle)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesTeleportToSlot", onTeleportToSlot)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesImport", onImportFromMap)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesSetSnapToGround", onSetSnapToGround)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesSetSnapMethod", onSetSnapMethod)
    beamjoy_communications_ui.addHandler("BJEditorDeliveriesRequestState", pushFullState)
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

return M
