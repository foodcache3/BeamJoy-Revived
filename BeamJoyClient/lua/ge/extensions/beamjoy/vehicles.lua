local M = {
    preloadedDependencies = { "core_vehicles", "core_vehicle_partmgmt", "core_vehicleBridge", "gameplay_walk" },
    dependencies = {},

    TYPES = {
        CAR = "Car",
        TRUCK = "Truck",
        TRAILER = "Trailer",
        PROP = "Prop",
        TRAFFIC = "Traffic",
    },
    WALKING = "unicycle",

    ---@type tablelib<integer, BJVehicle> index vid
    vehicles = Table(),

    modelTypeCache = {},
}
AddPreloadedDependencies(M)

---@param model string
---@return boolean
local function isAi(model)
    return type(model) == "string" and model:lower():find("traffic") ~= nil
end

local function onInit()
    InitPreloadedDependencies(M)
    beamjoy_communications.addHandler("deleteVehicle", M.delete)
    beamjoy_communications.addHandler("explodeVehicle", M.explode)
    beamjoy_communications.addHandler("updateVehicleGhost", function(vid, state)
        local mpVeh = M.vehicles[vid]
        if mpVeh then
            M.setGhost(mpVeh.veh, state == true, true)
        end
    end)
end

---@param vid integer
---@param callback fun(mpVeh: BJVehicle)?
local function registerVehicle(vid, callback)
    callback = callback or function() end
    local veh = be:getObjectByID(vid)
    if not veh then
        M.vehicles[vid] = nil
        return
    end
    core_jobsystem.create(function(job)
        local mpVeh
        repeat
            mpVeh = Table(MPVehicleGE.getVehicles())
                :find(function(v) return v.gameVehicleID == vid end)
            job.sleep(.01)
        until mpVeh and mpVeh.jbeam == veh.jbeam
        mpVeh = mpVeh or {} -- fail safe

        local owner
        while not owner do
            owner = beamjoy_players.players
                :find(function(p) return p.playerID == mpVeh.ownerID end)
            if not owner then job.sleep(.25) end
        end
        local vtype = M.getType(veh.jbeam)
        local aiVeh = isAi(veh.jbeam)
        if aiVeh then
            veh.playerUsable = false
            veh.uiState = 0
        elseif not mpVeh.isLocal and veh.jbeam == M.WALKING then
            veh.playerUsable = false
        end
        M.vehicles[vid] = {
            vid = vid,
            serverVID = mpVeh.serverVehicleID,
            remoteVID = mpVeh.remoteVehID ~= -1 and mpVeh.remoteVehID or vid,
            ownerID = owner.playerID,
            ownerName = owner.playerName,
            tanks = {},
            veh = veh,
            jbeam = veh.jbeam,
            height = veh:getInitialHeight(),
            type = vtype,
            isVehicle = veh.jbeam ~= M.WALKING and
                not table.includes({ M.TYPES.TRAILER, M.TYPES.PROP }, vtype),
            isAi = aiVeh,
            spectators = Table(),
            isDeleted = mpVeh.isDeleted,
            isLocal = mpVeh.isLocal,
            isSpawned = mpVeh.isSpawned,
            protected = mpVeh.protected == "1",
        }

        callback(M.vehicles[vid])
        extensions.hook("onBJVehicleInstantiated", vid)

        if owner and replay.replayPlayers[owner.playerName] then
            veh:disableCollision()
        end
    end)
end

local function onVehicleSpawned(vid)
    registerVehicle(vid, function(mpVeh)
        if mpVeh.isLocal then
            if camera.getCamera() == camera.CAMERAS.FREE then
                camera.toggleFreeCam()
            end
            local self = beamjoy_players.getSelf()
            if not mpVeh.isAi and self and self.froze then
                M.setFreeze(vid, false)
            end
        end
    end)
end

