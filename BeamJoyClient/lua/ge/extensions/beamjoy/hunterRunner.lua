--- Live Hunter-round runtime: receives session state from `services/hunterGrid.lua`, drives the
--- local stuck-timer/reveal/hunter-reset mechanics (all pure client-side, self-reported, see the
--- plan's own "accepted limitation" note), and reports checkpoint/elimination progress back to the
--- server for the fugitive. Mirrors `raceRunner.lua`'s own shape closely (session tracking,
--- restrictions, camera/freeze lock, vehicle-pool enforcement) but trimmed to Hunter's simpler
--- mechanics: no gates/sectors/leaderboard.
---
--- Console entry points for testing ahead of any UI: `beamjoy_hunterRunner.startHunt()`,
--- `beamjoy_hunterRunner.ready()`, `beamjoy_hunterRunner.leave()`.

local CAMERA_RELEASE_SECONDS = 3
local STUCK_WARNING_SECONDS = 5

local M = {
    dependencies = { "beamjoy_hunter", "beamjoy_vehicles", "beamjoy_players", "camera" },

    ---@type BJHunterSession?
    session = nil,
    huntStartTimeMs = nil,
    gridReadyTargetMs = nil,
    gridTimeoutTargetMs = nil,

    -- COUNTDOWN camera-lock/freeze state, same technique as raceRunner.lua's own. countdownStartMs
    -- stays nil while COUNTDOWN is only waiting on vehicle confirmations (see
    -- session.countdownTicking); it's only ever set once the server actually starts the real
    -- hunt-start timer, not the instant COUNTDOWN itself begins
    scenarioLocked = false,
    countdownStartMs = nil,
    countdownTotal = nil,
    lastSentSeconds = nil,
    sentWaitingBroadcast = false,
    ---@type boolean whether THIS client has already sent its own hunterVehicleConfirmed this
    ---COUNTDOWN. Distinguishes "still picking my own vehicle" (choosingOwn) from "waiting on
    ---everyone ELSE" (waiting) in the countdown overlay, instead of showing the same generic
    ---"waiting for players" text to a player who hasn't even picked their own vehicle yet
    selfVehicleConfirmed = false,
    ---@type boolean? last `choosingOwn` value actually broadcast, so updateCountdown can re-send
    ---the instant it changes rather than only once per COUNTDOWN
    lastWaitingChoosingOwn = nil,
    cameraReleased = false,
    ---@type string? camera mode the player was on before it got forced to EXTERNAL
    previousCamera = nil,

    ---@type integer? vid of the local player's own current session vehicle, tracked so
    ---onVehicleDestroyed can tell "MY vehicle was destroyed" apart from any other vehicle in the
    ---world being destroyed (see its own comment for why this matters, the fugitive forfeit rule)
    myVehicleVid = nil,

    -- fugitive-only, local stuck-timer mechanic (BJI convention: >stuckDistance == still moving)
    lastProgressPos = nil,
    lastProgressCheckMs = nil,
    lastStuckWarningSecond = nil,

    -- fugitive-only, local reveal computation (proximity / near-final-waypoint / post-reset),
    -- self-reported to the server via hunterRevealUpdate so every other client can read one shared
    -- boolean instead of each independently re-deriving it
    revealedLocally = false,
    revealedUntilMs = nil, -- post-reset reveal window

    ---@type integer? fugitive-only: 1-based index into session.route of whichever waypoint the
    ---native GPS (core_groundMarkers) is currently pointed at, tracked so updateGpsGuidance only
    ---re-issues setPath when the actual target changes, not every slow tick
    lastGpsWaypointIndex = nil,

    -- hunter-only, local crash-reset penalty (freeze + camera lock for huntersRespawnDelay)
    hunterResetLockedUntilMs = nil,
    ---@type integer hunter-only : how many times THIS hunter has reset/crashed this hunt, shown on
    ---their own HUD ; reset to 0 at every fresh HUNT start
    hunterResetCount = 0,
    ---@type integer? local anchor (GetCurrentTimeMillis domain) for a pure spectator's own smooth
    ---elapsed-time display, re-derived from the server's own huntElapsedMs snapshot on every
    ---spectate update (see pushHud's own comment for why a snapshot alone isn't enough)
    spectatingHuntStartTimeMs = nil,
    ---@type integer? local target (GetCurrentTimeMillis domain) for the timed-mode survival
    ---countdown shown on the HUD ; re-derived from the server's own huntTimedSecondsLeft snapshot on
    ---every session update, same self-correcting anchor-and-tick technique as huntStartTimeMs above
    huntDeadlineTargetMs = nil,
    ---@type integer? same as huntDeadlineTargetMs but for a pure spectator, re-derived on every
    ---spectate update
    spectatingHuntDeadlineTargetMs = nil,
    ---@type boolean fugitive-only : whether any hunter is currently within
    ---huntedResetDistanceThreshold, gating the reset/recover restriction in onBJRequestRestrictions
    huntedResetLocked = false,

    lastHudPushMs = nil,

    ---@type BJHunterSession? a session being watched as a pure non-participant, mirrors
    ---raceRunner.lua's own spectatingSession (entirely separate from M.session)
    spectatingSession = nil,

    ---@type table[] last-known open/joinable hunter lobby list, for the remount-gap request-replay
    openSessions = {},
}

---@return BJHunterParticipant?
local function getSelfParticipant()
    if not M.session then return nil end
    local selfName = MPConfig.getNickname()
    return table.find(M.session.participants, function(p) return p.playerName == selfName end)
end

---@param session BJHunterSession?
---@return BJHunterParticipant?
local function getHunted(session)
    session = session or M.session
    if not session then return nil end
    return table.find(session.participants, function(p) return p.role == "hunted" end)
end

--- true from COUNTDOWN through HUNT: the frozen/locked window race-integrity restrictions apply
---@return boolean
local function isHuntLocked()
    return M.session ~= nil and (M.session.state == "COUNTDOWN" or M.session.state == "HUNT")
end

--- shared by every "my vehicle is confirmed" call site (matches/randomize/onBJVehicleInstantiated)
--- so the local "have I personally confirmed yet" flag can't drift out of sync with the actual send
---@param sessionId string
local function confirmOwnVehicle(sessionId)
    M.selfVehicleConfirmed = true
    beamjoy_communications.send("hunterVehicleConfirmed", sessionId)
end

--- whether `mpVeh` is the current fugitive's OWN vehicle and should be hidden (nametag/minimap)
--- from every OTHER client right now. Never hides it on the fugitive's own client (their own
--- vehicle's self-nametag is already excluded by nametags.lua's own pre-existing "don't show your
--- own tag while driving" check, and minimap uiState is only ever toggled off for a REMOTE copy,
--- see updateRevealVisuals below)
---@param mpVeh BJVehicle
---@return boolean
local function isHiddenFugitiveVehicle(mpVeh)
    local session = M.session or M.spectatingSession
    if not session or session.state ~= "HUNT" then return false end
    local hunted = getHunted(session)
    if not hunted or hunted.revealed then return false end
    return mpVeh.ownerName == hunted.playerName and not mpVeh.isLocal
end

--- Inverse-ish of isHiddenFugitiveVehicle: true only for the fugitive's own (remote) vehicle once
--- actually revealed. Used by nametags.lua to force-draw just this one tag even for a viewer who
--- has nametags globally disabled. The reveal is core Hunter gameplay, not cosmetic, so it
--- shouldn't stop working just because a player turned nametags off. Deliberately narrow: every
--- other vehicle's nametag still respects the viewer's own preference untouched.
---@param mpVeh BJVehicle
---@return boolean
local function isRevealedFugitiveVehicle(mpVeh)
    local session = M.session or M.spectatingSession
    if not session or session.state ~= "HUNT" then return false end
    local hunted = getHunted(session)
    if not hunted or not hunted.revealed then return false end
    return mpVeh.ownerName == hunted.playerName and not mpVeh.isLocal
end

--- distance-fade multiplier for a hunter's own nametag, per hunterNametagFadeDistance. Applied on
--- top of (multiplied against) the viewer's own generic client-side nametag-fade alpha in
--- nametags.lua's drawNametag, not a replacement for it. Returns 1 (no effect at all) whenever
--- there's no active hunt, the setting is 0/unset, or `mpVeh` isn't a hunter-role participant right
--- now. Deliberately not scoped to only the fugitive's own viewpoint: every hunter sees every
--- OTHER hunter fade the same way, keeping this one simple distance rule instead of a per-viewer-
--- role branch that would only matter for a symmetry nobody actually asked for.
---@param mpVeh BJVehicle
---@param dist number
---@return number alpha multiplier in [0, 1], 1 meaning "no effect"
local function hunterNametagAlpha(mpVeh, dist)
    local session = M.session or M.spectatingSession
    if not session or session.state ~= "HUNT" then return 1 end
    local fadeDistance = session.settings.hunterNametagFadeDistance
    if not fadeDistance or fadeDistance <= 0 then return 1 end
    local isHunter = table.find(session.participants, function(p)
        return p.playerName == mpVeh.ownerName and p.role == "hunter"
    end) ~= nil
    if not isHunter then return 1 end
    return math.scale(dist, fadeDistance, 0, 0, 1, true)
end

---@return {model: string, config: string, label: string, parts: table}[]? pool, string? label
local function activeVehiclePool()
    if not M.session then return nil end
    local participant = getSelfParticipant()
    if not participant or participant.role == nil then return nil end
    if participant.role == "hunted" then
        return M.session.settings.huntedVehiclePool, M.session.settings.huntedVehicleLabel
    end
    return M.session.settings.huntersVehiclePool, M.session.settings.huntersVehicleLabel
