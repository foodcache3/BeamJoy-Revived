--- BeamJoy's own drag strips (services/dragStrips.lua, made in Config > Freeroam > Drag strips) :
--- run by this game, for this game's own car, like a real lane.
---   - Roll up to a lane's start line : the pre-stage light comes on a metre short of it, the stage
---     light in the last 40 cm. Held staged for a second, the tree starts : a sportsman tree's three
---     ambers half a second apart then green, a pro tree's three together then green 0.4 s later
---     (on screen, in the drag overlay : there's no tree in the world).
---   - Leaving the line before the green is a red light (out). After it, the reaction time is how
---     long you took, and the clock starts as the car's nose crosses the line : every mark (60 ft,
---     330 ft, 1/8 mile, 1000 ft, 1/4 mile) and the speed traps are timed from there, placed between
---     two frames by distance.
---   - Out of the lane, stopping, slowing time or changing gravity during a run : out.
--- What it shows and where results go is the drag overlay's (beamjoy/dragRun.lua) : this hands it
--- a strip's data and a racer the same shape as the game's own (gameplay/drag) so the overlay, the
--- pairing of the two lanes through the server and the timeslip work the same, and its results go
--- on the same Drag boards (beamjoy/freeroamChallenges.lua), under "bj:<id>".

local M = {
    dependencies = {},

    ---@type table[] the current map's strips (the server's cache)
    strips = {},
    --- the lane this car is in, with its run : {strip, lane, data, racer, ...}
    ---@type table?
    active = nil,
    --- strips whose lines are drawn (near you)
    ---@type table[]
    nearby = {},
}

-- the marks, as the game's own strips time them (gameplay/drag/saveSystem.lua DEFAULT_TIMERS)
local MARKS = {
    { id = "reactionTime", label = "Reaction Time", shortLabel = "R/T", type = "distanceTimer", distance = 0.178 },
    { id = "time_60", label = "60 ft", shortLabel = "60'", type = "distanceTimer", distance = 18.288 },
    { id = "time_330", label = "330 ft", shortLabel = "330'", type = "distanceTimer", distance = 100.584 },
    { id = "time_1_8", label = "1/8 mile", shortLabel = "1/8", type = "distanceTimer", distance = 201.168 },
    { id = "time_1000", label = "1000 ft", shortLabel = "1000'", type = "distanceTimer", distance = 304.8 },
    { id = "time_1_4", label = "1/4 mile", shortLabel = "1/4", type = "distanceTimer", distance = 402.336 },
    { id = "velAt_1_8", label = "Speed at 1/8 mile", type = "velocity", distance = 201.168 },
    { id = "velAt_1000", label = "Speed at 1000 ft", type = "velocity", distance = 304.8 },
    { id = "velAt_1_4", label = "Speed at 1/4 mile", type = "velocity", distance = 402.336 },
}
-- each length's finish mark ; a strip times every mark up to it, with the trap at the finish and
-- the 1/8 mile one when the finish is past it
local FINISH = { ["1_4"] = "time_1_4", ["1_8"] = "time_1_8", ["1000"] = "time_1000" }
M.LENGTHS = { "1_4", "1_8", "1000" }

