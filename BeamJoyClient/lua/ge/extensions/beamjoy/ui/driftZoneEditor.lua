--- In-world drift zone editor : the "Drift zones" section of Config > Freeroam, a sub-editor hosted
--- by `freeroamEditor.lua` (the same host contract as `dragStripEditor.lua` : refresh / standUp /
--- standDown / close / save / onBJClick).
---
--- A zone is a name, a corridor width and a route : its first point is the start gate, its last the
--- finish gate, any points between shape the corridor. Each gate faces along the route (from the
--- start to the next point, from the point before to the finish). A new zone starts at your car with
--- its finish 60 m ahead ; a new point goes after the selected one (before the finish otherwise),
--- at your car ; points move with the gizmo. Server side : services/driftZones.lua.
---
--- Each point has its own width (`w`, direct request) : the zone being edited shows a handle at each
--- end of every point's line across the route, dragged like a race gate's edges (raceEditor.lua) :
--- the other end stays put and the point moves to the middle of its line, or with Ctrl held both
--- ends move and the point stays. The sidebar's width slider sets every point's at once. Players
--- call these "drift spots".
---
--- Its edge lines' paint (`edgePaint`, "none" for none) is picked in the sidebar, and its drift signs
--- (`signs`, direct request : at least one a spot, a save is refused without) are added beside the
--- start and moved and turned with the gizmo. The spots being edited show their paint and signs
--- in the world as they change (beamjoy_driftZones.setEditorZones).

local M = {}

local ACTIVE_COLOR = BJColor(0, 1, 1, .9)
local START_COLOR = BJColor(.2, 1, .4, .85)
local FINISH_COLOR = BJColor(1, 1, 1, .9)
local ROUTE_COLOR = BJColor(1, .85, .2, .6)
local EDGE_COLOR = BJColor(1, .45, .1, .5)
local DIM_COLOR = BJColor(1, 1, 1, .45)
local TEXT_BG = BJColor(0, 0, 0, .35)
-- a point's width handles : the posts at the ends of its line across the route (the race gates'
-- own handle colour, raceMarkers.lua), the one being dragged white
local HANDLE_COLOR = BJColor(0, 1, 1, .9)
local HANDLE_DRAG_COLOR = BJColor(1, 1, 1, 1)
local HANDLE_HEIGHT = 2
-- metres between the mouse's ray and a post for a click to take it
local HANDLE_HIT_TOLERANCE = .5
-- ms between two sidebar updates while a handle is dragged
local HANDLE_PUSH_MS = 150

local DEFAULT_WIDTH = 16
local MIN_WIDTH, MAX_WIDTH = 6, 60
local MAX_POINTS = 40
local MAX_NAME_LEN = 40
local NEW_ZONE_LENGTH = 60
-- signs a spot holds (kept in sync with services/driftZones.lua) ; a new one stands this far
-- beside the start's edge and this far before it
local MAX_SIGNS = 4
local SIGN_SIDE_GAP, SIGN_BEFORE = 2.5, 3
local SIGN_COLOR = BJColor(1, .55, .1, .9)

---@type fun(): boolean
local isActive = function() return false end

local state = {
    ---@type table[]
    zones = {},
    ---@type integer?
    activeZone = nil,
    ---@type integer?
    activePoint = nil,
    ---@type integer? a sign of the active zone (never with activePoint)
    activeSign = nil,
    dirty = false,
    snapToGroundEnabled = true,
    ---@type "terrain"|"raycast"
    snapMethod = "terrain",
}

