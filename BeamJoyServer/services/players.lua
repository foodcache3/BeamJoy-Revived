local M = {
    ---@type tablelib<string, BJSPlayerPending> index playerName
    pending = Table(),
    ---@type tablelib<string, BJSPlayer> index playerName
    players = Table(),
}

---@param playerName string? nil if guest
---@return (integer|string)? returnCode 1 = not allowed; 2 = bypass, string = reason
local function getAuthReturnCode(playerName)
    local staff = false
    local groupWhitelisted = false
    if playerName then
        local playerData = dao_players.get(playerName)

        if playerData then
            local group = services_groups.data[services_groups.getGroupIndex(playerData.group) or -1]
            if not group then return 1 end

            if playerData.banned or group.banned then
                local key = "auth.banned"
                if playerData.banReason then
                    key = "auth.bannedWithReason"
                end
                return services_lang.get(key, playerData.lang)
                    :var({ reason = playerData.banReason })
            end

            if playerData.tempBanUntil then
                local now = GetCurrentTime()
                if playerData.tempBanUntil < now then
                    playerData.tempBanUntil = nil
                    dao_players.save(playerName, playerData)
                else
                    local key = "auth.tempbanned"
                    if playerData.banReason then
                        key = "auth.tempbannedWithReason"
                    end
                    local delay = PrettyDelay(playerData.tempBanUntil - now)
                    return services_lang.get(key, playerData.lang)
                        :var({ delay = delay, reason = playerData.banReason })
                end
            end

            if group.staff then
                staff = true
            end
            if group.whitelisted then
                groupWhitelisted = true
            end

            if CheckServerVersion(3, 6) and staff then
                return 2
            end
        end
    end

    if services_config.data.Whitelist.Enabled then
        if not playerName then
            services_lang.get("auth.guestNotWhitelisted", services_lang.defaultLang)
        elseif not table.includes(services_config.data.Whitelist.PlayerNames, playerName) and
            not groupWhitelisted and not staff then
            return services_lang.get("auth.notWhitelisted", services_lang.defaultLang)
        end
    end
end

---@param playerName string
---@param role string
---@param guest boolean
---@param identifiers {ip: string, beammp: string}
---@return any returnCode 1 = not allowed; 2 = bypass, string = reason
local function onPlayerAuth(playerName, role, guest, identifiers)
    local returnCode = getAuthReturnCode(not guest and playerName or nil)
    if returnCode and returnCode ~= 2 then return returnCode end

    M.pending[playerName] = {
        playerName = playerName,
        guest = guest,
        ip = identifiers.ip,
        beammpID = identifiers.beammp, -- nil if guest
        ready = false,
    }

    return returnCode
end

---@param playerID integer
---@param pending BJSPlayerPending
---@param saved BJSPlayerSaved?
---@return BJSPlayer
local function instantiatePlayer(playerID, pending, saved)
    local res = table.assign({
        playerID = playerID,
        group = services_groups.getDefaultGroup(),
        ready = false,
        currentVehicle = nil,
        activity = nil, -- freeroaming
        froze = false,
        shut = false,
        vehicles = Table(),
        data = {},
        replay = false,
    }, pending)
    return saved and table.assign(res, saved) or res
end

---@param playerID integer
local function onPlayerConnecting(playerID)
    local playerName = MP.GetPlayerName(playerID)
    local pending = M.pending[playerName]
    if not pending then return end

    local playerData = not pending.guest and dao_players.get(playerName) or nil
    M.players[playerName] = instantiatePlayer(playerID, pending, playerData)
    if not playerData then
        M.players[playerName].firstConnection = true
        M.savePlayer(M.players[playerName])
    end
    M.pending[playerName] = nil
end

---@param playerID integer
local function onPlayerJoining(playerID)
    -- nothing to do now
end

---@param playerID integer
local function onPlayerJoin(playerID)
    -- nothing to do now
end

---@param ctxt BJSContext
---@param playerLang string?
local function onPlayerReady(ctxt, playerLang)
    if ctxt.sender then
        ctxt.sender.lang = playerLang
        ctxt.sender.ready = true

        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "updatePlayer",
            ctxt.sender.playerName, services_players.players[ctxt.sender.playerName])
        services_chat.sendEvent("beamjoy.chat.event.playerJoined", { playerName = ctxt.sender.playerName })
        services_chat.sendWelcomeMessage(ctxt.sender.playerName)
    end
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    local playerName = MP.GetPlayerName(playerID)
    if M.pending[playerName] then
        M.pending[playerName] = nil
    end
    if M.players[playerName] then
        M.players[playerName] = nil
        -- TODO send update to all players

        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "updatePlayer",
            playerName)
        services_chat.sendEvent("beamjoy.chat.event.playerLeft", { playerName = playerName })
    end
end

---@param ctxt BJSContext
---@param newLang string
local function onPlayerChangeLang(ctxt, newLang)
    ctxt.sender.lang = newLang
end

