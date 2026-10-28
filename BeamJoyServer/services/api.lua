--- The plugin API (direct request : other server plugins working with BeamJoy, e.g. a website kept
--- in sync with the race leaderboards, a Discord bot, or a plugin of its own adding to the races).
---
--- Every BeamMP server plugin (each folder in Resources/Server) runs in its own Lua state : none can
--- see another's variables or call its functions, they only exchange events. So :
--- - a request : a plugin fires `BJAPI_Request` with a JSON string `{id, method, params, from}` ;
---   the answer goes out to every plugin as `BJAPI_Response` `{v, id, to, ok, result | error}`
--- - an event : BeamJoy fires `BJAPI_<Name>` with a JSON string `{v, event, instance, data}`
--- - a hook : BeamJoy asks the plugins registered for it (`BJAPI_Hook`, an event like any other)
---   and waits a moment for their answers (`hooks.answer`, a request like any other) before it
---   goes on : a ready-up a plugin can refuse, the order cars start in
--- Payloads are a public shape of their own (API_VERSION), never BeamJoy's internal tables, which
--- keep changing. The reference : api/README.md ; the helper plugins use : api/BeamJoyAPI.lua.

local M = {
    dependencies = { "services_core", "services_maps", "services_races", "services_players",
        "services_identity", "services_permissions", "services_environment", "services_clockSync", "services_racePhases",
        "dao_activity" },

    API_VERSION = 1,
    --- this server run's own id : a plugin seeing another knows BeamJoy started again
    instance = nil,
    readySent = false,
    ---@type table<string, true> maps whose races changed since the last tick (sent together)
    pendingRacesChanged = {},
    ---@type table<string, true>? who changed the environment since the last tick (sent together)
    pendingEnvironmentChanged = nil,
    ---@type table<string, fun(params: table, ctx: {plugin: string?}): any, string?, string?>
    methods = {},

    ---@type table<string, {plugin: string, timeoutMs: integer, misses: integer}[]> hook -> the
    ---plugins answering it, in the order they registered (the first one to refuse or decide wins)
    hooks = {},
    ---@type table<string, table> hookId -> the question waiting for answers
    pendingHooks = {},
    hookCounter = 0,
}

local REQUEST_EVENT = "BJAPI_Request"
local RESPONSE_EVENT = "BJAPI_Response"
local EVENTS = { "Ready", "LeaderboardChanged", "RacesChanged", "MapChanged", "PlayerJoined", "PlayerLeft",
    "RaceGridOpened", "RaceCountdown", "RaceGreenLight", "RacerLap", "RacerFinished", "RacerOut",
    "RacerStarted", "RacerJoinedPhase", "RacerGate", "RacerReset", "RacePositionsChanged", "RaceControl",
    "RacerPitEntry", "RacerPitStop", "RacerPitExit", "RacerPitPenalty", "RacerPitTow", "RacerPitReturned",
    "RacePhaseFinished", "RaceFinished", "RaceClosed", "EnvironmentChanged", "ConfigChanged", "ConfigAction",
    "PageOpened", "PageAction", "Hook" }
local LEADERBOARD_LIMIT_DEFAULT = 100

--- the questions BeamJoy asks plugins (see raceGrid.lua)
local HOOKS = {
    raceJoin = true, -- a player joins a lobby, or an event under way : a plugin may refuse, with a reason
    raceReady = true, -- a racer readies up : a plugin may refuse, with a reason
    gridOrder = true, -- the grid is about to be placed : a plugin may give the order
    phaseResult = true, -- a phase is over : a plugin may change its result (penalties, out, an order)
}
local HOOK_TIMEOUT_DEFAULT_MS = 2000
local HOOK_TIMEOUT_MAX_MS = 10000
--- unanswered questions in a row before a plugin's hook is dropped (a plugin removed or broken
--- mustn't hold every ready-up up for its timeout forever)
local HOOK_MAX_MISSES = 3

---@param name string
---@param data table
local function emit(name, data)
    local ok, json = pcall(utils_json.stringifyRaw,
        { v = M.API_VERSION, event = name, instance = M.instance, data = data })
    if not ok or not json then
        return LogError(string.format("[BJ api] %s couldn't be encoded : %s", name, tostring(json)))
    end
    MP.TriggerGlobalEvent("BJAPI_" .. name, json)
end

--- GetCurrentTime() reads a UTC date as local time (os.time(os.date("!*t"))) : off from real Unix
--- time by the server's UTC offset, unless it runs on UTC. Stored dates are put right here
---@param t any a date GetCurrentTime() gave
---@return integer?
local function unixTime(t)
    t = tonumber(t)
    if not t then return nil end
    return math.floor(t - (GetCurrentTime() - os.time()))
end

