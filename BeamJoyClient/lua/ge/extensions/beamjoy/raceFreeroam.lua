--- Freeroam runs : a race flagged `freeroam` (the race editor's Info tab) is also run straight from
--- freeroam, no lobby. Drive through its start gate the way it faces and the clock starts ; one lap
--- through its gates, as in a grid race, and the time goes on the race's freeroam board (a rolling
--- start, so not the grid board). A lap race starts its next run as you cross the line, for laps
--- back to back.
---
--- This client spots the gates, the same plane-crossing test as a grid race (raceRunner.lua) ; the
--- server follows the run and checks it before the time counts (services/raceFreeroam.lua).
--- A run ends without a time on a reset or recovery, a change of car, joining an activity, too long
--- without reaching a gate, slowing time / pausing, changing gravity or using the node grabber
--- (none of which a freeroam run can block the way a race lobby does), or the HUD's Retire.

local M = {
    ---@type table? the run going on
    run = nil,
    ---@type BJRace[] the freeroam races whose start gates are near enough to watch
    nearby = {},
    --- this session's best run per race id, its time and gate splits (for the HUD's delta)
    ---@type table<integer, {timeMs: integer, splits: table<integer, integer>}>
    bests = {},
}

-- start gates within this many metres are watched, and drawn (beamjoy_raceMarkers)
M.NEAR_DISTANCE = 300
-- no gate for this long ends a run
local GATE_TIMEOUT_MS = 120000
-- a start only counts when rolling at least this fast (m/s) : not by parking in the gate
local MIN_START_SPEED = 2
local HUD_PUSH_MS = 50
-- a car moved further than this in one frame was moved (quick travel, a teleport), not driven :
-- no gate counts as crossed by it, and a run ends
local TELEPORT_DISTANCE = 60

local lastLy = {}
local prevFrameMs, frameMs
local lastPos

---@return boolean
local function enabled()
    local fr = beamjoy_config and beamjoy_config.data and beamjoy_config.data.Freeroam
    return not fr or fr.RaceRuns ~= false
end

---@return BJVehicle? your own car, not walking
local function ownCar()
    local v = beamjoy_vehicles.getCurrentOwn()
    if not v or v.jbeam == beamjoy_vehicles.WALKING or v.isAi then return nil end
    return v
end

---@return boolean nothing else going on that a run would clash with
local function free()
    if navigation and navigation.inActivity and navigation.inActivity() then return false end
    if beamjoy_driftZones and beamjoy_driftZones.run then return false end
    if beamjoy_raceRunner and (beamjoy_raceRunner.session or beamjoy_raceRunner.spectatingSession) then return false end
    local raceEditor = require("ge/extensions/beamjoy/ui/raceEditor")
    return raceEditor.race == nil
end

---@param race BJRace
---@param index integer
---@return integer
local function stepOf(race, index)
    return race.branchingEnabled and (tonumber(race.gates[index].step) or index) or index
end

---@param race BJRace
---@return integer the last step of a lap
local function lastStep(race)
    local n = 0
    for i in ipairs(race.gates) do n = math.max(n, stepOf(race, i)) end
    return n
end

---@param race BJRace
---@param index integer
---@return boolean
local function isStartGate(race, index)
    return race.gates[index] ~= nil and stepOf(race, index) == 1
end

