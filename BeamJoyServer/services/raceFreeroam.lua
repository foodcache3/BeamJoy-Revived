--- Freeroam runs of the races flagged `freeroam` (services/races.lua) : a player in freeroam
--- drives through a race's start gate and runs one lap against the clock, no lobby, no grid. The
--- player's game spots the gates, as in a grid race (beamjoy/raceFreeroam.lua) ; this follows each
--- run and checks what it can see itself before its time goes on the race's freeroam board :
---   - the start is one of the race's start gates, and every gate after it follows the route (the
---     next gate, or one the route branches to), up to the finish, every step of the lap crossed ;
---   - the player's car is near each gate they report (BeamMP's positions, room left for lag) ;
---   - the time isn't well under what this server measured since the start was reported, nor
---     faster than the race's length at MAX_SPEED.
--- One run per player at a time : a new start replaces the run, a cancel or a disconnect ends it.

local M = {
    dependencies = { "services_races", "services_clockSync", "services_vehicles", "services_identity", "services_config" },

    ---@type table<integer, {raceId: integer, startedAtMs: integer, last: integer, steps: table<integer, true>}>
    runs = {},
}

-- metres past a gate's half-width the server's copy of the car may be (same as a grid race)
local GATE_POSITION_MARGIN = 100
-- how far a reported time may sit under the server's own measure (the report travels after the
-- crossing, the start report too)
local REPORT_LAG_MAX_MS = 5000
-- m/s : no lap is faster than its length at this speed
local MAX_SPEED = 150
-- a run with no news for this long is forgotten
local RUN_TIMEOUT_MS = 30 * 60 * 1000

---@param raceId any
---@return BJRace?
local function getRace(raceId)
    local race = services_races.getById(tonumber(raceId) or raceId)
    return race and race.freeroam == true and race or nil
end

---@param race BJRace
---@param index integer
---@return integer
local function stepOf(race, index)
    return race.branchingEnabled and tonumber(race.gates[index].step) or index
end

---@param race BJRace
---@param index integer
---@return boolean a gate a run starts from (step 1)
local function isStartGate(race, index)
    return race.gates[index] ~= nil and stepOf(race, index) == 1
end

