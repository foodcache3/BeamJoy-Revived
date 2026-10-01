--- BJS's notification stack, beside the main window's rail (windows/notices) : race, hunter and
--- infected lobbies you could join. Two kinds of notice :
---   * invite   : a player invited you into their lobby (services/lobbyInvites.lua, lobbyInvite)
---   * announce : someone opened a lobby (the runners' onSessionsList, replacing the old centre
---                screen "X started a race" text)
--- Each has Join and Dismiss. The convoy invite stays delivery.lua's own, drawn in the same stack.
--- Crew invites (services/crews.lua, kind "crew") ride along : they stay while you're busy, and
--- joining opens the Crew tab. So does "pulled" : your crew's leader brought you into their lobby
--- (or convoy) ; A opens it in the main window, and it goes away once you're out of it.
--- "results" : a game you played just ended (the runners call results()) ; A opens its results
--- (the UI side opens the info panel, see windows/notices).
---
--- Pad : like the convoy invite, a notice only takes A / B once focused with the Focus
--- notification control (beamjoy/mainNav.lua walks delivery's invite first, then these). A joins
--- the top notice, B dismisses it. Joining opens the lobby in the main window (Activities).
---
--- Also relays the lobby invite picker's list (lobbyInviteList) and sends invites for the lobby
--- panels (BJLobbyInviteList / BJLobbyInvite).

local M = {
    dependencies = { "beamjoy_communications", "beamjoy_communications_ui", "beamjoy_uiNav" },
    OWNER = "notices",
    INVITE_SEC = 20,
    ANNOUNCE_SEC = 12,
    PULLED_SEC = 15,
    RESULTS_SEC = 30,
    ---@type table[] newest first : {id, type, kind, sessionId, fromName, title, count, max, expiresAtMs}
    list = {},
    focused = false,
    padActive = false,
    lastPush = 0,
}

--- per activity : the runner that knows its open sessions and your own, the join event, the
--- Activities section, the lobby state name
local KINDS = {
    race = { runner = function() return beamjoy_raceRunner end, join = "BJRaceJoin", section = "races", lobby = "GRID" },
    hunter = { runner = function() return beamjoy_hunterRunner end, join = "BJHunterJoin", section = "hunter", lobby = "LOBBY" },
    infected = { runner = function() return beamjoy_infectedRunner end, join = "BJInfectedJoin", section = "infected", lobby = "LOBBY" },
    derby = { runner = function() return beamjoy_derbyRunner end, join = "BJDerbyJoin", section = "derby", lobby = "LOBBY" },
}

---@return boolean in any activity : notices would only be noise
local function busy()
    for _, k in pairs(KINDS) do
        local runner = k.runner()
        if runner and runner.session then return true end
    end
    return beamjoy_delivery ~= nil and (beamjoy_delivery.job ~= nil or beamjoy_delivery.lobby ~= nil)
end

--- the notice's session, if it's still a lobby you could join
---@param n table
---@return table?
--- the section and whether you're still in that lobby, for a "pulled" notice
local PULLED = {
    race = { section = "races", runner = function() return beamjoy_raceRunner end, lobby = "GRID" },
    hunter = { section = "hunter", runner = function() return beamjoy_hunterRunner end, lobby = "LOBBY" },
    infected = { section = "infected", runner = function() return beamjoy_infectedRunner end, lobby = "LOBBY" },
    derby = { section = "derby", runner = function() return beamjoy_derbyRunner end, lobby = "LOBBY" },
    convoy = { section = "jobs" },
}

---@param n table a "pulled" notice
---@return boolean
local function stillIn(n)
    if n.kind == "convoy" then
        local l = beamjoy_delivery and beamjoy_delivery.lobby
        return l ~= nil and l.id == n.sessionId
    end
    local k = PULLED[n.kind]
    local runner = k and k.runner and k.runner()
    local s = runner and runner.session
    return s ~= nil and s.id == n.sessionId and s.state == k.lobby
end

local function liveSession(n)
    if n.type == "results" then return {} end
    if n.type == "pulled" then
        -- the lobby's own (bigger, maybe chunked) update can land just after this notice : give
        -- it a moment before deciding you're not in it
        local settling = GetCurrentTimeMillis() - (n.addedAtMs or 0) < 3000
        return (stillIn(n) or settling) and {} or nil
    end
    if n.kind == "crew" then
        return beamjoy_crews and beamjoy_crews.joinable(n.sessionId) and {} or nil
    end
    local k = KINDS[n.kind]
    local runner = k and k.runner()
    for _, s in ipairs(runner and runner.openSessions or {}) do
        if s.id == n.sessionId then
            return (s.state == k.lobby and s.joinable ~= false) and s or nil
        end
    end
    return nil
end

local function push()
    M.lastPush = GetCurrentTimeMillis()
    local now = GetCurrentTimeMillis()
    local items = {}
    for _, n in ipairs(M.list) do
        local s = liveSession(n)
        items[#items + 1] = {
            id = n.id,
            type = n.type,
            kind = n.kind,
            fromName = n.fromName,
            title = n.title or (s and s.raceName),
            count = s and s.participantCount or n.count,
            max = s and s.maxParticipants or n.max,
            expiresIn = math.max(0, (n.expiresAtMs - now) / 1000),
            total = n.total or (n.type == "invite" and M.INVITE_SEC or M.ANNOUNCE_SEC),
        }
    end
    beamjoy_communications_ui.send("BJNotices", { items = items, padActive = M.padActive })
end

---@param id string
local function remove(id)
    for i, n in ipairs(M.list) do
        if n.id == id then
            table.remove(M.list, i)
            break
        end
    end
    if #M.list == 0 then M.focused = false end
end

---@param notice table
local function add(notice)
    -- one notice per lobby : an invite replaces the announcement
    for i = #M.list, 1, -1 do
        local n = M.list[i]
        if n.kind == notice.kind and n.sessionId == notice.sessionId then
            if n.type == "invite" and notice.type == "announce" then return end
            table.remove(M.list, i)
        end
    end
    notice.id = notice.kind .. ":" .. tostring(notice.sessionId)
    table.insert(M.list, 1, notice)
    push()
end

--- someone opened a lobby (called by the runners for each newly listed session)
---@param kind "race"|"hunter"|"infected"|"derby"
---@param session table the runner's open-session summary
local function announce(kind, session)
    local k = KINDS[kind]
    if not k or session.state ~= k.lobby or session.joinable == false or busy() then return end
    add({
        type = "announce",
        kind = kind,
        sessionId = session.id,
        fromName = session.starterName,
        title = session.raceName,
        count = session.participantCount,
        max = session.maxParticipants,
        expiresAtMs = GetCurrentTimeMillis() + M.ANNOUNCE_SEC * 1000,
    })
end

---@param data table see services/lobbyInvites.lua lobbyInvite
local function onServerInvite(data)
    if type(data) ~= "table" or not KINDS[data.kind] or busy() then return end
    add({
        type = "invite",
        kind = data.kind,
        sessionId = data.sessionId,
        fromName = data.fromName,
        title = data.title,
        count = data.count,
        max = data.max,
        expiresAtMs = GetCurrentTimeMillis() + (tonumber(data.expiresIn) or M.INVITE_SEC) * 1000,
    })
end

--- your crew's leader opened a lobby or convoy and you were joined into it (services/crews.lua
--- pullIn)
---@param data table {kind, sessionId, fromName, title}
local function crewPulled(data)
    if type(data) ~= "table" or not PULLED[data.kind] then return end
    add({
        type = "pulled",
        kind = data.kind,
        sessionId = data.sessionId,
        fromName = data.fromName,
        title = data.title,
        total = M.PULLED_SEC,
        addedAtMs = GetCurrentTimeMillis(),
        expiresAtMs = GetCurrentTimeMillis() + M.PULLED_SEC * 1000,
    })