local function onVehicleSwitched(previousVID, newVID)
    if previousVID ~= -1 and M.vehicles[previousVID] then
        local v = M.vehicles[previousVID]
        if v.isLocal then
            if v.jbeam == M.WALKING then
                async.delayTask(function()
                    -- delay unicycle deletion to allow toggleWalk process to complete
                    local veh = be:getObjectByID(previousVID)
                    if veh then veh:delete() end
                end, 50)
            else
                -- reset inputs except parking brake
                v.veh:queueLuaCommand([[
                    local parkingbrake = input.state.parkingbrake.val
                    input.init()
                    input.state.parkingbrake.val = parkingbrake
                ]])
            end
        end
        if v.veh.ghost == "1" then
            extensions.core_vehicle_partmgmt.setHighlightedPartsVisiblity(.5, v.vid)
        end
    end
    if newVID ~= -1 then
        local timeout = GetCurrentTimeMillis() + 2000
        async.task(function(job, ctxt)
            if ctxt.now >= timeout then return true end
            local v = M.getVehicle(newVID, true)
            if not v then return false end
            return v.remoteVID ~= nil
        end, function(job, ctxt)
            local v = M.getVehicle(newVID, true)
            if v and replay.replayPlayers[v.ownerName] then
                M.switchToNextVehicle()
                return
            end
            if v and (v.isLocal or v.remoteVID) then
                beamjoy_communications.send("updateCurrentVehicle",
                    v.remoteVID)
            else
                local currentVeh = M.getCurrent()
                if currentVeh and currentVeh.remoteVID ~= beamjoy_players.getSelf().currentVehicle then
                    beamjoy_communications.send("updateCurrentVehicle", currentVeh.remoteVID)
                elseif not currentVeh and beamjoy_players.getSelf().currentVehicle then
                    beamjoy_communications.send("updateCurrentVehicle")
                end
            end
            if v then
                if v.veh.ghost == "1" then
                    extensions.core_vehicle_partmgmt.setHighlightedPartsVisiblity(1, v.vid)
                end
                beamjoy_communications_ui.send("BJHUDIcon", {
                    pos = 3,
                    state = v.veh.ghost == "1",
                    name = "ghost",
                })
            end
        end)
    else
        beamjoy_communications.send("updateCurrentVehicle")
    end
end

local function onVehicleDestroyed(vid)
    M.vehicles[vid] = nil
end

local lastShut = {}
local function onSlowUpdate()
    -- speed and damage update process
    M.vehicles:filter(function(v) return v.isVehicle end)
        :forEach(function(v)
            v.veh:queueLuaCommand(string.var([[
                local sp = tostring(obj:getAirflowSpeed());
                obj:queueGameEngineLua("beamjoy_vehicles.updateVehAttribute('speed', {1}, "..sp..")");

                local dmg = serialize(beamstate.damage);
                obj:queueGameEngineLua("beamjoy_vehicles.updateVehAttribute('damages', {1}, "..dmg..")");
            ]], { v.vid }))
        end)

    -- shut vehicles engine process
    M.vehicles:filter(function(v)
        return v.isLocal and not v.isAi and v.isVehicle
    end):forEach(function(v)
        if v.veh.shut == "1" then
            M.setEngine(v.vid, false)
            if not lastShut[v.vid] then
                lastShut[v.vid] = true
            end
        elseif lastShut[v.vid] then
            M.setEngine(v.vid, true)
            lastShut[v.vid] = nil
        end
    end)
end

---@param ctxt TickContext
local function onServerTick(ctxt)
    if not ctxt.self then return LogWarn("Vehicle server tick => self not initialized") end
    ctxt.self.vehicles:map(function(v)
        return M.vehicles[v.vid]
    end):filter(function(v) ---@param v BJVehicle
        return not v.isAi and v.jbeam ~= M.WALKING
    end):forEach(function(v) ---@param v BJVehicle
        if #beamjoy_activity_manager.data.safeZones > 0 then
            local vPos = M.getVehiclePositionRotation(v.veh) + vec3(0, 0, v.veh:getInitialHeight() / 2)
            ---@param zone GizmoObject
            local inZone = table.any(beamjoy_activity_manager.data.safeZones, function(zone)
                local right = zone.dir:cross(zone.up)
                local d = vPos - zone.pos
                local lx = d:dot(right)
                local ly = d:dot(zone.dir)
                local lz = d:dot(zone.up)
                return math.abs(lx) <= zone.scales.x * .5 and
                    math.abs(ly) <= zone.scales.y * .5 and
                    math.abs(lz) <= zone.scales.z * .5
            end)
            if v.veh.ghost ~= "1" and inZone then
                M.setGhost(v.veh, true)
            elseif v.veh.ghost == "1" and not inZone then
                M.setGhost(v.veh, false)
            end
        elseif v.veh.ghost == "1" then
            M.setGhost(v.veh, false)
        end
    end)
