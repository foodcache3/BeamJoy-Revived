--[[
BJHudLabels : an example plugin for BeamJoy's plugin API, putting labels beside racers' names on
the race HUD. Meant to be read, then copied and changed.

- Class : each racer's class, from the car they race (CLASSES below), beside their name on the
  race HUD and kept on their result and leaderboard entry (`hud = true`).
- Places : how many places they've gained or lost since the start, "+2" / "-1", updated at every
  lap. The race's live information : on the race HUD only, never kept (`hud = "only"`).

One HUD at a time, chosen in the config window's "HUD labels" tab :
- BeamJoy's race HUD (default) : BeamJoy's own, live, in each player's chosen layout, with the
  labels beside the names. The plugin only sends the labels.
- Extended : the plugin's own overlay in the race HUD's look standing in for BeamJoy's (`hides`),
  the same labels on its rows, plus every racer's best lap. It's the plugin's : it changes at laps
  only, and looks the same for everyone.

Install : copy this whole folder into Resources/Server/ (next to BeamJoyServer), restart the
server.
]]

-- this file's own path : Resources/Server/BJHudLabels/main.lua
local here = debug.getinfo(1).source:gsub("^@", ""):gsub("\\", "/")
local folder = here:match("^(.*)/[^/]*$") or "."
local BJ = dofile((folder:match("^(.*)/[^/]+$") or "..") .. "/BeamJoyServer/api/BeamJoyAPI.lua")

--- the classes, first match wins : a car whose name (as the lobby shows it, e.g. "ETK 800 Series")
--- holds one of `cars` is in that class. Anything else is in the last one
local CLASSES = {
    { label = "GT", color = "accent", cars = { "SBR4", "Scintilla", "Bolide", "Sunburst" } },
    { label = "Touring", color = "#4fa3ff", cars = { "ETK", "Pessima", "Covet" } },
    { label = "Open", color = "muted", cars = {} },
}

local function log(msg) print("[BJHudLabels] " .. msg) end

--- 1:02.345
local function clock(ms)
    if type(ms) ~= "number" then return "-" end
    local s = ms / 1000
    return string.format("%d:%06.3f", math.floor(s / 60), s % 60)
end

---@param vehicle string?
---@return table class
local function classOf(vehicle)
    for _, c in ipairs(CLASSES) do
        for _, car in ipairs(c.cars) do
            if vehicle and vehicle:find(car, 1, true) then return c end
        end
    end
    return CLASSES[#CLASSES]
end

--- "beamjoy" or "extended" (the config tab)
local hudMode = "beamjoy"

---@type table<string, {raceName: string, greenClockMs: integer, ids: integer[], shown: boolean}>
local live = {}

--- a racer's labels, as results.setFields takes them, and as an overlay row's `fields` too
---@param r table a racer from races.sessions
---@return table
local function labelsOf(r)
    local c = classOf(r.vehicle)
    local labels = {
        { key = "class", label = "Class", value = c.label, color = c.color, hud = true },
    }
    local gained = r.gridPosition and r.position and (r.gridPosition - r.position) or 0
    -- an empty value takes the label away : nothing to say while they hold their place
    labels[2] = { key = "places", label = "Places", hud = "only",
        value = gained > 0 and ("+" .. gained) or gained < 0 and tostring(gained) or "",
        color = gained > 0 and "good" or "bad" }
    if r.dnf or r.disqualified then labels[2].value = "" end
    return labels
end

--- the extended HUD : the race HUD's look, the labels on every row
---@param sessionId string
---@param session table from races.sessions
---@param nowClockMs integer? the latest event's moment (BeamJoy's clock), for the race timer
local function showExtended(sessionId, session, nowClockMs)
    local s = live[sessionId]
    if not s then return end
    local rows, fastest = {}, nil
    for i, r in ipairs(session.racers) do
        local value
        if r.disqualified then value = "DSQ"
        elseif r.dnf then value = "OUT"
        else value = r.bestLapMs and clock(r.bestLapMs) or "" end
        rows[i] = {
            pos = tostring(r.position or i),
            name = r.name,
            value = value,
            playerId = r.id,
            flag = r.finished or nil,
            out = (r.dnf or r.disqualified) or nil,
            pen = r.penaltyMs and string.format("+%gs", r.penaltyMs / 1000) or nil,
            fields = labelsOf(r),
        }
        if r.bestLapMs and (not fastest or r.bestLapMs < fastest.ms) then fastest = { name = r.name, ms = r.bestLapMs } end
    end
    local leaderLap = session.racers[1] and session.racers[1].lap or 1
    s.shown = true
    BJ.call("overlay.show", {
        id = "hud-" .. sessionId,
        players = s.ids,
        hides = { "race" },
        eyebrow = "RACING",
        title = s.raceName,
        progress = session.laps > 1 and { text = "Lap " .. math.min(leaderLap, session.laps), of = "/" .. session.laps } or nil,
        timer = { mode = "up", ms = math.max(0, (nowClockMs or s.greenClockMs) - s.greenClockMs) },
        rows = rows,
        footer = fastest and { label = "Fastest lap", name = fastest.name, value = clock(fastest.ms) } or nil,
    }, function(ok, err)
        if not ok then log("overlay.show failed : " .. tostring(err.message)) end
    end)
