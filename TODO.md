# TODO / planned features

Ideas that have been discussed and design-approved but deliberately not started yet, or genuine
open follow-ups flagged during other work. Not a backlog of every idea ever mentioned, just things
worth picking up later without re-deriving the design/investigation from scratch. Completed work
belongs in CHANGELOG.md, not here.

## Traffic vehicle pooling

**Status:** planned, not started. User asked to add this to the plan rather than build it now.

Agent's Traffic Tool has a "Use Pooling" option that raises `gameplay_traffic.setActiveAmount(...)`,
letting native's own `core_vehicleActivePooling` keep a larger roster of traffic vehicles around
while only fully simulating ("active") the ones near the player, swapping others in/out cheaply as
inactive/dormant as the player moves. BJS's own traffic system doesn't use `gameplay_traffic` at
all for spawning; it spawns and tracks every traffic vehicle itself (`M.vehs`), fully active and
network-synced to every connected player, with no dormant reserve of any kind.

There's no existing "pool" in BJS's architecture for a setting like Agent's to plug into. Building
one would mean a genuinely new subsystem: BJS would need its own concept of an inactive/dormant
vehicle reserve, separate from the always-active spawned set it has today, comparable in scope to
the parked-vehicle work already done (see CHANGELOG v1.8.59). Given BJS's traffic is inherently
per-player and network-synced (unlike native's single-player-only pooling), a real design pass is
needed on what "inactive" should even mean here before implementation: whether inactive vehicles
still need to exist as real synced entities other players can see (defeating most of the point) or
whether they'd need to be a purely local-client illusion until "activated," and how that
interacts with the existing per-player balancer.

## Weather syncing

**Status:** planned, not started. User asked to add this to the plan rather than build it now.

`environment.lua` currently syncs time-of-day (`timeSync`) and gravity (`gravitySync`) between
players, each with its own toggle + wrapped native setter (`core_environment.setTimeOfDay`/
`setState`), plus a periodic re-apply in `onUpdate`/`updateToD`/`updateGravity` to keep drift-prone
native state pinned to the shared `M.data`. Weather (cloud cover, fog, precipitation, wind, etc. —
all present on native's own `core_environment.getState()`/`setState()`, see `res.cloudCover`,
`res.fogDensity`, `res.numOfDrops`, `res.windSpeed`, `res.groundWind` in the engine's
`core/environment.lua`) has no BJS sync at all today: whatever a player's own client happens to
have set locally (or the level default) is what they see, independent of everyone else.

A real implementation would follow the same shape already established for ToD/gravity: a
`weatherSync` toggle + a synced weather-data table in both client and server `environment.lua`,
hooked into the existing `interceptEnvState` wrap (which already receives the full native
`state` object on every native environment-panel change, weather fields included) and into
`onUpdate`'s periodic re-apply loop. Needs a design pass on which weather fields are worth syncing
(cloud cover / fog / precipitation probably yes; things like cloud wind direction or altitude
probably not worth the bandwidth) before touching code.

## Moon jump / date rollover at midnight

**Status:** investigating, blocked on an engine test.

The sky (`core/celestial.lua`) is stateless: every frame it positions the sun, moon and stars from
the engine's current `time` + date (`whenToJD`). Nothing in the game's Lua ever advances the date
when the clock passes midnight, so crossing midnight on a fixed date steps the sky's instant back
a day, and the moon (moves ~12-13 degrees/day) visibly jumps. But the user found the jump only
happens after a full played-through cycle, NOT when crossing midnight via the panel's preset
times, which the stateless-Lua explanation alone can't produce. So the engine's C++ TimeOfDay
likely does something with the date (or time) during free-running playback that isn't visible in
Lua or the panel.

Next step: in vanilla single-player, `core_environment.setTimeOfDay({dayLength = 300, play =
true})`, then `dump(core_environment.getTimeOfDay())` just before midnight, just after, and after
a full cycle, and compare `year/month/day/time`. Then: if the engine advances the date itself,
BJS's synced date should follow it (currently written only on change, so it doesn't fight it);
if not, implement rollover in `envClock.advance` (count midnights crossed since the epoch,
advance the synced date; the per-date segment cache already supports a date that moves).

## Sim pause: replace the deliberate-error block with a function wrap

**Status:** planned, not started. User asked to add this to the plan rather than build it now.