-- the shared clock (services_clockSync, milliseconds, the one the race's green light is set on)
-- against real Unix time : taken together once, so a moment on that clock converts to Unix
-- milliseconds (right to about a second, os.time's own precision ; the time between two moments
-- is exact)
local unixBaseMs, clockBaseMs

---@param clockMs integer? a moment on services_clockSync's clock (default : now)
---@return {unixMs: integer, clockMs: integer}
local function stamp(clockMs)
    clockMs = clockMs or services_clockSync.nowMs()
    if not unixBaseMs then
        unixBaseMs, clockBaseMs = os.time() * 1000, services_clockSync.nowMs()
    end
    return { unixMs = math.floor(unixBaseMs + (clockMs - clockBaseMs)), clockMs = clockMs }
end

--- a param left out, or sent as JSON null (the parser's own marker for it, an empty table)
---@param v any
---@return boolean
local function absent(v)
    return v == nil or (type(v) == "table" and next(v) == nil)
end

---@param v any
---@return string? a map name safe to put in a file path, or nil
local function saneMapName(v)
    if type(v) ~= "string" or #v == 0 or #v > 128 then return nil end
    if not v:find("^[%w_%-%.]+$") or v:find("%.%.") then return nil end
    return v
end

---@param params table
---@return string? map, string? error
local function mapParam(params)
    if absent(params.map) then
        return services_core.getCurrentMap()
    end
    local map = saneMapName(params.map)
    if not map then return nil, "map must be a map's name (like \"west_coast_usa\")" end
    return map
end

--- a map's races : the current map's from memory (up to the second), another's from disk
---@param map string
---@return table[]
local function racesOf(map)
    if map == services_core.getCurrentMap() then return services_races.data or {} end
    local list = dao_activity.get(map, services_races.ACTIVITY_TYPE)
    return type(list) == "table" and list or {}
end

---@param params table
---@return "grid"|"freeroam"? board, string? error
local function boardParam(params, default)
    local b = params.board
    if absent(b) then return default end
    if b == "grid" or b == "freeroam" then return b end
    return nil, "board must be \"grid\" or \"freeroam\""
end

---@param params table
---@return integer? limit, string? error
local function limitParam(params)
    if absent(params.limit) then return LEADERBOARD_LIMIT_DEFAULT end
    local n = tonumber(params.limit)
    if not n or n < 1 then return nil, "limit must be a number, 1 or more" end
    return math.floor(n)
end

---@param e table services_races.sortedEntries' entry
local function entryOut(e)
    return {
        rank = e.rank,
        name = e.playerName,
        timeMs = e.time,
        model = type(e.model) == "string" and #e.model > 0 and e.model or nil,
        date = unixTime(e.date),
        -- "nickname", "guest", "beammp", or "unknown" for a time saved before BeamJoy kept it
        identity = e.identity or "unknown",
        -- plugins' labels on the run that set it (services/pluginUi.lua)
        fields = e.fields or {},
    }
end

---@param race table
---@param board "grid"|"freeroam"
---@param limit integer?
---@return {total: integer, entries: table[]}
local function boardOut(race, board, limit)
    local all = services_races.sortedEntries(race, board)
    local entries = {}
    for i = 1, math.min(#all, limit or #all) do entries[i] = entryOut(all[i]) end
    return { total = #all, entries = entries }
end

---@param race table
local function raceOut(race)
    local grid = services_races.sortedEntries(race, "grid")
    local freeroam = services_races.sortedEntries(race, "freeroam")
    return {
        id = race.id,
        name = race.name,
        author = race.author,
        distanceM = tonumber(race.distance) and math.floor(race.distance + .5) or nil,
        loopable = race.loopable == true,
        laps = race.defaults and tonumber(race.defaults.laps) or nil,
        gates = type(race.gates) == "table" and #race.gates or 0,
        freeroam = race.freeroam == true,
        vehicleRestriction = race.vehicleRestrictionMode or "free",
        -- plugins' own race options as set for this race in the editor : plugin -> option -> value
        options = race.defaults and type(race.defaults.plugins) == "table" and race.defaults.plugins or {},
        times = { grid = #grid, freeroam = #freeroam },
        records = {
            grid = grid[1] and entryOut(grid[1]) or nil,
            freeroam = freeroam[1] and entryOut(freeroam[1]) or nil,
        },
    }
end

local function playerCount()
    return services_players.players:length()
end

local function serverInfo()
    local map = services_core.getCurrentMap()
    local mapData = services_maps.data and services_maps.data[map]
    local methods, hooks = {}, {}
    for name in pairs(M.methods) do methods[#methods + 1] = name end
    for name in pairs(HOOKS) do hooks[#hooks + 1] = name end
    table.sort(methods)
    table.sort(hooks)
    return {
        api = M.API_VERSION,
        instance = M.instance,
        beamjoy = { version = BeamJoyServer.VERSION, build = BeamJoyServer.BUILD },
        map = { name = map, label = mapData and mapData.label or map },
        players = playerCount(),
        methods = methods,
        events = EVENTS,
        hooks = hooks,
    }
end

-- ---------------------------------------------------------------------------------------------
-- races being run (services/raceGrid.lua's sessions), in the API's own shape

---@param lapSectors table<integer, integer>? sector -> its time, ms
---@return integer[] the sectors' times in order, as far as they're timed
local function sectorsOf(lapSectors)
    local out = {}
    if type(lapSectors) ~= "table" then return out end
    local i = 1
    while lapSectors[i] do
        out[i] = lapSectors[i]
        i = i + 1
    end
    return out
end

--- every completed lap of a racer : {lap, timeMs, sectorsMs[]}
---@param p table BJRaceParticipant
local function lapsOf(p)
    local laps = {}
    for i, t in ipairs(p.lapTimes or {}) do
        laps[i] = { lap = i, timeMs = t, sectorsMs = sectorsOf(p.lapSectorHistory and p.lapSectorHistory[i]) }
    end
    return laps
end

--- one racer, as plugins see them. `id` is their player ID while connected ; nil while they're
--- away (disconnected mid-race, waiting under a key of their own). `racerKey` is theirs for the
--- whole event, away or back under a new ID (their joinIndex)
---@param p table BJRaceParticipant
---@param session table? BJRaceSession, for their fields
---@return table
local function racerOut(p, session)
    local info = services_raceGrid.racerInfo(p)
    local best = p.bestLapMs
    if not best and p.lapTimes and #p.lapTimes > 0 then best = math.min(table.unpack(p.lapTimes)) end
    return {
        id = p.playerID >= 0 and p.playerID or nil,
        racerKey = p.joinIndex,
        name = info.name,
        identity = info.identity,
        away = p.disconnected == true,
        vehicle = p.vehicleModel,
        ready = p.ready == true,
        readyChecking = p.readyChecking == true,
        readyBlock = p.readyBlockReason and { reason = p.readyBlockReason, by = p.readyBlockBy } or nil,
        gridPosition = p.gridPosition,
        lap = p.currentLap,
        finished = p.finished == true,
        dnf = p.dnf == true,
        disqualified = p.disqualified == true,
        penaltyMs = (p.penaltyMs or 0) > 0 and p.penaltyMs or nil,
        bestLapMs = best,
        -- this phase's laps (or runs) added up, with penalties
        totalMs = p.lapTimes and #p.lapTimes > 0 and services_racePhases.timeOf(p) or nil,
        -- in the phase being run ; not : left out of it (its `takes`), or out of the event
        inPhase = p.sittingOut ~= true,
        -- a start of their own (a staggered start, a run, a mid-phase join) : when they go
        startAt = p.startAtMs and stamp(p.startAtMs) or nil,
        -- a plugin's phase : waiting for the plugin to start them (race.startRacer)
        awaitingStart = p.awaitingStart == true or nil,
        -- the pits (PIT_SYSTEM_PLAN.md) : in the pit lane, stops made this phase
        inPit = p.inPit == true or nil,
        pitStops = p.pitStops,
        -- a plugin's score this phase (phase.setScores)
        score = p.score,
        scoreDisplay = p.scoreDisplay,
        -- plugins' labels on them (results.setFields, and race options marked `field`)
        fields = session and services_pluginUi.fieldList(services_pluginUi.racerFields(session, p)) or {},
    }
end

--- a phase, as plugins see it (services/racePhases.lua's, with its place)
---@param phase table BJRacePhase
---@param index integer
---@return table
local function phaseOut(phase, index)
    return {
        index = index,
        name = phase.name,
        start = phase.start,
        intervalS = phase.intervalS,
        laps = phase.laps,
        timeLimitMin = phase.timeLimitMin,
        afterTime = phase.afterTime,
        ranking = phase.ranking,
        order = phase.order,
        takes = phase.takes,
        lateJoin = phase.lateJoin,
        leaderboard = phase.leaderboard,
        countsToEvent = phase.countsToEvent,
        breakS = phase.breakS,
        rules = phase.rules,
        -- plugins' own options for this phase (race options `where = "phase"`) : plugin -> option -> value
        options = phase.plugins or {},
    }
end

---@param session table BJRaceSession
---@return table
local function sessionBase(session)
    local race = services_races.getById(session.raceId)
    local index = session.phaseIndex or 1
    return {
        sessionId = session.id,
        raceId = session.raceId,
        raceName = race and race.name or "?",
        map = services_core.getCurrentMap(),
        -- plugins' own race options for this race (services/pluginUi.lua) : plugin -> option -> value
        options = session.settings and session.settings.plugins or {},
        -- the phase being run (in the lobby, the first), and how many the event has
        phaseIndex = index,
        phase = session.phases and session.phases[index] and phaseOut(session.phases[index], index) or nil,
        phaseCount = session.phases and #session.phases or 1,
        -- a plugin's format it runs ("plugin:id", formats.register)
        format = session.format,
    }
end

--- a phase's results (raceGrid's buildResults), or the event's standings, as plugins see them :
--- in order, the placed ones first with their `position`
---@param rows table[]
---@return table[]
local function resultsOut(rows)
    local out = {}
    for i, r in ipairs(rows or {}) do
        local placed = r.position ~= nil
        out[i] = {
            position = r.position,
            id = r.playerID and r.playerID >= 0 and r.playerID or nil,
            racerKey = r.joinIndex,
            name = r.playerName,
            identity = r.identity or "unknown",
            vehicle = r.vehicle,
            finished = placed,
            disqualified = r.disqualified == true,
            totalMs = placed and r.totalMs or nil,
            bestLapMs = r.bestLapMs,
            penaltyMs = r.penaltyMs,
            newPB = r.isNewPB == true,
            newRecord = r.isNewRecord == true,
            leaderboardRank = r.rank,
            fields = r.fields or {},
            laps = lapsOf(r),
            bestSectorsMs = sectorsOf(r.bestSectorMs),
            -- the event's standings, "sum" : how many of the phases counted they have a result in
            phasesDone = r.phasesDone,
            -- a plugin's score (phase.setScores)
            score = r.score,
            scoreDisplay = r.scoreDisplay,
        }
    end
    return out
end

--- every phase run so far : [{phase, results}]
---@param session table BJRaceSession
---@return table[]
local function phaseResultsOut(session)
    local out = {}
    for i, phase in ipairs(session.phases or {}) do
        local rows = session.phaseResults and session.phaseResults[i]
        if rows then out[#out + 1] = { phase = phaseOut(phase, i), results = resultsOut(rows) } end
    end
    return out
end

---@param session table BJRaceSession
---@return table
local function sessionOut(session)
    local out = sessionBase(session)
    local race = services_races.getById(session.raceId)
    out.state = session.state
    out.joinable = session.joinable == true
    out.private = session.private == true
    -- the phase's : nil when it's timed only
    out.laps = session.settings and session.settings.laps
    out.timeLimitMin = session.settings and session.settings.timeLimitMin
    out.placementMode = session.settings and session.settings.placementMode
    out.gridSlots = race and race.startPositions and #race.startPositions or 0
    out.greenAt = session.goAtMs and stamp(session.goAtMs) or nil
    out.endsAt = session.phaseEndsAtMs and stamp(session.phaseEndsAtMs) or nil
    out.timeUpAt = session.flagAtMs and stamp(session.flagAtMs) or nil
    out.breakEndsAt = session.breakEndsAtMs and stamp(session.breakEndsAtMs) or nil
    out.result = session.result
    out.phases = {}
    for i, phase in ipairs(session.phases or {}) do out.phases[i] = phaseOut(phase, i) end
    out.phaseResults = phaseResultsOut(session)
    out.eventStandings = session.eventStandings and resultsOut(session.eventStandings) or nil
    local starter = session.participants[session.starterID]
    out.starter = starter and services_raceGrid.racerInfo(starter).name or nil
    -- a plugin's lobby (race.open) : that plugin, and the lobby's name
    out.hostedBy = session.hostedBy
    out.hostName = session.hostedBy and session.hostName or nil
    out.holdStart = session.holdStart == true or nil
    out.racers = {}
    local racing = session.state == "RACE" or session.state == "BREAK" or session.state == "FINISHED"
    for i, p in ipairs(services_raceGrid.computeLeaderboard(session)) do
        local r = racerOut(p, session)
        if racing and not p.sittingOut then r.position = i end
        out.racers[i] = r
    end
    return out
end

--- a racer's time on this race's grid leaderboard, if they have one
---@param session table BJRaceSession
---@param name string their leaderboard name
---@return integer?
local function leaderboardMs(session, name)
    local race = services_races.getById(session.raceId)
    local entry = race and race.leaderboard and race.leaderboard[name]
    return entry and tonumber(entry.time) or nil
end

--- a connected player, as plugins see them (players.online)
---@param p table services_players player
---@return table
local function playerOut(p)
    return {
        id = p.playerID,
        name = p.playerName,
        displayName = p.identityNickname or p.displayName or p.playerName,
        nickname = p.identityNickname,
        guest = p.guest == true,
        group = p.group,
        staff = services_permissions.isStaff(p.playerName) == true,
    }
end

--- the raceJoin hook's question : who's joining which session, and whether it's under way
---@param session table BJRaceSession
---@param player table services_players player
---@param midway boolean
---@return table
function M.joinHookData(session, player, midway)
    local out = playerOut(player)
    out.identity = services_identity.getIdentityKind(player.playerID) or (player.guest and "guest" or "beammp")
    out.leaderboardMs = leaderboardMs(session, services_identity.getIdentityKey(player.playerID) or player.playerName)
    return { session = sessionOut(session), player = out, midway = midway == true }
end

--- the raceReady hook's question : who's readying up, in what, for which race
---@param session table BJRaceSession
---@param p table BJRaceParticipant
---@return table
function M.readyHookData(session, p)
    local racer = racerOut(p, session)
    racer.leaderboardMs = leaderboardMs(session, racer.name)
    return { session = sessionOut(session), racer = racer }
end

--- the gridOrder hook's question : the racers, the order BeamJoy would place them in, the phase
--- it's for and the phases run before it
---@param session table BJRaceSession
---@param grid {p: table, slot: integer}[] BeamJoy's own grid
---@return table
function M.gridOrderHookData(session, grid)
    local racers, defaultOrder = {}, {}
    for i, e in ipairs(grid) do
        local r = racerOut(e.p, session)
        r.leaderboardMs = leaderboardMs(session, r.name)
        r.joinIndex = e.p.joinIndex
        racers[i] = r
        defaultOrder[i] = e.p.playerID
    end
    local index = session.phaseIndex or 1
    return {
        session = sessionOut(session),
        racers = racers,
        defaultOrder = defaultOrder,
        phaseIndex = index,
        phase = phaseOut(session.phases[index], index),
        previous = phaseResultsOut(session),
        event = session.eventStandings and resultsOut(session.eventStandings) or nil,
    }
end

--- the phaseResult hook's question : the phase just over, its result as BeamJoy has it
---@param session table BJRaceSession
---@return table
function M.phaseResultHookData(session)
    local index = session.phaseIndex or 1
    return {
        session = sessionOut(session),
        phaseIndex = index,
        phase = phaseOut(session.phases[index], index),
        results = resultsOut(services_raceGrid.provisionalResults(session)),
        previous = phaseResultsOut(session),
    }
end

---@param sessionId any
---@return table? session
local function findSession(sessionId)
    if type(sessionId) ~= "string" or not services_raceGrid then return nil end
    return services_raceGrid.sessions[sessionId]
end

--- the racer a request names : `racerKey` (theirs for the whole event, see racerOut) or `playerId`
---@param session table BJRaceSession
---@param params table
---@return integer? playerID their key in the session (an away racer's is below 0), string? code, string? why
local function racerIdParam(session, params)
    if not absent(params.racerKey) then
        local key = tonumber(params.racerKey)
        local p = key and services_raceGrid.participantByKey(session, math.floor(key))
        if not p then return nil, "notFound", "no racer " .. tostring(params.racerKey) .. " in this race" end
        return p.playerID
    end
    local id = tonumber(params.playerId)
    if not id then return nil, "badParams", "playerId (or racerKey) is needed" end
    return math.floor(id)
end

--- one racer a plugin names in a list or a map : a player ID, or a racer key when it says
--- `by = "racerKey"`
---@param id any
---@param byKey boolean
---@param session table? BJRaceSession
---@return integer? playerID
local function idOf(id, byKey, session)
    id = tonumber(id)
    if not id then return nil end
    id = math.floor(id)
    if not byKey then return id end
    local p = session and services_raceGrid.participantByKey(session, id)
    return p and p.playerID or nil
end

--- a reason a plugin gives (race control, closing a race), checked
---@param v any
---@return string|false? reason (false : not text)
local function reasonParam(v)
    if absent(v) then return nil end
    if type(v) ~= "string" then return false end
    return services_pluginOverlay.cleanText(v, 200)
end

-- ---------------------------------------------------------------------------------------------
-- methods : each takes its params table and who's asking, and returns its result, or nil, an
-- error code and why

---@param ctx {plugin: string?}
---@return string? plugin, string? error
local function pluginOf(ctx)
    if ctx.plugin then return ctx.plugin end
    return nil, "this method needs your plugin's name in the request's `from` (the helper sends it)"
end

M.methods["server.info"] = function()
    return serverInfo()
end

M.methods["maps.list"] = function()
    local current = services_core.getCurrentMap()
    local list = {}
    for name, map in pairs(services_maps.data or {}) do
        if not map.ignore then
            list[#list + 1] = {
                name = name,
                label = map.label or name,
                modded = map.base ~= true,
                enabled = map.enabled == true,
                current = name == current,
            }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return { maps = list }
end

M.methods["races.list"] = function(params)
    local map, err = mapParam(params)
    if not map then return nil, "badParams", err end
    local races = {}
    for _, race in ipairs(racesOf(map)) do races[#races + 1] = raceOut(race) end
    return { map = map, races = races }
end

M.methods["races.leaderboard"] = function(params)
    local map, err = mapParam(params)
    if not map then return nil, "badParams", err end
    local board, boardErr = boardParam(params, "grid")
    if not board then return nil, "badParams", boardErr end
    local limit, limitErr = limitParam(params)
    if not limit then return nil, "badParams", limitErr end
    local raceId = tonumber(params.raceId)
    if not raceId then return nil, "badParams", "raceId is needed (races.list gives them)" end
    local race = table.find(racesOf(map), function(r) return r.id == raceId end)
    if not race then return nil, "notFound", string.format("no race %s on %s", raceId, map) end
    local out = boardOut(race, board, limit)
    return { map = map, raceId = race.id, raceName = race.name, board = board, total = out.total,
        entries = out.entries }
end

M.methods["races.leaderboards"] = function(params)
    local map, err = mapParam(params)
    if not map then return nil, "badParams", err end
    local board, boardErr = boardParam(params, false)
    if board == nil then return nil, "badParams", boardErr end
    local races = {}
    for _, race in ipairs(racesOf(map)) do
        local boards = {}
        if not board or board == "grid" then boards.grid = boardOut(race, "grid") end
        if not board or board == "freeroam" then boards.freeroam = boardOut(race, "freeroam") end
        races[#races + 1] = { raceId = race.id, raceName = race.name, boards = boards }
    end
    return { map = map, races = races }
end

M.methods["races.sessions"] = function()
    local list = {}
    if services_raceGrid then
        services_raceGrid.sessions:forEach(function(s) list[#list + 1] = sessionOut(s) end)
    end
    table.sort(list, function(a, b) return a.sessionId < b.sessionId end)
    return { sessions = list }
end

M.methods["race.setGridOrder"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    if type(params.order) ~= "table" then
        return nil, "badParams", "order must be a list of player IDs, first on the grid first"
    end
    local order, byKey = {}, params.by == "racerKey"
    for _, id in ipairs(params.order) do
        if not tonumber(id) then return nil, "badParams", "order must be a list of player IDs (or racer keys)" end
        -- a racer key that isn't a racer's : left out, as a player ID that isn't
        order[#order + 1] = idOf(id, byKey, session)
    end
    local ok, why = services_raceGrid.pluginSetGridOrder(session, order, plugin)
    if not ok then return nil, "refused", why end
    return { sessionId = session.id, order = order }
end

M.methods["race.unready"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local playerID = tonumber(params.playerId)
    if not absent(params.racerKey) then
        local session = findSession(params.sessionId)
        if not session then return nil, "notFound", "a racerKey needs its sessionId" end
        local code, why
        playerID, code, why = racerIdParam(session, params)
        if not playerID then return nil, code, why end
    end
    if not playerID then return nil, "badParams", "playerId is needed" end
    local reason = params.reason
    if absent(reason) then reason = nil end
    if reason ~= nil and type(reason) ~= "string" then return nil, "badParams", "reason must be text" end
    if reason then reason = services_pluginOverlay.cleanText(reason, 200) end
    local ok, why = services_raceGrid.pluginUnready(math.floor(playerID), reason, plugin)
    if not ok then return nil, "refused", why end
    return { playerId = playerID }
end

-- ---------------------------------------------------------------------------------------------
-- an event's phases (services/racePhases.lua) : formats, and a running event's controls

--- the plugin's own formats in the start menu (replacing the ones it registered before)
M.methods["formats.register"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local ok, why = services_racePhases.registerFormats(plugin, params.formats)
    if not ok then return nil, "badParams", why end
    return { formats = #params.formats }
end

M.methods["formats.unregister"] = function(_, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    services_racePhases.unregisterFormats(plugin)
    return {}
end

--- a lobby's phases, before it starts
M.methods["race.setPhases"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    local result = not absent(params.result) and params.result or nil
    local ok, why = services_raceGrid.pluginSetPhases(session, params.phases, result)
    if not ok then return nil, why == "only while the lobby is open" and "refused" or "badParams", why end
    local phases = {}
    for i, phase in ipairs(session.phases) do phases[i] = phaseOut(phase, i) end
    return { sessionId = session.id, phases = phases, result = session.result }
end

--- the phase under way, now over (a red flag, a judged run done)
M.methods["race.endPhase"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    local ok, why = services_raceGrid.pluginEndPhase(session)
    if not ok then return nil, "refused", why end
    return { sessionId = session.id, phaseIndex = session.phaseIndex }
end

--- more time for a timed phase (`minutes`, less with a negative), or more laps (runs) for one on
--- laps (`laps`)
M.methods["race.extendPhase"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    if params.laps ~= nil and params.minutes == nil then
        local laps = tonumber(params.laps)
        if not laps or laps ~= laps or laps ~= math.floor(laps) or laps == 0 or math.abs(laps) > 999 then
            return nil, "badParams", "laps must be a whole number, not 0, 999 at most either way"
        end
        local ok, why = services_raceGrid.pluginExtendLaps(session, laps)
        if not ok then return nil, "refused", why end
        return { sessionId = session.id, laps = session.settings.laps }
    end
    local minutes = tonumber(params.minutes)
    if not minutes or minutes ~= minutes or minutes == 0 or math.abs(minutes) > 600 then
        return nil, "badParams", "minutes must be a number, not 0, 600 at most either way"
    end
    local ok, why = services_raceGrid.pluginExtendPhase(session, minutes)
    if not ok then return nil, "refused", why end
    return { sessionId = session.id, endsAt = stamp(session.phaseEndsAtMs) }
end

--- no more break : the next phase's countdown now
M.methods["race.nextPhase"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    local ok, why = services_raceGrid.pluginNextPhase(session)
    if not ok then return nil, "refused", why end
    return { sessionId = session.id, phaseIndex = session.phaseIndex }
end

--- a plugin's phase (start = "plugin") : this racer goes, after a countdown
M.methods["race.startRacer"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    local playerID, code, err = racerIdParam(session, params)
    if not playerID then return nil, code, err end
    if not absent(params.from) and params.from ~= "grid" and params.from ~= "first" then
        return nil, "badParams", "from must be \"grid\" or \"first\""
    end
    local ok, why = services_raceGrid.pluginStartRacer(session, playerID,
        not absent(params.countdownS) and params.countdownS or nil, not absent(params.from) and params.from or nil)
    if not ok then return nil, "refused", why end
    local p = session.participants[playerID]
    return { sessionId = session.id, playerId = playerID >= 0 and playerID or nil, racerKey = p.joinIndex,
        startAt = stamp(p.startAtMs) }
end

--- this racer's phase is over (finished with the laps they did, out without any)
M.methods["race.stopRacer"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    local playerID, code, err = racerIdParam(session, params)
    if not playerID then return nil, code, err end
    local p = session.participants[playerID]
    local ok, why = services_raceGrid.pluginStopRacer(session, playerID)
    if not ok then return nil, "refused", why end
    return { sessionId = session.id, playerId = playerID >= 0 and playerID or nil, racerKey = p and p.joinIndex }
end

--- scores : this phase's (its ranking "plugin" places racers by them) or the event's (`event`, its
--- result "plugin")
M.methods["phase.setScores"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    if type(params.scores) ~= "table" then return nil, "badParams", "scores must be {[playerId] = number}" end
    if not absent(params.better) and params.better ~= "high" and params.better ~= "low" then
        return nil, "badParams", "better must be \"high\" or \"low\""
    end
    -- every key, not ipairs : {[3] = ..} arrives as an array with holes (see results.setFields)
    local scores, display, n = {}, {}, 0
    for k, v in pairs(params.scores) do
        -- the gaps of {[3] = .., [7] = ..} sent as an array (JSON nulls) : nothing there
        if not absent(v) then
            local id, score = tonumber(k), tonumber(v)
            if not id or not score or score ~= score then return nil, "badParams", "scores must be {[playerId] = number}" end
            scores[math.floor(id)] = score
            n = n + 1
        end
    end
    if n > 64 then return nil, "badParams", "64 racers at most" end
    if type(params.display) == "table" then
        for k, v in pairs(params.display) do
            local id = tonumber(k)
            local text = services_pluginOverlay.cleanText(v, 16)
            if id and text then display[math.floor(id)] = text end
        end
    end
    -- a player who isn't a racer of this event (or, for a phase's scores, no longer in the race) is
    -- left out rather than failing everyone else's
    local skipped = services_raceGrid.pluginSetScores(session, scores,
        params.better == "high" and "high" or "low", display, params.event == true, params.by == "racerKey")
    return { sessionId = session.id, count = n - #skipped, skipped = #skipped > 0 and skipped or nil }
end

-- ---------------------------------------------------------------------------------------------
-- race control : stewarding a racer while the phase runs, as staff watching it can

---@param action "penalty"|"clearPenalties"|"disqualify"|"reinstate"
local function raceControlMethod(action)
    return function(params, ctx)
        local plugin, perr = pluginOf(ctx)
        if not plugin then return nil, "badParams", perr end
        local session = findSession(params.sessionId)
        if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
        local playerID, code, err = racerIdParam(session, params)
        if not playerID then return nil, code, err end
        local ms
        if action == "penalty" then
            ms = tonumber(params.ms)
            if not ms or ms ~= ms or math.abs(ms) < 1 or math.abs(ms) > 600000 then
                return nil, "badParams", "ms must be a number of milliseconds, 600000 at most either way, not 0"
            end
            ms = math.floor(ms)
        end
        local reason = reasonParam(params.reason)
        if reason == false then return nil, "badParams", "reason must be text" end
        local ok, why, p, change = services_raceGrid.pluginControlRacer(session, playerID, action, ms, plugin, reason)
        if not ok then return nil, "refused", why end
        return { sessionId = session.id, playerId = p.playerID >= 0 and p.playerID or nil, racerKey = p.joinIndex,
            penaltyMs = p.penaltyMs or 0, changeMs = change ~= 0 and change or nil, disqualified = p.disqualified == true }
    end
end

--- a time penalty (`ms`, time taken off with a negative), on their race time at once
M.methods["race.penalize"] = raceControlMethod("penalty")
M.methods["race.clearPenalties"] = raceControlMethod("clearPenalties")
M.methods["race.disqualify"] = raceControlMethod("disqualify")
M.methods["race.reinstate"] = raceControlMethod("reinstate")

-- ---------------------------------------------------------------------------------------------
-- a plugin's own lobbies : scheduled events, league nights

--- a lobby of the plugin's, on a race of the current map
M.methods["race.open"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local raceId = tonumber(params.raceId)
    if not raceId then return nil, "badParams", "raceId is needed (races.list gives them)" end
    local options = params.options
    if absent(options) then options = {} end
    if type(options) ~= "table" then return nil, "badParams", "options must be an object (the start options)" end
    local name
    if not absent(params.name) then
        name = type(params.name) == "string" and services_pluginOverlay.cleanText(params.name, 48) or nil
        if not name then return nil, "badParams", "name must be text" end
    end
    if not absent(params.holdStart) and type(params.holdStart) ~= "boolean" then
        return nil, "badParams", "holdStart must be true or false"
    end
    local entrants
    if params.entrants ~= nil then
        if type(params.entrants) ~= "table" then return nil, "badParams", "entrants must be a list of player IDs" end
        entrants = {}
        for _, id in ipairs(params.entrants) do
            if not tonumber(id) then return nil, "badParams", "entrants must be a list of player IDs" end
            entrants[#entrants + 1] = math.floor(tonumber(id))
        end
        if #entrants == 0 then return nil, "badParams", "entrants must name a player at least (leave it out : anyone)" end
    end
    local session, why, invited = services_raceGrid.pluginOpen(plugin, math.floor(raceId), options,
        { name = name, holdStart = params.holdStart == true, entrants = entrants })
    if not session then return nil, "refused", why end
    local out = sessionOut(session)
    out.invited = invited
    return out
end

--- a session ends now (a lobby, or an event under way), its racers told why
M.methods["race.close"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    local reason = reasonParam(params.reason)
    if reason == false then return nil, "badParams", "reason must be text" end
    LogInfo(string.format("[BJ api] %s closed race session %s (%s)", plugin, session.id, session.state))
    services_raceGrid.pluginClose(session, reason)
    return { sessionId = session.id }
end

--- a lobby starts now, as when its time runs out
M.methods["race.startNow"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    local ok, why = services_raceGrid.pluginStartNow(session)
    if not ok then return nil, "refused", why end
    -- nobody was ready : the lobby closed
    return { sessionId = session.id, state = findSession(session.id) and session.state or "CLOSED" }
end

M.methods["players.online"] = function()
    local players = {}
    services_players.players:forEach(function(p) players[#players + 1] = playerOut(p) end)
    table.sort(players, function(a, b) return a.id < b.id end)
    return { players = players }
end

local function environmentOut()
    local env = services_environment.data
    local tod = services_environment.currentToD()
    local year, month, day = services_environment.currentDate()
    -- the game's time of day : 0 is noon, .5 midnight
    local minutes = math.floor(((tod * 24 + 12) % 24) * 60 + .5) % (24 * 60)
    return {
        timeOfDay = tod,
        clock = string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60),
        timeSync = env.timeSync == true,
        dayNightCycle = env.dayNightCycle == true,
        dayLengthS = env.dayLength,
        date = year and { year = year, month = month, day = day } or nil,
        simSpeed = env.simSpeed,
        simPause = env.simPause == true,
        gravity = env.gravity,
        gravitySync = env.gravitySync == true,
        weatherSync = env.weatherSync == true,
        -- what an admin set in the game's weather panel while weather sync is on (its own fields
        -- and units), nil while the map's own weather plays
        weather = env.weatherSync and env.weather or nil,
    }
end

M.methods["environment.get"] = function()
    return environmentOut()
end

--- time and weather, as staff set them in BeamJoy's environment panel. Only the fields sent change
M.methods["environment.set"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local payload = {}
    if not absent(params.clock) then
        local h, m = tostring(params.clock):match("^(%d%d?):(%d%d)$")
        h, m = tonumber(h), tonumber(m)
        if not h or h > 23 or m > 59 then return nil, "badParams", "clock must be \"HH:MM\"" end
        -- the game's scale : 0 is noon
        payload.ToD = ((h * 60 + m) / 1440 - .5) % 1
    elseif not absent(params.timeOfDay) then
        local tod = tonumber(params.timeOfDay)
        if not tod then return nil, "badParams", "timeOfDay must be a number (0 is noon, .5 midnight)" end
        payload.ToD = tod % 1
    end
    for _, key in ipairs({ "timeSync", "dayNightCycle", "weatherSync" }) do
        if not absent(params[key]) then
            if type(params[key]) ~= "boolean" then return nil, "badParams", key .. " must be true or false" end
            payload[key] = params[key]
        end
    end
    if not absent(params.dayLengthS) then
        if not tonumber(params.dayLengthS) then return nil, "badParams", "dayLengthS must be a number" end
        payload.dayLength = tonumber(params.dayLengthS)
    end
    if not absent(params.date) then
        local d = params.date
        if type(d) ~= "table" or not tonumber(d.year) or not tonumber(d.month) or not tonumber(d.day) then
            return nil, "badParams", "date must be {year, month, day}"
        end
        payload.year, payload.month, payload.day = d.year, d.month, d.day
    end
    if not absent(params.weather) then
        if type(params.weather) ~= "table" then return nil, "badParams", "weather must be an object" end
        payload.weather = params.weather
    end
    if next(payload) == nil then return nil, "badParams", "nothing to change" end
    local ctxt = InitContext()
    ctxt.apiSource = "plugin:" .. plugin
    services_environment.changeEnv(ctxt, payload)
    return environmentOut()
end

M.methods["overlay.show"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local ok, why = services_pluginOverlay.show(plugin, params)
    if not ok then return nil, "badParams", why end
    return { id = params.id }
end

M.methods["overlay.hide"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local ok, why = services_pluginOverlay.hide(plugin, params)
    if not ok then return nil, "badParams", why end
    return { id = params.id }
end

M.methods["overlay.clear"] = function(_, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    return { removed = services_pluginOverlay.clear(plugin) }
end

--- the line of text across BeamJoy's own HUD (the one "X started a race" used to use) : for
--- everyone, a list of players, one player, or a race's racers and / or spectators (one racer of it,
--- by racer key)
M.methods["hud.message"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    if type(params.text) ~= "string" or #params.text == 0 then return nil, "badParams", "text is needed" end
    local targets = (params.players ~= nil and 1 or 0) + (not absent(params.playerId) and 1 or 0) +
        (not absent(params.sessionId) and 1 or 0)
    if targets > 1 then return nil, "badParams", "players, playerId or sessionId : one of them" end
    local message = { text = params.text, color = params.color, durationS = params.durationS, players = params.players }
    if not absent(params.playerId) then
        local id = tonumber(params.playerId)
        if not id then return nil, "badParams", "playerId must be a player ID" end
        message.players = { math.floor(id) }
    elseif not absent(params.sessionId) then
        local session = findSession(params.sessionId)
        if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
        if not absent(params.racerKey) then
            local id, code, err = racerIdParam(session, params)
            if not id then return nil, code, err end
            message.players = { id }
        else
            local audience = absent(params.audience) and "all" or params.audience
            if audience ~= "all" and audience ~= "racers" and audience ~= "spectators" then
                return nil, "badParams", "audience must be \"racers\", \"spectators\" or \"all\""
            end
            message.players = services_raceGrid.audienceOf(session, audience)
        end
    end
    local ok, why = services_pluginOverlay.message(message)
    if not ok then return nil, "badParams", why end
    return {}
end

-- ---------------------------------------------------------------------------------------------
-- plugins' own options, fields and config tabs (services/pluginUi.lua)

--- sections of options in the race start menu and the race editor
M.methods["raceOptions.register"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local ok, why = services_pluginUi.registerRaceOptions(plugin, params)
    if not ok then return nil, "badParams", why end
    return { sections = #params.sections }
end

M.methods["raceOptions.unregister"] = function(_, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    services_pluginUi.unregisterRaceOptions(plugin)
    return {}
end

--- the tyre sets racers can pick in the pit menu (the server's experimental tyre changes)
M.methods["tyres.register"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local ok, why = services_pluginUi.registerTyreOptions(plugin, params)
    if not ok then return nil, "badParams", why end
    return { options = #params.options }
end

M.methods["tyres.unregister"] = function(_, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    services_pluginUi.unregisterTyreOptions(plugin)
    return {}
end

--- labels on a racer's result in a race being run (and on the leaderboard entry it set, if it did),
--- or on several racers' at once (`racers`)
M.methods["results.setFields"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local session = findSession(params.sessionId)
    if not session then return nil, "notFound", "no race session " .. tostring(params.sessionId) end
    if params.racers ~= nil then
        -- {[playerId] = fields} or [{playerId, fields, replace?}] : every racer checked before any
        -- changes, so a mistake changes nothing
        if type(params.racers) ~= "table" then return nil, "badParams", "racers must be a list or an object" end
        -- every key, not ipairs : the helper sends {[3] = ..., [7] = ...} as a JSON array with gaps
        -- (nulls), which arrives as a table with holes
        -- `by = "racerKey"` : the keys are racer keys ; a list's entries may name either
        local list, byKey = {}, params.by == "racerKey"
        for k, r in pairs(params.racers) do
            if type(r) ~= "table" then return nil, "badParams", "each racer's fields must be a list or an object" end
            if r.racerKey ~= nil then
                list[#list + 1] = { id = r.racerKey, byKey = true, fields = r.fields, replace = r.replace }
            elseif r.playerId ~= nil then
                list[#list + 1] = { id = r.playerId, fields = r.fields, replace = r.replace }
            else
                list[#list + 1] = { id = k, byKey = byKey, fields = r }
            end
        end
        table.sort(list, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
        if #list > 64 then return nil, "badParams", "64 racers at most" end
        local checked, ids = {}, {}
        for _, r in ipairs(list) do
            if not tonumber(r.id) then return nil, "badParams", "each racer needs a playerId (or racerKey)" end
            local id = idOf(r.id, r.byKey == true, session)
            if not id or not session.participants[id] then
                return nil, "notFound", string.format("%s %s isn't in this race", r.byKey and "racer" or "player",
                    tostring(r.id))
            end
            local fields, why = services_pluginUi.fieldsOf(r.fields)
            if not fields then return nil, "badParams", string.format("player %d : %s", id, why) end
            checked[#checked + 1] = { id = id, fields = fields, replace = r.replace == true or params.replace == true }
        end
        for _, r in ipairs(checked) do
            services_raceGrid.pluginSetFields(session, r.id, plugin, r.fields, r.replace)
            ids[#ids + 1] = r.id
        end
        return { sessionId = session.id, playerIds = ids }
    end
    local playerID, code, err = racerIdParam(session, params)
    if not playerID then return nil, code, err end
    local fields, why = services_pluginUi.fieldsOf(params.fields)
    if not fields then return nil, "badParams", why end
    local ok, notFound = services_raceGrid.pluginSetFields(session, playerID, plugin, fields,
        params.replace == true)
    if not ok then return nil, "notFound", notFound end
    return { sessionId = session.id, playerId = playerID >= 0 and playerID or nil }
end

--- labels on a leaderboard entry, on the current map
M.methods["leaderboard.setFields"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    if not absent(params.map) and params.map ~= services_core.getCurrentMap() then
        return nil, "refused", "only the current map's leaderboards can be changed"
    end
    local board, boardErr = boardParam(params, "grid")
    if not board then return nil, "badParams", boardErr end
    local raceId = tonumber(params.raceId)
    if not raceId then return nil, "badParams", "raceId is needed" end
    if type(params.name) ~= "string" then return nil, "badParams", "name (the entry's name) is needed" end
    local fields, why = services_pluginUi.fieldsOf(params.fields)
    if not fields then return nil, "badParams", why end
    if not services_races.setEntryFields(raceId, board, params.name, plugin, fields, params.replace == true) then
        return nil, "notFound", string.format("no %s entry for %s on race %s", board, params.name, raceId)
    end
    return { raceId = raceId, board = board, name = params.name }
end

--- a tab of the plugin's own settings in BeamJoy's config window (stored by BeamJoy)
M.methods["config.register"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local ok, why = services_pluginUi.registerConfigTab(plugin, params)
    if not ok then return nil, "badParams", why end
    return { values = services_pluginUi.configOf(plugin) }
end

M.methods["config.unregister"] = function(_, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    services_pluginUi.unregisterConfigTab(plugin)
    return {}
end

--- the plugin's own config values (its defaults where none are stored)
M.methods["config.get"] = function(_, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    return { values = services_pluginUi.configOf(plugin) }
end

--- sets the plugin's own config values (the ones its tab describes)
M.methods["config.set"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    if not services_pluginUi.configTabs[plugin] then
        return nil, "refused", "register a config tab first (config.register)"
    end
    if type(params.values) ~= "table" then return nil, "badParams", "values must be an object" end
    local changed = services_pluginUi.setConfig(plugin, params.values)
    local keys = {}
    for k in pairs(changed) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys > 0 then M.configChanged(plugin, keys, "plugin:" .. plugin) end
    return { values = services_pluginUi.configOf(plugin), changed = keys }
end

-- ---------------------------------------------------------------------------------------------
-- plugins' own pages in the main window (services/pluginPages.lua)

--- a page : a rail button with its side panel, a tab in the full window, or both
M.methods["pages.register"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local ok, why = services_pluginPages.register(plugin, params)
    if not ok then return nil, "badParams", why end
    return { id = params.id }
end

--- a page's content : everyone's, or the players given their own
M.methods["pages.update"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local ok, why, code = services_pluginPages.update(plugin, params)
    if not ok then return nil, code or "badParams", why end
    return { id = params.id }
end

--- one page, or (no id) every page of the plugin's
M.methods["pages.unregister"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    if params.id == nil then return { removed = services_pluginPages.clear(plugin) } end
    services_pluginPages.unregister(plugin, params.id)
    return { id = params.id }
end

-- ---------------------------------------------------------------------------------------------
-- hooks : BeamJoy asks, the plugins registered for that question answer, BeamJoy goes on with
-- their answers once they've all answered or the time's up

---@param name string
---@return boolean whether any plugin answers this hook (when none does, BeamJoy doesn't wait)
local function hasHook(name)
    return M.hooks[name] ~= nil and #M.hooks[name] > 0
end

---@param id string
---@param timedOut boolean
local function finishHook(id, timedOut)
    local q = M.pendingHooks[id]
    if not q then return end
    M.pendingHooks[id] = nil
    local answers = {}
    for _, plugin in ipairs(q.plugins) do
        local answer = q.answers[plugin]
        local reg = table.find(M.hooks[q.name] or {}, function(r) return r.plugin == plugin end)
        if answer then
            answers[#answers + 1] = { plugin = plugin, answer = answer }
            if reg then reg.misses = 0 end
        elseif reg then
            reg.misses = reg.misses + 1
            LogWarn(string.format("[BJ api] %s didn't answer the %s hook in time", plugin, q.name))
            if reg.misses >= HOOK_MAX_MISSES then
                M.hooks[q.name] = table.filter(M.hooks[q.name], function(r) return r ~= reg end)
                LogWarn(string.format("[BJ api] %s missed the %s hook %d times in a row : dropped (it registers again to come back)",
                    plugin, q.name, HOOK_MAX_MISSES))
            end
        end
    end
    local ok, err = pcall(q.done, answers, timedOut)
    if not ok then LogError(string.format("[BJ api] the %s hook's result failed : %s", q.name, tostring(err))) end
end

--- asks the plugins registered for `name`, then calls `done(answers)` : {plugin, answer}[] in
--- registration order (the ones that answered). Right away (no wait) when nobody's registered
---@param name string
---@param data table
---@param done fun(answers: {plugin: string, answer: table}[], timedOut: boolean)
local function runHook(name, data, done)
    if not hasHook(name) then return done({}, false) end
    M.hookCounter = M.hookCounter + 1
    local id = string.format("%s-%d", name, M.hookCounter)
    local plugins, timeout = {}, 0
    for _, r in ipairs(M.hooks[name]) do
        plugins[#plugins + 1] = r.plugin
        timeout = math.max(timeout, r.timeoutMs)
    end
    M.pendingHooks[id] = {
        name = name,
        plugins = plugins,
        answers = {},
        deadline = services_clockSync.nowMs() + timeout,
        done = done,
    }
    emit("Hook", { hookId = id, hook = name, plugins = plugins, timeoutMs = timeout, data = data })
end

M.methods["hooks.register"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    if not HOOKS[params.hook] then
        local names = {}
        for n in pairs(HOOKS) do names[#names + 1] = n end
        table.sort(names)
        return nil, "badParams", "hook must be one of : " .. table.concat(names, ", ")
    end
    local timeout = HOOK_TIMEOUT_DEFAULT_MS
    if not absent(params.timeoutMs) then
        timeout = tonumber(params.timeoutMs)
        if not timeout then return nil, "badParams", "timeoutMs must be a number" end
        timeout = math.clamp(math.floor(timeout), 100, HOOK_TIMEOUT_MAX_MS)
    end
    M.hooks[params.hook] = M.hooks[params.hook] or {}
    local reg = table.find(M.hooks[params.hook], function(r) return r.plugin == plugin end)
    if reg then
        reg.timeoutMs, reg.misses = timeout, 0
    else
        table.insert(M.hooks[params.hook], { plugin = plugin, timeoutMs = timeout, misses = 0 })
        LogInfo(string.format("[BJ api] %s answers the %s hook", plugin, params.hook))
    end
    return { hook = params.hook, timeoutMs = timeout }
end

M.methods["hooks.unregister"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    if M.hooks[params.hook] then
        M.hooks[params.hook] = table.filter(M.hooks[params.hook], function(r) return r.plugin ~= plugin end)
    end
    return { hook = params.hook }
end

M.methods["hooks.answer"] = function(params, ctx)
    local plugin, perr = pluginOf(ctx)
    if not plugin then return nil, "badParams", perr end
    local q = M.pendingHooks[params.hookId]
    if not q then return nil, "notFound", "no question " .. tostring(params.hookId) .. " waiting (answered too late?)" end
    if not table.includes(q.plugins, plugin) then return nil, "refused", "this question wasn't asked to " .. plugin end
    q.answers[plugin] = params
    for _, p in ipairs(q.plugins) do
        if not q.answers[p] then return {} end
    end
    finishHook(params.hookId, false)
    return {}
end

--- the first refusal among a raceReady hook's answers
---@param answers {plugin: string, answer: table}[]
---@return {reason: string, by: string}?
local function firstBlock(answers)
    for _, a in ipairs(answers) do
        if a.answer.allow == false then
            local reason = services_pluginOverlay.cleanText(a.answer.reason, 200) or ""
            return { reason = reason, by = a.plugin }
        end
    end
end

--- a hook answer's list of racers as player IDs : `by = "racerKey"` in the answer, racer keys
---@param list table
---@param answer table
---@param session table? BJRaceSession
---@return integer[]
local function answerIds(list, answer, session)
    local out = {}
    for _, id in ipairs(list) do
        local playerID = idOf(id, answer.by == "racerKey", session)
        if playerID then out[#out + 1] = playerID end
    end
    return out
end

--- the first `take` (who races the phase : player IDs) among a gridOrder hook's answers
---@param answers {plugin: string, answer: table}[]
---@param session table? BJRaceSession (answers by racer key)
---@return integer[]?, string? plugin
local function firstTake(answers, session)
    for _, a in ipairs(answers) do
        if type(a.answer.take) == "table" and #a.answer.take > 0 then
            local take = answerIds(a.answer.take, a.answer, session)
            if #take > 0 then return take, a.plugin end
        end
    end
end

--- the phaseResult hook's answers together : every plugin's time adjustments added up, every
--- racer any of them puts out, and the first order given
---@param answers {plugin: string, answer: table}[]
---@param session table? BJRaceSession (answers by racer key)
---@return {adjustMs: table<integer, integer>, out: integer[], order: integer[]?}
local function judging(answers, session)
    local out = { adjustMs = {}, out = {} }
    for _, a in ipairs(answers) do
        local ans = a.answer
        if type(ans.adjustMs) == "table" then
            for id, ms in pairs(ans.adjustMs) do
                id, ms = idOf(id, ans.by == "racerKey", session), tonumber(ms)
                if id and ms and ms == ms then
                    out.adjustMs[id] = math.clamp((out.adjustMs[id] or 0) + math.floor(ms), -3600000, 3600000)
                end
            end
        end
        if type(ans.out) == "table" then
            for _, id in ipairs(answerIds(ans.out, ans, session)) do out.out[#out.out + 1] = id end
        end
        if not out.order and type(ans.order) == "table" and #ans.order > 0 then
            local order = answerIds(ans.order, ans, session)
            if #order > 0 then out.order = order end
        end
    end
    return out
end

--- the first grid order among a gridOrder hook's answers
---@param answers {plugin: string, answer: table}[]
---@param session table? BJRaceSession (answers by racer key)
---@return integer[]?, string? plugin
local function firstOrder(answers, session)
    for _, a in ipairs(answers) do
        if type(a.answer.order) == "table" and #a.answer.order > 0 then
            local order = answerIds(a.answer.order, a.answer, session)
            if #order > 0 then return order, a.plugin end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- requests

---@param raw any
local function onRequest(raw)
    -- a player's game can trigger any server event too (TriggerServerEvent) : BeamMP then passes
    -- the sender's ID first, a number. Only plugins (TriggerGlobalEvent) pass the JSON alone
    if type(raw) ~= "string" then
        if type(raw) == "number" then
            LogWarn(string.format("[BJ api] %s (player %d) sent a plugin API request from their game, ignored",
                tostring(MP.GetPlayerName(raw)), raw))
        end
        return
    end
    local parsed, req = pcall(utils_json.parse, raw)
    if not parsed or type(req) ~= "table" or (type(req.id) ~= "string" and type(req.id) ~= "number") then
        return LogWarn("[BJ api] a plugin sent a request that isn't valid (JSON with an id), ignored")
    end
    local function respond(ok, payload)
        local msg = { v = M.API_VERSION, id = req.id, to = type(req.from) == "string" and req.from or nil, ok = ok }
        if ok then msg.result = payload else msg.error = payload end
        local encoded, json = pcall(utils_json.stringifyRaw, msg)
        if not encoded or not json then
            LogError(string.format("[BJ api] %s's answer couldn't be encoded : %s", tostring(req.method), tostring(json)))
            json = utils_json.stringifyRaw({ v = M.API_VERSION, id = req.id, to = msg.to, ok = false,
                error = { code = "internal", message = "the answer couldn't be encoded" } })
        end
        MP.TriggerGlobalEvent(RESPONSE_EVENT, json)
    end
    local method = type(req.method) == "string" and M.methods[req.method]
    if not method then
        return respond(false, { code = "unknownMethod", message = "no method " .. tostring(req.method) ..
            " (server.info lists them)" })
    end
    local params = type(req.params) == "table" and req.params or {}
    local ctx = {
        plugin = type(req.from) == "string" and req.from:find("^[%w_%-]+$") and #req.from <= 64 and req.from or nil,
    }
    local ran, result, code, why = pcall(method, params, ctx)
    if not ran then
        LogError(string.format("[BJ api] %s failed : %s", req.method, tostring(result)))
        return respond(false, { code = "internal", message = tostring(result) })
    end
    if result == nil then
        return respond(false, { code = code or "internal", message = why })
    end
    respond(true, result)
end

-- ---------------------------------------------------------------------------------------------
-- events, from the services

--- a time added to (or put back on) a race's leaderboard, on the current map (services_races)
---@param raceId integer
---@param board "grid"|"freeroam"
---@param kind "pb"|"restored" a new personal best, or a disqualified run's replaced time put back
---@param name string the leaderboard name that changed
function M.leaderboardChanged(raceId, board, kind, name)
    local race = services_races.getById(raceId)
    if not race then return end
    local out = boardOut(race, board)
    emit("LeaderboardChanged", {
        map = services_core.getCurrentMap(),
        raceId = race.id,
        raceName = race.name,
        board = board,
        change = { kind = kind, name = name },
        total = out.total,
        entries = out.entries,
    })
end

--- a map's races were added, edited (which clears their times), deleted or imported : sent on the
--- next tick, once per map however many changed
---@param map string
function M.racesChanged(map)
    if type(map) == "string" then M.pendingRacesChanged[map] = true end
end

--- time, weather or the sim changed (services_environment) : sent on the next tick, once
---@param by string who : a player's name, "plugin:<name>", or "server"
function M.environmentChanged(by)
    M.pendingEnvironmentChanged = M.pendingEnvironmentChanged or {}
    M.pendingEnvironmentChanged[by or "server"] = true
end

--- a lobby opened
---@param session table BJRaceSession
function M.raceGridOpened(session)
    emit("RaceGridOpened", sessionOut(session))
end

--- the grid is placed and the countdown runs : the order, and when the light goes green
---@param session table BJRaceSession
---@param grid table[] BJRaceParticipant, in grid order
---@param orderedBy string? the plugin that gave the order, if one did
function M.raceCountdown(session, grid, orderedBy)
    local data = sessionBase(session)
    data.at = stamp()
    data.greenAt = stamp(session.goAtMs)
    data.countdownS = session.settings.countdown
    data.orderedBy = orderedBy
    data.grid = {}
    for i, p in ipairs(grid) do
        local r = racerOut(p, session)
        r.gridPosition = i
        data.grid[i] = r
    end
    emit("RaceCountdown", data)
end

---@param session table BJRaceSession
function M.raceGreenLight(session)
    local data = sessionBase(session)
    data.at = stamp()
    data.greenAt = stamp(session.goAtMs)
    -- the phase's : nil when it's timed only
    data.laps = session.settings.laps
    data.timeLimitMin = session.settings.timeLimitMin
    data.endsAt = session.phaseEndsAtMs and stamp(session.phaseEndsAtMs) or nil
    data.racers = {}
    session.participants:forEach(function(p)
        if not p.sittingOut then data.racers[#data.racers + 1] = racerOut(p, session) end
    end)
    emit("RaceGreenLight", data)
end

--- a racer completed a lap (their last one included : RacerFinished follows)
---@param session table BJRaceSession
---@param p table BJRaceParticipant
function M.racerLap(session, p)
    local data = sessionBase(session)
    data.at = stamp()
    data.racer = racerOut(p, session)
    local lap = #p.lapTimes
    data.lap = lap
    data.lapMs = p.lapTimes[lap]
    data.sectorsMs = sectorsOf(p.lapSectorHistory and p.lapSectorHistory[lap])
    local raceMs = 0
    for _, t in ipairs(p.lapTimes) do raceMs = raceMs + t end
    data.raceMs = raceMs
    data.bestLap = p.bestLapMs == data.lapMs
    for i, other in ipairs(services_raceGrid.computeLeaderboard(session)) do
        if other == p then data.position = i end
    end
    emit("RacerLap", data)
end

---@param session table BJRaceSession
---@param p table BJRaceParticipant
function M.racerFinished(session, p)
    local data = sessionBase(session)
    data.at = stamp()
    data.racer = racerOut(p, session)
    data.finishOrder = p.finishOrder
    local raceMs = 0
    for _, t in ipairs(p.lapTimes or {}) do raceMs = raceMs + t end
    data.raceMs = raceMs
    data.totalMs = raceMs + (p.penaltyMs or 0)
    data.laps = lapsOf(p)
    data.newPB = p.isNewPB == true
    data.newRecord = p.isNewRecord == true
    emit("RacerFinished", data)
end

--- a racer's own start was set (services/racePhases.lua : their next run on a point-to-point track,
--- or a mid-phase join) : when they go
---@param session table BJRaceSession
---@param p table BJRaceParticipant
function M.racerStarted(session, p)
    local data = sessionBase(session)
    data.at = stamp()
    data.racer = racerOut(p, session)
    data.startAt = p.startAtMs and stamp(p.startAtMs) or nil
    -- their run (or lap) about to start
    data.run = p.currentLap
    emit("RacerStarted", data)
end

--- a racer's place in the phase's standings now (the ones sitting it out left out)
---@param session table BJRaceSession
---@param p table BJRaceParticipant
---@return integer?
local function positionOf(session, p)
    local place = 0
    for _, other in ipairs(services_raceGrid.computeLeaderboard(session)) do
        if not other.sittingOut then
            place = place + 1
            if other == p then return place end
        end
    end
end

--- a racer went through a gate (every one, the line included). When it completes a lap, after
--- RacerLap (and RacerFinished, or RacerStarted for their next run)
---@param session table BJRaceSession
---@param p table BJRaceParticipant
---@param c {gate: integer, step: integer, lap: integer, lapMs: integer?, deltaMs: integer?, lapComplete: boolean?, outLap: boolean?, sectors: {sector: integer, ms: integer}[]?}
function M.racerGate(session, p, c)
    local data = sessionBase(session)
    data.at = stamp()
    data.racer = racerOut(p, session)
    data.gate = c.gate
    data.step = c.step
    data.lap = c.lap
    data.lapComplete = c.lapComplete == true
    data.outLap = c.outLap == true or nil
    data.lapMs = c.lapMs
    data.deltaMs = c.deltaMs
    data.sectors = c.sectors or {}
    data.position = positionOf(session, p)
    emit("RacerGate", data)
end

--- a racer reset (recovered, respawned at a checkpoint...), as their game reports it
---@param session table BJRaceSession
---@param p table BJRaceParticipant
---@param addedMs integer? the reset's time penalty, when the race has one
function M.racerReset(session, p, addedMs)
    local s = session.settings
    local data = sessionBase(session)
    data.at = stamp()
    data.racer = racerOut(p, session)
    data.lap = p.currentLap
    data.lastGate = p.lastCrossedGate ~= 0 and p.lastCrossedGate or nil
    data.respawn = s.respawnStrategy
    data.penaltyMs = addedMs and addedMs > 0 and addedMs or nil
    data.holdS = s.resetPenaltyEnabled and s.resetPenaltyMode ~= "time" and s.resetPenaltySeconds or nil
    emit("RacerReset", data)
end

local PIT_EVENTS = { entry = "RacerPitEntry", stop = "RacerPitStop", exit = "RacerPitExit",
    penalty = "RacerPitPenalty", tow = "RacerPitTow", returned = "RacerPitReturned" }

--- a racer and the pits (raceGrid.lua's racePit) : in through PIT IN (`speedKmh`), a stop made
--- (`fuelL`, `repair`, `tyres`, `tyreOption`, `durationMs`, `servedMs`, `towed`), out through PIT OUT (`stopped`), a pit
--- penalty (`reason` "entrySpeed"|"transit"|"missingStops"|"stopShort", `penaltyMs`), a tow (`holdMs`, `metres`), back
--- in their box after the phase (`towed`)
---@param session table BJRaceSession
---@param p table BJRaceParticipant
---@param kind "entry"|"stop"|"exit"|"penalty"|"tow"|"returned"
---@param fields table?
function M.racerPit(session, p, kind, fields)
    local name = PIT_EVENTS[kind]
    if not name then return end
    local data = sessionBase(session)
    data.at = stamp()
    data.racer = racerOut(p, session)
    data.lap = p.currentLap
    for k, v in pairs(fields or {}) do data[k] = v end
    emit(name, data)
end

--- places changed during a phase (an overtake, a finish, a penalty) : who, from where to where
---@param session table BJRaceSession
---@param changes {p: table, from: integer, to: integer}[] best place first
function M.racePositionsChanged(session, changes)
    local data = sessionBase(session)
    data.at = stamp()
    data.changes = {}
    for i, c in ipairs(changes) do
        data.changes[i] = { racer = racerOut(c.p, session), from = c.from, to = c.to }
    end
    emit("RacePositionsChanged", data)
end

--- race control acted on a racer : staff, or a plugin
---@param session table BJRaceSession
---@param p table BJRaceParticipant
---@param action "penalty"|"clearPenalties"|"disqualify"|"reinstate"
---@param change integer the penalty time added (taken off, negative), 0 for the others
---@param by string "staff:<name>" or "plugin:<name>"
---@param reason string?
function M.raceControl(session, p, action, change, by, reason)
    local data = sessionBase(session)
    data.at = stamp()
    data.racer = racerOut(p, session)
    data.action = action
    data.ms = change ~= 0 and change or nil
    data.penaltyMs = p.penaltyMs or 0
    data.by = by
    data.reason = reason
    emit("RaceControl", data)
end

--- a player joined the event while a phase was under way (its `lateJoin`) and is in it now
---@param session table BJRaceSession
---@param p table BJRaceParticipant
function M.racerJoinedPhase(session, p)
    local data = sessionBase(session)
    data.at = stamp()
    data.racer = racerOut(p, session)
    emit("RacerJoinedPhase", data)
end

--- a racer stopped without finishing, or was disqualified
---@param session table BJRaceSession
---@param p table BJRaceParticipant
---@param reason "retired"|"disconnected"|"disqualified"
function M.racerOut(session, p, reason)
    local data = sessionBase(session)
    data.at = stamp()
    data.racer = racerOut(p, session)
    data.reason = reason
    data.laps = lapsOf(p)
    emit("RacerOut", data)
end

--- one of an event's phases is over (raceGrid.lua's completePhase) : its results, the event's
--- standings so far, and what's next
---@param session table BJRaceSession
---@param index integer the phase
---@param results table[] its results (raceGrid's buildResults), in order
function M.racePhaseFinished(session, index, results)
    local data = sessionBase(session)
    data.at = stamp()
    data.phaseIndex = index
    data.phase = phaseOut(session.phases[index], index)
    data.results = resultsOut(results)
    data.eventStandings = session.eventStandings and resultsOut(session.eventStandings) or nil
    local next = session.phases[index + 1]
    data.nextPhase = next and phaseOut(next, index + 1) or nil
    data.breakS = next and session.phases[index].breakS or nil
    emit("RacePhaseFinished", data)
end

--- an event ended (raceGrid.lua's finishEvent) : its result, and every phase's
---@param session table BJRaceSession
---@param info table {raceName, laps}
---@param results table[] the event's standings (or the last phase's results), in order
function M.raceFinished(session, info, results)
    local data = sessionBase(session)
    data.raceName = info.raceName
    data.laps = info.laps
    data.at = stamp()
    data.greenAt = session.goAtMs and stamp(session.goAtMs) or nil
    data.result = session.result
    data.results = resultsOut(results)
    data.phases = phaseResultsOut(session)
    emit("RaceFinished", data)
end

--- a plugin's config tab was saved (or the plugin set its values) : its values, and which changed.
--- Goes to every plugin like any event ; `plugin` says whose. Secrets left out, `secretsSet` saying
--- which are set (security review : a plugin passing every event on, to Discord or a log, passed
--- the API keys on too). The plugin reads them with config.get, as the helper does
---@param plugin string
---@param changed string[]
---@param by string a player's name, or "plugin:<name>"
function M.configChanged(plugin, changed, by)
    local values, secretsSet = services_pluginUi.configOf(plugin, true)
    emit("ConfigChanged", { plugin = plugin, values = values, secretsSet = secretsSet or {}, changed = changed,
        by = by })
end

--- a button on a plugin's config tab was clicked
---@param plugin string
---@param action string the button's id
---@param by {id: integer, name: string}
function M.configAction(plugin, action, by)
    emit("ConfigAction", { plugin = plugin, action = action, by = by })
end

--- a player opened one of a plugin's pages (its side panel or its tab)
---@param plugin string
---@param page string the page's id
---@param by {id: integer, name: string}
function M.pageOpened(plugin, page, by)
    emit("PageOpened", { plugin = plugin, page = page, by = by })
end

--- a button on a plugin's page was clicked
---@param plugin string
---@param page string the page's id
---@param action string the button's id
---@param values table the page's fields, as that player set them (checked)
---@param by {id: integer, name: string}
function M.pageAction(plugin, page, action, values, by)
    emit("PageAction", { plugin = plugin, page = page, action = action, values = values, by = by })
end

--- a session ended without finishing : cancelled, everyone left, nobody ready in time
---@param session table BJRaceSession
function M.raceClosed(session)
    local data = sessionBase(session)
    data.at = stamp()
    data.state = session.state
    emit("RaceClosed", data)
end

-- ---------------------------------------------------------------------------------------------
-- hooks (BeamJoy's own lifecycle)

local function onInit()
    M.instance = UUID()
    _G._BJSApiRequest = onRequest
    MP.RegisterEvent(REQUEST_EVENT, "_BJSApiRequest")
end

local function onUpdate()
    -- once every module is up (onInit's order is a hash's) : plugins that started first learn
    -- BeamJoy is here
    if not M.readySent then
        M.readySent = true
        stamp() -- the Unix / shared clock pairing, from here on
        emit("Ready", serverInfo())
        LogInfo(string.format("[BJ api] plugin API ready (v%d)", M.API_VERSION))
    end
    if next(M.pendingRacesChanged) then
        local maps = M.pendingRacesChanged
        M.pendingRacesChanged = {}
        for map in pairs(maps) do emit("RacesChanged", { map = map }) end
    end
    if M.pendingEnvironmentChanged then
        local by = {}
        for name in pairs(M.pendingEnvironmentChanged) do by[#by + 1] = name end
        table.sort(by)
        M.pendingEnvironmentChanged = nil
        local data = environmentOut()
        data.by = by
        emit("EnvironmentChanged", data)
    end
    if next(M.pendingHooks) then
        local now = services_clockSync.nowMs()
        local late = {}
        for id, q in pairs(M.pendingHooks) do
            if now >= q.deadline then late[#late + 1] = id end
        end
        for _, id in ipairs(late) do finishHook(id, true) end
    end
end

local function onMapChanged(oldMap, newMap)
    emit("MapChanged", { from = oldMap, to = newMap })
end

local function onPlayerJoin(playerID)
    local name = MP.GetPlayerName(playerID)
    local p = name and services_players.players[name]
    emit("PlayerJoined", { id = playerID, name = name, guest = p and p.guest == true or false,
        players = playerCount() })
end

local function onPlayerDisconnect(playerID)
    -- other modules' own onPlayerDisconnect may have dropped the player's record already
    local name = MP.GetPlayerName(playerID)
    local count = playerCount()
    if name and services_players.players[name] then count = count - 1 end
    emit("PlayerLeft", { id = playerID, name = name, players = math.max(0, count) })
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onMapChanged = onMapChanged
M.onPlayerJoin = onPlayerJoin
M.onPlayerDisconnect = onPlayerDisconnect

M.emit = emit
M.stamp = stamp
M.hasHook = hasHook
M.runHook = runHook
M.firstBlock = firstBlock
M.firstOrder = firstOrder
M.firstTake = firstTake
M.judging = judging
M.sessionOut = sessionOut

return M
