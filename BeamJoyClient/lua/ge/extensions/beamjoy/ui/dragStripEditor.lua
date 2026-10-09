--- In-world drag strip editor : the "Drag strips" section of Config > Freeroam, a sub-editor hosted
--- by `freeroamEditor.lua` like the bus lines one (`busLineEditor.lua`, the same host contract :
--- refresh / standUp / standDown / close / save / onBJClick).
---
--- A strip is laid out like a prop line (direct request) : two handles, the middle of its start line
--- and the middle of its finish line, each moved with the gizmo ; the strip runs straight between
--- them and its lanes lie side by side across it, all parallel (a lane count, a lane width and the
--- gap between two lanes). Ctrl held while dragging a handle moves the whole strip ; turning the
--- start handle with the rotate tool swings the strip round its start. Dropped, the finish handle
--- goes back to the strip's timed distance on the line it was dragged to, and both sit on the
--- road's surface, so a strip on a slope or a cambered road is drawn on it.
---
--- Saved as the server keeps them (services/dragStrips.lua) : each lane's start line middle and the
--- way it runs ; read back, a strip's handles come from its lanes. Shown here : every strip's start
--- lines, and for the strip being edited its whole length (beamjoy_dragStrips.drawStrip) with its
--- handles.

local M = {}

local ACTIVE_COLOR = BJColor(0, 1, 1, .9)
local LINE_COLOR = BJColor(1, 1, 1, .85)
local MARK_COLOR = BJColor(1, .85, .2, .8)
local EDGE_COLOR = BJColor(1, 1, 1, .4)
local AXIS_COLOR = BJColor(0, 1, 1, .35)
local DIM_COLOR = BJColor(1, 1, 1, .45)
local HANDLE_COLOR = BJColor(1, 1, 1, .7)
local TEXT_BG = BJColor(0, 0, 0, .35)

local DEFAULT_LANE_WIDTH = 4
local MIN_LANE_WIDTH, MAX_LANE_WIDTH = 2, 8
local MAX_LANE_GAP = 10
local DEFAULT_LANES = 2
local MAX_LANES = 4
local MAX_NAME_LEN = 40
-- metres : where a click picks a handle (round the sphere drawn on it)
local HANDLE_PICK = 2

---@type fun(): boolean
local isActive = function() return false end

local state = {
    ---@type table[] {id, name, length, tree, laneWidth, laneGap, laneCount, start, finish}
    strips = {},
    ---@type integer?
    activeStrip = nil,
    ---@type "start"|"finish"|nil the handle the gizmo holds
    activeHandle = nil,
    dirty = false,
    snapToGroundEnabled = true,
    ---@type "terrain"|"raycast"
    snapMethod = "raycast",
}

---@param v vec3|table
---@return table
local function xyz(v) return { x = v.x, y = v.y, z = v.z } end

---@param v table {x, y, z}
---@return vec3
local function v3(v) return vec3(v.x, v.y, v.z) end

-- GEOMETRY ------------------------------------------------------------------------------------

---@param pos vec3
---@return number
local function groundHeightAt(pos)
    if state.snapMethod ~= "raycast" then
        local h = core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(pos)
        if h then return h end
    end
    -- from a few metres up : a strip under a bridge stays on its road
    return shape.onGround(pos).z
end

---@param pos vec3
---@return vec3 pos on the ground (snapping on), as it is otherwise
local function grounded(pos)
    if not state.snapToGroundEnabled then return pos end
    return vec3(pos.x, pos.y, groundHeightAt(pos))
end

---@param d vec3
---@param fallback vec3?
---@return vec3 d made horizontal and unit
local function flat(d, fallback)
    local f = vec3(d.x, d.y, 0)
    if f:length() < 1e-4 then return fallback or vec3(0, 1, 0) end
    return f:normalized()
end

---@param strip table
---@return number metres from the start line to the finish line
local function finishDistance(strip)
    local marks, finishId = beamjoy_dragStrips.marksOf(strip)
    for _, m in ipairs(marks) do
        if m.id == finishId then return m.distance end
    end
    return 402.336
end

---@param strip table
---@return vec3 dir the way the strip runs (horizontal), vec3 right across it
local function axes(strip)
    local dir = flat(v3(strip.finish) - v3(strip.start))
    return dir, dir:cross(vec3(0, 0, 1))
