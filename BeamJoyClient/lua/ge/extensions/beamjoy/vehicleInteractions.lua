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
---
--- Electrics for late joiners (direct request) : BeamMP sends a car's electrics.values (lights,
--- signals, lightbar, a mod's own keys...) and its drivetrain modes only as they change. Its
--- MPElectricsVE.check() keeps what it already sent (`lastElectrics`, `checkElectrics`) and
--- MPPowertrainVE its `lastDevices`, never reset, so a car that appears here later shows them at
--- their spawn defaults until its owner changes them again (a police lightbar off mid-chase, a derby
--- wreck without its hazards, headlights off at night). Engine and ignition aren't affected :
--- BeamMP resends those every 10 s on its own. So when another player's car appears here, this
--- client asks its owner for them, once (after RESYNC_DELAY_MS : the car settles first) ; the server
--- passes it on (services/vehicleInteractions.lua) ; the owner empties those records on that car,
--- and BeamMP's next tick sends the whole set through its own packet, to everyone (BeamMP has no
--- other way), so requests from several players for one car are merged into one send.
--- MPElectricsGE.sendElectrics also drops a payload identical to the last one it sent, and the game's
--- sandbox refuses debug.setupvalue in GE, so its record can't be cleared : it's wrapped instead,
--- and only a resend that repeats that very payload gets a space after its opening brace (another
--- string to that check, the same JSON to everyone receiving it). Everything stays BeamMP's own
--- send and packet ; all of ours is in pcall, so it can never stop BeamMP's own sync.

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

    -- a car that just appeared here settles before its electrics are asked for
    RESYNC_DELAY_MS = 2000,
    -- requests waiting for a car's server id (it may not be known yet), at most this long
    RESYNC_WAIT_MS = 15000,
    -- the most cars one request names (the server caps it too)
    RESYNC_MAX_PER_MESSAGE = 50,
    -- own cars : requests arriving this close together make one resend
    RESYNC_MERGE_MS = 500,
    --- other players' cars to ask for : vid -> { at, untilMs }
    ---@type table<integer, {at: integer, untilMs: integer}>
    resyncWanted = {},
    --- own cars to resend : vid -> when
    ---@type table<integer, integer>
    resyncDue = {},
    --- own cars whose next electrics payload is a resend : vid -> until when
    ---@type table<integer, integer>
    resyncSending = {},
    ---@type function? BeamMP's own MPElectricsGE.sendElectrics, while ours stands in
    originalSendElectrics = nil,
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

-- ELECTRICS RESYNC ------------------------------------------------------------------------------

--- the owner's side, VE : empty BeamMP's records of what it already sent for this car (the same
--- tables kept, emptied : its check() keeps using them). Electrics : MPElectricsVE.check's
--- `lastElectrics` and `checkElectrics`. Drivetrain modes : `lastDevices`, an upvalue of
--- getPowerTrainData, itself one of MPPowertrainVE.check's
local RESYNC_VE = [[
pcall(function()
  local function upvalue(f, wanted)
    local i = 1
    while type(f) == "function" do
      local name, value = debug.getupvalue(f, i)
      if not name then return nil end
      if name == wanted then return value end
      i = i + 1
    end
  end
  local function clear(t) if type(t) == "table" then for k in pairs(t) do t[k] = nil end end end
  local check = MPElectricsVE and MPElectricsVE.check
  clear(upvalue(check, "lastElectrics"))
  clear(upvalue(check, "checkElectrics"))
  local pt = MPPowertrainVE and MPPowertrainVE.check
  clear(upvalue(upvalue(pt, "getPowerTrainData"), "lastDevices"))
end)
]]

--- what BeamMP's sendElectrics sent last (read only : reading an upvalue is allowed in GE), or nil
---@return string?
local function lastElectricsSent()
    local f = M.originalSendElectrics
    local i = 1
    while type(f) == "function" do
        local name, value = debug.getupvalue(f, i)
        if not name then return nil end
        if name == "lastElectrics" then return value end
        i = i + 1
    end
end