local function onInit()
    communications_rx.addHandler("clientConnection", onPlayerReady)
    communications_rx.addHandler("changeLang", onPlayerChangeLang)
    communications_rx.addHandler("toggleFreeze", M.toggleFreeze)
    communications_rx.addHandler("toggleEngine", M.toggleEngine)
    communications_rx.addHandler("toggleReplayState", M.toggleReplayState)
    communications_rx.addHandler("demote", M.demote)
    communications_rx.addHandler("promote", M.promote)
    communications_rx.addHandler("mute", M.mute)
    communications_rx.addHandler("kick", M.kick)
    communications_rx.addHandler("ban", M.ban)
    communications_rx.addHandler("tempban", M.tempBan)
    communications_rx.addHandler("unban", M.unban)
    communications_rx.addHandler("requestDatabase", M.requestDatabase)
    communications_rx.addHandler("setGroup", M.setGroup)
    communications_rx.addHandler("setData", M.setData)
    communications_rx.addHandler("teleportFrom", M.teleportFrom)

    services_consoleCommands.register("kick", "commands.bjkick.args", "commands.bjkick.desc", M.consoleKick)
    services_consoleCommands.register("ban", "commands.bjban.args", "commands.bjban.desc", M.consoleBan)
    services_consoleCommands.register("tempban", "commands.bjtempban.args", "commands.bjtempban.desc", M.consoleTempBan)
    services_consoleCommands.register("mute", "commands.bjmute.args", "commands.bjmute.desc", M.consoleMute)
    services_consoleCommands.register("unmute", "commands.bjunmute.args", "commands.bjunmute.desc", M.consoleUnmute)
    services_consoleCommands.register("group", "commands.bjgroup.args", "commands.bjgroup.desc", M
        .consoleGroup)

    services_chatCommands.addCommand("kick", "chat.command.kick.desc", M.chatKick,
        { commandKey = "chat.command.kick.command", permissions = { BJ_PERMISSIONS.Kick } })
    services_chatCommands.addCommand("mute", "chat.command.mute.desc", M.chatMute,
        { commandKey = "chat.command.mute.command", permissions = { BJ_PERMISSIONS.Mute } })
    services_chatCommands.addCommand("unmute", "chat.command.unmute.desc", M.chatUnmute,
        { commandKey = "chat.command.unmute.command", permissions = { BJ_PERMISSIONS.Mute } })
    services_chatCommands.addCommand("ban", "chat.command.ban.desc", M.chatBan,
        { commandKey = "chat.command.ban.command", permissions = { BJ_PERMISSIONS.Ban } })
    services_chatCommands.addCommand("tempban", "chat.command.tempban.desc", M.chatTempBan,
        { commandKey = "chat.command.tempban.command", permissions = { BJ_PERMISSIONS.TempBan } })
    services_chatCommands.addCommand("unban", "chat.command.unban.desc", M.chatUnban,
        { commandKey = "chat.command.unban.command", permissions = { BJ_PERMISSIONS.Ban } })
    services_chatCommands.addCommand("setgroup", "chat.command.setgroup.desc", M.chatSetGroup,
        { commandKey = "chat.command.setgroup.command", permissions = { BJ_PERMISSIONS.SetGroup } })
    services_chatCommands.addCommand("freeze", "chat.command.freeze.desc", M.chatFreeze,
        { commandKey = "chat.command.freeze.command", permissions = { BJ_PERMISSIONS.FreezePlayers } })
    services_chatCommands.addCommand("engine", "chat.command.engine.desc", M.chatEngine,
        { commandKey = "chat.command.engine.command", permissions = { BJ_PERMISSIONS.EnginePlayers } })
    services_chatCommands.addCommand("tpfrom", "chat.command.tpfrom.desc", M.chatTeleportFrom,
        { commandKey = "chat.command.tpfrom.command", permissions = { BJ_PERMISSIONS.TeleportFrom } })
    services_chatCommands.addCommand("tp", "chat.command.tp.desc", M.chatTeleportTo,
        { commandKey = "chat.command.tp.command", permissions = { BJ_PERMISSIONS.TeleportTo } })
end

local function onBJRequestCache(caches, targetID)
    local target = M.players:find(function(p) return p.playerID == targetID end)
    if target then
        local senderGroup = services_groups.data[services_groups.getGroupIndex(target.group) or -1]
        if not senderGroup then return end

        caches.players = M.players:filter(function(p) return targetID == p.playerID or p.ready end)
            :map(function(p)
                if senderGroup.staff or p.playerID == targetID then
                    ---@type table
                    local player = table.assign({}, p)
                    -- REMOVE SENSITIVE DATA FROM CACHE
                    player.beammpID = nil
                    player.ip = nil
                    -- see services/identity.lua's own doc comment: a pure display convenience
                    -- (nametags/roster), never used for anything identity-critical. Already a
                    -- real field on `p` itself (set at login, alongside identityNickname) so it
                    -- survives the OTHER places that broadcast this raw object directly instead
                    -- of going through this function - table.assign above already copied it, this
                    -- is just the (harmless, idempotent) fallback for a never-logged-in player
                    player.displayName = p.displayName or p.playerName
                    return player
                end

                return {
                    playerID = p.playerID,
                    playerName = p.playerName,
                    displayName = p.displayName or p.playerName,
                    group = p.group,
                    currentVehicle = p.currentVehicle,
                    activity = p.activity,
                    firstConnection = p.firstConnection,
                    vehicles = p.vehicles:map(function(v)
                        return {
                            vid = v.vid,
                            serverVehicleID = v.vehicleID,
                            jbeam = v.jbeam,
                            paints = v.paints,
                        }
                    end),
                }
            end)
    end
