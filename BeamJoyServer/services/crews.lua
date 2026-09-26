--- Crews : a small party (up to MAX players) that rides together. When the crew's leader opens a
--- race, hunter or infected lobby, or a delivery convoy, every crewmate who's online and free is
--- joined into it (pullIn, called by the grids and deliveries) ; busy ones skip that one.
---
--- Crews live in memory until the server restarts, kept by player name : a member who
--- disconnects is still in the crew when they come back. A leader who leaves hands the crew to
--- the next member (an online one first) ; an empty crew is gone.
---
--- Joining : an open crew takes anyone ; otherwise a player asks to join (the leader accepts or
--- declines) or the leader invites them (the invitee's notification stack, beamjoy/notices.lua).
---
--- Wire : crewStateRequest -> crewState (your crew, or nil) + crewList (every crew) ;
--- crewCreate(name), crewLeave, crewJoin(crewId), crewRequestReply(name, accept),
--- crewKick(name), crewPromote(name), crewSetOpen(open), crewInviteList -> crewInviteList,
--- crewInvite(targetID) -> the target gets crewInvite {crewId, fromName, title, count, max,
--- expiresIn}, crewInviteReply(crewId, accept).

local M = {
    MAX = 8,
    INVITE_SEC = 30,
    REQUEST_SEC = 120,
    NAME_MAX = 24,
    ---@type table<integer, BJCrew>
    crews = {},
    nextId = 1,
    --- targetName -> { crewId, expiresAt }
    invites = {},
    --- crewId -> signature of the last pushed state (the slow update pushes on change)
    lastPushed = {},
}

---@class BJCrew
---@field id integer
---@field name string
---@field leader string playerName
---@field members string[] playerNames, in join order
---@field open boolean anyone can join without asking
---@field requests table<string, number> playerName -> expiresAt

---@param playerName string
---@return BJSPlayer? connected
local function online(playerName)
    return services_players.players[playerName]
end

---@param playerID integer
---@return BJSPlayer?
local function byID(playerID)
    return services_players.players:find(function(p) return p.playerID == playerID end)
end

---@param playerName string
---@return BJCrew?
local function crewOfName(playerName)
    for _, c in pairs(M.crews) do
        if table.includes(c.members, playerName) then return c end
    end
    return nil
end

---@param playerID integer
---@return BJCrew?
local function crewOf(playerID)
    local p = byID(playerID)
    return p and crewOfName(p.playerName) or nil
end

---@param aID integer
---@param bID integer
---@return boolean
local function sameCrew(aID, bID)
    local c = crewOf(aID)
    return c ~= nil and c == crewOf(bID)
end

---@param playerName string
---@return "offline"|"busy"|"free"
---@param playerName string
---@param viewerName string? who's looking : a crewmate in the same activity as them is "with you",
---not busy
local function memberStatus(playerName, viewerName)
    local p = online(playerName)
    if not p then return "offline" end
    if services_lobbyInvites.isBusy(p.playerID) then
        local viewer = viewerName and viewerName ~= playerName and online(viewerName)
        local mine = viewer and services_lobbyInvites.activityOf(viewer.playerID)
        if mine and mine == services_lobbyInvites.activityOf(p.playerID) then return "withYou" end
        return "busy"
    end
    return "free"
end

---@param playerName string
---@return string
local function displayName(playerName)
    local p = online(playerName)
    return p and p.displayName or playerName
end

---@param c BJCrew
---@param except string?
---@return string? the first online member (in join order) other than `except`
local function firstOnline(c, except)
    for _, name in ipairs(c.members) do
        if name ~= except and online(name) then return name end
    end
    return nil
end

---@param c BJCrew
local function summary(c)
    return {
        id = c.id,
        name = c.name,
        leaderName = displayName(c.leader),
        count = #c.members,
        max = M.MAX,
        open = c.open,
        -- the Players tab offers "Invite to crew" only to players in no crew
        memberNames = c.members,
    }
end

---@param c BJCrew
---@param forName string the member it's sent to (the leader also gets the requests)
local function statePayload(c, forName)
    local members = {}
    for _, name in ipairs(c.members) do
        members[#members + 1] = {
            playerName = name,
            displayName = displayName(name),
            status = memberStatus(name, forName),
            leader = name == c.leader,
            you = name == forName,
        }
    end
    local requests = {}
    if forName == c.leader then
        for name, expiresAt in pairs(c.requests) do
            if expiresAt > GetCurrentTime() then
                requests[#requests + 1] = { playerName = name, displayName = displayName(name) }
            end
        end
        table.sort(requests, function(a, b) return a.playerName < b.playerName end)
    end
    return {
        id = c.id,
        name = c.name,
        open = c.open,
        max = M.MAX,
        isLeader = forName == c.leader,
        members = members,
        requests = requests,
    }
end

---@param c BJCrew
---@return string
local function signature(c)
    local parts = { c.name, c.leader, tostring(c.open) }
    for _, name in ipairs(c.members) do
        local p = online(name)
        local activity = p and services_lobbyInvites.activityOf(p.playerID) or ""
        parts[#parts + 1] = name .. ":" .. memberStatus(name) .. ":" .. activity
    end
    for name in pairs(c.requests) do parts[#parts + 1] = "?" .. name end
    return table.concat(parts, "|")
end

local function broadcastList()
    local list = {}
    for _, c in pairs(M.crews) do list[#list + 1] = summary(c) end
    table.sort(list, function(a, b) return a.id < b.id end)
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "crewList", list)
end

---@param c BJCrew
local function pushState(c)
    M.lastPushed[c.id] = signature(c)
    for _, name in ipairs(c.members) do
        local p = online(name)
        if p then communications_tx.sendToPlayer(p.playerID, "crewState", statePayload(c, name)) end
    end
end

---@param playerName string
local function pushNoCrew(playerName)
    local p = online(playerName)
    if p then communications_tx.sendToPlayer(p.playerID, "crewState", nil) end
end

---@param playerName string
---@param key string
---@param vars table?
local function toast(playerName, key, vars)
    local p = online(playerName)
    if not p then return end
    local text = services_lang.get(key, p.lang)
    if vars then text = text:var(vars) end
    communications_tx.sendToPlayer(p.playerID, "toast", "info", text)
end

---@param c BJCrew
---@param playerName string
local function addMember(c, playerName)
    c.members[#c.members + 1] = playerName
    c.requests[playerName] = nil
    M.invites[playerName] = nil
    -- asking other crews is moot now
    for _, other in pairs(M.crews) do other.requests[playerName] = nil end
    for _, name in ipairs(c.members) do
        if name ~= playerName then toast(name, "crew.joined", { name = displayName(playerName) }) end
    end
    pushState(c)
    broadcastList()
end

---@param c BJCrew
---@param playerName string
local function removeMember(c, playerName)
    local i = table.indexOf(c.members, playerName)
    if not i then return end
    table.remove(c.members, i)
    pushNoCrew(playerName)
    if #c.members == 0 then
        M.crews[c.id] = nil
        M.lastPushed[c.id] = nil
        return broadcastList()
    end
    if c.leader == playerName then
        -- an online member first, else whoever joined next
        c.leader = firstOnline(c) or c.members[1]
        toast(c.leader, "crew.nowLeader")
    end
    pushState(c)
    broadcastList()
end

---@param ctxt BJSContext
---@return BJCrew?
local function leaderCrew(ctxt)
    local c = ctxt.sender and crewOfName(ctxt.sender.playerName)
    if c and c.leader == ctxt.sender.playerName then return c end
    return nil
end

-- HANDLERS --------------------------------------------------------------------------------------

---@param ctxt BJSContext
local function crewStateRequest(ctxt)
    if not ctxt.sender then return end
    local c = crewOfName(ctxt.sender.playerName)
    communications_tx.sendToPlayer(ctxt.senderID, "crewState", c and statePayload(c, ctxt.sender.playerName) or nil)
    local list = {}
    for _, crew in pairs(M.crews) do list[#list + 1] = summary(crew) end
    table.sort(list, function(a, b) return a.id < b.id end)
    communications_tx.sendToPlayer(ctxt.senderID, "crewList", list)
end

---@param ctxt BJSContext
---@param name string?
local function crewCreate(ctxt, name)
    if not ctxt.sender or crewOfName(ctxt.sender.playerName) then return end
    name = type(name) == "string" and name:trim() or ""
    if #name == 0 then
        name = services_lang.get("crew.defaultName", ctxt.sender.lang)
            :var({ name = ctxt.sender.displayName or ctxt.sender.playerName })
    end
    ---@type BJCrew
    local c = {
        id = M.nextId,
        name = name:sub(1, M.NAME_MAX),
        leader = ctxt.sender.playerName,
        members = {},
        open = false,
        requests = {},
    }
    M.nextId = M.nextId + 1
    M.crews[c.id] = c
    addMember(c, ctxt.sender.playerName)
end

---@param ctxt BJSContext
local function crewLeave(ctxt)
    if not ctxt.sender then return end
    local c = crewOfName(ctxt.sender.playerName)
    if c then removeMember(c, ctxt.sender.playerName) end
end

---@param ctxt BJSContext
---@param crewId integer
local function crewJoin(ctxt, crewId)
    if not ctxt.sender or crewOfName(ctxt.sender.playerName) then return end
    local c = M.crews[tonumber(crewId) or -1]
    if not c then return end
    if #c.members >= M.MAX then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("crew.full", ctxt.sender.lang))
    end
    local invite = M.invites[ctxt.sender.playerName]
    if c.open or (invite and invite.crewId == c.id and invite.expiresAt > GetCurrentTime()) then
        return addMember(c, ctxt.sender.playerName)
    end
    -- a closed crew : ask its leader
    c.requests[ctxt.sender.playerName] = GetCurrentTime() + M.REQUEST_SEC
    toast(c.leader, "crew.requested", { name = ctxt.sender.displayName or ctxt.sender.playerName })
    toast(ctxt.sender.playerName, "crew.requestSent", { crew = c.name })
    pushState(c)
end

---@param ctxt BJSContext
---@param playerName string
---@param accept boolean
local function crewRequestReply(ctxt, playerName, accept)
    local c = leaderCrew(ctxt)
    if not c or not c.requests[playerName] then return end
    c.requests[playerName] = nil
    if accept and #c.members < M.MAX and not crewOfName(playerName) then
        return addMember(c, playerName)
    end
    if not accept then toast(playerName, "crew.requestDeclined", { crew = c.name }) end
    pushState(c)
end

---@param ctxt BJSContext
---@param playerName string
local function crewKick(ctxt, playerName)
    local c = leaderCrew(ctxt)
    if not c or playerName == c.leader or not table.includes(c.members, playerName) then return end
    toast(playerName, "crew.removed", { crew = c.name })
    removeMember(c, playerName)
end

---@param ctxt BJSContext
---@param playerName string
local function crewPromote(ctxt, playerName)
    local c = leaderCrew(ctxt)
    if not c or playerName == c.leader or not table.includes(c.members, playerName) then return end
    c.leader = playerName
    toast(playerName, "crew.nowLeader")
    pushState(c)
    broadcastList()
end

---@param ctxt BJSContext
---@param open boolean
local function crewSetOpen(ctxt, open)
    local c = leaderCrew(ctxt)
    if not c then return end
    c.open = open == true
    pushState(c)
    broadcastList()
end

---@param ctxt BJSContext
local function crewInviteList(ctxt)
    local c = leaderCrew(ctxt)
    if not c then return end
    local now = GetCurrentTime()
    local list = {}
    services_players.players:forEach(function(p)
        if p.playerID == ctxt.senderID then return end
        local other = crewOfName(p.playerName)
        local invite = M.invites[p.playerName]
        list[#list + 1] = {
            playerID = p.playerID,
            name = p.displayName or p.playerName,
            inCrew = other ~= nil,
            invited = invite ~= nil and invite.crewId == c.id and invite.expiresAt > now,
        }
    end)
    table.sort(list, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    communications_tx.sendToPlayer(ctxt.senderID, "crewInviteList", { players = list, full = #c.members >= M.MAX })
end

---@param ctxt BJSContext
---@param targetID integer
local function crewInvite(ctxt, targetID)
    local c = leaderCrew(ctxt)
    targetID = tonumber(targetID)
    if not c or not targetID or targetID == ctxt.senderID then return end
    local target = byID(targetID)
    if not target or crewOfName(target.playerName) or #c.members >= M.MAX then return crewInviteList(ctxt) end
    M.invites[target.playerName] = { crewId = c.id, expiresAt = GetCurrentTime() + M.INVITE_SEC }
    communications_tx.sendToPlayer(targetID, "crewInvite", {
        crewId = c.id,
        fromName = ctxt.sender.displayName or ctxt.sender.playerName,
        title = c.name,
        count = #c.members,
        max = M.MAX,
        expiresIn = M.INVITE_SEC,
    })
    crewInviteList(ctxt)
end

---@param ctxt BJSContext
---@param crewId integer
---@param accept boolean
local function crewInviteReply(ctxt, crewId, accept)
    if not ctxt.sender then return end
    local invite = M.invites[ctxt.sender.playerName]
    if not invite or invite.crewId ~= tonumber(crewId) then return end
    if not accept then
        M.invites[ctxt.sender.playerName] = nil
        return
    end
    crewJoin(ctxt, invite.crewId)
end

-- PULL ------------------------------------------------------------------------------------------

---@param leaderID integer
---@return string[] names of the leader's crewmates who are online and free
local function freeCrewmates(leaderID)
    local c = crewOf(leaderID)
    local leader = byID(leaderID)
    if not c or not leader or c.leader ~= leader.playerName then return {} end
    local names = {}
    for _, name in ipairs(c.members) do
        if name ~= c.leader and memberStatus(name) == "free" then names[#names + 1] = name end
    end
    return names
end

--- how many players the leader's crew would bring (the leader plus free crewmates) ; 1 when
--- they don't lead a crew
---@param leaderID integer
---@return integer
local function pullSize(leaderID)
    return 1 + #freeCrewmates(leaderID)
end

--- the crew's leader just opened a lobby : join every free crewmate into it through the
--- activity's own join handler (which re-checks everything, a full lobby included)
---@param leaderID integer
---@param kind "race"|"hunter"|"infected"|"convoy"
---@param sessionId any
local function pullIn(leaderID, kind, sessionId)
    local names = freeCrewmates(leaderID)
    if #names == 0 then return end
    local leader = byID(leaderID)
    local join = ({
        race = function(ctxt) services_raceGrid.raceJoin(ctxt, sessionId) end,
        hunter = function(ctxt) services_hunterGrid.hunterJoin(ctxt, sessionId) end,
        infected = function(ctxt) services_infectedGrid.infectedJoin(ctxt, sessionId) end,
        convoy = function(ctxt) services_deliveries.deliveryConvoyJoin(ctxt, sessionId) end,
    })[kind]
    if not join then return end
    local leaderName = leader and (leader.displayName or leader.playerName) or "?"
    -- the lobby's name, for the notice (a convoy's job shows in its own lobby panel)
    local title
    local grid = ({ race = services_raceGrid, hunter = services_hunterGrid, infected = services_infectedGrid })[kind]
    if grid and grid.sessions and grid.sessions[sessionId] and grid.summarize then
        title = grid.summarize(grid.sessions[sessionId]).raceName
    end
    for _, name in ipairs(names) do
        local p = online(name)
        if p then
            join(InitContext(p.playerID))
            if services_lobbyInvites.isBusy(p.playerID) then
                -- the notification stack's "joined with your crew" notice (beamjoy/notices.lua)
                communications_tx.sendToPlayer(p.playerID, "crewPulled", {
                    kind = kind,
                    sessionId = sessionId,
                    fromName = leaderName,
                    title = title,
                })
            else
                toast(name, "crew.noRoom", { name = leaderName })
            end
        end
    end
    local c = crewOf(leaderID)
    if c then pushState(c) end
end

-- LIFECYCLE -------------------------------------------------------------------------------------

local function onSlowUpdate()
    local now = GetCurrentTime()
    for name, invite in pairs(M.invites) do
        if invite.expiresAt <= now or not M.crews[invite.crewId] then M.invites[name] = nil end
    end
    for _, c in pairs(M.crews) do
        for name, expiresAt in pairs(c.requests) do
            if expiresAt <= now or crewOfName(name) then c.requests[name] = nil end
        end
        -- a leader who went offline hands the crew to an online member (they stay a member)
        if not online(c.leader) then
            local next = firstOnline(c, c.leader)
            if next then
                c.leader = next
                toast(next, "crew.nowLeader")
                broadcastList()
            end
        end
        -- members come online, go offline, start and finish activities
        if M.lastPushed[c.id] ~= signature(c) then pushState(c) end
    end
end

local function onInit()
    communications_rx.addHandler("crewStateRequest", M.crewStateRequest)
    communications_rx.addHandler("crewCreate", M.crewCreate)
    communications_rx.addHandler("crewLeave", M.crewLeave)
    communications_rx.addHandler("crewJoin", M.crewJoin)
    communications_rx.addHandler("crewRequestReply", M.crewRequestReply)
    communications_rx.addHandler("crewKick", M.crewKick)
    communications_rx.addHandler("crewPromote", M.crewPromote)
    communications_rx.addHandler("crewSetOpen", M.crewSetOpen)
    communications_rx.addHandler("crewInviteList", M.crewInviteList)
    communications_rx.addHandler("crewInvite", M.crewInvite)
    communications_rx.addHandler("crewInviteReply", M.crewInviteReply)
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate
M.crewStateRequest = crewStateRequest
M.crewCreate = crewCreate
M.crewLeave = crewLeave
M.crewJoin = crewJoin
M.crewRequestReply = crewRequestReply
M.crewKick = crewKick
M.crewPromote = crewPromote
M.crewSetOpen = crewSetOpen
M.crewInviteList = crewInviteList
M.crewInvite = crewInvite
M.crewInviteReply = crewInviteReply
M.crewOf = crewOf
M.sameCrew = sameCrew
M.pullSize = pullSize
M.pullIn = pullIn

return M