end

--- a crew leader invited you (services/crews.lua crewInvite)
---@param data table {crewId, fromName, title, count, max, expiresIn}
local function crewInvite(data)
    if type(data) ~= "table" or data.crewId == nil then return end
    local seconds = tonumber(data.expiresIn) or M.INVITE_SEC
    add({
        type = "invite",
        kind = "crew",
        sessionId = data.crewId,
        fromName = data.fromName,
        title = data.title,
        count = data.count,
        max = data.max,
        total = seconds,
        expiresAtMs = GetCurrentTimeMillis() + seconds * 1000,
    })
end

--- a game you played just ended : a notice to open its results
---@param kind "derby"
---@param sessionId string
---@param winnerName string?
---@param title string? the arena / track name
local function results(kind, sessionId, winnerName, title)
    add({
        type = "results",
        kind = kind,
        sessionId = sessionId,
        fromName = winnerName,
        title = title,
        total = M.RESULTS_SEC,
        expiresAtMs = GetCurrentTimeMillis() + M.RESULTS_SEC * 1000,
    })
end

---@param want boolean
local function updatePad(want)
    if want == M.padActive then return end
    M.padActive = want
    if want then beamjoy_uiNav.acquire(M.OWNER) else beamjoy_uiNav.release(M.OWNER) end