end

---@param playerData BJSPlayer|BJSPlayerSaved
local function savePlayer(playerData)
    if not playerData.guest then
        ---@type BJSPlayerSaved
        local data = {
            playerName = playerData.playerName,
            ip = playerData.ip,
            beammpID = playerData.beammpID,
            lang = playerData.lang,
            group = playerData.group,
            muted = playerData.muted,
            muteReason = playerData.muteReason,
            banned = playerData.banned,
            tempBanUntil = playerData.tempBanUntil,
            banReason = playerData.banReason,
            kickReason = playerData.kickReason,
            data = playerData.data,
        }
        dao_players.save(data.playerName, data)
    end
    if M.players[playerData.playerName] then
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "updatePlayer",
            playerData.playerName, M.players[playerData.playerName])
    elseif not playerData.guest then
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "updateDBPlayer",
            playerData.playerName, playerData)
    end
end

---@return table<string, BJSPlayerSaved>
local function getAllPlayers()
    return dao_players.getAll()
end

---@param str string can be an insensitive subpart of playername
---@return tablelib<integer, BJSPlayer> matches index 1-N, if exact name, then only one match, otherwise 0-N insensitive matches
local function getConnectedByName(str)
    local exactMatch = M.players:find(function(p) return p.playerName == str end)
    if exactMatch then return Table({ exactMatch }) end
    return M.players:filter(function(p) return p.playerName:lower():find(str:lower()) ~= nil end):values()
end

local function sendCacheUpdate()
    M.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches, p.playerID)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

---@param ctxt BJSContext
---@param targetName string
---@param vid integer?
local function toggleFreeze(ctxt, targetName, vid)
    if not ctxt.sender then return end
    if not services_permissions.isStaff(ctxt.sender.playerName) then return end

    local target = services_players.players[targetName]
    if not target then return end

    if vid then
        local targetVeh = target.vehicles:find(function(v) return v.vid == vid end)
        if not targetVeh then return end

        targetVeh.froze = not targetVeh.froze
    else
        target.froze = not target.froze
    end
    M.sendCacheUpdate()
end

---@param ctxt BJSContext
---@param targetName string
---@param vid integer?
local function toggleEngine(ctxt, targetName, vid)
    if not ctxt.sender then return end
    if not services_permissions.isStaff(ctxt.sender.playerName) then return end

    local target = M.players[targetName] ---@type BJSPlayer?
    if not target then return end

    if vid then
        ---@type BJSVehicle?
        local targetVeh = target.vehicles:find(function(v) return v.vid == vid end)
        if not targetVeh then return end

        targetVeh.shut = not targetVeh.shut
    else
        target.shut = not target.shut
    end
    M.sendCacheUpdate()
end

---@param ctxt BJSContext
---@param state boolean
local function toggleReplayState(ctxt, state)
    if not ctxt.sender then return end

    ctxt.sender.replay = state
    M.sendCacheUpdate()
end

---@param ctxt BJSContext
---@param playerName string
local function demote(ctxt, playerName)
    local target = M.players[playerName] ---@type BJSPlayer?
    if not target then return end
    local targetGroupIndex = services_groups.getGroupIndex(target.group)
    ---@type BJGroup?
    local targetGroup = services_groups.data[targetGroupIndex or -1]
    if not targetGroup then return end
    if ctxt.origin == "player" and ctxt.group then
        if ctxt.groupIndex <= targetGroupIndex or
            not services_permissions.isStaff(ctxt.sender.playerName) or
            not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.SetGroup) then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
        end
    end
    local _, defaultGroupIndex = services_groups.getDefaultGroup()
    if targetGroupIndex > defaultGroupIndex then
        local previousGroup, previousLevel
        for i, g in pairs(services_groups.data) do
            if i < targetGroupIndex and
                (not previousLevel or i > previousLevel) then
                previousGroup = g.name
                previousLevel = i
            end
        end
        if previousGroup then
            target.group = previousGroup
            M.savePlayer(target)
            M.sendCacheUpdate()
        end
    end
end

---@param ctxt BJSContext
---@param playerName string
local function promote(ctxt, playerName)
    local target = M.players[playerName] ---@type BJSPlayer?
    if not target then return end
    local targetGroupIndex = services_groups.getGroupIndex(target.group)
    ---@type BJGroup?
    local targetGroup = services_groups.data[targetGroupIndex]
    if not targetGroup then return end
    if ctxt.origin == "player" and ctxt.group then
        if ctxt.groupIndex <= targetGroupIndex + 1 or
            not services_permissions.isStaff(ctxt.sender.playerName) or
            not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.SetGroup) then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
        end
    end
    if targetGroupIndex < #services_groups.data then
        local nextGroup, nextLevel
        for i, g in pairs(services_groups.data) do
            if i > targetGroupIndex and
                (not nextLevel or i < nextLevel) then
                nextGroup = g.name
                nextLevel = i
            end
        end
        if nextGroup then
            target.group = nextGroup
            M.savePlayer(target)
            M.sendCacheUpdate()
        end
    end
