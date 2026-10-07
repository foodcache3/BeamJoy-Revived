--- In-world drift zone editor : the "Drift zones" section of Config > Freeroam, a sub-editor hosted
--- by `freeroamEditor.lua` (the same host contract as `dragStripEditor.lua` : refresh / standUp /
--- standDown / close / save / onBJClick).
---
--- A zone is a name, a corridor width and a route : its first point is the start gate, its last the
--- finish gate, any points between shape the corridor. Each gate faces along the route (from the
--- start to the next point, from the point before to the finish). A new zone starts at your car with
--- its finish 60 m ahead ; a new point goes after the selected one (before the finish otherwise),
--- at your car ; points move with the gizmo. Server side : services/driftZones.lua.

local M = {}

local ACTIVE_COLOR = BJColor(0, 1, 1, .9)
local START_COLOR = BJColor(.2, 1, .4, .85)
local FINISH_COLOR = BJColor(1, 1, 1, .9)
local ROUTE_COLOR = BJColor(1, .85, .2, .6)
local EDGE_COLOR = BJColor(1, .45, .1, .5)
local DIM_COLOR = BJColor(1, 1, 1, .45)
local TEXT_BG = BJColor(0, 0, 0, .35)

local DEFAULT_WIDTH = 16
local MIN_WIDTH, MAX_WIDTH = 6, 60
local MAX_POINTS = 40
local MAX_NAME_LEN = 40
local NEW_ZONE_LENGTH = 60

---@type fun(): boolean
local isActive = function() return false end

local state = {
    ---@type table[]
    zones = {},
    ---@type integer?
    activeZone = nil,
    ---@type integer?
    activePoint = nil,
    dirty = false,
    snapToGroundEnabled = true,
    ---@type "terrain"|"raycast"
    snapMethod = "terrain",
}

-- WIRE ------------------------------------------------------------------------------------------

local function pushZones()
    beamjoy_communications_ui.send("BJEditorDriftZonesListUpdate", state.zones)
end

local function pushActive()
    beamjoy_communications_ui.send("BJEditorDriftZonesActiveUpdate",
        { zone = state.activeZone, point = state.activePoint })
end

local function pushFullState()
    pushZones()
    pushActive()
    beamjoy_communications_ui.send("BJEditorDirty", state.dirty)
    beamjoy_communications_ui.send("BJEditorDriftZonesSnapToGround", state.snapToGroundEnabled)
    beamjoy_communications_ui.send("BJEditorDriftZonesSnapMethod", state.snapMethod)
end

local function markDirty()
    if not state.dirty then
        state.dirty = true
        beamjoy_communications_ui.send("BJEditorDirty", true)
    end
end

-- GEOMETRY ------------------------------------------------------------------------------------

---@param pos vec3
---@return number
local function groundHeightAt(pos)
    if state.snapMethod ~= "raycast" then
        local h = core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(pos)
        if h then return h end
    end
    return be:getSurfaceHeightBelow(pos + vec3(0, 0, 10))
end

---@return vec3? pos, vec3? dir your car's (or the free camera's) position and flat facing
local function currentPositionDirection()
    local currVeh = beamjoy_vehicles.getCurrent()
    local pos, dir
    if not currVeh or camera.getCamera() == camera.CAMERAS.FREE then
        pos, dir = camera.getPositionRotation(false)
    else
        pos, dir = beamjoy_vehicles.getVehiclePositionRotation(currVeh.veh)
    end
    if not pos then return nil end
    if state.snapToGroundEnabled then pos = vec3(pos.x, pos.y, groundHeightAt(pos)) end
    local flat = dir and vec3(dir.x, dir.y, 0) or vec3(0, 1, 0)
    if flat:length() < 1e-4 then flat = vec3(0, 1, 0) end
    return pos, flat:normalized()
end

---@param v vec3
---@return table
local function xyz(v) return { x = v.x, y = v.y, z = v.z } end

---@param p table
---@return vec3
local function v3(p) return vec3(p.x, p.y, p.z) end

