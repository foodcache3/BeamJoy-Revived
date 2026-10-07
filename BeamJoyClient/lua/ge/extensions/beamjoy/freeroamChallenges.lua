--- The game's own freeroam challenges on the server's leaderboards (direct request) : drift spots
--- and drag strips. The game runs both on this game only ; this reports each finished one to the
--- server (services/freeroamChallenges.lua), which keeps everyone's best per spot / strip, and
--- feeds the Leaderboards window's Drift and Drag sections (the spots and strips of this map, from
--- the game's own data, plus the server's boards).
---
--- Drift : the game says a spot started (only its line, "<spot id> - lineOne") and, later, that it
--- was completed with a score ; the spot is remembered in between.
--- Drag : when this game's own car crosses the end of a strip (dragRaceEndLineReached) every timer
--- of the run is set ; the strip's main timer (the 1/4 mile, unless the strip times something
--- else) is what the board ranks by, lowest first. Disqualified runs (a jump start, leaving the
--- lane...) don't count.
---
--- Both are off in the game outside career unless its "Drift in freeroam" / "Drag racing in
--- freeroam" settings are on : the window offers to turn them on.

local M = {
    dependencies = {},

    KINDS = { "drift", "drag" },
    SETTINGS = { drift = "enableDriftInFreeroam", drag = "enableDragRaceInFreeroam" },

    --- the drift spot being driven, from onDriftSpotStarted until it ends
    ---@type string?
    driftSpot = nil,
    --- spot / strip id -> its name, for the result toasts
    ---@type table<string, string>
    names = {},
}

---@param key string?
---@param fallback string?
---@return string
local function gameText(key, fallback)
    if type(key) ~= "string" or key == "" then return fallback or "?" end
    -- a plain name ("Alder Main Strip") is shown as it is ; only a translation key
    -- ("levels.west_coast_usa.driftSpots.garage.name") goes through the game's translations, the
    -- fallback standing in when it has none
    if key:find("%s") or not key:find("^[%w_]+%.[%w_.]+$") then return key end
    if type(_tr) == "function" then
        local ok, res = pcall(_tr, key)
        if ok and type(res) == "string" and res ~= "" and res ~= key then return res end
    end
    return fallback or key
end

local function enabled(kind)
    return settings.getValue(M.SETTINGS[kind]) == true
end

-- THIS MAP'S SPOTS AND STRIPS -------------------------------------------------------------------

