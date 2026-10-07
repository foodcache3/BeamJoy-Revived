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

## Weather sync: follow-ups

**Status:** open follow-ups to the built weather sync (client 2574 / server 2400 : "Sync weather"
toggle, an admin's clouds / fog / wind from the game's own Time and weather panel applied on every
client).

- **Rain.** The game's panel has no rain control, so `numOfDrops` (core_environment's
  `setPrecipitation`) isn't synced. Would need a BJS control (config panel slider). Only maps with
  a `Precipitation` object can rain: West Coast USA, East Coast USA, Italy, Jungle Rock Island,
  Small Island, Industrial, Driver Training (not Utah, Johnson Valley, Gridmap...).
- **Automatic weather** (the server shifting between weather states on a timer, lerped on every
  client). The user chose static weather for now. The game's own weather presets
  (`art/weather/defaults.json`) also set the time of day, so a dynamic mode would send the weather
  fields only, never preset names.

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
  - **Parts 2/3 follow-ups - DONE (client 2522 / server 2365):** the Crew tab (with the Crews
    feature), staff Cancel on any lobby, the staff Everyone's vehicles block, Change settings in
    the race lobby and the Bus lines restyle.
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

## Freeroam: police chases between players: follow-ups

Built in client 2578 / server 2402 (`beamjoy/playerPursuit.lua`, `services/playerPursuit.lua`).
Not built yet:
- A GPS route to the nearest fugitive for the police player (old BeamJoy had one).
- A police / fugitive leaderboard (the counts are already saved in `player.data.pursuit`).

## Freeroam: passive zones (own drift zones, drag strips, passive races)

**Status:** planned, not started (direct request : "add B to the todo", 2026-10-07). Chosen over
feeding our own zones into the game's systems (see "Rejected" below).

One BeamJoy framework for anything you drive into from freeroam with no lobby : a start you drive
into, a route or checkpoints, a finish, and a result that goes to the server's leaderboards.
Zones are made in BeamJoy editors, stored per map on the server like races, and run by BeamJoy's
own code. The game's own (vanilla) drift spots and drag strips stay as they are, run by the game,
and are listed beside ours : both feed the same Drift / Drag leaderboards
(`services/freeroamChallenges.lua`, `beamjoy/freeroamChallenges.lua`).

| Kind | Start | Scored by |
|---|---|---|
| Passive race / time trial | gate, rolling or standing | time through the checkpoints (lower wins) |
| Drag strip | staged in a lane, tree | elapsed time at the strip's main mark (lower wins) |
| Drift zone | gate, rolling | drift points (higher wins) |

Order, most reuse first :
1. **The framework + passive races.** A passive race can be an existing race flagged "run it from
   freeroam" : the race editor already authors the start, gates and checkpoints. Only one run per
   player at a time ; leaving the route / a reset / too long ends it. Results to a leaderboard per
   race (the race leaderboards, or a passive board beside them : to decide).
2. **Drag strips.** An editor placing the lanes (start line, direction, length) and the timed
   marks. Timing is distance marks along the lane. The drag overlay and timeslip
   (`beamjoy/dragRun.lua`, windows/dragHud, windows/dragTimeslip) already run from our side : they
   need to read our own run instead of `gameplay_drag_core`'s. No physical tree on our strips :
   on-screen tree lights instead. Two players in opposite lanes pair through the server as now.
3. **Drift zones.** An editor placing the start gate, route and bounds. **Check first** whether
   the game's drift scorer (`gameplay_drift_*`) keeps scoring outside its own spots in freeroam :
   if so, score between our gates with it ; if not, scoring has to be our own.

Notes :
- Ours don't need the game's "Drift in freeroam" / "Drag racing in freeroam" settings ; vanilla
  ones still do (the Leaderboards window already offers to turn them on).
- Spot / strip ids must not collide with the game's (prefix ours, e.g. `bj:<map>/<id>`).
- Big map : our zones as POIs with quick travel and the route preview, like races and bus lines.

