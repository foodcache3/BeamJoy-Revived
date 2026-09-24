local DEFAULT_GRAVITY = -9.81
local M = {
    ---@class BJEnvironment
    data = {
        simSpeed = 1,
        simPause = false,
        timeSync = false,
        ToD = 0, -- noon ; the ToD value AT ToDEpochAt (see below), not necessarily the current one
        dayNightCycle = false,
        ---@type integer
        dayLength = 1800, -- seconds
        dayScale = 1,
        nightScale = 2,
        gravitySync = false,
        gravity = DEFAULT_GRAVITY,
        ---@type number milliseconds on this session's own monotonic realtimeClock (see onInit)
        ---this ToD was last collapsed to its true current value ; see collapseToD's own doc
        ---comment. Not meaningful cross-session, re-anchored to "now" on every onInit
        ToDEpochAt = 0,
    },
    default = {},

    -- Real, confirmed design flaw (direct report: night-time playback was structurally jerky, and
    -- got WORSE the more often corrections were pushed - "cranking up the update speed isn't a
    -- good solution, it could be very performance intensive"): this used to broadcast a plain ToD
    -- VALUE once a second (onBJRequestServerTickPayload) and rely on every client periodically
    -- correcting its own native clock toward it. The installed game's own native `play` auto-advance
    -- has no concept of dayScale/nightScale at all (confirmed: zero references to either in the
    -- installed game's own core/environment.lua) - it can only free-run at ONE flat rate for the
    -- whole cycle. Whenever dayScale ~= nightScale (the default: nightScale=2, nights pass twice as
    -- fast as days), native's own flat rate can NEVER actually match the server's real, asymmetric
    -- one - it's not a timing/frequency problem correction pushes can fix, it's a structural rate
    -- mismatch that needed constant, ever-growing correction specifically at night, which is
    -- unavoidably visible no matter how often it's pushed.
    --
    -- Redesigned around an EPOCH instead of a per-tick value, the same "push a duration, not a
    -- timestamp" pattern this codebase already uses for race/hunt elapsed time: `ToD` is the value
    -- AT `ToDEpochAt` (this session's own monotonic clock domain), pushed to clients as a plain duration
    -- (`epochAgoMs`, computed fresh at send time) only when something actually changes - not every
    -- tick. Every client (see computeCurrentToD's own client-side twin) derives its own exact
    -- current ToD locally, on demand, from that one epoch using the real day/night piecewise rate -
    -- a closed-form calculation, not a loop, so it's correct and free-running for any elapsed
    -- duration without needing further server pushes at all. This is strictly CHEAPER on the network
    -- than the old once-a-second broadcast (an occasional push instead of a constant one), and lets
    -- each client correct as often as it wants against the mathematically exact target, entirely
    -- locally, with zero added server load - directly answering "some other solution might be
    -- required" instead of just tuning the old push frequency up or down.
}

---@return boolean whether ToD is actually advancing right now
local function isToDPlaying()
    return M.data.timeSync and M.data.dayNightCycle and not M.data.simPause
end

-- Backs ToDEpochAt/collapseToD/currentToD/buildEnvPayload's own elapsed-time math. GetCurrentTime()
-- (still used for lastSafetyResyncAt's own once-a-minute cadence check further below, which is
-- fine at 1-second resolution) is NOT precise enough for this: os.time() is whole-seconds-only, so
-- subtracting two readings of it always throws away up to just under a second of the true elapsed
-- real time - deterministically, on literally every single call, not a rare edge case. Confirmed
-- live: a direct report (with `[BJToDDebug3]` diagnostic logging) of `forceToD` re-triggering on
-- EVERY single 60-second safety broadcast without fail, with the sign of the resulting diff
-- flipping between captures - exactly what discarding an essentially-random sub-second remainder
-- every time would produce, not a rate or wraparound bug (both already ruled out/fixed earlier).
-- MP.CreateTimer() (wrapped by the existing utils/math.lua's own math.timer()) is a genuine
-- sub-second-precision monotonic stopwatch, with none of that quantization loss.
local realtimeClock

---@param t0 number ToD at the start of the elapsed window, 0-1
---@param dtSec number real seconds elapsed since t0 (may be very large - e.g. a long-idle server -
---or negative, treated as 0)
---@param dayLength integer
---@param dayScale number
---@param nightScale number
---@param simSpeed number
---@return number ToD, 0-1
---@nodiscard
--- Closed-form (not a loop) day/night-aware ToD advance, matching onSlowUpdate's own historical
--- per-tick step exactly (same day=[0,.25)u[.75,1), night=[.25,.75) split, same `scale/dayLength`
--- rate) but computed directly for any elapsed duration. Re-expressed in a "shifted" coordinate
--- (`shifted = (ToD - .75) % 1`) where day is the single contiguous span [0,.5) and night is
--- [.5,1), since that's what makes a closed-form piecewise formula tractable - day/night's own
--- span in real ToD-space is two disjoint pieces, awkward to reason about directly. Has an exact
--- client-side twin (environment.lua's own computeCurrentToD) - keep both in sync if this changes.
local function computeCurrentToD(t0, dtSec, dayLength, dayScale, nightScale, simSpeed)
    dayLength = tonumber(dayLength) or 1800
    dayScale = tonumber(dayScale) or 1
    nightScale = tonumber(nightScale) or 1
    simSpeed = tonumber(simSpeed) or 1
    dtSec = math.max(0, tonumber(dtSec) or 0)
    t0 = (tonumber(t0) or 0) % 1
    if dayLength <= 0 or simSpeed <= 0 or dtSec <= 0 then return t0 end

    local dayRate = math.max(dayScale, 0) * simSpeed / dayLength
    local nightRate = math.max(nightScale, 0) * simSpeed / dayLength
    if dayRate <= 0 and nightRate <= 0 then return t0 end -- both segments frozen ; nothing to do

    local dayDurationSec = dayRate > 0 and (0.5 / dayRate) or math.huge
    local nightDurationSec = nightRate > 0 and (0.5 / nightRate) or math.huge
    local cycleDurationSec = dayDurationSec + nightDurationSec
    if cycleDurationSec == math.huge then
        -- exactly one of the two segments never advances ; can't wrap a cycle, just walk directly
        -- within whichever segment t0 starts in (the other segment is a wall this can't cross)
        local shifted0 = (t0 - 0.75) % 1
        if shifted0 < 0.5 and dayRate > 0 then
            return (math.min(0.5, shifted0 + dayRate * dtSec) + 0.75) % 1
        elseif shifted0 >= 0.5 and nightRate > 0 then
            return (math.min(1, shifted0 + nightRate * dtSec) + 0.75) % 1
        end
        return t0
    end

    local shifted0 = (t0 - 0.75) % 1
    local s0 = shifted0 < 0.5 and (shifted0 / dayRate) or (dayDurationSec + (shifted0 - 0.5) / nightRate)
    local s1 = (s0 + dtSec) % cycleDurationSec
    local shifted1 = s1 < dayDurationSec and (s1 * dayRate) or (0.5 + (s1 - dayDurationSec) * nightRate)
    return (shifted1 + 0.75) % 1
end

--- Collapses M.data.ToD/ToDEpochAt to the true current value (if it's actually been advancing since
--- the last collapse) and re-anchors the epoch to right now. Call this BEFORE changing anything that
--- affects the rate or play state (dayLength/dayScale/nightScale/dayNightCycle/simSpeed/simPause/
--- timeSync/an explicit ToD set) - so the window that just elapsed is correctly accounted for under
--- the OLD settings before the new ones take over, and any client that was already playing keeps
--- exact continuity across the change instead of jumping.
local function collapseToD()
    local nowMs = realtimeClock:get()
    if isToDPlaying() then
        M.data.ToD = computeCurrentToD(M.data.ToD, (nowMs - M.data.ToDEpochAt) / 1000,
            M.data.dayLength, M.data.dayScale, M.data.nightScale, M.data.simSpeed)
    end
    M.data.ToDEpochAt = nowMs
end

---@return number ToD, 0-1, right now
local function currentToD()
    if not isToDPlaying() then return M.data.ToD end
    return computeCurrentToD(M.data.ToD, (realtimeClock:get() - M.data.ToDEpochAt) / 1000,
        M.data.dayLength, M.data.dayScale, M.data.nightScale, M.data.simSpeed)
end

---@return table a plain clone of M.data, with ToDEpochAt replaced by a fresh epochAgoMs DURATION
---(this session's own monotonic clock reading is meaningless to a client directly - see
---collapseToD's own doc comment for why this whole feature is built around durations, not
---timestamps)
local function buildEnvPayload()
    local payload = table.clone(M.data)
    payload.ToDEpochAt = nil
    payload.epochAgoMs = math.floor(realtimeClock:get() - M.data.ToDEpochAt)
    return payload
end

local function onInit()
    realtimeClock = math.timer()
    M.default = table.clone(M.data)
    table.assign(M.data, dao_environment.get() or {})
    M.data.ToDEpochAt = realtimeClock:get() -- never meaningful across a restart ; re-anchor fresh

    communications_rx.addHandler("simSpeed", M.changeSimSpeed)
    communications_rx.addHandler("simPause", M.changeSimPause)
    communications_rx.addHandler("setEnv", M.changeEnv)

    services_consoleCommands.register("env", "commands.bjenv.args", "commands.bjenv.desc", M.consoleEnv)
end

local function onBJRequestCache(caches, targetID)
    caches.environment = buildEnvPayload()
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
-- server/client real-time clock drift unrelated to the day/night rate mismatch fixed above) fires
-- while actively playing - replaces the old once-a-second broadcast; 60s is far more than enough
-- to bound plain clock drift to something negligible, at a fraction of the old network cost
local SAFETY_RESYNC_INTERVAL_SEC = 60
local lastSafetyResyncAt = 0

local function onSlowUpdate()
    if isToDPlaying() and GetCurrentTime() - lastSafetyResyncAt >= SAFETY_RESYNC_INTERVAL_SEC then
        lastSafetyResyncAt = GetCurrentTime()
        collapseToD()
        dao_environment.save(M.data)
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache",
            { environment = buildEnvPayload() })
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
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache",
            { environment = buildEnvPayload() })
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
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache",
            { environment = buildEnvPayload() })
    end
end

---@param ctxt BJSContext
---@param payload {timeSync: boolean, ToD: number, dayNightCycle: boolean, dayLength: integer, dayScale: number, nightScale: number, gravitySync: boolean, gravity: number}
local function changeEnv(ctxt, payload)
    if ctxt.sender and not services_permissions.hasAnyPermission(ctxt.senderID,
            BJ_PERMISSIONS.SetEnvironment) then
        return
    end

    collapseToD() -- account for the elapsed window under the OLD settings before anything changes
    local newData = table.assign(table.clone(M.data), payload)
    if not table.compare(M.data, newData) then
        table.assign(M.data, newData)
        if not M.data.gravitySync and M.data.gravity ~= DEFAULT_GRAVITY then
            M.data.gravity = DEFAULT_GRAVITY
        end
        M.data.ToDEpochAt = realtimeClock:get() -- fresh epoch under the NEW settings (or explicit ToD)
        dao_environment.save(M.data)
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache",
            { environment = buildEnvPayload() })
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

M.changeSimSpeed = changeSimSpeed
M.changeSimPause = changeSimPause
M.changeEnv = changeEnv
M.consoleEnv = consoleEnv

return M
