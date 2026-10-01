--- Invites into a race, hunter or infected lobby (the convoy's own invites live in
--- services/deliveries.lua). Any participant of a lobby that's still forming and joinable can
--- invite a free player ; the invitee's client shows it in BJS's notification stack, and
--- accepting simply joins through the activity's normal join handler (raceJoin / hunterJoin /
--- infectedJoin), which re-checks everything. Invites expire after INVITE_SEC.
---
--- Wire : lobbyInviteList(kind) -> lobbyInviteList {kind, players = {playerID, name, busy,
--- invited}} ; lobbyInvite(kind, targetID) -> the target gets lobbyInvite {kind, sessionId,
--- fromName, title, count, max, expiresIn}, the sender a fresh lobbyInviteList.

local M = {
    -- an unanswered invite lapses after this : the sender's picker offers Invite again
    INVITE_SEC = 15,
    --- targetID -> { kind -> { sessionId, expiresAt } }
    ---@type table<integer, table<string, {sessionId: string, expiresAt: number}>>
    invites = {},
}

--- per kind : the grid service and the lobby state name
local KINDS = {
    race = { grid = function() return services_raceGrid end, lobby = "GRID" },
    hunter = { grid = function() return services_hunterGrid end, lobby = "LOBBY" },
    infected = { grid = function() return services_infectedGrid end, lobby = "LOBBY" },
    derby = { grid = function() return services_derbyGrid end, lobby = "LOBBY" },
}

---@param playerID integer
---@return boolean in any activity (a lobby, a game, a delivery or a convoy)
local function isBusy(playerID)
    for _, k in pairs(KINDS) do
        local grid = k.grid()
        if grid and grid.findSessionByParticipant and grid.findSessionByParticipant(playerID) then
            return true
        end
    end
    return services_deliveries ~= nil and services_deliveries.isBusy ~= nil and services_deliveries.isBusy(playerID)
end

---@param playerID integer
---@return string? key the activity the player is in ("race:<id>", "convoy:<id>"...), the same for
---everyone in it ; nil when free (a solo delivery is its own)
local function activityOf(playerID)
    for kind, k in pairs(KINDS) do
        local grid = k.grid()
        local session = grid and grid.findSessionByParticipant and grid.findSessionByParticipant(playerID)
        if session then return kind .. ":" .. tostring(session.id) end
    end
    local d = services_deliveries
    if d and d.memberOf and d.memberOf[playerID] ~= nil then return "convoy:" .. tostring(d.memberOf[playerID]) end
    if d and d.jobs and d.jobs[playerID] ~= nil then return "job:" .. tostring(playerID) end
    return nil
end

---@param kind string
---@param playerID integer
---@return table? session the sender's own lobby of that kind, still forming and joinable
local function ownLobby(kind, playerID)
    local k = KINDS[kind]
    if not k then return nil end
    local grid = k.grid()
    local session = grid and grid.findSessionByParticipant and grid.findSessionByParticipant(playerID)
    if not session or session.state ~= k.lobby or not session.joinable then return nil end
    return session
end

---@param kind string
---@param targetID integer
---@param sessionId string
---@return boolean
local function isInvited(kind, targetID, sessionId)
    local entry = M.invites[targetID] and M.invites[targetID][kind]
    return entry ~= nil and entry.sessionId == sessionId and entry.expiresAt > GetCurrentTime()
end

---@param ctxt BJSContext
---@param kind string
local function lobbyInviteList(ctxt, kind)
    if not ctxt.sender then return end
    local session = ownLobby(kind, ctxt.senderID)
    if not session then return end
    local list = {}
    services_players.players:forEach(function(p)
        if p.playerID ~= ctxt.senderID and not session.participants[p.playerID] then
            list[#list + 1] = {
                playerID = p.playerID,
                name = p.displayName or p.playerName,
                busy = isBusy(p.playerID),
                invited = isInvited(kind, p.playerID, session.id),
            }
        end
    end)
    table.sort(list, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    communications_tx.sendToPlayer(ctxt.senderID, "lobbyInviteList", { kind = kind, players = list })
end

---@param ctxt BJSContext
---@param kind string
---@param targetID integer
local function lobbyInvite(ctxt, kind, targetID)
    if not ctxt.sender then return end
    targetID = tonumber(targetID)
    local session = ownLobby(kind, ctxt.senderID)
    if not session or not targetID or targetID == ctxt.senderID or session.participants[targetID] then return end
    local target = services_players.players:find(function(p) return p.playerID == targetID end)
    if not target or isBusy(targetID) then return lobbyInviteList(ctxt, kind) end
    local summary = KINDS[kind].grid().summarize(session)
    if (summary.maxParticipants or 0) > 0 and (summary.participantCount or 0) >= summary.maxParticipants then
        return lobbyInviteList(ctxt, kind)
    end
    M.invites[targetID] = M.invites[targetID] or {}
    M.invites[targetID][kind] = { sessionId = session.id, expiresAt = GetCurrentTime() + M.INVITE_SEC }
    communications_tx.sendToPlayer(targetID, "lobbyInvite", {
        kind = kind,
        sessionId = session.id,
        fromName = ctxt.sender.displayName or ctxt.sender.playerName,
        title = summary.raceName,
        count = summary.participantCount,
        max = summary.maxParticipants,
        expiresIn = M.INVITE_SEC,
    })
    lobbyInviteList(ctxt, kind)
end

local function onSlowUpdate()
    local now = GetCurrentTime()
    for targetID, byKind in pairs(M.invites) do
        for kind, entry in pairs(byKind) do
            if entry.expiresAt <= now then byKind[kind] = nil end
        end
        if next(byKind) == nil then M.invites[targetID] = nil end
    end
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.invites[playerID] = nil
end

local function onInit()
    communications_rx.addHandler("lobbyInviteList", M.lobbyInviteList)
    communications_rx.addHandler("lobbyInvite", M.lobbyInvite)
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate
M.onPlayerDisconnect = onPlayerDisconnect
M.lobbyInviteList = lobbyInviteList
M.lobbyInvite = lobbyInvite
M.isBusy = isBusy
M.activityOf = activityOf
M.isInvited = isInvited

return M