Pressing J logs a `*** FATAL LUA ERROR ... BeamJoy needs to prevent game from toggling pause (this
error is not a real one)` with a full stack trace every time. It's intentional and harmless (inherited
from the original mod): native `simTimeAuthority.togglePause` (`lua/ge/simTimeAuthority.lua:229`)
runs the `onTogglePause` hook and then pauses locally, with no supported veto (hook return values
are ignored), so client `environment.lua`'s `onTogglePause` sends `simPause` to the server and then
throws to abort the local pause. The server's `sendCache` reply then applies the pause for everyone.
Works, but the log noise looks like a real crash to anyone reading a BeamNG.log.

Cleaner: wrap `simTimeAuthority.togglePause` itself in `onInit` (store the original in
`M.baseFunctions` so `RollBackNGFunctionsWrappers` restores it on unload, same as the
`core_environment` wraps). The wrapper calls the original during replay playback (local pause stays
local there, matching the current `core_replay.state.state ~= "playback"` check) and otherwise just
sends `simPause`, no error. The J binding executes `simTimeAuthority.togglePause(true)` as a string
at press time (visible in the traceback), so a replaced function is picked up. Then remove the
throwing `onTogglePause`. Worth checking whether anything else (radial menu, UI pause button) calls
`simTimeAuthority.pause` directly instead of `togglePause`. `updateSimSpeed`'s per-frame re-sync
already reverts those, but they'd bypass the server request.

## Freeroam / Bus lines — later phases

Phase 0-2 (energy stations, garages, bus lines) are shipped — see CHANGELOG. Scope for what's next:

