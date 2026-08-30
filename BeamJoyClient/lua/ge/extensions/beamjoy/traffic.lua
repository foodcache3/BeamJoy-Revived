local M = {
    preloadedDependencies = { "gameplay_traffic" },
    dependencies = { "beamjoy_communications", "beamjoy_communications_ui" },

    data = {
        enabled = false,
        amount = 0,
        total = 20,
        maxPerPlayer = 10,
        models = { "simple_traffic" },
    },
    ---@type tablelib<integer, integer> index 1-N, value vid
    vehs = Table(), -- owned AI vehs

    baseFunctions = {},
}
AddPreloadedDependencies(M)

---@return tablelib<integer, {pos: vec3, dir: vec3, speed: number}> index vid, value pos
local function getPlayersPositions()
    return beamjoy_vehicles.vehicles:filter(function(v)
        if (not v.isVehicle and
                v.jbeam ~= beamjoy_vehicles.WALKING) or
            v.isAi then
            return false
        end
        local mpVeh = beamjoy_vehicles.getVehicle(v.vid)
        return mpVeh ~= nil and mpVeh.spectators:length() > 0
    end):map(function(v) --- @param v BJVehicle
        return {
            pos = vec3(be:getObjectOOBBCenterXYZ(v.vid)),
            dir = v.veh:getDirectionVector(),
            speed = tonumber(v.veh.speed) or 0,
        }
    end)
end

---@param speed number meter/sec
---@return integer minDist, integer maxDist
local function getMinMaxDistFromPlayer(speed)
    return math.scale(speed * 3.6, 20, 200, 50, 200, true),
        math.scale(speed * 3.6, 20, 200, 150, 400, true)
end

-- Matches ge/extensions/gameplay/traffic.lua's own speed-based falloff (native traffic biases
-- spawns ahead of the player's travel direction at speed instead of picking a fully random road).
-- Without this, spawns stay uniformly random around the player even at highway speed, so most of
-- the fixed traffic budget lands somewhere behind/beside the player and is never driven past,
-- reading as "traffic got sparse" once the min/max band above also widens with speed.
---@param speed number meter/sec
---@return number
local function getPathRandomization(speed)
    return math.scale(speed * 3.6, 20, 200, 1, .15, true)
end

-- ge/extensions/core/funstuff.lua:randomRoute():191 <br/>
-- ge/spawn.lua:teleportToLastRoadCallback():616
---@param job NGJob?
---@return vec3? pos, quat? rot
local function getNewRandomSpawn(job)
    local mapNodes = map.getMap().nodes
    if table.length(mapNodes) == 0 then return end

    local playerPositions = getPlayersPositions()

    local valid = false
    local origin, spawnData, onRoute
    local tries, threshold = 0, 10
    repeat
        tries = tries + 1
        if playerPositions:length() == 0 then
            local min, max = M.getMinMaxDistFromPlayer(0)
            origin = {
                pos = table.random(mapNodes).pos,
                dir = vec3(0, 1, 0),
                speed = 0,
                minDistance = min,
                maxDistance = max,
                pathRandomization = M.getPathRandomization(0),
            }
        else
            origin = playerPositions:random()
            origin.minDistance, origin.maxDistance = M.getMinMaxDistFromPlayer(origin.speed)
            origin.pathRandomization = M.getPathRandomization(origin.speed)
        end
        spawnData, onRoute = extensions.gameplay_traffic_trafficUtils
            .findSpawnPointRadial(origin.pos, origin.dir,
                origin.minDistance, origin.maxDistance, origin.minDistance +
                (origin.maxDistance - origin.minDistance) / 4,
                { pathRandomization = origin.pathRandomization, minDrivability = .1 })
        if onRoute then
            local playersDistances = playerPositions:map(function(pData)
                return {
                    distance = vec3(spawnData.pos):distance(pData.pos),
                    minDistance = pData.minDistance,
                    maxDistance = pData.maxDistance,
                }
            end)
            if playerPositions:length() == 0 or
                (playersDistances:every(function(pData)
                        return pData.distance > pData.minDistance
                    end) and
                    playersDistances:any(function(pData)
                        return pData.distance < pData.maxDistance
                    end)) then
                valid = true
            end
        end
        if not valid and job then job.sleep(.01) end
    until valid or tries >= threshold

    if valid then
        local pos, dir = extensions.gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir,
            spawnData.n1, spawnData.n2, {
                legalDirection = true,
            })
        if job then job.sleep(.01) end
        local normal = map.surfaceNormal(pos, 1)
        return pos, quatFromDir(vec3(0, 1, 0):rotated(quatFromDir(dir, normal)), normal)
    end
