local M = {
    ---@type tablelib<string, BJCPlayer> index playerName
    players = Table(),
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications.addHandler("updatePlayer", M.updatePlayer)
    beamjoy_communications.addHandler("updateDBPlayer", M.updateDBPlayer)
    beamjoy_communications.addHandler("teleportToPlayer", M.onTeleportToPlayer)
    beamjoy_communications.addHandler("chatTeleportTo", M.onChatTeleportTo)

    beamjoy_communications_ui.addHandler("BJReady", M.onUIReady)
    beamjoy_communications_ui.addHandler("BJPlayerAction", M.onPlayerAction)
    beamjoy_communications_ui.addHandler("BJVehicleAction", M.onVehicleAction)
    beamjoy_communications_ui.addHandler("BJModerationDemote", M.onModerationDemote)
    beamjoy_communications_ui.addHandler("BJModerationPromote", M.onModerationPromote)
    beamjoy_communications_ui.addHandler("BJModerationMute", M.onModerationMute)
    beamjoy_communications_ui.addHandler("BJModerationKick", M.onModerationKick)
    beamjoy_communications_ui.addHandler("BJModerationBan", M.onModerationBan)
    beamjoy_communications_ui.addHandler("BJModerationTempBan", M.onModerationTempBan)
end

--- Client-local only, unlike every other field on the player list: whether a player has a vehicle
--- this client's own BeamMP layer remembers as deleted (MPVehicleGE.getVehicles()'s own isDeleted
--- flag) is purely a fact about what THIS viewer's client has seen - BeamMP never syncs it through
--- the server - so it can't ride along on the server-authored BJCPlayer payload every other
--- player-list field comes from (see onPlayerAction's own "restore" case doc comment). Recomputed
--- and pushed to the UI locally instead, only when the actual set of names changes. Drives the
--- "Queue deleted vehicles" HUD button's visibility (see player-line/app.js): only shown for a
--- player this client can actually do something useful for.
local lastDeletedVehiclePlayers = {}
---@param force boolean? bypass change-detection and resend regardless - used on UI (re)connect,
---where a fresh UI needs the current state even if it hasn't changed since the last send (the
---previous send went to a UI instance that may no longer exist)
local function pushDeletedVehiclePlayers(force)
    local current = {}
    for _, v in pairs(MPVehicleGE.getVehicles()) do
        if v.isDeleted and v.ownerName then
            current[v.ownerName] = true
        end
    end
    local changed = force == true
    if not changed then
        for name in pairs(current) do
            if not lastDeletedVehiclePlayers[name] then
                changed = true
                break
            end
        end
    end
    if not changed then
        for name in pairs(lastDeletedVehiclePlayers) do
            if not current[name] then
                changed = true
                break
            end
        end
    end
    if not changed then return end
    lastDeletedVehiclePlayers = current
    beamjoy_communications_ui.send("BJPlayersWithDeletedVehicles", current)
end

local function onSlowUpdate()
    pushDeletedVehiclePlayers()
end

local firstFocusMade = false
local function onUIReady()
    core_jobsystem.create(function(job)
        while M.players:length() == 0 do
            job.sleep(.01)
        end
        beamjoy_communications_ui.send("BJUpdatePlayers", M.players:values())
        local self = M.getSelf()
        if self then
            beamjoy_communications_ui.send("BJUpdateSelf", self)
        end
        pushDeletedVehiclePlayers(true)

        if not firstFocusMade then
            ---@type tablelib<integer, integer>
            local playersVehs = M.players:reduce(function(acc, p)
                return acc:addAll({ p.currentVehicle }, true)
            end, Table())
            while playersVehs:any(function(rvid)
                    return not beamjoy_vehicles.vehicles:find(function(v)
                        return rvid == v.remoteVID
                    end)
                end) do
                job.sleep(.2)
            end
            ---@type tablelib<integer, integer> index 1-N, value vid
            local vehs = playersVehs:map(function(rvid)
                return beamjoy_vehicles.vehicles:find(function(mpVeh) ---@param mpVeh BJVehicle
                    return mpVeh.remoteVID == rvid
                end).vid
            end)
            if vehs:length() > 0 then
                beamjoy_vehicles.focusVehicle(vehs:random())
            end
            firstFocusMade = true
        end
    end)