end

---@param ctxt BJSContext
---@param playerName string
---@param state boolean?
---@param reason string?
local function mute(ctxt, playerName, state, reason)
    local connected = M.players[playerName] ---@type BJSPlayer?
    local target = connected or dao_players.get(playerName)
    if not target then return end
    if ctxt.origin == "player" and ctxt.group then
        local targetGroupIndex = services_groups.getGroupIndex(target.group)
        if ctxt.groupIndex <= targetGroupIndex or
            not services_permissions.isStaff(ctxt.sender.playerName) or
            not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.Mute) then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
        end
    end
    if state == nil then state = not target.muted end
    local chatEvent
    if state then
        if reason and #reason > 0 then
            target.muteReason = services_lang.get(reason, services_config.data.Console.Lang)
            chatEvent = services_lang.get("auth.mutedWithReason", target.lang)
                :var({ reason = services_lang.get(reason, target.lang) })
        else
            target.muteReason = nil
            chatEvent = services_lang.get("auth.muted", target.lang)
        end
    else
        chatEvent = services_lang.get("auth.unmuted", target.lang)
    end
    target.muted = state
    M.savePlayer(target)
    if connected then
        services_chat.sendServerChat(target.playerID, chatEvent)
    end
end

---@param playerID integer
---@param reason string key or text
---@param reasonParams table?
local function drop(playerID, reason, reasonParams)
    ---@type BJSPlayer?
    local player = M.players:find(function(p) return p.playerID == playerID end)
    if not player then return end
    local finalReason = services_lang.get(reason, player.lang):var(reasonParams or {})
    MP.DropPlayer(playerID, finalReason)
end

---@param ctxt BJSContext
---@param playerName string
---@param reason string?
local function kick(ctxt, playerName, reason)
    local target = M.players[playerName] ---@type BJSPlayer?
    if not target then return end
    if ctxt.origin == "player" and ctxt.group then
        local targetGroupIndex = services_groups.getGroupIndex(target.group)
        if ctxt.groupIndex <= targetGroupIndex or
            not services_permissions.isStaff(ctxt.sender.playerName) or
            not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.Kick) then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
        end
    end
    if reason and #reason > 0 then
        target.kickReason = services_lang.get(reason, services_config.data.Console.Lang)
    else
        target.kickReason = nil
        reason = "auth.kicked"
    end
    M.savePlayer(target)
    M.drop(target.playerID, reason)
end

---@param ctxt BJSContext
---@param playerName string
---@param reason string? key or text
---@param reasonParams table?
local function ban(ctxt, playerName, reason, reasonParams)
    local connected = M.players[playerName] ---@type BJSPlayer?
    local target = connected or dao_players.get(playerName)
    if not target then return end
    if ctxt.origin == "player" and ctxt.group then
        local targetGroupIndex = services_groups.getGroupIndex(target.group)
        if ctxt.groupIndex <= targetGroupIndex or
            not services_permissions.isStaff(ctxt.sender.playerName) or
            not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.Ban) then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
        end
    end
    target.tempBanUntil = nil
    target.banned = true
    target.banReason = (reason and #reason > 0) and reason or nil
    M.savePlayer(target)
    if connected then
        local finalReason = reason and
            services_lang.get(reason, connected.lang):var(reasonParams or {}) or
            ""
        if #finalReason == 0 then
            finalReason = services_lang.get("auth.banned", connected.lang)
        else
            finalReason = services_lang.get("auth.bannedWithReason", connected.lang)
                :var({ reason = finalReason })
        end
        M.drop(connected.playerID, finalReason)
    end
end

---@param ctxt BJSContext
---@param playerName string
---@param duration integer 120-N
---@param reason string? key or text
---@param reasonParams table?
local function tempBan(ctxt, playerName, duration, reason, reasonParams)
    local connected = M.players[playerName] ---@type BJSPlayer?
    local target = connected or dao_players.get(playerName)
    if not target then return end
    if ctxt.origin == "player" and ctxt.group then
        local targetGroupIndex = services_groups.getGroupIndex(target.group)
        if ctxt.groupIndex <= targetGroupIndex or
            not services_permissions.isStaff(ctxt.sender.playerName) or
            not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.TempBan) then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
        end
    end
    target.banned = nil
    target.tempBanUntil = GetCurrentTime() + duration
    target.banReason = (reason and #reason > 0) and reason or nil
    M.savePlayer(target)
    if connected then
        local finalReason = reason and
            services_lang.get(reason, connected.lang):var(reasonParams or {}) or
            ""
        if #finalReason == 0 then
            finalReason = services_lang.get("auth.tempbanned", connected.lang)
                :var({ delay = PrettyDelay(duration) })
        else
            finalReason = services_lang.get("auth.tembannedWithReason", connected.lang)
                :var({ delay = PrettyDelay(duration), reason = finalReason })
        end
        M.drop(connected.playerID, finalReason)
    end
end

---@param ctxt BJSContext
---@param playerName string
local function unban(ctxt, playerName)
    local target = dao_players.get(playerName)
    if not target then return end
    if ctxt.origin == "player" and ctxt.group then
        local targetGroupIndex = services_groups.getGroupIndex(target.group)
        if ctxt.groupIndex <= targetGroupIndex or
            not services_permissions.isStaff(ctxt.sender.playerName) or
            not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.Ban) then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
        end
    end
    target.banned = nil
    target.tempBanUntil = nil
    M.savePlayer(target)
