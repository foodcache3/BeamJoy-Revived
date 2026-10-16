--[[
BJRaceControl : an example plugin for BeamJoy's plugin API, using its hooks, race events and
overlays. Meant to be read, then copied and changed.

- Ready check : a guest without a BeamJoy nickname can't ready up (their times wouldn't be kept
  under one name), and, if ALLOWED_VEHICLES lists any, only those vehicles can race.
- Grid order : fastest leaderboard time at the front ; racers without one at the back.
- Live timing : an overlay with every racer's laps, in BeamJoy's race HUD look, at the top left.

Install : copy this whole folder into Resources/Server/ (next to BeamJoyServer), restart the
server.
]]

-- this file's own path : Resources/Server/BJRaceControl/main.lua
local here = debug.getinfo(1).source:gsub("^@", ""):gsub("\\", "/")
local folder = here:match("^(.*)/[^/]*$") or "."
local BJ = dofile((folder:match("^(.*)/[^/]+$") or "..") .. "/BeamJoyServer/api/BeamJoyAPI.lua")

--- vehicle names (as the lobby shows them, e.g. "ETK 800 Series") allowed to race ; empty : any
local ALLOWED_VEHICLES = {}

local function log(msg) print("[BJRaceControl] " .. msg) end

--- 1:02.345
local function clock(ms)
    if type(ms) ~= "number" then return "-" end
    local s = ms / 1000
    return string.format("%d:%06.3f", math.floor(s / 60), s % 60)
end

-- ---------------------------------------------------------------------------------------------
-- live timing : per session, every racer's laps

---@type table<string, {raceName: string, laps: integer, racers: table<string, table>, ids: integer[]}>
local live = {}