end

local function onBJVehicleInstantiated(vid)
    core_jobsystem.create(function(job)
        local mpVeh = beamjoy_vehicles.getVehicle(vid, true)
        if not mpVeh then return end
        local owner = M.players:find(function(p) return p.playerID == mpVeh.ownerID end)
        if not owner then return end

        while not owner.vehicles[mpVeh.serverVID] do
            job.sleep(.01)
        end

        owner.vehicles[mpVeh.serverVID].vid = mpVeh.remoteVID
        owner.vehicles[mpVeh.serverVID].veh = mpVeh
        LogDebug(string.format("VehicleSpawn vid applied: %s-%d", owner.playerName, mpVeh.vid))
    end)
end

local teleportToLock = false

---@param targetPlayerName string
---@param forced boolean? true when triggered remotely by a "Teleport From" summon (bypasses the cooldown)
local function tryTeleportToPlayer(targetPlayerName, forced)
    local staff = beamjoy_permissions.isStaff()
    if not forced and not staff and
        not beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.TeleportTo) then
        return
    end

    local target = M.players[targetPlayerName]
    if not target or not target.currentVehicle then return end

    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return end

    -- voluntary self-teleport during an active race would trivially let someone skip ahead.
    -- staff-forced summons (`forced == true`, a moderator using "Teleport From") are left
    -- unaffected, same as how they already bypass the cooldown below. Staff themselves are NOT
    -- exempt here (a previous round's comment claimed this matched the walking-away/nodegrabber
    -- restrictions in raceRunner.lua, but those actually apply unconditionally once race-locked,
    -- with no staff bypass at all. That mismatch is almost certainly why this looked like it
    -- "didn't work" when tested from a staff/owner account).
    if not forced then
        local session = beamjoy_raceRunner and beamjoy_raceRunner.session
        -- COUNTDOWN too, not just RACE. A real, confirmed gap : a player could still self-
        -- teleport away during the grid/countdown lock (before gate-crossing tracking even starts,
        -- so it wouldn't even show as leaving the track), skipping the start entirely. Same class
        -- of bug this file's own other race restrictions (walking away, nodegrabber, camera) all
        -- originally shipped RACE-only and needed a follow-up patch for.
        if session and (session.state == "RACE" or session.state == "COUNTDOWN") then
            local selfName = MPConfig.getNickname()
            local participant = table.find(session.participants, function(p) return p.playerName == selfName end)
            if participant and not participant.finished and not participant.dnf then
                return toast.warn(beamjoy_lang.translate("beamjoy.teleport.duringRace"))
            end
        end

        -- per direct request : same reasoning as races' own restriction above. A hunter/fugitive
        -- self-teleporting during an active hunt would trivially skip the chase entirely (or let
        -- the fugitive escape any close call). Scoped to COUNTDOWN/HUNT, not LOBBY, matching races'
        -- own RACE/COUNTDOWN-only scope.
        local hunterSession = beamjoy_hunterRunner and beamjoy_hunterRunner.session
        if hunterSession and (hunterSession.state == "COUNTDOWN" or hunterSession.state == "HUNT") then
            local selfName = MPConfig.getNickname()
            local participant = table.find(hunterSession.participants, function(p) return p.playerName == selfName end)
            if participant then
                return toast.warn(beamjoy_lang.translate("beamjoy.teleport.duringHunt"))
            end
        end
    end

    if not forced and not staff then
        if teleportToLock then
            return toast.warn(beamjoy_lang.translate("beamjoy.teleport.onCooldown"))
        end
        teleportToLock = true
        local delay = (beamjoy_config.data.Freeroam and beamjoy_config.data.Freeroam.TeleportDelay) or 30
        async.delayTask(function() teleportToLock = false end, delay * 1000, "BJTeleportToDelay")
    end

    ---@type BJVehicle?
    local targetMpVeh = beamjoy_vehicles.vehicles:find(function(v)
        return v.remoteVID == target.currentVehicle
    end)
    if not targetMpVeh then return end

    local pos, dir, up = beamjoy_vehicles.getVehiclePositionRotation(targetMpVeh.veh)
    beamjoy_vehicles.setVehiclePositionRotation(myVeh.veh, pos, dir, up)
end

---@param fromPlayerName string
local function onTeleportToPlayer(fromPlayerName)
    M.tryTeleportToPlayer(fromPlayerName, true)
end

--- relay for the "/tp <player>" chat command : the server can't move the caller's vehicle itself
--- (teleport is entirely client-driven, per tryTeleportToPlayer's own rate-limit/permission/
--- race-restriction checks below), so it just tells this client to run the exact same call the
--- "Teleport To" UI button already makes locally. forced=false, so the normal cooldown still
--- applies (unlike the forced=true "Teleport From" summon path above)
---@param targetPlayerName string
local function onChatTeleportTo(targetPlayerName)
    M.tryTeleportToPlayer(targetPlayerName, false)
end

local function onPlayerAction(playerName, action)
    local target = M.players[playerName]
    if not target then return end

    LogDebug(string.format("onPlayerAction %s %s", playerName, action))

    if action == "focus" then
        local self = M.getSelf()
        if self and target.playerName == self.playerName then
            if self.currentVehicle and self.vehicles:some(function(v) ---@param v BJCPlayerVehicle
                    -- I have playable vehicle(s)
                    local mpVeh = v.veh and v.veh or nil
                    return mpVeh ~= nil and not mpVeh.isAi
                end) and beamjoy_vehicles.vehicles:any(function(v) ---@param v BJVehicle
                    -- my current vehicle belongs to another player
                    return v.remoteVID == self.currentVehicle and v.ownerName ~= self.playerName
                end) then
                self.vehicles:find(function(v) ---@param v BJCPlayerVehicle
                    local mpVeh = v.veh and v.veh or nil
                    return mpVeh ~= nil and not mpVeh.isAi and mpVeh.ownerName == self.playerName
                end, function(v)
                    beamjoy_vehicles.focusVehicle(v.veh.vid)
                end)
            end
        else
            local mpVeh = beamjoy_vehicles.vehicles
                :find(function(v) return v.remoteVID == target.currentVehicle end)
            if mpVeh and mpVeh.veh.playerUsable then
                beamjoy_vehicles.focusVehicle(mpVeh.vid)
            end
        end
    elseif action == "freeze" then
        beamjoy_communications.send("toggleFreeze", playerName)
    elseif action == "engine" then
        beamjoy_communications.send("toggleEngine", playerName)
    elseif action == "delete" then
        if playerName == MPConfig.getNickname() then
            M.players[playerName].vehicles:forEach(function(v)
                beamjoy_vehicles.delete(v.vid)
            end)
        else
            beamjoy_communications.send("deletePlayerVehicles", playerName)
        end
    elseif action == "restore" then
        -- Purely local/client-side, no server round-trip needed: BeamMP's own
        -- restorePlayerVehicle(playerName) just re-requests a spawn for whichever of that
        -- player's vehicles THIS client's own BeamMP layer still remembers as deleted
        -- (vehicle.isDeleted, keyed by that player's already-known server vehicle IDs) - the exact
        -- native mechanism behind BeamMP's own "queue deleted vehicles" player-list action.
        -- Harmless no-op if this client has nothing deleted to restore for them.
        MPVehicleGE.restorePlayerVehicle(playerName)
    elseif action == "teleportTo" then
        M.tryTeleportToPlayer(playerName)
    elseif action == "teleportFrom" then
        beamjoy_communications.send("teleportFrom", playerName)
    end
end

---@param playerName string
---@param rvid integer
---@param action string
local function onVehicleAction(playerName, rvid, action)
    local target = M.players[playerName]
    if not target then return end
    ---@type BJCPlayerVehicle?
    local targetVeh = target.vehicles:find(function(v) return v.vid == rvid end)
    if not targetVeh then return end

    LogDebug(string.format("onVehicleAction %s %d %s", playerName, rvid, action))

    if action == "focus" then
        beamjoy_vehicles.focusVehicle(targetVeh.veh.vid)
    elseif action == "freeze" then
        beamjoy_communications.send("toggleFreeze", playerName, rvid)
    elseif action == "engine" then
        beamjoy_communications.send("toggleEngine", playerName, rvid)
    elseif action == "delete" then
        if targetVeh.veh.isLocal then
            beamjoy_vehicles.delete(targetVeh.vid)
        else
            beamjoy_communications.send("deleteVehicle", playerName, rvid)
        end
    elseif action == "explode" then
        beamjoy_communications.send("explodeVehicle", rvid)
    elseif action == "launch" then
        beamjoy_communications.send("launchVehicle", rvid)
    end
end

---@param playerName string
local function onModerationDemote(playerName)
    if beamjoy_permissions.isStaff() or
        beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.SetGroup) then
        beamjoy_communications.send("demote", playerName)
    end
end

---@param playerName string
local function onModerationPromote(playerName)
    if beamjoy_permissions.isStaff() or
        beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.SetGroup) then
        beamjoy_communications.send("promote", playerName)
    end