end

---@param ctxt BJSContext
---@param playerName string
---@param groupName string
local function setGroup(ctxt, playerName, groupName)
    local connected = M.players[playerName]
    local target = connected or dao_players.get(playerName)
    if not target then return end
    local finalGroupIndex = services_groups.getGroupIndex(groupName)
    if not finalGroupIndex then return end
    if ctxt.origin == "player" and ctxt.group then
        local targetGroupIndex = services_groups.getGroupIndex(target.group)
        if ctxt.groupIndex <= finalGroupIndex or
            ctxt.groupIndex <= targetGroupIndex or
            not services_permissions.isStaff(ctxt.sender.playerName) or
            not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.SetGroup) then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
        end
    end
    target.group = services_groups.data[finalGroupIndex].name
    M.savePlayer(target)

    if connected then
        -- update all player caches
        local caches = {}
        extensions.hook("onBJRequestCache", caches, connected.playerID)
        communications_tx.sendToPlayer(connected.playerID, "sendCache", caches)
    end
end

---@param ctxt BJSContext
---@param playerName string
---@param key string
---@param value any?
local function setData(ctxt, playerName, key, value)
    local target = M.players[playerName] or dao_players.get(playerName)
    if not target then return end
    if ctxt.origin == "player" and ctxt.group then
        if ctxt.group.name ~= "owner" then
            local targetGroupIndex = services_groups.getGroupIndex(target.group)
            if ctxt.groupIndex <= targetGroupIndex or
                not services_permissions.isStaff(ctxt.sender.playerName) or
                not services_permissions.hasAllPermissions(ctxt.senderID,
                    BJ_PERMISSIONS.DatabasePlayers) then
                return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                    services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
            end
        end
    end
    target.data[key] = value
    M.savePlayer(target)
end

---@param ctxt BJSContext
---@param targetName string brought to the sender's position
local function teleportFrom(ctxt, targetName)
    if not ctxt.sender then return end
    if not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.TeleportFrom) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end
    local target = M.players[targetName]
    if not target or target.playerID == ctxt.senderID then return end

    communications_tx.sendToPlayer(target.playerID, "teleportToPlayer", ctxt.sender.playerName)
end

---@param ctxt BJSContext
---@param args string[] "&lt;player_name> &lt;message...>"
---@param command BJChatCommand
local function chatPrivateMessage(ctxt, args, command)
    if #args < 2 then
        services_chat.directSend(ctxt.senderID,
            string.format("%s : %s -> %s",
                services_lang.get("chat.command.usage", ctxt.sender.lang),
                services_lang.get(command.commandKey, ctxt.sender.lang),
                services_lang.get(command.descKey, ctxt.sender.lang)),
            services_chat.COLORS.ERROR)
        return
    end
    local playerName = args[1]
    local targets = M.getConnectedByName(playerName)
        :filter(function(p)
            return p.playerID ~= ctxt.senderID
        end)
    if #targets == 0 then
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.pm.invalidTarget", ctxt.sender.lang)
            :var({ playerName = playerName }),
            services_chat.COLORS.ERROR)
        return
    elseif #targets > 1 then
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.pm.ambiguousTargets", ctxt.sender.lang)
            :var({
                playerList = targets:map(function(p) return p.playerName end)
                    :join(", ")
            }),
            services_chat.COLORS.ERROR)
        return
    end

    local message = table.filter(args, function(_, i) return i > 1 end):join(" ")
    -- sends the message to the target
    services_chat.directSend(targets[1].playerID,
        services_lang.get("chat.command.pm.receivedFrom", targets[1].lang)
        :var({ playerName = ctxt.sender.playerName, message = message }),
        services_chat.COLORS.MP)
    -- sends a copy to the sender
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.pm.sentTo", targets[1].lang)
        :var({ playerName = targets[1].playerName, message = message }),
        services_chat.COLORS.MP)
    if not services_permissions.isStaff(ctxt.sender.playerName) then
        -- if sender is not staff, sends a copy to all staff members
        M.players:filter(function(p)
            return p.playerID ~= ctxt.senderID and
                p.playerID ~= targets[1].playerID and
                services_permissions.isStaff(p.playerName)
        end):forEach(function(p)
            services_chat.directSend(p.playerID,
                services_lang.get("chat.command.pm.sentFromTo", targets[1].lang)
                :var({
                    sender = ctxt.sender.playerName,
                    target = targets[1].playerName,
                    message = message,
                }),
                services_chat.COLORS.DISABLED)
        end)
    end
end

