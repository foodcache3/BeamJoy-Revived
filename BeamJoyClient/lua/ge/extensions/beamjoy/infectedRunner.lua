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
-- Real gap, per direct request: resetting mid-round used to be entirely free (no gate at all),
-- unlike Races (host-configurable ghost+freeze penalty, or an outright block under "norespawn")
-- and Hunter (never blocked, but a host-configurable escalating freeze). Matches the community
-- "Outbreak" mod's own default (disableResetsWhenMoving/maxResetMovingSpeed, both default true/2
-- in its Server/OutBreak/main.lua) : resetting is only ever allowed below this speed, so it can't
-- be used to instantly escape being chased/rammed.
local RESET_MAX_SPEED = 2

local M = {
    dependencies = { "beamjoy_infected", "beamjoy_vehicles", "beamjoy_players", "camera" },

    ---@type BJInfectedSession?
    session = nil,
    gameStartTimeMs = nil,
    roundDeadlineTargetMs = nil,
    gridReadyTargetMs = nil,
    gridTimeoutTargetMs = nil,
    ---@type integer? GetCurrentTimeMillis domain: when the GAME-start release-freeze delay
    ---(infectedStartDelay ; survivors have no such delay) actually unfreezes this client, nil once
    ---released or whenever no hold is in effect. Real bug: this delay used to have no HUD indicator at
    ---all, so a held participant had no way to tell they were frozen on purpose (working as
    ---intended) rather than stuck/bugged.
    holdReleaseTargetMs = nil,

    -- COUNTDOWN camera-lock/freeze state, same technique as hunterRunner.lua's own, minus the
    -- vehicle-confirm wait (Infected has nothing per-role to confirm ; see this file's own header)
    scenarioLocked = false,
    countdownStartMs = nil,
    countdownTotal = nil,
    ---@type boolean per direct request (mirroring hunterRunner.lua's own identical mechanism): the
    ---countdown overlay stays ticking through this round's own infectedStartDelay instead of
    ---vanishing at 0 and freezing again with no visible timer (Infected already had a SEPARATE,
    ---smaller HUD indicator for this via holdReleaseTargetMs/pushHud - this is about the same big
    ---overlay experience Hunter now gets too, not a replacement for that). When true,
    ---updateCountdown()'s own per-tick freeze-(re)assertion is skipped - this phase's
    ---freeze/unfreeze is driven entirely by the explicit calls around the GAME-transition block,
    ---not that loop, so it can't fight the delayed release at the exact moment it fires.
    countdownDisplayOnly = false,
    lastSentSeconds = nil,
    cameraReleased = false,
    ---@type string? camera mode the player was on before it got forced to EXTERNAL
    previousCamera = nil,

    ---@type integer? vid of the local player's own current session vehicle
    myVehicleVid = nil,

    ---@type table<integer, NGPaint>? this round's own snapshot of the local player's OWN vehicle
    ---paint (all 3 slots, as returned by beamjoy_vehicles.getFullConfig), taken the first time
    ---applyRoleColor actually overrides it (round start, or the mid-round survivor->infected
    ---flip for someone with no prior override this round) ; nil whenever enableColors is off or
    ---nothing's been overridden yet this round. Restored (and cleared) the moment the round ends
    ---or this client leaves/is removed, so a repainted car doesn't stay that color forever.
    originalPaints = nil,

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

    lastHudPushMs = nil,

    ---@type BJInfectedSession? a session being watched as a pure non-participant, mirrors
    ---hunterRunner.lua's own spectatingSession (entirely separate from M.session)
    spectatingSession = nil,

    ---@type table[] last-known open/joinable infected lobby list, for the remount-gap request-replay
    openSessions = {},

    ---@type boolean true while the local vehicle is moving faster than RESET_MAX_SPEED, updated
    ---every frame ; resets are blocked while this is true (see onBJRequestRestrictions), same
    ---policy as the community "Outbreak" mod's own default
    movingTooFastToReset = false,
    ---@type integer? GetCurrentTimeMillis domain: resets are blocked until this passes, set right
    ---after any reset actually happens (see onVehicleResetted) for session.settings.resetRelockSeconds
    ---- a flat anti-spam debounce, not an escalating penalty, matching BJI's own resetLock
    ---convention (there: a fixed, non-configurable 1s ; here: host-configurable)
    resetRelockUntilMs = nil,
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

--- session.settings.survivorColor/infectedColor arrive over the wire as plain {r, g, b} tables
--- (Lua's BJColor is never anything more than that shape ; see services/infected.lua's own
--- BJInfectedDefaults doc), not real BJColor() objects with their metatable/methods attached
--- (JSON round-tripping never reconstructs those, same reason localStorage.lua's own color reads
--- come back as plain tables too). Normalizes into a real BJColor so every caller gets a
--- consistent, always-valid object with a real default alpha, falling back to `fallback` (itself
--- a real BJColor) whenever the setting is unset/malformed. In practice only the always-on
--- nametag override (infectedNametagColor) still relies on that fallback: applyRoleColor's own
--- vehicle repaint checks the RAW setting itself first and skips entirely on nil, so a cleared
--- color means free paint there, not "forced to this fallback instead".
---@param raw table?
---@param fallback BJColor
---@return BJColor
local function toColor(raw, fallback)
    if type(raw) == "table" and type(raw.r) == "number" then
        return BJColor(raw.r, raw.g, raw.b, raw.a)
    end
    return fallback
end

local DEFAULT_SURVIVOR_COLOR = BJColor(.33, 1, .33)
local DEFAULT_INFECTED_COLOR = BJColor(1, 0, 0)

---@param session BJInfectedSession
---@param role BJInfectedRole
---@return BJColor
local function roleColor(session, role)
    if role == "infected" then
        return toColor(session.settings.infectedColor, DEFAULT_INFECTED_COLOR)
    end
    return toColor(session.settings.survivorColor, DEFAULT_SURVIVOR_COLOR)
end

---@param p Point4F?
---@return {x: number, y: number, z: number, w: number}?
local function snapshotColorField(p)
    if not p then return nil end
    return { x = p.x, y = p.y, z = p.z, w = p.w }
end

--- NGPaint shaped from a plain 4-value color snapshot, at fixed material defaults (BJI's own
--- reference values for a flat, uniform paint job). Used both for the role-color override itself
--- and for reconstructing a paintable NGPaint from a restore snapshot, so a restore goes through
--- the exact same beamjoy_vehicles.paint()/liveUpdateVehicleColors path the override did (the
--- proven, network-synced mechanism this codebase already establishes for repainting a vehicle,
--- e.g. traffic.lua's own random livery pick ; a remote participant's own repaint likewise reaches
--- every other client through that same BeamMP paint sync, not by this function running again on
--- their behalf). The trade-off: only the color itself round-trips exactly, not whatever
--- metallic/roughness/clearCoat finish the vehicle's own config originally had ; an accepted
--- simplification, not a bug, since there's no established way in this codebase to read a
--- vehicle's live (as opposed to catalog) material properties at all.
---@param snap {x: number, y: number, z: number, w: number}
---@return NGPaint
local function ngPaintFromSnapshot(snap)
    return {
        baseColor = { snap.x, snap.y, snap.z, snap.w },
        metallic = .5,
        roughness = .5,
        clearCoat = .5,
        clearCoatRoughness = .5,
    }
end

--- enableColors' own effect (separate from, and in addition to, the always-on nametag color
--- above): force-repaints the LOCAL PLAYER'S OWN vehicle to their current role's flat color, all 3
--- paint slots, matching BJI's own tryApplyScenarioColor (a uniform paint loop over every slot).
--- Only ever touches this client's own vehicle: a remote participant's repaint reaches every other
--- client the normal way, through BeamMP's own vehicle paint sync, not through this function
--- running again on their behalf. Snapshots the vehicle's real current color into M.originalPaints
--- the first time this actually overrides anything this round (never overwritten by a later call,
--- e.g. the mid-round survivor->infected flip, so the snapshot always reflects genuinely original
--- color, not an already-overridden one), for restoreOriginalPaint to hand back later. Reads
--- veh.color/colorPalette0/colorPalette1 directly (the vehicle's real, currently-rendered colors,
--- Point4F x/y/z/w) rather than beamjoy_vehicles.getFullConfig(veh).paints: that field is only
--- ever populated for a vehicle that already has an explicit runtime paint override recorded, and
--- is an EMPTY table for the common case of one just using its .pc file's own baked-in colors,
--- which would make a later restore call silently do nothing. Same snapshot source the standalone
--- community "Outbreak" mod uses for this exact same temporarily-recolor-then-revert case.
---@param role BJInfectedRole
local function applyRoleColor(role)
    if not M.session or not M.session.settings.enableColors then return end
    -- Real gap: an unset color (survivorColor/infectedColor both start nil) fell through to
    -- roleColor's own hardcoded green/red fallback, which is right for the nametag color above
    -- (always-on, needs SOME color regardless) but wrong here - clearing a role's color is
    -- supposed to mean that role keeps free paint choice, not "force a different hardcoded
    -- color instead". Checked against the RAW setting, not roleColor's own fallback-applying
    -- return value, specifically so this function alone can skip the repaint while nametags
    -- still get their default color.
    local rawColor = role == "infected" and M.session.settings.infectedColor or M.session.settings.survivorColor
    if not rawColor then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return end
    local veh = myVeh.veh
    if not M.originalPaints then
        M.originalPaints = {
            snapshotColorField(veh.color),
            snapshotColorField(veh.colorPalette0),
            snapshotColorField(veh.colorPalette1),
        }
    end

    local color = roleColor(M.session, role)
    local ngPaint = ngPaintFromSnapshot({ x = color.r, y = color.g, z = color.b, w = color.a })
    beamjoy_vehicles.paint(veh, { [1] = ngPaint, [2] = ngPaint, [3] = ngPaint })
end

--- hands the local player's own vehicle color back once a round ends or this client stops
--- participating, so enableColors never leaves a car stuck red/green after the fact. A no-op
--- whenever nothing was ever actually overridden this round (M.originalPaints stays nil).
local function restoreOriginalPaint()
    if not M.originalPaints then return end
    local snap = M.originalPaints
    M.originalPaints = nil
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return end
    local paintData = {}
    for slot = 1, 3 do
        if snap[slot] then paintData[slot] = ngPaintFromSnapshot(snap[slot]) end
    end
    beamjoy_vehicles.paint(myVeh.veh, paintData)
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
    return true, roleColor(session, participant.role), BJColor(0, 0, 0, .5)
end

--- Real bug: the color override above used to be unconditional, meaning a survivor could tell
--- exactly who's infected just by nametag color alone, trivially defeating the point of the mode.
--- Host-configurable (session.settings.hideInfectedNametags, default off) rather than a hardcoded
--- behavior change. Only ever hides the tag from a viewer who is THEMSELVES a survivor in this
--- same session: staff/spectators/other infected are unaffected, mirroring how
--- hunterRunner.lua's own isHiddenFugitiveVehicle is likewise narrow in scope.
---@param mpVeh BJVehicle
---@return boolean
local function isHiddenInfectedVehicle(mpVeh)
    local session = M.session or M.spectatingSession
    if not session or (session.state ~= "COUNTDOWN" and session.state ~= "GAME") then return false end
    if not session.settings.hideInfectedNametags then return false end
    local self = M.session and getSelfParticipant()
    if not self or self.role ~= "survivor" then return false end
    local target = table.find(session.participants, function(p) return p.playerName == mpVeh.ownerName end)
    return target ~= nil and target.role == "infected"
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
    -- Real bug: "replace" (a normal vehicle-selector tile pick) was never rejected here at all,
    -- regardless of isGameLocked() - only clone/spawn were, since a replace deletes the existing
    -- vehicle itself rather than leaving two around, which is all this function originally cared
    -- about. That left a participant free to swap to a completely different vehicle mid-round with
    -- zero consequence once COUNTDOWN starts, since a replace goes through the vehicle selector,
    -- not "spawn"/"clone". Per direct request: a locked-in participant shouldn't be able to change
    -- vehicle at all once the countdown has started, not just be prevented from having two at once.
    if action == "replace" then
        req.state = false
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

    -- Reworked per direct request, after live testing of the original "in-place always ok,
    -- reposition always blocked" policy: recover_vehicle (BeamNG's classic hold-to-recover, a
    -- sustained in-place-ish nudge rather than an instant teleport) is now the ONE reset method
    -- actually left reachable, velocity-gated exactly like reset_physics used to be. Every OTHER
    -- reset/recover/reposition path is unconditionally blocked instead - including two native UI
    -- paths that bypass core_input_actionFilter entirely otherwise, confirmed by reading the
    -- installed game's own source:
    --   - lua/ge/extensions/ui/pause/providers/vehicleTabInteractions.lua's own tryResetVehicle
    --     (the ESC-menu "Reset" tile per spawned vehicle) calls vehicle:requestReset(RESET_PHYSICS)
    --     directly - no core_input_actionFilter.isActionBlocked call anywhere in it. It CAN'T be
    --     targeted directly through this restriction system at all (there's no action name to
    --     block - the call is unconditional). It's only reachable at all while
    --     canModifyVehicles() (that same file) returns true, which itself checks
    --     switch_next_vehicle/switch_previous_vehicle - so blocking those two also disables this
    --     whole panel (Reset/Repair/Clone/Delete) as a side effect, which is the only lever this
    --     restriction system actually has over it. Since that tile's own reset is the same instant
    --     physics reset reset_physics is (not the gradual recovery recover_vehicle does), it needs
    --     to be unconditionally closed too, not just gated.
    --   - lua/ge/extensions/core/quickAccess.lua's own radial-menu "Go Home" entry
    --     (recovery.loadHome) IS gated by isActionBlocked, but under "loadHome" - never included
    --     here before, so a player could bookmark an arbitrary point (saveHome) and teleport back
    --     to it anytime, fully bypassing this restriction entirely.
    --   - that same file's own M.tryAction("recoverVehicle"/"resetVehicle") binding layer (used by
    --     some UI apps/buttons) ALSO checks isActionBlocked, but under those literal camelCase
    --     names - never the native underscored ones, so they were silently never covered either.
    --     Both resolve to in-place resets (spawn.safeTeleport to the vehicle's OWN current
    --     position, or resetGameplay(0)), same category as reset_physics, not recover_vehicle.
    if M.session.state == "COUNTDOWN" then
        -- Resetting/recovering during COUNTDOWN (frozen at the grid) is always blocked, same as
        -- races'/hunter's own COUNTDOWN block - recover_vehicle included, unlike during GAME below.
        restrictions:addAll({
            "recover_vehicle", "recover_vehicle_alt", "recover_to_last_road", "loadHome",
            "reset_physics", "reset_all_physics", "reload_vehicle", "recoverVehicle", "resetVehicle",
            "switch_next_vehicle", "switch_previous_vehicle",
        }, true)
    elseif M.session.state == "GAME" then
        -- recover_vehicle_alt/recover_to_last_road/loadHome all explicitly search for (or teleport
        -- a meaningful distance to) a different "safe" spot (confirmed by reading the installed
        -- game's own core/input/actions/gameplay.json) - unlike recover_vehicle itself (below),
        -- these stay unconditionally blocked. reset_physics/reset_all_physics/reload_vehicle (and
        -- their quickAccess-binding-layer equivalents recoverVehicle/resetVehicle) are an instant
        -- in-place physics/damage reset, no longer the allowed exception per direct request -
        -- blocked outright now too, alongside switch_next/previous_vehicle (the ESC-menu panel
        -- reasoning above).
        restrictions:addAll({
            "recover_vehicle_alt", "recover_to_last_road", "loadHome",
            "reset_physics", "reset_all_physics", "reload_vehicle", "recoverVehicle", "resetVehicle",
            "switch_next_vehicle", "switch_previous_vehicle",
        }, true)

        -- recover_vehicle itself is the one gated on speed and the post-use relock instead of
        -- blocked outright - a sustained hold-based recovery, not an instant teleport.
        if M.movingTooFastToReset or (M.resetRelockUntilMs and GetCurrentTimeMillis() < M.resetRelockUntilMs) then
            restrictions:addAll({ "recover_vehicle" }, true)
        end
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
    M.countdownDisplayOnly = false
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
    M.holdReleaseTargetMs = nil
    async.removeTask("BJInfectedReleaseFreeze")
    M.movingTooFastToReset = false
    M.resetRelockUntilMs = nil
    async.removeTask("BJInfectedResetRelock")
    M.nearbySurvivorVids = {}
    M.selfDiag = nil
    M.survivorDiagCache = {}
    M.taggedVids = {}
    M.myVehicleVid = nil
    restoreOriginalPaint()
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
        -- see infectedGrid.lua's own buildBasePayload comment: tryStartFromLobby silently refuses
        -- to start below this floor even once everyone is ready, so the UI needs it to know why
        minParticipants = session.minParticipants,
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
    -- Real bug: the GAME-start release-freeze delay had no HUD indicator at all, so a held
    -- participant (asymmetric release, see the GAME-start block's own comment) had no way to
    -- tell they were frozen ON PURPOSE rather than stuck/bugged. Spectator-only, no M.session:
    -- never held themselves, so no equivalent target to read.
    local holdSecondsLeft = M.holdReleaseTargetMs and
        math.max(0, math.ceil((M.holdReleaseTargetMs - GetCurrentTimeMillis()) / 1000)) or nil

    beamjoy_communications_ui.send("BJInfectedHud", {
        active = true,
        gameElapsedMs = elapsedMs,
        roundSecondsLeft = roundSecondsLeft,
        survivorsLeft = survivorsLeft,
        infectedCount = infectedCount,
        role = participant and participant.role or nil,
        tagCount = participant and participant.tagCount or nil,
        holdSecondsLeft = holdSecondsLeft,
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
    -- captured before M.session gets overwritten below, purely so applyRoleColor's mid-round
    -- survivor->infected repaint (see the GAME-state block further down) can tell "just got
    -- infected this update" apart from "already was infected, this is an unrelated push"
    local wasInfected = false
    if M.session then
        local prevSelf = getSelfParticipant()
        wasInfected = prevSelf ~= nil and prevSelf.role == "infected"
    end
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
            -- Real bug: this used to only ever run once GAME started, so a participant's role
            -- color (enableColors) stayed invisible for the entire COUNTDOWN even though roles
            -- are already committed and known by this point. Fresh per-round snapshot here (a
            -- leftover M.originalPaints from an earlier round, should never happen but cheap
            -- insurance) since this is now the real "first paint of the round" moment.
            M.originalPaints = nil
            applyRoleColor(participant.role)
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
        -- Asymmetric release, exactly mirroring hunterRunner.lua's own huntedStartDelay/
        -- huntersStartDelay treatment: both roles freeze at the exact GAME-start instant
        -- server-side, unfreezing locally after their own role's own delay (infected's built-in
        -- delay is the survivors' head start). A survivor tagged mid-round is never frozen at all;
        -- this block only ever runs once, at the real LOBBY/COUNTDOWN -> GAME transition.
        -- Survivors deliberately have NO configurable delay at all, per direct request (was
        -- previously defaulted to 0 but still host-configurable ; now hardcoded) - they always
        -- release the instant GAME starts, same as a survivor created mid-round by a tag.
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        local delaySec = math.max(0, participant.role == "infected" and session.settings.infectedStartDelay or 0)
        -- Per direct request, same mechanism as hunterRunner.lua's own: keep the countdown overlay
        -- ticking continuously through infectedStartDelay instead of vanishing at 0 and freezing
        -- again with no visible timer. delaySec == 0 (survivors, always) keeps the exact prior
        -- behavior: unlock immediately, no second phase.
        if delaySec > 0 then
            M.scenarioLocked = true
            M.countdownDisplayOnly = true
            M.countdownStartMs = GetCurrentTimeMillis()
            M.countdownTotal = delaySec
            M.lastSentSeconds = nil
        elseif M.scenarioLocked then
            unlockScenario()
            beamjoy_communications_ui.send("BJInfectedCountdown", { active = false })
        end
        if myVeh then
            beamjoy_vehicles.setFreeze(myVeh.vid, true)
        end
        M.holdReleaseTargetMs = GetCurrentTimeMillis() + delaySec * 1000
        async.delayTask(function()
            M.holdReleaseTargetMs = nil
            pushHud()
            local currVeh = beamjoy_vehicles.getCurrentOwn()
            if currVeh then beamjoy_vehicles.setFreeze(currVeh.vid, false) end
            -- ends the extended countdown display (if delaySec > 0 started one above) in the SAME
            -- tick as the actual unfreeze, so updateCountdown()'s own freeze-enforcement loop can
            -- never re-freeze on the very next frame
            if M.scenarioLocked then
                unlockScenario()
                beamjoy_communications_ui.send("BJInfectedCountdown", { active = false })
            end
            M.countdownDisplayOnly = false
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
        end, delaySec * 1000, "BJInfectedReleaseFreeze")
        M.gameStartTimeMs = GetCurrentTimeMillis()
        M.nearbySurvivorVids = {}
        M.selfDiag = nil
        M.survivorDiagCache = {}
        M.taggedVids = {}
        -- Color is applied at COUNTDOWN start now (see that block above), not here, so it's
        -- visible during the countdown rather than only once it ends. Only re-applied here as a
        -- fallback for a client that never saw this round's own COUNTDOWN at all (joining
        -- mid-round): M.originalPaints is still nil precisely because that block never ran for
        -- them. For the normal case (present since COUNTDOWN) this is a no-op - resetting
        -- M.originalPaints unconditionally here would otherwise re-snapshot the ALREADY-recolored
        -- vehicle as if it were "original", breaking the restore at round end.
        if not M.originalPaints then
            applyRoleColor(participant.role)
        end
        beamjoy_communications_ui.uiBroadcast("beamjoy.infected.gameStarted", nil, "green", 3)
    end

    -- mid-round survivor->infected repaint : the round-start block above already covers everyone
    -- ONCE, at the LOBBY/COUNTDOWN -> GAME transition, so this only needs to catch a participant
    -- whose role just changed while already in GAME (a successful tag against them)
    if session.state == "GAME" and wasGame and participant.role == "infected" and not wasInfected then
        applyRoleColor("infected")
        -- see updateTagDetection's own comment on the exact same call: the real, full-force
        -- collision this contact-based tag required (non-ghosted on purpose) can leave the
        -- camera visually detached on the tagged side too, so re-force a reattachment here as well
        camera.setCamera(camera.getCamera(), false)
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
            restoreOriginalPaint()
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
    -- see countdownDisplayOnly's own doc comment: this phase's freeze/unfreeze is driven entirely
    -- by the explicit calls around the GAME-transition block, not this loop, so it can't re-freeze
    -- the vehicle in the same window the delayed release is trying to let it go
    if not M.countdownDisplayOnly then
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh and myVeh.veh.froze ~= "1" then
            beamjoy_vehicles.setFreeze(myVeh.vid, true)
        end
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

--- Real bug, removed entirely per direct request (this feature was never wanted): the native-GPS
--- beacon to the sole remaining survivor used to live here, ported from BJI's own equivalent. It
--- was also the actual root cause of "camera goes stuck right at the end of the countdown as
--- infected" - core_groundMarkers.setPath(wp, options) (confirmed by reading the installed game's
--- own core/groundMarkers.lua) only ever accepts a navgraph node NAME (string), a {x,y,z} position
--- table, or an already-vec3 position, never a raw game vehicle ID, but this passed the survivor's
--- bare vid straight through. Native route-building code tried to treat that number as a position
--- and threw ("attempt to index local 'b' (a number value)", lua/common/mathlib.lua) from deep
--- inside a route/pathfinding call, called via extensions.hook's plain `func(...)` loop with no
--- pcall anywhere in the chain (confirmed by reading the installed game's own common/
--- extensions.lua). Confirmed from a real BeamNG.log capture that this left core_groundMarkers'
--- own internal route state permanently corrupted afterward: its own onPreRender hook
--- (generateRouteDecals) then threw on every single subsequent render frame for the rest of the
--- round, and since it sits earlier than this mod's own per-frame hook in that same dispatch list,
--- everything scheduled after it - including this mod's own onUpdate/onSlowUpdate cascade, which
--- native camera tracking effectively depends on working correctly - silently stopped running for
--- the whole rest of the round instead of just this one feature failing quietly.
--- Real bug: getCurrentOwn() (ultimately be:getPlayerVehicle(0)) can itself go nil for stretches
--- of gameplay unrelated to genuinely having no vehicle - the exact same native call a third-party
--- mod crashed on elsewhere this session, right around vehicle-attach transitions - which broke
--- tag detection outright for anyone caught in that window (most visibly: someone just converted
--- by a tag could never land one themselves afterward). M.myVehicleVid is BJS's own bookkeeping,
--- kept up to date independent of that native call (COUNTDOWN teleport-in, onBJVehicleInstantiated),
--- so falling back to it here keeps tag detection working even while the native query is stuck.
---@return BJVehicle?
local function myCurrentVehicle()
    return beamjoy_vehicles.getCurrentOwn() or (M.myVehicleVid and beamjoy_vehicles.getVehicle(M.myVehicleVid))
end

--- slow-tick coarse cull (BJI's own two-tier convention) : rebuilds the small nearby-survivor
--- candidate list a fast per-frame precise check can then afford to run against every tick. A no-op
--- (empty list) whenever the local player isn't currently an infected participant in an active GAME.
local function refreshTagCandidates()
    M.nearbySurvivorVids = {}
    if not M.session or M.session.state ~= "GAME" then return end
    local participant = getSelfParticipant()
    if not participant or participant.role ~= "infected" then return end
    local myVeh = myCurrentVehicle()
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
    local myVeh = myCurrentVehicle()
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
                    -- Real bug, root cause: tagging requires actual contact, and players are
                    -- deliberately non-ghosted for exactly that reason (see setGhostReason's own
                    -- comments elsewhere in this file), so a successful tag always coincides with
                    -- a real, full-force BeamNG vehicle-vehicle collision against a network-synced
                    -- remote vehicle. That collision can leave the camera visually detached from
                    -- the vehicle on BOTH sides of the hit - fully drivable, camera mode/name
                    -- unchanged, but the rendered view stops tracking it. Re-issuing the current
                    -- camera mode forces a real reattachment (core_camera.setByName re-binds the
                    -- camera to the vehicle) rather than just resetCamera()'s rotation-only recenter,
                    -- which is why this uses setCamera instead. Fired here (the tagger) and in the
                    -- mid-round repaint block below (the tagged), since both sides of the same
                    -- collision are affected.
                    camera.setCamera(camera.getCamera(), false)
                end
            end
        end
    end
end

--- Real gap, per direct request: this file never had an onVehicleResetted hook at all before.
--- Two separate real gaps fixed here, both only reachable via a mid-round reset (see
--- onBJRequestRestrictions' own GAME-state block for the speed gate itself, checked live rather
--- than here since it needs to hold BEFORE a reset is even allowed, not just react after one):
--- 1) "ghosting needs to be fully disabled for infected" - a mid-round reset/recover is also the
---    moment vehicles.lua's own generic Freeroam respawn-ghost protection (applyRespawnProtection,
---    host-configurable duration) gets re-applied, and with no hook here to strip it back off, a
---    reset genuinely left a participant non-collidable (breaking contact-based tagging) for
---    however long that's configured. Same fix, same reasoning as hunterRunner.lua's own
---    identical treatment; vehicles.lua's own onVehicleResetted (which applies the generic
---    protection) runs first, ahead of this one, per main.lua's dependency load order.
--- 2) a customizable relock after any reset actually happens, on top of (not instead of) the
---    speed gate, matching BJI's own resetLock convention (there: a fixed, non-configurable 1s
---    window after every reset ; here: host-configurable, 0 to disable).
---@param vid integer
local function onVehicleResetted(vid)
    if not M.session or M.session.state ~= "GAME" then return end
    local participant = getSelfParticipant()
    if not participant then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh or myVeh.vid ~= vid then return end

    beamjoy_vehicles.setGhostReason(vid, "respawn", false)

    local relockSec = M.session.settings.resetRelockSeconds or 0
    async.removeTask("BJInfectedResetRelock")
    if relockSec > 0 then
        M.resetRelockUntilMs = GetCurrentTimeMillis() + relockSec * 1000
        extensions.beamjoy_restrictions.update()
        async.delayTask(function()
            extensions.beamjoy_restrictions.update()
        end, relockSec * 1000, "BJInfectedResetRelock")
    end