end

---@param playerName string
---@param reason string?
local function onModerationMute(playerName, reason)
    if beamjoy_permissions.isStaff() or
        beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.Mute) then
        local targetPlayer = M.players[playerName]
        if not targetPlayer then return end
        if targetPlayer.muted then
            beamjoy_communications.send("mute", playerName, nil, reason)
        else
            uiHelpers.popupConfirm(
                beamjoy_lang.translate("beamjoy.moderation.confirm.mute" ..
                    (reason and "WithReason" or "")):var({
                    playerName = playerName,
                    reason = reason,
                }),
                function()
                    beamjoy_communications.send("mute", playerName, nil, reason)
                end
            )
        end
    end
end

---@param playerName string
---@param reason string?
local function onModerationKick(playerName, reason)
    if beamjoy_permissions.isStaff() or
        beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.Kick) then
        uiHelpers.popupConfirm(
            beamjoy_lang.translate("beamjoy.moderation.confirm.kick" ..
                (reason and "WithReason" or "")):var({
                playerName = playerName,
                reason = reason,
            }),
            function()
                beamjoy_communications.send("kick", playerName, reason)
            end
        )
    end
end

---@param playerName string
---@param reason string?
local function onModerationBan(playerName, reason)
    if beamjoy_permissions.isStaff() or
        beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.Ban) then
        uiHelpers.popupConfirm(
            beamjoy_lang.translate("beamjoy.moderation.confirm.ban" ..
                (reason and "WithReason" or "")):var({
                playerName = playerName,
                reason = reason,
            }),
            function()
                beamjoy_communications.send("ban", playerName, reason)
            end
        )
    end
