local M = {
    interval = {
        min = 60 * 2 * 1000, -- 2 minutes
        max = 60 * 5 * 1000, -- 5 minutes
    },

    ---@type table<integer, string> index vid, value label
    fugitives = {},
    --- is current vehicle own and police
    isPolice = false,
    arrest = {
        maxDistanceTrigger = 5,
        maxSpeedBlock = 2,
        maxDistanceBlock = 1,
        durationBlock = 5,

        ---@type number? 0-N
        duration = nil,
        ---@type vec3?
        lastPos = nil,
        ---@type BJVehicle?
        target = nil,
    },
}

--- Real, confirmed annoyance (direct report): "pursuit tick shouldn't apply to parked vehicles."
--- Parked traffic is still `isAi`, so the target filter below happily picked a car sat in a parking
--- space and started a pursuit against something that was never driving anywhere. Two sources,
--- because the two spawners are separate: BJS's own parked pool (beamjoy_traffic.parkedVehs, the
--- cars this client spawned into parking spots - see traffic.lua's own updateParkedVehs) and
--- native's (gameplay_parking's own list, which also covers a level's pre-placed parked cars).
--- Both are plain vid lists.
---@param v BJVehicle
---@return boolean
local function isParked(v)
    if not v or not v.vid then return true end
    local bjParked = beamjoy_traffic and beamjoy_traffic.parkedVehs
    if bjParked and bjParked.includes and bjParked:includes(v.vid) then return true end
    local parking = extensions.gameplay_parking
    if parking and parking.getParkedCarsList then
        local ok, list = pcall(parking.getParkedCarsList)
        if ok and type(list) == "table" and table.includes(list, v.vid) then return true end
    end
    return false
end

-- Tick to find a fugitive to start a pursuit<br/>
-- Can only be an owned traffic vehicle otherwise the pursuit<br/>
-- behavior is dumb (drive into walls and vehicles) :/
local function tick()
    if beamjoy_traffic.data.enabled then
        LogDebug("Pursuit tick")
        local mpVeh = beamjoy_vehicles.getCurrent()
        if mpVeh and M.isPolice then
            local pos = beamjoy_vehicles.getVehiclePositionRotation(mpVeh.veh)

            if table.length(M.fugitives) == 0 or not table.any(M.fugitives, function(_, fugitiveVID)
                    ---@type BJVehicle?
                    local v = beamjoy_vehicles.vehicles[fugitiveVID]
                    if not v or not v.isAi then return false end
                    local vPos = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
                    local _, maxDist = beamjoy_traffic.getMinMaxDistFromPlayer(tonumber(v.veh.speed) or 0)
                    return pos:distance(vPos) < maxDist
                end) then
                ---@type BJVehicle?
                local target = beamjoy_vehicles.vehicles:filter(function(v)
                    if not v.isAi then return false end
                    if isParked(v) then return false end -- see isParked's own comment
                    if not v.isLocal and
                        mpVeh.vid ~= beamjoy_players.players[v.ownerName].currentVehicle then
                        -- owner is not close => pursuit behavior would be dumb
                        return false
                    end
                    local vPos = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
                    local minDist = beamjoy_traffic.getMinMaxDistFromPlayer(tonumber(v.veh.speed) or 0)
                    return pos:distance(vPos) < minDist
                end):random()
                if target then
                    beamjoy_communications.send("pursuitStart", target.remoteVID, mpVeh.vid)
                end
            end
        end
    end
    async.delayTask(tick, math.random(M.interval.min, M.interval.max))
end

local function onInit()
    tick()

    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications.addHandler("pursuitStart", M.startPursuit)
    beamjoy_communications.addHandler("pursuitStop", M.stopPursuit)
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    local current = beamjoy_vehicles.getCurrent()
    ---@type BJVehicle?
    local mpVeh = beamjoy_vehicles.vehicles[vid]
    if current ~= nil and mpVeh ~= nil and
        current == mpVeh then
        M.isPolice = mpVeh.isLocal and
            beamjoy_vehicles.isPolice(mpVeh)
    end
end

local function onVehicleSwitched(_, newVID)
    ---@type BJVehicle?
    local mpVeh = beamjoy_vehicles.vehicles[newVID]
    M.isPolice = mpVeh ~= nil and mpVeh.isLocal and
        beamjoy_vehicles.isPolice(mpVeh)
