local DEFAULT_GRAVITY = -9.81
-- shared VERBATIM with the server (utils/envClock.lua) - see its own header
local envClock = require("lua/envClock")

local M = {
    preloadedDependencies = { "core_jobsystem" },
    dependencies = {},

    baseFunctions = {},

    ---@type BJEnvironment
    data = {
        simSpeed = 1,
        simPause = false,
        timeSync = false,
        ToD = 0,          -- noon ; the ToD value AT ToDEpochAtMs (see below), not necessarily now
        dayNightCycle = false,
        dayLength = 1800, -- seconds, the full cycle at 1x day AND night speed (vanilla panel's meaning)
        dayScale = 1,
        nightScale = 2,
        ---@type integer? synced calendar date (nil until the server has one), written to the engine
        ---only when it changes - see writeNative
        year = nil,
        ---@type integer?
        month = nil,
        ---@type integer?
        day = nil,
        ---@type table|false the current map's solar data (latitude/longitude/utcOffset/dstRule),
        ---synced by the server so every client splits day from night identically ; false = none
        ---known, envClock falls back to a fixed 06:00-18:00 day
        observer = false,
        gravitySync = false,
        gravity = DEFAULT_GRAVITY,
        ---@type integer? GetCurrentTimeMillis() domain anchor this client derived from the
        ---server's own epochAgoMs duration (see currentToD's own doc comment) ; nil until the
        ---first environment cache/change arrives
        ToDEpochAtMs = nil,
    },

    speedProcess = false,
    ToDProcess = false,
}
AddPreloadedDependencies(M)

---@return boolean whether the synced clock is advancing right now - must match the server's own
---isToDPlaying exactly, simPause included: the server stops advancing (and collapses) while the
---game is paused, so a client that kept advancing through a pause got snapped back by the whole
---pause's worth of clock the moment it ended
local function isPlaying()
    return M.data.timeSync and M.data.dayNightCycle and not M.data.simPause
end

-- reused every call (currentToD runs every frame) so the hot path allocates nothing
local clockParams = {}
local function fillClockParams()
    local p = clockParams
    p.dayLength, p.dayScale, p.nightScale = M.data.dayLength, M.data.dayScale, M.data.nightScale
    p.simSpeed, p.observer = M.data.simSpeed, M.data.observer
    p.year, p.month, p.day = M.data.year, M.data.month, M.data.day
    return p
end

---@return number ToD, 0-1, right now - computed locally from the server's own epoch, no network
---round-trip needed, identical on every client and the server (envClock.advance)
---@nodiscard
local function currentToD()
    if not isPlaying() then return M.data.ToD end
    local elapsedSec = (GetCurrentTimeMillis() - (M.data.ToDEpochAtMs or GetCurrentTimeMillis())) / 1000
    return envClock.advance(M.data.ToD, elapsedSec, fillClockParams())
end

---@param time number ToD
---@return number the dayLength to hand the engine at `time`: the current phase's own (day or
---night) rate, always within the game's own 5min-24h bounds (envClock.nativeDayLength)
local function nativeDayLengthAt(time)
    local night = envClock.isNight(M.data.observer, M.data.year, M.data.month, M.data.day, time)
    return envClock.nativeDayLength(night and M.data.nightScale or M.data.dayScale, M.data.dayLength)
end

