--- Map voting, ported from BeamJoy Free's VotesManager.Map (X:\beam\essentials\beamjoy-2.0.8's
--- BJCVote.Map) onto this fork's own services/dao/communications pattern rather than copied
--- verbatim. Any connected player can start a vote (BJI's own model too, not gated behind the
--- mod-only SwitchMap permission direct-switch already uses) ; the actual map change still goes
--- through services_maps.switchMap once the vote passes, so it inherits that function's own
--- mod-archive-swap/reboot/player-kick handling for free.

local M = {
    dependencies = { "services_maps", "services_chat", "services_players", "services_config", "utils_async" },

    ---@type integer? playerID
    creatorID = nil,
    ---@type string? map key
    targetMap = nil,
    ---@type integer? epoch seconds
    endsAt = nil,
    ---@type tablelib<integer, true> index playerID
    voters = Table(),
}

local function started()
    return M.targetMap ~= nil
end

local function getThreshold()
    if not started() then return 0 end
    return math.max(math.ceil(services_players.players:length() *
        (services_config.data.Voting.MapVoteThresholdPercent / 100)), 2)
end

---@param caches table
local function onBJRequestCache(caches)
    -- visible to everyone, not permission-gated : anyone can see/join an active vote.
    -- Always a real table with an explicit `active` flag, never plain nil : sendCache pushes are
    -- per-module partial payloads (this module's own broadcastUpdate() only ever populates its
    -- own `caches.mapVote` key, same as every other service's onBJRequestCache), so a push where
    -- `caches.mapVote` was simply never set is indistinguishable from one explicitly saying "no
    -- vote right now": the client would have no way to tell "ignore this push" from "the vote you
    -- were watching just ended" and would keep showing a stale vote forever after one is cancelled
    -- or resolved.
    caches.mapVote = {
        active = started(),
        creatorName = M.creatorID and MP.GetPlayerName(M.creatorID) or nil,
        targetMap = M.targetMap,
        targetMapLabel = M.targetMap and services_maps.data[M.targetMap] and
            services_maps.data[M.targetMap].label or M.targetMap,
        -- precomputed remaining seconds, not the raw endsAt epoch : the client's own JS clock has
        -- no guaranteed sync with this server's GetCurrentTime(), so let it just display whatever
        -- number this sends rather than diffing two possibly-unrelated clocks
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
    utils_async.removeTask("BJMapVoteTimeout")
    M.creatorID = nil
    M.targetMap = nil
    M.endsAt = nil
    M.voters = Table()
    broadcastUpdate()
end

local function endVote()
    local mapLabel = services_maps.data[M.targetMap] and services_maps.data[M.targetMap].label or M.targetMap
    if M.voters:length() >= getThreshold() then
        services_chat.sendEvent("beamjoy.chat.event.mapVotePassed", { map = mapLabel })
        services_maps.switchMap(InitContext(), M.targetMap)
    else
        services_chat.sendEvent("beamjoy.chat.event.mapVoteFailed", { map = mapLabel })
    end
    reset()
end

---@param ctxt BJSContext
---@param mapName string exact key
---@return string? error
local function start(ctxt, mapName)
    if started() then
        return "error.mapVote.alreadyActive"
    end
    local map = services_maps.data[mapName]
    if not map or not map.enabled or map.ignore then
        return "error.mapVote.mapNotFound"
    elseif mapName == services_core.getCurrentMap() then
        return "error.mapVote.alreadyCurrent"
    end

    if services_players.players:length() <= 1 then
        -- nobody else to vote, switch immediately
        services_maps.switchMap(InitContext(), mapName)
        return
    end

    M.creatorID = ctxt.senderID
    M.targetMap = mapName
    M.endsAt = GetCurrentTime() + services_config.data.Voting.MapVoteTimeout
    M.voters = Table({ [ctxt.senderID] = true })
    utils_async.programTask(endVote, M.endsAt, "BJMapVoteTimeout")

    services_chat.sendEvent("beamjoy.chat.event.mapVoteStarted",
        { playerName = ctxt.sender.playerName, map = map.label })
    broadcastUpdate()
end

---@param ctxt BJSContext
local function vote(ctxt)
    if not started() then return end

    if M.voters[ctxt.senderID] then
        M.voters[ctxt.senderID] = nil
    else
        M.voters[ctxt.senderID] = true
    end

    if M.voters:length() == 0 then
        local mapLabel = services_maps.data[M.targetMap] and services_maps.data[M.targetMap].label or M.targetMap
        services_chat.sendEvent("beamjoy.chat.event.mapVoteFailed", { map = mapLabel })
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

    local mapLabel = services_maps.data[M.targetMap] and services_maps.data[M.targetMap].label or M.targetMap
    services_chat.sendEvent(ctxt.senderID == M.creatorID and
        "beamjoy.chat.event.mapVoteCancelledByCreator" or "beamjoy.chat.event.mapVoteCancelled",
        { map = mapLabel })
    reset()
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    if not started() then return end

    if playerID == M.creatorID then
        local mapLabel = services_maps.data[M.targetMap] and services_maps.data[M.targetMap].label or M.targetMap
        services_chat.sendEvent("beamjoy.chat.event.mapVoteCancelledByCreator", { map = mapLabel })
        reset()
        return
    end

    if M.voters[playerID] then
        M.voters[playerID] = nil
        if M.voters:length() == 0 then
            local mapLabel = services_maps.data[M.targetMap] and services_maps.data[M.targetMap].label or M.targetMap
            services_chat.sendEvent("beamjoy.chat.event.mapVoteFailed", { map = mapLabel })
            reset()
        else
            broadcastUpdate()
        end
    end
end

---@param query string
---@return string[] matches map keys
local function resolveMapName(query)
    if services_maps.data[query] then
        return { query }
    end
    return table.keys(services_maps.data):filter(function(name)
        local map = services_maps.data[name]
        return map.enabled and not map.ignore and
            tostring(name):lower():find(query:lower()) ~= nil
    end)
end

---@param ctxt BJSContext
local function voteMapVote(ctxt)
    vote(ctxt)
end

---@param ctxt BJSContext
local function voteMapStop(ctxt)
    local err = stop(ctxt)
    if err then
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get(err, ctxt.sender.lang))
    end
end

--- UI entry point for starting a vote directly (a map picker offering real, exact map keys), as
--- an alternative front door to chatVoteMap's fuzzy-matched "/votemap <name>" for players without
--- direct chat-command usage in mind. Gated on VoteMap same as the chat command's own gate for the
--- start action (join/cancel remain ungated, matching chatVoteMap).
---@param ctxt BJSContext
---@param mapName string exact key
local function voteMapStart(ctxt, mapName)
    if not services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.VoteMap) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end

    local err = start(ctxt, mapName)
    if err then
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get(err, ctxt.sender.lang))
    end