end

---@param vid integer
local function onBJTrafficVehicleDeleted(vid)
    if M.fugitives[vid] then
        beamjoy_communications.send("pursuitStop", vid, 2)
    end
end

---@param veh NGVehicle
local function onBJTrafficVehicleResetted(veh)
    if M.fugitives[veh:getID()] then
        beamjoy_communications.send("pursuitStop", veh:getID(), 0)
    end
end
local resetArrestation = function()
    M.arrest.duration = nil
    M.arrest.target = nil
    M.arrest.lastPos = nil
end

local function onServerTick()
    if not M.isPolice or table.length(M.fugitives) == 0 then return end
    local veh = beamjoy_vehicles.getCurrent()
    if not veh then return end

    if not M.arrest.target then
        local pos = beamjoy_vehicles.getVehiclePositionRotation(veh.veh)
        local radius = veh.veh:getInitialLength() / 2
        local fPos
        table.map(M.fugitives, function(_, vid)
            return beamjoy_vehicles.vehicles[vid]
        end):values():find(function(v) ---@param v BJVehicle
            local speed = tonumber(v.veh.speed)
            if not speed or speed > M.arrest.maxSpeedBlock then return false end
            fPos = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
            local fRadius = v.veh:getInitialLength() / 2
            return pos:distance(fPos) - (radius + fRadius) < M.arrest.maxDistanceTrigger
        end, function(target)
            M.arrest.target = target
            M.arrest.duration = M.arrest.durationBlock
            M.arrest.lastPos = fPos
            beamjoy_communications_ui.uiBroadcast("beamjoy.pursuit.arrestIn",
                { time = math.round(M.arrest.duration) }, nil, 1.2)
        end)
    else
        if not beamjoy_vehicles.vehicles[M.arrest.target.vid] then
            -- target is now invalid
            return resetArrestation()
        end
        local speed = tonumber(M.arrest.target.veh.speed)
        if not speed or speed > M.arrest.maxSpeedBlock then
            return resetArrestation()
        end
        local fPos = beamjoy_vehicles.getVehiclePositionRotation(M.arrest.target.veh)
        if M.arrest.lastPos:distance(fPos) > M.arrest.maxDistanceBlock then
            return resetArrestation()
        end
        local pos = beamjoy_vehicles.getVehiclePositionRotation(veh.veh)
        local radius = veh.veh:getInitialLength() / 2
        local fRadius = M.arrest.target.veh:getInitialLength() / 2
        if pos:distance(fPos) - (radius + fRadius) >= M.arrest.maxDistanceTrigger then
            return resetArrestation()
        end
        if M.arrest.duration > 0 then
            if not simTimeAuthority.getPause() then
                M.arrest.duration = M.arrest.duration - simTimeAuthority.get()
            end
            if M.arrest.duration <= 0 then
                -- arrestation succeed
                beamjoy_communications.send("pursuitStop", M.arrest.target.remoteVID, 1)
            elseif math.round(M.arrest.duration) > 0 then
                beamjoy_communications_ui.uiBroadcast("beamjoy.pursuit.arrestIn",
                    { time = math.round(M.arrest.duration) }, nil, 1.2)
            end
        end
    end
end

---@param caches table
local function retrieveCache(caches)
    if caches.pursuitFugitives then
        local previousFugitivesLength = table.length(M.fugitives)
        local newVIDs = table.map(caches.pursuitFugitives, function(remoteVID)
            ---@param v BJVehicle
            local mpVeh = beamjoy_vehicles.vehicles:find(function(v)
                return v.remoteVID == remoteVID
            end)
            return mpVeh and mpVeh.vid or nil
        end)
        -- remove obsolete fugitives
        table.forEach(M.fugitives, function(_, vid)
            if not table.includes(newVIDs, vid) then
                M.fugitives[vid] = nil
            end
        end)
        -- add new labels
        table.forEach(newVIDs, function(vid)
            if not M.fugitives[vid] then
                local mpVeh = beamjoy_vehicles.vehicles[vid]
                if not mpVeh then return end
                local fullConfig = beamjoy_vehicles.getFullConfig(mpVeh.veh)
                if not fullConfig then return end
                if fullConfig.key then
                    M.fugitives[vid] = beamjoy_vehicles.getConfigLabel(fullConfig.model, fullConfig.key)
                else
                    M.fugitives[vid] = beamjoy_vehicles.getModelLabel(fullConfig.model)
                end
            end
        end)
        if M.isPolice and previousFugitivesLength > 0 and table.length(M.fugitives) == 0 then
            local current = beamjoy_vehicles.getCurrent()
            if current then
                -- stop siren and lights
                current.veh:queueLuaCommand('electrics.set_lightbar_signal(0)')
            end
        end
    end