end

--- overrides ge/extensions/core/multiSpawn.lua:createGroup():285
---@param job NGJob
---@param amount integer
---@return {model: string, config: string}[]
local function createGroup(job, amount)
    if type(amount) ~= "number" or amount < 1 then return {} end
    local models = table.filter(beamjoy_vehicles.getAllVehicleConfigs(job, { traffic = true }),
        function(_, model)
            return table.includes(M.data.models, model)
        end)

    if models:length() < 1 then
        LogError("Invalid traffic models")
        dump(M.data.models)
        return {}
    end

    local res = {}
    repeat
        local model = models:keys():random()
        local config = table.keys(models[model].configs):random()
        table.insert(res, { model = model, config = config })
    until #res == amount
    return res
end

local function createPostSpawnMergeCheck(vid)
    local event = string.format("TrafficMergeCheck-%d", vid)
    async.removeTask(event)
    async.delayTask(function()
        ---@type NGVehicle?
        local v = be:getObjectByID(vid)
        local damages = v and tonumber(v.damages)
        if damages and damages >= 1 then
            M.markForRespawn(vid)
        end
    end, 500, event)
end

local spawnLock = false
---@param amount? integer 1-N
local function spawnNewTrafficVehicles(amount)
    if spawnLock then return end                             -- already spawning traffic
    if table.length(map.getMap().nodes) == 0 then return end -- map has no routes

    spawnLock = true
    amount = amount or 1
    core_jobsystem.create(function(job)
        local vehConfigs = createGroup(job, amount)
        uiHelpers.toastInfo(beamjoy_lang.translate("beamjoy.toast.traffic.waitForSpawn"))
        uiHelpers.applyLoading(true)
        job.sleep(.3)
        for i = 1, amount do
            local vehConfig = vehConfigs[i]
            if vehConfig then
                local options = {}
                options.vehicleName = "traffic"
                options.cling = true
                options.autoEnterVehicle = false

                local pos, rot
                while not pos do
                    pos, rot = getNewRandomSpawn(job)
                    if not pos then job.sleep(.01) end
                end
                job.sleep(.01)
                local coreModel = extensions.core_vehicles.getModel(vehConfig.model)
                job.sleep(.01)
                local paintNames = table.keys(coreModel.model.paints or {})
                for j = 1, 3 do
                    local pickName = table.random(paintNames)
                    if coreModel.model.paints[pickName] then
                        local key = "paintName"
                        if j > 1 then key = key .. tostring(j) end
                        options[key] = pickName
                        key = "paint"
                        if j > 1 then key = key .. tostring(j) end
                        options[key] = coreModel.model.paints[pickName]
                    end
                end
                job.sleep(.01)
                local pathConfig = string.format("vehicles/%s/%s.pc", vehConfig.model, vehConfig.config)
                local veh = spawn.spawnVehicle(vehConfig.model, pathConfig, pos, rot, options)
                job.sleep(.01)
                extensions.hook("onBJTrafficVehicleSpawned", veh)
                core_vehicleBridge.executeAction(veh, 'setAIMode', "traffic")
                job.sleep(.01)
                createPostSpawnMergeCheck(veh:getID())
                while i == amount and not M.vehs:includes(veh:getID()) do
                    job.sleep(.2)
                end
            end
        end
        uiHelpers.applyLoading(false)
        spawnLock = false
        extensions.hook("onBJTrafficUpdated")
    end)
end