end

---@param veh NGVehicle
---@param pool {model: string, parts: table}[]
---@return boolean
local function vehicleMatchesPool(veh, pool)
    local full = beamjoy_vehicles.getFullConfig(veh)
    if not full then return false end
    return table.find(pool, function(v)
        return v.model == full.model and v.parts ~= nil and table.deepcompare(full.parts or {}, v.parts)
    end) ~= nil
end

--- whether `model` is actually spawnable on THIS client right now: see raceRunner.lua's own
--- modelAvailableLocally for why this matters (a pool entry can reference a mod the preset's
--- author has that a joining participant doesn't)
---@param model string
---@return boolean
local function modelAvailableLocally(model)
    local configs = beamjoy_vehicles.getAllVehicleConfigs(nil, { trailers = true, props = true })
    return configs[model] ~= nil
end

--- randomizeVehiclePool's own force-spawn, mirroring raceRunner.lua's identical helper: picks a
--- uniformly random pool entry (restricted to ones actually installed locally) and spawns it via
--- its own real `config` file, same as the native selector would present.
---@param pool {model: string, config: string, label: string, parts: table}[]
---@return boolean success
local function forceRandomPoolVehicle(pool)
    local available = table.filter(pool, function(v) return modelAvailableLocally(v.model) end)
    if #available == 0 then return false end
    local entry = available[math.random(#available)]
    local pos
    local currVeh = beamjoy_vehicles.getCurrent()
    if currVeh and camera.getCamera() ~= camera.CAMERAS.FREE then
        pos = beamjoy_vehicles.getVehiclePositionRotation(currVeh.veh)
    else
        pos = camera.getPositionRotation(false)
    end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh then
        beamjoy_vehicles.deleteCurrentOwnVehicle()
    end
    local newVeh = core_vehicles.spawnNewVehicle(entry.model, { pos = pos, config = entry.config })
    if newVeh then
        be:enterVehicle(0, newVeh)
        if camera.getCamera() == camera.CAMERAS.FREE then
            camera.toggleFreeCam()
        end
        return true
    end
    return false
end

--- respawn-strategy helper for the incremental-penalty/respawn-hub feature: the closest entry in
--- `list` to `pos` (straight-line distance, matching this codebase's own established "good enough,
--- no navgraph needed" convention for this class of pick; see GPS guidance's own comment)
---@param list {pos: {x: number, y: number, z: number}, dir: {x: number, y: number, z: number}}[]
---@param pos vec3
---@return {pos: {x: number, y: number, z: number}, dir: {x: number, y: number, z: number}}?
local function nearestSpawnPoint(list, pos)
    local best, bestDist
    for _, s in ipairs(list) do
        local d = (vec3(s.pos.x, s.pos.y, s.pos.z) - pos):length()
        if not bestDist or d < bestDist then
            best, bestDist = s, d
        end
    end
    return best
end

--- "nearestSpawn" strategy's own refinement, per direct request: prefer a hunter spawn that's also
--- OUTSIDE the fugitive's own huntedResetDistanceThreshold, so respawning a hunter after their
--- crash penalty doesn't just extend/renew the fugitive's own reset-lock the instant they reappear
--- nearby. The fugitive's live position is read the same way updateFugitiveState's own hunter-
--- proximity scan already does the reverse (beamjoy_vehicles.vehicles by ownerName). The fugitive's
--- minimap/nametag visibility is purely a rendering trick (see isHiddenFugitiveVehicle); the actual
--- replicated position data is always there regardless of reveal state, so this is no different a
--- privacy concern than any other purely internal computation already made in this file. Falls back
--- to the plain closest spawn (nearestSpawnPoint) whenever there's no fugitive to consider, no real
--- threshold configured, or literally every spawn is within it.
---@param list {pos: {x: number, y: number, z: number}, dir: {x: number, y: number, z: number}}[]
---@param pos vec3 the hunter's own crash position
---@return {pos: {x: number, y: number, z: number}, dir: {x: number, y: number, z: number}}?
local function nearestHunterSpawnClearOfFugitive(list, pos)
    local threshold = M.session and M.session.settings.huntedResetDistanceThreshold
    local hunted = M.session and getHunted(M.session)
    if not threshold or threshold <= 0 or not hunted or hunted.eliminated then
        return nearestSpawnPoint(list, pos)
    end
    local fugitiveVeh = beamjoy_vehicles.vehicles:find(function(v) return v.ownerName == hunted.playerName end)
    if not fugitiveVeh then
        return nearestSpawnPoint(list, pos)
    end
    local clear = table.filter(list, function(s)
        return (vec3(s.pos.x, s.pos.y, s.pos.z) - fugitiveVeh.position):length() > threshold
    end)
    if #clear > 0 then
        return nearestSpawnPoint(clear, pos)
    end
    return nearestSpawnPoint(list, pos)
end

--- real enforcement (not just the ready()-time UX nag), routed through the same generic
--- spawn-authorization hook races' own onBJRequestCanSpawnVehicle already uses
---@param req RequestAuthorization
---@param model string
---@param config string?
---@param action ("spawn"|"replace"|"clone")? which native operation this authorization check is
---actually for: see vehicleSelector.lua's own comments (confirmed against the installed game's
---source). "replace" (a normal tile pick) deletes the existing vehicle itself, so it's never a
---"second vehicle" concern; "spawn" (the separate "Spawn New" action) and "clone" both never
---delete anything, genuinely leaving two vehicles at once
local function onBJRequestCanSpawnVehicle(req, model, config, action)
    local pool = activeVehiclePool()
    if pool then
        local allowed = table.find(pool, function(v) return v.model == model and v.config == config end) ~= nil
        if not allowed then
            req.state = false
            return
        end
    end

    if not isHuntLocked() then return end

    -- Rejects a genuinely additional simultaneous vehicle for anyone locked into a hunt. Cloning is
    -- rejected outright, and spawning a fresh one on top of an existing real vehicle is rejected
    -- too (the walking-mode "vehicle" doesn't count, matching this file's own hasVehicle convention).
    if action == "clone" then
        req.state = false
        return
    end
    if action == "spawn" then
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh and myVeh.veh.jbeam ~= beamjoy_vehicles.WALKING then
            req.state = false
        end
    end
end

local function onInit()
    beamjoy_communications.addHandler("hunterSessionUpdate", M.onSessionUpdate)
    beamjoy_communications.addHandler("hunterSessionsList", M.onSessionsList)
    beamjoy_communications.addHandler("hunterSessionRemoved", M.onSessionRemoved)
    beamjoy_communications.addHandler("hunterSpectateUpdate", M.onSpectateUpdate)
    beamjoy_communications.addHandler("hunterSpectateRemoved", M.onSpectateRemoved)

    beamjoy_communications_ui.addHandler("BJHunterStart", M.startHunt)
    beamjoy_communications_ui.addHandler("BJHunterJoin", M.joinHunt)
    beamjoy_communications_ui.addHandler("BJHunterReady", M.ready)
    beamjoy_communications_ui.addHandler("BJHunterLeave", M.leave)
    beamjoy_communications_ui.addHandler("BJHunterCancel", M.cancel)
    beamjoy_communications_ui.addHandler("BJHunterForceFugitive", M.forceFugitive)
    beamjoy_communications_ui.addHandler("BJHunterSpectate", M.spectateSession)
    beamjoy_communications_ui.addHandler("BJHunterStopSpectate", M.stopSpectating)
    beamjoy_communications_ui.addHandler("BJHunterSessionStatusRequest", M.pushSessionStatus)
    beamjoy_communications_ui.addHandler("BJHunterOpenSessionsRequest", M.pushOpenSessions)
    beamjoy_communications_ui.addHandler("BJHunterCountdownRequest", M.pushCountdown)
    beamjoy_communications_ui.addHandler("BJHunterHudRequest", M.pushHud)
end

--- cameras a participant shouldn't be able to reach while hunt-locked: unlike races, this isn't
--- host-configurable (matches BJI's own unconditional behavior for this mode)
---@return string[]
local function huntBlockedCameras()
    return { camera.CAMERAS.BIG_MAP, camera.CAMERAS.FREE, camera.CAMERAS.CINEMATIC, camera.CAMERAS.STEADYCAM }
end

---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    if not M.session then return end
    local participant = getSelfParticipant()
    if not participant then return end

    -- No walking during LOBBY (scouting/hiding) or an active HUNT. There's no gate-crossing-style
    -- progress tracking here, but walking away from a chase is just as much a way to sidestep it.
    -- Matches BJI's own canWalk == false for this mode.
    if M.session.state == "LOBBY" or M.session.state == "HUNT" then
        restrictions:addAll({ "toggleWalkingMode", "dropPlayerAtCamera", "dropPlayerAtCameraNoReset" }, true)
    end

    if not isHuntLocked() then return end

    -- Node grabber: same reasoning as races.lua's own disableNodegrabber option (can strand a
    -- player on a camera this file already blocks, or be used to disruptively manipulate a vehicle
    -- mid-chase). Not host-configurable here, always on.
    restrictions:addAll({
        "nodegrabberAction", "nodegrabberGrab", "nodegrabberRender",
        "nodegrabberStrength", "nodegrabberPadGrab", "nodegrabberPadMode",
    }, true)

    -- Always on, not host-configurable, matching races' own identical treatment. Slow-motion and
    -- pausing during an active hunt would be a real reaction-time/precision advantage. Also
    -- actively reasserted every frame in onUpdate below, since BeamNG's own Environment settings
    -- panel reaches simTimeAuthority directly, bypassing this action filter entirely.
    restrictions:addAll({ "toggle_slow_motion", "slower_motion", "faster_motion", "pause" }, true)

    -- Resetting/recovering during COUNTDOWN (frozen at the grid) is always blocked, same as races'
    -- own COUNTDOWN block. During HUNT, the fugitive's own reset is additionally gated by
    -- huntedResetDistanceThreshold (see updateStuckAndReveal below). Hunters can always reset
    -- freely during HUNT; crashing just costs them the huntersRespawnDelay penalty.
    if M.session.state == "COUNTDOWN" or
        (M.session.state == "HUNT" and participant.role == "hunted" and M.huntedResetLocked) then
        restrictions:addAll({
            "recover_vehicle", "recover_vehicle_alt", "recover_to_last_road",
            "reset_physics", "reset_all_physics", "reload_vehicle",
        }, true)
    end
end

--- FREE is one of huntBlockedCameras()'s own entries, blocked unconditionally for the whole
--- hunt-lock (COUNTDOWN through HUNT). Falling back to it while that block is still active would
--- get immediately kicked away again by camera.lua's own reactive re-enforcement, and for a
--- genuinely carless player there's no vehicle-camera ring to cycle into either. There is, in
--- fact, no camera that can be safely restored to with no vehicle present: every vehicle-relative
--- camera needs a vehicle to attach to, and every non-vehicle camera is blocked. So this leaves
--- M.previousCamera intact instead of discarding it, letting a genuinely later, successful call
--- (once a vehicle actually exists) still restore it properly.
local function restorePreviousCamera()
    camera.stopForcedCameras()
    if not M.previousCamera then return end
    if not beamjoy_vehicles.getCurrentOwn() then return end
    -- Every camera huntBlockedCameras() blocks needs converting to a real vehicle camera here, not
    -- just FREE/BIG_MAP. Restoring straight to a still-blocked camera (Cinematic/Steadycam, say)
    -- would get immediately kicked away again by camera.lua's own reactive re-block.
    local nonVehicleCameras = { camera.CAMERAS.FREE, camera.CAMERAS.BIG_MAP,
        camera.CAMERAS.CINEMATIC, camera.CAMERAS.STEADYCAM }
    local target = table.includes(nonVehicleCameras, M.previousCamera) and camera.CAMERAS.ORBIT or
        M.previousCamera
    camera.setCamera(target)
    M.previousCamera = nil
end

local function unlockScenario()
    if not M.scenarioLocked then return end
    M.scenarioLocked = false
    M.cameraReleased = false
    M.countdownStartMs = nil
    M.sentWaitingBroadcast = false
    M.lastWaitingChoosingOwn = nil
    restorePreviousCamera()
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh then beamjoy_vehicles.setFreeze(myVeh.vid, false) end
    extensions.hook("onBJScenarioChanged")
end

--- Always sends the countdown-overlay deactivation regardless of M.scenarioLocked, even though
--- unlockScenario() is a no-op when already unlocked. Defensive hardening so a cancel or
--- session-removal can never leave the big countdown number on screen.
local function releaseScenarioLock()
    unlockScenario()
    beamjoy_communications_ui.send("BJHunterCountdown", { active = false })
end

---@return boolean
local function clearHuntState()
    local hadSession = M.session ~= nil
    M.session = nil
    M.huntStartTimeMs = nil
    M.huntDeadlineTargetMs = nil
    M.gridReadyTargetMs = nil
    M.gridTimeoutTargetMs = nil
    M.lastProgressPos = nil
    M.lastProgressCheckMs = nil
    M.lastStuckWarningSecond = nil
    M.revealedLocally = false
    M.revealedUntilMs = nil
    M.hunterResetLockedUntilMs = nil
    M.hunterResetCount = 0
    M.huntedResetLocked = false
    M.selfVehicleConfirmed = false
    M.myVehicleVid = nil
    if M.lastGpsWaypointIndex ~= nil then
        M.lastGpsWaypointIndex = nil
        extensions.core_groundMarkers.setPath(nil)
    end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh then
        beamjoy_vehicles.setGhostReason(myVeh.vid, "hunter", false)
    end
    releaseScenarioLock()
    camera.stopForcedCameras()
    camera.unblockCameras()
    return hadSession
end

---@param session BJHunterSession
local function pushSessionStatus_impl(session)
    local participant = getSelfParticipant()
    if not session or not participant then
        return beamjoy_communications_ui.send("BJHunterSessionStatus", nil)
    end
    local starter = table.find(session.participants, function(p) return p.playerID == session.starterID end)
    local arena = session.arenaSnapshot or {}
    beamjoy_communications_ui.send("BJHunterSessionStatus", {
        id = session.id,
        state = session.state,
        participantCount = #session.participants,
        maxParticipants = 1 + #(arena.hunterSpawns or {}),
        participants = table.map(session.participants, function(p)
            return { playerName = p.playerName, playerID = p.playerID, ready = p.ready, role = p.role }
        end),
        role = participant.role,
        ready = participant.ready,
        isStarter = starter and starter.playerName == participant.playerName,
        eliminated = participant.role == "hunted" and participant.eliminated or nil,
        waypointsReached = participant.role == "hunted" and participant.waypointsReached or nil,
        totalWaypoints = participant.role == "hunted" and session.route and #session.route or nil,
        revealed = participant.role == "hunted" and participant.revealed or nil,
        winner = session.winner,
        -- Lobby/countdown/hunt participants can see what vehicles/settings apply to this round,
        -- not just on the start-options panel before joining. Plain passthrough of the already-
        -- resolved session.settings: nothing here is private, so no per-recipient filtering needed.
        settings = {
            winCondition = session.settings.winCondition,
            timedModeDuration = session.settings.timedModeDuration,
            waypointCount = session.settings.waypointCount,
            huntedVehicleLabel = session.settings.huntedVehicleLabel,
            huntersVehicleLabel = session.settings.huntersVehicleLabel,
            randomizeVehiclePool = session.settings.randomizeVehiclePool,
            hunterRespawnStrategy = session.settings.hunterRespawnStrategy,
            huntersRespawnDelay = session.settings.huntersRespawnDelay,
            respawnPenaltyIncrement = session.settings.respawnPenaltyIncrement,
            revealProximityDistance = session.settings.revealProximityDistance,
            huntedResetDistanceThreshold = session.settings.huntedResetDistanceThreshold,
        },
        gridReadySecondsLeft = M.gridReadyTargetMs and
            math.max(0, math.ceil((M.gridReadyTargetMs - GetCurrentTimeMillis()) / 1000)) or nil,
        gridTimeoutSecondsLeft = M.gridTimeoutTargetMs and
            math.max(0, math.ceil((M.gridTimeoutTargetMs - GetCurrentTimeMillis()) / 1000)) or nil,
    })
end

local function pushSessionStatus()
    if not M.session then
        return beamjoy_communications_ui.send("BJHunterSessionStatus", nil)
    end
    pushSessionStatus_impl(M.session)
end

local lastGridReadySec, lastGridTimeoutSec = nil, nil
local function updateGridCountdown()
    if not (M.gridReadyTargetMs or M.gridTimeoutTargetMs) then return end
    local readySec = M.gridReadyTargetMs and
        math.max(0, math.ceil((M.gridReadyTargetMs - GetCurrentTimeMillis()) / 1000)) or nil
    local timeoutSec = M.gridTimeoutTargetMs and
        math.max(0, math.ceil((M.gridTimeoutTargetMs - GetCurrentTimeMillis()) / 1000)) or nil
    if readySec ~= lastGridReadySec or timeoutSec ~= lastGridTimeoutSec then
        lastGridReadySec, lastGridTimeoutSec = readySec, timeoutSec
        pushSessionStatus()
    end
end

local function pushOpenSessions()
    beamjoy_communications_ui.send("BJHunterOpenSessions", M.openSessions or {})
end

---@param list table[]
local function onSessionsList(list)
    -- Pings the HUD for any session that just became newly joinable (not the starter, they
    -- already know), mirroring raceRunner.lua's own equivalent fix.
    local previousIds = table.map(M.openSessions or {}, function(s) return s.id end)
    local selfName = MPConfig.getNickname()
    table.forEach(list, function(s)
        if not table.includes(previousIds, s.id) and s.starterName ~= selfName then
            beamjoy_communications_ui.uiBroadcast("beamjoy.hunter.newJoinableSession",
                { starterName = s.starterName }, nil, 4)
        end
    end)

    M.openSessions = list
    pushOpenSessions()
end

local function pushHud()
    local session = M.session or M.spectatingSession
    if not session or session.state ~= "HUNT" then
        return beamjoy_communications_ui.send("BJHunterHud", { active = false })
    end
    local participant = M.session and getSelfParticipant() or nil
    local hunted = getHunted(session)
    local huntersLeft = 0
    for _, p in ipairs(session.participants) do
        if p.role == "hunter" then huntersLeft = huntersLeft + 1 end
    end
    -- Computed from a local anchor, not session.huntElapsedMs directly. That field is only as
    -- fresh as the last hunterSessionUpdate push, so re-sending it unchanged on every throttled
    -- tick just repeats the same stale number until an unrelated event refreshes it. Same
    -- anchor-locally-and-tick technique raceRunner.lua's pushHud uses: M.huntStartTimeMs
    -- (participant) is set once at the real HUNT transition; M.spectatingHuntStartTimeMs (pure
    -- spectator) is re-derived from the server's own snapshot on every spectate update, since a
    -- spectator can join mid-hunt with no start-of-hunt moment of their own to anchor from.
    local elapsedMs = session.huntElapsedMs or 0
    if M.session and M.huntStartTimeMs then
        elapsedMs = GetCurrentTimeMillis() - M.huntStartTimeMs
    elseif M.spectatingSession and M.spectatingHuntStartTimeMs then
        elapsedMs = GetCurrentTimeMillis() - M.spectatingHuntStartTimeMs
    end
    -- Same local-anchor-and-tick technique as elapsedMs above, for the timed-mode survival
    -- countdown. Only meaningful when the session is actually in timed mode.
    local timedSecondsLeft
    if session.settings and session.settings.winCondition == "timed" then
        local targetMs = M.session and M.huntDeadlineTargetMs or
            (M.spectatingSession and M.spectatingHuntDeadlineTargetMs)
        if targetMs then
            timedSecondsLeft = math.max(0, math.ceil((targetMs - GetCurrentTimeMillis()) / 1000))
        end
    end
    beamjoy_communications_ui.send("BJHunterHud", {
        active = true,
        huntElapsedMs = elapsedMs,
        huntersLeft = huntersLeft,
        -- Was sent unconditionally to everyone before, so hunters saw their own HUD claim "YOU ARE
        -- EXPOSED" whenever the fugitive got revealed, not just the fugitive. Scoped the same way
        -- huntedResetLocked below already correctly is.
        huntedRevealed = participant and participant.role == "hunted" and hunted and hunted.revealed or false,
        role = participant and participant.role or nil,
        waypointsReached = participant and participant.role == "hunted" and participant.waypointsReached or nil,
        totalWaypoints = participant and participant.role == "hunted" and session.route and #session.route or nil,
        hunterResetCount = participant and participant.role == "hunter" and M.hunterResetCount or nil,
        -- Replaces the old reset-lock toast. A persistent overlay indicator reads better than a
        -- transient popup for a state that can hold for a while, and doesn't get lost among other
        -- toasts.
        huntedResetLocked = participant and participant.role == "hunted" and M.huntedResetLocked or nil,
        winCondition = session.settings and session.settings.winCondition or nil,
        timedSecondsLeft = timedSecondsLeft,
        spectatingPlayerName = (not M.session and M.spectatingSession) and (hunted and hunted.playerName) or nil,
    })
end

---@param session BJHunterSession
local function onSpectateUpdate(session)
    M.spectatingSession = session
    if session.state == "HUNT" and session.huntElapsedMs ~= nil then
        M.spectatingHuntStartTimeMs = GetCurrentTimeMillis() - session.huntElapsedMs
    else
        M.spectatingHuntStartTimeMs = nil
    end
    if session.state == "HUNT" and session.huntTimedSecondsLeft ~= nil then
        M.spectatingHuntDeadlineTargetMs = GetCurrentTimeMillis() + session.huntTimedSecondsLeft * 1000
    else
        M.spectatingHuntDeadlineTargetMs = nil
    end
    pushHud()
end

---@param sessionId string
local function onSpectateRemoved(sessionId)
    if M.spectatingSession and M.spectatingSession.id == sessionId then
        M.spectatingSession = nil
        M.spectatingHuntStartTimeMs = nil
        M.spectatingHuntDeadlineTargetMs = nil
        pushHud()
    end
end

---@param sessionId string
local function spectateSession(sessionId)
    beamjoy_communications.send("hunterSpectate", sessionId)
end

local function stopSpectating()
    beamjoy_communications.send("hunterStopSpectate")
end

local function pushSpectateStatus()
    -- Placeholder parity with raceRunner.lua's own request-replay convention. Nothing additional
    -- to send beyond what onSpectateUpdate already pushes via pushHud.
    pushHud()
end

---@param session BJHunterSession
local function onSessionUpdate(session)
    local wasInSession = M.session ~= nil
    local wasCountdown = M.session ~= nil and M.session.state == "COUNTDOWN"
    local wasHunt = M.session ~= nil and M.session.state == "HUNT"
    local wasFinished = M.session ~= nil and M.session.state == "FINISHED"
    M.session = session

    if session.state == "LOBBY" and session.joinable and session.gridReadySecondsLeft ~= nil then
        M.gridReadyTargetMs = GetCurrentTimeMillis() + session.gridReadySecondsLeft * 1000
        M.gridTimeoutTargetMs = GetCurrentTimeMillis() + (session.gridTimeoutSecondsLeft or 0) * 1000
    else
        M.gridReadyTargetMs = nil
        M.gridTimeoutTargetMs = nil
    end

    -- Same self-correcting re-anchor as gridReadyTargetMs/gridTimeoutTargetMs above, recomputed on
    -- every push so a late-joining spectator or a brief desync can't leave this stale.
    if session.state == "HUNT" and session.huntTimedSecondsLeft ~= nil then
        M.huntDeadlineTargetMs = GetCurrentTimeMillis() + session.huntTimedSecondsLeft * 1000
    else
        M.huntDeadlineTargetMs = nil
    end

    local participant = getSelfParticipant()
    if not participant then
        clearHuntState()
        extensions.hook("onBJScenarioChanged")
        pushHud()
        pushSessionStatus()
        return extensions.hook("onBJHunterMarkersRefresh")
    end
    pushSessionStatus()

    -- Steers the player toward a matching vehicle the moment they join the lobby, same convention
    -- races' own GRID-entry steering uses.
    if session.state == "LOBBY" and not wasInSession then
        local pool, label = activeVehiclePool()
        if pool then
            local myVeh = beamjoy_vehicles.getCurrentOwn()
            local matches = myVeh ~= nil and vehicleMatchesPool(myVeh.veh, pool)
            if not matches then
                local anyAvailable = table.find(pool, function(v) return modelAvailableLocally(v.model) end) ~= nil
                if anyAvailable then
                    if myVeh then beamjoy_vehicles.deleteCurrentOwnVehicle() end
                    toast.warn(label and string.format("This hunt restricts vehicles to: %s. Pick one", label) or
                        "This hunt restricts which vehicles can play. Pick one from the vehicle selector", nil, 6)
                    extensions.ui_vehicleSelector_general.openVehicleSelectorForFreeroam()
                else
                    toast.warn("This hunt's allowed vehicles aren't installed on your game. You won't be able to play",
                        nil, 8)
                end
            end
        end
    end

    if session.state == "COUNTDOWN" and not wasCountdown then
        beamjoy_communications_ui.closeWindow("config")
        if beamjoy_ui_activityEditor then
            beamjoy_ui_activityEditor.onClose()
        end

        -- Reset before the vehicle-confirm block below, which may itself call confirmOwnVehicle
        -- (setting this back to true) within this same COUNTDOWN transition. Resetting it after
        -- that block would immediately undo a same-frame confirmation.
        M.selfVehicleConfirmed = false

        -- Role (and which vehicle-pool restriction applies, if any) is only knowable from this
        -- moment on, since the fugitive is drawn randomly at hunt start rather than fixed at join
        -- time. A vehicle picked freely during LOBBY can turn out not to match, or the player may
        -- not have readied up with a vehicle at all. This gets the same steer-and-reselect
        -- treatment the LOBBY-join steering above uses (delete + reopen the selector), not just a
        -- warning: the countdown now waits on every participant's own hunterVehicleConfirmed
        -- before its real hunt-start timer begins, so there's no rush. The field stays frozen for
        -- as long as it takes (up to vehicleConfirmTimeout). Whatever the player ends up in gets
        -- teleported/frozen/ghosted (and confirmed) by onBJVehicleInstantiated below, since the
        -- one-time spawn treatment further down only touches the vehicle that existed at the
        -- moment COUNTDOWN began. onBJRequestCanSpawnVehicle still rejects a non-matching pick
        -- outright, so anything that spawns here is already known-matching, safe to confirm
        -- unconditionally.
        do
            local pool, label = activeVehiclePool()
            local myVeh = beamjoy_vehicles.getCurrentOwn()
            local hasVehicle = myVeh ~= nil and myVeh.veh.jbeam ~= beamjoy_vehicles.WALKING
            local matches = hasVehicle and (not pool or vehicleMatchesPool(myVeh.veh, pool))
            if pool and M.session.settings.randomizeVehiclePool then
                -- Used to only kick in as a fallback for a mismatched vehicle, so a player already
                -- sitting in a vehicle that happened to be in the pool never got randomized at
                -- all. The whole point of this option is to always randomize, not just fix a
                -- mismatch, so this now runs unconditionally whenever it's on, regardless of
                -- `matches`.
                local anyAvailable = table.find(pool, function(v) return modelAvailableLocally(v.model) end) ~= nil
                if anyAvailable then
                    if forceRandomPoolVehicle(pool) then
                        toast.warn(label and
                            string.format("Your role for this hunt requires: %s. You've been given a random one", label) or
                            "You've been given a random vehicle for this hunt", nil, 6)
                        confirmOwnVehicle(session.id)
                    else
                        toast.warn(
                            "Your role's allowed vehicles aren't installed on your game. You won't be able to play",
                            nil, 8)
                    end
                else
                    toast.warn(
                        "Your role's allowed vehicles aren't installed on your game. You won't be able to play",
                        nil, 8)
                end
            elseif matches then
                confirmOwnVehicle(session.id)
            else
                local anyAvailable = not pool or
                    table.find(pool, function(v) return modelAvailableLocally(v.model) end) ~= nil
                if anyAvailable then
                    if hasVehicle then beamjoy_vehicles.deleteCurrentOwnVehicle() end
                    toast.warn(label and
                        string.format(
                            "Your role for this hunt requires: %s. Pick one now, the countdown won't start until everyone has",
                            label) or
                        "You need a vehicle for this hunt. Pick one now, the countdown won't start until everyone has",
                        nil, 8)
                    extensions.ui_vehicleSelector_general.openVehicleSelectorForFreeroam()
                else
                    toast.warn(
                        "Your role's allowed vehicles aren't installed on your game. You won't be able to play",
                        nil, 8)
                end
            end
        end

        -- Everything below (teleport, ghost, freeze, forcing the vehicle-relative EXTERNAL camera)
        -- is deliberately conditional on actually having a vehicle right now, since forcing a
        -- vehicle-relative camera mode with no vehicle causes a nasty class of bugs (see
        -- onBJVehicleInstantiated's own comment). A carless player picks all of this up later, once
        -- onBJVehicleInstantiated fires for whatever they spawn from the steering block above.
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh then
            -- Tracked so a later mid-HUNT destroy/replace of this specific vehicle can be told
            -- apart from any other vehicle being destroyed. See onVehicleDestroyed.
            M.myVehicleVid = myVeh.vid
            if participant.spawnPos then
                -- cling defaults to true (re-snaps to the nearest surface below), which is wrong
                -- here: this position was already deliberately placed by the arena editor.
                -- Re-clinging at spawn time can land the vehicle on top of whatever's directly
                -- above a legitimately-covered spawn point (a gas station awning, a tunnel
                -- ceiling), since the search ray starts 10 units above and stops at the first
                -- surface it hits.
                beamjoy_vehicles.setVehiclePositionRotation(myVeh.veh,
                    vec3(participant.spawnPos.x, participant.spawnPos.y, participant.spawnPos.z),
                    vec3(participant.spawnDir.x, participant.spawnDir.y, participant.spawnDir.z),
                    vec3(0, 0, 1), { cling = false })
            else
                LogWarn("beamjoy_hunterRunner: no spawn position to teleport to")
            end
            beamjoy_vehicles.setGhostReason(myVeh.vid, "hunter", true)
        end

        M.scenarioLocked = true
        M.cameraReleased = false
        -- deliberately NOT started yet: see session.countdownTicking below, this only begins
        -- ticking once every participant has confirmed a matching vehicle
        M.countdownStartMs = nil
        M.countdownTotal = session.settings.countdown
        M.lastSentSeconds = nil
        M.sentWaitingBroadcast = false
        M.lastWaitingChoosingOwn = nil
        M.previousCamera = camera.getCamera()
        if myVeh then
            -- Both conditional on myVeh, for the same reason: huntBlockedCameras() blocks FREE, but
            -- a carless player's active camera necessarily IS free (no vehicle-relative ring to be
            -- on yet), so blocking it anyway makes camera.lua's own reactive re-enforcement fight a
            -- losing battle every frame trying to cycle off free cam into a ring that doesn't
            -- exist. Applied instead, once, from onBJVehicleInstantiated once there's a real
            -- vehicle ring for either of these to mean anything against.
            camera.setCamera(camera.CAMERAS.EXTERNAL)
            camera.blockCameras(table.unpack(huntBlockedCameras()))
            beamjoy_vehicles.setFreeze(myVeh.vid, true)
        end
        extensions.hook("onBJScenarioChanged")
    end

    -- The real hunt-start timer can flip on any session push while still in COUNTDOWN, not just
    -- the first one above, since it only starts once every participant's vehicleConfirmed lands.
    -- Checked unconditionally so the local ticking clock picks it up the moment it happens.
    if session.state == "COUNTDOWN" and session.countdownTicking and not M.countdownStartMs then
        M.countdownStartMs = GetCurrentTimeMillis()
        M.countdownTotal = session.settings.countdown
        M.lastSentSeconds = nil
    end

    if session.state == "HUNT" and not wasHunt then
        -- This block used to run on every session push while state == "HUNT" (a checkpoint,
        -- reveal update, elimination attempt, force-fugitive, anything mid-hunt), not just the one
        -- real LOBBY/COUNTDOWN -> HUNT transition. That re-froze the local player's own vehicle
        -- for huntersStartDelay/huntedStartDelay seconds on every unrelated update, reported as
        -- "forcing on my brakes randomly". Gating on `not wasHunt`, mirroring the COUNTDOWN block
        -- above, makes this one-time setup actually run once.
        if M.scenarioLocked then
            unlockScenario()
            beamjoy_communications_ui.send("BJHunterCountdown", { active = false })
        end
        -- Asymmetric release: both roles are frozen at the exact HUNT-start instant server-side
        -- (huntStartTimeMs, below), unfreezing locally after their own role's start delay: the
        -- fugitive's built-in head start (see BJHunterDefaults.huntedStartDelay/huntersStartDelay).
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        local delaySec = participant.role == "hunted" and session.settings.huntedStartDelay or
            session.settings.huntersStartDelay
        if myVeh then
            beamjoy_vehicles.setFreeze(myVeh.vid, true)
        end
        -- This release used to be nested inside the `if myVeh then` check above, so if
        -- getCurrentOwn() returned nil at this exact instant (a real possibility if the vehicle
        -- was still mid-registration), no release ever got scheduled: onBJVehicleInstantiated had
        -- already frozen it, but nothing unfroze it, leaving the car stuck for the rest of the
        -- hunt. Scheduling this unconditionally means a vehicle that only exists a moment later
        -- still gets released on time, since the delayed callback re-fetches getCurrentOwn() fresh.
        async.delayTask(function()
            local currVeh = beamjoy_vehicles.getCurrentOwn()
            if currVeh then beamjoy_vehicles.setFreeze(currVeh.vid, false) end
            local vid = currVeh and currVeh.vid or (myVeh and myVeh.vid)
            if not vid then return end
            -- checkGhostedBystanders=false + a bounded force-fallback, mirroring raceRunner.lua's
            -- own fix for the "everyone releases together, stale ghost flags" race condition.
            -- Everyone on the same role shares the same start delay and can release within the
            -- same frame, so each client's locally-known ghost flag for the others can be a few ms
            -- stale. Checking real distance regardless of a bystander's reported ghost state
            -- closes that window, and the 2s force-fallback guarantees nobody's stuck ghosted
            -- forever in a genuinely tight spawn cluster.
            beamjoy_vehicles.setGhostReason(vid, "hunter", false, false, false)
            local forceTaskName = "ghostHunterStartForce-" .. vid
            async.removeTask(forceTaskName)
            async.delayTask(function()
                beamjoy_vehicles.setGhostReason(vid, "hunter", false, true)
            end, 2000, forceTaskName)
        end, math.max(0, delaySec) * 1000, "BJHunterReleaseFreeze")
        M.huntStartTimeMs = GetCurrentTimeMillis()
        M.lastProgressPos = nil
        M.lastProgressCheckMs = nil
        M.lastStuckWarningSecond = nil
        M.revealedLocally = false
        M.revealedUntilMs = nil
        M.huntedResetLocked = false
        M.hunterResetCount = 0
        -- An explicit "the hunt has started" notification, distinct from the countdown's own brief
        -- "GO!" flash (which the next line hides anyway, since the overlay tears down the instant
        -- HUNT begins).
        beamjoy_communications_ui.uiBroadcast("beamjoy.hunter.huntStarted", nil, "green", 3)
    end
    -- This re-assertion needs to run on every HUNT push regardless of whether a vehicle exists,
    -- unlike its sibling at the COUNTDOWN transition (gated on `if myVeh then`). FREE is one of
    -- huntBlockedCameras()'s own entries; a still-carless participant's only possible camera IS
    -- free, so blocking it anyway made camera.lua's own reactive re-enforcement fight a losing
    -- battle every push for the rest of the hunt.
    if session.state == "HUNT" and beamjoy_vehicles.getCurrentOwn() then
        -- Re-asserted on every push, not just the one-time setup above. Belt-and-suspenders,
        -- matching races' own equivalent RACE-transition re-block. Harmless to repeat: only acts
        -- if the local camera is currently on one of the blocked cameras.
        camera.blockCameras(table.unpack(huntBlockedCameras()))
    end

    if session.state == "FINISHED" then
        unlockScenario()
        camera.unblockCameras()
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh then beamjoy_vehicles.setGhostReason(myVeh.vid, "hunter", false) end
        if not wasFinished then
            -- Neither role had a "the hunt is over" screen before this. Reuses the countdown
            -- overlay as a generic "big transient message" primitive, matching races' own
            -- Finished/DNF popup precedent rather than building a second component.
            beamjoy_communications_ui.send("BJHunterCountdown",
                { active = true, finished = true, winner = session.winner })
            async.delayTask(function()
                beamjoy_communications_ui.send("BJHunterCountdown", { active = false })
            end, 8000, "BJHunterFinishedPopupHide")
        end
    end

    pushHud()
    extensions.hook("onBJHunterMarkersRefresh")
end

---@param sessionId string
local function onSessionRemoved(sessionId)
    if not M.session or M.session.id ~= sessionId then return end
    clearHuntState()
    extensions.hook("onBJScenarioChanged")
    pushHud()
    pushSessionStatus()
    extensions.hook("onBJHunterMarkersRefresh")
end

local function updateCountdown()
    if not M.scenarioLocked or not M.countdownTotal then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh and myVeh.veh.froze ~= "1" then
        beamjoy_vehicles.setFreeze(myVeh.vid, true)
    end

    -- Still waiting on vehicle confirmations: the real timer hasn't started yet (see the
    -- countdownTicking-flip check in onSessionUpdate). Distinguishes "I haven't picked my own
    -- vehicle yet" (choosingOwn) from "I have, now waiting on everyone else" (waiting), so a
    -- player who hasn't confirmed yet doesn't see the same generic "waiting for players" text as
    -- someone who already has. Re-sent whenever this player's own confirmed state changes, since
    -- they can flip from choosingOwn to waiting mid-phase, well before the timer starts.
    if not M.countdownStartMs then
        local choosingOwn = not M.selfVehicleConfirmed
        if not M.sentWaitingBroadcast or M.lastWaitingChoosingOwn ~= choosingOwn then
            M.sentWaitingBroadcast = true
            M.lastWaitingChoosingOwn = choosingOwn
            beamjoy_communications_ui.send("BJHunterCountdown",
                { active = true, waiting = not choosingOwn, choosingOwn = choosingOwn })
        end
        return
    end

    local elapsedSec = (GetCurrentTimeMillis() - M.countdownStartMs) / 1000
    local remaining = math.max(0, math.ceil(M.countdownTotal - elapsedSec))
    if remaining ~= M.lastSentSeconds then
        M.lastSentSeconds = remaining
        beamjoy_communications_ui.send("BJHunterCountdown", { active = true, seconds = remaining })
    end
    if not M.cameraReleased and remaining <= CAMERA_RELEASE_SECONDS then
        M.cameraReleased = true
        -- This used to also discard M.previousCamera whenever the camera wasn't reported as
        -- EXTERNAL at this exact instant, which reintroduced "the external camera doesn't reset"
        -- as a COUNTDOWN-specific regression. This early check is purely an optimization (hand the
        -- camera back a few seconds sooner than the real unlock would), never the only chance to
        -- restore it: the real, unconditional restore always still happens moments later at the
        -- HUNT-transition (unlockScenario) or on cancel. So this now only acts opportunistically
        -- when the camera is currently external, and otherwise leaves M.previousCamera intact for
        -- that later, definitive call.
        if camera.getCamera() == camera.CAMERAS.EXTERNAL then
            restorePreviousCamera()
        end
        extensions.hook("onBJScenarioChanged")
    end
end

local function pushCountdown()
    if not M.session or M.session.state ~= "COUNTDOWN" then return end
    if M.countdownStartMs and M.lastSentSeconds ~= nil then
        beamjoy_communications_ui.send("BJHunterCountdown", { active = true, seconds = M.lastSentSeconds })
    elseif M.sentWaitingBroadcast then
        beamjoy_communications_ui.send("BJHunterCountdown",
            { active = true, waiting = not M.lastWaitingChoosingOwn, choosingOwn = M.lastWaitingChoosingOwn })
    end
end

--- Minimap visibility (native `veh.uiState`, the same primitive `pursuit.lua`'s own AI-fugitive
--- reveal uses) for the current fugitive's vehicle, on every other client. Never touched on the
--- fugitive's own client, who always sees themselves normally.
local function updateRevealVisuals()
    local session = M.session or M.spectatingSession
    if not session or session.state ~= "HUNT" then return end
    local hunted = getHunted(session)
    if not hunted then return end
    local mpVeh = beamjoy_vehicles.vehicles:find(function(v) return v.ownerName == hunted.playerName end)
    if not mpVeh or mpVeh.isLocal then return end
    mpVeh.veh.uiState = hunted.revealed and 1 or 0
end

--- Fugitive-only: self-computes the three BJI-ported reveal triggers (proximity, near-final-
--- waypoint, post-reset) every slow tick and self-reports the combined boolean to the server. This
--- stays client-computed since every client already has real, low-latency vehicle position data
--- via BeamMP's own native replication, the same primitive nametags.lua's distance-based fade and
--- pursuit.lua's proximity capture already rely on. Also drives the fugitive's own reset lock
--- (huntedResetDistanceThreshold). GPS guidance to the fugitive's current target waypoint routes
--- through BeamNG's native GPS (core_groundMarkers), re-issued only when the target changes: setPath
--- sets up its own persistent state and keeps rendering every frame on its own, nothing here needs
--- to re-call it just to keep it visible. Never runs for anyone but the fugitive: session.route is
--- already stripped server-side for every other participant/spectator, so there's nothing here to
--- guide toward on any other client.
local function updateGpsGuidance()
    local participant = M.session and getSelfParticipant() or nil
    local active = M.session and M.session.state == "HUNT" and participant and
        participant.role == "hunted" and not participant.eliminated and M.session.route
    local nextIndex, waypoint
    if active then
        nextIndex = participant.waypointsReached + 1
        waypoint = M.session.route[nextIndex]
    end
    if waypoint then
        if M.lastGpsWaypointIndex ~= nextIndex then
            M.lastGpsWaypointIndex = nextIndex
            extensions.core_groundMarkers.setPath(vec3(waypoint.pos.x, waypoint.pos.y, waypoint.pos.z))
        end
    elseif M.lastGpsWaypointIndex ~= nil then
        M.lastGpsWaypointIndex = nil
        extensions.core_groundMarkers.setPath(nil)
    end
end

local function updateFugitiveState()
    if not M.session or M.session.state ~= "HUNT" then return end
    local participant = getSelfParticipant()
    if not participant or participant.role ~= "hunted" or participant.eliminated then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return end
    local settings = M.session.settings
    local myPos = beamjoy_vehicles.getVehiclePositionRotation(myVeh.veh)

    -- Proximity: closest currently-tracked hunter vehicle. v.position is a cached field, only
    -- refreshed by beamjoy_vehicles.getVehicle(vid) being called without light=true, and the only
    -- place that happens for another player's vehicle is nametags.lua's "draw all" loop (skipped
    -- once nametags are disabled). With nametags off, v.position for a hunter's vehicle never
    -- updates past registration, so this proximity check was comparing against a frozen, stale
    -- position instead of the hunter's real one, letting the prey reset with a hunter right next
    -- to them. Computing position fresh here removes that accidental coupling.
    local nearestHunterDist = math.huge
    beamjoy_vehicles.vehicles:forEach(function(v) ---@param v BJVehicle
        local isHunter = table.find(M.session.participants, function(p)
            return p.role == "hunter" and p.playerName == v.ownerName
        end) ~= nil
        if not isHunter or not v.veh then return end
        local pos = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
        local d = myPos:distance(pos)
        if d < nearestHunterDist then nearestHunterDist = d end
    end)

    local proximityReveal = nearestHunterDist <= settings.revealProximityDistance
    local finalWaypointReveal = settings.revealOnFinalWaypoint and M.session.route and
        participant.waypointsReached >= (#M.session.route - 1)
    local resetReveal = M.revealedUntilMs ~= nil and GetCurrentTimeMillis() < M.revealedUntilMs

    local revealed = proximityReveal or finalWaypointReveal or resetReveal
    if revealed ~= M.revealedLocally then
        M.revealedLocally = revealed
        beamjoy_communications.send("hunterRevealUpdate", M.session.id, revealed)
    end

    -- reset lock : cannot reset/recover at all while any hunter is within huntedResetDistanceThreshold
    -- (0 == never allowed to reset)
    local wasResetLocked = M.huntedResetLocked
    M.huntedResetLocked = nearestHunterDist <= settings.huntedResetDistanceThreshold
    if M.huntedResetLocked ~= wasResetLocked then
        -- onBJRequestRestrictions is not re-evaluated every frame: restrictions.lua's own update()
        -- only recomputes off onVehicleInstantiated/onVehicleSwitched/onBJScenarioChanged/
        -- onBJUpdateSelf, never on a plain timer. A restriction that depends on a value recomputed
        -- every slow tick (like this one) has to explicitly ask for a fresh recompute when that
        -- value changes, or the cached restriction snapshot from whenever one of those four events
        -- last fired (HUNT start, quite possibly with no hunter nearby yet) never updates again
        -- for the rest of the hunt, meaning the reset block could stay permanently off regardless
        -- of how close a hunter later got.
        extensions.hook("onBJScenarioChanged")

        -- Replaces the earlier per-engage/release toast with a persistent HUD indicator (see
        -- pushHud's own huntedResetLocked field): a toast is easy to miss or gets buried, and this
        -- state can hold for a while, which an always-visible overlay communicates better. Pushed
        -- immediately rather than waiting for onUpdate's own ~200ms HUD throttle, so the indicator
        -- appears/disappears the instant the lock engages/releases.
        pushHud()
    end

    -- stuck timer
    if not M.lastProgressPos or myPos:distance(M.lastProgressPos) > settings.huntedStuckDistance then
        M.lastProgressPos = myPos
        M.lastProgressCheckMs = GetCurrentTimeMillis()
        M.lastStuckWarningSecond = nil
    else
        local timeoutMs = settings.huntedStuckTimeout * 1000
        local stalledMs = GetCurrentTimeMillis() - (M.lastProgressCheckMs or GetCurrentTimeMillis())
        if stalledMs > timeoutMs then
            beamjoy_communications.send("hunterEliminated", M.session.id)
        elseif timeoutMs - stalledMs <= STUCK_WARNING_SECONDS * 1000 then
            local secondsLeft = math.ceil((timeoutMs - stalledMs) / 1000)
            if secondsLeft ~= M.lastStuckWarningSecond then
                M.lastStuckWarningSecond = secondsLeft
                beamjoy_communications_ui.uiBroadcast("beamjoy.hunter.stuckWarning",
                    { seconds = tostring(secondsLeft) }, "orange", 1.5)
            end
        end
    end

    -- checkpoint reporting : the next expected waypoint in the server-picked, private route
    if M.session.route then
        local nextIndex = participant.waypointsReached + 1
        local waypoint = M.session.route[nextIndex]
        if waypoint then
            local wPos = vec3(waypoint.pos.x, waypoint.pos.y, waypoint.pos.z)
            if myPos:distance(wPos) <= waypoint.radius then
                beamjoy_communications.send("hunterCheckpointReached", M.session.id, nextIndex,
                    { x = myPos.x, y = myPos.y, z = myPos.z })
            end
        end
    end
end

--- A vehicle picked from the mismatch-steering selector above spawns fresh, after the COUNTDOWN
--- transition's own one-time teleport/freeze/ghost already ran against whatever vehicle existed at
--- that moment. Re-applies the same treatment to this new one, so a mid-countdown pick still
--- starts frozen at the correct grid slot instead of wherever the selector spawns it. Also applies
--- the vehicle-relative EXTERNAL camera lock and the free/big-map/cinematic/steadycam block if
--- either couldn't be applied yet at the COUNTDOWN transition (no vehicle existed then). Never
--- forced/blocked without a real vehicle present.
---
--- Root cause of "spawns sometimes don't seem to work": this used to be wired to the native, raw
--- `onVehicleSpawned` hook, which fires the instant a vehicle object is created, before
--- `vehicles.lua`'s own `registerVehicle` (an async job) has finished populating `M.vehicles[vid]`.
--- `getCurrentOwn()` reads from that same table, so it could easily still return nil at that exact
--- moment, silently skipping the whole teleport intermittently. `vehicles.lua` (and five other
--- modules in this codebase) all solve this the same way: listen for the custom
--- `onBJVehicleInstantiated` hook instead, fired only once that async registration has genuinely
--- completed. Switched to that, reading the vehicle directly by id (`getVehicle(vid, true)`)
--- rather than via `getCurrentOwn()`'s indirection, a more direct and robust check for "is this
--- vehicle actually mine". Also reports hunterVehicleConfirmed: onBJRequestCanSpawnVehicle already
--- rejects any non-matching model before a vehicle can be created, so anything that reaches this
--- hook is already a valid pick, safe to confirm unconditionally.
---@param vid integer
local function onBJVehicleInstantiated(vid)
    if not M.session then return end
    if M.session.state ~= "COUNTDOWN" and M.session.state ~= "HUNT" then return end
    local participant = getSelfParticipant()
    if not participant then return end
    local mpVeh = beamjoy_vehicles.getVehicle(vid, true)
    if not mpVeh or not mpVeh.isLocal then return end

    if M.session.state == "HUNT" then
        -- This hook used to be COUNTDOWN-only, so a vehicle swapped mid-HUNT (via the native
        -- selector's "replace", or a fresh spawn after the old one was destroyed) got none of the
        -- usual treatment: no teleport, no ghost, no freeze, no camera lock, it just appeared
        -- wherever the engine put it, fully solid.
        if participant.role == "hunted" then
            -- The fugitive is never meant to change vehicles mid-hunt: by the time HUNT begins
            -- they've already confirmed a real, matching vehicle during COUNTDOWN, so any new
            -- vehicle instantiation here can only mean their assigned vehicle was destroyed or
            -- replaced. Treated as an outright forfeit, reusing the same hunterEliminated RX path
            -- the stuck-timer already uses server-side.
            if not participant.eliminated then
                beamjoy_communications.send("hunterEliminated", M.session.id)
            end
            return
        end
        if participant.role ~= "hunter" then return end
        -- A hunter voluntarily swapping vehicles mid-chase (not a crash/reset, those keep the same
        -- vid and go through onVehicleResetted instead): no teleport (no "grid slot" to return to
        -- mid-hunt) and no freeze (nothing to countdown against), just the same brief ghost safety
        -- net every other spawn/reset in this mode gets, so materializing doesn't land them
        -- directly on top of another vehicle. Same distance-safe release + bounded fallback as the
        -- HUNT-start/crash-penalty releases, since a plain fixed timer can't know if it's safe yet.
        M.myVehicleVid = vid
        beamjoy_vehicles.setGhostReason(vid, "hunter", true)
        beamjoy_vehicles.setGhostReason(vid, "respawn", false)
        beamjoy_vehicles.setGhostReason(vid, "hunter", false, false, false)
        local forceTaskName = "ghostHunterSwapForce-" .. vid
        async.removeTask(forceTaskName)
        async.delayTask(function()
            beamjoy_vehicles.setGhostReason(vid, "hunter", false, true)
        end, 2000, forceTaskName)
        return
    end

    M.myVehicleVid = vid
    if participant.spawnPos then
        -- Same cling=false reasoning as the sibling call above (the COUNTDOWN-transition
        -- teleport): this position is already correctly placed, and re-clinging to the nearest
        -- surface below can land the vehicle on top of a covering structure instead.
        beamjoy_vehicles.setVehiclePositionRotation(mpVeh.veh,
            vec3(participant.spawnPos.x, participant.spawnPos.y, participant.spawnPos.z),
            vec3(participant.spawnDir.x, participant.spawnDir.y, participant.spawnDir.z),
            vec3(0, 0, 1), { cling = false })
    end
    beamjoy_vehicles.setFreeze(vid, true)
    beamjoy_vehicles.setGhostReason(vid, "hunter", true)
    -- Hunter participants get an immediate, unconditional 0s respawn-ghost window on every spawn
    -- regardless of the server's own generic Freeroam.RespawnGhostTimeout. vehicles.lua's own
    -- onVehicleSpawned already applied that generic protection by the time this fires, so this
    -- just cancels it for Hunter without touching the server-wide setting for anyone else. The
    -- whole point of this mode is collision-based chasing, and a few free seconds of ghosting
    -- right after a spawn would let either side drive straight through the other at exactly the
    -- moment it matters most.
    beamjoy_vehicles.setGhostReason(vid, "respawn", false)
    if M.scenarioLocked then
        camera.setCamera(camera.CAMERAS.EXTERNAL)
        camera.blockCameras(table.unpack(huntBlockedCameras()))
    end
    confirmOwnVehicle(M.session.id)
end

--- Closes the other half of the same gap as onBJVehicleInstantiated above: the fugitive's own
--- vehicle being destroyed mid-hunt (deleted with no replacement, at least not yet) is just as
--- much a forfeit as swapping to a different one. Without this, deleting their car would silently
--- freeze their own stuck-timer/reveal computation forever, making them unreachable AND
--- un-eliminable.
---@param vid integer
local function onVehicleDestroyed(vid)
    if vid ~= M.myVehicleVid then return end
    M.myVehicleVid = nil
    if not M.session or M.session.state ~= "HUNT" then return end
    local participant = getSelfParticipant()
    if not participant or participant.role ~= "hunted" or participant.eliminated then return end
    beamjoy_communications.send("hunterEliminated", M.session.id)
end

--- Hunter crash/reset: freeze + camera-lock penalty, matching BJI's own huntersRespawnDelay
--- convention. Fugitive crash/reset: opens the post-reset reveal window (revealResetDuration), the
--- third of the three BJI-ported reveal triggers. This function used to return immediately for any
--- non-"hunter" role, so the fugitive's own crash never actually revealed them despite the setting
--- being fully wired through everywhere else.
---@param vid integer
local function onVehicleResetted(vid)
    if not M.session or M.session.state ~= "HUNT" then return end
    local participant = getSelfParticipant()
    if not participant then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh or myVeh.vid ~= vid then return end

    -- Same 0s respawn-ghost override as onBJVehicleInstantiated's identical treatment, since a
    -- mid-hunt crash/reset is the other moment vehicles.lua's generic Freeroam respawn-ghost
    -- protection gets re-applied. vehicles.lua's own onVehicleResetted (which applies the generic
    -- protection) runs first, ahead of this one, per main.lua's dependency load order.
    beamjoy_vehicles.setGhostReason(vid, "respawn", false)

    if participant.role == "hunted" then
        if participant.eliminated then return end
        local durationSec = M.session.settings.revealResetDuration
        if durationSec and durationSec > 0 then
            M.revealedUntilMs = GetCurrentTimeMillis() + durationSec * 1000
        end
        return
    end
    if participant.role ~= "hunter" then return end

    -- A reset event arriving while already serving a penalty lock must be ignored outright, not
    -- treated as a fresh crash. Hunters are never blocked from resetting during HUNT, so a repeated
    -- recover-key press while already frozen (or the crash's own physics settling re-firing this
    -- hook) would otherwise increment hunterResetCount and recompute a larger delaySec each time,
    -- visibly growing the displayed timer instead of counting down.
    if M.hunterResetLockedUntilMs then return end

    -- Counts every reset regardless of whether a real penalty delay is configured, shown on the
    -- hunter's own HUD.
    M.hunterResetCount = (M.hunterResetCount or 0) + 1

    local settings = M.session.settings

    -- Respawn strategy: teleport before computing/applying the freeze, so the penalty (if any) is
    -- served wherever the hunter is sent back to, not wherever they crashed, and independent of
    -- whether a real time penalty even applies below.
    local strategy = settings.hunterRespawnStrategy or "free"
    if strategy ~= "free" then
        local list = strategy == "hubs" and M.session.arenaSnapshot.respawnHubs or nil
        if not list or #list == 0 then
            list = M.session.arenaSnapshot.hunterSpawns
        end
        if list and #list > 0 then
            local pos = beamjoy_vehicles.getVehiclePositionRotation(myVeh.veh)
            -- "nearestSpawn" prefers a spawn that's also clear of the fugitive's own reset-lock
            -- distance, so respawning here doesn't just extend the fugitive's lock the instant
            -- this hunter reappears nearby. "hubs" (and its fallback to hunterSpawns when none are
            -- placed) keeps the plain-nearest pick, since a hub is presumably already a
            -- deliberately-placed, away-from-the-action spot.
            local target = strategy == "nearestSpawn" and nearestHunterSpawnClearOfFugitive(list, pos) or
                nearestSpawnPoint(list, pos)
            if target then
                beamjoy_vehicles.setVehiclePositionRotation(myVeh.veh,
                    vec3(target.pos.x, target.pos.y, target.pos.z),
                    vec3(target.dir.x, target.dir.y, target.dir.z),
                    vec3(0, 0, 1))
            end
        end
    end

    -- Escalating penalty: +respawnPenaltyIncrement seconds per prior reset this hunt
    -- (hunterResetCount is already incremented above, so the first reset counts as 1).
    -- respawnPenaltyIncrement defaults to 0, so this is a flat delay unless a host turns it on.
    local delaySec = (settings.huntersRespawnDelay or 0) + (settings.respawnPenaltyIncrement or 0) * M.hunterResetCount
    if not delaySec or delaySec <= 0 then return end

    M.hunterResetLockedUntilMs = GetCurrentTimeMillis() + delaySec * 1000
    beamjoy_vehicles.setFreeze(vid, true)
    -- This lock never ghosted the vehicle at all before. A hunter frozen in place for the whole
    -- penalty duration was fully solid the entire time, reachable by the fugitive or another
    -- hunter exactly when they're least able to react. Same "hunter" reason and distance-safe
    -- mechanism the countdown-phase spawn ghost already uses.
    beamjoy_vehicles.setGhostReason(vid, "hunter", true)
    -- This camera lock never captured what the player was on before switching to EXTERNAL, so the
    -- camera never got restored once the penalty ended, leaving the player stuck on EXTERNAL
    -- indefinitely. Reuses the same M.previousCamera/restorePreviousCamera() mechanism the
    -- COUNTDOWN lock established, safe to share since the two locks are temporally mutually
    -- exclusive (COUNTDOWN vs HUNT). One-time set, not a reactive per-frame reassertion: races' own
    -- countdown lock tried the latter first and found it flicker-prone, then walked back to "just
    -- switch once, respect a manual change afterward"; same choice here.
    M.previousCamera = camera.getCamera()
    camera.setCamera(camera.CAMERAS.EXTERNAL)
    beamjoy_communications_ui.send("BJHunterCountdown", { active = true, seconds = math.ceil(delaySec) })
end

local function updateHunterResetLock()
    if not M.hunterResetLockedUntilMs then return end
    -- real, confirmed bug fixed here: this lock's own freeze was only ever SET once, at the
    -- moment of the crash. Unlike updateCountdown's own equivalent freeze, nothing here ever
    -- re-checked/reasserted it on subsequent frames, so if BeamNG's own physics/recovery briefly
    -- dropped the freeze flag on its own mid-lock, nothing caught it: "the hunter spawn cooldown
    -- sometimes lets you move your car while counting down". Mirrors updateCountdown's own
    -- per-frame reassertion exactly.
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh and myVeh.veh.froze ~= "1" then
        beamjoy_vehicles.setFreeze(myVeh.vid, true)
    end
    local remaining = math.max(0, math.ceil((M.hunterResetLockedUntilMs - GetCurrentTimeMillis()) / 1000))
    beamjoy_communications_ui.send("BJHunterCountdown", { active = true, seconds = remaining })
    if GetCurrentTimeMillis() >= M.hunterResetLockedUntilMs then
        M.hunterResetLockedUntilMs = nil
        -- real, confirmed bug fixed here: camera.stopForcedCameras() alone is a no-op for this
        -- lock (it only ever calls plain setCamera, never forceCamera). restorePreviousCamera()
        -- actually hands the camera back to whatever the player was on before the crash, same
        -- mechanism the COUNTDOWN lock uses, and already calls stopForcedCameras() internally too
        restorePreviousCamera()
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh then
            beamjoy_vehicles.setFreeze(myVeh.vid, false)
            -- per direct request: same checkGhostedBystanders=false + bounded force-fallback
            -- treatment as the HUNT-start release. A hunter coming off their own penalty lock
            -- alone isn't the "everyone releases simultaneously" scenario that check exists for,
            -- but it's harmless and consistent to apply the same safety margin regardless
            beamjoy_vehicles.setGhostReason(myVeh.vid, "hunter", false, false, false)
            local forceTaskName = "ghostHunterPenaltyForce-" .. myVeh.vid
            async.removeTask(forceTaskName)
            async.delayTask(function()
                beamjoy_vehicles.setGhostReason(myVeh.vid, "hunter", false, true)
            end, 2000, forceTaskName)
        end
        beamjoy_communications_ui.send("BJHunterCountdown", { active = false })
    end
end

local function onUpdate()
    if M.session and M.session.state == "LOBBY" then
        updateGridCountdown()
    end
    if M.session and M.session.state == "COUNTDOWN" then
        updateCountdown()
    end
    if M.hunterResetLockedUntilMs then
        updateHunterResetLock()
    end

    -- always on, not host-configurable (matching races' own anticheat parity, per direct
    -- request): gravity has no native keybind to block, so it's actively reasserted every frame
    -- instead; slow-motion/pause bypasses the action-filter restriction above entirely via
    -- BeamNG's own Environment settings panel (confirmed mechanism, ported from races' own
    -- identical block/comments). Both need this same active-reassertion treatment, not just an
    -- input block.
    if isHuntLocked() then
        local expectedGravity = beamjoy_environment.data.gravity
        if extensions.core_environment.getGravity() ~= expectedGravity then
            extensions.core_environment.setGravity(expectedGravity)
        end
        if simTimeAuthority.getPause() then
            simTimeAuthority.pause(false)
        elseif simTimeAuthority.get() ~= 1 then
            simTimeAuthority.setInstant(1)
        end
    end

    local isHunting = M.session and M.session.state == "HUNT"
    local isSpectatingHunt = M.spectatingSession and M.spectatingSession.state == "HUNT"
    if isHunting or isSpectatingHunt then
        local nowMs = GetCurrentTimeMillis()
        if not M.lastHudPushMs or nowMs - M.lastHudPushMs >= 200 then
            M.lastHudPushMs = nowMs
            pushHud()
        end
    end
end

local function onSlowUpdate()
    updateFugitiveState()
    updateRevealVisuals()
    updateGpsGuidance()
end

---@param opts table?
local function startHunt(opts)
    beamjoy_communications.send("hunterStart", opts or {})
end

---@param sessionId string
local function joinHunt(sessionId)
    beamjoy_communications.send("hunterJoin", sessionId)
end

---@param state boolean?
local function ready(state)
    if not M.session then return LogError("beamjoy_hunterRunner: not in a hunter session") end
    local becomingReady = state ~= false
    local model
    if becomingReady then
        -- role (and therefore which vehicle pool, if any, actually applies) isn't known until
        -- COUNTDOWN (see hunterGrid.lua's beginCountdown, the random fugitive draw), so there is
        -- nothing meaningful to validate a vehicle against yet at ready-up time ; requiring one
        -- here first is just friction for a player who hasn't decided yet or doesn't own a car at
        -- this exact moment. The COUNTDOWN-transition steering + hunterVehicleConfirmed gate (see
        -- onSessionUpdate) is what actually enforces a matching vehicle, with genuinely unhurried
        -- time to fix it, including from scratch with no vehicle at all. See that block's own
        -- comments for why this is now safe to relax.
        local veh = beamjoy_vehicles.getCurrentOwn()
        if veh and veh.jbeam ~= beamjoy_vehicles.WALKING then
            model = beamjoy_vehicles.getCurrentConfigDisplayLabel(veh.veh)
        end
    end
    beamjoy_communications.send("hunterReady", M.session.id, becomingReady, model)
end

local function leave()
    if not M.session then return end
    beamjoy_communications.send("hunterLeave", M.session.id)
end

local function cancel()
    if not M.session then return end
    beamjoy_communications.send("hunterCancel", M.session.id)
end

---@param targetPlayerID integer
local function forceFugitive(targetPlayerID)
    if not M.session then return end
    beamjoy_communications.send("hunterForceFugitive", M.session.id, targetPlayerID)
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onBJRequestCanSpawnVehicle = onBJRequestCanSpawnVehicle
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed

M.onSessionUpdate = onSessionUpdate
M.onSessionsList = onSessionsList
M.onSessionRemoved = onSessionRemoved
M.onSpectateUpdate = onSpectateUpdate
M.onSpectateRemoved = onSpectateRemoved
M.pushSessionStatus = pushSessionStatus
M.pushOpenSessions = pushOpenSessions
M.pushCountdown = pushCountdown
M.pushHud = pushHud
M.pushSpectateStatus = pushSpectateStatus

M.startHunt = startHunt
M.joinHunt = joinHunt
M.ready = ready
M.leave = leave
M.cancel = cancel
M.forceFugitive = forceFugitive
M.spectateSession = spectateSession
M.stopSpectating = stopSpectating

M.isHiddenFugitiveVehicle = isHiddenFugitiveVehicle
M.isRevealedFugitiveVehicle = isRevealedFugitiveVehicle
M.hunterNametagAlpha = hunterNametagAlpha

return M
