--- Using the interactive buttons on other players' cars : door handles, the hood and trunk, light
--- switches, the horn, every trigger the game lets you aim at and click on a car (its own crosshair,
--- labels and keys, core/vehicleTriggers.lua).
---
--- In plain BeamMP a click on someone else's car runs on this client's own copy of it and goes
--- nowhere (BeamMP even blocks latches on those copies). So a click on another player's car is
--- taken before the game runs it and sent to the server instead (services/vehicleInteractions.lua),
--- which passes it to the owner : the owner's client presses that same trigger on their own car,
--- and BeamMP shows the result to everyone, this player included. A press and its release are both
--- sent, so a held button (the horn) is held as long as it is here.
---
--- Settings > Vehicle > "Lock my vehicles" : nobody but your crew can use your cars' buttons.

local M = {
    -- m/s : the owner's own check, BeamMP's copy of the speed on the server lags behind
    MAX_SPEED = 2,
    -- a press the owner never got the release of (the requester left, a lost message) is let go
    -- after this
    HOLD_TIMEOUT_MS = 5000,
    locked = false,
    --- this player's presses on other cars, by action number, until released
    ---@type table<integer, {serverVID: string, t: integer, hit: table}>
    held = {},
    --- presses on this player's own cars from others, until released : key -> data
    ---@type table<string, {vid: integer, t: integer, actionNumber: integer, until: integer}>
    pressed = {},
    ---@type function? the game's own onActionEvent, while ours stands in
    originalOnActionEvent = nil,
}

---@return table?
local function triggers()
    return extensions.core_vehicleTriggers
end

---@param vid integer
---@return table? vdata
local function vehicleData(vid)
    local manager = extensions.core_vehicle_manager
    local data = manager and manager.getVehicleData(vid)
    return data and data.vdata or nil
end

---@param vid integer
---@param t any
---@return boolean
local function hasTrigger(vid, t)
    local vdata = vehicleData(vid)
    return vdata ~= nil and type(vdata.triggers) == "table" and vdata.triggers[t] ~= nil
end

--- BeamMP's full id for a vehicle, "<ownerID>-<vehicleID>" : BJVehicle.serverVID is only the
--- vehicle part (each player numbers their own vehicles from 0), so on its own it doesn't say whose
--- car it is
---@param mpVeh BJVehicle
---@return string?
local function serverKey(mpVeh)
    if not mpVeh or mpVeh.ownerID == nil or mpVeh.serverVID == nil then return nil end
    local vid = tostring(mpVeh.serverVID)
    if vid:find("-", 1, true) then return vid end
    return string.format("%s-%s", tostring(mpVeh.ownerID), vid)
end

---@param vid integer
---@return BJVehicle? another player's car (not traffic, not someone walking)
local function remoteCar(vid)
    local mpVeh = beamjoy_vehicles.vehicles[vid]
    if not mpVeh or mpVeh.isLocal or mpVeh.isAi or mpVeh.jbeam == beamjoy_vehicles.WALKING then
        return nil
    end
    return mpVeh
end

---@param serverVID string
---@param t any
---@param actionNumber integer
---@param value number
local function sendRequest(serverVID, t, actionNumber, value)
    local own = beamjoy_vehicles.getCurrentOwn()
    beamjoy_communications.send("vehicleTriggerRequest", serverVID, t, actionNumber, value,
        own and serverKey(own) or nil)
end

--- stands in for core_vehicleTriggers.onActionEvent (the triggerAction0-2 keys) : a click on
--- another player's car goes to its owner, anything else to the game as usual
---@param actionNumber integer
---@param inputValue number
---@return boolean?
local function onActionEvent(actionNumber, inputValue)
    local vt = triggers()
    local original = M.originalOnActionEvent
    local held = M.held[actionNumber]
    if held then
        -- the release of a press sent to an owner (or a new press before it, which ends it too)
        M.held[actionNumber] = nil
        sendRequest(held.serverVID, held.t, actionNumber, 0)
        if vt and vt.state.currentlyUsedTrigger == held.hit then
            vt.state.currentlyUsedTrigger = nil
        end
        if inputValue == 0 then return true end
    end
    if inputValue ~= 0 and vt and vt.isEnabled() then
        local hit = be:triggerRaycastClosest(vt.getTriggerRaycastDistance(), vt.state.useCursorCoordinates)
        local mpVeh = hit and hit.v and hit.t ~= nil and remoteCar(hit.v)
        local key = mpVeh and serverKey(mpVeh)
        if key and hasTrigger(hit.v, hit.t) then
            sendRequest(key, hit.t, actionNumber, inputValue)
            M.held[actionNumber] = { serverVID = key, t = hit.t, hit = hit }
            -- the game's own highlight on the trigger while it's held
            vt.state.currentlyUsedTrigger = hit
            return true
        end
    end
    if original then return original(actionNumber, inputValue) end
