--- Vote-kick, ported from BeamJoy Free's VotesManager.Kick onto this fork's own services/dao/
--- communications pattern rather than copied verbatim, mirroring mapVote.lua's own structure and
--- decisions for consistency between the two vote types. BJI itself excludes staff from starting
--- or voting on a kick vote (staff already have direct /kick) ; this fork originally kept that
--- exclusion, but it produced a real, confusing bug in practice: staff (including the server
--- owner) got a bare "insufficient permissions" toast trying to start one, which reads as exactly
--- backwards for someone who has *more* than enough permission, not less. Opened up to everyone
--- instead, matching mapVote.lua's own "any connected player" design: staff not *needing* the
--- softer tool was never a reason to actively prevent them from using it if they want to (e.g.
--- letting the community decide via vote instead of unilaterally kicking).

local M = {
    dependencies = { "services_players", "services_chat", "services_config", "utils_async" },

    ---@type integer? playerID
    creatorID = nil,
    ---@type integer? playerID
    targetID = nil,
    ---@type integer? epoch seconds
    endsAt = nil,
    ---@type tablelib<integer, true> index playerID
    voters = Table(),
}

local function started()
    return M.targetID ~= nil
end

---@return string?
local function targetName()
    if not M.targetID then return nil end
    local ok, name = pcall(MP.GetPlayerName, M.targetID)
    return ok and name or nil
end

--- players eligible to vote : connected, not the target themselves
local function eligibleVoterCount()
    return services_players.players:filter(function(p)
        return p.playerID ~= M.targetID
    end):length()
end

local function getThreshold()
    if not started() then return 0 end
    return math.ceil(eligibleVoterCount() * (services_config.data.Voting.KickVoteThresholdPercent / 100))
end

---@param caches table
local function onBJRequestCache(caches)
    -- visible to everyone, not permission-gated ; see mapVote.lua for why this is always a real
    -- table with an explicit `active` flag rather than plain nil
    caches.kickVote = {
        active = started(),
        creatorName = M.creatorID and MP.GetPlayerName(M.creatorID) or nil,
        targetName = targetName(),
        secondsLeft = M.endsAt and math.max(0, M.endsAt - GetCurrentTime()) or nil,
        threshold = getThreshold(),
        voterNames = M.voters:keys():map(function(pid) return MP.GetPlayerName(pid) end),
    }
end

local function broadcastUpdate()
    services_players.players:forEach(function(p)
        local caches = {}
        onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

local function reset()
    utils_async.removeTask("BJKickVoteTimeout")
    M.creatorID = nil
    M.targetID = nil
    M.endsAt = nil
    M.voters = Table()
    broadcastUpdate()
end

local function endVote()
    local name = targetName()
    if M.voters:length() >= getThreshold() then
        services_chat.sendEvent("beamjoy.chat.event.kickVotePassed", { playerName = name })
        services_players.kick(InitContext(), name, "auth.kick.voteKicked")
    else
        services_chat.sendEvent("beamjoy.chat.event.kickVoteFailed", { playerName = name })
    end
    reset()
end

---@param ctxt BJSContext
---@param targetPlayerID integer
---@return string? error
local function start(ctxt, targetPlayerID)
    if started() then
        return "error.kickVote.alreadyActive"
    elseif targetPlayerID == ctxt.senderID then
        return "error.kickVote.cantTargetSelf"
    end

    M.targetID = targetPlayerID
    if eligibleVoterCount() < 2 then
        M.targetID = nil
        return "error.kickVote.notEnoughPlayers"
    end

    M.creatorID = ctxt.senderID
    M.endsAt = GetCurrentTime() + services_config.data.Voting.KickVoteTimeout
    M.voters = Table({ [ctxt.senderID] = true })
    utils_async.programTask(endVote, M.endsAt, "BJKickVoteTimeout")

    services_chat.sendEvent("beamjoy.chat.event.kickVoteStarted",
        { playerName = ctxt.sender.playerName, target = MP.GetPlayerName(targetPlayerID) })
    broadcastUpdate()
end

---@param ctxt BJSContext
local function vote(ctxt)
    if not started() then return end
    if ctxt.senderID == M.targetID then
        return
    end

    if M.voters[ctxt.senderID] then
        M.voters[ctxt.senderID] = nil
    else
        M.voters[ctxt.senderID] = true
    end

    if M.voters:length() == 0 then
        services_chat.sendEvent("beamjoy.chat.event.kickVoteFailed", { playerName = targetName() })
        reset()
    else
        broadcastUpdate()
    end
end

---@param ctxt BJSContext
---@return string? error
local function stop(ctxt)
    if not started() then return end
    if not services_permissions.isStaff(ctxt.sender.playerName) and
        ctxt.senderID ~= M.creatorID then
        return "error.insufficientPermissions"
    end

    services_chat.sendEvent(ctxt.senderID == M.creatorID and
        "beamjoy.chat.event.kickVoteCancelledByCreator" or "beamjoy.chat.event.kickVoteCancelled",
        { playerName = targetName() })
    reset()
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    if not started() then return end

    if playerID == M.targetID or eligibleVoterCount() < 2 then
        -- target left on their own, or too few eligible voters remain either way
        reset()
        return
    end

    if playerID == M.creatorID then
        services_chat.sendEvent("beamjoy.chat.event.kickVoteCancelledByCreator",
            { playerName = targetName() })
        reset()
        return
    end

    if M.voters[playerID] then
        M.voters[playerID] = nil
        if M.voters:length() == 0 then
            services_chat.sendEvent("beamjoy.chat.event.kickVoteFailed", { playerName = targetName() })
            reset()
        else
            broadcastUpdate()
        end
    end
end

---@param ctxt BJSContext
local function voteKickVote(ctxt)
    vote(ctxt)
end

---@param ctxt BJSContext
local function voteKickStop(ctxt)
    local err = stop(ctxt)
    if err then
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get(err, ctxt.sender.lang))
    end
