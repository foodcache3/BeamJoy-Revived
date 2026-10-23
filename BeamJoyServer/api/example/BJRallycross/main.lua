--[[
BJRallycross : an example plugin for BeamJoy's plugin API, a discipline of its own built on race
phases. Meant to be read, then copied and changed.

A "Rallycross" format in the race start menu (circuits only) :
- Heat 1, then Heat 2 on the reversed grid of Heat 1's result. Each heat's places score points
  (POINTS below), shown beside the racers' names on the race HUD for the rest of the event.
- The Final : the top FINALISTS on points race it (the phase's `takes` : the others watch),
  gridded by points (the gridOrder hook : ties go to the better Heat 2 place).
- The event's result is the plugin's : the Final's order, then everyone else by points.
The format locks its phases and how they're ranked, gridded and picked : the starter still sets
the laps, the breaks and the rules.

What it shows : formats (BJ.formats), the event's result by a plugin's scores (phase.setScores
with `event`), the phaseResult hook (here only to score a phase before its result is final),
the gridOrder hook, and HUD labels between phases.

Install : copy this whole folder into Resources/Server/ (next to BeamJoyServer), restart the
server.
]]

-- this file's own path : Resources/Server/BJRallycross/main.lua
local here = debug.getinfo(1).source:gsub("^@", ""):gsub("\\", "/")
local folder = here:match("^(.*)/[^/]*$") or "."
local BJ = dofile((folder:match("^(.*)/[^/]+$") or "..") .. "/BeamJoyServer/api/BeamJoyAPI.lua")

local NAME = "BJRallycross"
local FORMAT = NAME .. ":rallycross"
--- points for a heat's places, first to last
local POINTS = { 20, 16, 13, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 }
local FINALISTS = 6

local function log(msg) print("[" .. NAME .. "] " .. msg) end

---@type table<string, {points: table<integer, integer>, heat2: table<integer, integer>}> sessionId ->
---each racer's points (by player ID), and their Heat 2 place (the tie-break)
local events = {}

---@param sessionId string
local function eventOf(sessionId)
    events[sessionId] = events[sessionId] or { points = {}, heat2 = {} }
    return events[sessionId]
end

--- the points on the race HUD, beside each racer's name, until the event's over (`hud = "only"` :
--- never kept on a result or a leaderboard entry)
---@param sessionId string
local function showPoints(sessionId)
    local e = eventOf(sessionId)
    local racers = {}
    for id, pts in pairs(e.points) do
        racers[#racers + 1] = { playerId = id, fields = {
            { key = "points", label = "Points", value = pts .. " pts", color = "accent", hud = "only" } } }
    end
    if #racers == 0 then return end
    BJ.call("results.setFields", { sessionId = sessionId, racers = racers }, function(ok, err)
        if not ok then log("results.setFields failed : " .. tostring(err.message)) end
    end)
end

--- the event's standings : the Final's places first (once it's been run), then everyone by points
---@param sessionId string
---@param finalResults table[]? the Final's results
local function scoreEvent(sessionId, finalResults)
    local e = eventOf(sessionId)
    local scores, display = {}, {}
    -- lower is better : a finalist's place, then everyone else by points (1000 less their points)
    for id, pts in pairs(e.points) do
        scores[id] = 1000 - pts
        display[id] = pts .. " pts"
    end
    for _, r in ipairs(finalResults or {}) do
        if r.id and r.position then
            scores[r.id] = r.position
            display[r.id] = "Final P" .. r.position
        end
    end
    BJ.call("phase.setScores", { sessionId = sessionId, event = true, better = "low", scores = scores,
        display = display }, function(ok, err)
        if not ok then log("phase.setScores failed : " .. tostring(err.message)) end
    end)
end

function onInit()
    BJ.init(NAME)

    BJ.formats({ {
        id = "rallycross",
        name = "Rallycross",
        description = string.format("Two heats for points, then the top %d in the Final", FINALISTS),
        track = "loop",
        result = "plugin",
        locked = { "phases", "ranking", "order", "takes" },
        phases = {
            { name = "Heat 1", ranking = "position", laps = 4, breakS = 30 },
            { name = "Heat 2", ranking = "position", laps = 4, breakS = 30,
                order = { from = "phase", phase = 1, reverse = -1 } },
            { name = "Final", ranking = "position", laps = 6,
                order = { from = "event" }, takes = { top = FINALISTS } },
        },
    } })

    -- a phase is over : before its result is final, score it. A heat : points for its places ; the
    -- Final : the event's order. Answering nothing keeps BeamJoy's result as it is
    BJ.hook("phaseResult", function(q)
        if q.session.format ~= FORMAT then return {} end
        local sessionId = q.session.sessionId
        local e = eventOf(sessionId)
        if q.phaseIndex <= 2 then
            for _, r in ipairs(q.results) do
                if r.id and r.position then
                    e.points[r.id] = (e.points[r.id] or 0) + (POINTS[r.position] or 0)
                    if q.phaseIndex == 2 then e.heat2[r.id] = r.position end
                end
            end
            scoreEvent(sessionId)
            showPoints(sessionId)
        else
            scoreEvent(sessionId, q.results)
        end
        return {}
    end)

    -- the Final's grid : most points first, ties to the better Heat 2 place
    BJ.hook("gridOrder", function(q)
        if q.session.format ~= FORMAT or q.phaseIndex ~= 3 then return {} end
        local e = eventOf(q.session.sessionId)
        local ids = {}
        for _, r in ipairs(q.racers) do
            if r.id then ids[#ids + 1] = r.id end
        end
        table.sort(ids, function(a, b)
            local pa, pb = e.points[a] or 0, e.points[b] or 0
            if pa ~= pb then return pa > pb end
            return (e.heat2[a] or 99) < (e.heat2[b] or 99)
        end)
        return { order = ids }
    end)

    local function done(d) events[d.sessionId] = nil end
    BJ.on("RaceFinished", done)
    BJ.on("RaceClosed", done)
end