- **Phase 3 — deliveries.** Package + vehicle delivery, improving on BJI's
  `ScenarioDelivery{Package,Vehicle,Multi}`. Design agreed 2026-09-24. Phase 3 mockup (Jobs tab,
  depot prompt and convoy invite, job board, convoy lobby and results as HUD panels):
  https://claude.ai/artifact/THviDWY8eYTf4KDnVzQ1p1
  - **Build order** (each slice testable in-game before the next builds on it). Written so the
    work can be picked up cold after a context reset: file names, wire events and what's left.
    1. **Delivery points** - DONE, tested in-game (import + first save ~10 s).
       - Server `services/deliveryPoints.lua` (`<map>_deliverypoints.json` + `<map>_deliveryroutes.json`,
         routes flat `[fromId, toId, metres]`, `deliveryPointsSave` / `deliveryRoutesRequest`).
       - Client cache `beamjoy/deliveryPoints.lua` ; editor `ui/deliveryEditor.lua` as the
         "deliveries" section of `ui/freeroamEditor.lua` ; sidebar
         `windows/config/freeroam/deliveries/app.html` (component `bjConfigDeliveries` in
         `windows/config/freeroam/app.js`).
       - Point = `{id, name, pos, radius, provides[packages|vehicles], receives[packages|cars|trucks],
         slots[{pos,dir}] (max 4, only when provides vehicles)}`.
       - Import: the level's facilities + every `*.sites.json` parking spot ; slots 2-4 filled
         from nearby level parking spots (60 m, car/truck sized, 4 m apart).
    2. **Solo package delivery** - BUILT (client 2497+, server 2356), in testing.
       - Server `services/deliveries.lua`: boards per depot (lazy, `OffersPerDepot`, rotation,
         min/max route), jobs per playerID (server clock, fail at 2x target), position checks via
         `MP.GetPositionRaw` (skipped when unavailable), scoring, totals in
         `BeamJoyData/db/deliveryScores.json`. Wire: `deliveryBoardOpen/Close`, `deliveryStart`,
         `deliveryArrive`, `deliveryAbandon`, `deliveryStateRequest` -> `deliveryBoard`,
         `deliveryJob`, `deliveryStartRefused`, `deliveryArriveRefused`, `deliveryEnded`,
         `deliveryResult`. Config key `Deliveries` (services/config.lua + Config > General >
         Deliveries panel).
       - Client `beamjoy/delivery.lua` (POIs, prompt, board/HUD/results state, run tick, zone
         ghosting reason "delivery"), `beamjoy/uiNav.lua` (MenuIndependent action maps while a
         window is open), `beamjoy/recoveryPolicy.lua` (shared with Infected: resets -> in-place
         recovery ; `claim(name, {active, allowRecovery, vehicle, blockRepair})`).
       - UI `windows/deliveryBoard` (also defines the `beamjoyDelivery` service + the shared
         `.bj-dlv` styles), `windows/deliveryHud`, `windows/deliveryResults`.
       - Fixed after first test (client 2498): buttons needing two presses (press tracker missed
         the release that closed a window) ; B/Y/A also firing the game's own global UI-nav
         defaults (pause menu, Big Map, Crossfire) - blocked with a `ui_nav` capture listener ;
         editor labels staying in the world after leaving the Freeroam tab.
       - Still to verify live: full run end to end, gamepad not also driving the car while a
         window is open, the server position check, Infected resets unchanged.
    3. **Vehicle delivery** - BUILT (client 2500, server 2357), untested in-game. Pool:
       `beamjoy/deliveryPool.lua` + server `deliveryPool.json` (`deliveryPoolSave`,
       `deliveryPoolBlacklist`, admin-only `caches.deliveryPool`), panel in Config > General >
       Deliveries. Spawn at a free slot in `delivery.lua` spawnDeliveryVehicle (waits up to 20 s for
       the vehicle to register), conditions via `partCondition.initConditions` + 'getPartConditions'
       at arrival (3 s timeout). Still to verify live: the spawn facing, part conditions actually
       readable in MP freeroam, garages refusing during the job. The design notes below are what
       was built:
       - Server: offers of kind "vehicles" from depots that provide vehicles and have >= 1 slot, to
         points receiving cars/trucks ; the offer carries the model/config picked server-side from
         the pool, matched to the destination (cars vs trucks by Body Style / Type).
       - Pool = stock vehicles + server-distributed mods minus a new vehicle-delivery blacklist
         (separate from `ModelBlacklist`). The server has no vehicle list, so an admin's client
         uploads the eligible pool (model, config, label, type/body style) - same idea as the
         route measuring. Admin UI for the blacklist (reuse the model-blacklist picker).
       - Start: replace the player's car with the delivery vehicle at a depot start slot
         (`beamjoy_vehicles` spawn/replace like raceRunner/hunterRunner do) ; the job ties to the
         new vid ; you keep the vehicle afterwards.
       - Damage: broken parts from `getPartConditions` (integrity 0) counted from the job's start,
         bands Pristine / Minor (<=5%) / Moderate (<=15%) / Heavy -> factor 1.0 / 0.85 / 0.6 / 0.3.
         Verify part conditions work in freeroam MP ; fallback `beamstate.damage`. Client reports
         the counts at arrival ; server applies the factor and shows it in the results breakdown.
       - Recovery claim with `blockRepair = true` ; garages blocked for the job
         (`onBJRequestStationInteraction` kind "repair"), refuelling allowed.
       - Board/results already take `kind` ; add the vehicle row ("Vehicle, one per player") and
         the condition line.
    4. **Convoys** (co-op, up to 4 ; one piece of cargo each) - BUILT (client 2502, server 2358),
       untested in-game. Server `services/deliveries.lua` CONVOY LOBBY / CONVOY RUN sections
       (`M.convoys`, `M.memberOf`), wire `deliveryConvoyCreate/Join/Ready/StartNow/Leave/
       InviteList/Invite/InviteReply`, `deliveryVehicleReady` -> `deliveryLobby`,
       `deliveryLobbyClosed`, `deliveryConvoys` (broadcast of forming lobbies), `deliveryInvite`,
       `deliveryInviteClosed`, `deliveryInviteList`, `deliveryConvoyGrace`, `deliveryConvoyResults`.
       Config `Deliveries.LobbyDuration`. Client `delivery.lua` CONVOY LOBBY / CONVOY INVITE
       sections ; UI `windows/deliveryLobby`, `windows/deliveryInvite`. Unstuck = `onUnstuck` in
       delivery.lua. Changed after review (client 2503, server 2359): invites and the away-from-
       depot lobby take the pad only after the game's `gameplay_interact` chord (RB + Y, Shift + E ;
       GE hook `onGameplayInteract`) focuses them, and members no longer have to be at the depot
       when the convoy leaves (`bringToDepot` moves a package member's car to slot i or next to
       the depot ; vehicle members spawn on slot i as before). Still to verify live: two clients
       end to end, cohesion samples actually getting positions (`MP.GetPositionRaw` with the
       reported vids), the interact chord reaching `onGameplayInteract` while driving in MP,
       Unstuck's landing spot.
       Follow-ups (client 2504, server 2360): multi-stop package offers (`offer.stops` /
       `legMeters`, `extendStops`, `deliveryLegArrive` -> `deliveryLeg`, STOP_BONUS 1 / 1.15 /
       1.3 ; stop-to-stop routes kept by deliveryPoints `isRoutePair`, measured by the editor's
       `isStopPair`), ready-countdown restore (`updateReadyCountdown`, `readyHold`,
       `leaderStarted`), VEHICLE_SYNC_SEC = 8 (vehicle frozen until the clock starts),
       LobbyDuration default 180, per-config delivery blacklist (`pool.configBlacklist`). The design notes below are what was built:
       - Server: a convoy = a job with a leader + members, formed at a depot ; lobby state
         pushed to members ; ready-up countdown (reuse the race grid's countdown pattern) ; "Start
         now" (Y) for the leader.
       - Join paths: depot drive-up prompt (X: Join <leader>'s convoy), the board's "Convoys
         forming here", later the Jobs section. Convoy invite from the lobby (X opens a player
         picker ; invitee gets an A/B toast that expires).
       - Vehicle convoys: one start slot per member (max players = slot count).
       - Grace period after the first delivery: 20% of the target, 45-180 s. On-time members get
         the convoy bonus (+10% per extra player), late ones base score only ; hard deadline 2x
         target fails the rest ; nobody waits on one player.
       - Cohesion: server samples `MP.GetPositionRaw` once a second ; share of samples within
         200 m of another member (first 20 s and anything after the first arrival excluded) ;
         bonus = share x 20%.
       - UI: lobby and results as HUD panels per the mockup (A Ready, Y Start now, X Invite,
         B Leave) ; results table with every member.
       - **Unstuck button** (user request), vehicle deliveries (solo and convoy): an "Unstuck"
         button on the delivery HUD, next to Abandon, that moves the vehicle to the nearest road,
         keeping its damage. Use the unwrapped `spawn.teleportToLastRoad(veh, {resetVehicle =
         false})` via `beamjoy_inputs.baseFunctions` (what the pause menu's own "recover to
         road" button calls ; the recovery claim denies RECOVER_LAST_ROAD for every other path).
         Only when nearly stopped (under ~2 m/s), with a cooldown (~30 s) so it can't be used
         to skip ahead ; the job's 150 m teleport check must allow the jump (grace the next
         position check, as spawn grace does). Say so on the button when it's unavailable
         ("Stop first", "Ready in 12 s"). Asked for vehicle jobs ; offering it on package jobs
         too is a one-line change if wanted. Locale keys under `beamjoy.delivery.hud.unstuck*`.
    5. **Jobs section + leaderboards** - BUILT (client 2509, server 2361), untested in-game.
       UI `windows/deliveryJobs` (`bjDeliveryJobs`, its own window) plus a summary + "Open jobs"
       section in the main window (`windows/main/activities/jobs`, `bjMainJobs`) ; delivery.lua
       JOBS SECTION (`openJobsWindow(pad)` / `closeJobsWindow`, pad only from the prompt's "All
       depots" entry, `uiNav` owner "deliveryJobs") ; server `deliveryDepotsRequest` -> `deliveryDepots`,
       `deliveryLeaderboardRequest` -> `deliveryLeaderboard`. Focus control: `bjFocusNotification`
       in core/input/actions/beamjoy.json, defaults in settings/inputmaps/xidevice_beamjoy.json
       (RB + X) and keyboard_beamjoy.json (Shift + J), handled by delivery.lua
       `onBJFocusNotification`. **When the main window goes controller-driven, it joins that same
       control, AFTER notifications (invite, lobby) in the focus order.**
       - Main window > Activities > Jobs: every depot (filter Packages / Vehicles), distance, open
         job count, convoys forming, Set GPS, Join convoy. Controller-driven (d-pad, A Set GPS,
         X Join convoy, Y filter, B close) ; a controller reaches it ONLY from the depot prompt's
         Y (All depots). The existing main window stays mouse-driven.
       - Leaderboard view per type (packages / vehicles) from `deliveryScores.json`, own rank
         pinned.
  - **Depots and points.** Admin-placed delivery points tagged with what they send/receive; a
    depot is a point that offers jobs. Two-leg jobs: the depot is the pickup, then the drop-off.
    Drop-offs use a zone with a 3-second hold (the hold already forces a stop; no separate
    stationary check).
  - **West Coast USA import** of the game's own ~65 delivery facilities
    (`levels/west_coast_usa/facilities/delivery/*.facilities.json`, `logisticTypesProvided/Received`).
  - **Route lengths** between all point pairs computed once by the admin's client when points are
    saved, stored with the points; no GPS route calls at runtime.
  - **Jobs tab** (Activities): every depot, filterable by Packages / Vehicles, with distance, open
    job count, any convoy forming, Set GPS and Join convoy. Replaces "GPS to nearest depot".
  - **Job board** at each depot (drive-up prompt "View jobs"): 3-5 server-generated offers, shared
    by everyone, replaced as soon as one is taken and rotated every few minutes. Destinations
    limited to the server's min/max route distance. Target time = route length / reference speed.
    Styled after vanilla windows (tokens pulled from `ui/ui-vue/dist/base.css`: translucent
    `#0009` surfaces, cool-grey scale, `#f60` for lines and selection, `#c24b00` primary buttons,
    Overpass titles with bold-italic big buttons, Noto Sans body).
  - **Vehicle choice**: pool = stock vehicles plus server-distributed mods, minus a dedicated
    vehicle-delivery blacklist (separate from the global spawn `ModelBlacklist`), uploaded by the
    admin's client since the server has no vehicle list. Drop-offs tagged cars / trucks / any to
    match vehicles to destinations by model type and Body Style. No "not installed" state: every
    player always has every pool vehicle.
  - **Convoys** (co-op, up to 4): one piece of cargo per player (vehicle delivery = one vehicle
    each, package = one package each in their own car). Formed at a depot with a lobby (ready-up
    countdown reused from races); others join through the depot's drive-up prompt, the board's
    "Convoys forming here", the Jobs tab's Join convoy, or a **convoy invite** from the lobby
    (X in the lobby panel opens a player picker; the invitee gets an A/B toast that expires). Vehicle delivery replaces your car at a
    depot start slot when the job starts; you keep the delivered vehicle afterwards.
  - **Grace period**: the first delivery starts it (default 20% of the target time, 45-180 s).
    On-time players get the full score plus the convoy-size bonus; late players only their base
    score; a hard deadline (2x target) fails anyone left. The group is never blocked on one player.
  - **Resets** (vehicle delivery; package delivery too, to stop reset-teleport exploits): like
    Infected, every reset becomes an in-place recovery that never repairs; reload and repair
    blocked; garages blocked during vehicle delivery, refuelling allowed. Share the code with
    Infected in one module instead of copying it.
  - **Ghosting**: any vehicle inside a pickup or drop-off zone is ghosted (new `delivery` ghost
    reason), still applied under the "forced collisions" admin setting, like races.
  - **Damage** (vehicle delivery): broken parts via the game's part conditions (`getPartConditions`,
    integrity 0), measured from the job's start, banded Pristine / Minor (≤5%) / Moderate (≤15%) /
    Heavy. Verify in-game that part conditions work in freeroam MP; fallback `beamstate.damage`.
  - **Scoring**: base (100 per route km, min 50) x time (target/actual, 0.5-1.25) x condition
    (1.0 / 0.85 / 0.6 / 0.3) x convoy size (+10% per extra player, on-time only) x cohesion (up to
    +20%). Recoveries shown, not penalized.
  - **Cohesion bonus**: per player, sampled once a second by the server (`MP.GetPositionRaw`):
    the share of samples where you were within 200 m of at least one other convoy member. First
    20 s and anything after the first arrival excluded. Bonus = share x 20%, so drifting away for
    a while only reduces it proportionally.
  - **Leaderboards**: each player's total score across every delivery of a type (one board for
    packages, one for vehicles), all maps combined, own rank pinned.
  - **Controller support for everything new in Phase 3.** Menus that already exist in the current
    build stay exactly as they are, mouse-driven (the user will redesign them later): the main
    window's Main/Settings tabs and the existing Races, Bus lines, Hunter and Infected sections.
    Controller-driven:
    - the new **Jobs section** in the main window's Activities tab (d-pad between depots, A: Set
      GPS, X: Join convoy, Y: cycle the filter, B: close). A controller reaches it ONLY through a
      depot's drive-up prompt (Y: All depots), which opens the main window straight on the Jobs
      section. No LB/RB section switching: that would mean making the existing main window's tabs
      controller-driven, which waits for the user's main HUD redesign;
    - the new **job board** window (d-pad browse, A: Start convoy, X: Start solo, B: close);
    - the **convoy lobby and results** as HUD panels with bound actions (A: Ready / next job, Y:
      Start now, X: Invite player, B: Leave / close);
    - the depot's native drive-up prompt (already controller-friendly).
    Use the game's own menu actions (`menu_item_*`, `menu_tab_left/right`, back) without the
    gamepad also driving the car. First try opting into vanilla's own spatial navigation
    (`bng-nav-item` / `menu-navigation`); fall back to a BJS action map pushed only while a BJS
    window has focus.