end

---@param playerName string
---@param duration integer
---@param reason string?
local function onModerationTempBan(playerName, duration, reason)
    if beamjoy_permissions.isStaff() or
        beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.TempBan) then
        uiHelpers.popupConfirm(
            beamjoy_lang.translate("beamjoy.moderation.confirm.kick" ..
                (reason and "WithReason" or "")):var({
                playerName = playerName,
                duration = duration and PrettyDelay(duration) or nil,
                reason = reason,
            }),
            function()
                beamjoy_communications.send("tempban", playerName, duration, reason)
            end
        )
    end
end

local function onReplayStarted()
    beamjoy_communications.send("toggleReplayState", true)
end

local function onReplayStopped()
    beamjoy_communications.send("toggleReplayState", false)
end

---@return BJCPlayer?
local function getSelf()
    return M.players[MPConfig.getNickname()]
end

local function updatePlayerData(playerName)
    local player = M.players[playerName]
    if player then
        -- VEHICLES PARSING
        player.vehicles = Table(player.vehicles)
            :map(function(v) --- @param v BJCPlayerVehicle
                v.label = beamjoy_vehicles.getLabelByModel(v.jbeam)
                v.veh = beamjoy_vehicles.vehicles:find(function(mpVeh)
                    return mpVeh.remoteVID == v.vid
                end)
                return v
            end)

        -- REPLAY CHECKS
        if player.replay and not replay.replayPlayers[playerName] then
            beamjoy_vehicles.vehicles:filter(function(v)
                return v.owner == playerName
            end):forEach(function(v)
                v.veh:disableCollision()
            end)
            replay.replayPlayers[playerName] = true
        elseif not player.replay and replay.replayPlayers[playerName] then
            beamjoy_vehicles.vehicles:filter(function(v)
                return v.owner == playerName
            end):forEach(function(v)
                v.veh:enableCollision()
            end)
            replay.replayPlayers[playerName] = nil
        end
        extensions.hook("onBJUpdatePlayer", player)
    end