---@return table[] {id, name, preview, targets = {bronze, silver, gold}}
local function driftSpots()
    if not extensions.gameplay_drift_saveLoad then pcall(extensions.load, "gameplay_drift_saveLoad") end
    local saveLoad = extensions.gameplay_drift_saveLoad
    local ok, spots = pcall(function() return saveLoad.loadAndSanitizeDriftFreeroamSpotsCurrMap() end)
    local list = {}
    for _, spot in ipairs(ok and spots or {}) do
        if spot.id then
            local info = spot.info or {}
            local targets = {}
            for _, o in ipairs(info.objectives or {}) do
                if type(o.id) == "string" and tonumber(o.score) then targets[o.id] = tonumber(o.score) end
            end
            local name = gameText(info.name, tostring(spot.id):match("[^/]+$") or spot.id)
            M.names[spot.id] = name
            list[#list + 1] = { id = spot.id, name = name, preview = info.preview, targets = targets }
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

--- the id a strip goes by : the same table (copied) is the drag run's data, so it matches
---@param d table
---@return string?
local function stripId(d)
    local id = d.id or d._fnWithoutExt or (d.strip and d.strip.id)
    return id ~= nil and tostring(id) or nil
end

---@param d table
---@return string
local function stripName(d, id)
    local name = (d.stripInfo and d.stripInfo.stripName) or (d.strip and d.strip.name) or d.name
    return gameText(name, id)
end

--- the strip's main timer and the speed trap at the same distance
---@param d table
---@return table? main, table? trap
local function stripTimers(d)
    local timers = d.timers or (gameplay_drag_saveSystem and gameplay_drag_saveSystem.DEFAULT_TIMERS) or {}
    local mainId = d.importantTimerId or "time_1_4"
    local main, trap
    for _, t in ipairs(timers) do
        if t.id == mainId then main = t end
    end
    if main then
        for _, t in ipairs(timers) do
            if t.type == "velocity" and t.distance == main.distance then trap = t end
        end
    end
    return main, trap
end

---@return table[] {id, name, lanes, timer}
local function dragStrips()
    local core = extensions.gameplay_drag_core
    local ok, all = pcall(function() return core.getDragDataForLevel(getCurrentLevelIdentifier()) end)
    local list, seen = {}, {}
    for _, d in pairs(ok and all or {}) do
        local id = type(d) == "table" and stripId(d)
        if id and not seen[id] then
            seen[id] = true
            local main = stripTimers(d)
            local name = stripName(d, id)
            M.names[id] = name
            list[#list + 1] = {
                id = id,
                name = name,
                lanes = d.strip and d.strip.lanes and #d.strip.lanes or nil,
                timer = main and (main.label or main.shortLabel) or nil,
            }
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

local function pushSpots(kind)
    if kind ~= "drift" and kind ~= "drag" then return end
    beamjoy_communications_ui.send("BJChallengeSpots", {
        kind = kind,
        enabled = enabled(kind),
        -- trap speeds in the game's own units
        imperial = settings.getValue("uiUnitLength") == "imperial",
        spots = kind == "drift" and driftSpots() or dragStrips(),
    })
    beamjoy_communications.send("challengeSummaryRequest", kind)
end

-- RESULTS ---------------------------------------------------------------------------------------

---@return string?
local function ownCarLabel()
    local own = beamjoy_vehicles.getCurrentOwn()
    return own and beamjoy_vehicles.getModelLabel(own.jbeam) or nil
end

---@param data {lineId: string?}
local function onDriftSpotStarted(data)
    local lineId = data and data.lineId
    M.driftSpot = type(lineId) == "string" and lineId:match("^(.-) %- line%w+$") or nil
end

---@param data {score: number?}
local function onDriftSpotCompleted(data)
    local spot = M.driftSpot
    M.driftSpot = nil
    local score = data and tonumber(data.score)
    if not spot or not score or score <= 0 then return end
    beamjoy_communications.send("challengeResult", "drift", spot,
        { score = math.floor(score), vehicle = ownCarLabel() })
end

local function onDriftSpotEnded()
    M.driftSpot = nil
end

---@param vehId integer
local function dragRaceEndLineReached(vehId)
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or own.vid ~= vehId then return end
    local core = extensions.gameplay_drag_core
    local data = core and core.getData and core.getData()
    local racer = data and data.racers and data.racers[vehId]
    if not racer or racer.isDisqualified or racer.isDesqualified then return end
    local id = stripId(data)
    local main, trap = stripTimers(data)
    local timers = racer.timers or {}
    local function value(timerId)
        local t = timerId and timers[timerId]
        return t and t.isSet and tonumber(t.value) or nil
    end
    local et = main and value(main.id)
    if not id or not et or et <= 0 then return end
    local reaction
    if gameplay_drag_times and gameplay_drag_times.getReactionTimerValue then
        local ok, rt = pcall(gameplay_drag_times.getReactionTimerValue, racer)
        reaction = ok and tonumber(rt) or nil
    end
    M.names[id] = M.names[id] or stripName(data, id)
    -- every mark set, for the next run's mark-by-mark comparison (beamjoy/dragRun.lua)
    local splits = {}
    for timerId, t in pairs(timers) do
        if type(t) == "table" and t.isSet and (t.type == "distanceTimer" or t.type == "velocity") then
            splits[timerId] = tonumber(t.value)
        end
    end
    beamjoy_communications.send("challengeResult", "drag", id, {
        et = et,
        reaction = reaction,
        sixty = value("time_60"),
        trap = trap and value(trap.id) or nil,
        timer = main.label or main.shortLabel,
        dial = timers.dial and tonumber(timers.dial.value) or nil,
        splits = splits,
        vehicle = ownCarLabel(),
    })
end

--- the server kept (or didn't keep) a result : say so when it's worth saying
---@param r table
local function onResultSaved(r)
    if type(r) ~= "table" then return end
    local name = M.names[r.spot] or r.spot
    if r.saved == false then
        if r.reason == "guest" then
            toast.warn(beamjoy_lang.translate("beamjoy.challenges.toast.guest"), nil, 8)
        end
    elseif r.record then
        toast.success(string.var(beamjoy_lang.translate("beamjoy.challenges.toast.record"), { spot = name }), nil, 6)
    elseif r.best then
        toast.info(string.var(beamjoy_lang.translate("beamjoy.challenges.toast.best"),
            { spot = name, rank = r.rank or "?", players = r.players or "?" }), nil, 6)
    end
    beamjoy_communications_ui.send("BJChallengeChanged", { kind = r.kind, spot = r.spot })
    if beamjoy_dragRun and r.kind == "drag" then beamjoy_dragRun.onResultSaved(r) end
end

-- WIRING ----------------------------------------------------------------------------------------

local function onInit()
    beamjoy_communications_ui.addHandler("BJChallengeSpotsRequest", pushSpots)
    beamjoy_communications_ui.addHandler("BJChallengeBoardRequest", function(kind, spot)
        beamjoy_communications.send("challengeBoardRequest", kind, spot)
    end)
    -- the window's "Turn on" : the game's own setting, the same one as in its options
    beamjoy_communications_ui.addHandler("BJChallengeEnable", function(kind)
        if not M.SETTINGS[kind] then return end
        settings.setValue(M.SETTINGS[kind], true)
        if extensions.gameplay_rawPois then extensions.gameplay_rawPois.clear() end -- their markers
        pushSpots(kind)
    end)
    beamjoy_communications.addHandler("challengeSummary", function(data)
        beamjoy_communications_ui.send("BJChallengeSummary", data or {})
    end)
    beamjoy_communications.addHandler("challengeBoard", function(data)
        beamjoy_communications_ui.send("BJChallengeBoard", data or {})
        if beamjoy_dragRun and data and data.kind == "drag" then beamjoy_dragRun.onBoard(data) end
    end)
    beamjoy_communications.addHandler("challengeResultSaved", onResultSaved)
end

M.onInit = onInit
M.onDriftSpotStarted = onDriftSpotStarted
M.onDriftSpotCompleted = onDriftSpotCompleted
M.onDriftSpotFailed = onDriftSpotEnded
M.onDriftSpotForcedEnd = onDriftSpotEnded
M.dragRaceEndLineReached = dragRaceEndLineReached
M.pushSpots = pushSpots
-- shared with beamjoy/dragRun.lua
M.gameText = gameText
M.stripId = stripId
M.stripName = stripName
M.stripTimers = stripTimers
M.ownCarLabel = ownCarLabel

return M