end

---@param id string
---@param accept boolean
local function reply(id, accept)
    local notice
    for _, n in ipairs(M.list) do
        if n.id == id then notice = n end
    end
    if not notice then return end
    remove(id)
    if notice.type == "results" then
        -- nothing here : the UI opened the results itself (it owns the info panel)
    elseif notice.type == "pulled" then
        -- you're already in : A just opens it
        if accept and beamjoy_mainNav then beamjoy_mainNav.focusOn("play", PULLED[notice.kind].section) end
    elseif notice.kind == "crew" then
        if beamjoy_crews then beamjoy_crews.inviteReply(notice.sessionId, accept) end
        if accept and beamjoy_mainNav then beamjoy_mainNav.focusOn("crew") end
    elseif accept then
        local k = KINDS[notice.kind]
        beamjoy_communications_ui.dispatch(k.join, { notice.sessionId })
        -- the lobby opens in the main window, with the pad
        if beamjoy_mainNav then beamjoy_mainNav.focusOn("play", k.section) end
    end
    if #M.list == 0 then updatePad(false) end
    push()
end

-- mainNav's view --------------------------------------------------------------------------------

---@return boolean
local function focusable()
    return #M.list > 0
end

---@return boolean
local function isFocused()
    return M.focused and #M.list > 0
end

---@param focused boolean
local function setFocus(focused)
    M.focused = focused == true and #M.list > 0
    updatePad(M.focused)
    push()
end

-- TICK ------------------------------------------------------------------------------------------

local function onUpdate()
    if #M.list == 0 then
        if M.padActive then updatePad(false) end
        return
    end
    local now = GetCurrentTimeMillis()
    local changed = false
    local isBusy = busy()
    for i = #M.list, 1, -1 do
        local n = M.list[i]
        -- expired, joined something else, or the lobby is gone / started / full
        -- (a results notice stays : the finished game still counts as busy for a few seconds)
        if now >= n.expiresAtMs or (isBusy and n.kind ~= "crew" and n.type ~= "pulled" and n.type ~= "results")
            or not liveSession(n) then
            table.remove(M.list, i)
            changed = true
        end
    end
    if #M.list == 0 then
        M.focused = false
        updatePad(false)
    end
    -- the expiry bars move : a few pushes a second is plenty
    if changed or now - M.lastPush >= 250 then push() end
end

local function onInit()
    beamjoy_communications.addHandler("lobbyInvite", onServerInvite)
    beamjoy_communications.addHandler("lobbyInviteList", function(data)
        beamjoy_communications_ui.send("BJLobbyInviteList", data)
    end)
    beamjoy_communications_ui.addHandler("BJNoticeReply", reply)
    beamjoy_communications_ui.addHandler("BJNoticesRequest", push)
    beamjoy_communications_ui.addHandler("BJLobbyInviteList", function(kind)
        beamjoy_communications.send("lobbyInviteList", kind)
    end)
    beamjoy_communications_ui.addHandler("BJLobbyInvite", function(kind, targetID)
        beamjoy_communications.send("lobbyInvite", kind, targetID)
    end)
    -- staff : cancel someone else's race / hunt / infected game from Happening now
    beamjoy_communications_ui.addHandler("BJStaffSessionCancel", function(kind, sessionId)
        local event = ({ race = "raceCancel", hunter = "hunterCancel", infected = "infectedCancel",
            derby = "derbyCancel" })[kind]
        if event and sessionId then beamjoy_communications.send(event, sessionId) end
    end)
end

local function onServerLeave()
    M.list = {}
    M.focused = false
    updatePad(false)
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onServerLeave = onServerLeave
M.onExtensionUnloaded = onServerLeave
M.announce = announce
M.crewInvite = crewInvite
M.crewPulled = crewPulled
M.results = results
M.notificationFocusable = focusable
M.notificationFocused = isFocused
M.setNotificationFocus = setFocus

return M
