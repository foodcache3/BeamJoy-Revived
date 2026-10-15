--- The plugin API (direct request : other server plugins reading BeamJoy's data, e.g. a website
--- kept in sync with the race leaderboards). Read-only for now.
---
--- Every BeamMP server plugin (each folder in Resources/Server) runs in its own Lua state : none can
--- see another's variables or call its functions, they only exchange events. So :
--- - a request : a plugin fires `BJAPI_Request` with a JSON string `{id, method, params, from}` ;
---   the answer goes out to every plugin as `BJAPI_Response` `{v, id, to, ok, result | error}`
--- - an event : BeamJoy fires `BJAPI_<Name>` with a JSON string `{v, event, instance, data}`
--- Payloads are a public shape of their own (API_VERSION), never BeamJoy's internal tables, which
--- keep changing. The reference, and the helper library plugins use : PluginAPI/ in the repository.

local M = {
    dependencies = { "services_core", "services_maps", "services_races", "services_players",
        "services_identity", "services_permissions", "services_environment", "dao_activity" },

    API_VERSION = 1,
    --- this server run's own id : a plugin seeing another knows BeamJoy started again
    instance = nil,
    readySent = false,
    ---@type table<string, true> maps whose races changed since the last tick (sent together)
    pendingRacesChanged = {},
    ---@type table<string, fun(params: table): any, string?, string?>
    methods = {},
}

local REQUEST_EVENT = "BJAPI_Request"
local RESPONSE_EVENT = "BJAPI_Response"
local EVENTS = { "Ready", "LeaderboardChanged", "RacesChanged", "RaceFinished", "MapChanged",
    "PlayerJoined", "PlayerLeft" }
local LEADERBOARD_LIMIT_DEFAULT = 100

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
    local methods = {}
    for name in pairs(M.methods) do methods[#methods + 1] = name end
    table.sort(methods)
    return {
        api = M.API_VERSION,
        instance = M.instance,
        beamjoy = { version = BeamJoyServer.VERSION, build = BeamJoyServer.BUILD },
        map = { name = map, label = mapData and mapData.label or map },
        players = playerCount(),
        methods = methods,
        events = EVENTS,
    }
end

-- ---------------------------------------------------------------------------------------------
-- methods : each takes its params table and returns its result, or nil, an error code and why

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

M.methods["players.online"] = function()
    local players = {}
    services_players.players:forEach(function(p)
        players[#players + 1] = {
            id = p.playerID,
            name = p.playerName,
            displayName = p.identityNickname or p.displayName or p.playerName,
            nickname = p.identityNickname,
            guest = p.guest == true,
            group = p.group,
            staff = services_permissions.isStaff(p.playerName) == true,
        }
    end)
    table.sort(players, function(a, b) return a.id < b.id end)
    return { players = players }
end

M.methods["environment.get"] = function()
    local env = services_environment.data
    local tod = services_environment.currentToD()
    -- the game's time of day : 0 is noon, .5 midnight
    local minutes = math.floor(((tod * 24 + 12) % 24) * 60 + .5) % (24 * 60)
    return {
        timeOfDay = tod,
        clock = string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60),
        timeSync = env.timeSync == true,
        dayNightCycle = env.dayNightCycle == true,
        dayLengthS = env.dayLength,
        date = env.year and { year = env.year, month = env.month, day = env.day } or nil,
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

-- ---------------------------------------------------------------------------------------------
-- requests

---@param raw any
local function onRequest(raw)
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
    local ran, result, code, why = pcall(method, params)
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

--- a grid race ended (raceGrid.lua's checkSessionComplete)
---@param session table BJRaceSession
---@param info table raceGrid's buildResults info
---@param results table[] raceGrid's buildResults results, in order
function M.raceFinished(session, info, results)
    local out = {}
    local position = 0
    for _, r in ipairs(results) do
        local finished = r.totalMs ~= nil and not r.dnf
        if finished then position = position + 1 end
        out[#out + 1] = {
            position = finished and position or nil,
            name = r.playerName,
            identity = r.identity or "unknown",
            vehicle = r.vehicle,
            finished = finished,
            disqualified = r.disqualified == true,
            totalMs = finished and r.totalMs or nil,
            bestLapMs = r.bestLapMs,
            penaltyMs = r.penaltyMs,
            newPB = r.isNewPB == true,
            newRecord = r.isNewRecord == true,
            leaderboardRank = r.rank,
        }
    end
    emit("RaceFinished", {
        map = services_core.getCurrentMap(),
        raceId = session.raceId,
        raceName = info.raceName,
        laps = info.laps,
        results = out,
    })
end

-- ---------------------------------------------------------------------------------------------
-- hooks

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
        emit("Ready", serverInfo())
        LogInfo(string.format("[BJ api] plugin API ready (v%d)", M.API_VERSION))
    end
    if next(M.pendingRacesChanged) then
        local maps = M.pendingRacesChanged
        M.pendingRacesChanged = {}
        for map in pairs(maps) do emit("RacesChanged", { map = map }) end
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

return M