end

local function onVehicleResetted(vid)
    if M.vehicles[vid] and M.vehicles[vid].isLocal and
        not M.vehicles[vid].isAi and M.vehicles[vid].veh.froze then
        M.setFreeze(vid, false)
    end
end

---@param req RequestAuthorization
---@param model string
---@param config string?
local function onBJRequestCanSpawnVehicle(req, model, config)
    local canSpawnTrailers = beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.SpawnTrailers)
    local canSpawnProps = beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.SpawnProps)
    if not M.allVehicleConfigs then
        M.getAllVehicleConfigs()
    end
    if not canSpawnTrailers and M.allTrailerConfigs[model] then
        req.state = false
    elseif not canSpawnProps and M.allPropConfigs[model] then
        req.state = false
    elseif not M.allVehicleConfigs[model] and
        not M.allTrailerConfigs[model] and
        not M.allPropConfigs[model] and
        not model == M.WALKING then
        req.state = false
    end
end

local function onBJVehicleModChanged()
    local allModels = beamjoy_vehicles.getAllVehicleConfigs(nil,
        { cars = true, trucks = true, trailers = true, props = true, forced = true })
    beamjoy_vehicles.vehicles:filter(function(v) ---@param v BJVehicle
        -- Find owned and invalid vehicles
        return v.isLocal and not v.isAi and
            v.jbeam ~= beamjoy_vehicles.WALKING and
            not allModels[v.jbeam]
    end):forEach(function(v) ---@param v BJVehicle
        beamjoy_vehicles.delete(v.vid)
    end)
end

---@param jbeam string
---@return string
local function getType(jbeam)
    if M.modelTypeCache[jbeam] then
        return M.modelTypeCache[jbeam]
    end

    if not M.allVehicleConfigs then
        M.getAllVehicleConfigs()
    end

    local finalType
    if M.allVehicleConfigs[jbeam] then
        finalType = M.allVehicleConfigs[jbeam].Type
    elseif M.allTrailerConfigs[jbeam] then
        finalType = M.allTrailerConfigs[jbeam].Type
    elseif M.allPropConfigs[jbeam] then
        finalType = M.allPropConfigs[jbeam].Type
    end
    M.modelTypeCache[jbeam] = finalType
    return finalType
end

---@param vid integer
---@param light boolean?
---@return BJVehicle?
local function getVehicle(vid, light)
    local v = M.vehicles[vid]
    if M.vehicles[vid] and not light then
        v.position, v.rotation = M.getVehiclePositionRotation(v.veh)
        v.spectators = beamjoy_context.get().players
            :filter(function(p) return p.currentVehicle == v.remoteVID end)
            :map(function() return true end)
    end
    return v
end

---@param remoteVID integer
---@param withPosition boolean?
---@return BJVehicle?
local function getVehicleByRemoteID(remoteVID, withPosition)
    local mpVeh = Table(MPVehicleGE.getVehicles())
        :find(function(v) return v.remoteVehID == remoteVID end)
    if mpVeh then
        return getVehicle(mpVeh.gameVehID, not withPosition)
    end
end

---@param veh NGVehicle
---@return vec3 pos, vec3 dir, vec3 up
local function getVehiclePositionRotation(veh)
    return vec3(be:getObjectOOBBCenterXYZ(veh:getID())) -
        veh:getDirectionVectorUp() * veh:getInitialHeight() / 2,
        veh:getDirectionVector(), veh:getDirectionVectorUp()
end