--- stands in for MPElectricsGE.sendElectrics (each own car's MPElectricsVE.check hands it its
--- payload), then runs it
---@param data string the JSON payload
---@param gameVehicleID integer
local function sendElectrics(data, gameVehicleID, ...)
    -- ours in pcall : whatever happens here, BeamMP's own send below runs
    pcall(function()
        if not M.resyncSending[gameVehicleID] then return end
        M.resyncSending[gameVehicleID] = nil
        -- the very payload BeamMP sent last would be dropped as a repeat (two resends with nothing
        -- changed in between) : a space after the opening brace, the same JSON
        if type(data) == "string" and data == lastElectricsSent() then
            data = (data:gsub("^{", "{ ", 1))
        end
    end)
    return M.originalSendElectrics(data, gameVehicleID, ...)
end

local function installResync()
    if MPElectricsGE and type(MPElectricsGE.sendElectrics) == "function" and
        MPElectricsGE.sendElectrics ~= sendElectrics then
        M.originalSendElectrics = MPElectricsGE.sendElectrics
        MPElectricsGE.sendElectrics = sendElectrics
    end
end

local function uninstallResync()
    if MPElectricsGE and MPElectricsGE.sendElectrics == sendElectrics and M.originalSendElectrics then
        MPElectricsGE.sendElectrics = M.originalSendElectrics
    end
    M.originalSendElectrics = nil
end

--- the joining side : ask the owners of the cars that are due, in one message
---@param now integer
local function requestResyncs(now)
    local list = {}
    for vid, wanted in pairs(M.resyncWanted) do
        local mpVeh = beamjoy_vehicles.vehicles[vid]
        local key = mpVeh and remoteCar(vid) and serverKey(mpVeh)
        if not mpVeh or now >= wanted.untilMs then
            M.resyncWanted[vid] = nil
        elseif key and now >= wanted.at and #list < M.RESYNC_MAX_PER_MESSAGE then
            M.resyncWanted[vid] = nil
            list[#list + 1] = key
        end
    end
    if #list > 0 then beamjoy_communications.send("vehicleResyncRequest", list) end
end

--- the owner's side : the server passing on requests for these cars of ours
---@param serverVIDs string[]
local function onVehicleResync(serverVIDs)
    if type(serverVIDs) ~= "table" then return end
    local wanted = {}
    for _, key in pairs(serverVIDs) do wanted[tostring(key)] = true end
    local now = GetCurrentTimeMillis()
    for vid, mpVeh in pairs(beamjoy_vehicles.vehicles) do
        if mpVeh.isLocal and not mpVeh.isAi and wanted[serverKey(mpVeh) or ""] and not M.resyncDue[vid] then
            M.resyncDue[vid] = now + M.RESYNC_MERGE_MS
        end
    end
end

--- the owner's side : resend the cars that are due
---@param now integer
local function resendDue(now)
    for vid, at in pairs(M.resyncDue) do
        if now >= at then
            M.resyncDue[vid] = nil
            local mpVeh = beamjoy_vehicles.vehicles[vid]
            if mpVeh and mpVeh.isLocal and mpVeh.veh then
                M.resyncSending[vid] = now + 2000
                mpVeh.veh:queueLuaCommand(RESYNC_VE)
            end
        end
    end
    -- a resend whose payload never came (nothing left to send) : back to ordinary payloads
    for vid, untilMs in pairs(M.resyncSending) do
        if now >= untilMs then M.resyncSending[vid] = nil end
    end
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    local mpVeh = remoteCar(vid)
    if mpVeh then
        local now = GetCurrentTimeMillis()
        M.appliedLatches[vid] = nil -- a (re)spawned copy has every latch closed again
        M.pendingLatches[vid] = { at = now + M.LATCH_APPLY_DELAY_MS, untilMs = now + M.LATCH_APPLY_WAIT_MS }
        -- this copy starts from its spawn defaults : ask its owner for the real electrics
        M.resyncWanted[vid] = { at = now + M.RESYNC_DELAY_MS, untilMs = now + M.RESYNC_WAIT_MS }
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
    pcall(installResync)
    local now = GetCurrentTimeMillis()
    requestResyncs(now)
    resendDue(now)
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
    beamjoy_communications.addHandler("vehicleResync", onVehicleResync)
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
    pcall(uninstallResync)
end

M.onInit = onInit
M.onBJClientReady = sendLocked
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onLatchReport = onLatchReport
M.onVehicleResync = onVehicleResync
M.onSlowUpdate = onSlowUpdate
M.onExtensionUnloaded = onExtensionUnloaded
M.onPreExit = onExtensionUnloaded

return M