---@param race BJRace
---@param steps table<integer, true>
---@return boolean every step after the start crossed (the finish's own aside)
local function lapDone(race, steps, finishStep)
    for step = 2, lastStep(race) do
        if step ~= finishStep and not steps[step] then return false end
    end
    return true
end

---@param race BJRace
---@param index integer
---@return boolean crossing it ends the lap (once the rest is done)
local function isFinish(race, index)
    if race.loopable then return isStartGate(race, index) end
    if race.branchingEnabled then return race.gates[index].isFinish == true end
    return index == #race.gates
end

--- the gates that may come next : the next one, or every one the route branches to (a lap race's
--- line only once the rest of the lap is done)
---@param run table
---@return integer[]
local function candidates(run)
    local race = run.race
    local out = {}
    if race.branchingEnabled then
        for i, g in ipairs(race.gates) do
            local closing = race.loopable and stepOf(race, i) == 1
            if closing then
                if lapDone(race, run.steps, 1) then table.insert(out, i) end
            elseif table.includes(g.parents or {}, run.last) then
                table.insert(out, i)
            end
        end
    else
        out[1] = (run.last % #race.gates) + 1
    end
    return out
end

--- same as raceRunner.lua's gateLocalCoords
---@param gate BJRaceGate
---@param vPos vec3
---@return number lx, number ly, number lz
local function gateLocalCoords(gate, vPos)
    local pos = vec3(gate.pos.x, gate.pos.y, gate.pos.z)
    local dir = vec3(gate.dir.x, gate.dir.y, gate.dir.z):normalized()
    local right = dir:cross(vec3(0, 0, 1))
    local d = vPos - pos
    return d:dot(right), d:dot(dir), d:dot(vec3(0, 0, 1))
end

--- whether the car went through the gate since last frame, and when (ms, between the two frames)
---@param key string this gate's slot in lastLy
---@param gate BJRaceGate
---@param car BJVehicle
---@param vPos vec3
---@param forwardOnly boolean
---@return number? crossingMs
local function crossed(key, gate, car, vPos, forwardOnly)
    local lx, ly, lz = gateLocalCoords(gate, vPos)
    local prev = lastLy[key]
    lastLy[key] = ly
    if prev == nil then return nil end
    local signChanged = (prev < 0 and ly >= 0) or (prev >= 0 and ly < 0)
    if not signChanged or (forwardOnly and not (prev < 0 and ly >= 0)) then return nil end
    -- the same leniency as a grid race : a quarter of the car's own width / height
    if math.abs(lx) > gate.width / 2 + car.veh:getInitialWidth() / 4 then return nil end
    local leniencyZ = car.veh:getInitialHeight() / 4
    if lz < -leniencyZ or lz > gate.height + leniencyZ then return nil end
    lastLy[key] = nil
    local span = math.abs(prev) + math.abs(ly)
    local overshoot = span > 0 and math.abs(ly) / span or 0
    return frameMs - overshoot * (frameMs - (prevFrameMs or frameMs))
end

---@param race BJRace
---@return integer gates in a lap (steps, a branching race's alternates counting once)
local function totalSteps(race)
    local n = lastStep(race)
    return race.loopable and n or math.max(1, n - 1)
end

local function hideHud()
    beamjoy_communications_ui.send("BJRaceHud", { active = false })
end

local lastHudPush = 0
local function pushHud()
    local run = M.run
    if not run then return end
    lastHudPush = frameMs or GetCurrentTimeMillis()
    local elapsed = math.max(0, (frameMs or GetCurrentTimeMillis()) - run.startMs)
    local best = M.bests[run.race.id]
    local delta
    if best and run.lastSplitStep and best.splits[run.lastSplitStep] and run.lastSplitMs then
        delta = run.lastSplitMs - best.splits[run.lastSplitStep]
    end
    beamjoy_communications_ui.send("BJRaceHud", {
        active = true,
        raceName = run.race.name,
        totalGates = totalSteps(run.race),
        totalSectors = 1,
        totalLaps = 1,
        elapsedMs = elapsed,
        self = {
            playerName = MPConfig.getNickname(),
            currentLap = 1,
            currentGate = run.done,
            currentSector = 1,
            finished = false,
            currentLapElapsedMs = elapsed,
            bestLapMs = best and best.timeMs or nil,
            liveDeltaMs = delta,
        },
        fastestSectorMs = {},
        finishedCount = 0,
    })
end

---@param reasonKey string? a locale key saying why, nil for none (a run replaced, the server left)
local function cancel(reasonKey)
    if not M.run then return end
    M.run = nil
    lastLy = {}
    beamjoy_communications.send("raceFreeroamCancel")
    hideHud()
    if reasonKey then toast.warn(beamjoy_lang.translate(reasonKey), nil, 4) end
    extensions.hook("onBJRaceMarkersRefresh")
end

---@param race BJRace
---@param gateIndex integer the start gate
---@param atMs number when it was crossed
---@param car BJVehicle
local function start(race, gateIndex, atMs, car)
    M.run = {
        race = race,
        startMs = atMs,
        last = gateIndex,
        steps = {},
        splits = {},
        done = 0,
        vid = car.vid,
        lastGateMs = atMs,
    }
    lastLy = {}
    beamjoy_communications.send("raceFreeroamStart", race.id, gateIndex)
    pushHud()
    extensions.hook("onBJRaceMarkersRefresh")
end

---@param restriction table?
---@param car BJVehicle
---@return boolean the car may run this race
local function carAllowed(restriction, car)
    if not restriction then return true end
    local ok, matches = pcall(beamjoy_raceRunner.vehicleMatchesRestriction, car.veh, restriction)
    return ok and matches == true
end

local warnedRestriction = {}

--- start gates : a forward crossing at speed starts a run
---@param car BJVehicle
---@param vPos vec3
local function watchStarts(car, vPos)
    local speed = car.veh:getVelocity():length()
    for _, race in ipairs(M.nearby) do
        for i, gate in ipairs(race.gates) do
            if isStartGate(race, i) then
                local at = crossed(string.format("s%d:%d", race.id, i), gate, car, vPos, true)
                if at and speed >= MIN_START_SPEED then
                    if carAllowed(beamjoy_raceRunner.raceVehicleRestriction(race), car) then
                        return start(race, i, at, car)
                    elseif not warnedRestriction[race.id] then
                        warnedRestriction[race.id] = true
                        local r = beamjoy_raceRunner.raceVehicleRestriction(race)
                        toast.warn(string.var(beamjoy_lang.translate("beamjoy.raceFreeroam.restricted"),
                            { r and r.label or "" }), nil, 5)
                    end
                end
            end
        end
    end
end

---@param run table
---@param gateIndex integer
---@param atMs number
---@param car BJVehicle
local function finish(run, gateIndex, atMs, car)
    local timeMs = math.floor(atMs - run.startMs + .5)
    local race = run.race
    run.splits[stepOf(race, gateIndex) == 1 and lastStep(race) + 1 or stepOf(race, gateIndex)] = timeMs
    beamjoy_communications.send("raceFreeroamFinish", race.id, gateIndex, timeMs,
        beamjoy_vehicles.getCurrentConfigDisplayLabel(car.veh))
    local best = M.bests[race.id]
    if not best or timeMs < best.timeMs then
        M.bests[race.id] = { timeMs = timeMs, splits = run.splits }
    end
    M.lastFinish = { raceId = race.id, timeMs = timeMs }
    M.run = nil
    lastLy = {}
    hideHud()
    -- a lap race : the line is the next run's start
    if race.loopable then
        start(race, gateIndex, atMs, car)
    else
        extensions.hook("onBJRaceMarkersRefresh")
    end
end

---@param car BJVehicle
---@param vPos vec3
local function followRun(car, vPos)
    local run = M.run
    local race = run.race
    for _, i in ipairs(candidates(run)) do
        local gate = race.gates[i]
        local at = gate and crossed(string.format("r%d", i), gate, car, vPos, race.oneWayGates == true)
        if at then
            run.lastGateMs = at
            if isFinish(race, i) and lapDone(race, run.steps, stepOf(race, i)) then
                return finish(run, i, at, car)
            end
            local step = stepOf(race, i)
            run.last = i
            run.steps[step] = true
            run.done = run.done + 1
            run.splits[step] = math.floor(at - run.startMs + .5)
            run.lastSplitStep, run.lastSplitMs = step, run.splits[step]
            -- a branch not taken : its crossing state means nothing next time it comes up
            for k in pairs(lastLy) do
                if k:sub(1, 1) == "r" then lastLy[k] = nil end
            end
            beamjoy_communications.send("raceFreeroamGate", race.id, i)
            pushHud()
            extensions.hook("onBJRaceMarkersRefresh")
            return
        end
    end
end

---@return string? the locale key of what a run may not do right now
local function brokenRule()
    if simTimeAuthority.getPause() or simTimeAuthority.get() ~= 1 then return "beamjoy.raceFreeroam.cancelled.time" end
    local expected = beamjoy_environment and beamjoy_environment.data and beamjoy_environment.data.gravity
    if expected and math.abs(extensions.core_environment.getGravity() - expected) > 1e-3 then
        return "beamjoy.raceFreeroam.cancelled.gravity"
    end
    local ng = extensions.core_nodegrabberGamepad
    local st = ng and ng.state
    if (st and (st.mouseActive or st.grabbing or st.active)) or
        (beamjoy_inputs ~= nil and beamjoy_inputs.isNodegrabberRenderActive == true) then
        return "beamjoy.raceFreeroam.cancelled.nodegrabber"
    end
    return nil
end

local function onUpdate()
    prevFrameMs = frameMs
    frameMs = GetCurrentTimeMillis()
    if not enabled() then return cancel() end
    local car = ownCar()
    if M.run then
        if not car or car.vid ~= M.run.vid then return cancel("beamjoy.raceFreeroam.cancelled.car") end
        if not free() then return cancel() end
        local rule = brokenRule()
        if rule then return cancel(rule) end
        if frameMs - M.run.lastGateMs > GATE_TIMEOUT_MS then return cancel("beamjoy.raceFreeroam.cancelled.timeout") end
    end
    if not car or (not M.run and (#M.nearby == 0 or not free())) then return end
    local vPos = beamjoy_vehicles.getVehiclePositionRotation(car.veh) + vec3(0, 0, car.veh:getInitialHeight() / 2)
    local jumped = lastPos ~= nil and vPos:distance(lastPos) > TELEPORT_DISTANCE
    lastPos = vPos
    if jumped then
        lastLy = {}
        if M.run then cancel("beamjoy.raceFreeroam.cancelled.teleport") end
        return
    end
    if M.run then
        followRun(car, vPos)
        if M.run and frameMs - lastHudPush >= HUD_PUSH_MS then pushHud() end
    else
        watchStarts(car, vPos)
    end
end

--- which freeroam races' start gates are near : watched for a start, drawn by the markers
local lastNearbyKey
local function onSlowUpdate()
    local car = ownCar()
    local nearby = {}
    -- none while busy elsewhere (an activity, the race editor) : nothing to start, nothing drawn
    if car and enabled() and (M.run or free()) then
        local pos = beamjoy_vehicles.getVehiclePositionRotation(car.veh)
        for _, race in ipairs(beamjoy_races and beamjoy_races.data or {}) do
            if race.freeroam and type(race.gates) == "table" then
                for i, gate in ipairs(race.gates) do
                    if isStartGate(race, i) and
                        pos:distance(vec3(gate.pos.x, gate.pos.y, gate.pos.z)) <= M.NEAR_DISTANCE then
                        table.insert(nearby, race)
                        break
                    end
                end
            end
        end
    end
    M.nearby = nearby
    local key = table.concat(table.map(nearby, function(r) return tostring(r.id) end), ",")
    if key ~= lastNearbyKey then
        lastNearbyKey = key
        -- a start gate's crossing state from before it went out of range means nothing now
        for k in pairs(lastLy) do
            if k:sub(1, 1) == "s" then lastLy[k] = nil end
        end
        extensions.hook("onBJRaceMarkersRefresh")
    end
end

---@param raceId integer
---@param result {timeMs: integer, bestMs: integer, previousMs: integer?, isNewPB: boolean?, isNewRecord: boolean?, rank: integer?, players: integer?}
local function onResult(raceId, result)
    local race = table.find(beamjoy_races.data or {}, function(r) return r.id == raceId end)
    if not race or type(result) ~= "table" then return end
    -- 1:48.21, as the HUD and the leaderboards show it
    local cs = math.floor(result.timeMs / 10 + .5)
    local time = string.format("%d:%05.2f", math.floor(cs / 6000), (cs % 6000) / 100)
    local key
    if result.isNewRecord then
        key = "beamjoy.raceFreeroam.result.record"
    elseif result.isNewPB then
        key = "beamjoy.raceFreeroam.result.pb"
    else
        key = "beamjoy.raceFreeroam.result.time"
    end
    toast.success(string.var(beamjoy_lang.translate(key),
        { race.name, time, tostring(result.rank or "-"), tostring(result.players or "-") }), nil, 6)
end

local function onVehicleResetted(vid)
    if M.run and M.run.vid == vid then cancel("beamjoy.raceFreeroam.cancelled.reset") end
end

local function onInit()
    beamjoy_communications.addHandler("raceFreeroamResult", onResult)
    -- the race HUD's Retire, on a freeroam run
    beamjoy_communications_ui.addHandler("BJRaceRetire", function()
        if M.run then cancel("beamjoy.raceFreeroam.cancelled.retired") end
    end)
end

local function onServerLeave()
    M.run = nil
    M.nearby = {}
    lastLy = {}
    lastPos = nil
end

M.cancel = cancel
M.isStartGate = isStartGate
M.candidates = candidates

M.onInit = onInit
M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate
M.onVehicleResetted = onVehicleResetted
M.onServerLeave = onServerLeave

return M