--- a width handle being dragged : the point, its side, the end that stays put (its middle with Ctrl)
--- and the line across the route it slides along (as at the drag's start)
---@type {point: integer, side: "left"|"right", anchor: vec3, axis: vec3, symmetric: boolean}?
local dragging = nil
local lastHandlePush = 0

-- WIRE ------------------------------------------------------------------------------------------

local function pushZones()
    beamjoy_communications_ui.send("BJEditorDriftZonesListUpdate", state.zones)
end

local function pushActive()
    beamjoy_communications_ui.send("BJEditorDriftZonesActiveUpdate",
        { zone = state.activeZone, point = state.activePoint, sign = state.activeSign })
end

--- the edge paints offered in the sidebar : none, then every paint (their names' locale keys)
local function pushPaints()
    local options = { { value = "none", label = "beamjoy.driftZones.edit.edgePaint.none" } }
    for _, p in ipairs(beamjoy_props and beamjoy_props.PAINTS or {}) do
        options[#options + 1] = { value = p.id, label = "beamjoy.props.paints.name." .. p.id }
    end
    beamjoy_communications_ui.send("BJEditorDriftZonesPaints", options)
end

local function pushFullState()
    pushPaints()
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

--- a point's width : its own, else the zone's (beamjoy/driftZones.lua)
---@param zone table
---@param i integer
---@return number
local function pointWidth(zone, i)
    return beamjoy_driftZones.pointWidth(zone, i)
end

---@param zone table
---@param i integer
---@return vec3 pos, vec3 dir, vec3 right its line across the route (beamjoy/driftZones.lua)
local function pointFrame(zone, i)
    return beamjoy_driftZones.pointFrame(zone, i)
end

---@param zone table
---@return {pos: vec3, right: vec3, w: number}[] the route's smooth curve (beamjoy/driftZones.lua)
local function curve(zone)
    return beamjoy_driftZones.curve(zone)
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
    if isActive() and beamjoy_driftZones then beamjoy_driftZones.setEditorZones(state.zones) end
    for zi, zone in ipairs(state.zones) do
        local active = state.activeZone == zi
        local pts = zone.points
        if not active then
            local p = v3(pts[1])
            shape.addSphere(p + vec3(0, 0, .5), .8, DIM_COLOR)
            shape.addText(zone.name ~= "" and zone.name or beamjoy_lang.translate("beamjoy.driftZones.zone"),
                p + vec3(0, 0, 2.5), DIM_COLOR, TEXT_BG)
        else
            -- on the road's surface, as the zone is drawn when driven (beamjoy/driftZones.lua) : its
            -- edges from the end of one point's line across the route to the next's, along its curve
            local samples = curve(zone)
            for i = 2, #samples do
                local a, b = samples[i - 1], samples[i]
                shape.addGroundLine(a.pos, b.pos, .2, ROUTE_COLOR)
                shape.addGroundLine(a.pos - a.right, b.pos - b.right, .1, EDGE_COLOR)
                shape.addGroundLine(a.pos + a.right, b.pos + b.right, .1, EDGE_COLOR)
            end
            -- the gates, across the route
            for _, gate in ipairs({ { 1, START_COLOR }, { #pts, FINISH_COLOR } }) do
                local p, dir, right = pointFrame(zone, gate[1])
                shape.addGroundLine(p - right, p + right, .25, gate[2], .05, 1.5)
                shape.addArrow(p + vec3(0, 0, 1) + dir * 2, dir, 2, gate[2])
            end
            for i, pt in ipairs(pts) do
                local selected = state.activePoint == i
                local color = selected and ACTIVE_COLOR or i == 1 and START_COLOR or i == #pts and FINISH_COLOR or ROUTE_COLOR
                local p, _, right = pointFrame(zone, i)
                shape.addSphere(p + vec3(0, 0, .5), selected and .9 or .6, color)
                shape.addText(string.format("%s  %d m", pointLabel(zone, i), math.round(pointWidth(zone, i))),
                    p + vec3(0, 0, 2), color, TEXT_BG)
                -- its line across the route (the gates draw their own) and a handle at each end
                if i > 1 and i < #pts then shape.addGroundLine(p - right, p + right, .08, ROUTE_COLOR) end
                for _, side in ipairs({ "left", "right" }) do
                    local foot = side == "left" and p - right or p + right
                    local held = dragging and dragging.point == i and dragging.side == side
                    shape.addLine(foot, .25, foot + vec3(0, 0, HANDLE_HEIGHT), .25,
                        held and HANDLE_DRAG_COLOR or HANDLE_COLOR)
                end
            end
            -- its signs : a label over each (the gizmo shows the picked one)
            for si, sign in ipairs(zone.signs or {}) do
                local color = state.activeSign == si and ACTIVE_COLOR or SIGN_COLOR
                shape.addText(string.format("%s %d", beamjoy_lang.translate("beamjoy.driftZones.edit.sign"), si),
                    v3(sign) + vec3(0, 0, 1.8), color, TEXT_BG)
            end
        end
    end
end

local function updateGizmo()
    gizmo.hide()
    local zone = state.activeZone and state.zones[state.activeZone]
    local sign = zone and state.activeSign and zone.signs and zone.signs[state.activeSign]
    if sign then
        -- a sign moves and turns (standing upright)
        gizmo.show({
            pos = v3(sign),
            dir = beamjoy_driftZones.signDir(sign),
            up = vec3(0, 0, 1),
            scales = vec3(1, 1, 1),
        }, function(updated)
            if not isActive() then return end
            if gizmo.tool == "rotate" then
                local d = updated.dir and vec3(updated.dir.x, updated.dir.y, 0)
                if d and d:length() > 1e-4 then
                    d = d:normalized()
                    sign.dir = { x = d.x, y = d.y }
                end
            else
                sign.x, sign.y, sign.z = updated.pos.x, updated.pos.y, updated.pos.z
            end
            renderAll()
            markDirty()
        end, function()
            if state.snapToGroundEnabled then sign.z = groundHeightAt(v3(sign)) end
            renderAll()
            updateGizmo()
            pushZones()
        end)
        return
    end
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

-- WIDTH HANDLES ---------------------------------------------------------------------------------

--- distance from the mouse's ray to a post (the bounded segment ab)
---@param camPos vec3
---@param rayDir vec3 unit
---@param a vec3
---@param b vec3
---@return number
local function rayToSegmentDistance(camPos, rayDir, a, b)
    local seg = b - a
    local len = seg:length()
    if len < 1e-5 then
        return (camPos + rayDir * math.max(0, rayDir:dot(a - camPos))):distance(a)
    end
    local dir = seg / len
    local r = camPos - a
    local bb, f, c = rayDir:dot(dir), dir:dot(r), rayDir:dot(r)
    local denom = 1 - bb * bb
    local t, s
    if math.abs(denom) < 1e-5 then
        t, s = 0, math.max(0, math.min(len, f))
    else
        t = math.max(0, (bb * f - c) / denom)
        s = math.max(0, math.min(len, (f - bb * c) / denom))
    end
    return (camPos + rayDir * t):distance(a + dir * s)
end

--- where along a line (through `origin`, unit `dir`) the mouse's ray passes closest : the race
--- gates' handles' own math (raceEditor.lua closestLineParam)
---@return number u signed metres along dir from origin
local function closestLineParam(camPos, rayDir, origin, dir)
    local r = camPos - origin
    local b, f, c = rayDir:dot(dir), dir:dot(r), rayDir:dot(r)
    local denom = 1 - b * b
    if math.abs(denom) < 1e-5 then return f end
    if (b * f - c) / denom < 0 then return f end
    return (f - b * c) / denom
end

--- the handle under the mouse, on the zone being edited
---@return integer? point, "left"|"right"|nil side
local function hitTestHandles(camPos, rayDir)
    local zone = state.activeZone and state.zones[state.activeZone]
    if not zone then return nil end
    local best, bestPoint, bestSide = HANDLE_HIT_TOLERANCE, nil, nil
    for i = 1, #zone.points do
        local p, _, right = pointFrame(zone, i)
        for _, side in ipairs({ "left", "right" }) do
            local foot = side == "left" and p - right or p + right
            local d = rayToSegmentDistance(camPos, rayDir, foot, foot + vec3(0, 0, HANDLE_HEIGHT))
            if d < best then best, bestPoint, bestSide = d, i, side end
        end
    end
    return bestPoint, bestSide
end

---@param pi integer
---@param side "left"|"right"
---@param symmetric boolean
local function beginHandleDrag(pi, side, symmetric)
    local zone = state.zones[state.activeZone]
    local p, _, right = pointFrame(zone, pi)
    local axis = right:normalized()
    -- the other end stays put, or the point itself with Ctrl
    local anchor = symmetric and p or (side == "left" and p + right or p - right)
    dragging = { point = pi, side = side, anchor = anchor, axis = axis, symmetric = symmetric }
    if state.activePoint ~= pi then
        state.activePoint = pi
        pushActive()
    end
    gizmo.hide()
    renderAll()
end

---@param camPos vec3
---@param rayDir vec3
local function updateHandleDrag(camPos, rayDir)
    local zone = state.activeZone and state.zones[state.activeZone]
    local pt = zone and zone.points[dragging.point]
    if not pt then
        dragging = nil
        return
    end
    local u = closestLineParam(camPos, rayDir, dragging.anchor, dragging.axis)
    if dragging.side == "left" then u = -u end
    local width = math.max(MIN_WIDTH, math.min(MAX_WIDTH, dragging.symmetric and u * 2 or u))
    pt.w = width
    if not dragging.symmetric then
        -- the point to the middle of its line, the other end where it was
        local half = dragging.axis * (width / 2)
        local center = dragging.side == "left" and dragging.anchor - half or dragging.anchor + half
        pt.x, pt.y = center.x, center.y
    end
    renderAll()
    markDirty()
    local now = GetCurrentTimeMillis()
    if now - lastHandlePush > HANDLE_PUSH_MS then
        lastHandlePush = now
        pushZones()
    end
end

local function endHandleDrag()
    local zone = state.activeZone and state.zones[state.activeZone]
    local pt = zone and dragging and zone.points[dragging.point]
    local moved = dragging and not dragging.symmetric
    dragging = nil
    if pt then
        pt.w = math.round(pt.w or pointWidth(zone, state.activePoint or 1), 1)
        if moved and state.snapToGroundEnabled then pt.z = groundHeightAt(v3(pt)) end
    end
    renderAll()
    updateGizmo()
    pushZones()
end

--- per frame while this section is open (freeroamEditor.onUpdate) : a click on a handle starts
--- its drag, the mouse's release ends it
local function onUpdate()
    if not isActive() then
        dragging = nil
        return
    end
    if dragging then
        if not ui_imgui.IsMouseDown(ui_imgui.MouseButton_Left) then return endHandleDrag() end
        local camPos, rayDir = camera.mouseRay()
        if camPos then updateHandleDrag(camPos, rayDir) end
        return
    end
    if not state.activeZone or not ui_imgui.IsMouseClicked(ui_imgui.MouseButton_Left) then return end
    if (getCEFFocusMouse and getCEFFocusMouse() == true) or (gizmo.isHovered and gizmo.isHovered()) then return end
    local camPos, rayDir = camera.mouseRay()
    if not camPos then return end
    local pi, side = hitTestHandles(camPos, rayDir)
    if pi then
        local io = ui_imgui.GetIO()
        beginHandleDrag(pi, side, io ~= nil and io.KeyCtrl == true)
    end
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
    state.activePoint, state.activeSign = nil, nil
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
    state.activeSign = nil
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
    table.insert(state.zones, { name = "", width = DEFAULT_WIDTH, edgePaint = beamjoy_driftZones.DEFAULT_EDGE_PAINT,
        signs = {}, points = { xyz(pos), xyz(finish) } })
    state.activeZone, state.activePoint, state.activeSign = #state.zones, 2, nil
    changed()
end

---@param zi integer
local function onDeleteZone(zi)
    if not isActive() or not zoneAt(zi) then return end
    table.remove(state.zones, tonumber(zi))
    state.activeZone, state.activePoint, state.activeSign = nil, nil, nil
    changed()
end

---@param zi integer
---@param partial table name / width / edgePaint
local function onSetZone(zi, partial)
    if not isActive() then return end
    local zone = zoneAt(zi)
    if not zone or type(partial) ~= "table" then return end
    if type(partial.name) == "string" then zone.name = partial.name:sub(1, MAX_NAME_LEN) end
    if type(partial.edgePaint) == "string" and (partial.edgePaint == "none" or
            (beamjoy_props and beamjoy_props.getPaint(partial.edgePaint))) then
        zone.edgePaint = partial.edgePaint
    end
    if partial.width ~= nil then
        zone.width = math.max(MIN_WIDTH, math.min(MAX_WIDTH, tonumber(partial.width) or zone.width))
        -- the slider : every point's width at once
        for _, pt in ipairs(zone.points) do pt.w = zone.width end
        pushZones()
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
    -- as wide as the two points it goes between, halfway
    local new = xyz(pos)
    new.w = math.round((pointWidth(zone, at - 1) + pointWidth(zone, at)) / 2, 1)
    table.insert(zone.points, at, new)
    state.activeZone, state.activePoint, state.activeSign = tonumber(zi), at, nil
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

--- a drift sign beside a gate, facing the cars coming to it : the first two on the right then the
--- left of the start's line, the next two the same at the finish (direct request : the 3rd and 4th
--- stood on the 1st and 2nd)
---@param zi integer
local function onAddSign(zi)
    if not isActive() then return end
    local zone = zoneAt(zi)
    if not zone then return end
    zone.signs = zone.signs or {}
    if #zone.signs >= MAX_SIGNS then return end
    local p, dir, right = pointFrame(zone, #zone.signs < 2 and 1 or #zone.points)
    local out = right:normalized() * (right:length() + SIGN_SIDE_GAP)
    local pos = p - dir * SIGN_BEFORE + (#zone.signs % 2 == 0 and out or -out)
    pos = vec3(pos.x, pos.y, groundHeightAt(pos))
    -- its face (the mesh's -Y) towards them : its +Y along the route
    table.insert(zone.signs, { x = pos.x, y = pos.y, z = pos.z, dir = { x = dir.x, y = dir.y } })
    state.activeZone, state.activePoint, state.activeSign = tonumber(zi), nil, #zone.signs
    changed()
end

---@param zi integer
---@param si integer
local function onSelectSign(zi, si)
    if not isActive() then return end
    local zone = zoneAt(zi)
    si = tonumber(si)
    if not zone or not si or not (zone.signs and zone.signs[si]) then return end
    state.activeZone = tonumber(zi)
    state.activeSign = state.activeSign == si and nil or si
    state.activePoint = nil
    renderAll()
    updateGizmo()
    pushActive()
end

---@param zi integer
---@param si integer
local function onDeleteSign(zi, si)
    if not isActive() then return end
    local zone = zoneAt(zi)
    si = tonumber(si)
    if not zone or not si or not (zone.signs and zone.signs[si]) then return end
    table.remove(zone.signs, si)
    state.activeSign = nil
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
    local new = xyz(pos)
    new.w = pt.w
    zone.points[tonumber(pi)] = new
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
    local zone = state.activeZone and state.zones[state.activeZone]
    local bestSign
    for si, sign in ipairs(zone and zone.signs or {}) do
        local p = v3(sign) + vec3(0, 0, 1.2)
        local along = (p - camPos):dot(rayDir)
        if along > 0 and (camPos + rayDir * along):distance(p) <= 1.2 and (not best or along < best) then
            best, bestSign = along, si
        end
    end
    if bestSign then
        if state.activeSign ~= bestSign then
            state.activePoint, state.activeSign = nil, bestSign
            renderAll()
            updateGizmo()
            pushActive()
        end
        return
    end
    if bestZone and not (bestZone == state.activeZone and bestPoint == state.activePoint) then
        state.activeZone, state.activePoint, state.activeSign = bestZone, bestPoint, nil
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
            edgePaint = type(z.edgePaint) == "string" and z.edgePaint or beamjoy_driftZones.DEFAULT_EDGE_PAINT,
            signs = table.map(type(z.signs) == "table" and z.signs or {}, function(s)
                return { x = s.x, y = s.y, z = s.z, dir = type(s.dir) == "table" and { x = s.dir.x, y = s.dir.y } or nil }
            end),
            points = table.map(z.points or {}, function(p) return { x = p.x, y = p.y, z = p.z, w = p.w } end),
        }
    end
    if not state.activeZone or not state.zones[state.activeZone] then
        state.activeZone, state.activePoint, state.activeSign = nil, nil, nil
    else
        if state.activePoint and not state.zones[state.activeZone].points[state.activePoint] then
            state.activePoint = nil
        end
        if state.activeSign and not state.zones[state.activeZone].signs[state.activeSign] then
            state.activeSign = nil
        end
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
    dragging = nil
    -- the saved spots back in the world
    if beamjoy_driftZones then beamjoy_driftZones.setEditorZones(nil) end
end

local function close()
    gizmo.hide()
    dragging = nil
    state.zones = {}
    state.activeZone, state.activePoint, state.activeSign = nil, nil, nil
    state.dirty = false
    if beamjoy_driftZones then beamjoy_driftZones.setEditorZones(nil) end
end

---@param onDone fun(ok: boolean)?
local function save(onDone)
    -- every spot needs a sign (direct request) : the first without one picked, and nothing sent
    for zi, z in ipairs(state.zones) do
        if not z.signs or #z.signs == 0 then
            local name = (z.name or "") ~= "" and z.name or
                string.format("%s %d", beamjoy_lang.translate("beamjoy.driftZones.zone"), zi)
            toast.error(string.var(beamjoy_lang.translate("beamjoy.driftZones.edit.missingSign"), { name = name }))
            state.activeZone, state.activePoint, state.activeSign = zi, nil, nil
            renderAll()
            updateGizmo()
            pushActive()
            if onDone then onDone(false) end
            return
        end
    end
    local payload = table.map(state.zones, function(z)
        return {
            id = z.id,
            name = z.name,
            width = math.round(tonumber(z.width) or DEFAULT_WIDTH, 1),
            edgePaint = z.edgePaint,
            signs = table.map(z.signs, function(s)
                local d = beamjoy_driftZones.signDir(s)
                return { x = math.round(s.x, 3), y = math.round(s.y, 3), z = math.round(s.z, 3),
                    dir = { x = math.round(d.x, 4), y = math.round(d.y, 4) } }
            end),
            points = table.map(z.points, function(p, i)
                return { x = math.round(p.x, 3), y = math.round(p.y, 3), z = math.round(p.z, 3),
                    w = math.round(pointWidth(z, i), 1) }
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
            toast.error(err or "Failed to save the drift spots")
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
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesAddSign", onAddSign)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesSelectSign", onSelectSign)
    beamjoy_communications_ui.addHandler("BJEditorDriftZonesDeleteSign", onDeleteSign)
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
M.onUpdate = onUpdate
M.isDirty = function() return state.dirty end

return M