---@param veh NGVehicle
---@param pos vec3
---@param dir vec3?
---@param up vec3?
---@param options {cling: false?, autoEnterVehicle: true?, safe: false?, noReset: true?}?
local function setVehiclePositionRotation(veh, pos, dir, up, options)
    options = options or {}
    options.cling = options.cling ~= false -- default true
    options.autoEnterVehicle = options.autoEnterVehicle == true
    options.safe = options.safe ~= false   -- default true
    options.noReset = options.noReset == true

    if options.cling then
        pos.z = be:getSurfaceHeightBelow(pos + vec3(0, 0, 10))
    end
    if not dir then
        local _
        _, dir, up = M.getVehiclePositionRotation(veh)
    end

    local rot = quatFromDir(dir * -1, up)
    if options.noReset then
        local vehRot = quat(veh:getClusterRotationSlow(veh:getRefNodeId()))
        local diffRot = vehRot:inversed() * rot
        veh:setClusterPosRelRot(veh:getRefNodeId(), pos.x, pos.y, pos.z,
            diffRot.x, diffRot.y, diffRot.z, diffRot.w)
        veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 0, 0, 0, 0)
    else
        veh:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
        local center = rot * veh.initialNodePosBB:getCenter()
        local refnode = rot * veh:getInitialNodePosition(veh:getRefNodeId())
        local centerToRefnode = refnode - center
        pos = pos + centerToRefnode
        if options.safe then
            rot = rot * quat(0, 0, 1, 0)
            spawn.safeTeleport(veh, pos, rot, false)
        else
            veh:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
            veh:resetBrokenFlexMesh()
        end
    end
end

---@class NGVehicleConfig
---@field label string
---@field custom boolean
---@field value integer?

---@class NGVehicleModel
---@field label string
---@field type string
---@field custom boolean
---@field paints table<string, NGPaint>
---@field configs table<string, NGVehicleConfig> index config_key
---@field preview string

---@param job NGJob?
---@param data {cars: boolean?, trucks: boolean?, trailers: boolean?, props: boolean?, traffic: boolean?, forced: boolean?}?
---@return table<string, NGVehicleModel> allConfigs index model_key
local function getAllVehicleConfigs(job, data)
    data = data or {}
    data.cars = data.cars ~= false
    data.trucks = data.trucks ~= false

    if not data.forced and M.allVehicleConfigs then
        -- cached data
        local configs = {}
        if data.cars then
            table.assign(configs, Table(M.allVehicleConfigs):clone()
                :filter(function(v) return v.Type == M.TYPES.CAR end))
        end
        if data.trucks then
            table.assign(configs, Table(M.allVehicleConfigs):clone()
                :filter(function(v) return v.Type == M.TYPES.TRUCK end))
        end
        if data.trailers then
            table.assign(configs, Table(M.allTrailerConfigs):clone())
        end
        if data.props then
            table.assign(configs, Table(M.allPropConfigs):clone())
        end
        if data.traffic then
            table.assign(configs, Table(M.allTrafficConfigs):clone())
        end
        return configs
    end

    local time = GetCurrentTimeMillis()
    local frameSkip = function()
        if job and GetCurrentTimeMillis() > time + 1 then
            job.sleep(.01)
            time = GetCurrentTimeMillis()
        end
    end

    -- data gathering
    local vehicles = {}
    local trailers = {}
    local props = {}
    local traffic = {}
    local vehs = extensions.core_vehicles.getVehicleList().vehicles
    for _, veh in ipairs(vehs) do
        if veh.model then
            local isVeh = true -- Truck | Car
            local isTraffic = veh.model.Type == M.TYPES.TRAFFIC and veh.model.key:lower():find("traffic")
            M.modelTypeCache[veh.model.key] = veh.model.Type
            if table.includes({ M.TYPES.TRAILER, M.TYPES.PROP }, M.modelTypeCache[veh.model.key]) or
                M.modelTypeCache[veh.model.key] == M.TYPES.TRAFFIC then
                isVeh = false
            end

            if table.includes({
                    M.WALKING,
                    "roof_crush_tester"
                }, veh.model.key) then
                -- do not use
                goto skipVeh
            end

            if veh.model.aggregates.Source.Mod then
                local jbeamIO = require('jbeam/io')
                local function tryLoadVeh()
                    if not jbeamIO.getMainPartName(jbeamIO.startLoading({
                            string.var("/vehicles/{1}/", { veh.model.key }),
                            "/vehicles/common/"
                        })) then
                        error()
                    end
                end
                if not pcall(tryLoadVeh) then
                    -- vehicle lot loaded
                    goto skipVeh
                end
            end

            local target
            if isVeh then
                target = vehicles
            elseif isTraffic then
                target = traffic
            elseif veh.model.Type == M.TYPES.TRAILER then
                target = trailers
            elseif veh.model.Type == M.TYPES.PROP then
                target = props
            end
            local brandPrefix = ""
            if veh.model.Brand then
                brandPrefix = veh.model.Brand .. " "
            end
            local yearsSuffix = ""
            if veh.model.Years and veh.model.Years.min then
                yearsSuffix = string.format(" (%s)", tostring(veh.model.Years.min))
            end

            target[veh.model.key] = table.clone(veh.model)
            table.assign(target[veh.model.key], {
                label = string.format("%s%s%s", brandPrefix, veh.model.Name, yearsSuffix),
                type = veh.model.Type,
                custom = veh.model.aggregates.Source.Mod,
                paints = target[veh.model.key].paints or {},
                configs = {},
                preview = veh.model.preview,
            })

            local configs = target[veh.model.key].configs
            for key, config in pairs(veh.configs) do
                if config.key then
                    local label = (config.Configuration or config.key):gsub("_", " ")
                    if not config.key:lower():endswith("_parked") then
                        configs[key] = table.clone(config)
                        table.assign(configs[key], {
                            label = label,
                            custom = not target[veh.model.key].custom and
                                config.Source ~= "BeamNG - Official",
                            value = config.aggregates and config.aggregates.Value or nil
                        })
                    end
                end
            end
            frameSkip()
        end
        ::skipVeh::
    end
    M.allVehicleConfigs = vehicles
    M.allTrailerConfigs = trailers
    M.allPropConfigs = props
    M.allTrafficConfigs = traffic

    -- LABELS

    M.allVehicleLabels = {}
    for model, d in pairs(vehicles) do
        M.allVehicleLabels[model] = d.label or model
    end
    frameSkip()
    M.allTrailerLabels = {}
    for model, d in pairs(trailers) do
        M.allTrailerLabels[model] = d.label or model
    end
    frameSkip()
    M.allPropLabels = {}
    for model, d in pairs(props) do
        M.allPropLabels[model] = d.label or model
    end
    frameSkip()
    M.allTrafficLabels = {}
    for model, d in pairs(traffic) do
        M.allTrafficLabels[model] = d.label or model
    end

    extensions.hook("onBJVehiclesCacheUpdate")

    data.forced = nil
    -- return cached data
    return M.getAllVehicleConfigs(job, data)
