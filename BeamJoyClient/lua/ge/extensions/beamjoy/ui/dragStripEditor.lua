--- In-world drag strip editor : the "Drag strips" section of Config > Freeroam, a sub-editor hosted
--- by `freeroamEditor.lua` like the bus lines one (`busLineEditor.lua`, the same host contract :
--- refresh / standUp / standDown / close / save / onBJClick).
---
--- A strip is a name, its timed distance, its tree and lane width, and its lanes : each lane is its
--- start line's middle and the way it runs (`dir`, kept flat). Lanes are placed like bus stops (at
--- your car, facing your way ; a new lane beside the strip's last one) and moved with the gizmo.
--- Shown here : every lane's start line, and for the strip being edited its whole length (lane
--- edges, the marks, the finish line). Server side : services/dragStrips.lua.

local M = {}

local ACTIVE_COLOR = BJColor(0, 1, 1, .9)
local LINE_COLOR = BJColor(1, 1, 1, .85)
local MARK_COLOR = BJColor(1, .85, .2, .8)
local EDGE_COLOR = BJColor(1, 1, 1, .4)
local DIM_COLOR = BJColor(1, 1, 1, .45)
local TEXT_BG = BJColor(0, 0, 0, .35)

local DEFAULT_LANE_WIDTH = 4
local MIN_LANE_WIDTH, MAX_LANE_WIDTH = 2, 8
local MAX_LANES = 4
local MAX_NAME_LEN = 40

---@type fun(): boolean
local isActive = function() return false end

local state = {
    ---@type table[]
    strips = {},
    ---@type integer?
    activeStrip = nil,
    ---@type integer?
    activeLane = nil,
    dirty = false,
    snapToGroundEnabled = true,
    ---@type "terrain"|"raycast"
    snapMethod = "terrain",
}

-- WIRE ------------------------------------------------------------------------------------------

local function pushStrips()
    beamjoy_communications_ui.send("BJEditorDragStripsListUpdate", state.strips)
end

local function pushActive()
    beamjoy_communications_ui.send("BJEditorDragStripsActiveUpdate",
        { strip = state.activeStrip, lane = state.activeLane })
end

local function pushFullState()
    pushStrips()
    pushActive()
    beamjoy_communications_ui.send("BJEditorDirty", state.dirty)
    beamjoy_communications_ui.send("BJEditorDragStripsSnapToGround", state.snapToGroundEnabled)
    beamjoy_communications_ui.send("BJEditorDragStripsSnapMethod", state.snapMethod)
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

-- RENDER ------------------------------------------------------------------------------------

local function renderAll()
    shape.reset()
    local lift = vec3(0, 0, .05)
    for si, strip in ipairs(state.strips) do
        local active = state.activeStrip == si
        local half = (tonumber(strip.laneWidth) or DEFAULT_LANE_WIDTH) / 2
        local marks, finishId = beamjoy_dragStrips.marksOf(strip)
        for li, lane in ipairs(strip.lanes) do
            local p = vec3(lane.pos.x, lane.pos.y, lane.pos.z) + lift
            local dir = vec3(lane.dir.x, lane.dir.y, 0):normalized()
            local right = dir:cross(vec3(0, 0, 1)) * half
            local selected = active and state.activeLane == li
            local color = selected and ACTIVE_COLOR or active and LINE_COLOR or DIM_COLOR
            shape.addLine(p - right, .15, p + right, .15, color)
            shape.addArrow(p + vec3(0, 0, .5) + dir * 2, dir, 2, color)
            shape.addText(string.format("%s, %s %d", strip.name ~= "" and strip.name or
                    beamjoy_lang.translate("beamjoy.dragStrips.strip"),
                    beamjoy_lang.translate("beamjoy.dragStrips.lane"), li),
                p + vec3(0, 0, 2), color, TEXT_BG)
            if active then
                -- the whole lane : its edges to the finish, every mark across it
                local finishDistance = 0
                for _, m in ipairs(marks) do
                    if m.type == "distanceTimer" and m.distance > 1 then
                        local c = p + dir * m.distance
                        local isFinish = m.id == finishId
                        shape.addLine(c - right, isFinish and .25 or .08, c + right, isFinish and .25 or .08,
                            isFinish and LINE_COLOR or MARK_COLOR)
                        if isFinish then finishDistance = m.distance end
                    end
                end
                shape.addLine(p - right, .06, p - right + dir * finishDistance, .06, EDGE_COLOR)
                shape.addLine(p + right, .06, p + right + dir * finishDistance, .06, EDGE_COLOR)
            end
        end
    end
end