end

local function onBJVehicleInstantiated(vid)
    if not M.session then return end
    local participant = getSelfParticipant()
    if not participant then return end
    local mpVeh = beamjoy_vehicles.getVehicle(vid, true)
    if not mpVeh or not mpVeh.isLocal then return end

    if M.session.state == "GAME" then
        -- a genuinely new vehicle object appeared mid-round (reload_vehicle, or any other full
        -- respawn) : ordinary reset/recover keeps the same object, so the live NGPaint override
        -- applyRoleColor already applied survives those fine on its own and never reaches this
        -- hook at all - onVehicleResetted above only ever fires for an ordinary in-place reset,
        -- the same object surviving intact. A real respawn is different, it's a brand new object
        -- with none of that override, and no snapshot of ITS own default color either, so both
        -- need redoing from scratch, same as a fresh round start.
        M.myVehicleVid = vid
        M.originalPaints = nil
        applyRoleColor(participant.role)
        -- Real bug: a fresh vehicle object mid-round (this same respawn) can leave the camera
        -- pointed at the old, now-destroyed one, which BeamNG falls back to FREE cam for - and
        -- since nothing else re-targets the camera at the NEW object afterward, cycling cameras
        -- manually never reaches a working one either. blockCameras both re-disallows FREE and,
        -- per its own implementation, immediately kicks out of it if it's already active.
        camera.blockCameras(table.unpack(gameBlockedCameras()))
        camera.resetCamera()
        return
    end
    if M.session.state ~= "COUNTDOWN" then return end

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

