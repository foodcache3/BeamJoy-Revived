--- BJS's notification stack, beside the main window's rail (windows/notices) : race, hunter and
--- infected lobbies you could join. Two kinds of notice :
---   * invite   : a player invited you into their lobby (services/lobbyInvites.lua, lobbyInvite)
---   * announce : someone opened a lobby (the runners' onSessionsList, replacing the old centre
---                screen "X started a race" text)
--- Each has Join and Dismiss. The convoy invite stays delivery.lua's own, drawn in the same stack.
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
local function liveSession(n)
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
            total = n.type == "invite" and M.INVITE_SEC or M.ANNOUNCE_SEC,
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
---@param kind "race"|"hunter"|"infected"
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
    if accept then
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
        if now >= n.expiresAtMs or isBusy or not liveSession(n) then
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
M.notificationFocusable = focusable
M.notificationFocused = isFocused
M.setNotificationFocus = setFocus

return M
