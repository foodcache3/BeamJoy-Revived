--- Live Hunter session state machine (join/ready/countdown/hunt/finish): separate from
--- services/hunter.lua, which only owns the static arena *definition*, exactly mirroring the
--- races.lua / raceGrid.lua split. Multiple sessions can run concurrently (different player
--- groups), same as races.
---
--- NOT YET IMPLEMENTED (deferred, see the plan): the admin-forced server-wide path, any reward/
--- scoring beyond win/lose (this fork has no reputation system to hook into at all).

---@alias BJHunterSessionState "LOBBY"|"COUNTDOWN"|"HUNT"|"FINISHED"
---@alias BJHunterRole "hunter"|"hunted"

---@class BJHunterParticipant
---@field playerID integer
---@field playerName string
---@field role BJHunterRole? nil for everyone throughout LOBBY, deliberately unknown until assignRoles
---actually commits it (a random draw at COUNTDOWN start, or an explicit staff force-reassign), so no
---vehicle-pool restriction is resolvable (and none applies) while still in the lobby picking a
---vehicle ; see hunterRunner.lua's own activeVehiclePool, which already treats a nil role as "no
---restriction" for exactly this reason
---@field ready boolean
---@field spawnPos {x: number, y: number, z: number}? assigned at COUNTDOWN from the role-appropriate
---spawn list, regenerated whenever this participant's role changes (see hunterForceFugitive) so a
---reassigned fugitive's spawn isn't spoiled to hunters who already saw the previous one
---@field spawnDir {x: number, y: number, z: number}?
---@field vehicleModel string? reported at ready, same pattern as races' own BJRaceParticipant
---@field eliminated boolean fugitive-only : true once caught (self-reported, see hunterEliminated)
---@field waypointsReached integer fugitive-only : how many of the round's own ordered route have
---been reached so far, deliberately stripped from every OTHER participant's copy of the session
---payload (see buildBasePayload/withHuntedPrivateFields) so hunters can't read "how close is the
---fugitive to escaping" for free ; that mystery is the whole point of the final-waypoint reveal
---@field revealed boolean fugitive-only : current hide/reveal state. Self-computed and reported by
---the fugitive's own client from all three BJI-ported triggers at once (proximity / near-final-
---waypoint / post-reset; see hunterRevealUpdate) ; every other participant/spectator just reads
---this to decide nametag/minimap rendering for that one vehicle
---@field vehicleConfirmed boolean self-reported once this participant's own client has confirmed
---their current vehicle matches their freshly-assigned role's pool (or there's no pool to match at
---all). Reset false by beginCountdown every round, see hunterVehicleConfirmed/startCountdownTimer.
---The actual hunt-start timer doesn't begin ticking until every participant reaches true, or
---BJHunterSessionSettings.vehicleConfirmTimeout elapses regardless

---@class BJHunterSessionSettings host-configurable at hunt-start time, seeded from BJHunterDefaults
---; see services/hunter.lua for full field docs, mirrored here 1:1 except where noted
---@field waypointCount integer
---@field huntedStuckTimeout integer
---@field huntedStuckDistance number
---@field huntedStartDelay integer
---@field huntersStartDelay integer
---@field huntersRespawnDelay integer
---@field revealProximityDistance number
---@field revealResetDuration integer
---@field revealOnFinalWaypoint boolean
---@field huntedResetDistanceThreshold number
---@field huntedVehiclePresetId integer?
---@field huntedVehiclePool BJVehiclePresetEntry[]? resolved once from huntedVehiclePresetId at
---session-build time, same "snapshot at session start, never re-read the preset live again"
---treatment races' own vehicleRestrictionPool already established (see raceGrid.lua's buildSettings)
---@field huntedVehicleLabel string?
---@field huntersVehiclePresetId integer?
---@field huntersVehiclePool BJVehiclePresetEntry[]?
---@field huntersVehicleLabel string?
---@field gridTimeout integer
---@field gridReadyTimeout integer
---@field countdown integer
---@field vehicleConfirmTimeout integer
---@field randomizeVehiclePool boolean
---@field respawnPenaltyIncrement number
---@field hunterRespawnStrategy ("free"|"nearestSpawn"|"hubs")
---@field hunterNametagFadeDistance number
---@field winCondition ("waypoints"|"timed")
---@field timedModeDuration integer minutes

---@class BJHunterSession
---@field id string
---@field starterID integer
---@field joinable boolean always true; see hunterStart's own comment for why this mode never gets
---a "Multiplayer" toggle the way races does
---@field settings BJHunterSessionSettings
---@field state BJHunterSessionState
---@field createdAt integer
---@field startedAt integer?
---@field winner ("hunted"|"hunters")? set once state reaches FINISHED via a real win (not a cancel,
---which tears the session down immediately with no FINISHED/results step at all, matching races'
---own raceCancel)
---@field participants tablelib<integer, BJHunterParticipant> index playerID
---@field joinOrder integer[] playerIDs, reordered so joinOrder[1] names whoever assignRoles should
---make the fugitive the next time it runs. Join order itself only until the random draw (or a staff
---force-reassign) moves someone else to the front ; pruneJoinOrder keeps this in sync with
---participants on every join/leave regardless of whether roles have actually been assigned yet
---@field rolesLocked boolean once true, beginCountdown's automatic random draw no longer runs: set
---by a staff force-reassign (hunterForceFugitive) so an explicit LOBBY-time override can't get
---silently clobbered by the normal random pick moments later
---@field arenaSnapshot BJHunterArena resolved once at session-build time: editing the live arena
---mid-session can't retroactively change what's already running, same "snapshot at start" treatment
---races' own vehicle-pool resolution gets
---@field route integer[]? populated at HUNT start only when settings.winCondition == "waypoints" :
---ordered indices into arenaSnapshot.waypoints, this round's actual sampled sequence: sent ONLY to
---the hunted participant (see the plan's own "server-picked, server-validated waypoint route"
---improvement over BJI), never broadcast. Left nil for the whole hunt in "timed" mode: there is no
---route to reach, the fugitive wins purely by surviving huntDeadlineAt
---@field huntDeadlineAt integer? only set when settings.winCondition == "timed" : the
---GetCurrentTime() timestamp at which the fugitive automatically wins by survival if not yet caught
---(see onTimedModeExpired) ; nil in "waypoints" mode
---@field countdownTicking boolean false the instant COUNTDOWN begins (roles/spawns committed, field
---frozen, but the actual hunt-start timer not yet running) ; flips true (starting the real timer)
---once every participant's own vehicleConfirmed is true, or vehicleConfirmTimeout elapses regardless.
---See startCountdownTimer/hunterVehicleConfirmed
---@field debugSolo boolean? staff-only testing bypass (see hunterDebugStart / the "/hunter debug"
---chat subcommands): lets tryStartFromLobby/onGridTimeout proceed with fewer than
---MINIMUM_PARTICIPANTS and skips the lobby-floor wait entirely, so a single staff member can drive
---a Hunter session through its whole state machine alone. Never settable from the normal start UI:
---only ever true via the debug chat command, which independently re-checks isStaff itself

