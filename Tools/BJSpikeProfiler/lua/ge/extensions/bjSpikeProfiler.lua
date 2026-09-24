-- bjSpikeProfiler: standalone GE Lua spike logger. A debugging tool, not part of BeamJoy itself,
-- and costs nothing unless loaded.
--
-- In the in-game Lua console (~, GE Lua context):
--   extensions.load("bjSpikeProfiler")      start (calibrates for ~30 frames, then logs)
--   bjSpikeProfiler.setThreshold(8)         only log frames with >= 8 ms of Lua hook time (default 5)
--   bjSpikeProfiler.summary()               which hooks / jobs show up in spikes the most, so far
--   bjSpikeProfiler.reset()                 clear the summary
--   extensions.unload("bjSpikeProfiler")    stop (also prints the summary)
-- Output goes to BeamNG.log, every line tagged BJSpike. Close the console while recording: its own
-- window costs 10-20 ms a frame every few seconds and shows up as spikes.
--
-- How it works: the performance graph's "log GELua profile" button (requestGeluaProfile in the
-- game's lua/ge/main.lua) arms the game's own LuaProfiler for exactly ONE frame, then prints and
-- discards it - it only catches a spike that happens to land on that frame. This keeps the same
-- profiler armed every frame instead: extensions.setProfiler(p) switches the game's hook dispatcher
-- to hookSingleFrameProfiled (lua/common/extensions.lua), which times every extension hook call
-- separately (nested hook calls are attributed to the inner hook, so a dispatcher shows only its
-- own time). Once per frame this reads what was collected and logs it only if it crosses the
-- threshold. Frames that are slow while the hooks are not are logged as "outside GE Lua hooks":
-- the cause is then GC, engine C++/rendering, or vehicle Lua, none of which this can see.
--
-- Background jobs: core_jobsystem runs EVERY job inside its one onUpdate hook, so the hook timing
-- alone can't say which job was slow. core_jobsystem.create is wrapped while this is loaded: each
-- job is labeled with where it was created (file:line, plus two callers up) and the time of every
-- slice it runs between its own sleep()/yield() calls is attributed to that label. Only jobs created
-- AFTER loading are covered.
--
-- Limitations: only game-engine Lua is timed (not vehicle Lua, UI JavaScript or C++). The profiled
-- dispatcher skips the game's hook cache, so Lua runs somewhat slower while this is loaded - spikes
-- still stand out against normal frames, but absolute numbers are somewhat inflated.

local M = {}

local LOG_TAG = "BJSpike"
local SELF_PREFIX = "extensions.bjSpikeProfiler." -- our own hook calls, excluded from the numbers
local TOP_SECTIONS = 8
local TOP_JOBS = 5
local MAX_LOGS_PER_SECOND = 2
local CALIBRATION_FRAMES = 30
-- a frame counts as slow (for the "outside hooks" check) above this, or 3x the running average
local MIN_SLOW_FRAME_MS = 50
-- a section/job only counts toward the summary if it took at least this long in the spike frame,
-- so bystanders that merely ran during a spike (0.03 ms) don't drown out the actual cause
local MIN_SUMMARY_MS = 1

local thresholdMs = 5
local profiler = nil
-- the game's own hook dispatcher from before this was loaded, restored on unload (see
-- onExtensionUnloaded for why extensions.setProfiler(nil) can't be used for that)
local originalHook = nil
local originalJobCreate = nil