end

---@param sessionId string
local function hideExtended(sessionId)
    local s = live[sessionId]
    if s and s.shown then
        s.shown = false
        BJ.call("overlay.hide", { id = "hud-" .. sessionId })
    end
end

--- every racer's labels from BeamJoy's standings, sent in one call (`racers`), and the extended
--- HUD if that's the one in use
---@param sessionId string
---@param nowClockMs integer?
local function refresh(sessionId, nowClockMs)
    BJ.call("races.sessions", {}, function(ok, result)
        if not ok or not live[sessionId] then return end
        local session
        for _, x in ipairs(result.sessions) do
            if x.sessionId == sessionId then session = x end
        end
        if not session or session.state ~= "RACE" then return end
        local racers = {}
        for _, r in ipairs(session.racers) do
            -- `id` is left out while a racer is away (disconnected, inside their rejoin time)
            if r.id then racers[#racers + 1] = { playerId = r.id, fields = labelsOf(r) } end
        end
        if #racers > 0 then
            BJ.call("results.setFields", { sessionId = sessionId, racers = racers }, function(okSet, err)
                if not okSet then log("results.setFields failed : " .. tostring(err.message)) end
            end)
        end
        if hudMode == "extended" then showExtended(sessionId, session, nowClockMs)
        else hideExtended(sessionId) end
    end)
end

function onInit()
    BJ.init("BJHudLabels")

    BJ.configTab({ title = "HUD labels", sections = { { id = "hud", title = "Race HUD", options = {
        { id = "mode", type = "select", label = "HUD", default = "beamjoy", choices = {
            { value = "beamjoy", label = "BeamJoy's race HUD" },
            { value = "extended", label = "Extended" },
        }, tooltip = "Extended : this plugin's own race HUD, with every racer's best lap, standing in for BeamJoy's. Both show the labels." },
    } } } }, function(values)
        hudMode = values.mode == "extended" and "extended" or "beamjoy"
        -- changed mid-race : the races being run switch now
        for sessionId in pairs(live) do refresh(sessionId) end
    end)

    BJ.on("RaceGreenLight", function(d)
        local s = { raceName = d.raceName, greenClockMs = d.greenAt.clockMs, ids = {}, shown = false }
        for _, r in ipairs(d.racers) do
            if r.id then s.ids[#s.ids + 1] = r.id end
        end
        live[d.sessionId] = s
        refresh(d.sessionId, d.at.clockMs)
    end)
    BJ.on("RacerLap", function(d) refresh(d.sessionId, d.at.clockMs) end)
    BJ.on("RacerFinished", function(d) refresh(d.sessionId, d.at.clockMs) end)
    BJ.on("RacerOut", function(d) refresh(d.sessionId, d.at.clockMs) end)

    -- the race is over : BeamJoy's results take over (the Class label stays on them)
    local function done(d)
        hideExtended(d.sessionId)
        live[d.sessionId] = nil
    end
    BJ.on("RaceFinished", done)
    BJ.on("RaceClosed", done)
end
