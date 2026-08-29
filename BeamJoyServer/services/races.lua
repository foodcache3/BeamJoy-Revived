---@alias BJRaceMode "grid"|"passive"
---@alias BJRaceRespawnStrategy "all"|"norespawn"|"lastcheckpoint"
---@alias BJRacePlacementMode "deterministic"|"random"|"manual"

---@class BJRaceGate
---@field pos {x: number, y: number, z: number}
---@field dir {x: number, y: number, z: number}
---@field width number
---@field height number
---@field sector true? marks this gate as a sector boundary when the owning race's own
---`manualSectors` is enabled; ignored entirely otherwise (see BJRace.manualSectors below)
---@field step integer read-only/derived: never trust a client-submitted value for this field.
---The gate's ordinal position in the route, 1-based ; several gates may share the same step
---(parallel branch alternates: only one is ever actually crossed on a given run). While
---`branchingEnabled` is on, this is DERIVED from the `parents` graph (see deriveStepsFromParents :
---`1 + the highest step among this gate's own real parents`, or 1 if its only parent is "start").
---Not independently client-authored, specifically because a branch alternate created later than
---its siblings has no way to guess the right step on its own, and requiring an author to manually
---keep it in sync with `parents` by hand is exactly the class of bug a real live report hit ("when
---I went through 3, it said 6": gate 3 was simply the 6th gate ever created, never manually
---re-numbered once wired up as gate 2's alternate). `sanitizeRace` force-normalizes this to the
---gate's own array position whenever `branchingEnabled` is off, so a non-branching race's `step` is
---always identical to its array index and every existing step/index-based system (leaderboard
---tie-break, gateTimes indexing, live delta, backmarker progress) keeps working completely
---unmodified. Mirrors BeamJoy Free's own `steps[][]` shape (parallel waypoint options per ordinal
---step) rather than a free-form graph, chosen specifically so this stays compatible with a future
---BJI race importer, and so branch alternates stay directly comparable by a plain progress number
---instead of needing a fallback metric
---@field parents integer[]? only meaningful/editable while `branchingEnabled` is on ; which
---gate(s) this one may be validly crossed AFTER: an entry of `0` means "reachable directly from
---the start/grid" (never a real gate index, so it can't collide with one). `sanitizeRace`
---force-normalizes this to `{index - 1}` (i.e. "only reachable from the previous gate") whenever
---`branchingEnabled` is off, exactly reproducing the old implicit linear-only behavior
---@field isFinish true? only meaningful/editable while `branchingEnabled` is on, and only for a
---non-loopable race (a loopable race's finish is always "re-crossing the step-1 gate", regardless
---of this flag; see raceGrid.lua's own lapComplete check) ; marks this gate as a valid finish
---line. `sanitizeRace` force-sets this to true on the race's own last gate whenever `branchingEnabled`
---is off (reproducing "the last gate is the finish" exactly), and also force-flags the last gate
---when branching IS on but no gate was actually flagged, so a race can never end up with no real
---finish at all

---@class BJRaceDefaults host-configurable at race-start time, see the plan's
---"Host-configurable race-start options" section: these are just the per-race baseline,
---overridable per start by whoever starts the race (grid/joinable/admin-forced alike)
---@field laps integer?
---@field respawnStrategy BJRaceRespawnStrategy
---@field placementMode BJRacePlacementMode? how grid slots are assigned at countdown time (see
---M.PLACEMENT_MODES / raceGrid.lua's beginCountdown) ; default "random"
---@field joinable boolean default state of the "let others join" flag for the `grid` mode
---@field gridTimeout integer seconds
---@field gridReadyTimeout integer seconds
---@field countdown integer seconds
---@field dnfEnabled boolean? stall-based DNF under "norespawn" ; default true
---@field dnfTimeout integer? seconds of no progress before a DNF triggers
---@field resetPenaltyEnabled boolean? matching Hunter's own crash-reset penalty: freezes a
---participant's vehicle for resetPenaltySeconds each time they reset/recover during an active
---attempt. Default false, unlike dnfEnabled, since this is a new opt-in deterrent, not a
---previously-hardcoded-on behavior being formalized. Purely client-enforced (raceRunner.lua).
---Moot under "norespawn" (resets already fully blocked there).
---@field resetPenaltySeconds integer? seconds frozen per reset when resetPenaltyEnabled is on.
---Default 5.
---@field autoSpectateOnFinish boolean? auto-switch a finisher to spectating another still-active
---participant (matches the always-on DNF behavior) rather than leaving them free to keep driving
---their own car after their own attempt is over ; default true
---@field disableNodegrabber boolean? blocks BeamNG's node-grabber tool for active participants ;
---default true
---@field disableCameras boolean? "Disable Free Cam": blocks the Free, Cinematic, and Steadycam
---global cameras for the duration of a participant's attempt, in addition to the always-blocked
---Big Map. Covers both leaving the vehicle behind entirely via Free Cam, and the loophole where
---node-grabbing (or any other way onto those cameras) could otherwise strand a player on Cinematic/
---Steadycam with no way back to the vehicle ring ; default true
---@field disableGravityChange boolean? re-asserts the expected gravity (server-synced value if
---set, else real-world) every frame for an active participant during COUNTDOWN/RACE. Gravity has
---no native BeamNG keybind to block outright (unlike every other anticheat option here), so this
---actively corrects a console/script-driven change instead of preventing the input itself ; default
---true
---@field ghostOnCountdown boolean? ghosts every participant's vehicle for the COUNTDOWN grid phase
---so simultaneous grid spawns/teleports can't land vehicles on top of each other, independent of
---the server-wide Freeroam.CollisionsMode setting. For a MULTIPLAYER attempt the ghost lifts the
---moment RACE actually begins, so racers collide with each other normally ; for a SOLO attempt
---(client-side decided, by participant count) it deliberately stays on for the whole race instead
---BeamNG's ghosting has no concept of "collide with these vehicles but not those", so a solo
---run either ghosts against everything (traffic/bystanders included, nobody else is actually
---racing to preserve collision with) or nothing at all ; matches BJI's own precedent of only ever
---permanently ghosting a solo scenario, never a multiplayer one ; default true
---@field disableCollisions boolean? opt-in, unlike ghostOnCountdown above : ghosts every
---participant for the WHOLE race (COUNTDOWN through the entire RACE, not just the grid phase),
---regardless of solo/multiplayer participant count, for a host who wants a genuinely
---collision-free multiplayer race throughout, not just a pileup-safe start. Independent reason
---from ghostOnCountdown's own "race" ghost reason (see vehicles.lua's M.ghostReasons), so it never
---interferes with ghostOnCountdown's own solo-only full-race behavior or its multiplayer
---RACE-transition un-ghost ; default false
---@field ghostBackmarkers boolean? opt-in : once the race leader has gained a full lap of real
---gate-progress on a given participant (genuinely lapped them, not just a raw lap-NUMBER
---difference; see raceGrid.lua's buildSettings for why that distinction matters), that
---participant's own client ghosts their vehicle for as long as they stay lapped. Same BeamNG
---limitation as every other ghost option here : there's no selective "ghost against the leader
---only": a ghosted backmarker is ghosted against everyone, including other backmarkers ; default
---false
---@field showGateNametags boolean? whether the floating "Gate N (Start/Finish)" text label renders
---above each gate while actually racing (COUNTDOWN/RACE; the lobby/GRID phase always shows every
---label regardless of this setting). The gate quad/arrow themselves are unaffected, this only
---toggles the text. The race editor's own authoring view always shows labels regardless of this
---setting too, since they're needed while building the track ; default false
---@field limitVisibleGates boolean? when true, only the next `visibleGateCount` upcoming gates
---(relative to each participant's own next gate) render at all once COUNTDOWN/RACE begins: every
---other gate, past or further-future, is hidden entirely. Purely a rendering declutter for long/
---dense tracks ; the lobby/GRID phase always shows every gate regardless, so players can still see
---the whole layout before committing to start ; default true
---@field visibleGateCount integer? how many upcoming gates stay visible when limitVisibleGates is
---on, [1,5] ; default 2
---@field allowTuning boolean? only meaningful while a vehicle restriction is actually active
---("single"/"pool"/"raceDefined" resolving to either; meaningless for "free", which has nothing
---to restrict tuning against in the first place). When true (default), a participant may freely
---adjust their tuning variables (tire pressure, gearing, ARB, diff, ...) after being placed into
---the required/pool vehicle: vehicleMatchesRestriction only ever compares the parts tree, never
---vars, so this is the current always-on behavior. When false, the captured/pool entry's own vars
---snapshot is ALSO compared, same treatment as parts: a genuine "spec car, spec tune" mode. Paint
---is never gated by this (still always freely changeable regardless) ; see the plan's own TODO for
---eventually splitting paint out as its own toggle too if that's ever wanted.
---@field randomizeVehiclePool boolean? only meaningful while the resolved vehicle restriction is
---"pool": when true, each participant is automatically force-spawned a random entry from the pool
---the moment they join the lobby, instead of being steered to the native vehicle selector to pick
---one themselves ; default false

---@class BJRace
---@field id integer
---@field name string
---@field author string
---@field mode BJRaceMode
---@field distance number meters, derived client-side at authoring time
---@field loopable boolean
---@field env table? per-race environment preset, optional
---@field gates BJRaceGate[] flat array: array position doubles as gate identity everywhere else
---in this system (world-click hit-test, gizmo attachment, `parents` references), but ordinal race
---PROGRESS is tracked via each gate's own `step` field instead (see BJRaceGate.step) once
---`branchingEnabled` is on, so several gates can share one step as parallel alternates
---@field branchingEnabled boolean? per-race, author-level toggle (default off): while off, every
---gate's `step`/`parents`/`isFinish` fields are force-normalized back to the plain implicit linear
---shape by `sanitizeRace` regardless of what's stored, so a race can be safely toggled back to
---linear at any time with zero risk of stale branching data leaking through. While on, the editor
---exposes per-gate parent/child links and an explicit finish flag ; `sectorCount`/`manualSectors`
---are ignored (forced off) for a branching race, since index/distance-based sector splitting is
---still ambiguous once a route can genuinely fork. `limitVisibleGates` used to be forced off here
---too (a sliding "next N gates" window has no meaning for a plain linear index once a route can
---fork), but raceMarkers.lua's own visibleGateSetBranching now walks the real `parents` graph
---instead, so it's meaningful (and left as configured) for a branching race as well
---@field startPositions {pos: {x: number, y: number, z: number}, dir: {x: number, y: number, z: number}}[]
---grid-slot placements for `grid` mode with multiple participants; index 1 is also used as the
---single spawn point for a solo/passive attempt. `dir` (not a quaternion) matches
---`BJRaceGate.dir`'s convention: simpler to write/read/round-trip than a quat, and consistent
---with how gates already store facing
---@field defaults BJRaceDefaults
---@field leaderboard table<string, {time: integer, model: string, date: integer}>? playerName ->
---that player's own personal-best completed lap for this race ; the source of truth for both PBs
---and the overall record (whoever has the lowest `time` here). Deliberately excluded from the
---general race-cache broadcast (`onBJRequestCache` sends a trimmed clone) since every player's
---data living inside every race object would otherwise get pushed to every connected client on
---every unrelated cache sync ; fetched on demand instead via `raceLeaderboardRequest`.
---@field sectorCount integer? how many sectors the timing/results panel splits each lap into,
---for gate-crossing splits comparable to sim-racing sector times ; the gate sequence is divided
---into this many roughly-even (by track distance) contiguous groups (creator-set, not fixed at 3
---(some races here have 60+ gates, where "always 3" would be too coarse to be useful) ; default
---3, clamped to [1, min(#gates, 12)] since more sectors than gates is meaningless and the results
---panel gets unreadable well before 12 anyway. Ignored (superseded by the gate-flagged boundaries
---below) whenever `manualSectors` is on.
---@field manualSectors boolean? when true, sector boundaries come from whichever gates have their
---own `sector = true` flag set (see BJRaceGate.sector) instead of `sectorCount`'s automatic
---even-by-distance split: for a creator who wants sectors to line up with something specific about
---the track (a technical section, a jump, a village) rather than wherever the math happens to land.
---The final gate always implicitly closes the last sector even if not flagged ; if no gate is
---flagged at all, raceGrid.lua falls back to the automatic `sectorCount` split so a race is never
---left with zero real sectors ; default false
---@field vehicleRestrictionMode ("free"|"single"|"pool")? "free" (default) : any vehicle/config
---may participate. "single" : every participant is force-spawned into exactly one captured
---vehicle+parts the moment they join the lobby (see vehicleRestrictionModel/Parts/Vars/Paints
---below): no picking involved, so this is the only mode that can require a fully custom (never
---saved) setup, since nothing needs to present it as a choice. "pool" : the host picks a shared
---BJVehiclePreset (vehicleRestrictionPoolPresetId below, see services/vehiclePresets.lua) and a
---joining participant picks any one of its vehicles via the native vehicle selector, pre-filtered
---down to just the pool. Checked/enforced
---client-side (join-time force-spawn or selector-filtering, plus the spawn-authorization hook).
---The server has never tracked vehicle parts, so none of this is new anti-cheat, just a UX/design
---feature matching the race's own intent (e.g. a spec-car challenge or a class race). A race-level
---property, not a per-start override: unlike the anticheat toggles, this is part of the race's
---own design, not a per-attempt convenience.
---@field vehicleRestrictionModel string? jbeam model key (e.g. "pickup"), only meaningful when
---vehicleRestrictionMode == "single" ; captured from the editor's own currently-equipped vehicle,
---never typed by hand
---@field vehicleRestrictionParts table<string, string>? "single" mode only : the captured
---vehicle's full parts tree (slot -> chosen part name, see vehicles.lua's getFullConfig): the
---actual thing every joining participant gets force-spawned into and compared against, works
---identically whether the source was a saved .pc or a fully custom (never saved) setup
---@field vehicleRestrictionVars table<string, number>? "single" mode only : captured tuning
---variables, applied on force-spawn for a faithful reproduction; never itself compared, matching
---the same "parts define the requirement, tuning/paint don't" reasoning a pool preset's own
---model+config exact-match doesn't need this level of nuance for at all
---@field vehicleRestrictionPaints table? "single" mode only : captured paint slots, applied on
---force-spawn for a faithful reproduction; never itself compared, same reasoning as Vars above
---@field vehicleRestrictionLabel string? "single" mode only : human-readable "Model - Config" (or
---"Model (custom)") display label, captured alongside the fields above purely for display
---@field vehicleRestrictionPoolPresetId integer? "pool" mode only : id of a shared
---BJVehiclePreset (see services/vehiclePresets.lua): the race stores only a reference, not its own
---copy of the entries, so editing a preset (adding/removing vehicles) updates every race that
---points at it without needing to re-save each one. Resolved to the preset's actual entries at
---session-build time (raceGrid.lua's buildSettings), same "snapshot at session start, not read live
---mid-session" treatment "single" mode's own captured parts already get

local M = {
    -- services_hunter : only for its own already-verified quatToFlatDir helper, reused by this
    -- file's own legacy race importer (see convertLegacyStartPositions and convertLegacyRaceGates
    -- below) rather than re-deriving the same fragile quaternion math a second time
    dependencies = { "dao_activity", "dao_bundled", "services_core", "services_config",
        "services_vehiclePresets", "services_hunter" },

    ACTIVITY_TYPE = "races",

    RESPAWN_STRATEGIES = {
        ALL = "all",
        NORESPAWN = "norespawn",
        LASTCHECKPOINT = "lastcheckpoint",
    },
    -- how grid slots map to participants at countdown (see raceGrid.lua's beginCountdown):
    -- "deterministic" = lobby join order (starter first), "random" = shuffled, "manual" = the
    -- host assigns each participant's slot in the lobby. Random is the default: the old implicit
    -- behavior was pairs() iteration order over playerIDs, i.e. arbitrary anyway, never a real
    -- ordering anyone could have been relying on
    PLACEMENT_MODES = {
        DETERMINISTIC = "deterministic",
        RANDOM = "random",
        MANUAL = "manual",
    },
    MODES = {
        GRID = "grid",
        PASSIVE = "passive",
    },

    ---@type BJRace[] races for the current map
    data = {},
}

--- Real, confirmed bug fixed by existing at all: `step` used to be a client-authored field, just
--- like `parents`. But a branch alternate created LATER than the gates around it (the normal way
--- to build "gate 1 splits into 2 and 3, both rejoining at 4": place 1, 2, 4 first, then go back
--- and add 3 as 2's alternate) defaults its OWN `step` to "how many gates existed at the moment IT
--- was created", which has no relationship to where it ends up sitting in the route once its
--- `parents` are pointed at gate 1. A real live report confirmed exactly this: "when I went
--- through 3, it said 6" (3 was simply the 6th gate ever created, its `step` never manually
--- re-synced to match 2's own step once wired up as a second alternate). `step` is no longer
--- trusted from the client at all: it's derived here from the `parents` graph itself, the same
--- source of truth the crossing-validation logic already reads, so it structurally can't drift
--- out of sync with what the author actually linked, regardless of creation order.
---@param race BJRace
local function deriveStepsFromParents(race)
    local resolved = {}
    -- Real, confirmed bug fixed here (live report: adding a second, real parent alongside "Start"
    -- silently stripped a gate's own step-1/Start-Finish status, even with "Start" still sitting
    -- right there in its own parents list. And removing "Start" entirely in favor of a real link
    -- back from the route's own last gate(s) (the natural way to author a visible closing segment)
    -- left NOTHING at step 1 at all, so a lap could never be detected as complete: "an infinitely
    -- looping race where laps didn't count"). This used to require a gate's parents to be
    -- EXCLUSIVELY the "start" sentinel (0) to grant step 1 at all. Fixed to grant step 1 any time 0
    -- is present among a gate's parents, regardless of whatever real gates are also listed
    -- alongside it: a gate can now genuinely be "reachable from the start grid OR from the route's
    -- own last gate(s)" and still correctly be treated as the loop's own anchor either way.
    for i, g in ipairs(race.gates) do
        if table.includes(g.parents, 0) then
            resolved[i] = 1
        end
    end
    -- Iterative fixed-point resolution: a gate becomes resolvable once every one of its own real
    -- parents has itself already been resolved, same as a topological sort but without needing to
    -- build an explicit sorted order first. Bounded at #gates passes: a well-formed route can
    -- never need more (each pass resolves at least one more gate, or the graph has a real cycle
    -- and no further pass would help anyway)
    local changed, iterations = true, 0
    while changed and iterations < #race.gates do
        changed, iterations = false, iterations + 1
        for i, g in ipairs(race.gates) do
            if not resolved[i] then
                local ready, maxParentStep = true, 0
                for _, p in ipairs(g.parents) do
                    if p ~= 0 then
                        if resolved[p] then
                            maxParentStep = math.max(maxParentStep, resolved[p])
                        else
                            ready = false
                        end
                    end
                end
                if ready then
                    resolved[i] = maxParentStep + 1
                    changed = true
                end
            end
        end
    end
    -- Anything still unresolved here means a genuine cycle among real gates (not the intentional
    -- step-1 loop-closing exception, which never routes through this graph at all): a malformed
    -- setup that can't produce a meaningful progress number regardless, so this just falls back to
    -- SOME number rather than leaving `step` nil and crashing whatever reads it downstream. Real,
    -- confirmed bug fixed here: that fallback used to be the gate's own array position, which for
    -- a gate that happens to sit at position 1 (or, on a branching race, any gate whose `parents`
    -- loop back on itself through a shared multi-parent node, e.g. two step-1 alternates both
    -- feeding into the same next gate) collides with a REAL step-1 value, silently mislabeling an
    -- unrelated gate as the loop's own Start/Finish and handing it the unconditional step-1
    -- loop-closing bypass it was never meant to have. Falling back to `#race.gates + i` instead
    -- guarantees this can never coincide with a genuine step (every real step is <= #race.gates),
    -- so a cyclic/malformed graph still fails loudly and visibly (every affected gate reads some
    -- implausibly large step) rather than quietly pretending to be a valid start/finish line.
    for i, g in ipairs(race.gates) do
        g.step = resolved[i] or (#race.gates + i)
    end
end

--- Shared by sanitizeRace (runs at save time) AND loadData (runs at boot/map-change, for races
--- saved before this feature existed and never re-saved since). Extracted specifically because a
--- gate's `step` is read UNCONDITIONALLY server-side once a race is actually running
--- (raceGrid.lua's raceGateCrossed indexes gateTimes by it regardless of branchingEnabled), so a
--- legacy race whose gates have never had this field backfilled would hit a hard "table index is
--- nil" Lua error the first time anyone actually raced it, not just a display glitch. Running this
--- at load time too closes that gap without requiring every race author to individually re-open
--- and re-save their race first.
---@param race BJRace
local function normalizeGateSteps(race)
    race.branchingEnabled = race.branchingEnabled == true
    if race.branchingEnabled then
        for i, g in ipairs(race.gates) do
            if not table.isArray(g.parents) then g.parents = { i - 1 } end
            g.parents = table.filter(g.parents, function(p)
                p = tonumber(p)
                return p ~= nil and p ~= i and p >= 0 and p <= #race.gates
            end)
            -- De-duplicated defensively (confirmed real, not theoretical): the editor's own
            -- `table.assign`-based partial-gate update used to recursively MERGE a shorter new
            -- `parents` array into the old, longer one instead of replacing it wholesale, leaving a
            -- stale trailing entry from the old array in place and silently duplicating whatever
            -- value already sat there (removing one of two parents could echo back with the
            -- REMAINING one duplicated). That editor-side bug is fixed at its own source
            -- (ui/raceEditor.lua's onSetGate), but a duplicate that was already saved before that
            -- fix shipped would otherwise persist forever without getting cleaned up on its own.
            -- This catches that case (and any other future source of a duplicate) for free,
            -- at both save and load time, same as the rest of this function's own safety net.
            local seen, deduped = {}, {}
            for _, p in ipairs(g.parents) do
                if not seen[p] then
                    seen[p] = true
                    table.insert(deduped, p)
                end
            end
            g.parents = deduped
            if #g.parents == 0 then g.parents = { 0 } end
            g.isFinish = g.isFinish == true or nil
        end
        deriveStepsFromParents(race)
        if not race.loopable and not table.any(race.gates, function(g) return g.isFinish end) then
            race.gates[#race.gates].isFinish = true
        end
    else
        for i, g in ipairs(race.gates) do
            g.step = i
            g.parents = { i - 1 }
            g.isFinish = (i == #race.gates) or nil
        end
    end
end

---@param race BJRace
---@param existingRaces BJRace[]? defaults to M.data (the current map's own races): only ever
---passed explicitly by the legacy race importer below, which may be preparing a race for a
---DIFFERENT map than the one currently loaded (it scans every legacy file found, not just the
---current map's) and needs the duplicate-name check to compare against THAT map's own races, not
---whatever happens to be loaded in memory right now
---@return string? error
local function sanitizeRace(race, existingRaces)
    existingRaces = existingRaces or M.data
    -- 40, not the old 150: matches the editor's own new maxlength (see the plan file's note on
    -- also applying a character limit to every other player-enterable name field eventually).
    -- Tightened here too so a race created via a path that bypasses the editor's own input limit
    -- (chat/console/a future API) can't still slip in an oversized name
    if type(race.name) ~= "string" or #race.name:trim() < 3 or #race.name:trim() > 40 then
        return "Invalid name"
    elseif not table.includes(M.MODES, race.mode) then
        return "Invalid mode"
    elseif not table.isArray(race.gates) or #race.gates < 2 then
        return "A race needs at least 2 gates"
    elseif table.any(race.gates, function(g)
            return type(g.pos) ~= "table" or type(g.dir) ~= "table" or
                type(g.width) ~= "number" or type(g.height) ~= "number"
        end) then
        return "Invalid gate data"
    elseif not table.isArray(race.startPositions) or #race.startPositions < 1 then
        return "A race needs at least 1 start position"
    elseif table.any(race.startPositions, function(s)
            return type(s.pos) ~= "table" or type(s.dir) ~= "table"
        end) then
        return "Invalid start position data"
    end

    race.sectorCount = math.max(1, math.min(math.floor(tonumber(race.sectorCount) or 3), #race.gates, 12))
    race.manualSectors = race.manualSectors == true
    table.forEach(race.gates, function(g)
        g.sector = g.sector == true or nil
        -- mandatory-stop was removed outright (never actually implemented, see raceRunner.lua/
        -- raceGrid.lua's own former "NOT YET IMPLEMENTED" notes) ; scrubbed here too so a gate
        -- saved back through the editor sheds any stray `stand` flag left over from before
        g.stand = nil
    end)

    -- branching paths : see BJRace.branchingEnabled's own doc comment above, and
    -- normalizeGateSteps's own comment for why this same normalization also runs at load time
    normalizeGateSteps(race)

    -- "single"/"pool" only actually mean anything with a real capture already present (see
    -- vehicles.lua's getFullConfig/getCurrentConfigIdentity, client-side) ; silently falls back to
    -- "free" rather than rejecting the save outright, since this could be either a genuinely
    -- missing capture (editor never used to set one up yet) or a stray/malformed submission
    -- bypassing it, and "no restriction yet" is itself a perfectly valid state while a host is
    -- still setting one up
    if race.vehicleRestrictionMode == "single" and
        type(race.vehicleRestrictionModel) == "string" and #race.vehicleRestrictionModel > 0 and
        type(race.vehicleRestrictionParts) == "table" and table.length(race.vehicleRestrictionParts) > 0 then
        race.vehicleRestrictionMode = "single"
        race.vehicleRestrictionVars = type(race.vehicleRestrictionVars) == "table" and race.vehicleRestrictionVars or {}
        race.vehicleRestrictionPaints = type(race.vehicleRestrictionPaints) == "table" and race.vehicleRestrictionPaints or {}
    elseif race.vehicleRestrictionMode == "pool" and tonumber(race.vehicleRestrictionPoolPresetId) and
        services_vehiclePresets.getById(tonumber(race.vehicleRestrictionPoolPresetId)) then
        race.vehicleRestrictionMode = "pool"
        race.vehicleRestrictionPoolPresetId = tonumber(race.vehicleRestrictionPoolPresetId)
    else
        race.vehicleRestrictionMode = "free"
    end

    race.defaults = race.defaults or {}
    if not table.includes(M.RESPAWN_STRATEGIES, race.defaults.respawnStrategy) then
        race.defaults.respawnStrategy = M.RESPAWN_STRATEGIES.LASTCHECKPOINT
    end
    if not table.includes(M.PLACEMENT_MODES, race.defaults.placementMode) then
        race.defaults.placementMode = M.PLACEMENT_MODES.RANDOM
    end
    -- a race with only one grid slot can never actually be joined by anyone else (raceJoin caps
    -- participants at #startPositions), so normalize the saved default here too, not just at
    -- raceStart time: the editor's own state can't drift out of sync with what the toggle
    -- would even mean once a race is edited down to a single start position
    race.defaults.joinable = race.defaults.joinable == true and #race.startPositions > 1
    race.defaults.gridTimeout = tonumber(race.defaults.gridTimeout) or 180
    race.defaults.gridReadyTimeout = tonumber(race.defaults.gridReadyTimeout) or 10
    race.defaults.countdown = tonumber(race.defaults.countdown) or 10
    race.defaults.dnfEnabled = race.defaults.dnfEnabled ~= false
    race.defaults.dnfTimeout = math.max(3, tonumber(race.defaults.dnfTimeout) or 30)
    race.defaults.resetPenaltyEnabled = race.defaults.resetPenaltyEnabled == true
    race.defaults.resetPenaltySeconds = math.max(1, tonumber(race.defaults.resetPenaltySeconds) or 5)
    race.defaults.autoSpectateOnFinish = race.defaults.autoSpectateOnFinish ~= false
    race.defaults.disableNodegrabber = race.defaults.disableNodegrabber ~= false
    race.defaults.disableCameras = race.defaults.disableCameras ~= false
    race.defaults.disableGravityChange = race.defaults.disableGravityChange ~= false
    race.defaults.ghostOnCountdown = race.defaults.ghostOnCountdown ~= false
    race.defaults.disableCollisions = race.defaults.disableCollisions == true
    race.defaults.ghostBackmarkers = race.defaults.ghostBackmarkers == true
    race.defaults.showGateNametags = race.defaults.showGateNametags == true
    race.defaults.limitVisibleGates = race.defaults.limitVisibleGates ~= false
    race.defaults.visibleGateCount = math.max(1, math.min(math.floor(tonumber(race.defaults.visibleGateCount) or 2), 5))
    race.defaults.allowTuning = race.defaults.allowTuning ~= false
    race.defaults.randomizeVehiclePool = race.defaults.randomizeVehiclePool == true
    if race.defaults.laps ~= nil then
        race.defaults.laps = math.max(1, math.floor(tonumber(race.defaults.laps) or 1))
    end

    local duplicate = table.find(existingRaces, function(r)
        return r.id ~= race.id and r.name:lower() == race.name:trim():lower()
    end)
    if duplicate then return "A race with this name already exists" end
end

--- Legacy BeamJoy Free (BJI) race importer. BJI stores races in one `<mapName>_races.json` file
--- per map under `<dbPath>/scenarii/` (a plain JSON array of race objects), same folder convention
--- already established by the Hunter arena importer above. Per direct request, this is
--- NON-DESTRUCTIVE: every convertible race is ADDED as a brand-new race (a fresh id, never
--- touching/overwriting anything already in the list); a name collision with an existing race is
--- skipped and reported, never silently renamed or overwritten. Like the Hunter importer, this
--- operates on EVERY map found at once, not just the currently-loaded one: an admin migrating a
--- whole server's worth of old data shouldn't have to switch maps repeatedly to import each one.
local LEGACY_DIR = "scenarii"

---@param ax number
---@param ay number
---@param bx number
---@param by number
---@return number dx, number dy normalized direction from (ax,ay) to (bx,by), or 0,0 if the two
---points are (near-)identical
local function deltaNormalized(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-3 then return 0, 0 end
    return dx / len, dy / len
end

--- Real, confirmed bug fixed here (live report with actual source data attached, "gates
--- sometimes rotated at strange angles", reproduced even on a genuinely non-branching race):
--- this used to always IGNORE BJI's own waypoint `rot` for gates outright, reasoning it was "a
--- raw captured vehicle-rotation quaternion with no more meaning for a pure radius-trigger
--- checkpoint than the one already flagged for Hunter's spawn import", and derived a direction
--- from the route's own topology instead (point toward this gate's own children). Checked against
--- the reported race's real exported data: BJI's waypoints are frequently 60-300m apart on a
--- circuit that curves between them, so a straight chord to the next waypoint routinely points
--- nowhere near the actual LOCAL road heading at the gate itself, exactly the "rotated at a
--- strange angle" symptom, reproducing even with zero branching involved, since the chord method
--- never depended on branching to begin with. `rot` (via quatToFlatDir, same helper this file's
--- own convertLegacyStartPositions and Hunter's own spawn import already trust for the identical
--- purpose) turned out to diverge from the chord direction by anywhere from ~0 to ~90 degrees
--- across that same real race, exactly the signature of it capturing genuine local heading the
--- chord approximation can't. `rot` is now used directly whenever present ; the topology-derived
--- heuristic below is kept only as a fallback for the rare gate missing usable rot data (an older
--- export, or a hand-edited file), not the default path anymore.
---@param gates BJRaceGate[] already positioned, with `parents` already resolved to real indices
---@param children table<integer, integer[]> gate index -> array of its own children's indices
---@param onlyIndices table<integer, true> only these gate indices get a derived direction (every
---other gate already has a real rot-derived one, see convertLegacyRaceGates)
local function deriveLegacyGateDirections(gates, children, onlyIndices)
    for i, g in ipairs(gates) do
        if onlyIndices[i] then
            local dx, dy = 0, 0
            local kids = children[i]
            if kids then
                for _, childIdx in ipairs(kids) do
                    local cx, cy = deltaNormalized(g.pos.x, g.pos.y, gates[childIdx].pos.x, gates[childIdx].pos.y)
                    dx, dy = dx + cx, dy + cy
                end
            end
            local len = math.sqrt(dx * dx + dy * dy)
            if len < 1e-3 then
                local realParent
                for _, p in ipairs(g.parents) do
                    if p > 0 then
                        realParent = p
                        break
                    end
                end
                if realParent then
                    dx, dy = deltaNormalized(gates[realParent].pos.x, gates[realParent].pos.y, g.pos.x, g.pos.y)
                    len = math.sqrt(dx * dx + dy * dy)
                end
            end
            if len < 1e-3 then
                dx, dy = 1, 0
            else
                dx, dy = dx / len, dy / len
            end
            g.dir = { x = dx, y = dy, z = 0 }
        end
    end
end

--- Flattens BJI's `steps[][]` (parallel waypoint alternates per ordinal step) into this fork's own
--- flat gate array + `parents` (by index, not name: BJI references waypoints by their own unique
--- `name` string, or the literal "start" sentinel). `step`/`isFinish` for a genuinely branching
--- result are left for deriveStepsFromParents/the finish-flagging below to fill in; nothing here
--- needs to preserve BJI's own step GROUPING once the graph edges themselves are captured.
---@param steps {name:string, pos:table, rot:table, radius:number, parents:string[]?}[][]
---@param loopable boolean
---@return BJRaceGate[]? gates, boolean branching
local function convertLegacyRaceGates(steps, loopable)
    if not table.isArray(steps) or #steps == 0 then return nil end

    local gates, nameToIndex = {}, {}
    local branching = table.any(steps, function(step) return table.isArray(step) and #step > 1 end)
    for _, step in ipairs(steps) do
        if not table.isArray(step) then return nil end
        for _, wp in ipairs(step) do
            if type(wp) ~= "table" or type(wp.pos) ~= "table" or type(wp.name) ~= "string" or #wp.name == 0 then
                return nil
            end
            local hasRot = type(wp.rot) == "table"
            table.insert(gates, {
                pos = { x = tonumber(wp.pos.x) or 0, y = tonumber(wp.pos.y) or 0, z = tonumber(wp.pos.z) or 0 },
                dir = hasRot and services_hunter.quatToFlatDir(wp.rot) or { x = 1, y = 0, z = 0 }, -- placeholder
                -- if !hasRot, replaced below by deriveLegacyGateDirections once every gate exists
                width = math.max(2, (tonumber(wp.radius) or 3) * 2),
                height = math.max(2, (tonumber(wp.radius) or 3) * 2),
                parents = {}, -- filled in below, once every name is known
                -- transient, stripped before this function returns: survives the loopable
                -- rewrite's own array reordering below since it travels on the gate object itself,
                -- unlike a plain index-based set built at this creation-time indexing would
                needsDerivedDir = not hasRot or nil,
            })
            nameToIndex[wp.name] = #gates
        end
    end

    local gateIndex = 0
    for _, step in ipairs(steps) do
        for _, wp in ipairs(step) do
            gateIndex = gateIndex + 1
            local parents = {}
            if type(wp.parents) == "table" then
                for _, p in ipairs(wp.parents) do
                    if p == "start" then
                        table.insert(parents, 0)
                    elseif nameToIndex[p] then
                        table.insert(parents, nameToIndex[p])
                    end
                end
            end
            if #parents == 0 then parents = { 0 } end
            if #parents > 1 then branching = true end
            gates[gateIndex].parents = parents
        end
    end

    -- Real, confirmed bug fixed here (live report against two actual imported BJI races, "Sawmill
    -- Long"/"Gas Station Loop": the start/finish line ends up on the wrong gate, and the loop
    -- doesn't visibly close back to it). BJI's own steps[][] format always chains a genesis
    -- gate(s) parented straight to its literal "start" sentinel through to a terminal gate(s)
    -- nothing else parents ("finish", or an alternate ending like "pit"); BJI's own lap-restart is
    -- purely procedural (replay the same steps sequence again), never an explicit graph edge back
    -- from the terminal to the genesis. Checking the real, live-measured positions of both
    -- reported races against their own recorded grid start confirmed the terminal gate(s), not the
    -- genesis gate(s), are the ones actually sitting back at the real start/finish line (e.g. Gas
    -- Station Loop's "finish"/"pit" sit ~12-21m from the grid, its "wp2" genesis sits ~175m away),
    -- exactly matching real-world track design (the pits/start line are the same physical spot).
    -- This fork's own loop-closing mechanic needs the step-1 gate itself to BE that physically-
    -- adjacent-to-grid spot (raceGrid.lua's raceGateCrossed treats *re*-crossing step 1 as closing
    -- every lap, unconditionally, regardless of `parents`), so for a loopable race the genesis/
    -- terminal roles are swapped here: the (possibly several, parallel) terminal gate(s) become
    -- the new genesis (parented straight to the sentinel), and the old genesis gate(s) get rewired
    -- to be reached FROM the terminal(s) instead.
    if loopable then
        local isParentOf = {}
        for _, g in ipairs(gates) do
            for _, p in ipairs(g.parents) do
                if p > 0 then isParentOf[p] = true end
            end
        end
        local terminals = {}
        for i in ipairs(gates) do
            if not isParentOf[i] then table.insert(terminals, i) end
        end
        local genesis = {}
        for i, g in ipairs(gates) do
            if table.includes(g.parents, 0) then table.insert(genesis, i) end
        end
        local terminalSet = {}
        for _, t in ipairs(terminals) do terminalSet[t] = true end
        local needsRotation = #terminals > 0 and #genesis > 0 and
            table.any(genesis, function(g) return not terminalSet[g] end)
        if needsRotation then
            -- Real, confirmed bug fixed here (live report: imported gates "sometimes rotated at
            -- strange angles", against a race with multiple parallel start/finish lanes). The
            -- rewiring below used to connect EVERY genesis gate to EVERY terminal (a full
            -- bipartite cross-product) whenever more than one of either existed, e.g. two lanes
            -- each ending at their own physically-separate finish checkpoint, instead of only its
            -- own lane's actual terminal. deriveLegacyGateDirections then averaged each terminal's
            -- direction across ALL genesis gates as children, including ones never actually
            -- reachable from it, pulling a lane's own start/finish gate diagonally toward a
            -- completely unrelated lane's next checkpoint instead of pointing straight down its
            -- own lane. Fixed by only connecting a genesis gate to the terminal(s) actually
            -- reachable FROM it, computed via a plain forward BFS over the ORIGINAL (pre-rewire)
            -- parent chain, before any of the parents below get mutated.
            local preRewireChildren = {}
            for i, g in ipairs(gates) do
                for _, p in ipairs(g.parents) do
                    if p > 0 then
                        preRewireChildren[p] = preRewireChildren[p] or {}
                        table.insert(preRewireChildren[p], i)
                    end
                end
            end
            ---@param fromIdx integer
            ---@return table<integer, true> every terminal gate index reachable from fromIdx by
            ---walking preRewireChildren forward (the original, pre-rewire DAG: strictly genesis ->
            ---... -> terminal, so no cycle risk here)
            local function reachableTerminals(fromIdx)
                local seen, found, frontier = { [fromIdx] = true }, {}, { fromIdx }
                while #frontier > 0 do
                    local nextFrontier = {}
                    for _, idx in ipairs(frontier) do
                        if terminalSet[idx] then found[idx] = true end
                        for _, child in ipairs(preRewireChildren[idx] or {}) do
                            if not seen[child] then
                                seen[child] = true
                                table.insert(nextFrontier, child)
                            end
                        end
                    end
                    frontier = nextFrontier
                end
                return found
            end

            -- 1. Rewire the graph: the (possibly several, parallel) terminal gate(s) become the
            -- new genesis (parented straight to the sentinel), the old genesis gate(s) get rewired
            -- to be reached FROM their own lane's terminal(s) instead. deriveStepsFromParents
            -- (already required for any branching race, see normalizeGateSteps) recomputes every
            -- gate's `step` correctly from this regardless of the gates array's own physical
            -- order, so only force branchingEnabled on when a real fork actually exists (start,
            -- finish, or both): a genuinely simple single-path loop stays non-branching, keeping
            -- its sector timing / visible-gate-limit support instead of losing both purely as a
            -- side effect of this fix
            for _, g in ipairs(genesis) do
                local gate = gates[g]
                local newParents = {}
                for _, p in ipairs(gate.parents) do
                    if p ~= 0 then table.insert(newParents, p) end
                end
                local ownTerminals = reachableTerminals(g)
                if next(ownTerminals) then
                    for t in pairs(ownTerminals) do table.insert(newParents, t) end
                else
                    -- defensive fallback, shouldn't happen for a well-formed chain (every genesis
                    -- eventually reaches SOME terminal): better a loop that closes onto the wrong
                    -- lane than one that can never close at all
                    for _, t in ipairs(terminals) do table.insert(newParents, t) end
                end
                gate.parents = newParents
            end
            for _, t in ipairs(terminals) do
                gates[t].parents = { 0 }
            end
            if #genesis > 1 or #terminals > 1 then branching = true end

            -- 2. Physically move every terminal gate to the FRONT of the array (in original
            -- relative order), so array position (not just the derived `step`) matches this
            -- fork's own "gate 1 is the start/finish line" editor convention, exactly like a
            -- natively-authored race already gets by construction. Everything else follows in its
            -- original relative order after them. `.parents` references are index-based, so every
            -- gate's own list has to be remapped through the old->new index table too.
            local oldToNew, newGates = {}, {}
            for _, t in ipairs(terminals) do
                table.insert(newGates, gates[t])
                oldToNew[t] = #newGates
            end
            for i, g in ipairs(gates) do
                if not terminalSet[i] then
                    table.insert(newGates, g)
                    oldToNew[i] = #newGates
                end
            end
            for _, g in ipairs(newGates) do
                local remapped = {}
                for _, p in ipairs(g.parents) do
                    table.insert(remapped, p == 0 and 0 or oldToNew[p])
                end
                g.parents = remapped
            end
            gates = newGates
        end
    end

    local children = {}
    local needsDerivedDir = {}
    for i, g in ipairs(gates) do
        for _, p in ipairs(g.parents) do
            if p > 0 then
                children[p] = children[p] or {}
                table.insert(children[p], i)
            end
        end
        if g.needsDerivedDir then
            needsDerivedDir[i] = true
            g.needsDerivedDir = nil -- transient, never part of the real BJRaceGate shape
        end
    end
    deriveLegacyGateDirections(gates, children, needsDerivedDir)

    -- finish flagging : only meaningful for a branching, non-loopable race (a loopable race's own
    -- finish is always "re-crossing the step-1 gate" regardless of this flag, and a non-branching
    -- race gets its own last-gate-is-finish default from sanitizeRace/normalizeGateSteps instead)
    if branching and not loopable then
        for _, wp in ipairs(steps[#steps]) do
            local idx = nameToIndex[wp.name]
            if idx then gates[idx].isFinish = true end
        end
    end

    return gates, branching
end

---@param entries {pos: table, rot: table}[]?
---@return {pos: {x:number,y:number,z:number}, dir: {x:number,y:number,z:number}}[]
local function convertLegacyStartPositions(entries)
    local result = {}
    if type(entries) == "table" then
        for _, e in ipairs(entries) do
            if type(e) == "table" and type(e.pos) == "table" then
                table.insert(result, {
                    pos = { x = tonumber(e.pos.x) or 0, y = tonumber(e.pos.y) or 0, z = tonumber(e.pos.z) or 0 },
                    -- unlike gate direction above, a start position's own captured rotation IS a
                    -- genuine, meaningful facing (which way to point at the grid), using the same
                    -- reasoning and same already-verified math as Hunter's own spawn import
                    dir = type(e.rot) == "table" and services_hunter.quatToFlatDir(e.rot) or { x = 1, y = 0, z = 0 },
                })
            end
        end
    end
    return result
end

---@param oldData table raw parsed BJI race object
---@return BJRace? unsaved (no id yet) ; nil if fundamentally unconvertible (missing/invalid
---steps or start positions)
local function convertLegacyRace(oldData)
    if type(oldData) ~= "table" then return nil end
    local loopable = oldData.loopable == true
    local gates, branching = convertLegacyRaceGates(oldData.steps, loopable)
    if not gates or #gates < 2 then return nil end
    local startPositions = convertLegacyStartPositions(oldData.startPositions)
    if #startPositions == 0 then return nil end

    -- sanitizeRace enforces a 40-char max (added after this importer was first built, see its own
    -- "not the old 150" comment) ; a real legacy race name routinely exceeds that (BJRally/BJI
    -- allowed much longer descriptive names), and this importer would otherwise unconditionally
    -- fail sanitation for every one of those instead of importing a truncated name
    local importedName = type(oldData.name) == "string" and oldData.name:trim() or ""
    if #importedName < 3 then
        importedName = "Imported Race"
    elseif #importedName > 40 then
        importedName = importedName:sub(1, 40):trim()
    end

    return {
        name = importedName,
        -- Credits the ORIGINAL BJI author, not whoever ran the import: raceSave's own new-race
        -- path (the only other place `author` gets stamped) would otherwise leave every imported
        -- race attributed to nobody but the admin who happened to click Import, silently erasing
        -- whoever actually built the route. This importer bypasses raceSave entirely (writes
        -- straight to disk via dao_activity.save), so nothing else was ever setting this field
        author = type(oldData.author) == "string" and oldData.author or "console",
        mode = M.MODES.GRID,
        loopable = loopable,
        distance = 0,
        gates = gates,
        startPositions = startPositions,
        branchingEnabled = branching,
        sectorCount = 3,
        manualSectors = false,
        vehicleRestrictionMode = "free",
        defaults = {
            respawnStrategy = M.RESPAWN_STRATEGIES.LASTCHECKPOINT,
            joinable = false,
            gridTimeout = 180,
            gridReadyTimeout = 10,
            countdown = 10,
            laps = 3,
        },
    }
end

---@return {map: string, name: string, author: string, gateCount: integer, startCount: integer, loopable: boolean, branching: boolean, conflict: boolean, invalid: boolean}[]
local function scanLegacyRaces()
    local results = {}
    local dir = dao_main.dbPath .. "/" .. LEGACY_DIR
    if not FS.Exists(dir) then return results end
    for _, filename in pairs(FS.ListFiles(dir)) do
        local mapName = filename:match("^(.+)_races%.json$")
        if mapName then
            local raw = dao_main.get(LEGACY_DIR .. "/" .. filename)
            if table.isArray(raw) then
                local isCurrentMap = mapName == services_core.getCurrentMap()
                local existing = isCurrentMap and M.data or (dao_activity.get(mapName, M.ACTIVITY_TYPE) or {})
                for _, oldRace in ipairs(raw) do
                    local converted = convertLegacyRace(oldRace)
                    if converted then
                        local err = sanitizeRace(converted, existing)
                        table.insert(results, {
                            map = mapName,
                            name = converted.name,
                            author = converted.author,
                            gateCount = #converted.gates,
                            startCount = #converted.startPositions,
                            loopable = converted.loopable == true,
                            branching = converted.branchingEnabled == true,
                            conflict = err == "A race with this name already exists",
                            invalid = err ~= nil and err ~= "A race with this name already exists",
                        })
                    end
                end
            end
        end
    end
    return results
end

---@param ctxt BJSContext
local function raceLegacyImportPreview(ctxt)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditRaces) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end
    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "raceLegacyImportPreviewResult", scanLegacyRaces())
    end
end

---@param ctxt BJSContext
local function raceLegacyImportConfirm(ctxt)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditRaces) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end

    local dir = dao_main.dbPath .. "/" .. LEGACY_DIR
    local imported, skipped, failed = 0, 0, 0
    if FS.Exists(dir) then
        for _, filename in pairs(FS.ListFiles(dir)) do
            local mapName = filename:match("^(.+)_races%.json$")
            if mapName then
                local raw = dao_main.get(LEGACY_DIR .. "/" .. filename)
                if table.isArray(raw) then
                    local isCurrentMap = mapName == services_core.getCurrentMap()
                    -- the CURRENT map's own targetList IS M.data itself (same table reference, not
                    -- a copy) so every insert below mutates it in place, same as any other save ;
                    -- any OTHER map's targetList is a fresh fetch, written back explicitly afterward
                    local targetList = isCurrentMap and M.data or (dao_activity.get(mapName, M.ACTIVITY_TYPE) or {})
                    local changedThisMap = false
                    for _, oldRace in ipairs(raw) do
                        local converted = convertLegacyRace(oldRace)
                        if converted then
                            local err = sanitizeRace(converted, targetList)
                            if err then
                                if err == "A race with this name already exists" then
                                    skipped = skipped + 1
                                else
                                    LogError(string.format(
                                        "raceLegacyImportConfirm: %s / %s failed sanitation: %s",
                                        mapName, tostring(oldRace.name), err))
                                    failed = failed + 1
                                end
                            else
                                local id = 1
                                while table.any(targetList, function(r) return r.id == id end) do
                                    id = id + 1
                                end
                                converted.id = id
                                converted.leaderboard = {}
                                table.insert(targetList, converted)
                                imported = imported + 1
                                changedThisMap = true
                            end
                        end
                    end
                    if changedThisMap then
                        if isCurrentMap then
                            -- Inlined rather than calling saveData(): that's a LOCAL function
                            -- declared further down in this file, and Lua's local scoping means a
                            -- bare reference to it from code defined earlier (like this importer)
                            -- would resolve to an undeclared global instead of the real one.
                            -- Equivalent to what saveData() itself does either way
                            dao_activity.save(services_core.getCurrentMap(), M.ACTIVITY_TYPE, M.data)
                            services_players.players:forEach(function(p)
                                local caches = {}
                                M.onBJRequestCache(caches, p.playerID)
                                communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
                            end)
                        else
                            dao_activity.save(mapName, M.ACTIVITY_TYPE, targetList)
                        end
                    end
                end
            end
        end
    end

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "raceLegacyImportDone", imported, skipped, failed)
    end
end

--- load races for the current map, called on boot and on map change
local function loadData()
    M.data = dao_activity.get(services_core.getCurrentMap(), M.ACTIVITY_TYPE) or {}
    -- Real, confirmed bug: a race saved before the vehicle-restriction feature existed (or simply
    -- never re-opened/re-saved since) has vehicleRestrictionMode == nil on disk. sanitizeRace only
    -- ever runs at actual save time (see raceSave below), never on load, so that nil flowed
    -- straight through to every client as JS `undefined`. The start panel's own anticheat-warning
    -- check (`race.vehicleRestrictionMode !== "free"`) then misread "no data at all" as "this race
    -- has a restriction", triggering a spurious "one or more anticheat options are disabled" popup
    -- on every start of an untouched race, regardless of the actual anticheat toggles' state.
    -- Backfilled here, once, at load time: cheaper and safer than requiring every race author to
    -- individually re-open and re-save their race for this to self-correct.
    table.forEach(M.data, function(r)
        -- see normalizeGateSteps's own comment : a race saved before branching paths existed has
        -- no gate.step at all, and that field is read unconditionally once anyone actually races
        -- it (raceGrid.lua's raceGateCrossed), so this can't wait for sanitizeRace's own
        -- save-time-only normalization the way vehicleRestrictionMode's backfill below can
        if table.isArray(r.gates) then
            normalizeGateSteps(r)
        end
        if r.vehicleRestrictionMode == nil then
            r.vehicleRestrictionMode = "free"
        elseif r.vehicleRestrictionMode == "pool" and
            (not tonumber(r.vehicleRestrictionPoolPresetId) or
                not services_vehiclePresets.getById(tonumber(r.vehicleRestrictionPoolPresetId))) then
            -- Same class of legacy-shape backfill as the nil case above: "pool" used to store its
            -- own inline vehicleRestrictionPool array before presets existed as a shared concept.
            -- A race saved under that old shape (or one whose referenced preset was since deleted)
            -- has no valid presetId, which sanitizeRace would only ever catch on next SAVE, not on
            -- load; falls back to "free" here so it doesn't spuriously trip the client's
            -- "has-a-restriction" anticheat warning for a restriction that can't actually resolve
            r.vehicleRestrictionMode = "free"
        end
    end)
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches, p.playerID)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

local function saveData()
    dao_activity.save(services_core.getCurrentMap(), M.ACTIVITY_TYPE, M.data)
end

--- auto-imports any of this mod's own bundled default races that haven't been seeded into a
--- given map's live data yet, per direct request (see dao/bundled.lua's own doc for the whole
--- mechanism). Runs once, at boot, for every map dao_bundled has content for, not just whichever
--- one happens to be currently loaded, so it's already there and ready the moment an admin
--- switches maps later without needing a restart. Deliberately NOT re-run on every onMapChanged
--- (loadData already is, right after this in onInit): a bundled race is only ever considered once
--- per (map, name), tracked persistently by dao_bundled's own ledger, so this can never re-add
--- something an admin has since deleted on purpose, and never touches an already-seeded map again
--- just because the server restarted
local function seedBundledRaces()
    for _, mapName in ipairs(dao_bundled.listMapsForType(M.ACTIVITY_TYPE)) do
        local bundled = dao_bundled.get(mapName, M.ACTIVITY_TYPE)
        if table.isArray(bundled) then
            local targetList = dao_activity.get(mapName, M.ACTIVITY_TYPE) or {}
            local changed = false
            for _, race in ipairs(bundled) do
                local name = type(race.name) == "string" and race.name or ""
                if not dao_bundled.isSeeded(mapName, M.ACTIVITY_TYPE, name) then
                    -- work on a copy: sanitizeRace mutates its argument (defaults backfill etc.),
                    -- and re-mutating the same shared bundled table across every map it happens to
                    -- also ship for would be a real bug otherwise
                    local candidate = table.deepcopy(race)
                    local err = sanitizeRace(candidate, targetList)
                    if err then
                        if err == "A race with this name already exists" then
                            -- someone (an admin, or a previous boot) already has a race by this
                            -- name on this map ; treat it as handled rather than retrying forever
                            LogInfo(string.format(
                                "seedBundledRaces: skipped %s / %s, a race with this name already exists",
                                mapName, name))
                            dao_bundled.markSeeded(mapName, M.ACTIVITY_TYPE, name)
                        else
                            LogError(string.format(
                                "seedBundledRaces: %s / %s failed sanitation: %s", mapName, name, err))
                        end
                    else
                        local id = 1
                        while table.any(targetList, function(r) return r.id == id end) do
                            id = id + 1
                        end
                        candidate.id = id
                        candidate.leaderboard = {}
                        table.insert(targetList, candidate)
                        dao_bundled.markSeeded(mapName, M.ACTIVITY_TYPE, name)
                        changed = true
                        LogInfo(string.format("seedBundledRaces: seeded %s / %s", mapName, name))
                    end
                end
            end
            if changed then
                dao_activity.save(mapName, M.ACTIVITY_TYPE, targetList)
            end
        end
    end
end

---@param caches table
local function onBJRequestCache(caches)
    -- Visible to every player, not staff-gated: races are meant to be played, not just administered.
    -- Leaderboard is deliberately stripped here (see BJRace.leaderboard's own doc comment): it's
    -- fetched on demand per-race instead, not synced as part of every player's routine race cache
    caches.races = table.map(M.data, function(r)
        local trimmed = table.clone(r)
        -- leaderboardCount (a plain integer, not the actual per-player data) lets the editor warn
        -- before a save wipes it (see raceSave below) without syncing everyone's real times to
        -- every client just to know that count
        trimmed.leaderboardCount = table.length(r.leaderboard or {})
        trimmed.leaderboard = nil
        return trimmed
    end)
end

---@param ctxt BJSContext
---@param race BJRace
local function raceSave(ctxt, race)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditRaces) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end

    local err = sanitizeRace(race)
    if err then
        -- always log server-side, not just when console-invoked : a player-triggered failure
        -- previously only ever reached the client as a toast, leaving nothing in the server
        -- console to actually diagnose what was wrong with the submitted data
        LogError(string.format("raceSave rejected%s: %s",
            ctxt.sender and (" from " .. ctxt.sender.playerName) or "", err))
        -- dump unconditionally, not gated on IsDebug() : that depends on the server's own
        -- MP.Settings.Debug flag, which may well be off, and this is exactly the situation
        -- where seeing the actual rejected data matters
        dump(race)
        if ctxt.sender then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
        end
        return
    end

    local existingIndex
    if race.id == nil then
        local id = 1
        while table.any(M.data, function(r) return r.id == id end) do
            id = id + 1
        end
        race.id = id
    else
        local _, idx = table.find(M.data, function(r) return r.id == race.id end)
        existingIndex = idx
    end

    -- host-configurable, default OFF (services_config.data.RaceAuthorshipRestriction) : when on,
    -- non-staff editors may only touch races they authored themselves, staff bypasses this (same
    -- "staff reaches everything, others need their own specific grant" convention already used for
    -- the config window itself) ; when off (the default), anyone with EditRaces can manage any
    -- race, same as before this restriction ever existed. `author` is never trusted from the
    -- submitted payload regardless of this setting: preserved from the existing race on edit
    -- (unlike `leaderboard` right below, which is deliberately WIPED on every edit instead),
    -- stamped from the actual sender on creation, so a
    -- non-staff client can't just claim authorship of someone else's race by resubmitting it with a
    -- different `author` string even while the restriction itself is off. A pre-existing race saved
    -- before this field existed (author left nil) is staff-only to edit while the restriction is on,
    -- same as any other race whose real author isn't this sender: no legacy special-case.
    if existingIndex then
        local existing = M.data[existingIndex]
        if ctxt.sender and services_config.data.RaceAuthorshipRestriction and
            not services_permissions.isStaff(ctxt.sender.playerName) and
            existing.author ~= ctxt.sender.playerName then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
                services_lang.get("error.notRaceAuthor", ctxt.sender.lang))
        end
        race.author = existing.author
        -- Per direct request: editing a saved race always wipes its recorded times, not just when
        -- gates/layout actually changed. The editor warns about this beforehand (see the confirm
        -- dialog in windows/config/races/editor/app.js) whenever there was anything to lose, using
        -- the leaderboardCount onBJRequestCache computes for exactly that purpose
        race.leaderboard = {}
        race.leaderboardCount = nil -- derived/display-only, never actually persisted
        M.data[existingIndex] = race
    else
        race.author = ctxt.sender and ctxt.sender.playerName or "console"
        race.leaderboard = {}
        race.leaderboardCount = nil
        table.insert(M.data, race)
    end
    saveData()

    if ctxt.sender then
        -- explicit ack, mirroring activityConfig.lua's safeZonesSave pattern : the RX dispatcher
        -- discards a handler's return value, nothing relays it to the client on its own
        communications_tx.sendToPlayer(ctxt.senderID, "raceSaved", true, race.id)
    end

    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches, p.playerID)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)

    return race.id
end

---@param ctxt BJSContext
---@param raceId integer
local function raceDelete(ctxt, raceId)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditRaces) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end

    local race, index = table.find(M.data, function(r) return r.id == raceId end)
    if not index then return end

    if ctxt.sender and services_config.data.RaceAuthorshipRestriction and
        not services_permissions.isStaff(ctxt.sender.playerName) and
        race.author ~= ctxt.sender.playerName then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.notRaceAuthor", ctxt.sender.lang))
    end

    table.remove(M.data, index)
    saveData()

    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches, p.playerID)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

---@param raceId integer
---@return BJRace?
local function getById(raceId)
    return table.find(M.data, function(r) return r.id == raceId end)
end

--- System-triggered time submission (race finish), not the player-editing path: no permission
--- check, not routed through raceSave/sanitizeRace. Updates `playerName`'s own personal best for
--- this race if `time` beats it (or they have none yet) ; the overall "record" is just whoever
--- currently holds the lowest time across every player's own entry, not a separately-tracked value.
---@param raceId integer
---@param playerName string
---@param model string
---@param time integer best lap time (ms)
---@return boolean isNewPB, boolean isNewRecord
local function submitTime(raceId, playerName, model, time)
    local race = M.getById(raceId)
    if not race then return false, false end
    race.leaderboard = race.leaderboard or {}

    local previousBest = math.huge
    for _, entry in pairs(race.leaderboard) do
        if entry.time < previousBest then previousBest = entry.time end
    end

    local existing = race.leaderboard[playerName]
    local isNewPB = not existing or time < existing.time
    if not isNewPB then return false, false end

    race.leaderboard[playerName] = { time = time, model = model, date = GetCurrentTime() }
    saveData()
    return true, time < previousBest
end

---@param raceId integer
---@param limit integer? default 100
---@return {playerName: string, time: integer, model: string, date: integer, rank: integer}[]
local function getLeaderboard(raceId, limit)
    local race = M.getById(raceId)
    if not race or not race.leaderboard then return {} end
    limit = limit or 100

    local list = {}
    for playerName, entry in pairs(race.leaderboard) do
        table.insert(list, {
            playerName = playerName,
            time = entry.time,
            model = entry.model,
            date = entry.date,
        })
    end
    table.sort(list, function(a, b) return a.time < b.time end)
    for i, entry in ipairs(list) do
        entry.rank = i
    end
    while #list > limit do
        table.remove(list)
    end
    return list
end

---@param ctxt BJSContext
---@param raceId integer
local function onRaceLeaderboardRequest(ctxt, raceId)
    if not ctxt.sender then return end
    raceId = tonumber(raceId) or raceId
    local race = M.getById(raceId)
    if not race then return end

    local entries = getLeaderboard(raceId, 100)
    local selfEntry = table.find(entries, function(e) return e.playerName == ctxt.sender.playerName end)
    if not selfEntry and race.leaderboard and race.leaderboard[ctxt.sender.playerName] then
        -- own PB exists but fell outside the returned top N ; still worth showing, with a real
        -- rank computed against the full (untrimmed) leaderboard rather than just "> 100"
        local pb = race.leaderboard[ctxt.sender.playerName]
        local rank = 1
        for otherName, entry in pairs(race.leaderboard) do
            if otherName ~= ctxt.sender.playerName and entry.time < pb.time then
                rank = rank + 1
            end
        end
        selfEntry = {
            playerName = ctxt.sender.playerName,
            time = pb.time,
            model = pb.model,
            date = pb.date,
            rank = rank,
        }
    end
    communications_tx.sendToPlayer(ctxt.senderID, "raceLeaderboard", raceId, entries, selfEntry)
end

-- TEMPORARY debug tooling, for testing leaderboard formatting/pagination (top-100 cap, pinned
-- self-row, rank coloring) without needing 100 real players/attempts. Remove once no longer needed.
---@param args string[]
---@param printUsage fun()
local function consoleDebugLeaderboard(args, printUsage)
    local raceId = tonumber(args[1])
    local count = tonumber(args[2])
    local baseMs = tonumber(args[3])
    if not raceId or not count or not baseMs then return printUsage() end
    local race = M.getById(raceId)
    if not race then
        print("[BJ races] racedebugleaderboard: race not found: " .. tostring(raceId))
        return
    end
    race.leaderboard = race.leaderboard or {}
    for i = 1, count do
        local name = string.format("DebugPlayer%03d", i)
        race.leaderboard[name] = {
            -- spread around baseMs (+/- 5s) so ranks/times actually look varied, floored at 1ms
            time = math.max(1, math.floor(baseMs + math.random(-5000, 5000))),
            model = "Pickup - Sport",
            date = GetCurrentTime() - math.random(0, 60 * 60 * 24 * 30),
        }
    end
    saveData()
    print(string.format("[BJ races] racedebugleaderboard: injected %d fake entries into race %d (~%dms)",
        count, raceId, baseMs))
end

local function onInit()
    communications_rx.addHandler("raceSave", M.raceSave)
    communications_rx.addHandler("raceDelete", M.raceDelete)
    communications_rx.addHandler("raceLeaderboardRequest", M.onRaceLeaderboardRequest)
    communications_rx.addHandler("raceLegacyImportPreview", M.raceLegacyImportPreview)
    communications_rx.addHandler("raceLegacyImportConfirm", M.raceLegacyImportConfirm)

    services_consoleCommands.register("racedebugleaderboard", "<raceId> <count> <timeMs>",
        "inject <count> fake leaderboard entries around <timeMs> for <raceId> (debug)",
        consoleDebugLeaderboard)

    seedBundledRaces()
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData

M.getById = getById
M.submitTime = submitTime
M.getLeaderboard = getLeaderboard
M.onRaceLeaderboardRequest = onRaceLeaderboardRequest
M.raceSave = raceSave
M.raceDelete = raceDelete
M.raceLegacyImportPreview = raceLegacyImportPreview
M.raceLegacyImportConfirm = raceLegacyImportConfirm

return M