end

---@param job NGJob?
---@param data {cars: boolean?, trucks: boolean?, trailers: boolean?, props: boolean?, traffic: boolean?, forced: boolean?}?
---@return table<string, string>
local function getAllVehicleLabels(job, data)
    data = data or {}
    if data.forced or not M.allVehicleConfigs then
        M.getAllVehicleConfigs(job, { forced = true })
    end
    local labels = table.clone(M.allVehicleLabels)
    if job then job.sleep(.01) end
    if data.trailers then
        for k, v in pairs(M.allTrailerLabels) do
            labels[k] = v
        end
        if job then job.sleep(.01) end
    end
    if data.props then
        for k, v in pairs(M.allPropLabels) do
            labels[k] = v
        end
        if job then job.sleep(.01) end
    end
    if data.traffic then
        for k, v in pairs(M.allTrafficLabels) do
            labels[k] = v
        end
        if job then job.sleep(.01) end
    end
    return labels
end

---@param model? string
---@param withTechName? boolean
---@return string
local function getModelLabel(model, withTechName)
    model = model or M.getCurrentModel()
    if type(model) ~= "string" then
        return "?"
    end

    if not M.allVehicleConfigs then
        M.getAllVehicleConfigs()
    end

    local label
    if M.allVehicleLabels[model] then
        label = M.allVehicleLabels[model]
    elseif M.allTrailerLabels[model] then
        label = M.allTrailerLabels[model]
    elseif M.allPropLabels[model] then
        label = M.allPropLabels[model]
    elseif M.allTrafficLabels[model] then
        label = M.allTrafficLabels[model]
    end
    if label == model then
        return model
    elseif not withTechName then
        return label or "?"
    else
        return string.var("{1} - {2}", { model, label or "?" })
    end
end

---@param model string
---@param configKey string
---@return string
local function getConfigLabel(model, configKey)
    if type(model) ~= "string" or type(configKey) ~= "string" then
        return "?"
    end

    local modelData = M.getAllVehicleConfigs(nil,
        { trailers = true, props = true, traffic = true })[model] or {}
    return (modelData.configs and modelData.configs[configKey]) and
        modelData.configs[configKey].label or "?"