end

local function install()
    local vt = triggers()
    if not vt or vt.onActionEvent == onActionEvent then return end
    M.originalOnActionEvent = vt.onActionEvent
    vt.onActionEvent = onActionEvent
end

local function uninstall()
    local vt = triggers()
    if vt and vt.onActionEvent == onActionEvent and M.originalOnActionEvent then
        vt.onActionEvent = M.originalOnActionEvent
    end
    M.originalOnActionEvent = nil
end

---@param vid integer
---@param t any
---@param actionNumber integer
---@param value number
local function press(vid, t, actionNumber, value)
    local vt = triggers()
    local vdata = vehicleData(vid)
    if not vt or not vdata then return end
    local ok, err = pcall(vt.triggerEvent, "action" .. tostring(actionNumber), value, t, vid, vdata)
    if not ok then LogError("beamjoy_vehicleInteractions: trigger failed: " .. tostring(err)) end
end

--- the owner's side : another player clicked a trigger on one of this player's cars
---@param serverVID string
---@param t any
---@param actionNumber integer
---@param value number
---@param requesterName string
local function onVehicleTrigger(serverVID, t, actionNumber, value, requesterName)
    actionNumber, value = tonumber(actionNumber), tonumber(value)
    if not actionNumber or not value then return end
    local mpVeh = beamjoy_vehicles.vehicles:find(function(v)
        return v.isLocal and serverKey(v) == serverVID
    end)
    if not mpVeh or not mpVeh.veh or not hasTrigger(mpVeh.vid, t) then return end
    local key = string.format("%s:%s:%s:%d", tostring(requesterName), mpVeh.vid, tostring(t), actionNumber)

    if value == 0 then
        -- only the release of a press that went through
        if M.pressed[key] then
            M.pressed[key] = nil
            press(mpVeh.vid, t, actionNumber, 0)
        end
        return
    end
    -- the server checks the lock too, but a lock set a moment ago may not have reached it yet
    if M.locked and not (beamjoy_crews and beamjoy_crews.crew and type(beamjoy_crews.crew.members) == "table" and
            table.find(beamjoy_crews.crew.members, function(m) return m.playerName == requesterName end)) then
        return
    end
    if mpVeh.veh:getVelocity():length() > M.MAX_SPEED then return end
    M.pressed[key] = { vid = mpVeh.vid, t = t, actionNumber = actionNumber,
        ["until"] = GetCurrentTimeMillis() + M.HOLD_TIMEOUT_MS }
    press(mpVeh.vid, t, actionNumber, value)
end

local function sendLocked()
    beamjoy_communications.send("vehicleLocked", M.locked)
end

local function onSlowUpdate()
    -- the game reloads its extensions now and then (a Lua reload) : stand in again
    install()
    local now = GetCurrentTimeMillis()
    for key, p in pairs(M.pressed) do
        if now >= p["until"] then
            M.pressed[key] = nil
            press(p.vid, p.t, p.actionNumber, 0)
        end
    end
end

local function onInit()
    M.locked = localStorage.get(localStorage.GLOBAL_VALUES.LOCK_VEHICLES) == true
    install()
    beamjoy_communications.addHandler("vehicleTrigger", onVehicleTrigger)
    beamjoy_communications_ui.addHandler("BJUserSettings", function(newSettings)
        local locked = type(newSettings) == "table" and type(newSettings.vehicle) == "table" and
            newSettings.vehicle.lockVehicles
        if type(locked) ~= "boolean" or locked == M.locked then return end
        M.locked = locked
        localStorage.set(localStorage.GLOBAL_VALUES.LOCK_VEHICLES, locked)
        sendLocked()
    end)
end

local function onExtensionUnloaded()
    uninstall()
end

M.onInit = onInit
M.onBJClientReady = sendLocked
M.onSlowUpdate = onSlowUpdate
M.onExtensionUnloaded = onExtensionUnloaded
M.onPreExit = onExtensionUnloaded

return M