local M = {
    dependencies = { "services_hunter", "services_vehiclePresets", "utils_async" },

    ---@type tablelib<string, BJHunterSession>
    sessions = Table(),

    --- non-participant spectators, entirely separate from BJHunterSession/participants: same
    --- reasoning as raceGrid.lua's own M.spectators
    ---@type tablelib<integer, string> playerID -> sessionId
    spectators = Table(),
}

-- matches BJI's own hardcoded floor (a "hunt" with 0 hunters is meaningless), not host-
-- configurable, same as BJI never exposed this as a setting either
local MINIMUM_PARTICIPANTS = 2

---@param a {x: number, y: number, z: number}
---@param b {x: number, y: number, z: number}
---@return number
local function pointDistance(a, b)
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- which session (if any) a player currently belongs to: mirrors raceGrid.lua's own
--- findSessionByParticipant exactly, same "one live session per player" reasoning
---@param playerID integer
---@return BJHunterSession?
local function findSessionByParticipant(playerID)
    return M.sessions:find(function(s) return s.participants[playerID] ~= nil end)
end

---@param session BJHunterSession
---@param playerID integer
---@param playerName string
local function addParticipant(session, playerID, playerName)
    session.participants[playerID] = {
        playerID = playerID,
        playerName = playerName,
        -- role left unset (nil) here on purpose; see BJHunterParticipant.role's own doc comment
        ready = false,
        eliminated = false,
        waypointsReached = 0,
        revealed = false,
        vehicleConfirmed = false,
    }
end

--- keeps joinOrder in sync with participants (drops anyone who left/disconnected). Called after
--- every LOBBY join/leave regardless of whether roles have been committed yet, since assignRoles
--- itself needs a clean joinOrder to read from whenever it does eventually run
---@param session BJHunterSession
local function pruneJoinOrder(session)
    session.joinOrder = table.filter(session.joinOrder,
        function(id) return session.participants[id] ~= nil end)
end

--- commits joinOrder[1] as the real fugitive for every participant: the ONE place BJHunterParticipant
--- .role actually gets written. Called exactly once per round (beginCountdown, after either the
--- random draw or an already-locked-in staff choice) plus again on any later hunterForceFugitive
---@param session BJHunterSession
local function assignRoles(session)
    pruneJoinOrder(session)
    local huntedID = session.joinOrder[1]
    session.participants:forEach(function(p)
        p.role = p.playerID == huntedID and "hunted" or "hunter"
    end)
end

--- picks a uniformly random participant to be this round's fugitive, replacing the old deterministic
--- "first to join" default, per direct request, so nobody can angle for (or against) the fugitive
--- role just by racing to click Join first. Only reorders joinOrder ; assignRoles is what actually
--- turns the pick into real participant.role values.
---@param session BJHunterSession
local function randomizeFugitive(session)
    pruneJoinOrder(session)
    local pick = table.random(session.joinOrder)
    if not pick then return end
    session.joinOrder = table.filter(session.joinOrder, function(id) return id ~= pick end)
    table.insert(session.joinOrder, 1, pick)
end

--- assigns each participant a real spawn point from the role-appropriate list: hunters get
--- deduplicated slots (never two hunters on the same spawn), guaranteed non-empty by construction
--- since hunterJoin already caps hunter count at #arenaSnapshot.hunterSpawns (the structural fix for
--- BJI's own real bug : an unbounded hunter join count could exhaust majorPositions and call
--- :random() on an empty set; see the plan's "improvements over BJI")
---@param session BJHunterSession
local function assignSpawns(session)
    local arena = session.arenaSnapshot
    local huntedID = session.joinOrder[1]
    local usedHunterSlots = {}
    session.participants:forEach(function(p)
        if p.playerID == huntedID then
            local slot = table.random(arena.preySpawns)
            p.spawnPos, p.spawnDir = slot.pos, slot.dir
        else
            local available = {}
            for i, s in ipairs(arena.hunterSpawns) do
                if not usedHunterSlots[i] then table.insert(available, { index = i, slot = s }) end
            end
            local pick = table.random(available) or { index = 1, slot = arena.hunterSpawns[1] }
            usedHunterSlots[pick.index] = true
            p.spawnPos, p.spawnDir = pick.slot.pos, pick.slot.dir
        end
    end)
end