end

---@param fugitiveRemoteVID integer
---@param policeRemoteVID integer
local function startPursuit(fugitiveRemoteVID, policeRemoteVID)
    beamjoy_vehicles.vehicles:find(function(v)
        return v.remoteVID == fugitiveRemoteVID
    end, function(v) ---@param v BJVehicle
        async.task(function()
            return M.fugitives[v.vid] ~= nil
        end, function()
            -- show fugitive on minimap
            v.veh.uiState = 1
            if v.isLocal then
                v.veh:queueLuaCommand([[
                    ai.setMode("flee");
                    ai.driveInLane("off");
                    ai.setSpeedMode("off");
                ]])
                beamjoy_vehicles.vehicles:find(function(v2)
                    return v2.remoteVID == policeRemoteVID
                end, function(policeVeh)
                    policeVeh.veh:queueLuaCommand("ai.setTargetObjectID(" ..
                        tostring(policeVeh.vid) .. ")")
                end)
            end
            if M.isPolice then
                local current = beamjoy_vehicles.getCurrent()
                if not current then return end
                local pos = beamjoy_vehicles.getVehiclePositionRotation(current.veh)
                local fPos = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
                local _, maxDist = beamjoy_traffic.getMinMaxDistFromPlayer(tonumber(v.veh.speed) or 0)
                if pos:distance(fPos) < maxDist then
                    if extensions.gameplay_traffic.showMessages then
                        ui_message(string.var("{1} {2}", {
                            translateLanguage('ui.traffic.suspectFlee',
                                'A suspect is fleeing from you! Vehicle:'),
                            M.fugitives[v.vid],
                        }), 5, 'traffic', 'traffic')
                    end
                    if localStorage.get(localStorage.GLOBAL_VALUES.AUTOMATIC_LIGHTS) then
                        -- auto enable siren and lights
                        current.veh:queueLuaCommand('electrics.set_lightbar_signal(2)')
                    end
                end
            end
        end)
    end)
end

---@param remoteVID integer
---@param caught boolean
local function stopPursuit(remoteVID, caught)
    beamjoy_vehicles.vehicles:find(function(v)
        return v.remoteVID == remoteVID
    end, function(v) ---@param v BJVehicle
        -- hide fugitive on minimap
        v.veh.uiState = 0
        if v.isLocal then
            if caught then
                local vid = v.vid
                async.delayTask(function()
                    beamjoy_traffic.markForRespawn(vid)
                end, 5000)
            end
            v.veh:queueLuaCommand([[
                ai.setMode("stop")
                ai.setTargetObjectID(-1)
                ai.driveInLane("on")
                ai.setSpeedMode("legal")
            ]])
        end
        if M.isPolice then
            if extensions.gameplay_traffic.showMessages then
                ui_message(caught and 'ui.traffic.suspectArrest' or
                    'ui.traffic.suspectEvade', 5, 'traffic', 'traffic')
            end
            if M.arrest.target and M.arrest.target.vid == v.vid then
                resetArrestation()
                beamjoy_communications_ui.uiBroadcast('ui.traffic.suspectArrest',
                    nil, nil, 3)
            end
        end
    end)
end

M.onInit = onInit
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onVehicleSwitched = onVehicleSwitched
M.onBJTrafficVehicleDeleted = onBJTrafficVehicleDeleted
M.onBJTrafficVehicleResetted = onBJTrafficVehicleResetted
M.onServerTick = onServerTick

M.retrieveCache = retrieveCache
M.startPursuit = startPursuit
M.stopPursuit = stopPursuit

return M
