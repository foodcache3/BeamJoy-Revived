local M = {
    dawn = .77,
    dusk = .23,

    ---@type table<integer, true> index vid
    processed = {},
}

--- Updates traffic vehicles lights
---@param ToD number? 0-1
local function updateTrafficLights(ToD)
    ToD = ToD or extensions.core_environment.getTimeOfDay().time

    beamjoy_vehicles.vehicles:filter(function(v) ---@param v BJVehicle
        return v.isLocal and v.isAi
    end):forEach(function(v) ---@param v BJVehicle
        beamjoy_vehicles.setLights(v.vid, ToD >= M.dusk and ToD < M.dawn)
    end)
end

---@param mpVeh BJVehicle
---@param ToD number? 0-1
local function update(mpVeh, ToD)
    ToD = ToD or extensions.core_environment.getTimeOfDay().time

    if not M.processed[mpVeh.vid] then
        beamjoy_vehicles.setLights(mpVeh.vid, ToD >= M.dusk and ToD < M.dawn)
        M.processed[mpVeh.vid] = true
    end
end

local function onInit()
    beamjoy_communications_ui.addHandler("BJUserSettings", function(newSettings)
        localStorage.set(localStorage.GLOBAL_VALUES.AUTOMATIC_LIGHTS,
            newSettings.vehicle.automaticLights)
        if newSettings.vehicle.automaticLights then
            local mpVeh = beamjoy_vehicles.getCurrent()
            if mpVeh and mpVeh.isLocal then
                update(mpVeh)
            end
        else
            table.clear(M.processed)
        end
    end)
end

local previousToD
local function onServerTick()
    local ToD = extensions.core_environment.getTimeOfDay()
    if not ToD then return end

    if previousToD then
        local wasNight = previousToD >= M.dusk and previousToD < M.dawn
        local isNight = ToD.time >= M.dusk and ToD.time < M.dawn
        if wasNight ~= isNight then
            if localStorage.get(localStorage.GLOBAL_VALUES.AUTOMATIC_LIGHTS) then
                table.clear(M.processed)
                local mpVeh = beamjoy_vehicles.getCurrent()
                if mpVeh and mpVeh.isLocal then
                    update(mpVeh, ToD.time)
                end
            end
            updateTrafficLights(ToD.time)
        end
    end

    previousToD = ToD.time
end

local function onBJVehicleInstantiated(vid)
    if localStorage.get(localStorage.GLOBAL_VALUES.AUTOMATIC_LIGHTS) then
        local mpVeh = beamjoy_vehicles.vehicles[vid]
        if mpVeh and mpVeh.isLocal then
            update(mpVeh)
        end
    end
end

local function onVehicleSwitched(previousVID, newVID)
    if localStorage.get(localStorage.GLOBAL_VALUES.AUTOMATIC_LIGHTS) then
        -- does not shut previous vehicle lights
        if newVID ~= -1 then
            local mpVeh = beamjoy_vehicles.vehicles[newVID]
            if mpVeh and mpVeh.isLocal then
                update(mpVeh)
            end
        end
    end
end

M.onInit = onInit
M.onServerTick = onServerTick
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onVehicleSwitched = onVehicleSwitched
M.onBJTrafficUpdated = updateTrafficLights

return M