- **Main window redesign** (started 2026-09-25): replaces the old tabbed main window with something
  streamlined, unobtrusive and vanilla-looking, controller-driven through the Focus notification
  control (after notifications in the focus order). Mockups:
  https://claude.ai/artifact/CGvMdFLWjZdj1J2nTNe18C. The user picked the **edge rail** (revision 3
  page: player and staff versions of Home, Start a race, Race lobby, Leaderboards, Players and the
  full window; race start = laps / vehicles / respawns up front, the rest under Advanced settings,
  X start solo, A open lobby). The staff Config window is out of scope here (its own session).
  Branding: **A1 "signal tile"** (orange rounded tile, three rising bars knocked out, Overpass
  Italic 900 "BJR"), picked on the canvas's Branding page.
  - **Part 1 - DONE (client 2512), untested in-game:** rail (`windows/main/app.html`), side
    panels, full window shell, Happening now (`windows/main/now`, service `beamjoyNow`), Vote
    panel (`windows/main/vote`), invite placed beside the rail/panel (`$rootScope.bjMainLayout`).
    Panels still host the OLD Activities / Players / Settings components unchanged.
  - **Parts 2 and 3 - DONE (client 2513), untested in-game:** races restyled (start form with
    Advanced settings, X solo / A lobby, lobby card with crown + ready tags ; `starterID` added to
    BJRaceSessionStatus), a `.bjr` skin in `windows/main/app.html` restyling the older hosted
    components (hunter, infected, bus lines, settings, moderation), expandable player rows
    (`main/players-list`, `player-line` takes `full`), full window Home = Now / Players / You
    (`windows/main/you`), Leaderboards tab (`windows/main/leaderboards`), Change nickname
    (login prompt `{change: true}` ; `communications/ui.lua` only runs proceedAfterLogin once).
  - **Still open from parts 2/3:** a Crew tab needs the Crews feature itself (see Phase 3
    follow-ups), not just UI. Staff Cancel on any lobby, the staff Everyone's vehicles block,
    Change settings in the race lobby and the Bus lines restyle are DONE (client 2522 / server
    2365), untested in-game.
  - **Part 4 - DONE (client 2514), untested in-game:** `beamjoy/mainNav.lua` owns the Focus
    notification control (order: delivery notification, then main window ; delivery exposes
    notificationFocusable / notificationFocused / setNotificationFocus), `uiNav.acquire(owner,
    extraActions)` (LB/RB = `uiNav.TAB_ACTIONS` for the full window), Angular pad levels rail /
    panel / full in `windows/main/app.js` (generic focusables walk, `data-pad-x` for a panel's X
    action). Not done: A directly opening a lobby from the start form (A presses the focused
    element instead), text inputs need a keyboard, bj-select dropdowns aren't pad-driven.
  - **Fix round (client 2516), untested:** spatial pad nav (`findDir` in windows/main/app.js),
    Jobs + convoy lobby folded into Activities > Jobs (`windows/main/activities/jobs` ;
    standalone windows/deliveryJobs and windows/deliveryLobby deleted ; the convoy lobby at the
    depot takes the pad through `mainNav.autoFocus("lobby", ...)`, "All depots" through
    `mainNav.focusOn("play", "jobs")`), race lobby rebuilt on the shared `.bjr-lobby` layout,
    `beamjoyNow.activeSection()` filters Activities, `beamjoyNow.raceDraft` keeps a start form.
  - **Round 2 (client 2519 / server 2362), untested:** notification stack (`beamjoy/notices.lua`,
    `windows/notices` ; the convoy invite renders inside it), lobby invites + Start now for race /
    hunter / infected (`services/lobbyInvites.lua`, `raceStartNow` / `hunterStartNow` /
    `infectedStartNow`, picker `windows/main/lobbyInvite`), hunter / infected lobbies on
    `.bjr-lobby`, draggable rail with side detection (`railRect` / `side()` in windows/main),
    dropdown pad support (`cycleSelect`), `data-pad-b`, mouse click takes the pad
    (`BJMainPadFocus`), menu closes on `beamjoyNow.runningKey()` change, binding hint
    (`mainNav` pushBinding -> `$rootScope.bjFocusLabel`).
  - Known debt: the hosted old components register `$rootScope.$on` listeners without cleanup,
    and panels now mount/unmount them often ; fix as each is restyled.
  - **Staff player panel in the full window keeps the player-wide buttons.** Revision 3's full
    window now uses the small menu's expandable player rows (actions, vehicles with per-vehicle
    buttons, moderation box). When building it, the full window's staff version must ALSO keep the
    player-level buttons the small menu leaves out, i.e. the ones acting on all of that player's
    vehicles at once, matching today's player-line actions: Freeze all / Unfreeze all, Stop all
    engines / Start all engines, Remove all, Queue deleted vehicles to respawn (plus Bring here /
    Teleport to / Spectate). The small side menu doesn't need them. The Jobs window (`windows/deliveryJobs`) folds into it later.
