# Changelog

All notable changes to BeamJoy Sandbox. The v1.3.0 entry was originally compiled against a real
file-by-file diff of this working directory against the last GitHub release (v1.2.0), not just
session memory, then kept up to date as work continued. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/). Server-side entries need separate deployment to
the live server per the usual workflow: see each entry.

## [1.8.77] - 2026-09-06

Client v1.8.77, server v1.8.61. Server-side change in this range needs deploying to the live
server separately; the client is a straight mod update.

### Added
- **New Infected Arena setting: "Hide infected nametags from survivors"** (Config > Infected
  Arena, off by default). Fixes a real bug: an infected participant's nametag was unconditionally
  colored by their role, visible to every viewer, so a survivor could tell exactly who's infected
  just from nametag color alone, trivially defeating the point of the mode. Turning this setting
  on hides an infected participant's whole nametag from survivor viewers specifically; staff,
  spectators, and other infected still see it normally. *(server + client)*

## [1.8.76] - 2026-09-06

### Fixed
- **Real bug: getting tagged (or otherwise respawning) mid-round could leave the camera stuck in
  free cam, with no manual camera switch able to reach a working one again.** A fresh vehicle
  object mid-round (the same respawn this repaint already accounts for) can leave BeamNG's camera
  system pointed at the old, now-destroyed vehicle, which the engine falls back to free cam for;
  nothing was re-targeting the camera at the new object afterward. Camera restrictions are now
  re-applied and reset the moment the new vehicle appears. *(client only)*
