--[[
BJShootout : an example plugin for BeamJoy's plugin API, a phase the plugin runs itself. Meant to
be read, then copied and changed.

A "Shootout + race" format in the race start menu (any track) :
- The Shootout : one lap (or run) each, alone on track, one racer at a time, the last on the grid
  first. The plugin starts each racer itself (race.startRacer) once the one before is through,
  and scores them by their time (phase.setScores : ranking "plugin").
- The 107% rule : a time more than 7% slower than the fastest is out (the phaseResult hook).
- The Race : its grid is the Shootout's result.
The format is locked : the starter can't change it.

What it shows : a phase with start = "plugin" and ranking = "plugin" (racers held on the grid until
the plugin starts them, ranked by its scores), race.startRacer, phase.setScores, and the
phaseResult hook taking racers out.

Install : copy this whole folder into Resources/Server/ (next to BeamJoyServer), restart the
server.
]]

-- this file's own path : Resources/Server/BJShootout/main.lua
local here = debug.getinfo(1).source:gsub("^@", ""):gsub("\\", "/")
local folder = here:match("^(.*)/[^/]*$") or "."
local BJ = dofile((folder:match("^(.*)/[^/]+$") or "..") .. "/BeamJoyServer/api/BeamJoyAPI.lua")

local NAME = "BJShootout"
local FORMAT = NAME .. ":shootout"
--- out when more than this much slower than the fastest (1.07 : the 107% rule)
local CUTOFF = 1.07

local function log(msg) print("[" .. NAME .. "] " .. msg) end

--- 1:02.345
local function clock(ms)
    local s = ms / 1000
    return string.format("%d:%06.3f", math.floor(s / 60), s % 60)
end

---@type table<string, {queue: integer[], running: integer?, times: table<integer, integer>}>
---sessionId -> who's still to go (player IDs, in order), who's out there, the times so far
local shootouts = {}

--- the next racer off, once the one before is through (or straight away for the first)
---@param sessionId string
local function startNext(sessionId)
    local s = shootouts[sessionId]
    if not s or s.running then return end
    local id = table.remove(s.queue, 1)
    if not id then return end
    s.running = id
    BJ.call("race.startRacer", { sessionId = sessionId, playerId = id, countdownS = 5, from = "first" },
        function(ok, err)
            if ok then return end
            -- gone meanwhile (left, disconnected) : the next one
            log("race.startRacer failed : " .. tostring(err.message))
            s.running = nil
            startNext(sessionId)
        end)
end

--- a racer's done (finished, or out) : their time scored, the next one off
---@param d table the event
---@param timeMs integer? their lap's time
local function through(d, timeMs)
    local s = shootouts[d.sessionId]
    if not s or not d.racer.id or s.running ~= d.racer.id then return end
    s.running = nil
    if timeMs then
        s.times[d.racer.id] = timeMs
        local display = {}
        for id, ms in pairs(s.times) do display[id] = clock(ms) end
        BJ.call("phase.setScores", { sessionId = d.sessionId, better = "low", scores = s.times, display = display },
            function(ok, err)
                if not ok then log("phase.setScores failed : " .. tostring(err.message)) end
            end)
    end
    startNext(d.sessionId)
end

function onInit()
    BJ.init(NAME)

    BJ.formats({ {
        id = "shootout",
        name = "Shootout + race",
        description = "One lap each, alone on track, the plugin starting you ; then the race on that grid",
        result = "last",
        locked = true,
        phases = {
            { name = "Shootout", start = "plugin", ranking = "plugin", laps = 1, countsToEvent = false,
                breakS = 20 },
            { name = "Race", ranking = "position", laps = 5, order = { from = "phase", phase = 1 } },
        },
    } })

    -- the Shootout's green light : everyone's held on the grid, the last on it goes first
    BJ.on("RaceGreenLight", function(d)
        if d.format ~= FORMAT or d.phaseIndex ~= 1 then return end
        local racers = {}
        for _, r in ipairs(d.racers) do
            if r.id then racers[#racers + 1] = r end
        end
        table.sort(racers, function(a, b) return (a.gridPosition or 0) > (b.gridPosition or 0) end)
        local queue = {}
        for i, r in ipairs(racers) do queue[i] = r.id end
        shootouts[d.sessionId] = { queue = queue, times = {} }
        startNext(d.sessionId)
    end)
    BJ.on("RacerFinished", function(d)
        if d.format == FORMAT and d.phaseIndex == 1 then through(d, d.raceMs) end
    end)
    BJ.on("RacerOut", function(d)
        if d.format == FORMAT and d.phaseIndex == 1 then through(d, nil) end
    end)

    -- the 107% rule : too slow, out (not on the Race's grid's front, its time gone from the result)
    BJ.hook("phaseResult", function(q)
        if q.session.format ~= FORMAT or q.phaseIndex ~= 1 then return {} end
        local fastest
        for _, r in ipairs(q.results) do
            if r.score and (not fastest or r.score < fastest) then fastest = r.score end
        end
        local out = {}
        for _, r in ipairs(q.results) do
            if fastest and r.id and r.score and r.score > fastest * CUTOFF then out[#out + 1] = r.id end
        end
        return { out = out }
    end)

    local function done(d) shootouts[d.sessionId] = nil end
    BJ.on("RacePhaseFinished", function(d) if d.phaseIndex == 1 then done(d) end end)
    BJ.on("RaceFinished", done)
    BJ.on("RaceClosed", done)
end