---@param ctxt BJSContext
---@param command BJChatCommand
local function chatCommandUsage(ctxt, command)
    services_chat.directSend(ctxt.senderID,
        string.format("%s : %s -> %s",
            services_lang.get("chat.command.usage", ctxt.sender.lang),
            services_lang.get(command.commandKey, ctxt.sender.lang),
            services_lang.get(command.descKey, ctxt.sender.lang)),
        services_chat.COLORS.ERROR)
end

--- resolves a chat-typed player name to exactly one currently-connected player, sending the
--- appropriate not-found/ambiguous chat feedback itself (mirrors chatPrivateMessage's own inline
--- resolution, factored out since every moderation/utility/teleport chat command below needs the
--- exact same "connected player, fuzzy name, single match required" behavior)
---@param ctxt BJSContext
---@param playerName string
---@return BJSPlayer? target nil if not resolved (an error message has already been sent)
local function resolveChatTarget(ctxt, playerName)
    local targets = M.getConnectedByName(playerName)
    if #targets == 0 then
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.error.invalidTarget", ctxt.sender.lang)
            :var({ playerName = playerName }),
            services_chat.COLORS.ERROR)
        return nil
    elseif #targets > 1 then
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.error.ambiguousTargets", ctxt.sender.lang)
            :var({ playerList = targets:map(function(p) return p.playerName end):join(", ") }),
            services_chat.COLORS.ERROR)
        return nil
    end
    return targets[1]
end

---@param ctxt BJSContext
---@param args string[] "<player_name> [reason...]"
---@param command BJChatCommand
local function chatKick(ctxt, args, command)
    if #args < 1 then return chatCommandUsage(ctxt, command) end
    local target = resolveChatTarget(ctxt, args[1])
    if not target then return end
    local reason = #args > 1 and table.filter(args, function(_, i) return i > 1 end):join(" ") or nil
    M.kick(ctxt, target.playerName, reason)
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.kick.success", ctxt.sender.lang):var({ playerName = target.playerName }))
end

---@param ctxt BJSContext
---@param args string[] "<player_name> [reason...]"
---@param command BJChatCommand
local function chatMute(ctxt, args, command)
    if #args < 1 then return chatCommandUsage(ctxt, command) end
    local target = resolveChatTarget(ctxt, args[1])
    if not target then return end
    local reason = #args > 1 and table.filter(args, function(_, i) return i > 1 end):join(" ") or nil
    M.mute(ctxt, target.playerName, true, reason)
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.mute.success", ctxt.sender.lang):var({ playerName = target.playerName }))
end

---@param ctxt BJSContext
---@param args string[] "<player_name>"
---@param command BJChatCommand
local function chatUnmute(ctxt, args, command)
    if #args < 1 then return chatCommandUsage(ctxt, command) end
    local target = resolveChatTarget(ctxt, args[1])
    if not target then return end
    M.mute(ctxt, target.playerName, false)
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.unmute.success", ctxt.sender.lang):var({ playerName = target.playerName }))
end

---@param ctxt BJSContext
---@param args string[] "<player_name> [reason...]"
---@param command BJChatCommand
local function chatBan(ctxt, args, command)
    if #args < 1 then return chatCommandUsage(ctxt, command) end
    local target = resolveChatTarget(ctxt, args[1])
    if not target then return end
    local reason = #args > 1 and table.filter(args, function(_, i) return i > 1 end):join(" ") or nil
    M.ban(ctxt, target.playerName, reason)
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.ban.success", ctxt.sender.lang):var({ playerName = target.playerName }))
end

---@param ctxt BJSContext
---@param args string[] "<player_name> <seconds> [reason...]"
---@param command BJChatCommand
local function chatTempBan(ctxt, args, command)
    local duration = args[2] and tonumber(args[2])
    if #args < 2 or not duration then return chatCommandUsage(ctxt, command) end
    local target = resolveChatTarget(ctxt, args[1])
    if not target then return end
    local reason = #args > 2 and table.filter(args, function(_, i) return i > 2 end):join(" ") or nil
    M.tempBan(ctxt, target.playerName, duration, reason)
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.tempban.success", ctxt.sender.lang):var({ playerName = target.playerName }))
end

---@param ctxt BJSContext
---@param args string[] "<exact_player_name>"
---@param command BJChatCommand
local function chatUnban(ctxt, args, command)
    if #args < 1 then return chatCommandUsage(ctxt, command) end
    -- a banned target is by definition not connected, so this is the one target-resolution
    -- exception among these commands : exact offline lookup via the database, not
    -- getConnectedByName (which only ever searches currently-connected players)
    if not dao_players.get(args[1]) then
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.error.invalidTarget", ctxt.sender.lang)
            :var({ playerName = args[1] }),
            services_chat.COLORS.ERROR)
        return
    end
    M.unban(ctxt, args[1])
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.unban.success", ctxt.sender.lang):var({ playerName = args[1] }))
end