**Rejected : feeding our zones into the game's own systems** (wrapping
`gameplay_drift_saveLoad.getDriftSpotsById` / `gameplay_drag_core.getDragDataForLevel` and writing
their race / bounds files to a temp folder). It would have reused the game's scoring and markers,
but : the painted lines, signs and tree lights are map objects ours wouldn't have ; it depends on
internal formats BeamNG keeps changing (the drag code was just reworked, and now ships its own
multiplayer drag lobbies, `gameplay/drag/mpDragHandlers.lua` / `dragBridge.lua`) ; and ours would
also need the game's freeroam settings on. How the game finds its own : drift spots are folders
under `levels/<map>/driftSpots/` (`spot.driftSpot.json`, `race.race.json`, `bounds.sites.json`,
`info.json`), drag strips are `levels/<map>/dragstrips/*.dragSettings.json` pointing at a
`*.strip.json`, both read once per map and cached.

## Races: placed props (a framework, saved with the race)

**Status:** planned, not started (direct request, 2026-10-07 : "a framework for placing props and
saving them with races").

Authors place props (barriers, tire walls, cones, arches, banners, flags...) in the race editor ;
they're saved as part of the race and appear for everyone while it runs. Built as a generic
framework (`beamjoy_props` client module + a `props` list any activity can carry) so hunter /
infected / derby arenas and the passive zones above (a drag strip's tree, a drift zone's signs)
can use it later. Nothing like it exists yet : race gates and markers are drawn shapes
(`beamjoy_raceMarkers`), not objects.

Two kinds of prop, very different in multiplayer :
- **Static** (a mesh, `TSStatic` with a `.dae` from the game's art, or a game prefab through
  `spawnPrefab`, ge_utils.lua) : spawned by each client itself from the race data, so nothing is
  synced through BeamMP and they cost little. Solid to cars but never move. The main kind : walls,
  tire stacks, arches, banners, flags, start / finish gantries.
- **Physics** (the game's "Prop" vehicles : cones, barrels, signs, plastic barriers) : real vehicles.
  In multiplayer each one is synced and owned by a player, counts toward vehicle limits, gets
  knocked out of place and would need putting back between runs. **Investigate first** whether a
  client-only, unsynced spawn is possible under BeamMP (BeamMP syncs vehicles spawned locally) ;
  if not, physics props stay out, or are limited to a few owned by the race's host.

Data, saved with the race (server activity JSON, like gates / startPositions) :
`props = [{ kind = "static" | "physics", shape | model + config, pos, rot, scale }]`. Server-side :
validate and cap the count (e.g. 200 static / 20 physics), shape paths only under the game's own
art folders. Client-side : a prop whose shape or model isn't installed (a mod's) is skipped, and
the editor says so.

When they exist :
- During the race session (grid to finished) for participants and spectators ; removed when it
  ends, on leaving, on map change and when BeamJoy unloads (no leftovers in freeroam).
- In the race editor while editing (a preview).
- Later, passive races / zones : always there in freeroam ? To decide (they'd be in everyone's
  way when nobody's racing).

Editor (a Props section in the race editor, `ui/raceEditor.lua` + its Angular sidebar) :
- A curated catalog (one file listing the shapes / prop models offered, with names and a preview),
  not the game's 700 raw `.dae` files.
- Place at your position / facing (the editor's existing convention), then the gizmo (already
  used for gates) to move / rotate / scale ; snap to the ground ; duplicate ; delete ; a list of
  the race's props to select from.
- Collision matters : a wall in the wrong place blocks the route, so the editor shows the props
  exactly as they'll be in the race.
- **Line tool** (direct request) : place the two ends of a line, set how many props go on it,
  and they're spread evenly from end to end (both ends included). One rotation for the whole line
  turns every prop at once around its own vertical axis, for a model that isn't aligned the way
  the line expects (a barrier sideways, a cone's sign facing the wrong way). Each prop faces along
  the line by default and sits on the ground under its spot (a line over a hump or a dip follows
  it). Saved as the line itself, not its props :
  `{ kind = "line", shape | model, a, b, count, yaw, followGround }`, expanded when spawned, so
  moving an end or changing the count respaces it ; "Split into props" turns it into single props
  to adjust one by one. The count counts toward the race's prop cap. Maybe later : spacing in
  metres instead of a count, and a curved line (a middle handle).