- **Real bug: the release-freeze delay at round start had no indicator at all.** Survivors and
  infected each freeze briefly at GAME start (the infected's built-in head start for survivors),
  but a held participant had no way to tell they were frozen on purpose rather than stuck. The HUD
  now shows "Held, released in Xs" for as long as the hold lasts. *(client only)*
- **Real bug: a participant's role color (Force role paint) only became visible once the
  countdown ended, instead of during it**, even though roles are already assigned and known the
  moment the countdown begins. Colors are now applied at countdown start. *(client only)*

## [1.8.60] - 2026-09-06 (server only, TEMPORARY)

Server v1.8.60. No client changes.

### Changed
- **TEMPORARY, for 2-player testing:** Infected's minimum participant count lowered from 3 to 2
  (`services_infected.MINIMUM_PARTICIPANTS`), so a 2-player lobby can actually reach GAME instead
  of being permanently blocked by the floor described in 1.8.75 below. Revert to 3 once real
  3+-player testing resumes; this is not meant to ship as a permanent lower floor. *(server only)*

## [1.8.75] - 2026-09-06

Client v1.8.75, server v1.8.59. Server-side change in this range needs deploying to the live
server separately; the client is a straight mod update.

### Fixed
- **Real bug: Infected never actually started even after both players readied up**, showing
  "Starting in 0s" that just sat there forever. Infected requires a real minimum of 3
  participants (Hunter's own floor is 2), so a 2-player lobby can never leave LOBBY no matter how
  long everyone waits, but the UI's countdown badge had no way to know that floor existed and
  happily ticked down to 0 regardless. The lobby now tells the client its actual minimum
  participant count, the countdown badge only shows once there are actually enough people to
  start, and a "Need more players to start (2/3)" message explains the wait instead.
  *(server + client)*

## [1.8.74] - 2026-09-06

### Fixed
- **Real bug: opening the Legacy Import preview (Hunter, Infected, or Races) crashed with
  "results.filter is not a function" whenever the scan found nothing to import.** An empty scan
  result is correctly sent from server to client as a JSON array, but the client then re-forwards
  it to the UI through BeamNG's own native `guihooks` bridge, a second, separate JSON encode pass
  that can't tell an empty Lua table was meant to be an array and turns it into a plain object
  instead. The UI's own "nothing to import" guard checked `results.length === 0`, which is
  `undefined` (not `0`) on a plain object, so it fell through to `.filter()` on a non-array and
  threw. All three preview handlers now check real arrayness first. *(client only)*

## [1.8.73] - 2026-09-05

### Fixed
- **Real bug: parked traffic vehicles spawned, and stayed, with their headlights on at night.**
  `automaticLights.lua` has no way to tell a parked car apart from moving traffic, both are the
  same `simple_traffic` model and `isAi` alone doesn't distinguish them: its periodic day/night
  sweep force-set headlights on every AI vehicle in the world, parked ones included, and a second,
  separate spot (its per-vehicle spawn hook) applied the player's own "Automatic Lights" preference
  to every vehicle this client spawned, again with no distinction between the player's own car and
  an AI one. The sweep now excludes traffic's own parked set, and the spawn hook now only ever
  touches the vehicle the player is actually driving. *(client only)*

## [1.8.72] - 2026-09-05

### Fixed
- **Traffic could still land a vehicle overlapping another one, mostly in multiplayer.** The
  spawn-point search already rejects any point within 15m of a known vehicle (further ahead of a
  fast-moving one), but that check runs before the point gets snapped to a random lane, and every
  connected player spawns their own traffic independently, so a spot that looked clear on one
  client can already be filled by another player's just-spawned vehicle before it network-syncs.
  The actual final position is now re-checked immediately before committing to it, and simply
  discarded (the existing retry loop tries again) rather than used, on a miss. *(client only)*

## [1.8.71] - 2026-09-05

### Fixed
- **Real bug found in live multiplayer testing: traffic vehicles braked to a stop the instant they
  spawned.** Traffic is spawned directly via `spawn.spawnVehicle` and then given
  `setAIMode("traffic")`, which only tells a vehicle's own vlua AI which personality to run.
  Actually driving it (route, speed target, steering, every frame) is native `gameplay_traffic.lua`'s
  job, and that logic only ever runs for vehicles registered into that module's own internal
  tracking via its `insertTraffic` call, which is also the only thing that flips its internal state
  from "off" to "on" in the first place. Spawning outside its own `activate()`/`spawnTraffic()` flow
  skipped that registration entirely, so every traffic vehicle had an AI mode set with nothing ever
  actually driving it. Each spawn now also registers itself the same way native's own `activate()`
  does per vehicle, so the vehicle actually gets driven from the moment it lands. *(client only)*
- **Real bug: `beamjoy_nametags`' per-frame update was the single largest source of garbage
  collection pressure in the mod**, showing up as the reported "massive lag while moving the mouse"
  and intermittent stutter, worse the more vehicles were in play (traffic included). It rebuilt a
  whole throwaway list through two freshly-allocated closures and a full extra array copy every
  single frame; both branches now use a plain loop with the exact same filtering logic and zero
  per-frame allocation. *(client only)*

## [1.8.70] - 2026-09-02

### Fixed
- **Infected's role-color repaint didn't survive a mid-round `reload_vehicle`.** Ordinary
  reset/recover keeps the same vehicle object, so the live paint override `enableColors` applies
  already survived those with no extra work (Infected deliberately has no reset penalty at all,
  unlike Hunter, so nothing here needed to hook resets themselves). A full reload is different: it
  creates a genuinely new vehicle object with none of that override and no snapshot of its own
  default color either. `onBJVehicleInstantiated` now also fires during `GAME` (previously
  early-returned for any state but `COUNTDOWN`), re-snapshotting and reapplying the current round's
  role color to a freshly-reloaded vehicle the same way a fresh round start already does.
  *(client only)*

## [1.8.69] - 2026-09-01

### Added
- **Infected's `enableColors` now actually repaints vehicles**, the one piece v1.8.68 shipped
  stored/exposed in the UI but never applied. Every participant's own client force-repaints its
  own vehicle (all 3 paint slots) to the current role's flat color at round start, and again the
  instant a survivor gets tagged, via the same `beamjoy_vehicles.paint()` call (and therefore the
  same BeamMP paint sync) traffic's own livery randomization already uses, so the repaint reaches
  every other player normally. The original color is restored the moment the round ends or the
  player leaves.

### Fixed
- **Real bug caught before it shipped further: the color-format mismatch this repaint work
  surfaced.** `<bj-color-picker>` only ever speaks hex strings, but the arena's `survivorColor`/
  `infectedColor` settings are plain `{r, g, b}` objects everywhere else in this codebase (what
  Lua's `BJColor` actually is). The arena editor's defaults panel now converts at its own edge
  (`services/settings.js`'s own identical `rgbToHex`/`hexToRgb` boundary conversion for nametag
  colors, reused via `beamjoyStore.utils`), and the client-side color lookup normalizes a
  plain `{r,g,b}` table (no metatable, since nothing server-sent ever reconstructs `BJColor`'s own
  methods) into a real `BJColor` instead of assuming one arrives ready-made.
  - Also fixed the snapshot source for the restore-on-round-end above: `beamjoy_vehicles.
    getFullConfig(veh).paints` is empty for the common case of a vehicle using its `.pc` file's own
    baked-in colors with no explicit runtime override recorded, which would have made the restore
    silently do nothing for most players. Reads the vehicle's real live color fields
    (`veh.color`/`colorPalette0`/`colorPalette1`) instead, the same snapshot source the standalone
    community "Outbreak" mod uses for this identical temporarily-recolor-then-revert case.
  *(client only)*

## [1.8.68] - 2026-09-01 (server v1.8.58)

### Added
- **Infected mode**, a new gamemode alongside Race and Hunter: a lobby of survivors (green
  nametags) starts with a random subset already infected (red nametags), who spread the infection
  by touching a survivor's vehicle; survivors win by outlasting a host-configurable round timer,
  infected win once every survivor is caught. Built as a close structural mirror of Hunter
  (`services/infected.lua` + `services/infectedGrid.lua` server-side, `infected.lua` +
  `infectedRunner.lua` client-side), reusing its exact LOBBY/COUNTDOWN/lock/freeze-release/
  restriction conventions rather than inventing a new shape, but trimmed to what Infected actually
  needs: no vehicle-pool/respawn-penalty/reveal system, and a genuinely new client-side two-tier
  proximity tag-detection loop (coarse cull every slow-tick, precise bounding-radius check every
  frame, deduped so a held touch doesn't spam the server) since Infected's win condition has no
  equivalent in Hunter's own waypoint-chase design.
  - Full UI: an in-world arena editor (survivor/infected spawn points, built on the same shared
    point-list-editor toolkit Hunter's own arena editor uses), a lobby/join window with live
    roster and per-infected tag counts, countdown and in-round HUD overlays, and a start-options
    panel (starting infected count, round length, asymmetric release delay, optional forced
    role-color repaint).
  - **Legacy BeamJoy Free (BJI) import**: reads the exact same `<map>_hunter.json` files Hunter's
    own importer already reads (BJI stores both modes' spawn points in that one file), a new row
    next to Hunter's own in Config > Core > Legacy Import.
  - New `EditInfectedArenas` permission (mod rank by default), gating both arena edits and the
    legacy import row, mirroring `EditHunterArenas` exactly.
  - One deliberate departure from BJI: a genuine host-configurable round timer for survivors to
    win by outlasting, since neither BJI's own client reference nor the standalone community
    "Outbreak" mod this design was cross-checked against expose one, and a mode where the only way
    to end is every survivor eventually getting caught felt like a real gap.
  - **Not yet wired up**: `enableColors`' vehicle-repaint behavior is stored and exposed in the UI
    but not yet applied client-side (nametag role-coloring works unconditionally regardless; only
    the optional flat vehicle-paint override is the deferred part). Untested against the real
    engine (no BeamNG access from this environment) : this is careful, closely-mirrored code
    against an already-shipped Hunter implementation, not confirmed-working via actual play yet.
    *(client + server, server needs deployment)*

## [1.8.67] - 2026-08-31

### Added
- **Race Share Codes.** The race editor (Config > Races) now has "Copy Share Code" and "Import
  from Code" buttons. Export serializes the currently-open race (name/mode/loopable/sectors/
  branching/gates/start positions/defaults, not id/author/leaderboard, and not any vehicle
  restriction capture since that's local to the exporting server), rounds every number to 3
  decimal places, gzips the compact JSON, base64-encodes it behind a `BJRACE1:` prefix, and copies
  the result to the clipboard entirely client-side (native `CompressionStream`/`btoa`, no bundled
  library). Import decodes a pasted code the same way and replaces the editor's in-progress race
  with it (confirming first if there's anything unsaved worth losing), but nothing about the
  imported data is trusted any further than a race authored from scratch would be: it still has to
  go through the existing `sanitizeRace` validation server-side the moment it's actually saved, no
  server-side change was needed for this at all. Scoped to races only for now, per the original
  design note; Hunter arenas weren't extended to this.

## [server 1.8.57] - 2026-08-30

### Fixed
- **Same "increments of 10m" gap as revealProximityDistance (server 1.8.56), found on the other
  two fields that make the same promise.** Searched the whole locale file for every tooltip
  promising a specific increment; `huntedResetDistanceThreshold` and `hunterNametagFadeDistance`
  are the only other two ("Increments of 10m."), and both had the exact same issue: their
  `services/hunter.lua` and `services/hunterGrid.lua` resolve steps only ever floored the value
  (at 0, since unlike revealProximityDistance both explicitly allow 0 to mean "disabled" per their
  own tooltips), never rounded it to 10. Both now round to the nearest 10, floor unchanged at 0.
  Other sliders with a non-1 step (`huntedStuckDistance` at 0.1, `gridTimeout` at 10 in both
  Hunter and Races) don't make an explicit increment promise in their own tooltips, so they're not
  the same class of bug and were left as-is. *(server only, needs deployment)*

## [server 1.8.56] - 2026-08-30

### Fixed
- **Real bug: Hunter arena's reveal distance wasn't actually guaranteed to be in 10m increments.**
  The Config UI's `bj-slider` widget for it (min 10, step 10) does correctly snap to 10m while
  actively dragging or typing in it (its own tooltip promises "Increments of 10m"), but that's
  purely a client-side widget behavior. The actual value used by gameplay resolves through
  `services/hunter.lua` (arena defaults) and `services/hunterGrid.lua` (per-session start
  overrides), and both only ever clamped it to a floor of 1 (`math.max(1, ...)`) with no rounding
  to 10 at all. Any value saved before that slider behavior existed, or set through any other
  path, silently kept whatever precision it already had and got used exactly as-is by the real
  proximity check (`hunterRunner.lua`'s `nearestHunterDist <= settings.revealProximityDistance`).
  Both resolve steps now round to the nearest 10 (floor raised to 10 to match the slider's own
  minimum) instead of just flooring at 1. *(server only, needs deployment)*

## [1.8.66] - 2026-08-30

### Fixed
- **Real bug: parked vehicles still ended up in the middle of the road after v1.8.65's spawn-time
  fix, for larger parked amounts (e.g. 10/player).** The actual cause was never at spawn time; it
  was `onRubberbandTick`, the moving-traffic relocation tick. A parked vehicle is still
  `simple_traffic` by model name, so the instant each one individually finishes registering
  (`onBJVehicleInstantiated`, well before the whole `"autoParking"` batch finishes) it's
  `isAi=true` and lands in `M.vehs` too, exactly like moving traffic. `M.onVehicleGroupSpawned`
  only claims the *entire* batch into `M.parkedVehs` once `core_multiSpawn.spawnGroup`'s own
  async job is completely done, and `updateVehs`' own `M.vehs`/`M.parkedVehs` reconciliation only
  runs at specific trigger points (settings changes, `BJReady`), not every tick. With a large
  batch (10 per player) taking a few seconds to spawn and `onRubberbandTick` firing roughly once a
  second, an early-registered parked vehicle could sit in `M.vehs`, unclaimed, long enough for a
  tick to treat it as moving traffic and teleport it via the road-graph spawn search instead of
  leaving it at its parking spot. `onRubberbandTick` now filters `M.parkedVehs` out of its
  candidate list directly (instead of trusting `M.vehs` to already be clean) and skips entirely
  while a parked batch is actively spawning (a timed flag, cleared early once
  `M.onVehicleGroupSpawned` confirms the batch actually finished, with a 15s ceiling as defense in
  depth against the same permanently-stuck-flag class of bug fixed for `spawnLock` earlier).
  *(client only)*

## [1.8.65] - 2026-08-30

### Fixed
- **Parked vehicles still occasionally spawned on the road after v1.8.63/v1.8.64's spot-count
  clamp.** Clamping the requested amount to a spot count found beforehand still left
  `gameplay_parking.setupVehicles` free to run its own internal `getRandomParkingSpots` search a
  second time when actually spawning, moments later. That second search can disagree with the
  first (map/vehicle state can shift between the two calls, or `filterParkingSpots`' own
  randomization can select a different subset), and if it comes up short, `setupVehicles` still
  falls back to `core_multiSpawn.spawnGroup`'s generic `"roadBehind"` mode exactly like before.
  `updateParkedVehs` no longer calls `setupVehicles` at all: it builds the spawn transforms
  directly from the exact spots already confirmed by its own check, and calls
  `core_multiSpawn.spawnGroup` itself (the same lower-level call `setupVehicles` makes
  internally, and the same `"autoParking"` groupName `gameplay_parking`'s own
  `onVehicleGroupSpawned` listens for to register the result into its own tracking), removing the
  second search, and the race, entirely. *(client only)*

## [1.8.64] - 2026-08-30

### Fixed
- **Real bug: v1.8.63's own parking-spot check regressed parked vehicles to never spawning at
  all.** `gameplay_parking.getRandomParkingSpots` bails out to an empty list
  (`if not sites then return {} end`) instead of loading that data on demand the way
  `setupVehicles` does; unlike `setupVehicles`, it never calls native's own `loadSites()` itself.
  `updateParkedVehs`' new pre-check called it directly, so on a fresh connect (before anything
  else had triggered a load) every request saw zero spots and clamped to 0, silently disabling
  parked vehicles entirely instead of just avoiding the road-placement fallback. Now calls
  `gameplay_parking.getParkingSpots()` first (its own `if not sites then loadSites() end` is
  exactly what native's own tooling relies on to trigger this), which guarantees `sites` are
  loaded before the real spot-count check runs. *(client only)*

## [1.8.63] - 2026-08-30

### Fixed
- **Real bug: parked vehicles spawning in the middle of the road.** Native's own
  `gameplay_parking.setupVehicles` only builds real parking-spot placements when its own internal
  search finds at least as many usable spots as requested (`if psList[amount] then transforms =
  {...} end`); short of that, it doesn't reduce the count or skip spawning, it silently falls
  through to `core_multiSpawn.spawnGroup`'s generic `"roadBehind"` placement mode instead, putting
  every vehicle in that batch along the road rather than at an actual parking spot. This happened
  on any map with fewer usable parking spots nearby than the requested parked amount.
  `updateParkedVehs` now checks the actual usable spot count first, via
  `gameplay_parking.getRandomParkingSpots` with the exact same filters `setupVehicles` uses
  internally, and clamps the request to it, so the request never crosses into that fallback path.
  *(client only)*

## [1.8.62] - 2026-08-30 (server v1.8.55)

### Added
- **License plate controls for traffic**, ported from Agent's Traffic Tool and scoped to the parts
  of it that don't require detecting a specific third-party plate mod: front plate usage
  (Normal/None/Random), plate shape (native US square / EU wide, swapped via each config's own
  `_licenseplate_F/R_US`/`_EU` alternate parts), and a plate design dropdown. The design list is a
  real scan (`FS:findFiles` + jbeam parse over `/vehicles/common/` for any part tagged
  `licenseplate_design_2_1`), the same method Agent's own tool uses, not a preset list, so it stays
  accurate as new plate-design content gets installed. Shape intentionally stops at native US/EU:
  unlike design, a plate *shape* is a genuinely different jbeam part per mod, not a different skin
  of the same slot, so there's no way to discover a new shape by scanning, only by hardcoding a
  specific mod's naming scheme the way Agent's own tool does per-shape; going beyond native US/EU
  would mean maintaining that same kind of mod-specific list. Implemented by loading each spawned
  vehicle's base `.pc` config, mutating its `parts` table, and passing the resulting table (rather
  than a file path) to `spawn.spawnVehicle`, which native's own `spawn.lua:setVehicleObject`
  already supports (serializing a table the same way it would read one from disk) - confirmed by
  reading the engine source, not assumed. Applies to moving traffic only; parked vehicles spawn
  through native's own separate `gameplay_parking` pipeline, which doesn't offer the same hook.
  *(server-side services/traffic.lua and services/config.lua changes need deployment)*

## [1.8.61] - 2026-08-30 (server v1.8.54)

### Added
- **Per-source rarity weighting for traffic.** Config -> Traffic's model list now shows a Rarity
  slider (0-100%, plus Rare/Medium/Common quick-set buttons, matching Agent's own Traffic Tool
  convention) next to each selected source once more than one is selected. `createGroup` now picks
  a source (raw model or vehGroup) weighted by this value first, then a config uniformly within
  that source, instead of pooling every config from every source together where a large pack (e.g.
  128 configs) would dominate a small one (e.g. 5) purely by config count. Defaults to 100
  (Common) for any source without an explicit weight, so nothing goes quiet unless deliberately
  turned down. *(server-side services/traffic.lua and services/config.lua changes need deployment)*

## [1.8.60] - 2026-08-30

### Fixed
- **Real bug: traffic content from a vehGroup whose model name doesn't contain "traffic" (e.g.
  SimpleNG's SNG_120a, SNG_510, ...) broke traffic entirely once spawned.**
  `beamjoy_vehicles.lua`'s `isAi(model)` decides whether a spawned vehicle counts as AI-controlled
  traffic purely by checking whether its model name contains the substring "traffic"; it has no
  idea a vehGroup even exists. For a model that doesn't follow that naming convention,
  `registerVehicle` misclassified the spawn exactly like the local player spawning their own car:
  it left `playerUsable` true, force-exited free cam, applied respawn protection to a car nobody
  is driving, and attributed local ownership to it, which is why it showed an orange "You"
  nametag. Separately, `traffic.lua`'s own spawn loop waits for the just-spawned vid to land in
  `M.vehs`, which only happens via the same `isAi` classification, so with it wrongly false that
  wait span forever, leaving the loading overlay up and (more seriously) leaking `spawnLock = true`
  forever, which permanently blocked every later traffic setting change from taking effect until a
  restart. Added `beamjoy_vehicles.markVehicleAsAi(vid)`, a per-vid override any spawner can call
  immediately after spawning a vehicle it knows is meant to be AI regardless of its model's name;
  `traffic.lua` now calls it right after every traffic spawn. Also bounded the spawn loop's own
  wait to 10s as defense in depth, so any future gap of the same shape fails gracefully (releasing
  `spawnLock`) instead of wedging the whole traffic system again. *(client only)*

## [1.8.59] - 2026-08-30 (server v1.8.53)

### Added
- **Parked vehicles and population/region "Smart Selection" for traffic.** Two additions to the
  Config -> Traffic panel, both requiring the server-side update too (v1.8.53):
  - **Parked vehicles**, sourced exclusively from stock simple_traffic's own dedicated "_parked"
    configs (e.g. `bastion_base_parked.pc`), which `beamjoy_vehicles`' regular config scan
    deliberately excludes. Placed via native's own `gameplay_parking` extension, using real
    hand-authored parking-spot markers on the map, not the road-graph search moving traffic uses,
    so they won't appear on maps without that data, same as native single-player. Gets its own
    independent amount/max-per-player budget and per-player server-side balancer (mirroring the
    existing moving-traffic one, generalized into a shared `computeBalancer` helper server-side),
    separate from the moving-traffic total so it doesn't compete for the same slots. Unlike moving
    traffic, `gameplay_parking.setupVehicles` has no incremental "spawn N more" primitive, so a
    parked-count change always fully replaces this client's own current parked set rather than
    diffing it.
  - **Smart Selection**, a toggle mirroring native's own "Smart Selection" traffic setting:
    weights which config gets picked by each stock config's real `Population`/`Region` metadata
    (e.g. `info_bastion_base.json`: `{"Population":10000,"Region":["northAmerica"]}`), instead of
    picking uniformly at random, biasing toward whatever's actually common for the current map's
    own region. Only appears in Config when `simple_traffic` is the sole selected traffic source,
    since third-party vehGroups/models generally don't carry that same metadata; applies to both
    moving and parked vehicle selection. *(server-side services/traffic.lua and services/config.lua
    changes need deployment to the live server)*

## [1.8.58] - 2026-08-30

### Fixed
- **Real bug: vehGroup traffic bundles added in v1.8.57 never showed up for BeamMP server mods
  (Resources/Client), only for mods already active at game boot.** `scanVehGroups()` only ran once,
  from `traffic.lua`'s own `onInit`, which fires at GE extension load, before a BeamMP server mod
  (like a Resources/Client traffic pack) has necessarily been downloaded and mounted by
  `MPModManager` during the actual connection. `beamjoy_vehicles` already solves the identical
  problem for its own vehicle/config scan via a custom `onBJVehicleModChanged` event
  (`ge/extensions/mods.lua`, hooked into `MPModManager.onModActivated`/`onModDeactivated`), but
  `traffic.lua` was never wired into it. Added an `onBJVehicleModChanged` handler that rescans
  vehGroups, so a server-provided traffic pack's groups now appear once it actually mounts instead
  of only if it happened to already be active before the game finished loading. *(client only)*

## [1.8.57] - 2026-08-30

### Added
- **Support for native BeamNG "Vehicle Group" (`*.vehGroup.json`) traffic bundles.** BJS's traffic
  system previously only picked spawns from raw model names configured in Config -> Traffic
  (`M.data.models`), scanning every config a whitelisted model happens to have. It had no support
  at all for `.vehGroup.json` files, BeamNG's own format for a curated, named list of specific
  `{model, config, paintName}` combos (used e.g. by third-party regional/themed traffic packs that
  reuse a shared model like `simple_traffic` with only a subset of its configs, rather than
  shipping a whole new model). `traffic.lua` now scans `/vehicleGroups/**/*.vehGroup.json` at init
  (mirroring native's own `trafficUtils.lua:getTrafficGroupFromFile` discovery convention) and
  lists each discovered group as an extra selectable entry in the existing Config -> Traffic
  models list, prefixed internally so it can't collide with a real model name; no changes needed
  to the Config UI itself, since it already treats that list as a generic key/label multi-select.
  Selecting a vehGroup is additive: its curated entries become one more pool the random spawn pick
  draws from, alongside whatever raw models are also selected, and an explicit non-"random"
  `paintName` in a vehGroup entry now overrides the primary paint slot instead of always
  re-randomizing it. *(client only)*

## [1.8.56] - 2026-08-30

### Fixed
- **Reduced remaining pop-in after v1.8.55.** `getNewRandomSpawn` computed `targetDist` (the
  point past which `findSafeSpawnPoint`'s search stops requiring a candidate be hidden from the
  camera) as 25% into the speed-scaled min/max search band. Native's own call site for this exact
  function uses the band's midpoint instead (`clamp(lerp(minDist, maxDist, 0.5), 120, 500)`), so
  BJS was giving up on requiring a hidden spawn spot noticeably sooner than native itself does with
  the same underlying search. Matched native's midpoint convention. Some residual pop-in on long,
  unobstructed straight roads is inherent to any on-demand spawn system and can't be fully
  eliminated without a much larger vehicle budget or a genuine dormant vehicle pool, which BJS
  doesn't have (each traffic vehicle is a real BeamMP-synced entity, unlike native's local-only
  pool). *(client only)*

## [1.8.55] - 2026-08-30

### Fixed
- **Traffic still sparse and now also popping in visibly at speed, after v1.8.53/v1.8.54.** Root
  cause was the spawn-point search method itself: `getNewRandomSpawn` called
  `trafficUtils.findSpawnPointRadial` directly, a raw "somewhere within a ring" search that can
  land a vehicle on any nearby road segment, including one behind the player, a side road, or one
  that curves into direct view around a bend or over a rise. BeamNG's own native traffic never
  uses that function for its actual live spawn maintenance; it uses `findSafeSpawnPoint`, which
  tries a route generated along the road graph ahead of the player's travel direction first, and
  only falls back to a radial search if no point on that route validates. Both methods share the
  same camera-occlusion check (a candidate must be hidden from view unless past a target distance,
  which BJS sets to only ~25% into its speed-scaled min/max band), but without route-ahead
  placement, most candidates fell outside that narrow hidden window and could pop straight into
  view, while cars placed on unrelated nearby roads were simply never driven past. Switched
  `getNewRandomSpawn` to call `findSafeSpawnPoint` instead, matching what native traffic actually
  uses. *(client only)*

## [1.8.54] - 2026-08-30

### Fixed
- **Real bug: AI traffic still stayed sparse at high speed after v1.8.53's spawn-direction fix.**
  Two compounding issues in `onRubberbandTick`: (1) the server only fires a
  `trafficRubberbandTick` event to a given player at most once per second (`onSlowUpdate`,
  round-robined across players who own traffic), and the client only rubberbanded a single
  out-of-range vehicle per tick, no matter how many actually needed it; at 100+ mph a player can
  leave several owned traffic vehicles beyond max distance in the same second, but only one got
  repositioned, leaving the rest invisible out of range for multiple seconds. (2) the "pick the
  furthest vehicle" selection was dead code: its `distance` accumulator was initialized to `0` and
  only updated via `if dist < distance`, but `dist` (a max-distance value) is always positive, so
  the condition was never true and every candidate tied at `0`, making the "sort by furthest
  first" pick effectively arbitrary. Now rubberbands every vehicle that's out of range in a single
  tick instead of one, and drops the broken distance-sort entirely since it's no longer needed.
  *(client only)*

## [1.8.53] - 2026-08-30

### Fixed
- **AI traffic felt sparse while driving, fine while parked.** `traffic.lua`'s spawn placement
  (`getNewRandomSpawn`) always called `findSpawnPointRadial` with `pathRandomization = 1`
  (fully random road direction), regardless of the observing player's speed. Compared against
  BeamNG's own native traffic system (`gameplay/traffic.lua`), which scales that same parameter
  down as speed increases so spawns get biased ahead of the player's travel direction, BJS never
  carried that scaling over, even though its own code comments cite the native functions it was
  modeled on. Combined with `getMinMaxDistFromPlayer`'s existing min/max spawn-distance band
  widening at speed, spawns kept landing uniformly all around the player at any speed, so most of
  the fixed traffic budget (`total`/`maxPerPlayer`) ended up behind or beside the player and was
  never actually driven past, reading as "traffic disappeared" once moving. Added
  `getPathRandomization(speed)`, mirroring the existing `getMinMaxDistFromPlayer` speed-scale
  convention (1 at 20 km/h and below down to 0.15 at 200 km/h and above), and wired it into both
  `getNewRandomSpawn` origin branches. *(client only)*

## [1.8.52] - 2026-08-29

### Fixed
- **Real bug: "random" grid placement never teleported anyone to their start position.**
  `beginCountdown`'s random branch shuffled the participant list via `table.shuffle`, which
  deep-CLONES its input (`table.clone` all the way down) before shuffling, so the slot-assignment
  loop wrote every `startPosition` onto throwaway copies while the real session participants
  never received one. Each client then hit raceRunner.lua's "no start position to teleport to"
  fallback and stayed wherever it was. Deterministic/manual modes were unaffected (`values()`
  rebuilds the array but keeps real references; no clone involved). Now shuffles in place with a
  plain Fisher-Yates over the values array. Verified under the server-side test harness: the
  regression test asserts every REAL participant record ends countdown holding a distinct grid
  slot, and fails on the previous code exactly as reported. *(server only, needs deployment)*

## [1.8.51] - 2026-08-29

### Fixed
- **Real bug: manual grid-slot assignment (v1.8.50) never actually applied.** Picking a new slot
  in the lobby's per-player dropdown showed the change for about a second, then reverted, with or
  without a collision. Root cause was client-side, in `bj-select`'s ng-change plumbing (this was
  the first consumer of it): the component invoked its `&` callback with a positional argument,
  which Angular `&` bindings ignore, so the caller's expression read the slot back off its own
  two-way-bound `player.gridSlot`, which still holds the OLD value at the instant ng-change
  fires (the binding's write-back to the parent scope runs later in the digest). The client
  therefore sent the player's current slot to the server, which correctly treated "already on
  that slot" as a no-op, and the once-a-second lobby status tick then repainted the authoritative
  (unchanged) state: exactly the observed show-then-revert. Server-side placement logic
  (seeding, swap, free move, countdown assignment) was verified correct under a test harness,
  including 0-based player IDs and float-typed wire arguments. Fixed by having `bj-select` expose
  the freshly picked value to its ng-change expression as a named local (`value`) and sending
  that; also `track by player.playerID` on the lobby player list so those rows (and an open
  dropdown) survive the once-a-second status pushes instead of being torn down and rebuilt every
  tick. *(client only, no server changes)*

## [1.8.50] - 2026-08-28

### Added
- **Race grid placement strategies**, contributed by Bytestorm5 via
  [PR #1](https://github.com/foodcache3/BeamJoy-Revived/pull/1) (originally opened and tagged
  v1.8.48-v1.8.50 upstream; renumbered here to 1.8.50-1.8.52 to land after this fork's own
  v1.8.48/v1.8.49 below, which used those same numbers for unrelated work first). How starting
  slots are assigned when a race's countdown begins is now a real, host-configurable choice
  (per-start option in the start panel, per-race default in the race editor's Settings section,
  only shown for multi-slot races): **Join order** ("deterministic") places players in the order
  they joined the lobby, host first; **Random** (the new default) shuffles the field; **Manual**
  lets the host assign each player's slot from the lobby player list (a dropdown per player,
  visible to the host while the lobby is open; picking a slot someone else holds swaps the two, so
  a full grid can be freely rearranged; everyone else sees their assigned slot number next to each
  name). Previously there was no policy at all: slots followed `pairs()` iteration order over the
  participants table (keyed by playerID), i.e. roughly server-connection order by accident and
  formally arbitrary, which is also why "Random" rather than the old behavior is the new default,
  nothing reproducible existed to preserve. Manual assignments are auto-seeded join-ordered so the
  host only has to touch what they want changed, and the countdown falls back to filling free slots
  in join order for anyone left unassignable (defensive only; the lobby always maintains a complete
  assignment). *(client + server, needs deployment)*

## [1.8.49] - 2026-08-29

### Fixed
- **Real bug: a hard game crash (native C++ crash, not a catchable Lua error) could happen right
  after a race ends.** Confirmed from a user-supplied `beamng.log`: the crash landed inside the
  engine's own vehicle-construction code (`finishConstructionGESide`), immediately after another
  player's vehicle had just been destroyed, right as `raceRunner.lua`'s `restoreSavedVehicle()`
  synchronously spawned the player's own pre-race car back in, from inside a network-message
  handler mid-frame. Matches the same "let the engine settle first" issue class already found and
  fixed elsewhere in this file for reset-teleports: triggering another native vehicle spawn while
  the engine is still mid-way through processing a prior vehicle event can crash it outright.
  Deferred the actual spawn by one short async tick so the engine has a chance to finish first,
  same pattern already used for that teleport fix. *(client only)*

## [1.8.48] - 2026-08-29

### Fixed
- **Real bug: nametag rendering could crash with a FATAL LUA ERROR spam right after connecting to
  a server.** `nametags.lua` had four call sites that indexed `beamjoy_players.getSelf()` directly
  (`.playerName`/`.playerID`), assuming it always returns the local player's own record. For a
  short window right after connecting, before the server's own player-list push has landed,
  `getSelf()` legitimately returns nil, while other players' vehicles can already be drawing
  nametags every frame. That produced a repeating "attempt to index a nil value" error at
  `nametags.lua:113` (and the other three call sites), tens of times a second until the player list
  arrived, confirmed in a user-supplied `beamng.log`. Fixed by treating "self not loaded yet" as
  "not self" at each call site instead of indexing nil. *(client only)*

## [1.8.47] - 2026-08-27

### Changed
- **Repo renamed to BeamJoy-Revived** (github.com/foodcache3/BeamJoy-Revived), to distinguish this
  fork from the original BeamJoy Sandbox it started from. Updated the in-game Settings window's
  GitHub link and the README's title/download link to match. Internal naming (`beamjoy`, `BJ`/`BJS`
  throughout the codebase) is unchanged; this is a repo/branding-only update. *(client only, no
  server changes)*

## [1.8.46] - 2026-08-27

### Fixed
- **Real bug: `west_coast_usa_races.json`'s bundled content had a trailing comma before its
  closing bracket, making it invalid JSON.** Confirmed severity, not just a west_coast_usa
  problem: `seedBundledRaces()` loops over every map's bundled file in one pass, and this
  codebase's own JSON parser raises a real Lua error on malformed input rather than returning
  nil/false. Left unguarded, that error propagated all the way up through `services_races.onInit`,
  which calls `seedBundledRaces()` immediately before its own `loadData()` call in the same
  function body ; an uncaught error partway through aborts the rest of that function too, so
  `loadData()` never runs and the current map's actual races silently never load into memory at
  all on that boot, not just west_coast_usa's bundled races going unseeded. Fixed the file itself,
  and hardened `dao/main.lua`'s `get()` with a `pcall` around the JSON parse so any future
  malformed file (bundled or admin-authored) fails to load just that one file, logged clearly,
  instead of taking the rest of that boot's initialization down with it. Every other bundled
  race/hunter arena file (149 races, 6 hunter arenas across 12 maps) was checked against the
  actual save-time validation rules (`sanitizeRace`/`sanitizeArena`) and found structurally clean
  otherwise: no invalid gates/start positions, no hunter arenas below the enable minimums, no
  dangling references to a vehicle preset id that won't exist on a fresh server. *(server only,
  needs deployment)*

## [1.8.45] - 2026-08-27

### Fixed
- **Real bug: the vehicle-next-to-name display added in v1.8.42 never actually showed up anywhere**,
  regardless of solo vs. multiplayer. The Angular templates were updated to display `vehicleModel`,
  but the two client-side functions that actually build the data those screens receive
  (`raceRunner.lua`'s `pushSessionStatus`, feeding the lobby player-list, and `pushRaceInfo`,
  feeding both the Live and Results race info screens, since Results reuses the same payload) each
  hand-pick which participant fields to forward, and neither list included `vehicleModel`, so it
  was silently dropped every time before ever reaching the UI. Found and fixed the identical bug
  in `hunterRunner.lua`'s own equivalent lobby push too. *(client only, no server changes; the
  server side already tracked and sent this correctly)*

## [1.8.44] - 2026-08-27

### Fixed
- **Real bug, same root cause as v1.8.42's height-handle drag fix, one level up: a race gate (or
  a hunter arena point marker) couldn't be clicked to select in the world at all while looking
  steeply upward at it with open sky behind it.** `inputs.lua`'s shared `onBJClick` hook only ever
  fired when its own raycast against real world geometry actually hit something ; looking at open
  sky means that raycast finds nothing, so the hook never fired, and the click-to-select logic in
  `raceEditor.lua`/`pointListEditor.lua` (used by the hunter arena editor's own point-list
  selection) never even ran, let alone with an unusable position. Fixed at both ends: `inputs.lua`
  now fires the hook regardless (`pos`/`distance` simply nil on a miss, which existing hit-dependent
  consumers like the vehicle context menu already handle safely), and gate/point selection no
  longer needs a hit position anyway, since it already does its own ray↔plane / ray↔point math
  against authored world-space positions. The camera-ray math this needs (mouse position -> world
  ray, independent of hitting anything) already existed as a local helper in `raceEditor.lua` for
  the earlier handle-drag fix ; promoted it to `camera.lua` as `camera.mouseRay()` so both editors
  share one implementation. *(client only, no server changes)*

## [1.8.43] - 2026-08-27

### Fixed
- **Real bug: the hunter arena editor's toolbar still didn't stay pinned at the top**, despite
  last round's fix. The CSS added for it targeted the selector `bj-config-hunterarena`, but the
  component is actually registered as `bjConfigHunterArena`, which AngularJS normalizes to the
  custom element `bj-config-hunter-arena` (hyphen between "hunter" and "arena"). The selector
  never matched anything, so none of the pinned/scrolling flex layout rules ever applied. Fixed
  by correcting the selector. *(client only, no server changes)*
- **Real bug: last round's gate height increase (to 30, hard cap 60) only updated the Config
  window's slider.** The in-viewport 3D drag handle used to resize a gate directly in the race
  editor is a separate system (`raceEditor.lua`) with its own hardcoded cap, still at 15 while the
  width handles right next to it were already at 30. Raised to match. *(client only, no server
  changes)*

### Changed
- **Starting a race from the Activities tab now hides every other race in the list** (and the
  open-sessions list) while its start options panel is open, showing only the race being
  configured until Cancel is pressed, instead of leaving the options panel buried inline in a
  long scrolling list of unrelated races. *(client only, no server changes)*

## [1.8.42] - 2026-08-26

### Fixed
- **Real bug, per direct report: a branching, loopable race could be lap-counted by crossing the
  start/finish line, backing up, and crossing it again, with zero real progress in between.** The
  loop-closing bypass added for step-1 gates (making them unconditionally reachable so a race
  doesn't need an explicit backward parents-link) accepted every step-1 crossing regardless of the
  participant's actual position, so two crossings back-to-back both passed it, and the
  already-crossed flag from the first one made the second register as a genuine completed lap.
  Fixed by also requiring `currentGate ~= step` for the bypass: false only immediately after a
  step-1 crossing with nothing else crossed since, which now correctly falls through to the
  normal parents-check and gets rejected as a no-op instead. A real lap (at least one other gate
  crossed since) is unaffected. *(server only, needs deployment)*
- **Hunter/prey spawn-on-roof fix applied to races too.** `setVehiclePositionRotation`'s default
  `cling=true` re-snaps to the nearest surface below via a ray starting 10 units above the target,
  which can land a vehicle on top of a covering structure (an awning, a tunnel ceiling, a roof)
  instead of the actually-authored position if one happens to sit underneath. `hunterRunner.lua`
  already passes `cling=false` at its own spawn-teleport call sites for exactly this reason ;
  `raceRunner.lua`'s three own teleport call sites (grid start, and both last-checkpoint respawn
  paths) never did. All three now do. *(client only, no server changes)*

### Added
- **Hunter arena editor's translate/rotate/snap-to-ground toolbar now stays pinned at the top
  while scrolling**, matching the race editor's own already-established layout. Split out of
  `bjPointListEditor` into a new standalone `bjPointListEditorToolbar` component (both stay in
  sync purely via the same `$rootScope` broadcasts they already used, no direct coupling), since
  the toolbar and the point-list rows needed to live in separate pinned/scrolling regions.
- **A player's currently-selected vehicle now shows next to their name** in the race lobby, the
  Hunter lobby, and both race info screens (Live and Results). The data (`participant.vehicleModel`)
  was already tracked server-side and already reaching the client, just never actually displayed
  anywhere until now.
- **Maximum gate height increased** from 15 (hard cap 30) to 30 (hard cap 60), matching gate
  width's own existing scale.

### Changed
- **"Multiplayer" is now the topmost option** in both the race editor's own defaults section and
  the in-game start-options panel, per direct request: the single most consequential option in
  either screen (solo/private vs a real lobby others can join).
- **Scroll-wheel-to-adjust removed from sliders entirely**, per direct request: scrolling a
  settings page whose cursor happened to pass over a slider silently changed its value along the
  way. Sliders are now purely drag/click/type.
- Version bumped to 1.8.42 (buildversion 2298) on both client and server, `UI_BUILD` kept in sync.

## [1.8.41] - 2026-08-26

### Added
- **Bundled default race/hunter arena seeding now logs what it actually did, per direct request
  ("how can I be sure they'll be applied").** `seedBundledRaces`/`seedBundledHunterArena` (see
  1.8.33) ran completely silently before, the only way to confirm a bundled race/arena actually
  landed was to dig through `BeamJoyData/db/activities/` or the ledger file by hand. Each one now
  logs a clear line to the server console the moment it actually happens: a successful seed, a
  skip because a race/arena by that name already exists on that map, or a validation failure
  (already logged as an error before this, kept as-is). Nothing to see yet since no content is
  bundled, this just makes the next real addition to `bundledContent/activities/` immediately
  confirmable in the console on the boot after you add it and restart. *(server only, needs
  deployment)*

### Changed
- Version bumped to 1.8.41 (buildversion 2297) on both client and server, `UI_BUILD` kept in sync.

## [1.8.40] - 2026-08-26

### Fixed
- **Removed a stray leftover debug `console.log` in `player-line/app.js`** that printed every
  player's name and resolved current-vehicle-owner on every update, cluttering the CEF console
  for every player. Found while investigating a live report (missing teleport options, broken
  spectate-by-name, orange nametag, all for the same player): its output was the evidence that
  actually pinned down the real bug, that player's `currentVehicle` field was never syncing from
  their own client, staying `null` across two full reconnects and multiple vehicle spawns. The
  underlying sync issue itself is still under investigation (needs a log from that player's own
  client to trace further, this client only observes it over the network), this entry is just the
  debug-code cleanup. *(client only, no server changes)*

### Changed
- Version bumped to 1.8.40 (buildversion 2296) on both client and server, `UI_BUILD` kept in sync.

## [1.8.39] - 2026-08-26

### Changed
- **Big Map is now blocked at the real source during a race/Hunter lock, not just its camera.**
  The previous approach only ever blocked the "bigMap" camera NAME via `camera.lua`'s reactive
  poll (one frame late at best, and native code changes the camera directly, a path that wrapper
  never sees at all, so it could only clean up after big map had already started opening). Found
  a much cleaner native hook by reading the installed game's own `freeroam/bigMapMode.lua`:
  `enterBigMap` is the true common funnel every real entry path goes through (the default keybind,
  the quick-access menu's map icon, which calls it directly and bypasses the keybind's own separate
  check entirely, career code), and it already refuses outright if
  `gameplay_missions_missionManager.getCurrentTaskdataTypeOrNil()` returns anything truthy, the
  same check a vanilla mission/scenario already relies on to block big map for itself. That
  function has exactly one caller in the entire game, so `bigmap.lua` now wraps it (same
  wrap/rollback pattern already used there for 3 other native functions) to also return truthy
  while `raceRunner.lua`/`hunterRunner.lua` report a race/hunt lock, covering every entry path at
  once with zero side effects elsewhere. The existing camera-level block stays in place too, as a
  second, independent layer. *(client only, no server changes)*
- Version bumped to 1.8.39 (buildversion 2295) on both client and server, `UI_BUILD` kept in sync.

## [1.8.38] - 2026-08-26

### Added
- **Camera auto-centers when control is handed back after a race/Hunter countdown.** Camera
  control returns to the player a few seconds before the actual start (`CAMERA_RELEASE_SECONDS`),
  and free-looking an orbit camera around during that window used to leave it wherever it was
  rotated once the vehicle actually unfroze, instead of facing forward. New `camera.resetCamera()`
  wrapper (`core_camera.resetCamera(0)`, confirmed against the installed game's own
  `core/cameraModes/orbit.lua`: its `reset()` snaps rotation back to `defaultRotation`, directly
  behind the vehicle) is now called right after both `raceRunner.lua`'s and `hunterRunner.lua`'s
  own `restorePreviousCamera()` restores the player's camera. Safe regardless of which camera mode
  actually ends up active, `core_camera.resetCamera` just delegates to whatever that mode's own
  `reset()` does (or no-ops if it doesn't define one). *(client only, no server changes)*

### Changed
- Version bumped to 1.8.38 (buildversion 2294) on both client and server, `UI_BUILD` kept in sync.

## [1.8.37] - 2026-08-26

### Fixed
- **Real bug, per direct follow-up report with the actual source data attached: the 1.8.36 fix
  didn't resolve it, gates still came in rotated at strange angles, even on a genuinely
  non-branching race.** The real root cause was upstream of the loop-rewiring fixed in 1.8.36:
  `convertLegacyRaceGates` always ignored BJI's own waypoint `rot` for gates outright, deriving a
  direction from the route's own topology instead (a straight chord to this gate's own next
  waypoint). Checked against the reported race's real exported data: BJI's waypoints are
  frequently 60-300m apart on a circuit that curves between them, so a straight chord routinely
  points nowhere near the actual local road heading at the gate itself, by as much as ~90 degrees
  off on that same real race. `rot` (via `quatToFlatDir`, the same helper this file's own
  `convertLegacyStartPositions` and Hunter's own spawn import already trust for the identical
  purpose) is now used directly whenever present ; the old topology-derived heuristic is kept only
  as a fallback for a gate genuinely missing usable rot data. A previously-imported race isn't
  automatically fixed (Legacy Import is non-destructive/additive, and a same-named re-import is
  skipped as a duplicate, not overwritten), delete the affected race first, then re-run Legacy
  Import to get a freshly, correctly-oriented copy. *(server only, needs deployment)*

### Changed
- Version bumped to 1.8.37 (buildversion 2293) on both client and server, `UI_BUILD` kept in sync.

## [1.8.36] - 2026-08-26

### Fixed
- **Real bug, per direct report with a screenshot: the Legacy Import (BJI) race importer's gates
  sometimes came in rotated at strange, skewed angles**, specifically for a loopable race with
  multiple parallel start/finish lanes (e.g. a dual-lane grid, each lane ending at its own
  physically-separate finish checkpoint). The loop-closing rewrite (`convertLegacyRaceGates`,
  which promotes the terminal gate(s) to the new genesis/step-1 so the start/finish line always
  sits at gate 1) used to connect EVERY genesis gate to EVERY terminal, a full bipartite
  cross-product, whenever more than one of either existed, instead of only its own lane's actual
  terminal. `deriveLegacyGateDirections` then averaged each terminal's direction across ALL
  genesis gates as children, including ones never actually reachable from it, pulling a lane's own
  start/finish gate diagonally toward a completely unrelated lane's next checkpoint instead of
  pointing straight down its own lane, exactly the skewed/kite-shaped gates in the report. Fixed by
  only connecting a genesis gate to the terminal(s) actually reachable from it, computed via a
  forward BFS over the original (pre-rewire) parent chain before any parents get rewritten. A
  single-lane loop (the common case) is unaffected either way, since there's only ever one genesis
  and one terminal to connect regardless. *(server only, needs deployment ; re-running Legacy
  Import again picks up the fix for any race still affected, since import is non-destructive and
  additive)*

### Changed
- Version bumped to 1.8.36 (buildversion 2292) on both client and server, `UI_BUILD` kept in sync.

## [1.8.35] - 2026-08-26

### Added
- **"Limit visible gates" now works for branching races too, not just linear ones.** Previously
  forced off outright the moment a race had `branchingEnabled` on: the old computation
  (`visibleGateSet`) was a plain "index + i" walk, which has no defined meaning once a route can
  fork (which branch's "next N" do you even walk?), so the server zeroed the setting and the UI
  hid the toggle entirely for a branching race. `raceMarkers.lua` now has a real branching-aware
  equivalent, `visibleGateSetBranching`: instead of a linear index, it walks the race's actual
  `parents` graph breadth-first, `visibleGateCount` levels deep, unioning every level (built on a
  new shared `branchingStep` helper, mirroring `raceGrid.lua`'s own real crossing-validation rule
  exactly, including the loopable "step 1 is always reachable" exception). Sitting right at a fork
  now shows every alternate fanning out from it, resolving the old ambiguity by showing all
  reachable branches instead of guessing one. The toggle is back in both the race editor's default
  settings and the in-game start-options panel for a branching race. `sectorCount`/`manualSectors`
  remain forced off for branching (that limitation is unrelated and unchanged, index/distance-based
  sector splitting is still genuinely ambiguous once a route forks). *(client and server, server
  needs deployment)*

### Changed
- Version bumped to 1.8.35 (buildversion 2291) on both client and server, `UI_BUILD` kept in sync.

## [1.8.34] - 2026-08-26

### Removed
- **Race "Mandatory stop" (the `stand` gate flag and `stand` respawn strategy) removed entirely.**
  This was always a stub: both `raceRunner.lua` and `raceGrid.lua` carried their own explicit
  "NOT YET IMPLEMENTED" note for it, the data model, editor toggle, and save validation existed,
  but nothing at the actual gate-crossing/respawn level ever enforced a real stop, a stand gate
  behaved exactly like any other checkpoint. Removed rather than finished, per direct request:
  `BJRaceGate.stand`, `RESPAWN_STRATEGIES.STAND`, the editor's per-gate "Mandatory stop" toggle and
  the respawn strategy option, the "(stand)" gate label, the legacy BJI importer's now-pointless
  `stand` field mapping, and the 3 related locale keys across all 13 client locales are all gone.
  `sanitizeRace` now also actively scrubs any stray `stand` flag off a gate the next time its race
  is saved through the editor. A race saved with `respawnStrategy: "stand"` before this update
  falls back to `lastcheckpoint` the next time it's re-saved (sanitizeRace's own existing
  unrecognized-strategy fallback); since the strategy was never actually implemented at runtime,
  this changes nothing about how such a race actually played, only what gets written to disk on
  its next save. *(client and server, server needs deployment)*

### Changed
- Version bumped to 1.8.34 (buildversion 2290) on both client and server, `UI_BUILD` kept in sync.

## [1.8.33] - 2026-08-26

### Added
- **Bundled default races and hunter arenas, seeded automatically, no admin action required.**
  New `Server/BeamJoyServer/bundledContent/activities/` folder ships as part of the mod package
  (empty for now, plumbing only, see its own README.md for the file-naming/schema convention for
  future rounds). On every boot, `dao/bundled.lua` mirrors that folder into a brand-new
  `BeamJoyData/db/bundled/` (always fully overwritten from the package, never admin-edited),
  deliberately kept separate from `BeamJoyData/db/activities/` so shipping or updating bundled
  content can never interfere with an admin's own existing races/arenas. `services/races.lua` and
  `services/hunter.lua` each auto-import anything bundled that hasn't been seeded into a given
  map's live data yet, tracked persistently in a small ledger so a given bundled item is only ever
  considered once, ever: an admin renaming, editing, or deleting their own copy of a seeded race
  or arena afterward is never overwritten or reintroduced on a later restart, and a later mod
  update that adds new bundled content is picked up automatically on the next boot with no
  migration step. Races seed per-map, per-name (a name collision with an existing race is skipped,
  not overwritten); hunter arenas seed only for a map that has genuinely never had one saved at
  all, since a map only ever has one arena. *(server only, needs deployment)*

### Changed
- Version bumped to 1.8.33 (buildversion 2289) on both client and server, `UI_BUILD` kept in sync.

## [1.8.32] - 2026-08-26

### Fixed
- **Race paint picker's swatch list could go stale after a "pool" mode vehicle switch.** 1.8.31
  restricted the in-lobby paint picker to "single" vehicle-restriction races only, over a real
  concern: "pool" mode legitimately lets a racer switch between pool entries via the native
  selector before readying up (`onBJRequestCanSpawnVehicle` authorizes any model/config that's a
  member of the pool), but `currentPaintOptions()`/`pushPaintOptions()` only ever ran once, when
  the picker's own Angular component first mounted, so switching vehicles left it showing swatches
  for whatever model the player used to have. Not dangerous (`setPaint`'s own key lookup is always
  against the CURRENTLY spawned vehicle's real paint list, so a stale key just silently missed
  instead of mis-painting anything), just broken/confusing UX. Fixed at the source instead of
  leaving pool paint disabled: `raceRunner.lua`'s `onBJVehicleInstantiated` now re-pushes fresh
  paint options whenever the player's own local vehicle changes during GRID, so the swatch list
  stays honest across any mid-lobby vehicle change. *(client only, no server changes)*

### Changed
- **Race paint picker re-enabled for "pool" mode races**, now that the stale-swatch-list issue
  above is actually fixed rather than worked around by disabling it. Both the picker's own `ng-if`
  and `raceRunner.lua`'s `setPaint` handler are back to allowing any non-"free" vehicle restriction
  (GRID state still required, unchanged from 1.8.31).
- Version bumped to 1.8.32 (buildversion 2288) on both client and server, `UI_BUILD` kept in sync.

## [1.8.31] - 2026-08-26

### Fixed
- **Promote/demote buttons in the player list never reflected a player's actual current rank.**
  `services/players.lua`'s `demote`/`promote` updated and saved `target.group` correctly but never
  broadcast the change to any client, unlike every sibling moderation action (`toggleFreeze`,
  `toggleEngine`, `setGroup`), which all call `M.sendCacheUpdate()`. Every connected client kept
  showing the player's OLD group forever, so the moderation panel's computed next/previous labels
  (via `getNext`/`getPrevious`) always looked "stuck" on the very first promotion/demotion available
  from whatever rank the UI had last actually seen, exactly matching the report. Both functions now
  call `M.sendCacheUpdate()` after saving, same as every other moderation action. *(server only,
  needs deployment)*
- **The player who started a race could only Retire, never Leave.** The Leave button in
  `races/app.html` was hidden outright with `ng-if="!$ctrl.status.isStarter"`, forcing the starter
  into either Cancel (GRID only, or solo, and ends the session for everyone) or Retire (RACE only,
  stays a tracked DNF participant) with no way to just leave and hand the race off. The server's own
  `raceLeave` already reassigns `session.starterID` to another participant when the starter leaves
  (`session.starterID = session.participants:keys()[1]`) and correctly tears the session down if
  they were the last one in it, this was purely a client UI restriction with no matching server
  requirement. Hunter's own Leave button already had no such restriction. Removed the gate: the
  starter now sees Leave same as any other participant. *(client only, no server changes)*
- **Ghost mode could silently fail to apply to a just-spawned vehicle if it hadn't finished syncing
  to the local client yet.** `updateVehicleGhost`'s handler looked up the target vehicle by
  `remoteVID` in `M.vehicles` and, if not found yet (a real, race-prone window: `registerVehicle`
  polls `MPVehicleGE.getVehicles()` and can take a few frames to pick up a fresh spawn), silently
  dropped the ghost state with nothing to ever retry it once the vehicle actually appeared. Added
  `M.pendingGhostStates`, keyed by `remoteVID`: a miss now records the intended state instead of
  discarding it, and `registerVehicle` consumes and applies it the moment that vehicle actually
  finishes registering. *(client only, no server changes)*
- **A player who readied up could edit their vehicle's parts or tuning afterward with the race
  still treating them as ready.** BeamMP's `onVehicleEdited` fires for any real config/tuning change
  but never touched a player's ready state in either race or Hunter lobbies. Added
  `unreadyOnVehicleChange(playerID)` to both `raceGrid.lua` and `hunterGrid.lua` (mirrors each
  other exactly): looks up the player's current GRID/LOBBY session, and if they're ready, un-readies
  them and pushes the session update. Wired in from `services/vehicles.lua`'s `onVehicleEdited`.
  *(server only, needs deployment)*

### Changed
- **Belated documentation for a revision already shipped under 1.8.29/1.8.30's own buildversions,
  never previously written up:** the welcome/intro panel's custom-image support turned out to
  actually need a real `http(s)://` URL replaced with a root-relative local path instead (e.g.
  `/myWelcomeStuff/image.jpg`), delivered to clients via the server's own `Resources/Client/`
  folder, the same mechanism that already delivers BJ.zip itself. A genuine live `http(s)://` URL
  is not reachable here: BeamNG's engine only allows cross-origin loads for a small, hardcoded set
  of domains (confirmed by reading strings out of the game's own binary), so it would have silently
  rendered a blank white panel instead of the intended image. The Intro Panel editor also gained a
  folder-browse assist (`BJRequestIntroPanelImagesInFolder` / `listIntroPanelImagesInFolder`): point
  it at a folder and pick a file from a list instead of typing the exact path by hand. Also, Legacy
  Import race names longer than sanitizeRace's 40-character max are now truncated on import instead
  of unconditionally failing sanitization, real legacy BJRally/BJI race names routinely exceed it.
- **The in-lobby race paint picker is now GRID-only and "single" vehicle-restriction only.**
  Previously shown for any non-free vehicle restriction (including "pool") and regardless of race
  state, meaning it stayed visible (and functional, `setPaint` had no state/mode check of its own)
  straight through COUNTDOWN and into a live RACE. "Pool" races are excluded for now since per-entry
  paint tracking across a pool reroll/respawn isn't implemented yet, only "single" is. Both the
  panel's own `ng-if` and `raceRunner.lua`'s `setPaint` handler now enforce
  `state === 'GRID'` and `mode === 'single'` as a second, independent layer, not just the panel's
  visibility. *(client only, no server changes)*
- Version bumped to 1.8.31 (buildversion 2287) on both client and server, `UI_BUILD` kept in sync.

## [1.8.30] - 2026-08-25

### Fixed
- **Real bug, per direct follow-up report: a mod-rank account with only `EditRaces` or
  `EditHunterArenas` could still open Config > Core and reach the Legacy Import accordion, when
  only `SetCore` (owner rank) should ever be able to open this tab at all.** The previous round
  (1.8.28) correctly gated the identity-fields form itself behind `SetCore`, but the Core tab's own
  visibility was still deliberately widened to `["SetCore", "EditHunterArenas", "EditRaces"]` from
  an earlier round, specifically so a mod-rank importer-only account could still reach the tab for
  Legacy Import. Per direct request, that widening is reverted: the Core tab's own `permissions`
  list is back to `["SetCore"]` only. A non-owner account with `EditRaces`/`EditHunterArenas` no
  longer sees the Core tab in the Config window at all, Legacy Import included, matching the same
  "SetCore only" boundary the identity-fields form was already given. A true `SetCore`/owner-rank
  account still sees every Legacy Import row it's entitled to via this codebase's own rank-
  inheritance rule (an owner rank almost always satisfies every lower-ranked permission
  automatically). *(client only, no server changes)*

### Changed
- Version bumped to 1.8.30 (buildversion 2286) on both client and server, `UI_BUILD` kept in sync.

## [1.8.29] - 2026-08-25

### Added
- **Welcome/intro panel now supports a custom external image URL, not just the fixed list of
  bundled BeamNG tutorial images.** Previously raised as a planned item: `uiHelpers.lua`'s
  `openPanel(title, content, image)` hard-rejected anything not in its own `PANEL_IMAGES`
  whitelist, and the image URL was always built from a hardcoded `/gameplay/tutorials/pages/
  {image}/image.jpg` template with no path for an external URL at all. `openPanel` now detects a
  real `http(s)://` URL and uses it directly as the panel's `background-image`, CEF's own renderer
  handles a real external URL the same as any other image, this was never a hard engine
  limitation, only `openPanel`'s own whitelist check. The Config > General > Intro Panel editor
  gained a toggle button next to the image picker to switch between the existing built-in-image
  dropdown and a plain text field for a custom URL, with the live preview image switching sources
  to match. No server-side change was needed: `services/config.lua`'s `IntroPanel` field already
  stores `image` as an opaque string with no whitelist validation of its own, the restriction was
  entirely client-side. New locale keys (`useCustomUrl`, `useBuiltIn`, `customUrl.tooltip`) added
  across all 13 client locales. *(client only, no server changes)*

### Changed
- Version bumped to 1.8.29 (buildversion 2285) on both client and server, `UI_BUILD` kept in sync.

## [1.8.28] - 2026-08-25

### Fixed
- **Real bug, per direct report: an account with only `EditRaces` or `EditHunterArenas` (a
  mod-rank permission) could open Config > Core and see the full server identity-fields form
  (Name, Description, Max Players, Private, Debug, Information Packet, with a real if
  ultimately-rejected Save button), when only `SetCore` (owner rank) should ever be able to.**
  The server already correctly withholds this data server-side (`services/core.lua`'s
  `onBJRequestCache` only ever includes `caches.core` for a `SetCore` holder), but the client-side
  identity-fields form itself rendered unconditionally the moment the Core tab mounted at all.
  Since the tab's own visibility was deliberately widened in an earlier round to
  `["SetCore", "EditHunterArenas", "EditRaces"]` (so each mode's own Legacy Import row stays
  reachable for a mod-rank holder who isn't also owner-rank), a `EditRaces`/`EditHunterArenas`
  account could reach the tab and see the identity-fields form fully rendered, even though any
  Save attempt would have been rejected server-side and the requested data would never actually
  arrive (a `nil` `BJSendCoreData` payload for a non-`SetCore` requester). Fixed by gating the
  identity-fields form itself (`core/app.html`'s whole `<table>`) on a new `$ctrl.canSetCore`
  check, computed the same way `canImportHunter`/`canImportRaces` already are, and skipping the
  `BJRequestCoreData` request entirely in `$onInit` unless `canSetCore` is true. A non-`SetCore`
  holder now only ever sees the Formatting Hints reference and their own permitted Legacy Import
  rows; the identity-fields form is invisible to them entirely, not just non-functional.
  *(client only, no server changes)*

### Changed
- Version bumped to 1.8.28 (buildversion 2284) on both client and server, `UI_BUILD` kept in sync.

## [1.8.27] - 2026-08-25

### Added
- **New staff moderation action: "Launch"**, a discrete-impulse punishment that catapults a
  target vehicle into the air (upward velocity plus a random horizontal direction), alongside the
  existing "Explode" action. Mirrors the existing `explode`/`explodeVehicle` architecture exactly:
  the server (`services_permissions.isStaff` gated) resolves the target vehicle by its
  cross-client-stable vid and broadcasts a `launchVehicle` event to every connected client, but
  only the vehicle's OWNING client actually applies the velocity (`mpVeh.isLocal` check) via
  `applyClusterVelocityScaleAdd` (BeamNG's own native per-vehicle-cluster velocity primitive) with
  a random launch angle each time. This discrete, one-shot design is what makes it feasible at
  all: BeamMP vehicle physics is authoritative only on the owning client, so a continuous,
  per-frame interaction (like a server-side node grabber) isn't achievable the same way, but a
  single relayed impulse is, since it becomes real physics on the vehicle's own authoritative
  simulation the moment it's applied there. Exposed via both the player-list vehicle-line action
  row and the in-world right-click vehicle context menu, staff-only in both places. New
  `beamjoy.window.main.playerlist.actions.launch` locale key added across all 13 client locales
  (translated, not machine-literal) and a new hand-drawn `launch.svg` icon (an upward arrow,
  matching the existing icon set's style/viewBox rather than guessing at a memorized icon-font
  glyph). *(client and server, server needs deployment)*

### Changed
- Version bumped to 1.8.27 (buildversion 2283) on both client and server, `UI_BUILD` kept in sync.

## [1.8.26] - 2026-08-25

### Added
- **Full locale expansion: every non-English client and server translation brought to 100% key
  parity with `en-US.json`.** All 12 non-English client locales (`de_DE`, `es_419`, `es_ES`,
  `fr_FR`, `ja_JP`, `ko_KR`, `pl_PL`, `pt_BR`, `pt_PT`, `ru_RU`, `zh_Hans`, `zh_Hant`) were missing
  the same 403 keys (this session's race/Hunter/config additions) and carried 2 stale orphaned
  keys (`allowMods`/`allowMods.tooltip`, superseded by an earlier rename in the English source).
  All 7 non-English server locales (`de_DE`, `es_419`, `es_ES`, `fr_FR`, `pl_PL`, `pt_BR`, `pt_PT`)
  were missing the same 94 keys. Every missing key was given a real, natively-translated value
  (not machine-literal), matching each locale's existing tone and register, with regional dialect
  differentiation where relevant (`es_419` Latin American vs. `es_ES` Peninsular Spanish,
  `pt_BR` vs. `pt_PT`), and preserving every `{placeholder}` token and `\n` escape exactly. Server
  locales keep this codebase's existing ASCII-only convention (diacritics stripped); client locales
  use full native diacritics as before. Verified via a full key-set diff (0 missing, 0 extra
  everywhere) and a JSON-validity sweep across all 21 locale files. *(both client and server, server
  locales need deployment)*

### Changed
- Version bumped to 1.8.26 (buildversion 2282) on both client and server, `UI_BUILD` kept in sync
  per the project's own versioning convention.

## [1.8.25] - 2026-08-23

### Fixed
- **Race reset-penalty lock hardened: the ghost reason is now reasserted every frame, same as the
  freeze already was**, per direct request to make sure it genuinely holds for the whole duration.
  `vehicles.lua`'s own generic `onVehicleResetted` hook unconditionally un-freezes any already-frozen
  vehicle the instant a native reset event fires, with no awareness of this lock. Since
  `applyResetPenalty` sets its freeze pre-emptively (from `onBJRequestCurrentVehicleReset`, which
  fires before the actual reset event dispatches), that generic hook could briefly see the fresh
  freeze as pre-existing and clear it within the same tick, before the next frame's reassertion
  caught it back. The ghost reason itself was never touched by that hook, so it already persisted
  correctly through the shared ghost-reason registry; reasserting it every frame regardless is a
  cheap, purely defensive tightening. *(client only, no server changes)*

## [1.8.24] - 2026-08-23

### Fixed
- **versionCheck banner's own advice was wrong**, per direct correction: "fully reinstall the mod"
  doesn't clear BeamNG's cache at all. Reinstalling only replaces the mod's own files on disk, with
  no effect on the separate CEF cache state actually causing the staleness, so it was never a real
  alternative. Removed. Also dropped the "UI" qualifier from "clear your UI cache," since BeamNG's
  own in-game terminology (Help menu) just calls it "Clear cache." Message is now: "Close BeamNG
  completely, clear your cache, then relaunch." *(client only, no server changes)*

## [1.8.23] - 2026-08-23

### Changed
- **Reverted the "Clear Cache & Reload" button. Confirmed, via live testing, that no in-session
  fix for this actually exists.** Two separate attempts (1.8.19's `reloadUI()` round-trip, 1.8.22's
  query-string cache-busted navigation) were both live-tested and failed: the player bumped the
  server's build after the UI had already cached the old one, clicked the button, and the banner
  still correctly reported "out of date" both times. BeamNG's own native UI has no working live
  cache-clear to model this on either: its "Clear cache" tool (Help menu) just sets a
  `folderCleanupRequested` flag and labels itself "(requires a restart)," with the actual cleanup
  only running on the next launch. Both prior attempts only ever affected ordinary browser HTTP
  caching, and BeamNG serves its UI through a custom `local://` CEF scheme, not real HTTP, so
  neither had anything to actually bust.
- The banner no longer offers a button that can't work. Its message is now honest about what
  actually fixes this: close BeamNG completely, clear the cache, then relaunch. Only "Close"
  (dismiss) remains as an action. *(client only, no server changes)*

## [1.8.22] - 2026-08-23

### Fixed
- **"Clear Cache & Reload" (versionCheck) visibly reloaded the UI but never actually cleared the
  staleness.** The 1.8.21 diagnostics confirmed the click did reach Lua and did call the native
  `reloadUI()` engine global successfully, ruling out every theory from that round. Traced
  `reloadUI()` itself by reading the installed game's own `ui/entrypoints/main/main.js`: it's a
  thin wrapper around a plain `window.location.reload()`, an ordinary reload, not a
  cache-bypassing one. Modern Chromium/CEF ignores the legacy "force reload" argument entirely, so
  this reloaded the Angular app in place without ever forcing a fresh fetch of the cached
  JS/ES-module content: the page visibly reloads, but the same stale bundle (and the same
  mismatch) comes right back.
- **Real fix**: `clearCacheAndReload()` now cache-busts the navigation URL directly, in the mod's
  own JS, no Lua round-trip at all. It appends a changing query parameter and does a real
  `window.location.href` navigation, which Chromium can't serve from either the HTTP cache or the
  JS module cache (both keyed by exact URL). The now-dead-end Lua-side
  `BJRequestUIReload`/`requestUIReload` handler and the 1.8.21 diagnostics were removed.
- **Known bootstrapping limitation, flagged honestly**: anyone already stuck on a stale UI from
  before this fix has the old, broken button cached and needs one manual cache clear (or a full
  game restart) to pick up this fix at all. Every mismatch after that will be fixable with the
  button alone. *(client only, no server changes)*

## [1.8.21] - 2026-08-23 (diagnostic only)

### Diagnostics
- **"Clear Cache & Reload" button (versionCheck) reported as doing nothing, with no console
  output at all.** LogError's own output only shows in the game's own in-game Lua console, which
  may not have been what was being watched, so nothing here was live-confirmed yet. Shipped a
  visible, no-setup-required diagnostic instead of guessing again: a `console.log` right when the
  button is clicked (browser/CEF devtools), and an in-game `toast.warn` right when
  `communications/ui.lua`'s `requestUIReload` handler is actually reached, reporting whether
  `reloadUI` resolves to a real function at all. Both are temporary and will be removed once the
  actual break point is confirmed. *(client only, no server changes)*

## [1.8.20] - 2026-08-23

### Added
- **New race option: "Reset penalty"**, matching Hunter's own crash-reset penalty design (minus
  the camera lock, per direct request: races just freeze and briefly ghost the vehicle, no forced
  external view). When enabled (default off), a racer's vehicle freezes and ghosts for a
  configurable number of seconds every time they reset or recover during an active attempt, no
  exception for a plain in-place Recover, matching Hunter's own "any reset counts" philosophy. An
  earlier design that added time directly to the total race clock was scrapped in favor of this
  once it became clear the freeze itself is the penalty: being unable to move for N seconds already
  costs real race time on its own. Threaded through the exact same host-configurable-default
  pattern as `dnfEnabled`/`dnfTimeout`: `BJRaceDefaults.resetPenaltyEnabled`/`resetPenaltySeconds`
  (`services/races.lua`), `raceGrid.lua`'s `buildSettings` override resolution, a toggle+slider in
  both the race editor and the per-start options panel (hidden entirely under "norespawn", where
  resets are already fully blocked outright). Purely client-enforced (`raceRunner.lua`) with zero
  server round-trip, same as Hunter's own version. Reuses the existing shared countdown overlay
  (`windows/raceCountdown`) for the freeze timer display, adding a new "penalty" mode alongside its
  existing countdown/finished/dnf ones. **Server file changed, needs deployment**:
  `Server/BeamJoyServer/services/{races.lua,raceGrid.lua}`.

### Added
- **The stale-UI-cache banner (`windows/versionCheck`) can now actually fix itself, not just tell
  the player to do it manually.** Previously the mismatch banner's only action was a "Close"
  dismiss button, and its message just told the player to try clearing the cache or reinstalling
  the mod by hand. Added a "Clear Cache & Reload" button that calls a new `communications/ui.lua`
  handler (`BJRequestUIReload` -> `requestUIReload`), which invokes BeamNG's own native
  `reloadUI()` global, confirmed via the game's own installed `mcp/tools/system.lua` to hard-reload
  the UI ignoring cache. *(client only, no server changes; superseded in 1.8.22-1.8.23, see above)*

## [1.8.18] - 2026-08-23

### Fixed
- **Hunter's fugitive-reveal nametag never rendered at all for a hunter with nametags globally
  disabled.** `nametags.lua`'s entire "draw all" block (including the revealed fugitive's own tag)
  was wrapped in `if not M.state.hideNameTags then`, a purely cosmetic personal preference
  unrelated to Hunter. A hunter who'd turned nametags off for normal freeroam would never see the
  fugitive's tag even after a real reveal trigger fired, silently breaking the reveal mechanic for
  them specifically. Fixed narrowly, not by forcing nametags on for everyone: new
  `beamjoy_hunterRunner.isRevealedFugitiveVehicle` lets `nametags.lua` force-draw just the
  currently-revealed fugitive's tag when `hideNameTags` is on, while every other vehicle's nametag
  still respects the viewer's own preference. *(client only, no server changes)*

## [1.8.17] - 2026-08-23

### Fixed
- **`/map`/`bj map`'s own "Current map is X" confirmation printed/sent immediately after
  triggering a switch, before the actual mods-reload (Windows) or restart (Linux) had happened,**
  misleadingly claiming the switch was already complete while it was still mid-flight (a real
  captured log showed the confirmation appearing before the "reloading server mods" warning and
  the actual `reloadmods` completion). `switchMap` gained an optional `onComplete` callback,
  invoked once the switch has genuinely finished. `bj map <name>`'s console confirmation now uses
  it, so it only prints once the switch is actually done. `/map <name>`'s chat confirmation
  deliberately does not use it: the sender gets kicked along with everyone else as part of the same
  switch, so a confirmation sent after the fact would never reach them. It's sent immediately
  instead, reworded to "Switching to X..." rather than "Current map is X." *(server only, no
  client changes)*

### Added
- **`MaxPlayers` is now forced to 0 for the entire duration of a map switch** (kick countdown plus
  mods-reload-or-restart), not just during `refreshModsIfChanged`'s own internal scan. Previously
  nothing stopped a new player from connecting mid-countdown or in the gap before Windows'
  `reloadmods` actually ran, potentially serving them an inconsistent mix of old/new mod archives.
  Restored to its real original value automatically once the switch completes, including on the
  Linux restart path, where it's restored before the delayed `exit()` rather than after, since
  leaving it at 0 across a process exit would persist into the config BeamMP-Server reads back on
  restart and permanently lock the server at 0 players.

## [1.8.16] - 2026-08-23

### Fixed
- **`reloadmods` map-switch fix from 1.8.12/1.8.13 crashed a Linux-hosted server.** The
  `reloadmods`-via-console-injection technique (`FS.SendConsoleCommand`) only ever had a Windows
  implementation (`AttachConsole`/`WriteConsoleInput`, real Win32 APIs), and ran unconditionally on
  any modded-map switch regardless of host OS. A Linux server hoster hit `FS.SendConsoleCommand is
  Windows-only` instead of ever actually reloading its mods. `switchMap`'s modded-switch branch now
  checks `FS.isWindows()` first: Windows still uses the no-restart `reloadmods` path exactly as
  before; anything else falls back to the original, cross-platform behavior from before 1.8.12,
  `exit()` after a 3s warning, relying on the host's own process supervisor (systemd, pm2, the
  hoster's control panel, etc.) to restart BeamMP-Server, which then picks up the already-swapped
  mod archive on its own. *(server only, no client changes)*

## [1.8.15] - 2026-08-23

### Fixed
- **The actual root cause of "the fugitive could reset/recover while a hunter was right next to
  them."** The reset-lock distance check (and the reveal-proximity check, which shares the same
  computation) compared the local player's position against `v.position`, a cached field on each
  tracked vehicle. That field is only ever refreshed by `beamjoy_vehicles.getVehicle(vid)` being
  called without `light=true`, which for another player's vehicle only ever happens in
  `nametags.lua`'s own "draw all" loop (skipped entirely once nametags are disabled) plus its
  Alt-gated hover-reveal. On a client with nametags turned off, a hunter's tracked position never
  updated past wherever they were at registration, so the fugitive's own reset-lock/reveal checks
  were silently comparing against a frozen, stale position. Fixed by computing each candidate
  hunter's position fresh (`beamjoy_vehicles.getVehiclePositionRotation`) instead of trusting the
  cached field, removing an accidental coupling between the cosmetic nametag system and Hunter's
  core proximity mechanics. This was the only place in the codebase relying on that cached field
  for another vehicle's live world position. *(client only, no server changes)*

## [1.8.14] - 2026-08-22

### Fixed
- **Hunter: sometimes the countdown ends without releasing your car.** The HUNT-start
  freeze-and-release logic captured `getCurrentOwn()` once and skipped scheduling the release
  entirely if that returned nil, a real possibility for a vehicle that had only just spawned
  (still mid-registration at that exact instant). `onBJVehicleInstantiated` had already frozen it
  moments earlier during COUNTDOWN, so with the release never scheduled, the vehicle stayed
  frozen for the rest of the hunt. The release is now always scheduled regardless of whether a
  vehicle exists at that exact instant; the delayed callback already re-fetches the current
  vehicle fresh when it actually fires.
- **Hunter: hunters saw their own HUD claim "YOU ARE EXPOSED"** whenever the fugitive got
  revealed, not just the fugitive themselves. `huntedRevealed` was pushed to every participant
  unconditionally, unlike its sibling `huntedResetLocked` right next to it, which was already
  correctly scoped to the fugitive's own client only. Fixed to match.
- **Hunter: a spawn point placed under an object (a gas station awning, a tunnel ceiling) spawned
  the vehicle on top of it instead.** Both hunter spawn-teleport call sites left `cling` at its
  default (`true`), which re-snaps the position to the nearest surface below a point 10 units above
  the target: fine for a point sitting in the open, but wrong for one deliberately placed under a
  covering structure, where that structure's own underside is what the ray hits first. The arena
  editor already places these positions correctly; spawn time no longer re-clings them.
- **Verified, not a bug**: the Hunter reveal-proximity distance setting is genuinely meters, with
  no unit mismatch or scaling applied anywhere in the chain.
- **Verified, not a bug**: `huntedResetDistanceThreshold` resolution and the reset-lock distance
  check are both completely independent of `winCondition` ("waypoints" vs "timed"). No
  timed-mode-specific difference found in this logic. *(client only, no server changes)*

## [1.8.13] - 2026-08-22

### Fixed
- **A real gap from 1.8.12's own change, caught immediately**: switching to/from a modded map no
  longer restarts the process, but a restart used to be what re-triggered `onInit`'s own mods-
  changed scan (`scanNewMods`) as a side effect. Any other new mod content sitting in
  `Client/`/`Maps/`, unrelated to the specific map being switched to, would now never get
  discovered until a genuine manual server restart. `switchMap` now re-runs that same scan
  directly (`scanNewMods`, extracted alongside its own cache-comparison gating into a shared
  `refreshModsIfChanged`) as part of the same modded-switch branch, restoring the original
  cadence without needing an actual restart. `scanNewMods` itself now takes an optional
  `onRebootNeeded` callback so a caller that's already about to reload mods for its own reason
  (like this one) can suppress its default "schedule `exit()` in 3s" behavior instead of both
  independently trying to handle the same situation. **Needs server deployment.**

## [1.8.12] - 2026-08-22

### Changed
- **Switching to/from a modded map no longer restarts the server**, confirmed with a BeamMP dev
  and live-tested end to end. Previously, `switchMap` called `exit()` whenever either side of a
  map switch was modded, since BeamMP-Server only serves `Client/`'s contents at process startup,
  and the only way to make a newly-added/removed mod archive available was a full restart. BeamMP's
  own `reloadmods` console command re-serves the current folder contents to newly-connecting
  players without a restart, but has no Lua-callable equivalent. New `FS.SendConsoleCommand(cmd)`
  (`utils/FS.lua`) works around that: a short-lived PowerShell process (via the same
  `runPowerShell` helper already used for mod extraction) attaches to its own parent process's
  console (the running `BeamMP-Server.exe`, found via WMI, no PID needs passing in) and injects
  the command as real key-event records via the Win32 `AttachConsole`/`WriteConsoleInput` APIs,
  then exits: a single short-lived process, no persistent/hidden background daemon. Requires
  `BeamMP-Server.exe` to have a real attached console (launched normally, not with its own stdin/
  stdout redirected to pipes/files).
- `switchMap`'s own player-kick countdown is unchanged (still warns and clears everyone before the
  map actually changes). Only what happens after that changed: `reloadmods` instead of `exit()`
  when either map is modded.
- **Real correctness fix found while making this change**: the `onMapChangedWithReboot` hook fired
  for a modded switch had zero listeners anywhere in the codebase. `activityConfig.lua`/
  `races.lua`/`hunter.lua`'s own `onMapChanged` listeners (which reload their per-map data) never
  actually ran for a modded map switch, only for a non-modded one. Harmless before, since the
  process died via `exit()` immediately after anyway, but would have been a real gap now that it
  doesn't. Fixed by always firing `onMapChanged` regardless of modded status.
- `scanNewMods`'s own startup-time reboot path (a different code path, for a newly-discovered
  map found during the mod scan at server boot) is deliberately left unchanged for now. The
  timing there (very early in server startup, before the console's own input loop may be fully
  ready) hasn't been verified safe for `FS.SendConsoleCommand` the way the runtime `switchMap`
  case has been. **Needs server deployment.**

## [1.8.11] - 2026-08-22

### Changed
- **The 1.8.9 nametag hover-reveal throttle replaced with a real fix**, per direct feedback that
  a throttle alone just spreads the same expensive native `cameraMouseRayCast()` cost out over
  time rather than removing it, showing up as intermittent stutter instead of steady lag. The
  hover-reveal (letting a hovered vehicle's nametag show even while nametags are globally hidden)
  is a minor cosmetic nicety, not gameplay-critical, so it's now opt-in: the raycast only runs at
  all while **Alt** is held (unbound by default in BeamNG's own `keyboard.json`, confirmed before
  choosing it), so idle/normal play never pays this cost at all. Still throttled to at most once
  every 150ms while Alt is actually held, so sweeping the camera across a crowd of vehicles with
  Alt down doesn't reintroduce a steady per-frame cost either. *(client only, no server changes)*

## [1.8.10] - 2026-08-22

### Fixed
- **A real regression from 1.8.7, confirmed via a live disconnect capture**: session mods no
  longer got cleaned up properly on disconnect (files remained where BeamMP's own multiplayer
  Resources cache lives, instead of being removed/moved the way they normally are). Root cause:
  1.8.7 added an `M.state` (`AllowClientMods`) guard to `deleteMod`, based on the wrong assumption
  that it's purely a player-initiated action like its sibling wrappers
  (`activateModId`/`deactivateModId`). It isn't: `mods.lua` overrides
  `extensions.core_modmanager.deleteMod` at the Lua level, and BeamMP's own native
  `cleanUpSessionMods()` (the disconnect-cleanup routine) calls back into that same overridden
  function to actually remove each session mod. Once 1.8.8 permanently forced `AllowClientMods`
  off, that guard silently blocked every call to `deleteMod`, including BeamMP's own internal
  cleanup calls, not just a player's own manual "delete mod" action. Fixed by reverting the guard
  on `deleteMod` specifically (it now only checks `isServerMod`, same as before 1.8.7). Every other
  wrapper in this file stays correctly gated on `M.state`, since none of the others are called
  internally by BeamMP's own cleanup the way this one is. *(client only, no server changes)*

## [1.8.9] - 2026-08-22

### Fixed
- **The actual, confirmed root cause of the reported race/proximity lag** (the mod-scan fixes in
  1.8.6-1.8.8 were real bugs but turned out to be connect-time costs, not this). Found from a live
  per-extension engine profile showing `extensions.beamjoy_nametags.onUpdate` costing 5.5-13.3ms in
  a single frame, while every other extension (native or BJS, ~90 of them) sat at 0.0002-0.07ms.
  `nametags.lua`'s "mouse hover nametag" feature (letting a hovered vehicle's tag show even while
  nametags are globally hidden) called the native `cameraMouseRayCast()` every single frame,
  unconditionally, not gated by the `hideNameTags` setting at all unlike the rest of this file.
  That native raycast is expensive against a vehicle's actual mesh, worse for more complex/modded
  vehicles, and only produces a hit when the camera is pointed at a vehicle within its range,
  matching every reported symptom exactly. Fixed by throttling the raycast to run at most every
  150ms instead of every frame, redrawing the last resolved target in between so there's no visible
  flicker. As a side effect, this also cuts how often the surrounding
  disableCollision()/enableCollision() toggle on the local vehicle fires, which was separately
  flagged as a suspect in the unrelated "unicycle randomly gets removed" investigation earlier in
  this project's history. *(client only, no server changes)*

## [1.8.8] - 2026-08-22

### Changed
- **`AllowClientMods` (letting players use their own personal vehicle mods in multiplayer) is now
  permanently disabled**, per direct request: the re-scan mechanism it enables (`mods.lua`'s
  `onModActivated`/`onModDeactivated` -> a forced full jbeam re-parse of every installed vehicle
  mod) was found, from a real client log, to cause a severe multi-minute stall right after
  connecting whenever several distinct vehicle mods activated close together (the common case with
  multiple players each using a different custom vehicle). See 1.8.6/1.8.7's own entries for the
  full diagnosis and partial mitigations. Rather than continue optimizing a feature that's this
  expensive to support, it's shelved outright: `AllowClientMods` now defaults to `false` and
  `sanitizeConfigValue` rejects any attempt to change it (server-side, so this can't be re-enabled
  via the UI, chat, or console), and its toggle has been removed from Config > General entirely,
  since it no longer does anything. `mods.lua`'s own wrapping logic is untouched and simply stays
  permanently dormant as a result. Server-mod enforcement (forcing required server mods to stay
  active) is
  unaffected, since that was already unconditional and never depended on this setting. **Needs
  server deployment** (`services/config.lua`).

## [1.8.7] - 2026-08-22

### Fixed
- **`deleteMod` bypassed the `AllowClientMods` gate**, unlike every sibling mod-manager wrapper
  (`deactivateModId`/`deactivateAllMods`/`activateModId`/`activateAllMods` all check `M.state`
  first). Deleting (not just deactivating) a non-server vehicle mod through the vanilla mod manager
  UI could still schedule the same forced `onBJVehicleModChanged` re-scan even with client mods
  disabled server-wide. Fixed by adding the same `if not M.state then return stopProcess() end`
  guard `deleteAllMods` already has. *(client only, no server changes)*

## [1.8.6] - 2026-08-22

### Added
- **A UI cache/version mismatch warning.** GE-Lua always reads `version`/`buildversion` fresh off
  disk every session, but the Angular UI runs inside CEF (a real embedded browser) and can keep
  serving a stale, browser-cached bundle after a mod update if the player never clears their cache,
  with no built-in way for a player to know that's what's happening. A new
  `windows/versionCheck` component compares Lua's real, freshly-reported build number against a
  `UI_BUILD` constant baked directly into the UI's own JS source (kept in sync with the client
  `buildversion` at every release) ; on a mismatch, it shows a persistent, dismissible banner
  across the top of the screen telling the player their UI looks out of date. Reuses the existing
  one-time `BJVersion` push (previously only consumed by the Settings tab's About section) for the
  Lua-side number, and adds a matching `BJVersionRequest` handler so this new component gets a
  reliable value regardless of when it happens to mount, instead of racing a broadcast it could
  otherwise miss entirely. *(client only, no server changes)*

### Fixed
- **A real GPU/performance bug in the race gate/marker rendering**, reported as lag/stutter when
  racers are close to each other: `onBJRaceMarkersRefresh` fired on every session update, and the
  server pushes one on every participant's gate crossing, not just the local player's own. Nothing
  drawn in the live-session render branch actually depends on any OTHER participant's progress
  (their crossings never change this player's own next-gate highlight, visible-gate window, or a
  pure spectator's always-fully-visible gate set), so most of those refreshes were rebuilding the
  full gate layout from scratch (a `shape.reset()` plus every gate's quad/arrow/text/path geometry)
  for no visual change at all, worse the more nearby participants are actively crossing gates.
  Fixed by computing a lightweight signature of exactly what the live-session render actually
  depends on (session id/state, the local player's own last-crossed/current gate, finished/dnf) and
  skipping the rebuild entirely when it's unchanged since the last call. *(client only, no server
  changes)*
- **A real GPU/CPU stall found from a live server log**, contributing to the same race lag/stutter
  reports: any time BeamMP activates or deactivates a vehicle mod locally (this happens once per
  distinct vehicle mod as it gets streamed in for each connected player, so it's common for several
  to fire close together, e.g. everyone in a race using a different custom vehicle), `mods.lua`
  scheduled a full forced re-parse of every installed vehicle mod's jbeam files
  (`onBJVehicleModChanged`) 200ms later. None of those scheduling calls passed a dedupe key, so
  several mod-change events landing close together queued that same expensive full re-scan once
  *per event* instead of once for the whole burst. The captured log showed exactly this: a run of
  duplicate-part and malformed-JSON errors from broken vehicle mods (`DK_TUNDRA`, `Kinetik`) large
  enough to flood the console. Fixed by giving all three scheduling call sites the same debounce key
  (`async.lua`'s `delayTask` already supports canceling-and-replacing a pending call by key, just
  wasn't being used here), collapsing a burst of mod-change events into a single re-scan instead of
  one per mod. Note: the two mods named above are genuinely malformed (a real duplicate-part
  conflict and an invalid JSON comment). This fix reduces how often they get re-parsed; it doesn't
  fix the mod files themselves, which isn't something this mod's own code can do. *(client only, no
  server changes)*

## [1.8.4] - 2026-08-21

### Fixed
- **1.8.3's own fix broke server startup entirely:** `onInit: utils/FS.lua:72: attempt to index
  a nil value (global 'utils_sha')`, thrown the instant the server started, before the mod scan
  ever ran. Root cause: the new PowerShell-based `FS.RemoveDirectory` reached for
  `utils_sha.bin_to_base64` to encode its script, but `FS.RemoveDirectory` is also called from
  `checkWritePermissions()` at the very start of `BeamJoyServer.lua`'s own `onInit`,
  *before* `loadExtensions()` runs, which is what populates `utils_sha` in `_G` in the first
  place. `utils/FS.lua` is deliberately `require()`'d at the very top of the file specifically so
  it's usable standalone this early ; depending on a module that only exists after the dependency
  system finishes loading broke that. Fixed by giving `FS.lua` its own tiny, self-contained base64
  encoder instead of reusing `utils_sha`'s, removing the dependency entirely. *(server:
  `utils/FS.lua`, needs deployment)*

## [1.8.3] - 2026-08-21

### Fixed
- **A third variant of the mod-scan Unicode crash, this time cascading across multiple unrelated
  mods in the same scan:** a live capture showed four otherwise-plain-named mods all failing
  back to back with the same `No mapping for the Unicode character exists in the target
  multi-byte code page` error, right after each other, immediately following "Starting new mods
  scan process". Root cause: `services/maps.lua`'s mod scan reuses one shared scratch folder
  (`tmp/`) to analyze every mod archive in turn, pre-cleaning it via `FS.RemoveDirectory` before
  each one. That pre-clean still went through BeamMP-Server's own native `FS.ListFiles`/
  `FS.Remove` bindings, which, like `Expand-Archive`, can themselves throw this exact error when
  touching a genuinely Unicode-named leftover file (from whatever mod was extracted into that same
  scratch folder previously). Once that happens, the leftover never actually gets removed, so every
  later mod's own scan attempt trips over the same poisoned scratch folder before it even reaches
  its own extraction, explaining why several unrelated, plain-named mods all failed in a row.
  1.8.1's fix (routing `os.execute`'s own command line through `-EncodedCommand`) and 1.8.2's fix
  (dropping `Expand-Archive` for .NET's `ZipFile` API) were both real, necessary fixes for their
  own distinct failure points, but neither one touched this pre-clean step. Fixed by rewriting
  `FS.RemoveDirectory` itself to go through PowerShell's `Remove-Item -Recurse -Force` (via the
  same `-EncodedCommand` transport, Unicode-safe end to end) instead of the native bindings, on
  Windows, closing off the whole class of "a native FS call chokes on a Unicode-named file" bug
  at its source rather than patching each call site that happens to trip over it. Linux is
  unaffected: the native recursive-delete path is kept there, since it isn't subject to this
  ANSI-codepage limitation to begin with. *(server: `utils/FS.lua`, needs deployment)*

## [1.8.2] - 2026-08-21

### Fixed
- **A different, second bug in the same mod-scan area, surfaced by live testing after 1.8.1**:
  extracting some custom mods (confirmed against a wheel mod with non-ASCII characters in its
  internal file names) still failed, this time inside `Expand-Archive` itself:
  `Cannot find path '...' because it does not exist` repeated for every affected file, thrown from
  the cmdlet's own post-extraction cleanup pass (`Microsoft.PowerShell.Archive.psm1`). This is a
  known flakiness in Windows PowerShell 5.1's built-in `Expand-Archive`: for archives with certain
  non-ASCII entry names, the cmdlet's internal record of "which paths did I just write" can drift
  from what's actually on disk, so its own cleanup `Remove-Item` pass throws trying to delete paths
  that were never really there. 1.8.1's fix (routing the command through `-EncodedCommand` so the
  path text never has to survive an ANSI-codepage conversion) was necessary and is still correct:
  it's what let PowerShell actually start running instead of failing immediately, but it doesn't
  touch this separate bug living inside `Expand-Archive` itself. Fixed by dropping `Expand-Archive`
  entirely and extracting directly via .NET's `System.IO.Compression.ZipFile.ExtractToDirectory`,
  which does the raw extraction without that extra cleanup/bookkeeping layer, and whose normal
  Unicode-safe file I/O isn't affected by the OS's active ANSI codepage either way. Linux is
  unaffected: this only touches the Windows extraction branch. *(server: `utils/FS.lua`, needs
  deployment)*

## [1.8.1] - 2026-08-21

### Fixed
- **Loading a certain custom map could crash the whole server-side mod scan** with `No mapping
  for the Unicode character exists in the target multi-byte code page`. The mod-archive extractor
  ran PowerShell by interpolating the archive/destination paths directly into the `os.execute`
  command line, which Windows converts through the system's active ANSI codepage; a map whose zip
  filename (or extracted level folder name) contained a Unicode character outside that codepage
  made the conversion itself throw, taking down `services_maps.onInit` entirely, not just for that
  one map, but blocking the whole mod scan (and therefore every map) until the server was restarted
  without it. Fixed by handing PowerShell a base64-encoded, UTF-16-encoded script via
  `-EncodedCommand` instead of literal text on the command line, so the outer command line is pure
  ASCII regardless of what the paths themselves contain. Also hardened the mod scan itself so a
  future problem with one archive can't repeat this: each mod is now analyzed inside its own
  `pcall`, logging and skipping just that one archive instead of aborting the scan, and the scan as
  a whole is `pcall`'d too so a failure elsewhere can't leave `MaxPlayers` stuck at 0 or block the
  rest of `onInit` (map RX handlers, current-map fallback, chat commands) from ever registering.
  Linux is unaffected either way: the new encoding path only runs on Windows; the Linux `unzip`
  branch is untouched. *(server: `utils/FS.lua`, `services/maps.lua`, needs deployment)*

## [1.8.0] - 2026-08-21

### Added
- **A "How to install legacy races" help button** in the Config > Core "Legacy Import" section,
  opening a plain info popup that explains what the feature does and walks through installing old
  BeamJoy Free data step by step. The same steps are now also documented in the project README.

### Fixed
- **The legacy race importer's author fix from the previous release didn't actually take effect:**
  a single leftover line, predating that fix, unconditionally stamped every imported race's
  author back to `"console"` immediately after conversion, silently overwriting the correct value.
  Removed. *(server: `services/races.lua`, needs deployment)*
- **The previous release's fix for unreadable white-on-white dropdown options didn't actually work:**
  it targeted the wrong attribute (`aria-selected`, Angular Material's real attribute for this is
  the boolean `selected`) and, even corrected, would still have lost outright: the game's own
  Material theme generates this highlight via a rule carrying a theme class plus two pseudo-classes,
  which beats a plain rule on specificity regardless of stylesheet order. Confirmed by reading the
  actual theme template baked into the game's own `angular-material.js`. Fixed with the real
  attribute and an explicit override, which is the correct tool here given the exact theme class
  name is only known at runtime.
- **A branching race's gate could silently lose its Start/Finish status the moment a second real
  parent was added alongside "Start"** (even with "Start" still sitting right there in the list),
  and replacing "Start" entirely with a link from the route's own last gate (the natural way to
  author a visible closing segment) left nothing at all recognized as the loop's anchor, producing
  a race that looped forever without ever counting a lap. Fixed so a gate keeps its Start/Finish
  status any time "Start" is present anywhere in its own parents, regardless of what else is also
  listed alongside it. *(server: `services/races.lua`, needs deployment)*
- **Removing a parent from a branching race's gate could silently duplicate a different one instead**
  (e.g. removing "Start" from `[Start, Gate 6]` could echo back as `[Gate 6, Gate 6]`), which then
  threw a hard Angular error the instant that duplicate reached the "reachable from" chip list,
  the real explanation for a separately-reported "Start disappeared from the parent list" symptom,
  since the thrown error left that list's rendering stuck on stale content instead of reflecting
  its real, current data. Root cause: the race editor applied every gate edit through a generic
  recursive merge instead of replacing the whole list at once, so a shorter new list only
  overwrote the front of the old, longer one and left its own stale tail value in place. Fixed at
  the source, plus a defensive de-duplication pass on save/load so any race already saved with a
  duplicate from this bug gets cleaned up automatically. *(server: `services/races.lua`, needs
  deployment)*
- **A race's countdown-to-green-light and Hunter's own equivalent hunt-start release could
  un-ghost two vehicles that were still genuinely inside each other**, once their shared timeout
  ran out. A starting grid is deliberately packed tight by design, so genuine overlap at the exact
  moment everyone releases together is the expected case there, not a rare edge case, making this
  a real collision-explosion risk specific to these tight-grid releases (the same underlying
  fallback is much safer everywhere else in the ghosting system, since a single freshly-spawned
  vehicle is rarely placed in genuine contact with another one to begin with). Fixed so a timed-out
  release can only ever skip past an overly generous *extra* safety margin, never through the two
  vehicles' own real physical overlap, everywhere this pattern is used, race and Hunter alike.

## [1.7.0] - 2026-08-21

### Added
- **Races: the legacy BeamJoy Free importer now credits the original race's own author**, instead
  of leaving every imported race unattributed (which silently made it staff-only to edit or
  delete, with no record of who actually built it). The author's name is also shown in the import
  preview dialog next to each race. *(server: `services/races.lua`, needs deployment)*

### Fixed
- **A long list in any confirm dialog (both the Hunter and Races legacy importer previews included)
  could grow taller than the screen with no way to scroll and see the rest of it:** the shared
  confirm dialog now caps its height and scrolls its message internally instead.
- **Branching-path races imported from legacy BeamJoy Free data had their start/finish line on the
  wrong gate, with no visible connection back to it:** BJI's own race format always places its
  "finish" waypoint (and any alternate ending, like a pit stop) physically right back at the real
  start grid, but graphically at the *end* of its own waypoint chain ; the importer was taking that
  literally, leaving this fork's actual loop-closing gate deep in the middle of the route instead
  of at the real start/finish line. Confirmed by measuring two real imported races ("Sawmill Long",
  "Gas Station Loop") against their own recorded grid positions. Fixed by having the importer swap
  which end of the route is treated as the anchor, and physically reordering the gate list so the
  real start/finish line is gate 1 (matching how a race built directly in this fork's own editor
  is always laid out), instead of only being correct in the invisible, derived step number.
  *(server: `services/races.lua`, needs deployment)*
- **A branching, loopable race's real closing segment (the drive from its last gate back to the
  start/finish line) was never drawn**, in the editor or in a live race, even though it's still a
  real, driven part of the route. Only the plain, non-branching case ever got this treatment
  before. Now drawn for any branching, loopable race, not just the two reported above.
- **Manually editing a branching race's gate connections could silently mislabel an unrelated gate
  as the Start/Finish line.** Found while investigating the report above: a gate with two parents
  (a genuinely supported, correct setup, e.g. two parallel finish alternates both leading back
  into the same next gate) could, after a further edit elsewhere, form a real loop back through
  itself. The engine's own fallback for that case used to default to the gate's own position in the
  list, which for gate 1 happens to collide with a genuine "this is the start/finish" value, so an
  unrelated gate would silently take over that role, with no warning that anything had gone wrong
  (matching a separately-reported symptom where the "reachable from" list looked wrong even though
  the drawn path was correct: both were downstream of the same bad value). Fixed so this fallback
  can never be mistaken for a real start/finish gate. *(server: `services/races.lua`, needs
  deployment)*
- **The first option in any dropdown could render as unreadable white text on a white background:**
  whichever option a dropdown opens on with nothing selected yet (always the first one, e.g. a
  race gate's "reachable from" picker before a choice is made) was picking up the browser's own
  default focus highlight with no color override, anywhere in the app, not just this one dropdown.

## [1.6.0] - 2026-08-21

### Added
- **Hunter: timed mode**, an alternative win condition alongside the original waypoint route:
  hunters have a configurable number of minutes to catch the fugitive, who otherwise wins by
  survival once the clock runs out. No route/waypoints exist at all in this mode; the HUD shows a
  live countdown instead of waypoint progress. Configurable per-arena default and per-start
  override, same as every other Hunter setting. *(server: `services/hunter.lua`,
  `services/hunterGrid.lua`, needs deployment)*
- **Hunter: session settings shown in the lobby**, not just before starting: vehicle pool
  restrictions, respawn strategy/penalty, reset-lock distance, and reveal distance are now visible
  in a collapsible section of the lobby/countdown/hunt status panel.
- **Races: branching paths**, a new opt-in per-race toggle. Gates can have more than one valid
  "next" gate (parallel alternates, forks that rejoin later, shortcuts) instead of one fixed
  sequential order. Authored via a flat "Reachable from" parent/child picker on each gate. No
  graph/tree view yet, by design. A gate's position in the route ("step") is fully derived from
  these links automatically, never manually set, so it can't drift out of sync with what's
  actually connected. Sectors and the "limit visible gates" display option are automatically
  disabled for a branching race, since both are ambiguous once a route can genuinely fork.
  *(server: `services/races.lua`, `services/raceGrid.lua`, needs deployment)*
- **Races: importer for legacy BeamJoy Free races**, in the same "Legacy Import" section (Core
  config tab) as the existing Hunter arena importer. Non-destructive: every convertible race is
  added as a brand-new race with a fresh id, never overwriting anything already in the list. A
  name collision with an existing race is skipped and reported instead. Converts BJI's own
  parents-by-name waypoint graph into this fork's gate/branching model, sizes gates from the
  source checkpoint radius, and derives gate facing from the route's own shape rather than
  trusting BJI's captured rotation (a proximity checkpoint has no meaningful facing to begin with).
  *(server: `services/races.lua`, `services/hunter.lua`, needs deployment)*

### Fixed
- **A slider configured with any step other than 0.1 (e.g. the Hunter reset-lock distance, meant
  to move in 10m increments) actually settled on arbitrary ~1m values:** the shared slider
  component rounded every drag to the nearest 0.1 unconditionally, ignoring its own configured
  `step` entirely. This affected every stepped slider app-wide, not just Hunter's.
- Hunter's fugitive reset-lock toast (shown when a hunter gets too close to reset/recover) replaced
  with a persistent HUD indicator. A one-off toast was easy to miss for a state that can hold for
  a while.
- **Branching-race "Reachable from" dropdown showed no selectable options at all:** its options
  were built by calling a function directly from the template instead of binding to a precomputed
  property, the pattern every other working dropdown in this codebase actually uses.
- **The remove button on a "Reachable from" chip didn't remove anything:** a nested list inside
  the per-gate parent list shadowed the outer gate index AngularJS was actually needing, so the
  wrong gate object (or none at all) got mutated on every click.
- **A branching race's progress could get permanently stuck one lap in, showing no further gate
  progress on any path:** closing the loop (re-crossing the route's own starting gate to complete
  a lap) used to require the exact same explicit "reachable from" link as any other gate, an
  easy-to-forget backward link that silently froze all further progress once missed. A loopable
  race's own starting gate is now always a valid crossing regardless of that link.
  *(server: `services/raceGrid.lua`, needs deployment)*
- **A branching race's gate counter could show a much higher total than the route actually has:**
  a gate's position in the route ("step") used to be an independently hand-set field, which a
  branch alternate created after its siblings had no way to default correctly on its own; now fully
  derived from the actual "reachable from" links instead of trusted from manual input.
  *(server: `services/races.lua`, needs deployment)*
- A branching race's in-world path line connected gates by their raw array order regardless of
  actual topology. Now draws the real "reachable from" links instead.
- A branching race's Results screen still showed a sector-time column (and a meaningless
  "Theoretical" time equal to the whole lap) even though sectors are supposed to be disabled
  entirely for that mode.

## [1.5.0] - 2026-08-17

### Added
- **Vehicle Pool Presets**: a new dedicated Config tab to create, name, and manage reusable pools
  of vehicles (captured once), then selectable from any race's Pool vehicle restriction (in the
  race editor) or picked fresh at start time, instead of authoring a pool separately per race.
  Built generically enough to be reused by future non-race gamemodes too. A shortcut "edit preset"
  button appears next to a race's pool restriction in the Activities menu for anyone with the new
  permission below. *(server: new `services/vehiclePresets.lua`, `dao/vehiclePresets.lua`, needs
  deployment)*
- New `EditVehiclePresets` permission (default rank `mod`), gating the new Config tab.
- **Streamlined in-lobby paint picker** for single-config and Pool vehicle-restricted races: the
  full native paint list, across all 3 paint slots, applied live with one click. No need to open
  BeamNG's own tuning menu.
- **"Allow tuning" option** (race editor + start options, default **on**) for single-config, Pool,
  and Race-defined vehicle restrictions. When turned off, tuning variables (tire pressure,
  gearing, anti-roll bars, differential, ...) are locked to the captured setup alongside parts, for
  a genuine "spec car, spec tune" mode. Paint is always free regardless of this setting.
  *(server: `services/races.lua`, `services/raceGrid.lua`, `services/vehiclePresets.lua`, needs
  deployment)*

### Changed
- **Pool vehicle restriction now matches by the vehicle's actual captured parts**, not by which
  saved config file it was loaded from, resolving the "Known unresolved" issue noted in 1.4.0
  below. Repainting or adjusting tuning after picking a pool vehicle no longer invalidates it
  (unless "Allow tuning" is off, in which case only tuning changes count against it, while an actual
  parts swap still always does, in both Single Config and Pool modes).

### Fixed
- Vehicle-restriction tuning comparison used exact floating-point equality on values that cross a
  JSON round-trip on their way to the check, which could reject a perfectly matching car (with
  "Allow tuning" off) for no reason at all. Now compares with a small tolerance instead.
- Vehicle preset dropdowns (race editor's Pool picker, start-options' Pool picker) rendered no
  options at all (the only native HTML `<select>` in the whole UI, which doesn't work in BeamNG's
  off-screen-rendered UI); switched to the app's own dropdown component like everywhere else.

### Known unresolved
- Paint still can't be independently locked the way parts and (now) tuning can: it's always free
  regardless of any restriction setting. A future pass may add its own toggle for it, following the
  same pattern "Allow tuning" just established.

## [1.4.0] - 2026-08-16

### Added
- **Race leaderboards**: per-race personal-best/record tracking with a dedicated leaderboard
  button (small bulleted-list icon) next to each race in the browse list. Shows the top 100 times,
  with the viewing player's own rank/time pinned separately below if they're outside it, and the
  vehicle/config actually used for each time (showing "(custom)" if it doesn't match a saved
  config). A new-PB/new-record popup shows on finish. Retiring or DNF'ing still submits whatever
  best lap was already completed, instead of only a full finish counting. Saving an edited race
  now wipes its existing leaderboard, with a confirmation warning naming the record count (skipped
  if there are none). *(server: `services/races.lua`, `services/raceGrid.lua`, needs deployment)*
- **Vehicle restrictions** for races, chosen per race in the editor: **Free** (default), **Single
  Config** (every participant is force-spawned into one exact captured vehicle, including a fully
  custom/never-saved setup, not limited to a saved `.pc`), and **Pool** (a curated list of
  saved-config vehicles a joining participant picks from via the native vehicle selector,
  pre-filtered to just the pool). At start time, whoever starts a race independently chooses Free
  / a fresh Single Config captured from their own current vehicle right at that moment / the
  race's own authored restriction ("Race-defined", offered only when the race actually has one). A
  restriction-violating attempt is excluded from the leaderboard. A missing vehicle mod or an
  unshareable personal saved config is caught and explained rather than silently stranding a
  player carless. *(server: `services/races.lua`, `services/raceGrid.lua`, needs deployment)*
- "Disable gravity changes" anticheat option (race editor + start options, default on): actively
  re-asserts the server's expected gravity every frame during a race, since gravity has no native
  BeamNG keybind to block outright the way other anticheat options can.
- Starting a race with any anticheat or vehicle-restriction option disabled now shows a
  confirmation warning that the attempt won't count on the leaderboard.
- A debug console command to seed a race's leaderboard with fake entries around a given time, for
  testing formatting/pagination.

### Changed
- Slow-motion and pausing are no longer a per-race toggle: always blocked and actively reasserted
  for every race (matching the other anticheat options, but with no opt-out, since neither was
  ever a legitimate racing input to begin with).
- Race editor's "Reverse" button now keeps a loopable race's start/finish line in the same
  physical spot, only flipping the direction of travel around the loop. It used to relocate the
  start/finish line to wherever the old last gate happened to be.
- Race results/leaderboard panel background is now slightly transparent instead of fully opaque.
- Race editor's Vehicle Restrictions section moved to the top of the settings list, with its own
  divider.

### Fixed
- **The vehicle selector's own search/type filters had stopped working entirely:** a global
  spawn-permission wrapper was replacing the native filtering function outright instead of
  layering on top of it, so no filter criteria (only spawn permission) was ever actually checked.
- Traffic vehicles were incorrectly exempted from the solo-race ghost visual reversal (rendered
  solid instead of translucent): the check used to key off a flag that's also true for local
  traffic, not just the racer's own vehicle.
- Staff/owner could bypass the slow-motion/pause anticheat block via the Environment settings
  panel, which reaches the game's simulation-speed API directly. The previous block only covered
  the keybind path.
- A race saved before the vehicle-restriction feature existed (or simply never re-saved since)
  could trigger a spurious "anticheat options disabled" warning on every start regardless of the
  real toggle states. Legacy races are now backfilled to a real "no restriction" value on load.
  *(server: `services/races.lua`, needs deployment)*
- A long vehicle-restriction note in the Activities race list, or a long tooltip anywhere in the
  UI, could widen the whole window instead of wrapping.
- Race info panel: a low-gate-count/high-sector-count race only ever recorded times for the first
  couple of sectors; the best lap wasn't highlighted like it already was in the Live tab; the date
  column stretched to fill the panel.
- Race info panel now waits ~3s before auto-opening on finish, so it doesn't visually collide with
  the finish popup.
- Leaderboard's vehicle column was always blank; the leaderboard and start buttons were visually
  mismatched in size (start button switched to a plain icon).

### Known unresolved
- Vehicle Pool restriction mode currently rejects *any* live edit to a matching vehicle (paint,
  tuning variables, or actual parts alike) as a mismatch, since it keys off the vehicle's own
  "loaded from an exact file" state, which BeamNG clears on any live edit regardless of what
  actually changed. Deliberately left as-is for now: a future pass is planned to allow
  customizing exactly which kinds of changes (parts / tuning / paint) are permitted per
  restriction, most likely by switching Pool's match logic onto the same parts/vars/paints
  comparison Single Config mode already has.

## [1.3.2] - 2026-08-15

### Added
- **Reverse** button in the race editor: reverses gate order and flips each gate to face the new
  direction of travel. Start positions are left untouched: where the grid should sit for a
  reversed direction is a track-specific call, so it's flagged for the author to double check
  rather than guessed at automatically.
- Race editor ground-snapping now has a switchable height source, cycled with the existing
  snap-to-ground button: off (red) → terrain height (green) → raycast (blue). Terrain height reads
  the map's real heightmap directly, so it can no longer snap a gate into tree/foliage collision,
  but some maps (Gridmap) have a visible ground that isn't real terrain at all, so raycast (the old
  behavior) is kept available for those.
- An **About** section in the Settings tab showing the installed version/build and a link to the
  GitHub repository.

### Fixed
- **Traffic never actually spawned** once the amount or max-per-player sliders were touched:
  their typed values were sent to the server as strings, and the traffic balancer's own comparison
  against them threw a runtime error every time, silently leaving every player's traffic
  allocation at 0 regardless of what the settings said. *(needs deployment: `services/traffic.lua`)*
- **Phantom `chatBroadcast` events kept firing** on their configured interval even after deleting
  the last broadcast message. Enabling the feature was never re-checked against whether there was
  anything left to actually say. *(needs deployment: `services/broadcast.lua`)*
- **DNF'd/finished participants' vehicles still weren't coming back**, even after the 1.3.0 fix:
  that earlier fix (defaulting `vars`/`paints` to `{}`) was a real, worthwhile bugfix but never
  actually the cause of the crash. Found via a debug-injected fake participant (simulating a second
  player without needing one) that the restore's spawn config used `format = 4` (the game's own
  *multi-vehicle* config wrapper, which expects a `vehicles` array the restore never provided)
  instead of `format = 2`, a real single-vehicle config. Every restore attempt was crashing the
  game's own spawn code on this, unconditionally. *(needs deployment: `services/raceGrid.lua`)*

## [1.3.0] - 2026-08-14

### Added
- **Race system** (the largest addition): full grid-based racing, solo hotlapping and
  head-to-head, with join/leave/ready/cancel/retire, gate-crossing detection, lap tracking, a
  leaderboard, DNF handling, configurable respawn strategies, and an in-world 3D gate/start editor
  with translate/rotate gizmos and edge-resize handles. Race authorship tracking (non-staff players
  can only edit/delete races they created). Configurable per-race defaults: laps, respawn strategy,
  joinable/multiplayer toggle, phase timers (grid timeout, ready timeout, countdown), DNF handling,
  and auto-spectate-on-finish. Finished/DNF popup feedback, vehicle restoration after a race ends,
  and a "Retire and spectate" option alongside "Leave". *(new server files
  `services/races.lua`, `services/raceGrid.lua`; needs deployment)*
- **Map voting**: `/votemap <name>` starts a vote (any connected player), `/votemap`/`/votemap join`
  toggles your own vote, `/votemap cancel` stops it (creator or staff). Passes at a majority
  threshold (min. 2 votes) within 30s, with a live status panel showing the target map, vote
  count, and countdown. A lone connected player switches instantly with no vote needed. *(new
  server file `services/mapVote.lua`, needs deployment)*
- **Vote-kick**: `/votekick <player>` starts a vote (staff excluded, they already have direct
  `/kick`), `/votekick`/`/votekick join` toggles your own vote (staff and the target can't vote),
  `/votekick cancel` stops it (creator or staff only). Passes at a majority of eligible voters
  within 30s, with a live status panel showing the target, vote count, and countdown. *(new server
  file `services/kickVote.lua`, needs deployment)*
- **Chat commands** ported from BeamJoy Free plus new additions: `/kick`, `/mute`, `/unmute`,
  `/ban`, `/tempban`, `/unban`, `/setgroup`, `/freeze`, `/engine`, `/tpfrom`, `/tp`, `/map`,
  `/race ready|leave|cancel|retire`. `/help` lists only commands the caller has permission for.
  *(server: `chatCommands.lua`, `players.lua`, `maps.lua`, `raceGrid.lua`, needs deployment)*
- **Teleportation**: "Teleport To" (self-directed, rate-limited via a configurable
  `Freeroam.TeleportDelay`, blocked mid-race, staff-exempt) and "Teleport From" (mod-permission
  server-relayed summon, no position data crosses the server) as two new player-list action
  buttons, plus `/tp`/`/tpfrom` chat command equivalents. *(server: `players.lua`, `config.lua`,
  needs deployment)*
- Draggable/resizable main and config windows, with position/size persisted per window.
- A reusable confirmation-modal component (`cmps/confirm`), used for a "discard unsaved changes?"
  guard when closing the config window or switching tabs with an unsaved race edit open, and for
  the race editor's "Save As New" name prompt.
- Race list now shows grid-slot count and distance under each race name.
- Typed values above a slider's normal maximum are now accepted (up to a hard cap) for gate
  width/height, laps (500), and all four race timer settings (600), not just draggable within the
  visible range.
- **Manual sector boundaries**: races can now flag specific gates as sector boundaries directly,
  instead of always relying on an automatic even-by-distance split. Falls back to the automatic
  split if nothing is flagged. Sector labels in both the editor and live race now show the actual
  sector number.
- **Gate nametag and visible-gate-count race options**: toggle floating "Gate N" labels on/off
  during a race, and optionally limit rendering to only the next N (1-5) upcoming gates for long or
  dense tracks. The lobby (grid) phase always shows every gate regardless, so players can see the
  full layout before starting. Defaults to nametags off, limited to 2 gates.
- Current sector is now shown in the race HUD, below the current gate.
- Live lobby countdown feedback ("Starting in Ns" once everyone's ready, "Lobby closes in Ns"
  otherwise) in the Activities tab's status panel. Previously only the COUNTDOWN phase had this.
- New `EditSafeZones` permission, gating both the SafeZones and General config tabs from players
  who don't hold it (previously always visible to anyone who could open Config at all). *(server:
  `services/permissions.lua`, `services/activityConfig.lua`, needs deployment)*
- An "Edit" button next to the Racing category on the Activities tab opens the race editor
  directly for any `EditRaces` holder, not just staff digging through the Config window's own tab
  list.
- "Ghost backmarkers" race option: once a leader gains a full lap of real gate-progress on a
  trailing racer, that racer ghosts (against everyone, since BeamNG has no selective collision)
  until they catch back up.
- "Disable collisions" race option: ghosts every participant for the entire race, not just the
  grid phase, regardless of solo/multiplayer participant count.
- Race names are now capped at 40 characters, enforced both in the editor's name field and the
  "Save as New" prompt.
- Configurable respawn-ghost protection: an explicit enable toggle (replacing an earlier
  slide-to-max "disabled" sentinel that could trip config validation) plus a configurable timeout
  (default 10s) and an extra buffer distance vehicles must clear before un-ghosting. A trailer
  attached to the local vehicle now bypasses this distance/contact check entirely, so towing
  something can't leave a vehicle stuck ghosted indefinitely. *(server: `services/config.lua`,
  needs deployment)*
- BeamJoy-Main's default on-screen position moved lower (~60% down the screen).

### Fixed
- **Unicycle/walking character was never visible**, in free cam or otherwise. Root cause:
  `camera.lua` was deleting the player's own unicycle the instant free cam engaged (the one
  camera mode the base game ever renders the walking character in at all).
- **Chat messages never appeared** after typing and sending, even though sending itself worked:
  this mod's own incoming-message handler had been stubbed to a no-op during an earlier BeamNG
  0.39 compatibility pass and never reconnected to anything. Now reuses BeamMP's own native
  `addMessage()`.
- **Non-staff players with a config-tab permission (e.g. edit-races) couldn't open the config
  window at all:** three separate places were blanket-checking staff status instead of the
  actual granted permission.
- **UI could silently go stale after a Lua→UI push:** the central event handler never wrapped
  work in an Angular digest, so a bound value could update internally but not actually re-render
  until some unrelated click or timer happened to trigger the next digest. Explained several
  separately-reported "this button does nothing" symptoms at once.
- **Race editor rotate gizmo would flip 180° instantly** on any rotation, even though the native
  gizmo widget itself rendered correctly the whole time. It was reading rotation from the gizmo's
  live transform every frame during the drag, which is unreliable mid-drag; now reads it once, at
  drag-end.
- **Drag-to-reorder gates in the race editor was broken three separate ways**: native HTML5 drag
  was swallowing the mouseup a custom drag tracker needed; the visual drop-zone padding was on the
  wrong (non-interactive) element; and a reordered index was being sent as a concatenated string
  instead of a number, corrupting the value server-side received.
- A generic `table.removeAll` helper was referenced but never actually defined anywhere in the
  codebase. It threw an error on every call.
- **"Finished screen disappears almost instantly":** every delayed popup-hide in the race runner
  was passing seconds where milliseconds were expected, firing near-instantly regardless of the
  intended duration.
- **Race grid timer/countdown values could be silently overridden or discarded** server-side:
  the countdown clamp didn't match the client's own allowed range.
- Menu/list scrolling felt sluggish. It was accelerating an element that never actually had anything
  to scroll; now finds the real scrolling ancestor.
- Players could ready up in a race with no vehicle spawned.
- Rapid clicks on a gate width/height number box's spin arrows only applied every other click.
- Slider drag-and-type editing had several rounds of regressions (values snapping, live update
  breaking); settled on a mode-toggle design (slider vs. typed entry, never both live at once)
  that resolved the whole bug class.
- The race editor's pinned header/toolbar could visually overlap the scrolling gate/start list;
  rebuilt as a real flex layout instead of a sticky overlay.
- Closing the config window via the ImGui menu (rather than the in-window close button) bypassed
  the discard-unsaved-changes prompt entirely.
- `MaxCars` server setting was silently forced to 200 on every server start regardless of the
  admin's actual configured value. *(server: `services/core.lua`, needs deployment)*
- `nametags.lua` was toggling collision on the player's current vehicle every single frame just
  to keep it out of the nametag hover raycast.
- A vehicle-model permission check (`onBJRequestCanSpawnVehicle`) had a Lua operator-precedence
  bug that silently disabled rejection of unlisted models.
- **DNF'd/finished players' vehicles never came back once the race ended:** confirmed from a live
  console capture (not just static tracing) that `core_vehicles.spawnNewVehicle` was crashing
  inside the game's own native spawn code (`bad argument #1 to 'ipairs'`) whenever the saved
  vehicle's `vars`/`paints` were `nil`, which is the normal case for a vehicle with no runtime
  tuning or custom paint (i.e. most vehicles, not an edge case). Both now default to empty tables.
- The very last participant to finish/DNF a race (whose own action completes the whole session)
  no longer has their own vehicle needlessly deleted for auto-spectate, since there's nobody left to
  spectate, and it would've just been restored again moments later anyway.
- **Real multiplayer race-start collision risk**: every participant transitioning from ghosted to
  solid together at the green light had a narrow window where two nearby cars could both perceive
  each other as "still ghosted, safe to ignore" and un-ghost simultaneously while overlapping,
  materializing solid inside each other.
- Camera would flicker every frame if the player tried to change camera during a race countdown.
  The forced-camera logic was cycling the camera ring one step at a time instead of jumping
  straight to the locked camera.
- The laps option was missing from the start-options panel for every race, even loopable ones.
  The trimmed race-list payload sent to the UI never actually included the `loopable` field.
- Ghost-timeout slider showed raw `{{...}}` template text instead of rendering: an invalid
  `{{}}`-interpolated value on a one-way expression binding (`<?`) threw a syntax error that
  aborted the rest of that component's compilation.
- **Toggling the global "Respawn ghost timeout" or "Collisions mode" setting visually reverted
  itself right after saving:** the broadcast that pushes config data to the UI never actually
  included the `Freeroam`/`Voting` sections at all, so any unrelated config save anywhere on the
  server reset those two accordions back to their hardcoded UI defaults.
- A player DNF'ing as the very last active racer didn't reliably end the session for everyone,
  including spectators. Several call sites weren't re-checking session completion after DNF/Leave.
- Race-info panel column misalignment, finally traced to a global stylesheet rule with higher CSS
  specificity than the panel's own table styles, silently overriding two earlier fix attempts.
- Sliders app-wide weren't resizing with their container: a custom element defaults to
  `display: inline`, so `width: 100%` had never actually applied to any `bj-slider` anywhere.
- Self-teleporting (both this mod's own "Teleport To" and BeamNG's native "drop vehicle at
  camera" action, bound to F7 by default) was still possible during a race's COUNTDOWN freeze, and
  an earlier partial fix incorrectly exempted staff/owner accounts from the block.
- BeamJoy-Main's default position change had no effect for anyone: a duplicated, never-updated
  hardcoded position table was what actually drove the rendered default, not the app's own
  manifest.
- Respawn-ghost distance's own un-ghost safety check retried forever with no bound, defeating a
  configured timeout entirely if a vehicle happened to be parked somewhere crowded; separately,
  disabling the timeout altogether left vehicles ghosted forever even when standing completely
  alone, since the code never actually attempted to clear the ghost in that mode at all.
- BeamNG's native vehicle recovery/rewind was still usable during a race's COUNTDOWN freeze.
- **Grid-session timer settings genuinely weren't taking effect** (previously listed below as
  unresolved). Root cause found: the joinable/multiplayer flag was resolved with a plain `OR`
  that couldn't represent an explicit "off" override, so unchecking Multiplayer for one attempt
  was silently ignored whenever the race's own saved default had it on, leaving the grid timers
  "active" for a session that should have been solo.
- "1/4 joined" and "Waiting for players" text no longer shown for solo (non-joinable) races.
- The spectate HUD timer only updated when the spectated racer crossed a checkpoint, instead of
  ticking smoothly every frame like the active-racer HUD already did.
- The ahead/behind gap indicator on the race HUD went blank for the entire stretch between a
  racer crossing the start/finish line and actually completing a full lap ahead, instead of
  showing a continuous value.
- The race name character-limit counter in the editor rendered off-screen regardless of window
  width.
- Dragging a gate's width/height handle over uneven terrain now only ground-snaps once, at
  mouse-release, instead of risking a mid-drag jump.
- Chat message color pickers removed from the settings menu: non-functional since chat moved to
  native BeamMP message rendering, which only supports its own fixed color codes.

### Known unresolved
- The race editor's height-resize handle is unusable when the camera is pointed at open sky with
  nothing behind the handle. Four fix attempts so far, none successful; paused pending better
  diagnostic evidence.
- "Ghost backmarkers" doesn't appear to actually ghost a lapped racer in testing. The entire
  server/client chain reads correct in isolation and no bug has been found yet; needs a console
  capture from a repro where a real lap gap should have triggered it.