---@param forceReset boolean? if traffic models have changed
local function updateVehs(forceReset)
    if spawnLock then
        -- process lock system
        async.removeTask("updateTrafficVehs")
        async.task(function() return not spawnLock end, function()
            updateVehs(forceReset)
        end, "updateTrafficVehs")
        return
    end

    local function clearVehs()
        for _, vid in pairs(M.vehs) do
            beamjoy_vehicles.delete(vid)
            extensions.hook("onBJTrafficVehicleDeleted", vid)
        end
        M.vehs:clear()
    end
    if M.data.enabled and forceReset then
        clearVehs()
    end
    if M.data.enabled and M.vehs:length() ~= M.data.amount then
        if M.vehs:length() > M.data.amount then
            for i = M.vehs:length(), M.data.amount + 1, -1 do
                local vid = M.vehs:remove(i)
                beamjoy_vehicles.delete(vid)
                extensions.hook("onBJTrafficVehicleDeleted", vid)
            end
        elseif M.vehs:length() < M.data.amount then
            spawnNewTrafficVehicles(M.data.amount - M.vehs:length())
        end
    elseif not M.data.enabled and M.vehs:length() > 0 then
        clearVehs()
    end
end

local function saveAndSend(payload)
    local newData = table.clone(M.data)
    table.assign(newData, payload)
    newData.amount = nil
    if payload.amount then newData.total = payload.amount end
    if payload.models then newData.models = payload.models end
    local dirty = not table.compare(newData, M.data)
    if dirty then
        beamjoy_communications.send("trafficSettings", {
            enabled = newData.enabled,
            amount = newData.total,
            maxPerPlayer = newData.maxPerPlayer,
            models = newData.models,
        })
    end
end

local function sendSettingsToUI()
    extensions.core_jobsystem.create(function(job)
        local models = beamjoy_vehicles.getAllVehicleConfigs(job,
                { cars = false, trucks = false, traffic = true })
            :map(function(v)
                return v.label
            end)
        beamjoy_communications_ui.send("BJTrafficSettings", {
            data = {
                enabled = M.data.enabled,
                amount = M.data.total,
                maxPerPlayer = M.data.maxPerPlayer,
                models = M.data.models,
            },
            models = models
        })
        local newModels = table.filter(table.clone(M.data.models), function(m)
            return models[m] ~= nil
        end)
        if not table.compare(newModels, M.data.models) then
            if #newModels == 0 then table.insert(newModels, "simple_traffic") end
            saveAndSend({ models = newModels })
        end
    end)
end

local function toggleTraffic()
    if beamjoy_permissions.isStaff() then
        saveAndSend({ enabled = not M.data.enabled })
    end
end

local function overrideNGHooks()
    M.baseFunctions = {
        gameplay_traffic = {
            toggle = extensions.gameplay_traffic.toggle,
            activate = extensions.gameplay_traffic.activate,
            deactivate = extensions.gameplay_traffic.deactivate,
            deleteVehicles = extensions.gameplay_traffic.deleteVehicles,
            setupTrafficWaitForUi = extensions.gameplay_traffic.setupTrafficWaitForUi,
        }
    }

    -- keybind
    extensions.gameplay_traffic.toggle = toggleTraffic
    -- radial play
    extensions.gameplay_traffic.activate = function()
        if not M.data.enabled then toggleTraffic() end
    end
    -- radial pause
    extensions.gameplay_traffic.deactivate = function()
        if M.data.enabled then toggleTraffic() end
    end
    -- radial remove traffic
    extensions.gameplay_traffic.deleteVehicles = function()
        if M.data.enabled then toggleTraffic() end
    end
    -- radial spawn traffic
    extensions.gameplay_traffic.setupTrafficWaitForUi = function(withPolice)
        if not M.data.enabled then
            if withPolice then
                uiHelpers.toastWarning(beamjoy_lang.translate("beamjoy.toast.traffic.policeDisabled"))
            end
            toggleTraffic()
        end
    end
end

local function onInit()
    InitPreloadedDependencies(M)

    beamjoy_communications.addHandler("sendCache", function(caches)
        if caches.traffic then
            M.retrieveCache(caches.traffic)
        end
    end)
    beamjoy_communications_ui.addHandler("BJReady", updateVehs)
    beamjoy_communications_ui.addHandler("BJRequestTrafficSettings", sendSettingsToUI)
    beamjoy_communications_ui.addHandler("BJTrafficSettings", saveAndSend)
    beamjoy_communications.addHandler("trafficRubberbandTick", M.onRubberbandTick)

    overrideNGHooks()
