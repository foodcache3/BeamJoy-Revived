--- Live Infected session state machine (join/ready/countdown/game/finish): separate from
--- services/infected.lua, which only owns the static arena *definition*, exactly mirroring the
--- hunter.lua / hunterGrid.lua split. Multiple sessions can run concurrently (different player
--- groups), same as races/hunts.
---
--- Trimmed relative to hunterGrid.lua's own shape in a few deliberate ways, since Infected's own
--- asymmetry is different from Hunter's fixed 1-vs-N: no joinOrder/randomizeFugitive cycling (a
--- session only ever runs ONE round, so there's no "next round" reuse to keep fair across restarts,
--- unlike Hunter's fugitive-cycling design) ; no per-role vehicle-preset pools or the vehicle-confirm
--- countdown-gate that goes with them (Infected only ever supports a single optional forced
--- `config`, applied identically to every participant, so there's nothing asymmetric to confirm) ;
--- no respawn-hub/reset-penalty system (crashing has no special Infected-specific consequence here).
---
--- NOT YET IMPLEMENTED (deferred): the admin-forced server-wide path, any reward/scoring beyond
--- win/lose (this fork has no reputation system to hook into at all, same limitation hunterGrid.lua
--- itself already notes).

---@alias BJInfectedSessionState "LOBBY"|"COUNTDOWN"|"GAME"|"FINISHED"
---@alias BJInfectedRole "survivor"|"infected"

---@class BJInfectedParticipant
---@field playerID integer
---@field playerName string
---@field role BJInfectedRole? nil for everyone throughout LOBBY, deliberately unknown until
---assignRoles actually commits it (a random draw at COUNTDOWN start, topped up by any staff
---force-assignment already made ; see BJInfectedSession.forcedInfectedIds)
---@field ready boolean
---@field spawnPos {x: number, y: number, z: number}?
---@field spawnDir {x: number, y: number, z: number}?
---@field vehicleModel string? reported at ready, same pattern as races'/hunter's own equivalent field
---@field originalInfected boolean? true if this participant started the round already infected
---(the random draw, or a staff force-assignment), as opposed to being tagged mid-round ; drives the
---asymmetric survivorsStartDelay/infectedStartDelay freeze release client-side
---@field infectedAt integer? GetCurrentTime() timestamp of the tag that infected this participant ;
---nil for both survivors and the round's original infected (who were never "tagged" at all)
---@field infectedBy integer? playerID of whoever tagged this participant ; nil for survivors and
---original infected
---@field tagCount integer how many OTHER participants this one has personally infected so far this
---round (self-inflicted stat, shown on the live roster ; see BJIWindowInfected's own
---infectedSurvivors precedent)

---@class BJInfectedSessionSettings host-configurable at game-start time, seeded from
---BJInfectedDefaults ; see services/infected.lua for full field docs, mirrored here 1:1
---@field initialInfectedCount integer
---@field survivorsStartDelay integer
---@field infectedStartDelay integer
---@field roundDuration integer minutes
---@field gridReadyTimeout integer
---@field gridTimeout integer
---@field countdown integer
---@field endTimeout integer
---@field enableColors boolean
---@field survivorColor BJColor?
---@field infectedColor BJColor?
---@field hideInfectedNametags boolean hides an infected participant's whole nametag from
---survivor viewers specifically ; see infectedRunner.lua's own isHiddenInfectedVehicle
---@field config table?

---@class BJInfectedSession
---@field id string
---@field starterID integer
---@field joinable boolean always true, same "a solo round is meaningless" reasoning as hunterGrid.lua's
---own session.joinable : this mode never gets a "Multiplayer" toggle the way races does
---@field settings BJInfectedSessionSettings
---@field state BJInfectedSessionState
---@field createdAt integer
---@field startedAt integer?
---@field winner ("survivors"|"infected")? set once state reaches FINISHED via a real win (not a
---cancel, which tears the session down immediately with no FINISHED/results step at all, matching
---hunterGrid.lua's own hunterCancel/raceGrid.lua's raceCancel)
---@field participants tablelib<integer, BJInfectedParticipant> index playerID
---@field forcedInfectedIds tablelib<integer, boolean> playerIDs staff explicitly pre-assigned as
---infected during LOBBY/COUNTDOWN (see infectedForceInfected) : a growing SET, not a single swap
---target like hunterGrid.lua's own hunterForceFugitive, since BJI's own "set as infected" UI action
---is per-target and additive (any number of participants can be pre-marked, not just one)
---@field roundDeadlineAt integer? GetCurrentTime() timestamp at which survivors automatically win by
---outlasting the clock, set at GAME start ; see the plan's own "BJS-only addition" note on
---BJInfectedDefaults.roundDuration for why this exists at all
---@field arenaSnapshot BJInfectedArena resolved once at session-build time: editing the live arena
---mid-session can't retroactively change what's already running, same "snapshot at start" treatment
---hunterGrid.lua's own arenaSnapshot gets
---@field debugSolo boolean? staff-only testing bypass (see infectedDebugStart / the "/infected debug"
---chat subcommands): lets tryStartFromLobby/onGridTimeout proceed with fewer than
---MINIMUM_PARTICIPANTS, and always makes the lone tester the round's infected (the only sensible
---single-participant outcome; see infectedDebugSetRole to test the survivor side instead). Never
---settable from the normal start UI: only ever true via the debug chat command, which independently
---re-checks isStaff itself