- **Phase 3 follow-ups, after everything else in Phase 3:**
  - **Parking spots as a drop-off option**: per point, a zone or 1-4 parking spots, using the
    game's `gameplay/sites/parkingSpot.lua` `checkParking` (all four corners inside, aligned
    within 45°, nearly stopped) and `precisionParking.lua` grades for a parking factor
    (perfect 1.15 / good 1.10 / ok 1.05 / bad 1.0). A job's max players = its drop-off's spot
    count. West Coast USA facilities reference real parking spots in `*.sites.json`.
  - **Crews - BUILT (client 2522 / server 2365), untested in-game:** `services/crews.lua`
    (in memory, by player name, pullIn / pullSize / sameCrew called by the grids and
    deliveries), `beamjoy/crews.lua`, `windows/main/crew` (service `beamjoyCrew`), crew invites
    in `beamjoy/notices.lua`. Not done: crew markers (none exist yet, so nothing to hide during
    hunts / infected rounds). Original spec below.
    Spec: a persistent party (max 4 to start) with its own Crew tab next to Activities on the
    main HUD. Join once and you're pulled into the leader's lobbies (deliveries, races, hunts,
    infected) automatically when free; busy members skip that one. Not in a crew: the tab lists
    every crew to ask to join or join. A job smaller than the crew can't be started with the crew.
    In Hunter/Infected, roles stay random across everyone, and crew markers must be hidden during
    rounds so crewmates can't track a fugitive or spot an infected crewmate.
  - **Crew invites**: extend Phase 3's convoy invites to crews (player context menu, Crew tab
    search), with its own frontend design pass.
