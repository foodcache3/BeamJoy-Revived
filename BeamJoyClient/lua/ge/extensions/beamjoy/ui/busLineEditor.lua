--- In-world bus-line editor. NOT a standalone `activityEditor` slot - it's a sub-editor hosted by
--- `freeroamEditor.lua` (the "Bus Lines" section of the Config > Freeroam tab), which owns the one
--- `activityEditor.activeEditor` slot for that whole tab and forwards onUpdate / onBJClick / save /
--- close to whichever section is live.
---
--- Bus lines are a 2-level structure - an ordered list of lines, each an ordered list of stops -
--- which `pointListEditor.lua` (flat, no reordering) deliberately doesn't model, so this is its
--- own thing. A stop is `{ name, pos, dir, radius }` : same `dir` (forward-vector) facing
--- convention as hunter spawns, fed straight to setVehiclePositionRotation by the gameplay side,
--- no quat anywhere. Server side: services/busLines.lua (`<map>_buslines.json`).

---@class BJBusStopEdit
---@field name string
---@field pos {x:number, y:number, z:number}
---@field dir {x:number, y:number, z:number}
---@field radius number

local M = {}

local ACTIVE_COLOR = BJColor(1, 1, 1, .9)
local LINE_COLOR = BJColor(.3, .7, 1, .8)
local DIM_COLOR = BJColor(.3, .7, 1, .35)
local SEGMENT_COLOR = BJColor(1, 1, 0, .5)
local LOOP_COLOR = BJColor(1, .5, 0, .5)
local TEXT_BG = BJColor(0, 0, 0, .3)

local DEFAULT_RADIUS = 3
local MIN_RADIUS = 1
local MAX_RADIUS = 10
local MAX_NAME_LEN = 40

--- freeroamEditor injects "is the Bus Lines section live right now" ; every mutation guards on it
---@type fun(): boolean
local isActive = function() return false end

local state = {
    ---@type table[]
    lines = {},
    ---@type integer?
    activeLine = nil,
    ---@type integer?
    activeStop = nil,
    dirty = false,
    loaded = false,
    snapToGroundEnabled = true,
    ---@type "terrain"|"raycast"
    snapMethod = "terrain",
}

-- WIRE ------------------------------------------------------------------------------------------

local function pushLines()
    beamjoy_communications_ui.send("BJEditorBusLinesListUpdate", state.lines)
end

local function pushActive()
    beamjoy_communications_ui.send("BJEditorBusLinesActiveUpdate",
        { line = state.activeLine, stop = state.activeStop })
end

local function pushFullState()
    pushLines()
    pushActive()
    beamjoy_communications_ui.send("BJEditorDirty", state.dirty)
    beamjoy_communications_ui.send("BJEditorBusLinesSnapToGround", state.snapToGroundEnabled)
    beamjoy_communications_ui.send("BJEditorBusLinesSnapMethod", state.snapMethod)
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

--- current vehicle (or free-cam) position + flattened forward dir, mirroring pointListEditor's
--- own currentPositionDirection
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
    local flat = dir and vec3(dir.x, dir.y, 0) or vec3(1, 0, 0)
    if flat:length() < 1e-4 then flat = vec3(1, 0, 0) end
    return pos, flat:normalized()
end

---@param line table
---@return integer
local function stopCount(line) return line and line.stops and #line.stops or 0 end

-- RENDER ------------------------------------------------------------------------------------

