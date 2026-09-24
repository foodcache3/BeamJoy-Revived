local DEFAULT_GRAVITY = -9.81
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
        dayLength = 1800, -- seconds
        dayScale = 1,
        nightScale = 2,
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

---@param t0 number ToD at the start of the elapsed window, 0-1
---@param dtSec number real seconds elapsed since t0 (may be very large, or negative - treated as 0)
---@param dayLength integer
---@param dayScale number
---@param nightScale number
---@param simSpeed number
---@return number ToD, 0-1
---@nodiscard
--- Exact client-side twin of `services/environment.lua`'s own `computeCurrentToD` (server) - see
--- its own doc comment for the full reasoning (closed-form, not a loop; the "shifted" coordinate
--- that makes day/night's own two-disjoint-pieces span in raw ToD-space tractable). Keep both in
--- sync if this ever changes.
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

---@return number ToD, 0-1, right now - computed locally, no network round-trip needed
---@nodiscard
local function currentToD()
    if not (M.data.timeSync and M.data.dayNightCycle) then return M.data.ToD end
    local elapsedSec = (GetCurrentTimeMillis() - (M.data.ToDEpochAtMs or GetCurrentTimeMillis())) / 1000
    return computeCurrentToD(M.data.ToD, elapsedSec, M.data.dayLength, M.data.dayScale,
        M.data.nightScale, M.data.simSpeed)
end

---@param a number ToD, 0-1
---@param b number ToD, 0-1
---@return number the signed distance from b to a going the SHORT way around the 0-1 wrap, in
---(-0.5, 0.5] - e.g. circularDiff(0.0002, 0.9999) is ~0.0003, not ~0.9997
---@nodiscard
--- Real, confirmed bug (direct report: a large, incorrect jump "forwards then stops" specifically
--- around noon - ToD 0, the exact point the raw value wraps from just-under-1 back to
--- just-over-0 in this codebase's convention): every drift/rollback check below used to compare
--- native's own .time against a target with a plain subtraction, which isn't wrap-aware - right at
--- the boundary (e.g. native.time=0.9999, target=0.0002) that reads as a difference of ~1.0
--- instead of the true ~0.0003, tripping the "needs correcting" threshold for a swing that isn't
--- actually there and snapping across almost a full cycle. Every ToD comparison in this file goes
--- through this instead.
local function circularDiff(a, b)
    return (a - b + 0.5) % 1 - 0.5
end

---@param data {timeSync: boolean?, ToD: number, dayNightCycle: boolean?, dayLength: integer?, dayScale: number?, nightScale: number?, gravitySync: boolean?, gravity: number?}
local function sendEnv(data)
    local payload = table.assign({
        timeSync = M.data.timeSync,
        -- Real, confirmed bug (found while implementing the epoch redesign above, before it ever
        -- shipped): this used to default to the raw M.data.ToD - now only the value AT its own
        -- epoch, not "right now" - so sending it as part of some unrelated change (e.g. toggling
        -- gravitySync alone) while playing would tell the server to roll the clock BACK to that
        -- stale epoch value, undoing everything that had played out since. currentToD() is always
        -- the live, correct value regardless of what's actually changing.
        ToD = currentToD(),
        dayNightCycle = M.data.dayNightCycle,
        dayLength = M.data.dayLength,
        dayScale = M.data.dayScale,
        nightScale = M.data.nightScale,
        gravitySync = M.data.gravitySync,
        gravity = M.data.gravity,
    }, data)
    beamjoy_communications.send("setEnv", payload)
end

-- Shared lerp duration for any *forced* one-off ToD resync (as opposed to the routine per-tick
-- pass-through): jumping the clock discontinuously desyncs the engine's real-time lighting/
-- exposure adaptation and can leave it broken until an actual sunrise re-settles it naturally.
local RESYNC_LERP_SECONDS = 0.9
-- Real, confirmed bug (direct report: shadows still visibly jerk at high framerate, even with
-- drift itself confirmed negligible - forceToD no longer firing spuriously). The routine playing-
-- time correction below used to be throttled to at most once every fixed 200ms (CORRECTION_
-- INTERVAL_MS) - an explicit wall-clock wait, not a drift-threshold one, so it always applied
-- whatever had accumulated over that FULL fixed window in one instant snap, however large that
-- happened to be, rather than firing the moment the (much smaller) 0.0001 threshold was first
-- crossed. At high framerate, many more frames render within that same 200ms window, so the eye
-- sees a long smooth run then one comparatively large snap at the end of it - more perceptible the
-- higher the framerate, exactly the report. The check itself (currentToD() plus a native read and
-- a comparison) is a cheap local computation - no native WRITE unless a correction actually fires
-- - so there's no need to gate the check on a timer at all. Only the forceToD lerp above needs a
-- brief exclusion window (below), so the routine correction doesn't fight it mid-transition.
local resyncLerpUntilMs = nil
--- on environment setting changed via in-game menu (or toggling bigmap menu)
---@param state EnvState
-- `lerpSeconds` must be captured and forwarded: the panel calls setState(patch, lerpSeconds)
-- for anything but a bare play/pause toggle (see useEnvironmentState.js's applyState). Losing
-- it here previously forced every change through native's `duration <= 0` instant-snap path
-- instead of its smooth fade, which desyncs the engine's real-time lighting/exposure adaptation -
-- jumping the clock instead of easing it through the change left lighting wrong (severity
-- depending on the jump from the previous time) until an actual sunrise re-settled it naturally.
local function interceptEnvState(state, lerpSeconds)
    local newData = {}
    if M.data.timeSync then
        -- send new env data
        table.assign(newData, {
            dayNightCycle = state.play,
            dayLength = state.dayLength,
            dayScale = state.dayScale,
            nightScale = state.nightScale,
        })
        -- Real, confirmed bug (direct report: sync only worked for non-admins): the panel calls
        -- setState continuously while playing (see this function's own header comment), and its
        -- own state.time naturally races ahead of M.data.ToD - the value AT its own epoch, not
        -- "right now" (see currentToD's own doc comment) - on its own, more so the longer it's
        -- been playing since that epoch. Treating that as "the player dragged the slider" pushed
        -- the panel's own drifting local value to the server as authoritative on every such call,
        -- for any player with SetEnvironment permission - fighting the real sync (which only ever
        -- reaches the server for a permitted player, i.e. exactly the reported "admin-only"
        -- symptom). Originally fixed by only ever honoring state.time while paused, on the theory
        -- that a deliberate pick only makes sense then - but a time-of-day quick-jump/preset button
        -- (confirmed via the installed UI's own TodControl.vue: applyTodTimeToEngine passes
        -- `play: !!next.play`, i.e. whatever play already was, never pausing) is just as deliberate
        -- and doesn't pause first, direct report: "skipping from noon to night... breaks the
        -- lighting for both clients" - that skip was silently getting dropped here (never sent to
        -- the server at all) AND overwritten back to the old synced time by the rollback further
        -- below before it ever reached native, explaining why it needed a second, unrelated change
        -- to "unstick". `play` was never actually the right signal - whether state.time is
        -- meaningfully different from the live currentToD() is: ordinary per-frame redisplay while
        -- playing stays within the same ~0.0001 tolerance updateToD's own routine correction keeps
        -- native pinned to (confirmed reliable there already), so it's a safe threshold for "is this
        -- actually a deliberate change" regardless of play state, without reviving the original
        -- false-positive bug this replaced.
        if state.time ~= nil and math.abs(circularDiff(state.time, currentToD())) > 0.0001 then
            newData.ToD = state.time
            -- fresh anchor for the new value - without this, currentToD() would advance it by
            -- however long it's been since the OLD (now stale) epoch the instant anything reads it
            -- again, since M.data.ToD is about to change here but M.data.ToDEpochAtMs otherwise
            -- wouldn't (harmless for the paused case above, since dayNightCycle=false there makes
            -- currentToD() skip the epoch math entirely - but not while playing, this new case).
            newData.ToDEpochAtMs = GetCurrentTimeMillis()
        end
    end
    if M.data.gravitySync then
        newData.gravity = state.gravity
    end

    if table.length(newData) > 0 then
        if beamjoy_permissions.hasAnyPermission(nil,
                BJ_PERMISSIONS.SetEnvironment) then
            ---@type table
            newData = table.assign(table.clone(M.data), newData)
            if not table.compare(M.data, newData) then
                M.data = newData
                sendEnv({
                    ToD = newData.ToD,
                    dayNightCycle = newData.dayNightCycle,
                    dayLength = newData.dayLength,
                    dayScale = newData.dayScale,
                    nightScale = newData.nightScale,
                    gravity = newData.gravity,
                })
                M.ToDProcess = true
            end
        end
    end

    -- Real, confirmed bug (direct report: "not smooth, especially at night... gets LESS smooth at
    -- higher framerate"): the vanilla panel calls setState continuously while open (see this
    -- function's own header comment) - for all sorts of reasons unrelated to time itself (cloud
    -- cover, wind, ...), every single render frame it stays open. This rollback used to run
    -- unconditionally on every one of those calls, forcibly re-pushing time/play/etc through a
    -- REAL native setState call regardless of whether anything actually needed correcting -
    -- restarting/interfering with whatever lerp was already in flight, every single frame the panel
    -- stayed open. More frames per second meant more restarts per second, giving any one of them
    -- even less time to actually settle before being cut off again - textbook explanation for "gets
    -- worse at higher framerate". Fixed by only touching the fields that are actually wrong: `time`
    -- compares against `currentToD()` (the live, locally-computed value - see its own doc comment),
    -- NOT the raw M.data.ToD, which is only accurate at the moment of its own epoch and drifts
    -- further from reality the longer the clock's been playing since; the rest are discrete,
    -- host-configured values so an exact comparison is right. Nothing to correct means
    -- state/lerpSeconds pass through completely untouched, for whatever the panel actually wanted
    -- to change.
    if M.data.timeSync then
        local rollback = {}
        local nowToD = currentToD()
        if state.time == nil or math.abs(circularDiff(state.time, nowToD)) > 0.0001 then
            rollback.time = nowToD
        end
        if state.play ~= M.data.dayNightCycle then rollback.play = M.data.dayNightCycle end
        if state.dayLength ~= M.data.dayLength then rollback.dayLength = M.data.dayLength end
        if state.dayScale ~= M.data.dayScale then rollback.dayScale = M.data.dayScale end
        if state.nightScale ~= M.data.nightScale then rollback.nightScale = M.data.nightScale end
        if next(rollback) then
            table.assign(state, rollback)
        end
    end
    if M.data.gravitySync and state.gravity ~= M.data.gravity then
        table.assign(state, {
            gravity = M.data.gravity,
        })
    end
    M.baseFunctions.core_environment.setState(state, lerpSeconds)
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
        extensions.core_environment.setTimeOfDay = function(ToD)
            if not M.data.timeSync then
                M.baseFunctions.core_environment.setTimeOfDay(ToD)
            elseif not bigmap.menuOpened and -- skip ToD when bigmap is opened
                beamjoy_permissions.hasAnyPermission(nil,
                    BJ_PERMISSIONS.SetEnvironment) then
                -- optimistic local update, mirrors interceptEnvState below: BeamNG 0.39's
                -- env panel play/pause button now calls setTimeOfDay({play=...}) directly
                -- (a single-key partial) instead of going through setState, so without this
                -- M.data.dayNightCycle stays stale until the server round-trip lands. The
                -- very next onUpdate tick (100ms) would otherwise read that stale value in
                -- updateToD() and immediately push play back off, which looked like the
                -- play button "auto-pausing" itself.
                local newData = table.clone(M.data)
                -- capture the TRUE current value (before anything below changes) as the new
                -- epoch's starting position, whether or not ToD.time was explicitly given - a
                -- bare {play=...} toggle (no time field, "a single-key partial" per above) still
                -- needs a correct anchor, not a stale M.data.ToD left over from whenever the last
                -- epoch arrived
                newData.ToD = ToD.time ~= nil and ToD.time or currentToD()
                newData.ToDEpochAtMs = GetCurrentTimeMillis()
                if ToD.play ~= nil then newData.dayNightCycle = ToD.play == true end
                if ToD.dayLength ~= nil then newData.dayLength = ToD.dayLength end
                if ToD.dayScale ~= nil then newData.dayScale = ToD.dayScale end
                if ToD.nightScale ~= nil then newData.nightScale = ToD.nightScale end
                M.data = newData
                M.ToDProcess = true

                sendEnv({
                    ToD = newData.ToD,
                    dayNightCycle = newData.dayNightCycle,
                    dayLength = newData.dayLength,
                    dayScale = newData.dayScale,
                    nightScale = newData.nightScale,
                })
                M.baseFunctions.core_environment.setTimeOfDay(ToD)
            end
        end
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

-- BJS has no day/night cycle duration setting of its own anymore: `dayLength` is picked up from
-- whatever the player sets in the *vanilla* environment panel (via interceptEnvState above, same
-- as dayScale/nightScale already were) and only re-applied here to keep it synced across players
-- when timeSync is on. Previously this forced a hardcoded `dayLength = 1800` onto the engine every
-- ~100ms tick whenever timeSync was OFF, which silently reset any locally-chosen cycle duration
-- back to 30 minutes (confirmed live) - and even when timeSync was ON, this file never actually
-- captured `state.dayLength` from the panel, so picking anything above the old BJS-only config
-- UI's own 300-minute cap got stomped back down on the very next tick. Fix: only touch `ToD` at
-- all when there's actually something for BJS to enforce (timeSync, or a one-shot forced stop).
---@param forceToD boolean?
---@param forceStopTimePlay boolean?
-- Real, confirmed design flaw (direct report: "not smooth, especially at night... gets less smooth
-- at higher framerate... some other solution might be required"), on top of the real, confirmed
-- shared-table write bug fixed earlier (see below): even once writes actually took effect, the
-- installed game's own native `play` auto-advance has NO concept of dayScale/nightScale at all
-- (confirmed: zero references to either in the installed game's own core/environment.lua) - it can
-- only free-run at ONE flat rate for the whole cycle. Whenever dayScale ~= nightScale (the default),
-- native's own flat rate can never actually match the server's real, asymmetric one - not a
-- correction-frequency problem, a structural rate mismatch, worst at night (nightScale=2 by
-- default: nights pass twice as fast as native's own flat rate can represent).
--
-- Redesigned around `currentToD()` (see its own doc comment): the mathematically exact current ToD,
-- computed locally from the server's own epoch, correct for any elapsed duration with no further
-- network round-trip. While PAUSED, this just pins that exact value directly (unchanged from
-- before - that half was already confirmed working). While PLAYING, native's own `play=true` still
-- drives the free, always-smooth per-frame motion (day, where dayScale=1 by default, needs
-- essentially no correction at all this way), but is now corrected toward the exact target the
-- moment it actually drifts far enough to matter (checked every frame, purely local - no added
-- server/network cost) instead of on a fixed once-a-second server-driven cadence, so even night's
-- unavoidable rate mismatch gets smoothed into many small nudges instead of few large ones.
local function updateToD(forceToD, forceStopTimePlay)
    -- Real, confirmed bug (direct report: "correcting drift just keeps going up", eventually
    -- traced to nativeTime never moving AT ALL despite constant write attempts with canChange()
    -- true). Root cause, confirmed by reading the installed game's own core/environment.lua:
    -- `getTimeOfDay()` does not return a fresh table - it returns a reference to ONE shared,
    -- module-level singleton (`local timeOfDay = {}`) that every caller in the engine reads AND
    -- writes. This function used to mutate that SAME shared table in place (`ToD.time = ...`)
    -- and pass it straight back into setTimeOfDay - but setTimeOfDay fires the native
    -- `onEnvironmentChanged` hook BEFORE it actually writes to the real TimeOfDay object, and if
    -- anything anywhere in the engine reacts to that by calling getTimeOfDay() again, it silently
    -- clobbers our pending value back to the stale one (same shared table), and the write that
    -- follows just reapplies that stale value - a no-op disguised as a real write, confirmed live
    -- (nativeTime frozen for 35+ real seconds while M.data.ToD kept climbing correctly). Fixed by
    -- never mutating/reusing the shared table: only ever used here for the nil-check (no level
    -- loaded yet), and every outgoing call gets its own fresh, BJS-owned table instead.
    if not extensions.core_environment.getTimeOfDay() then return end

    if forceToD and M.data.timeSync then
        -- Meaningful one-off resync (cache retrieved on join, or another player's environment
        -- change just arrived) - ease into it via setState's lerp instead of an instant
        -- setTimeOfDay snap. Using the raw instant snap here is what let the night-lighting bug
        -- keep reproducing for a single player only (specifically whichever one just went through
        -- this forced resync, e.g. right after joining) even after that fix, and only when
        -- timeSync is on (the only case this branch runs at all). Uses currentToD(), not a raw
        -- M.data.ToD, so this lands on the exact right value even if some processing delay
        -- elapsed between the epoch arriving and this actually running.
        local setState = M.baseFunctions.core_environment.setState
            or extensions.core_environment.setState
        local resyncTarget = currentToD()
        setState({
            time = resyncTarget,
            play = M.data.dayNightCycle == true,
            dayLength = tonumber(M.data.dayLength) or 1800,
            dayScale = tonumber(M.data.dayScale) or 1,
            nightScale = tonumber(M.data.nightScale) or 2,
        }, RESYNC_LERP_SECONDS)
        -- don't let the routine playing-correction below immediately fire again right on top of
        -- this lerp before it's had a chance to finish
        resyncLerpUntilMs = GetCurrentTimeMillis() + RESYNC_LERP_SECONDS * 1000
        return
    end

    if forceStopTimePlay then
        local setToD = M.baseFunctions.core_environment.setTimeOfDay
            or extensions.core_environment.setTimeOfDay
        setToD({ play = false })
        return
    end

    if not M.data.timeSync then return end

    if not M.data.dayNightCycle then
        -- paused : pin the exact synced value every tick - this half was already confirmed
        -- working correctly before the redesign above, unchanged here
        local setToD = M.baseFunctions.core_environment.setTimeOfDay
            or extensions.core_environment.setTimeOfDay
        setToD({ play = false, time = currentToD() })
        return
    end

    -- playing : correction toward the exact target, checked every frame (see this function's own
    -- header comment, and resyncLerpUntilMs's own doc comment, for why there's no throttle on the
    -- check itself anymore). native is read-only here (see the shared-table doc comment above) -
    -- only ever used for the .time comparison, never mutated or passed back into any native call.
    --
    -- Real, confirmed bug (direct report: "much smoother, however at high framerates over 60 it
    -- still can seem jerky... jerking increases with framerate"): this used to correct via a
    -- lerped setState call. The installed game's own core/environment.lua steps every in-progress
    -- lerp with `stateLerp.elapsed = min(stateLerp.elapsed + max(dtReal, 1/60), stateLerp.duration)`
    -- - it floors EVERY frame's own delta-time at 1/60s, even when far less real time actually
    -- passed. Above 60fps that means each frame advances the lerp by MORE than really elapsed, so
    -- it completes proportionally faster than requested the higher the framerate climbs (2x fast
    -- at 120fps, 4x at 240fps, ...) - a native engine quirk, not something fixable from here.
    -- These corrections are already meant to be tiny, frequent nudges now (not the old once-a-
    -- second jumps that genuinely needed easing), so they don't need a lerp at all - an instant
    -- setTimeOfDay snap sidesteps the native floor bug entirely, since there's no lerp left for
    -- it to distort, while still being visually imperceptible as a "jump" given how small each
    -- one is.
    if resyncLerpUntilMs and GetCurrentTimeMillis() < resyncLerpUntilMs then return end
    local native = extensions.core_environment.getTimeOfDay()
    local target = currentToD()
    if native and math.abs(circularDiff(native.time, target)) > 0.0001 then
        local setToD = M.baseFunctions.core_environment.setTimeOfDay
            or extensions.core_environment.setTimeOfDay
        setToD({ time = target, play = true })
    end
end

---@param resetGravity boolean?
local function updateGravity(resetGravity)
    if M.data.gravitySync then
        extensions.core_environment.setGravity(M.data.gravity)
    elseif resetGravity then
        extensions.core_environment.setGravity(DEFAULT_GRAVITY)
    end
end

local function onUpdate()
    updateSimSpeed()
    updateToD()
    updateGravity()
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
        local forceStopTimePlay = M.data.dayNightCycle and
            changes.timeSync == false
        local resetGravity = M.data.gravity ~= DEFAULT_GRAVITY and
            changes.gravitySync == false
        -- Real, confirmed bug (direct report: a jerk "forwards then stops" that got WORSE with
        -- higher framerate and went away at lower framerate - the same signature as the native
        -- lerp-floor bug documented in updateToD's own doc comment, just not from the routine
        -- correction this time, from THIS forceToD path's own lerped setState call, still present
        -- there). Root cause: the once-a-minute safety-net broadcast (services/environment.lua's
        -- own SAFETY_RESYNC_INTERVAL_SEC) always carries a FRESH ToD-at-a-NEW-epoch value, which
        -- reads as numerically "changed" from whatever epoch this client already had via the plain
        -- `changes.ToD` check below - even though it's the exact same continuously-advancing
        -- clock, just re-anchored, predicting essentially the same current position. Treating
        -- every such re-anchor as a genuine "the time meaningfully changed" event triggered the
        -- big, lerped forceToD resync once a minute for no real reason, and at high framerate that
        -- lerp races through fast enough to look like a jerk (same native floor bug). Only the
        -- PREDICTED CURRENT VALUE actually matters, not whether the raw epoch-relative number
        -- moved - compared before and after applying the new epoch below, via circularDiff so a
        -- comparison straddling the noon wrap point isn't ALSO a problem here.
        local oldPredicted = currentToD()
        -- epochAgoMs is a wire-only DURATION (server GetCurrentTime() is meaningless here - see
        -- services/environment.lua's own doc comment for why this whole feature is built around
        -- durations, not timestamps), converted into a local GetCurrentTimeMillis()-domain anchor
        -- the instant it arrives ; table.assign below would otherwise just leave it sitting
        -- unused as a plain M.data.epochAgoMs field
        local epochAgoMs = caches.environment.epochAgoMs
        table.assign(M.data, caches.environment)
        if epochAgoMs ~= nil then
            M.data.ToDEpochAtMs = GetCurrentTimeMillis() - epochAgoMs
        end
        local newPredicted = currentToD()
        local forceToD = M.data.timeSync and
            (changes.dayNightCycle or changes.dayLength or changes.dayScale or changes.nightScale or
                math.abs(circularDiff(newPredicted, oldPredicted)) > 0.0001)
        applySimSpeed(M.data.simSpeed, M.data.simPause)
        M.ToDProcess = true
        updateToD(forceToD, forceStopTimePlay)
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
    beamjoy_communications_ui.send("BJEnvironment", {
        timeSync = M.data.timeSync,
        gravitySync = M.data.gravitySync,
    })
end

---@param newData {timeSync: boolean, gravitySync: boolean}
local function setEnv(newData)
    local payload = {
        timeSync = newData.timeSync,
        gravitySync = newData.gravitySync,
    }
    if not M.data.timeSync and newData.timeSync then
        -- retrieve env data from game
        local ToD = extensions.core_environment.getTimeOfDay()
        if ToD then
            payload.ToD = ToD.time
            payload.dayNightCycle = ToD.play
            payload.dayScale = ToD.dayScale
            payload.nightScale = ToD.nightScale
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
M.onBeforeRadialOpened = onBeforeRadialOpened
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onReplayStarted = onReplayStateChanged
M.onReplayStopped = onReplayStateChanged
M.onServerLeave = onServerLeave

M.retrieveCache = retrieveCache
M.sendEnvToUI = sendEnvToUI
M.setEnv = setEnv

return M