---@param ctxt BJSContext
---@param args string[] "<player_name> <group>"
---@param command BJChatCommand
local function chatSetGroup(ctxt, args, command)
    if #args < 2 then return chatCommandUsage(ctxt, command) end
    local target = resolveChatTarget(ctxt, args[1])
    if not target then return end
    if not services_groups.getGroupIndex(args[2]) then
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.setgroup.groupNotFound", ctxt.sender.lang)
            :var({ group = args[2] }),
            services_chat.COLORS.ERROR)
        return
    end
    M.setGroup(ctxt, target.playerName, args[2])
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.setgroup.success", ctxt.sender.lang)
        :var({ playerName = target.playerName, group = args[2] }))
end

---@param ctxt BJSContext
---@param args string[] "<player_name>"
---@param command BJChatCommand
local function chatFreeze(ctxt, args, command)
    if #args < 1 then return chatCommandUsage(ctxt, command) end
    local target = resolveChatTarget(ctxt, args[1])
    if not target then return end
    M.toggleFreeze(ctxt, target.playerName)
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.freeze.success", ctxt.sender.lang):var({ playerName = target.playerName }))
end

---@param ctxt BJSContext
---@param args string[] "<player_name>"
---@param command BJChatCommand
local function chatEngine(ctxt, args, command)
    if #args < 1 then return chatCommandUsage(ctxt, command) end
    local target = resolveChatTarget(ctxt, args[1])
    if not target then return end
    M.toggleEngine(ctxt, target.playerName)
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.engine.success", ctxt.sender.lang):var({ playerName = target.playerName }))
end

---@param ctxt BJSContext
---@param args string[] "<player_name>"
---@param command BJChatCommand
local function chatTeleportFrom(ctxt, args, command)
    if #args < 1 then return chatCommandUsage(ctxt, command) end
    local target = resolveChatTarget(ctxt, args[1])
    if not target or target.playerID == ctxt.senderID then return end
    M.teleportFrom(ctxt, target.playerName)
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.tpfrom.success", ctxt.sender.lang):var({ playerName = target.playerName }))
end

--- self-teleport is entirely client-driven (rate limit, permission re-check, and the mid-race
--- block all already live in the client's own beamjoy_players.tryTeleportToPlayer, used
--- unchanged by the existing "Teleport To" UI button): this just tells the issuing player's OWN
--- client to run it, the same call the UI button already makes locally with no server round trip
---@param ctxt BJSContext
---@param args string[] "<player_name>"
---@param command BJChatCommand
local function chatTeleportTo(ctxt, args, command)
    if #args < 1 then return chatCommandUsage(ctxt, command) end
    local target = resolveChatTarget(ctxt, args[1])
    if not target or target.playerID == ctxt.senderID then return end
    communications_tx.sendToPlayer(ctxt.senderID, "chatTeleportTo", target.playerName)
end

---@param playerID integer
---@param message string
---@param messageParams table?
---@param color string? css color instruction
---@param durationSecs number?
local function sendBroadcast(playerID, message, messageParams, color, durationSecs)
    messageParams = messageParams or {}
    color = color or "white"
    durationSecs = durationSecs or 3
    M.players:find(function(p) return p.playerID == playerID end, function(p)
        communications_tx.sendToPlayer(p.playerID, "uiBroadcast", message, messageParams, color, durationSecs)
    end)
end

---@param args string[]
---@param printUsage fun()
local function consoleKick(args, printUsage)
    if not args[1] then return printUsage() end
    local reason = args[2] and
        table.filter(args, function(_, i) return i > 1 end):join(" ") or nil
    local targets = M.getConnectedByName(args[1])
    if #targets == 0 then
        local out = "\n" .. services_lang.get("commands.bjkick.playerNotFound")
        out = out .. "\n" .. services_players.players:keys():join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    elseif #targets > 1 then
        local out = "\n" .. services_lang.get("commands.bjkick.playerAmbiguity")
        out = out .. "\n" .. targets:map(function(p) return p.playerName end):join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    else
        M.kick(targets[1].playerName, reason)
    end
end

---@param args string[]
---@param printUsage fun()
local function consoleBan(args, printUsage)
    if not args[1] then return printUsage() end
    local reason = args[2] and
        table.filter(args, function(_, i) return i > 1 end):join(" ") or nil
    local targets = M.getConnectedByName(args[1])
    if #targets == 0 then
        local out = "\n" .. services_lang.get("commands.bjban.playerNotFound")
        out = out .. "\n" .. services_players.players:keys():join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    elseif #targets > 1 then
        local out = "\n" .. services_lang.get("commands.bjban.playerAmbiguity")
        out = out .. "\n" .. targets:map(function(p) return p.playerName end):join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    else
        M.ban(InitContext(), targets[1].playerName, reason)
    end
end

---@param args string[]
---@param printUsage fun()
local function consoleTempBan(args, printUsage)
    if not args[1] or not args[2] then return printUsage() end
    local delay = tonumber(args[2])
    if not delay then return printUsage() end
    local reason = args[3] and
        table.filter(args, function(_, i) return i > 2 end):join(" ") or nil
    local targets = M.getConnectedByName(args[1])
    if #targets == 0 then
        local out = "\n" .. services_lang.get("commands.bjtempban.playerNotFound")
        out = out .. "\n" .. services_players.players:keys():join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    elseif #targets > 1 then
        local out = "\n" .. services_lang.get("commands.bjtempban.playerAmbiguity")
        out = out .. "\n" .. targets:map(function(p) return p.playerName end):join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    else
        M.tempBan(InitContext(), targets[1].playerName, delay, reason)
    end
