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
---
--- Latch state for late joiners : BeamMP sends a door opening or closing as it happens, never the
--- state itself, so a car that appears on this client later (joining, the car spawning in) showed
--- every door closed. This client reports its own cars' unlatched groups (doors, hood, trunk...)
--- to the server when they change (services/vehicleInteractions.lua keeps them), and applies the
--- stored ones to another player's car when it appears here, through BeamMP's own couplerVE (it
--- knows how to move a latch on a remote copy). Live changes stay BeamMP's own sync.

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

    -- how often this client checks its own cars' latches
    LATCH_POLL_MS = 2000,
    -- a car that just appeared settles (and latches its doors) before the stored state is applied
    LATCH_APPLY_DELAY_MS = 2000,
    -- how long a car that just appeared waits for its state (the join cache may come after it)
    LATCH_APPLY_WAIT_MS = 10000,
    --- serverVID -> { group -> state } : everyone's cars, as the server keeps them
    ---@type table<string, table<string, string>>
    latches = {},
    --- this client's own cars : vid -> what was last reported (a stable string of it)
    ---@type table<integer, string>
    reportedLatches = {},
    --- this client's own cars : vid -> what the last poll found (a stable string of it)
    ---@type table<integer, string>
    polledLatches = {},
    --- other players' cars that just appeared : vid -> { at, untilMs }
    ---@type table<integer, {at: integer, untilMs: integer}>
    pendingLatches = {},
    --- other players' cars the stored state was applied to (since they appeared) : vid -> true
    ---@type table<integer, true>
    appliedLatches = {},
    lastLatchPoll = 0,
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

-- LATCH STATE ------------------------------------------------------------------------------------