end

--- UI entry point for starting a vote directly (picking a target from the already-available
--- player list), alongside chatVoteKick's fuzzy-matched "/votekick <name>". Gated on VoteKick same
--- as the chat command's own gate for the start action (join/cancel remain ungated).
---@param ctxt BJSContext
---@param targetPlayerID integer
local function voteKickStart(ctxt, targetPlayerID)
    if not services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.VoteKick) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end

    local err = start(ctxt, targetPlayerID)
    if err then
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get(err, ctxt.sender.lang))
    end
end

--- chat-command front door : "/votekick <player_name>" starts, bare "/votekick" or
--- "/votekick join" toggles the sender's vote on whichever vote is active, "/votekick cancel"
--- stops it (creator or staff only, enforced in stop() itself)
---@param ctxt BJSContext
---@param args string[]
---@param command BJChatCommand
local function chatVoteKick(ctxt, args, command)
    local sub = args[1] and args[1]:lower()
    if not sub or sub == "join" then
        if not started() then
            return services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.votekick.notStarted", ctxt.sender.lang),
                services_chat.COLORS.ERROR)
        end
        return vote(ctxt)
    elseif sub == "cancel" then
        local err = stop(ctxt)
        if err then
            services_chat.directSend(ctxt.senderID, services_lang.get(err, ctxt.sender.lang),
                services_chat.COLORS.ERROR)
        end
        return
    end

    if not services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.VoteKick) then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang),
            services_chat.COLORS.ERROR)
    end

    local targets = services_players.getConnectedByName(args[1])
    if #targets == 0 then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.error.invalidTarget", ctxt.sender.lang)
            :var({ playerName = args[1] }),
            services_chat.COLORS.ERROR)
    elseif #targets > 1 then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.error.ambiguousTargets", ctxt.sender.lang)
            :var({ playerList = targets:map(function(p) return p.playerName end):join(", ") }),
            services_chat.COLORS.ERROR)
    end

    local err = start(ctxt, targets[1].playerID)
    if err then
        services_chat.directSend(ctxt.senderID, services_lang.get(err, ctxt.sender.lang),
            services_chat.COLORS.ERROR)
    end
end

local function onInit()
    communications_rx.addHandler("voteKickVote", voteKickVote)
    communications_rx.addHandler("voteKickStop", voteKickStop)
    communications_rx.addHandler("voteKickStart", voteKickStart)

    services_chatCommands.addCommand("votekick", "chat.command.votekick.desc", M.chatVoteKick,
        { commandKey = "chat.command.votekick.command" })
end

--- keeps the countdown shown on every client in sync, same reasoning as mapVote.lua's own
local function onSlowUpdate()
    if started() then
        broadcastUpdate()
    end
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onSlowUpdate = onSlowUpdate
M.onPlayerDisconnect = onPlayerDisconnect

M.voteKickVote = voteKickVote
M.voteKickStop = voteKickStop
M.voteKickStart = voteKickStart
M.chatVoteKick = chatVoteKick

return M