local function renderAll()
    shape.reset()
    if not next(state.lines) then return end

    for li, line in ipairs(state.lines) do
        local activeLine = state.activeLine == li
        local label = (type(line.name) == "string" and #line.name > 0)
            and line.name or string.format("%s %d", beamjoy_lang.translate("beamjoy.buslines.line"), li)

        if not activeLine then
            -- an inactive line : just a small marker + its name at the first stop
            local s = line.stops and line.stops[1]
            if s then
                local p = vec3(s.pos.x, s.pos.y, s.pos.z)
                shape.addSphere(p, 1, DIM_COLOR)
                shape.addText(label, p + vec3(0, 0, 2), DIM_COLOR, TEXT_BG)
            end
        else
            local n = stopCount(line)
            for si, s in ipairs(line.stops) do
                local p = vec3(s.pos.x, s.pos.y, s.pos.z)
                local activeStop = state.activeStop == si
                local color = activeStop and ACTIVE_COLOR or LINE_COLOR
                local radius = math.max(MIN_RADIUS, tonumber(s.radius) or DEFAULT_RADIUS)
                shape.addSphere(p, radius, color)
                shape.addArrow(p + vec3(0, 0, .5),
                    vec3(s.dir.x, s.dir.y, s.dir.z):normalized(), 2.5, color)
                local stopLabel = (type(s.name) == "string" and #s.name > 0)
                    and s.name or string.format("%s %d", beamjoy_lang.translate("beamjoy.buslines.stop"), si)
                shape.addText(string.format("%d. %s", si, stopLabel), p + vec3(0, 0, radius + 1),
                    color, TEXT_BG)
                -- connecting segment to the previous stop
                if si > 1 then
                    local prev = line.stops[si - 1]
                    shape.addLine(vec3(prev.pos.x, prev.pos.y, prev.pos.z) + vec3(0, 0, .3), .3,
                        p + vec3(0, 0, .3), .3, SEGMENT_COLOR)
                end
            end
            -- loop-closing segment
            if line.loopable and n >= 2 then
                local first, last = line.stops[1], line.stops[n]
                shape.addLine(vec3(last.pos.x, last.pos.y, last.pos.z) + vec3(0, 0, .3), .3,
                    vec3(first.pos.x, first.pos.y, first.pos.z) + vec3(0, 0, .3), .3, LOOP_COLOR)
            end
        end
    end
end

local function updateGizmo()
    gizmo.hide()
    local line = state.activeLine and state.lines[state.activeLine]
    local stop = line and state.activeStop and line.stops[state.activeStop]
    if not stop then return end
    gizmo.show({
        pos = vec3(stop.pos.x, stop.pos.y, stop.pos.z),
        dir = vec3(stop.dir.x, stop.dir.y, stop.dir.z),
        up = vec3(0, 0, 1),
        scales = vec3(1, 1, 1),
    }, function(updated)
        if not isActive() then return end
        stop.pos = { x = updated.pos.x, y = updated.pos.y, z = updated.pos.z }
        local flat = vec3(updated.dir.x, updated.dir.y, 0)
        if flat:length() < 1e-4 then flat = vec3(stop.dir.x, stop.dir.y, 0) end
        flat = flat:normalized()
        stop.dir = { x = flat.x, y = flat.y, z = 0 }
        renderAll()
        markDirty()
    end, function()
        if state.snapToGroundEnabled then
            stop.pos.z = groundHeightAt(vec3(stop.pos.x, stop.pos.y, stop.pos.z))
            renderAll()
            updateGizmo()
        end
        pushLines()
    end)
end

-- MUTATIONS ---------------------------------------------------------------------------------

---@param li integer?
local function onSelectLine(li)
    if not isActive() then return end
    li = tonumber(li)
    if li and state.lines[li] then
        state.activeLine = (state.activeLine == li) and nil or li
    else
        state.activeLine = nil
    end
    state.activeStop = nil
    renderAll()
    updateGizmo()
    pushActive()
end

---@param li integer
---@param si integer
local function onSelectStop(li, si)
    if not isActive() then return end
    li, si = tonumber(li), tonumber(si)
    local line = li and state.lines[li]
    if not line or not line.stops[si] then return end
    state.activeLine = li
    if state.activeStop == si then
        state.activeStop = nil
    else
        state.activeStop = si
    end
    renderAll()
    updateGizmo()
    pushActive()
end

local function onAddLine()
    if not isActive() then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    table.insert(state.lines, {
        name = "",
        loopable = false,
        stops = { { name = "", pos = { x = pos.x, y = pos.y, z = pos.z },
            dir = { x = dir.x, y = dir.y, z = dir.z }, radius = DEFAULT_RADIUS } },
    })
    state.activeLine = #state.lines
    state.activeStop = 1
    renderAll()
    updateGizmo()
    pushLines()
    pushActive()
    markDirty()
end

---@param li integer
local function onDeleteLine(li)
    if not isActive() then return end
    li = tonumber(li)
    if not li or not state.lines[li] then return end
    table.remove(state.lines, li)
    state.activeLine, state.activeStop = nil, nil
    renderAll()
    updateGizmo()
    pushLines()
    pushActive()
    markDirty()
end

---@param li integer
---@param name string
local function onSetLineName(li, name)
    if not isActive() then return end
    local line = tonumber(li) and state.lines[tonumber(li)]
    if not line then return end
    name = type(name) == "string" and name or ""
    if #name > MAX_NAME_LEN then name = name:sub(1, MAX_NAME_LEN) end
    line.name = name
    renderAll()
    markDirty()
end

---@param li integer
---@param loopable boolean
local function onSetLoopable(li, loopable)
    if not isActive() then return end
    local line = tonumber(li) and state.lines[tonumber(li)]
    if not line then return end
    line.loopable = loopable == true
    renderAll()
    markDirty()
end

---@param li integer
local function onAddStop(li)
    if not isActive() then return end
    li = tonumber(li)
    local line = li and state.lines[li]
    if not line then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    table.insert(line.stops, { name = "", pos = { x = pos.x, y = pos.y, z = pos.z },
        dir = { x = dir.x, y = dir.y, z = dir.z }, radius = DEFAULT_RADIUS })
    state.activeLine = li
    state.activeStop = #line.stops
    renderAll()
    updateGizmo()
    pushLines()
    pushActive()
    markDirty()
end

---@param li integer
---@param si integer
local function onDeleteStop(li, si)
    if not isActive() then return end
    li, si = tonumber(li), tonumber(si)
    local line = li and state.lines[li]
    if not line or not line.stops[si] then return end
    table.remove(line.stops, si)
    state.activeStop = nil
    renderAll()
    updateGizmo()
    pushLines()
    pushActive()
    markDirty()
end

--- drag-and-drop reorder, lifted verbatim from raceEditor.lua's own onReorderGates algorithm.
--- Both indices arrive already 1-based and pre-normalized by the Angular side (see
--- windows/config/freeroam/app.js's sortUpdate, same `index + 1` / `newValue + 1` convention the
--- race editor's own sortUpdate uses for cmps/sortable's drag handle + drop separators) - this
--- function does no further adjustment on `toIndex` itself, only the standard
--- remove-then-shifted-insert. Deselects afterward rather than trying to track the moved stop to
--- its new index - races does the same (see its own onReorderGates : `M.activeGateIndex = nil`).
---@param li integer
---@param fromIndex integer
---@param toIndex integer
local function onMoveStop(li, fromIndex, toIndex)
    if not isActive() then return end
    li, fromIndex, toIndex = tonumber(li), tonumber(fromIndex), tonumber(toIndex)
    local line = li and state.lines[li]
    if not line or not fromIndex or not toIndex or not line.stops[fromIndex] then return end

    local stop = table.remove(line.stops, fromIndex)
    local finalIndex = toIndex > fromIndex and (toIndex - 1) or toIndex
    finalIndex = math.max(1, math.min(finalIndex, #line.stops + 1))
    table.insert(line.stops, finalIndex, stop)

    if state.activeLine == li then state.activeStop = nil end
    renderAll()
    updateGizmo()
    pushLines()
    pushActive()
    markDirty()
end

---@param li integer
---@param si integer
---@param name string
local function onSetStopName(li, si, name)
    if not isActive() then return end
    li, si = tonumber(li), tonumber(si)
    local line = li and state.lines[li]
    local stop = line and line.stops[si]
    if not stop then return end
    name = type(name) == "string" and name or ""
    if #name > MAX_NAME_LEN then name = name:sub(1, MAX_NAME_LEN) end
    stop.name = name
    renderAll()
    markDirty()
end

---@param li integer
---@param si integer
---@param radius number
local function onSetStopRadius(li, si, radius)
    if not isActive() then return end
    li, si = tonumber(li), tonumber(si)
    local line = li and state.lines[li]
    local stop = line and line.stops[si]
    if not stop then return end
    stop.radius = math.max(MIN_RADIUS, math.min(MAX_RADIUS, tonumber(radius) or stop.radius))
    renderAll()
    -- no pushLines : Angular holds the value via ng-model, re-pushing the whole list mid-drag
    -- would rebuild the rows and drop input focus (same reasoning as onSetStopName)
    markDirty()
end

---@param li integer
---@param si integer
local function onSetStopToVehicle(li, si)
    if not isActive() then return end
    li, si = tonumber(li), tonumber(si)
    local line = li and state.lines[li]
    local stop = line and line.stops[si]
    if not stop then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    stop.pos = { x = pos.x, y = pos.y, z = pos.z }
    stop.dir = { x = dir.x, y = dir.y, z = dir.z }
    renderAll()
    if state.activeLine == li and state.activeStop == si then updateGizmo() end
    pushLines()
    markDirty()
end

---@param li integer
---@param si integer
local function onTeleportToStop(li, si)
    if not isActive() then return end
    li, si = tonumber(li), tonumber(si)
    local line = li and state.lines[li]
    local stop = line and line.stops[si]
    if not stop then return end
    local current = beamjoy_vehicles.getCurrentOwn()
    if not current then return end
    beamjoy_vehicles.setVehiclePositionRotation(current.veh,
        vec3(stop.pos.x, stop.pos.y, stop.pos.z),
        vec3(stop.dir.x, stop.dir.y, stop.dir.z), vec3(0, 0, 1))
end

---@param enabled boolean
local function onSetSnapToGround(enabled)
    state.snapToGroundEnabled = enabled == true
    beamjoy_communications_ui.send("BJEditorBusLinesSnapToGround", state.snapToGroundEnabled)
end

---@param method string
local function onSetSnapMethod(method)
    state.snapMethod = method == "raycast" and "raycast" or "terrain"
    beamjoy_communications_ui.send("BJEditorBusLinesSnapMethod", state.snapMethod)
end

-- WORLD CLICK -----------------------------------------------------------------------------

--- click a stop of the active line in the world to select it (mirrors pointListEditor.onBJClick)
---@param clickType string
---@param data table
local function onBJClick(clickType, data)
    if clickType ~= "left" or not isActive() then return end
    local line = state.activeLine and state.lines[state.activeLine]
    if not line then return end
    local camPos, rayDir = camera.mouseRay()
    if not camPos then return end
    local bestStop, bestAlong
    for si, s in ipairs(line.stops) do
        local p = vec3(s.pos.x, s.pos.y, s.pos.z)
        local along = (p - camPos):dot(rayDir)
        if along > 0 then
            local closest = camPos + rayDir * along
            local r = math.max(1.5, tonumber(s.radius) or DEFAULT_RADIUS)
            if closest:distance(p) <= r and (not bestAlong or along < bestAlong) then
                bestStop, bestAlong = si, along
            end
        end
    end
    if bestStop and bestStop ~= state.activeStop then
        onSelectStop(state.activeLine, bestStop)
    end
end

-- HOST INTERFACE (called by freeroamEditor) ---------------------------------------------

---@param fn fun(): boolean
local function setActivePredicate(fn)
    isActive = fn or isActive
end

--- (re)load lines from the synced cache. Keeps selection if still valid.
local function refresh()
    local src = (beamjoy_busLines and beamjoy_busLines.data and beamjoy_busLines.data.lines) or {}
    state.lines = {}
    for _, line in ipairs(src) do
        local stops = {}
        for _, s in ipairs(line.stops or {}) do
            stops[#stops + 1] = {
                name = s.name or "",
                pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z },
                dir = { x = s.dir.x, y = s.dir.y, z = s.dir.z },
                radius = s.radius or DEFAULT_RADIUS,
            }
        end
        state.lines[#state.lines + 1] = {
            id = line.id,
            name = line.name or "",
            loopable = line.loopable == true,
            stops = stops,
        }
    end
    if not state.activeLine or not state.lines[state.activeLine] then
        state.activeLine, state.activeStop = nil, nil
    elseif state.activeStop and not state.lines[state.activeLine].stops[state.activeStop] then
        state.activeStop = nil
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

--- section switched away from Bus Lines : drop the gizmo (shapes get cleared by the next
--- section's own renderAll -> shape.reset)
local function standDown()
    gizmo.hide()
end

local function close()
    gizmo.hide()
    state.lines = {}
    state.activeLine, state.activeStop = nil, nil
    state.dirty = false
    state.loaded = false
end

---@param onDone fun(ok: boolean)?
local function save(onDone)
    local payload = {}
    for _, line in ipairs(state.lines) do
        local stops = {}
        for _, s in ipairs(line.stops) do
            local rounded = math.roundPosRotDirUp({
                pos = vec3(s.pos.x, s.pos.y, s.pos.z),
                dir = vec3(s.dir.x, s.dir.y, s.dir.z),
            })
            stops[#stops + 1] = {
                name = s.name,
                pos = { x = rounded.pos.x, y = rounded.pos.y, z = rounded.pos.z },
                dir = { x = rounded.dir.x, y = rounded.dir.y, z = rounded.dir.z },
                radius = math.round(s.radius or DEFAULT_RADIUS, 2),
            }
        end
        payload[#payload + 1] = {
            id = line.id,
            name = line.name,
            loopable = line.loopable == true,
            stops = stops,
        }
    end
    beamjoy_communications.send("busLinesSave", payload)
    beamjoy_communications.addOneUseHandler("busLinesSaved", function(status, err)
        if status then
            -- the server also pushes a fresh cache (-> onBJBusLinesChanged -> refresh + standUp),
            -- but clear dirty right away so the UI doesn't flash a stale Save/Discard
            if state.dirty then
                state.dirty = false
                beamjoy_communications_ui.send("BJEditorDirty", false)
            end
        else
            refresh()
            standUp()
            toast.error(err or "Failed to save bus lines")
        end
        if onDone then onDone(status == true) end
    end, 5000)
end

local function onInit()
    beamjoy_communications_ui.addHandler("BJEditorBusLinesSelectLine", onSelectLine)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesSelectStop", onSelectStop)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesAddLine", onAddLine)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesDeleteLine", onDeleteLine)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesSetLineName", onSetLineName)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesSetLoopable", onSetLoopable)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesAddStop", onAddStop)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesDeleteStop", onDeleteStop)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesMoveStop", onMoveStop)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesSetStopName", onSetStopName)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesSetStopRadius", onSetStopRadius)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesSetStopToVehicle", onSetStopToVehicle)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesTeleportToStop", onTeleportToStop)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesSetSnapToGround", onSetSnapToGround)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesSetSnapMethod", onSetSnapMethod)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesRequestState", pushFullState)
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
