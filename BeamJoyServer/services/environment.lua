local DEFAULT_GRAVITY = -9.81
-- shared VERBATIM with the client (Client/BJ/lua/envClock.lua) - see its own header
local envClock = require("utils/envClock")
local M = {
    ---@class BJEnvironment
    data = {
        simSpeed = 1,
        simPause = false,
        timeSync = false,
        ToD = 0, -- noon ; the ToD value AT ToDEpochAt (see below), not necessarily the current one
        dayNightCycle = false,
        ---@type integer
        dayLength = 1800, -- seconds, the full cycle at 1x day AND night speed (vanilla panel's meaning)
        dayScale = 1,
        nightScale = 2,
        ---@type integer? synced calendar date AT ToDEpochAt ; nil until a client first reports its
        ---level's own date (see reportObserver) or an admin sets one
        year = nil,
        ---@type integer?
        month = nil,
        ---@type integer?
        day = nil,
        ---@type table<string, table> per-map solar data (latitude/longitude/utcOffset/dstRule),
        ---keyed by services_core.getCurrentMap() ; the first client on a map reports it
        observers = {},
        gravitySync = false,
        gravity = DEFAULT_GRAVITY,
        ---@type number milliseconds on this session's own monotonic realtimeClock (see onInit)
        ---this ToD was last collapsed to its true current value ; see collapseToD's own doc
        ---comment. Not meaningful cross-session, re-anchored to "now" on every onInit
        ToDEpochAt = 0,
    },
    default = {},

    -- Designed around an EPOCH instead of a per-tick value, the same "push a duration, not a
    -- timestamp" pattern this codebase already uses for race/hunt elapsed time: `ToD` is the value
    -- AT `ToDEpochAt` (this session's own monotonic clock domain), pushed to clients as a plain
    -- duration (`epochAgoMs`, computed fresh at send time) only when something actually changes -
    -- not every tick. The server and every client derive the exact current ToD locally, on demand,
    -- from that one epoch with the same shared math (utils/envClock.lua: real sunset/sunrise split,
    -- separate day/night speeds), so nothing needs pushing while it free-runs. Clients hand the
    -- engine a per-phase dayLength so its own advance matches too (see the client's syncNative).
}

---@return boolean whether ToD is actually advancing right now
local function isToDPlaying()
    return M.data.timeSync and M.data.dayNightCycle and not M.data.simPause
end

-- Backs ToDEpochAt/collapseToD/currentToD/buildEnvPayload's own elapsed-time math. GetCurrentTime()
-- (still used for lastSafetyResyncAt's own once-a-minute cadence check further below, which is
-- fine at 1-second resolution) is NOT precise enough for this: os.time() is whole-seconds-only, so
-- subtracting two readings of it always throws away up to just under a second of the true elapsed
-- real time - confirmed live as `forceToD` re-triggering on every 60-second safety broadcast.
-- MP.CreateTimer() (wrapped by the existing utils/math.lua's own math.timer()) is a genuine
-- sub-second-precision monotonic stopwatch, with none of that quantization loss.
local realtimeClock

---@param mapName string?
---@return table|false that map's solar data, false if no client has reported it yet (envClock then
---falls back to a fixed 06:00-18:00 day, on every client alike - it's synced, see buildEnvPayload)
local function observerFor(mapName)
    return mapName and M.data.observers and M.data.observers[mapName] or false
end

local function currentObserver()
    return observerFor(services_core.getCurrentMap())
end

---@param observer table|false
local function clockParams(observer)
    return {
        dayLength = M.data.dayLength,
        dayScale = M.data.dayScale,
        nightScale = M.data.nightScale,
        simSpeed = M.data.simSpeed,
        observer = observer,
        year = M.data.year,
        month = M.data.month,
        day = M.data.day,
    }
end

--- Collapses M.data.ToD/ToDEpochAt to the true current value (if it's actually been advancing since
--- the last collapse) and re-anchors the epoch to right now. Call this BEFORE changing anything that
--- affects the rate or play state (dayLength/dayScale/nightScale/dayNightCycle/simSpeed/simPause/
--- timeSync/date/solar data/an explicit ToD set) - so the window that just elapsed is correctly
--- accounted for under the OLD settings before the new ones take over, and any client that was
--- already playing keeps exact continuity across the change instead of jumping.
---@param observer table|false|nil override the solar data the elapsed window ran under (onMapChanged:
---the OLD map's) ; nil = the current map's
local function collapseToD(observer)
    if observer == nil then observer = currentObserver() end
    local nowMs = realtimeClock:get()
    if isToDPlaying() then
        M.data.ToD = envClock.advance(M.data.ToD, (nowMs - M.data.ToDEpochAt) / 1000, clockParams(observer))
    end
    M.data.ToDEpochAt = nowMs
end

---@return number ToD, 0-1, right now
local function currentToD()
    if not isToDPlaying() then return M.data.ToD end
    return envClock.advance(M.data.ToD, (realtimeClock:get() - M.data.ToDEpochAt) / 1000,
        clockParams(currentObserver()))
end

---@return table a plain clone of M.data, with ToDEpochAt replaced by a fresh epochAgoMs DURATION
---(this session's own monotonic clock reading is meaningless to a client directly), and the
---per-map solar data table replaced by just the current map's entry (explicit false when unknown,
---so a client can't keep a previous map's entry around)
local function buildEnvPayload()
    local payload = table.clone(M.data)
    payload.ToDEpochAt = nil
    payload.observers = nil
    payload.observer = currentObserver()
    payload.epochAgoMs = math.floor(realtimeClock:get() - M.data.ToDEpochAt)
    return payload
end

local function broadcastEnv()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache",
        { environment = buildEnvPayload() })
end

local function isLeapYear(y)
    return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

---@return integer?, integer?, integer? the date if it's a real calendar date, else nil
local function validDate(year, month, day)
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or not month or not day then return nil end
    year, month, day = math.floor(year), math.floor(month), math.floor(day)
    if year < 1 or year > 9999 or month < 1 or month > 12 or day < 1 then return nil end
    local monthDays = { 31, isLeapYear(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if day > monthDays[month] then return nil end
    return year, month, day
end

---@param ctxt BJSContext
---@param report {map: string, latitude: number?, longitude: number?, utcOffset: number?, dstRule: string?, year: integer?, month: integer?, day: integer?}
--- The server has no engine to read a level's solar data from, but needs it to split day from night
--- exactly like every client (collapseToD). Every client reports it once its world is ready
--- (client environment.lua's reportObserver); the first report for the current map is kept and
--- persisted - it's level data, so every honest client sends the same values. Also seeds the synced
--- date from the level's own if the server has never had one.
local function reportObserver(ctxt, report)
    if type(report) ~= "table" then return end
    local map = services_core.getCurrentMap()
    if tostring(report.map or ""):lower() ~= tostring(map):lower() then return end -- stale, map switched

    local changed = false
    M.data.observers = M.data.observers or {}
    if M.data.observers[map] == nil then
        collapseToD() -- the elapsed window ran under the fallback split
        M.data.observers[map] = {
            latitude = tonumber(report.latitude),
            longitude = tonumber(report.longitude),
            utcOffset = tonumber(report.utcOffset),
            dstRule = type(report.dstRule) == "string" and report.dstRule or nil,
        }
        changed = true
    end
    if M.data.year == nil then
        local y, mo, d = validDate(report.year, report.month, report.day)
        if y then
            collapseToD()
            M.data.year, M.data.month, M.data.day = y, mo, d
            changed = true
        end
    end
    if changed then
        dao_environment.save(M.data)
        broadcastEnv()
    end
end

local function onInit()
    realtimeClock = math.timer()
    M.default = table.clone(M.data)
    table.assign(M.data, dao_environment.get() or {})
    -- removed setting (CHANGELOG 1.10.3) an older save may still carry ; dropped so it isn't
    -- re-saved or broadcast forever
    M.data.nightBrightnessMultiplier = nil
    M.data.observers = M.data.observers or {}
    M.data.ToDEpochAt = realtimeClock:get() -- never meaningful across a restart ; re-anchor fresh

    communications_rx.addHandler("simSpeed", M.changeSimSpeed)
    communications_rx.addHandler("simPause", M.changeSimPause)
    communications_rx.addHandler("setEnv", M.changeEnv)
    communications_rx.addHandler("envObserver", M.reportObserver)

    services_consoleCommands.register("env", "commands.bjenv.args", "commands.bjenv.desc", M.consoleEnv)
end

local function onBJRequestCache(caches, targetID)
    caches.environment = buildEnvPayload()
end

---@param oldMapName string
---@param newMapName string
local function onMapChanged(oldMapName, newMapName)
    -- the elapsed window ran under the OLD map's solar data ; from here on the new map's applies
    -- (or the fallback split, until its first client reports it)
    collapseToD(observerFor(oldMapName))
    dao_environment.save(M.data)
    broadcastEnv()
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    if not services_players.players:filter(function(p) return p.playerID ~= playerID end):any(function(p)
            return
                services_permissions.isStaff(p.playerName)
        end) then
        -- no staff member left
        if M.data.simSpeed ~= 1 or M.data.simPause then
            M.changeSimPause(InitContext(), false)
            M.changeSimSpeed(InitContext(), 1)
        end
        if M.data.gravity ~= DEFAULT_GRAVITY then
            M.changeEnv(InitContext(), { gravity = DEFAULT_GRAVITY })
        end
    end
end

-- how often the safety-net resync (persistence + a fresh epoch broadcast, in case of long-run
-- server/client real-time clock drift) fires while actively playing; 60s is far more than enough
-- to bound plain clock drift to something negligible, at a fraction of the network cost of a
-- constant broadcast
local SAFETY_RESYNC_INTERVAL_SEC = 60
local lastSafetyResyncAt = 0

local function onSlowUpdate()
    if isToDPlaying() and GetCurrentTime() - lastSafetyResyncAt >= SAFETY_RESYNC_INTERVAL_SEC then
        lastSafetyResyncAt = GetCurrentTime()
        collapseToD()
        dao_environment.save(M.data)
        broadcastEnv()
    end
end

---@param ctxt BJSContext
---@param newSpeed integer
local function changeSimSpeed(ctxt, newSpeed)
    if not tonumber(newSpeed) then return end
    if ctxt.sender and not services_permissions.hasAnyPermission(ctxt.senderID,
            BJ_PERMISSIONS.SetEnvironment) then
        return
    end

    if M.data.simSpeed ~= newSpeed then
        collapseToD() -- simSpeed affects the ToD rate too ; account for the elapsed window first
        M.data.simSpeed = newSpeed
        dao_environment.save(M.data)
        broadcastEnv()
    end
end

---@param ctxt BJSContext
---@param pauseState boolean
local function changeSimPause(ctxt, pauseState)
    if ctxt.sender and not services_permissions.hasAnyPermission(ctxt.senderID,
            BJ_PERMISSIONS.SetEnvironment) then
        return
    end

    if M.data.simPause ~= pauseState then
        collapseToD() -- pausing/unpausing changes whether ToD is advancing at all
        M.data.simPause = pauseState
        dao_environment.save(M.data)
        broadcastEnv()
    end
end

-- the only fields a setEnv payload may touch ; everything else in M.data (the per-map solar data,
-- the epoch) is server-owned
local SETTABLE_FIELDS = {
    timeSync = true, ToD = true, dayNightCycle = true, dayLength = true, dayScale = true,
    nightScale = true, year = true, month = true, day = true, gravitySync = true, gravity = true,
}

---@param ctxt BJSContext
---@param payload {timeSync: boolean, ToD: number, dayNightCycle: boolean, dayLength: integer, dayScale: number, nightScale: number, year: integer?, month: integer?, day: integer?, gravitySync: boolean, gravity: number}
local function changeEnv(ctxt, payload)
    if ctxt.sender and not services_permissions.hasAnyPermission(ctxt.senderID,
            BJ_PERMISSIONS.SetEnvironment) then
        return
    end
    if type(payload) ~= "table" then return end

    local clean = {}
    for key, value in pairs(payload) do
        if SETTABLE_FIELDS[key] then clean[key] = value end
    end
    if clean.ToD ~= nil then
        clean.ToD = tonumber(clean.ToD) and tonumber(clean.ToD) % 1 or nil
    end
    -- the game's own day length bounds (envClock.MIN/MAX_DAY_LENGTH)
    if clean.dayLength ~= nil then
        clean.dayLength = tonumber(clean.dayLength) and envClock.clampDayLength(clean.dayLength) or nil
    end
    -- day/night speed multipliers: nightScale is set from the config panel's own slider (0.1x-10x),
    -- dayScale has no UI but gets the same bounds (envClock.effectiveScale further limits both at
    -- use, so the engine's per-phase dayLength stays within the game's own bounds). Anything
    -- non-numeric is dropped rather than stored.
    for _, key in ipairs({ "dayScale", "nightScale" }) do
        if clean[key] ~= nil then
            local value = tonumber(clean[key])
            clean[key] = value and math.clamp(value, envClock.MIN_SCALE, envClock.MAX_SCALE) or nil
        end
    end
    -- the date only ever changes as a whole, and only to a real one
    if clean.year ~= nil or clean.month ~= nil or clean.day ~= nil then
        clean.year, clean.month, clean.day = validDate(clean.year, clean.month, clean.day)
    end

    collapseToD() -- account for the elapsed window under the OLD settings before anything changes
    local newData = table.assign(table.clone(M.data), clean)
    if not table.compare(M.data, newData) then
        table.assign(M.data, newData)
        if not M.data.gravitySync and M.data.gravity ~= DEFAULT_GRAVITY then
            M.data.gravity = DEFAULT_GRAVITY
        end
        M.data.ToDEpochAt = realtimeClock:get() -- fresh epoch under the NEW settings (or explicit ToD)
        dao_environment.save(M.data)
        broadcastEnv()
    end
end

local function consoleEnvHelp()
    local lang = services_config.data.Console.Lang
    local args = {}
    local commandMaxLength = 0
    local descs = {}
    local commands = Table({ "timesync", "time", "timeplay" })
    commands:forEach(function(v)
        args[v] = services_lang.get("commands.bjenv." .. v .. ".args", lang)
        local length = #args[v] + 1
        if commandMaxLength < length then
            commandMaxLength = length
        end
        descs[v] = services_lang.get("commands.bjenv." .. v .. ".desc", lang)
    end)
    print("\n" .. services_lang.get("commands.usage", lang) .. " :\n" ..
        commands:map(function(cmd)
            return string.format("%s env %s - %s",
                services_consoleCommands.baseCommand,
                string.normalize(args[cmd], commandMaxLength),
                descs[cmd])
        end):join("\n"))
end

local function consoleEnvTimesync(args)
    local lang = services_config.data.Console.Lang
    local printUsage = function()
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            string.format("\n%s : %s env %s - %s",
                services_lang.get("commands.usage", lang),
                services_consoleCommands.baseCommand,
                services_lang.get("commands.bjenv.timesync.args", lang),
                services_lang.get("commands.bjenv.timesync.desc", lang)
            ) .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    end
    local showStatus = function()
        print("\n" .. GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_BLUE) ..
            services_lang.get("commands.bjenv.timesync.status", lang)
            :var({
                state = services_lang.get(M.data.timeSync and
                    "common.enabled" or "common.disabled", lang)
            }) .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET)
        )
    end
    if not args[1] then
        return showStatus()
    end
    if args[1] and not table.includes({ "true", "false" }, args[1]:lower()) then
        return printUsage()
    end
    local newState = args[1]:lower() == "true"
    changeEnv(InitContext(), { timeSync = newState })
    return showStatus()
end

local function consoleEnvTime(args)
    local lang = services_config.data.Console.Lang
    local printUsage = function()
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            string.format("\n%s : %s env %s - %s",
                services_lang.get("commands.usage", lang),
                services_consoleCommands.baseCommand,
                services_lang.get("commands.bjenv.time.args", lang),
                services_lang.get("commands.bjenv.time.desc", lang)
            ) .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    end
    local showStatus = function()
        local formattedTime = ""
        local nowToD = currentToD() -- live value, not the possibly-stale epoch snapshot
        if nowToD == 0 then
            formattedTime = services_lang.get("time.noon", lang)
        elseif nowToD == .25 then
            formattedTime = services_lang.get("time.dusk", lang)
        elseif nowToD == .5 then
            formattedTime = services_lang.get("time.night", lang)
        elseif nowToD == .75 then
            formattedTime = services_lang.get("time.dawn", lang)
        else
            local time = (nowToD + .5) % 1
            local hour = math.floor(time * 24)
            local minute = math.round(time % 24 * 60)
            formattedTime = string.format("%s:%s",
                hour < 10 and "0" .. hour or hour,
                minute < 10 and "0" .. minute or minute
            )
        end
        print("\n" .. GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_BLUE) ..
            services_lang.get("commands.bjenv.time.status", lang)
            :var({
                time = formattedTime
            }) .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET)
        )
    end
    if not args[1] then
        return showStatus()
    end
    if args[1] and not table.includes({ "dawn", "noon", "dusk", "night" }, args[1]:lower()) then
        return printUsage()
    end
    local newToD
    if args[1]:lower() == "dawn" then
        newToD = .75
    elseif args[1]:lower() == "noon" then
        newToD = 0
    elseif args[1]:lower() == "dusk" then
        newToD = .25
    elseif args[1]:lower() == "night" then
        newToD = .5
    end
    changeEnv(InitContext(), { ToD = newToD })
    return showStatus()
end

local function consoleEnvTimeplay(args)
    local lang = services_config.data.Console.Lang
    local printUsage = function()
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            string.format("\n%s : %s env %s - %s",
                services_lang.get("commands.usage", lang),
                services_consoleCommands.baseCommand,
                services_lang.get("commands.bjenv.timeplay.args", lang),
                services_lang.get("commands.bjenv.timeplay.desc", lang)
            ) .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    end
    local showStatus = function()
        print("\n" .. GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_BLUE) ..
            services_lang.get("commands.bjenv.timeplay.status", lang)
            :var({
                state = services_lang.get(M.data.dayNightCycle and
                    "common.enabled" or "common.disabled", lang)
            }) .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET)
        )
    end
    if not args[1] then
        return showStatus()
    end
    if args[1] and not table.includes({ "true", "false" }, args[1]:lower()) then
        return printUsage()
    end
    local newState = args[1]:lower() == "true"
    changeEnv(InitContext(), { dayNightCycle = newState })
    return showStatus()
end

---@param args string[]
local function consoleEnv(args)
    local fns = {
        timesync = consoleEnvTimesync,
        time = consoleEnvTime,
        timeplay = consoleEnvTimeplay,
    }
    if not args[1] or not fns[args[1]:lower()] then
        return consoleEnvHelp()
    end

    fns[args[1]:lower()](table.filter(args, function(_, i) return i > 1 end))
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onPlayerDisconnect = onPlayerDisconnect
M.onSlowUpdate = onSlowUpdate
M.onMapChanged = onMapChanged

M.changeSimSpeed = changeSimSpeed
M.changeSimPause = changeSimPause
M.changeEnv = changeEnv
M.reportObserver = reportObserver
M.consoleEnv = consoleEnv

return M
