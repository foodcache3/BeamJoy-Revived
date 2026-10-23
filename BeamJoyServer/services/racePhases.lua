--- Race phases (direct request) : a race session (services/raceGrid.lua) runs as an event of one or
--- more phases, each with its own start, length, ranking and rules : practice, qualifying then the
--- race, a sprint then a feature race on a reversed grid, heats then a final, two runs summed...
--- This module is the phase model : what a phase is, the checks on one (a start menu's, a race's
--- own, a plugin's), plugins' formats, how racers are ranked within a phase, the grid one phase
--- builds from another's result, and the event's standings across phases. raceGrid.lua runs them.
--- The built-in formats are the start menu's (cmps/racePhases) : it sends their phases
---
--- A race started as before is a single phase ending on laps : it behaves exactly as it always did.

---@alias BJRacePhaseStart "grid"|"individual"|"sequential"|"open"|"plugin"
---@alias BJRacePhaseRanking "position"|"best"|"total"|"plugin"
---@alias BJRacePhaseAfterTime "leader"|"own"|"stop"
---@alias BJRaceEventResult "last"|"sum"|"plugin"

---@class BJRacePhaseOrder
---@field from "lobby"|"phase"|"event" the lobby's own order (join order, random, manual slots, the
---session's placementMode), an earlier phase's result, or the event's standings so far
---@field phase integer? "phase" : which one (an earlier one)
---@field reverse integer? 0 : as it finished ; n : the first n reversed ; -1 : all of it reversed

---@class BJRacePhaseTakes only some racers take part ; the others watch
---@field from integer? an earlier phase, by its result ; nil : the event's standings so far
---@field top integer how many

---@class BJRacePhase
---@field name string? shown on the HUD and results ("Practice", "Q2", "Heat 1") ; nil : the
---client names it from its place and ranking
---@field start BJRacePhaseStart "grid" : everyone together from the grid, a standing start ;
---"individual" (the start menu's "Time offset") : each from the first slot, every `intervalS`, in
---grid order, several on track at once (a time trial, a rally stage) ; "sequential" (its "One at a
---time") : each from the first slot in grid order, alone : their whole phase (its laps or runs, its
---time limit counted from their own start) before the next is released ; "open" : together from
---the grid, and on a point-to-point track each racer's next
---run starts on its own once they're through the finish (practice, runs) ; "plugin" : each waits
---on their grid slot until a plugin starts them (the plugin API's race.startRacer)
---@field intervalS integer? "individual" : seconds between two racers' starts
---@field laps integer? laps on a circuit, runs on a point-to-point track ; nil : no limit
---@field timeLimitMin number? nil : no limit. Laps and a time limit : whichever comes first
---@field afterTime BJRacePhaseAfterTime once the time's up : "leader" (position ranking only) the
---leader's next crossing of the line ends their race, then everyone's own next ; "own" everyone
---finishes the lap they're on, and it counts ; "stop" it's over at once, a lap under way doesn't
---count
---@field ranking BJRacePhaseRanking "position" : laps done, then race time (a race) ; "best" : best
---lap or run (practice, qualifying, time attack) ; "total" : every lap or run's time added up ;
---"plugin" : a plugin's scores (phase.setScores : judged runs, points)
---@field plugins table? plugins' own options for this phase (race options `where = "phase"`)
---@field order BJRacePhaseOrder the grid
---@field takes BJRacePhaseTakes?
---@field lateJoin boolean players may join while it runs
---@field leaderboard boolean its laps go on the race's leaderboard
---@field countsToEvent boolean part of the event's result (see BJRaceEventResult)
---@field breakS integer seconds of results after it, before the next one
---@field rules table overrides of the session's own settings for this phase (RULE_KEYS)

local M = {
    dependencies = { "services_races", "services_pluginOverlay" },

    START = { GRID = "grid", INDIVIDUAL = "individual", SEQUENTIAL = "sequential", OPEN = "open", PLUGIN = "plugin" },
    RANKING = { POSITION = "position", BEST = "best", TOTAL = "total", PLUGIN = "plugin" },
    AFTER_TIME = { LEADER = "leader", OWN = "own", STOP = "stop" },
    RESULT = { LAST = "last", SUM = "sum", PLUGIN = "plugin" },

    ---@type table<string, table[]> plugin -> its formats (formats.register), checked
    pluginFormats = {},
    MAX_PLUGIN_FORMATS = 16,

    MAX_PHASES = 20,
    MAX_LAPS = 999,
    MAX_TIME_MIN = 1440,
    BREAK_DEFAULT_S = 30,
    BREAK_MIN_S = 5,
    BREAK_MAX_S = 600,
    NAME_MAX = 32,
    TOP_MAX = 64,
}

-- the starts raceGrid runs
local STARTS_RUN = { grid = true, individual = true, sequential = true, open = true, plugin = true }

--- a phase's rules : settings of the session's (raceGrid's BJRaceSessionSettings) a phase may set
--- for itself. The rest (vehicle restriction, anti-cheat, display, the lobby's) is the event's
local RULE_KEYS = {
    respawnStrategy = "respawn",
    dnfEnabled = "boolean",
    dnfTimeout = { 3, 3600 },
    resetPenaltyEnabled = "boolean",
    resetPenaltySeconds = { 1, 600 },
    resetPenaltyMode = { "hold", "time" },
    ghostOnCountdown = "boolean",
    disableCollisions = "boolean",
    ghostBackmarkers = "boolean",
    autoSpectateOnFinish = "boolean",
}

---@param v any
---@param set table<string, any>
---@return string?
local function oneOf(v, set)
    if type(v) ~= "string" then return nil end
    for _, s in pairs(set) do
        if s == v then return v end
    end
end

---@param v any
---@param min number
---@param max number
---@return integer?
local function int(v, min, max)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    return math.clamp(math.floor(v), min, max)
end

---@param rules any
---@return table
local function sanitizeRules(rules)
    local out = {}
    if type(rules) ~= "table" then return out end
    for key, kind in pairs(RULE_KEYS) do
        local v = rules[key]
        if v ~= nil then
            if kind == "boolean" then
                if type(v) == "boolean" then out[key] = v end
            elseif kind == "respawn" then
                out[key] = oneOf(v, services_races.RESPAWN_STRATEGIES)
            elseif type(kind[1]) == "number" then
                out[key] = int(v, kind[1], kind[2])
            else
                out[key] = oneOf(v, kind)
            end
        end
    end
    return out
end

--- one phase, checked. `index` is its place : an order or a takes can only point back
---@param raw table
---@param index integer
---@param race BJRace
---@return BJRacePhase
local function sanitizePhase(raw, index, race)
    local phase = {
        name = services_pluginOverlay.cleanText(raw.name, M.NAME_MAX),
        start = oneOf(raw.start, M.START) or M.START.GRID,
        ranking = oneOf(raw.ranking, M.RANKING) or M.RANKING.POSITION,
        laps = int(raw.laps, 1, M.MAX_LAPS),
        lateJoin = raw.lateJoin == true,
        leaderboard = raw.leaderboard ~= false,
        countsToEvent = raw.countsToEvent ~= false,
        breakS = int(raw.breakS, M.BREAK_MIN_S, M.BREAK_MAX_S) or M.BREAK_DEFAULT_S,
        rules = sanitizeRules(raw.rules),
    }
    if not STARTS_RUN[phase.start] then phase.start = M.START.GRID end
    if phase.start == M.START.INDIVIDUAL then phase.intervalS = int(raw.intervalS, 3, 600) or 10 end
    -- racers starting on their own (a run from the first slot, a staggered start) cross one another
    -- at the start : ghosted unless the phase says otherwise
    if phase.start ~= M.START.GRID and phase.rules.disableCollisions == nil then
        phase.rules.disableCollisions = true
    end

    local minutes = tonumber(raw.timeLimitMin)
    if minutes and minutes == minutes and minutes > 0 then
        -- to the tenth of a minute (6 s)
        phase.timeLimitMin = math.clamp(math.floor(minutes * 10 + .5) / 10, .1, M.MAX_TIME_MIN)
    end
    -- a point-to-point track raced from the grid is one run : there's no lap to repeat, so nothing
    -- for a time limit to count either
    if not race.loopable and phase.start == M.START.GRID then
        phase.laps, phase.timeLimitMin = 1, nil
    end
    -- no end at all : only for a plugin's phase, the plugin ends it (race.endPhase, race.stopRacer)
    if not phase.laps and not phase.timeLimitMin and phase.start ~= M.START.PLUGIN then phase.laps = 1 end
    -- plugins' own options for this phase (race options `where = "phase"`)
    phase.plugins = services_pluginUi and services_pluginUi.phaseValues(raw.plugins) or nil

    phase.afterTime = oneOf(raw.afterTime, M.AFTER_TIME) or
        (phase.ranking == M.RANKING.POSITION and M.AFTER_TIME.LEADER or M.AFTER_TIME.OWN)
    -- "the leader" means something in a race only, and alone on track there's no leader to follow
    if phase.afterTime == M.AFTER_TIME.LEADER and
        (phase.ranking ~= M.RANKING.POSITION or phase.start == M.START.SEQUENTIAL) then
        phase.afterTime = M.AFTER_TIME.OWN
    end

    local order = type(raw.order) == "table" and raw.order or {}
    if order.from == "phase" and int(order.phase, 1, index - 1) and index > 1 then
        phase.order = { from = "phase", phase = int(order.phase, 1, index - 1),
            reverse = int(order.reverse, -1, M.TOP_MAX) or 0 }
    elseif order.from == "event" and index > 1 then
        phase.order = { from = "event", reverse = int(order.reverse, -1, M.TOP_MAX) or 0 }
    else
        phase.order = { from = "lobby" }
    end

    local takes = raw.takes
    if type(takes) == "table" and index > 1 and int(takes.top, 1, M.TOP_MAX) then
        local from = takes.from ~= nil and int(takes.from, 1, index - 1) or nil
        phase.takes = { from = from, top = int(takes.top, 1, M.TOP_MAX) }
    end
    return phase
end

--- a list of phases, checked (a start menu's, a race's own defaults, a plugin's)
---@param list any
---@param race BJRace
---@return BJRacePhase[]? phases, string? why not
function M.sanitize(list, race)
    if type(list) ~= "table" or #list == 0 then return nil, "phases must be a list of 1 or more" end
    if #list > M.MAX_PHASES then return nil, string.format("%d phases at most", M.MAX_PHASES) end
    local phases = {}
    for i, raw in ipairs(list) do
        if type(raw) ~= "table" then return nil, string.format("phase %d must be an object", i) end
        phases[i] = sanitizePhase(raw, i, race)
    end
    return phases
end

---@param v any
---@return BJRaceEventResult
function M.sanitizeResult(v)
    return oneOf(v, M.RESULT) or M.RESULT.LAST
end

--- the event a start asks for : its own phases, else the race's own, else one phase, the race as
--- it always was, its length from the start menu (laps and/or time) or the race's defaults
---@param race BJRace
---@param opts table the start options
---@return BJRacePhase[], BJRaceEventResult, string? format the plugin format's name ("plugin:id"), when one
function M.fromStart(race, opts)
    opts = opts or {}
    local defaults = race.defaults or {}
    -- a plugin's format : its phases, what it locks kept as it set them
    local fromPlugin, pluginResult = M.fromPluginFormat(opts.format, race, opts.phases)
    if fromPlugin then return fromPlugin, pluginResult, opts.format end
    local phases = M.sanitize(opts.phases, race)
    if phases then return phases, M.sanitizeResult(opts.result) end
    phases = M.sanitize(defaults.phases, race)
    if phases then return phases, M.sanitizeResult(defaults.result) end
    -- the start menu's length when it sent one (laps, time, or both), else the race's own
    local src = (opts.laps ~= nil or opts.timeLimitMin ~= nil) and opts or defaults
    return M.sanitize({ { laps = src.laps, timeLimitMin = src.timeLimitMin, afterTime = src.afterTime } }, race),
        M.RESULT.LAST
end

--- the session's settings for a phase : the event's own, the phase's rules over them, and its length
---@param base table BJRaceSessionSettings, as raceGrid's buildSettings made them
---@param phase BJRacePhase
---@return table
function M.effectiveSettings(base, phase)
    local s = {}
    for k, v in pairs(base) do s[k] = v end
    for k, v in pairs(phase.rules or {}) do s[k] = v end
    s.laps = phase.laps
    s.timeLimitMin = phase.timeLimitMin
    s.afterTime = phase.afterTime
    s.ranking = phase.ranking
    s.start = phase.start
    s.intervalS = phase.intervalS
    -- a personal start's countdown (a run, a staggered start, a mid-phase join) : short
    s.startCountdownMs = math.clamp(math.floor(tonumber(base.countdown) or 5), 3, 5) * 1000
    return s
end

--- whether a phase's racers do runs, one after another, each started on its own : a point-to-point
--- track raced other than from the grid all together
---@param phase BJRacePhase
---@param race BJRace
---@return boolean
function M.runs(phase, race)
    return not race.loopable and phase.start ~= M.START.GRID and phase.start ~= M.START.PLUGIN
end

-- ---------------------------------------------------------------------------------------------
-- rankings, within a phase

---@param p table BJRaceParticipant
---@return integer
local function lapsDone(p) return #(p.lapTimes or {}) end

---@param p table BJRaceParticipant
---@return integer laps plus penalties
local function timeOf(p)
    local total = p.penaltyMs or 0
    for _, t in ipairs(p.lapTimes or {}) do total = total + t end
    return total
end

---@param p table BJRaceParticipant
---@return integer? best lap plus penalties
local function bestOf(p)
    if not p.bestLapMs then return nil end
    return p.bestLapMs + (p.penaltyMs or 0)
end

M.lapsDone = lapsDone
M.timeOf = timeOf
M.bestOf = bestOf

--- racing progress : most laps, most gates, earliest at that gate
local function byProgress(a, b)
    if a.currentLap ~= b.currentLap then return a.currentLap > b.currentLap end
    if a.currentGate ~= b.currentGate then return a.currentGate > b.currentGate end
    local aTime = a.gateTimes and a.gateTimes[a.currentGate] or math.huge
    local bTime = b.gateTimes and b.gateTimes[b.currentGate] or math.huge
    if aTime ~= bTime then return aTime < bTime end
    return (a.joinIndex or 0) < (b.joinIndex or 0)
end

local COMPARE = {}

--- a race : finishers by laps then race time (a timed race's finishers can have done different
--- laps), then the ones still racing by progress, the ones out last
COMPARE.position = function(a, b)
    if a.dnf ~= b.dnf then return not a.dnf end
    if a.finished ~= b.finished then return a.finished end
    if a.finished then
        if lapsDone(a) ~= lapsDone(b) then return lapsDone(a) > lapsDone(b) end
        local aTime, bTime = timeOf(a), timeOf(b)
        if aTime ~= bTime then return aTime < bTime end
        if (a.finishOrder or 0) ~= (b.finishOrder or 0) then return (a.finishOrder or 0) < (b.finishOrder or 0) end
        return (a.joinIndex or 0) < (b.joinIndex or 0)
    end
    return byProgress(a, b)
end

--- best lap or run : a time beats none ; equal times, the first to set it. Retiring keeps a time
COMPARE.best = function(a, b)
    local aBest, bBest = bestOf(a), bestOf(b)
    if (aBest ~= nil) ~= (bBest ~= nil) then return aBest ~= nil end
    if aBest then
        if aBest ~= bBest then return aBest < bBest end
        if (a.bestLapAtMs or 0) ~= (b.bestLapAtMs or 0) then return (a.bestLapAtMs or 0) < (b.bestLapAtMs or 0) end
        return (a.joinIndex or 0) < (b.joinIndex or 0)
    end
    if a.dnf ~= b.dnf then return not a.dnf end
    return byProgress(a, b)
end

--- every lap or run added up : the most done, then the least time
COMPARE.total = function(a, b)
    if lapsDone(a) ~= lapsDone(b) then return lapsDone(a) > lapsDone(b) end
    if lapsDone(a) > 0 then
        local aTime, bTime = timeOf(a), timeOf(b)
        if aTime ~= bTime then return aTime < bTime end
    end
    if a.dnf ~= b.dnf then return not a.dnf end
    return byProgress(a, b)
end

--- a plugin's scores (phase.setScores) : the ones with a score first, the best first (scoreKey :
--- lower is better, whichever way the plugin counts)
COMPARE.plugin = function(a, b)
    if (a.scoreKey ~= nil) ~= (b.scoreKey ~= nil) then return a.scoreKey ~= nil end
    if a.scoreKey and a.scoreKey ~= b.scoreKey then return a.scoreKey < b.scoreKey end
    if a.dnf ~= b.dnf then return not a.dnf end
    return byProgress(a, b)
end

--- a phase's standings : by its ranking, the disqualified after, the ones not in this phase last
---@param list table[] BJRaceParticipant, sorted in place
---@param ranking BJRacePhaseRanking?
---@return table[]
function M.sort(list, ranking)
    local compare = COMPARE[ranking] or COMPARE.position
    table.sort(list, function(a, b)
        if (a.sittingOut == true) ~= (b.sittingOut == true) then return not a.sittingOut end
        if (a.disqualified == true) ~= (b.disqualified == true) then return not a.disqualified end
        return compare(a, b)
    end)
    return list
end

--- whether a racer has a result in a phase they took part in : a place in its classification
---@param p table BJRaceParticipant
---@param ranking BJRacePhaseRanking
---@return boolean
function M.classified(p, ranking)
    if p.sittingOut or p.disqualified then return false end
    if ranking == M.RANKING.BEST then return p.bestLapMs ~= nil end
    if ranking == M.RANKING.PLUGIN then return p.scoreKey ~= nil end
    if ranking == M.RANKING.TOTAL then return p.finished == true and lapsDone(p) > 0 end
    return p.finished == true
end

-- ---------------------------------------------------------------------------------------------
-- grids and who takes part, from earlier results

--- the racers (their joinIndex : it stays with them through a disconnect and their return, unlike
--- their player ID) in a result's order, reversed as asked : n the first n of the ones placed, -1
--- all of them. The ones without a place keep theirs after
---@param rows table[] a phase's results, or the event's standings
---@param reverse integer?
---@return integer[]
function M.orderOf(rows, reverse)
    local placed, rest = {}, {}
    for _, r in ipairs(rows or {}) do
        if r.position then placed[#placed + 1] = r.joinIndex else rest[#rest + 1] = r.joinIndex end
    end
    reverse = reverse or 0
    local n = reverse < 0 and #placed or math.min(reverse, #placed)
    for i = 1, math.floor(n / 2) do
        placed[i], placed[n + 1 - i] = placed[n + 1 - i], placed[i]
    end
    for _, j in ipairs(rest) do placed[#placed + 1] = j end
    return placed
end

--- the racers (joinIndex) placed in the first `top` of a result
---@param rows table[]
---@param top integer
---@return table<integer, true>
function M.topOf(rows, top)
    local set = {}
    for _, r in ipairs(rows or {}) do
        if r.position and r.position <= top then set[r.joinIndex] = true end
    end
    return set
end

-- ---------------------------------------------------------------------------------------------
-- the event's standings, across its phases

--- the event's standings from the phases run so far : "last", the latest phase counted ; "sum",
--- the times of every phase counted added up, the ones with a result in each first. nil before
--- any counted phase has finished
---@param phases BJRacePhase[]
---@param phaseResults table<integer, table[]> phase index -> its results (raceGrid's buildResults)
---@param result BJRaceEventResult
---@return table[]? rows {joinIndex, playerID, playerName, identity, vehicle, position?, totalMs?, bestLapMs?, phasesDone, dnf, disqualified}
function M.eventStandings(phases, phaseResults, result, eventScores)
    local counted = {}
    for i, phase in ipairs(phases) do
        if phaseResults[i] and phase.countsToEvent then counted[#counted + 1] = i end
    end
    -- a plugin's scores (phase.setScores with `event`) : everyone who raced, the ones scored first
    if result == M.RESULT.PLUGIN then
        local byRacer, list = {}, {}
        for i = 1, #phases do
            for _, r in ipairs(phaseResults[i] or {}) do
                local s = byRacer[r.joinIndex]
                if not s then
                    s = { joinIndex = r.joinIndex }
                    byRacer[r.joinIndex] = s
                    list[#list + 1] = s
                end
                s.playerID, s.playerName, s.connectionName = r.playerID, r.playerName, r.connectionName
                s.identity, s.vehicle = r.identity, r.vehicle
                if r.bestLapMs and (not s.bestLapMs or r.bestLapMs < s.bestLapMs) then s.bestLapMs = r.bestLapMs end
                if r.disqualified then s.disqualified = true end
            end
        end
        if #list == 0 then return nil end
        for _, s in ipairs(list) do
            local score = eventScores and eventScores[s.joinIndex]
            if score then s.score, s.scoreKey, s.scoreDisplay = score.score, score.key, score.display end
        end
        table.sort(list, function(a, b)
            if (a.disqualified == true) ~= (b.disqualified == true) then return not a.disqualified end
            if (a.scoreKey ~= nil) ~= (b.scoreKey ~= nil) then return a.scoreKey ~= nil end
            if a.scoreKey and a.scoreKey ~= b.scoreKey then return a.scoreKey < b.scoreKey end
            return a.joinIndex < b.joinIndex
        end)
        local position = 0
        for _, s in ipairs(list) do
            if s.scoreKey ~= nil and not s.disqualified then
                position = position + 1
                s.position = position
            end
            s.dnf = s.position == nil
            s.scoreKey = nil
        end
        return list
    end
    if #counted == 0 then return nil end
    if result ~= M.RESULT.SUM then
        local rows = {}
        for i, r in ipairs(phaseResults[counted[#counted]]) do rows[i] = r end
        return rows
    end
    local byRacer, list = {}, {}
    for _, i in ipairs(counted) do
        for _, r in ipairs(phaseResults[i]) do
            local s = byRacer[r.joinIndex]
            if not s then
                s = { joinIndex = r.joinIndex, playerID = r.playerID, playerName = r.playerName,
                    identity = r.identity, vehicle = r.vehicle, totalMs = 0, phasesDone = 0,
                    disqualified = false }
                byRacer[r.joinIndex] = s
                list[#list + 1] = s
            end
            -- the latest name and ID (a racer back from a disconnect has a new ID)
            s.playerID, s.playerName, s.connectionName = r.playerID, r.playerName, r.connectionName
            if r.position and r.totalMs then
                s.phasesDone = s.phasesDone + 1
                s.totalMs = s.totalMs + r.totalMs
            end
            if r.bestLapMs and (not s.bestLapMs or r.bestLapMs < s.bestLapMs) then s.bestLapMs = r.bestLapMs end
            if r.disqualified then s.disqualified = true end
        end
    end
    table.sort(list, function(a, b)
        if a.disqualified ~= b.disqualified then return not a.disqualified end
        if a.phasesDone ~= b.phasesDone then return a.phasesDone > b.phasesDone end
        if a.totalMs ~= b.totalMs then return a.totalMs < b.totalMs end
        return a.joinIndex < b.joinIndex
    end)
    local position = 0
    for _, s in ipairs(list) do
        -- placed : a result in every phase counted
        if not s.disqualified and s.phasesDone == #counted then
            position = position + 1
            s.position = position
        else
            s.totalMs = nil
        end
        s.dnf = s.position == nil
    end
    return list
end

-- ---------------------------------------------------------------------------------------------
-- plugins' formats (the plugin API's formats.register) : phase lists in the start menu, for a
-- discipline of their own. `locked` settings stay as the plugin set them, whatever the start menu
-- sends (checked again at the start, services/raceGrid.lua)

--- what a format may lock : the phase list itself ("phases" : how many, in which order), or a
--- setting of every phase
local LOCKABLE = { phases = true, name = true, start = true, length = true, ranking = true, order = true,
    takes = true, lateJoin = true, leaderboard = true, countsToEvent = true, breakS = true, rules = true,
    plugins = true }
-- a phase's fields each lockable setting covers
local LOCK_FIELDS = { length = { "laps", "timeLimitMin", "afterTime" }, start = { "start", "intervalS" } }

--- a plugin's formats, checked (their phases against a circuit : each start checks them again
--- against its own track)
---@param plugin string
---@param list any
---@return boolean ok, string? why not
function M.registerFormats(plugin, list)
    if type(list) ~= "table" then return false, "formats must be a list" end
    if #list > M.MAX_PLUGIN_FORMATS then return false, string.format("%d formats at most", M.MAX_PLUGIN_FORMATS) end
    local out, seen = {}, {}
    for i, f in ipairs(list) do
        if type(f) ~= "table" then return false, string.format("format %d must be an object", i) end
        local fid = type(f.id) == "string" and f.id:find("^%a[%w_%-]*$") and #f.id <= 32 and f.id or nil
        if not fid or seen[fid] then return false, string.format("format %d : id must be a word, unique", i) end
        seen[fid] = true
        local name = services_pluginOverlay.cleanText(f.name, 48)
        if not name then return false, string.format("format %s : a name is needed", fid) end
        local phases, why = M.sanitize(f.phases, { loopable = true })
        if not phases then return false, string.format("format %s : %s", fid, why) end
        local locked
        if f.locked == true then
            locked = true
        elseif type(f.locked) == "table" then
            locked = {}
            for _, k in ipairs(f.locked) do
                if not LOCKABLE[k] then return false, string.format("format %s : %s can't be locked", fid, tostring(k)) end
                locked[#locked + 1] = k
            end
        end
        local track = (f.track == "loop" or f.track == "pointToPoint") and f.track or "any"
        out[#out + 1] = {
            plugin = plugin,
            id = fid,
            name = name,
            description = services_pluginOverlay.cleanText(f.description, 300),
            phases = f.phases,
            result = M.sanitizeResult(f.result),
            locked = locked,
            track = track,
        }
    end
    M.pluginFormats[plugin] = #out > 0 and out or nil
    if services_pluginUi then services_pluginUi.pushDefinitions() end
    return true
end

---@param plugin string
function M.unregisterFormats(plugin)
    if not M.pluginFormats[plugin] then return end
    M.pluginFormats[plugin] = nil
    if services_pluginUi then services_pluginUi.pushDefinitions() end
end

--- every plugin's formats, for the start menu
---@return table[]
function M.formatsForClient()
    local out, plugins = {}, {}
    for plugin in pairs(M.pluginFormats) do plugins[#plugins + 1] = plugin end
    table.sort(plugins)
    for _, plugin in ipairs(plugins) do
        for _, f in ipairs(M.pluginFormats[plugin]) do
            out[#out + 1] = { ref = plugin .. ":" .. f.id, plugin = plugin, id = f.id, name = f.name,
                description = f.description, phases = M.sanitize(f.phases, { loopable = true }),
                result = f.result, locked = f.locked, track = f.track }
        end
    end
    return out
end

--- a start asking for a plugin's format ("plugin:id") : its phases for this track, with what the
--- start menu changed kept where the format doesn't lock it
---@param ref any the start options' `format`
---@param race BJRace
---@param chosen any the start menu's phases
---@return BJRacePhase[]? phases, BJRaceEventResult? result
function M.fromPluginFormat(ref, race, chosen)
    if type(ref) ~= "string" then return nil end
    local plugin, fid = ref:match("^([%w_%-]+):([%w_%-]+)$")
    local f = plugin and table.find(M.pluginFormats[plugin] or {}, function(x) return x.id == fid end)
    if not f then return nil end
    local base = M.sanitize(f.phases, race)
    if not base then return nil end
    chosen = M.sanitize(chosen, race)
    if f.locked == true or not chosen then return base, f.result end
    local locked = {}
    for _, k in ipairs(f.locked or {}) do locked[k] = true end
    -- the phase list : as many as the format's when it locks them, else the start menu's ; each
    -- phase the start menu's, with what the format locks put back as it set it
    local phases = {}
    for i = 1, locked.phases and #base or #chosen do
        local own, mine = base[i], chosen[i]
        local phase = mine or own
        if own and mine then
            for k in pairs(locked) do
                if k ~= "phases" then
                    for _, field in ipairs(LOCK_FIELDS[k] or { k }) do phase[field] = own[field] end
                end
            end
        end
        phases[i] = phase
    end
    return phases, f.result
end

return M