---@param race BJRace
---@param last integer the gate crossed before
---@param index integer
---@return boolean index may come right after last
local function follows(race, last, index)
    local gate = race.gates[index]
    if not gate then return false end
    if race.branchingEnabled then
        if race.loopable and stepOf(race, index) == 1 then return true end
        return table.includes(gate.parents or {}, last)
    end
    return index == (last % #race.gates) + 1
end

---@param race BJRace
---@param index integer
---@return boolean crossing this gate ends the lap
local function isFinish(race, index)
    if race.loopable then return isStartGate(race, index) end
    if race.branchingEnabled then return race.gates[index].isFinish == true end
    return index == #race.gates
end

---@param race BJRace
---@param steps table<integer, true> the steps crossed after the start
---@return boolean every step of the lap was crossed (the finish's own included)
local function lapComplete(race, steps)
    local maxStep = 0
    for i in ipairs(race.gates) do maxStep = math.max(maxStep, stepOf(race, i)) end
    for step = 2, maxStep do
        if not steps[step] then return false end
    end
    return true
end

---@param ctxt BJSContext
---@param race BJRace
---@param index integer
---@return boolean
local function nearGate(ctxt, race, index)
    local gate = race.gates[index]
    local distance = services_vehicles.distanceToPoint(ctxt.senderID, gate.pos)
    if distance and distance > (tonumber(gate.width) or 20) / 2 + GATE_POSITION_MARGIN then
        LogWarn(string.format("raceFreeroam : %s reported gate %d of \"%s\" from %dm away, ignored",
            ctxt.sender.playerName, index, race.name, math.floor(distance)))
        return false
    end
    return true
end

---@param ctxt BJSContext
---@param raceId integer
---@return table? run, BJRace? race
local function currentRun(ctxt, raceId)
    local run = M.runs[ctxt.senderID]
    if not run then return nil end
    if services_clockSync.nowMs() - run.startedAtMs > RUN_TIMEOUT_MS then
        M.runs[ctxt.senderID] = nil
        return nil
    end
    local race = getRace(raceId)
    if not race or run.raceId ~= race.id then return nil end
    return run, race
end

---@param ctxt BJSContext
---@param raceId integer
---@param gateIndex integer the start gate driven through
local function raceFreeroamStart(ctxt, raceId, gateIndex)
    if not ctxt.sender then return end
    local freeroam = services_config.data.Freeroam
    if freeroam and freeroam.RaceRuns == false then return end
    local race = getRace(raceId)
    gateIndex = tonumber(gateIndex)
    M.runs[ctxt.senderID] = nil
    if not race or not gateIndex or not isStartGate(race, gateIndex) or not nearGate(ctxt, race, gateIndex) then
        return
    end
    M.runs[ctxt.senderID] = {
        raceId = race.id,
        startedAtMs = services_clockSync.nowMs(),
        last = gateIndex,
        steps = {},
    }
end

---@param ctxt BJSContext
---@param raceId integer
---@param gateIndex integer
local function raceFreeroamGate(ctxt, raceId, gateIndex)
    if not ctxt.sender then return end
    local run, race = currentRun(ctxt, raceId)
    gateIndex = tonumber(gateIndex)
    if not run or not gateIndex then return end
    if not follows(race, run.last, gateIndex) or isFinish(race, gateIndex) then
        LogWarn(string.format("raceFreeroam : %s reported gate %d of \"%s\" out of order, run dropped",
            ctxt.sender.playerName, gateIndex, race.name))
        M.runs[ctxt.senderID] = nil
        return
    end
    if not nearGate(ctxt, race, gateIndex) then return end
    run.last = gateIndex
    run.steps[stepOf(race, gateIndex)] = true
end

---@param ctxt BJSContext
---@param raceId integer
---@param gateIndex integer the finish gate
---@param elapsedMs integer the lap time the player's game measured
---@param model string? the car's model, for the board
local function raceFreeroamFinish(ctxt, raceId, gateIndex, elapsedMs, model)
    if not ctxt.sender then return end
    local run, race = currentRun(ctxt, raceId)
    gateIndex, elapsedMs = tonumber(gateIndex), tonumber(elapsedMs)
    if not run or not gateIndex or not elapsedMs or elapsedMs <= 0 then return end
    M.runs[ctxt.senderID] = nil
    if not follows(race, run.last, gateIndex) or not isFinish(race, gateIndex) then return end
    if not nearGate(ctxt, race, gateIndex) then return end
    local steps = table.clone(run.steps)
    steps[stepOf(race, gateIndex)] = true
    if not lapComplete(race, steps) then
        return LogWarn(string.format("raceFreeroam : %s finished \"%s\" without every gate, ignored",
            ctxt.sender.playerName, race.name))
    end

    local serverElapsedMs = services_clockSync.nowMs() - run.startedAtMs
    if elapsedMs < serverElapsedMs - REPORT_LAG_MAX_MS then
        LogWarn(string.format("raceFreeroam : %s reported %dms on \"%s\", the server measured %dms",
            ctxt.sender.playerName, elapsedMs, race.name, serverElapsedMs))
        elapsedMs = serverElapsedMs - REPORT_LAG_MAX_MS
    end
    local fastestMs = (tonumber(race.distance) or 0) / MAX_SPEED * 1000
    if elapsedMs < fastestMs then
        return LogWarn(string.format("raceFreeroam : %s ran \"%s\" (%dm) in %dms, ignored",
            ctxt.sender.playerName, race.name, tonumber(race.distance) or 0, elapsedMs))
    end
    elapsedMs = math.floor(elapsedMs + .5)

    local key = services_identity.getIdentityKey(ctxt.senderID) or ctxt.sender.playerName
    local previous = race.freeroamLeaderboard and race.freeroamLeaderboard[key]
    local isNewPB, isNewRecord = services_races.submitTime(race.id, key,
        type(model) == "string" and model:sub(1, 64) or "", elapsedMs, "freeroam")
    local all = services_races.sortedEntries(race, "freeroam")
    local mine = table.find(all, function(e) return e.playerName == key end)
    communications_tx.sendToPlayer(ctxt.senderID, "raceFreeroamResult", race.id, {
        timeMs = elapsedMs,
        bestMs = mine and mine.time or elapsedMs,
        previousMs = previous and previous.time or nil,
        isNewPB = isNewPB,
        isNewRecord = isNewRecord,
        rank = mine and mine.rank or nil,
        players = #all,
    })
end

---@param ctxt BJSContext
local function raceFreeroamCancel(ctxt)
    M.runs[ctxt.senderID] = nil
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.runs[playerID] = nil
end

local function onInit()
    communications_rx.addHandler("raceFreeroamStart", raceFreeroamStart)
    communications_rx.addHandler("raceFreeroamGate", raceFreeroamGate)
    communications_rx.addHandler("raceFreeroamFinish", raceFreeroamFinish)
    communications_rx.addHandler("raceFreeroamCancel", raceFreeroamCancel)
end

M.onInit = onInit
M.onPlayerDisconnect = onPlayerDisconnect

return M
