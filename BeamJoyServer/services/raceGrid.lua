--- Live `grid`-mode race session state machine (join/ready/countdown/leaderboard/finish).
--- Separate from `services/races.lua`, which only owns the static race *definitions*
--- (storage/CRUD). This module owns *instances* of a race actually being run. Multiple sessions
--- can run concurrently, one per player-started race, unlike BeamJoy Free's single
--- server-wide active scenario.
---
--- NOT YET IMPLEMENTED (deferred, see the plan): vehicle model/config enforcement during grid,
--- the admin-forced server-wide path, and anything about `passive` mode (that's an ambient/
--- freeroam mechanic, not a grid session at all).

---@alias BJRaceSessionState "GRID"|"COUNTDOWN"|"RACE"|"FINISHED"

---@class BJRaceParticipant
---@field playerID integer
---@field playerName string
---@field joinIndex integer 1-based order in which this participant entered the session (the
---starter is always 1). The "deterministic" placement mode's sort key, and the fallback fill
---order for "manual" mode's defensive path; previously nothing recorded join order at all
---(participants are keyed by playerID, so pairs() iteration order was the de-facto, arbitrary
---grid order)
---@field gridSlot integer? "manual" placement mode only : this participant's host-assigned grid
---slot (1-based index into race.startPositions). Auto-seeded to the lowest free slot on join so
---the lobby always shows a complete assignment, then re-arranged by the host via raceSetGridSlot
---(assigning an occupied slot swaps the two participants). nil in every other placement mode
---@field ready boolean
---@field currentGate integer 0 = nothing crossed yet this race, else the PROGRESS number (each
---gate's own `step`, see BJRaceGate.step, identical to the crossed gate's plain array index for
---any non-branching race) of the last gate physically crossed. Cycles 1..totalSteps(race) and back
---to 1 every lap (see raceGateCrossed's own validation). Deliberately never force-reset to 0 on a
---lap boundary. A participant who just crossed the last step but hasn't yet re-crossed step 1 (a
---loopable race's own start/finish line, see the note on lapComplete below) has genuinely made more
---progress than one still sitting at the start, and forcing this back to 0 used to misrepresent
---that on the leaderboard for the whole drive back to the line. This is a plain progress number,
---not a gate identity. Every existing consumer (leaderboard tie-break, gateTimes indexing, live
---delta, backmarker progress) only ever needed something comparable, which this still is even for a
---branching race where several different physical gates can share the same step
---@field lastCrossedGate integer 0 = nothing crossed yet, else the actual array INDEX (gate
---identity, not progress) of the physical gate last crossed, distinct from currentGate above
---specifically for branching races, where multiple gates can share one step/progress number.
---Needed by two things that care about identity rather than progress: validating the NEXT
---crossing against that gate's own `parents` list, and the "lastcheckpoint" respawn strategy
---(raceRunner.lua's lastCheckpointTarget), which must respawn at the exact physical gate crossed,
---not just "a" gate at the same progress number. Identical to currentGate for any non-branching race
---@field currentLap integer
---@field gateTimes table<integer, integer> gate index -> elapsed ms since race start
---@field lapTimes integer[] completed lap times (ms)
---@field bestLapMs integer? this participant's own fastest completed lap this session
---@field bestLapGateTimes table<integer, integer>? gate index -> elapsed ms since the *lap*
---started (not race-cumulative, unlike gateTimes), snapshotted from bestLapMs's own lap. The
---reference the live delta bar compares against, so a solo racer with no one else to race has
---something to chase from their second lap onward
---@field liveDeltaMs integer? signed ms vs bestLapGateTimes at the last gate crossed. Negative
---means ahead of own best pace, positive means behind, nil until a best lap exists
---@field currentSector integer 1-based, which sector (per race.sectorCount) this participant is
---currently within
---@field sectorStartMs integer lap-relative ms at which currentSector began, for computing that
---sector's own duration once its last gate is crossed
---@field lapSectors table<integer, integer> sector index -> duration (ms) completed so far this
---lap, filled in as each sector's last gate is crossed
---@field lapSectorHistory table<integer, table<integer,integer>> lap number -> that lap's
---lapSectors snapshot, captured whole once the lap completes. The per-lap sector breakdown the
---results panel reads
---@field bestSectorMs table<integer, integer> sector index -> this participant's own fastest
---duration for that sector across every lap so far. Used for the results panel's personal-best
---highlighting; the race-wide fastest-sector "purple" highlight is derived client-side by
---comparing this same field across every participant, no separate server aggregation needed
---@field finished boolean
---@field dnf boolean
---@field lastProgressTime integer GetCurrentTime() of the last recorded gate crossing
---@field vehicleModel string? jbeam of whatever vehicle the client was in when they last readied
---up. Reported directly by the client (raceReady's own model arg), not resolved server-side
---through services_players.players[...].currentVehicle, a different (and effectively unusable for
---this) id space; see raceRunner.lua's ready() for the full story. Used for the
---leaderboard's vehicle column (services_races.submitTime)
---@field isNewPB boolean? set once at finishParticipant, from services_races.submitTime; not
---currently surfaced to the client (no popup wired up yet), kept for future use/debugging
---@field isNewRecord boolean? same as isNewPB, true when this PB is now the race's overall best

---@class BJRaceSessionSettings host-configurable at start time, seeded from BJRaceDefaults
---@field laps integer?
---@field respawnStrategy BJRaceRespawnStrategy
---@field placementMode BJRacePlacementMode how grid slots are assigned at countdown time:
---"deterministic" = lobby join order (starter first), "random" = shuffled, "manual" = whatever
---the host assigned in the lobby (see raceSetGridSlot). Default "random"
---@field gridTimeout integer seconds
---@field gridReadyTimeout integer seconds
---@field countdown integer seconds
---@field dnfEnabled boolean stall-based DNF under "norespawn". Default true
---@field dnfTimeout integer seconds of no progress before a DNF triggers
---@field resetPenaltyEnabled boolean matching Hunter's own crash-reset penalty. Freezes and
---camera-locks (external view) a participant for resetPenaltySeconds each time they reset/recover
---during an active attempt. Default false. Purely client-enforced (raceRunner.lua), same as
---Hunter's own version; nothing server-side tracks or times this beyond resolving the setting
---itself. Moot under "norespawn" (resets are already fully blocked there)
---@field resetPenaltySeconds integer seconds frozen per reset when resetPenaltyEnabled is on
---@field autoSpectateOnFinish boolean auto-switch a finisher to spectating another still-active
---participant. Default true
---@field disableNodegrabber boolean blocks BeamNG's node-grabber tool for active participants.
---Default true
---@field disableCameras boolean "Disable Free Cam": blocks Free, Cinematic, and Steadycam for the
---duration of a participant's attempt, on top of the always-blocked Big Map. Default true
---@field disableGravityChange boolean re-asserts expected gravity every frame while race-locked.
---Default true
---@field vehicleRestrictionStartMode ("free"|"single"|"pool"|"raceDefined")? per-start choice of
---vehicle restriction, independent of BJRace.vehicleRestrictionMode (the race's own AUTHORED
---restriction, fixed by its design, never overridable). "free" means no restriction this attempt.
---"raceDefined" uses the race's own authored restriction (only meaningful, and only offered by
---the client UI, when the race actually has one; see races.lua's own doc). "single" is a fresh,
---start-time-only capture: raceRunner.lua's startRace() snapshots whoever is STARTING the
---session's own current vehicle (not the race's own saved one) the instant they click Start, and
---every participant is force-spawned into that same capture, same mechanism as a "raceDefined"
---single restriction; see vehicleRestrictionModel/Parts/Vars/Paints/Label below for where that
---capture actually lives. "pool" is a fresh, start-time-only choice of a shared BJVehiclePreset
---(see services/vehiclePresets.lua), picked from a dropdown rather than authored per-race, resolved
---to the preset's actual entries once, here in buildSettings, and snapshotted into
---vehicleRestrictionPool/Label below, same "resolve once at session start, never read the preset
---live again mid-session" treatment "single" mode's own capture already gets. Default "free"
---@field vehicleRestrictionModel string? "single" start-mode only : jbeam model of the
---start-time capture (see vehicleRestrictionStartMode above). NOT the same field as
---BJRace.vehicleRestrictionModel, which is the race's own separate, editor-authored capture
---@field vehicleRestrictionParts table<string, string>? "single" start-mode only : the start-time
---capture's full parts tree (see vehicles.lua's getFullConfig): the actual thing every
---participant gets force-spawned into and compared against
---@field vehicleRestrictionVars table<string, number>? "single" start-mode only : the start-time
---capture's tuning variables, applied on force-spawn for a faithful reproduction
---@field vehicleRestrictionPaints table? "single" start-mode only : the start-time capture's paint
---slots, applied on force-spawn for a faithful reproduction
---@field vehicleRestrictionLabel string? "single"/"pool" start-mode only : human-readable display
---label for the start-time capture (single) or the chosen preset's own name (pool)
---@field vehicleRestrictionPool {model: string, config: string, label: string}[]? "pool" start-mode
---only : the chosen BJVehiclePreset's entries, resolved once at session-build time: the actual
---list a joining participant picks from via the native vehicle selector
---@field ghostOnCountdown boolean ghosts every participant during the COUNTDOWN grid phase.
---For a solo attempt the client keeps this ghost active for the whole race instead of lifting it
---at RACE start (see BJRaceDefaults.ghostOnCountdown). Default true
---@field disableCollisions boolean opt-in whole-race ghost, independent of ghostOnCountdown above.
---Every participant stays ghosted for the entire race regardless of participant count (see
---BJRaceDefaults.disableCollisions). Default false
---@field ghostBackmarkers boolean opt-in. A participant genuinely lapped by the current leader
---(a full lap of real gate-progress behind, not just a lower lap NUMBER; see
---buildSessionPayload's own backmarker computation) ghosts themselves for as long as that stays
---true (see BJRaceDefaults.ghostBackmarkers). Default false
---@field showGateNametags boolean whether the "Gate N" text label renders above each gate once
---COUNTDOWN/RACE begins (see BJRaceDefaults.showGateNametags). Default false
---@field limitVisibleGates boolean only render the next visibleGateCount upcoming gates once
---COUNTDOWN/RACE begins, hiding every other gate (see BJRaceDefaults.limitVisibleGates). Default
---true
---@field visibleGateCount integer [1,5] (see BJRaceDefaults.visibleGateCount). Default 2
---@field allowTuning boolean only meaningful while vehicleRestrictionStartMode isn't "free" (see
---BJRaceDefaults.allowTuning). Default true
---@field randomizeVehiclePool boolean only meaningful while vehicleRestrictionStartMode == "pool"
---(see BJRaceDefaults.randomizeVehiclePool). Default false

---@class BJRaceSession
---@field id string
---@field raceId integer
---@field starterID integer
---@field joinable boolean
---@field settings BJRaceSessionSettings
---@field state BJRaceSessionState
---@field createdAt integer
---@field startedAt integer?
---@field joinCounter integer? monotonic source of BJRaceParticipant.joinIndex (see
---addParticipant); never decremented on leave
---@field participants tablelib<integer, BJRaceParticipant> index playerID

local M = {
    dependencies = { "services_races", "services_vehiclePresets", "utils_async" },

    ---@type tablelib<string, BJRaceSession>
    sessions = Table(),

    --- non-participant spectators, kept entirely separate from BJRaceSession/participants rather
    --- than folded into the session itself. Session updates already reach every PARTICIPANT via
    --- pushSessionUpdate, but a spectator failing getSelfParticipant() on the client would trip the
    --- exact same "I'm not a participant, this must mean I left" logic a real leaving participant
    --- relies on (onSessionUpdate's own client-side branch). Spectators need their own separate
    --- push (raceSpectateUpdate) and their own separate client-side state (M.spectatingSession),
    --- never touching M.session/the participant code paths at all.
    ---@type tablelib<integer, string> playerID -> sessionId
    spectators = Table(),
}

---@param session BJRaceSession
---@return BJRace?
local function getRace(session)
    return services_races.getById(session.raceId)
end

--- which session (if any) a player currently belongs to, regardless of raceId. Moved up here
--- (was originally only defined much later, for the chat-command ready/leave/cancel/retire front
--- door) so raceStart/raceJoin can both reuse it to enforce "one live session per player at a
--- time". Nothing was previously stopping a player from starting or joining a second session
--- while already a participant in another one (including a different session of the exact same
--- race), which would leave two different BJRaceSession records both containing them as a
--- participant. The client only ever tracks one `M.session`, so whichever session's update
--- happened to arrive last would silently win, with no reliable way to tell which one was "real"
--- from the player's own perspective. Running multiple independent sessions of the same race
--- concurrently (different sets of players) is fine and intentional. A single player being in
--- two of them at once, simultaneously or across different races, never was.
---@param playerID integer
---@return BJRaceSession?
local function findSessionByParticipant(playerID)
    return M.sessions:find(function(s) return s.participants[playerID] ~= nil end)
end

--- how many distinct progress units make up one lap: identical to `#race.gates` for any
--- non-branching race (every gate's own `step` is force-normalized to its array index by
--- sanitizeRace whenever branchingEnabled is off), but the correct, non-inflated count for a
--- branching race, where `#race.gates` also counts parallel alternates that were never actually
--- part of any single run's progress. Used anywhere `#race.gates` used to mean "how many progress
--- units per lap" (leaderboard/backmarker progress math, the bestLapGateTimes snapshot bound);
--- NOT anywhere it means "how many gate OBJECTS exist" (rendering, sector distance calc, which stay
--- on the real array length since sectors are disabled outright for branching races anyway).
---@param race BJRace
---@return integer
local function totalSteps(race)
    local total = 0
    for _, g in ipairs(race.gates) do
        if g.step > total then total = g.step end
    end
    return total
end

---@param a BJRaceGate
---@param b BJRaceGate
---@return number
local function gateDistance(a, b)
    local dx, dy, dz = b.pos.x - a.pos.x, b.pos.y - a.pos.y, b.pos.z - a.pos.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- cumulative straight-line distance from gate 1 up to and including each gate index. Plain
--- gate-to-gate distance, same straight-line-not-driving-line approximation raceMarkers.lua's own
--- `drawPath` already uses to visualize the route, not a real path/nav distance
---@param race BJRace
---@return table<integer, number> gate index -> cumulative distance from gate 1
local function buildCumulativeDistances(race)
    local cum = { [1] = 0 }
    for i = 2, #race.gates do
        cum[i] = cum[i - 1] + gateDistance(race.gates[i - 1], race.gates[i])
    end
    return cum
end

--- records the participant's currently in-progress sector as complete, at lapRelativeNow, and
--- advances currentSector. The one piece of work shared between however many sectors a single
--- gate crossing might complete (see raceGateCrossed's own comment on why that can be more than
--- one) and the final sector's own separate lap-completion trigger.
---@param participant BJRaceParticipant
---@param lapRelativeNow integer
local function completeCurrentSector(participant, lapRelativeNow)
    local sectorDuration = lapRelativeNow - participant.sectorStartMs
    participant.lapSectors[participant.currentSector] = sectorDuration
    if not participant.bestSectorMs[participant.currentSector] or
        sectorDuration < participant.bestSectorMs[participant.currentSector] then
        participant.bestSectorMs[participant.currentSector] = sectorDuration
    end
    participant.sectorStartMs = lapRelativeNow
    participant.currentSector = participant.currentSector + 1
end

--- last gate index belonging to EACH sector (all of them, one pass, not one call per sector),
--- given the race's own gate layout and creator-configured sectorCount (races here can have 60+
--- gates, so a fixed "always 3" would be too coarse). Divided by actual track distance, not gate
--- count. Gates are rarely evenly spaced, so an equal-gate-count split could put most of the lap
--- in one "sector" and almost nothing in another, so this walks the cumulative distance and picks
--- whichever gate first reaches each 1/sectorCount fraction of the total lap distance (including
--- the loopable closing segment, gate N back to gate 1, in that total; see the loopable branch
--- below). On a loopable race, the LAST sector's real endpoint is actually the gate-1 recrossing
--- (the closing segment), one step past whatever this returns for it. raceGateCrossed's own
--- completion check special-cases that, this function doesn't need to know about it.
---
--- Each sector's gate is clamped to be strictly greater than the previous sector's, and to leave
--- at least one gate for every sector still to come. Computing all of them together, in order,
--- is what makes that enforceable. Without it, a big distance jump between two consecutive gates
--- can cross more than one sector's fractional target at once, silently resolving two different
--- sectors onto the exact same physical gate. This was confirmed as the actual mechanism behind
--- "only the first two sectors of a 4-gate/4-sector race ever got a recorded time": whichever
--- sector was "current" when that one gate was finally crossed completed, and every other sector
--- whose own target gate got used up that way then had no crossing left where its number and its
--- gate could ever line up again. The clamp guarantees every sector spans at least one real
--- gate-to-gate segment instead.
---@param race BJRace
---@return integer[] gateIndex per sector, 1-based
local function sectorEndGates(race)
    -- branching paths make index/distance-based sector splitting ambiguous (which branch's
    -- distance counts?). Rather than trying to generalize it, sectors are simply disabled outright
    -- for a branching race: one "sector" spanning the whole lap, same degenerate-count handling
    -- already used below for a race with sectorCount == 1
    if race.branchingEnabled then
        return { #race.gates }
    end

    -- manual mode: boundaries come from whichever gates the creator flagged (gate.sector == true),
    -- sorted/deduped ascending, with the final gate always implicitly closing the last sector even
    -- if not itself flagged (a sector can't end mid-race). Falls back to the automatic distance
    -- split below if nothing was flagged, so a race can never end up with zero real sectors.
    if race.manualSectors then
        local flagged = {}
        for i, g in ipairs(race.gates) do
            if g.sector and i < #race.gates then table.insert(flagged, i) end
        end
        table.insert(flagged, #race.gates)
        if #flagged > 0 then return flagged end
    end

    local count = math.max(1, math.min(race.sectorCount or 3, #race.gates))
    local gates = {}
    if count <= 1 then
        gates[1] = #race.gates
        return gates
    end

    local cum = buildCumulativeDistances(race)
    local totalDist = cum[#race.gates]
    if race.loopable then
        totalDist = totalDist + gateDistance(race.gates[#race.gates], race.gates[1])
    end

    -- gate 1 is the implicit lap-start/closing trigger on a loopable race, never a valid interior
    -- sector boundary of its own. Confirmed the actual root cause of "only sector 1 ever shows,
    -- every best sector attributed to lap 1" on a race where sectorCount equals the gate count: the
    -- automatic split's own math forces sector 1's boundary onto gate 1 whenever there's zero
    -- slack, e.g. a 4-gate/4-sector race. raceGateCrossed's per-gate completion loop can only ever
    -- observe gate 1 being crossed at the exact moment a lap begins or ends, never as an
    -- independent mid-lap checkpoint. So once lap 1 (whose own sector 1 "lucked into" being the
    -- grid-to-gate-1 stretch) reset currentSector back to 1 for lap 2, nothing would ever advance
    -- it again: gate 1 doesn't get crossed again until the next lap boundary, so every later lap
    -- got stuck reporting only a single (bogus, whole-lap-length) "sector 1" and never touched
    -- sectors 2+ at all. Reserving gate 1 entirely for loopable races (search starts at gate 2, and
    -- the "leave room for what's left" upper bound gets one extra gate of slack to match, since the
    -- final sector never competes for a searched gate of its own either way) fixes this at the
    -- source instead of special-casing it in the completion logic.
    local searchFloor = race.loopable and 1 or 0
    local lastAssigned = searchFloor
    for s = 1, count - 1 do
        local found
        if totalDist <= 0 then
            -- degenerate (every gate at/near the same position) : distance can't distinguish
            -- anything, fall back to an even gate-count split instead of returning garbage
            found = math.ceil(#race.gates * s / count)
        else
            local target = totalDist * (s / count)
            found = #race.gates
            for i = lastAssigned + 1, #race.gates do
                if cum[i] >= target then
                    found = i
                    break
                end
            end
        end
        -- never collapse onto (or behind) the previous sector, and always leave at least one gate
        -- for each sector still to come (including the final one, always gates[count] = #gates)
        found = math.max(found, lastAssigned + 1)
        found = math.min(found, #race.gates - (count - s) + searchFloor)
        gates[s] = found
        lastAssigned = found
    end
    gates[count] = #race.gates
    return gates
end

---@param session BJRaceSession
---@return {id: string, raceId: integer, raceName: string, starterName: string, joinable: boolean,
---participantCount: integer, maxParticipants: integer, state: BJRaceSessionState}
local function summarize(session)
    local race = getRace(session)
    local starter = session.participants[session.starterID]
    return {
        id = session.id,
        raceId = session.raceId,
        raceName = race and race.name or "?",
        starterName = starter and starter.playerName or "?",
        joinable = session.joinable,
        participantCount = session.participants:length(),
        maxParticipants = race and #race.startPositions or 0,
        state = session.state,
    }
end

--- builds the outbound session payload shared by pushSessionUpdate and raceSpectate: participants
--- as a plain array (not the internal Table), the computed leaderboard, and, once actually racing,
--- a server-computed elapsed duration (raceElapsedMs), not a timestamp. session.startedAt is in
--- the server's own GetCurrentTime() clock domain, meaningless compared directly against a client's
--- own GetCurrentTimeMillis(). A plain duration crosses that boundary safely, letting any client
--- (including one that only started watching mid-race, e.g. a spectator) derive a correct elapsed
--- time locally without needing to have observed the actual RACE transition itself.
---@param session BJRaceSession
---@return table
local function buildSessionPayload(session)
    local payload = table.clone(session)
    payload.participants = session.participants:values()
    payload.leaderboard = M.computeLeaderboard(session)
    if session.state == "RACE" and session.startedAt then
        payload.raceElapsedMs = math.floor((GetCurrentTime() - session.startedAt) * 1000)
    end
    -- lobby-phase countdown feedback, same "push a duration, not a timestamp" reasoning as
    -- raceElapsedMs above (session.createdAt is in the server's own GetCurrentTime() clock domain,
    -- meaningless compared directly against a client's GetCurrentTimeMillis()). Only meaningful
    -- for a real joinable multiplayer lobby. A non-joinable (solo/private) session never schedules
    -- either of these timers server-side (raceStart only does so when session.joinable), so
    -- there's nothing to report for one. gridReadySecondsLeft counts down to the earliest moment
    -- an already-fully-ready lobby is allowed to actually start (see tryStartFromGrid's own
    -- gridReadyTimeout check: it's a floor on lobby duration, not a "start regardless of who's
    -- ready" trigger, so the client decides for itself whether it's actually relevant to show,
    -- based on whether everyone's ready yet). gridTimeoutSecondsLeft counts down to the hard
    -- deadline where anyone still unready gets kicked and the lobby starts (or closes) regardless.
    if session.state == "GRID" and session.joinable then
        local gridElapsedSec = GetCurrentTime() - session.createdAt
        payload.gridReadySecondsLeft = math.max(0, math.ceil(session.settings.gridReadyTimeout - gridElapsedSec))
        payload.gridTimeoutSecondsLeft = math.max(0, math.ceil(session.settings.gridTimeout - gridElapsedSec))
    end
    -- backmarker flag for the optional "ghost backmarkers" setting (client decides whether to
    -- actually act on it, see raceRunner.lua). Deliberately not a raw currentLap comparison.
    -- currentLap increments the instant gate 1 is (re)crossed, so "leader.currentLap >
    -- p.currentLap" alone would flag someone as a lapped backmarker the moment the leader crosses
    -- the line a fraction of a second ahead of them, even mid-pack and neck-and-neck, not actually
    -- lapped at all. Same class of bug (and same fix) as the client HUD's own "+1 lap" indicator.
    -- See raceRunner.lua's describeOpponent: real gate-progress gap, only counted a genuine
    -- backmarker once it's actually >= one full lap's worth of gates. leaderboard is already
    -- sorted "most progress first", so index 1 is the leader.
    --
    -- BACKMARKER_GATE_SAFETY_MARGIN shaves one gate off that full-lap threshold on purpose, per
    -- direct request: ghosting exactly at the moment of the pass is too late to matter for
    -- collision safety, since the two vehicles are already about to occupy the same space at that
    -- instant. Triggering a gate earlier gives the about-to-be-lapped car time to actually be
    -- ghosted before the leader arrives, not right as they do.
    if session.settings.ghostBackmarkers and payload.leaderboard[1] then
        local race = getRace(session)
        local totalGates = race and totalSteps(race) or 0
        if totalGates > 0 then
            local BACKMARKER_GATE_SAFETY_MARGIN = 1
            local threshold = math.max(1, totalGates - BACKMARKER_GATE_SAFETY_MARGIN)
            local leader = payload.leaderboard[1]
            local leaderProgress = (leader.currentLap - 1) * totalGates + (leader.currentGate or 0)
            table.forEach(payload.participants, function(p)
                if p.finished or p.dnf then
                    p.backmarker = false
                    return
                end
                local pProgress = (p.currentLap - 1) * totalGates + (p.currentGate or 0)
                p.backmarker = (leaderProgress - pProgress) >= threshold
            end)
        end
    end
    return payload
end

--- pushes the full session (with leaderboard) to every current participant, and the exact same
--- payload under a different event name (so the client never confuses the two) to anyone
--- currently spectating this session. See M.spectators's own comment for why that has to be a
--- separate channel rather than just also being sent "raceSessionUpdate"
---@param session BJRaceSession
local function pushSessionUpdate(session)
    local payload = buildSessionPayload(session)
    session.participants:forEach(function(_, playerID)
        communications_tx.sendToPlayer(playerID, "raceSessionUpdate", payload)
    end)
    M.spectators:forEach(function(sessionId, playerID)
        if sessionId == session.id then
            communications_tx.sendToPlayer(playerID, "raceSpectateUpdate", payload)
        end
    end)
end

--- pushes every session worth showing on the main HUD to every connected player: GRID+joinable
--- ones to join (the original scope, discovery ahead of the deprioritized race-invite UI), plus
--- COUNTDOWN/RACE ones to spectate. A session only becomes something worth watching once it
--- actually has a race in progress, and stops being listed once it's torn down like any other.
--- `summarize`'s own `state` field is what the client uses to tell "Join" apart from "Spectate".
local function pushOpenSessionsList()
    local visible = M.sessions:filter(function(s)
        return (s.state == "GRID" and s.joinable) or
            s.state == "COUNTDOWN" or s.state == "RACE"
    end):map(summarize):values()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "raceSessionsList", visible)
end

---@param session BJRaceSession
local function removeSession(session)
    utils_async.removeTask("BJRaceGrid-" .. session.id .. "-readyTimeout")
    utils_async.removeTask("BJRaceGrid-" .. session.id .. "-gridTimeout")
    utils_async.removeTask("BJRaceGrid-" .. session.id .. "-countdown")
    utils_async.removeTask("BJRaceGrid-" .. session.id .. "-cleanup")
    -- tell participants before the session disappears. Without this, clients never learn a
    -- session ended (only ever pushed updates while it existed), so anything derived from it
    -- client-side (gate markers, etc.) would linger forever
    session.participants:forEach(function(_, playerID)
        communications_tx.sendToPlayer(playerID, "raceSessionRemoved", session.id)
    end)
    -- same courtesy for anyone spectating it, on their own separate channel. Also actually frees
    -- them to spectate something else afterward instead of being stuck "watching" a dead session id
    M.spectators:forEach(function(sessionId, playerID)
        if sessionId == session.id then
            communications_tx.sendToPlayer(playerID, "raceSpectateRemoved", session.id)
            M.spectators[playerID] = nil
        end
    end)
    M.sessions[session.id] = nil
    pushOpenSessionsList()
end

--- sorts participants for leaderboard display: not-DNF first, most laps, most gates, fastest
---@param session BJRaceSession
---@return BJRaceParticipant[]
local function computeLeaderboard(session)
    local list = session.participants:values()
    table.sort(list, function(a, b)
        if a.dnf ~= b.dnf then return not a.dnf end
        if a.finished ~= b.finished then return a.finished end
        if a.currentLap ~= b.currentLap then return a.currentLap > b.currentLap end
        if a.currentGate ~= b.currentGate then return a.currentGate > b.currentGate end
        local aTime = a.gateTimes[a.currentGate] or math.huge
        local bTime = b.gateTimes[b.currentGate] or math.huge
        return aTime < bTime
    end)
    return list
end

---@param race BJRace
---@param overrides table?
---@return BJRaceSessionSettings
local function buildSettings(race, overrides)
    overrides = overrides or {}
    local defaults = race.defaults or {}

    -- dnfEnabled defaults to true (matches the previously-hardcoded always-on behavior) unless
    -- explicitly turned off by either the starter's override or the race's own defaults. An
    -- override is only actually "set" when the field is present at all, not merely falsy
    local dnfEnabled = true
    if overrides.dnfEnabled ~= nil then
        dnfEnabled = overrides.dnfEnabled == true
    elseif defaults.dnfEnabled ~= nil then
        dnfEnabled = defaults.dnfEnabled == true
    end

    -- resetPenaltyEnabled defaults OFF (unlike dnfEnabled) : this is a new, optional deterrent,
    -- not a previously-hardcoded-on behavior being formalized, so an existing race/session
    -- shouldn't suddenly start penalizing resets just because this field didn't exist before
    local resetPenaltyEnabled = false
    if overrides.resetPenaltyEnabled ~= nil then
        resetPenaltyEnabled = overrides.resetPenaltyEnabled == true
    elseif defaults.resetPenaltyEnabled ~= nil then
        resetPenaltyEnabled = defaults.resetPenaltyEnabled == true
    end

    local autoSpectateOnFinish = true
    if overrides.autoSpectateOnFinish ~= nil then
        autoSpectateOnFinish = overrides.autoSpectateOnFinish == true
    elseif defaults.autoSpectateOnFinish ~= nil then
        autoSpectateOnFinish = defaults.autoSpectateOnFinish == true
    end

    local disableNodegrabber = true
    if overrides.disableNodegrabber ~= nil then
        disableNodegrabber = overrides.disableNodegrabber == true
    elseif defaults.disableNodegrabber ~= nil then
        disableNodegrabber = defaults.disableNodegrabber == true
    end

    local disableCameras = true
    if overrides.disableCameras ~= nil then
        disableCameras = overrides.disableCameras == true
    elseif defaults.disableCameras ~= nil then
        disableCameras = defaults.disableCameras == true
    end

    local disableGravityChange = true
    if overrides.disableGravityChange ~= nil then
        disableGravityChange = overrides.disableGravityChange == true
    elseif defaults.disableGravityChange ~= nil then
        disableGravityChange = defaults.disableGravityChange == true
    end

    -- a pure per-start choice, no race.defaults fallback layer like every other setting here,
    -- since there's no meaningful "race-authored default" for which start-time MODE gets
    -- preselected beyond what the client UI itself already does (defaults to "raceDefined" when
    -- the race has an authored restriction, else "free"; see windows/main/races/app.js)
    local vehicleRestrictionStartMode = "free"
    local vehicleRestrictionModel, vehicleRestrictionParts, vehicleRestrictionVars,
    vehicleRestrictionPaints, vehicleRestrictionLabel, vehicleRestrictionPool
    if overrides.vehicleRestrictionMode == "raceDefined" then
        vehicleRestrictionStartMode = "raceDefined"
    elseif overrides.vehicleRestrictionMode == "single" and
        type(overrides.vehicleRestrictionModel) == "string" and #overrides.vehicleRestrictionModel > 0 and
        type(overrides.vehicleRestrictionParts) == "table" and table.length(overrides.vehicleRestrictionParts) > 0 then
        vehicleRestrictionStartMode = "single"
        vehicleRestrictionModel = overrides.vehicleRestrictionModel
        vehicleRestrictionParts = overrides.vehicleRestrictionParts
        vehicleRestrictionVars = type(overrides.vehicleRestrictionVars) == "table" and
            overrides.vehicleRestrictionVars or {}
        vehicleRestrictionPaints = type(overrides.vehicleRestrictionPaints) == "table" and
            overrides.vehicleRestrictionPaints or {}
        vehicleRestrictionLabel = type(overrides.vehicleRestrictionLabel) == "string" and
            overrides.vehicleRestrictionLabel or "?"
    elseif overrides.vehicleRestrictionMode == "pool" and tonumber(overrides.vehicleRestrictionPoolPresetId) then
        -- resolved once, here, to the preset's real entries. Never re-read live from the preset
        -- again for the rest of this session, same "snapshot at start" treatment "single" mode's
        -- own capture gets, so a host editing/deleting the preset mid-session can't retroactively
        -- change what an already-running session enforces
        local preset = services_vehiclePresets.getById(tonumber(overrides.vehicleRestrictionPoolPresetId))
        if preset and table.isArray(preset.entries) and #preset.entries > 0 then
            vehicleRestrictionStartMode = "pool"
            vehicleRestrictionPool = preset.entries
            vehicleRestrictionLabel = preset.name
        end
    end
    -- anything else (an unrecognized value, or a "pool" override whose preset no longer exists)
    -- silently falls through to "free" rather than erroring

    local ghostOnCountdown = true
    if overrides.ghostOnCountdown ~= nil then
        ghostOnCountdown = overrides.ghostOnCountdown == true
    elseif defaults.ghostOnCountdown ~= nil then
        ghostOnCountdown = defaults.ghostOnCountdown == true
    end

    local disableCollisions = false
    if overrides.disableCollisions ~= nil then
        disableCollisions = overrides.disableCollisions == true
    elseif defaults.disableCollisions ~= nil then
        disableCollisions = defaults.disableCollisions == true
    end

    local ghostBackmarkers = false
    if overrides.ghostBackmarkers ~= nil then
        ghostBackmarkers = overrides.ghostBackmarkers == true
    elseif defaults.ghostBackmarkers ~= nil then
        ghostBackmarkers = defaults.ghostBackmarkers == true
    end

    local showGateNametags = false
    if overrides.showGateNametags ~= nil then
        showGateNametags = overrides.showGateNametags == true
    elseif defaults.showGateNametags ~= nil then
        showGateNametags = defaults.showGateNametags == true
    end

    local limitVisibleGates = true
    if overrides.limitVisibleGates ~= nil then
        limitVisibleGates = overrides.limitVisibleGates == true
    elseif defaults.limitVisibleGates ~= nil then
        limitVisibleGates = defaults.limitVisibleGates == true
    end
    -- used to be forced off outright for a branching race (a sliding "next N gates" window has no
    -- meaning for a plain linear index once a route can fork). raceMarkers.lua's own
    -- visibleGateSetBranching now walks the real `parents` graph instead of a linear index, so the
    -- setting is meaningful (and left as whatever the host actually configured) for both now.

    local allowTuning = true
    if overrides.allowTuning ~= nil then
        allowTuning = overrides.allowTuning == true
    elseif defaults.allowTuning ~= nil then
        allowTuning = defaults.allowTuning == true
    end

    local randomizeVehiclePool = false
    if overrides.randomizeVehiclePool ~= nil then
        randomizeVehiclePool = overrides.randomizeVehiclePool == true
    elseif defaults.randomizeVehiclePool ~= nil then
        randomizeVehiclePool = defaults.randomizeVehiclePool == true
    end

    ---@type BJRaceSessionSettings
    local settings = {
        laps = race.loopable and (tonumber(overrides.laps) or defaults.laps) or 1,
        respawnStrategy = table.includes(services_races.RESPAWN_STRATEGIES, overrides.respawnStrategy)
            and overrides.respawnStrategy or defaults.respawnStrategy or services_races.RESPAWN_STRATEGIES
            .LASTCHECKPOINT,
        placementMode = table.includes(services_races.PLACEMENT_MODES, overrides.placementMode)
            and overrides.placementMode
            or (table.includes(services_races.PLACEMENT_MODES, defaults.placementMode)
                and defaults.placementMode)
            or services_races.PLACEMENT_MODES.RANDOM,
        gridTimeout = math.max(10, tonumber(overrides.gridTimeout) or defaults.gridTimeout or 180),
        gridReadyTimeout = math.max(0, tonumber(overrides.gridReadyTimeout) or defaults.gridReadyTimeout or 10),
        -- was clamped to [3,30], a hidden ceiling/floor mismatched with the client slider's own
        -- [0,30] range (typeable up to a 600 hard-cap, see the editor/start-options sliders), so a
        -- client-set 0-2s countdown or anything above 30s was silently overridden right back down
        -- at race-start time without any visible feedback. Widened to match.
        countdown = math.clamp(tonumber(overrides.countdown) or defaults.countdown or 10, 0, 600),
        -- stall-based DNF, only meaningful under "norespawn" (the client gates on that too, this
        -- is just the toggle/duration for it)
        dnfEnabled = dnfEnabled,
        dnfTimeout = math.max(3, tonumber(overrides.dnfTimeout) or defaults.dnfTimeout or 30),
        resetPenaltyEnabled = resetPenaltyEnabled,
        resetPenaltySeconds = math.max(1, tonumber(overrides.resetPenaltySeconds) or defaults.resetPenaltySeconds or 5),
        autoSpectateOnFinish = autoSpectateOnFinish,
        disableNodegrabber = disableNodegrabber,
        disableCameras = disableCameras,
        disableGravityChange = disableGravityChange,
        vehicleRestrictionStartMode = vehicleRestrictionStartMode,
        vehicleRestrictionModel = vehicleRestrictionModel,
        vehicleRestrictionParts = vehicleRestrictionParts,
        vehicleRestrictionVars = vehicleRestrictionVars,
        vehicleRestrictionPaints = vehicleRestrictionPaints,
        vehicleRestrictionLabel = vehicleRestrictionLabel,
        vehicleRestrictionPool = vehicleRestrictionPool,
        ghostOnCountdown = ghostOnCountdown,
        disableCollisions = disableCollisions,
        ghostBackmarkers = ghostBackmarkers,
        showGateNametags = showGateNametags,
        limitVisibleGates = limitVisibleGates,
        visibleGateCount = math.max(1, math.min(math.floor(tonumber(overrides.visibleGateCount) or
            defaults.visibleGateCount or 2), 5)),
        allowTuning = allowTuning,
        randomizeVehiclePool = randomizeVehiclePool,
    }
    if settings.laps then
        settings.laps = math.max(1, math.floor(settings.laps))
    end
    return settings
end

---@param session BJRaceSession
---@param playerID integer
---@param playerName string
local function addParticipant(session, playerID, playerName)
    -- monotonic join counter, never decremented on leave : joinIndex must stay unique and
    -- ordered even after someone mid-list leaves the lobby
    session.joinCounter = (session.joinCounter or 0) + 1
    -- "manual" placement : seed the lowest free slot immediately so the lobby always shows a
    -- complete, host-rearrangeable assignment instead of a pile of "unassigned" entries the
    -- host would have to place one by one before starting
    local gridSlot
    if session.settings.placementMode == services_races.PLACEMENT_MODES.MANUAL then
        local race = getRace(session)
        local maxSlots = race and #race.startPositions or 0
        for slot = 1, maxSlots do
            if not session.participants:any(function(p) return p.gridSlot == slot end) then
                gridSlot = slot
                break
            end
        end
    end
    session.participants[playerID] = {
        playerID = playerID,
        playerName = playerName,
        joinIndex = session.joinCounter,
        gridSlot = gridSlot,
        ready = false,
        currentGate = 0,
        lastCrossedGate = 0,
        currentLap = 1,
        gateTimes = {},
        lapTimes = {},
        bestLapMs = nil,
        bestLapGateTimes = nil,
        liveDeltaMs = nil,
        currentSector = 1,
        sectorStartMs = 0,
        lapSectors = {},
        lapSectorHistory = {},
        bestSectorMs = {},
        finished = false,
        dnf = false,
        lastProgressTime = GetCurrentTime(),
    }
end

--- begins the pre-race countdown. Assigns start positions per the session's placementMode,
--- freezes the field, schedules the actual race start
---@param session BJRaceSession
local function beginCountdown(session)
    local race = getRace(session)
    if not race then return removeSession(session) end

    session.state = "COUNTDOWN"
    local mode = session.settings.placementMode
    if mode == services_races.PLACEMENT_MODES.MANUAL then
        -- gridSlot is the authoritative assignment (auto-seeded on join, rearranged by the host
        -- via raceSetGridSlot). The fallback path below is purely defensive: a participant can
        -- only ever lack a valid, unique slot through a bug or stray data, but silently stacking
        -- two cars on one slot (or none) is bad enough to be worth guarding against anyway :
        -- anyone unplaceable gets the free slots, in join order
        local taken = {}
        local unassigned = {}
        session.participants:forEach(function(p)
            local slot = p.gridSlot
            if slot and race.startPositions[slot] and not taken[slot] then
                taken[slot] = true
                p.startPosition = race.startPositions[slot]
            else
                table.insert(unassigned, p)
            end
        end)
        table.sort(unassigned, function(a, b) return (a.joinIndex or 0) < (b.joinIndex or 0) end)
        local nextFree = 1
        for _, p in ipairs(unassigned) do
            while taken[nextFree] and nextFree < #race.startPositions do
                nextFree = nextFree + 1
            end
            taken[nextFree] = true
            p.startPosition = race.startPositions[nextFree]
        end
    else
        -- "deterministic" : lobby join order, starter first. This replaces the old implicit
        -- behavior, which iterated session.participants (keyed by playerID) with pairs() and was
        -- therefore arbitrary, not actually join-ordered. "random" : a real shuffle on top
        local participants = session.participants:values()
        table.sort(participants, function(a, b) return (a.joinIndex or 0) < (b.joinIndex or 0) end)
        if mode == services_races.PLACEMENT_MODES.RANDOM then
            participants = table.shuffle(participants)
        end
        table.forEach(participants, function(p, i)
            local slot = race.startPositions[((i - 1) % #race.startPositions) + 1]
            p.startPosition = slot
        end)
    end

    utils_async.delayTask(function() M.beginRace(session.id) end,
        session.settings.countdown, "BJRaceGrid-" .. session.id .. "-countdown")
    pushSessionUpdate(session)
    pushOpenSessionsList()
end

---@param sessionId string
local function beginRace(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "COUNTDOWN" then return end

    session.state = "RACE"
    session.startedAt = GetCurrentTime()
    session.participants:forEach(function(p)
        p.currentGate = 0
        p.lastCrossedGate = 0
        p.currentLap = 1
        p.gateTimes = {}
        p.lapTimes = {}
        p.bestLapMs = nil
        p.bestLapGateTimes = nil
        p.liveDeltaMs = nil
        p.currentSector = 1
        p.sectorStartMs = 0
        p.lapSectors = {}
        p.lapSectorHistory = {}
        p.bestSectorMs = {}
        p.finished = false
        p.dnf = false
        p.lastProgressTime = GetCurrentTime()
    end)
    pushSessionUpdate(session)
end

---@param session BJRaceSession
local function checkSessionComplete(session)
    if session.participants:every(function(p) return p.finished or p.dnf end) then
        session.state = "FINISHED"
        pushSessionUpdate(session)
        utils_async.delayTask(function() removeSession(session) end,
            10, "BJRaceGrid-" .. session.id .. "-cleanup")
    end
end

--- shared by finishParticipant and raceDNF. A retiring or auto-DNF'd participant's own best
--- completed lap still counts, per direct request: only a full-race finish used to submit
--- anything at all, silently discarding a perfectly good lap from anyone who didn't finish every
--- lap of the attempt.
---@param session BJRaceSession
---@param participant BJRaceParticipant
---@param timeMs integer the lap time being submitted
local function trySubmitTime(session, participant, timeMs)
    -- per direct request: an attempt started with any anticheat protection turned off never
    -- submits a time at all, finish or DNF alike. Those toggles exist specifically to keep
    -- recorded times honest, so a run with one disabled was never a valid record/PB attempt to
    -- begin with, regardless of how it ends. Slow-motion/pausing isn't in this list: it's no
    -- longer a toggle at all, always forced off unconditionally (see raceRunner.lua's
    -- onBJRequestRestrictions/onUpdate), so there's nothing to check here for it.
    local s = session.settings
    if not (s.disableNodegrabber and s.disableCameras and s.disableGravityChange) then
        return
    end
    -- same reasoning, for the vehicle restriction's own per-start choice. A race restricted to a
    -- specific vehicle/pool exists specifically to make its leaderboard an apples-to-apples
    -- comparison, so an attempt that didn't honor the race's own authored restriction, whether it
    -- went fully unrestricted ("free") or used a different, start-time-only restriction instead
    -- ("single"/"pool"), was never a valid PB/record attempt for this race either. Only actually
    -- matters for a race that has an authored restriction to begin with; a "free" race is never
    -- affected by this check regardless of what start mode was picked.
    local race = getRace(session)
    if race and race.vehicleRestrictionMode ~= "free" and s.vehicleRestrictionStartMode ~= "raceDefined" then
        return
    end
    participant.isNewPB, participant.isNewRecord = services_races.submitTime(
        session.raceId, participant.playerName, participant.vehicleModel or "", timeMs)
end

---@param session BJRaceSession
---@param participant BJRaceParticipant
local function finishParticipant(session, participant)
    participant.finished = true
    local bestLap = math.min(table.unpack(participant.lapTimes))
    trySubmitTime(session, participant, bestLap)
    checkSessionComplete(session)
end

---@param session BJRaceSession whose GRID phase just ended (start-now, or force-cut via timers)
local function tryStartFromGrid(session)
    -- diagnostics: "grid timer settings don't seem to do anything" reported after a real 2-player
    -- test, and static tracing didn't turn up an obvious bug. Logging every actual decision point
    print(string.format(
        "[BJ raceGrid] tryStartFromGrid session=%s state=%s joinable=%s participants=%d allReady=%s elapsed=%d gridReadyTimeout=%s",
        session.id, session.state, tostring(session.joinable), session.participants:length(),
        tostring(session.participants:every(function(p) return p.ready end)),
        GetCurrentTime() - session.createdAt, tostring(session.settings.gridReadyTimeout)))
    if session.state ~= "GRID" then return end
    if not session.joinable then
        -- solo path: starts the instant its lone participant is ready, no grace period
        if session.participants:every(function(p) return p.ready end) then
            beginCountdown(session)
        end
        return
    end
    if session.participants:length() > 0 and
        session.participants:every(function(p) return p.ready end) and
        GetCurrentTime() - session.createdAt >= session.settings.gridReadyTimeout then
        print("[BJ raceGrid] tryStartFromGrid: starting countdown now")
        beginCountdown(session)
    end
end

---@param ctxt BJSContext
---@param raceId integer
---@param opts {joinable: boolean?, laps: integer?, respawnStrategy: string?, placementMode: string?, gridTimeout: integer?, gridReadyTimeout: integer?, countdown: integer?, dnfEnabled: boolean?, dnfTimeout: integer?, resetPenaltyEnabled: boolean?, resetPenaltySeconds: integer?, autoSpectateOnFinish: boolean?, disableNodegrabber: boolean?, disableCameras: boolean?, disableGravityChange: boolean?, vehicleRestrictionMode: string?, vehicleRestrictionModel: string?, vehicleRestrictionParts: table?, vehicleRestrictionVars: table?, vehicleRestrictionPaints: table?, vehicleRestrictionLabel: string?, vehicleRestrictionPoolPresetId: integer?, ghostOnCountdown: boolean?, disableCollisions: boolean?, ghostBackmarkers: boolean?, showGateNametags: boolean?, limitVisibleGates: boolean?, visibleGateCount: integer?, allowTuning: boolean?}?
local function raceStart(ctxt, raceId, opts)
    if not ctxt.sender then return end
    -- multiple independent sessions of the SAME race running concurrently (different players) is
    -- fine. This one player already being a participant in another session (same race or not) is
    -- what actually isn't; see findSessionByParticipant's own comment for why
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.race.alreadyInSession", ctxt.sender.lang))
    end
    local race = services_races.getById(raceId)
    if not race or race.mode ~= services_races.MODES.GRID then return end
    if #race.startPositions == 0 then return end

    opts = opts or {}
    ---@type BJRaceSession
    local session = {
        id = UUID(),
        raceId = raceId,
        starterID = ctxt.senderID,
        -- a race with only one grid slot can never actually be joined (raceJoin's own cap is
        -- #race.startPositions). Force non-joinable regardless of what the client/defaults say,
        -- rather than letting it show up in the open-sessions list as a dead end.
        --
        -- Real bug fixed here: this used to be a plain `opts.joinable == true or
        -- (race.defaults and race.defaults.joinable) == true` OR, which can't represent an
        -- explicit "off" override. A player who unchecked "Multiplayer" for this one attempt
        -- (opts.joinable == false, always sent as a real boolean by the start-options panel, never
        -- omitted) still ended up with session.joinable == true whenever the race's own saved
        -- default had Multiplayer on, silently ignoring their override. That's why the grid-ready/
        -- grid-timeout timers below (correctly gated behind `if session.joinable`) still looked
        -- "active" even with Multiplayer deselected. Fixed with the same override -> default ->
        -- fallback resolution every other per-start setting in this function already uses.
        joinable = (function()
            if #race.startPositions <= 1 then return false end
            if opts.joinable ~= nil then return opts.joinable == true end
            return race.defaults ~= nil and race.defaults.joinable == true
        end)(),
        settings = buildSettings(race, opts),
        state = "GRID",
        createdAt = ctxt.time,
        participants = Table(),
    }
    addParticipant(session, ctxt.senderID, ctxt.sender.playerName)
    M.sessions[session.id] = session

    print(string.format(
        "[BJ raceGrid] raceStart session=%s joinable=%s gridReadyTimeout=%s gridTimeout=%s (opts.gridReadyTimeout=%s opts.gridTimeout=%s)",
        session.id, tostring(session.joinable), tostring(session.settings.gridReadyTimeout),
        tostring(session.settings.gridTimeout), tostring(opts.gridReadyTimeout), tostring(opts.gridTimeout)))

    if session.joinable then
        utils_async.delayTask(function() tryStartFromGrid(session) end,
            session.settings.gridReadyTimeout, "BJRaceGrid-" .. session.id .. "-readyTimeout")
        utils_async.delayTask(function()
            print(string.format("[BJ raceGrid] gridTimeout fired for session=%s", session.id))
            local s = M.sessions[session.id]
            if not s or s.state ~= "GRID" then
                print(string.format("[BJ raceGrid] gridTimeout: session gone or not in GRID (state=%s)",
                    s and s.state or "nil"))
                return
            end
            local kicked = s.participants:filter(function(p) return not p.ready end):values()
            s.participants = s.participants:filter(function(p) return p.ready end)
            -- notify anyone kicked for not readying up in time directly. pushSessionUpdate
            -- only ever reaches current participants, and they're no longer one
            table.forEach(kicked, function(p)
                communications_tx.sendToPlayer(p.playerID, "raceSessionRemoved", s.id)
            end)
            if s.participants:length() == 0 then
                return removeSession(s)
            end
            beginCountdown(s)
        end, session.settings.gridTimeout, "BJRaceGrid-" .. session.id .. "-gridTimeout")
    end

    pushSessionUpdate(session)
    pushOpenSessionsList()
    return session.id
end

---@param ctxt BJSContext
---@param sessionId string
local function raceJoin(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "GRID" or not session.joinable then return end
    if session.participants[ctxt.senderID] then return end
    -- see raceStart's own identical check / findSessionByParticipant's comment. Joining a second
    -- session while already a participant in another one (this one included, already covered by
    -- the check just above, or any other) is what actually isn't allowed. Multiple concurrent
    -- sessions of the same race, with different players in each, is fine
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.race.alreadyInSession", ctxt.sender.lang))
    end
    local race = getRace(session)
    if not race or session.participants:length() >= #race.startPositions then return end

    addParticipant(session, ctxt.senderID, ctxt.sender.playerName)
    pushSessionUpdate(session)
    pushOpenSessionsList()
end

--- watch a session without becoming a participant in it: a plain camera-follow + info-panel feed,
--- entirely separate from BJRaceSession/participants (see M.spectators's own comment). Switching
--- directly from spectating one session to another is fine (just re-sends). Spectating while
--- actually racing yourself is not: nothing useful to watch while you're mid-attempt yourself, and
--- it'd be ambiguous which vehicle the camera should even be attached to.
---@param ctxt BJSContext
---@param sessionId string
local function raceSpectate(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state == "GRID" or session.state == "FINISHED" then return end
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.race.alreadyInSession", ctxt.sender.lang))
    end

    M.spectators[ctxt.senderID] = sessionId
    communications_tx.sendToPlayer(ctxt.senderID, "raceSpectateUpdate", buildSessionPayload(session))
end

---@param ctxt BJSContext
local function raceStopSpectate(ctxt)
    if not ctxt.sender then return end
    local sessionId = M.spectators[ctxt.senderID]
    if not sessionId then return end
    M.spectators[ctxt.senderID] = nil
    communications_tx.sendToPlayer(ctxt.senderID, "raceSpectateRemoved", sessionId)
end

---@param ctxt BJSContext
---@param sessionId string
local function raceLeave(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or not session.participants[ctxt.senderID] then return end

    session.participants[ctxt.senderID] = nil
    -- notify the leaving player directly. Once removed, pushSessionUpdate's forEach over
    -- session.participants will never reach them again, so without this their own client never
    -- learns the leave actually succeeded (stuck thinking they're still in a live session)
    communications_tx.sendToPlayer(ctxt.senderID, "raceSessionRemoved", sessionId)
    if session.participants:length() == 0 then
        return removeSession(session)
    end
    if ctxt.senderID == session.starterID then
        session.starterID = session.participants:keys()[1]
    end
    if session.state == "GRID" then
        tryStartFromGrid(session)
    elseif session.state == "RACE" then
        -- unlike a disconnect mid-race (onPlayerDisconnect, which marks the departing player DNF
        -- and stays), an explicit Leave removes them from session.participants entirely, meaning
        -- they're no longer counted at all, not even as a finished/dnf entry. If they were the
        -- last participant still actively racing, every remaining participant (all long since
        -- finished/dnf, spectating) now satisfies checkSessionComplete's "everyone's done" check,
        -- but nothing was re-checking that here. The session just sat in RACE state forever with
        -- nobody left to finish it, `removeSession`/the client's own onSessionRemoved never fired
        -- for anyone still in it, and every piece of state that only ever gets cleaned up there
        -- (the "you're in a session" status panel, a spectating participant's saved vehicle) never
        -- got cleaned up either. finishParticipant/raceDNF/onPlayerDisconnect(RACE) already all
        -- call this after any change that could complete the session; this path just never did.
        checkSessionComplete(session)
    end
    pushSessionUpdate(session)
    pushOpenSessionsList()
end

---@param ctxt BJSContext
---@param sessionId string
local function raceCancel(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session then return end
    if session.starterID ~= ctxt.senderID and
        not services_permissions.isStaff(ctxt.sender.playerName) then
        return
    end
    removeSession(session)
end

---@param ctxt BJSContext
---@param sessionId string
---@param ready boolean
---@param model string? the client's own current vehicle jbeam, sent alongside becoming ready:
---see raceRunner.lua's ready() for why this is the reliable way to get it, not
---services_players.players[...].currentVehicle (a real, confirmed id-space mismatch bug there)
local function raceReady(ctxt, sessionId, ready, model)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "GRID" then return end
    local participant = session.participants[ctxt.senderID]
    if not participant then return end

    participant.ready = ready == true
    if participant.ready and type(model) == "string" and model ~= "" then
        participant.vehicleModel = model
    end
    if participant.ready then
        tryStartFromGrid(session)
    end
    if M.sessions[sessionId] then -- session may have just been consumed by tryStartFromGrid
        pushSessionUpdate(session)
    end
end

--- "manual" placement mode's lobby-time slot assignment: the starter (or staff) moves any
--- participant onto any grid slot while still in GRID. Assigning a slot someone else already
--- occupies swaps the two participants' slots rather than erroring or silently unseating the
--- occupant, so the host can freely rearrange a full grid without ever passing through an
--- invalid "two players, one slot" state.
---@param ctxt BJSContext
---@param sessionId string
---@param targetPlayerID integer whose slot is being set
---@param slot integer 1-based index into race.startPositions
local function raceSetGridSlot(ctxt, sessionId, targetPlayerID, slot)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "GRID" then return end
    if session.settings.placementMode ~= services_races.PLACEMENT_MODES.MANUAL then return end
    if session.starterID ~= ctxt.senderID and
        not services_permissions.isStaff(ctxt.sender.playerName) then
        return
    end
    local race = getRace(session)
    local target = session.participants[tonumber(targetPlayerID)]
    slot = tonumber(slot)
    if not race or not target or not slot then return end
    slot = math.floor(slot)
    if not race.startPositions[slot] then return end
    if target.gridSlot == slot then return end

    local occupant = session.participants:find(function(p) return p.gridSlot == slot end)
    if occupant then
        occupant.gridSlot = target.gridSlot
    end
    target.gridSlot = slot
    pushSessionUpdate(session)
end

---@param playerID integer
--- unreadies a GRID participant the moment their vehicle's actual config changes (parts, tuning,
--- anything BeamMP's own onVehicleEdited fires for), per direct report. "Ready" is supposed to mean
--- "the vehicle I'm about to race is locked in as-is" ; letting it silently keep counting as ready
--- after the player edited parts/retuned post-ready-up (no re-confirmation) meant tryStartFromGrid
--- could launch a session on a vehicle nobody actually re-confirmed was still legit for that race.
local function unreadyOnVehicleChange(playerID)
    local session = findSessionByParticipant(playerID)
    if not session or session.state ~= "GRID" then return end
    local participant = session.participants[playerID]
    if not participant or not participant.ready then return end
    participant.ready = false
    pushSessionUpdate(session)
end

---@param ctxt BJSContext
---@param sessionId string
---@param gateIndex integer
---@param elapsedMs integer client-computed elapsed time since race start
local function raceGateCrossed(ctxt, sessionId, gateIndex, elapsedMs)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "RACE" then return end
    local participant = session.participants[ctxt.senderID]
    if not participant or participant.finished or participant.dnf then return end
    local race = getRace(session)
    if not race then return end

    local gate = race.gates[gateIndex]
    if not gate then return end

    if race.branchingEnabled then
        -- real, confirmed bug fixed here (live-tested report: "my reset point was stuck before
        -- the finish line, and the other path on the next lap didn't count anything"). A
        -- loopable race's own loop-closing transition (re-crossing a step-1 gate to complete a
        -- lap) used to require the SAME explicit parents-link as any other crossing, meaning an
        -- author had to remember to manually add the actual last gate(s) of every branch as a
        -- parent of the step-1 gate, on top of already marking the race loopable, just for the
        -- loop to be able to close at all. Forgetting that one link (easy to miss, since it's the
        -- one backward-pointing edge in an otherwise forward-only graph) silently rejected every
        -- re-crossing of step 1 forever: lastCrossedGate/currentGate froze at whatever the last
        -- valid crossing was (matching "stuck before the finish line" for the lastcheckpoint
        -- respawn strategy, which reads lastCrossedGate directly), and every later gate on any
        -- branch then also failed its own parents-check against that frozen, stale
        -- lastCrossedGate, matching "the other path counted nothing" as the same cascading
        -- failure, not a second, separate bug. Fixed by making step-1 unconditionally reachable
        -- whenever the race is loopable: "loopable" already means "the whole route loops back",
        -- so requiring a second, easy-to-forget explicit link on top of that flag for the one
        -- transition every loopable branching race always needs anyway was pure authoring risk
        -- with no real benefit. Every other (non-step-1) crossing still goes through the normal
        -- parents-check below, unchanged.
        --
        -- Real, confirmed bug fixed here too (live report: crossing the start/finish line, then
        -- backing up and crossing it again immediately, counted a second lap with zero real
        -- progress in between). The unconditional bypass above accepted EVERY step-1 crossing
        -- regardless of the participant's actual position, so two crossings back-to-back with
        -- nothing driven in between both passed it, and gateAlreadyCrossed (set true by the
        -- first one) made the second one register as a genuine lap completion. Fixed by also
        -- requiring `participant.currentGate ~= gate.step` : false only immediately after a
        -- step-1 crossing with nothing else crossed since (currentGate is still left at step 1
        -- from that last crossing), which correctly falls through to the normal parents-check
        -- below and gets rejected outright (a step-1 gate is never its own listed parent),
        -- discarding the stray re-crossing as a no-op instead of registering it. Any REAL lap
        -- (at least one other gate crossed since the last step-1 crossing) leaves currentGate at
        -- that other gate's step, so this never reintroduces the original "stuck" bug above.
        local isLoopClosing = race.loopable and gate.step == 1 and participant.currentGate ~= gate.step
        if not isLoopClosing and not table.includes(gate.parents, participant.lastCrossedGate) then
            return
        end
    else
        local expected = (participant.currentGate % #race.gates) + 1
        if gateIndex ~= expected then return end -- out of order / duplicate report, ignore
    end

    -- "has step 1 already been crossed once this lap cycle": captured before this crossing
    -- overwrites it, used below to tell the race-opening crossing of step 1 apart from every
    -- later *re*-crossing of it (which is what actually completes a lap on a loopable race).
    -- Keyed by step (progress number), not the raw gate index, so this stays correct even when
    -- several different physical gates share step 1 as parallel starting alternates
    local gateAlreadyCrossed = participant.gateTimes[gate.step] ~= nil

    participant.currentGate = gate.step
    participant.lastCrossedGate = gateIndex
    participant.gateTimes[gate.step] = elapsedMs
    participant.lastProgressTime = ctxt.time

    -- lapTimes stores each lap's own duration, not cumulative race time: elapsedMs is
    -- cumulative since race start, so subtract off everything already elapsed as of the
    -- previous lap boundary. Computed once here (not just at the final gate) since the live
    -- delta below needs this same lap-relative baseline at every gate, not only lap ends.
    local previousLapsElapsed = 0
    table.forEach(participant.lapTimes, function(t) previousLapsElapsed = previousLapsElapsed + t end)
    local lapRelativeNow = elapsedMs - previousLapsElapsed

    -- live delta vs this participant's own best lap at the same STEP: nil (nothing to show)
    -- until a best lap actually exists, i.e. from the second lap onward
    participant.liveDeltaMs = (participant.bestLapGateTimes and participant.bestLapGateTimes[gate.step])
        and (lapRelativeNow - participant.bestLapGateTimes[gate.step]) or nil

    -- A loopable race's step 1 is the start/finish line: raceMarkers.lua already draws the
    -- closing "last gate -> gate 1" segment as real, drivable track for exactly this reason, so a
    -- lap only actually completes once that closing segment has been driven, i.e. on *re*-crossing
    -- step 1 (gateAlreadyCrossed, above), not on merely reaching the last placed gate. Treating
    -- "last gate reached" as the finish (the old behavior) silently dropped that closing segment
    -- from lap 1's own timing: lap 1 measured grid-start -> step 1 as its first split instead of
    -- the real step-N -> step-1 segment every later lap uses, while folding the real segment into
    -- the start of lap 2 instead, corrupting every step-indexed comparison (liveDeltaMs,
    -- bestLapGateTimes, sectors) between lap 1 and any later lap. A non-loopable (point-to-point)
    -- race has no closing segment at all; step 1 is just its first checkpoint, so it still
    -- finishes once a real finish gate is crossed instead (gate.isFinish: for a non-branching race
    -- this is only ever true on the last gate, sanitizeRace's own force-normalization, matching the
    -- old `gateIndex == #race.gates` check exactly).
    local lapComplete
    if race.loopable then
        lapComplete = gate.step == 1 and gateAlreadyCrossed
    else
        lapComplete = gate.isFinish == true
    end

    -- sector tracking: a sector completes whenever its own last gate is crossed, except the final
    -- sector of a loopable race, whose real endpoint is that same closing segment. It closes
    -- exactly when the lap does, not when sectorEndGates's own index-based math reaches the last
    -- placed gate (which is the second-to-last crossing on a loopable race, not the last).
    --
    -- sectorEndGates guarantees every sector's gate is distinct and strictly increasing (see its
    -- own comment for why that matters), so in practice this loop only ever runs once per
    -- crossing now. Kept as a loop rather than a single if-check anyway as a defensive backstop,
    -- not the primary fix. A single if-check silently drops a sector's timing entirely if it ever
    -- gets skipped this way again; a repeatable loop just quietly catches up instead.
    local sectorGates = sectorEndGates(race)
    local sectorCount = #sectorGates
    while participant.currentSector < sectorCount and
        gateIndex == sectorGates[participant.currentSector] do
        completeCurrentSector(participant, lapRelativeNow)
    end
    if participant.currentSector >= sectorCount and lapComplete then
        completeCurrentSector(participant, lapRelativeNow)
    end

    if lapComplete then
        table.insert(participant.lapTimes, lapRelativeNow)

        if not participant.bestLapMs or lapRelativeNow < participant.bestLapMs then
            participant.bestLapMs = lapRelativeNow
            -- snapshot this lap's own step splits, lap-relative, before the next lap's crossings
            -- start overwriting these same gateTimes indices. Bounded by totalSteps(race), not
            -- the raw gate array length, since gateTimes is keyed by step and a branching race's
            -- array can hold more physical gates than there are real progress steps
            local snapshot = {}
            for g = 1, totalSteps(race) do
                if participant.gateTimes[g] then
                    snapshot[g] = participant.gateTimes[g] - previousLapsElapsed
                end
            end
            participant.bestLapGateTimes = snapshot
        end

        -- snapshot this lap's completed sector breakdown (the results panel's per-lap history)
        -- before resetting for the next lap
        participant.lapSectorHistory[participant.currentLap] = participant.lapSectors
        participant.lapSectors = {}
        participant.currentSector = 1
        participant.sectorStartMs = 0

        if participant.currentLap >= (session.settings.laps or 1) then
            finishParticipant(session, participant)
        else
            -- currentGate deliberately not reset here, see its own doc comment above. The
            -- `expected` calc at the top of this function already wraps 1..#race.gates via plain
            -- modulo regardless of whether currentGate sits at 0 or at its last real value
            participant.currentLap = participant.currentLap + 1
        end
    end

    pushSessionUpdate(session)
end

---@param ctxt BJSContext
---@param sessionId string
local function raceDNF(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "RACE" then return end
    local participant = session.participants[ctxt.senderID]
    if not participant or participant.finished or participant.dnf then return end

    participant.dnf = true
    if participant.bestLapMs then
        trySubmitTime(session, participant, participant.bestLapMs)
    end
    checkSessionComplete(session)
    -- checkSessionComplete already pushes (and transitions to FINISHED) if this was the last
    -- still-active participant, same as finishParticipant's own identical pattern just below it.
    -- This used to push again unconditionally regardless, which is at best redundant (harmless
    -- duplicate) but at worst can double-fire the client's own flip-detection logic (onSessionUpdate
    -- diffs old vs new state per call) right at the exact moment it matters most. Only pushing here
    -- when the session isn't complete yet keeps this consistent with finishParticipant's pattern.
    if session.state ~= "FINISHED" then
        pushSessionUpdate(session)
    end
end

--- chat-command front door for ready/leave/cancel/retire. All four act on "whichever session I'm
--- currently in", resolved here rather than requiring the player to type a session UUID. No
--- permission requirement, matching raceReady/raceLeave's own design (any participant may act on
--- their own membership); raceCancel already self-restricts to the starter or staff internally.
---@param ctxt BJSContext
---@param args string[] "<ready|leave|cancel|retire>"
---@param command BJChatCommand
local function chatRace(ctxt, args, command)
    local sub = args[1] and args[1]:lower()
    if not table.includes({ "ready", "leave", "cancel", "retire" }, sub) then
        return services_chat.directSend(ctxt.senderID,
            string.format("%s : %s -> %s",
                services_lang.get("chat.command.usage", ctxt.sender.lang),
                services_lang.get(command.commandKey, ctxt.sender.lang),
                services_lang.get(command.descKey, ctxt.sender.lang)),
            services_chat.COLORS.ERROR)
    end

    local session = findSessionByParticipant(ctxt.senderID)
    if not session then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.race.notInSession", ctxt.sender.lang),
            services_chat.COLORS.ERROR)
    end

    if sub == "ready" then
        local participant = session.participants[ctxt.senderID]
        local nowReady = not participant.ready
        M.raceReady(ctxt, session.id, nowReady)
        services_chat.directSend(ctxt.senderID,
            services_lang.get(nowReady and "chat.command.race.readyOn" or "chat.command.race.readyOff",
                ctxt.sender.lang))
    elseif sub == "leave" then
        M.raceLeave(ctxt, session.id)
        services_chat.directSend(ctxt.senderID, services_lang.get("chat.command.race.left", ctxt.sender.lang))
    elseif sub == "cancel" then
        local sessionId = session.id
        M.raceCancel(ctxt, sessionId)
        if M.sessions[sessionId] then
            services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.error.noPermission", ctxt.sender.lang),
                services_chat.COLORS.ERROR)
        else
            services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.race.cancelled", ctxt.sender.lang))
        end
    elseif sub == "retire" then
        -- "retire and spectate": a voluntary self-DNF, distinct from leave. Stays a tracked
        -- participant (still gets HUD/leaderboard updates, client auto-focuses another still-
        -- active racer's vehicle) rather than exiting the session outright like "leave" does
        local participant = session.participants[ctxt.senderID]
        if session.state ~= "RACE" then
            return services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.race.notRacing", ctxt.sender.lang),
                services_chat.COLORS.ERROR)
        elseif participant.finished or participant.dnf then
            return services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.race.alreadyDone", ctxt.sender.lang),
                services_chat.COLORS.ERROR)
        end
        M.raceDNF(ctxt, session.id)
        services_chat.directSend(ctxt.senderID, services_lang.get("chat.command.race.retired", ctxt.sender.lang))
    end
end

local function onInit()
    communications_rx.addHandler("raceStart", M.raceStart)
    communications_rx.addHandler("raceJoin", M.raceJoin)
    communications_rx.addHandler("raceLeave", M.raceLeave)
    communications_rx.addHandler("raceCancel", M.raceCancel)
    communications_rx.addHandler("raceReady", M.raceReady)
    communications_rx.addHandler("raceSetGridSlot", M.raceSetGridSlot)
    communications_rx.addHandler("raceGateCrossed", M.raceGateCrossed)
    communications_rx.addHandler("raceDNF", M.raceDNF)
    communications_rx.addHandler("raceSpectate", M.raceSpectate)
    communications_rx.addHandler("raceStopSpectate", M.raceStopSpectate)

    services_chatCommands.addCommand("race", "chat.command.race.desc", M.chatRace,
        { commandKey = "chat.command.race.command" })

    -- TEMPORARY debug tooling, for testing multiplayer-only race-completion paths (DNF/finish
    -- teardown while another participant is still active) with only one real connected client.
    -- "racedebugadd" injects a fake, never-connecting participant (playerID -1000, deliberately
    -- not -1, since communications_tx.ALL_PLAYERS is also -1, so sending to that "playerID" would
    -- actually broadcast to every real connected player instead of harmlessly no-op'ing like a
    -- real disconnected/fake ID does; confirmed the hard way, it double-fired the real player's
    -- own onSessionRemoved) into the given real player's current session via the same
    -- addParticipant() every real join uses, so their own finish/DNF doesn't solo-complete the
    -- session. "racedebugcomplete" then flips that fake participant to dnf, mirroring exactly what
    -- raceDNF does for a real player, to simulate "the other racer DNFs last" without needing a
    -- second real client. Remove once no longer needed.
    services_consoleCommands.register("racedebugadd", "<playerName>",
        "inject a fake never-finishing participant into <playerName>'s current race session (debug)",
        function(args, printUsage)
            if not args[1] then return printUsage() end
            local targets = services_players.getConnectedByName(args[1])
            if #targets ~= 1 then
                print(string.format("[BJ raceGrid] racedebugadd: %s match(es) for '%s'", #targets, args[1]))
                return
            end
            local session = findSessionByParticipant(targets[1].playerID)
            if not session then
                print("[BJ raceGrid] racedebugadd: " .. targets[1].playerName .. " is not in a race session")
                return
            end
            addParticipant(session, -1000, "DebugGhost")
            pushSessionUpdate(session)
            print("[BJ raceGrid] racedebugadd: injected DebugGhost into session " .. session.id)
        end)
    services_consoleCommands.register("racedebugcomplete", "<playerName>",
        "DNF the fake DebugGhost participant in <playerName>'s current race session (debug)",
        function(args, printUsage)
            if not args[1] then return printUsage() end
            local targets = services_players.getConnectedByName(args[1])
            if #targets ~= 1 then
                print(string.format("[BJ raceGrid] racedebugcomplete: %s match(es) for '%s'", #targets, args[1]))
                return
            end
            local session = findSessionByParticipant(targets[1].playerID)
            if not session then
                print("[BJ raceGrid] racedebugcomplete: " .. targets[1].playerName .. " is not in a race session")
                return
            end
            local fake = session.participants[-1000]
            if not fake then
                print("[BJ raceGrid] racedebugcomplete: no DebugGhost found (run racedebugadd first)")
                return
            end
            fake.dnf = true
            checkSessionComplete(session)
            if session.state ~= "FINISHED" then
                pushSessionUpdate(session)
            end
            print("[BJ raceGrid] racedebugcomplete: DebugGhost DNF'd, session.state=" .. session.state)
        end)
end

---@param playerID integer
--- inlined rather than routed through raceLeave/raceDNF: those need ctxt.sender resolved via
--- services_players.players, which other extensions' own onPlayerDisconnect handlers may have
--- already cleared by the time this one runs (extensions.hook has no ordering guarantee)
local function onPlayerDisconnect(playerID)
    M.spectators[playerID] = nil
    M.sessions:forEach(function(session)
        if not session.participants[playerID] then return end

        if session.state == "GRID" then
            session.participants[playerID] = nil
            if session.participants:length() == 0 then
                return removeSession(session)
            end
            if playerID == session.starterID then
                session.starterID = session.participants:keys()[1]
            end
            tryStartFromGrid(session)
            pushSessionUpdate(session)
            pushOpenSessionsList()
        elseif session.state == "RACE" then
            local participant = session.participants[playerID]
            participant.dnf = true
            if participant.bestLapMs then
                trySubmitTime(session, participant, participant.bestLapMs)
            end
            checkSessionComplete(session)
            -- same redundant-double-push cleanup already applied to raceDNF/raceLeave. Only push
            -- again here if checkSessionComplete didn't already do so itself (it pushes once, on
            -- its own, exactly when this disconnect happens to be the one that completes the
            -- session)
            if session.state ~= "FINISHED" then
                pushSessionUpdate(session)
            end
        end
    end)
end

M.onInit = onInit
M.onPlayerDisconnect = onPlayerDisconnect

M.raceStart = raceStart
M.raceJoin = raceJoin
M.raceLeave = raceLeave
M.raceCancel = raceCancel
M.raceReady = raceReady
M.raceSetGridSlot = raceSetGridSlot
M.unreadyOnVehicleChange = unreadyOnVehicleChange
M.raceGateCrossed = raceGateCrossed
M.raceDNF = raceDNF
M.raceSpectate = raceSpectate
M.raceStopSpectate = raceStopSpectate
M.beginRace = beginRace
M.computeLeaderboard = computeLeaderboard
M.chatRace = chatRace

return M