end

---@return BJVehicle?
local function getCurrent()
    local current = be:getPlayerVehicle(0)
    if current then
        return M.getVehicle(current:getID(), true)
    end
end

---@return BJVehicle?
local function getCurrentOwn()
    local current = getCurrent()
    return (current and current.isLocal) and current or nil
end

-- return the current vehicle model key
---@return string?
local function getCurrentModel()
    local current = getCurrent()
    return current and current.jbeam or nil
end

---@param vid integer
local function delete(vid)
    local veh = be:getObjectByID(vid)
    if veh then veh:delete() end
end

local function deleteCurrentOthersVehicle()
    ---@type NGVehicle?
    local current = be:getPlayerVehicle(0)
    if current and M.vehicles[current:getID()] and
        not M.vehicles[current:getID()].isLocal then
        M.delete(current:getID())
    end
end

local function deleteCurrentOwnVehicle()
    ---@type NGVehicle?
    local current = be:getPlayerVehicle(0)
    if current and M.vehicles[current:getID()] and
        M.vehicles[current:getID()].isLocal then
        M.delete(current:getID())
    end
end

local function deleteOtherOwnVehicles()
    local own = M.vehicles:filter(function(v)
        return v.isLocal and not v.isAi
    end):keys()
    ---@type NGVehicle?
    local current = be:getPlayerVehicle(0)
    if current then
        own = own:filter(function(v) return v ~= current:getID() end)
    end
    own:forEach(M.delete)
end

---@param vid integer
---@param state boolean?
local function setFreeze(vid, state)
    local v = M.getVehicle(vid, true)
    if v and v.isLocal then
        if state == nil then
            state = v.veh.froze ~= "1"
        end
        local finalState = state and 1 or 0
        v.veh:queueLuaCommand(string.format("controller.setFreeze(%d)", finalState))
        v.veh:setDynDataFieldbyName("froze", 0, tostring(finalState))
    end
end

---@param vid integer
---@param state boolean
local function setEngine(vid, state)
    local v = M.getVehicle(vid, true)
    if v and v.isLocal then
        if state == nil then
            state = v.veh.shut == "1"
        end
        if state then
            v.veh:queueLuaCommand('controller.mainController.setStarter(true)')
        end
        v.veh:queueLuaCommand(string.format(
            "if controller.mainController.setEngineIgnition then controller.mainController.setEngineIgnition(%s) end",
            tostring(state)
        ))
        local wasForceShut = v.veh.shut == "1"
        v.veh:setDynDataFieldbyName("shut", 0, state and "0" or "1")
        if state and wasForceShut then
            core_jobsystem.create(function(job)
                job.sleep(1)
                v.veh:queueLuaCommand('controller.mainController.setStarter(true)')
            end)
        end
    end
end

---@param vid integer
---@param state boolean
---@param allLights boolean?
local function setLights(vid, state, allLights)
    local v = M.getVehicle(vid, true)
    if v and v.isLocal then
        local finalState = state == true and 1 or 0

        if finalState == 1 then
            v.veh:queueLuaCommand("electrics.setLightsState(1)")
            v.veh:queueLuaCommand("electrics.setLightsState(2)")
        else
            v.veh:queueLuaCommand("electrics.setLightsState(0)")
            if allLights then
                v.veh:queueLuaCommand(string.var("electrics.set_warn_signal({1})", { finalState }))
                v.veh:queueLuaCommand(string.var("electrics.set_lightbar_signal({1})", { finalState }))
                v.veh:queueLuaCommand(string.var("electrics.set_fog_lights({1})", { finalState }))
            end
        end
    end
end

local function focusVehicle(vid)
    local mpVeh = M.vehicles[vid]
    if mpVeh then
        be:enterVehicle(0, mpVeh.veh)
        if camera.getCamera() == camera.CAMERAS.FREE then
            camera.toggleFreeCam()
        end
    end
end

---@param jbeam string
---@return string
local function getLabelByModel(jbeam)
    if not M.allVehicleLabels then
        -- TODO optimization
        return jbeam
    end

    return M.allVehicleLabels[jbeam] or
        M.allTrailerLabels[jbeam] or
        M.allPropLabels[jbeam] or
        jbeam