end

--- each lane's start line middle, side by side across the start handle
---@param strip table
---@return {pos: vec3, dir: vec3}[]
local function lanesOf(strip)
    local dir, right = axes(strip)
    local start = v3(strip.start)
    local spacing = strip.laneWidth + strip.laneGap
    local lanes = {}
    for i = 1, strip.laneCount do
        local offset = ((i - 1) - (strip.laneCount - 1) / 2) * spacing
        lanes[i] = { pos = grounded(start + right * offset), dir = dir }
    end
    return lanes
end

--- the finish handle back on the strip's timed distance, along the way it points
---@param strip table
local function fitFinish(strip)
    local dir = axes(strip)
    strip.finish = xyz(grounded(v3(strip.start) + dir * finishDistance(strip)))
end

--- a strip as the server keeps it (its lanes) read as handles : the start in the middle of the
--- lanes' start lines, the finish down the first lane's way, the lanes' spacing kept as the gap
---@param s table
---@return table
local function fromSaved(s)
    local laneWidth = tonumber(s.laneWidth) or DEFAULT_LANE_WIDTH
    local saved = {}
    for _, lane in ipairs(s.lanes or {}) do
        if lane.pos and lane.dir then saved[#saved + 1] = lane end
    end
    local strip = {
        id = s.id,
        name = s.name or "",
        length = s.length or "1_4",
        tree = s.tree or "sportsman",
        laneWidth = laneWidth,
        laneGap = 0,
        laneCount = math.max(1, math.min(MAX_LANES, #saved)),
    }
    if #saved == 0 then
        strip.start, strip.finish = { x = 0, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }
        return strip
    end
    local dir = flat(v3(saved[1].dir))
    local right = dir:cross(vec3(0, 0, 1))
    local first = v3(saved[1].pos)
    local across = table.map(saved, function(lane) return (v3(lane.pos) - first):dot(right) end)
    local lo, hi, center = math.huge, -math.huge, vec3(0, 0, 0)
    for i, x in ipairs(across) do
        lo, hi = math.min(lo, x), math.max(hi, x)
        center = center + v3(saved[i].pos)
    end
    center = center / #saved
    if #saved > 1 then
        local spacing = (hi - lo) / (#saved - 1)
        strip.laneGap = math.max(0, math.min(MAX_LANE_GAP, math.round(spacing - laneWidth, 2)))
    end
    strip.start = xyz(center)
    strip.finish = xyz(grounded(center + dir * finishDistance(strip)))
    return strip
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
    return grounded(pos), flat(dir or vec3(0, 1, 0))
end

--- Ctrl held while a handle is dragged : the whole strip goes with it (as for a prop line)
---@return boolean
local function ctrlHeld()
    local ok, held = pcall(function()
        local io = ui_imgui.GetIO()
        return io ~= nil and io.KeyCtrl == true
    end)
    return ok and held == true
end

-- WIRE ------------------------------------------------------------------------------------------

local function pushStrips()
    beamjoy_communications_ui.send("BJEditorDragStripsListUpdate", table.map(state.strips, function(s)
        return {
            name = s.name,
            length = s.length,
            tree = s.tree,
            laneWidth = s.laneWidth,
            laneGap = s.laneGap,
            laneCount = s.laneCount,
        }
    end))
end

local function pushActive()
    beamjoy_communications_ui.send("BJEditorDragStripsActiveUpdate",
        { strip = state.activeStrip, handle = state.activeHandle })
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

-- RENDER ------------------------------------------------------------------------------------

local function renderAll()
    shape.reset()
    local colors = { line = LINE_COLOR, mark = MARK_COLOR, edge = EDGE_COLOR }
    local dimColors = { line = DIM_COLOR, mark = DIM_COLOR, edge = DIM_COLOR }
    for si, strip in ipairs(state.strips) do
        local active = state.activeStrip == si
        local drawn = { length = strip.length, laneWidth = strip.laneWidth, lanes = lanesOf(strip) }
        beamjoy_dragStrips.drawStrip(shape, drawn, active and colors or dimColors, { startOnly = not active })
        local start, finish = v3(strip.start), v3(strip.finish)
        local dir = axes(strip)
        if active then
            -- the strip's middle, handle to handle : what lines it up with the road
            shape.addGroundLine(start, finish, .05, AXIS_COLOR, .04, 8)
            for li, lane in ipairs(drawn.lanes) do
                shape.addText(string.format("%s %d", beamjoy_lang.translate("beamjoy.dragStrips.lane"), li),
                    lane.pos + vec3(0, 0, 1.2), LINE_COLOR, TEXT_BG)
            end
            for _, handle in ipairs({ { "start", start }, { "finish", finish } }) do
                local selected = state.activeHandle == handle[1]
                local color = selected and ACTIVE_COLOR or HANDLE_COLOR
                shape.addSphere(handle[2] + vec3(0, 0, .5), selected and .9 or .7, color)
                shape.addText(beamjoy_lang.translate("beamjoy.dragStrips.edit.handle." .. handle[1]),
                    handle[2] + vec3(0, 0, 2.2), color, TEXT_BG)
            end
            shape.addArrow(start + vec3(0, 0, .5) + dir * 3, dir, 2, ACTIVE_COLOR)
        else
            shape.addText(strip.name ~= "" and strip.name or beamjoy_lang.translate("beamjoy.dragStrips.strip"),
                start + vec3(0, 0, 2), DIM_COLOR, TEXT_BG)
        end
    end
end

---@param strip table
---@param delta vec3
local function shiftStrip(strip, delta)
    strip.start = xyz(v3(strip.start) + delta)
    strip.finish = xyz(v3(strip.finish) + delta)
end

local function updateGizmo()
    gizmo.hide()
    local strip = state.activeStrip and state.strips[state.activeStrip]
    local handle = strip and state.activeHandle
    if not handle then return end
    gizmo.show({
        pos = v3(strip[handle]),
        dir = axes(strip),
        up = vec3(0, 0, 1),
        scales = vec3(1, 1, 1),
    }, function(updated)
        if not isActive() then return end
        local before = v3(strip[handle])
        if ctrlHeld() then
            shiftStrip(strip, updated.pos - before)
        elseif handle == "start" and gizmo.tool == "rotate" then
            -- turned : the strip swings round its start
            local reach = vec3(strip.finish.x - before.x, strip.finish.y - before.y, 0):length()
            strip.finish = xyz(before + flat(updated.dir, axes(strip)) * math.max(reach, 1))
        else
            strip[handle] = xyz(updated.pos)
        end
        renderAll()
        markDirty()
    end, function()
        -- the start back on the road, the finish on the timed distance along the new line
        strip.start = xyz(grounded(v3(strip.start)))
        fitFinish(strip)
        renderAll()
        updateGizmo()
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
    if si and state.strips[si] and state.activeStrip ~= si then
        state.activeStrip, state.activeHandle = si, "start"
    else
        state.activeStrip, state.activeHandle = nil, nil
    end
    renderAll()
    updateGizmo()
    pushActive()
end

---@param si integer
---@param handle "start"|"finish"
local function onSelectHandle(si, handle)
    if not isActive() or not stripAt(si) or (handle ~= "start" and handle ~= "finish") then return end
    state.activeStrip, state.activeHandle = tonumber(si), handle
    renderAll()
    updateGizmo()
    pushActive()
end

--- starting at your car, running the way it faces
local function onAddStrip()
    if not isActive() then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    local strip = {
        name = "",
        length = "1_4",
        tree = "sportsman",
        laneWidth = DEFAULT_LANE_WIDTH,
        laneGap = 0,
        laneCount = DEFAULT_LANES,
        start = xyz(pos),
    }
    strip.finish = xyz(pos + dir)
    fitFinish(strip)
    table.insert(state.strips, strip)
    state.activeStrip, state.activeHandle = #state.strips, "start"
    changed()
end

---@param si integer
local function onDeleteStrip(si)
    if not isActive() or not stripAt(si) then return end
    table.remove(state.strips, tonumber(si))
    state.activeStrip, state.activeHandle = nil, nil
    changed()
end

---@param si integer
---@param partial table name / length / tree / laneWidth / laneGap / laneCount
local function onSetStrip(si, partial)
    if not isActive() then return end
    local strip = stripAt(si)
    if not strip or type(partial) ~= "table" then return end
    local relaid = false
    if type(partial.name) == "string" then strip.name = partial.name:sub(1, MAX_NAME_LEN) end
    if table.includes(beamjoy_dragStrips.LENGTHS, partial.length) then
        strip.length = partial.length
        fitFinish(strip)
        relaid = true
    end
    if partial.tree == "sportsman" or partial.tree == "pro" then strip.tree = partial.tree end
    if partial.laneWidth ~= nil then
        strip.laneWidth = math.max(MIN_LANE_WIDTH, math.min(MAX_LANE_WIDTH, tonumber(partial.laneWidth) or strip.laneWidth))
    end
    if partial.laneGap ~= nil then
        strip.laneGap = math.max(0, math.min(MAX_LANE_GAP, tonumber(partial.laneGap) or strip.laneGap))
    end
    if partial.laneCount ~= nil then
        strip.laneCount = math.max(1, math.min(MAX_LANES, math.floor(tonumber(partial.laneCount) or strip.laneCount)))
        relaid = true
    end
    renderAll()
    -- a re-push mid-typing drops the name field's focus : only for what the list shows otherwise
    if relaid then pushStrips() end
    if partial.length then updateGizmo() end
    markDirty()
end

--- the start at your car, the strip running the way it faces
---@param si integer
local function onSetStripToVehicle(si)
    if not isActive() then return end
    local strip = stripAt(si)
    if not strip then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    strip.start = xyz(pos)
    strip.finish = xyz(pos + dir)
    fitFinish(strip)
    changed()
end

--- your car a few metres short of a lane's start line, facing down it
---@param si integer
---@param li integer
local function onTeleportToLane(si, li)
    if not isActive() then return end
    local strip = stripAt(si)
    local lane = strip and lanesOf(strip)[tonumber(li) or 0]
    local current = beamjoy_vehicles.getCurrentOwn()
    if not lane or not current then return end
    beamjoy_vehicles.setVehiclePositionRotation(current.veh, lane.pos - lane.dir * 8, lane.dir, vec3(0, 0, 1))
end

---@param enabled boolean
local function onSetSnapToGround(enabled)
    state.snapToGroundEnabled = enabled == true
    beamjoy_communications_ui.send("BJEditorDragStripsSnapToGround", state.snapToGroundEnabled)
end

---@param method string
local function onSetSnapMethod(method)
    state.snapMethod = method == "terrain" and "terrain" or "raycast"
    beamjoy_communications_ui.send("BJEditorDragStripsSnapMethod", state.snapMethod)
end

--- click a strip's start or finish handle in the world to pick it (any strip's start line too)
---@param clickType string
local function onBJClick(clickType)
    if clickType ~= "left" or not isActive() then return end
    local camPos, rayDir = camera.mouseRay()
    if not camPos then return end
    local best, bestStrip, bestHandle
    local function try(si, handle, p, reach)
        local along = (p - camPos):dot(rayDir)
        if along > 0 and (camPos + rayDir * along):distance(p) <= reach and (not best or along < best) then
            best, bestStrip, bestHandle = along, si, handle
        end
    end
    for si, strip in ipairs(state.strips) do
        try(si, "start", v3(strip.start) + vec3(0, 0, .5), HANDLE_PICK)
        if si == state.activeStrip then
            try(si, "finish", v3(strip.finish) + vec3(0, 0, .5), HANDLE_PICK)
        else
            for _, lane in ipairs(lanesOf(strip)) do
                try(si, "start", lane.pos, math.max(1.5, strip.laneWidth / 2))
            end
        end
    end
    if bestStrip and not (bestStrip == state.activeStrip and bestHandle == state.activeHandle) then
        state.activeStrip, state.activeHandle = bestStrip, bestHandle
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
    state.strips = table.map(beamjoy_dragStrips and beamjoy_dragStrips.strips or {}, fromSaved)
    if not state.activeStrip or not state.strips[state.activeStrip] then
        state.activeStrip, state.activeHandle = nil, nil
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
    state.activeStrip, state.activeHandle = nil, nil
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
            lanes = table.map(lanesOf(s), function(lane)
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
    beamjoy_communications_ui.addHandler("BJEditorDragStripsSelectHandle", onSelectHandle)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsAddStrip", onAddStrip)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsDeleteStrip", onDeleteStrip)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsSetStrip", onSetStrip)
    beamjoy_communications_ui.addHandler("BJEditorDragStripsSetStripToVehicle", onSetStripToVehicle)
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
