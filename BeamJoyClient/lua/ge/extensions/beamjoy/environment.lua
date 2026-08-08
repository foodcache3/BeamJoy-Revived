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
        ToD = 0,          -- noon
        dayNightCycle = false,
        dayLength = 1800, -- seconds
        dayScale = 1,
        nightScale = 2,
        nightBrightnessMultiplier = 1,
        gravitySync = false,
        gravity = DEFAULT_GRAVITY,
    },

    speedProcess = false,
    ToDProcess = false,

    cachedObjects = {},
}
AddPreloadedDependencies(M)

---@param data {timeSync: boolean?, ToD: number, dayNightCycle: boolean?, dayLength: integer?, dayScale: number?, nightScale: number?, nightBrightnessMultiplier: number?, gravitySync: boolean?, gravity: number?}
local function sendEnv(data)
    local payload = table.assign({
        timeSync = M.data.timeSync,
        ToD = M.data.ToD,
        dayNightCycle = M.data.dayNightCycle,
        dayLength = M.data.dayLength,
        dayScale = M.data.dayScale,
        nightScale = M.data.nightScale,
        nightBrightnessMultiplier = M.data.nightBrightnessMultiplier,
        gravitySync = M.data.gravitySync,
        gravity = M.data.gravity,
    }, data)
    beamjoy_communications.send("setEnv", payload)
end

local minuteStep = 1 / 24 / 60
--- on environment setting changed via in-game menu (or toggling bigmap menu)
---@param state EnvState
local function interceptEnvState(state)
    local newData = {}
    if M.data.timeSync then
        -- send new env data
        table.assign(newData, {
            dayNightCycle = state.play,
            dayScale = state.dayScale,
            nightScale = state.nightScale,
        })
        if not state.play or math.abs(state.time - M.data.ToD) > minuteStep then
            newData.ToD = state.time
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
                    dayScale = newData.dayScale,
                    nightScale = newData.nightScale,
                    gravity = newData.gravity,
                })
                M.ToDProcess = true
            end
        end
    end

    -- rollback server-driven settings
    if M.data.timeSync then
        table.assign(state, {
            time = M.data.ToD,
            play = M.data.dayNightCycle,
            dayScale = M.data.dayScale,
            nightScale = M.data.nightScale,
        })
    end
    if M.data.gravitySync then
        table.assign(state, {
            gravity = M.data.gravity,
        })
    end
    M.baseFunctions.core_environment.setState(state)
end

local function cacheWorldObjects()
    local classes = Table(scenetree.findClassObjects("ScatterSky"))
    if classes:length() > 0 then
        classes:forEach(function(name)
            local obj = scenetree.findObject(name)
            if obj then
                M.cachedObjects.ScatterSky = obj
            end
        end)
    end
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
                sendEnv({
                    ToD = ToD.time,
                    dayNightCycle = ToD.play == true,
                    dayLength = ToD.dayLength,
                    dayScale = ToD.dayScale,
                    nightScale = ToD.nightScale,
                })
                M.baseFunctions.core_environment.setTimeOfDay(ToD)
            end
        end
    end

    async.task(function() return beamjoy_main.world_ready end, cacheWorldObjects)
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

---@param forceToD boolean?
---@param forceStopTimePlay boolean?
local function updateToD(forceToD, forceStopTimePlay)
    local ToD = extensions.core_environment.getTimeOfDay()
    if ToD then
        if M.data.timeSync then
            ToD.play = M.data.dayNightCycle == true
            if not ToD.play or forceToD then
                ToD.time = tonumber(M.data.ToD) or 0
            end
            ToD.dayLength = tonumber(M.data.dayLength) or 1800
            ToD.dayScale = tonumber(M.data.dayScale) or 1
            ToD.nightScale = tonumber(M.data.nightScale) or 2
        else
            ToD.dayLength = 1800 -- default
        end

        if forceStopTimePlay then
            ToD.play = false
        end
        local setToD = M.baseFunctions.core_environment.setTimeOfDay
            or extensions.core_environment.setTimeOfDay
        setToD(ToD)
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

local function updateBrightness()
    if not beamjoy_main.world_ready then return end
    local ToD = extensions.core_environment.getTimeOfDay()
    if not ToD then return end

    if M.data.timeSync then
        -- refresh brightness
        local targetBrightness
        if ToD.time < .245 or ToD.time > .755 then
            -- day
            targetBrightness = 1
        elseif ToD.time > .25 or ToD.time < .75 then
            -- night
            targetBrightness = M.data.nightBrightnessMultiplier
        elseif ToD.time <= .25 then
            -- dusk
            targetBrightness = math.scale(ToD.time, .245, .25, 1, tonumber(M.data.nightBrightnessMultiplier) or 1, true)
        else -- if ToD.time >= .75 then
            -- dawn
            targetBrightness = math.scale(ToD.time, .75, .755, tonumber(M.data.nightBrightnessMultiplier) or 1, 1, true)
        end
        if M.cachedObjects.ScatterSky.brightness ~= targetBrightness then
            M.cachedObjects.ScatterSky.brightness = targetBrightness
        end
    else
        M.cachedObjects.ScatterSky.brightness = 1
    end
end

local function onUpdate()
    updateSimSpeed()
    updateToD()
    updateGravity()
    updateBrightness()
end

---@param ctxt TickContext
---@param serverTick BJServerTick
local function onServerTick(ctxt, serverTick)
    local ToD = extensions.core_environment.getTimeOfDay()
    if ToD and serverTick.ToD then
        M.data.ToD = serverTick.ToD
        if math.abs(ToD.time - M.data.ToD) > 0.001 then
            -- resync
            ToD.time = tonumber(M.data.ToD) or 0
            local setToD = M.baseFunctions.core_environment.setTimeOfDay
                or extensions.core_environment.setTimeOfDay
            setToD(ToD)
        end
    end
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
        table.assign(M.data, caches.environment)
        local forceToD = M.data.timeSync and
            (changes.dayNightCycle or changes.ToD)
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
        dayLength = M.data.dayLength,
        nightBrightnessMultiplier = M.data.nightBrightnessMultiplier,
        gravitySync = M.data.gravitySync,
    })
end

---@param newData {timeSync: boolean, dayLength: integer, nightBrightnessMultiplier: number, gravitySync: boolean}
local function setEnv(newData)
    local payload = {
        timeSync = newData.timeSync,
        dayLength = newData.dayLength,
        nightBrightnessMultiplier = newData.nightBrightnessMultiplier,
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
M.onServerTick = onServerTick
M.onBeforeRadialOpened = onBeforeRadialOpened
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onReplayStarted = onReplayStateChanged
M.onReplayStopped = onReplayStateChanged
M.onServerLeave = onServerLeave

M.retrieveCache = retrieveCache
M.sendEnvToUI = sendEnvToUI
M.setEnv = setEnv

return M