--- Real gap, per direct request: resetting used to have no speed gate at all. Checked every frame
--- (not just on the discrete events restrictions.lua's own update() normally reacts to, since
--- speed changes continuously), but only actually recomputes restrictions when the gate's own
--- state changes, not every frame - matching the community "Outbreak" mod's own identical
--- "only touch the action filter on an actual isStopped flip" approach in its own onPreRender.
local function updateResetGate()
    if not M.session or M.session.state ~= "GAME" then
        if M.movingTooFastToReset then
            M.movingTooFastToReset = false
        end
        return
    end
    local myVeh = myCurrentVehicle()
    local tooFast = myVeh ~= nil and myVeh.veh:getVelocity():length() > RESET_MAX_SPEED or false
    if tooFast ~= M.movingTooFastToReset then
        M.movingTooFastToReset = tooFast
        extensions.beamjoy_restrictions.update()
    end
end

local function onUpdate()
    if M.scenarioLocked then
        updateCountdown()
    end
    updateTagDetection()
    updateResetGate()
end

local function onSlowUpdate()
    updateGridCountdown()
    refreshTagCandidates()
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
M.onVehicleResetted = onVehicleResetted

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
M.isHiddenInfectedVehicle = isHiddenInfectedVehicle
M.isGameLocked = isGameLocked

return M
