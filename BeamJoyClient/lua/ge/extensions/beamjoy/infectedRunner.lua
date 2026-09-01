--- Live Infected-round runtime: receives session state from `services/infectedGrid.lua`, drives the
--- local tag-detection mechanic (pure client-side, self-reported, same accepted trust model
--- hunterRunner.lua's own checkpoint/reveal reports already use), and reports a successful touch
--- back to the server. Mirrors `hunterRunner.lua`'s own shape (session tracking, restrictions,
--- camera/freeze lock) but trimmed to Infected's simpler mechanics: no waypoints/reveal/vehicle-pool/
--- respawn-penalty system, no per-role vehicle restriction (Infected's only ever a single optional
--- forced `config`, uniform across every role from LOBBY onward).
---
--- Console entry points for testing ahead of any UI: `beamjoy_infectedRunner.startInfected()`,
--- `beamjoy_infectedRunner.ready()`, `beamjoy_infectedRunner.leave()`.

local CAMERA_RELEASE_SECONDS = 3
local TAG_CANDIDATE_RADIUS = 50 -- slow-tick coarse cull distance, matching BJI's own equivalent

local M = {
    dependencies = { "beamjoy_infected", "beamjoy_vehicles", "beamjoy_players", "camera" },

    ---@type BJInfectedSession?
    session = nil,
    gameStartTimeMs = nil,
    roundDeadlineTargetMs = nil,
    gridReadyTargetMs = nil,
    gridTimeoutTargetMs = nil,

    -- COUNTDOWN camera-lock/freeze state, same technique as hunterRunner.lua's own, minus the
    -- vehicle-confirm wait (Infected has nothing per-role to confirm ; see this file's own header)
    scenarioLocked = false,
    countdownStartMs = nil,
    countdownTotal = nil,
    lastSentSeconds = nil,
    cameraReleased = false,
    ---@type string? camera mode the player was on before it got forced to EXTERNAL
    previousCamera = nil,

    ---@type integer? vid of the local player's own current session vehicle
    myVehicleVid = nil,

    -- infected-only, local tag-detection state : nearbySurvivorVids is the slow-tick coarse cull
    -- (BJI's own two-tier convention), refreshed roughly once a second ; selfDiag/survivorDiagCache
    -- avoid recomputing each vehicle's own bounding radius every frame
    ---@type integer[] gameVehIDs, refreshed by refreshTagCandidates (onSlowUpdate)
    nearbySurvivorVids = {},
    ---@type number? local player's own current vehicle bounding radius (half-diagonal)
    selfDiag = nil,
    ---@type table<integer, number> vid -> half-diagonal, cached once per vehicle
    survivorDiagCache = {},
    ---@type table<integer, boolean> vid -> true, survivors already reported this round : without
    ---this, staying in contact for more than one frame would resend infectedTag every single frame
    ---for as long as the touch lasts, instead of exactly once per target (the server itself is
    ---idempotent either way, this is purely to not spam the network)
    taggedVids = {},

    ---@type integer? local anchor (GetCurrentTimeMillis domain) for a pure spectator's own smooth
    ---elapsed-time display, re-derived from the server's own snapshot on every spectate update
    spectatingGameStartTimeMs = nil,
    ---@type integer? same anchor treatment for the round-survival countdown, spectator side
    spectatingRoundDeadlineTargetMs = nil,

    ---@type integer? gameVehID the native GPS is currently pointed at (the sole remaining
    ---survivor's own vehicle), tracked so updateGpsGuidance only re-issues setPath when the actual
    ---target changes, not every slow tick
    lastGpsTargetVid = nil,

    lastHudPushMs = nil,

    ---@type BJInfectedSession? a session being watched as a pure non-participant, mirrors
    ---hunterRunner.lua's own spectatingSession (entirely separate from M.session)
    spectatingSession = nil,

    ---@type table[] last-known open/joinable infected lobby list, for the remount-gap request-replay
    openSessions = {},
}

---@return BJInfectedParticipant?
local function getSelfParticipant()
    if not M.session then return nil end
    local selfName = MPConfig.getNickname()
    return table.find(M.session.participants, function(p) return p.playerName == selfName end)
end

--- true from COUNTDOWN through GAME: the frozen/locked window scenario-integrity restrictions apply
---@return boolean
local function isGameLocked()
    return M.session ~= nil and (M.session.state == "COUNTDOWN" or M.session.state == "GAME")
end

--- whether `mpVeh` currently belongs to an Infected participant, and if so which color its nametag
--- should be forced to (green survivor / red infected by default, host-overridable). Used by
--- nametags.lua exactly like beamjoy_pursuit's own fugitive-tag precedent: an unconditional color
--- override applied on top of whatever the viewer's own nametag color preferences would draw,
--- independent of the (separate, vehicle-paint-only) enableColors setting.
---@param mpVeh BJVehicle
---@return boolean isParticipant, BJColor? textColor, BJColor? bgColor
local function infectedNametagColor(mpVeh)
    local session = M.session or M.spectatingSession
    if not session or (session.state ~= "COUNTDOWN" and session.state ~= "GAME") then return false end
    local participant = table.find(session.participants, function(p) return p.playerName == mpVeh.ownerName end)
    if not participant or not participant.role then return false end
    if participant.role == "infected" then
        return true, session.settings.infectedColor or BJColor(1, 0, 0), BJColor(0, 0, 0, .5)
    end
    return true, session.settings.survivorColor or BJColor(.33, 1, .33), BJColor(0, 0, 0, .5)
end

---@param req RequestAuthorization
---@param model string
---@param config string?
---@param action ("spawn"|"replace"|"clone")?
local function onBJRequestCanSpawnVehicle(req, model, config, action)
    if M.session and M.session.settings.config then
        local forced = M.session.settings.config
        if model ~= forced.model or config ~= forced.config then
            req.state = false
            return
        end
    end

    if not isGameLocked() then return end

    -- Rejects a genuinely additional simultaneous vehicle for anyone locked into a round. Cloning
    -- is rejected outright, spawning a fresh one on top of an existing real vehicle too. Mirrors
    -- hunterRunner.lua's own onBJRequestCanSpawnVehicle identically.
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
    beamjoy_communications.addHandler("infectedSessionUpdate", M.onSessionUpdate)
    beamjoy_communications.addHandler("infectedSessionsList", M.onSessionsList)
    beamjoy_communications.addHandler("infectedSessionRemoved", M.onSessionRemoved)
    beamjoy_communications.addHandler("infectedSpectateUpdate", M.onSpectateUpdate)
    beamjoy_communications.addHandler("infectedSpectateRemoved", M.onSpectateRemoved)

    beamjoy_communications_ui.addHandler("BJInfectedStart", M.startInfected)
    beamjoy_communications_ui.addHandler("BJInfectedJoin", M.joinInfected)
    beamjoy_communications_ui.addHandler("BJInfectedReady", M.ready)
    beamjoy_communications_ui.addHandler("BJInfectedLeave", M.leave)
    beamjoy_communications_ui.addHandler("BJInfectedCancel", M.cancel)
    beamjoy_communications_ui.addHandler("BJInfectedForceInfected", M.forceInfected)
    beamjoy_communications_ui.addHandler("BJInfectedSpectate", M.spectateSession)
    beamjoy_communications_ui.addHandler("BJInfectedStopSpectate", M.stopSpectating)
    beamjoy_communications_ui.addHandler("BJInfectedSessionStatusRequest", M.pushSessionStatus)
    beamjoy_communications_ui.addHandler("BJInfectedOpenSessionsRequest", M.pushOpenSessions)
    beamjoy_communications_ui.addHandler("BJInfectedCountdownRequest", M.pushCountdown)
    beamjoy_communications_ui.addHandler("BJInfectedHudRequest", M.pushHud)
end

--- cameras a participant shouldn't be able to reach while game-locked : unlike races, this isn't
--- host-configurable, matching hunterRunner.lua's own unconditional huntBlockedCameras
---@return string[]
local function gameBlockedCameras()
    return { camera.CAMERAS.BIG_MAP, camera.CAMERAS.FREE, camera.CAMERAS.CINEMATIC, camera.CAMERAS.STEADYCAM }
end

---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    if not M.session then return end
    local participant = getSelfParticipant()
    if not participant then return end

    -- No walking during LOBBY or an active GAME : walking away from a chase sidesteps it just as
    -- much as any vehicle-based evasion would. Matches hunterRunner.lua's own identical treatment.
    if M.session.state == "LOBBY" or M.session.state == "GAME" then
        restrictions:addAll({ "toggleWalkingMode", "dropPlayerAtCamera", "dropPlayerAtCameraNoReset" }, true)
    end

    if not isGameLocked() then return end

    restrictions:addAll({
        "nodegrabberAction", "nodegrabberGrab", "nodegrabberRender",
        "nodegrabberStrength", "nodegrabberPadGrab", "nodegrabberPadMode",
    }, true)

    restrictions:addAll({ "toggle_slow_motion", "slower_motion", "faster_motion", "pause" }, true)

    -- Resetting/recovering during COUNTDOWN (frozen at the grid) is always blocked, same as
    -- races'/hunter's own COUNTDOWN block. No GAME-time reset restriction at all : unlike Hunter,
    -- crashing has no special penalty here, a survivor or infected can reset freely mid-round.
    if M.session.state == "COUNTDOWN" then
        restrictions:addAll({
            "recover_vehicle", "recover_vehicle_alt", "recover_to_last_road",
            "reset_physics", "reset_all_physics", "reload_vehicle",
        }, true)
    end
end

--- see hunterRunner.lua's own identical function for the full reasoning (no camera can be safely
--- restored to with no vehicle present, so a genuinely carless player just keeps M.previousCamera
--- intact for a later, successful call to actually use)
local function restorePreviousCamera()
    camera.stopForcedCameras()
    if not M.previousCamera then return end
    if not beamjoy_vehicles.getCurrentOwn() then return end
    local nonVehicleCameras = { camera.CAMERAS.FREE, camera.CAMERAS.BIG_MAP,
        camera.CAMERAS.CINEMATIC, camera.CAMERAS.STEADYCAM }
    local target = table.includes(nonVehicleCameras, M.previousCamera) and camera.CAMERAS.ORBIT or
        M.previousCamera
    camera.setCamera(target)
    camera.resetCamera()
    M.previousCamera = nil
end

local function unlockScenario()
    if not M.scenarioLocked then return end
    M.scenarioLocked = false
    M.cameraReleased = false
    M.countdownStartMs = nil
    restorePreviousCamera()
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh then beamjoy_vehicles.setFreeze(myVeh.vid, false) end
    extensions.hook("onBJScenarioChanged")
end

local function releaseScenarioLock()
    unlockScenario()
    beamjoy_communications_ui.send("BJInfectedCountdown", { active = false })
end

---@return boolean
local function clearGameState()
    local hadSession = M.session ~= nil
    M.session = nil
    M.gameStartTimeMs = nil
    M.roundDeadlineTargetMs = nil
    M.gridReadyTargetMs = nil
    M.gridTimeoutTargetMs = nil
    M.nearbySurvivorVids = {}
    M.selfDiag = nil
    M.survivorDiagCache = {}
    M.taggedVids = {}
    M.myVehicleVid = nil
    if M.lastGpsTargetVid ~= nil then
        M.lastGpsTargetVid = nil
        extensions.core_groundMarkers.setPath(nil)
    end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh then
        beamjoy_vehicles.setGhostReason(myVeh.vid, "infected", false)
    end
    releaseScenarioLock()
    camera.stopForcedCameras()
    camera.unblockCameras()
    return hadSession
end

---@param session BJInfectedSession
local function pushSessionStatus_impl(session)
    local participant = getSelfParticipant()
    if not session or not participant then
        return beamjoy_communications_ui.send("BJInfectedSessionStatus", nil)
    end
    local starter = table.find(session.participants, function(p) return p.playerID == session.starterID end)
    local arena = session.arenaSnapshot or {}
    beamjoy_communications_ui.send("BJInfectedSessionStatus", {
        id = session.id,
        state = session.state,
        participantCount = #session.participants,
        maxParticipants = #(arena.survivorSpawns or {}) +
            math.min(session.settings.initialInfectedCount, #(arena.infectedSpawns or {})),
        participants = table.map(session.participants, function(p)
            return {
                playerName = p.playerName,
                playerID = p.playerID,
                ready = p.ready,
                role = p.role,
                vehicleModel = p.vehicleModel,
                tagCount = p.tagCount,
            }
        end),
        role = participant.role,
        ready = participant.ready,
        isStarter = starter and starter.playerName == participant.playerName,
        winner = session.winner,
        settings = {
            roundDuration = session.settings.roundDuration,
            initialInfectedCount = session.settings.initialInfectedCount,
            enableColors = session.settings.enableColors,
        },
        gridReadySecondsLeft = M.gridReadyTargetMs and
            math.max(0, math.ceil((M.gridReadyTargetMs - GetCurrentTimeMillis()) / 1000)) or nil,
        gridTimeoutSecondsLeft = M.gridTimeoutTargetMs and
            math.max(0, math.ceil((M.gridTimeoutTargetMs - GetCurrentTimeMillis()) / 1000)) or nil,
    })
end

local function pushSessionStatus()
    if not M.session then
        return beamjoy_communications_ui.send("BJInfectedSessionStatus", nil)
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
    beamjoy_communications_ui.send("BJInfectedOpenSessions", M.openSessions or {})
end

---@param list table[]
local function onSessionsList(list)
    local previousIds = table.map(M.openSessions or {}, function(s) return s.id end)
    local selfName = MPConfig.getNickname()
    table.forEach(list, function(s)
        if not table.includes(previousIds, s.id) and s.starterName ~= selfName then
            beamjoy_communications_ui.uiBroadcast("beamjoy.infected.newJoinableSession",
                { starterName = s.starterName }, nil, 4)
        end
    end)

    M.openSessions = list
    pushOpenSessions()
end

local function pushHud()
    local session = M.session or M.spectatingSession
    if not session or session.state ~= "GAME" then
        return beamjoy_communications_ui.send("BJInfectedHud", { active = false })
    end
    local participant = M.session and getSelfParticipant() or nil
    local survivorsLeft, infectedCount = 0, 0
    for _, p in ipairs(session.participants) do
        if p.role == "survivor" then
            survivorsLeft = survivorsLeft + 1
        elseif p.role == "infected" then
            infectedCount = infectedCount + 1
        end
    end
    local elapsedMs = session.gameElapsedMs or 0
    if M.session and M.gameStartTimeMs then
        elapsedMs = GetCurrentTimeMillis() - M.gameStartTimeMs
    elseif M.spectatingSession and M.spectatingGameStartTimeMs then
        elapsedMs = GetCurrentTimeMillis() - M.spectatingGameStartTimeMs
    end
    local targetMs = M.session and M.roundDeadlineTargetMs or
        (M.spectatingSession and M.spectatingRoundDeadlineTargetMs)
    local roundSecondsLeft = targetMs and math.max(0, math.ceil((targetMs - GetCurrentTimeMillis()) / 1000)) or nil

    beamjoy_communications_ui.send("BJInfectedHud", {
        active = true,
        gameElapsedMs = elapsedMs,
        roundSecondsLeft = roundSecondsLeft,
        survivorsLeft = survivorsLeft,
        infectedCount = infectedCount,
        role = participant and participant.role or nil,
        tagCount = participant and participant.tagCount or nil,
    })
end

---@param session BJInfectedSession
local function onSpectateUpdate(session)
    M.spectatingSession = session
    if session.state == "GAME" and session.gameElapsedMs ~= nil then
        M.spectatingGameStartTimeMs = GetCurrentTimeMillis() - session.gameElapsedMs
    else
        M.spectatingGameStartTimeMs = nil
    end
    if session.state == "GAME" and session.roundSecondsLeft ~= nil then
        M.spectatingRoundDeadlineTargetMs = GetCurrentTimeMillis() + session.roundSecondsLeft * 1000
    else
        M.spectatingRoundDeadlineTargetMs = nil
    end
    pushHud()
end

---@param sessionId string
local function onSpectateRemoved(sessionId)
    if M.spectatingSession and M.spectatingSession.id == sessionId then
        M.spectatingSession = nil
        M.spectatingGameStartTimeMs = nil
        M.spectatingRoundDeadlineTargetMs = nil
        pushHud()
    end
end

---@param sessionId string
local function spectateSession(sessionId)
    beamjoy_communications.send("infectedSpectate", sessionId)
end

local function stopSpectating()
    beamjoy_communications.send("infectedStopSpectate")
end

local function pushSpectateStatus()
    pushHud()
end

---@param session BJInfectedSession
local function onSessionUpdate(session)
    local wasInSession = M.session ~= nil
    local wasCountdown = M.session ~= nil and M.session.state == "COUNTDOWN"
    local wasGame = M.session ~= nil and M.session.state == "GAME"
    local wasFinished = M.session ~= nil and M.session.state == "FINISHED"
    M.session = session

    if session.state == "LOBBY" and session.joinable and session.gridReadySecondsLeft ~= nil then
        M.gridReadyTargetMs = GetCurrentTimeMillis() + session.gridReadySecondsLeft * 1000
        M.gridTimeoutTargetMs = GetCurrentTimeMillis() + (session.gridTimeoutSecondsLeft or 0) * 1000
    else
        M.gridReadyTargetMs = nil
        M.gridTimeoutTargetMs = nil
    end

    if session.state == "GAME" and session.roundSecondsLeft ~= nil then
        M.roundDeadlineTargetMs = GetCurrentTimeMillis() + session.roundSecondsLeft * 1000
    else
        M.roundDeadlineTargetMs = nil
    end

    local participant = getSelfParticipant()
    if not participant then
        clearGameState()
        extensions.hook("onBJScenarioChanged")
        pushHud()
        pushSessionStatus()
        return
    end
    pushSessionStatus()

    -- Steers the player toward the forced vehicle the moment they join the lobby (if any), same
    -- convention races'/hunter's own GRID-entry steering uses. Unlike Hunter's per-role pool, this
    -- applies uniformly from LOBBY onward, since Infected's forced config isn't role-dependent.
    if session.state == "LOBBY" and not wasInSession and session.settings.config then
        local forced = session.settings.config
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        local full = myVeh and beamjoy_vehicles.getFullConfig(myVeh.veh)
        local matches = full ~= nil and full.model == forced.model and
            table.deepcompare(full.parts or {}, forced.parts or {})
        if not matches then
            if myVeh then beamjoy_vehicles.deleteCurrentOwnVehicle() end
            toast.warn(string.format("This round requires vehicle: %s. Pick it from the vehicle selector",
                forced.label or forced.model), nil, 6)
            extensions.ui_vehicleSelector_general.openVehicleSelectorForFreeroam()
        end
    end

    if session.state == "COUNTDOWN" and not wasCountdown then
        beamjoy_communications_ui.closeWindow("config")
        if beamjoy_ui_activityEditor then
            beamjoy_ui_activityEditor.onClose()
        end

        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh then
            M.myVehicleVid = myVeh.vid
            if participant.spawnPos then
                beamjoy_vehicles.setVehiclePositionRotation(myVeh.veh,
                    vec3(participant.spawnPos.x, participant.spawnPos.y, participant.spawnPos.z),
                    vec3(participant.spawnDir.x, participant.spawnDir.y, participant.spawnDir.z),
                    vec3(0, 0, 1), { cling = false })
            else
                LogWarn("beamjoy_infectedRunner: no spawn position to teleport to")
            end
            beamjoy_vehicles.setGhostReason(myVeh.vid, "infected", true)
        end

        M.scenarioLocked = true
        M.cameraReleased = false
        M.countdownStartMs = GetCurrentTimeMillis()
        M.countdownTotal = session.settings.countdown
        M.lastSentSeconds = nil
        M.previousCamera = camera.getCamera()
        if myVeh then
            camera.setCamera(camera.CAMERAS.EXTERNAL)
            camera.blockCameras(table.unpack(gameBlockedCameras()))
            beamjoy_vehicles.setFreeze(myVeh.vid, true)
        end
        extensions.hook("onBJScenarioChanged")
    end

    if session.state == "GAME" and not wasGame then
        if M.scenarioLocked then
            unlockScenario()
            beamjoy_communications_ui.send("BJInfectedCountdown", { active = false })
        end
        -- Asymmetric release, exactly mirroring hunterRunner.lua's own huntedStartDelay/
        -- huntersStartDelay treatment: both roles freeze at the exact GAME-start instant
        -- server-side, unfreezing locally after their own role's own delay (infected's built-in
        -- delay is the survivors' head start). A survivor tagged mid-round is never frozen at all;
        -- this block only ever runs once, at the real LOBBY/COUNTDOWN -> GAME transition.
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        local delaySec = participant.role == "infected" and session.settings.infectedStartDelay or
            session.settings.survivorsStartDelay
        if myVeh then
            beamjoy_vehicles.setFreeze(myVeh.vid, true)
        end
        async.delayTask(function()
            local currVeh = beamjoy_vehicles.getCurrentOwn()
            if currVeh then beamjoy_vehicles.setFreeze(currVeh.vid, false) end
            local vid = currVeh and currVeh.vid or (myVeh and myVeh.vid)
            if not vid then return end
            -- same distance-safe release + bounded force-fallback as hunterRunner.lua's own
            -- HUNT-start release, for the same "everyone on a role releases together, stale ghost
            -- flags" reasoning
            beamjoy_vehicles.setGhostReason(vid, "infected", false, false, false)
            local forceTaskName = "ghostInfectedStartForce-" .. vid
            async.removeTask(forceTaskName)
            async.delayTask(function()
                beamjoy_vehicles.setGhostReason(vid, "infected", false, true)
            end, 2000, forceTaskName)
        end, math.max(0, delaySec) * 1000, "BJInfectedReleaseFreeze")
        M.gameStartTimeMs = GetCurrentTimeMillis()
        M.nearbySurvivorVids = {}
        M.selfDiag = nil
        M.survivorDiagCache = {}
        M.taggedVids = {}
        beamjoy_communications_ui.uiBroadcast("beamjoy.infected.gameStarted", nil, "green", 3)
    end

    if session.state == "GAME" and beamjoy_vehicles.getCurrentOwn() then
        camera.blockCameras(table.unpack(gameBlockedCameras()))
    end

    if session.state == "FINISHED" then
        unlockScenario()
        camera.unblockCameras()
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh then beamjoy_vehicles.setGhostReason(myVeh.vid, "infected", false) end
        if not wasFinished then
            beamjoy_communications_ui.send("BJInfectedCountdown",
                { active = true, finished = true, winner = session.winner })
            async.delayTask(function()
                beamjoy_communications_ui.send("BJInfectedCountdown", { active = false })
            end, 8000, "BJInfectedFinishedPopupHide")
        end
    end

    pushHud()
end

---@param sessionId string
local function onSessionRemoved(sessionId)
    if not M.session or M.session.id ~= sessionId then return end
    clearGameState()
    extensions.hook("onBJScenarioChanged")
    pushHud()
    pushSessionStatus()
end

local function updateCountdown()
    if not M.scenarioLocked or not M.countdownStartMs or not M.countdownTotal then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh and myVeh.veh.froze ~= "1" then
        beamjoy_vehicles.setFreeze(myVeh.vid, true)
    end

    local elapsedSec = (GetCurrentTimeMillis() - M.countdownStartMs) / 1000
    local remaining = math.max(0, math.ceil(M.countdownTotal - elapsedSec))
    if remaining ~= M.lastSentSeconds then
        M.lastSentSeconds = remaining
        beamjoy_communications_ui.send("BJInfectedCountdown", { active = true, seconds = remaining })
    end
    if not M.cameraReleased and remaining <= CAMERA_RELEASE_SECONDS then
        M.cameraReleased = true
        if camera.getCamera() == camera.CAMERAS.EXTERNAL then
            restorePreviousCamera()
        end
        extensions.hook("onBJScenarioChanged")
    end
end

local function pushCountdown()
    if not M.session or M.session.state ~= "COUNTDOWN" then return end
    if M.countdownStartMs and M.lastSentSeconds ~= nil then
        beamjoy_communications_ui.send("BJInfectedCountdown", { active = true, seconds = M.lastSentSeconds })
    end
end

--- native-GPS beacon to the sole remaining survivor, for every infected participant and every
--- spectator, once exactly one survivor is left. Ported from BJI's own equivalent (see
--- ScenarioInfected.lua's slowTick), an endgame-tension nicety that also keeps a round from
--- dragging on in a genuinely huge, empty map once the chase is already effectively decided.
--- Re-issued only when the actual target changes, same "setPath renders on its own every frame,
--- nothing here needs to re-call it just to keep it visible" reasoning as hunterRunner.lua's own
--- updateGpsGuidance.
local function updateGpsGuidance()
    local session = M.session or M.spectatingSession
    local participant = M.session and getSelfParticipant() or nil
    local relevant = session and session.state == "GAME" and (not M.session or
        (participant and participant.role == "infected"))
    local targetVid
    if relevant then
        local survivors = table.filter(session.participants, function(p) return p.role == "survivor" end)
        if #survivors == 1 then
            local mpVeh = beamjoy_vehicles.vehicles:find(function(v) return v.ownerName == survivors[1].playerName end)
            targetVid = mpVeh and mpVeh.vid
        end
    end
    if targetVid ~= M.lastGpsTargetVid then
        M.lastGpsTargetVid = targetVid
        if targetVid then
            extensions.core_groundMarkers.setPath(targetVid)
        else
            extensions.core_groundMarkers.setPath(nil)
        end
    end
end

--- slow-tick coarse cull (BJI's own two-tier convention) : rebuilds the small nearby-survivor
--- candidate list a fast per-frame precise check can then afford to run against every tick. A no-op
--- (empty list) whenever the local player isn't currently an infected participant in an active GAME.
local function refreshTagCandidates()
    M.nearbySurvivorVids = {}
    if not M.session or M.session.state ~= "GAME" then return end
    local participant = getSelfParticipant()
    if not participant or participant.role ~= "infected" then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return end
    local myFresh = beamjoy_vehicles.getVehicle(myVeh.vid)
    if not myFresh or not myFresh.position then return end

    local survivorNames = {}
    for _, p in ipairs(M.session.participants) do
        if p.role == "survivor" then survivorNames[p.playerName] = true end
    end
    beamjoy_vehicles.vehicles:forEach(function(v)
        if survivorNames[v.ownerName] then
            local fresh = beamjoy_vehicles.getVehicle(v.vid)
            if fresh and fresh.position and fresh.position:distance(myFresh.position) < TAG_CANDIDATE_RADIUS then
                table.insert(M.nearbySurvivorVids, v.vid)
            end
        end
    end)
end

---@param veh NGVehicle
---@return number half-diagonal, matching BJI's own bounding-radius convention
local function vehicleDiag(veh)
    return math.sqrt((veh:getInitialLength() / 2) ^ 2 + (veh:getInitialWidth() / 2) ^ 2)
end

--- fast per-frame precise check against whatever refreshTagCandidates last found nearby : a plain
--- bounding-radius touch (self diag + target diag vs actual distance), same primitive BJI's own
--- fastTick uses. Reports a successful touch to the server via infectedTag ; the server is the real
--- authority (idempotent role check), this is purely "what should I even bother sending".
local function updateTagDetection()
    if #M.nearbySurvivorVids == 0 then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return end
    local myFresh = beamjoy_vehicles.getVehicle(myVeh.vid)
    if not myFresh or not myFresh.position then return end
    if not M.selfDiag then
        M.selfDiag = vehicleDiag(myVeh.veh)
    end

    for _, vid in ipairs(M.nearbySurvivorVids) do
        local mpVeh = not M.taggedVids[vid] and beamjoy_vehicles.vehicles[vid]
        if mpVeh then
            local fresh = beamjoy_vehicles.getVehicle(vid)
            if fresh and fresh.position then
                local otherDiag = M.survivorDiagCache[vid]
                if not otherDiag then
                    otherDiag = vehicleDiag(fresh.veh)
                    M.survivorDiagCache[vid] = otherDiag
                end
                if fresh.position:distance(myFresh.position) < (M.selfDiag + otherDiag) then
                    M.taggedVids[vid] = true
                    beamjoy_communications.send("infectedTag", M.session.id, mpVeh.ownerID)
                end
            end
        end
    end
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    if not M.session or M.session.state ~= "COUNTDOWN" then return end
    local participant = getSelfParticipant()
    if not participant then return end
    local mpVeh = beamjoy_vehicles.getVehicle(vid, true)
    if not mpVeh or not mpVeh.isLocal then return end

    M.myVehicleVid = vid
    if participant.spawnPos then
        beamjoy_vehicles.setVehiclePositionRotation(mpVeh.veh,
            vec3(participant.spawnPos.x, participant.spawnPos.y, participant.spawnPos.z),
            vec3(participant.spawnDir.x, participant.spawnDir.y, participant.spawnDir.z),
            vec3(0, 0, 1), { cling = false })
    end
    beamjoy_vehicles.setFreeze(vid, true)
    beamjoy_vehicles.setGhostReason(vid, "infected", true)
    -- 0s respawn-ghost override, same reasoning as hunterRunner.lua's own identical treatment : the
    -- whole point of this mode is contact-based tagging, so a few free seconds of ghosting right
    -- after a countdown-time spawn would be exactly the wrong moment for it
    beamjoy_vehicles.setGhostReason(vid, "respawn", false)
    if M.scenarioLocked then
        camera.setCamera(camera.CAMERAS.EXTERNAL)
        camera.blockCameras(table.unpack(gameBlockedCameras()))
    end
end

local function onUpdate()
    if M.scenarioLocked then
        updateCountdown()
    end
    updateTagDetection()
end

local function onSlowUpdate()
    updateGridCountdown()
    refreshTagCandidates()
    updateGpsGuidance()
    local now = GetCurrentTimeMillis()
    if not M.lastHudPushMs or now - M.lastHudPushMs > 900 then
        M.lastHudPushMs = now
        pushHud()
    end
end

---@param opts table? see BJInfectedSessionSettings for every overridable field
local function startInfected(opts)
    beamjoy_communications.send("infectedStart", opts or {})
end

---@param sessionId string
local function joinInfected(sessionId)
    beamjoy_communications.send("infectedJoin", sessionId)
end

---@param state boolean
local function ready(state)
    if not M.session then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    beamjoy_communications.send("infectedReady", M.session.id, state == true,
        myVeh and myVeh.veh.jbeam or nil)
end

local function leave()
    if not M.session then return end
    beamjoy_communications.send("infectedLeave", M.session.id)
end

local function cancel()
    if not M.session then return end
    beamjoy_communications.send("infectedCancel", M.session.id)
end

---@param targetPlayerID integer
local function forceInfected(targetPlayerID)
    if not M.session then return end
    beamjoy_communications.send("infectedForceInfected", M.session.id, targetPlayerID)
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onBJRequestCanSpawnVehicle = onBJRequestCanSpawnVehicle
M.onBJVehicleInstantiated = onBJVehicleInstantiated

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

M.startInfected = startInfected
M.joinInfected = joinInfected
M.ready = ready
M.leave = leave
M.cancel = cancel
M.forceInfected = forceInfected
M.spectateSession = spectateSession
M.stopSpectating = stopSpectating

M.infectedNametagColor = infectedNametagColor

return M