-- the game's timer (HighPerfTimer, used by LuaProfiler) has ambiguous units in its own code
-- comments, so they're measured instead against dtReal. After calibration the same timer keeps
-- running as the frame timer: the wall time between two of our onPreRender calls is exactly the
-- window the collected hook sections cover. (dtReal can't be used for that: it's the previous
-- frame's, and evidently smoothed - it read ~10 ms on a frame with 40 ms of Lua in it.)
local unitToMs = nil
local frameTimer, calibFrames, calibTimerSum, calibRealMs = nil, 0, 0, 0

local clockSec = 0 -- sum of dtReal, for rate limiting
local logWindowStart, logsInWindow, suppressed = 0, 0, 0
local avgFrameMs = nil
local lastGarbageKB = nil

-- job label -> ms spent this frame (swapped out every frame, like the profiler's sections)
local jobSlices = {}

local framesSeen, spikesSeen, outsideSeen = 0, 0, 0
---@type table<string, {spikes: integer, worstMs: number, totalMs: number}>
local stats = {}

local function info(msg)
    log("I", LOG_TAG, msg)
end

local function calibrate(dtReal)
    if not frameTimer then
        frameTimer = (HighPerfTimer or hptimer)()
        return
    end
    local t = frameTimer:stopAndReset()
    if dtReal and dtReal > 0 and t and t > 0 then
        calibTimerSum = calibTimerSum + t
        calibRealMs = calibRealMs + dtReal * 1000
        calibFrames = calibFrames + 1
    end
    if calibFrames >= CALIBRATION_FRAMES then
        local ratio = calibRealMs / calibTimerSum -- real ms per timer unit
        -- the timer is ms, s or us: snap to whichever is nearest
        if ratio > 30 then
            unitToMs = 1000
        elseif ratio < 0.03 then
            unitToMs = 0.001
        else
            unitToMs = 1
        end
        info(string.format("calibrated (timer unit = %g ms, measured ratio %.3f). Logging frames with >= %g ms of GE Lua time.",
            unitToMs, ratio, thresholdMs))
    end
end

local function canLog()
    if clockSec - logWindowStart >= 1 then
        logWindowStart, logsInWindow = clockSec, 0
    end
    if logsInWindow >= MAX_LOGS_PER_SECOND then
        suppressed = suppressed + 1
        return false
    end
    logsInWindow = logsInWindow + 1
    return true
end

local function suppressedNote()
    if suppressed == 0 then return "" end
    local note = string.format(", %d earlier spike(s) not logged (rate limit)", suppressed)
    suppressed = 0
    return note
end

local function countInSummary(name, ms)
    if ms < MIN_SUMMARY_MS then return end
    local st = stats[name]
    if not st then
        st = { spikes = 0, worstMs = 0, totalMs = 0 }
        stats[name] = st
    end
    st.spikes = st.spikes + 1
    st.totalMs = st.totalMs + ms
    if ms > st.worstMs then st.worstMs = ms end
end

local function reportSpike(sections, hookMs, frameMs, gcRan, jobs)
    spikesSeen = spikesSeen + 1

    local rows = {}
    for _, s in ipairs(sections) do
        if not s.section:find(SELF_PREFIX, 1, true) then
            rows[#rows + 1] = {
                name = s.section,
                ms = s.time * unitToMs,
                kb = math.max(0, s.garbage or 0) / 1024,
                runs = s.runs,
            }
        end
    end
    table.sort(rows, function(a, b) return a.ms > b.ms end)

    local jobRows = {}
    for label, ms in pairs(jobs) do
        jobRows[#jobRows + 1] = { label = label, ms = ms }
    end
    table.sort(jobRows, function(a, b) return a.ms > b.ms end)

    for i = 1, math.min(TOP_SECTIONS, #rows) do countInSummary(rows[i].name, rows[i].ms) end
    for i = 1, math.min(TOP_JOBS, #jobRows) do countInSummary("job " .. jobRows[i].label, jobRows[i].ms) end

    if not canLog() then return end
    info(string.format("SPIKE frame %.1f ms, GE Lua hooks %.1f ms (threshold %g ms)%s%s",
        frameMs, hookMs, thresholdMs, gcRan and ", GC ran this frame" or "", suppressedNote()))
    for i = 1, math.min(TOP_SECTIONS, #rows) do
        local row = rows[i]
        info(string.format("  %8.2f ms %8.1f KB  x%-3d %s", row.ms, row.kb, row.runs or 1, row.name))
    end
    local shown = 0
    for i = 1, math.min(TOP_JOBS, #jobRows) do
        if jobRows[i].ms >= 0.5 then
            if shown == 0 then info("  background jobs (core_jobsystem) this frame, by creator:") end
            info(string.format("  %8.2f ms  job %s", jobRows[i].ms, jobRows[i].label))
            shown = shown + 1
        end
    end
end

local function reportOutside(frameMs, hookMs, gcRan)
    outsideSeen = outsideSeen + 1
    if not canLog() then return end
    info(string.format("SLOW FRAME %.1f ms (avg %.1f ms) but GE Lua hooks only %.1f ms: outside extension hooks%s%s",
        frameMs, avgFrameMs or 0, hookMs,
        gcRan and " (GC ran this frame, likely a garbage collection pause)" or " (engine/rendering/vehicle Lua)",
        suppressedNote()))
end

function M.onPreRender(dtReal)
    if not profiler then return end
    -- re-arm every frame: the performance graph's own button calls extensions.setProfiler(nil) after
    -- its one frame, which would otherwise silently switch this off
    extensions.setProfiler(profiler)

    -- take this frame's sections and hand the profiler a fresh list. Only the list: its timer must
    -- NOT be reset here, since the dispatcher is timing this very call and will add() our own
    -- section right after it returns (LuaProfiler:add logs a "Missing start" error without one).
    local sections = profiler.sections
    profiler.sections = nil
    local jobs = jobSlices
    jobSlices = {}

    dtReal = tonumber(dtReal) or 0
    clockSec = clockSec + dtReal
    framesSeen = framesSeen + 1
    local garbageKB = collectgarbage("count")
    local gcRan = lastGarbageKB ~= nil and garbageKB < lastGarbageKB
    lastGarbageKB = garbageKB

    if not unitToMs then
        calibrate(dtReal)
        return
    end
    local frameMs = frameTimer:stopAndReset() * unitToMs

    local hookMs = 0
    if sections then
        for _, s in ipairs(sections) do
            if not s.section:find(SELF_PREFIX, 1, true) then
                hookMs = hookMs + s.time * unitToMs
            end
        end
    end

    if sections and hookMs >= thresholdMs then
        reportSpike(sections, hookMs, frameMs, gcRan, jobs)
    elseif avgFrameMs and frameMs >= math.max(MIN_SLOW_FRAME_MS, avgFrameMs * 3) then
        reportOutside(frameMs, hookMs, gcRan)
    end
    avgFrameMs = avgFrameMs and (avgFrameMs * 0.95 + frameMs * 0.05) or frameMs
end

------------------------------------------------------------------------------------------------
-- core_jobsystem attribution
------------------------------------------------------------------------------------------------

local function shortSource(info)
    -- engine-loaded chunks report as [string "lua/ge/extensions/beamjoy/config.lua"]
    local src = (info.short_src or "?"):gsub('^%[string "', ""):gsub('"%]$', "")
    return (src:match("([^/\\]+)$") or src) .. ":" .. tostring(info.currentline or 0)
end

-- "traffic.lua:862 < traffic.lua:968 < ui.lua:71": the creator plus two callers up, since a lot of
-- jobs are created through small helpers (async.lua) where the direct creator alone says little
local function jobLabel()
    local parts = {}
    for level = 3, 5 do
        local frameInfo = debug.getinfo(level, "Sl")
        if not frameInfo then break end
        parts[#parts + 1] = shortSource(frameInfo)
    end
    return table.concat(parts, " < ")
end

local function wrappedJobCreate(fct, maxdt, ...)
    local label = jobLabel()
    local function timed(job, ...)
        local sliceStart = os.clockhp()
        local function record()
            local ms = (os.clockhp() - sliceStart) * 1000
            jobSlices[label] = (jobSlices[label] or 0) + ms
        end
        -- a job gives the frame back only through its own sleep()/yield(): time each stretch
        -- between them. yield() doesn't always actually yield (only past maxdt), which just splits
        -- one frame's time into two records - the per-frame sum stays right.
        if type(job) == "table" then
            local origSleep, origYield = job.sleep, job.yield
            if type(origSleep) == "function" then
                job.sleep = function(...)
                    record()
                    origSleep(...)
                    sliceStart = os.clockhp()
                end
            end
            if type(origYield) == "function" then
                job.yield = function(...)
                    record()
                    origYield(...)
                    sliceStart = os.clockhp()
                end
            end
        end
        fct(job, ...)
        record()
    end
    return originalJobCreate(timed, maxdt, ...)
end

------------------------------------------------------------------------------------------------

---@param ms number
function M.setThreshold(ms)
    ms = tonumber(ms)
    if not ms or ms <= 0 then
        info("setThreshold: expected a positive number of milliseconds")
        return
    end
    thresholdMs = ms
    info(string.format("threshold set to %g ms", thresholdMs))
end

function M.summary()
    local names = {}
    for name in pairs(stats) do names[#names + 1] = name end
    table.sort(names, function(a, b)
        if stats[a].spikes ~= stats[b].spikes then return stats[a].spikes > stats[b].spikes end
        return stats[a].worstMs > stats[b].worstMs
    end)
    info(string.format("SUMMARY %d frames, %d Lua spikes (>= %g ms), %d slow frames outside Lua hooks",
        framesSeen, spikesSeen, thresholdMs, outsideSeen))
    if #names == 0 then
        info("  no Lua spikes recorded")
        return
    end
    info("   spikes    worst ms      avg ms  hook / job")
    for i = 1, math.min(20, #names) do
        local st = stats[names[i]]
        info(string.format("  %7d %11.2f %11.2f  %s", st.spikes, st.worstMs, st.totalMs / st.spikes, names[i]))
    end
end

function M.reset()
    stats = {}
    framesSeen, spikesSeen, outsideSeen, suppressed = 0, 0, 0, 0
    info("summary cleared")
end

function M.onExtensionLoaded()
    if type(LuaProfiler) ~= "function" or not extensions.setProfiler then
        log("E", LOG_TAG, "LuaProfiler / extensions.setProfiler not available in this game version")
        return
    end
    -- stay loaded across level changes: map loads are a prime spike suspect
    setExtensionUnloadMode(M, "manual")
    originalHook = extensions.hook
    profiler = LuaProfiler("bjSpikeProfiler")
    extensions.setProfiler(profiler)
    if extensions.core_jobsystem and type(os.clockhp) == "function" then
        originalJobCreate = extensions.core_jobsystem.create
        extensions.core_jobsystem.create = wrappedJobCreate
    end
    info(string.format("loaded, calibrating the timer for %d frames...", CALIBRATION_FRAMES))
end

-- stands in for the real profiler during the rest of the hook loop that's running while unloading
local NOOP_PROFILER = { start = function() end, add = function() end }

function M.onExtensionUnloaded()
    if not profiler then return end
    -- Real, confirmed crash: the console executes typed commands from inside its own onUpdate hook,
    -- so extensions.unload() here runs in the MIDDLE of the profiled dispatcher's loop, which calls
    -- profiler:add() right after the console's hook returns and profiler:start() for every
    -- extension after it. extensions.setProfiler(nil) nils that profiler out from under the loop
    -- ("attempt to index upvalue 'profiler' (a nil value)", lua/common/extensions.lua:775).
    -- Instead: hand the loop a do-nothing profiler so it can finish safely, and put the original
    -- dispatcher back directly so every later hook call is back to the normal fast path.
    extensions.setProfiler(NOOP_PROFILER)
    extensions.hook = originalHook
    -- jobs already created keep their timing wrapper until they finish; harmless (they only add
    -- to a table nothing reads anymore)
    if originalJobCreate and extensions.core_jobsystem and
        extensions.core_jobsystem.create == wrappedJobCreate then
        extensions.core_jobsystem.create = originalJobCreate
    end
    profiler = nil
    M.summary()
end

return M