local function standings(s)
    local list = {}
    for _, r in pairs(s.racers) do list[#list + 1] = r end
    -- most laps first, then the quickest to get there
    table.sort(list, function(a, b)
        if a.lap ~= b.lap then return a.lap > b.lap end
        return (a.raceMs or math.huge) < (b.raceMs or math.huge)
    end)
    return list
end

local function showTiming(sessionId)
    local s = live[sessionId]
    if not s then return end
    local rows = {}
    for i, r in ipairs(standings(s)) do
        rows[#rows + 1] = {
            pos = tostring(i),
            name = r.name,
            value = r.out and "OUT" or r.finished and clock(r.raceMs) or (r.bestMs and clock(r.bestMs) or ""),
            playerId = r.id, -- the client marks your own row
            flag = r.finished or nil,
            out = r.out or nil,
        }
    end
    BJ.call("overlay.show", {
        id = "timing-" .. sessionId,
        players = s.ids,
        position = "top-left",
        eyebrow = "LIVE TIMING",
        title = s.raceName,
        progress = { text = "Lap " .. math.min(s.leaderLap, s.laps), of = "/" .. s.laps },
        timer = s.finished and { mode = "static", ms = s.finishedMs } or { mode = "up", ms = s.elapsedMs or 0 },
        rows = rows,
        footer = s.fastest and { label = "Fastest lap", name = s.fastest.name, value = clock(s.fastest.ms) } or nil,
    }, function(ok, err)
        if not ok then log("overlay.show failed : " .. tostring(err.message)) end
    end)
end

function onInit()
    BJ.init("BJRaceControl")

    BJ.onReady(function(info)
        log("BeamJoy " .. tostring(info.beamjoy.version) .. " found : ready checks, grid order and live timing on")
    end)

    -- a racer readies up : refuse, with a reason they see in the lobby, or allow
    BJ.hook("raceReady", function(q)
        if q.racer.identity == "guest" then
            return { allow = false, reason = "Pick a nickname first (Home, Change nickname), so your times are kept" }
        end
        if #ALLOWED_VEHICLES > 0 then
            for _, v in ipairs(ALLOWED_VEHICLES) do
                if q.racer.vehicle and q.racer.vehicle:find(v, 1, true) then return { allow = true } end
            end
            return { allow = false, reason = "This server races " .. table.concat(ALLOWED_VEHICLES, ", ") .. " only" }
        end
        return { allow = true }
    end)

    -- the grid is about to be placed : fastest leaderboard time first
    BJ.hook("gridOrder", function(q)
        local racers = {}
        for i, r in ipairs(q.racers) do racers[i] = { id = r.id, ms = r.leaderboardMs, i = i } end
        table.sort(racers, function(a, b)
            if (a.ms ~= nil) ~= (b.ms ~= nil) then return a.ms ~= nil end
            if a.ms and a.ms ~= b.ms then return a.ms < b.ms end
            return a.i < b.i -- BeamJoy's own order otherwise
        end)
        local order = {}
        for _, r in ipairs(racers) do
            if r.id then order[#order + 1] = r.id end
        end
        return { order = order }
    end)

    BJ.on("RaceCountdown", function(d)
        local names = {}
        for _, r in ipairs(d.grid) do names[#names + 1] = r.gridPosition .. ". " .. r.name end
        log(string.format("%s : grid %s, green in %ss", d.raceName, table.concat(names, "  "), d.countdownS))
    end)

    BJ.on("RaceGreenLight", function(d)
        local s = { raceName = d.raceName, laps = d.laps, racers = {}, ids = {}, leaderLap = 1,
            greenClockMs = d.greenAt.clockMs, elapsedMs = math.max(0, d.at.clockMs - d.greenAt.clockMs) }
        for _, r in ipairs(d.racers) do
            s.racers[r.name] = { id = r.id, name = r.name, lap = 0 }
            if r.id then s.ids[#s.ids + 1] = r.id end
        end
        live[d.sessionId] = s
        showTiming(d.sessionId)
    end)

    BJ.on("RacerLap", function(d)
        local s = live[d.sessionId]
        local r = s and s.racers[d.racer.name]
        if not r then return end
        r.lap, r.raceMs = d.lap, d.raceMs
        if not r.bestMs or d.lapMs < r.bestMs then r.bestMs = d.lapMs end
        if not s.fastest or d.lapMs < s.fastest.ms then s.fastest = { name = d.racer.name, ms = d.lapMs } end
        s.leaderLap = math.max(s.leaderLap, d.lap + 1)
        -- the race clock : from the green light, on BeamJoy's shared clock
        s.elapsedMs = math.max(0, d.at.clockMs - s.greenClockMs)
        showTiming(d.sessionId)
    end)

    BJ.on("RacerFinished", function(d)
        local s = live[d.sessionId]
        local r = s and s.racers[d.racer.name]
        if r then r.finished, r.raceMs = true, d.totalMs end
        log(string.format("%s finished P%d in %s", d.racer.name, d.finishOrder, clock(d.totalMs)))
    end)

    BJ.on("RacerOut", function(d)
        local s = live[d.sessionId]
        local r = s and s.racers[d.racer.name]
        if r then r.out = true end
        if s then showTiming(d.sessionId) end
        log(string.format("%s is out (%s)", d.racer.name, d.reason))
    end)

    -- the results stay up a while, then the overlay goes
    BJ.on("RaceFinished", function(d)
        local s = live[d.sessionId]
        if not s then return end
        s.finished = true
        s.finishedMs = d.at.clockMs - (d.greenAt and d.greenAt.clockMs or d.at.clockMs)
        showTiming(d.sessionId)
        live[d.sessionId] = nil
        BJ.call("overlay.show", { id = "timing-" .. d.sessionId, players = s.ids, position = "top-left",
            eyebrow = "RESULTS", title = d.raceName, rows = (function()
                local rows = {}
                for _, r in ipairs(d.results) do
                    rows[#rows + 1] = { pos = r.position and tostring(r.position) or "-", name = r.name,
                        value = r.finished and clock(r.totalMs) or (r.disqualified and "DSQ" or "DNF"),
                        playerId = r.id, flag = r.finished or nil, out = (not r.finished) or nil }
                end
                return rows
            end)(), durationS = 20 })
    end)

    BJ.on("RaceClosed", function(d)
        if live[d.sessionId] then
            live[d.sessionId] = nil
            BJ.call("overlay.hide", { id = "timing-" .. d.sessionId })
        end
    end)
end
