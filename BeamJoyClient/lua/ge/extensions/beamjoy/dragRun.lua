--- BeamJoy's drag strip HUD (direct request, replacing the game's own drag apps, which BeamMP's
--- screen layout doesn't hold) : the live overlay (top right, windows/dragHud) while this game's own
--- car is in a lane of one of the game's drag strips, and the timeslip (windows/dragTimeslip).
---
--- The game runs the drag (gameplay/drag : tree, timers, disqualifications) for this car only ; this
--- reads its racer every frame and shows it. A run is compared mark by mark with this player's best
--- on the strip (the server's leaderboard keeps every mark of it, services/freeroamChallenges.lua),
--- and with whoever is lined up in the other lane : the server pairs the two and passes each side the
--- other's run as it happens ("dragState" / "dragOpponent"). The game never lets the two trees drop
--- together, so the winner is whoever has the lower reaction + time : who would have crossed first
--- had they.

local M = {
    dependencies = {},

    --- seconds between live pushes (elapsed time, speed) while a run is on
    LIVE_PUSH_SECONDS = 0.1,

    ---@type table? the run in this lane, nil when not lined up
    run = nil,
    --- the other lane's player, from the server (dragOpponent), nil when nobody is there
    ---@type table?
    opponent = nil,
    --- the server's board of the strip being run : {stripId, mine, rows, players}
    ---@type table?
    board = nil,
    --- the last finished run, for the timeslip (kept after leaving the strip)
    ---@type table?
    slip = nil,
    timeslipOpen = false,

    lastHudSig = nil,
    lastStateSig = nil,
    liveTimer = 0,
}

local function fc() return beamjoy_freeroamChallenges end

local function imperial()
    return settings.getValue("uiUnitLength") == "imperial"
end

-- THE STRIP'S MARKS -----------------------------------------------------------------------------

--- the strip's marks in the order a car reaches them : reaction, then each distance with its
--- speed trap (if any) right after it
---@param data table drag data
---@return table[] {id, kind = "reaction"|"time"|"speed", label, main}
local function buildMarks(data)
    local config = data.timers or (gameplay_drag_saveSystem and gameplay_drag_saveSystem.DEFAULT_TIMERS) or {}
    local mainId = data.importantTimerId or "time_1_4"
    local times, speeds = {}, {}
    for _, t in ipairs(config) do
        if t.id and t.type == "distanceTimer" then
            times[#times + 1] = t
        elseif t.id and t.type == "velocity" then
            speeds[t.distance or 0] = t
        end
    end
    table.sort(times, function(a, b) return (a.distance or 0) < (b.distance or 0) end)
    local marks = {}
    for _, t in ipairs(times) do
        local reaction = (t.distance or 0) < 0.5
        marks[#marks + 1] = {
            id = t.id,
            kind = reaction and "reaction" or "time",
            label = t.label or t.id,
            main = t.id == mainId,
        }
        local speed = not reaction and speeds[t.distance or 0]
        if speed then
            marks[#marks + 1] = { id = speed.id, kind = "speed", label = t.label or t.id, main = false }
        end
    end
    return marks
end

---@param data table
---@return string?, table? the strip's id and its main timer
local function stripOf(data)
    local id = fc().stripId(data)
    local main = fc().stripTimers(data)
    return id, main
end

-- READING THE RACER ------------------------------------------------------------------------------

---@param racer table
---@param id string
---@param kind string
---@return number?
local function markValue(racer, id, kind)
    local t = racer.timers and racer.timers[id]
    if not t or not t.isSet then return nil end
    if kind == "reaction" and gameplay_drag_times and gameplay_drag_times.getReactionTimerValue then
        local ok, rt = pcall(gameplay_drag_times.getReactionTimerValue, racer)
        if ok and tonumber(rt) then return tonumber(rt) end
    end
    return tonumber(t.value)
end

---@param data table
---@param racer table
---@return string phase name
local function phaseOf(data, racer)
    local p = racer.phases and racer.phases[racer.currentPhase]
    local name = p and p.name or (data.phases and data.phases[racer.currentPhase] and data.phases[racer.currentPhase].name)
    return name or "stage"
end

---@param data table
---@param lane integer?
---@return string?
local function laneName(data, lane)
    local l = lane and data.strip and data.strip.lanes and data.strip.lanes[lane]
    return l and (l.shortName or l.name) or (lane and tostring(lane)) or nil
end

local TREES = { [".400"] = "pro", [".500"] = "sportsman" }

--- the run as the overlay and the server see it, read fresh from the game
---@param data table
---@param racer table
---@return table
local function readRun(data, racer)
    local stripId, main = stripOf(data)
    local run = M.run
    if not run or run.stripId ~= stripId or run.lane ~= racer.lane then
        run = {
            stripId = stripId,
            stripName = fc().stripName(data, stripId),
            lane = racer.lane,
            laneName = laneName(data, racer.lane),
            lanes = data.strip and data.strip.lanes and #data.strip.lanes or 2,
            marks = buildMarks(data),
            mainLabel = main and main.label or nil,
            tree = TREES[data.prefabs and data.prefabs.christmasTree and data.prefabs.christmasTree.treeType] or "sportsman",
            count = 0, -- runs done in this lane, this visit
            best = M.board and M.board.stripId == stripId and M.board.mine or nil,
        }
        -- the strip's board : your best (every mark) and the record
        beamjoy_communications.send("challengeBoardRequest", "drag", stripId)
    end
    local values, set = {}, 0
    for _, m in ipairs(run.marks) do
        local v = markValue(racer, m.id, m.kind)
        if v then
            values[m.id] = v
            set = set + 1
        end
    end
    local phase = phaseOf(data, racer)
    local dq = (racer.isDisqualified or racer.isDesqualified) and
        (racer.disqualifiedReason or racer.desqualifiedReason or "dq") or nil
    local mainMark
    for _, m in ipairs(run.marks) do if m.main then mainMark = m end end
    local finished = not dq and (racer.isFinished or phase == "stop" or
        (mainMark ~= nil and values[mainMark.id] ~= nil and set >= #run.marks))

    -- a new run in the same lane : the last one was over and everything is cleared again
    if run.over and set == 0 and not dq then
        run.count = run.count + 1
        run.over = false
        run.result = nil
        -- compared with the best as it stands now (the run just done may have beaten it)
        run.best = M.board and M.board.stripId == stripId and M.board.mine or run.best
    end
    if finished or dq then run.over = true end

    run.values = values
    run.set = set
    run.phase = phase
    run.staged = racer.phases and racer.phases[1] and racer.phases[1].completed == true or phase ~= "stage"
    run.dq = dq
    run.finished = finished
    run.elapsed = racer.timers and racer.timers.timer and tonumber(racer.timers.timer.value) or 0
    run.speed = tonumber(racer.vehSpeed) or 0
    run.dial = racer.timers and racer.timers.dial and tonumber(racer.timers.dial.value) or nil
    run.mainId = mainMark and mainMark.id or nil
    return run
end

-- WHAT GOES TO THE SERVER -----------------------------------------------------------------------

local function sendState()
    local run = M.run
    if not run then
        if M.lastStateSig ~= "none" then
            M.lastStateSig = "none"
            beamjoy_communications.send("dragState", nil)
        end
        return
    end
    local sig = table.concat({ run.stripId, run.lane, run.phase, run.set, tostring(run.dq), tostring(run.finished),
        run.count }, "|")
    if sig == M.lastStateSig then return end
    M.lastStateSig = sig
    beamjoy_communications.send("dragState", {
        strip = run.stripId,
        lane = run.lane,
        phase = run.phase,
        splits = run.values,
        dial = run.dial,
        dq = run.dq and fc().gameText(run.dq, run.dq) or nil,
        finished = run.finished,
        run = run.count,
        car = fc().ownCarLabel(),
    })
end

-- WHAT GOES TO THE SCREEN -----------------------------------------------------------------------

--- the board's numbers the panels show : your best (and its marks), the record, your place
local function boardSummary()
    local b = M.board
    if not b or not M.run or b.stripId ~= M.run.stripId then return nil end
    local record = b.rows and b.rows[1]
    return {
        record = record and { name = record.name, et = record.et, vehicle = record.vehicle } or nil,
        rank = b.mine and b.mine.rank or nil,
        players = b.players or 0,
    }
end

local function opponentView()
    local o = M.opponent
    if not o then return nil end
    return {
        name = o.name, car = o.car, lane = o.lane,
        laneName = o.lane and M.laneNameOf and M.laneNameOf(o.lane) or nil,
        splits = o.splits or {}, finished = o.finished == true, dq = o.dq, phase = o.phase,
        dial = o.dial,
    }
end

local function hudPayload()
    local run = M.run
    if not run then return { active = false } end
    local state
    if run.dq then state = "dq"
    elseif run.finished then state = "finished"
    elseif run.phase == "race" then state = "running"
    elseif run.phase == "countdown" then state = "tree"
    elseif run.staged then state = "staged"
    else state = "approach" end
    return {
        active = true,
        state = state,
        strip = run.stripName,
        lane = run.laneName,
        tree = run.tree,
        mainLabel = run.mainLabel,
        mainId = run.mainId,
        marks = run.marks,
        values = run.values,
        best = run.best and { et = run.best.et, trap = run.best.trap, splits = run.best.splits or {} } or nil,
        board = boardSummary(),
        opponent = opponentView(),
        result = run.result,
        dqText = run.dq and fc().gameText(run.dq, run.dq) or nil,
        elapsed = run.elapsed,
        speed = run.speed,
        imperial = imperial(),
        slip = M.slip ~= nil,
    }
end

local function pushHud(force)
    local payload = hudPayload()
    local run = M.run
    local sig = run and table.concat({ payload.state, run.set, run.count, tostring(M.opponent and M.opponent.rev),
        tostring(run.result ~= nil), tostring(M.board and M.board.rev), tostring(M.slip ~= nil) }, "|") or "off"
    if not force and sig == M.lastHudSig then return end
    M.lastHudSig = sig
    beamjoy_communications_ui.send("BJDragHud", payload)
end

--- the live numbers only (elapsed, speed), between full pushes
local function pushLive()
    local run = M.run
    if not run then return end
    beamjoy_communications_ui.send("BJDragHudLive", { elapsed = run.elapsed, speed = run.speed })
end

-- THE TIMESLIP ----------------------------------------------------------------------------------

--- both lanes of the last finished run, as printed, plus the server's side of it
local function buildSlip()
    local run = M.run
    if not run then return M.slip end
    local o = M.opponent
    local env = core_environment
    local tempK = env and env.getTemperatureK and env.getTemperatureK() or nil
    local gravity = env and env.getGravity and math.abs(env.getGravity()) or 9.81
    local self = beamjoy_players and beamjoy_players.getSelf and beamjoy_players.getSelf()
    local me = {
        name = self and (self.displayName or self.playerName) or nil,
        car = fc().ownCarLabel(),
        lane = run.lane,
        laneName = run.laneName,
        values = run.values,
        dial = run.dial,
        dq = run.dq and fc().gameText(run.dq, run.dq) or nil,
        you = true,
    }
    local them = o and {
        name = o.name, car = o.car, lane = o.lane,
        laneName = o.lane and M.laneNameOf and M.laneNameOf(o.lane) or nil,
        values = o.splits or {}, dial = o.dial, dq = o.dq, finished = o.finished == true,
    } or nil
    return {
        strip = run.stripName,
        stripId = run.stripId,
        date = os.date("%a %m/%d/%Y  %I:%M:%S %p"),
        tree = run.tree,
        tempC = tempK and (tempK - 273.15) or nil,
        gravity = gravity,
        marks = run.marks,
        mainId = run.mainId,
        lanes = { me, them },
        best = run.best and { et = run.best.et, trap = run.best.trap, splits = run.best.splits or {} } or nil,
        result = run.result,
        board = M.board and M.board.stripId == run.stripId and {
            rows = M.board.rows, mine = M.board.mine, players = M.board.players,
        } or nil,
        imperial = imperial(),
    }
end

local function pushSlip()
    beamjoy_communications_ui.send("BJDragTimeslip", { open = M.timeslipOpen and M.slip ~= nil, slip = M.slip })
end

local function openTimeslip()
    if not M.slip then return end
    M.timeslipOpen = true
    pushSlip()
end

local function closeTimeslip()
    M.timeslipOpen = false
    pushSlip()
end

-- EVERY FRAME -----------------------------------------------------------------------------------

local function leave()
    M.run = nil
    M.opponent = nil
    sendState()
    pushHud(true)
end

local function onUpdate(dtReal)
    local core = extensions.gameplay_drag_core
    local data = core and core.getData and core.getData()
    local own = data and data.racers and beamjoy_vehicles and beamjoy_vehicles.getCurrentOwn()
    local racer = own and data.racers[own.vid]
    if not racer then
        if M.run then leave() end
        return
    end
    local wasOver = M.run and M.run.over
    local run = readRun(data, racer)
    M.run = run
    M.laneNameOf = function(lane) return laneName(data, lane) end
    -- finished (or out) just now : the timeslip is this run's from here on
    if run.over and not wasOver then
        M.slip = buildSlip()
        if M.timeslipOpen then pushSlip() end
    end
    sendState()
    pushHud(false)
    if run.phase == "race" and not run.over then
        M.liveTimer = M.liveTimer + (dtReal or 0)
        if M.liveTimer >= M.LIVE_PUSH_SECONDS then
            M.liveTimer = 0
            pushLive()
        end
    end
end

-- FROM THE SERVER -------------------------------------------------------------------------------

--- the other lane's run (or false : nobody there now)
---@param o table|false
local function onOpponent(o)
    if type(o) ~= "table" then
        M.opponent = nil
    else
        o.rev = (M.opponent and M.opponent.rev or 0) + 1
        M.opponent = o
    end
    -- their run finished after ours : the timeslip gets their lane
    if M.run and M.run.over then
        M.slip = buildSlip()
        if M.timeslipOpen then pushSlip() end
    end
    pushHud(false)
end

--- the strip's board (forwarded by beamjoy/freeroamChallenges.lua)
---@param data table
function M.onBoard(data)
    if not M.run or data.spot ~= M.run.stripId then return end
    M.board = {
        stripId = data.spot, rows = data.rows or {}, mine = data.mine, players = data.players or 0,
        rev = (M.board and M.board.rev or 0) + 1,
    }
    -- first look at this strip : the best to beat is the one on the board now
    if M.run.best == nil and M.run.set == 0 then M.run.best = data.mine end
    if M.run.over then
        M.slip = buildSlip()
        if M.timeslipOpen then pushSlip() end
    end
    pushHud(false)
end

--- the server kept (or not) the run just finished (forwarded by beamjoy/freeroamChallenges.lua)
---@param r table
function M.onResultSaved(r)
    if not M.run or r.spot ~= M.run.stripId then return end
    M.run.result = {
        saved = r.saved ~= false, best = r.best == true, record = r.record == true,
        rank = r.rank, players = r.players, reason = r.reason,
    }
    -- your place and the record moved : the board again
    beamjoy_communications.send("challengeBoardRequest", "drag", M.run.stripId)
    M.slip = buildSlip()
    if M.timeslipOpen then pushSlip() end
    pushHud(false)
end

local function onInit()
    beamjoy_communications.addHandler("dragOpponent", onOpponent)
    beamjoy_communications_ui.addHandler("BJDragHudRequest", function() pushHud(true) end)
    beamjoy_communications_ui.addHandler("BJDragTimeslipOpen", openTimeslip)
    beamjoy_communications_ui.addHandler("BJDragTimeslipClose", closeTimeslip)
    beamjoy_communications_ui.addHandler("BJDragTimeslipRequest", pushSlip)
end

M.onInit = onInit
M.onUpdate = onUpdate

return M