local function updateGizmo()
    gizmo.hide()
    local strip = state.activeStrip and state.strips[state.activeStrip]
    local lane = strip and state.activeLane and strip.lanes[state.activeLane]
    if not lane then return end
    gizmo.show({
        pos = vec3(lane.pos.x, lane.pos.y, lane.pos.z),
        dir = vec3(lane.dir.x, lane.dir.y, 0),
        up = vec3(0, 0, 1),
        scales = vec3(1, 1, 1),
    }, function(updated)
        if not isActive() then return end
        lane.pos = xyz(updated.pos)
        local flat = vec3(updated.dir.x, updated.dir.y, 0)
        if flat:length() < 1e-4 then flat = vec3(lane.dir.x, lane.dir.y, 0) end
        flat = flat:normalized()
        lane.dir = { x = flat.x, y = flat.y, z = 0 }
        renderAll()
        markDirty()
    end, function()
        if state.snapToGroundEnabled then
            lane.pos.z = groundHeightAt(vec3(lane.pos.x, lane.pos.y, lane.pos.z))
        end
        renderAll()
        updateGizmo()
        pushStrips()
    end)
end

local function changed()
    renderAll()
    updateGizmo()
    pushStrips()
    pushActive()
    markDirty()
end

-- MUTATIONS ---------------------------------------------------------------------------------

---@param si any
---@return table?
local function stripAt(si)
    si = tonumber(si)
    return si and state.strips[si] or nil
end

---@param si integer?
local function onSelectStrip(si)
    if not isActive() then return end
    si = tonumber(si)
    if si and state.strips[si] then
        state.activeStrip = (state.activeStrip == si and not state.activeLane) and nil or si
    else
        state.activeStrip = nil
    end
    state.activeLane = nil
    renderAll()
    updateGizmo()
    pushActive()
end

---@param si integer
---@param li integer
local function onSelectLane(si, li)
    if not isActive() then return end
    local strip = stripAt(si)
    li = tonumber(li)
    if not strip or not li or not strip.lanes[li] then return end
    state.activeStrip = tonumber(si)
    state.activeLane = state.activeLane == li and nil or li
    renderAll()
    updateGizmo()
    pushActive()
end

local function onAddStrip()
    if not isActive() then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    table.insert(state.strips, {
        name = "",
        length = "1_4",
        tree = "sportsman",
        laneWidth = DEFAULT_LANE_WIDTH,
        lanes = { { pos = xyz(pos), dir = xyz(dir) } },
    })
    state.activeStrip, state.activeLane = #state.strips, 1
    changed()
end

---@param si integer
local function onDeleteStrip(si)
    if not isActive() or not stripAt(si) then return end
    table.remove(state.strips, tonumber(si))
    state.activeStrip, state.activeLane = nil, nil
    changed()
end

---@param si integer
---@param partial table name / length / tree / laneWidth
local function onSetStrip(si, partial)
    if not isActive() then return end
    local strip = stripAt(si)
    if not strip or type(partial) ~= "table" then return end
    if type(partial.name) == "string" then strip.name = partial.name:sub(1, MAX_NAME_LEN) end
    if table.includes(beamjoy_dragStrips.LENGTHS, partial.length) then strip.length = partial.length end
    if partial.tree == "sportsman" or partial.tree == "pro" then strip.tree = partial.tree end
    if partial.laneWidth ~= nil then
        strip.laneWidth = math.max(MIN_LANE_WIDTH, math.min(MAX_LANE_WIDTH, tonumber(partial.laneWidth) or strip.laneWidth))
    end
    renderAll()
    -- no pushStrips : the sidebar holds these values itself (a re-push mid-typing drops focus)
    markDirty()
end

