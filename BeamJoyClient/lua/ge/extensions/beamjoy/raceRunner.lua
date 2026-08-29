--- Live race-attempt runtime : receives session state from `services/raceGrid.lua`, detects gate
--- crossings for the local player's vehicle, and reports progress back to the server. The server
--- is authoritative on session/leaderboard state; this module is authoritative on the actual
--- checkpoint geometry/timing, same trust model BeamJoy Free and BJRally both already use.
---
--- Console entry points for testing ahead of any UI : `beamjoy_raceRunner.startRace(raceId)`,
--- `beamjoy_raceRunner.ready()`, `beamjoy_raceRunner.leave()`, `beamjoy_raceRunner.retire()`.
---
--- Camera-lock/vehicle-freeze scenario UX (BJI convention) : on entering `COUNTDOWN`, the local
--- vehicle is frozen (`beamjoy_vehicles.setFreeze`) and the camera forced to `EXTERNAL`
--- (`camera.forceCamera`/`stopForcedCameras`: an existing, reusable, non-race-specific primitive
--- this fork already had, previously unused) via the also-existing-but-previously-never-fired
--- `onBJScenarioChanged` hook (`restrictions.lua` already listens for it). Camera control is
--- handed back to the player once ≤3s remain (BJI's exact timing), while the vehicle stays frozen
--- until the actual green light. The countdown number itself is pushed to a new Angular
--- component (`BJRaceCountdown` event) rather than drawn in world-space, per direct instruction.
---
--- Leaderboard/HUD : pushed via a new `BJRaceHud` event during `RACE` state only. The server has
--- been computing a sorted `session.leaderboard` since the earlier grid-logic slice, nothing ever
--- displayed it until now. Own progress (lap/gate/live timer) always shows; the comparison table
--- only appears once there's more than one participant, matching the "solo is a private attempt"
--- design: nothing to compare against alone.

local CAMERA_RELEASE_SECONDS = 3
local DNF_WARNING_SECONDS = 10
local FINISH_POPUP_SECONDS = 8 -- was 4 ; reported as disappearing too fast to actually read

local M = {
    dependencies = { "beamjoy_races", "beamjoy_vehicles", "beamjoy_players", "camera" },

    ---@type BJRaceSession?
    session = nil,
    raceStartTimeMs = nil,
    ---@type integer? local GetCurrentTimeMillis()-domain virtual timestamp for when the lobby's
    ---gridReadyTimeout floor elapses (see onSessionUpdate's own re-anchoring comment)
    gridReadyTargetMs = nil,
    ---@type integer? same as gridReadyTargetMs, for the lobby's hard gridTimeout deadline
    gridTimeoutTargetMs = nil,
    ---@type table<integer, number> gate index -> last frame's signed distance along the gate's dir
    lastLy = {},
    lastProgressPos = nil,
    lastProgressCheckMs = nil,
    ---@type integer? last whole-second value warned about, throttles the DNF countdown ping
    lastDnfWarningSecond = nil,
    ---@type integer? vid of the local player's own current session vehicle, seeded at the RACE
    ---transition (see onBJVehicleInstantiated/onVehicleDestroyed below for why this matters)
    ---(closing the "delete/replace your vehicle to dodge respawnStrategy" gap)
    myVehicleVid = nil,

    -- scenario-lock (countdown) state
    scenarioLocked = false,
    countdownStartMs = nil,
    countdownTotal = nil,
    lastSentSeconds = nil,
    cameraReleased = false,
    ---@type string? camera mode the player was on before it got forced to EXTERNAL, restored on
    ---release. stopForcedCameras() alone only stops the switch-away *enforcement*, it never
    ---actually changes the camera to anything, so nothing restores the player's own camera
    ---without this
    previousCamera = nil,

    ---@type integer? last GetCurrentTimeMillis() the HUD was pushed at, throttles ticks to ~20/sec
    ---(50ms) rather than every render frame: fine enough for a smoothly-updating hundredths-place
    ---timer without spamming the UI bridge at full framerate
    lastHudPushMs = nil,

    ---@type integer? local GetCurrentTimeMillis() timestamp the reset penalty (opt-in, matching
    ---Hunter's own crash-reset penalty) currently frozen-until, nil when not being served. Purely
    ---client-side, no server round-trip, same as Hunter's own version.
    resetPenaltyLockedUntilMs = nil,

    ---@type {model: string, parts: table, vars: table?, paints: table?}? captured by
    ---saveCurrentVehicleForRespawn() right before a DNF/auto-spectate-on-finish deletes the
    ---player's own vehicle, consumed by restoreSavedVehicle() once the race is actually over
    savedVehicleConfig = nil,

    ---@type table? the last "active=true" payload pushRaceInfo sent, kept around so a freshly
    ---(re)mounted race-info tab/panel (which always re-requests on its own $onInit, since bj-tabs
    ---destroys/recreates tab content on every switch) still has something to show after the
    ---session is fully torn down (M.session goes nil, see onSessionRemoved) instead of coming back
    ---empty just because it wasn't already mounted when the last real push happened. Cleared only
    ---when a genuinely new race begins (GRID/COUNTDOWN), not by teardown itself.
    lastRaceInfoPayload = nil,

    ---@type integer? the vid of another racer's vehicle this client is currently spectating via
    ---spectateAnotherRacer (own DNF/auto-spectate-on-finish), so onVehicleDestroyed below can tell
    ---"the vehicle I'm camera-attached to just vanished" apart from any other vehicle despawning
    ---anywhere else in the world. nil whenever not spectating another racer (in own car, in free
    ---cam with nobody to watch, or not in a session at all).
    spectatingVID = nil,
    ---@type string? the playerName paired with spectatingVID above. A plain Leave (as opposed to
    ---DNF/finish) never deletes the leaving player's vehicle, so onVehicleDestroyed has nothing to
    ---react to in that case ; onSessionUpdate uses this name to independently notice "the racer I'm
    ---watching isn't a participant anymore" and re-target, regardless of whether their vehicle
    ---itself ever goes away.
    spectatingPlayerName = nil,

    ---@type BJRaceSession? a session being watched as a pure non-participant (raceSpectate/
    ---raceStopSpectate), entirely separate from M.session: the server won't let a player be both
    ---at once (see raceGrid.lua's own raceSpectate). pushHud/pushRaceInfo fall back to this
    ---whenever M.session is nil, so the same HUD/info-panel components work identically whether
    ---the data came from actually racing or from spectating ; spectatingVID/spectatingPlayerName
    ---above are reused as-is for camera-follow, since spectateAnotherRacer already behaves
    ---correctly for a non-participant (their own name never matches anyone in the session).
    spectatingSession = nil,
    ---@type integer? a local GetCurrentTimeMillis()-domain virtual race-start instant, re-derived
    ---on every raceSpectateUpdate from the server's own raceElapsedMs duration (see
    ---buildSessionPayload server-side) rather than snapshotted once at "started watching", so it
    ---stays accurate even for a spectator who joins mid-race, unlike a plain first-observed timestamp.
    spectatingRaceStartTimeMs = nil,
    ---@type integer? the vid of the player's own vehicle at the moment spectateSession() was
    ---called, so onSpectateRemoved can put the camera back in it (be:enterVehicle via focusVehicle)
    ---instead of dropping the player into free cam. Pure spectating never deletes or replaces the
    ---player's own vehicle, it only moves the camera away from it, so this is always still there to
    ---return to unless the vehicle itself was despawned/reset away in the meantime.
    preSpectateOwnVID = nil,
}

local function onInit()
    beamjoy_communications.addHandler("raceSessionUpdate", M.onSessionUpdate)
    beamjoy_communications.addHandler("raceSessionsList", M.onSessionsList)
    beamjoy_communications.addHandler("raceSessionRemoved", M.onSessionRemoved)
    beamjoy_communications.addHandler("raceSpectateUpdate", M.onSpectateUpdate)
    beamjoy_communications.addHandler("raceSpectateRemoved", M.onSpectateRemoved)

    -- UI entry points for the race browser (windows/main/races/). The console functions
    -- (beamjoy_raceRunner.startRace/joinRace/ready/leave/cancel) stay as-is, this just gives
    -- Angular the same calls over the usual communications_ui bridge
    beamjoy_communications_ui.addHandler("BJRaceStart", M.startRace)
    beamjoy_communications_ui.addHandler("BJRaceJoin", M.joinRace)
    beamjoy_communications_ui.addHandler("BJRaceReady", M.ready)
    beamjoy_communications_ui.addHandler("BJRaceLeave", M.leave)
    beamjoy_communications_ui.addHandler("BJRaceCancel", M.cancel)
    beamjoy_communications_ui.addHandler("BJRaceRetire", M.retire)
    beamjoy_communications_ui.addHandler("BJRaceSpectate", M.spectateSession)
    beamjoy_communications_ui.addHandler("BJRaceStopSpectate", M.stopSpectating)
    -- the race-info panel's tab components each mount fresh (bj-tabs only ever compiles the
    -- active tab's template, destroying/recreating on switch, see cmps/tabs/app.html), so a
    -- freshly-mounted tab has missed every BJRaceInfo broadcast that happened before it existed.
    -- Requests an immediate re-push on mount instead of waiting for the next organic session
    -- update, same pattern this codebase already uses elsewhere (e.g. BJRequestConfigData).
    beamjoy_communications_ui.addHandler("BJRaceInfoRequest", M.pushRaceInfo)
    -- same remount problem as BJRaceInfoRequest above, for the main window's "you're in a
    -- session" lobby status panel : bjMainRaces (windows/main/races/) is itself a bj-tabs tab, so
    -- switching away from and back to the Races tab destroys/recreates it, and pushSessionStatus
    -- is only ever sent reactively on an actual session update. With nothing else happening in
    -- the lobby in the meantime, the freshly-remounted component had no way to learn it was still
    -- in a session at all, and looked like it had silently left.
    beamjoy_communications_ui.addHandler("BJRaceSessionStatusRequest", M.pushSessionStatus)
    beamjoy_communications_ui.addHandler("BJRaceOpenSessionsRequest", M.pushOpenSessions)
    beamjoy_communications_ui.addHandler("BJRaceSpectateStatusRequest", M.pushSpectateStatus)
    beamjoy_communications_ui.addHandler("BJRaceCountdownRequest", M.pushCountdown)
    -- streamlined in-lobby paint picker, for single-config/pool vehicle-restricted races. Purely
    -- cosmetic (paint is never compared by vehicleMatchesRestriction), so this never needs to
    -- coordinate with the session/server at all, just the local vehicle
    beamjoy_communications_ui.addHandler("BJRacePaintOptionsRequest", M.pushPaintOptions)
    beamjoy_communications_ui.addHandler("BJRaceSetPaint", M.setPaint)
end

---@return BJRaceParticipant?
local function getSelfParticipant()
    if not M.session then return nil end
    local selfName = MPConfig.getNickname()
    return table.find(M.session.participants, function(p) return p.playerName == selfName end)
end

---@param session BJRaceSession?
---@return BJRace?
local function getRaceForSession(session)
    if not session then return nil end
    return table.find(beamjoy_races.data, function(r) return r.id == session.raceId end)
end

--- mirrors raceGrid.lua's own sectorEndGates COUNT (not the boundary gates themselves):
--- actual per-sector times are already computed server-side and just synced down keyed 1..N) so
--- the info panel iterates the same number of S1..SN columns the server actually populated,
--- whether that count came from the automatic distance split or manually-flagged gates.
---@param race BJRace
---@return integer
local function computeSectorCount(race)
    -- sectors are disabled outright for a branching race (see races.lua's own
    -- BJRace.branchingEnabled doc), mirroring raceGrid.lua's sectorEndGates own branching
    -- short-circuit so this stays consistent with what the server actually populated. Real,
    -- confirmed bug fixed here : this used to return 1 (a degenerate "single sector"), which the
    -- HUD's own `totalSectors > 1` guard already treats as "don't show sector info", but the
    -- race-info Results panel has no equivalent guard at all, so a sectorCount of 1 still built a
    -- real (if meaningless) "S1" column and a "Theoretical" time equal to the whole lap. Returning
    -- 0 instead means "no sectors at all" unambiguously everywhere it's read, not just in the one
    -- place that happened to already special-case the degenerate 1-sector value.
    if race.branchingEnabled then return 0 end
    if race.manualSectors then
        local flagged = 0
        for i, g in ipairs(race.gates) do
            if g.sector and i < #race.gates then flagged = flagged + 1 end
        end
        if flagged > 0 then return flagged + 1 end
    end
    return math.max(1, math.min(race.sectorCount or 3, #race.gates))
end

---@return BJRace?
local function getRace()
    return getRaceForSession(M.session)
end

--- client-side mirror of raceGrid.lua's own totalSteps: identical to #race.gates for any
--- non-branching race, but the correct non-inflated progress-unit count for a branching one, where
--- the gate array also holds parallel alternates that were never part of any single run
---@param race BJRace
---@return integer
local function totalSteps(race)
    local total = 0
    for _, g in ipairs(race.gates) do
        if (g.step or 0) > total then total = g.step end
    end
    return total
end

--- true from the moment a participant is frozen at their start position (COUNTDOWN) through the
--- actual race (RACE): whenever race-integrity restrictions (nodegrabber, walking away,
--- disallowed cameras) ought to apply. Exists specifically so that class of check has ONE place to
--- read from instead of each one separately hardcoding `state == "RACE"` : that's exactly how the
--- nodegrabber/camera restrictions originally shipped RACE-only and had to be patched afterward to
--- also cover COUNTDOWN, once it turned out the vehicle being frozen doesn't stop native camera/
--- tool inputs from still being live. Deliberately NOT used for gameplay mechanics that genuinely
--- only make sense once actually racing (gate-crossing, DNF-stall, respawn-strategy enforcement).
--- Those stay RACE-only on purpose, nothing to fix there.
---@return boolean
local function isRaceLocked()
    return M.session ~= nil and (M.session.state == "COUNTDOWN" or M.session.state == "RACE")
end

--- cameras a participant shouldn't be able to reach while race-locked (see isRaceLocked above) :
--- Big Map always, plus Free/Cinematic/Steadycam under the "Disable Free Cam" option (default on).
--- Shared by both the COUNTDOWN freeze (on top of its own stricter forceCamera(EXTERNAL) allowlist,
--- belt-and-suspenders in case that ever fails to escape a global camera cleanly) and the RACE
--- transition, so there's exactly one place that ever needs to change if this set does.
---@return string[]
local function raceBlockedCameras()
    local list = { camera.CAMERAS.BIG_MAP }
    if M.session and M.session.settings.disableCameras then
        table.insert(list, camera.CAMERAS.FREE)
        table.insert(list, camera.CAMERAS.CINEMATIC)
        table.insert(list, camera.CAMERAS.STEADYCAM)
    end
    return list
end

--- focuses the camera on another still-active racer's vehicle after this player's own is deleted
--- on DNF, instead of leaving them alone in free cam with nothing to look at. Reuses
--- beamjoy_vehicles.focusVehicle (the same "Spectate" primitive already used by the player-list
--- action and context menu) rather than building new camera-attach code.
---@param session BJRaceSession
---@return boolean found true if another racer's vehicle was actually found and focused
local function spectateAnotherRacer(session)
    local selfName = MPConfig.getNickname()
    local target = table.find(session.participants, function(p)
        return p.playerName ~= selfName and not p.finished and not p.dnf
    end)
    if not target then return false end

    local targetPlayer = beamjoy_players.players[target.playerName]
    local remoteVID = targetPlayer and targetPlayer.currentVehicle
    if not remoteVID then return false end
    local mpVeh = beamjoy_vehicles.vehicles:find(function(v) return v.remoteVID == remoteVID end)
    if not mpVeh then return false end

    beamjoy_vehicles.focusVehicle(mpVeh.vid)
    M.spectatingVID = mpVeh.vid
    M.spectatingPlayerName = target.playerName
    return true
end

--- the racer being spectated (see spectateAnotherRacer above) can themselves finish/DNF at any
--- moment, which deletes THEIR vehicle on their own client and replicates as a normal vehicle
--- despawn everywhere else, including here, where this client is currently `be:enterVehicle`'d
--- into it. BeamNG doesn't handle losing the vehicle you're actually "in" gracefully (the reported
--- softlock spectating the last other racer left to DNF/finish), so this reacts immediately : if
--- the vehicle that just got destroyed is the one being spectated, re-target another still-active
--- racer, or fall back to free cam if nobody's left, exactly spectateAnotherRacer's own fallback,
--- just re-triggered reactively instead of only at the moment of this player's own finish/DNF.
---@param vid integer
local function onVehicleDestroyed(vid)
    -- real gap closed here : deleting your own vehicle mid-race (the selector's "Remove" button,
    -- console, etc.) bypasses respawnStrategy's own reset/recover enforcement just as much as
    -- replacing it does (see onBJVehicleInstantiated below). Neither is a native "reset" event,
    -- so onBJRequestCurrentVehicleReset/onVehicleResetted above never see it at all. "all" (free
    -- respawn) has nothing to bypass, so it's exempted ; an already-finished/dnf'd participant is
    -- also exempt, same as every other race restriction in this file.
    if M.myVehicleVid == vid then
        M.myVehicleVid = nil
        if M.session and M.session.state == "RACE" and M.session.settings.respawnStrategy ~= "all" then
            local participant = getSelfParticipant()
            if participant and not participant.finished and not participant.dnf then
                beamjoy_communications.send("raceDNF", M.session.id)
            end
        end
    end

    if not M.spectatingVID or M.spectatingVID ~= vid then return end
    M.spectatingVID = nil
    M.spectatingPlayerName = nil
    -- applies just as much to pure non-participant spectating (M.spectatingSession) as to
    -- watching a fellow participant after this player's own DNF/finish (M.session). The vehicle
    -- disappearing out from under the camera doesn't care which reason put it there
    local session = M.session or M.spectatingSession
    if not (session and spectateAnotherRacer(session)) then
        camera.setCamera(camera.CAMERAS.FREE)
    end
end

--- real gap closed here : the enforcement above only ever reacts to a NATIVE reset event. A
--- player could otherwise sidestep "lastcheckpoint"/"norespawn" entirely by picking a
--- DIFFERENT vehicle mid-race via the selector's own "Replace" action (or a delete-then-respawn,
--- see onVehicleDestroyed above), neither of which BeamNG considers a "reset" at all. Mirrors
--- hunterRunner.lua's own identical fix for the fugitive : any vehicle appearing for this client
--- during an active RACE that ISN'T the one tracked at the race's own start is treated as a
--- forfeit (auto-DNF), reusing the exact same raceDNF self-report path stall-timeout DNF already
--- uses. "all" (free respawn) has nothing to bypass, so it's exempted.
---@param vid integer
local function onBJVehicleInstantiated(vid)
    -- real, confirmed bug: the paint picker's own swatch list (see currentPaintOptions/
    -- pushPaintOptions below) only ever requested itself once, when the picker's own Angular
    -- component first mounted. A "pool" racer legitimately switching between pool entries via the
    -- native selector before readying up (allowed: onBJRequestCanSpawnVehicle authorizes any
    -- model/config that's a member of the pool, not just whichever one they first spawned into)
    -- left the picker showing swatches for whatever model they USED to have, not the one they
    -- actually have now. Clicking one of those stale swatches wasn't dangerous (setPaint's own key
    -- lookup is always against the CURRENT vehicle's real paint list, so a stale key just silently
    -- misses) but it was broken/confusing UX with zero feedback. Re-pushing here, scoped to GRID
    -- (the only state the picker's ever shown in) and the player's own vehicle specifically, keeps
    -- the swatch list honest across any mid-lobby vehicle change, pool or otherwise.
    if M.session and M.session.state == "GRID" then
        local instantiatedVeh = beamjoy_vehicles.getVehicle(vid, true)
        if instantiatedVeh and instantiatedVeh.isLocal then
            M.pushPaintOptions()
        end
    end

    if not M.session or M.session.state ~= "RACE" then return end
    local mpVeh = beamjoy_vehicles.getVehicle(vid, true)
    if not mpVeh or not mpVeh.isLocal then return end
    if M.myVehicleVid == nil then
        -- nothing tracked yet this race (shouldn't normally happen: the race transition itself
        -- seeds this from whatever vehicle already existed, but never penalize a first sighting)
        M.myVehicleVid = vid
        return
    end
    if vid == M.myVehicleVid then return end
    M.myVehicleVid = vid
    if M.session.settings.respawnStrategy == "all" then return end
    local participant = getSelfParticipant()
    if not participant or participant.finished or participant.dnf then return end
    beamjoy_communications.send("raceDNF", M.session.id)
end

--- captures the local player's currently-driven vehicle's exact model/parts/paint (the same
--- data the mod's own "clone vehicle" action already reads via getFullConfig) right before a
--- DNF or auto-spectate-on-finish transition deletes it, so restoreSavedVehicle() below can
--- give the player back the actual car they were driving once the race is genuinely over,
--- instead of losing it permanently the moment their own attempt ends.
local function saveCurrentVehicleForRespawn()
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return end
    local fullConfig = beamjoy_vehicles.getFullConfig(myVeh.veh)
    if not fullConfig then return end
    M.savedVehicleConfig = {
        model = fullConfig.model,
        parts = fullConfig.parts,
        vars = fullConfig.vars,
        paints = fullConfig.paints,
    }
end

--- respawns whatever saveCurrentVehicleForRespawn() last captured, at wherever the player is
--- currently spectating from (the vehicle they're focused on, or the free camera position if
--- nobody was left to spectate). No-op if nothing was ever saved this session. Deliberately
--- called once the race is actually over (session removed, or the player leaves/gets kicked
--- while still spectating) rather than immediately at the finish/DNF moment, so it doesn't fight
--- the moment-of-finish spectate camera or the "Finished"/"DNF" popup.
local function restoreSavedVehicle()
    local saved = M.savedVehicleConfig
    if not saved then return end
    M.savedVehicleConfig = nil

    local pos
    local currVeh = beamjoy_vehicles.getCurrent()
    if currVeh and camera.getCamera() ~= camera.CAMERAS.FREE then
        pos = beamjoy_vehicles.getVehiclePositionRotation(currVeh.veh)
    else
        pos = camera.getPositionRotation(false)
    end

    -- goes through the mod's own core_vehicles.spawnNewVehicle wrapper (vehicleSelector.lua),
    -- not the raw native function, same spawn-permission path any normal vehicle spawn already
    -- goes through, rather than a special-cased bypass
    --
    -- `vars`/`paints` from getFullConfig can legitimately be nil for a normal vehicle with no
    -- runtime tuning set. The game's spawn code unconditionally iterates them, throwing "bad
    -- argument #1 to 'ipairs' (table expected, got nil)" and aborting the spawn if they're nil,
    -- which is why a DNF'd/finished participant's car never came back. Defaulted to empty tables
    -- here so the spawn call always gets a real, iterable value.
    --
    -- Format 4 is not a plain single-vehicle .pc shape. It's the game's multi-vehicle config
    -- wrapper (core/vehicles.lua's prepareMultiVehConfig routes format==4 into
    -- spawnMultipleVehicles, which iterates a top-level `vehicles` array this table never had,
    -- the actual source of the same ipairs crash). A real single-vehicle .pc file uses format 2.
    --
    -- Real crash: both call sites run synchronously inside a network-message handler (session
    -- removed / leave-while-spectating), which itself runs mid-onUpdate. A user-supplied log
    -- showed a native engine crash (FATAL, not a catchable Lua error) inside
    -- finishConstructionGESide right as this spawn's C callback landed, immediately after another
    -- player's vehicle had just been destroyed (a large mesh-cache rebuild for the newly-spawned
    -- model's parts was still in flight in the same log window). Matches the exact "let the engine
    -- settle first" issue class already found and fixed elsewhere in this file (see the
    -- lastCheckpointTarget reset-teleport below): triggering another native vehicle op while the
    -- engine is still mid-way through processing a prior one can crash it outright, not just error.
    -- Deferring the actual spawn by one short async tick, same pattern already used for that
    -- teleport, gives the engine a chance to finish whatever it was doing first. pos/currVeh are
    -- still captured synchronously above, matching "wherever the player currently is" at the
    -- moment the restore was triggered.
    async.delayTask(function()
        local newVeh = core_vehicles.spawnNewVehicle(saved.model, {
            pos = pos,
            config = {
                format = 2,
                model = saved.model,
                parts = saved.parts or {},
                vars = saved.vars or {},
                paints = saved.paints or {},
            },
        })
        if newVeh then
            be:enterVehicle(0, newVeh)
            if camera.getCamera() == camera.CAMERAS.FREE then
                camera.toggleFreeCam()
            end
        end
    end, 100, "BJRaceRestoreSavedVehicle")
end

--- Blocks native BeamNG inputs that would otherwise let an active participant sidestep the race
--- entirely: "get out and walk" always, plus (when respawnStrategy is norespawn specifically)
--- resetting/recovering/rewinding (BeamNG's native recover-vehicle feature previews as a
--- "rewind"), which used to leave a norespawn crash with no real consequence. Routed through the
--- existing generic restriction system (`restrictions.lua`'s `onBJRequestRestrictions`, already
--- refreshed automatically on `onBJScenarioChanged`, which this module already fires at every
--- race state transition) rather than building a separate input-blocking mechanism.
---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    -- camera/control is currently attached to ANOTHER player's vehicle (spectateAnotherRacer,
    -- either after this player's own DNF/finish or pure non-participant spectating via the Races
    -- tab). BeamNG's native reset/recover/reload inputs act on whatever vehicle
    -- be:getPlayerVehicle(0) currently is, with zero regard for ownership, so left unblocked here
    -- they'd let a spectator reset, recover (BeamNG's own "rewind"), or reload the car out from
    -- under whoever's actually driving it. Checked independently of isRaceLocked()/the rest of
    -- this function below. Spectating isn't limited to COUNTDOWN/RACE either (a finished/DNF'd
    -- participant watching the rest of their own race play out counts too).
    if M.spectatingVID then
        restrictions:addAll({
            "recover_vehicle", "recover_vehicle_alt", "recover_to_last_road",
            "reset_physics", "reset_all_physics", "reload_vehicle",
        }, true)
    end

    -- isRaceLocked (COUNTDOWN or RACE), not a bare state=="RACE" check : walking away or grabbing
    -- nodes is just as much a way to sidestep the race during the frozen countdown as during the
    -- race itself: being frozen only stops the vehicle from moving, not these inputs.
    if not isRaceLocked() then return end
    local participant = getSelfParticipant()
    if not participant or participant.finished or participant.dnf then return end

    -- BeamNG's native "get out and walk" (action id confirmed via the game's own gameplay.json)
    -- trivially breaks an active attempt regardless of respawn strategy. Gate-crossing tracks
    -- the vehicle, not the player, so walking away sidesteps DNF/stall detection entirely and
    -- leaves the vehicle just sitting there. Unlike the recover/reset block below, this isn't
    -- specific to norespawn.
    --
    -- "dropPlayerAtCamera"/"dropPlayerAtCameraNoReset" (default keybind F7, confirmed via the
    -- installed game's own settings/inputmaps/keyboard.json, not guessed) are BeamNG's native
    -- "teleport my vehicle to wherever the free camera currently is" actions, a real, direct
    -- teleport completely independent of both this mod's own player-to-player Teleport To/From
    -- feature (players.lua's tryTeleportToPlayer, which only ever touches THAT specific code
    -- path) and the Big Map block (raceBlockedCameras only stops the CAMERA itself from reaching
    -- Big Map, it was never going to touch this: a totally different action, nothing to do with
    -- Big Map at all). Neither previous teleport fix could ever have caught this. Same
    -- unconditional-regardless-of-respawn-strategy treatment as walking away above, since flying
    -- the free camera ahead and dropping the car there is just as trivial a way to skip real track
    -- progress.
    restrictions:addAll({ "toggleWalkingMode", "dropPlayerAtCamera", "dropPlayerAtCameraNoReset" }, true)

    -- host-configurable, default on (see races.lua's sanitizeRace/raceGrid.lua's buildSettings) :
    -- the node grabber (BeamNG's Ctrl-hold-and-click ragdoll/node-pull tool) can strand a player on
    -- the Cinematic/Steadycam global cameras, which aren't part of the normal vehicle camera ring,
    -- see raceBlockedCameras/its call sites for why that's a real problem specifically while Free
    -- Cam is already blocked. Blocking the whole nodegrabber action template (every name BeamNG
    -- itself groups under it, confirmed via the installed game's own actionFilter.lua
    -- actionTemplates, not guessed) prevents the situation outright rather than only mitigating its
    -- symptom.
    if M.session.settings.disableNodegrabber then
        restrictions:addAll({
            "nodegrabberAction", "nodegrabberGrab", "nodegrabberRender",
            "nodegrabberStrength", "nodegrabberPadGrab", "nodegrabberPadMode",
        }, true)
    end

    -- always on, not host-configurable (removed the toggle entirely: slow-motion/pausing during a
    -- race is never legitimate, so there's nothing to opt out of) : BeamNG's native slow-motion
    -- keybinds (confirmed action ids via the installed game's own core/input/actions/
    -- slowmotion.json, not guessed) let a participant locally slow the simulation down during their
    -- own attempt: real reaction-time/precision-jump advantage a race time shouldn't be allowed to
    -- benefit from. "pause" (confirmed via core/input/actions/general.json : onDown =
    -- simTimeAuthority.togglePause(true)) is the same underlying mechanism taken to its extreme (0x
    -- instead of merely <1x) and blocked here too. Belt-and-suspenders only: both are also
    -- actively reasserted every frame below (onUpdate), since the Environment settings panel's
    -- Simulation Speed slider reaches the exact same simTimeAuthority calls without going through
    -- this action filter at all.
    restrictions:addAll({ "toggle_slow_motion", "slower_motion", "faster_motion", "pause" }, true)

    -- resetting/recovering (BeamNG's own "rewind to last safe position" / reset inputs) only
    -- actually matters as a norespawn-specific concern once there's real race progress to protect
    -- during RACE itself: other respawn strategies deliberately allow it there. COUNTDOWN is a
    -- separate, unconditional case regardless of strategy though, per direct request : the
    -- vehicle is frozen at its grid slot during COUNTDOWN specifically so every participant starts
    -- from the same synchronized position, and "recover" can rewind it to wherever it was standing
    -- right before the freeze, potentially a completely different spot, undermining that the
    -- same way dropPlayerAtCamera/walking away do, just via a different native action.
    if M.session.state == "COUNTDOWN" or
        (M.session.state == "RACE" and M.session.settings.respawnStrategy == "norespawn") then
        restrictions:addAll({
            "recover_vehicle", "recover_vehicle_alt", "recover_to_last_road",
            "reset_physics", "reset_all_physics", "reload_vehicle",
        }, true)
    end
end

--- a normalized restriction descriptor, regardless of WHERE it actually came from: the race's own
--- editor-authored capture (session.settings.vehicleRestrictionStartMode == "raceDefined") or a
--- fresh, start-time-only capture from whoever started this particular session
--- ("single") or resolved once at session-build time from a shared BJVehiclePreset (see
--- services/vehiclePresets.lua) into a plain {model,config,label}[] pool ("pool"). Every other
--- function in this file works off this normalized shape rather than reaching into BJRace/
--- session.settings/the preset cache directly.
---@alias BJVehicleRestriction {mode: "single"|"pool", model: string?, parts: table?, vars: table?, paints: table?, label: string?, pool: {model:string, config:string, label:string, parts:table?, vars:table?}[]?, allowTuning: boolean}

--- the restriction the local player should currently be held to, or nil if none applies right now
--- (start mode "free", or genuinely not in a position for it to matter). Deliberately wider than
--- isRaceLocked() (GRID included, not just COUNTDOWN/RACE): a restricted race needs to start
--- steering the player toward the right vehicle from the moment they join the lobby, not just once
--- the countdown freezes them ; a finished/dnf'd participant is excluded, same as every other
--- active-attempt-only check in this file, since there's nothing left for them to spawn into that
--- would matter.
---@return BJVehicleRestriction?
local function activeVehicleRestriction()
    if not M.session then return nil end
    local state = M.session.state
    if state ~= "GRID" and state ~= "COUNTDOWN" and state ~= "RACE" then return nil end
    local participant = getSelfParticipant()
    if not participant or participant.finished or participant.dnf then return nil end
    local s = M.session.settings
    local startMode = s.vehicleRestrictionStartMode
    -- resolved once, session-wide, regardless of which branch below actually builds the rest of
    -- the descriptor (raceGrid.lua's buildSettings computes it the same way no matter which
    -- vehicleRestrictionStartMode was chosen, see BJRaceDefaults.allowTuning's own doc)
    local allowTuning = s.allowTuning ~= false
    if startMode == "single" then
        if not s.vehicleRestrictionModel then return nil end -- capture failed at start time
        return {
            mode = "single",
            model = s.vehicleRestrictionModel,
            parts = s.vehicleRestrictionParts,
            vars = s.vehicleRestrictionVars,
            paints = s.vehicleRestrictionPaints,
            label = s.vehicleRestrictionLabel,
            allowTuning = allowTuning,
        }
    elseif startMode == "pool" then
        -- resolved server-side once at session-build time (raceGrid.lua's buildSettings) from
        -- whichever preset was chosen at start. session.settings already carries the real
        -- entries/label directly, no client-side preset lookup needed here
        if not table.isArray(s.vehicleRestrictionPool) or #s.vehicleRestrictionPool == 0 then return nil end
        return {
            mode = "pool",
            pool = s.vehicleRestrictionPool,
            label = s.vehicleRestrictionLabel,
            allowTuning = allowTuning,
        }
    elseif startMode == "raceDefined" then
        local race = getRace()
        if not race or race.vehicleRestrictionMode == "free" then return nil end
        if race.vehicleRestrictionMode == "single" then
            return {
                mode = "single",
                model = race.vehicleRestrictionModel,
                parts = race.vehicleRestrictionParts,
                vars = race.vehicleRestrictionVars,
                paints = race.vehicleRestrictionPaints,
                label = race.vehicleRestrictionLabel,
                allowTuning = allowTuning,
            }
        else -- "pool" : the race only stores a preset REFERENCE (vehicleRestrictionPoolPresetId),
            -- resolved here against the client's own shared preset cache, same resolve-once-at-
            -- use-time treatment the server's own raceGrid.lua gives a start-time preset choice
            local preset = beamjoy_vehiclePresets.getById(race.vehicleRestrictionPoolPresetId)
            if not preset or not table.isArray(preset.entries) or #preset.entries == 0 then return nil end
            return { mode = "pool", pool = preset.entries, label = preset.name, allowTuning = allowTuning }
        end
    end
    -- "free"
    return nil
end

-- real root cause of "changing paint (or nothing at all) with allowTuning off makes the car
-- invalid", found from a live console capture the user provided : NOT paint at all. The printed
-- before/after values in the diagnostic (e.g. "-0.012->-0.012") LOOKED identical but
-- table.deepcompare (an exact ~= check) still called them different. restriction.vars travels
-- through TWO full JSON round-trips before ever reaching this comparison (client -> raceStart
-- opts -> server session.settings -> back down in every session update), and this codebase's own
-- custom JSON lib (utils/json.lua) doesn't guarantee a numeric value survives that round-trip as
-- the exact same Lua number it started as (same general class of "a number becomes a string, or
-- loses precision, crossing a serialization boundary" already worked around elsewhere in this
-- codebase, e.g. bj-slider's own CEF quirk), so a captured tuning float that's cosmetically
-- identical once printed can still fail a bare `==`/deepcompare the instant it's read back off a
-- freshly-spawned vehicle. Exact equality was never going to survive that ; an epsilon-tolerant,
-- type-coercing comparison is required specifically for vars (parts are plain strings, never
-- floats, and already matched fine per the diagnostic: this is scoped to vars only).
local VARS_EPSILON = 0.0001
---@param a table<string, number>?
---@param b table<string, number>?
---@return boolean
local function varsMatch(a, b)
    a = a or {}
    b = b or {}
    local seen = {}
    for k in pairs(a) do seen[k] = true end
    for k in pairs(b) do seen[k] = true end
    for k in pairs(seen) do
        local av, bv = tonumber(a[k]), tonumber(b[k])
        if av == nil or bv == nil then
            if a[k] ~= b[k] then return false end
        elseif math.abs(av - bv) > VARS_EPSILON then
            return false
        end
    end
    return true
end

---@param veh NGVehicle
---@param restriction BJVehicleRestriction
---@return boolean
local function vehicleMatchesRestriction(veh, restriction)
    local full = beamjoy_vehicles.getFullConfig(veh)
    if not full then return false end
    -- paint is never compared, in either mode, regardless of allowTuning (see the plan's own TODO
    -- on eventually splitting paint out as its own separate toggle if that's ever wanted)
    if restriction.mode == "single" then
        -- parts always required ; vars (tuning) only ALSO required when allowTuning is off. A
        -- tire-pressure slider or a paint tweak shouldn't be treated as "not the required vehicle"
        -- by default, only an actual parts swap does (or, opt-in, a tuning change too)
        return full.model == restriction.model and
            table.deepcompare(full.parts or {}, restriction.parts or {}) and
            (restriction.allowTuning or varsMatch(full.vars, restriction.vars))
    elseif restriction.mode == "pool" then
        -- matched by PARTS (each pool entry's own captured snapshot, see services/vehiclePresets.lua),
        -- not by config-key identity like this used to. Real, confirmed bug : ANY live edit
        -- (parts, tuning, OR paint) resets the vehicle's config-file identity to "custom"
        -- (core/vehicle/partmgmt.lua's mergeConfigOfVehicle blanks partConfig on ANY live edit,
        -- regardless of what actually changed), which broke the OLD key-based match the instant a
        -- player so much as repainted or adjusted a tuning slider after picking their vehicle from
        -- the selector, even though nothing about their actual hardware changed. Parts-only
        -- comparison (plus vars too, when allowTuning is off) is exactly what "single" mode above
        -- already does, for the same reason ; a legacy entry captured before these fields existed
        -- has no v.parts (or no v.vars, under allowTuning == false) to compare against and is
        -- correctly never matched (falls through, same as any other genuinely non-matching entry)
        -- rather than erroring.
        local match = table.find(restriction.pool, function(v)
            return v.model == full.model and v.parts ~= nil and
                table.deepcompare(full.parts or {}, v.parts) and
                (restriction.allowTuning or (v.vars ~= nil and varsMatch(full.vars, v.vars)))
        end)
        if not match then
            -- Diagnostic only, same technique that found the real varsMatch float-precision bug
            -- earlier (see this file's own history) : rather than guess again at why one specific
            -- vehicle fails pool matching while others don't, log the exact key-by-key parts diff
            -- against every same-model pool candidate. Safe to remove once a real cause is
            -- confirmed from actual output.
            for _, v in ipairs(restriction.pool) do
                if v.model == full.model and v.parts ~= nil then
                    local diffs, seen = {}, {}
                    for k in pairs(full.parts or {}) do seen[k] = true end
                    for k in pairs(v.parts) do seen[k] = true end
                    for k in pairs(seen) do
                        local a, b = (full.parts or {})[k], v.parts[k]
                        if a ~= b then
                            table.insert(diffs, string.format("%s: live=%s preset=%s", k, tostring(a), tostring(b)))
                        end
                    end
                    LogWarn(string.format("pool match failed for '%s' (%d part diffs): %s",
                        tostring(v.label), #diffs, table.concat(diffs, " | ")))
                end
            end
        end
        return match ~= nil
    end
    return true
end

--- real enforcement (not just the ready()-time UX nag) for a vehicle-restricted race, routed
--- through the same generic spawn-authorization hook every OTHER spawn policy in this codebase
--- already uses (vehicles.lua's own cap/blacklist checks, group permissions). See
--- vehicleSelector.lua's spawnNewVehicle/replaceVehicle/cloneCurrent wrappers and its
--- passesFilters override, both already funneled through this one event. Denying here has two
--- effects for free, no extra plumbing needed : the actual spawn/replace/clone is blocked outright
--- (any path: the native selector, /veh, a script), AND (for "pool") the native vehicle
--- selector's own tile grid silently filters down to only the pool's entries, since passesFilters
--- checks this same authorization per item.
---@param req RequestAuthorization
---@param model string
---@param config string? nil for a raw-config (custom parts table) spawn. The native selector
---and any saved-.pc spawn always provide a real string here, only a raw core_vehicles.spawnNewVehicle
---call with a table config (this file's own forceRequiredVehicle below, or any other raw spawn)
---leaves it nil
---@param action ("spawn"|"replace"|"clone")? which native operation this authorization check is
---actually for. See vehicleSelector.lua's own comments (confirmed against the installed game's
---source) : "replace" (a normal tile pick) deletes the existing vehicle itself, so it's never a
---"second vehicle" concern ; "spawn" (the separate "Spawn New" action) and "clone" both never
---delete anything, genuinely leaving two vehicles at once
local function onBJRequestCanSpawnVehicle(req, model, config, action)
    local restriction = activeVehicleRestriction()
    if restriction then
        if restriction.mode == "single" then
            if model ~= restriction.model then
                req.state = false
                return
            end
            -- "single" mode's whole requirement is an exact captured PARTS breakdown, which this
            -- hook's own signature has no way to see for a raw-config spawn (config is nil there,
            -- whether it's this file's own forceRequiredVehicle or any other raw-parts spawn of the
            -- right model). Accepted, same "UX guard, not new anti-cheat" scope every other
            -- client-trusted check in this file already has (the server has never tracked vehicle
            -- parts either). What IS reliably checkable is refusing any NAMED saved config under the
            -- right model, since "single" was never meant to correspond to any specific .pc file at
            -- all. This closes the "right model, wrong preset via the selector" loophole outright.
            if config ~= nil then
                req.state = false
                return
            end
        elseif restriction.mode == "pool" then
            local allowed = table.find(restriction.pool, function(v)
                return v.model == model and v.config == config
            end) ~= nil
            if not allowed then
                req.state = false
                return
            end
        end
    end

    -- per direct request : reject a genuinely ADDITIONAL simultaneous vehicle for any active
    -- (not finished/dnf'd) participant, regardless of vehicle restriction. A normal tile pick
    -- (action == "replace") is unaffected, since that always deletes the old vehicle itself ; same
    -- reasoning/scope as hunterRunner.lua's own identical check
    if isRaceLocked() then
        local participant = getSelfParticipant()
        if participant and not participant.finished and not participant.dnf then
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
    end
end

--- whether `model` is actually spawnable on THIS client right now. A captured vehicle restriction
--- can reference a vehicle mod the capturing host has installed that a joining participant simply
--- doesn't (this fork's own AllowClientMods setting, see mods.lua, only guarantees every player has
--- an identical mod set when an admin turns it OFF: with it on, players can freely run their own
--- local-only mods nobody else has). Checked before ever touching the player's existing vehicle, so
--- a missing mod can never leave someone stranded carless. See both call sites below.
---@param model string
---@return boolean
local function modelAvailableLocally(model)
    local configs = beamjoy_vehicles.getAllVehicleConfigs(nil, { trailers = true, props = true })
    return configs[model] ~= nil
end

--- "single" mode's own force-spawn : deletes whatever the player currently has (if anything) and
--- spawns the exact captured vehicle (parts/vars/paints: works identically whether the original
--- capture was a saved .pc, a fully custom setup, or a fresh start-time capture) at wherever they
--- currently are. Mirrors restoreSavedVehicle's own spawn technique exactly (raw format-2 config
--- through the mod's own core_vehicles.spawnNewVehicle wrapper, not a bypass). See that
--- function's own comments for the vars/paints-default-to-{} and format-2-not-4 bugs already fixed
--- there, both equally applicable here. Returns false (leaving the player's existing vehicle
--- completely untouched) if the required model isn't installed on this client at all. See
--- modelAvailableLocally's own comment for why that's a real possibility, not a paranoid check.
---@param restriction BJVehicleRestriction
---@return boolean success
local function forceRequiredVehicle(restriction)
    if not modelAvailableLocally(restriction.model) then
        return false
    end
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
    local newVeh = core_vehicles.spawnNewVehicle(restriction.model, {
        pos = pos,
        config = {
            format = 2,
            model = restriction.model,
            parts = restriction.parts or {},
            vars = restriction.vars or {},
            paints = restriction.paints or {},
        },
    })
    if newVeh then
        be:enterVehicle(0, newVeh)
        if camera.getCamera() == camera.CAMERAS.FREE then
            camera.toggleFreeCam()
        end
        return true
    end
    return false
end

--- "pool" mode's own randomizeVehiclePool force-spawn : same technique as forceRequiredVehicle
--- above, but picks a uniformly random entry from the pool (restricted to ones actually installed
--- on this client, see modelAvailableLocally) instead of a single captured vehicle. Only spawns
--- via the entry's own real `config` file (the same one the native selector would present), never
--- a raw parts/vars/paints table. Pool entries were only ever captured as a shareable config
--- reference, unlike "single" mode's own fully custom capture.
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

--- streamlined in-lobby paint picker for single-config/pool vehicle-restricted races : the whole
--- model's own native paint list (every slot gets the same list, same reasoning traffic.lua's own
--- random-repaint already relies on, vehicles.lua's getAllPaints), not a curated subset, per direct
--- request. Purely cosmetic: paint is never part of vehicleMatchesRestriction, so this needs zero
--- coordination with the session/server, just the local vehicle's own model.
---@return {key: string, baseColor: number[]}[]? nil if there's no local vehicle to read paints from
local function currentPaintOptions()
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return nil end
    local options = {}
    for key, p in pairs(beamjoy_vehicles.getAllPaints(myVeh.veh)) do
        table.insert(options, { key = key, baseColor = p.baseColor })
    end
    return options
end

local function pushPaintOptions()
    beamjoy_communications_ui.send("BJRacePaintOptions", currentPaintOptions() or {})
end

---@param slot integer 1-3
---@param key string paint key, as returned by currentPaintOptions
local function setPaint(slot, key)
    -- UI-only guard mirrored here as a second, independent layer (same convention as the ready()
    -- vehicle-restriction check above) : the picker itself is only ever shown during GRID (see
    -- races/app.html), but nothing stopped this handler itself from still applying a stray/replayed
    -- BJRaceSetPaint once the grid starts moving, which is exactly the "paint menu should go away
    -- on countdown" report's underlying concern, not just a cosmetic panel-visibility one. "pool" is
    -- allowed through here same as "single": the key lookup below is always against whatever
    -- vehicle is CURRENTLY spawned, so it's safe regardless of which pool entry that happens to be.
    if not M.session or M.session.state ~= "GRID" then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return end
    local p = beamjoy_vehicles.getAllPaints(myVeh.veh)[key]
    if not p then return end
    beamjoy_vehicles.paint(myVeh.veh, { [slot] = p })
end

--- stops enforcing the camera lock AND actually restores whatever camera the player was on
--- before. Idempotent, safe to call more than once (M.previousCamera is nil after the first).
--- Rejects free/bigmap specifically : if that's what the player was on before the lock, falls
--- back to orbit (a real vehicle-following camera, matching the one used during the lock itself)
--- instead of handing them back a camera with no car in view. `camera.CAMERAS` is read inside the
--- function (not a module-top-level constant) matching this codebase's established convention of
--- never touching "game util" globals at file-parse time.
local function restorePreviousCamera()
    camera.stopForcedCameras()
    if M.previousCamera then
        -- cameras that don't actually follow the vehicle. Restoring straight back to one of
        -- these would leave the player not looking at their own car the instant they regain
        -- control
        local nonVehicleCameras = { camera.CAMERAS.FREE, camera.CAMERAS.BIG_MAP }
        local target = table.includes(nonVehicleCameras, M.previousCamera)
            and camera.CAMERAS.ORBIT or M.previousCamera
        camera.setCamera(target)
        -- per direct request : a player free-looking their orbit camera around during the last
        -- few seconds of countdown (control is handed back at CAMERA_RELEASE_SECONDS remaining,
        -- see updateCountdown) used to leave it wherever they'd rotated it once the vehicle
        -- actually unfroze, instead of facing forward down the track. Re-centers whatever camera
        -- mode ended up active, see camera.resetCamera's own doc for why this is safe regardless
        -- of which one that turned out to be.
        camera.resetCamera()
        M.previousCamera = nil
    end
end

--- unfreezes the vehicle and releases the camera lock (idempotent). Does NOT touch the countdown
--- UI. Callers decide whether to hide it immediately (early exit, no "GO!" moment to show) or
--- leave a brief "GO!" flash on screen first (normal countdown->race handoff)
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

--- early-exit release : unlocks and hides the countdown UI immediately (left mid-countdown,
--- session cancelled)
local function releaseScenarioLock()
    if not M.scenarioLocked then return end
    unlockScenario()
    beamjoy_communications_ui.send("BJRaceCountdown", { active = false })
end

--- describes `other` relative to `self` for HUD display: one signed number (`gapMs`, positive
--- means `other` is behind `self`, negative means ahead) covers the common "still racing, same
--- lap" case ; `lapsDiff` covers a lap split (a raw gate-time diff across different laps would be
--- meaningless) ; a finished/dnf `other` just reports its own state, the caller decides how to
--- render it (no live gap makes sense once someone's actually done)
---@param self BJRaceParticipant
---@param other BJRaceParticipant
---@param totalGates integer? the race's own gate count, needed to tell "just crossed the
---start/finish line first" (still within the same lap of real progress) apart from "genuinely
---lapped them" (a full lap of gate progress ahead). self.currentLap ~= other.currentLap alone
---isn't enough for that : currentLap increments the instant gate 1 is (re)crossed, regardless of
---how close the field still is at that moment.
---@return {playerName: string, finished: boolean, dnf: boolean, gapMs: integer?, lapsDiff: integer?}
local function describeOpponent(self, other, totalGates)
    local desc = { playerName = other.playerName, finished = other.finished, dnf = other.dnf }
    if self.dnf or other.dnf or self.finished ~= other.finished then
        return desc
    end
    if self.finished then -- both finished, self.finished == other.finished already checked above
        local selfTotal, otherTotal = 0, 0
        table.forEach(self.lapTimes or {}, function(t) selfTotal = selfTotal + t end)
        table.forEach(other.lapTimes or {}, function(t) otherTotal = otherTotal + t end)
        desc.gapMs = otherTotal - selfTotal
        return desc
    end
    if self.currentLap ~= other.currentLap and totalGates and totalGates > 0 then
        local selfProgress = (self.currentLap - 1) * totalGates + self.currentGate
        local otherProgress = (other.currentLap - 1) * totalGates + other.currentGate
        local gateGap = selfProgress - otherProgress
        if math.abs(gateGap) >= totalGates then
            -- same sign convention as gapMs below : positive means `other` is behind `self`.
            -- Whole-lap count derived from the real gate-progress gap, not self.currentLap -
            -- other.currentLap directly. That raw lap-number difference is exactly what let a
            -- "just crossed the line a moment before them" case show +1 lap prematurely, before
            -- real track progress actually backed it up.
            desc.lapsDiff = (gateGap > 0 and 1 or -1) * math.floor(math.abs(gateGap) / totalGates)
            return desc
        end
        -- different lap numbers but not yet a genuine full lap apart (the window right after
        -- either side crosses the start/finish line). Real, confirmed bug : this used to just
        -- `return desc` with nothing set here at all, which is exactly "the relative gap
        -- disappears" between crossing the line and actually completing a full lap ahead. The
        -- same-lap commonGate comparison below can't be reused directly (gateTimes resets per lap,
        -- so comparing raw gateTimes[gate] across two different laps compares two different lap-
        -- relative clocks). Instead, each racer's own total RACE-relative elapsed time (every
        -- already-completed lap's duration, plus their current lap's own lap-relative gate time)
        -- gives a continuous, always-comparable proxy : not pinned to one exact shared reference
        -- point the way the same-lap case is, but it converges to that same precise metric as the
        -- gap closes, and never just vanishes.
        local function raceRelativeMs(p)
            local total = 0
            table.forEach(p.lapTimes or {}, function(t) total = total + t end)
            local gateMs = p.gateTimes and p.gateTimes[p.currentGate]
            return gateMs and (total + gateMs) or nil
        end
        local selfMs, otherMs = raceRelativeMs(self), raceRelativeMs(other)
        if selfMs and otherMs then
            desc.gapMs = otherMs - selfMs
        end
        return desc
    end
    local commonGate = math.min(self.currentGate, other.currentGate)
    if commonGate >= 1 then
        local selfTime = self.gateTimes and self.gateTimes[commonGate]
        local otherTime = other.gateTimes and other.gateTimes[commonGate]
        if selfTime and otherTime then
            desc.gapMs = otherTime - selfTime
        end
    end
    return desc
end

--- pushes (or hides) the race HUD: own progress always included ; position/ahead/behind/full
--- standings only once there's more than one participant (a solo attempt has nothing to compare
--- against, but still gets the live best-lap delta once it has a lap to compare to). Also serves
--- pure non-participant spectating (M.spectatingSession) : same payload shape either way, just
--- built around the spectated participant instead of "self" when there's no self to speak of.
local function pushHud()
    -- an actual attempt (M.session) takes priority over pure spectating (M.spectatingSession) if
    -- somehow both were set. The server won't actually let that happen (see raceSpectate's own
    -- guard), this is just which one to read from
    local session = M.session or M.spectatingSession
    if not session or session.state ~= "RACE" then
        return beamjoy_communications_ui.send("BJRaceHud", { active = false })
    end
    local race = getRaceForSession(session)
    if not race then
        return beamjoy_communications_ui.send("BJRaceHud", { active = false })
    end

    -- who the HUD is actually about. Actually racing (M.session) : the local player's own entry,
    -- further redirected to whoever's being spectated if this player has since DNF'd/finished and
    -- auto-spectate kicked in, same as before. Pure spectating (M.spectatingSession, never a
    -- participant at all) : the spectated participant directly, there's no "self" to fall back to.
    local participant
    local elapsedStartMs
    if M.session then
        participant = getSelfParticipant()
        if not participant then
            return beamjoy_communications_ui.send("BJRaceHud", { active = false })
        end
        if M.spectatingPlayerName then
            local spectated = table.find(session.participants,
                function(p) return p.playerName == M.spectatingPlayerName end)
            if spectated then participant = spectated end
        end
        elapsedStartMs = M.raceStartTimeMs
    else
        if not M.spectatingPlayerName then
            return beamjoy_communications_ui.send("BJRaceHud", { active = false })
        end
        participant = table.find(session.participants,
            function(p) return p.playerName == M.spectatingPlayerName end)
        if not participant then
            return beamjoy_communications_ui.send("BJRaceHud", { active = false })
        end
        elapsedStartMs = M.spectatingRaceStartTimeMs
    end

    local elapsedMs = elapsedStartMs and (GetCurrentTimeMillis() - elapsedStartMs) or 0
    local previousLapsElapsed = 0
    table.forEach(participant.lapTimes or {}, function(t) previousLapsElapsed = previousLapsElapsed + t end)

    local leaderboard = session.leaderboard
    local position, totalRacers, ahead, behind, standings
    if leaderboard and #leaderboard > 1 then
        totalRacers = #leaderboard
        for i, row in ipairs(leaderboard) do
            if row.playerName == participant.playerName then
                position = i
                if leaderboard[i - 1] then ahead = describeOpponent(participant, leaderboard[i - 1], totalSteps(race)) end
                if leaderboard[i + 1] then behind = describeOpponent(participant, leaderboard[i + 1], totalSteps(race)) end
                break
            end
        end
        standings = table.map(leaderboard, function(row)
            return describeOpponent(participant, row, totalSteps(race))
        end)
    end

    beamjoy_communications_ui.send("BJRaceHud", {
        active = true,
        raceName = race.name,
        totalGates = totalSteps(race),
        totalSectors = computeSectorCount(race),
        totalLaps = session.settings.laps or 1,
        elapsedMs = elapsedMs,
        self = {
            playerName = participant.playerName,
            currentLap = participant.currentLap,
            currentGate = participant.currentGate,
            currentSector = participant.currentSector,
            finished = participant.finished,
            dnf = participant.dnf,
            currentLapElapsedMs = elapsedMs - previousLapsElapsed,
            lastLapMs = participant.lapTimes and participant.lapTimes[#participant.lapTimes] or nil,
            bestLapMs = participant.bestLapMs,
            liveDeltaMs = participant.liveDeltaMs,
        },
        position = position,
        totalRacers = totalRacers,
        ahead = ahead,
        behind = behind,
        standings = standings,
        -- lets the UI distinguish "this is my own progress" from "I'm watching someone else" (e.g.
        -- to label the panel accordingly) without having to separately compare playerName against
        -- some other locally-known "self" value
        spectatingPlayerName = M.spectatingPlayerName,
    })
end

--- sector/lap indices here are plain small positive integers (1, 2, 3...). A table keyed that way
--- (e.g. {[1]=1234, [2]=5678}) is indistinguishable from a real array to both this codebase's own
--- JSON encoder (services/utils/jsonOld.lua's isJsonArray) and the engine's own Lua->UI bridge
--- (guihooks.trigger, used by communications/ui.lua's send()), so it serializes as a 0-indexed JS
--- array instead of an object. Angular then reads it with a 1-based sector/lap number and gets
--- either the WRONG neighboring entry (index N really holds sector/lap N+1's value) or nothing at
--- all for the last one (index == length is out of bounds). This is what was actually behind both
--- "sector 3 is misaligned" and "the last lap's sectors aren't counted". Prefixing the key with a
--- non-numeric character defeats the array heuristic on both ends, forcing a real object ; JS
--- indexing a plain object with a numeric key (p.bestSectorMs[3]) auto-coerces to the same string
--- key anyway, so this only needs a matching read-side convention, not a behavior change.
---@param t table<integer, any>?
---@param prefix string
---@return table<string, any>?
local function keyify(t, prefix)
    if not t then return t end
    local out = {}
    for k, v in pairs(t) do
        out[prefix .. tostring(k)] = v
    end
    return out
end

--- lapSectorHistory is a table keyed by lap number whose own VALUES are themselves sector-indexed
--- tables: both levels hit the same array-ambiguity problem keyify() exists for, so both need
--- reprefixed keys, not just the inner one
---@param lapSectorHistory table<integer, table<integer, any>>?
---@return table<string, table<string, any>>?
local function keyifyLapSectorHistory(lapSectorHistory)
    if not lapSectorHistory then return lapSectorHistory end
    local out = {}
    for lap, sectors in pairs(lapSectorHistory) do
        out["lap" .. tostring(lap)] = keyify(sectors, "s")
    end
    return out
end

--- pushes the fuller per-player sector/lap breakdown the reusable race-info panel reads. Unlike
--- pushHud, deliberately does NOT hide itself once the session is removed (nothing sent at all in
--- that case, not an explicit "active=false") : the Angular side just keeps showing whatever the
--- last push was, which is exactly the frozen FINISHED-state results a player would want to
--- review after the race is actually over. Only an explicit GRID/COUNTDOWN push (a genuinely new
--- race beginning) clears a stale previous result.
---
--- Also replays the last "active=true" payload (M.lastRaceInfoPayload) whenever there's no live
--- session to build a fresh one from : bj-tabs destroys/recreates each tab's component on every
--- switch, and the info panel itself gets destroyed/recreated by its own ng-if on close/reopen, so
--- a freshly mounted tab always fires a new BJRaceInfoRequest. Without this, that request would
--- get silently ignored once M.session goes nil (post-race teardown), and the newly-mounted
--- component would show "no active race" despite a real finished result existing moments earlier.
--- (also serves pure non-participant spectating, M.spectatingSession, falling back to it whenever
--- M.session is nil. Same payload shape either way, since it was never "self"-shaped to begin
--- with, just every participant's full breakdown)
local function pushRaceInfo()
    local session = M.session or M.spectatingSession
    if not session then
        if M.lastRaceInfoPayload then
            beamjoy_communications_ui.send("BJRaceInfo", M.lastRaceInfoPayload)
        end
        return
    end
    if session.state == "GRID" or session.state == "COUNTDOWN" then
        M.lastRaceInfoPayload = nil
        return beamjoy_communications_ui.send("BJRaceInfo", { active = false })
    end
    local race = getRaceForSession(session)
    if not race then return end

    local payload = {
        active = true,
        state = session.state,
        raceName = race.name,
        totalLaps = session.settings.laps or 1,
        totalGates = totalSteps(race),
        sectorCount = computeSectorCount(race),
        selfPlayerName = MPConfig.getNickname(),
        -- leaderboard (already correctly sorted server-side) when there's someone to compare
        -- against, else just this player's own solo entry. Either way, every participant's full
        -- sector/lap breakdown, not just self's (unlike pushHud, which only needs self plus two
        -- trimmed neighbor rows)
        participants = (function()
            local rawParticipants = session.leaderboard or session.participants:values()
            -- leaderboard is already sorted "most progress first" server-side, so the first entry
            -- is the race leader. Reusing describeOpponent (built for the HUD's own ahead/behind
            -- gap) against it gives every other row a "gap to leader" figure for free, with the
            -- exact same finished/lap-split/live-gate-time rules the HUD already established,
            -- rather than inventing a second gap convention just for this panel. Also computed
            -- against the immediately-preceding row (aheadGapMs/aheadLapsDiff) for a live "gap to
            -- the car in front" column, same shape, just a different reference participant.
            local leader = rawParticipants[1]
            return table.map(rawParticipants, function(p, i)
                local gap = (leader and leader ~= p) and describeOpponent(leader, p, totalSteps(race)) or nil
                local ahead = rawParticipants[i - 1]
                local aheadGap = (ahead and ahead ~= p) and describeOpponent(ahead, p, totalSteps(race)) or nil
                return {
                    playerName = p.playerName,
                    vehicleModel = p.vehicleModel,
                    finished = p.finished,
                    dnf = p.dnf,
                    currentLap = p.currentLap,
                    currentSector = p.currentSector,
                    lapTimes = p.lapTimes,
                    bestLapMs = p.bestLapMs,
                    lapSectors = keyify(p.lapSectors, "s"),
                    lapSectorHistory = keyifyLapSectorHistory(p.lapSectorHistory),
                    bestSectorMs = keyify(p.bestSectorMs, "s"),
                    gapMs = gap and gap.gapMs or nil,
                    lapsDiff = gap and gap.lapsDiff or nil,
                    aheadGapMs = aheadGap and aheadGap.gapMs or nil,
                    aheadLapsDiff = aheadGap and aheadGap.lapsDiff or nil,
                }
            end)
        end)(),
    }
    -- only cached for replay-on-remount (see this function's own doc comment) when this is the
    -- player's OWN race. Caching a spectated session's results here would replay a stranger's
    -- race the next time the info panel mounts after this player stops spectating, instead of
    -- correctly going blank (onSpectateRemoved pushes an explicit active=false for exactly that)
    if M.session then
        M.lastRaceInfoPayload = payload
    end
    beamjoy_communications_ui.send("BJRaceInfo", payload)
end

--- begins watching a running session as a pure non-participant, server-validated (must actually
--- be running, must not already be racing yourself), see raceGrid.lua's own raceSpectate.
---@param sessionId string
local function spectateSession(sessionId)
    -- only capture on the FIRST spectate (not already watching something). Switching directly
    -- from spectating one session to another shouldn't overwrite this with whatever vehicle the
    -- player happened to be camera-attached to mid-spectate (another racer's, via
    -- spectateAnotherRacer), which onSpectateRemoved must never try to "return" the player to.
    if not M.spectatingSession then
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        M.preSpectateOwnVID = myVeh and myVeh.vid or nil
    end
    beamjoy_communications.send("raceSpectate", sessionId)
end

--- stops watching, if currently doing so. Waits for the server's own raceSpectateRemoved to
--- actually clear M.spectatingSession, same round-trip pattern leave()/retire() already use rather
--- than assuming success locally
local function stopSpectating()
    if not M.spectatingSession then return end
    beamjoy_communications.send("raceStopSpectate")
end

--- compact "you're spectating X" status for the main HUD's Races tab, same role pushSessionStatus
--- plays for actually being in a session. Separate event/state on the Angular side (a spectator
--- was never a participant, mixing the two would misrepresent them as one)
local function pushSpectateStatus()
    if not M.spectatingSession then
        return beamjoy_communications_ui.send("BJRaceSpectateStatus", nil)
    end
    local race = getRaceForSession(M.spectatingSession)
    beamjoy_communications_ui.send("BJRaceSpectateStatus", {
        sessionId = M.spectatingSession.id,
        raceName = race and race.name or "?",
        state = M.spectatingSession.state,
        participantCount = #M.spectatingSession.participants,
    })
end

---@param session BJRaceSession
local function onSpectateUpdate(session)
    local wasWatchingThis = M.spectatingSession ~= nil and M.spectatingSession.id == session.id
    M.spectatingSession = session

    -- re-anchored on every update (not just the first COUNTDOWN->RACE transition) using the
    -- server's own computed raceElapsedMs, a raw duration, not a timestamp, so it doesn't need
    -- the client and server clocks to agree on anything. Anchoring off "the moment this client
    -- personally started watching" (the previous approach) always started counting from 0 the
    -- instant spectating began, regardless of how long the race had actually been running by
    -- then ; for a spectator who joins after the target has already completed a lap or two, that
    -- made previousLapsElapsed (real elapsed time) exceed this locally-tracked value, driving
    -- currentLapElapsedMs permanently negative and the HUD timer permanently showing "-". Re-
    -- anchoring every update keeps this self-correcting while still ticking smoothly between
    -- updates via GetCurrentTimeMillis() locally, same as before.
    if session.state == "RACE" and session.raceElapsedMs then
        M.spectatingRaceStartTimeMs = GetCurrentTimeMillis() - session.raceElapsedMs
    elseif session.state ~= "RACE" then
        M.spectatingRaceStartTimeMs = nil
    end

    -- (re)pick who to watch the first time this session starts being watched, or if whoever was
    -- being watched isn't a participant in it anymore. Same leave-detection onSessionUpdate's
    -- own DNF/finish-spectate path uses, just triggered here instead since a pure spectator never
    -- goes through onSessionUpdate at all
    if not wasWatchingThis or (M.spectatingPlayerName and not table.find(session.participants,
            function(p) return p.playerName == M.spectatingPlayerName end)) then
        if not spectateAnotherRacer(session) then
            camera.setCamera(camera.CAMERAS.FREE)
        end
    end

    pushHud()
    pushRaceInfo()
    pushSpectateStatus()
    extensions.hook("onBJRaceMarkersRefresh")
end

---@param sessionId string
local function onSpectateRemoved(sessionId)
    if not M.spectatingSession or M.spectatingSession.id ~= sessionId then return end
    M.spectatingSession = nil
    M.spectatingRaceStartTimeMs = nil
    M.spectatingVID = nil
    M.spectatingPlayerName = nil

    -- pure spectating never touches the player's own vehicle (unlike DNF/auto-spectate, which
    -- deletes it via saveCurrentVehicleForRespawn). It's still sitting wherever it was left, so
    -- return the camera to it directly instead of dropping the player into free cam. Falls back
    -- to free cam only if that vehicle is gone by now (e.g. reset/deleted while spectating).
    local ownVID = M.preSpectateOwnVID
    M.preSpectateOwnVID = nil
    if ownVID and beamjoy_vehicles.vehicles[ownVID] then
        beamjoy_vehicles.focusVehicle(ownVID)
    else
        camera.setCamera(camera.CAMERAS.FREE)
    end
    pushHud()
    pushSpectateStatus()
    -- deliberately NOT pushRaceInfo() : that function replays M.lastRaceInfoPayload whenever
    -- there's no live session to build a fresh one from, which exists for the real "review your
    -- own just-finished race" case. Replaying it here would show a stale PERSONAL race result
    -- (from before this spectate session ever started) instead of correctly going blank
    beamjoy_communications_ui.send("BJRaceInfo", { active = false })
    extensions.hook("onBJRaceMarkersRefresh")
end

--- pushes (or hides) the "you're in a session" status panel. Covers the GRID (waiting room)
--- phase specifically, which previously had zero UI feedback at all (console-only : nothing told
--- a joined-but-not-ready player they were even in a lobby). Sent on every session update
--- regardless of state, unlike BJRaceHud/BJRaceCountdown which are state-specific.
---
--- gridReadySecondsLeft/gridTimeoutSecondsLeft are computed fresh from the local anchors
--- (gridReadyTargetMs/gridTimeoutTargetMs, set in onSessionUpdate) every time this is called,
--- rather than just forwarding whatever M.session itself last carried. This is what lets
--- updateGridCountdown below re-call this every second for a smoothly ticking display, not just a
--- chunky one that only updates on an actual server push (join/leave/ready-toggle).
local function pushSessionStatus()
    if not M.session then
        return beamjoy_communications_ui.send("BJRaceSessionStatus", nil)
    end
    local participant = getSelfParticipant()
    if not participant then
        return beamjoy_communications_ui.send("BJRaceSessionStatus", nil)
    end
    local race = getRace()
    local starter = table.find(M.session.participants, function(p) return p.playerID == M.session.starterID end)
    -- real, confirmed bug ("info button tooltip is still a placeholder") : statusInfoText() (the
    -- Angular side) used to unconditionally show a hardcoded "not implemented yet" line for
    -- vehicle restrictions, left over from before this feature existed. This session's own
    -- effective restriction (activeVehicleRestriction(), the same normalized descriptor every
    -- other enforcement check in this file already uses) was simply never pushed at all. Sent as
    -- structured data, not a pre-formatted string, so Angular can translate the label itself
    -- (matching how laps/respawnStrategy already work here) rather than hardcoding English in Lua.
    local restriction = activeVehicleRestriction()
    beamjoy_communications_ui.send("BJRaceSessionStatus", {
        id = M.session.id,
        raceName = race and race.name or "?",
        state = M.session.state,
        joinable = M.session.joinable,
        participantCount = #M.session.participants,
        maxParticipants = race and #race.startPositions or 0,
        -- {playerName, ready, vehicleModel} per participant, for the status panel's player-list
        -- dropdown
        participants = table.map(M.session.participants, function(p)
            return { playerName = p.playerName, ready = p.ready, vehicleModel = p.vehicleModel }
        end),
        laps = M.session.settings.laps,
        respawnStrategy = M.session.settings.respawnStrategy,
        vehicleRestrictionMode = restriction and restriction.mode or "free",
        vehicleRestrictionLabel = restriction and restriction.mode == "single" and restriction.label or nil,
        vehicleRestrictionPoolCount = restriction and restriction.mode == "pool" and
            #(restriction.pool or {}) or nil,
        vehicleRestrictionPoolLabel = restriction and restriction.mode == "pool" and restriction.label or nil,
        ready = participant.ready,
        isStarter = starter and starter.playerName == participant.playerName,
        -- lets the status panel hide "Retire" once already retired/finished, instead of letting
        -- the player click a no-op button (raceDNF already silently guards against it server-side,
        -- this is purely so the UI doesn't look actionable when it isn't anymore)
        finished = participant.finished,
        dnf = participant.dnf,
        gridReadySecondsLeft = M.gridReadyTargetMs and
            math.max(0, math.ceil((M.gridReadyTargetMs - GetCurrentTimeMillis()) / 1000)) or nil,
        gridTimeoutSecondsLeft = M.gridTimeoutTargetMs and
            math.max(0, math.ceil((M.gridTimeoutTargetMs - GetCurrentTimeMillis()) / 1000)) or nil,
    })
end

--- ticks the lobby countdown display once a second while actually in GRID. Same throttled-by-
--- whole-second-change pattern as updateCountdown's own COUNTDOWN-state ticking, just re-pushing
--- the session status instead of the big overlay (this is specifically for the Races tab's small
--- status panel, not a full-screen moment)
local lastGridReadySec, lastGridTimeoutSec = nil, nil
local function updateGridCountdown()
    if not (M.gridReadyTargetMs or M.gridTimeoutTargetMs) then return end
    local readySec = M.gridReadyTargetMs and
        math.max(0, math.ceil((M.gridReadyTargetMs - GetCurrentTimeMillis()) / 1000)) or nil
    local timeoutSec = M.gridTimeoutTargetMs and
        math.max(0, math.ceil((M.gridTimeoutTargetMs - GetCurrentTimeMillis()) / 1000)) or nil
    if readySec ~= lastGridReadySec or timeoutSec ~= lastGridTimeoutSec then
        lastGridReadySec = readySec
        lastGridTimeoutSec = timeoutSec
        pushSessionStatus()
    end
end

---@param session BJRaceSession
local function onSessionUpdate(session)
    local wasInSession = M.session ~= nil
    local wasRacing = M.session ~= nil and M.session.state == "RACE"
    local wasCountdown = M.session ~= nil and M.session.state == "COUNTDOWN"
    local wasSessionFinished = M.session ~= nil and M.session.state == "FINISHED"
    local wasDnf = false
    local wasFinished = false
    if M.session then
        local previousParticipant = getSelfParticipant()
        wasDnf = previousParticipant ~= nil and previousParticipant.dnf == true
        wasFinished = previousParticipant ~= nil and previousParticipant.finished == true
    end
    M.session = session

    -- lobby-phase countdown anchors, same "server duration -> local virtual timestamp" technique
    -- as spectating's own raceElapsedMs handling : re-anchored on every GRID update (not just
    -- once), so it stays accurate/self-correcting and still ticks smoothly between updates via
    -- GetCurrentTimeMillis() locally (see updateGridCountdown below, driven from onUpdate)
    if session.state == "GRID" and session.gridReadySecondsLeft ~= nil then
        M.gridReadyTargetMs = GetCurrentTimeMillis() + session.gridReadySecondsLeft * 1000
        M.gridTimeoutTargetMs = GetCurrentTimeMillis() + (session.gridTimeoutSecondsLeft or 0) * 1000
    else
        M.gridReadyTargetMs = nil
        M.gridTimeoutTargetMs = nil
    end

    local participant = getSelfParticipant()
    if not participant then
        -- no longer part of this session (left, kicked at gridTimeout, session gone)
        M.session = nil
        M.raceStartTimeMs = nil
        M.gridReadyTargetMs = nil
        M.gridTimeoutTargetMs = nil
        M.spectatingVID = nil
        M.spectatingPlayerName = nil
        M.myVehicleVid = nil
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh then
            beamjoy_vehicles.setGhostReason(myVeh.vid, "race", false)
            beamjoy_vehicles.setGhostReason(myVeh.vid, "noCollisionRace", false)
            beamjoy_vehicles.setGhostReason(myVeh.vid, "backmarker", false)
        end
        -- reset-penalty lock is separate state from the COUNTDOWN scenario lock (releaseScenarioLock
        -- below only clears that one, gated on M.scenarioLocked) : a player leaving/getting kicked/
        -- reaching the real session-removed teardown while still serving a reset penalty needs its
        -- own explicit release, or they'd stay frozen and ghosted indefinitely with no session left
        -- to ever tick updateResetPenaltyLock again
        if M.resetPenaltyLockedUntilMs then
            M.resetPenaltyLockedUntilMs = nil
            if myVeh then
                beamjoy_vehicles.setFreeze(myVeh.vid, false)
                beamjoy_vehicles.setGhostReason(myVeh.vid, "resetPenalty", false, true)
            end
            beamjoy_communications_ui.send("BJRaceCountdown", { active = false })
        end
        -- unconditional, not gated on myVeh like the reason-clear above : if this player already
        -- DNF'd/finished (their own vehicle deleted for spectating, per saveCurrentVehicleForRespawn)
        -- before leaving, myVeh is nil here and the reason-clear above never runs. But the solo
        -- visual reversal (see vehicles.lua's own M.soloGhostVisualReversed) isn't tied to any
        -- specific vehicle's existence, so it needs its own explicit clear or it would otherwise
        -- stay stuck on indefinitely, silently misrendering every vehicle after this race is over
        beamjoy_vehicles.setSoloGhostVisualReversed(false)
        releaseScenarioLock()
        -- releaseScenarioLock only clears the COUNTDOWN camera/freeze lock, gated on
        -- M.scenarioLocked (already false once RACE has actually begun). The post-green-light
        -- vehicle-only camera restriction and norespawn reset/recover block are separate state
        -- that also needs clearing when leaving mid-race, not just when leaving mid-countdown
        camera.stopForcedCameras()
        camera.unblockCameras()
        -- covers Leave/kicked while already spectating (DNF'd or auto-spectating a finish). The
        -- session-removed path below won't fire for them personally once they're gone from the
        -- session, so this is the only remaining place that would ever give their car back
        restoreSavedVehicle()
        extensions.hook("onBJScenarioChanged")
        pushHud()
        pushSessionStatus()
        return extensions.hook("onBJRaceMarkersRefresh")
    end
    pushSessionStatus()

    -- per direct request : a "single config" restricted race should steer the player toward the
    -- right vehicle the moment they join the lobby (GRID), not just block them at ready-up
    -- (ready()'s own check, further down) or silently reject a manual spawn attempt
    -- (onBJRequestCanSpawnVehicle above). Fires exactly once, on the real GRID entry (wasInSession
    -- false, the very first session push this client has seen for ANY session, whether just
    -- starting one or just joining someone else's), not on every later GRID push. A vehicle that
    -- already matches is left completely alone, per direct request.
    if session.state == "GRID" and not wasInSession then
        -- activeVehicleRestriction() reads M.session, already reassigned above, so it already
        -- reflects this fresh session's own vehicleRestrictionStartMode (raceDefined/single/free)
        local restriction = activeVehicleRestriction()
        if restriction then
            local myVeh = beamjoy_vehicles.getCurrentOwn()
            local matches = myVeh ~= nil and vehicleMatchesRestriction(myVeh.veh, restriction)
            if restriction.mode == "pool" and session.settings.randomizeVehiclePool then
                -- real, confirmed bug fixed here : randomize used to only ever kick in as a
                -- fallback for a MISMATCHED vehicle (nested inside "not matches" below), so a
                -- player who happened to already be sitting in a vehicle that's coincidentally in
                -- the pool never got randomized at all. The whole point of this option is to
                -- always randomize, not just to fix up a mismatch, so this now runs unconditionally
                -- whenever it's on, regardless of `matches`.
                local anyAvailable = table.find(restriction.pool, function(v)
                    return modelAvailableLocally(v.model)
                end) ~= nil
                if anyAvailable then
                    if forceRandomPoolVehicle(restriction.pool) then
                        toast.warn("This race restricts which vehicles can race. You've been given a random one", nil, 6)
                    else
                        toast.warn(
                            "This race's allowed vehicles aren't installed on your game. You won't be able to race",
                            nil, 8)
                    end
                else
                    toast.warn(
                        "This race's allowed vehicles aren't installed on your game. You won't be able to race",
                        nil, 8)
                end
            elseif not matches then
                if restriction.mode == "single" then
                    -- per direct request, for simplicity : no picking involved at all, the player
                    -- is put straight into the exact required vehicle (also the only way this can
                    -- work for a fully custom capture, there's no file for a selector to present).
                    -- forceRequiredVehicle only ever touches the player's existing car once it's
                    -- confirmed the required model is actually installed on THIS client. A
                    -- captured restriction can reference a vehicle mod the host (or, for a
                    -- start-time capture, the session starter) has that a joining participant
                    -- doesn't (see modelAvailableLocally's own comment), which must never leave
                    -- someone stranded carless.
                    if forceRequiredVehicle(restriction) then
                        toast.warn(string.format("This race requires: %s. You've been placed in it",
                            restriction.label or "?"), nil, 6)
                    else
                        toast.warn(string.format(
                            "This race requires a vehicle mod you don't have installed (%s). You won't be able to race",
                            restriction.label or "?"), nil, 8)
                    end
                else -- "pool", randomize off
                    -- same "don't strand them carless" reasoning as above : only actually delete
                    -- their car if at least one pool entry is something they could realistically
                    -- pick afterward
                    local anyAvailable = table.find(restriction.pool, function(v)
                        return modelAvailableLocally(v.model)
                    end) ~= nil
                    if anyAvailable then
                        if myVeh then
                            beamjoy_vehicles.deleteCurrentOwnVehicle()
                        end
                        toast.warn("This race restricts which vehicles can race. Pick one from the vehicle selector", nil, 6)
                        -- the native selector's own passesFilters (see vehicleSelector.lua) is
                        -- already wired through the same onBJRequestCanSpawnVehicle authorization
                        -- this file's own hook above denies non-pool vehicles through, so simply
                        -- opening it here already shows just the pool, pre-filtered. No manual
                        -- search/filter state needs to be set.
                        extensions.ui_vehicleSelector_general.openVehicleSelectorForFreeroam()
                    else
                        toast.warn(
                            "This race's allowed vehicles aren't installed on your game. You won't be able to race",
                            nil, 8)
                    end
                end
            end
        end
    end

    -- the racer being spectated (see spectateAnotherRacer) can simply Leave rather than DNF or
    -- finish. Unlike those, a plain Leave never deletes the leaving player's vehicle (see
    -- raceGrid.lua's raceLeave : it just drops them from session.participants), so
    -- onVehicleDestroyed never fires and this client would otherwise keep staring at a car that
    -- isn't even part of the race anymore. Checked independently here rather than relying on that
    -- hook for this specific case.
    if M.spectatingPlayerName and not table.find(session.participants,
            function(p) return p.playerName == M.spectatingPlayerName end) then
        M.spectatingVID = nil
        M.spectatingPlayerName = nil
        if not spectateAnotherRacer(session) then
            camera.setCamera(camera.CAMERAS.FREE)
        end
    end

    if session.state == "COUNTDOWN" and not wasCountdown then
        -- the race editor being left open while a race is actually running is a real, confusing
        -- state (its own gate/start markers fight the live session's, and it doesn't know or care
        -- about race state at all). Force it closed the moment a race actually begins, same
        -- point the freeze/camera lock also kicks in. Called directly rather than round-tripping
        -- through Angular's own BJCloseWindow flow, since this is already Lua calling Lua.
        beamjoy_communications_ui.closeWindow("config")
        if beamjoy_ui_activityEditor then
            beamjoy_ui_activityEditor.onClose()
        end

        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if participant.startPosition and myVeh then
            local sp = participant.startPosition
            -- real, confirmed bug fixed here (per direct request, mirroring hunterRunner.lua's
            -- own identical fix): setVehiclePositionRotation's default cling=true re-snaps to the
            -- nearest surface below via a ray starting 10 units above the target and stopping at
            -- the first surface it hits, which can land the vehicle on top of a covering
            -- structure (a gas station awning, a tunnel ceiling, a building roof) instead of the
            -- actually-authored start position if one happens to sit underneath. This position is
            -- already correctly placed, so re-clinging only ever risks moving it somewhere worse.
            beamjoy_vehicles.setVehiclePositionRotation(myVeh.veh,
                vec3(sp.pos.x, sp.pos.y, sp.pos.z),
                vec3(sp.dir.x, sp.dir.y, sp.dir.z),
                vec3(0, 0, 1), { cling = false })
        else
            LogWarn("beamjoy_raceRunner: no start position to teleport to")
        end
        -- ghosts every participant for the grid/countdown phase (default on, see
        -- BJRaceDefaults.ghostOnCountdown) so simultaneous grid teleports can't land vehicles on
        -- top of each other, independent of the server-wide Freeroam.CollisionsMode setting.
        -- Multiplayer un-ghosts the moment RACE actually begins below (see that transition for
        -- why) ; a solo attempt has nobody else actually racing to preserve collision with, so
        -- this reason is deliberately left active straight through the whole race for solo,
        -- matching BJI's own "solo scenario stays permanently ghosted" precedent. Cleared only
        -- on leave/session-removed below, same as every other race-ghost exit path.
        if myVeh and session.settings.ghostOnCountdown ~= false then
            beamjoy_vehicles.setGhostReason(myVeh.vid, "race", true)
        end
        -- opt-in, independent reason from "race" above (see BJRaceDefaults.disableCollisions) :
        -- stays active for the WHOLE race regardless of participant count, never cleared at the
        -- RACE transition below (unlike "race", which lifts for multiplayer at the green light).
        -- Only cleared on leave/session-removed, same exit paths as every other race-ghost reason
        if myVeh and session.settings.disableCollisions then
            beamjoy_vehicles.setGhostReason(myVeh.vid, "noCollisionRace", true)
        end

        M.scenarioLocked = true
        M.cameraReleased = false
        M.countdownStartMs = GetCurrentTimeMillis()
        M.countdownTotal = session.settings.countdown
        M.lastSentSeconds = nil

        -- per direct request (revised again) : still starts the countdown on the EXTERNAL
        -- camera, but no longer LOCKS it there. A plain one-time setCamera, not forceCamera
        -- (forceCamera's own reactive onCameraModeChanged enforcement was what fought a manual
        -- switch-away). Remembering what the player was on before, so the near-the-green-light
        -- "hand it back" moment in updateCountdown below has something real to restore to if they
        -- never touched the camera themselves. See that code's own comment for why it's now
        -- conditional on the camera still being EXTERNAL at that point (a manual switch during the
        -- countdown must NOT get overridden back to "previous" any more than it should get
        -- snapped back to EXTERNAL immediately after switching).
        M.previousCamera = camera.getCamera()
        camera.setCamera(camera.CAMERAS.EXTERNAL)
        camera.blockCameras(table.unpack(raceBlockedCameras()))
        extensions.hook("onBJScenarioChanged")

        -- freeze is reasserted every frame in updateCountdown() below rather than issued once
        -- here. A single delayed attempt (tried first) still didn't stick reliably, root cause
        -- unconfirmed (possibly the teleport's safeTeleport re-settling the vehicle, possibly
        -- something else entirely). Continuous per-frame correction matches camera.lua's own
        -- established pattern for keeping the camera locked and is robust regardless of the
        -- exact cause, since anything that transiently un-freezes the vehicle gets overridden
        -- again within one frame.

        local race = getRace()
        beamjoy_communications_ui.send("BJRaceCountdown",
            { active = true, seconds = M.countdownTotal, raceName = race and race.name })
        LogInfo("beamjoy_raceRunner: teleported to start position, race begins in "
            .. tostring(session.settings.countdown) .. "s")
    end

    if session.state == "RACE" and not wasRacing then
        M.raceStartTimeMs = GetCurrentTimeMillis()
        M.lastLy = {}
        M.lastProgressPos = nil
        M.lastProgressCheckMs = GetCurrentTimeMillis()
        M.lastDnfWarningSecond = nil
        LogInfo("beamjoy_raceRunner: race started")

        -- the grid is moving now. Grid ghosting (see the COUNTDOWN transition above) has done
        -- its job. Multiplayer should collide normally from here (real racing) ; solo has nobody
        -- else actually racing to preserve collision with, so its ghost stays on for the whole
        -- run (cleared on leave/session-removed instead). See the COUNTDOWN transition's own
        -- comment for the full reasoning
        --
        -- checkGhostedBystanders=false, per direct report ("possible to get stuck in someone's
        -- car right after the start") : the generic distance/contact safety check (setGhost's own,
        -- shared by every ghost reason) normally skips a bystander that's currently ghosted itself,
        -- safe in general, since a ghost-ghost overlap can't collide. But every participant
        -- transitions to solid together at this exact moment, and each client's own locally-known
        -- ghost flag for a fellow racer can be a few ms stale (their own un-ghost hasn't synced
        -- back yet). Both sides can end up perceiving each other as "still ghosted, safe to
        -- ignore" and clear simultaneously while actually overlapping. Checking real distance
        -- regardless of the bystander's own reported ghost state closes that window. Bounded by a
        -- short force-fallback (same pattern as the respawn-timeout fix) so a genuinely tight grid
        -- can't leave someone stuck ghosted indefinitely waiting for a clearance that never comes.
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        -- seeded here (not left to onBJVehicleInstantiated's own bootstrap) because this vehicle
        -- was already spawned back at GRID/ready-up, well before RACE begins. There's no fresh
        -- instantiate event for it to catch on its own at this exact transition
        M.myVehicleVid = myVeh and myVeh.vid or nil
        if myVeh and #session.participants > 1 then
            beamjoy_vehicles.setGhostReason(myVeh.vid, "race", false, false, false)
            local forceTaskName = "ghostRaceStartForce-" .. myVeh.vid
            async.removeTask(forceTaskName)
            async.delayTask(function()
                beamjoy_vehicles.setGhostReason(myVeh.vid, "race", false, true)
            end, 2000, forceTaskName)
        end

        -- unfreeze/release camera right at the green light. The "GO!" flash below is cosmetic
        -- only and must not delay when the player can actually move
        unlockScenario()
        -- Big Map is always blocked for the duration of the race, matching how a vanilla BeamNG
        -- scenario restricts cameras. Deliberately NOT forceCamera's allowlist approach : this
        -- fork's own CAMERAS enum only names orbit/external/driver/passenger, but BeamNG 0.39's
        -- actual vehicle camera ring has more entries than that (hood/chase/bumper/etc.). An
        -- allowlist of just those 4 names caused core_camera's own cycling to skip straight past
        -- any vehicle camera whose name isn't one of them, which is what left only driver/orbit
        -- reachable when this was first tried as forceCamera(...).
        --
        -- host-configurable, default on ("Disable Free Cam") : Free, Cinematic (smoothFree), and
        -- Steadycam are all global cameras, same category, all disallowed together under this one
        -- toggle (raceBlockedCameras). See its own comment for why. Free Cam itself was previously
        -- blocked unconditionally regardless of any toggle ; folding it into this same option means
        -- turning the option off deliberately re-opens Free Cam too, not just the two cameras
        -- nodegrabber can reach.
        camera.blockCameras(table.unpack(raceBlockedCameras()))
        extensions.hook("onBJScenarioChanged")
        beamjoy_communications_ui.send("BJRaceCountdown", { active = true, seconds = 0 })
        -- async.delayTask takes MILLISECONDS (its own param is literally named delayMs, see
        -- async.lua), not seconds ; every delayTask call in this file used to pass a bare
        -- "seconds" value straight through unconverted, which was the actual root cause behind
        -- "the finished screen disappears almost instantly". Confirmed from real timestamped
        -- console output showing the hide firing ~70ms after the popup, not ~8s later. players.lua
        -- already gets this right elsewhere (`delay * 1000`) ; this file just never did.
        async.delayTask(function()
            beamjoy_communications_ui.send("BJRaceCountdown", { active = false })
        end, 1000, "BJRaceCountdownGoHide")
    elseif session.state == "FINISHED" then
        LogInfo("beamjoy_raceRunner: race finished")
    end

    -- once this player's own attempt is over (even if others are still racing), let them use
    -- whatever camera they like again and lift the norespawn reset/recover block. Nothing left
    -- for either to protect
    if participant.finished or participant.dnf then
        camera.stopForcedCameras()
        camera.unblockCameras()
        extensions.hook("onBJScenarioChanged")
    end

    -- DNF specifically (not finishing normally) removes the vehicle and drops the player to
    -- spectate another still-active racer. Skipped for a solo attempt (nobody left to watch, and
    -- losing your only vehicle over what might just be a stall you're about to recover from
    -- anyway isn't useful when there's no one else racing). Only on the actual transition (not
    -- every subsequent update while still dnf), so it doesn't keep yanking the player's camera
    -- every time something else about the session changes. Falls back to plain free cam only if
    -- nobody else is still actively racing (e.g. everyone else already finished/dnf'd too).
    -- deliberately a one-shot focus at the transition, not a continuous lock, so the player can
    -- still freely look around/switch afterward (camera restrictions were already lifted above).
    -- real bug, matching a live-captured report ("seems like it's deleting all cars upon finish")
    -- : when THIS transition is also what completes the whole session (checkSessionComplete runs
    -- server-side in the very same call that set participant.dnf/finished, so session.state ==
    -- "FINISHED" arrives on this exact same push), there's nobody left to spectate and the delete
    -- is just going to be undone again ~10s later by onSessionRemoved's own restoreSavedVehicle:
    -- pure unnecessary churn (and, per the user's report, a source of real confusion/risk) for
    -- whoever's own action happens to be the last one needed to finish the race. Skipped entirely
    -- in that case ; they simply stay in their own car the way anyone would if playing solo.
    if participant.dnf and not wasDnf and #session.participants > 1 and session.state ~= "FINISHED" then
        saveCurrentVehicleForRespawn()
        beamjoy_vehicles.deleteCurrentOwnVehicle()
        if not spectateAnotherRacer(session) then
            camera.setCamera(camera.CAMERAS.FREE)
        end
    end

    -- finishing normally (not DNF'ing) does the exact same thing, but only when the race's own
    -- autoSpectateOnFinish setting opts into it (default true, see races.lua's sanitizeRace and
    -- raceGrid.lua's buildSettings). Unlike DNF, staying in your own car after finishing is a
    -- perfectly reasonable thing to want (e.g. just driving back to the pits), so this is the one
    -- of the two that's actually configurable rather than always-on.
    if participant.finished and not wasFinished and session.settings.autoSpectateOnFinish and
        #session.participants > 1 and session.state ~= "FINISHED" then
        saveCurrentVehicleForRespawn()
        beamjoy_vehicles.deleteCurrentOwnVehicle()
        if not spectateAnotherRacer(session) then
            camera.setCamera(camera.CAMERAS.FREE)
        end
    end

    -- "Finished"/"DNF" popups on the countdown overlay (reused as a generic "big transient
    -- message" primitive, same as the "GO!" flash above). Previously a solo racer got zero
    -- on-screen feedback that their attempt was over at all, since the leaderboard HUD only ever
    -- sends its comparison table once there's more than one participant. Deliberately NOT gated
    -- on participant count, unlike the vehicle-delete/free-cam block above. The popup should
    -- show in solo too, that's the whole point.
    if participant.finished and not wasFinished then
        local race = getRace()
        -- a loopable (multi-lap) race's own "best lap" is the meaningful number to celebrate here,
        -- not total elapsed time (which just rewards a long race, not a fast one) ; a single-lap
        -- race has no separate concept of "lap" vs "the whole attempt", so total time stays as-is
        local loopable = (session.settings.laps or 1) > 1
        beamjoy_communications_ui.send("BJRaceCountdown", {
            active = true,
            mode = "finished",
            raceName = race and race.name,
            timeMs = loopable and participant.bestLapMs
                or (M.raceStartTimeMs and (GetCurrentTimeMillis() - M.raceStartTimeMs) or nil),
            isBestLap = loopable,
            -- set server-side in raceGrid.lua's finishParticipant (services_races.submitTime),
            -- carried here straight off the raw participant object in the session payload. No
            -- extra plumbing needed, buildSessionPayload already sends participants unfiltered
            isNewPB = participant.isNewPB == true,
            isNewRecord = participant.isNewRecord == true,
        })
        async.delayTask(function()
            beamjoy_communications_ui.send("BJRaceCountdown", { active = false })
        end, FINISH_POPUP_SECONDS * 1000, "BJRaceCountdownFinishedHide")
    end
    if participant.dnf and not wasDnf then
        local race = getRace()
        beamjoy_communications_ui.send("BJRaceCountdown", {
            active = true,
            mode = "dnf",
            raceName = race and race.name,
        })
        async.delayTask(function()
            beamjoy_communications_ui.send("BJRaceCountdown", { active = false })
        end, FINISH_POPUP_SECONDS * 1000, "BJRaceCountdownDnfHide")
    end

    -- optional "ghost backmarkers" (see BJRaceDefaults.ghostBackmarkers) : server recomputes
    -- participant.backmarker on every session push (true once the leader is a lap ahead of this
    -- participant). Reacted to on every update, not just a one-shot transition, since this can
    -- flip back and forth as positions change over the course of the race, unlike the "race"/
    -- "noCollisionRace" reasons above which only ever change at fixed points
    if session.state == "RACE" and session.settings.ghostBackmarkers then
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh then
            beamjoy_vehicles.setGhostReason(myVeh.vid, "backmarker", participant.backmarker == true)
        end
    end

    pushHud()
    pushRaceInfo()

    -- auto-surface the results once the whole race (every participant, not just this one) is
    -- actually over. Fires once, on the real transition, not on every subsequent push during the
    -- ~10s FINISHED grace period
    if session.state == "FINISHED" and not wasSessionFinished then
        local race = getRace()
        beamjoy_communications_ui.send("BJRaceInfoAutoOpen", { raceName = race and race.name })
    end

    extensions.hook("onBJRaceMarkersRefresh")
end

--- re-sends the last known open-sessions list on demand, same remount-gap fix already applied to
--- BJRaceInfo/BJRaceSessionStatus : bjMainRaces (windows/main/races/) only ever populates
--- this.sessions reactively from BJRaceOpenSessions pushes, which the server only sends on actual
--- session-list-changing events (start/join/leave/removal), not on request. A session that opened
--- while the Races tab was closed (bj-tabs destroys/recreates tab content on every switch) was
--- simply invisible until some unrelated session event happened to trigger a fresh broadcast.
local function pushOpenSessions()
    beamjoy_communications_ui.send("BJRaceOpenSessions", M.openSessions or {})
end

---@param list table[]
local function onSessionsList(list)
    -- ping the HUD for any session that just became newly joinable (not the starter themselves,
    -- they already know) ; reuses the existing broadcast-text system rather than a new mechanism
    -- (communications_ui.uiBroadcast -> BJHUDText, not uiHelpers, which has no such function at all:
    -- this was calling a method that never existed until caught by a live in-game error)
    local previousIds = table.map(M.openSessions or {}, function(s) return s.id end)
    local selfName = MPConfig.getNickname()
    table.forEach(list, function(s)
        if not table.includes(previousIds, s.id) and s.starterName ~= selfName then
            -- durationSecs was previously omitted entirely, which uiBroadcast/BJHUDText both
            -- treat as "infinite" (no auto-hide timer gets scheduled at all). The ping just sat
            -- on screen forever until some other broadcast happened to overwrite it
            beamjoy_communications_ui.uiBroadcast("beamjoy.race.newJoinableSession",
                { raceName = s.raceName, starterName = s.starterName }, nil, 4)
        end
    end)

    M.openSessions = list
    beamjoy_communications_ui.send("BJRaceOpenSessions", list)
end

---@param sessionId string
local function onSessionRemoved(sessionId)
    if M.session and M.session.id == sessionId then
        M.session = nil
        M.raceStartTimeMs = nil
        M.gridReadyTargetMs = nil
        M.gridTimeoutTargetMs = nil
        M.spectatingVID = nil
        M.spectatingPlayerName = nil
        M.myVehicleVid = nil
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh then
            beamjoy_vehicles.setGhostReason(myVeh.vid, "race", false)
            beamjoy_vehicles.setGhostReason(myVeh.vid, "noCollisionRace", false)
            beamjoy_vehicles.setGhostReason(myVeh.vid, "backmarker", false)
        end
        -- reset-penalty lock is separate state from the COUNTDOWN scenario lock (releaseScenarioLock
        -- below only clears that one, gated on M.scenarioLocked) : a player leaving/getting kicked/
        -- reaching the real session-removed teardown while still serving a reset penalty needs its
        -- own explicit release, or they'd stay frozen and ghosted indefinitely with no session left
        -- to ever tick updateResetPenaltyLock again
        if M.resetPenaltyLockedUntilMs then
            M.resetPenaltyLockedUntilMs = nil
            if myVeh then
                beamjoy_vehicles.setFreeze(myVeh.vid, false)
                beamjoy_vehicles.setGhostReason(myVeh.vid, "resetPenalty", false, true)
            end
            beamjoy_communications_ui.send("BJRaceCountdown", { active = false })
        end
        -- unconditional, same reasoning as onSessionUpdate's own leave-path above. This is the
        -- real "race is genuinely over" signal (fires after the FINISHED grace period), by which
        -- point a solo racer who DNF'd/finished has typically had their own vehicle deleted for
        -- spectating already, leaving myVeh nil and the reason-clear above a no-op
        beamjoy_vehicles.setSoloGhostVisualReversed(false)
        releaseScenarioLock() -- covers cancellation mid-countdown
        -- same reasoning as onSessionUpdate's own leave-path above : the post-green-light camera
        -- restriction and norespawn block aren't covered by releaseScenarioLock once past COUNTDOWN
        camera.stopForcedCameras()
        camera.unblockCameras()
        -- the actual "race is genuinely over" signal. Fires ~10s after every participant
        -- finished/dnf'd (services/raceGrid.lua's own FINISHED grace period, effectively the
        -- results screen), well after the per-participant "Finished"/"DNF" popup has long since
        -- auto-hidden. Gives back whatever car a DNF or auto-spectate-on-finish took away instead
        -- of leaving the player stuck spectating/in free cam forever.
        restoreSavedVehicle()
        extensions.hook("onBJScenarioChanged")
        pushHud()
        -- previously missing entirely : the race tab's "you're in a session" status panel never
        -- got told the session was gone, so it stayed showing "running"/"waiting" indefinitely
        -- after a finish or cancel, until some unrelated digest cycle (e.g. switching tabs)
        -- happened to catch up
        pushSessionStatus()
        LogInfo("beamjoy_raceRunner: session ended")
        extensions.hook("onBJRaceMarkersRefresh")
    end
end

---@param gate BJRaceGate
---@param vPos vec3
---@return number lx, number ly, number lz
local function gateLocalCoords(gate, vPos)
    local pos = vec3(gate.pos.x, gate.pos.y, gate.pos.z)
    local dir = vec3(gate.dir.x, gate.dir.y, gate.dir.z):normalized()
    local up = vec3(0, 0, 1)
    local right = dir:cross(up)
    local d = vPos - pos
    return d:dot(right), d:dot(dir), d:dot(up)
end

--- ticks the countdown UI and hands camera control back ~3s before the green light (BJI
--- convention) while keeping the vehicle frozen until the actual start
local function updateCountdown()
    if not M.scenarioLocked or not M.countdownStartMs then return end

    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh and myVeh.veh.froze ~= "1" then
        beamjoy_vehicles.setFreeze(myVeh.vid, true)
    end

    local elapsedSec = (GetCurrentTimeMillis() - M.countdownStartMs) / 1000
    local remaining = math.max(0, math.ceil(M.countdownTotal - elapsedSec))

    if remaining ~= M.lastSentSeconds then
        M.lastSentSeconds = remaining
        beamjoy_communications_ui.send("BJRaceCountdown", { active = true, seconds = remaining })
    end

    if not M.cameraReleased and remaining <= CAMERA_RELEASE_SECONDS then
        M.cameraReleased = true
        -- only hand back the player's own pre-countdown camera if they never touched it
        -- themselves. The camera isn't locked/reasserted anymore (see the COUNTDOWN transition's
        -- own comment), so a manual switch away from EXTERNAL mid-countdown is a deliberate choice
        -- that shouldn't get silently overridden back to "previous" any more than it should have
        -- been snapped back to EXTERNAL the instant they made it
        if camera.getCamera() == camera.CAMERAS.EXTERNAL then
            restorePreviousCamera()
        else
            M.previousCamera = nil
        end
        extensions.hook("onBJScenarioChanged")
    end
end

--- replays the last countdown tick on request. Lets a freshly (re)mounted component (e.g. the
--- Races tab, destroyed/recreated by bj-tabs on every switch, per this file's own established
--- remount-gap pattern) show the current countdown immediately instead of waiting up to ~1s for
--- the next natural tick from updateCountdown() above
local function pushCountdown()
    if M.session and M.session.state == "COUNTDOWN" and M.lastSentSeconds ~= nil then
        beamjoy_communications_ui.send("BJRaceCountdown", { active = true, seconds = M.lastSentSeconds })
    end
end

--- reset penalty (opt-in, matching Hunter's own crash-reset penalty exactly, minus the camera
--- lock: races just freeze+ghost, no forced external view). Triggered on EVERY reset/recover
--- during an active attempt, no exception for a plain in-place Recover, since Hunter's own
--- version makes no such distinction either, and the whole point of this setting is "resetting
--- always costs you", not "only a hard reset does". Purely client-side, no server round-trip:
--- nothing server-side tracks or times this beyond resolving resetPenaltyEnabled/resetPenaltySeconds.
---@param vid integer
local function applyResetPenalty(vid)
    if not M.session or M.session.state ~= "RACE" then return end
    if not M.session.settings.resetPenaltyEnabled then return end
    -- already serving a penalty: ignore, don't restart/extend it. Same reasoning as Hunter's own
    -- identical guard, a repeated key press or the reset's own physics settling re-firing this
    -- hook must not keep pushing the release time back out
    if M.resetPenaltyLockedUntilMs then return end

    M.resetPenaltyLockedUntilMs = GetCurrentTimeMillis() + M.session.settings.resetPenaltySeconds * 1000
    beamjoy_vehicles.setFreeze(vid, true)
    -- ghosted while frozen, same reasoning as Hunter's own penalty lock : a vehicle stuck in place
    -- for the whole penalty duration is otherwise fully solid the entire time, reachable by
    -- another racer exactly when neither side can react
    beamjoy_vehicles.setGhostReason(vid, "resetPenalty", true)
    beamjoy_communications_ui.send("BJRaceCountdown",
        { active = true, mode = "penalty", seconds = math.ceil(M.session.settings.resetPenaltySeconds) })
end

--- ticks the reset-penalty lock: reasserts both the freeze and the ghost every frame (matching
--- updateCountdown's own equivalent freeze reassertion). BeamNG's own physics/recovery can briefly
--- drop a freeze mid-lock. Separately, vehicles.lua's own generic onVehicleResetted hook
--- unconditionally un-freezes any already-frozen vehicle the instant a native reset event fires
--- for it, with zero awareness of this lock. Since applyResetPenalty sets this freeze BEFORE that
--- native event actually dispatches (it fires pre-emptively, from onBJRequestCurrentVehicleReset),
--- that generic hook can see this lock's own freshly-applied freeze as "already frozen" and clear
--- it in the very same tick. Reasserting both every frame closes that gap regardless of the cause.
--- Also updates the countdown overlay and releases once the timer elapses.
local function updateResetPenaltyLock()
    if not M.resetPenaltyLockedUntilMs then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh then
        if myVeh.veh.froze ~= "1" then
            beamjoy_vehicles.setFreeze(myVeh.vid, true)
        end
        -- idempotent/cheap when already ghosted (setGhost's own early-return), so reasserting this
        -- every frame alongside the freeze costs nothing in the common case where nothing actually
        -- cleared it, and guarantees it can't silently lapse if something ever does
        beamjoy_vehicles.setGhostReason(myVeh.vid, "resetPenalty", true)
    end

    local remaining = math.max(0, math.ceil((M.resetPenaltyLockedUntilMs - GetCurrentTimeMillis()) / 1000))
    beamjoy_communications_ui.send("BJRaceCountdown", { active = true, mode = "penalty", seconds = remaining })

    if GetCurrentTimeMillis() >= M.resetPenaltyLockedUntilMs then
        M.resetPenaltyLockedUntilMs = nil
        if myVeh then
            beamjoy_vehicles.setFreeze(myVeh.vid, false)
            -- same immediate-attempt + bounded-forced-fallback release Hunter's own penalty lock
            -- uses : try the distance-safe clear first, force it after a short grace period so a
            -- crowded spot can't leave this vehicle ghosted indefinitely
            beamjoy_vehicles.setGhostReason(myVeh.vid, "resetPenalty", false, false, false)
            local forceTaskName = "raceResetPenaltyGhostForce-" .. myVeh.vid
            async.removeTask(forceTaskName)
            async.delayTask(function()
                beamjoy_vehicles.setGhostReason(myVeh.vid, "resetPenalty", false, true)
            end, 2000, forceTaskName)
        end
        beamjoy_communications_ui.send("BJRaceCountdown", { active = false })
    end
end

local function onUpdate()
    if M.session and M.session.state == "GRID" then
        updateGridCountdown()
    end
    if M.session and M.session.state == "COUNTDOWN" then
        updateCountdown()
    end
    if M.resetPenaltyLockedUntilMs then
        updateResetPenaltyLock()
    end
    -- keeps the live timer ticking smoothly between gate crossings instead of only jumping
    -- forward whenever the server happens to push a fresh update (a real, confirmed bug for the
    -- pure-spectate case : pushHud was only ever called reactively from onSpectateUpdate/
    -- onSessionUpdate, both of which the server only actually sends on gate crossings and a
    -- handful of other discrete events, not on any regular tick, so a spectated racer's timer
    -- visibly stair-stepped once per checkpoint instead of counting smoothly). Covers both : this
    -- player actively racing (even once finished/dnf'd, since others may still be going), and this
    -- player purely spectating another racer's own attempt. Throttled to ~20/sec (50ms), not once
    -- per whole second (that used to leave the hundredths/tenths place frozen for a full second at
    -- a time, only ever changing right when the seconds digit rolled over). Shared across both
    -- cases since only one of M.session/M.spectatingSession is ever active at once.
    local isRacing = M.session and M.session.state == "RACE"
    local isSpectatingRace = M.spectatingSession and M.spectatingSession.state == "RACE" and M.spectatingPlayerName
    if isRacing or isSpectatingRace then
        local nowMs = GetCurrentTimeMillis()
        if not M.lastHudPushMs or nowMs - M.lastHudPushMs >= 50 then
            M.lastHudPushMs = nowMs
            pushHud()
        end
    end
    -- host-configurable, default on : gravity has no native BeamNG keybind to block (confirmed:
    -- checked the installed game's own core/input/actions/ registry, nothing there), so unlike
    -- every other anticheat toggle here this can't be stopped at the input level. Instead, actively
    -- re-asserts the expected gravity every frame while race-locked (COUNTDOWN or RACE, same scope
    -- as the input-blocked options above). Catches a console/script-driven change within one
    -- frame instead of letting it stick. beamjoy_environment.data.gravity (not a hardcoded -9.81)
    -- is the actual expected value, since a server may run its own custom synced gravity.
    if isRaceLocked() and M.session.settings.disableGravityChange then
        local expected = beamjoy_environment.data.gravity
        if extensions.core_environment.getGravity() ~= expected then
            extensions.core_environment.setGravity(expected)
        end
    end
    -- always on, not host-configurable (see onBJRequestRestrictions above for why the toggle was
    -- removed entirely) : that input-action block only ever covered the toggle_slow_motion/
    -- slower_motion/faster_motion keybinds. Real, confirmed bypass : BeamNG's Environment settings
    -- panel (Escape menu > Environment > Simulation Speed) calls simTimeAuthority.set()/
    -- setInstant() directly (confirmed via the installed game's own lua/ge/simTimeAuthority.lua and
    -- its Vue panel), a completely separate path the action filter never touches at all, letting a
    -- race participant slow the whole simulation down with zero restriction regardless of the
    -- keybind block. Same active-reassertion treatment as gravity above, since there's no way to
    -- block this at the input level either : setInstant (not set) snaps back immediately with no
    -- easing, so it can't be out-dragged by repeated slider input the way a smoothed correction
    -- could.
    if isRaceLocked() then
        -- a genuine pause (be:getEnabled() == false, whatever triggered it: the "pause" action
        -- above, the pause menu, a console/script call) needs its own real unpause call : simply
        -- forcing the target speed back to 1 via setInstant does NOT resume the engine on its own
        -- (setTargetSpeed bails out early without touching updateDispatch/be:setEnabled whenever
        -- simTimeAuthority.getPause() is still true), so a forced-back-to-1 target would otherwise
        -- sit inert until whatever paused it also explicitly unpauses.
        if simTimeAuthority.getPause() then
            simTimeAuthority.pause(false)
        elseif simTimeAuthority.get() ~= 1 then
            simTimeAuthority.setInstant(1)
        end
    end

    if not M.session or M.session.state ~= "RACE" then return end
    local participant = getSelfParticipant()
    if not participant or participant.finished or participant.dnf then return end
    local race = getRace()
    if not race then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return end

    local vPos = beamjoy_vehicles.getVehiclePositionRotation(myVeh.veh) +
        vec3(0, 0, myVeh.veh:getInitialHeight() / 2)

    -- branching paths : more than one physical gate can be a valid "next" at once (parallel
    -- alternates sharing the last-crossed gate as a parent). The player picks one just by driving
    -- through it, so every candidate needs its own local crossing test each frame instead of one
    -- fixed expected index. A non-branching race always has exactly one candidate here, identical
    -- to the old fixed `expectedIndex` computation.
    local candidates
    if race.branchingEnabled then
        candidates = {}
        for i, g in ipairs(race.gates) do
            -- a loopable race's own step-1 gate is always a valid candidate (the loop-closing
            -- transition), regardless of parents. Mirrors raceGrid.lua's own identical exception,
            -- see its comment for the real bug this fixes (a forgotten backward link silently
            -- freezing progress for the rest of the race)
            local isLoopClosing = race.loopable and g.step == 1
            if isLoopClosing or table.includes(g.parents, participant.lastCrossedGate) then
                table.insert(candidates, i)
            end
        end
    else
        candidates = { (participant.currentGate % #race.gates) + 1 }
    end

    -- clear any stale M.lastLy entry for a gate that ISN'T a candidate this frame, otherwise a
    -- branch alternate's leftover sign from a previous lap/approach could falsely trigger (or
    -- suppress) a crossing the next time that same physical gate becomes a candidate again. A
    -- non-branching race only ever has one live candidate at a time by construction, so this is a
    -- no-op for it.
    for idx in pairs(M.lastLy) do
        if not table.includes(candidates, idx) then
            M.lastLy[idx] = nil
        end
    end

    for _, gateIdx in ipairs(candidates) do
        local gate = race.gates[gateIdx]
        if gate then
            local lx, ly, lz = gateLocalCoords(gate, vPos)

            -- real racing typically only requires most of the car within track limits (e.g. two
            -- wheels), not its exact center threading the gate perfectly. Actually tracking each
            -- vehicle's own wheels would be expensive and wildly inconsistent across body types
            -- (motorcycles, semis, trailers...), so this widens the gate's effective bounds by a
            -- quarter of the vehicle's own bounding-box width/height instead : a cheap, fully
            -- generic proxy (works for any vehicle, no per-type wheel geometry needed) for "enough
            -- of the car made it through," rather than requiring the single center point tested
            -- here to land dead-on within the strict rectangle.
            local leniencyX = myVeh.veh:getInitialWidth() / 4
            local leniencyZ = myVeh.veh:getInitialHeight() / 4

            local prevLy = M.lastLy[gateIdx]
            local crossed = prevLy ~= nil and prevLy < 0 and ly >= 0 and
                math.abs(lx) <= gate.width / 2 + leniencyX and
                lz >= -leniencyZ and lz <= gate.height + leniencyZ
            if crossed then
                beamjoy_communications.send("raceGateCrossed", M.session.id, gateIdx,
                    GetCurrentTimeMillis() - M.raceStartTimeMs)
                M.lastLy[gateIdx] = nil -- fresh start for this gate index next lap
                break -- only one candidate can actually be crossed in a single frame
            else
                M.lastLy[gateIdx] = ly
            end
        end
    end
end

--- DNF stall detection (BJI convention : >0.5m == still moving), applies under *any* respawn
--- strategy now (previously norespawn-only). Getting wedged in unrecoverable terrain is possible
--- regardless of what happens on a manual reset, and every other strategy still needs a way out
--- of that besides waiting forever. Only condition left is the race/start's own dnfEnabled toggle.
--- Runs on the ~250ms onSlowUpdate tick, not every render frame, unlike gate-crossing detection
--- above (which genuinely needs per-frame precision, a fast-moving vehicle could pass all the way
--- through a gate between two 250ms samples and never register the crossing at all), a stall is by
--- definition "hasn't moved in multiple *seconds*" ; sampling 4x/second instead of ~60x/second
--- changes nothing about when it actually triggers, just how often this runs.
local function checkDnfStall()
    if not M.session or M.session.state ~= "RACE" then return end
    if not M.session.settings.dnfEnabled then return end
    local participant = getSelfParticipant()
    if not participant or participant.finished or participant.dnf then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh then return end

    local vPos = beamjoy_vehicles.getVehiclePositionRotation(myVeh.veh) +
        vec3(0, 0, myVeh.veh:getInitialHeight() / 2)

    if not M.lastProgressPos or vPos:distance(M.lastProgressPos) > 0.5 then
        M.lastProgressPos = vPos
        M.lastProgressCheckMs = GetCurrentTimeMillis()
        M.lastDnfWarningSecond = nil
    else
        local timeoutMs = (M.session.settings.dnfTimeout or 30) * 1000
        local stalledMs = GetCurrentTimeMillis() - M.lastProgressCheckMs
        if stalledMs > timeoutMs then
            beamjoy_communications.send("raceDNF", M.session.id)
        elseif timeoutMs - stalledMs <= DNF_WARNING_SECONDS * 1000 then
            -- once-per-second-ish countdown ping in the final stretch, not a wall of text every
            -- tick. The player being DNF'd previously had no warning at all before it hit
            local secondsLeft = math.ceil((timeoutMs - stalledMs) / 1000)
            if secondsLeft ~= M.lastDnfWarningSecond then
                M.lastDnfWarningSecond = secondsLeft
                beamjoy_communications_ui.uiBroadcast("beamjoy.race.dnfWarning",
                    { seconds = tostring(secondsLeft) }, "orange", 1.5)
            end
        end
    end
end

local function onSlowUpdate()
    checkDnfStall()
end

-- teleporting a vehicle (spawn.safeTeleport, inside setVehiclePositionRotation below) fires
-- BeamNG's own native reset detection, which calls straight back into onVehicleResetted. Without
-- an exemption, the teleport-to-last-checkpoint kept re-triggering itself off its own reset event,
-- forever ("keeps respawning you repeatedly on vehicle reset"). Same class of feedback loop BJI's
-- own player-teleport code already guards against (an "exempt this reset from being treated as
-- player-initiated" flag set right before moving the vehicle).
local ignoreNextReset = {} ---@type table<integer, true> vid -> true

--- picks the lastcheckpoint respawn target : the last gate actually crossed, wherever the race
--- currently is in its lap cycle, or the assigned start position if nothing's been crossed yet
--- this whole race. `lastCrossedGate` never gets force-reset on a lap boundary (see its own doc
--- comment server-side in raceGrid.lua), so it's always the real last gate crossed.
---@param participant BJRaceParticipant
---@param race BJRace
---@return {pos:table, dir:table}?
local function lastCheckpointTarget(participant, race)
    -- lastCrossedGate (actual gate array index/identity), not currentGate (the progress/step
    -- number). Several physical gates can share one step in a branching race, so indexing
    -- race.gates by currentGate could land on the wrong physical gate entirely. Identical to
    -- currentGate for any non-branching race, where the two always match.
    local gate = participant.lastCrossedGate
    return (gate and gate > 0) and race.gates[gate] or participant.startPosition
end

--- respawnStrategy enforcement for "lastcheckpoint" (always) and "all" (hard resets only,
--- see below). Primary path : intercepts BEFORE the native reset/recover actually runs
--- (`inputs.lua`'s `overrideResetInputs` routes every reset-ish keybind through `onReset`, which
--- fires this exact hook and checks `req.state` before doing anything at all) and substitutes our
--- own teleport instead. This is how BeamJoy Free avoids a visible flash here : denying the
--- native reset means BeamNG never applies its own in-place/last-spawn result in the first place,
--- so there's nothing to visibly flash to before our teleport lands, unlike reacting only after
--- the fact.
---@param req RequestAuthorization
---@param resetType string
---@param mpVeh BJVehicle?
local function onBJRequestCurrentVehicleReset(req, resetType, mpVeh)
    if not M.session or M.session.state ~= "RACE" then return end
    if not mpVeh or not mpVeh.isLocal then return end
    local participant = getSelfParticipant()
    if not participant or participant.finished or participant.dnf then return end

    -- unconditional : fires for EVERY reset/recover attempt reaching this hook, regardless of
    -- respawnStrategy or reset type, matching Hunter's own crash-reset penalty exactly (applyResetPenalty
    -- itself no-ops if the setting is off or a lock is already being served)
    applyResetPenalty(mpVeh.vid)

    local strategy = M.session.settings.respawnStrategy
    -- "all" (free respawn) still lets a plain Recover behave exactly like vanilla BeamNG: that's
    -- just fixing a tip-over in place, not restarting your run. But a *hard* reset (physics
    -- reset / reload vehicle) would otherwise strand you at a random default spawn far from the
    -- track, so those specifically still redirect to the last checkpoint even under "all".
    local isLightRecover = resetType == beamjoy_inputs.RESET.RECOVER or
        resetType == beamjoy_inputs.RESET.RECOVER_ALT
    local shouldRedirect = strategy == "lastcheckpoint" or (strategy == "all" and not isLightRecover)
    if not shouldRedirect then return end
    local race = getRace()
    if not race then return end
    local target = lastCheckpointTarget(participant, race)
    if not target then return end

    req.state = false -- deny the native reset entirely ; we're substituting our own teleport below
    ignoreNextReset[mpVeh.vid] = true -- setVehiclePositionRotation's own teleport still triggers
    -- BeamNG's native reset detection as a side effect ; without this it would recurse straight
    -- back into onVehicleResetted below
    -- cling=false, same reasoning as the sibling grid-teleport above (and hunterRunner.lua's own
    -- identical fix): this position is already correctly placed, re-clinging to the nearest
    -- surface below can land the vehicle on top of a covering structure instead
    beamjoy_vehicles.setVehiclePositionRotation(mpVeh.veh,
        vec3(target.pos.x, target.pos.y, target.pos.z),
        vec3(target.dir.x, target.dir.y, target.dir.z),
        vec3(0, 0, 1), { cling = false })
end

-- teleporting a vehicle (spawn.safeTeleport, inside setVehiclePositionRotation below) fires
-- BeamNG's own native reset detection, which calls straight back into onVehicleResetted. Without
-- an exemption, the teleport-to-last-checkpoint kept re-triggering itself off its own reset event,
-- forever ("keeps respawning you repeatedly on vehicle reset"). Same class of feedback loop BJI's
-- own player-teleport code already guards against (an "exempt this reset from being treated as
-- player-initiated" flag set right before moving the vehicle).

-- Ported from BJI's own CollisionsManager (confirmed via direct research, not guessed) : mid-race
-- reset-ghosting is deliberately its OWN thing, entirely separate from the general freeroam
-- CollisionsMode="ghosts" respawn-protection in vehicles.lua. That mechanism has zero race-
-- awareness at all -- it fires for any reset anywhere, for its own host-configurable
-- RespawnGhostTimeout (~10s by default, meant for "just freeroam-spawned, give me a moment to
-- clear parked cars"), and would otherwise let a mid-race crash ghost a real racer against real
-- opponents for several seconds, exactly the "actual racers could go through each other" bug
-- flagged live before this existed. BJI's own fix, ported here : (1) gated strictly to
-- session.state == "RACE" (never GRID/COUNTDOWN -- BJI keeps collisions fully FORCED before the
-- race actually starts specifically so grid position can't be gamed by ghosting through it,
-- matching this fork's own COUNTDOWN-is-collision-real convention already) ; (2) a short, fixed
-- base delay (BJI's own constant, not a long host-configurable one) that only actually extends
-- while the vehicle remains within setGhost's own proximity check, dropping the instant it's
-- clear rather than blindly waiting out a timer ; (3) applied identically for ANY vehicle's
-- reset, local or remote -- every client already independently observes the same native
-- onVehicleResetted event with the same already-synced vehicle state, so (matching BJI exactly)
-- this needs no separate network message at all, unlike the general "respawn" reason.
local RACE_RESET_GHOST_SECONDS = 5
---@param vid integer
local function applyRaceResetGhost(vid)
    if not M.session or M.session.state ~= "RACE" then return end
    local mpVeh = beamjoy_vehicles.getVehicle(vid, true)
    if not mpVeh or mpVeh.isAi or mpVeh.jbeam == beamjoy_vehicles.WALKING then return end
    beamjoy_vehicles.setGhostReason(vid, "raceReset", true)
    local taskName = "raceResetGhost-" .. vid
    async.removeTask(taskName)
    async.delayTask(function()
        beamjoy_vehicles.setGhostReason(vid, "raceReset", false)
    end, RACE_RESET_GHOST_SECONDS * 1000, taskName)
end

--- fallback only now that `onBJRequestCurrentVehicleReset` above intercepts the common
--- keybind-triggered case before it ever visibly applies. This reactive path still matters for
--- any reset that reaches the vehicle by some other route `inputs.lua`'s override doesn't cover
--- (e.g. an environment auto-reset), where the native reset has already happened by the time we
--- find out about it, hence still needing the settle-then-correct deferral below.
---@param vid integer
local function onVehicleResetted(vid)
    -- unconditional (runs even for our own substituted checkpoint-teleport reset, and for any
    -- OTHER participant's reset too) -- only the checkpoint-teleport fallback logic below this is
    -- specific to "my own vehicle, lastcheckpoint strategy", the reset-ghost applies far more
    -- broadly than that
    applyRaceResetGhost(vid)

    if ignoreNextReset[vid] then
        ignoreNextReset[vid] = nil
        return
    end
    if not M.session or M.session.state ~= "RACE" then return end
    if M.session.settings.respawnStrategy ~= "lastcheckpoint" then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if not myVeh or myVeh.vid ~= vid then return end
    local participant = getSelfParticipant()
    if not participant or participant.finished or participant.dnf then return end
    local race = getRace()
    if not race then return end

    local target = lastCheckpointTarget(participant, race)
    if not target then return end

    -- deferred to the next tick, not called synchronously from inside the reset callback itself :
    -- triggering another full teleport (setVehiclePositionRotation's spawn.safeTeleport) while the
    -- engine is still mid-way through processing THIS reset event left the vehicle permanently
    -- stuck/locked. Matches the same "let the engine settle first" class of issue as the
    -- countdown's own teleport/freeze sequencing found earlier this session, just triggered by a
    -- different source event
    async.delayTask(function()
        local currentVeh = beamjoy_vehicles.getCurrentOwn()
        if not currentVeh or currentVeh.vid ~= vid then return end
        ignoreNextReset[vid] = true
        -- cling=false, same reasoning as this file's own other lastCheckpointTarget teleport
        beamjoy_vehicles.setVehiclePositionRotation(currentVeh.veh,
            vec3(target.pos.x, target.pos.y, target.pos.z),
            vec3(target.dir.x, target.dir.y, target.dir.z),
            vec3(0, 0, 1), { cling = false })
    end, 100, "BJRaceLastCheckpointRespawn-" .. vid)
end

---@param raceId integer
---@param opts table?
---@param raceId integer
---@param opts table?
local function startRace(raceId, opts)
    opts = opts or {}
    -- per direct request : "single" (start-time) vehicle restriction captures whatever the
    -- STARTER is currently driving, right at the moment they click Start, not a pre-authored
    -- race property (see BJRace.vehicleRestrictionMode for that one). The Angular start-options
    -- panel only ever sends the plain mode string ; it has no way to read live vehicle config
    -- itself (that's GE Lua-only), so the actual capture happens right here, the instant this
    -- message is about to leave the client, using the exact same getFullConfig technique the race
    -- editor's own "single" capture uses.
    if opts.vehicleRestrictionMode == "single" then
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        local full = myVeh and beamjoy_vehicles.getFullConfig(myVeh.veh)
        if full then
            opts.vehicleRestrictionModel = full.model
            opts.vehicleRestrictionParts = full.parts or {}
            opts.vehicleRestrictionVars = full.vars or {}
            opts.vehicleRestrictionPaints = full.paints or {}
            opts.vehicleRestrictionLabel = full.label
        else
            -- no vehicle to capture from. Falls back to "free" rather than silently starting an
            -- uncapturable "single" restriction nobody (including the starter) could ever satisfy
            toast.warn("You need a vehicle to start a single-config race. Starting without a restriction instead", nil, 6)
            opts.vehicleRestrictionMode = "free"
        end
    end
    beamjoy_communications.send("raceStart", raceId, opts)
end

---@param sessionId string
local function joinRace(sessionId)
    beamjoy_communications.send("raceJoin", sessionId)
end

---@param state boolean?
local function ready(state)
    if not M.session then return LogError("beamjoy_raceRunner: not in a race session") end
    local becomingReady = state ~= false
    local model
    if becomingReady then
        -- server-side has no reliable way to check this itself : it only tracks the last vid the
        -- client ever reported switching to (`currentVehicle`), which is never cleared back to
        -- nil on delete/despawn, so a player who deleted their only car (or walked away from the
        -- grid via "get out and walk" (not blocked during GRID, only during an active RACE, see
        -- the toggleWalkingMode restriction above) could still ready up with nothing to actually
        -- race in. getCurrentOwn() also returns the walking-mode "unicycle" jbeam itself, so that
        -- needs excluding explicitly too, not just a nil check.
        local veh = beamjoy_vehicles.getCurrentOwn()
        if not veh or veh.jbeam == beamjoy_vehicles.WALKING then
            -- toast.error with no explicit fadeSecs defaults to sticky (never auto-dismisses,
            -- requires the player to manually close it). Appropriate for a genuine failure like
            -- activityEditorSafeZone's "Failed to save data", but this is just a transient
            -- validation nag the player will immediately resolve by spawning a car, not something
            -- that should sit on screen forever after the fact. Explicit fadeSecs fixes that.
            toast.warn("You need a vehicle to ready up", nil, 4)
            return
        end
        -- per direct request : a race can restrict itself to a specific vehicle/config, or a pool
        -- of allowed ones (e.g. a spec-car challenge or a class race), either the race's own
        -- authored one or a fresh start-time capture (see activeVehicleRestriction's own doc).
        -- Same client-trusted UX-guard model as the "need a vehicle at all" check just above, not
        -- new server-side anti-cheat: the server has never tracked vehicle parts. In practice this
        -- should already be satisfied by the time ready-up is even reachable. The join-time
        -- force-spawn/selector-open (onSessionUpdate) and the onBJRequestCanSpawnVehicle hook
        -- above already steer/restrict what could be spawned in the first place. Kept here anyway
        -- as a second, independent layer.
        local restriction = activeVehicleRestriction()
        if restriction and not vehicleMatchesRestriction(veh.veh, restriction) then
            toast.warn(restriction.label and string.format("This race requires: %s", restriction.label) or
                "This race restricts which vehicles can race", nil, 4)
            return
        end
        -- real, confirmed bug found while wiring up the leaderboard's vehicle column : the
        -- server-side player.currentVehicle this could otherwise have been resolved from is
        -- populated by this same file's own updateCurrentVehicle send, which reports v.remoteVID,
        -- and BeamMP reports remoteVehID as -1 for a client's OWN vehicle (only meaningful for
        -- someone ELSE'S), so that send falls back to the raw local engine vid instead. That raw
        -- vid lives in a completely different numbering space than player.vehicles' own keys
        -- (BeamMP's small per-player vehicle slot index), so server-side lookups through
        -- currentVehicle -> vehicles[...] silently never match for a player's own car. Exactly
        -- why the leaderboard's vehicle column always came back blank. Sidestepped entirely by
        -- having the client just report its own already-known vehicle info directly, right here,
        -- instead of routing through that mismatched id chain at all. A full "Model - Config" (or
        -- "Model (custom)") display label, not just the bare jbeam, per direct request.
        model = beamjoy_vehicles.getCurrentConfigDisplayLabel(veh.veh)
    end
    beamjoy_communications.send("raceReady", M.session.id, becomingReady, model)
end

local function leave()
    if not M.session then return end
    beamjoy_communications.send("raceLeave", M.session.id)
end

--- "retire and spectate" : a voluntary self-DNF, distinct from Leave. Reuses raceGrid.lua's
--- existing raceDNF (previously only ever sent by the auto-stall-detection code below). The
--- server-side effect (marked dnf, stays a tracked participant) and the client-side effect
--- (vehicle removed, camera auto-focuses another still-active racer via spectateAnotherRacer
--- above) are both already exactly "retire and spectate", they just never had a voluntary,
--- player-facing entry point before now. Leave, by contrast, removes the player from the session
--- entirely (no more HUD/leaderboard, no spectating).
local function retire()
    if not M.session then return end
    beamjoy_communications.send("raceDNF", M.session.id)
end

local function cancel()
    if not M.session then return end
    beamjoy_communications.send("raceCancel", M.session.id)
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onBJRequestCanSpawnVehicle = onBJRequestCanSpawnVehicle
M.isRaceLocked = isRaceLocked

M.onSessionUpdate = onSessionUpdate
M.onSessionsList = onSessionsList
M.onSessionRemoved = onSessionRemoved
M.onSpectateUpdate = onSpectateUpdate
M.onSpectateRemoved = onSpectateRemoved
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onBJRequestCurrentVehicleReset = onBJRequestCurrentVehicleReset
M.pushRaceInfo = pushRaceInfo
M.pushSessionStatus = pushSessionStatus
M.pushCountdown = pushCountdown
M.pushOpenSessions = pushOpenSessions
M.pushSpectateStatus = pushSpectateStatus
M.pushPaintOptions = pushPaintOptions
M.setPaint = setPaint

M.startRace = startRace
M.joinRace = joinRace
M.ready = ready
M.leave = leave
M.cancel = cancel
M.retire = retire
M.spectateSession = spectateSession
M.stopSpectating = stopSpectating

return M
