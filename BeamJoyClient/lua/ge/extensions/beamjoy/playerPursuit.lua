--- Freeroam police chases between players (server side : services/playerPursuit.lua).
---
--- Police side : while this player drives their own police car in freeroam, the other players'
--- cars around them that can be chased are put into the game's own traffic table, and the game's
--- police logic (gameplay_police) does the rest, exactly as it does for traffic in singleplayer :
--- it notices offenses (speeding, red lights, reckless driving, hitting the police car...), starts
--- the chase, and decides the arrest (both stopped close together for 5 s) or the escape (out of
--- sight long enough). Each of those (its onPursuitAction hook) is relayed to the server.
---
--- The game's police logic only runs while its traffic system is on, and that needs at least one
--- AI car this game spawned itself. With no traffic here, this module keeps it going on its own :
--- the traffic state reads as "on" for gameplay_police, and the chase cars are updated each frame
--- (see drive()). Real traffic takes over again whenever it runs.
---
--- BeamJoy's own traffic chases (beamjoy_pursuit : a traffic car flees from a police player) stay
--- as they are. The game's police ignores traffic cars while this runs, so the two never mix, and
--- no traffic chase starts while this player is chasing a player.
---
--- Fugitive side : told by the server. The car can't be reset or moved while chased (it can still
--- be flipped upright), it's frozen for 5 s when arrested, and this game leaves a chase it
--- shouldn't be in (an activity, the setting turned off, out of that car).
---
--- Who can be chased : not ghosts, not police cars, not traffic, not a car its owner isn't in,
--- and not a player who turned off Settings > Vehicle > "Police can chase me" or is in an
--- activity (each player's own game tells the server, playerPursuitAvailable).

local M = {
    --- seconds before a car can be chased again after a chase on it ended here
    COOLDOWN = 30,
    ARREST_FREEZE = 5,

    --- Settings > Vehicle > "Police can chase me" (saved on this PC)
    allowChases = true,

    ---@type {chases: {vid: string, fugitiveID: integer, police: integer[]}[], unavailable: integer[]}
    state = { chases = {}, unavailable = {} },
    ---@type {arrests: integer?, escapes: integer?}
    stats = {},

    --- police side : this game's police logic is running
    active = false,
    --- the cars this player chases : serverVID -> local vid
    ---@type table<string, integer>
    myTargets = {},
    --- chases this game started, until the server confirms (joined) or refuses them
    ---@type table<string, integer>
    pending = {},
    ---@type table<string, integer> serverVID -> GetCurrentTimeMillis() until which it's left alone
    cooldowns = {},
    --- vids put in the game's traffic table (or given a role) by this module
    ---@type table<integer, true>
    managed = {},
    --- traffic AI flagged ignorePolice by this module
    ---@type table<integer, true>
    flaggedAi = {},
    ---@type table<integer, boolean> vid -> is a police car
    policeCache = {},

    --- fugitive side : the own car being chased (serverVID), if any
    ---@type string?
    chased = nil,
    frozenUntil = nil,

    ready = false,
    ---@type boolean?
    sentAvailable = nil,
    ---@type table?
    savedPoliceVars = nil,
    baseGetState = nil,
}

---@return boolean
local function inActivity()
    return navigation ~= nil and navigation.inActivity ~= nil and navigation.inActivity() == true
end

---@return boolean
local function enabled()
    local fr = beamjoy_config and beamjoy_config.data and beamjoy_config.data.Freeroam
    return not fr or fr.PlayerPursuits ~= false
end

---@return table?
local function traffic()
    return extensions.gameplay_traffic
end

---@param v BJVehicle
---@return boolean
local function isPoliceCar(v)
    local cached = M.policeCache[v.vid]
    if cached == nil then
        local ok, res = pcall(beamjoy_vehicles.isPolice, v)
        cached = ok and res == true
        M.policeCache[v.vid] = cached
    end
    return cached
end

---@param playerID integer
---@return table?
local function playerByID(playerID)
    for _, p in pairs(beamjoy_players.players) do
        if p.playerID == playerID then return p end
    end
end

--- a car's full BeamMP id ("<ownerID>-<vehicleID>", see beamjoy_vehicles.serverKey) : what the
--- server and every message name a car by. "serverVID" in this file always means that full id
---@param v BJVehicle?
---@return string?
local function keyOf(v)
    return beamjoy_vehicles.serverKey(v)
end

---@param serverVID string
---@return BJVehicle?
local function vehicleByServerVID(serverVID)
    return beamjoy_vehicles.getByServerKey(serverVID)
end

---@param v BJVehicle
---@return boolean
local function isGhost(v)
    return v.veh ~= nil and v.veh.ghost == "1"
end

---@param serverVID string?
---@return boolean
local function inCooldown(serverVID)
    local untilMs = serverVID and M.cooldowns[serverVID]
    if not untilMs then return false end
    if untilMs <= GetCurrentTimeMillis() then
        M.cooldowns[serverVID] = nil
        return false
    end
    return true
end

---@param msg string
---@param duration number?
local function trafficMessage(msg, duration)
    if traffic() and traffic().showMessages == false then return end
    ui_message(msg, duration or 5, "traffic", "traffic")
end

---@param offenses string[]?
local function offensesMessage(offenses)
    if type(offenses) ~= "table" or #offenses == 0 then return end
    local labels = {}
    for _, o in ipairs(offenses) do
        labels[#labels + 1] = translateLanguage("ui.traffic.infractions." .. o, o)
    end
    if traffic() and traffic().showMessages == false then return end
    ui_message(string.format("%s %s", translateLanguage("ui.traffic.infractions.title", "Offenses:"),
        table.concat(labels, ", ")), 8, "trafficInfractions", "traffic")
end

-- WHO CAN BE CHASED ---------------------------------------------------------------------------------

--- this player, as a fugitive
---@return boolean
local function selfAvailable()
    return enabled() and M.allowChases and not inActivity()
end

local function sendAvailability()
    if not M.ready then return end
    local available = selfAvailable()
    if available ~= M.sentAvailable then
        M.sentAvailable = available
        beamjoy_communications.send("playerPursuitAvailable", available)
    end
end

---@param playerID integer
---@return boolean
local function playerUnavailable(playerID)
    for _, id in ipairs(M.state.unavailable or {}) do
        if id == playerID then return true end
    end
    return false
end

---@param serverVID string
---@return table?
local function chaseOf(serverVID)
    for _, c in ipairs(M.state.chases or {}) do
        if c.vid == serverVID then return c end
    end
end

--- another player's car this police player's game may chase
---@param v BJVehicle
---@return boolean
local function canChase(v)
    if v.isLocal or v.isAi or not v.isVehicle or not v.veh or not keyOf(v) then return false end
    if isGhost(v) or isPoliceCar(v) then return false end
    if playerUnavailable(v.ownerID) or inCooldown(keyOf(v)) then return false end
    local owner = playerByID(v.ownerID)
    return owner ~= nil and owner.currentVehicle == v.remoteVID
end

--- police side : this player is in their own police car, in freeroam
---@return BJVehicle?
local function ownPoliceCar()
    if not enabled() or inActivity() or M.chased then return nil end
    local current = beamjoy_vehicles.getCurrentOwn()
    if not current or not current.veh or isGhost(current) or not isPoliceCar(current) then return nil end
    return current
end

-- THE GAME'S POLICE LOGIC ---------------------------------------------------------------------------

---@return string
local function realTrafficState()
    local t = traffic()
    if not t then return "off" end
    return (M.baseGetState or t.getState)()
end

--- the game's police logic reads the traffic state through gameplay_traffic.getState : while this
--- police mode runs with no traffic, it reads "on" (everything else keeps the real state, which
--- only gameplay_police and a few unused-in-multiplayer systems check)
local function installGetState()
    local t = traffic()
    if not t or M.baseGetState then return end
    M.baseGetState = t.getState
    t.getState = function(...)
        local state = M.baseGetState(...)
        if M.active and state ~= "on" then return "on" end
        return state
    end
end

local function uninstallGetState()
    local t = traffic()
    if t and M.baseGetState then t.getState = M.baseGetState end
    M.baseGetState = nil
end

local function setPoliceVars(on)
    -- the traffic focus point (what the police role measures from) is only kept up to date while
    -- traffic runs, or with this flag
    local t = traffic()
    if t then t.forceFocus = on or nil end
    if not gameplay_police then return end
    if on and not M.savedPoliceVars then
        local vars = gameplay_police.getPursuitVars() or {}
        M.savedPoliceVars = {
            suspectFrequency = vars.suspectFrequency,
            roadblockFrequency = vars.roadblockFrequency,
        }
        -- no random traffic suspect, and no roadblock : the game builds those from AI police cars,
        -- and a roadblock teleports police cars into place
        gameplay_police.setPursuitVars({ suspectFrequency = 0, roadblockFrequency = 0 })
    elseif not on and M.savedPoliceVars then
        gameplay_police.setPursuitVars(M.savedPoliceVars)
        M.savedPoliceVars = nil
    end
end

---@param vid integer
local function stopNativePursuit(vid)
    local t = traffic()
    local tv = t and t.getTrafficData()[vid]
    if not tv or not gameplay_police then return end
    if tv.pursuit and tv.pursuit.mode ~= 0 then
        pcall(gameplay_police.setPursuitMode, 0, vid)
    end
    if tv.queuedFuncs then tv.queuedFuncs.pursuitStart = nil end
end

---@param lightbar integer
local function setLightbar(lightbar)
    local current = beamjoy_vehicles.getCurrentOwn()
    if current and current.veh then
        current.veh:queueLuaCommand(string.format("electrics.set_lightbar_signal(%d)", lightbar))
    end
end

--- police side : a chase this player was in is over (any way), or called off here
---@param serverVID string
---@param silent boolean? no lightbar change
local function dropTarget(serverVID, silent)
    local vid = M.myTargets[serverVID] or M.pending[serverVID]
    M.myTargets[serverVID] = nil
    M.pending[serverVID] = nil
    M.cooldowns[serverVID] = GetCurrentTimeMillis() + M.COOLDOWN * 1000
    local v = vehicleByServerVID(serverVID)
    vid = vid or (v and v.vid)
    if vid then stopNativePursuit(vid) end
    if not silent and not next(M.myTargets) and M.active then setLightbar(0) end
end

--- every chase this player started or joined is called off (left the police car, an activity...)
local function callOffAll()
    local all = {}
    for serverVID in pairs(M.myTargets) do all[serverVID] = true end
    for serverVID in pairs(M.pending) do all[serverVID] = true end
    for serverVID in pairs(all) do
        beamjoy_communications.send("playerPursuitEvent", "reset", serverVID)
        dropTarget(serverVID, true)
    end
end

---@param serverVID string?
---@return boolean
local function isMyTarget(serverVID)
    return serverVID ~= nil and (M.myTargets[serverVID] ~= nil or M.pending[serverVID] ~= nil)
end

--- puts the cars where they belong in the game's traffic table : this player's police car as
--- "police", the cars it can chase as "standard", every other player car "empty" and ignored by
--- the police. Runs every second.
local function updateRoles()
    local t = traffic()
    if not t or not gameplay_police then return end
    local police = ownPoliceCar()
    local wasActive = M.active
    M.active = police ~= nil

    if wasActive and not M.active then
        callOffAll()
        setPoliceVars(false)
        for vid in pairs(M.flaggedAi) do
            local tv = t.getTrafficData()[vid]
            if tv then tv.ignorePolice = nil end
        end
        table.clear(M.flaggedAi)
    elseif M.active and not wasActive then
        setPoliceVars(true)
    end

    local data = t.getTrafficData()
    local inserted = false
    for vid, v in pairs(beamjoy_vehicles.vehicles) do
        local tv = data[vid]
        if v.isAi then
            if M.active and tv and not tv.ignorePolice then
                tv.ignorePolice = true
                M.flaggedAi[vid] = true
            end
        elseif v.veh then
            local role
            if police and vid == police.vid then
                role = "police"
            elseif M.active and canChase(v) then
                role = "standard"
            elseif tv and (M.managed[vid] or (tv.roleName == "police" and not v.isLocal)) then
                role = "empty"
            end
            if role and not tv and role ~= "empty" then
                t.insertTraffic(vid, true, true)
                tv = data[vid]
                inserted = inserted or tv ~= nil
            end
            if role and tv then
                M.managed[vid] = true
                -- what the game puts the car back to when a chase on it ends
                tv.autoRole = role
                if tv.roleName == "suspect" then
                    -- an ongoing chase on a car that can't be chased anymore here
                    if role ~= "standard" then
                        if isMyTarget(keyOf(v)) then
                            beamjoy_communications.send("playerPursuitEvent", "reset", keyOf(v))
                            dropTarget(keyOf(v))
                        else
                            stopNativePursuit(vid)
                        end
                        if tv.roleName ~= role then tv:setRole(role) end
                    end
                elseif tv.roleName ~= role then
                    tv:setRole(role)
                end
                tv.ignorePolice = role ~= "standard" and role ~= "police" or nil
                if role ~= "standard" and tv.queuedFuncs then tv.queuedFuncs.pursuitStart = nil end
            end
        end
    end
    -- the game's traffic init draws every inserted car solid : ghosts go back to see-through
    if inserted and beamjoy_vehicles.reapplyDisplayAlpha then beamjoy_vehicles.reapplyDisplayAlpha() end
end

--- with no traffic running here, the chase cars are updated by this module : the same per-car
--- update the game's traffic loop does (road tracking, collisions, offenses, the police role)
---@param dtReal number
---@param dtSim number
local function drive(dtReal, dtSim)
    if not M.active or realTrafficState() == "on" then return end
    if not be:getEnabled() or (freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive()) then return end
    local t = traffic()
    local data = t.getTrafficData()
    for vid in pairs(M.managed) do
        local tv = data[vid]
        if tv and tv.roleName ~= "empty" then
            local ok, err = pcall(tv.onUpdate, tv, dtReal, dtSim)
            if not ok then
                LogError("beamjoy_playerPursuit: traffic update failed for " .. tostring(vid) .. ": " .. tostring(err))
                M.managed[vid] = nil
            end
        end
    end
end

-- FUGITIVE SIDE -------------------------------------------------------------------------------------

local function releaseChased()
    M.chased = nil
    beamjoy_recoveryPolicy.release("playerPursuit")
    if beamjoy_restrictions then beamjoy_restrictions.update() end
end

---@param serverVID string
local function withdraw(serverVID)
    beamjoy_communications.send("playerPursuitWithdraw", serverVID)
    if M.chased == serverVID then releaseChased() end
end

--- this game's own car can still be chased as that car
---@param serverVID string
---@return boolean
local function stillChaseable(serverVID)
    if not selfAvailable() then return false end
    local current = beamjoy_vehicles.getCurrentOwn()
    return current ~= nil and keyOf(current) == serverVID and not isGhost(current)
end

---@param serverVID string
---@param data table
local function onChaseStart(serverVID, data)
    if not stillChaseable(serverVID) then return withdraw(serverVID) end
    M.chased = serverVID
    -- no reset or move while chased : flip upright only, damage kept
    beamjoy_recoveryPolicy.claim("playerPursuit", { blockRepair = true })
    if beamjoy_restrictions then beamjoy_restrictions.update() end
    sound.play(sound.SOUNDS.INFO_OPEN)
    trafficMessage("ui.traffic.policePursuit")
    if data.policeName then
        uiHelpers.toastWarning(beamjoy_lang.translate("beamjoy.pursuit.player.chasedBy")
            :var({ playerName = data.policeName }))
    end
end

---@param serverVID string
---@param data table
local function onArrested(serverVID, data)
    local own = vehicleByServerVID(serverVID)
    releaseChased()
    sound.play(sound.SOUNDS.MAIN_CANCEL)
    trafficMessage(data.ticket and "ui.traffic.policeTicket" or "ui.traffic.policeArrest")
    offensesMessage(data.offenses)
    if own and own.isLocal then
        local vid = own.vid
        beamjoy_vehicles.setFreeze(vid, true)
        M.frozenUntil = GetCurrentTimeMillis() + M.ARREST_FREEZE * 1000
        async.delayTask(function()
            M.frozenUntil = nil
            if beamjoy_vehicles.vehicles[vid] then beamjoy_vehicles.setFreeze(vid, false) end
            trafficMessage("ui.traffic.driveAway")
        end, M.ARREST_FREEZE * 1000)
    end
end

-- SERVER MESSAGES -----------------------------------------------------------------------------------

---@param kind string
---@param serverVID string
---@param data table?
local function onNotice(kind, serverVID, data)
    data = type(data) == "table" and data or {}
    local own = vehicleByServerVID(serverVID)
    local isMine = own ~= nil and own.isLocal

    if isMine then
        if kind == "start" then
            onChaseStart(serverVID, data)
        elseif kind == "arrest" then
            onArrested(serverVID, data)
        elseif kind == "escape" then
            releaseChased()
            sound.play(sound.SOUNDS.RACE_WAYPOINT)
            trafficMessage("ui.traffic.policeEvade")
        elseif kind == "over" then
            if M.chased == serverVID then
                releaseChased()
                trafficMessage(beamjoy_lang.translate("beamjoy.pursuit.player.over"))
            end
        end
        return
    end

    -- police side
    if kind == "joined" then
        local pendingVid = M.pending[serverVID]
        M.pending[serverVID] = nil
        -- this game called it off in the meantime : the server is already told
        if not pendingVid then return end
        if own then
            M.myTargets[serverVID] = own.vid
            sound.play(sound.SOUNDS.INFO_OPEN)
            uiHelpers.toastWarning(beamjoy_lang.translate("beamjoy.pursuit.player.fleeing")
                :var({ playerName = own.ownerName }))
            if localStorage.get(localStorage.GLOBAL_VALUES.AUTOMATIC_LIGHTS) then setLightbar(2) end
        end
    elseif kind == "refused" then
        dropTarget(serverVID, true)
    elseif kind == "arrest" then
        local self = beamjoy_players.getSelf()
        local byMe = self ~= nil and data.policeID == self.playerID
        if isMyTarget(serverVID) then
            if byMe then sound.play(sound.SOUNDS.RACE_WAYPOINT) end
            -- the arresting game said it already ; another police car in the chase is told here
            if not byMe then trafficMessage("ui.traffic.suspectArrest") end
            dropTarget(serverVID)
        end
    elseif kind == "escape" or kind == "lost" then
        if isMyTarget(serverVID) then
            sound.play(sound.SOUNDS.MAIN_CANCEL)
            dropTarget(serverVID)
        end
    elseif kind == "over" then
        if isMyTarget(serverVID) then
            if own then
                uiHelpers.toastInfo(beamjoy_lang.translate("beamjoy.pursuit.player.calledOff")
                    :var({ playerName = own.ownerName }))
            end
            dropTarget(serverVID)
        end
    end
end

--- the game's police logic, on this police player's game : relayed to the server
---@param id integer
---@param action string
---@param pursuit table?
local function onPursuitAction(id, action, pursuit)
    if not M.active then return end
    local v = beamjoy_vehicles.vehicles[id]
    local key = keyOf(v)
    if not v or v.isLocal or v.isAi or not key then return end
    local offenses = pursuit and type(pursuit.offensesList) == "table" and pursuit.offensesList or {}
    if action == "start" then
        if not canChase(v) then return stopNativePursuit(id) end
        if isMyTarget(key) then return end
        M.pending[key] = id
        -- the server checks the police car is this player's own, and its distance to the fugitive
        beamjoy_communications.send("playerPursuitEvent", "start", key, {
            offenses = offenses,
            police = keyOf(beamjoy_vehicles.getCurrentOwn()),
        })
    elseif not isMyTarget(key) then
        return
    elseif action == "arrest" then
        beamjoy_communications.send("playerPursuitEvent", "arrest", key, {
            ticket = pursuit ~= nil and pursuit.mode == 1,
            offenses = offenses,
            police = keyOf(beamjoy_vehicles.getCurrentOwn()),
        })
    elseif action == "evade" then
        beamjoy_communications.send("playerPursuitEvent", "evade", key)
    end
end

---@param caches table
local function retrieveCache(caches)
    if type(caches.playerPursuit) == "table" then
        M.state = {
            chases = caches.playerPursuit.chases or {},
            unavailable = caches.playerPursuit.unavailable or {},
        }
        -- a chase that ended without this game hearing it (missed message, reconnect). Only
        -- confirmed ones : a chase this game just started may not have reached the server yet
        if M.chased and not chaseOf(M.chased) then releaseChased() end
        for serverVID in pairs(M.myTargets) do
            if not chaseOf(serverVID) then dropTarget(serverVID) end
        end
    end
    if type(caches.playerPursuitStats) == "table" then
        M.stats = caches.playerPursuitStats
        beamjoy_communications_ui.send("BJPursuitStats", M.stats)
    end
end

-- HOOKS ---------------------------------------------------------------------------------------------

local function sendSettingsToUI()
    beamjoy_communications_ui.send("BJUserSettings", { pursuit = { allowChases = M.allowChases } })
end

local function onInit()
    M.allowChases = localStorage.get(localStorage.GLOBAL_VALUES.ALLOW_POLICE_CHASES) ~= false
    installGetState()
    beamjoy_communications.addHandler("sendCache", retrieveCache)
    beamjoy_communications.addHandler("playerPursuitNotice", onNotice)
    beamjoy_communications_ui.addHandler("BJRequestVehicleSettings", sendSettingsToUI)
    beamjoy_communications_ui.addHandler("BJRequestPursuitStats", function()
        beamjoy_communications_ui.send("BJPursuitStats", M.stats)
    end)
    beamjoy_communications_ui.addHandler("BJUserSettings", function(newSettings)
        local p = type(newSettings) == "table" and newSettings.pursuit
        if type(p) ~= "table" or type(p.allowChases) ~= "boolean" or p.allowChases == M.allowChases then
            return
        end
        M.allowChases = p.allowChases
        localStorage.set(localStorage.GLOBAL_VALUES.ALLOW_POLICE_CHASES, M.allowChases)
        sendAvailability()
    end)
end

local function onBJClientReady()
    M.ready = true
    M.sentAvailable = nil
    sendAvailability()
end

local function onSlowUpdate()
    if not M.ready then return end
    sendAvailability()
    if M.chased and not stillChaseable(M.chased) then withdraw(M.chased) end
    local ok, err = pcall(updateRoles)
    if not ok then LogError("beamjoy_playerPursuit: role update failed: " .. tostring(err)) end
end

---@param dtReal number
---@param dtSim number
local function onUpdate(dtReal, dtSim)
    drive(dtReal, dtSim)
end

---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    if not M.chased then return end
    restrictions:addAll(beamjoy_recoveryPolicy.REPOSITION_ACTIONS, true)
    restrictions:addAll({ "toggleWalkingMode" }, true)
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    M.policeCache[vid] = nil
end

---@param vid integer
local function onVehicleDestroyed(vid)
    M.policeCache[vid] = nil
    M.managed[vid] = nil
    M.flaggedAi[vid] = nil
end

local function onExtensionUnloaded()
    if M.active then callOffAll() end
    setPoliceVars(false)
    uninstallGetState()
    beamjoy_recoveryPolicy.release("playerPursuit")
end

--- this police player chases at least one player
---@return boolean
local function isChasing()
    return next(M.myTargets) ~= nil
end

--- a car (this game's vid) is being chased by police players
---@param vid integer
---@return boolean
local function isFugitiveVid(vid)
    local v = beamjoy_vehicles.vehicles[vid]
    return v ~= nil and keyOf(v) ~= nil and chaseOf(keyOf(v)) ~= nil
end

M.onInit = onInit
M.onBJClientReady = onBJClientReady
M.onSlowUpdate = onSlowUpdate
M.onUpdate = onUpdate
M.onPursuitAction = onPursuitAction
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onVehicleDestroyed = onVehicleDestroyed
M.onExtensionUnloaded = onExtensionUnloaded
M.onPreExit = onExtensionUnloaded

M.retrieveCache = retrieveCache
M.isChasing = isChasing
M.isFugitiveVid = isFugitiveVid

return M