end

---@param caches table
local function retrieveCache(caches)
    if caches.players then
        M.players = Table(caches.players)
        M.players:keys():forEach(updatePlayerData)
        local self = M.getSelf()
        if self then
            beamjoy_communications_ui.send("BJUpdateSelf", self)
            extensions.hook("onBJUpdateSelf")

            if self.froze then
                self.vehicles:forEach(function(v)
                    beamjoy_vehicles.setFreeze(v.vid, true)
                end)
            else
                self.vehicles:forEach(function(v)
                    beamjoy_vehicles.setFreeze(v.vid, not not v.froze)
                end)
            end

            if self.shut then
                self.vehicles:forEach(function(v)
                    beamjoy_vehicles.setEngine(v.vid, false)
                end)
            else
                self.vehicles:forEach(function(v)
                    beamjoy_vehicles.setEngine(v.vid, not v.shut)
                end)
            end
        end

        beamjoy_communications_ui.send("BJUpdatePlayers", M.players:values())
    end
end

---@param playerName integer
---@param data any
local function updatePlayer(playerName, data)
    M.players[playerName] = data
    updatePlayerData(playerName)
    beamjoy_communications_ui.send("BJUpdatePlayer", {
        playerName = playerName,
        data = M.players[playerName],
    })
    local self = M.getSelf()
    if self and playerName == self.playerName then
        beamjoy_communications_ui.send("BJUpdateSelf", self)
        extensions.hook("onBJUpdateSelf")
    end
end

local function updateDBPlayer(playerName, data)
    beamjoy_communications_ui.send("BJUpdateDBPlayer", {
        playerName = playerName,
        data = data,
    })
end

M.onInit = onInit
M.onUIReady = onUIReady
M.onSlowUpdate = onSlowUpdate
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onPlayerAction = onPlayerAction
M.tryTeleportToPlayer = tryTeleportToPlayer
M.onTeleportToPlayer = onTeleportToPlayer
M.onChatTeleportTo = onChatTeleportTo
M.onVehicleAction = onVehicleAction
M.onModerationDemote = onModerationDemote
M.onModerationPromote = onModerationPromote
M.onModerationMute = onModerationMute
M.onModerationKick = onModerationKick
M.onModerationBan = onModerationBan
M.onModerationTempBan = onModerationTempBan
M.onReplayStarted = onReplayStarted
M.onReplayStopped = onReplayStopped

M.getSelf = getSelf
M.retrieveCache = retrieveCache
M.updatePlayer = updatePlayer
M.updateDBPlayer = updateDBPlayer

return M