- **Phase 4 — derby.** A full 4th competitive gamemode (`services/derby.lua` +
  `services/derbyGrid.lua` + `derbyRunner.lua` + HUD/countdown/results, arena browse-list editor).
  Bigger than phases 1-3 combined.
- **Phase 5 — polish.** Quick-travel + GPS-to-nearest wiring, per-type legacy BJI import (most of
  this is already done for stations/garages/bus lines — this would be the remaining activity
  types).

Reference source for native API research, if picking any of these up:
- Current game: `E:\Steam Library\steamapps\common\BeamNG.drive\lua\ge\extensions\` -
  `gameplay/markerInteraction.lua`, `gameplay/playmodeMarkers.lua`, `gameplay/rawPois.lua`,
  `gameplay/markers/missionMarker.lua`, `freeroam/gasStations.lua`, `freeroam/facilities.lua`,
  `ui/missionInfo.lua`.
- BJI (UX/process shape reference only, not the marker layer - BJI's own `InteractiveMarkerManager`
  predates a native marker-system rewrite and isn't portable 1:1, see CHANGELOG 1.10.0):
  `X:\beam\essentials\beamjoy-2.0.8` -> `Client/BJI.zip` -> `StationsManager.lua`,
  `ui/windows/ScenarioEditor/{Stations,Garages,BusLines}.lua`.

## Hauling: trailer delivery and tow trucks (future version, not Phase 3)

**Status:** planned for a later version. User asked to add this to the plan, not this version.

- **Trailer delivery.** Hitch a spawned trailer at a pickup and arrive with it still coupled. West
  Coast USA's own delivery facility data already has `trailerSpotNames` for hitch points.
- **Tow truck mode** (the user's idea): a "hauling" gamemode where a tow truck recovers a broken-down
  or abandoned vehicle and brings it to a garage or yard. Likely shares trailer delivery's
  "coupled cargo" checks.

## Rideshare / taxi, and fragile cargo (future version)

**Status:** planned for a later version (already on the README's planned-features list).

- **Rideshare / taxi.** Pick up and drop off passengers.
- **Fragile cargo** (goes with rideshare): score how carefully cargo or passengers are carried,
  from damage gained during the job plus sudden g-force spikes, instead of BJI's pass/fail
  "pristine at the end" check. The same comfort score would work for passengers. Not yet confirmed
  how easily vehicle g-force data can be read from the game side.

## Bus lines — open follow-ups (not yet built)

- **Stationary-hold requirement.** The stop-hold check is purely radius-based today (no velocity
  check) - a bus could satisfy a wide-radius stop's hold while still rolling through it. Open
  question whether this is actually wanted before implementing.
- **`BusStopHoldDuration` has no config UI.** `busRun.lua` already reads
  `Freeroam.BusStopHoldDuration` (default 3s) but nothing writes it yet - fixed at 3s for every
  server until a config row is added.
- A bundled example bus line for a map or two.
- "Add every available activity to the Big Map with its own start position" - user asked to skip
  this for now; open question of what to do about duplicate start positions if it's picked back up.

## Vehicle interactions: late-join latch state

**Status:** open follow-up to the built vehicle interactions (doors, hood, buttons on other
players' cars, client build 2573). BeamMP doesn't resend latch state to late joiners or when a car
streams in, so a door left open shows closed to them. BJ could track open latches per vehicle and
replay them on join/spawn.

## Freeroam: player-vs-player police pursuits

**Status:** planned, not started. User asked to add this to the plan rather than build it now.

Sandbox's `beamjoy/pursuit.lua` only makes a random traffic car flee from a police player (its own
timer, no offenses). BeamJoy 2.0.9 had real player-vs-player chases, built on the game's own police
system: `BJI/managers/PursuitManager.lua` in `X:\beam\essentials\beamjoy-2.0.9\BJI.zip`, server side
in `X:\beam\essentials\beamjoy-2.0.8\Server\BeamJoyCore` (`rx/ScenarioRx.lua` PursuitData /
PursuitReward, `managers/PlayerManager.lua` onPursuitReward). Reference only, don't port it 1:1.

How theirs worked:
- Every vehicle registered with `gameplay_traffic`, with a role : the player's own police car
  (`veh.isPatrol`) "police", other players' cars "standard", traffic AI and ghosts "empty". The
  game's police logic (`gameplay_police`) then notices offenses and starts pursuits by itself.
- The game's pursuit events (start / arrest / evade / reset) relayed through the server to the
  police and fugitive clients. No start against AI, police cars, an idle car (owner not in it),
  ghosts, during a server activity, or with no police car on the server.
- Police : "suspect fleeing" message and sound, GPS to the nearest target, auto lightbar, several
  targets at once. Fugitive : message and sound, resets blocked while chased.
- Arrest : fugitive frozen 5 s, ticket/arrest message with the offenses, then "drive away".
- Rewards : reputation (ArrestReward for police within 10 m, EvadeReward for the fugitive).
- Reset on server activity start, going ghost, disconnect, vehicle deleted.

Open questions before building:
- Sandbox has no reputation : count arrests/escapes, a leaderboard, or no reward.
- How it sits with the existing traffic pursuit tick (both on, or one replaces the other).
- Off during every activity, like the traffic pursuit tick (`navigation.inActivity`).

## Races: rejoin grace period after a disconnect

**Status:** planned, not started. User asked to add this to the plan rather than build it now.

Today a racer who disconnects mid-race is marked DNF on the spot (`raceGrid.lua`
`onPlayerDisconnect`, RACE branch) and can never get back in. Fine for a 5-minute sprint, fatal for
endurance racing: a reported test case was a 40-lap race on a 37-mile lap (time to beat 31 hours),
where a game crash, launcher hiccup or short internet drop after 20 hours of driving throws the whole
race away. Over that long with several players, at least one disconnect is close to guaranteed.

Agreed design:
- On disconnect during RACE: mark the participant "disconnected" (with the time) instead of DNF and
  keep their entry. Their race clock keeps running (it's the shared clock from the green light,
  `session.goAtMs`), so time lost while away is the penalty. After the grace period runs out, DNF
  them exactly as today.
- Grace period: a per-race setting (e.g. 10 minutes default), alongside the other race settings.
- Reconnect gets a NEW playerID, so match by BeamMP player name and re-key the participant entry
  (`session.participants` is keyed by playerID) to the new ID, then push the session.
- The race must not end while anyone is still inside their grace period (`checkSessionComplete`).
- Client resume path in `raceRunner.lua` (a RACE-state session arriving while not in one): the
  player's car was deleted by BeamMP on disconnect, so spawn it at their last crossed gate
  (`lastCrossedGate`, same target the "lastcheckpoint" respawn strategy uses), enforcing the race's
  vehicle restriction; reset `M.lastLy`; resume timing on the shared clock. Must wait for a fresh
  `beamjoy_clockSync` estimate first, or the local fallback clock would restart the timer at zero.

Other systems that need a "disconnected" state: HUD standings row and race info panels (plus locale
strings), crews' "busy" status and lobby invites, spectators watching someone who drops,
Discord race results ("disconnected" vs "retired"), backmarker ghosting.

Open decisions: grace length/default; whether a rejoined racer's time can set a personal best or
server record. Server restarts are out of scope: sessions are memory-only and the shared clock
resets with the server, so hosts should disable scheduled restarts during an endurance race.

Best done after the race update-size rework (server-side gaps, ID-list standings, history only at
the finish), so the resume path is built against the final payload format.