-- metres : the pre-stage light within this of the line, the stage light within STAGE_DEPTH
local PRESTAGE_DEPTH = 1
local STAGE_DEPTH = .4
-- past the line by this much, the car has left the stage beam
local LEAVE_DEPTH = .05
-- how far back from the line a car is "in the lane" (rolling up to stage)
local APPROACH = 25
-- seconds : staged this long, the tree starts (after a short random wait, so it can't be timed)
local STAGED_HOLD = 1
local TREE_WAIT_MIN, TREE_WAIT_MAX = .6, 1.4
-- seconds : a stop this long during a run ends it
local STOP_SECONDS = 4
local NEAR_DISTANCE = 600

---@param strip table
---@return table[] the strip's marks, string the finish mark's id
local function marksOf(strip)
    local finishId = FINISH[strip.length] or "time_1_4"
    local finish
    for _, m in ipairs(MARKS) do
        if m.id == finishId then finish = m end
    end
    local out = {}
    for _, m in ipairs(MARKS) do
        if m.distance <= finish.distance + 1e-3 then
            local keep = m.type == "distanceTimer" or m.distance == finish.distance or
                (m.id == "velAt_1_8" and finish.distance > m.distance)
            if keep then out[#out + 1] = table.clone(m) end
        end
    end
    return out, finishId
end

--- the strip as the drag overlay reads the game's own : see beamjoy/dragRun.lua
---@param strip table
---@return table
local function stripData(strip)
    local timers, finishId = marksOf(strip)
    local lanes = {}
    for i in ipairs(strip.lanes) do
        lanes[i] = { name = string.format("%s %d", beamjoy_lang.translate("beamjoy.dragStrips.lane"), i),
            shortName = tostring(i) }
    end
    return {
        id = "bj:" .. tostring(strip.id),
        stripInfo = { stripName = strip.name },
        timers = timers,
        importantTimerId = finishId,
        strip = { lanes = lanes },
        prefabs = { christmasTree = { treeType = strip.tree == "pro" and ".400" or ".500" } },
        phases = { { name = "stage" }, { name = "countdown" }, { name = "race" }, { name = "stop" } },
        bjStrip = true,
    }
end

---@param data table stripData
---@param laneIndex integer
---@return table a fresh racer : nothing timed, staging
local function newRacer(data, laneIndex)
    local timers = { timer = { value = 0 } }
    for _, t in ipairs(data.timers) do
        timers[t.id] = { isSet = false, value = 0, type = t.type }
    end
    return {
        bjStrip = true,
        lane = laneIndex,
        timers = timers,
        phases = {
            { name = "stage", completed = false },
            { name = "countdown", completed = false },
            { name = "race", completed = false },
            { name = "stop", completed = false },
        },
        currentPhase = 1,
        isFinished = false,
        isDesqualified = false,
        vehSpeed = 0,
        lights = { prestage = false, stage = false, amber = 0, a1 = false, a2 = false, a3 = false,
            green = false, red = false },
    }
end

-- GEOMETRY ------------------------------------------------------------------------------------

---@param lane table
---@param p vec3
---@return number lx across the lane (right +), number ly along it from the start line
local function laneCoords(lane, p)
    local dir = vec3(lane.dir.x, lane.dir.y, 0):normalized()
    local right = dir:cross(vec3(0, 0, 1))
    local d = p - vec3(lane.pos.x, lane.pos.y, lane.pos.z)
    return d:dot(right), d:dot(dir)
end

---@param car BJVehicle
---@return vec3 center, vec3 nose, vec3 dir, number speed
local function carFrame(car)
    local pos, dir = beamjoy_vehicles.getVehiclePositionRotation(car.veh)
    local flat = vec3(dir.x, dir.y, 0)
    flat = flat:length() > 1e-4 and flat:normalized() or vec3(0, 1, 0)
    local nose = pos + flat * (car.veh:getInitialLength() / 2)
    return pos, nose, flat, car.veh:getVelocity():length()
end

---@return BJVehicle?
local function ownCar()
    local v = beamjoy_vehicles.getCurrentOwn()
    if not v or v.jbeam == beamjoy_vehicles.WALKING or v.isAi then return nil end
    return v
end

---@return boolean nothing else going on
local function free()
    if navigation and navigation.inActivity and navigation.inActivity() then return false end
    return not (beamjoy_raceRunner and beamjoy_raceRunner.spectatingSession)
end

-- RUNNING A LANE ------------------------------------------------------------------------------

local function now() return GetCurrentTimeMillis() / 1000 end

---@param a table active
---@param reason string a locale key
local function disqualify(a, reason)
    local r = a.racer
    r.isDesqualified = true
    r.desqualifiedReason = beamjoy_lang.translate(reason)
    r.phases[r.currentPhase].completed = true
    r.currentPhase = 4
end

---@param a table active
local function finish(a)
    local r = a.racer
    r.isFinished = true
    r.phases[3].completed = true
    r.currentPhase = 4
    if beamjoy_freeroamChallenges and beamjoy_freeroamChallenges.submitDrag then
        beamjoy_freeroamChallenges.submitDrag(a.data, r)
    end
end

---@param a table active
local function resetToStage(a)
    a.racer = newRacer(a.data, a.laneIndex)
    a.stagedSince, a.greenAt, a.treeAt, a.leftAt = nil, nil, nil, nil
    a.prevLy, a.prevT, a.prevSpeed, a.stoppedSince = nil, nil, nil, nil
end

---@param strip table
---@param laneIndex integer
---@return table active
local function enter(strip, laneIndex)
    local a = { strip = strip, laneIndex = laneIndex, lane = strip.lanes[laneIndex], data = stripData(strip) }
    resetToStage(a)
    return a
end

---@return string? the locale key of what a run may not do right now
local function brokenRule()
    if simTimeAuthority.getPause() or simTimeAuthority.get() ~= 1 then return "beamjoy.dragStrips.dq.time" end
    local expected = beamjoy_environment and beamjoy_environment.data and beamjoy_environment.data.gravity
    if expected and math.abs(extensions.core_environment.getGravity() - expected) > 1e-3 then
        return "beamjoy.dragStrips.dq.gravity"
    end
    return nil
end

--- the tree's lights at time t
---@param a table
---@param t number
local function treeLights(a, t)
    local l = a.racer.lights
    if not a.treeAt then
        l.amber, l.green = 0, false
        return
    end
    if a.strip.tree == "pro" then
        l.amber = t >= a.treeAt and 3 or 0
    else
        l.amber = t >= a.treeAt + 1 and 3 or t >= a.treeAt + .5 and 2 or t >= a.treeAt and 1 or 0
    end
    l.green = t >= a.greenAt
    if l.green then l.amber = 0 end
    -- each bulb : a sportsman tree's ambers one after another, a pro tree's three together
    local pro = a.strip.tree == "pro"
    l.a1 = l.amber > 0 and (pro or l.amber == 1)
    l.a2 = l.amber > 0 and (pro or l.amber == 2)
    l.a3 = l.amber > 0 and (pro or l.amber == 3)
end

---@param a table active
---@param car BJVehicle
local function step(a, car)
    local r = a.racer
    local t = now()
    local center, nose, _, speed = carFrame(car)
    local lx = laneCoords(a.lane, center)
    local _, ly = laneCoords(a.lane, nose)
    local half = a.strip.laneWidth / 2
    local phase = r.currentPhase
    r.vehSpeed = speed

    if phase == 1 then
        r.lights.prestage = ly >= -PRESTAGE_DEPTH and ly <= LEAVE_DEPTH
        r.lights.stage = ly >= -STAGE_DEPTH and ly <= LEAVE_DEPTH
        if r.lights.stage and speed < .5 then
            a.stagedSince = a.stagedSince or t
            if t - a.stagedSince >= STAGED_HOLD then
                r.phases[1].completed = true
                r.currentPhase = 2
                a.treeAt = t + TREE_WAIT_MIN + math.random() * (TREE_WAIT_MAX - TREE_WAIT_MIN)
                a.greenAt = a.treeAt + (a.strip.tree == "pro" and .4 or 1.5)
            end
        else
            a.stagedSince = nil
        end
    elseif phase == 2 then
        local rule = brokenRule()
        if rule then return disqualify(a, rule) end
        treeLights(a, t)
        if ly > LEAVE_DEPTH then
            -- the nose crossed the line between the last frame and this one
            local leftAt = t
            if a.prevLy and a.prevT and ly ~= a.prevLy then
                leftAt = a.prevT + (t - a.prevT) * (LEAVE_DEPTH - a.prevLy) / (ly - a.prevLy)
            end
            r.timers.reactionTime.isSet = true
            r.timers.reactionTime.value = leftAt - a.greenAt
            if leftAt < a.greenAt then
                r.lights.red, r.lights.green, r.lights.amber = true, false, 0
                r.lights.a1, r.lights.a2, r.lights.a3 = false, false, false
                return disqualify(a, "beamjoy.dragStrips.dq.redLight")
            end
            r.phases[2].completed = true
            r.currentPhase = 3
            a.leftAt = leftAt
            a.prevLy, a.prevT, a.prevSpeed = 0, leftAt, speed
            return
        elseif ly < -PRESTAGE_DEPTH - .5 then
            -- rolled back out of the beams before going : the tree stops
            resetToStage(a)
            return
        end
        r.lights.prestage = ly >= -PRESTAGE_DEPTH
        r.lights.stage = ly >= -STAGE_DEPTH
    elseif phase == 3 then
        local rule = brokenRule()
        if rule then return disqualify(a, rule) end
        if math.abs(lx) > half + .5 then return disqualify(a, "beamjoy.dragStrips.dq.lane") end
        if speed < 1 then
            a.stoppedSince = a.stoppedSince or t
            if t - a.stoppedSince >= STOP_SECONDS then return disqualify(a, "beamjoy.dragStrips.dq.stopped") end
        else
            a.stoppedSince = nil
        end
        r.timers.timer.value = t - a.leftAt
        local prevLy, prevT, prevSpeed = a.prevLy or 0, a.prevT or a.leftAt, a.prevSpeed or speed
        for _, m in ipairs(a.data.timers) do
            local timer = r.timers[m.id]
            if m.id ~= "reactionTime" and not timer.isSet and ly >= m.distance and prevLy < m.distance then
                local f = ly ~= prevLy and (m.distance - prevLy) / (ly - prevLy) or 1
                timer.isSet = true
                if m.type == "velocity" then
                    timer.value = prevSpeed + (speed - prevSpeed) * f
                else
                    timer.value = prevT + (t - prevT) * f - a.leftAt
                end
            end
        end
        a.prevLy, a.prevT, a.prevSpeed = ly, t, speed
        if r.timers[a.data.importantTimerId].isSet then
            -- the trap at the finish is set in the same frame (same distance)
            return finish(a)
        end
    end
    if phase ~= 3 then a.prevLy, a.prevT, a.prevSpeed = ly, t, speed end
end

--- the lane whose approach the car is in, facing down it
---@param car BJVehicle
---@return table? strip, integer? laneIndex
local function laneAt(car)
    local center, nose, dir = carFrame(car)
    for _, strip in ipairs(M.nearby) do
        for i, lane in ipairs(strip.lanes) do
            local lx = laneCoords(lane, center)
            local _, ly = laneCoords(lane, nose)
            local facing = dir:dot(vec3(lane.dir.x, lane.dir.y, 0):normalized())
            if math.abs(lx) <= strip.laneWidth / 2 and ly >= -APPROACH and ly <= LEAVE_DEPTH and facing >= .7 then
                return strip, i
            end
        end
    end
    return nil
end

--- still on the strip : in the lane's approach, or down the strip past the finish's run-out
---@param a table
---@param car BJVehicle
---@return boolean
local function onStrip(a, car)
    local center = carFrame(car)
    local lx, ly = laneCoords(a.lane, center)
    local finishMark
    for _, m in ipairs(a.data.timers) do
        if m.id == a.data.importantTimerId then finishMark = m end
    end
    return math.abs(lx) <= a.strip.laneWidth / 2 + 6 and ly >= -APPROACH - 5 and
        ly <= (finishMark and finishMark.distance or 402) + 400
end

local function onUpdate()
    local car = ownCar()
    local a = M.active
    if not car or not free() or (a and a.vid ~= car.vid) then
        M.active = nil
        return
    end
    if a and a.racer.currentPhase == 4 then
        -- a run over : back in the approach of a lane starts the next one there
        local strip, laneIndex = laneAt(car)
        if strip then
            if strip == a.strip and laneIndex == a.laneIndex then
                resetToStage(a)
            else
                M.active = enter(strip, laneIndex)
                M.active.vid = car.vid
            end
        elseif not onStrip(a, car) then
            M.active = nil
        end
        return
    end
    if a and a.racer.currentPhase == 1 then
        -- staging : another lane (or none) is a change of lane
        local strip, laneIndex = laneAt(car)
        if not strip then
            M.active = nil
            return
        end
        if strip ~= a.strip or laneIndex ~= a.laneIndex then
            a = enter(strip, laneIndex)
            a.vid = car.vid
            M.active = a
        end
    elseif not a then
        local strip, laneIndex = laneAt(car)
        if not strip then return end
        a = enter(strip, laneIndex)
        a.vid = car.vid
        M.active = a
    end
    step(a, car)
end

--- the strip's data and this car's racer, for the drag overlay (beamjoy/dragRun.lua)
---@return table? data, table? racer
function M.current()
    if not M.active then return nil end
    return M.active.data, M.active.racer
end

---@param vid integer
local function onVehicleResetted(vid)
    local a = M.active
    if a and a.vid == vid and (a.racer.currentPhase == 2 or a.racer.currentPhase == 3) then
        disqualify(a, "beamjoy.dragStrips.dq.reset")
    end
end

-- THE STRIPS IN THE WORLD ---------------------------------------------------------------------

local LAYER = "dragStrips"
local LINE_COLOR, MARK_COLOR, EDGE_COLOR, TEXT_COLOR, TEXT_BG

--- painted-line look : the start and finish lines across each lane, short ticks at the marks and
--- the lane edges, the lane's name at its start
local function draw()
    local layer = shape.layer(LAYER)
    layer.reset()
    if M.editing or (beamjoy_markerSettings and beamjoy_markerSettings.activitiesHidden()) then return end
    LINE_COLOR = LINE_COLOR or BJColor(1, 1, 1, .85)
    MARK_COLOR = MARK_COLOR or BJColor(1, .85, .2, .8)
    EDGE_COLOR = EDGE_COLOR or BJColor(1, 1, 1, .35)
    TEXT_COLOR = TEXT_COLOR or BJColor(1, 1, 1, .9)
    TEXT_BG = TEXT_BG or BJColor(0, 0, 0, .4)
    local lift = vec3(0, 0, .03)
    for _, strip in ipairs(M.nearby) do
        local marks, finishId = marksOf(strip)
        local half = strip.laneWidth / 2
        for i, lane in ipairs(strip.lanes) do
            local p = vec3(lane.pos.x, lane.pos.y, lane.pos.z)
            local dir = vec3(lane.dir.x, lane.dir.y, 0):normalized()
            local right = dir:cross(vec3(0, 0, 1)) * half
            local function across(d, color, width)
                local c = p + dir * d
                local h = be:getSurfaceHeightBelow(c + vec3(0, 0, 3))
                if not h or h < c.z - 20 then h = c.z end
                c = vec3(c.x, c.y, h) + lift
                layer.addLine(c - right, width, c + right, width, color)
                return c
            end
            across(0, LINE_COLOR, .15)
            local finishPos
            for _, m in ipairs(marks) do
                if m.type == "distanceTimer" and m.distance > 1 then
                    local c = across(m.distance, m.id == finishId and LINE_COLOR or MARK_COLOR,
                        m.id == finishId and .25 or .08)
                    if m.id == finishId then finishPos = c end
                end
            end
            if finishPos then
                layer.addLine(p - right + lift, .06, finishPos - right, .06, EDGE_COLOR)
                layer.addLine(p + right + lift, .06, finishPos + right, .06, EDGE_COLOR)
            end
            layer.addText(string.format("%s, %s %d", strip.name, beamjoy_lang.translate("beamjoy.dragStrips.lane"), i),
                p + vec3(0, 0, 1.5), TEXT_COLOR, TEXT_BG)
        end
    end
end

local lastNearKey
local function onSlowUpdate()
    local car = beamjoy_vehicles.getCurrentOwn()
    local pos = car and beamjoy_vehicles.getVehiclePositionRotation(car.veh) or
        (core_camera and core_camera.getPosition())
    local nearby = {}
    if pos and free() then
        for _, strip in ipairs(M.strips) do
            for _, lane in ipairs(strip.lanes) do
                if pos:distance(vec3(lane.pos.x, lane.pos.y, lane.pos.z)) <= NEAR_DISTANCE then
                    nearby[#nearby + 1] = strip
                    break
                end
            end
        end
    end
    M.nearby = nearby
    local key = table.concat(table.map(nearby, function(s) return tostring(s.id) end), ",")
    if key ~= lastNearKey then
        lastNearKey = key
        draw()
    end
end

-- THE CACHE -----------------------------------------------------------------------------------

---@param caches table
local function retrieveCache(caches)
    if not caches.dragstrips then return end
    M.strips = table.isArray(caches.dragstrips) and caches.dragstrips or {}
    M.active = nil
    lastNearKey = nil
    extensions.hook("onBJDragStripsChanged")
end

--- the strips for the Leaderboards window's Drag list (beamjoy/freeroamChallenges.lua)
---@return table[] {id, name, lanes, timer}
function M.list()
    return table.map(M.strips, function(s)
        local marks, finishId = marksOf(s)
        local finish
        for _, m in ipairs(marks) do if m.id == finishId then finish = m end end
        return { id = "bj:" .. tostring(s.id), name = s.name, lanes = #s.lanes, timer = finish and finish.label or nil }
    end)
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", retrieveCache)
end

--- the Freeroam editor opened or closed (fired by ui/freeroamEditor.lua) : its own drawing of the
--- strips replaces these lines meanwhile
---@param open boolean
local function onBJStationEditorState(open)
    M.editing = open == true
    draw()
end

local function onServerLeave()
    M.active = nil
    M.strips = {}
    M.nearby = {}
    shape.layer(LAYER).reset()
end

M.marksOf = marksOf
M.laneCoords = laneCoords
M.onInit = onInit
M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate
M.onVehicleResetted = onVehicleResetted
M.onServerLeave = onServerLeave
M.onBJStationEditorState = onBJStationEditorState
M.retrieveCache = retrieveCache

return M
