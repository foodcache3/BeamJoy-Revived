--[[
BJRallycross : an example plugin for BeamJoy's plugin API, a discipline of its own built on race
phases, with rallycross joker laps. Meant to be read, then copied and changed.

A "Rallycross" format in the race start menu (circuits only) :
- Heat 1, then Heat 2 on the reversed grid of Heat 1's result. Each heat's places score points
  (POINTS below), shown beside the racers' names on the race HUD for the rest of the event.
- The Final : the top FINALISTS on points race it (the phase's `takes` : the others watch),
  gridded by points (the gridOrder hook : ties go to the better Heat 2 place).
- The event's result is the plugin's : the Final's order, then everyone else by points.
The format locks its phases and how they're ranked, gridded and picked : the starter still sets
the laps, the breaks and the rules.

THE JOKER LAP works on any race whose track has one, the format's or not : a longer way round part
of the lap that every driver has to take once in each phase. BeamJoy has no joker lap of its own,
so this plugin makes one out of parts that are already there.

The track comes first, in the race editor, and this plugin doesn't build it. A joker lane is a
BRANCH :
 1. Open the race and turn "Branching" on.
 2. Put a checkpoint inside the joker lane. That gate and the one on the short way both list the
    SAME gate before the fork as their parent, and both are parents of the gate where the two ways
    meet again.
 3. Note the joker gate's own number (the one the parent picker shows beside it) and set it as
    "Joker gate" in the editor's "Joker lap" section. 0 means this race has no joker, and nothing
    below then changes anything.
A crossing is checked against that parent graph, so either way round counts as real progress and
neither can be skipped. Each gate keeps its own number whichever step it sits on, and that is how
this plugin can tell which way a racer went : RacerGate's `gate`.

Then, per phase :
- Every racer's joker count sits on the race HUD beside their name, live : "J 0/1" in orange,
  "J 1/1" in green, "J 2/1" in red.
- A racer who still hasn't taken it as their last lap begins is told so.
- A missing joker (or an extra one) is a time penalty on the phase's result, added through the
  phaseResult hook, so it counts in the standings before the result is final, and the result shows
  why. Each heat and the final want their own.

What it shows : formats (BJ.formats), the event's result by a plugin's scores (phase.setScores
with `event`), the phaseResult hook (scoring a phase, and adding time to it, before its result is
final), the gridOrder hook, race options in the editor and the start menu (BJ.raceOptions),
RacerGate on a branching race, racer keys (a joker count has to survive a disconnect, so none of
it is keyed by player ID), live HUD labels, and hud.message to one racer of a race.

Two things to know about a branching race : BeamJoy turns sector timing off for one (splitting a
route by index or by distance stops meaning anything once it can genuinely fork), and a time
penalty only moves a phase ranked by position or by total time, not one ranked by best lap.

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
--- which laps the joker may be taken on
local WINDOWS = {
    { value = "any", label = "Any lap" },
    { value = "notfirst", label = "Not the first" },
    { value = "notlast", label = "Not the last" },
}

local function log(msg) print("[" .. NAME .. "] " .. msg) end

---@type table<string, {points: table<integer, integer>, heat2: table<integer, integer>}> sessionId ->
---each racer's points (by player ID), and their Heat 2 place (the tie-break)
local events = {}

--- the joker laps of every phase being run : sessionId -> phaseIndex -> its own state. `jokers` and
--- `warned` are keyed by RACER KEY, not by player ID : a racer key is theirs for the whole event,
--- through a disconnect and a return under a new player ID, which is exactly what a joker count has
--- to survive (see the API's "By racer key")
---@type table<string, table<integer, {laps: integer?, jokers: table<integer, integer>, warned: table<integer, boolean>}>>
local jokerPhases = {}

---@param sessionId string
local function eventOf(sessionId)
    events[sessionId] = events[sessionId] or { points = {}, heat2 = {} }
    return events[sessionId]
end

---@param sessionId string
---@param phaseIndex integer?
local function jokerState(sessionId, phaseIndex)
    local index = phaseIndex or 1
    jokerPhases[sessionId] = jokerPhases[sessionId] or {}
    jokerPhases[sessionId][index] = jokerPhases[sessionId][index] or { jokers = {}, warned = {} }
    return jokerPhases[sessionId][index]
end

--- the points on the race HUD, beside each racer's name, until the event's over (`hud = "only"` :
--- never kept on a result or a leaderboard entry). The HUD shows two of a plugin's labels per
--- racer, so these sit beside the joker count below
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

-- ---------------------------------------------------------------------------------- the joker lap

--- this race's joker rules : `options[NAME]` as the editor and the start menu left them. Every race
--- event carries them, and so does every hook question's session
---@param options table? a race event's `options`, or a hook question's `session.options`
local function rulesOf(options)
    local mine = options and options[NAME] or {}
    local gate = math.floor(tonumber(mine.gate) or 0)
    local required = math.floor(tonumber(mine.required) or 1)
    return {
        -- a race with no joker gate set, or none required, is left exactly as it was
        on = gate > 0 and required > 0,
        gate = gate,
        required = required,
        penaltyMs = math.floor((tonumber(mine.penalty) or 30) * 1000),
        window = mine.window or "any",
        extras = mine.extras ~= false,
    }
end

--- whether a joker taken on this lap counts. A timed phase has no lap count, so "not the last"
--- can't be known there and every lap counts
---@param window string
---@param lap integer
---@param laps integer?
local function inWindow(window, lap, laps)
    if window == "notfirst" then return lap > 1 end
    if window == "notlast" then return not laps or lap < laps end
    return true
end

---@param window string
local function windowReason(window)
    if window == "notfirst" then return "Not on the first lap : that joker doesn't count" end
    return "Not on the last lap : that joker doesn't count"
end

--- the joker label on the race HUD beside a racer's name. Short, because the HUD cuts it past
--- about 6 characters
---@param count integer
---@param required integer
local function jokerField(count, required)
    return {
        key = "joker",
        label = "Joker laps",
        value = string.format("J %d/%d", count, required),
        color = count > required and "bad" or (count >= required and "good" or "warn"),
        hud = "only",
    }
end

--- `racers` is a list of {racerKey, fields} : an entry naming a racer key is taken as one, so this
--- needs no `by`. Every update sends the race's standings to everyone in it, so this is only ever
--- called on something happening (a gate, a green light), never on a timer
---@param sessionId string
---@param racers table[]
local function setJokerFields(sessionId, racers)
    if #racers == 0 then return end
    BJ.call("results.setFields", { sessionId = sessionId, racers = racers }, function(ok, err)
        if not ok then log("results.setFields failed : " .. tostring(err and err.message)) end
    end)
end

---@param sessionId string
---@param racerKey integer
---@param text string
---@param color string?
local function tell(sessionId, racerKey, text, color)
    BJ.call("hud.message", { sessionId = sessionId, racerKey = racerKey, text = text,
        color = color or "warn", durationS = 6 })
end

--- the phase's joker penalties, and the labels saying why, for the phaseResult hook
---@param q table the hook's question
---@return table answer `adjustMs` by racer key, or nothing to add
local function jokerPenalties(q)
    local r = rulesOf(q.session and q.session.options)
    if not r.on then return {} end
    local st = jokerState(q.session.sessionId, q.phaseIndex)
    local ranking = q.phase and q.phase.ranking
    if ranking == "best" or ranking == "plugin" then
        log(string.format("%s is ranked by %s : a joker penalty shows but doesn't move it",
            tostring(q.phase and q.phase.name or "this phase"), tostring(ranking)))
    end

    local adjustMs, racers = {}, {}
    for _, result in ipairs(q.results or {}) do
        local key = result.racerKey
        -- a racer with no place (retired, disqualified, no time) is out of it either way
        if key and result.position then
            local count = st.jokers[key] or 0
            local missing = math.max(0, r.required - count)
            local extra = r.extras and math.max(0, count - r.required) or 0
            local field
            if missing + extra > 0 then
                local ms = (missing + extra) * r.penaltyMs
                adjustMs[key] = ms
                field = { key = "joker", label = "Joker laps",
                    value = string.format("Joker +%ds", ms / 1000), color = "bad" }
                tell(q.session.sessionId, key, missing > 0
                    and string.format("No joker lap : %d s", ms / 1000)
                    or string.format("%d joker too many : %d s", extra, ms / 1000), "bad")
            else
                -- the HUD-only label is replaced by one the result keeps : same key, no `hud`
                field = { key = "joker", label = "Joker laps", value = "Joker ok", color = "good" }
            end
            racers[#racers + 1] = { racerKey = key, fields = { field } }
        end
    end
    -- set before the answer goes back, so the fields are on the result (and on the leaderboard
    -- entry, when this run put a time there)
    setJokerFields(q.session.sessionId, racers)
    return { by = "racerKey", adjustMs = adjustMs }
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

    -- the race editor and the race start menu. The gate is the track's own, so it's set per race
    -- and the start menu can't change it (`where = "editor"`) ; the rules are the event's, so they
    -- can be changed at each start. (`where = "phase"` on one of them would give every phase of an
    -- event its own value instead, read from `phase.options[NAME]`)
    BJ.raceOptions({
        {
            id = "joker",
            title = "Joker lap",
            note = "A longer way round, to be taken once a phase. Build it as a branch, then set " ..
                "the number of its own checkpoint here.",
            options = {
                { id = "gate", type = "number", label = "Joker gate", min = 0, max = 100, step = 1,
                    default = 0, where = "editor",
                    tooltip = "The gate number of the checkpoint inside the joker lane. 0 : this race has no joker" },
                { id = "required", type = "number", label = "Jokers required", min = 0, max = 3, step = 1,
                    default = 1, tooltip = "Per phase : each heat and the final want their own" },
                { id = "penalty", type = "number", label = "Missing joker", min = 0, max = 120, step = 5,
                    unit = "s", default = 30, tooltip = "Added to the race time for each one not taken" },
                { id = "window", type = "select", label = "May be taken on", choices = WINDOWS,
                    default = "any" },
                { id = "extras", type = "toggle", label = "Extra jokers cost the same", default = true,
                    tooltip = "One more than required is an infringement too" },
            },
        },
    })

    -- a phase is over : before its result is final, the joker penalties go on (any race), then a
    -- heat is scored for points and the Final gives the event's order (this format's races only).
    -- Answering nothing keeps BeamJoy's result as it is
    BJ.hook("phaseResult", function(q)
        local answer = jokerPenalties(q)
        if q.session.format ~= FORMAT then return answer end
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
        return answer
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

    -- a phase has started : everyone's joker count goes on the HUD at 0, and the lap count is kept
    -- for the "not the last lap" rule and the last-lap warning
    BJ.on("RaceGreenLight", function(data)
        local r = rulesOf(data.options)
        local st = jokerState(data.sessionId, data.phaseIndex)
        st.laps = data.laps
        if not r.on then return end
        local racers = {}
        for _, racer in ipairs(data.racers or {}) do
            if racer.racerKey then
                st.jokers[racer.racerKey] = st.jokers[racer.racerKey] or 0
                racers[#racers + 1] = { racerKey = racer.racerKey,
                    fields = { jokerField(st.jokers[racer.racerKey], r.required) } }
            end
        end
        setJokerFields(data.sessionId, racers)
    end)

    -- a racer joined the phase after the green light (a phase's `lateJoin`) : they get a count too
    BJ.on("RacerJoinedPhase", function(data)
        local r = rulesOf(data.options)
        if not r.on or not data.racer.racerKey then return end
        local st = jokerState(data.sessionId, data.phaseIndex)
        st.jokers[data.racer.racerKey] = st.jokers[data.racer.racerKey] or 0
        setJokerFields(data.sessionId, { { racerKey = data.racer.racerKey,
            fields = { jokerField(st.jokers[data.racer.racerKey], r.required) } } })
    end)

    -- THE JOKER ITSELF : a gate went by, and on a branching race its number says which way round
    -- the racer went. BeamJoy only sends this for a crossing that's in order, so a racer who dives
    -- into the lane and reverses back out without reaching its checkpoint hasn't taken it, and a
    -- reset back onto the joker gate can't count twice (a gate already crossed isn't the next one
    -- expected any more, so it raises no event at all)
    BJ.on("RacerGate", function(data)
        local r = rulesOf(data.options)
        if not r.on or data.gate ~= r.gate or data.outLap then return end
        local key = data.racer.racerKey
        if not key then return end
        local st = jokerState(data.sessionId, data.phaseIndex)

        if not inWindow(r.window, data.lap, st.laps) then
            tell(data.sessionId, key, windowReason(r.window))
            return
        end

        local count = (st.jokers[key] or 0) + 1
        st.jokers[key] = count
        setJokerFields(data.sessionId, { { racerKey = key, fields = { jokerField(count, r.required) } } })
        if count == r.required then
            tell(data.sessionId, key, "Joker lap taken", "good")
        elseif count > r.required and r.extras then
            tell(data.sessionId, key, string.format("One joker too many : %d s", r.penaltyMs / 1000), "bad")
        end
    end)

    -- a lap went by : the one who still hasn't taken it and is starting their last lap is told,
    -- once. A timed phase has no last lap to warn about
    BJ.on("RacerLap", function(data)
        local r = rulesOf(data.options)
        local key = data.racer.racerKey
        if not r.on or not key then return end
        local st = jokerState(data.sessionId, data.phaseIndex)
        if not st.laps or data.lap ~= st.laps - 1 then return end
        if st.warned[key] or (st.jokers[key] or 0) >= r.required then return end
        st.warned[key] = true
        tell(data.sessionId, key, "Last lap : take the joker", "bad")
    end)

    local function done(d)
        events[d.sessionId] = nil
        jokerPhases[d.sessionId] = nil
    end
    BJ.on("RaceFinished", done)
    BJ.on("RaceClosed", done)
end