end

---@param callback fun(mpVeh: BJVehicle)
local function waitForSpawn(callback)
    core_jobsystem.create(function(job)
        job.sleep(.2)
        local timeout = GetCurrentTimeMillis() + 20000

        local mpVeh = M.getCurrent()
        while ui_imgui.GetIO().Framerate < 5 or not mpVeh or
            not mpVeh.veh.damages or tonumber(mpVeh.veh.damages) > 100 do
            job.sleep(.01)
            mpVeh = mpVeh or M.getCurrent()
            if GetCurrentTimeMillis() >= timeout then
                LogError("waitForSpawn timed out")
                return
            end
        end

        callback(mpVeh)
    end)
end

---@param key string
---@param vid integer
---@param value any
local function updateVehAttribute(key, vid, value)
    if M.vehicles[vid] then
        M.vehicles[vid].veh:setDynDataFieldbyName(key, 0, tostring(value))
    end
end

---@param remoteVID integer
local function explode(remoteVID)
    local mpVeh = M.vehicles:find(function(v) return v.remoteVID == remoteVID end)
    if mpVeh then
        if mpVeh.isLocal then
            mpVeh.veh:applyClusterVelocityScaleAdd(mpVeh.veh:getRefNodeId(), 1, 0, 0, 3)
            core_jobsystem.create(function(job)
                job.sleep(.2)
                if M.vehicles[mpVeh.vid] then
                    mpVeh.veh:queueLuaCommand("beamstate.breakAllBreakgroups()")
                end
            end)
        end
        mpVeh.veh:queueLuaCommand("fire.explodeVehicle()")
    end
end

local function switchToNextVehicle()
    be:enterNextVehicle(0, 1)
end

---@param veh NGVehicle
---@param state boolean
---@param force boolean?
local function setGhost(veh, state, force)
    if (veh.ghost == "1") == state then return end
    local mpVeh = M.vehicles[veh:getID()]
    local processName = "ghostRecover-" .. tostring(veh:getID())
    if mpVeh and mpVeh.isLocal and not state and not force then
        local p1 = M.getVehiclePositionRotation(veh)
        local r1 = veh:getInitialLength() / 2
        if M.vehicles:any(function(v)
                if v.vid == veh:getID() or v.veh.ghost == "1" then return false end
                local p2 = M.getVehiclePositionRotation(v.veh)
                local r2 = v.veh:getInitialLength() / 2
                return p1:distance(p2) < r1 + r2
            end) then
            async.removeTask(processName)
            async.delayTask(function() setGhost(veh, false) end, 200, processName)
            return
        end
    end
    async.removeTask(processName)
    veh:queueLuaCommand("obj:setGhostEnabled(" .. tostring(state) .. ")")
    veh:setDynDataFieldbyName("ghost", 0, state and "1" or "0")
    local currentVeh = M.getCurrent()
    if not currentVeh or currentVeh.vid ~= veh:getID() then
        extensions.core_vehicle_partmgmt.setHighlightedPartsVisiblity(state and .5 or 1, veh:getID())
    else
        -- current veh is toggling
        beamjoy_communications_ui.send("BJHUDIcon", {
            pos = 3,
            state = state,
            name = "ghost",
        })
    end
    if mpVeh and mpVeh.isLocal then
        beamjoy_communications.send("updateVehicleGhost", mpVeh.vid, state)
    end
end

---@param vid integer
---@return integer[] VIDs
local function getAttachedTrailers(vid)
    local mpVeh = M.vehicles[vid]
    if not mpVeh then return {} end
    local res = {}
    local function _processAttached(vehData, level)
        level = level or 1
        if level > 10 then return end
        if vehData.vehId ~= vid and
            not table.includes(res, vehData.vehId) then
            table.insert(res, vehData.vehId)
        end
        if vehData.children and #vehData.children > 0 then
            for _, c in ipairs(vehData.children) do
                _processAttached(c, level + 1)
            end
        end
    end
    _processAttached(core_vehicles.generateAttachedVehiclesTree(vid))
    return res
end

-- config is optionnal
---@param veh NGVehicle
---@return boolean
local function isConfigCustom(veh)
    return not veh.partConfig:endswith(".pc")
end