end

local function onExtensionUnloaded()
    RollBackNGFunctionsWrappers(M.baseFunctions)
end

---@param restrictions tablelib<integer, string> index 1-N
local function onBJRequestRestrictions(restrictions)
    if not beamjoy_permissions.isStaff() then
        restrictions:insert("toggleTraffic")
    end
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    local mpVeh = beamjoy_vehicles.vehicles[vid]
    if mpVeh and mpVeh.isLocal then
        if mpVeh.isAi and not M.vehs:includes(vid) then
            M.vehs:insert(vid)
            mpVeh.playerUsable = false
            mpVeh.uiState = 0
        end
    elseif not mpVeh.isAi and M.vehs:includes(vid) then
        M.vehs:remove(vid)
        mpVeh.playerUsable = true
        mpVeh.uiState = 1
    end
end

local cachesPaints = {}

---@param job NGJob
---@param vid integer
local function rubberband(job, vid)
    if not M.vehs:includes(vid) then return end
    local target = beamjoy_vehicles.vehicles[vid]
    if not target or not target.isAi or not target.isLocal then return end

    local pos, rot = getNewRandomSpawn(job)
    if pos then
        if not cachesPaints[target.jbeam] then
            cachesPaints[target.jbeam] = table.values(beamjoy_vehicles.getAllPaints(target.veh))
        end
        if table.length(cachesPaints[target.jbeam]) > 0 then
            beamjoy_vehicles.paint(target.veh,
                { table.random(cachesPaints[target.jbeam]) })
        end
        spawn.safeTeleport(target.veh, pos, rot, true, nil, false, nil, true)
        core_vehicleBridge.executeAction(target.veh, 'setAIMode', "traffic")
        extensions.hook("onBJTrafficVehicleResetted", target.veh)
        createPostSpawnMergeCheck(target.veh:getID())
    end
end

local function onRubberbandTick()
    core_jobsystem.create(function(job)
        local playerPositions = getPlayersPositions()
        if playerPositions:length() > 0 then
            local selfAis = M.vehs:map(function(vid) return beamjoy_vehicles.vehicles[vid] end)
            -- Previously rubberbanded only a single (and, due to a dead distance-tracking bug,
            -- effectively arbitrary) vehicle per tick, which this server-throttled event fires at
            -- most once/second for. At speed, a player can leave several owned traffic vehicles
            -- beyond their max distance in the same tick; capping repositioning to one at a time
            -- left the rest invisible out of range for multiple seconds, reading as sparse traffic.
            -- Rubberbanding every out-of-range vehicle in one pass fixes the throughput, not just
            -- the spawn direction bias fixed by getPathRandomization above.
            local targetsToRubberband = selfAis:filter(function(v)
                local pos = vec3(be:getObjectOOBBCenterXYZ(v.vid))
                return playerPositions:every(function(data)
                    local _, maxDist = M.getMinMaxDistFromPlayer(data.speed)
                    return pos:distance(data.pos) >= maxDist
                end)
            end)
            targetsToRubberband:forEach(function(v)
                rubberband(job, v.vid)
            end)
        end
    end)
end

local function retrieveCache(cache)
    if not table.compare(cache, M.data, true) then
        local previousModels = table.clone(M.data.models)
        M.data = cache
        sendSettingsToUI()
        updateVehs(not table.compare(previousModels, M.data.models))
    end
end

local function markForRespawn(vid)
    if M.vehs:includes(vid) then
        core_jobsystem.create(function(job)
            job.sleep(.01)
            rubberband(job, vid)
        end)
    end
end

M.onInit = onInit
M.onExtensionUnloaded = onExtensionUnloaded
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onRubberbandTick = onRubberbandTick

M.getMinMaxDistFromPlayer = getMinMaxDistFromPlayer
M.getPathRandomization = getPathRandomization
M.retrieveCache = retrieveCache
M.markForRespawn = markForRespawn

M.createGroup = createGroup

return M