--- ported from BJI's own selection algorithm : each next waypoint is picked randomly from the
--- FARTHEST HALF of whatever's still left in the pool (by straight-line distance from the previous
--- pick), avoiding clustering the whole route near the fugitive's own spawn while staying
--- non-deterministic round to round. Runs server-side here (BJI runs the equivalent purely on the
--- fugitive's own client) specifically so the server has its own authoritative copy of the route to
--- validate checkpoint reports against; see the plan's own "server-picked, server-validated
--- waypoint route" improvement.
---@param arena BJHunterArena
---@param count integer
---@param fromPos {x: number, y: number, z: number}
---@return integer[] waypoint indices into arena.waypoints, in route order
local function pickWaypointRoute(arena, count, fromPos)
    local remaining = {}
    for i in ipairs(arena.waypoints) do table.insert(remaining, i) end
    local route = {}
    local currentPos = fromPos
    count = math.min(count, #remaining)
    for _ = 1, count do
        table.sort(remaining, function(a, b)
            return pointDistance(currentPos, arena.waypoints[a].pos) >
                pointDistance(currentPos, arena.waypoints[b].pos)
        end)
        local poolSize = math.max(1, math.ceil(#remaining / 2))
        local chosen = table.remove(remaining, math.random(1, poolSize))
        table.insert(route, chosen)
        currentPos = arena.waypoints[chosen].pos
    end
    return route
end

---@param session BJHunterSession
---@return table
local function summarize(session)
    local starter = session.participants[session.starterID]
    return {
        id = session.id,
        starterName = starter and starter.playerName or "?",
        joinable = session.joinable,
        participantCount = session.participants:length(),
        maxParticipants = 1 + #session.arenaSnapshot.hunterSpawns,
        state = session.state,
    }
end

--- the shared payload every participant/spectator gets: deliberately excludes `route` and every
--- participant's own `waypointsReached` (see BJHunterParticipant's own doc comments for why) ;
--- withHuntedPrivateFields augments a clone of this for the one recipient who's actually allowed to
--- see those two fields
---@param session BJHunterSession
---@return table
local function buildBasePayload(session)
    local payload = table.clone(session)
    payload.participants = table.map(session.participants:values(), function(p)
        local trimmed = table.clone(p)
        trimmed.waypointsReached = nil
        return trimmed
    end)
    payload.route = nil
    if session.state == "HUNT" and session.startedAt then
        -- same "push a duration, not a timestamp" reasoning as raceGrid.lua's own raceElapsedMs:
        -- session.startedAt is in the server's own GetCurrentTime() clock domain, meaningless
        -- compared directly against a client's GetCurrentTimeMillis()
        payload.huntElapsedMs = math.floor((GetCurrentTime() - session.startedAt) * 1000)
    end
    if session.state == "HUNT" and session.huntDeadlineAt then
        -- same duration-not-timestamp treatment as huntElapsedMs above, for the timed-mode
        -- survival countdown (see onTimedModeExpired)
        payload.huntTimedSecondsLeft = math.max(0, math.ceil(session.huntDeadlineAt - GetCurrentTime()))
    end
    if session.state == "LOBBY" and session.joinable then
        local elapsedSec = GetCurrentTime() - session.createdAt
        payload.gridReadySecondsLeft = math.max(0, math.ceil(session.settings.gridReadyTimeout - elapsedSec))
        payload.gridTimeoutSecondsLeft = math.max(0, math.ceil(session.settings.gridTimeout - elapsedSec))
    end
    return payload
end

---@param session BJHunterSession
---@param base table
---@param huntedPlayerID integer
---@return table
local function withHuntedPrivateFields(session, base, huntedPlayerID)
    local payload = table.clone(base)
    payload.participants = table.map(base.participants, function(p)
        if p.playerID ~= huntedPlayerID then return p end
        local withProgress = table.clone(p)
        withProgress.waypointsReached = session.participants[huntedPlayerID].waypointsReached
        return withProgress
    end)
    if session.route then
        payload.route = table.map(session.route, function(waypointIndex)
            return session.arenaSnapshot.waypoints[waypointIndex]
        end)
    end
    return payload
end

--- pushes to every current participant (the fugitive gets their own private extra fields) and every
--- spectator (the plain base payload; spectators never get the route either)
---@param session BJHunterSession
local function pushSessionUpdate(session)
    local huntedID = session.joinOrder[1]
    local base = buildBasePayload(session)
    session.participants:forEach(function(_, playerID)
        local payload = playerID == huntedID and withHuntedPrivateFields(session, base, huntedID) or base
        communications_tx.sendToPlayer(playerID, "hunterSessionUpdate", payload)
    end)
    M.spectators:forEach(function(sessionId, playerID)
        if sessionId == session.id then
            communications_tx.sendToPlayer(playerID, "hunterSpectateUpdate", base)
        end
    end)
end

local function pushOpenSessionsList()
    local visible = M.sessions:filter(function(s)
        return (s.state == "LOBBY" and s.joinable) or s.state == "COUNTDOWN" or s.state == "HUNT"
    end):map(summarize):values()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "hunterSessionsList", visible)
end

---@param session BJHunterSession
local function removeSession(session)
    utils_async.removeTask("BJHunterGrid-" .. session.id .. "-readyTimeout")
    utils_async.removeTask("BJHunterGrid-" .. session.id .. "-gridTimeout")
    utils_async.removeTask("BJHunterGrid-" .. session.id .. "-vehicleConfirm")
    utils_async.removeTask("BJHunterGrid-" .. session.id .. "-countdown")
    utils_async.removeTask("BJHunterGrid-" .. session.id .. "-timedMode")
    utils_async.removeTask("BJHunterGrid-" .. session.id .. "-cleanup")
    session.participants:forEach(function(_, playerID)
        communications_tx.sendToPlayer(playerID, "hunterSessionRemoved", session.id)
    end)
    M.spectators:forEach(function(sessionId, playerID)
        if sessionId == session.id then
            communications_tx.sendToPlayer(playerID, "hunterSpectateRemoved", session.id)
            M.spectators[playerID] = nil
        end
    end)
    M.sessions[session.id] = nil
    pushOpenSessionsList()
end

--- a real win, as opposed to hunterCancel, which tears the session down immediately with no
--- FINISHED/results step at all, matching races' own raceCancel exactly
---@param session BJHunterSession
---@param winner "hunted"|"hunters"
local function endHunt(session, winner)
    if session.state == "FINISHED" then return end
    utils_async.removeTask("BJHunterGrid-" .. session.id .. "-timedMode")
    session.state = "FINISHED"
    session.winner = winner
    pushSessionUpdate(session)
    utils_async.delayTask(function() removeSession(session) end,
        10, "BJHunterGrid-" .. session.id .. "-cleanup")
end

---@param arena BJHunterArena
---@param overrides table?
---@return BJHunterSessionSettings
local function buildSettings(arena, overrides)
    overrides = overrides or {}
    local defaults = arena.defaults or {}

    local huntedVehiclePresetId, huntedVehiclePool, huntedVehicleLabel
    local presetId = tonumber(overrides.huntedVehiclePresetId) or defaults.huntedVehiclePresetId
    if presetId then
        local preset = services_vehiclePresets.getById(presetId)
        if preset and table.isArray(preset.entries) and #preset.entries > 0 then
            huntedVehiclePresetId, huntedVehiclePool, huntedVehicleLabel = presetId, preset.entries, preset.name
        end
    end

    local huntersVehiclePresetId, huntersVehiclePool, huntersVehicleLabel
    presetId = tonumber(overrides.huntersVehiclePresetId) or defaults.huntersVehiclePresetId
    if presetId then
        local preset = services_vehiclePresets.getById(presetId)
        if preset and table.isArray(preset.entries) and #preset.entries > 0 then
            huntersVehiclePresetId, huntersVehiclePool, huntersVehicleLabel = presetId, preset.entries, preset.name
        end
    end

    local revealOnFinalWaypoint = true
    if overrides.revealOnFinalWaypoint ~= nil then
        revealOnFinalWaypoint = overrides.revealOnFinalWaypoint == true
    elseif defaults.revealOnFinalWaypoint ~= nil then
        revealOnFinalWaypoint = defaults.revealOnFinalWaypoint == true
    end

    local randomizeVehiclePool = false
    if overrides.randomizeVehiclePool ~= nil then
        randomizeVehiclePool = overrides.randomizeVehiclePool == true
    elseif defaults.randomizeVehiclePool ~= nil then
        randomizeVehiclePool = defaults.randomizeVehiclePool == true
    end

    -- must check "free" too at every step, not just the other two: otherwise an explicit "free"
    -- choice (override or saved default alike) would get silently skipped past by the next
    -- fallback, since "free" is neither "nearestSpawn" nor "hubs" either
    local hunterRespawnStrategy = overrides.hunterRespawnStrategy
    if hunterRespawnStrategy ~= "free" and hunterRespawnStrategy ~= "nearestSpawn" and hunterRespawnStrategy ~= "hubs" then
        hunterRespawnStrategy = defaults.hunterRespawnStrategy
    end
    if hunterRespawnStrategy ~= "free" and hunterRespawnStrategy ~= "nearestSpawn" and hunterRespawnStrategy ~= "hubs" then
        hunterRespawnStrategy = "nearestSpawn"
    end

    -- same "must check every valid value at every step" reasoning as hunterRespawnStrategy above:
    -- otherwise an explicit "waypoints" choice (override or saved default) could get silently
    -- skipped past by the next fallback
    local winCondition = overrides.winCondition
    if winCondition ~= "waypoints" and winCondition ~= "timed" then
        winCondition = defaults.winCondition
    end
    if winCondition ~= "waypoints" and winCondition ~= "timed" then
        winCondition = "waypoints"
    end

    return {
        waypointCount = math.max(2, math.min(math.floor(tonumber(overrides.waypointCount) or
            defaults.waypointCount or 5), math.max(2, #arena.waypoints))),
        huntedStuckTimeout = math.max(3, tonumber(overrides.huntedStuckTimeout) or
            defaults.huntedStuckTimeout or 10),
        huntedStuckDistance = math.max(.1, tonumber(overrides.huntedStuckDistance) or
            defaults.huntedStuckDistance or .5),
        huntedStartDelay = math.max(0, tonumber(overrides.huntedStartDelay) or defaults.huntedStartDelay or 0),
        huntersStartDelay = math.max(0, tonumber(overrides.huntersStartDelay) or defaults.huntersStartDelay or 5),
        huntersRespawnDelay = math.max(0, tonumber(overrides.huntersRespawnDelay) or
            defaults.huntersRespawnDelay or 10),
        respawnPenaltyIncrement = math.max(0, tonumber(overrides.respawnPenaltyIncrement) or
            defaults.respawnPenaltyIncrement or 0),
        hunterRespawnStrategy = hunterRespawnStrategy,
        -- see services/hunter.lua's own resolve step for why this rounds to the nearest 10
        -- instead of just flooring at 1: nothing else in this chain enforces the "increments of
        -- 10m" the Config UI's slider only ever promises cosmetically, client-side
        revealProximityDistance = math.max(10, math.round((tonumber(overrides.revealProximityDistance) or
            defaults.revealProximityDistance or 50) / 10) * 10),
        revealResetDuration = math.max(0, tonumber(overrides.revealResetDuration) or
            defaults.revealResetDuration or 5),
        revealOnFinalWaypoint = revealOnFinalWaypoint,
        -- same "Increments of 10m" tooltip promise as revealProximityDistance above, same gap
        huntedResetDistanceThreshold = math.max(0, math.round((tonumber(overrides.huntedResetDistanceThreshold) or
            defaults.huntedResetDistanceThreshold or 150) / 10) * 10),
        huntedVehiclePresetId = huntedVehiclePresetId,
        huntedVehiclePool = huntedVehiclePool,
        huntedVehicleLabel = huntedVehicleLabel,
        huntersVehiclePresetId = huntersVehiclePresetId,
        huntersVehiclePool = huntersVehiclePool,
        huntersVehicleLabel = huntersVehicleLabel,
        gridTimeout = math.max(10, tonumber(overrides.gridTimeout) or defaults.gridTimeout or 180),
        gridReadyTimeout = math.max(0, tonumber(overrides.gridReadyTimeout) or defaults.gridReadyTimeout or 10),
        countdown = math.clamp(tonumber(overrides.countdown) or defaults.countdown or 10, 0, 600),
        vehicleConfirmTimeout = math.max(3, tonumber(overrides.vehicleConfirmTimeout) or
            defaults.vehicleConfirmTimeout or 20),
        randomizeVehiclePool = randomizeVehiclePool,
        -- same "Increments of 10m" tooltip promise as revealProximityDistance above, same gap
        hunterNametagFadeDistance = math.max(0, math.round((tonumber(overrides.hunterNametagFadeDistance) or
            defaults.hunterNametagFadeDistance or 0) / 10) * 10),
        winCondition = winCondition,
        timedModeDuration = math.max(1, math.min(120, tonumber(overrides.timedModeDuration) or
            defaults.timedModeDuration or 10)),
    }
end

--- starts the real hunt-start timer (the ticking numeric countdown participants actually see). A
--- no-op if it's already running. Called once every participant has confirmed a matching vehicle
--- (hunterVehicleConfirmed), or once vehicleConfirmTimeout elapses regardless (onVehicleConfirmTimeout)
---@param session BJHunterSession
local function startCountdownTimer(session)
    if session.countdownTicking then return end
    session.countdownTicking = true
    utils_async.removeTask("BJHunterGrid-" .. session.id .. "-vehicleConfirm")
    utils_async.delayTask(function() M.beginHunt(session.id) end,
        session.settings.countdown, "BJHunterGrid-" .. session.id .. "-countdown")
end

--- fallback so one player stuck without a matching vehicle (mod not installed, alt-tabbed, etc.)
--- can't hold the whole lobby's countdown hostage forever: starts it anyway once this fires,
--- exactly the same "floor vs hard ceiling" shape gridReadyTimeout/gridTimeout already use for the
--- LOBBY phase
---@param sessionId string
local function onVehicleConfirmTimeout(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "COUNTDOWN" or session.countdownTicking then return end
    startCountdownTimer(session)
    pushSessionUpdate(session)
end

--- starts the countdown early if every REMAINING participant already turns out to be confirmed:
--- called after any participant removal during COUNTDOWN (leave/disconnect), so an unconfirmed
--- straggler crashing/disconnecting/AFK-quitting doesn't leave everyone else waiting out the full
--- vehicleConfirmTimeout for nothing once they're gone. A no-op outside COUNTDOWN or once already
--- ticking. Also used by hunterVehicleConfirmed itself, the normal (no departure) path to the same
--- check.
---@param session BJHunterSession
local function checkAllVehiclesConfirmed(session)
    if session.state ~= "COUNTDOWN" or session.countdownTicking then return end
    if session.participants:every(function(p) return p.vehicleConfirmed end) then
        startCountdownTimer(session)
    end
end

--- begins the pre-hunt countdown : assigns spawns, freezes the field, and waits for every
--- participant to confirm a vehicle matching their freshly-drawn role (see BJHunterSession.
--- countdownTicking) before the actual hunt-start timer begins ticking
---@param session BJHunterSession
local function beginCountdown(session)
    session.state = "COUNTDOWN"
    if not session.rolesLocked then
        randomizeFugitive(session)
        session.rolesLocked = true
    end
    assignRoles(session)
    assignSpawns(session)
    session.countdownTicking = false
    session.participants:forEach(function(p) p.vehicleConfirmed = false end)
    utils_async.delayTask(function() M.onVehicleConfirmTimeout(session.id) end,
        session.settings.vehicleConfirmTimeout, "BJHunterGrid-" .. session.id .. "-vehicleConfirm")
    pushSessionUpdate(session)
    pushOpenSessionsList()
end

---@param sessionId string
local function beginHunt(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "COUNTDOWN" then return end

    session.state = "HUNT"
    session.startedAt = GetCurrentTime()
    local hunted = session.participants[session.joinOrder[1]]
    if session.settings.winCondition == "timed" then
        -- no route at all in timed mode : the fugitive wins purely by surviving uncaught, not by
        -- reaching anything. session.route stays nil for the whole hunt (already stripped/absent
        -- from every payload the same way it always was for a hunter/spectator, see
        -- withHuntedPrivateFields), and hunterCheckpointReached's own `not session.route` guard
        -- already makes checkpoint reports a no-op with nothing further needed here
        session.route = nil
        session.huntDeadlineAt = GetCurrentTime() + session.settings.timedModeDuration * 60
        utils_async.delayTask(function() M.onTimedModeExpired(session.id) end,
            session.settings.timedModeDuration * 60, "BJHunterGrid-" .. session.id .. "-timedMode")
    else
        session.route = pickWaypointRoute(session.arenaSnapshot, session.settings.waypointCount, hunted.spawnPos)
        session.huntDeadlineAt = nil
    end
    session.participants:forEach(function(p)
        p.eliminated = false
        p.waypointsReached = 0
        p.revealed = false
    end)
    pushSessionUpdate(session)
end

--- timed-mode's own win condition : the hunters failed to catch the fugitive before the deadline,
--- a real win for the fugitive by survival, not a cancel. A no-op if the hunt already ended some
--- other way in the meantime (the fugitive was caught, someone left triggering a forfeit, etc.):
--- endHunt's own `state == "FINISHED"` guard already covers that, matching every other terminal
--- event in this file
---@param sessionId string
local function onTimedModeExpired(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "HUNT" then return end
    endHunt(session, "hunted")
end

---@param session BJHunterSession whose LOBBY phase just ended (start-now, or force-cut via timers)
local function tryStartFromLobby(session)
    if session.state ~= "LOBBY" then return end
    if session.participants:length() < MINIMUM_PARTICIPANTS and not session.debugSolo then return end
    if not session.participants:every(function(p) return p.ready end) then return end
    -- debugSolo also skips the lobby-floor wait entirely, for fast iteration; see hunterDebugStart
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
        communications_tx.sendToPlayer(p.playerID, "hunterSessionRemoved", session.id)
    end)
    pruneJoinOrder(session)
    if session.participants:length() < MINIMUM_PARTICIPANTS and not session.debugSolo then
        return removeSession(session)
    end
    beginCountdown(session)
end

---@param ctxt BJSContext
---@param opts table? see BJHunterSessionSettings for every overridable field
local function hunterStart(ctxt, opts)
    if not ctxt.sender then return end
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.hunter.alreadyInSession", ctxt.sender.lang))
    end
    local arena = services_hunter.getArena()
    if not arena or not arena.enabled then return end
    if #arena.hunterSpawns < services_hunter.MIN_HUNTER_SPAWNS or
        #arena.preySpawns < services_hunter.MIN_PREY_SPAWNS or
        #arena.waypoints < services_hunter.MIN_WAYPOINTS then
        return
    end

    opts = opts or {}
    ---@type BJHunterSession
    local session = {
        id = UUID(),
        starterID = ctxt.senderID,
        -- always joinable : a private Hunter session can never reach MINIMUM_PARTICIPANTS on its
        -- own (joining requires session.joinable, see hunterJoin), so this mode never gets a
        -- "Multiplayer" toggle the way races does: unlike a race, a solo hunt is meaningless, not
        -- just less interesting
        joinable = true,
        settings = buildSettings(arena, opts),
        state = "LOBBY",
        createdAt = ctxt.time,
        participants = Table(),
        joinOrder = {},
        rolesLocked = false,
        arenaSnapshot = table.clone(arena),
        -- never trusted from the normal client UI's own opts (a modified client could otherwise
        -- self-grant this): only ever true via the staff-gated "/hunter debug start" command,
        -- which is the only caller that ever sets this key at all
        debugSolo = opts.debugSolo == true and services_permissions.isStaff(ctxt.sender.playerName),
    }
    addParticipant(session, ctxt.senderID, ctxt.sender.playerName)
    table.insert(session.joinOrder, ctxt.senderID)
    M.sessions[session.id] = session

    utils_async.delayTask(function() tryStartFromLobby(session) end,
        session.settings.gridReadyTimeout, "BJHunterGrid-" .. session.id .. "-readyTimeout")
    utils_async.delayTask(function() onGridTimeout(session.id) end,
        session.settings.gridTimeout, "BJHunterGrid-" .. session.id .. "-gridTimeout")

    pushSessionUpdate(session)
    pushOpenSessionsList()
    return session.id
end

---@param ctxt BJSContext
---@param sessionId string
local function hunterJoin(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "LOBBY" or not session.joinable then return end
    -- Real bug (same fix as infectedGrid.lua's own infectedJoin): a session already open (still
    -- using its own frozen arenaSnapshot for the actual round, same as always) used to stay
    -- joinable by brand-new players even after the LIVE arena got disabled or dropped below the
    -- spawn minimums out from under it - the client UI now hides the "Open Lobbies" list in that
    -- case (see hunter/app.html), but a modified client could still send this event directly, so
    -- the same gate hunterStart already applies to creating a session belongs here too, for anyone
    -- trying to join one that already exists.
    local arena = services_hunter.getArena()
    if not arena or not arena.enabled then return end
    if #arena.hunterSpawns < services_hunter.MIN_HUNTER_SPAWNS or
        #arena.preySpawns < services_hunter.MIN_PREY_SPAWNS or
        #arena.waypoints < services_hunter.MIN_WAYPOINTS then
        return
    end
    if session.participants[ctxt.senderID] then return end
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.hunter.alreadyInSession", ctxt.sender.lang))
    end
    -- capacity : every participant besides the one fixed hunted slot must fit within the arena's
    -- own hunter-spawn count: the structural fix for BJI's own real bug (an unbounded hunter join
    -- count could exhaust majorPositions and call :random() on an empty set at spawn-assignment
    -- time), rejected up front here instead
    local hunterCount = session.participants:length() - 1
    if hunterCount >= #session.arenaSnapshot.hunterSpawns then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.hunter.arenaFull", ctxt.sender.lang))
    end

    addParticipant(session, ctxt.senderID, ctxt.sender.playerName)
    table.insert(session.joinOrder, ctxt.senderID)
    pruneJoinOrder(session)
    pushSessionUpdate(session)
    pushOpenSessionsList()
end

--- watch a session without becoming a participant in it: mirrors raceGrid.lua's own raceSpectate
---@param ctxt BJSContext
---@param sessionId string
local function hunterSpectate(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state == "LOBBY" or session.state == "FINISHED" then return end
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.hunter.alreadyInSession", ctxt.sender.lang))
    end

    M.spectators[ctxt.senderID] = sessionId
    communications_tx.sendToPlayer(ctxt.senderID, "hunterSpectateUpdate", buildBasePayload(session))
end

---@param ctxt BJSContext
local function hunterStopSpectate(ctxt)
    if not ctxt.sender then return end
    local sessionId = M.spectators[ctxt.senderID]
    if not sessionId then return end
    M.spectators[ctxt.senderID] = nil
    communications_tx.sendToPlayer(ctxt.senderID, "hunterSpectateRemoved", sessionId)
end

---@param ctxt BJSContext
---@param sessionId string
local function hunterLeave(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or not session.participants[ctxt.senderID] then return end

    local wasHunted = session.participants[ctxt.senderID].role == "hunted"
    session.participants[ctxt.senderID] = nil
    communications_tx.sendToPlayer(ctxt.senderID, "hunterSessionRemoved", sessionId)
    if session.participants:length() == 0 then
        return removeSession(session)
    end
    if ctxt.senderID == session.starterID then
        session.starterID = session.participants:keys()[1]
    end
    pruneJoinOrder(session)

    if session.state == "LOBBY" then
        tryStartFromLobby(session)
    elseif session.state == "COUNTDOWN" or session.state == "HUNT" then
        if wasHunted then
            -- explicit forfeit, matching BJI : the fugitive quitting mid-chase is a hunters win,
            -- not a silent role handoff to whoever's now first in joinOrder
            return endHunt(session, "hunters")
        elseif session.participants:length() - 1 < 1 then -- -1 for the fixed hunted slot
            -- every hunter is gone ; nobody left to catch the fugitive
            return endHunt(session, "hunted")
        end
        -- a still-unconfirmed departing participant might have been the only thing left blocking
        -- the countdown from starting; see checkAllVehiclesConfirmed's own comment
        checkAllVehiclesConfirmed(session)
    end
    if M.sessions[sessionId] then
        pushSessionUpdate(session)
        pushOpenSessionsList()
    end
end

--- session starter or staff only: tears the session down immediately, no FINISHED/results step at
--- all, matching races' own raceCancel exactly (as opposed to endHunt, a real win)
---@param ctxt BJSContext
---@param sessionId string
local function hunterCancel(ctxt, sessionId)
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
---"reliable way to get it" reasoning as raceGrid.lua's own raceReady
local function hunterReady(ctxt, sessionId, ready, model)
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
--- unreadies a LOBBY participant the moment their vehicle's actual config changes (parts, tuning,
--- anything BeamMP's own onVehicleEdited fires for), per direct report ; same reasoning and
--- exact-mirror implementation as raceGrid.lua's own unreadyOnVehicleChange
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
---@param routeIndex integer 1-based position within this round's own route the fugitive claims to
---have just reached
---@param pos {x: number, y: number, z: number} the fugitive's own reported position at the moment
---of the crossing, checked against the claimed waypoint's real position/radius: see the plan's own
---"server-picked, server-validated waypoint route" improvement over BJI's fully client-trusted
---checkpoint reports. The stuck-timer elimination report (hunterEliminated, below) stays
---client-detected/self-reported like BJI: verifying "is this vehicle actually stuck" server-side
---would need continuous position streaming this fork doesn't do for non-participants, an accepted,
---unchanged limitation
local function hunterCheckpointReached(ctxt, sessionId, routeIndex, pos)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "HUNT" or not session.route then return end
    local huntedID = session.joinOrder[1]
    if ctxt.senderID ~= huntedID then return end
    local participant = session.participants[huntedID]
    if not participant or participant.eliminated then return end

    local expected = participant.waypointsReached + 1
    if routeIndex ~= expected or expected > #session.route then return end

    local waypoint = session.arenaSnapshot.waypoints[session.route[routeIndex]]
    if not waypoint or type(pos) ~= "table" then return end
    if pointDistance(pos, waypoint.pos) > waypoint.radius then return end

    participant.waypointsReached = expected
    if expected >= #session.route then
        return endHunt(session, "hunted")
    end
    pushSessionUpdate(session)
end

---@param ctxt BJSContext
---@param sessionId string
---@param revealed boolean self-computed by the fugitive's own client from all three BJI-ported
---triggers at once (proximity / near-final-waypoint / post-reset); see the plan's reveal-mechanic
---section for why this stays client-computed rather than needing new server-side position
---streaming, matching the same accepted trust model this file's own checkpoint reports use
local function hunterRevealUpdate(ctxt, sessionId, revealed)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "HUNT" then return end
    local huntedID = session.joinOrder[1]
    if ctxt.senderID ~= huntedID then return end

    revealed = revealed == true
    if session.participants[huntedID].revealed == revealed then return end
    session.participants[huntedID].revealed = revealed
    pushSessionUpdate(session)
end

---@param ctxt BJSContext
---@param sessionId string
local function hunterEliminated(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "HUNT" then return end
    local huntedID = session.joinOrder[1]
    if ctxt.senderID ~= huntedID then return end
    local participant = session.participants[huntedID]
    if not participant or participant.eliminated then return end

    participant.eliminated = true
    endHunt(session, "hunters")
end

--- self-reported by a participant's own client once its current vehicle actually matches the pool
--- their freshly-drawn role requires (or there's no pool to match at all); see hunterRunner.lua's
--- own COUNTDOWN-transition steering / onVehicleSpawned. Starts the real hunt-start timer the
--- instant every participant has reached this, so nobody's clock is ticking down while someone else
--- is still mid-reselect in the vehicle selector
---@param ctxt BJSContext
---@param sessionId string
local function hunterVehicleConfirmed(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "COUNTDOWN" then return end
    local participant = session.participants[ctxt.senderID]
    if not participant or participant.vehicleConfirmed then return end

    participant.vehicleConfirmed = true
    checkAllVehiclesConfirmed(session)
    pushSessionUpdate(session)
end

--- staff-only, matching BJI's own more restrictive gate on this specific action (session starters
--- can cancel their own lobby, but reassigning roles mid-round is moderation-flavored). Swaps
--- targetPlayerID to the front of joinOrder and regenerates spawns for both the old and new fugitive
--- so the new one's spawn isn't spoiled to hunters who already saw the old one. Locks the session's
--- roles immediately (even during LOBBY, before the normal random draw would otherwise run) so this
--- explicit choice can't get silently overwritten by beginCountdown moments later.
---@param ctxt BJSContext
---@param sessionId string
---@param targetPlayerID integer
local function hunterForceFugitive(ctxt, sessionId, targetPlayerID)
    if not ctxt.sender or not services_permissions.isStaff(ctxt.sender.playerName) then return end
    local session = M.sessions[sessionId]
    -- per direct request : once the hunt has actually started, reassigning the fugitive would
    -- retroactively spoil the route/spawn a hunter already saw, mid-chase: only meaningful during
    -- LOBBY/COUNTDOWN, before real positions are in play
    if not session or session.state == "HUNT" or session.state == "FINISHED" then return end
    if not session.participants[targetPlayerID] then return end
    if session.participants[targetPlayerID].role == "hunted" then return end

    session.joinOrder = table.filter(session.joinOrder, function(id) return id ~= targetPlayerID end)
    table.insert(session.joinOrder, 1, targetPlayerID)
    session.rolesLocked = true
    assignRoles(session)
    if session.state == "COUNTDOWN" or session.state == "HUNT" then
        assignSpawns(session)
    end
    pushSessionUpdate(session)
end

--- ============================================================================================
--- Staff-only solo-testing debug tools ("/hunter debug ..."). Hunter is fundamentally asymmetric
--- (1 fugitive vs N hunters), so a single tester can never exercise both sides live at once the
--- way a real match would: these commands exist to let one person still walk the ENTIRE state
--- machine and inspect either role's own mechanics in isolation, not to simulate a real opponent.
--- Every entry point independently re-checks isStaff itself (never trusts a caller's own gate).
--- ============================================================================================

--- bypasses MINIMUM_PARTICIPANTS and the lobby-floor wait (see tryStartFromLobby's own debugSolo
--- check) so a lone staff member reaches COUNTDOWN almost immediately, as the round's sole
--- participant: assignRoles will always make them the fugitive to start (joinOrder[1] is the only
--- id there can be), see hunterDebugSetRole below for switching to "hunter" afterward.
---@param ctxt BJSContext
---@return string? error
local function hunterDebugStart(ctxt)
    if findSessionByParticipant(ctxt.senderID) then
        return services_lang.get("error.hunter.alreadyInSession", ctxt.sender.lang)
    end
    local sessionId = M.hunterStart(ctxt, { debugSolo = true })
    if not sessionId then
        return services_lang.get("chat.command.hunter.debug.startFailed", ctxt.sender.lang)
    end
    M.hunterReady(ctxt, sessionId, true)
end

--- forces the sender's OWN role directly, independent of joinOrder/assignRoles (which always
--- assigns strictly by join order and can't produce "hunter" at all with a single real
--- participant). Then regenerates just this one participant's own spawn from the role-appropriate
--- list, matching whatever assignSpawns would have picked for a real participant in that role.
--- Deliberately does not touch joinOrder or re-run assignRoles/assignSpawns for anyone else :
--- with typically one participant there's nobody else to keep consistent, and doing so would only
--- reintroduce the "always ends up hunted" problem this command exists to route around.
---@param ctxt BJSContext
---@param session BJHunterSession
---@param role BJHunterRole
---@return string? error
local function hunterDebugSetRole(ctxt, session, role)
    if session.state ~= "COUNTDOWN" and session.state ~= "HUNT" then
        return services_lang.get("chat.command.hunter.debug.notActive", ctxt.sender.lang)
    end
    local participant = session.participants[ctxt.senderID]
    if not participant then return end
    participant.role = role
    local arena = session.arenaSnapshot
    local list = role == "hunted" and arena.preySpawns or arena.hunterSpawns
    local slot = table.random(list)
    if slot then
        participant.spawnPos, participant.spawnDir = slot.pos, slot.dir
    end
    pushSessionUpdate(session)
end

--- force-completes the round immediately with the given winner: for testing the finish popup/
--- notification/teardown without actually driving a full route or waiting out an elimination
---@param ctxt BJSContext
---@param session BJHunterSession
---@param winner "hunted"|"hunters"
---@return string? error
local function hunterDebugFinish(ctxt, session, winner)
    if session.state ~= "COUNTDOWN" and session.state ~= "HUNT" then
        return services_lang.get("chat.command.hunter.debug.notActive", ctxt.sender.lang)
    end
    endHunt(session, winner)
end

--- force-completes the fugitive's own current waypoint without any position/radius check:
--- mirrors hunterCheckpointReached's own completion logic exactly, just skipping its validation,
--- so the whole route (or the reveal-on-final-waypoint trigger) can be exercised in seconds
---@param ctxt BJSContext
---@param session BJHunterSession
---@return string? error
local function hunterDebugSkipWaypoint(ctxt, session)
    if session.state ~= "HUNT" or not session.route then
        return services_lang.get("chat.command.hunter.debug.notActive", ctxt.sender.lang)
    end
    local huntedID = session.joinOrder[1]
    if ctxt.senderID ~= huntedID or session.participants[huntedID].role ~= "hunted" then
        return services_lang.get("chat.command.hunter.debug.notHunted", ctxt.sender.lang)
    end
    local participant = session.participants[huntedID]
    if participant.eliminated then return end
    local expected = participant.waypointsReached + 1
    if expected > #session.route then return end
    participant.waypointsReached = expected
    if expected >= #session.route then
        return endHunt(session, "hunted")
    end
    pushSessionUpdate(session)
end

---@param ctxt BJSContext
---@param args string[] "debug <start|role <hunter|hunted>|finish <hunted|hunters>|waypoint>"
local function chatHunterDebug(ctxt, args)
    if not services_permissions.isStaff(ctxt.sender.playerName) then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.hunter.debug.staffOnly", ctxt.sender.lang), services_chat.COLORS.ERROR)
    end
    local sub = args[2] and args[2]:lower()
    local usage = function()
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.hunter.debug.usage", ctxt.sender.lang), services_chat.COLORS.ERROR)
    end

    -- directSend has no return value, so the classic Lua `cond and A or B` ternary can't be used
    -- here (A evaluating to nil would silently fall through to B too, double-sending). Explicit
    -- if/else throughout, matching chatHunter's own cancel branch below
    if sub == "start" then
        local err = hunterDebugStart(ctxt)
        if err then
            return services_chat.directSend(ctxt.senderID, err, services_chat.COLORS.ERROR)
        end
        return services_chat.directSend(ctxt.senderID, services_lang.get("chat.command.hunter.debug.started", ctxt.sender.lang))
    end

    local session = findSessionByParticipant(ctxt.senderID)
    if not session then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.hunter.notInSession", ctxt.sender.lang), services_chat.COLORS.ERROR)
    end

    if sub == "role" then
        local role = args[3] and args[3]:lower()
        if role ~= "hunter" and role ~= "hunted" then return usage() end
        local err = hunterDebugSetRole(ctxt, session, role)
        if err then
            return services_chat.directSend(ctxt.senderID, err, services_chat.COLORS.ERROR)
        end
        return services_chat.directSend(ctxt.senderID,
            string.format("%s %s", services_lang.get("chat.command.hunter.debug.roleSet", ctxt.sender.lang), role))
    elseif sub == "finish" then
        local winner = args[3] and args[3]:lower()
        if winner ~= "hunted" and winner ~= "hunters" then return usage() end
        local err = hunterDebugFinish(ctxt, session, winner)
        if err then
            return services_chat.directSend(ctxt.senderID, err, services_chat.COLORS.ERROR)
        end
        return services_chat.directSend(ctxt.senderID,
            string.format("%s %s", services_lang.get("chat.command.hunter.debug.finished", ctxt.sender.lang), winner))
    elseif sub == "waypoint" then
        local err = hunterDebugSkipWaypoint(ctxt, session)
        if err then
            return services_chat.directSend(ctxt.senderID, err, services_chat.COLORS.ERROR)
        end
        return services_chat.directSend(ctxt.senderID, services_lang.get("chat.command.hunter.debug.waypointSkipped", ctxt.sender.lang))
    end
    return usage()
end

--- chat-command front door for join/leave/ready/cancel : "join" resolves the first open lobby (no
--- session-id concept a chat-only player would otherwise have any way to supply) ; the other three
--- act on "whichever session I'm currently in", same as raceGrid.lua's own chatRace
---@param ctxt BJSContext
---@param args string[] "<join|leave|ready|cancel>"
---@param command BJChatCommand
local function chatHunter(ctxt, args, command)
    local sub = args[1] and args[1]:lower()
    -- routed before the generic usage-error check below so a non-staff player typing this still
    -- gets a clean "staff only" response from chatHunterDebug rather than a bare usage error, while
    -- staff itself gets full debug functionality not otherwise advertised in the base usage string
    if sub == "debug" then
        return chatHunterDebug(ctxt, args)
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
                services_lang.get("chat.command.hunter.noneOpen", ctxt.sender.lang), services_chat.COLORS.ERROR)
        end
        return M.hunterJoin(ctxt, open.id)
    end

    local session = findSessionByParticipant(ctxt.senderID)
    if not session then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.hunter.notInSession", ctxt.sender.lang), services_chat.COLORS.ERROR)
    end

    if sub == "leave" then
        M.hunterLeave(ctxt, session.id)
        services_chat.directSend(ctxt.senderID, services_lang.get("chat.command.hunter.left", ctxt.sender.lang))
    elseif sub == "ready" then
        local participant = session.participants[ctxt.senderID]
        local nowReady = not participant.ready
        M.hunterReady(ctxt, session.id, nowReady)
        services_chat.directSend(ctxt.senderID,
            services_lang.get(nowReady and "chat.command.hunter.readyOn" or "chat.command.hunter.readyOff",
                ctxt.sender.lang))
    elseif sub == "cancel" then
        local sessionId = session.id
        M.hunterCancel(ctxt, sessionId)
        if M.sessions[sessionId] then
            services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.error.noPermission", ctxt.sender.lang), services_chat.COLORS.ERROR)
        else
            services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.hunter.cancelled", ctxt.sender.lang))
        end
    end
end

local function onInit()
    communications_rx.addHandler("hunterStart", M.hunterStart)
    communications_rx.addHandler("hunterJoin", M.hunterJoin)
    communications_rx.addHandler("hunterLeave", M.hunterLeave)
    communications_rx.addHandler("hunterCancel", M.hunterCancel)
    communications_rx.addHandler("hunterReady", M.hunterReady)
    communications_rx.addHandler("hunterCheckpointReached", M.hunterCheckpointReached)
    communications_rx.addHandler("hunterEliminated", M.hunterEliminated)
    communications_rx.addHandler("hunterRevealUpdate", M.hunterRevealUpdate)
    communications_rx.addHandler("hunterForceFugitive", M.hunterForceFugitive)
    communications_rx.addHandler("hunterVehicleConfirmed", M.hunterVehicleConfirmed)
    communications_rx.addHandler("hunterSpectate", M.hunterSpectate)
    communications_rx.addHandler("hunterStopSpectate", M.hunterStopSpectate)

    services_chatCommands.addCommand("hunter", "chat.command.hunter.desc", M.chatHunter,
        { commandKey = "chat.command.hunter.command" })
end

---@param playerID integer
--- inlined rather than routed through hunterLeave/hunterEliminated : same "other extensions' own
--- onPlayerDisconnect handlers may have already cleared services_players.players by the time this
--- one runs" reasoning as raceGrid.lua's own onPlayerDisconnect
local function onPlayerDisconnect(playerID)
    M.spectators[playerID] = nil
    M.sessions:forEach(function(session)
        if not session.participants[playerID] then return end

        if session.state == "LOBBY" then
            session.participants[playerID] = nil
            if session.participants:length() == 0 then
                return removeSession(session)
            end
            if playerID == session.starterID then
                session.starterID = session.participants:keys()[1]
            end
            pruneJoinOrder(session)
            tryStartFromLobby(session)
            pushSessionUpdate(session)
            pushOpenSessionsList()
        elseif session.state == "COUNTDOWN" or session.state == "HUNT" then
            local wasHunted = session.participants[playerID].role == "hunted"
            session.participants[playerID] = nil
            if session.participants:length() == 0 then
                return removeSession(session)
            end
            pruneJoinOrder(session)
            if wasHunted then
                return endHunt(session, "hunters")
            elseif session.participants:length() - 1 < 1 then
                return endHunt(session, "hunted")
            end
            checkAllVehiclesConfirmed(session)
            pushSessionUpdate(session)
        end
    end)
end

M.onInit = onInit
M.onPlayerDisconnect = onPlayerDisconnect

M.hunterStart = hunterStart
M.hunterJoin = hunterJoin
M.hunterLeave = hunterLeave
M.hunterCancel = hunterCancel
M.hunterReady = hunterReady
M.unreadyOnVehicleChange = unreadyOnVehicleChange
M.hunterCheckpointReached = hunterCheckpointReached
M.hunterEliminated = hunterEliminated
M.hunterRevealUpdate = hunterRevealUpdate
M.hunterForceFugitive = hunterForceFugitive
M.hunterVehicleConfirmed = hunterVehicleConfirmed
M.hunterSpectate = hunterSpectate
M.hunterStopSpectate = hunterStopSpectate
M.beginHunt = beginHunt
M.onVehicleConfirmTimeout = onVehicleConfirmTimeout
M.onTimedModeExpired = onTimedModeExpired
M.chatHunter = chatHunter

return M