---@param a vec3
---@param b vec3
---@return vec3
local function flatDir(a, b)
    local d = vec3(b.x - a.x, b.y - a.y, 0)
    return d:length() > 1e-4 and d:normalized() or vec3(0, 1, 0)
end

-- RENDER ------------------------------------------------------------------------------------

---@param zone table
---@param i integer
---@return string the point's label : Start, Finish, or its number along the way
local function pointLabel(zone, i)
    if i == 1 then return beamjoy_lang.translate("beamjoy.driftZones.start") end
    if i == #zone.points then return beamjoy_lang.translate("beamjoy.driftZones.finish") end
    return tostring(i - 1)
end

local function renderAll()
    shape.reset()
    local lift = vec3(0, 0, .05)
    for zi, zone in ipairs(state.zones) do
        local active = state.activeZone == zi
        local pts = zone.points
        local half = (tonumber(zone.width) or DEFAULT_WIDTH) / 2
        if not active then
            local p = v3(pts[1])
            shape.addSphere(p + vec3(0, 0, .5), .8, DIM_COLOR)
            shape.addText(zone.name ~= "" and zone.name or beamjoy_lang.translate("beamjoy.driftZones.zone"),
                p + vec3(0, 0, 2.5), DIM_COLOR, TEXT_BG)
        else
            for i = 2, #pts do
                local a, b = v3(pts[i - 1]), v3(pts[i])
                local right = flatDir(a, b):cross(vec3(0, 0, 1)) * half
                shape.addLine(a + lift, .2, b + lift, .2, ROUTE_COLOR)
                shape.addLine(a - right + lift, .1, b - right + lift, .1, EDGE_COLOR)
                shape.addLine(a + right + lift, .1, b + right + lift, .1, EDGE_COLOR)
            end
            -- the gates, across the route
            for _, gate in ipairs({ { 1, 2, START_COLOR }, { #pts, #pts - 1, FINISH_COLOR } }) do
                local p, other = v3(pts[gate[1]]), v3(pts[gate[2]])
                local dir = gate[1] == 1 and flatDir(p, other) or flatDir(other, p)
                local right = dir:cross(vec3(0, 0, 1)) * half
                shape.addLine(p - right + lift, .25, p + right + lift, .25, gate[3])
                shape.addArrow(p + vec3(0, 0, 1) + dir * 2, dir, 2, gate[3])
            end
            for i, pt in ipairs(pts) do
                local selected = state.activePoint == i
                local color = selected and ACTIVE_COLOR or i == 1 and START_COLOR or i == #pts and FINISH_COLOR or ROUTE_COLOR
                local p = v3(pt)
                shape.addSphere(p + vec3(0, 0, .5), selected and .9 or .6, color)
                shape.addText(pointLabel(zone, i), p + vec3(0, 0, 2), color, TEXT_BG)
            end
        end
    end
end

local function updateGizmo()
    gizmo.hide()
    local zone = state.activeZone and state.zones[state.activeZone]
    local pt = zone and state.activePoint and zone.points[state.activePoint]
    if not pt then return end
    gizmo.show({
        pos = v3(pt),
        dir = vec3(0, 1, 0),
        up = vec3(0, 0, 1),
        scales = vec3(1, 1, 1),
    }, function(updated)
        if not isActive() then return end
        -- a point only moves : the gates face along the route
        pt.x, pt.y, pt.z = updated.pos.x, updated.pos.y, updated.pos.z
        renderAll()
        markDirty()
    end, function()
        if state.snapToGroundEnabled then pt.z = groundHeightAt(v3(pt)) end
        renderAll()
        updateGizmo()
        pushZones()
    end)
end

local function changed()
    renderAll()
    updateGizmo()
    pushZones()
    pushActive()
    markDirty()
end

-- MUTATIONS ---------------------------------------------------------------------------------

---@param zi any
---@return table?
local function zoneAt(zi)
    zi = tonumber(zi)
    return zi and state.zones[zi] or nil
end

---@param zi integer?
local function onSelectZone(zi)
    if not isActive() then return end
    zi = tonumber(zi)
    if zi and state.zones[zi] then
        state.activeZone = (state.activeZone == zi and not state.activePoint) and nil or zi
    else
        state.activeZone = nil
    end
    state.activePoint = nil
    renderAll()
    updateGizmo()
    pushActive()
end

---@param zi integer
---@param pi integer
local function onSelectPoint(zi, pi)
    if not isActive() then return end
    local zone = zoneAt(zi)
    pi = tonumber(pi)
    if not zone or not pi or not zone.points[pi] then return end
    state.activeZone = tonumber(zi)
    state.activePoint = state.activePoint == pi and nil or pi
    renderAll()
    updateGizmo()
    pushActive()
end

local function onAddZone()
    if not isActive() then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    local finish = pos + dir * NEW_ZONE_LENGTH
    if state.snapToGroundEnabled then finish = vec3(finish.x, finish.y, groundHeightAt(finish)) end
    table.insert(state.zones, { name = "", width = DEFAULT_WIDTH, points = { xyz(pos), xyz(finish) } })
    state.activeZone, state.activePoint = #state.zones, 2
    changed()
end

---@param zi integer
local function onDeleteZone(zi)
    if not isActive() or not zoneAt(zi) then return end
    table.remove(state.zones, tonumber(zi))
    state.activeZone, state.activePoint = nil, nil
    changed()
end

---@param zi integer
---@param partial table name / width
local function onSetZone(zi, partial)
    if not isActive() then return end
    local zone = zoneAt(zi)
    if not zone or type(partial) ~= "table" then return end
    if type(partial.name) == "string" then zone.name = partial.name:sub(1, MAX_NAME_LEN) end
    if partial.width ~= nil then
        zone.width = math.max(MIN_WIDTH, math.min(MAX_WIDTH, tonumber(partial.width) or zone.width))
    end
    renderAll()
    markDirty()
end

--- a point at your car : after the selected one, before the finish otherwise
---@param zi integer
local function onAddPoint(zi)
    if not isActive() then return end
    local zone = zoneAt(zi)
    if not zone or #zone.points >= MAX_POINTS then return end
    local pos = currentPositionDirection()
    if not pos then return end
    local at = #zone.points
    if state.activeZone == tonumber(zi) and state.activePoint and state.activePoint < #zone.points then
        at = state.activePoint + 1
    end
    table.insert(zone.points, at, xyz(pos))
    state.activeZone, state.activePoint = tonumber(zi), at
    changed()
end

---@param zi integer
---@param pi integer
local function onDeletePoint(zi, pi)
    if not isActive() then return end
    local zone = zoneAt(zi)
    pi = tonumber(pi)
    if not zone or not pi or not zone.points[pi] or #zone.points <= 2 then return end
    table.remove(zone.points, pi)
    state.activePoint = nil
    changed()
end

---@param zi integer
---@param pi integer
local function onSetPointToVehicle(zi, pi)
    if not isActive() then return end
    local zone = zoneAt(zi)
    local pt = zone and zone.points[tonumber(pi)]
    if not pt then return end
    local pos = currentPositionDirection()
    if not pos then return end
    zone.points[tonumber(pi)] = xyz(pos)
    changed()
end

--- your car on the point, facing along the route
---@param zi integer
---@param pi integer
local function onTeleportToPoint(zi, pi)
    if not isActive() then return end
    local zone = zoneAt(zi)
    pi = tonumber(pi)
    local pt = zone and pi and zone.points[pi]
    local current = beamjoy_vehicles.getCurrentOwn()
    if not pt or not current then return end
    local nextPt = zone.points[pi + 1] or zone.points[pi - 1]
    local dir = pi < #zone.points and flatDir(v3(pt), v3(nextPt)) or flatDir(v3(nextPt), v3(pt))
    -- a start : a little before it, so the run starts as you drive off
    local pos = pi == 1 and v3(pt) - dir * 15 or v3(pt)
    beamjoy_vehicles.setVehiclePositionRotation(current.veh, pos, dir, vec3(0, 0, 1))
end

---@param enabled boolean
local function onSetSnapToGround(enabled)
    state.snapToGroundEnabled = enabled == true
    beamjoy_communications_ui.send("BJEditorDriftZonesSnapToGround", state.snapToGroundEnabled)
end

---@param method string
local function onSetSnapMethod(method)
    state.snapMethod = method == "raycast" and "raycast" or "terrain"
    beamjoy_communications_ui.send("BJEditorDriftZonesSnapMethod", state.snapMethod)
end

--- click a point of the zone being edited (or any zone's start) in the world to pick it
---@param clickType string
local function onBJClick(clickType)
    if clickType ~= "left" or not isActive() then return end
    local camPos, rayDir = camera.mouseRay()
    if not camPos then return end
    local best, bestZone, bestPoint
    for zi, zone in ipairs(state.zones) do
        for pi, pt in ipairs(zone.points) do
            if zi == state.activeZone or pi == 1 then
                local p = v3(pt) + vec3(0, 0, .5)
                local along = (p - camPos):dot(rayDir)
                if along > 0 and (camPos + rayDir * along):distance(p) <= 1.5 and (not best or along < best) then
                    best, bestZone, bestPoint = along, zi, pi
                end
            end
        end
    end
    if bestZone and not (bestZone == state.activeZone and bestPoint == state.activePoint) then
        state.activeZone, state.activePoint = bestZone, bestPoint
        renderAll()
        updateGizmo()
        pushActive()
    end
end

-- HOST INTERFACE (called by freeroamEditor) ---------------------------------------------

local function setActivePredicate(fn)
    isActive = fn or isActive
end

local function refresh()
    state.zones = {}
    for _, z in ipairs(beamjoy_driftZones and beamjoy_driftZones.zones or {}) do
        state.zones[#state.zones + 1] = {
            id = z.id,
            name = z.name or "",
            width = z.width or DEFAULT_WIDTH,
            points = table.map(z.points or {}, function(p) return { x = p.x, y = p.y, z = p.z } end),
        }
    end
    if not state.activeZone or not state.zones[state.activeZone] then
        state.activeZone, state.activePoint = nil, nil
    elseif state.activePoint and not state.zones[state.activeZone].points[state.activePoint] then
        state.activePoint = nil
    end
    state.dirty = false
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
    state.zones = {}
    state.activeZone, state.activePoint = nil, nil
    state.dirty = false
end

---@param onDone fun(ok: boolean)?
local function save(onDone)
    local payload = table.map(state.zones, function(z)
        return {
            id = z.id,
            name = z.name,
            width = math.round(tonumber(z.width) or DEFAULT_WIDTH, 1),
            points = table.map(z.points, function(p)
                return { x = math.round(p.x, 3), y = math.round(p.y, 3), z = math.round(p.z, 3) }
            end),
        }
    end)
    beamjoy_communications.send("driftZonesSave", payload)
    beamjoy_communications.addOneUseHandler("driftZonesSaved", function(status, err)
        if status then
            if state.dirty then
                state.dirty = false
                beamjoy_communications_ui.send("BJEditorDirty", false)
            end
        else
            refresh()
            standUp()
            toast.error(err or "Failed to save the drift zones")
        end
        if onDone then onDone(status == true) end
    end, 5000)
end

local function onInit()
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesSelectZone", onSelectZone)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesSelectPoint", onSelectPoint)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesAddZone", onAddZone)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesDeleteZone", onDeleteZone)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesSetZone", onSetZone)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesAddPoint", onAddPoint)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesDeletePoint", onDeletePoint)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesSetPointToVehicle", onSetPointToVehicle)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesTeleportToPoint", onTeleportToPoint)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesSetSnapToGround", onSetSnapToGround)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesSetSnapMethod", onSetSnapMethod)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesRequestState", pushFullState)
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