end

--- chat-command front door : "/votemap <map_name>" starts (or fuzzy-matches) a vote, bare
--- "/votemap" or "/votemap join" toggles the sender's vote on whichever vote is currently active,
--- "/votemap cancel" stops it (creator or staff only, enforced in stop() itself)
---@param ctxt BJSContext
---@param args string[]
---@param command BJChatCommand
local function chatVoteMap(ctxt, args, command)
    local sub = args[1] and args[1]:lower()
    if not sub or sub == "join" then
        if not started() then
            return services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.votemap.notStarted", ctxt.sender.lang),
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

    if not services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.VoteMap) then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang),
            services_chat.COLORS.ERROR)
    end

    local matches = resolveMapName(args[1])
    if #matches == 0 then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("commands.map.notFound", ctxt.sender.lang),
            services_chat.COLORS.ERROR)
    elseif #matches > 1 then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("commands.map.ambiguous", ctxt.sender.lang)
            .. "\n" .. matches:sort():join(", "),
            services_chat.COLORS.ERROR)
    end

    local err = start(ctxt, matches[1])
    if err then
        services_chat.directSend(ctxt.senderID, services_lang.get(err, ctxt.sender.lang),
            services_chat.COLORS.ERROR)
    end
end

local function onInit()
    communications_rx.addHandler("voteMapVote", voteMapVote)
    communications_rx.addHandler("voteMapStop", voteMapStop)
    communications_rx.addHandler("voteMapStart", voteMapStart)

    services_chatCommands.addCommand("votemap", "chat.command.votemap.desc", M.chatVoteMap,
        { commandKey = "chat.command.votemap.command" })
end

--- keeps the countdown shown on every client in sync with the actual remaining time without
--- requiring the client to compute it locally, matching this codebase's general "push state,
--- don't make the client derive it" convention
local function onSlowUpdate()
    if started() then
        broadcastUpdate()
    end
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onSlowUpdate = onSlowUpdate
M.onPlayerDisconnect = onPlayerDisconnect

M.voteMapVote = voteMapVote
M.voteMapStop = voteMapStop
M.voteMapStart = voteMapStart
M.chatVoteMap = chatVoteMap

return M