---@param a number ToD, 0-1
---@param b number ToD, 0-1
---@return number the signed distance from b to a going the SHORT way around the 0-1 wrap, in
---(-0.5, 0.5] - e.g. circularDiff(0.0002, 0.9999) is ~0.0003, not ~0.9997
---@nodiscard
--- Real, confirmed bug (direct report: a large, incorrect jump "forwards then stops" specifically
--- around noon - ToD 0, the exact point the raw value wraps from just-under-1 back to
--- just-over-0 in this codebase's convention): drift/rollback checks used to compare native's own
--- .time against a target with a plain subtraction, which isn't wrap-aware. Every ToD comparison
--- in this file goes through this instead.
local function circularDiff(a, b)
    return (a - b + 0.5) % 1 - 0.5
end

---@param data {timeSync: boolean?, ToD: number, dayNightCycle: boolean?, dayLength: integer?, dayScale: number?, nightScale: number?, year: integer?, month: integer?, day: integer?, gravitySync: boolean?, gravity: number?}
local function sendEnv(data)
    local payload = table.assign({
        timeSync = M.data.timeSync,
        -- always the live value, never the raw M.data.ToD (only accurate AT its own epoch):
        -- sending the stale epoch value as part of some unrelated change (e.g. toggling
        -- gravitySync alone) while playing would roll everyone's clock back
        ToD = currentToD(),
        dayNightCycle = M.data.dayNightCycle,
        dayLength = M.data.dayLength,
        dayScale = M.data.dayScale,
        nightScale = M.data.nightScale,
        year = M.data.year,
        month = M.data.month,
        day = M.data.day,
        gravitySync = M.data.gravitySync,
        gravity = M.data.gravity,
    }, data)
    beamjoy_communications.send("setEnv", payload)
end

-- Shared lerp duration for any *forced* one-off ToD resync: jumping the clock discontinuously
-- desyncs the engine's real-time lighting/exposure adaptation and can leave it broken until an
-- actual sunrise re-settles it naturally.
local RESYNC_LERP_SECONDS = 0.9
-- suppresses syncNative/checkNativeDrift while a forced resync lerp is still easing in
local resyncLerpUntilMs = nil

-- What BJS last wrote to the engine's TimeOfDay (nil = nothing yet / must rewrite everything).
-- syncNative compares against this, not against the engine, so it costs no engine reads per frame.
local applied = {}
local function invalidateApplied()
    applied = {}
end

local function getSetToD()
    return M.baseFunctions.core_environment.setTimeOfDay or extensions.core_environment.setTimeOfDay
end

--- Instant write of the synced state into the engine. The date only goes out when the synced date
--- differs from what was last written - never re-pinned continuously - so BJS can't fight anything
--- the engine itself does with its own date.
---@param time number
---@param play boolean
---@param dayLength number
local function writeNative(time, play, dayLength)
    local patch = { time = time, play = play, dayLength = dayLength }
    local y, mo, d = M.data.year, M.data.month, M.data.day
    if y and mo and d and (y ~= applied.year or mo ~= applied.month or d ~= applied.day) then
        patch.year, patch.month, patch.day = y, mo, d
        applied.year, applied.month, applied.day = y, mo, d
    end
    getSetToD()(patch)
    applied.play, applied.dayLength = play, dayLength
end

--- Redesign (direct request: "switch to the new system without the per-frame assertion with the
--- split day lengths"). BJS used to leave the engine free-running at ONE flat rate and, since the
--- engine has no concept of separate day/night speeds, correct it toward the synced clock every
--- frame - a constant stream of small snaps at night. Now the engine is handed a different
--- dayLength per phase (envClock.nativeDayLength: dayLength / that phase's speed), switched at the
--- real sunset/sunrise, so its own free-running advance already moves at exactly the synced rate
--- in both phases and nothing needs correcting. Per frame this only recomputes the synced state
--- (pure math, no engine reads) and writes ONLY on a transition: day<->night, play/pause, a new
--- date, a new day length/speed. checkNativeDrift (onSlowUpdate) is the safety net.
local function syncNative()
    local time = currentToD()
    local play = isPlaying()
    local dayLength = nativeDayLengthAt(time)
    local y, mo, d = M.data.year, M.data.month, M.data.day
    if play == applied.play and dayLength == applied.dayLength and
        (not y or (y == applied.year and mo == applied.month and d == applied.day)) then
        return
    end
    writeNative(time, play, dayLength)
end

-- how far the engine may drift from the synced clock before checkNativeDrift snaps it back:
-- ~43 in-game seconds while playing (should never be reached now that the rates match - only
-- frame-timing noise, or the engine advancing on real time instead of simulation time while the
-- simulation speed isn't 1x), and float32 noise only while paused
local PLAYING_DRIFT_TOLERANCE = 0.0005
local PAUSED_DRIFT_TOLERANCE = 1e-5

--- Low-frequency safety net (every onSlowUpdate, 250ms): reads the engine back and rewrites it only
--- if it has actually wandered - time drifted, play or dayLength changed by something outside BJS.
local function checkNativeDrift()
    if not M.data.timeSync or applied.dayLength == nil then return end
    if resyncLerpUntilMs and GetCurrentTimeMillis() < resyncLerpUntilMs then return end
    local native = extensions.core_environment.getTimeOfDay()
    if not native or native.time == nil then return end
    local time = currentToD()
    local play = isPlaying()
    local tolerance = play and PLAYING_DRIFT_TOLERANCE or PAUSED_DRIFT_TOLERANCE
    if native.play ~= play or
        math.abs((tonumber(native.dayLength) or 0) - applied.dayLength) > 0.01 or
        math.abs(circularDiff(native.time, time)) > tolerance then
        writeNative(time, play, nativeDayLengthAt(time))
    end
end

--- Turns a native-shaped time-of-day change (setState / setTimeOfDay patch) into a synced one.
---@param patch table
---@param nowToDBefore number the live position under the CURRENT settings, captured before
---anything changes them
---@return table? delta for M.data, nil if nothing synced actually changed
local function captureTimeChange(patch, nowToDBefore)
    local delta = {}
    -- the vanilla panel calls setState continuously while open, and its own time naturally reads
    -- back whatever the engine last showed: only a value meaningfully different from the live
    -- synced clock is an actual pick (a slider drag, a preset button - which don't pause first)
    local deliberateTime = patch.time ~= nil and math.abs(circularDiff(patch.time, nowToDBefore)) > 0.0001
    local playChanged = patch.play ~= nil and (patch.play == true) ~= (M.data.dayNightCycle == true)
    -- the engine holds the CURRENT PHASE's dayLength (not M.data.dayLength), and callers that
    -- pass the engine's whole state back through (photomode and similar) would otherwise read as
    -- "the player picked a new day length". A bare `{dayLength = X}` partial with no time (how the
    -- vanilla panel's picker sends it) is always a real pick; alongside a time, only a value
    -- different from what BJS itself last wrote is. Tolerances, not ~=: the engine stores
    -- dayLength as a float32, so e.g. 1800/7 reads back as 257.1428527..., never bit-identical.
    local newDayLength = nil
    local pickedDayLength = tonumber(patch.dayLength)
    if pickedDayLength and math.abs(pickedDayLength - (tonumber(M.data.dayLength) or 0)) > 0.01 and
        (patch.time == nil or math.abs(pickedDayLength - (applied.dayLength or 0)) > 0.01) then
        newDayLength = envClock.clampDayLength(pickedDayLength)
    end
    local dateChanged = (patch.year ~= nil and patch.year ~= M.data.year) or
        (patch.month ~= nil and patch.month ~= M.data.month) or
        (patch.day ~= nil and patch.day ~= M.data.day)

    if not (deliberateTime or playChanged or newDayLength or dateChanged) then return nil end

    if playChanged then delta.dayNightCycle = patch.play == true end
    if newDayLength then delta.dayLength = newDayLength end
    if dateChanged then
        delta.year = tonumber(patch.year) or M.data.year
        delta.month = tonumber(patch.month) or M.data.month
        delta.day = tonumber(patch.day) or M.data.day
    end
    -- Real, confirmed bug (direct report: pausing/unpausing "teleports the clock... sometimes a
    -- whole day cycle in less than a second", same when changing day length): the panel's play
    -- button and day-length picker send bare partials (`{play = ...}` / `{dayLength = ...}`, no
    -- time), and the epoch used to be re-anchored only when an explicit time came in - so the
    -- change landed on a stale epoch. Any change now collapses first: the new epoch starts where
    -- the clock actually was under the OLD settings, same as the server's own collapseToD.
    delta.ToD = deliberateTime and patch.time or nowToDBefore
    delta.ToDEpochAtMs = GetCurrentTimeMillis()
    return delta
end

--- on environment setting changed via in-game menu (or toggling bigmap menu)
---@param state EnvState
---@param lerpSeconds number?
-- `lerpSeconds` must be captured and forwarded: the panel calls setState(patch, lerpSeconds)
-- for anything but a bare play/pause toggle. Losing it forced every change through native's
-- instant-snap path instead of its smooth fade, which desyncs the engine's real-time
-- lighting/exposure adaptation.
local function interceptEnvState(state, lerpSeconds)
    local nowToDBefore = currentToD()
    local newData = {}
    if M.data.timeSync then
        local delta = captureTimeChange(state, nowToDBefore)
        if delta then table.assign(newData, delta) end
    end
    if M.data.gravitySync then
        newData.gravity = state.gravity
    end

    if table.length(newData) > 0 and
        beamjoy_permissions.hasAnyPermission(nil, BJ_PERMISSIONS.SetEnvironment) then
        ---@type table
        newData = table.assign(table.clone(M.data), newData)
        if not table.compare(M.data, newData) then
            M.data = newData
            sendEnv({
                ToD = newData.ToD,
                dayNightCycle = newData.dayNightCycle,
                dayLength = newData.dayLength,
                year = newData.year,
                month = newData.month,
                day = newData.day,
                gravity = newData.gravity,
            })
            M.ToDProcess = true
        end
    end

    -- Only touch the fields that are actually wrong (the panel calls this every frame it's open,
    -- for unrelated reasons too - cloud cover, wind - and forcing every field back through a real
    -- setState restarted in-flight lerps, the old "less smooth at higher framerate" bug). Nothing
    -- to correct means state/lerpSeconds pass through completely untouched.
    if M.data.timeSync then
        local nowToD = currentToD()
        local play = isPlaying()
        local dayLength = nativeDayLengthAt(nowToD)
        if state.time == nil or math.abs(circularDiff(state.time, nowToD)) > 0.0001 then
            state.time = nowToD
        end
        if state.play ~= play then state.play = play end
        if state.dayLength ~= dayLength then state.dayLength = dayLength end
        applied.play, applied.dayLength = play, dayLength
        local y, mo, d = M.data.year, M.data.month, M.data.day
        if y and mo and d and (state.year ~= nil or state.month ~= nil or state.day ~= nil) then
            state.year, state.month, state.day = y, mo, d
            applied.year, applied.month, applied.day = y, mo, d
        end
    end
    if M.data.gravitySync and state.gravity ~= M.data.gravity then
        state.gravity = M.data.gravity
    end
    M.baseFunctions.core_environment.setState(state, lerpSeconds)
end

--- wrapped core_environment.setTimeOfDay: other callers (0.39's panel for some actions, photomode,
--- scenarios) go through here instead of setState
---@param ToD table
local function interceptSetTimeOfDay(ToD)
    if not M.data.timeSync then
        return M.baseFunctions.core_environment.setTimeOfDay(ToD)
    end
    if bigmap.menuOpened or -- skip ToD when bigmap is opened
        not beamjoy_permissions.hasAnyPermission(nil, BJ_PERMISSIONS.SetEnvironment) then
        return
    end
    local delta = captureTimeChange(ToD, currentToD())
    if delta then
        M.data = table.assign(table.clone(M.data), delta)
        M.ToDProcess = true
        sendEnv({
            ToD = M.data.ToD,
            dayNightCycle = M.data.dayNightCycle,
            dayLength = M.data.dayLength,
            year = M.data.year,
            month = M.data.month,
            day = M.data.day,
        })
    end
    -- whatever else the caller set (location, celestial profile...) still goes through, but the
    -- synced fields always carry the synced values, never the caller's raw ones
    local time = currentToD()
    local play = isPlaying()
    local dayLength = nativeDayLengthAt(time)
    local patch = table.clone(ToD)
    patch.time, patch.play, patch.dayLength = time, play, dayLength
    if M.data.year and M.data.month and M.data.day then
        patch.year, patch.month, patch.day = M.data.year, M.data.month, M.data.day
        applied.year, applied.month, applied.day = M.data.year, M.data.month, M.data.day
    end
    M.baseFunctions.core_environment.setTimeOfDay(patch)
    applied.play, applied.dayLength = play, dayLength
end

--- The first client on a map reports that map's solar data (and date, used only if the server has
--- none yet) - the server has no engine to read it from, and needs it to compute the same
--- day/night split as every client. Latitude/longitude/timezone are level data, identical for
--- every honest client, so the server keeps the first report per map.
local function reportObserver()
    local tod = extensions.core_environment.getTimeOfDay()
    if not tod then return end
    beamjoy_communications.send("envObserver", {
        map = getCurrentLevelIdentifier(),
        latitude = tod.latitude,
        longitude = tod.longitude,
        utcOffset = tod.utcOffset,
        dstRule = tod.dstRule,
        year = tod.year,
        month = tod.month,
        day = tod.day,
    })
end

local function onInit()
    InitPreloadedDependencies(M)
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJRequestEnv", M.sendEnvToUI)
    beamjoy_communications_ui.addHandler("BJSetEnvironment", M.setEnv)

    M.baseFunctions = {
        core_environment = {
            setState = extensions.core_environment and extensions.core_environment.setState,
            requestState = extensions.core_environment and extensions.core_environment.requestState,
            setTimeOfDay = extensions.core_environment and extensions.core_environment.setTimeOfDay,
        }
    }
    if not M.baseFunctions.core_environment.setState then
        log('E', 'BeamJoy', 'core_environment not available during onInit - environment hooks skipped')
    else
        extensions.core_environment.setState = interceptEnvState
        extensions.core_environment.requestState = function()
            if not M.ToDProcess then
                local requestState = M.baseFunctions.core_environment.requestState
                    or extensions.core_environment.requestState
                requestState()
            end
        end
        extensions.core_environment.setTimeOfDay = interceptSetTimeOfDay
    end
end

local function onExtensionUnloaded()
    RollBackNGFunctionsWrappers(M.baseFunctions)
end

local function onTogglePause()
    if extensions.core_replay.state.state ~= "playback" then
        beamjoy_communications.send("simPause", not simTimeAuthority.getPause())
        error("BeamJoy needs to prevent game from toggling pause (this error is not a real one)")
    end
end

local function updateSimSpeed()
    if beamjoy_main and beamjoy_main.world_ready and
        extensions.core_replay.state.state ~= "playback" then
        local pause = simTimeAuthority.getPause()
        if pause ~= M.data.simPause then
            simTimeAuthority.pause(M.data.simPause)
        end

        local speed = simTimeAuthority.get()
        if speed ~= M.data.simSpeed then
            simTimeAuthority.set(M.data.simSpeed)
            uiHelpers.message(nil, "bullettime") -- remove message

            if not M.speedProcess and beamjoy_permissions.hasAnyPermission(nil,
                    BJ_PERMISSIONS.SetEnvironment) then
                ---@type RequestAuthorization
                local auth = CreateRequestAuthorization(true)
                extensions.hook("onBJRequestChangeSimSpeed", auth)
                if auth.state then
                    beamjoy_communications.send("simSpeed", speed)
                    M.speedProcess = true
                elseif auth.reasons[1] then
                    LogError("Cannot change simulation speed now : " .. auth.reasons[1])
                end
            end
        end
    end
end

---@param forceToD boolean? a meaningful one-off resync (joined, or another player's change arrived)
---@param timeSyncDisabled boolean? timeSync was just turned off
---@param wasPlaying boolean? whether the clock was playing right before that
local function updateToD(forceToD, timeSyncDisabled, wasPlaying)
    -- getTimeOfDay() returns ONE shared engine table: only ever read here (nil = no level yet),
    -- never mutated or passed back - see writeNative, which always builds a fresh patch
    if not extensions.core_environment.getTimeOfDay() then return end

    if timeSyncDisabled then
        -- hand the engine back the plain synced day length (it may be holding a phase-adjusted
        -- one), and stop it if it was playing
        local patch = { dayLength = envClock.clampDayLength(M.data.dayLength) }
        if wasPlaying then patch.play = false end
        getSetToD()(patch)
        invalidateApplied()
        return
    end

    if not M.data.timeSync then return end

    if forceToD then
        -- ease the time in via setState's lerp instead of an instant snap (see
        -- RESYNC_LERP_SECONDS); dayLength and date go in instantly beforehand - a date must never
        -- be lerped (month-end 31 -> 1 would sweep through every day in between)
        local time = currentToD()
        local play = isPlaying()
        local dayLength = nativeDayLengthAt(time)
        local instant = { dayLength = dayLength }
        local y, mo, d = M.data.year, M.data.month, M.data.day
        if y and mo and d then
            instant.year, instant.month, instant.day = y, mo, d
            applied.year, applied.month, applied.day = y, mo, d
        end
        getSetToD()(instant)
        local setState = M.baseFunctions.core_environment.setState or extensions.core_environment.setState
        setState({ time = time, play = play }, RESYNC_LERP_SECONDS)
        applied.play, applied.dayLength = play, dayLength
        resyncLerpUntilMs = GetCurrentTimeMillis() + RESYNC_LERP_SECONDS * 1000
        return
    end

    if resyncLerpUntilMs and GetCurrentTimeMillis() < resyncLerpUntilMs then return end
    syncNative()
end

---@param resetGravity boolean?
local function updateGravity(resetGravity)
    if M.data.gravitySync then
        -- Used to call setGravity unconditionally every frame. Native's setGravity fires the
        -- onEnvironmentChanged hook AND queues an `obj:setGravity(...)` Lua chunk into EVERY
        -- vehicle's own VM (be:queueAllObjectLua) - traffic included - so this was compiling and
        -- running one chunk per vehicle per frame for nothing. Now only writes when the level's
        -- actual gravity (getGravity reads theLevelInfo.gravity, which native keeps in step with
        -- every setGravity and uses for newly spawned vehicles) differs. Tolerance, not ~=, since
        -- theLevelInfo.gravity is a float32 that never reads back bit-identical to e.g. -9.81.
        if math.abs(extensions.core_environment.getGravity() - M.data.gravity) > 1e-4 then
            extensions.core_environment.setGravity(M.data.gravity)
        end
    elseif resetGravity then
        extensions.core_environment.setGravity(DEFAULT_GRAVITY)
    end
end

local function onUpdate()
    updateSimSpeed()
    updateToD()
    updateGravity()
end

local function onSlowUpdate()
    checkNativeDrift()
end

local function onBJClientReady()
    reportObserver()
end

---@param state integer
local function onWorldReadyState(state)
    -- every level load creates a fresh engine TimeOfDay: forget what was written to the previous
    -- one so syncNative rewrites everything (the date included) into the new one
    invalidateApplied()
    resyncLerpUntilMs = nil
end

local function onBeforeRadialOpened()
    -- force timeplay on radial menu opened
    if extensions.core_replay.state.state ~= "playback" then
        core_jobsystem.create(function(job)
            job.sleep(.01)
            simTimeAuthority.set(M.data.simSpeed)
        end)
    end
end

---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    if extensions.core_replay.state.state ~= "playback" and
        not beamjoy_permissions.isStaff() then
        restrictions:addAll({ "pause", "slower_motion", "faster_motion", "toggle_slow_motion" }, true)
    end
end

local function onReplayStateChanged()
    beamjoy_restrictions.update()
end

local function onServerLeave()
    simTimeAuthority.set(1)
end

local function applySimSpeed(speed, pause)
    -- pause toggle
    if pause and not simTimeAuthority.getPause() then
        simTimeAuthority.pause(pause)
    elseif not pause and simTimeAuthority.getPause() then
        simTimeAuthority.pause(pause)
    end
    -- speed change
    if simTimeAuthority.get() ~= speed then
        simTimeAuthority.set(speed)
        simTimeAuthority.reportSpeed(math.round(speed, 3))
    end
    M.speedProcess = false
end

local function retrieveCache(caches)
    if caches.environment then
        ---@type table
        local changes = table.filter(caches.environment, function(v, k)
            return M.data[k] ~= v
        end)
        local wasPlaying = M.data.timeSync and M.data.dayNightCycle
        local timeSyncDisabled = changes.timeSync == false
        local resetGravity = M.data.gravity ~= DEFAULT_GRAVITY and
            changes.gravitySync == false
        -- Real, confirmed bug: the once-a-minute safety-net broadcast always carries a fresh
        -- ToD-at-a-NEW-epoch value, which reads as numerically "changed" even though it predicts
        -- the same current position. Treating every re-anchor as a real change fired the big,
        -- lerped resync once a minute for nothing. Only the PREDICTED CURRENT VALUE matters,
        -- compared before and after applying the new epoch (wrap-aware).
        local oldPredicted = currentToD()
        -- epochAgoMs is a wire-only DURATION (the server's own clock is meaningless here),
        -- converted into a local GetCurrentTimeMillis()-domain anchor the instant it arrives
        local epochAgoMs = caches.environment.epochAgoMs
        table.assign(M.data, caches.environment)
        if epochAgoMs ~= nil then
            M.data.ToDEpochAtMs = GetCurrentTimeMillis() - epochAgoMs
        end
        local newPredicted = currentToD()
        local forceToD = M.data.timeSync and not timeSyncDisabled and
            (changes.timeSync or changes.dayNightCycle or
                math.abs(circularDiff(newPredicted, oldPredicted)) > 0.0001)
        applySimSpeed(M.data.simSpeed, M.data.simPause)
        M.ToDProcess = true
        -- day length/speed/date/observer changes need no lerp: syncNative picks them up as a
        -- transition on the very next frame
        updateToD(forceToD, timeSyncDisabled, wasPlaying)
        M.ToDProcess = false
        updateGravity(resetGravity)
        local requestState = M.baseFunctions.core_environment.requestState
            or extensions.core_environment.requestState
        requestState()
        M.sendEnvToUI()
        extensions.hook("onBJEnvironmentChanged", changes)
    end
end

local function sendEnvToUI()
    local dayLength = envClock.clampDayLength(M.data.dayLength)
    local nightScaleMin, nightScaleMax = envClock.scaleBounds(dayLength)
    beamjoy_communications_ui.send("BJEnvironment", {
        timeSync = M.data.timeSync,
        gravitySync = M.data.gravitySync,
        nightScale = M.data.nightScale,
        -- read-only inputs for the config panel's full-cycle readout and slider range (dayLength
        -- comes from the vanilla environment panel, dayScale has no UI of its own)
        dayLength = dayLength,
        dayScale = envClock.effectiveScale(M.data.dayScale, dayLength),
        nightScaleMin = nightScaleMin,
        nightScaleMax = nightScaleMax,
        -- real sunrise-to-sunset share of the synced date's cycle (in time of day, not real time)
        dayFraction = envClock.dayFraction(M.data.observer, M.data.year, M.data.month, M.data.day),
    })
end

---@param newData {timeSync: boolean, gravitySync: boolean, nightScale: number?}
local function setEnv(newData)
    local payload = {
        timeSync = newData.timeSync,
        gravitySync = newData.gravitySync,
    }
    if tonumber(newData.nightScale) then
        -- server clamps too ; this just keeps the optimistic value sane
        payload.nightScale = math.clamp(tonumber(newData.nightScale), envClock.MIN_SCALE, envClock.MAX_SCALE)
    end
    if not M.data.timeSync and newData.timeSync then
        -- retrieve env data from game
        local ToD = extensions.core_environment.getTimeOfDay()
        if ToD then
            payload.ToD = ToD.time
            payload.dayNightCycle = ToD.play
            payload.dayLength = envClock.clampDayLength(ToD.dayLength)
            payload.year, payload.month, payload.day = ToD.year, ToD.month, ToD.day
        end
    end
    if not M.data.gravity and newData.gravitySync then
        -- retrieve gravity from game
        payload.gravity = extensions.core_environment.getGravity()
    end
    sendEnv(payload)
end

M.onInit = onInit
M.onExtensionUnloaded = onExtensionUnloaded
M.onTogglePause = onTogglePause
M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate
M.onBJClientReady = onBJClientReady
M.onWorldReadyState = onWorldReadyState
M.onBeforeRadialOpened = onBeforeRadialOpened
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onReplayStarted = onReplayStateChanged
M.onReplayStopped = onReplayStateChanged
M.onServerLeave = onServerLeave

M.retrieveCache = retrieveCache
M.sendEnvToUI = sendEnvToUI
M.setEnv = setEnv

return M