end

---@param args string[]
---@param printUsage fun()
local function consoleMute(args, printUsage)
    if not args[1] then return printUsage() end
    local reason = args[2] and
        table.filter(args, function(_, i) return i > 1 end):join(" ") or nil
    local targets = M.getConnectedByName(args[1])
    if #targets == 0 then
        local out = "\n" .. services_lang.get("commands.bjmute.playerNotFound")
        out = out .. "\n" .. services_players.players:keys():join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    elseif #targets > 1 then
        local out = "\n" .. services_lang.get("commands.bjmute.playerAmbiguity")
        out = out .. "\n" .. targets:map(function(p) return p.playerName end):join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    else
        if targets[1].muted then
            return print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
                "\n" .. services_lang.get("commands.bjmute.alreadyMuted" ..
                    GetConsoleColor(CONSOLE_COLORS.STYLES.RESET)))
        end
        M.mute(InitContext(), targets[1].playerName, true, reason)
    end
end

---@param args string[]
---@param printUsage fun()
local function consoleUnmute(args, printUsage)
    if not args[1] then return printUsage() end
    local targets = M.getConnectedByName(args[1])
    if #targets == 0 then
        local out = "\n" .. services_lang.get("commands.bjunmute.playerNotFound")
        out = out .. "\n" .. services_players.players:keys():join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    elseif #targets > 1 then
        local out = "\n" .. services_lang.get("commands.bjunmute.playerAmbiguity")
        out = out .. "\n" .. targets:map(function(p) return p.playerName end):join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    else
        if not targets[1].muted then
            return print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
                "\n" .. services_lang.get("commands.bjunmute.notMuted") ..
                GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
        end
        M.mute(InitContext(), targets[1].playerName, false)
    end
end

---@param args string[]
---@param printUsage fun()
local function consoleGroup(args, printUsage)
    if not args[1] then return printUsage() end
    local targets = M.getConnectedByName(args[1])
    if #targets == 0 then
        local out = "\n" .. services_lang.get("commands.bjgroup.playerNotFound")
        out = out .. "\n" .. services_players.players:keys():join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
        return
    elseif #targets > 1 then
        local out = "\n" .. services_lang.get("commands.bjgroup.playerAmbiguity")
        out = out .. "\n" .. targets:map(function(p) return p.playerName end):join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
        return
    end
    local target = targets[1]
    if not args[2] then
        -- show player group
        local out = "\n" .. services_lang.get("commands.bjgroup.show")
            :var({ playerName = target.playerName, group = target.group })
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_BLUE) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
        return
    end
    local groupIndex = services_groups.getGroupIndex(args[2])
    if not groupIndex then
        local out = "\n" .. services_lang.get("commands.bjgroup.groupNotFound")
        out = out .. "\n" .. table.map(services_groups.data, function(g) return g.name end):join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
        return
    end
    M.setGroup(InitContext(), target.playerName, services_groups.data[groupIndex].name)
end

---@param ctxt BJSContext
local function requestDatabase(ctxt)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.DatabasePlayers) then
        return
    end

    communications_tx.sendToPlayer(ctxt.senderID, "UISend",
        "BJDatabase", {
            players = dao_players.getAll(),
        })
end

M.onPlayerAuth = onPlayerAuth
M.onPlayerConnecting = onPlayerConnecting
M.onPlayerJoining = onPlayerJoining
M.onPlayerJoin = onPlayerJoin
M.onPlayerDisconnect = onPlayerDisconnect
M.onInit = onInit
M.onBJRequestCache = onBJRequestCache

M.savePlayer = savePlayer
M.getAllPlayers = getAllPlayers
M.getConnectedByName = getConnectedByName
M.sendCacheUpdate = sendCacheUpdate
M.toggleFreeze = toggleFreeze
M.toggleEngine = toggleEngine
M.toggleReplayState = toggleReplayState
M.demote = demote
M.promote = promote
M.mute = mute
M.drop = drop
M.kick = kick
M.ban = ban
M.tempBan = tempBan
M.unban = unban
M.setGroup = setGroup
M.setData = setData
M.teleportFrom = teleportFrom
M.chatPrivateMessage = chatPrivateMessage
M.sendBroadcast = sendBroadcast

M.chatKick = chatKick
M.chatMute = chatMute
M.chatUnmute = chatUnmute
M.chatBan = chatBan
M.chatTempBan = chatTempBan
M.chatUnban = chatUnban
M.chatSetGroup = chatSetGroup
M.chatFreeze = chatFreeze
M.chatEngine = chatEngine
M.chatTeleportFrom = chatTeleportFrom
M.chatTeleportTo = chatTeleportTo

M.consoleKick = consoleKick
M.consoleBan = consoleBan
M.consoleTempBan = consoleTempBan
M.consoleMute = consoleMute
M.consoleUnmute = consoleUnmute
M.consoleGroup = consoleGroup

M.requestDatabase = requestDatabase

return M