local M = {
    dependencies = { "services_infected", "utils_async" },

    ---@type tablelib<string, BJInfectedSession>
    sessions = Table(),

    --- non-participant spectators, entirely separate from BJInfectedSession/participants: same
    --- reasoning as hunterGrid.lua's own M.spectators
    ---@type tablelib<integer, string> playerID -> sessionId
    spectators = Table(),
}

---@param playerID integer
---@return BJInfectedSession?
local function findSessionByParticipant(playerID)
    return M.sessions:find(function(s) return s.participants[playerID] ~= nil end)
end

---@param session BJInfectedSession
---@param playerID integer
---@param playerName string
local function addParticipant(session, playerID, playerName)
    session.participants[playerID] = {
        playerID = playerID,
        playerName = playerName,
        -- role left unset (nil) here on purpose; see BJInfectedParticipant.role's own doc comment
        ready = false,
        tagCount = 0,
    }
end

---@param session BJInfectedSession
---@return integer
local function resolveInfectedCount(session)
    return math.max(1, math.min(session.settings.initialInfectedCount,
        #session.arenaSnapshot.infectedSpawns, session.participants:length() - 1))
end

--- commits real BJInfectedParticipant.role values : any staff-forced ids first, topped up randomly
--- from the rest of the field up to resolveInfectedCount, everyone else survivor. The ONE place role
--- actually gets written, called exactly once (beginCountdown)
---@param session BJInfectedSession
local function assignRoles(session)
    local count = resolveInfectedCount(session)
    local ids = session.participants:keys()
    local forced = table.filter(ids, function(id) return session.forcedInfectedIds[id] == true end)
    local infectedIds = {}
    for i = 1, math.min(#forced, count) do table.insert(infectedIds, forced[i]) end
    if #infectedIds < count then
        local remaining = table.filter(ids, function(id) return not table.includes(infectedIds, id) end)
        while #infectedIds < count and #remaining > 0 do
            local pick = table.remove(remaining, math.random(#remaining))
            table.insert(infectedIds, pick)
        end
    end
    session.participants:forEach(function(p)
        local isInfected = table.includes(infectedIds, p.playerID)
        p.role = isInfected and "infected" or "survivor"
        p.originalInfected = isInfected or nil
        p.infectedAt = nil
        p.infectedBy = nil
    end)
end

--- assigns each participant a real spawn point from the role-appropriate list: deduplicated slots
--- (never two participants on the same spawn) as long as the pool covers the roster, falling back to
--- a plain random pick once it doesn't (defensive only, resolveInfectedCount/join-time capacity
--- checks already keep this from happening in practice ; mirrors hunterGrid.lua's own assignSpawns
--- fallback exactly)
---@param session BJInfectedSession
local function assignSpawns(session)
    local arena = session.arenaSnapshot
    local usedSurvivor, usedInfected = {}, {}
    session.participants:forEach(function(p)
        local pool, used = arena.survivorSpawns, usedSurvivor
        if p.role == "infected" then pool, used = arena.infectedSpawns, usedInfected end
        local available = {}
        for i, s in ipairs(pool) do
            if not used[i] then table.insert(available, { index = i, slot = s }) end
        end
        local pick = table.random(available) or (pool[1] and { index = 1, slot = pool[1] })
        if pick then
            used[pick.index] = true
            p.spawnPos, p.spawnDir = pick.slot.pos, pick.slot.dir
        end
    end)
end

---@param session BJInfectedSession
---@return table
local function summarize(session)
    local starter = session.participants[session.starterID]
    local arena = session.arenaSnapshot
    return {
        id = session.id,
        starterName = starter and starter.playerName or "?",
        joinable = session.joinable,
        participantCount = session.participants:length(),
        maxParticipants = #arena.survivorSpawns +
            math.min(session.settings.initialInfectedCount, #arena.infectedSpawns),
        state = session.state,
    }
end

---@param session BJInfectedSession
---@return table
local function buildBasePayload(session)
    local payload = table.clone(session)
    payload.participants = session.participants:values()
    if session.state == "GAME" and session.startedAt then
        -- same "push a duration, not a timestamp" reasoning as hunterGrid.lua's own huntElapsedMs:
        -- session.startedAt is in the server's own GetCurrentTime() clock domain, meaningless
        -- compared directly against a client's GetCurrentTimeMillis()
        payload.gameElapsedMs = math.floor((GetCurrentTime() - session.startedAt) * 1000)
    end
    if session.state == "GAME" and session.roundDeadlineAt then
        payload.roundSecondsLeft = math.max(0, math.ceil(session.roundDeadlineAt - GetCurrentTime()))
    end
    if session.state == "LOBBY" and session.joinable then
        local elapsedSec = GetCurrentTime() - session.createdAt
        payload.gridReadySecondsLeft = math.max(0, math.ceil(session.settings.gridReadyTimeout - elapsedSec))
        payload.gridTimeoutSecondsLeft = math.max(0, math.ceil(session.settings.gridTimeout - elapsedSec))
        -- Real bug: tryStartFromLobby silently refuses to leave LOBBY below this floor (session
        -- never starts, not even once gridReadyTimeout elapses), but the UI's own "Starting in Xs"
        -- countdown had nothing telling it that floor exists, so it happily ticked down to 0 and
        -- sat there forever whenever exactly 2 people readied up (Infected needs 3, unlike Hunter's
        -- 2). Exposed here so the client can gate that countdown on actually having enough people.
        payload.minParticipants = services_infected.MINIMUM_PARTICIPANTS
    end
    return payload
end

---@param session BJInfectedSession
local function pushSessionUpdate(session)
    local base = buildBasePayload(session)
    session.participants:forEach(function(_, playerID)
        communications_tx.sendToPlayer(playerID, "infectedSessionUpdate", base)
    end)
    M.spectators:forEach(function(sessionId, playerID)
        if sessionId == session.id then
            communications_tx.sendToPlayer(playerID, "infectedSpectateUpdate", base)
        end
    end)
end

local function pushOpenSessionsList()
    local visible = M.sessions:filter(function(s)
        return (s.state == "LOBBY" and s.joinable) or s.state == "COUNTDOWN" or s.state == "GAME"
    end):map(summarize):values()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "infectedSessionsList", visible)
end

---@param session BJInfectedSession
local function removeSession(session)
    utils_async.removeTask("BJInfectedGrid-" .. session.id .. "-readyTimeout")
    utils_async.removeTask("BJInfectedGrid-" .. session.id .. "-gridTimeout")
    utils_async.removeTask("BJInfectedGrid-" .. session.id .. "-countdown")
    utils_async.removeTask("BJInfectedGrid-" .. session.id .. "-roundTimeout")
    utils_async.removeTask("BJInfectedGrid-" .. session.id .. "-cleanup")
    session.participants:forEach(function(_, playerID)
        communications_tx.sendToPlayer(playerID, "infectedSessionRemoved", session.id)
    end)
    M.spectators:forEach(function(sessionId, playerID)
        if sessionId == session.id then
            communications_tx.sendToPlayer(playerID, "infectedSpectateRemoved", session.id)
            M.spectators[playerID] = nil
        end
    end)
    M.sessions[session.id] = nil
    pushOpenSessionsList()
end

--- a real win, as opposed to infectedCancel, which tears the session down immediately with no
--- FINISHED/results step at all, matching hunterGrid.lua's own endHunt exactly
---@param session BJInfectedSession
---@param winner "survivors"|"infected"
local function endGame(session, winner)
    if session.state == "FINISHED" then return end
    utils_async.removeTask("BJInfectedGrid-" .. session.id .. "-roundTimeout")
    session.state = "FINISHED"
    session.winner = winner
    pushSessionUpdate(session)
    utils_async.delayTask(function() removeSession(session) end,
        session.settings.endTimeout, "BJInfectedGrid-" .. session.id .. "-cleanup")
end

---@param arena BJInfectedArena
---@param overrides table?
---@return BJInfectedSessionSettings
local function buildSettings(arena, overrides)
    overrides = overrides or {}
    local defaults = arena.defaults or {}

    local enableColors = overrides.enableColors
    if enableColors == nil then enableColors = defaults.enableColors == true end

    local hideInfectedNametags = overrides.hideInfectedNametags
    if hideInfectedNametags == nil then hideInfectedNametags = defaults.hideInfectedNametags == true end

    local config = overrides.config
    if type(config) ~= "table" or type(config.model) ~= "string" or type(config.config) ~= "string" then
        config = defaults.config
    end

    return {
        initialInfectedCount = math.max(1, math.floor(tonumber(overrides.initialInfectedCount) or
            defaults.initialInfectedCount or 1)),
        survivorsStartDelay = math.max(0, tonumber(overrides.survivorsStartDelay) or
            defaults.survivorsStartDelay or 0),
        infectedStartDelay = math.max(0, tonumber(overrides.infectedStartDelay) or
            defaults.infectedStartDelay or 10),
        roundDuration = math.clamp(math.floor(tonumber(overrides.roundDuration) or
            defaults.roundDuration or 10), 1, 120),
        gridReadyTimeout = math.max(0, tonumber(overrides.gridReadyTimeout) or defaults.gridReadyTimeout or 15),
        gridTimeout = math.max(10, tonumber(overrides.gridTimeout) or defaults.gridTimeout or 120),
        countdown = math.clamp(tonumber(overrides.countdown) or defaults.countdown or 10, 0, 600),
        endTimeout = math.max(3, tonumber(overrides.endTimeout) or defaults.endTimeout or 10),
        enableColors = enableColors == true,
        survivorColor = enableColors and (type(overrides.survivorColor) == "table" and overrides.survivorColor or
            defaults.survivorColor) or nil,
        infectedColor = enableColors and (type(overrides.infectedColor) == "table" and overrides.infectedColor or
            defaults.infectedColor) or nil,
        hideInfectedNametags = hideInfectedNametags == true,
        config = type(config) == "table" and config or nil,
    }
end

--- begins the pre-game countdown : commits roles + spawns and freezes the field. Unlike
--- hunterGrid.lua's own beginCountdown, there's no vehicle-confirm handshake to wait on first (see
--- this file's own header comment for why), so the countdown timer starts immediately
---@param session BJInfectedSession
local function beginCountdown(session)
    session.state = "COUNTDOWN"
    assignRoles(session)
    assignSpawns(session)
    pushSessionUpdate(session)
    pushOpenSessionsList()
    utils_async.delayTask(function() M.beginGame(session.id) end,
        session.settings.countdown, "BJInfectedGrid-" .. session.id .. "-countdown")
end

---@param sessionId string
local function beginGame(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "COUNTDOWN" then return end

    session.state = "GAME"
    session.startedAt = GetCurrentTime()
    session.roundDeadlineAt = GetCurrentTime() + session.settings.roundDuration * 60
    utils_async.delayTask(function() M.onRoundTimeout(session.id) end,
        session.settings.roundDuration * 60, "BJInfectedGrid-" .. session.id .. "-roundTimeout")
    pushSessionUpdate(session)
end

--- survivors' own win condition : nobody left to catch them before the round's own clock ran out.
--- A no-op if the round already ended some other way in the meantime (last survivor got tagged,
--- every infected disconnected, etc.): endGame's own `state == "FINISHED"` guard already covers that
---@param sessionId string
local function onRoundTimeout(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "GAME" then return end
    endGame(session, "survivors")
end

---@param session BJInfectedSession whose LOBBY phase just ended (start-now, or force-cut via timers)
local function tryStartFromLobby(session)
    if session.state ~= "LOBBY" then return end
    if session.participants:length() < services_infected.MINIMUM_PARTICIPANTS and not session.debugSolo then
        return
    end
    if not session.participants:every(function(p) return p.ready end) then return end
    if not session.debugSolo and GetCurrentTime() - session.createdAt < session.settings.gridReadyTimeout then
        return
    end
    beginCountdown(session)
end

---@param sessionId string
local function onGridTimeout(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "LOBBY" then return end
    local kicked = session.participants:filter(function(p) return not p.ready end):values()
    session.participants = session.participants:filter(function(p) return p.ready end)
    table.forEach(kicked, function(p)
        communications_tx.sendToPlayer(p.playerID, "infectedSessionRemoved", session.id)
    end)
    if session.participants:length() < services_infected.MINIMUM_PARTICIPANTS and not session.debugSolo then
        return removeSession(session)
    end
    beginCountdown(session)
end

---@param ctxt BJSContext
---@param opts table? see BJInfectedSessionSettings for every overridable field
local function infectedStart(ctxt, opts)
    if not ctxt.sender then return end
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.infected.alreadyInSession", ctxt.sender.lang))
    end
    local arena = services_infected.getArena()
    if not arena or not arena.enabled then return end
    if #arena.survivorSpawns < services_infected.MIN_SURVIVOR_SPAWNS or
        #arena.infectedSpawns < services_infected.MIN_INFECTED_SPAWNS then
        return
    end

    opts = opts or {}
    ---@type BJInfectedSession
    local session = {
        id = UUID(),
        starterID = ctxt.senderID,
        -- always joinable, same "a solo round is meaningless" reasoning as hunterGrid.lua's own
        -- session.joinable : this mode never gets a "Multiplayer" toggle the way races does
        joinable = true,
        settings = buildSettings(arena, opts),
        state = "LOBBY",
        createdAt = ctxt.time,
        participants = Table(),
        forcedInfectedIds = Table(),
        arenaSnapshot = table.clone(arena),
        -- never trusted from the normal client UI's own opts (a modified client could otherwise
        -- self-grant this): only ever true via the staff-gated "/infected debug start" command
        debugSolo = opts.debugSolo == true and services_permissions.isStaff(ctxt.sender.playerName),
    }
    addParticipant(session, ctxt.senderID, ctxt.sender.playerName)
    M.sessions[session.id] = session

    utils_async.delayTask(function() tryStartFromLobby(session) end,
        session.settings.gridReadyTimeout, "BJInfectedGrid-" .. session.id .. "-readyTimeout")
    utils_async.delayTask(function() onGridTimeout(session.id) end,
        session.settings.gridTimeout, "BJInfectedGrid-" .. session.id .. "-gridTimeout")

    pushSessionUpdate(session)
    pushOpenSessionsList()
    return session.id
end

---@param ctxt BJSContext
---@param sessionId string
local function infectedJoin(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "LOBBY" or not session.joinable then return end
    if session.participants[ctxt.senderID] then return end
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.infected.alreadyInSession", ctxt.sender.lang))
    end

    -- capacity : bounded by survivor slots plus however many of the round's initial infected the
    -- infected-spawn pool can actually hold ; see resolveInfectedCount's own reasoning for why this
    -- estimate (using the still-unresolved settings value, not yet clamped by a real participant
    -- count) is always a safe upper bound once assignRoles actually runs
    local maxParticipants = #session.arenaSnapshot.survivorSpawns +
        math.min(session.settings.initialInfectedCount, #session.arenaSnapshot.infectedSpawns)
    if session.participants:length() >= maxParticipants then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.infected.arenaFull", ctxt.sender.lang))
    end

    addParticipant(session, ctxt.senderID, ctxt.sender.playerName)
    pushSessionUpdate(session)
    pushOpenSessionsList()
end

--- watch a session without becoming a participant in it: mirrors hunterGrid.lua's own hunterSpectate
---@param ctxt BJSContext
---@param sessionId string
local function infectedSpectate(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state == "LOBBY" or session.state == "FINISHED" then return end
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.infected.alreadyInSession", ctxt.sender.lang))
    end

    M.spectators[ctxt.senderID] = sessionId
    communications_tx.sendToPlayer(ctxt.senderID, "infectedSpectateUpdate", buildBasePayload(session))
end

---@param ctxt BJSContext
local function infectedStopSpectate(ctxt)
    if not ctxt.sender then return end
    local sessionId = M.spectators[ctxt.senderID]
    if not sessionId then return end
    M.spectators[ctxt.senderID] = nil
    communications_tx.sendToPlayer(ctxt.senderID, "infectedSpectateRemoved", sessionId)
end

---@param session BJInfectedSession
---@return integer survivorsLeft, integer infectedLeft
local function countRoles(session)
    local survivors, infected = 0, 0
    session.participants:forEach(function(p)
        if p.role == "infected" then
            infected = infected + 1
        elseif p.role == "survivor" then
            survivors = survivors + 1
        end
    end)
    return survivors, infected
end

--- re-evaluated after any GAME-time departure : the symmetric inverse of a successful tag chain
--- reaching zero survivors. Mirrors hunterGrid.lua's own "every hunter is gone" case, generalized
--- for Infected's many-infected shape instead of Hunter's fixed single fugitive
---@param session BJInfectedSession
local function checkRoleWipeout(session)
    if session.state ~= "GAME" then return end
    local survivors, infected = countRoles(session)
    if survivors == 0 then
        endGame(session, "infected")
    elseif infected == 0 then
        endGame(session, "survivors")
    end
end

---@param ctxt BJSContext
---@param sessionId string
local function infectedLeave(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or not session.participants[ctxt.senderID] then return end

    session.participants[ctxt.senderID] = nil
    session.forcedInfectedIds[ctxt.senderID] = nil
    communications_tx.sendToPlayer(ctxt.senderID, "infectedSessionRemoved", sessionId)
    if session.participants:length() == 0 then
        return removeSession(session)
    end
    if ctxt.senderID == session.starterID then
        session.starterID = session.participants:keys()[1]
    end

    if session.state == "LOBBY" then
        tryStartFromLobby(session)
    elseif session.state == "COUNTDOWN" or session.state == "GAME" then
        checkRoleWipeout(session)
    end
    if M.sessions[sessionId] then
        pushSessionUpdate(session)
        pushOpenSessionsList()
    end
end

--- session starter or staff only: tears the session down immediately, no FINISHED/results step at
--- all, matching hunterGrid.lua's own hunterCancel exactly (as opposed to endGame, a real win)
---@param ctxt BJSContext
---@param sessionId string
local function infectedCancel(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session then return end
    if session.starterID ~= ctxt.senderID and not services_permissions.isStaff(ctxt.sender.playerName) then
        return
    end
    removeSession(session)
end

---@param ctxt BJSContext
---@param sessionId string
---@param ready boolean
---@param model string? the client's own current vehicle jbeam, sent alongside becoming ready, same
---"reliable way to get it" reasoning as hunterGrid.lua's own hunterReady
local function infectedReady(ctxt, sessionId, ready, model)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "LOBBY" then return end
    local participant = session.participants[ctxt.senderID]
    if not participant then return end

    participant.ready = ready == true
    if participant.ready and type(model) == "string" and model ~= "" then
        participant.vehicleModel = model
    end
    if participant.ready then
        tryStartFromLobby(session)
    end
    if M.sessions[sessionId] then -- session may have just been consumed by tryStartFromLobby
        pushSessionUpdate(session)
    end
end

---@param playerID integer
--- unreadies a LOBBY participant the moment their vehicle's actual config changes ; same reasoning
--- and exact-mirror implementation as hunterGrid.lua's own unreadyOnVehicleChange
local function unreadyOnVehicleChange(playerID)
    local session = findSessionByParticipant(playerID)
    if not session or session.state ~= "LOBBY" then return end
    local participant = session.participants[playerID]
    if not participant or not participant.ready then return end
    participant.ready = false
    pushSessionUpdate(session)
end

---@param ctxt BJSContext
---@param sessionId string
---@param targetPlayerID integer the survivor claimed to have just been touched
local function infectedTag(ctxt, sessionId, targetPlayerID)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "GAME" then return end
    local sender = session.participants[ctxt.senderID]
    if not sender or sender.role ~= "infected" then return end
    local target = session.participants[targetPlayerID]
    if not target or target.role ~= "survivor" then return end

    target.role = "infected"
    target.infectedAt = GetCurrentTime()
    target.infectedBy = ctxt.senderID
    sender.tagCount = (sender.tagCount or 0) + 1

    -- inlined rather than checkRoleWipeout (which also handles the opposite, "every infected left"
    -- direction, impossible to reach from a tag : the sender making this call is themselves proof
    -- at least 1 infected still exists) so a winning tag pushes FINISHED exactly once, not a
    -- GAME-state update immediately followed by a second, redundant FINISHED one
    local survivors = countRoles(session)
    if survivors == 0 then
        return endGame(session, "infected")
    end
    pushSessionUpdate(session)
end

--- staff-only, matching hunterGrid.lua's own more restrictive gate on hunterForceFugitive (session
--- starters can cancel their own lobby, but reassigning roles mid-round is moderation-flavored).
--- Additive : marks targetPlayerID to be included among the round's initial infected once
--- assignRoles actually runs, rather than swapping a single fixed slot the way Hunter's fugitive
--- reassignment does (see BJInfectedSession.forcedInfectedIds's own doc comment for why). Only
--- meaningful before GAME start: once real positions/roles are already committed and playing out,
--- forcing a role flip would just be a second, redundant way to do what infectedTag already does
--- (and skip its own touch requirement), so this is deliberately restricted to LOBBY/COUNTDOWN.
---@param ctxt BJSContext
---@param sessionId string
---@param targetPlayerID integer
local function infectedForceInfected(ctxt, sessionId, targetPlayerID)
    if not ctxt.sender or not services_permissions.isStaff(ctxt.sender.playerName) then return end
    local session = M.sessions[sessionId]
    if not session or session.state == "GAME" or session.state == "FINISHED" then return end
    if not session.participants[targetPlayerID] then return end

    session.forcedInfectedIds[targetPlayerID] = true
    if session.state == "COUNTDOWN" then
        -- roles were already committed once for this COUNTDOWN ; redo the whole draw so the new
        -- forced id actually takes effect immediately instead of only on some hypothetical next round
        assignRoles(session)
        assignSpawns(session)
    end
    pushSessionUpdate(session)
end

--- ============================================================================================
--- Staff-only solo-testing debug tools ("/infected debug ..."), mirroring hunterGrid.lua's own
--- equivalent section: Infected is fundamentally asymmetric and needs a real minimum of 3 players,
--- so a single tester can never exercise a full round live. These commands exist to let one person
--- still walk the state machine and inspect either role's own mechanics in isolation. Every entry
--- point independently re-checks isStaff itself (never trusts a caller's own gate).
--- ============================================================================================

---@param ctxt BJSContext
---@return string? error
local function infectedDebugStart(ctxt)
    if findSessionByParticipant(ctxt.senderID) then
        return services_lang.get("error.infected.alreadyInSession", ctxt.sender.lang)
    end
    local sessionId = M.infectedStart(ctxt, { debugSolo = true })
    if not sessionId then
        return services_lang.get("chat.command.infected.debug.startFailed", ctxt.sender.lang)
    end
    M.infectedReady(ctxt, sessionId, true)
end

--- forces the sender's OWN role directly, independent of the normal random draw (which can't
--- produce "survivor" at all with a single real participant, since resolveInfectedCount always
--- reserves at least 1 infected out of participantCount - 1 survivors, and a solo tester IS
--- participantCount). Regenerates just this one participant's own spawn from the role-appropriate
--- list, matching what assignSpawns would have picked for a real participant in that role.
---@param ctxt BJSContext
---@param session BJInfectedSession
---@param role BJInfectedRole
---@return string? error
local function infectedDebugSetRole(ctxt, session, role)
    if session.state ~= "COUNTDOWN" and session.state ~= "GAME" then
        return services_lang.get("chat.command.infected.debug.notActive", ctxt.sender.lang)
    end
    local participant = session.participants[ctxt.senderID]
    if not participant then return end
    participant.role = role
    participant.originalInfected = role == "infected" or nil
    local arena = session.arenaSnapshot
    local list = role == "infected" and arena.infectedSpawns or arena.survivorSpawns
    local slot = table.random(list)
    if slot then
        participant.spawnPos, participant.spawnDir = slot.pos, slot.dir
    end
    pushSessionUpdate(session)
end

---@param ctxt BJSContext
---@param session BJInfectedSession
---@param winner "survivors"|"infected"
---@return string? error
local function infectedDebugFinish(ctxt, session, winner)
    if session.state ~= "COUNTDOWN" and session.state ~= "GAME" then
        return services_lang.get("chat.command.infected.debug.notActive", ctxt.sender.lang)
    end
    endGame(session, winner)
end

---@param ctxt BJSContext
---@param args string[] "debug <start|role <survivor|infected>|finish <survivors|infected>>"
local function chatInfectedDebug(ctxt, args)
    if not services_permissions.isStaff(ctxt.sender.playerName) then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.infected.debug.staffOnly", ctxt.sender.lang), services_chat.COLORS.ERROR)
    end
    local sub = args[2] and args[2]:lower()
    local usage = function()
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.infected.debug.usage", ctxt.sender.lang), services_chat.COLORS.ERROR)
    end

    if sub == "start" then
        local err = infectedDebugStart(ctxt)
        if err then
            return services_chat.directSend(ctxt.senderID, err, services_chat.COLORS.ERROR)
        end
        return services_chat.directSend(ctxt.senderID, services_lang.get("chat.command.infected.debug.started", ctxt.sender.lang))
    end

    local session = findSessionByParticipant(ctxt.senderID)
    if not session then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.infected.notInSession", ctxt.sender.lang), services_chat.COLORS.ERROR)
    end

    if sub == "role" then
        local role = args[3] and args[3]:lower()
        if role ~= "survivor" and role ~= "infected" then return usage() end
        local err = infectedDebugSetRole(ctxt, session, role)
        if err then
            return services_chat.directSend(ctxt.senderID, err, services_chat.COLORS.ERROR)
        end
        return services_chat.directSend(ctxt.senderID,
            string.format("%s %s", services_lang.get("chat.command.infected.debug.roleSet", ctxt.sender.lang), role))
    elseif sub == "finish" then
        local winner = args[3] and args[3]:lower()
        if winner ~= "survivors" and winner ~= "infected" then return usage() end
        local err = infectedDebugFinish(ctxt, session, winner)
        if err then
            return services_chat.directSend(ctxt.senderID, err, services_chat.COLORS.ERROR)
        end
        return services_chat.directSend(ctxt.senderID,
            string.format("%s %s", services_lang.get("chat.command.infected.debug.finished", ctxt.sender.lang), winner))
    end
    return usage()
end

--- chat-command front door for join/leave/ready/cancel : "join" resolves the first open lobby, the
--- other three act on "whichever session I'm currently in", same as hunterGrid.lua's own chatHunter
---@param ctxt BJSContext
---@param args string[] "<join|leave|ready|cancel>"
---@param command BJChatCommand
local function chatInfected(ctxt, args, command)
    local sub = args[1] and args[1]:lower()
    if sub == "debug" then
        return chatInfectedDebug(ctxt, args)
    end
    if not table.includes({ "join", "leave", "ready", "cancel" }, sub) then
        return services_chat.directSend(ctxt.senderID,
            string.format("%s : %s -> %s",
                services_lang.get("chat.command.usage", ctxt.sender.lang),
                services_lang.get(command.commandKey, ctxt.sender.lang),
                services_lang.get(command.descKey, ctxt.sender.lang)),
            services_chat.COLORS.ERROR)
    end

    if sub == "join" then
        local open = M.sessions:find(function(s) return s.state == "LOBBY" and s.joinable end)
        if not open then
            return services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.infected.noneOpen", ctxt.sender.lang), services_chat.COLORS.ERROR)
        end
        return M.infectedJoin(ctxt, open.id)
    end

    local session = findSessionByParticipant(ctxt.senderID)
    if not session then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.infected.notInSession", ctxt.sender.lang), services_chat.COLORS.ERROR)
    end

    if sub == "leave" then
        M.infectedLeave(ctxt, session.id)
        services_chat.directSend(ctxt.senderID, services_lang.get("chat.command.infected.left", ctxt.sender.lang))
    elseif sub == "ready" then
        local participant = session.participants[ctxt.senderID]
        local nowReady = not participant.ready
        M.infectedReady(ctxt, session.id, nowReady)
        services_chat.directSend(ctxt.senderID,
            services_lang.get(nowReady and "chat.command.infected.readyOn" or "chat.command.infected.readyOff",
                ctxt.sender.lang))
    elseif sub == "cancel" then
        local sessionId = session.id
        M.infectedCancel(ctxt, sessionId)
        if M.sessions[sessionId] then
            services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.error.noPermission", ctxt.sender.lang), services_chat.COLORS.ERROR)
        else
            services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.infected.cancelled", ctxt.sender.lang))
        end
    end
end

local function onInit()
    communications_rx.addHandler("infectedStart", M.infectedStart)
    communications_rx.addHandler("infectedJoin", M.infectedJoin)
    communications_rx.addHandler("infectedLeave", M.infectedLeave)
    communications_rx.addHandler("infectedCancel", M.infectedCancel)
    communications_rx.addHandler("infectedReady", M.infectedReady)
    communications_rx.addHandler("infectedTag", M.infectedTag)
    communications_rx.addHandler("infectedForceInfected", M.infectedForceInfected)
    communications_rx.addHandler("infectedSpectate", M.infectedSpectate)
    communications_rx.addHandler("infectedStopSpectate", M.infectedStopSpectate)

    services_chatCommands.addCommand("infected", "chat.command.infected.desc", M.chatInfected,
        { commandKey = "chat.command.infected.command" })
end

---@param playerID integer
--- inlined rather than routed through infectedLeave : same "other extensions' own onPlayerDisconnect
--- handlers may have already cleared services_players.players by the time this one runs" reasoning
--- as hunterGrid.lua's own onPlayerDisconnect
local function onPlayerDisconnect(playerID)
    M.spectators[playerID] = nil
    M.sessions:forEach(function(session)
        if not session.participants[playerID] then return end

        session.forcedInfectedIds[playerID] = nil
        if session.state == "LOBBY" then
            session.participants[playerID] = nil
            if session.participants:length() == 0 then
                return removeSession(session)
            end
            if playerID == session.starterID then
                session.starterID = session.participants:keys()[1]
            end
            tryStartFromLobby(session)
            pushSessionUpdate(session)
            pushOpenSessionsList()
        elseif session.state == "COUNTDOWN" or session.state == "GAME" then
            session.participants[playerID] = nil
            if session.participants:length() == 0 then
                return removeSession(session)
            end
            checkRoleWipeout(session)
            if M.sessions[session.id] then
                pushSessionUpdate(session)
                pushOpenSessionsList()
            end
        end
    end)
end

M.onInit = onInit
M.onPlayerDisconnect = onPlayerDisconnect

M.infectedStart = infectedStart
M.infectedJoin = infectedJoin
M.infectedLeave = infectedLeave
M.infectedCancel = infectedCancel
M.infectedReady = infectedReady
M.unreadyOnVehicleChange = unreadyOnVehicleChange
M.infectedTag = infectedTag
M.infectedForceInfected = infectedForceInfected
M.infectedSpectate = infectedSpectate
M.infectedStopSpectate = infectedStopSpectate
M.beginGame = beginGame
M.onRoundTimeout = onRoundTimeout
M.chatInfected = chatInfected

return M