---@param latches table<string, string>?
---@return string a stable form to compare reports with
local function latchSignature(latches)
    local keys = {}
    for name, state in pairs(latches or {}) do keys[#keys + 1] = name .. "=" .. state end
    table.sort(keys)
    return table.concat(keys, ";")
end

--- the vehicle side of a poll : its unlatched groups, back to onLatchReport. Real bug (direct
--- report: door sync for late joiners worked once, then never) : an open door is only "detached"
--- for a moment. Once it swings away from the frame the game arms its latch again
--- (advancedCouplerControl's auto latch), and it stays "autoCoupling" for as long as it's open. That
--- state used to count as "still moving" and skip the whole report, so an open door was only
--- reported when a poll happened to land in that first moment. Anything not latched is open now
--- ("broken" kept apart) ; a door swinging shut is caught by onLatchReport's two-poll rule instead
local LATCH_QUERY = [[
local out = {}
for _, c in pairs(controller.getControllersByType("advancedCouplerControl") or {}) do
    local ok, state = pcall(c.getGroupState)
    if ok and type(state) == "string" and state ~= "attached" and state ~= "desyncedAttached" then
        out[c.name] = state == "broken" and "broken" or "detached"
    end
end
obj:queueGameEngineLua("if beamjoy_vehicleInteractions then beamjoy_vehicleInteractions.onLatchReport("
    .. obj:getId() .. ", " .. serialize(out) .. ") end")
]]

--- this client's own cars (not traffic, not someone walking)
local function pollOwnLatches()
    for vid, mpVeh in pairs(beamjoy_vehicles.vehicles) do
        if mpVeh.isLocal and not mpVeh.isAi and mpVeh.veh and mpVeh.jbeam ~= beamjoy_vehicles.WALKING then
            mpVeh.veh:queueLuaCommand(LATCH_QUERY)
        end
    end
end

---@param vid integer
---@param latches table<string, string>
local function onLatchReport(vid, latches)
    local mpVeh = beamjoy_vehicles.vehicles[vid]
    local key = mpVeh and mpVeh.isLocal and serverKey(mpVeh)
    if not key then return end
    local signature = latchSignature(latches)
    -- only a state seen on two polls in a row : a door swinging shut, or a car latching its doors
    -- as it spawns, is open for a moment in between
    local previous = M.polledLatches[vid]
    M.polledLatches[vid] = signature
    if previous ~= signature then return end
    -- a car never reported yet with everything latched : nothing anyone needs to know
    if M.reportedLatches[vid] == nil and signature == "" then
        M.reportedLatches[vid] = signature
        return
    end
    if M.reportedLatches[vid] == signature then return end
    M.reportedLatches[vid] = signature
    beamjoy_communications.send("vehicleLatches", key, latches)
end

--- move another player's car's latches to the stored state (BeamMP's couplerVE does it on a remote
--- copy, and skips the groups already in that state)
---@param mpVeh BJVehicle
---@param latches table<string, string>
local function applyLatches(mpVeh, latches)
    local list = {}
    for name, state in pairs(latches) do list[#list + 1] = { name = name, state = state } end
    if #list == 0 or not mpVeh.veh then return end
    mpVeh.veh:queueLuaCommand(string.format(
        "if couplerVE and couplerVE.toggleCouplerState then couplerVE.toggleCouplerState(%q) end",
        jsonEncode(list)))
end

local function applyPendingLatches(now)
    for vid, pending in pairs(M.pendingLatches) do
        local mpVeh = beamjoy_vehicles.vehicles[vid]
        if not mpVeh then
            M.pendingLatches[vid] = nil
        elseif now >= pending.at then
            local latches = M.latches[serverKey(mpVeh) or ""]
            if latches then
                M.pendingLatches[vid] = nil
                M.appliedLatches[vid] = true
                applyLatches(mpVeh, latches)
            elseif now >= pending.untilMs then
                M.pendingLatches[vid] = nil -- nothing open on it
            end
        end
    end
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    local mpVeh = remoteCar(vid)
    if mpVeh then
        local now = GetCurrentTimeMillis()
        M.appliedLatches[vid] = nil -- a (re)spawned copy has every latch closed again
        M.pendingLatches[vid] = { at = now + M.LATCH_APPLY_DELAY_MS, untilMs = now + M.LATCH_APPLY_WAIT_MS }
    else
        M.reportedLatches[vid] = nil -- an own car (re)spawned : every latch closed again
        M.polledLatches[vid] = nil
    end
end

---@param caches table
local function retrieveCache(caches)
    if type(caches.vehicleLatches) ~= "table" then return end
    M.latches = caches.vehicleLatches
    -- Real bug (direct report: doors not synced for late joiners) : the stored state comes with the
    -- join cache, once this player's BeamJoy is ready, while the cars already on the map appear
    -- well before that ; each car only waited 10 s for it, so on a normal join none got it. Every
    -- other player's car here that hasn't had its state yet gets it now
    local now = GetCurrentTimeMillis()
    for vid, mpVeh in pairs(beamjoy_vehicles.vehicles) do
        if not M.appliedLatches[vid] and remoteCar(vid) and M.latches[serverKey(mpVeh) or ""] then
            local pending = M.pendingLatches[vid]
            M.pendingLatches[vid] = {
                at = pending and math.max(pending.at, now) or now,
                untilMs = now + M.LATCH_APPLY_WAIT_MS,
            }
        end
    end
end

---@param serverVID string
---@param latches table<string, string>
local function onVehicleLatches(serverVID, latches)
    serverVID = tostring(serverVID)
    M.latches[serverVID] = (type(latches) == "table" and next(latches)) and latches or nil
end

local function onSlowUpdate()
    -- the game reloads its extensions now and then (a Lua reload) : stand in again
    install()
    local now = GetCurrentTimeMillis()
    if now - M.lastLatchPoll >= M.LATCH_POLL_MS then
        M.lastLatchPoll = now
        pollOwnLatches()
    end
    applyPendingLatches(now)
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
    beamjoy_communications.addHandler("vehicleLatches", onVehicleLatches)
    beamjoy_communications.addHandler("sendCache", retrieveCache)
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
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onLatchReport = onLatchReport
M.onSlowUpdate = onSlowUpdate
M.onExtensionUnloaded = onExtensionUnloaded
M.onPreExit = onExtensionUnloaded

return M
