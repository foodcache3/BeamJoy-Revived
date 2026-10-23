--- Live `grid`-mode race session state machine (join/ready/countdown/leaderboard/finish).
--- Separate from `services/races.lua`, which only owns the static race *definitions*
--- (storage/CRUD). This module owns *instances* of a race actually being run. Multiple sessions
--- can run concurrently, one per player-started race, unlike BeamJoy Free's single
--- server-wide active scenario.
---
--- NOT YET IMPLEMENTED (deferred, see the plan): vehicle model/config enforcement during grid,
--- the admin-forced server-wide path, and anything about `passive` mode (that's an ambient/
--- freeroam mechanic, not a grid session at all).

---@alias BJRaceSessionState "GRID"|"COUNTDOWN"|"RACE"|"BREAK"|"FINISHED" BREAK : between two of the
---event's phases (services/racePhases.lua), the last one's results shown

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
---@field finishOrder integer? 1 for the first to finish this session, and so on
---@field penaltyMs integer time penalties staff have given (raceStaffAction), added to the race
---time once finished : the finishing order is by race time plus penalties
---@field disqualified boolean? by staff : last in the standings, no leaderboard time
---@field leaderboardKey string? the key a new PB was submitted under (trySubmitTime)
---@field replacedEntry table? the leaderboard entry that PB replaced, put back on a disqualification
---@field discordResult table? what this run meant for the leaderboard, set by trySubmitTime
---@field isNewRecord boolean? same as isNewPB, true when this PB is now the race's overall best
---@field disconnected boolean? left the server mid-race and may still come back (see
---onPlayerDisconnect / raceRejoin) : the race clock keeps running for them, the race doesn't end
---while they're away, and they're retired once settings.rejoinGraceMinutes run out
---@field rejoinSecondsLeft integer? while disconnected : how long they had left when the last
---update went out (rejoinBy is the server's own deadline)
---@field rejoinBy integer? GetCurrentTime() deadline, while disconnected
---@field guest boolean? joined on a BeamMP guest account (kept up to date while connected)
---@field nickname string? their BeamJoy nickname (services/identity.lua), kept up to date while
---connected : a guest who comes back on a new guest name is recognised by it
---@field readyChecking boolean? readying up, while the plugins answering the plugin API's
---raceReady hook are asked (requestReady)
---@field readyBlockReason string? why a plugin refused their last ready-up (or unreadied them),
---shown to them in the lobby ; cleared once they're ready
---@field readyBlockBy string? the plugin that refused
---@field gridPosition integer? their place on the grid, 1 first, set when the countdown begins
---@field bestLapAtMs integer? when (the shared clock) they set bestLapMs : equal best laps, the first
---to set it ranks first
---@field startAtMs integer? a personal start (services/racePhases.lua : a staggered start, a run, a
---mid-phase join) : when they go (the shared clock). nil : the phase's green light, with everyone
---@field clockBaseMs integer? what their race times count from (the shared clock) : their own start,
---or the phase's green light (a mid-phase join into a race). nil : the green light
---@field runStartPosition table? where their personal start is (the first slot, or a free one)
---@field elapsedOffsetMs integer? their laps' time before clockBaseMs (a run's clock starts at 0)
---@field outLapPending boolean? on their out lap (settings.outLap) : not timed until the line
---@field awaitingStart boolean? a plugin's phase (start = "plugin") : held on their slot until the
---plugin starts them (race.startRacer)
---@field score number? a plugin's score for them this phase (phase.setScores)
---@field scoreKey number? the same, lower is better whichever way the plugin counts : the ranking
---@field scoreDisplay string? how the HUD and results show it ("86 pts")
---@field lateJoining boolean? joined while the event was under way, not ready yet : they sit out
---until they are
---@field sittingOut boolean? not taking part in the phase being run (its `takes` left them out, or
---they're out of the event) : they watch it
---@field eventOut boolean? out of the event : they disconnected and didn't come back in time. They
---keep their earlier phases' results, and sit out the rest
---@field lastResetMs integer? the shared clock at their last reset counted (raceReset)

---@class BJRaceSessionSettings host-configurable at start time, seeded from BJRaceDefaults
---@field laps integer?
---@field flyingStart boolean? a point-to-point track : each racer's time (every run's) starts at the
---first checkpoint, not at their release (see BJRaceDefaults.flyingStart)
---@field outLap boolean? a circuit : an out lap from the grid first, each racer timed from the line
---at its end (see BJRaceDefaults.outLap)
---@field waiting "watch"|"grid"|nil a "sequential" phase's : how the racers wait their turn (racePhases)
---@field respawnStrategy BJRaceRespawnStrategy
---@field placementMode BJRacePlacementMode how grid slots are assigned at countdown time:
---"deterministic" = lobby join order (starter first), "random" = shuffled, "manual" = whatever
---the host assigned in the lobby (see raceSetGridSlot). Default "random"
---@field gridTimeout integer seconds
---@field gridReadyTimeout integer seconds
---@field countdown integer seconds
---@field dnfEnabled boolean stall-based DNF under "norespawn". Default true
---@field dnfTimeout integer seconds of no progress before a DNF triggers
---@field rejoinGraceMinutes integer how long a racer who disconnects mid-race has to come back
---before being retired (0 = retired at once, the old behavior). Default 10
---@field resetPenaltyEnabled boolean matching Hunter's own crash-reset penalty. Freezes and
---camera-locks (external view) a participant for resetPenaltySeconds each time they reset/recover
---during an active attempt. Default false. Purely client-enforced (raceRunner.lua), same as
---Hunter's own version; nothing server-side tracks or times this beyond resolving the setting
---itself. Moot under "norespawn" (resets are already fully blocked there)
---@field resetPenaltySeconds integer seconds per reset when resetPenaltyEnabled is on
---@field resetPenaltyMode "hold"|"time" "hold" : the car is frozen for resetPenaltySeconds (client
---side) ; "time" : they're added to the racer's race time (raceResetPenalty), with any staff ones
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
---@field showGates boolean the gates themselves once COUNTDOWN/RACE begins (see
---BJRaceDefaults.showGates). Default true
---@field waypointBeams boolean the GPS-style beam over the next gate once COUNTDOWN/RACE begins (see
---BJRaceDefaults.waypointBeams). Default true
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
---@field goAtMs integer? the green light, on services_clockSync's shared clock. Set when the
---countdown begins ; clients synced to that clock unfreeze and start their timers at exactly this
---moment themselves, instead of whenever the RACE push happens to reach them
---@field joinCounter integer? monotonic source of BJRaceParticipant.joinIndex (see
---addParticipant); never decremented on leave
---@field participants tablelib<integer, BJRaceParticipant> index playerID
---@field placing boolean? the plugins answering the gridOrder hook are being asked : the lobby
---is held (no joining, no ready changes) until they've answered (beginCountdown)
---@field pluginGridOrder integer[]? player IDs, first on the grid first, from a plugin's
---race.setGridOrder ; used unless a gridOrder hook answer gives another
---@field pluginGridOrderBy string? that plugin
---@field phases BJRacePhase[] the event's phases, in order (one : a race as it always was)
---@field result BJRaceEventResult how the event's result comes from its phases
---@field format string? a plugin's format it runs ("plugin:id", formats.register)
---@field phaseIndex integer the phase being run (in the lobby : the first)
---@field baseSettings BJRaceSessionSettings the event's own settings ; `settings` is them with the
---current phase's rules and length over them (racePhases.effectiveSettings)
---@field phaseResults table<integer, table[]> phase index -> its results (buildResults), once run
---@field eventStandings table[]? the event's standings from the phases run so far
---@field phaseEndsAtMs integer? a timed phase : when its time is up (the shared clock)
---@field flagAtMs integer? when its time was up : racers finish per the phase's afterTime
---@field chequered boolean? afterTime "leader" : the leader has taken the flag, everyone's next
---crossing of the line ends their race
---@field overtimeEndsAtMs integer? once the time's up, the latest the phase goes on (racers stopped
---or lost out there) ; anyone still out then is done
---@field breakEndsAtMs integer? BREAK : when the next phase's countdown begins (the shared clock)
---@field judging boolean? a phase over, its result with the plugins answering the phaseResult hook
---@field eventScores table<integer, {score: number, key: number, display: string?}>? joinIndex -> a
---plugin's event score (phase.setScores with `event`), for an event whose result is "plugin"
---@field hostedBy string? a lobby a plugin opened (the plugin API's race.open) : no leader, and it
---stays open while empty, until its time runs out
---@field hostName string? that lobby's name where a leader's would be ("League night")
---@field holdStart boolean? that lobby starts only when its time's up or the plugin says
---(race.startNow), not once everyone's been ready a moment
---@field entrants table<integer, true>? that lobby's entry list (player IDs) : only they may join
---@field lastPositions table<integer, integer>? RACE : joinIndex -> place at the last update (the
---plugin API's RacePositionsChanged)
---@field allReadyAt integer? GetCurrentTime() of the moment every current participant most
---recently became ready together, cleared again the instant that's no longer true (someone leaves
---unready, joins unready, un-readies via vehicle-change). gridReadySecondsLeft and the actual
---start-floor check (tryStartFromGrid) are both anchored to this, not createdAt - see
---updateAllReadyState's own doc comment for why

local M = {
    dependencies = { "services_races", "services_racePhases", "services_vehiclePresets", "utils_async",
        "services_identity" },

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

-- forward-declared : onPlayerDisconnect schedules the grace period's end with it
local rejoinTaskKey

--- tells the plugin API (services/api.lua) about something in a race. A failure there is logged,
--- never allowed to break the race itself
---@param name string the services_api function
local function apiEvent(name, ...)
    if not services_api or not services_api[name] then return end
    local ok, err = pcall(services_api[name], ...)
    if not ok then LogError(string.format("[BJ raceGrid] plugin API %s failed : %s", name, tostring(err))) end
end

-- how early (ms, on the shared clock) a gate crossing may arrive while the server itself is still
-- in COUNTDOWN : a synced client starts on its own at goAtMs, but the server only notices on its
-- next ~100ms tick, and the client's clock estimate can be off by a little either way
local GO_GRACE_MS = 1000

---@param session BJRaceSession
---@return BJRace?
local function getRace(session)
    return services_races.getById(session.raceId)
end

--- the phase being run (in the lobby, the first)
---@param session BJRaceSession
---@return BJRacePhase
local function currentPhase(session)
    return session.phases[session.phaseIndex or 1]
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

--- the end of a branch : a gate no other gate follows but the start/finish line (step 1). A
--- loopable branching race's line closes the lap from one, whichever branch it ends and however
--- long that branch is (steps count the longest way round, so a shorter last branch ends below the
--- top step)
---@param race BJRace
---@param index integer? a gate index (0 / nil : none crossed yet)
---@return boolean
local function isBranchEnd(race, index)
    if not index or not race.gates[index] then return false end
    for _, g in ipairs(race.gates) do
        if g.step ~= 1 and table.includes(g.parents or {}, index) then return false end
    end
    return true
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
---@param flyingStart boolean? a point-to-point track's flying start : its first checkpoint is where
---the time starts, so no sector ends there (as a circuit's start/finish line)
---@return integer[] gateIndex per sector, 1-based
local function sectorEndGates(race, flyingStart)
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
            if g.sector and i < #race.gates and not (flyingStart and not race.loopable and i == 1) then
                table.insert(flagged, i)
            end
        end
        table.insert(flagged, #race.gates)
        if #flagged > 0 then return flagged end
    end

    -- a flying start's first checkpoint kept out (see searchFloor below) : one gate fewer to share
    -- out (a circuit's last sector ends past its last gate, at the line : it has them all)
    local flying = flyingStart == true and not race.loopable
    local count = math.max(1, math.min(race.sectorCount or 3, #race.gates - (flying and 1 or 0)))
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
    -- A flying start's first checkpoint the same : the time starts there
    local searchFloor = (race.loopable or flying) and 1 or 0
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
        found = math.min(found, #race.gates - (count - s) + (race.loopable and 1 or 0))
        gates[s] = found
        lastAssigned = found
    end
    gates[count] = #race.gates
    return gates
end

--- The nickname system (services/identity.lua) only ever stamps `displayName` onto the general
--- player cache/live connection object, never onto a race/hunter/infected session's own
--- independent `participants` table - so a logged-in nickname never reached any of these session
--- payloads on its own. Real gap fixed here: every outbound participant/starter name in this file
--- now resolves through services_identity.getIdentityKey the same way the leaderboard already did
--- (see this file's own raceGateCrossed), falling back to the raw connection playerName exactly
--- like getIdentityKey itself does for a never-logged-in player.
---@param playerID integer
---@param fallbackName string
---@return string
local function resolveDisplayName(playerID, fallbackName)
    return services_identity.getIdentityKey(playerID) or fallbackName
end

--- copies who a connected participant is (guest account, nickname) onto them, for when they've
--- disconnected and the player record is gone
---@param p BJRaceParticipant
local function snapshotIdentity(p)
    if p.disconnected then return end
    local player = services_players.players[p.playerName]
    if not player then return end
    p.guest = player.guest == true
    p.nickname = player.identityNickname
end

--- what kind of name a participant's leaderboard key is (services_identity.getIdentityKind), for
--- one still connected or one away (their snapshotIdentity copy)
---@param p BJRaceParticipant
---@return "nickname"|"guest"|"beammp"
local function participantIdentityKind(p)
    local kind = services_identity.getIdentityKind(p.playerID)
    if kind then return kind end
    if p.nickname then return "nickname" end
    return p.guest and "guest" or "beammp"
end

--- who a participant is, as the plugin API shows them : their leaderboard name, and its kind
---@param p BJRaceParticipant
---@return {name: string, identity: string}
local function racerInfo(p)
    return { name = services_identity.getIdentityKey(p.playerID) or p.nickname or p.playerName,
        identity = participantIdentityKind(p) }
end

--- participants who disconnected mid-race wait under keys like these instead of their player ID.
--- Real bug (direct report) : BeamMP reuses a freed player ID, so a racer coming back often gets
--- the same one ; the rejoin saw "already in this race" (their own waiting entry) and did
--- nothing. Kept under that ID, anyone else who joined meanwhile with it would also have been
--- taken for that racer. Below -1 (communications_tx.ALL_PLAYERS) and the debug ghost's -1000
local lastAwayKey = -1000000
local function nextAwayKey()
    lastAwayKey = lastAwayKey - 1
    return lastAwayKey
end

--- what a slim session update (a gate crossing) leaves out : what can't change at a crossing, and
--- every client in the session already has (raceRunner.lua's onSessionUpdate keeps its own)
local SLIM_DROPPED = { settings = true, phases = true, phaseResults = true, eventStandings = true }

-- per-gate tables never sent to clients : gateTimes holds every gate's crossing time, so on a
-- track with hundreds of gates it was most of every session update, and it was only ever read to
-- work out the gaps between racers, which the server now does itself (gapBetween below)
local PAYLOAD_DROPPED_FIELDS = { gateTimes = true, bestLapGateTimes = true, leaderboardKey = true, replacedEntry = true,
    lastResetMs = true, pluginFields = true }

--- a session's own tables never sent to clients (an entry list's player IDs, the last places)
local SESSION_PRIVATE = { participants = true, baseSettings = true, lastPositions = true, entrants = true }

--- the copy of a participant that goes out in session updates : shallow (nothing in a payload
--- is modified after it's built), without the per-gate tables, plus a `displayName`
---@param p BJRaceParticipant
---@return table
local function payloadParticipant(p)
    local c = {}
    for k, v in pairs(p) do
        if not PAYLOAD_DROPPED_FIELDS[k] then c[k] = v end
    end
    if p.disconnected and p.rejoinBy then
        c.rejoinSecondsLeft = math.max(0, p.rejoinBy - GetCurrentTime())
    end
    c.rejoinBy = nil
    c.displayName = resolveDisplayName(p.playerID, p.nickname or p.playerName)
    return c
end

---@param p BJRaceParticipant
---@return integer
local function lapTimesTotal(p)
    local total = 0
    for _, t in ipairs(p.lapTimes or {}) do total = total + t end
    return total
end

--- a finisher's race time : their laps plus any staff penalties
---@param p BJRaceParticipant
---@return integer
local function raceTimeMs(p)
    return lapTimesTotal(p) + (p.penaltyMs or 0)
end

--- the gap from `self` back to `other`, ms (positive : other is behind), or a whole-lap count once
--- they're a genuine lap or more apart. Both nil when there's no meaningful gap (either retired,
--- or one finished and the other still racing).
---@param self BJRaceParticipant
---@param other BJRaceParticipant
---@param totalGates integer progress steps per lap (totalSteps)
---@param ranking BJRacePhaseRanking? the phase's (best lap : the gap between best laps ; total :
---between the times added up, or the laps/runs between them)
---@return integer? gapMs, integer? lapsDiff
local function gapBetween(self, other, totalGates, ranking)
    if self.disqualified or other.disqualified then return nil, nil end
    if ranking == services_racePhases.RANKING.BEST then
        local a, b = services_racePhases.bestOf(self), services_racePhases.bestOf(other)
        if a and b then return b - a, nil end
        return nil, nil
    elseif ranking == services_racePhases.RANKING.TOTAL then
        local a, b = services_racePhases.lapsDone(self), services_racePhases.lapsDone(other)
        if a ~= b then return nil, a - b end
        if a > 0 then return raceTimeMs(other) - raceTimeMs(self), nil end
        return nil, nil
    end
    if self.dnf or other.dnf or self.finished ~= other.finished then
        return nil, nil
    end
    if self.finished then
        -- a timed race's finishers can have done different laps
        local a, b = services_racePhases.lapsDone(self), services_racePhases.lapsDone(other)
        if a ~= b then return nil, a - b end
        return raceTimeMs(other) - raceTimeMs(self), nil
    end
    local selfProgress = (self.currentLap - 1) * totalGates + self.currentGate
    local otherProgress = (other.currentLap - 1) * totalGates + other.currentGate
    -- whole laps from real gate progress, not the lap numbers : the leader's lap number goes up
    -- the moment they cross the line, long before they're actually a lap ahead of anyone
    if self.currentLap ~= other.currentLap and totalGates > 0 and
        math.abs(selfProgress - otherProgress) >= totalGates then
        local gateGap = selfProgress - otherProgress
        return nil, (gateGap > 0 and 1 or -1) * math.floor(math.abs(gateGap) / totalGates)
    end
    -- compare both racers' race-cumulative times at the gate the TRAILING one is at (the latest
    -- gate both have crossed). Same lap : the leader crossed it earlier this lap. Leader one lap
    -- number ahead but less than a full lap of progress ahead : the leader hasn't reached that gate
    -- again yet this lap, so their gateTimes entry still holds the previous lap's crossing, the
    -- very lap the trailing racer is on. Either way the same physical point on the same lap.
    -- (Fixed bug, reported as "splits drifting" on a 40-lap endurance race : this case used to add
    -- each racer's completed lap times on top of their race-cumulative gate time, counting every
    -- completed lap twice, so the gap came out wrong by about a lap time.)
    local commonGate = math.min(self.currentGate, other.currentGate)
    if self.currentLap ~= other.currentLap then
        commonGate = (selfProgress < otherProgress and self or other).currentGate
    end
    if commonGate >= 1 then
        local selfTime = self.gateTimes and self.gateTimes[commonGate]
        local otherTime = other.gateTimes and other.gateTimes[commonGate]
        if selfTime and otherTime then
            return otherTime - selfTime, nil
        end
    end
    return nil, nil
end

-- forward-declared : the sessions list (summarize) says whether one can be joined midway
local joinableNow

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
        starterName = starter and resolveDisplayName(starter.playerID, starter.playerName) or session.hostName or "?",
        joinable = session.joinable,
        participantCount = session.participants:length(),
        maxParticipants = race and #race.startPositions or 0,
        state = session.state,
        phaseIndex = session.phaseIndex,
        phaseCount = #session.phases,
        phaseName = currentPhase(session).name,
        -- open to join now while under way (services/racePhases.lua's lateJoin)
        lateJoinable = session.state ~= "GRID" and select(2, joinableNow(session)) and
            session.participants:length() < (race and #race.startPositions or 0) or nil,
    }
end

--- builds the outbound session payload shared by pushSessionUpdate and raceSpectate: participants
--- as a plain array (not the internal Table) already in standings order (the client reads that same
--- array as the leaderboard, there's no second copy), each with its gaps worked out here
--- (aheadGapMs/aheadLapsDiff to the car in front, leaderGapMs/leaderLapsDiff to the leader), and,
--- once actually racing, a server-computed elapsed duration (raceElapsedMs), not a timestamp.
---
--- Kept small on purpose. Every gate crossing by anyone sends this to every racer and spectator,
--- and it used to carry each racer's time at every gate, plus a second full copy of every racer as
--- the leaderboard : on a long track with many racers that was hundreds of KB per crossing, more
--- than the server could encode and send (the reported 40-lap endurance race).
---@param session BJRaceSession
---@param slim boolean? leave out `settings` (the client keeps the ones it already has, see
---raceRunner.lua's onSessionUpdate) : only for gate-crossing pushes, the frequent ones, which
---can't change settings and never reach anyone who hasn't already received them
---@return table
local function buildSessionPayload(session, slim)
    local payload = {}
    for k, v in pairs(session) do
        if not SESSION_PRIVATE[k] and not (slim and SLIM_DROPPED[k]) then payload[k] = v end
    end

    local race = getRace(session)
    local totalGates = race and totalSteps(race) or 0
    local ranking = session.settings.ranking
    local ordered = M.computeLeaderboard(session)
    local leader = ordered[1]
    -- a still-racing row is measured against the leader as if the leader were still racing too,
    -- so it keeps a gap after the leader has finished. A loopable race finishes on re-crossing
    -- step 1, which leaves the finisher's currentLap on the final lap and currentGate back at 1 :
    -- read as progress, that put a finished leader a whole lap BEHIND where they really are, so
    -- every gap to them was nonsense for the rest of the final lap. They've completed that lap.
    local racingLeader = leader and setmetatable({
        finished = false,
        currentLap = leader.currentLap + ((leader.finished and race and race.loopable) and 1 or 0),
    }, { __index = leader })
    payload.participants = {}
    for i, p in ipairs(ordered) do
        local row = payloadParticipant(p)
        -- plugins' labels on this racer (services/pluginUi.lua), as shown
        local fields = services_pluginUi.racerFields(session, p)
        row.fields = fields and services_pluginUi.fieldList(fields) or nil
        if i > 1 then
            row.aheadGapMs, row.aheadLapsDiff = gapBetween(ordered[i - 1], p, totalGates, ranking)
            row.leaderGapMs, row.leaderLapsDiff = gapBetween(p.finished and leader or racingLeader, p, totalGates,
                ranking)
        end
        payload.participants[i] = row
    end

    if session.state == "RACE" and session.goAtMs then
        payload.raceElapsedMs = math.max(0, services_clockSync.nowMs() - session.goAtMs)
    end
    -- a timed phase's time left, and a break's, as durations too (the shared-clock moments,
    -- phaseEndsAtMs / breakEndsAtMs, go out as well)
    if session.state == "RACE" and session.phaseEndsAtMs then
        payload.phaseTimeLeftMs = math.max(0, session.phaseEndsAtMs - services_clockSync.nowMs())
    end
    if session.state == "BREAK" and session.breakEndsAtMs then
        payload.breakLeftMs = math.max(0, session.breakEndsAtMs - services_clockSync.nowMs())
    end
    -- lobby-phase countdown feedback, same "push a duration, not a timestamp" reasoning as
    -- raceElapsedMs above (session.createdAt/allReadyAt are in the server's own GetCurrentTime()
    -- clock domain, meaningless compared directly against a client's GetCurrentTimeMillis()). Only
    -- meaningful for a real joinable multiplayer lobby. A non-joinable (solo/private) session never
    -- schedules either of these timers server-side, so there's nothing to report for one.
    --
    -- gridReadySecondsLeft is a full, consistent gridReadyTimeout-second countdown anchored to
    -- session.allReadyAt (see updateAllReadyState's own doc comment for why, and the real,
    -- confirmed bug this replaces) - nil whenever not everyone's ready yet, so the client already
    -- naturally has nothing to show (previously sent a number even before anyone was ready, relying
    -- entirely on the client's own separate allReady gate to hide it). gridTimeoutSecondsLeft is
    -- unrelated and unchanged: the hard deadline where anyone still unready gets kicked and the
    -- lobby starts (or closes) regardless, still anchored to session.createdAt.
    if session.state == "GRID" and session.joinable then
        payload.gridReadySecondsLeft = (session.allReadyAt and not session.holdStart) and
            math.max(0, math.ceil(session.settings.gridReadyTimeout - (GetCurrentTime() - session.allReadyAt)))
            or nil
        payload.gridTimeoutSecondsLeft = math.max(0,
            math.ceil(session.settings.gridTimeout - (GetCurrentTime() - session.createdAt)))
    end
    -- backmarker flag for the optional "ghost backmarkers" setting (client decides whether to
    -- actually act on it, see raceRunner.lua). Deliberately not a raw currentLap comparison.
    -- currentLap increments the instant gate 1 is (re)crossed, so "leader.currentLap >
    -- p.currentLap" alone would flag someone as a lapped backmarker the moment the leader crosses
    -- the line a fraction of a second ahead of them, even mid-pack and neck-and-neck, not actually
    -- lapped at all. Same class of bug (and same fix) as the client HUD's own "+1 lap" indicator.
    -- See gapBetween above: real gate-progress gap, only counted a genuine
    -- backmarker once it's actually >= one full lap's worth of gates. leaderboard is already
    -- sorted "most progress first", so index 1 is the leader.
    --
    -- BACKMARKER_GATE_SAFETY_MARGIN shaves one gate off that full-lap threshold on purpose, per
    -- direct request: ghosting exactly at the moment of the pass is too late to matter for
    -- collision safety, since the two vehicles are already about to occupy the same space at that
    -- instant. Triggering a gate earlier gives the about-to-be-lapped car time to actually be
    -- ghosted before the leader arrives, not right as they do.
    if session.settings.ghostBackmarkers and leader then
        if totalGates > 0 then
            local BACKMARKER_GATE_SAFETY_MARGIN = 1
            local threshold = math.max(1, totalGates - BACKMARKER_GATE_SAFETY_MARGIN)
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

--- the plugin API's RacePositionsChanged : during a phase, the places that changed since the last
--- update (an overtake, a finish, a penalty). A phase's first update only takes note of them, as
--- does a racer's first (a mid-phase join)
---@param session BJRaceSession
local function notePositions(session)
    if session.state ~= "RACE" or not services_api then return end
    local positions, byJoin, place = {}, {}, 0
    for _, p in ipairs(M.computeLeaderboard(session)) do
        if not p.sittingOut then
            place = place + 1
            positions[p.joinIndex] = place
            byJoin[p.joinIndex] = p
        end
    end
    local last = session.lastPositions
    session.lastPositions = positions
    if not last then return end
    local changes = {}
    for joinIndex, to in pairs(positions) do
        local from = last[joinIndex]
        if from and from ~= to then changes[#changes + 1] = { p = byJoin[joinIndex], from = from, to = to } end
    end
    if #changes == 0 then return end
    table.sort(changes, function(a, b) return a.to < b.to end)
    apiEvent("racePositionsChanged", session, changes)
end

--- pushes the full session (with leaderboard) to every current participant, and the exact same
--- payload under a different event name (so the client never confuses the two) to anyone
--- currently spectating this session. See M.spectators's own comment for why that has to be a
--- separate channel rather than just also being sent "raceSessionUpdate"
---@param session BJRaceSession
---@param slim boolean? see buildSessionPayload
local function pushSessionUpdate(session, slim)
    session.participants:forEach(snapshotIdentity)
    local payload = buildSessionPayload(session, slim)
    -- encoded once per audience, not once per player (see communications_tx.sendToPlayers)
    communications_tx.sendToPlayers(session.participants:keys(), "raceSessionUpdate", payload)
    local watchers = {}
    M.spectators:forEach(function(sessionId, playerID)
        if sessionId == session.id then watchers[#watchers + 1] = playerID end
    end)
    if #watchers > 0 then
        communications_tx.sendToPlayers(watchers, "raceSpectateUpdate", payload)
    end
    notePositions(session)
end

--- pushes every session worth showing on the main HUD to every connected player: GRID+joinable
--- ones to join (the original scope, discovery ahead of the deprioritized race-invite UI), plus
--- COUNTDOWN/RACE ones to spectate. A session only becomes something worth watching once it
--- actually has a race in progress, and stops being listed once it's torn down like any other.
--- `summarize`'s own `state` field is what the client uses to tell "Join" apart from "Spectate".
local function pushOpenSessionsList()
    local visible = M.sessions:filter(function(s)
        if s.private then return false end
        return (s.state == "GRID" and s.joinable) or
            s.state == "COUNTDOWN" or s.state == "RACE" or s.state == "BREAK"
    end):map(summarize):values()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "raceSessionsList", visible)
end

---@param session BJRaceSession
local function removeSession(session)
    -- a finished race was already reported (RaceFinished) ; anything else ended early
    if session.state ~= "FINISHED" and M.sessions[session.id] == session then
        apiEvent("raceClosed", session)
    end
    utils_async.removeTask("BJRaceGrid-" .. session.id .. "-readyTimeout")
    utils_async.removeTask("BJRaceGrid-" .. session.id .. "-gridTimeout")
    utils_async.removeTask("BJRaceGrid-" .. session.id .. "-countdown")
    utils_async.removeTask("BJRaceGrid-" .. session.id .. "-break")
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

--- the phase's standings, by its ranking (racePhases.sort) : a race's finishers by laps then race
--- time with penalties (a penalty can drop someone behind a later finisher), the ones still racing
--- by most laps, most gates, fastest ; practice or qualifying by best lap. Disqualified after, the
--- ones sitting the phase out last
---@param session BJRaceSession
---@return BJRaceParticipant[]
local function computeLeaderboard(session)
    local list = {}
    session.participants:forEach(function(p) list[#list + 1] = p end)
    return services_racePhases.sort(list, session.settings.ranking)
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
    local showGates = true
    if overrides.showGates ~= nil then
        showGates = overrides.showGates == true
    elseif defaults.showGates ~= nil then
        showGates = defaults.showGates == true
    end
    local waypointBeams = true
    if overrides.waypointBeams ~= nil then
        waypointBeams = overrides.waypointBeams == true
    elseif defaults.waypointBeams ~= nil then
        waypointBeams = defaults.waypointBeams == true
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

    -- a flying start (direct request) : a point-to-point track's only, where the first checkpoint
    -- can be the start line, run up to at speed. A circuit's laps already run line to line
    local flyingStart = false
    if not race.loopable then
        if overrides.flyingStart ~= nil then
            flyingStart = overrides.flyingStart == true
        elseif defaults.flyingStart ~= nil then
            flyingStart = defaults.flyingStart == true
        end
    end

    -- an out lap (direct request) : a circuit's only, a lap from the grid before the timed ones
    local outLap = false
    if race.loopable then
        if overrides.outLap ~= nil then
            outLap = overrides.outLap == true
        elseif defaults.outLap ~= nil then
            outLap = defaults.outLap == true
        end
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
        rejoinGraceMinutes = math.clamp(math.floor(tonumber(overrides.rejoinGraceMinutes) or
            defaults.rejoinGraceMinutes or 10), 0, 120),
        resetPenaltyEnabled = resetPenaltyEnabled,
        resetPenaltySeconds = math.max(1, tonumber(overrides.resetPenaltySeconds) or defaults.resetPenaltySeconds or 5),
        resetPenaltyMode = (overrides.resetPenaltyMode or defaults.resetPenaltyMode) == "time" and "time" or "hold",
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
        showGates = showGates,
        waypointBeams = waypointBeams,
        allowTuning = allowTuning,
        randomizeVehiclePool = randomizeVehiclePool,
        flyingStart = flyingStart,
        outLap = outLap,
        -- server plugins' own options (services/pluginUi.lua) : plugin -> option -> value
        plugins = services_pluginUi.sessionValues(defaults.plugins, overrides.plugins),
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
        penaltyMs = 0,
        lastProgressTime = GetCurrentTime(),
    }
end

--- the grid in BeamJoy's own order (the session's placementMode) : participants by slot
---@param session BJRaceSession
---@param race BJRace
---@return {p: BJRaceParticipant, slot: integer}[]
local function defaultGrid(session, race)
    local grid = {}
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
            if p.sittingOut then return end
            local slot = p.gridSlot
            if slot and race.startPositions[slot] and not taken[slot] then
                taken[slot] = true
                grid[#grid + 1] = { p = p, slot = slot }
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
            grid[#grid + 1] = { p = p, slot = nextFree }
        end
        table.sort(grid, function(a, b)
            if a.slot ~= b.slot then return a.slot < b.slot end
            return (a.p.joinIndex or 0) < (b.p.joinIndex or 0)
        end)
    else
        -- "deterministic" : lobby join order, starter first. This replaces the old implicit
        -- behavior, which iterated session.participants (keyed by playerID) with pairs() and was
        -- therefore arbitrary, not actually join-ordered. "random" : a real shuffle on top.
        --
        -- Shuffled in place, NOT via table.shuffle : that util deep-CLONES its input first
        -- (table.clone all the way down), so the loop below would assign startPosition onto
        -- throwaway copies while the real session.participants records never got one at all.
        -- Confirmed live as "random placement just fails to teleport people": every client hit
        -- raceRunner.lua's own "no start position to teleport to" fallback. values() itself is
        -- safe (it rebuilds the ARRAY but keeps the same participant references inside).
        local participants = session.participants:filter(function(p) return not p.sittingOut end):values()
        table.sort(participants, function(a, b) return (a.joinIndex or 0) < (b.joinIndex or 0) end)
        if mode == services_races.PLACEMENT_MODES.RANDOM then
            for i = #participants, 2, -1 do
                local j = math.random(i)
                participants[i], participants[j] = participants[j], participants[i]
            end
        end
        for i, p in ipairs(participants) do grid[i] = { p = p, slot = i } end
    end
    return grid
end

--- a plugin's order (player IDs, first on the grid first) over BeamJoy's own grid : the racers it
--- names, in its order, then anyone it left out, in BeamJoy's order ; slots from the front, no gaps
---@param grid {p: BJRaceParticipant, slot: integer}[]
---@param order integer[]?
---@return {p: BJRaceParticipant, slot: integer}[]
local function applyGridOrder(grid, order)
    if type(order) ~= "table" or #order == 0 then return grid end
    local byID, used, ordered = {}, {}, {}
    for _, e in ipairs(grid) do byID[e.p.playerID] = e end
    for _, id in ipairs(order) do
        local e = byID[id]
        if e and not used[e] then
            used[e] = true
            ordered[#ordered + 1] = e.p
        end
    end
    for _, e in ipairs(grid) do
        if not used[e] then ordered[#ordered + 1] = e.p end
    end
    local out = {}
    for i, p in ipairs(ordered) do out[i] = { p = p, slot = i } end
    return out
end

--- places the grid, freezes the field, schedules the actual race start
---@param session BJRaceSession
---@param race BJRace
---@param grid {p: BJRaceParticipant, slot: integer}[]
---@param orderedBy string? the plugin whose order this is
local function startCountdown(session, race, grid, orderedBy)
    session.state = "COUNTDOWN"
    -- a plugin's race.setGridOrder was for this grid
    session.pluginGridOrder, session.pluginGridOrderBy = nil, nil
    local placed = {}
    for i, e in ipairs(grid) do
        e.p.startPosition = race.startPositions[((e.slot - 1) % #race.startPositions) + 1]
        e.p.gridPosition = i
        placed[i] = e.p
    end

    -- the green light on the shared clock (see goAtMs). Polled every server tick rather than
    -- utils_async.delayTask, whose whole-second clock fired up to ~2s after the countdown the
    -- clients displayed
    session.goAtMs = services_clockSync.nowMs() + math.floor(session.settings.countdown * 1000)
    local phase = currentPhase(session)
    session.phaseEndsAtMs = phase.timeLimitMin and session.goAtMs + math.floor(phase.timeLimitMin * 60000) or nil
    -- "individual" : one at a time from the first slot, in grid order, intervalS apart
    local outLap = session.settings.outLap == true and race.loopable or nil
    for i, p in ipairs(placed) do
        p.elapsedOffsetMs = 0
        p.awaitingStart = nil
        p.outLapPending = outLap
        if phase.start == services_racePhases.START.INDIVIDUAL then
            p.startAtMs = session.goAtMs + (i - 1) * (phase.intervalS or 10) * 1000
            p.clockBaseMs = p.startAtMs
            p.runStartPosition = race.startPositions[1]
        elseif phase.start == services_racePhases.START.SEQUENTIAL then
            -- "sequential" : the first in grid order goes now, the others wait their turn on their
            -- slot (releaseNextTurn) ; the phase's time limit is each one's own, from this start
            if i == 1 then
                p.startAtMs, p.clockBaseMs, p.runStartPosition = session.goAtMs, session.goAtMs, race.startPositions[1]
                -- the others watch till their turn, each from the first slot : the first one too,
                -- to be fair (direct request)
                if phase.waiting ~= "grid" then p.startPosition = race.startPositions[1] end
            else
                p.startAtMs, p.clockBaseMs, p.runStartPosition = nil, nil, nil
                p.awaitingStart = true
            end
        else
            p.startAtMs, p.clockBaseMs, p.runStartPosition = nil, nil, nil
            -- a plugin's phase : on their slot until the plugin starts them (race.startRacer)
            if phase.start == services_racePhases.START.PLUGIN then p.awaitingStart = true end
        end
    end
    session.flagAtMs, session.chequered, session.overtimeEndsAtMs = nil, nil, nil
    utils_async.task(function()
        return services_clockSync.nowMs() >= session.goAtMs
    end, function() M.beginRace(session.id) end, "BJRaceGrid-" .. session.id .. "-countdown")
    pushSessionUpdate(session)
    pushOpenSessionsList()
    apiEvent("raceCountdown", session, placed, orderedBy)
end

--- the phase's grid in BeamJoy's own order : the lobby's (the session's placementMode), or an
--- earlier phase's result / the event's standings so far (reversed as the phase asks), the racers
--- without a place there behind, in the lobby's order
---@param session BJRaceSession
---@param race BJRace
---@return {p: BJRaceParticipant, slot: integer}[]
local function phaseGrid(session, race)
    local lobby = defaultGrid(session, race)
    local order = currentPhase(session).order
    if order.from == "lobby" then return lobby end
    local rows = order.from == "phase" and session.phaseResults[order.phase] or session.eventStandings
    local byJoin, used, out = {}, {}, {}
    for _, e in ipairs(lobby) do byJoin[e.p.joinIndex] = e end
    for _, joinIndex in ipairs(services_racePhases.orderOf(rows, order.reverse)) do
        local e = byJoin[joinIndex]
        if e and not used[e] then
            used[e] = true
            out[#out + 1] = { p = e.p, slot = #out + 1 }
        end
    end
    for _, e in ipairs(lobby) do
        if not used[e] then out[#out + 1] = { p = e.p, slot = #out + 1 } end
    end
    return out
end

--- a gridOrder hook's `take` : only these racers (player IDs) race the phase, the others sit it out
---@param grid {p: BJRaceParticipant, slot: integer}[]
---@param take integer[]
---@return {p: BJRaceParticipant, slot: integer}[]
local function takeOnly(grid, take)
    local wanted, out = {}, {}
    for _, id in ipairs(take) do wanted[id] = true end
    for _, e in ipairs(grid) do
        if wanted[e.p.playerID] then
            out[#out + 1] = { p = e.p, slot = #out + 1 }
        else
            e.p.sittingOut = true
        end
    end
    return out
end

local finishEvent

--- begins a phase's countdown : start positions per its order, or a plugin's (race.setGridOrder,
--- or an answer to the gridOrder hook, asked first, which may also pick who races)
---@param session BJRaceSession
local function beginCountdown(session)
    local state = session.state
    if (state ~= "GRID" and state ~= "BREAK") or session.placing then return end
    local race = getRace(session)
    if not race then return removeSession(session) end
    local grid = phaseGrid(session, race)
    -- nobody left to race this phase (everyone out of the event, or left out of it)
    if #grid == 0 then return finishEvent(session) end
    -- a solo start has no order to decide
    if #grid <= 1 or not (services_api and services_api.hasHook("gridOrder")) then
        return startCountdown(session, race, applyGridOrder(grid, session.pluginGridOrder),
            session.pluginGridOrder and session.pluginGridOrderBy or nil)
    end
    local okData, data = pcall(services_api.gridOrderHookData, session, grid)
    if not okData then
        LogError("[BJ raceGrid] the gridOrder hook's question failed : " .. tostring(data))
        return startCountdown(session, race, applyGridOrder(grid, session.pluginGridOrder),
            session.pluginGridOrder and session.pluginGridOrderBy or nil)
    end
    -- held while the plugins are asked : no joining, no ready changes (raceJoin / raceReady)
    session.placing = true
    services_api.runHook("gridOrder", data, function(answers)
        session.placing = nil
        if M.sessions[session.id] ~= session or session.state ~= state then return end
        -- anyone who left meanwhile is off the grid
        local still = {}
        for _, e in ipairs(grid) do
            if session.participants[e.p.playerID] == e.p then still[#still + 1] = e end
        end
        if #still == 0 then
            if state == "GRID" then return removeSession(session) end
            return finishEvent(session)
        end
        local take = services_api.firstTake(answers, session)
        if take then
            local taken = takeOnly(still, take)
            if #taken > 0 then still = taken end
        end
        local order, by = services_api.firstOrder(answers, session)
        if not order then order, by = session.pluginGridOrder, session.pluginGridOrderBy end
        startCountdown(session, race, applyGridOrder(still, order), order and by or nil)
    end)
end

---@param sessionId string
local function beginRace(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "COUNTDOWN" then return end

    session.state = "RACE"
    session.startedAt = GetCurrentTime()
    session.finishCounter = 0
    session.participants:forEach(function(p)
        p.currentGate = 0
        p.lastCrossedGate = 0
        p.currentLap = 1
        p.gateTimes = {}
        p.lapTimes = {}
        p.finishOrder = nil
        p.discordResult = nil
        p.bestLapMs = nil
        p.bestLapAtMs = nil
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
    session.lastPositions = nil
    pushSessionUpdate(session)
    -- open to join now (a phase's lateJoin : summarize's lateJoinable). Real bug (direct report : no
    -- Join button on a running race with it on) : the list was last sent at the countdown, when
    -- nobody could join yet, and nothing sent it again
    pushOpenSessionsList()
    apiEvent("raceGreenLight", session)
end

--- a finished phase's results, in its standings' order (the disqualified, then the ones without a
--- place, last), for the event's standings, Discord and the plugin API. Each row is a snapshot :
--- the racers go on to the next phase, their laps reset
---@param session BJRaceSession
---@param order integer[]? player IDs, first first : a plugin's order (the phaseResult hook) ahead of
---the standings' own
---@return table? info, table[] results
local function buildResults(session, order)
    local race = getRace(session)
    if not race then return nil, {} end
    local phase = currentPhase(session)
    local ranking = session.settings.ranking or services_racePhases.RANKING.POSITION
    local board = services_races.getLeaderboard(session.raceId, math.huge)
    local results, position, mostLaps = {}, 0, 0
    local standings = computeLeaderboard(session)
    if type(order) == "table" and #order > 0 then
        local rank = {}
        for i, id in ipairs(order) do if rank[id] == nil then rank[id] = i end end
        local before = {}
        for i, p in ipairs(standings) do before[p] = i end
        table.sort(standings, function(a, b)
            if (a.sittingOut == true) ~= (b.sittingOut == true) then return not a.sittingOut end
            if (a.disqualified == true) ~= (b.disqualified == true) then return not a.disqualified end
            local ra, rb = rank[a.playerID], rank[b.playerID]
            if (ra ~= nil) ~= (rb ~= nil) then return ra ~= nil end
            if ra and ra ~= rb then return ra < rb end
            return before[a] < before[b]
        end)
    end
    for _, p in ipairs(standings) do
        -- racedebug's ghost. Not any negative id : a racer who left mid-race waits under one (see
        -- nextAwayKey), and still has a result once retired. Nor anyone who sat this phase out
        if p.playerID ~= -1000 and not p.sittingOut then
            -- a copy : Real bug (direct report) : filled in place, the participant's own
            -- discordResult took order = math.huge for anyone who didn't finish, went out with the
            -- session's last update as "inf" (not JSON), and no client could read that update
            local r = table.clone(p.discordResult or { counted = false })
            -- a plugin's order (the phaseResult hook) places whoever it names
            local placed = services_racePhases.classified(p, ranking) or
                (order ~= nil and table.includes(order, p.playerID) and not p.disqualified)
            if placed then
                position = position + 1
                r.position = position
            end
            r.playerID = p.playerID
            -- their BeamMP name (playerName is their leaderboard name) : the client finds its own row by it
            r.connectionName = p.playerName
            r.joinIndex = p.joinIndex
            r.playerName = services_identity.getIdentityKey(p.playerID) or p.nickname or p.playerName
            r.vehicle = p.vehicleModel
            r.dnf = not placed
            r.disqualified = p.disqualified == true
            r.penaltyMs = (p.penaltyMs or 0) > 0 and p.penaltyMs or nil
            r.totalMs = placed and ranking ~= services_racePhases.RANKING.BEST and raceTimeMs(p) or nil
            r.bestLapMs = #p.lapTimes > 0 and math.min(table.unpack(p.lapTimes)) or nil
            r.lapsDone = #p.lapTimes
            r.order = p.finishOrder
            -- a plugin's score (phase.setScores)
            r.score, r.scoreDisplay = p.score, p.scoreDisplay
            r.identity = participantIdentityKind(p)
            r.fields = services_pluginUi.fieldList(services_pluginUi.withoutHudOnly(services_pluginUi.racerFields(session, p)))
            r.lapTimes = table.clone(p.lapTimes or {})
            r.lapSectorHistory = table.clone(p.lapSectorHistory or {})
            r.bestSectorMs = table.clone(p.bestSectorMs or {})
            if r.counted then
                for _, entry in ipairs(board) do
                    if entry.playerName == r.playerName then r.rank = entry.rank end
                end
                r.entries = #board
            end
            if r.lapsDone > mostLaps then mostLaps = r.lapsDone end
            table.insert(results, r)
        end
    end
    local name = race.name or "?"
    if #session.phases > 1 then
        name = string.format("%s - %s", name, phase.name or ("#" .. tostring(session.phaseIndex)))
    end
    local info = {
        raceName = name,
        -- Discord shows a race's total time, a single lap's (or a best lap's) time on its own
        laps = ranking == services_racePhases.RANKING.BEST and 1 or (phase.laps or math.max(1, mostLaps)),
        recordMs = board[1] and board[1].time,
        recordHolder = board[1] and board[1].playerName,
    }
    return info, results
end

---@param info table
---@param results table[]
local function postToDiscord(info, results)
    if not services_discord or #results == 0 then return end
    if #results == 1 then
        return services_discord.onRaceFinish(info, results[1])
    end
    services_discord.onRaceStandings(info, results)
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
    -- a disqualified run never counts
    if participant.disqualified then return end
    -- nor a phase kept off the leaderboard (racePhases : its `leaderboard`)
    if currentPhase(session).leaderboard == false then return end
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
    -- login workaround (services/identity.lua's own doc comment): credits the leaderboard entry
    -- to the participant's chosen nickname if they've logged in with one, same raw connection
    -- playerName as before otherwise. Only the leaderboard's own key changes here - this session's
    -- OWN bookkeeping (participant.playerName itself, used everywhere else in this file) is
    -- untouched.
    local key = services_identity.getIdentityKey(participant.playerID) or participant.nickname or
        participant.playerName
    local previous = race and race.leaderboard and race.leaderboard[key]
    local previousMs = previous and previous.time
    participant.isNewPB, participant.isNewRecord = services_races.submitTime(
        session.raceId, key, participant.vehicleModel or "", timeMs, nil, participantIdentityKind(participant),
        services_pluginUi.withoutHudOnly(services_pluginUi.racerFields(session, participant)))
    if participant.isNewPB then
        -- kept to put back if staff disqualify this run (raceStaffAction)
        participant.leaderboardKey = key
        participant.replacedEntry = previous and table.clone(previous) or nil
    end
    participant.discordResult = {
        counted = true,
        isNewPB = participant.isNewPB,
        isNewRecord = participant.isNewRecord,
        previousMs = previousMs,
    }
end

--- the event is over : its result (the event's standings, or the last phase's when no phase
--- counts towards it) to the plugin API, the results shown for a few seconds, then it closes
---@param session BJRaceSession
finishEvent = function(session)
    session.state = "FINISHED"
    session.phaseEndsAtMs, session.flagAtMs, session.chequered, session.overtimeEndsAtMs = nil, nil, nil, nil
    session.breakEndsAtMs = nil
    utils_async.removeTask("BJRaceGrid-" .. session.id .. "-break")
    local race = getRace(session)
    local last = session.phaseResults[session.phaseIndex] or {}
    local info = { raceName = race and race.name or "?", laps = session.settings.laps }
    if services_api then
        local ok, err = pcall(services_api.raceFinished, session, info, session.eventStandings or last)
        if not ok then LogError("[BJ raceGrid] plugin API raceFinished failed : " .. tostring(err)) end
    end
    pushSessionUpdate(session)
    pushOpenSessionsList()
    utils_async.delayTask(function() removeSession(session) end,
        10, "BJRaceGrid-" .. session.id .. "-cleanup")
end

local function nextPhase(sessionId) return M.nextPhase(sessionId) end

--- a phase's result, final : kept, posted when it counts towards the event, then the break before
--- the next phase, or the event's end
---@param session BJRaceSession
---@param order integer[]? a plugin's order (the phaseResult hook)
local function finalizePhase(session, order)
    local index = session.phaseIndex
    local built, info, results = pcall(buildResults, session, order)
    if not built then
        LogError("[BJ raceGrid] a phase's results failed : " .. tostring(info))
        info, results = nil, {}
    end
    session.phaseResults[index] = results or {}
    session.eventStandings = services_racePhases.eventStandings(session.phases, session.phaseResults,
        session.result, session.eventScores)
    if info and currentPhase(session).countsToEvent then pcall(postToDiscord, info, results) end
    apiEvent("racePhaseFinished", session, index, session.phaseResults[index])
    if index >= #session.phases then return finishEvent(session) end

    session.state = "BREAK"
    session.phaseEndsAtMs, session.flagAtMs, session.chequered, session.overtimeEndsAtMs = nil, nil, nil, nil
    session.breakEndsAtMs = services_clockSync.nowMs() + currentPhase(session).breakS * 1000
    local sessionId = session.id
    utils_async.task(function()
        return services_clockSync.nowMs() >= (session.breakEndsAtMs or 0)
    end, function() nextPhase(sessionId) end, "BJRaceGrid-" .. session.id .. "-break")
    pushSessionUpdate(session)
    pushOpenSessionsList()
end

--- a racer a plugin put out (the phaseResult hook's `out`) : disqualified, their leaderboard time
--- for this phase withdrawn, as staff disqualifying them would
---@param session BJRaceSession
---@param p BJRaceParticipant
local function judgedOut(session, p)
    if p.disqualified then return end
    p.disqualified = true
    if p.leaderboardKey then
        services_races.restoreEntry(session.raceId, p.leaderboardKey, p.replacedEntry)
        p.isNewPB, p.isNewRecord = false, false
        p.leaderboardKey, p.replacedEntry = nil, nil
        if p.discordResult then p.discordResult.counted = false end
    end
    apiEvent("racerOut", session, p, "disqualified")
end

--- a phase is over (everyone in it finished or out) : the plugins answering the phaseResult hook
--- may change its result first (time penalties, racers out, their own order : judging, stewards),
--- then it's final (finalizePhase)
---@param session BJRaceSession
local function completePhase(session)
    if session.judging then return end
    if not (services_api and services_api.hasHook("phaseResult")) then return finalizePhase(session) end
    local okData, data = pcall(services_api.phaseResultHookData, session)
    if not okData then
        LogError("[BJ raceGrid] the phaseResult hook's question failed : " .. tostring(data))
        return finalizePhase(session)
    end
    session.judging = true
    services_api.runHook("phaseResult", data, function(answers)
        session.judging = nil
        if M.sessions[session.id] ~= session or session.state ~= "RACE" then return end
        local judged = services_api.judging(answers, session)
        for id, ms in pairs(judged.adjustMs) do
            local p = session.participants[id]
            if p then p.penaltyMs = math.max(0, (p.penaltyMs or 0) + ms) end
        end
        for _, id in ipairs(judged.out) do
            local p = session.participants[id]
            if p then judgedOut(session, p) end
        end
        finalizePhase(session, judged.order)
    end)
end

--- a "sequential" phase's next turn, released once nobody's on track (defined below personalStart)
local releaseNextTurn

local function checkSessionComplete(session)
    if session.state ~= "RACE" or session.judging then return end
    -- one at a time : the last one's turn is over, the next one goes (the phase isn't)
    if releaseNextTurn(session) then return end
    -- a disconnected racer is neither finished nor out : the race waits for their grace period,
    -- but only while someone else is still racing. Real bug (direct report) : one racer left
    -- mid-race and, once everyone still there had finished, the race went on for the rest of the
    -- grace period with nobody in it. Once the last one here is done, those away are retired. (The
    -- last one still racing dropping out themselves is still waited for : nothing calls this then,
    -- see onPlayerDisconnect). With phases still to come, they keep their grace period for those
    local present, racing = false, false
    session.participants:forEach(function(p)
        if p.disconnected or p.sittingOut then return end
        present = true
        if not (p.finished or p.dnf) then racing = true end
    end)
    if present and not racing then
        local morePhases = session.phaseIndex < #session.phases
        session.participants:forEach(function(p)
            if not p.disconnected or p.sittingOut or p.finished or p.dnf then return end
            if not morePhases then
                utils_async.removeTask(rejoinTaskKey(session.id, p.playerName))
                p.disconnected, p.rejoinBy, p.rejoinSecondsLeft = nil, nil, nil
            end
            p.dnf = true
            if p.bestLapMs then trySubmitTime(session, p, p.bestLapMs) end
            apiEvent("racerOut", session, p, "disconnected")
        end)
    end
    if session.participants:every(function(p) return p.finished or p.dnf or p.sittingOut end) then
        completePhase(session)
    end
end

---@param session BJRaceSession
---@param participant BJRaceParticipant
---@param noCheck boolean? the caller checks whether the phase is over itself (several at once)
local function finishParticipant(session, participant, noCheck)
    participant.finished = true
    session.finishCounter = (session.finishCounter or 0) + 1
    participant.finishOrder = session.finishCounter
    if #participant.lapTimes > 0 then
        trySubmitTime(session, participant, math.min(table.unpack(participant.lapTimes)))
    end
    apiEvent("racerFinished", session, participant)
    if not noCheck then checkSessionComplete(session) end
end

--- once a run's done before the next starts (the car rolls to a stop, or not), ms
local RUN_ROLL_MS = 3000

--- a racer's next personal start : a run on a point-to-point track (back to the first slot, a
--- short countdown, a clock of its own), or a mid-phase join (`clockFromGreen` : a race's time
--- still counts from the phase's green light)
---@param session BJRaceSession
---@param p BJRaceParticipant
---@param position table where they start
---@param delayMs integer before the countdown
---@param clockFromGreen boolean?
local function personalStart(session, p, position, delayMs, clockFromGreen, countdownMs)
    p.awaitingStart = nil
    p.startAtMs = services_clockSync.nowMs() + delayMs + (countdownMs or session.settings.startCountdownMs or 5000)
    p.clockBaseMs = clockFromGreen and session.goAtMs or p.startAtMs
    p.runStartPosition = position
    -- the laps done so far : the new clock starts at 0 (from the green light : it never stopped)
    p.elapsedOffsetMs = clockFromGreen and 0 or services_racePhases.timeOf(p) - (p.penaltyMs or 0)
    p.currentGate, p.lastCrossedGate = 0, 0
    p.gateTimes = {}
    p.liveDeltaMs = nil
    p.currentSector, p.sectorStartMs, p.lapSectors = 1, 0, {}
    p.lastProgressTime = GetCurrentTime()
    -- a circuit's out lap : every start of one's own has one (settings.outLap is a circuit's only)
    p.outLapPending = session.settings.outLap == true or nil
    apiEvent("racerStarted", session, p)
end

---@param session BJRaceSession
---@return boolean
local function isSequential(session)
    return currentPhase(session).start == services_racePhases.START.SEQUENTIAL
end

--- on track in a "sequential" phase : started, not done
---@param p BJRaceParticipant
---@return boolean
local function onTurn(p)
    return not (p.finished or p.dnf or p.sittingOut or p.awaitingStart)
end

--- a "sequential" phase (one at a time) : once nobody's on track, the next one waiting, in grid
--- order, goes from the first slot after a short countdown. The phase's clock is theirs now : its
--- time limit counted from their start, the time's up flag and overtime cleared, so the HUD counts
--- their time down and a time limit is the same for each. A racer away (disconnected) is passed
--- over ; back in time, they're still waiting
---@param session BJRaceSession
---@return boolean whether a turn started
releaseNextTurn = function(session)
    if session.state ~= "RACE" or not isSequential(session) then return false end
    if session.participants:any(onTurn) then return false end
    local nextUp
    session.participants:forEach(function(p)
        if not p.awaitingStart or p.disconnected or p.finished or p.dnf or p.sittingOut then return end
        if not nextUp or (p.gridPosition or math.huge) < (nextUp.gridPosition or math.huge) then nextUp = p end
    end)
    local race = getRace(session)
    if not nextUp or not race then return false end
    personalStart(session, nextUp, race.startPositions[1], RUN_ROLL_MS)
    local minutes = currentPhase(session).timeLimitMin
    session.phaseEndsAtMs = minutes and nextUp.startAtMs + math.floor(minutes * 60000) or nil
    session.flagAtMs, session.chequered, session.overtimeEndsAtMs = nil, nil, nil
    pushSessionUpdate(session)
    return true
end

--- a "sequential" phase's turn is over now (its time's up and afterTime "stop", its overtime's over)
--- : the one on track is done with the laps they completed, or out without any, and the next goes
---@param session BJRaceSession
local function endTurnNow(session)
    if session.state ~= "RACE" then return end
    session.participants:forEach(function(p)
        if not onTurn(p) then return end
        if #p.lapTimes > 0 then
            finishParticipant(session, p, true)
        else
            p.dnf = true
            apiEvent("racerOut", session, p, "timeUp")
        end
    end)
    checkSessionComplete(session)
    if session.state == "RACE" then pushSessionUpdate(session) end
end

--- whether the lap a racer just completed ends their phase : its laps done, or, once its time is
--- up, its afterTime : "own" their lap counts and they're done ; "leader" the leader's lap ends
--- their race, then everyone's next. ("stop" ends it at once, see timeUp)
---@param session BJRaceSession
---@param p BJRaceParticipant
---@return boolean
local function lapEndsPhase(session, p)
    local laps = session.settings.laps
    if laps and #p.lapTimes >= laps then return true end
    if not session.flagAtMs then return false end
    if session.settings.afterTime ~= services_racePhases.AFTER_TIME.LEADER or session.chequered then return true end
    -- the leader : someone's already through the flag, or nobody still in it has done as many laps
    local leads = session.participants:any(function(o) return o.finished end) or
        session.participants:every(function(o)
            return o == p or o.dnf or o.disqualified or o.sittingOut or #o.lapTimes < #p.lapTimes
        end)
    if leads then session.chequered = true end
    return leads
end

--- a phase ends now (its time's up and afterTime "stop", the overtime's over, or a plugin ends it)
--- : whoever's still out there is done, finished with the laps they completed (the one under way
--- doesn't count), or out when they have none
---@param session BJRaceSession
local function endPhaseNow(session)
    if session.state ~= "RACE" then return end
    session.participants:forEach(function(p)
        if p.finished or p.dnf or p.sittingOut then return end
        if #p.lapTimes > 0 then
            finishParticipant(session, p, true)
        else
            p.dnf = true
            apiEvent("racerOut", session, p, "timeUp")
        end
    end)
    checkSessionComplete(session)
    if session.state == "RACE" then pushSessionUpdate(session) end
end

--- a timed phase's time is up : per its afterTime, at once ("stop") or once each racer finishes
--- their lap. Not forever (stopped, lost out there) : 1.5 times the phase's fastest lap, a minute at
--- least, then whoever's left is done
---@param session BJRaceSession
---@param now integer the shared clock
local function timeUp(session, now)
    session.flagAtMs = now
    if session.settings.afterTime == services_racePhases.AFTER_TIME.STOP then
        if isSequential(session) then return endTurnNow(session) end
        return endPhaseNow(session)
    end
    -- the ones waiting for a start (their next run, their turn) : no run under way, they're done
    local waiting = false
    session.participants:forEach(function(p)
        if p.finished or p.dnf or p.sittingOut or not p.startAtMs or p.startAtMs <= now then return end
        waiting = true
        if #p.lapTimes > 0 then
            finishParticipant(session, p, true)
        else
            p.dnf = true
            apiEvent("racerOut", session, p, "timeUp")
        end
    end)
    if waiting then
        checkSessionComplete(session)
        if session.state ~= "RACE" then return end
    end
    local fastest
    session.participants:forEach(function(p)
        if p.bestLapMs and (not fastest or p.bestLapMs < fastest) then fastest = p.bestLapMs end
    end)
    session.overtimeEndsAtMs = now + math.max(60000, math.floor((fastest or 120000) * 1.5))
    pushSessionUpdate(session)
end

-- forward-declared: updateAllReadyState's own rescheduled delayTask (below) needs to call this
-- from a closure defined lexically before tryStartFromGrid's own definition
local tryStartFromGrid, onGridTimeout

--- Tracks the moment (server GetCurrentTime() domain) this session's participants most recently
--- became ALL ready, clearing it again the instant that's no longer true (someone leaves unready,
--- joins unready, un-readies via a vehicle change). gridReadySecondsLeft (buildSessionPayload) and
--- the actual start-floor check (tryStartFromGrid, below) are both anchored to this now, not
--- session.createdAt.
---
--- Real, confirmed bug (direct report) this replaces: the floor used to be measured from when the
--- LOBBY was created, not from when everyone actually finished readying up. The displayed
--- "Starting in Xs" only appears once everyone's ready (client-side gate), so what a player saw was
--- "however much of the floor happened to be left over" at that moment - anywhere from the full
--- gridReadyTimeout down to 0/instant-start, depending purely on how long people took to ready up,
--- not a consistent countdown. Re-anchoring to the moment everyone's actually ready makes it a real,
--- consistent gridReadyTimeout-second wait every time, matching what "Starting in Xs" implies.
--- Schedules (or reschedules, on a later re-ready) the same fallback delayTask raceStart used to
--- schedule once at session creation, so a lobby where everyone was ready from the very start still
--- reliably auto-starts even with no further reactive trigger (leave/ready-toggle) to catch it.
---@param session BJRaceSession
local function updateAllReadyState(session)
    local allReady = session.participants:length() > 0 and
        session.participants:every(function(p) return p.ready end)
    local key = "BJRaceGrid-" .. session.id .. "-readyTimeout"
    if allReady and not session.allReadyAt then
        session.allReadyAt = GetCurrentTime()
        if session.joinable then
            utils_async.delayTask(function() tryStartFromGrid(session) end,
                session.settings.gridReadyTimeout, key)
        end
    elseif not allReady and session.allReadyAt then
        session.allReadyAt = nil
        utils_async.removeTask(key)
    end
end

---@param session BJRaceSession whose GRID phase just ended (start-now, or force-cut via timers)
tryStartFromGrid = function(session)
    if session.state ~= "GRID" then return end
    updateAllReadyState(session)
    -- a plugin's lobby held for its time (race.open's holdStart) : its time's up, or the plugin says
    if session.holdStart then return end
    -- a private lobby nobody joined is a solo start (not a plugin's : it waits for its entrants)
    if not session.joinable or (session.private and not session.hostedBy and session.participants:length() == 1) then
        -- solo path: starts the instant its lone participant is ready, no grace period
        if session.participants:every(function(p) return p.ready end) then
            beginCountdown(session)
        end
        return
    end
    if session.allReadyAt and
        GetCurrentTime() - session.allReadyAt >= session.settings.gridReadyTimeout then
        beginCountdown(session)
    end
end

--- the lobby's time is up (or the leader pressed Start now) : whoever isn't ready is dropped and
--- the rest go to the countdown
---@param sessionId string
onGridTimeout = function(sessionId)
    local s = M.sessions[sessionId]
    if not s or s.state ~= "GRID" then return end
    utils_async.removeTask("BJRaceGrid-" .. s.id .. "-gridTimeout")
    local kicked = s.participants:filter(function(p) return not p.ready end):values()
    s.participants = s.participants:filter(function(p) return p.ready end)
    -- notify anyone kicked for not readying up in time directly. pushSessionUpdate only ever
    -- reaches current participants, and they're no longer one
    table.forEach(kicked, function(p)
        communications_tx.sendToPlayer(p.playerID, "raceSessionRemoved", s.id)
    end)
    if s.participants:length() == 0 then
        return removeSession(s)
    end
    beginCountdown(s)
end

--- tells a racer a plugin refused their ready-up, or unreadied them
---@param p BJRaceParticipant
---@param key string "race.readyBlocked" / "race.unreadied" (+ "NoReason" when there's none)
---@param reason string?
local function tellReadyBlocked(p, key, reason)
    local player = services_players.players:find(function(pl) return pl.playerID == p.playerID end)
    if not player then return end
    local text
    if reason and #reason > 0 then
        -- string.var substitutes with gsub, where a "%" in the reason would be read as a capture
        text = services_lang.get(key, player.lang):var({ reason = (reason:gsub("%%", "%%%%")) })
    else
        text = services_lang.get(key .. "NoReason", player.lang)
    end
    communications_tx.sendToPlayer(p.playerID, "toast", "warning", text)
end

--- a racer readying up : the plugins answering the plugin API's raceReady hook may refuse, with a
--- reason the racer sees in the lobby (direct request). The racer shows as "checking" while
--- they're asked, then `onAllowed(session, participant)` ; at once when no plugin answers it
---@param session BJRaceSession
---@param participant BJRaceParticipant
---@param onAllowed fun(session: BJRaceSession, participant: BJRaceParticipant)
local function requestReady(session, participant, onAllowed)
    if not (services_api and services_api.hasHook("raceReady")) then
        participant.readyBlockReason, participant.readyBlockBy = nil, nil
        return onAllowed(session, participant)
    end
    local okData, data = pcall(services_api.readyHookData, session, participant)
    if not okData then
        LogError("[BJ raceGrid] the raceReady hook's question failed : " .. tostring(data))
        return onAllowed(session, participant)
    end
    participant.readyChecking = true
    local sessionId, playerID = session.id, participant.playerID
    services_api.runHook("raceReady", data, function(answers)
        local s = M.sessions[sessionId]
        local p = s and s.participants[playerID]
        -- unreadied, gone, or the lobby moved on meanwhile : the answer is moot
        if not p or not p.readyChecking or s.state ~= "GRID" then return end
        p.readyChecking = nil
        local block = services_api.firstBlock(answers)
        if block then
            p.ready = false
            p.readyBlockReason, p.readyBlockBy = block.reason, block.by
            tellReadyBlocked(p, "race.readyBlocked", block.reason)
            updateAllReadyState(s)
            return pushSessionUpdate(s)
        end
        p.readyBlockReason, p.readyBlockBy = nil, nil
        onAllowed(s, p)
    end)
    if participant.readyChecking and M.sessions[sessionId] then pushSessionUpdate(session) end
end

--- the plugin API's race.unready : a plugin takes a racer in a lobby back to not ready, with a
--- reason they see (their car no longer qualifies, they still owe an entry fee...)
---@param playerID integer
---@param reason string?
---@param plugin string
---@return boolean ok, string? why not
local function pluginUnready(playerID, reason, plugin)
    local session = findSessionByParticipant(playerID)
    if not session then return false, "that player isn't in a race lobby" end
    if session.state ~= "GRID" then return false, "their race has already started" end
    if session.placing then return false, "their grid is being placed" end
    local p = session.participants[playerID]
    local wasReady = p.ready or p.readyChecking
    p.ready = false
    p.readyChecking = nil
    p.readyBlockReason = reason
    p.readyBlockBy = reason and plugin or nil
    if wasReady or reason then tellReadyBlocked(p, "race.unreadied", reason) end
    updateAllReadyState(session)
    pushSessionUpdate(session)
    return true
end

--- the plugin API's race.setGridOrder : the order cars start in, set while the lobby is open
---@param session BJRaceSession
---@param order integer[] player IDs, first on the grid first
---@param plugin string
---@return boolean ok, string? why not
local function pluginSetGridOrder(session, order, plugin)
    if (session.state ~= "GRID" and session.state ~= "BREAK") or session.placing then
        return false, "that grid is already placed"
    end
    session.pluginGridOrder, session.pluginGridOrderBy = order, plugin
    return true
end

--- sessions whose racers' labels changed since the last onUpdate : sent once then, however many
--- labels changed in between (a plugin updating every racer's live label at once)
---@type table<string, true>
local fieldsChanged = {}

--- the plugin API's results.setFields : a plugin's labels on a racer, shown with their result (and
--- on the race HUD, the ones marked `hud`). When this race already put their time on the
--- leaderboard, the entry gets them too
---@param session BJRaceSession
---@param playerID integer
---@param plugin string
---@param fields table key -> field, or false to remove (services_pluginUi.fieldsOf)
---@param replace boolean?
---@return boolean ok, string? why not
local function pluginSetFields(session, playerID, plugin, fields, replace)
    local p = session.participants[playerID]
    if not p then return false, "that player isn't in this race" end
    p.pluginFields = services_pluginUi.applyFields(p.pluginFields, plugin, fields, replace)
    if p.leaderboardKey and p.isNewPB then
        services_races.setEntryFields(session.raceId, "grid", p.leaderboardKey, plugin, fields, replace)
    end
    fieldsChanged[session.id] = true
    return true
end

--- the plugin API's race.setPhases : a lobby's phases (and its result), checked like a start's.
--- Everyone goes back to not ready, as when the leader changes the settings
---@param session BJRaceSession
---@param phases any
---@param result any
---@return boolean ok, string? why not
local function pluginSetPhases(session, phases, result)
    if session.state ~= "GRID" or session.placing then return false, "only while the lobby is open" end
    local race = getRace(session)
    if not race then return false, "the race is gone" end
    local checked, why = services_racePhases.sanitize(phases, race)
    if not checked then return false, why end
    session.phases = checked
    if result ~= nil then session.result = services_racePhases.sanitizeResult(result) end
    session.settings = services_racePhases.effectiveSettings(session.baseSettings, checked[1])
    session.settingsRev = (session.settingsRev or 0) + 1
    session.participants:forEach(function(p)
        p.ready, p.readyChecking = false, nil
        p.readyBlockReason, p.readyBlockBy = nil, nil
    end)
    updateAllReadyState(session)
    pushSessionUpdate(session)
    return true
end

--- the plugin API's race.endPhase : the phase under way ends now (a red flag, a judged run over)
---@param session BJRaceSession
---@return boolean ok, string? why not
local function pluginEndPhase(session)
    if session.state ~= "RACE" then return false, "no phase is running" end
    if session.judging then return false, "its result is being decided" end
    endPhaseNow(session)
    return true
end

--- the plugin API's race.extendPhase : more time for a timed phase (less, with a negative), its
--- time not up yet
---@param session BJRaceSession
---@param minutes number
---@return boolean ok, string? why not
local function pluginExtendPhase(session, minutes)
    if session.state ~= "RACE" or not session.phaseEndsAtMs then return false, "no timed phase is running" end
    if session.flagAtMs then return false, "its time is already up" end
    local now = services_clockSync.nowMs()
    session.phaseEndsAtMs = math.max(now, session.phaseEndsAtMs + math.floor(minutes * 60000))
    pushSessionUpdate(session)
    return true
end

--- race control's "+1 lap" (direct request : a phase extended by laps when it's run on laps) and
--- the plugin API's race.extendPhase `laps` : more laps (runs) for the phase under way (fewer, with a
--- negative, never under 1 nor under what anyone's done). Not once someone's finished it : the
--- others would race more than they did
---@param session BJRaceSession
---@param laps integer
---@return boolean ok, string? why not
local function pluginExtendLaps(session, laps)
    if session.state ~= "RACE" or not session.settings.laps then return false, "no phase on laps is running" end
    if session.flagAtMs then return false, "its time is already up" end
    if session.participants:any(function(p) return p.finished end) then
        return false, "someone has already finished it"
    end
    local most = 0
    session.participants:forEach(function(p) most = math.max(most, #p.lapTimes) end)
    local now = math.clamp(session.settings.laps + math.floor(laps), math.max(1, most + 1), services_racePhases.MAX_LAPS)
    if now == session.settings.laps then return false, "no change" end
    session.settings.laps = now
    local phase = currentPhase(session)
    if phase then phase.laps = now end
    pushSessionUpdate(session)
    return true
end

--- the plugin API's race.nextPhase : no more break, the next phase's countdown now
---@param session BJRaceSession
---@return boolean ok, string? why not
local function pluginNextPhase(session)
    if session.state ~= "BREAK" or session.placing then return false, "not between two phases" end
    M.nextPhase(session.id)
    return true
end

--- the plugin API's race.startRacer : in a plugin's phase (start = "plugin"), this racer goes, after a
--- countdown, from their grid slot or the first one
---@param session BJRaceSession
---@param playerID integer
---@param countdownS number?
---@param from "grid"|"first"|nil
---@return boolean ok, string? why not
local function pluginStartRacer(session, playerID, countdownS, from)
    if session.state ~= "RACE" then return false, "no phase is running" end
    local p = session.participants[playerID]
    if not p then return false, "that player isn't in this race" end
    if not p.awaitingStart then return false, "that racer isn't waiting to start" end
    local race = getRace(session)
    if not race then return false, "the race is gone" end
    local position = from == "first" and race.startPositions[1] or p.startPosition or race.startPositions[1]
    personalStart(session, p, position, 0, false, math.floor(math.clamp(tonumber(countdownS) or 5, 0, 30) * 1000))
    pushSessionUpdate(session)
    return true
end

--- the plugin API's race.stopRacer : this racer's phase is over (a judged run done, a false start)
--- : finished with the laps (runs) they completed, or out without any
---@param session BJRaceSession
---@param playerID integer
---@return boolean ok, string? why not
local function pluginStopRacer(session, playerID)
    if session.state ~= "RACE" then return false, "no phase is running" end
    local p = session.participants[playerID]
    if not p then return false, "that player isn't in this race" end
    if p.finished or p.dnf or p.sittingOut then return false, "that racer is already done" end
    p.awaitingStart = nil
    if #p.lapTimes > 0 then
        finishParticipant(session, p)
    else
        p.dnf = true
        apiEvent("racerOut", session, p, "stopped")
        checkSessionComplete(session)
    end
    if session.state == "RACE" then pushSessionUpdate(session) end
    return true
end

--- a racer of this session by their racer key (the plugin API's `racerKey` : their joinIndex, the
--- same for the whole event, through a disconnect and a rejoin)
---@param session BJRaceSession
---@param key integer
---@return BJRaceParticipant?
local function participantByKey(session, key)
    return session.participants:find(function(p) return p.joinIndex == key end)
end

--- the plugin API's phase.setScores : a plugin's scores for this phase's racers (its ranking
--- "plugin" places them by these) or, `event`, for the event (its result "plugin")
---@param session BJRaceSession
---@param scores table<integer, number> player ID (racer key, `byKey`) -> score
---@param better "high"|"low"
---@param display table<integer, string>? the same keys -> the text shown ("86 pts")
---@param event boolean?
---@param byKey boolean? the keys are racer keys (joinIndex), not player IDs
---@return integer[] skipped the keys given that aren't racers of this event
local function pluginSetScores(session, scores, better, display, event, byKey)
    -- a racer by player ID : one in the race, or, for the event's scores, one who left it (or came
    -- back under a new ID) known by the latest phase result that has them under that ID. By racer
    -- key : the same, whatever their player ID
    local function racerOf(id)
        local p = byKey and participantByKey(session, id) or (not byKey and session.participants[id])
        if p then return p.joinIndex, p end
        if not event then return end
        for i = #(session.phases or {}), 1, -1 do
            for _, r in ipairs(session.phaseResults and session.phaseResults[i] or {}) do
                if (byKey and r.joinIndex or r.playerID) == id then return r.joinIndex end
            end
        end
    end
    local skipped = {}
    for id, score in pairs(scores) do
        local joinIndex, p = racerOf(id)
        local key = better == "high" and -score or score
        local text = display and display[id] or nil
        if not joinIndex then
            skipped[#skipped + 1] = id
        elseif event then
            session.eventScores = session.eventScores or {}
            session.eventScores[joinIndex] = { score = score, key = key, display = text }
        else
            p.score, p.scoreKey, p.scoreDisplay = score, key, text
        end
    end
    table.sort(skipped)
    if event then
        session.eventStandings = services_racePhases.eventStandings(session.phases, session.phaseResults,
            session.result, session.eventScores)
    end
    fieldsChanged[session.id] = true
    return skipped
end

local function onUpdate()
    local now = services_clockSync.nowMs()
    M.sessions:forEach(function(session)
        if session.state ~= "RACE" then return end
        if session.phaseEndsAtMs and not session.flagAtMs and now >= session.phaseEndsAtMs then
            timeUp(session, now)
        elseif session.overtimeEndsAtMs and now >= session.overtimeEndsAtMs then
            if isSequential(session) then endTurnNow(session) else endPhaseNow(session) end
        end
    end)
    if next(fieldsChanged) == nil then return end
    local ids = fieldsChanged
    fieldsChanged = {}
    for id in pairs(ids) do
        local session = M.sessions[id]
        if session then pushSessionUpdate(session) end
    end
end

--- the leader starts the race now with everyone who's ready (and is marked ready themselves,
--- through the same ready check as anyone)
---@param ctxt BJSContext
---@param sessionId string
local function raceStartNow(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.starterID ~= ctxt.senderID or session.placing then return end
    -- between phases : the next one now
    if session.state == "BREAK" then return M.nextPhase(session.id) end
    if session.state ~= "GRID" then return end
    local leader = session.participants[ctxt.senderID]
    if leader and not leader.ready then
        if leader.readyChecking then return end
        return requestReady(session, leader, function(s, p)
            p.ready = true
            onGridTimeout(s.id)
        end)
    end
    onGridTimeout(session.id)
end

local CAPTURE_KEYS = { "vehicleRestrictionModel", "vehicleRestrictionParts", "vehicleRestrictionVars",
    "vehicleRestrictionPaints" }
---@param opts table
---@return table
local function editableOpts(opts)
    local copy = table.clone(opts)
    for _, k in ipairs(CAPTURE_KEYS) do copy[k] = nil end
    return copy
end

--- a racer's state for a new phase : their laps, their result, any penalty or disqualification
--- were the last phase's
---@param p BJRaceParticipant
local function resetForPhase(p)
    p.currentGate, p.lastCrossedGate, p.currentLap = 0, 0, 1
    p.gateTimes, p.lapTimes = {}, {}
    p.finishOrder, p.discordResult = nil, nil
    p.bestLapMs, p.bestLapAtMs, p.bestLapGateTimes, p.liveDeltaMs = nil, nil, nil, nil
    p.currentSector, p.sectorStartMs = 1, 0
    p.lapSectors, p.lapSectorHistory, p.bestSectorMs = {}, {}, {}
    p.finished, p.dnf = false, false
    p.disqualified, p.penaltyMs, p.lastResetMs = nil, 0, nil
    p.isNewPB, p.isNewRecord, p.leaderboardKey, p.replacedEntry = nil, nil, nil, nil
    p.startPosition, p.gridPosition = nil, nil
    p.score, p.scoreKey, p.scoreDisplay, p.awaitingStart = nil, nil, nil, nil
    p.startAtMs, p.clockBaseMs, p.runStartPosition, p.elapsedOffsetMs = nil, nil, nil, nil
    p.outLapPending = nil
    p.lastProgressTime = GetCurrentTime()
end

--- the break is over (or the leader skipped it) : the next phase, its rules, who races it, its grid
---@param sessionId string
function M.nextPhase(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "BREAK" or session.placing then return end
    utils_async.removeTask("BJRaceGrid-" .. session.id .. "-break")
    session.breakEndsAtMs = nil
    session.phaseIndex = session.phaseIndex + 1
    local phase = currentPhase(session)
    session.settings = services_racePhases.effectiveSettings(session.baseSettings, phase)
    session.goAtMs = nil
    local takers
    if phase.takes then
        local rows = phase.takes.from and session.phaseResults[phase.takes.from] or session.eventStandings
        takers = services_racePhases.topOf(rows, phase.takes.top)
    end
    session.participants:forEach(function(p)
        resetForPhase(p)
        p.sittingOut = (p.eventOut or p.lateJoining or (takers ~= nil and not takers[p.joinIndex])) or nil
    end)
    beginCountdown(session)
end

---@param ctxt BJSContext
---@param raceId integer
---@param opts {joinable: boolean?, laps: integer?, respawnStrategy: string?, placementMode: string?, gridTimeout: integer?, gridReadyTimeout: integer?, countdown: integer?, dnfEnabled: boolean?, dnfTimeout: integer?, resetPenaltyEnabled: boolean?, resetPenaltySeconds: integer?, autoSpectateOnFinish: boolean?, disableNodegrabber: boolean?, disableCameras: boolean?, disableGravityChange: boolean?, vehicleRestrictionMode: string?, vehicleRestrictionModel: string?, vehicleRestrictionParts: table?, vehicleRestrictionVars: table?, vehicleRestrictionPaints: table?, vehicleRestrictionLabel: string?, vehicleRestrictionPoolPresetId: integer?, ghostOnCountdown: boolean?, disableCollisions: boolean?, ghostBackmarkers: boolean?, showGateNametags: boolean?, limitVisibleGates: boolean?, visibleGateCount: integer?, showGates: boolean?, waypointBeams: boolean?, allowTuning: boolean?}?
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
        baseSettings = buildSettings(race, opts),
        state = "GRID",
        createdAt = ctxt.time,
        participants = Table(),
        phaseIndex = 1,
        phaseResults = {},
    }
    session.phases, session.result, session.format = services_racePhases.fromStart(race, opts)
    session.settings = services_racePhases.effectiveSettings(session.baseSettings, session.phases[1])
    -- a private lobby : joinable by invitation only, never listed (so never announced). While
    -- nobody else is in it, it behaves like a solo start (see tryStartFromGrid)
    session.private = session.joinable and opts.private == true
    session.startOpts = editableOpts(opts)
    session.settingsRev = 0
    addParticipant(session, ctxt.senderID, ctxt.sender.playerName)
    M.sessions[session.id] = session

    print(string.format(
        "[BJ raceGrid] raceStart session=%s joinable=%s gridReadyTimeout=%s gridTimeout=%s (opts.gridReadyTimeout=%s opts.gridTimeout=%s)",
        session.id, tostring(session.joinable), tostring(session.settings.gridReadyTimeout),
        tostring(session.settings.gridTimeout), tostring(opts.gridReadyTimeout), tostring(opts.gridTimeout)))

    if session.joinable then
        -- no readyTimeout task scheduled here anymore: updateAllReadyState (tryStartFromGrid's own
        -- helper) now schedules it dynamically the moment everyone's actually ready, since the
        -- floor is anchored to that moment, not session creation - see its own doc comment
        utils_async.delayTask(function() onGridTimeout(session.id) end,
            session.settings.gridTimeout, "BJRaceGrid-" .. session.id .. "-gridTimeout")
    end

    pushSessionUpdate(session)
    pushOpenSessionsList()
    apiEvent("raceGridOpened", session)
    if session.joinable then
        -- the leader's crew comes along (services/crews.lua)
        services_crews.pullIn(ctxt.senderID, "race", session.id)
    end
    return session.id
end

--- the plugin API's race.open : a lobby a plugin opens (a scheduled event, a league night), with no
--- leader. Listed like any (with an entry list : not listed, its entrants invited), open while
--- empty until its time runs out (the options' gridTimeout). It starts like any lobby once
--- everyone's been ready a moment, or, `holdStart`, only when its time's up or the plugin says
--- (race.startNow)
---@param plugin string
---@param raceId integer
---@param opts table the start options, the start menu's
---@param host {name: string?, holdStart: boolean?, entrants: integer[]?}
---@return BJRaceSession? session, string? why not, integer[]? invited the entrants invited (connected, free)
local function pluginOpen(plugin, raceId, opts, host)
    local race = services_races.getById(raceId)
    if not race or race.mode ~= services_races.MODES.GRID then
        return nil, string.format("no grid race %s on this map", tostring(raceId))
    end
    if #race.startPositions < 2 then return nil, "the race needs 2 grid slots or more" end
    ---@type BJRaceSession
    local session = {
        id = UUID(),
        raceId = raceId,
        hostedBy = plugin,
        hostName = host.name or plugin,
        holdStart = host.holdStart == true or nil,
        joinable = true,
        baseSettings = buildSettings(race, opts),
        state = "GRID",
        createdAt = GetCurrentTime(),
        participants = Table(),
        phaseIndex = 1,
        phaseResults = {},
    }
    session.phases, session.result, session.format = services_racePhases.fromStart(race, opts)
    session.settings = services_racePhases.effectiveSettings(session.baseSettings, session.phases[1])
    if host.entrants then
        session.entrants = {}
        for _, id in ipairs(host.entrants) do session.entrants[id] = true end
        -- not listed : its entrants get an invite instead
        session.private = true
    end
    session.startOpts = editableOpts(opts)
    session.settingsRev = 0
    M.sessions[session.id] = session
    utils_async.delayTask(function() onGridTimeout(session.id) end,
        session.settings.gridTimeout, "BJRaceGrid-" .. session.id .. "-gridTimeout")
    LogInfo(string.format("[BJ raceGrid] %s opened race session %s (race %s, open %ds)", plugin, session.id,
        tostring(raceId), session.settings.gridTimeout))
    pushOpenSessionsList()
    apiEvent("raceGridOpened", session)
    local invited = {}
    if session.entrants and services_lobbyInvites then
        for id in pairs(session.entrants) do
            if services_lobbyInvites.hostInvite("race", session, id, session.hostName,
                    math.min(session.settings.gridTimeout, 300)) then
                invited[#invited + 1] = id
            end
        end
        table.sort(invited)
    end
    return session, nil, invited
end

--- the plugin API's race.close : the session ends now (a lobby, or an event under way), its racers
--- told, with the plugin's reason
---@param session BJRaceSession
---@param reason string?
local function pluginClose(session, reason)
    session.participants:forEach(function(p)
        local player = services_players.players:find(function(pl) return pl.playerID == p.playerID end)
        if not player then return end
        local text = reason and services_lang.get("race.cancelledByHostReason", player.lang)
            :var({ reason = (reason:gsub("%%", "%%%%")) }) or services_lang.get("race.cancelledByHost", player.lang)
        communications_tx.sendToPlayer(p.playerID, "toast", "info", text)
    end)
    removeSession(session)
end

--- the plugin API's race.startNow : a lobby starts now, as when its time runs out (whoever isn't
--- ready is left out ; nobody ready closes it)
---@param session BJRaceSession
---@return boolean ok, string? why not
local function pluginStartNow(session)
    if session.state ~= "GRID" then return false, "only while the lobby is open" end
    if session.placing then return false, "its grid is being placed" end
    onGridTimeout(session.id)
    return true
end

--- whether players may join this event now : its lobby, or (services/racePhases.lua's `lateJoin`)
--- while the phase allowing it runs, or in the break before one that does
---@param session BJRaceSession
---@return boolean lobby, boolean midway
joinableNow = function(session)
    if not session.joinable then return false, false end
    if session.state == "GRID" then return true, false end
    if session.state == "RACE" then return false, currentPhase(session).lateJoin == true end
    if session.state == "BREAK" then
        local next = session.phases[session.phaseIndex + 1]
        return false, next ~= nil and next.lateJoin == true
    end
    return false, false
end

--- players whose joining the plugins answering the raceJoin hook are being asked about :
--- playerID -> the session
---@type table<integer, string>
local pendingJoins = {}

--- tells a player a plugin refused their joining (the raceJoin hook)
---@param player table services_players player
---@param reason string?
local function tellJoinBlocked(player, reason)
    local text
    if reason and #reason > 0 then
        text = services_lang.get("race.joinBlocked", player.lang):var({ reason = (reason:gsub("%%", "%%%%")) })
    else
        text = services_lang.get("race.joinBlockedNoReason", player.lang)
    end
    communications_tx.sendToPlayer(player.playerID, "toast", "warning", text)
end

---@param ctxt BJSContext
---@param sessionId string
---@param asked boolean? the plugins answering the raceJoin hook let them in : everything else is
---checked again
local function raceJoin(ctxt, sessionId, asked)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session then return end
    local lobby, midway = joinableNow(session)
    if not lobby and not midway then return end
    -- the grid's being placed (the gridOrder hook) : about to start
    if session.placing then return end
    if session.participants[ctxt.senderID] then return end
    if session.entrants then
        -- a plugin's lobby with an entry list (race.open) : its entrants only
        if not session.entrants[ctxt.senderID] then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                services_lang.get("race.notEntrant", ctxt.sender.lang))
        end
    elseif session.private and not (services_lobbyInvites and
            services_lobbyInvites.isInvited("race", ctxt.senderID, session.id)) and
        not services_crews.sameCrew(ctxt.senderID, session.starterID) then
        -- private lobbies take invited players only
        return
    end
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

    -- plugins may refuse (the plugin API's raceJoin hook) : an entry list, licences. Asked first,
    -- then everything above is checked again (the lobby may have moved on or filled up meanwhile)
    if not asked and services_api and services_api.hasHook("raceJoin") then
        if pendingJoins[ctxt.senderID] then return end
        local okData, data = pcall(services_api.joinHookData, session, ctxt.sender, midway)
        if okData then
            pendingJoins[ctxt.senderID] = session.id
            local playerID, playerName = ctxt.senderID, ctxt.sender.playerName
            return services_api.runHook("raceJoin", data, function(answers)
                pendingJoins[playerID] = nil
                local again = InitContext(playerID)
                -- gone, or someone else under that ID now
                if not again.sender or again.sender.playerName ~= playerName then return end
                local block = services_api.firstBlock(answers)
                if block then return tellJoinBlocked(again.sender, block.reason) end
                raceJoin(again, sessionId, true)
            end)
        end
        LogError("[BJ raceGrid] the raceJoin hook's question failed : " .. tostring(data))
    end

    addParticipant(session, ctxt.senderID, ctxt.sender.playerName)
    if midway then
        -- they sit out until they're ready (raceReady), then start on their own
        local p = session.participants[ctxt.senderID]
        p.lateJoining, p.sittingOut = true, true
        pushSessionUpdate(session)
        return pushOpenSessionsList()
    end
    -- a fresh joiner always starts unready (addParticipant), so this only ever clears an
    -- already-set session.allReadyAt (and its scheduled start) - see its own doc comment
    updateAllReadyState(session)
    pushSessionUpdate(session)
    pushOpenSessionsList()
end

--- a racer who joined mid-event is ready : between phases, they're in the next one ; during one,
--- they start on their own now, from a free slot (the first, for a phase of personal starts). In a
--- race, their time counts from its green light like everyone's
---@param session BJRaceSession
---@param p BJRaceParticipant
local function lateJoinReady(session, p)
    p.ready, p.lateJoining = true, nil
    if session.state == "BREAK" then
        -- nextPhase decides (its `takes`)
        return pushSessionUpdate(session)
    end
    local race = getRace(session)
    if session.state ~= "RACE" or not race then return pushSessionUpdate(session) end
    local phase = currentPhase(session)
    resetForPhase(p)
    p.sittingOut = nil
    if phase.start == services_racePhases.START.SEQUENTIAL then
        -- one at a time : the back of the queue, on the first slot when it's their turn (now, when
        -- nobody's on track)
        local used = 0
        session.participants:forEach(function(o) if o.gridPosition and o ~= p then used = math.max(used, o.gridPosition) end end)
        p.gridPosition = used + 1
        p.startPosition = race.startPositions[1]
        p.awaitingStart = true
        apiEvent("racerJoinedPhase", session, p)
        if not releaseNextTurn(session) then pushSessionUpdate(session) end
        return
    end
    local position = race.startPositions[1]
    if phase.start == services_racePhases.START.GRID then
        -- the grid slot after the last one placed
        local used = 0
        session.participants:forEach(function(o) if o.gridPosition and o ~= p then used = math.max(used, o.gridPosition) end end)
        position = race.startPositions[(used % #race.startPositions) + 1]
        p.gridPosition = used + 1
    end
    p.startPosition = position
    personalStart(session, p, position, 1000, phase.ranking == services_racePhases.RANKING.POSITION)
    apiEvent("racerJoinedPhase", session, p)
    pushSessionUpdate(session)
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
    -- a plugin's lobby stays open, empty, until its time runs out
    if session.participants:length() == 0 and not (session.hostedBy and session.state == "GRID") then
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
    if session.starterID ~= ctxt.senderID then
        -- staff closing someone else's session : tell the players why it vanished
        session.participants:forEach(function(_, playerID)
            local player = services_players.players:find(function(p) return p.playerID == playerID end)
            communications_tx.sendToPlayer(playerID, "toast", "info",
                services_lang.get("race.cancelledByStaff", player and player.lang)
                :var({ name = ctxt.sender.playerName }))
        end)
    end
    removeSession(session)
end

--- the leader changes the race's settings while the lobby is still forming. Checked exactly like
--- a start (buildSettings), except the lobby's own timers, which were scheduled when it opened and
--- stay as they were. Everyone goes back to not ready : nobody stays ready for rules they didn't
--- see. settingsRev lets clients re-run their vehicle steering for a new restriction
---@param ctxt BJSContext
---@param sessionId string
---@param opts table
local function raceUpdateSettings(ctxt, sessionId, opts)
    if not ctxt.sender or type(opts) ~= "table" then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "GRID" or session.starterID ~= ctxt.senderID then return end
    local race = getRace(session)
    if not race then return end

    local previous = session.baseSettings
    local settings = buildSettings(race, opts)
    settings.gridTimeout = previous.gridTimeout
    settings.gridReadyTimeout = previous.gridReadyTimeout
    session.baseSettings = settings
    session.phases, session.result, session.format = services_racePhases.fromStart(race, opts)
    session.settings = services_racePhases.effectiveSettings(settings, session.phases[1])
    opts.gridTimeout = previous.gridTimeout
    opts.gridReadyTimeout = previous.gridReadyTimeout
    session.startOpts = editableOpts(opts)
    session.settingsRev = (session.settingsRev or 0) + 1

    -- "manual" placement keeps a slot per player : seed them in join order when switching to it,
    -- drop them when switching away
    if settings.placementMode ~= previous.placementMode then
        if settings.placementMode == services_races.PLACEMENT_MODES.MANUAL then
            local list = session.participants:values()
            table.sort(list, function(a, b) return a.joinIndex < b.joinIndex end)
            for i, p in ipairs(list) do p.gridSlot = i end
        else
            session.participants:forEach(function(p) p.gridSlot = nil end)
        end
    end

    -- new rules : a plugin's earlier refusal is moot too
    session.participants:forEach(function(p)
        p.ready, p.readyChecking = false, nil
        p.readyBlockReason, p.readyBlockBy = nil, nil
    end)
    updateAllReadyState(session)
    session.participants:forEach(function(_, playerID)
        if playerID ~= ctxt.senderID then
            local player = services_players.players:find(function(p) return p.playerID == playerID end)
            communications_tx.sendToPlayer(playerID, "toast", "info",
                services_lang.get("race.settingsChanged", player and player.lang))
        end
    end)
    pushSessionUpdate(session)
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
    if not session then return end
    local participant = session.participants[ctxt.senderID]
    if not participant then return end
    -- joined mid-event (raceJoin) : ready once, then in
    if participant.lateJoining and (session.state == "RACE" or session.state == "BREAK") then
        if ready ~= true or participant.readyChecking then return end
        if type(model) == "string" and model ~= "" then participant.vehicleModel = model end
        return requestReady(session, participant, lateJoinReady)
    end
    if session.state ~= "GRID" then return end
    -- the grid's being placed (the gridOrder hook) : it goes with who's ready now
    if session.placing then return end

    if ready ~= true then
        participant.ready = false
        -- an answer from the ready check still on its way is moot (requestReady)
        participant.readyChecking = nil
        -- manually un-readying doesn't call tryStartFromGrid (nothing to start), but still needs
        -- to clear session.allReadyAt/its scheduled start the same way un-readying via a vehicle
        -- change already does (unreadyOnVehicleChange) - see updateAllReadyState's own doc comment
        updateAllReadyState(session)
        return pushSessionUpdate(session)
    end
    if type(model) == "string" and model ~= "" then
        participant.vehicleModel = model
    end
    if participant.readyChecking then return end
    local function becameReady(s, p)
        p.ready = true
        tryStartFromGrid(s)
        if M.sessions[s.id] then -- session may have just been consumed by tryStartFromGrid
            pushSessionUpdate(s)
        end
    end
    if participant.ready then return becameReady(session, participant) end
    -- plugins may refuse (the plugin API's raceReady hook)
    requestReady(session, participant, becameReady)
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
    if not participant or not (participant.ready or participant.readyChecking) then return end
    participant.ready = false
    participant.readyChecking = nil
    -- clears session.allReadyAt (and the scheduled start it was driving) the instant this breaks
    -- the ready-floor - see updateAllReadyState's own doc comment
    updateAllReadyState(session)
    pushSessionUpdate(session)
end

--- metres past a gate's half-width a reported crossing may be from (BeamMP's positions lag a little
--- behind, more at speed)
local GATE_POSITION_MARGIN = 100
--- how far under the server's own measure a reported race time may be (the message's trip, the
--- clock sync's error)
local REPORT_LAG_MAX_MS = 5000

---@param ctxt BJSContext
---@param sessionId string
---@param gateIndex integer
---@param elapsedMs integer client-computed elapsed time since race start
local function raceGateCrossed(ctxt, sessionId, gateIndex, elapsedMs)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if session and session.state == "COUNTDOWN" and session.goAtMs and
        services_clockSync.nowMs() >= session.goAtMs - GO_GRACE_MS then
        M.beginRace(session.id)
    end
    if not session or session.state ~= "RACE" then return end
    local participant = session.participants[ctxt.senderID]
    if not participant or participant.finished or participant.dnf or participant.sittingOut then return end
    local race = getRace(session)
    if not race then return end

    local gate = race.gates[gateIndex]
    if not gate then return end

    -- Hardening : the crossing and its time come from the racer's own game. The server checks
    -- what it can see itself : the racer's car is near that gate (BeamMP's positions, with room
    -- for the lag at speed), and the time isn't well under what its own clock measured since the
    -- green light (a report can only arrive after the crossing)
    elapsedMs = tonumber(elapsedMs)
    if not elapsedMs or elapsedMs < 0 then return end
    local gateDistance = services_vehicles.distanceToPoint(ctxt.senderID, gate.pos)
    if gateDistance and gateDistance > (tonumber(gate.width) or 20) / 2 + GATE_POSITION_MARGIN then
        return LogWarn(string.format("raceGateCrossed : %s reported gate %d from %dm away, ignored",
            ctxt.sender.playerName, gateIndex, math.floor(gateDistance)))
    end
    -- not off yet (their turn, their next run, a plugin's start) : nothing to count
    if participant.awaitingStart then return end
    if participant.startAtMs and services_clockSync.nowMs() < participant.startAtMs - GO_GRACE_MS then return end
    local clockBase = participant.clockBaseMs or session.goAtMs
    if clockBase then
        local serverElapsedMs = services_clockSync.nowMs() - clockBase
        if elapsedMs < serverElapsedMs - REPORT_LAG_MAX_MS then
            LogWarn(string.format("raceGateCrossed : %s reported %dms, the server measured %dms",
                ctxt.sender.playerName, elapsedMs, serverElapsedMs))
            elapsedMs = serverElapsedMs - REPORT_LAG_MAX_MS
        end
    end

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
        --
        -- Real, confirmed bug fixed here as well (direct report, Italy's Heads-Up Quarry Slam :
        -- through the first two checkpoints, then back over the start/finish line, and a new lap
        -- began, the whole course skipped). Only refusing an immediate re-crossing still let the
        -- line close a lap from ANY point of it. It closes one only from the end of a branch now
        -- (isBranchEnd : the last gate before the line, on whichever branch, short or long), or from
        -- a gate the author linked to it as a parent (the normal check below).
        local isLoopClosing = race.loopable and gate.step == 1 and isBranchEnd(race, participant.lastCrossedGate)
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
    -- a flying start (a point-to-point track) : their time (this run's) starts here, at the first
    -- checkpoint, instead of at their release
    local flyingFrom = session.settings.flyingStart == true and not race.loopable and participant.currentGate == 0

    participant.currentGate = gate.step
    participant.lastCrossedGate = gateIndex
    participant.gateTimes[gate.step] = elapsedMs
    participant.lastProgressTime = ctxt.time

    -- lapTimes stores each lap's own duration, not cumulative race time: elapsedMs is
    -- cumulative since race start, so subtract off everything already elapsed as of the
    -- previous lap boundary. Computed once here (not just at the final gate) since the live
    -- delta below needs this same lap-relative baseline at every gate, not only lap ends.
    -- (a personal start's clock starts at 0 : the laps before it don't count here)
    local previousLapsElapsed = -(participant.elapsedOffsetMs or 0)
    table.forEach(participant.lapTimes, function(t) previousLapsElapsed = previousLapsElapsed + t end)
    if flyingFrom then
        -- the run up to the line doesn't count : the lap (run) is timed from now
        participant.elapsedOffsetMs = (participant.elapsedOffsetMs or 0) - (elapsedMs - previousLapsElapsed)
        previousLapsElapsed = elapsedMs
    end
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

    -- an out lap (a circuit, direct request) : the lap from the grid isn't one, nor its sectors.
    -- Their time starts as they cross the line at its end, as a flying start's at its line
    if participant.outLapPending then
        participant.liveDeltaMs = nil
        if lapComplete then
            participant.outLapPending = nil
            participant.elapsedOffsetMs = (participant.elapsedOffsetMs or 0) - lapRelativeNow
            -- the line crossed : the next time over it closes their first lap
            participant.gateTimes = { [gate.step] = elapsedMs }
            participant.currentSector, participant.sectorStartMs, participant.lapSectors = 1, 0, {}
        end
        apiEvent("racerGate", session, participant, { gate = gateIndex, step = gate.step,
            lap = participant.currentLap, outLap = true, lapComplete = lapComplete })
        return pushSessionUpdate(session, true)
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
    local sectorGates = sectorEndGates(race, session.settings.flyingStart)
    local sectorCount = #sectorGates
    local sectorBefore = participant.currentSector
    while participant.currentSector < sectorCount and
        gateIndex == sectorGates[participant.currentSector] do
        completeCurrentSector(participant, lapRelativeNow)
    end
    if participant.currentSector >= sectorCount and lapComplete then
        completeCurrentSector(participant, lapRelativeNow)
    end
    -- what this crossing was, for the plugin API's RacerGate (sent once the lap's dealt with)
    local crossing = { gate = gateIndex, step = gate.step, lap = participant.currentLap, lapMs = lapRelativeNow,
        deltaMs = participant.liveDeltaMs, lapComplete = lapComplete, sectors = {} }
    for s = sectorBefore, participant.currentSector - 1 do
        crossing.sectors[#crossing.sectors + 1] = { sector = s, ms = participant.lapSectors[s] }
    end

    if lapComplete then
        table.insert(participant.lapTimes, lapRelativeNow)

        if not participant.bestLapMs or lapRelativeNow < participant.bestLapMs then
            participant.bestLapMs = lapRelativeNow
            participant.bestLapAtMs = services_clockSync.nowMs()
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
        apiEvent("racerLap", session, participant)

        if lapEndsPhase(session, participant) then
            finishParticipant(session, participant)
        else
            -- currentGate deliberately not reset here, see its own doc comment above. The
            -- `expected` calc at the top of this function already wraps 1..#race.gates via plain
            -- modulo regardless of whether currentGate sits at 0 or at its last real value
            participant.currentLap = participant.currentLap + 1
            -- a point-to-point track's runs : back to the first slot for the next one ; a plugin's
            -- phase : held there until it starts them again
            if services_racePhases.runs(currentPhase(session), race) then
                personalStart(session, participant, race.startPositions[1], RUN_ROLL_MS)
            elseif not race.loopable and currentPhase(session).start == services_racePhases.START.PLUGIN then
                participant.awaitingStart = true
                participant.currentGate, participant.lastCrossedGate, participant.gateTimes = 0, 0, {}
                participant.currentSector, participant.sectorStartMs, participant.lapSectors = 1, 0, {}
                participant.elapsedOffsetMs = services_racePhases.timeOf(participant) - (participant.penaltyMs or 0)
            end
        end
    end

    apiEvent("racerGate", session, participant, crossing)
    -- slim : gate crossings are by far the most frequent pushes (see buildSessionPayload)
    pushSessionUpdate(session, true)
end

---@param ctxt BJSContext
---@param sessionId string
local function raceDNF(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "RACE" then return end
    local participant = session.participants[ctxt.senderID]
    if not participant or participant.finished or participant.dnf or participant.sittingOut then return end

    participant.dnf = true
    if participant.bestLapMs then
        trySubmitTime(session, participant, participant.bestLapMs)
    end
    apiEvent("racerOut", session, participant, "retired")
    checkSessionComplete(session)
    -- checkSessionComplete already pushes (and transitions to FINISHED) if this was the last
    -- still-active participant, same as finishParticipant's own identical pattern just below it.
    -- This used to push again unconditionally regardless, which is at best redundant (harmless
    -- duplicate) but at worst can double-fire the client's own flip-detection logic (onSessionUpdate
    -- diffs old vs new state per call) right at the exact moment it matters most. Only pushing here
    -- when the session isn't complete yet keeps this consistent with finishParticipant's pattern.
    if session.state == "RACE" then
        pushSessionUpdate(session)
    end
end

local STAFF_PENALTY_MAX_SEC = 600
local STAFF_PENALTY_TOTAL_MAX_MS = 3600 * 1000

--- a penalty in seconds for messages : whole seconds as "5", tenths as "0.5" / "10.5"
---@param ms integer
---@return string
local function penaltySecondsText(ms)
    local tenths = math.floor(ms / 100 + 0.5)
    if tenths % 10 == 0 then return tostring(math.floor(tenths / 10)) end
    return string.format("%.1f", tenths / 10)
end

--- race control for staff watching a race (raceSpectate) : a time penalty on a racer, clearing
--- their penalties, disqualifying them, or reinstating them. Only while the race is running, so
--- the results (and the Discord post, at the end) are final once everyone's done.
--- A penalty is added to the racer's race time once they finish : the finishing order is by race
--- time plus penalties. A disqualified racer still racing is stopped (out, like retiring) ; one
--- who already finished keeps their laps but drops to the bottom, and their leaderboard time is
--- withdrawn. Reinstating clears the disqualification and gives a finisher their leaderboard time
--- back ; a racer stopped by it stays out.
---@param ctxt BJSContext
---@param sessionId string
---@param targetID integer the racer's playerID
---@param action "penalty"|"clearPenalties"|"disqualify"|"reinstate"
---@param seconds number? "penalty" : 0.1 to STAFF_PENALTY_MAX_SEC, to the tenth (the half-second button)
--- race control for staff (watching the race, or in it) : the phase under way ends now, or gets 5
--- more minutes (a timed one) or one more lap or run (one on laps)
---@param ctxt BJSContext
---@param sessionId string
---@param action "endPhase"|"extendPhase"|"extendLaps"
local function raceStaffPhase(ctxt, sessionId, action)
    if not ctxt.sender or not services_permissions.isStaff(ctxt.sender.playerName) then return end
    local session = M.sessions[sessionId]
    if not session then return end
    if M.spectators[ctxt.senderID] ~= sessionId and not session.participants[ctxt.senderID] then return end
    local ok
    if action == "endPhase" then ok = pluginEndPhase(session)
    elseif action == "extendPhase" then ok = pluginExtendPhase(session, 5)
    elseif action == "extendLaps" then ok = pluginExtendLaps(session, 1) end
    if ok then
        LogInfo(string.format("raceGrid: %s : %s (session %s)", ctxt.sender.playerName, action, session.id))
    end
end

--- race control's actions on a racer while the phase runs, from staff (raceStaffAction) or a
--- plugin (pluginControlRacer) : a time penalty (time taken off with a negative, never under
--- none), clearing their penalties, disqualifying them, or reinstating them. The plugin API's
--- RaceControl tells plugins
---@param session BJRaceSession
---@param p BJRaceParticipant
---@param action "penalty"|"clearPenalties"|"disqualify"|"reinstate"
---@param ms integer? "penalty" : the time added (taken off, negative)
---@param by string "staff:<name>" or "plugin:<name>"
---@param reason string?
---@return integer? change nil : nothing changed ; else the penalty time added (taken off, negative ; 0
---for a disqualification or a reinstatement)
local function controlRacer(session, p, action, ms, by, reason)
    local change
    if action == "penalty" then
        if p.disqualified or not ms or ms == 0 then return nil end
        local before = p.penaltyMs or 0
        p.penaltyMs = math.clamp(before + ms, 0, STAFF_PENALTY_TOTAL_MAX_MS)
        change = p.penaltyMs - before
        if change == 0 then return nil end
    elseif action == "clearPenalties" then
        if (p.penaltyMs or 0) == 0 then return nil end
        change = -p.penaltyMs
        p.penaltyMs = 0
    elseif action == "disqualify" then
        if p.disqualified then return nil end
        p.disqualified = true
        if not p.finished and not p.dnf then
            p.dnf = true
        elseif p.leaderboardKey then
            services_races.restoreEntry(session.raceId, p.leaderboardKey, p.replacedEntry)
            p.isNewPB, p.isNewRecord = false, false
            p.leaderboardKey, p.replacedEntry = nil, nil
            if p.discordResult then p.discordResult.counted = false end
        end
        change = 0
        apiEvent("racerOut", session, p, "disqualified")
    elseif action == "reinstate" then
        if not p.disqualified then return nil end
        p.disqualified = false
        if p.finished and p.bestLapMs then
            trySubmitTime(session, p, p.bestLapMs)
        end
        change = 0
    else
        return nil
    end
    apiEvent("raceControl", session, p, action, change, by, reason)
    -- a disqualification can be what ends the race (the last one still racing)
    checkSessionComplete(session)
    if session.state == "RACE" then
        pushSessionUpdate(session)
    end
    return change
end

local function raceStaffAction(ctxt, sessionId, targetID, action, seconds)
    if not ctxt.sender or not services_permissions.isStaff(ctxt.sender.playerName) then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "RACE" or M.spectators[ctxt.senderID] ~= sessionId then return end
    local p = session.participants[tonumber(targetID) or -1]
    if not p then return end

    local ms
    if action == "penalty" then
        -- tenths of a second : the half-second penalty, and nothing finer than the race clock shows
        ms = math.floor((tonumber(seconds) or 0) * 10 + 0.5) * 100
        if ms < 100 or ms > STAFF_PENALTY_MAX_SEC * 1000 then return end
    end
    local staffName = ctxt.sender.playerName
    local target = services_players.players:find(function(pl) return pl.playerID == p.playerID end)
    local targetName = resolveDisplayName(p.playerID, p.playerName)
    if not controlRacer(session, p, action, ms, "staff:" .. staffName) then return end

    local function tell(key, vars)
        communications_tx.sendToPlayer(p.playerID, "toast", "warning",
            services_lang.get(key, target and target.lang):var(vars or {}))
    end
    if action == "penalty" then
        tell("race.staff.penalty", { seconds = penaltySecondsText(ms), total = penaltySecondsText(p.penaltyMs), name = staffName })
        LogInfo(string.format("raceGrid: %s gave %s a %ss penalty (session %s)", staffName, targetName,
            penaltySecondsText(ms), session.id))
    elseif action == "clearPenalties" then
        tell("race.staff.penaltiesCleared", { name = staffName })
        LogInfo(string.format("raceGrid: %s cleared %s's penalties (session %s)", staffName, targetName, session.id))
    elseif action == "disqualify" then
        tell("race.staff.disqualified", { name = staffName })
        LogInfo(string.format("raceGrid: %s disqualified %s (session %s)", staffName, targetName, session.id))
    elseif action == "reinstate" then
        tell("race.staff.reinstated", { name = staffName })
        LogInfo(string.format("raceGrid: %s reinstated %s (session %s)", staffName, targetName, session.id))
    end
end

--- the plugin API's race control (race.penalize / race.clearPenalties / race.disqualify /
--- race.reinstate) : as staff's, the racer told by "race control", with the plugin's reason
---@param session BJRaceSession
---@param playerID integer
---@param action "penalty"|"clearPenalties"|"disqualify"|"reinstate"
---@param ms integer? "penalty"
---@param plugin string
---@param reason string?
---@return boolean ok, string? why not, BJRaceParticipant? p, integer? change
local function pluginControlRacer(session, playerID, action, ms, plugin, reason)
    if session.state ~= "RACE" then return false, "no phase is running" end
    local p = session.participants[playerID]
    if not p then return false, "that player isn't in this race" end
    if p.sittingOut then return false, "that racer isn't in this phase" end
    local target = services_players.players:find(function(pl) return pl.playerID == p.playerID end)
    local change = controlRacer(session, p, action, ms, "plugin:" .. plugin, reason)
    if not change then
        if action == "penalty" and p.disqualified then return false, "that racer is disqualified" end
        return false, "nothing to change"
    end
    if target then
        local key = ({ penalty = change > 0 and "race.control.penalty" or "race.control.penaltyOff",
            clearPenalties = "race.control.penaltiesCleared", disqualify = "race.control.disqualified",
            reinstate = "race.control.reinstated" })[action]
        local text = services_lang.get(key, target.lang):var({ seconds = penaltySecondsText(math.abs(change)),
            total = penaltySecondsText(p.penaltyMs or 0) })
        if reason and #reason > 0 then text = text .. " : " .. reason end
        communications_tx.sendToPlayer(p.playerID, "toast", "warning", text)
    end
    LogInfo(string.format("raceGrid: %s : %s on %s%s (session %s)", plugin, action,
        resolveDisplayName(p.playerID, p.playerName), change ~= 0 and string.format(" %+dms", change) or "", session.id))
    return true, nil, p, change
end

-- one reset, however many times the client reports it (a held key, the reset settling)
local RESET_DEBOUNCE_MS = 1500

--- a racer reset during a phase, reported by their own game (raceRunner.lua's applyResetPenalty,
--- every reset since client build 2759 ; before, only for the time penalty : "raceResetPenalty",
--- counted the same). The plugin API's RacerReset ; and in a race whose reset penalty adds time,
--- resetPenaltySeconds go on their race time, with any staff penalties (the same red box, the same
--- finishing order). The "hold" penalty is enforced by their game
---@param ctxt BJSContext
---@param sessionId string
local function raceReset(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "RACE" then return end
    local p = session.participants[ctxt.senderID]
    if not p or p.finished or p.dnf or p.disqualified or p.sittingOut or p.awaitingStart then return end
    local now = services_clockSync.nowMs()
    if p.lastResetMs and now - p.lastResetMs < RESET_DEBOUNCE_MS then return end
    p.lastResetMs = now
    local s = session.settings
    local addedMs
    if s.resetPenaltyEnabled and s.resetPenaltyMode == "time" and s.respawnStrategy ~= "norespawn" then
        local before = p.penaltyMs or 0
        p.penaltyMs = math.min(STAFF_PENALTY_TOTAL_MAX_MS,
            before + math.floor((tonumber(s.resetPenaltySeconds) or 5) * 1000))
        addedMs = p.penaltyMs - before
    end
    apiEvent("racerReset", session, p, addedMs)
    if addedMs and addedMs > 0 then pushSessionUpdate(session, true) end
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
    communications_rx.addHandler("raceRejoin", M.raceRejoin)
    communications_rx.addHandler("raceCancel", M.raceCancel)
    communications_rx.addHandler("raceReady", M.raceReady)
    communications_rx.addHandler("raceSetGridSlot", M.raceSetGridSlot)
    communications_rx.addHandler("raceGateCrossed", M.raceGateCrossed)
    communications_rx.addHandler("raceDNF", M.raceDNF)
    communications_rx.addHandler("raceSpectate", M.raceSpectate)
    communications_rx.addHandler("raceStopSpectate", M.raceStopSpectate)
    communications_rx.addHandler("raceStartNow", M.raceStartNow)
    communications_rx.addHandler("raceUpdateSettings", M.raceUpdateSettings)
    communications_rx.addHandler("raceStaffAction", M.raceStaffAction)
    communications_rx.addHandler("raceStaffPhase", M.raceStaffPhase)
    communications_rx.addHandler("raceReset", M.raceReset)
    -- games before client build 2759
    communications_rx.addHandler("raceResetPenalty", M.raceReset)

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
            if session.state == "RACE" then
                pushSessionUpdate(session)
            end
            print("[BJ raceGrid] racedebugcomplete: DebugGhost DNF'd, session.state=" .. session.state)
        end)
end

---@param playerID integer
--- inlined rather than routed through raceLeave/raceDNF: those need ctxt.sender resolved via
--- services_players.players, which other extensions' own onPlayerDisconnect handlers may have
--- already cleared by the time this one runs (extensions.hook has no ordering guarantee)
---@param sessionId string
---@param playerName string
---@return string
function rejoinTaskKey(sessionId, playerName)
    return "BJRaceGrid-" .. sessionId .. "-rejoin-" .. playerName
end

--- an event under way : a racer who disconnects keeps their place for a while
local RUNNING = { COUNTDOWN = true, RACE = true, BREAK = true }

--- a disconnected racer's grace period ran out : retired, as a disconnect used to do at once
---@param sessionId string
---@param playerName string
local function expireRejoin(sessionId, playerName)
    local session = M.sessions[sessionId]
    if not session or not RUNNING[session.state] then return end
    local participant = session.participants:find(function(p)
        return p.disconnected and p.playerName == playerName
    end)
    if not participant then return end
    participant.disconnected, participant.rejoinBy, participant.rejoinSecondsLeft = nil, nil, nil
    -- out of the event : the phases still to come go on without them
    participant.eventOut = true
    if session.state == "COUNTDOWN" then participant.sittingOut = true end
    if session.state ~= "RACE" or participant.finished or participant.dnf or participant.sittingOut then
        return pushSessionUpdate(session)
    end
    participant.dnf = true
    if participant.bestLapMs then
        trySubmitTime(session, participant, participant.bestLapMs)
    end
    apiEvent("racerOut", session, participant, "disconnected")
    checkSessionComplete(session)
    if session.state == "RACE" then
        pushSessionUpdate(session)
    end
end

--- is this player the racer who left as `p` ? Same BeamMP name, or, for a guest (BeamMP hands out
--- a new random guest name whenever the launcher restarts), the same BeamJoy nickname. Nicknames
--- aren't password-protected : someone typing a disconnected guest's nickname could take their
--- place, the same trust the leaderboard already gives nicknames
---@param p BJRaceParticipant
---@param sender table services_players player
local function isReturningRacer(p, sender)
    if p.playerName == sender.playerName then return true end
    return p.guest == true and sender.guest == true and p.nickname ~= nil and
        sender.identityNickname == p.nickname
end

--- a player whose BeamJoy just finished loading, or who just picked their nickname : if they
--- dropped out of a race still running and are inside its grace period, they're put back in under
--- their current player ID. Their client then picks the race back up (raceRunner.lua's resume
--- path) from the last gate they crossed.
---@param ctxt BJSContext
local function raceRejoin(ctxt)
    if not ctxt.sender then return end
    M.sessions:forEach(function(session)
        if not RUNNING[session.state] or session.participants[ctxt.senderID] then return end
        local awayKey, participant
        for key, p in pairs(session.participants) do
            if p.disconnected and isReturningRacer(p, ctxt.sender) then
                awayKey, participant = key, p
                break
            end
        end
        if not participant then return end
        utils_async.removeTask(rejoinTaskKey(session.id, participant.playerName))
        session.participants[awayKey] = nil
        local oldName = participant.playerName
        participant.playerID = ctxt.senderID
        participant.playerName = ctxt.sender.playerName
        participant.disconnected, participant.rejoinBy, participant.rejoinSecondsLeft = nil, nil, nil
        participant.lastProgressTime = GetCurrentTime()
        session.participants[ctxt.senderID] = participant
        if session.starterID == awayKey then session.starterID = ctxt.senderID end
        LogInfo(string.format("[BJ races] %s rejoined race session %s%s", ctxt.sender.playerName,
            session.id, oldName ~= ctxt.sender.playerName and (" (left as " .. oldName .. ")") or ""))
        pushSessionUpdate(session)
    end)
end

--- a guest who came back on a new guest name is only recognisable once they pick their nickname
---@param ctxt BJSContext
local function onBJIdentityChanged(ctxt)
    -- a racer who changed their nickname : remembered right away, in case they disconnect next
    M.sessions:forEach(function(session)
        local p = session.participants[ctxt.senderID]
        if p then snapshotIdentity(p) end
    end)
    raceRejoin(ctxt)
end

local function onPlayerDisconnect(playerID)
    M.spectators[playerID] = nil
    pendingJoins[playerID] = nil
    M.sessions:forEach(function(session)
        if not session.participants[playerID] then return end

        if session.state == "GRID" then
            session.participants[playerID] = nil
            if session.participants:length() == 0 and not session.hostedBy then
                return removeSession(session)
            end
            if playerID == session.starterID then
                session.starterID = session.participants:keys()[1]
            end
            tryStartFromGrid(session)
            pushSessionUpdate(session)
            pushOpenSessionsList()
        elseif RUNNING[session.state] then
            local participant = session.participants[playerID]
            -- one at a time : everyone else waits on the one on track, so their turn ends here (the
            -- laps they completed kept) and the next goes, rather than holding the phase for their
            -- grace period
            if session.state == "RACE" and isSequential(session) and onTurn(participant) then
                if #participant.lapTimes > 0 then
                    finishParticipant(session, participant, true)
                else
                    participant.dnf = true
                    apiEvent("racerOut", session, participant, "disconnected")
                end
                checkSessionComplete(session)
            end
            local done = participant.finished or participant.dnf or participant.sittingOut
            -- done, and nothing after : their result stands as it is
            if done and session.phaseIndex >= #session.phases then return end
            -- a crash, a launcher hiccup or a short drop shouldn't throw away hours of an
            -- endurance race : the racer keeps their place for a while, the race clock running on
            -- for them (time lost away is the penalty), and gets back in where they were
            local graceSec = (session.settings.rejoinGraceMinutes or 0) * 60
            if graceSec > 0 then
                snapshotIdentity(participant)
                local awayKey = nextAwayKey()
                session.participants[playerID] = nil
                session.participants[awayKey] = participant
                participant.playerID = awayKey
                if session.starterID == playerID then session.starterID = awayKey end
                participant.disconnected = true
                participant.rejoinBy = GetCurrentTime() + graceSec
                participant.rejoinSecondsLeft = graceSec
                local sessionId, playerName = session.id, participant.playerName
                utils_async.delayTask(function() M.expireRejoin(sessionId, playerName) end, graceSec,
                    rejoinTaskKey(sessionId, playerName))
                return pushSessionUpdate(session)
            end
            -- no grace period : out of the event
            participant.eventOut = true
            if session.state == "COUNTDOWN" then participant.sittingOut = true end
            if session.state ~= "RACE" or done or participant.sittingOut then
                return pushSessionUpdate(session)
            end
            participant.dnf = true
            if participant.bestLapMs then
                trySubmitTime(session, participant, participant.bestLapMs)
            end
            apiEvent("racerOut", session, participant, "disconnected")
            checkSessionComplete(session)
            -- same redundant-double-push cleanup already applied to raceDNF/raceLeave. Only push
            -- again here if checkSessionComplete didn't already do so itself (it pushes once, on
            -- its own, exactly when this disconnect happens to be the one that completes the
            -- session)
            if session.state == "RACE" then
                pushSessionUpdate(session)
            end
        end
    end)
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onPlayerDisconnect = onPlayerDisconnect
M.raceRejoin = raceRejoin
M.onBJIdentityChanged = onBJIdentityChanged
M.expireRejoin = expireRejoin

M.raceStart = raceStart
M.raceJoin = raceJoin
M.raceLeave = raceLeave
M.raceCancel = raceCancel
M.raceUpdateSettings = raceUpdateSettings
M.raceReady = raceReady
M.raceSetGridSlot = raceSetGridSlot
M.unreadyOnVehicleChange = unreadyOnVehicleChange
M.raceGateCrossed = raceGateCrossed
M.raceDNF = raceDNF
M.raceSpectate = raceSpectate
M.raceStopSpectate = raceStopSpectate
M.raceStaffAction = raceStaffAction
M.raceReset = raceReset
M.raceStartNow = raceStartNow
M.findSessionByParticipant = findSessionByParticipant
M.summarize = summarize
M.beginRace = beginRace
M.computeLeaderboard = computeLeaderboard
M.racerInfo = racerInfo
M.pluginUnready = pluginUnready
M.pluginSetGridOrder = pluginSetGridOrder
M.pluginSetFields = pluginSetFields
M.pluginSetPhases = pluginSetPhases
M.pluginEndPhase = pluginEndPhase
M.pluginExtendPhase = pluginExtendPhase
M.pluginExtendLaps = pluginExtendLaps
M.pluginNextPhase = pluginNextPhase
M.pluginStartRacer = pluginStartRacer
M.pluginStopRacer = pluginStopRacer
M.pluginSetScores = pluginSetScores
M.participantByKey = participantByKey
M.pluginControlRacer = pluginControlRacer
M.pluginOpen = pluginOpen
M.pluginClose = pluginClose
M.pluginStartNow = pluginStartNow
--- a session's players for a message (the plugin API's hud.message) : its racers, its spectators,
--- or both
---@param session BJRaceSession
---@param which "racers"|"spectators"|"all"
---@return integer[]
M.audienceOf = function(session, which)
    local list = {}
    if which ~= "spectators" then
        session.participants:forEach(function(p) if p.playerID >= 0 then list[#list + 1] = p.playerID end end)
    end
    if which ~= "racers" then
        M.spectators:forEach(function(sessionId, playerID)
            if sessionId == session.id then list[#list + 1] = playerID end
        end)
    end
    table.sort(list)
    return list
end
M.raceStaffPhase = raceStaffPhase
M.provisionalResults = function(session) return select(2, buildResults(session)) end
M.chatRace = chatRace

return M