--- a new lane : beside the strip's last one (one lane width to its right, facing the same way),
--- or at your car for a strip with none
---@param si integer
local function onAddLane(si)
    if not isActive() then return end
    local strip = stripAt(si)
    if not strip or #strip.lanes >= MAX_LANES then return end
    local last = strip.lanes[#strip.lanes]
    local lane
    if last then
        local dir = vec3(last.dir.x, last.dir.y, 0):normalized()
        local pos = vec3(last.pos.x, last.pos.y, last.pos.z) + dir:cross(vec3(0, 0, 1)) * strip.laneWidth
        if state.snapToGroundEnabled then pos = vec3(pos.x, pos.y, groundHeightAt(pos)) end
        lane = { pos = xyz(pos), dir = xyz(dir) }
    else
        local pos, dir = currentPositionDirection()
        if not pos then return end
        lane = { pos = xyz(pos), dir = xyz(dir) }
    end
    table.insert(strip.lanes, lane)
    state.activeStrip, state.activeLane = tonumber(si), #strip.lanes
    changed()
end

---@param si integer
---@param li integer
local function onDeleteLane(si, li)
    if not isActive() then return end
    local strip = stripAt(si)
    li = tonumber(li)
    if not strip or not li or not strip.lanes[li] or #strip.lanes <= 1 then return end
    table.remove(strip.lanes, li)
    state.activeLane = nil
    changed()
end

---@param si integer
---@param li integer
local function onSetLaneToVehicle(si, li)
    if not isActive() then return end
    local strip = stripAt(si)
    local lane = strip and strip.lanes[tonumber(li)]
    if not lane then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    lane.pos, lane.dir = xyz(pos), xyz(dir)
    changed()
end

--- your car a few metres short of the lane's start line, facing down it
---@param si integer
---@param li integer
local function onTeleportToLane(si, li)
    if not isActive() then return end
    local strip = stripAt(si)
    local lane = strip and strip.lanes[tonumber(li)]
    local current = beamjoy_vehicles.getCurrentOwn()
    if not lane or not current then return end
    local dir = vec3(lane.dir.x, lane.dir.y, 0):normalized()
    beamjoy_vehicles.setVehiclePositionRotation(current.veh,
        vec3(lane.pos.x, lane.pos.y, lane.pos.z) - dir * 8, dir, vec3(0, 0, 1))
end

---@param enabled boolean
local function onSetSnapToGround(enabled)
    state.snapToGroundEnabled = enabled == true
    beamjoy_communications_ui.send("BJEditorDragStripsSnapToGround", state.snapToGroundEnabled)
end

---@param method string
local function onSetSnapMethod(method)
    state.snapMethod = method == "raycast" and "raycast" or "terrain"
    beamjoy_communications_ui.send("BJEditorDragStripsSnapMethod", state.snapMethod)
end

--- click a lane's start line in the world to pick it
---@param clickType string
local function onBJClick(clickType)
    if clickType ~= "left" or not isActive() then return end
    local camPos, rayDir = camera.mouseRay()
    if not camPos then return end
    local best, bestStrip, bestLane
    for si, strip in ipairs(state.strips) do
        for li, lane in ipairs(strip.lanes) do
            local p = vec3(lane.pos.x, lane.pos.y, lane.pos.z)
            local along = (p - camPos):dot(rayDir)
            if along > 0 and (camPos + rayDir * along):distance(p) <= math.max(1.5, strip.laneWidth / 2) and
                (not best or along < best) then
                best, bestStrip, bestLane = along, si, li
            end
        end
    end
    if bestStrip and not (bestStrip == state.activeStrip and bestLane == state.activeLane) then
        state.activeStrip, state.activeLane = bestStrip, bestLane
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
    state.strips = {}
    for _, s in ipairs(beamjoy_dragStrips and beamjoy_dragStrips.strips or {}) do
        local lanes = {}
        for _, lane in ipairs(s.lanes or {}) do
            lanes[#lanes + 1] = {
                pos = { x = lane.pos.x, y = lane.pos.y, z = lane.pos.z },
                dir = { x = lane.dir.x, y = lane.dir.y, z = 0 },
            }
        end
        state.strips[#state.strips + 1] = {
            id = s.id,
            name = s.name or "",
            length = s.length or "1_4",
            tree = s.tree or "sportsman",
            laneWidth = s.laneWidth or DEFAULT_LANE_WIDTH,
            lanes = lanes,
        }
    end
    if not state.activeStrip or not state.strips[state.activeStrip] then
        state.activeStrip, state.activeLane = nil, nil
    elseif state.activeLane and not state.strips[state.activeStrip].lanes[state.activeLane] then
        state.activeLane = nil
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
    state.strips = {}
    state.activeStrip, state.activeLane = nil, nil
    state.dirty = false
end

---@param onDone fun(ok: boolean)?
local function save(onDone)
    local payload = {}
    for _, s in ipairs(state.strips) do
        payload[#payload + 1] = {
            id = s.id,
            name = s.name,
            length = s.length,
            tree = s.tree,
            laneWidth = math.round(tonumber(s.laneWidth) or DEFAULT_LANE_WIDTH, 2),
            lanes = table.map(s.lanes, function(lane)
                return {
                    pos = { x = math.round(lane.pos.x, 3), y = math.round(lane.pos.y, 3), z = math.round(lane.pos.z, 3) },
                    dir = { x = math.round(lane.dir.x, 4), y = math.round(lane.dir.y, 4), z = 0 },
                }
            end),
        }
    end
    beamjoy_communications.send("dragStripsSave", payload)
    beamjoy_communications.addOneUseHandler("dragStripsSaved", function(status, err)
        if status then
            if state.dirty then
                state.dirty = false
                beamjoy_communications_ui.send("BJEditorDirty", false)
            end
        else
            refresh()
            standUp()
            toast.error(err or "Failed to save the drag strips")
        end
        if onDone then onDone(status == true) end
    end, 5000)
end

local function onInit()
    beamjoy_communications_ui.addHandler("BJEditorDragStripsSelectStrip", onSelectStrip)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsSelectLane", onSelectLane)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsAddStrip", onAddStrip)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsDeleteStrip", onDeleteStrip)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsSetStrip", onSetStrip)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsAddLane", onAddLane)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsDeleteLane", onDeleteLane)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsSetLaneToVehicle", onSetLaneToVehicle)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsTeleportToLane", onTeleportToLane)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsSetSnapToGround", onSetSnapToGround)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsSetSnapMethod", onSetSnapMethod)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsRequestState", pushFullState)
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