---@param tree table
---@return table<string, string>
local function convertPartsTree(tree)
    local parts = {}
    local function recursParts(data)
        if not data then return end
        for k, v in pairs(data) do
            if v.chosenPartName then
                parts[k] = v.chosenPartName
            end
            if v.children then
                recursParts(v.children)
            end
        end
    end
    recursParts(tree.children)
    return parts
end

--- return the full config raw data
---@param veh NGVehicle
---@return ClientVehicleConfig?
local function getFullConfig(veh)
    local rawConfig = extensions.core_vehicle_manager.getVehicleData(veh:getID())
    if not rawConfig or not rawConfig.config or not rawConfig.config.partsTree then return end

    local model = rawConfig.config.model
    local isCustom = isConfigCustom(veh)
    local key = not isCustom and tostring(rawConfig.config.partConfigFilename)
        :gsub("^vehicles/.*/", ""):gsub("%.pc$", "") or nil

    local modelLabel = M.getModelLabel(model)
    local label = (not isCustom and key) and
        string.var("{1} {2}", { modelLabel, M.getConfigLabel(model, key) }) or modelLabel
    return {
        model = model,
        label = label,
        key = key,
        parts = convertPartsTree(rawConfig.config.partsTree),
        vars = rawConfig.config.vars,
        paints = rawConfig.config.paints,
    }
end

---@param mpVeh BJVehicle
---@return boolean
local function isPolice(mpVeh)
    local policeMarkers = Table({ "police", "polizei", "polizia", "gendarmerie" })
    local conf = M.getFullConfig(mpVeh.veh)
    if not conf then return false end
    return policeMarkers:any(function(str) return conf.model:lower():find(str) ~= nil end) or
        Table(conf.parts):any(function(v, k)
            return policeMarkers:any(function(str)
                return (tostring(k):lower():find(str) ~= nil and #v > 0) or
                    tostring(v):lower():find(str) ~= nil
            end)
        end)
end

---@param veh NGVehicle
---@return NGPaint[]
local function getAllPaints(veh)
    local model = M.getAllVehicleConfigs(nil,
        {
            cars = true,
            trucks = true,
            trailers = true,
            props = true,
            traffic = true
        })[veh.jbeam]
    return model and model.paints or {}
end

---@param veh NGVehicle
---@param paintData NGPaint[] max 3 indices
local function paint(veh, paintData)
    for i = 1, 3 do
        if paintData[i] then
            extensions.core_vehicle_manager.liveUpdateVehicleColors(
                veh:getID(), veh, i, paintData[i])
        end
    end
end

M.onInit = onInit
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onSlowUpdate = onSlowUpdate
M.onServerTick = onServerTick
M.onVehicleResetted = onVehicleResetted
M.onBJRequestCanSpawnVehicle = onBJRequestCanSpawnVehicle
M.onBJVehicleModChanged = onBJVehicleModChanged

M.getVehicle = getVehicle
M.getType = getType
M.getVehicleByRemoteID = getVehicleByRemoteID
M.getVehiclePositionRotation = getVehiclePositionRotation
M.setVehiclePositionRotation = setVehiclePositionRotation
M.getAllVehicleConfigs = getAllVehicleConfigs
M.getAllVehicleLabels = getAllVehicleLabels
M.getModelLabel = getModelLabel
M.getConfigLabel = getConfigLabel
M.getCurrent = getCurrent
M.getCurrentOwn = getCurrentOwn
M.getCurrentModel = getCurrentModel
M.delete = delete
M.deleteCurrentOthersVehicle = deleteCurrentOthersVehicle
M.deleteCurrentOwnVehicle = deleteCurrentOwnVehicle
M.deleteOtherOwnVehicles = deleteOtherOwnVehicles
M.setFreeze = setFreeze
M.setEngine = setEngine
M.setLights = setLights
M.focusVehicle = focusVehicle
M.getLabelByModel = getLabelByModel
M.waitForSpawn = waitForSpawn
M.updateVehAttribute = updateVehAttribute
M.explode = explode
M.switchToNextVehicle = switchToNextVehicle
M.setGhost = setGhost
M.getAttachedTrailers = getAttachedTrailers
M.getFullConfig = getFullConfig
M.isPolice = isPolice
M.getAllPaints = getAllPaints
M.paint = paint

return M
