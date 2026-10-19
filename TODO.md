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

**Status:** built in client 2713 / server 2468 (see CHANGELOG), not yet tried live. The user found
the date never moves on, in multiplayer or single player. To check : with time sync on and a short
day, the moon doesn't jump at midnight and the panel's date goes on a day (on every client, and
after a rejoin) ; month and year ends ; with time sync off, the same on the engine's own clock.
Single player without BeamJoy still doesn't move its date (the game's own behaviour).

Investigation notes, kept for reference :

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

## Join loading time: the sidebar and weather take 7-10 s after the UI reload

**Status:** 1 and 2 built in client 2713 / server 2468 (see CHANGELOG), not yet tried live ; 3
not started (the user asked for the first two). To check : the sidebar and the weather come within
a second or two of the UI reload on West Coast ; a race's props show for its racers and spectators
(a race joined just after the join too), in the editor (a save right after opening says they're
loading), after the race is saved again (everyone gets the new ones), and shared / exported with a
race code ; the race list still shows each race's prop count.

Direct report : after the join's UI reload, the sidebar and the weather sync come much later than a
month ago. The UI reload itself is unchanged (about 4 s in the build 2495 logs and now). The gap is
the join caches : from the client's `clientConnection` to `sendCache` arriving took 0.06 s in build
2495, and 7-10 s in every 2703/2707 log (Nucleus Player1/Player2). The sidebar
(`communications/ui.lua` proceedAfterLogin waits on `beamjoy_cache.loaded`) and the weather both
wait on that one message (`services/cache.lua` requestCaches : every service's `onBJRequestCache`
in one `sendCache`).

Why (West Coast, measured from the server's db) : the join caches are about 90 parts of 20 KB, and
the paced sender (`communications/tx.lua`) sends one part per 100 ms tick, so about 9 s.
- **Race props.** `caches.races` is 1.35 MB as sent, and 80% of that is the props of all 57 races
  (4,086 props, about 225 bytes each). Without props it's 0.28 MB. A race's props are only needed
  when it's run, watched or edited.
- **Shared builds and presets** (`caches.vehiclePresets`, `caches.vehicleBuilds`) : about 370 KB.
  The build photos are already sent on request only.
- **The pacing sends half what it meant to.** SEND_BUDGET 40000 bytes per tick, but a 20 KB part
  grows to about 23 KB once wrapped and escaped (`{id, part, data}` as JSON), so only one part fits
  per tick : about 230 KB/s, not the 400 KB/s its comment says.

The plan :
1. **Race props on request.** The races cache carries a prop count instead of `props`, and the
   client asks for a race's props when it needs them : a race it's in or watching (props.lua
   sessionProps, which reads `beamjoy_races.data`), the race editor opening a race (its own copy,
   windows/config/races/editor), sharing / export (raceShareExportCode), and anything else that reads
   `race.props` (mapRaces' import keeps the map's own props). A save sends the race's new props to
   no one, the next request gets them. About 9 s to 3.5 s on West Coast.
2. **Small caches first.** The join's caches in two messages : settings, players, environment and
   the other small ones first (the sidebar and the weather from that one), then the big lists
   (races, vehicle presets, vehicle builds). Check what reads those lists at load and copes with
   them arriving a few seconds later.
3. **The pacing as intended** : two parts per tick (a budget that fits two wrapped parts), about
   460 KB/s. It's the guard against the BeamMP launcher's "zlib uncompress() failed" crash on big
   bursts (27 packets at once), so test it with a few players joining at once.

All three : the sidebar and weather within about a second, the full caches in 1-2 s.

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

**Status:** step 1 built (client 2615 / server 2428) : races flagged "Run from freeroam" start when
driven through, one lap, their own Freeroam board (`beamjoy/raceFreeroam.lua`,
`services/raceFreeroam.lua`, the board switch in `windows/raceLeaderboard`). Step 2 built (client
2616 / server 2429) : the server's own drag strips (`services/dragStrips.lua`, `beamjoy/dragStrips.lua`,
`ui/dragStripEditor.lua`, Config > Freeroam > Drag strips), run through the existing drag overlay /
timeslip / boards. Step 3 built (client 2617 / server 2430) : the server's own drift zones (`services/driftZones.lua`,
`beamjoy/driftZones.lua`, `ui/driftZoneEditor.lua`, `windows/driftZoneHud`), scored by the game's
own drift scorer (`gameplay_drift_scoring`, loaded if needed and reset at a zone's start, as its
drift spots do) : **check in game** that it scores in BeamMP freeroam with the game's drift
setting off.

Still open for step 3 :
- No score targets (bronze / silver / gold) on our zones, no Big Map pin.
- The game's own drift messages ("Nice drift!") may show during a zone : they're its freeroam ones.

Still open for step 2 :
- No Big Map pin for a strip, and no dial-in (bracket racing) on ours.
- Results are trusted from the player's game, as for the game's own strips (no server-side check
  of the car's position at the marks). Chosen over feeding our own zones into the game's systems (see
"Rejected" below).

Still open for step 1 :
- A race's props don't show during its freeroam runs (they'd appear out of nowhere as you start,
  and be in everyone else's way) : to decide.
- No Big Map pin of their own : a freeroam race shows through its grid start's pin.

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

## Races: props : multi-select and your own prefabs

**Status:** planned, not started (direct request, 2026-10-09 : "add the prefab saving to the todo").
Built-in prefabs (several meshes placed as one prop, the rally gazebos first) are being built now in
the props drawer's Prefabs tab ; this is the part left for later.

- **Multi-select** in the race editor : Shift+click props in the world or the list (maybe a drag
  box too) ; the selection moves with one gizmo (pivot at its middle ; turning is yaw only, every
  prop and line point swung round the pivot), deletes with the Delete key, duplicates as one.
  Useful on its own, before prefabs.
- **Save as prefab** : the selection stored relative to an anchor (its middle and a facing), every
  prop as it is : lines stay lines (count, curve, alternate mesh, lift, follow ground), single
  props keep their turn, scale and stretch. Named by the player.
- **Placing one** : the drawer's Prefabs tab lists the built-in ones and "Mine" (rename, delete) ;
  picking one arms it like a mesh, its whole ghost follows the cursor, the wheel turns it, a click
  places it. Placed as one prop made of several meshes (the same entry kind the built-in prefabs
  use : its parts relative to it), so it selects, moves and deletes as one ; "Split" makes it
  separate props again. Every mesh counts toward the race's 500.
- **Where they're kept** : per player on their own PC by default (simplest, client only) ; a
  shared library on the server (every editor sees the same ones) would need server storage, a
  permission for adding / deleting, and syncing. Ask which before building.

## Races: painted lines and swept curbs / walls

**Status:** swept curbs and walls built (client 2680 / server 2454, 2026-10-13 : "start working on
the curbs and walls"), painted lines built (client 2681 / server 2455, 2026-10-13 : "now please do
the painted lines"), neither checked in game yet. Two new kinds
of race prop next to static props and lines, both client-side objects like the props (never synced
through BeamMP), saved with the race, spawned by `beamjoy_props` for racers, spectators and the
editor's preview.

Built (`beamjoy/props.lua` SWEEPS, `ui/propEditor.lua`, the drawer's Curbs & walls tab,
`services/props.lua` saneSweep) : `{ kind = "sweep", profile, a, b, mid, count, followGround,
heights, group }`, one ProceduralMesh per entry (createMesh takes `{ { submesh, ... } }`, each
`{ verts, normals, uvs, faces = {{v, n, u}} (0-based), material }`), one submesh per paint colour,
runtime Materials made like core.lua's Track Builder ones. 7 profiles. Re-made in place on its
object while an end is dragged. A ProceduralMesh has no collision field (only `material`), so the
editor's preview and the ghost are deleted before every static collision rebuild done by
beamjoy_props and made again after.
**Check in game** : that a runtime ProceduralMesh only becomes solid on `be:reloadCollision` (if
createMesh makes it solid at once, the editor's preview is solid too) ; the stripes' colours and
the concrete texture's look ; the rumble ground model on curbs ; the faces' winding (the materials
are double-sided meanwhile).
Left for later : a profile's side (a kerb sloped toward the track only), tilting with the ground
across the path (it's sunk 0.4 m instead), a tyre-wall profile, eyedropping a whole sweep.

Painted lines built (`beamjoy/props.lua` PAINTS, the drawer's Paint tab, `services/props.lua`
sanePaint) : `{ kind = "paint", paint, a, b, mid, count, width, followGround, heights, group }`, one
DecalRoad per entry made as procTrack.lua makes its route (fields, `Node` "x y z width" per node,
then registerObject), a node every 2 m (at most 200), `improvedSpline`, `overObjects`,
`drivability` -1, `renderPriority` 1 (tyre marks 2). Made anew whenever it changes (no in-place
node editing). 15 paints, all game materials every map has (art/shapes/common/decalroads and
art/shapes/race, their textures links to /assets) ; m_tread_marks_clean left out (its texture is
only in Johnson Valley's zip). Weighs one prop every 20 segments (40 m), like a curb.
Texture length is the paint's own (fixed metres, or a multiple of the width for the checkers and
spray paint), not editable.
**Check in game** : that a runtime DecalRoad shows at once ; that renderPriority 1 draws over the
map's own lines and asphalt (lower is drawn later, as procTrack's orange markings over its tread
marks) ; overObjects on a map's mesh roads (and whether it then also paints over our curbs and
props) ; each paint's look and texture length (the checkers square at width × 5, the dashes'
spacing) ; the common materials' textures on a map other than their own (Johnson Valley's, West
Coast's : links to /assets, should be fine).

How the game does it (investigated 2026-10-12) :
- **Driver Training's quick races** are generated at load : a quickrace JSON with
  `"procedural": true` and `"luaFile": "procTrackGen"` (`levels/driver_training/quickrace/`) calls
  the game's `lua/ge/extensions/util/procTrack.lua` (`makeGymkhana`). It makes DecalRoads for the
  painted route (materials `tread_marks_clean` and `road_orange_markings` : no collision), TSStatic
  barrier segments placed one by one round each corner's arc (`barriersegmentL/R.dae`), gates,
  rings and barrel markers, BeamNGWaypoint checkpoints, all in a `GymkhanaArena` SimGroup, then one
  `be:reloadCollision()`. The same approach as our props.
- **Hirochi and Automation Test Track** have no MeshRoads : curbs and walls are hand-placed
  TSStatics (the test track's curbs are big meshes modelled to fit, `curbs.dae` / `s_curbs.dae`),
  forest items for repeated barriers, DecalRoads (about 1,500 on the test track) for paint.
- **Track Builder** (`lua/ge/extensions/util/trackBuilder/`) sweeps a cross-section along the track
  spline into one `ProceduralMesh` (`segmentToProceduralMesh.lua` : `createObject("ProceduralMesh")`
  then `:createMesh(meshes)`) : `basicBorders.lua` defines curb shapes (regular, bevel...) as a few
  cross-section points with their UV, `borderWallMesh.lua` the walls. One piece, so no joints on a
  curve. It rebuilds collision only when you press Drive.

What was planned (both now built, above) :
- **Painted lines** : a DecalRoad along a line (its two ends and its bend, the same handles as the
  line tool), with a material picked from a short list (white / yellow lines, kerb paint, tyre
  marks, orange markings), its width and texture length. No collision, and they cost far less than
  a prop : decide whether they count toward the race's 500 or have a limit of their own. To check :
  DecalRoad's `Node` field (`"x y z width"`), `improvedSpline`, `renderPriority` / `zBias` against
  the map's own decals, and that one made at runtime with `canSave = false` shows straight away.
- **Swept curbs and walls** : a ProceduralMesh swept along a line, from a few cross-sections like
  Track Builder's (a curb, a low wall, a tall wall, maybe a tyre-wall profile), following the
  ground (the line's heights). Solid, so it joins the static collision rebuild like the props. To
  check : the vertex / face format `createMesh` takes (read `segmentToProceduralMesh.lua` and
  `proceduralPrimitives.lua`), materials it can use (Track Builder's `materialUtil.lua`), how long
  a mesh one object can hold, and whether it can be changed in place while a line is dragged or
  has to be remade.

## Races: placed props (a framework, saved with the race)

**Status:** built for races (client 2615 / server 2428) : static props and the line tool in the race
editor's Props tab, saved with the race, spawned by each client for its racers and spectators
(`beamjoy/props.lua`, `services/races.lua`'s sanitizeProps). Not built : physics props (below :
investigated 2026-10-09 and dropped, each one a full vehicle, too heavy at a race's prop counts),
props for the passive zones, preview pictures in the catalog, spacing in metres and curved lines.
Hunter / Infected / Derby arenas have them too since client 2677 / server 2452 (the shared
`ui/propEditor.lua` and `cmps/propEditor`, checked by `services/props.lua`). The catalog is `beamjoy_props.CATALOG` (a mesh's yaw, length
and collision were read from the game's .dae files ; orientations still want a check in game).

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

## Vehicle presets: shared builds (custom vehicles for everyone)

**Built in client 2703 / server 2466 ; first live try (2703) : a personal save was added as a
plain entry (the game's Save writes an info file too), fixed in 2704, to try again.** Direct request : players' custom
vehicles in vehicle presets, available to everyone in the vehicle selector, managed in the Vehicle
Presets tab with its permission. Server : `services/vehiclePresets.lua` (builds checked, named,
deduplicated, dropped when unused), `dao/vehicleBuilds.lua` (`vehicleBuilds.json`). Client :
`beamjoy/vehicleBuilds.lua` (writes and removes the files, hides builds of hidden presets outside
their activities, captures a build and refuses parts from mods the server doesn't send),
`beamjoy/vehiclePresets.lua` (capture), the four runners (`onBJActiveVehiclePools`), the Vehicle
Presets tab. To check live :
- a custom car added, named, saved : the tile appears in another player's selector (name, author,
  picture, paint), spawns right, and BeamMP shows it right to others ;
- the same in a race pool, derby and hunter, with "Show in the selector" off too ;
- leaving the server (disconnect and "Exit level") removes the files ; a killed game's files go on
  the next join ;
- a part from a repo mod refused with its name ; parts from the server's own mods accepted (is
  `mods/multiplayer/` always where BeamMP puts them?) ;
- the selector's first open after builds arrive (the cache is cleared, then warmed again) ;
- photos (2705) : a build added gets its photo (row in the editor, then the tile in another
  player's selector once it's fetched), "Retake photo" in and out of the build, the game's UI
  only blinking while it's taken, a build made before 2705 keeping the model's picture until retaken ;
- join (2713) and the date at midnight (2713) : see their own sections ;
- 0.40 (2716) : the welcome panel (Config > General > intro panel, preview ; and on joining when
  enabled) opens with its title, image and text, its COPY button works, Continue closes it, a
  controller can close it and drive again after ; a bus on a line : the stop display's text in its
  usual font ; hold a door / the horn on another player's car (the trigger lights up while
  held, the owner's car reacts) ; click a seat box on another player's stopped car (the owner
  stays in their seat and can still drive) ; walk, pick a car in the selector (the car appears, no unicycle
  left, no error) ; Disconnect from the server (no "could not reload extension" in the log) ; a
  blocked replay shows as not loaded in the replay browser ;
- drift spots (2715 / 2469) : no name over a spot in the world ; "drift spots" and "dragstrips"
  everywhere ; the handles at each end of every point's line drag that point's width (the other
  end stays, Ctrl both sides), the corridor and the gates follow, saved and seen by others ; a run
  leaves the spot where it's narrow, not where it's wide ; the slider sets them all ;
- paints (2714) : every paint's ghost follows the mouse with no flashing (the white line, the
  chevrons, the hazard stripes, both rubbers, the dirt tracks : not only the zebra, the yellow line
  and the short dashes), on West Coast and on another map ; a dragged node too ; a placed line
  doesn't blink as it's placed, a deleted one goes ;
- paints (2712) : every line (the placing ghost and a dragged node) follows the mouse smoothly,
  the rubbers too, with no CPU spike ; both rubbers still look as before (on another map too) ;
- paints (2711) : Track rubber shows as one wide dark band (on a map other than West Coast too),
  its drawer picture too ;
- drag (2709) : after a run, the Focus control lights Open timeslip, A opens it, B lets go ; in the
  timeslip left / right / A work and B closes it, and the pad drives again once it's closed ;
- paints (2708) : yellow and black stripes look like the drawer's (and load on a map other than the
  first one), chevrons are V's, slanted stripes show, the rubber and dirt marks fade at their ends,
  dragging the rubber line no longer pins a CPU core ;
- photos (2706, 2707) : a new photo shows in the editor row (it was blocked as "unsafe:"), a retaken
  one replaces the old after saving, a ghosted car comes out solid in the photo and goes back to
  see-through right after.

Later, if wanted : players submitting builds for staff to approve (a separate permission), "Save this car" on another player's car, and the server making a preset
pack zip from favourite builds (sent by BeamMP like any mod, so players keep them
after leaving).

## Plugin API: other server plugins working with BeamJoy (leaderboard website, Discord bot, modular plugins)

**Step 4, plugin pages in the main window : built in client 2702 / server 2465, not yet tried live.**
Direct request : plugins adding "their own tabs to the main hud and sidebar hud". Server :
`services/pluginPages.lua` (pages, checks, each player's view kept in sync, clicks and opens rate
limited), `api.lua` (`pages.*`, `PageOpened`, `PageAction`). Client : `beamjoy/pluginPages.lua`,
`cmps/pluginPage` (draws a page), `windows/main` (rail buttons, panels, full window tabs, the
controller). Example : BJClasses' League page. To check live : the rail with a page or two (its
height, the label cut), a page panel and tab, the fields and buttons, the controller on a page,
per-player content arriving on opening.

**Step 3, plugins in BeamJoy's windows : built in client 2701 / server 2463, not yet tried live.**
Direct request : plugins add "categories and options" to the race start menu and the race editor,
"extra labels or fields to results or leaderboards without worrying about multiple entries", and
tabs of their own to the config window. Server : `services/pluginUi.lua` (definitions, checks,
config values in `pluginConfig.json`), wired into `races.lua` (race defaults, entry fields),
`raceGrid.lua` (session values, racer fields), `api.lua` (`raceOptions.*`, `results.setFields`,
`leaderboard.setFields`, `config.*`, `ConfigChanged`, `ConfigAction`). Permission
`EditPluginConfig`. Client : `beamjoy/pluginUi.lua`, `cmps/pluginOptions` (the options, the field
tags), `windows/config/plugins`. Example : `api/example/BJClasses`. To check live : the options'
look in the start menu, editor and config window, the editor not marking a race edited on open,
the tags in the results and leaderboard windows.

**Step 2, modular plugins : built in client 2700 / server 2462, not yet tried live.** Direct request
("allow for the installation of modular plugins") : hooks (`raceReady` with a reason the racer
sees, `gridOrder`), race events with server times (grid opened, countdown with the grid and green
time, green light, lap with sectors, finished, out, closed), results with every lap and sector,
`race.setGridOrder`, `race.unready`, `races.sessions`, `environment.set` + `EnvironmentChanged`,
`hud.message`, and activity overlays (`overlay.show/hide/clear` : the race HUD's look with the
plugin's values, or the plugin's own blocks ; can hide the race HUD). "HUD layout" means the
activity overlays like the race one (user's clarification). Server : `services/api.lua`,
`services/pluginOverlay.lua`, hooks wired in `services/raceGrid.lua`. Client :
`beamjoy/pluginOverlays.lua`, `windows/pluginOverlays`, the lobby's "Checking…" / reason box.
Example : `api/example/BJRaceControl`. To check live : BeamMP's cross-plugin events and `dofile`
(still unconfirmed on a real server), overlays' look in game, the race HUD hiding.

**Worth adding next (suggested, not asked for yet) :**
- More hooks : `raceStart` (rules for a league night : laps, vehicles), `raceJoin` (entry lists,
  licences), `raceResult` (before a time goes on the leaderboard), `environmentChange` (lock the
  weather during an event).
- Race control for plugins : `race.start` (scheduled events : open a lobby for given players),
  `race.cancel`, `race.penalty` / `race.disqualify` (stewarding from a plugin or a Discord bot).
- The other activities' events and sessions (hunter, infected, derby, drag, drift, deliveries),
  the same way as races ; `hides` for their HUDs too.
- Per-player storage for plugins (`players.data.get/set`, namespaced per plugin, in BeamJoy's
  player records) and player stats (`players.get` : group, first seen, races, wins...).
- Chat : `chat.send` through BeamJoy (mutes, languages), a `ChatMessage` event, plugin chat
  commands registered with BeamJoy's permission groups.
- `notice.show` : BeamJoy's notification stack (with a Join button) for a plugin's own activity.
- Buttons on overlays (a click comes back to the plugin as an event). (Config tabs have buttons
  since step 3.)
- Leaderboard views by a field (only the GT entries, say) in the game's leaderboard window.
- Who may write : an allowlist in BeamJoy's config of the plugins allowed to use the hooks and
  write methods (today any plugin on the server can ; plugins are the server owner's own).

**Step 1 status:** the API built in server 2460, not yet tried on a live server : `services/api.lua`,
`BeamJoyServer/api/` (README, helper, example export plugin ; inside BeamJoy's own folder so it
ships to servers with the release, user's call, and plugins load the helper from there). The `identity` marking is in. Next : the
user's own sync plugin (the website's kind still open), then the bot. Direct request : let
people's own BeamMP server plugins read
BeamJoy data (statistics, races, leaderboards, weather...). The user's own first use : a plugin
that syncs race leaderboards to a website. Read-only at first (user's choice) ; the race,
environment and overlay writes came with step 2.

**How plugins talk.** Every folder in `Resources/Server` is its own plugin in its own Lua state :
none can see another's variables or call its functions. They only exchange events
(`MP.TriggerGlobalEvent` / `MP.RegisterEvent`), as `BeamJoyServerHooks` already does. A third
party's plugin is its own folder beside `BeamJoyServer` (e.g. `Resources/Server/BJLeaderboardSync/`),
untouched by BeamJoy updates.

**BeamJoy side : a new `services/api.lua`.**
- Requests : a plugin fires `BJAPI_request` with `{id, method, params}` ; BeamJoy answers with
  `BJAPI_response` `{id, result | error}`. Request/reply by id, like BeamJoy's own client protocol
  (calls between plugins are asynchronous anyway ; BeamMP's own futures need polling).
- Events : BeamJoy fires `BJAPI_<name>` with a payload.
- Payloads are JSON strings with a version (`v: 1`), in a **public shape of their own**, never the
  internal tables (those keep changing : identity keys, legacy race formats, gate steps...).
- A registry : `services_api.register("races.leaderboard", fn)`, `services_api.emit(name, payload)`.
- Methods, first set : `server.info`, `maps.current`, `races.list`, `races.leaderboard` (any map,
  `grid` or `freeroam` board), `players.online`, `environment.get`.
- Events, first set : `leaderboardChanged` (from `services_races.submitTime` and `restoreEntry`),
  `raceFinished` (from the results `raceGrid.lua`'s `postToDiscord` already builds, so Discord
  becomes just another consumer), `mapChanged`.
- Ship a drop-in `BeamJoyAPI.lua` helper for plugin authors (`BJ.on(event, fn)`,
  `BJ.call(method, params, callback)`) and an `API.md`.
- Phase 0 first : a quick spike with two test plugins on BeamMP 3.9+ (argument types across
  states, ordering, whether a plugin's own global event reaches itself).

**Data traps the API should hide.**
- Races are per map, and only the current map's are in memory (`services_races.data`) : another
  map's leaderboard comes from disk (`dao_activity.get(map, "races")`).
- Two boards per race : `leaderboard` (grid) and `freeroamLeaderboard`.
- A leaderboard can get worse, not only better : a staff disqualification puts the replaced entry
  back (`restoreEntry`). So `leaderboardChanged` carries the race's board, not just "new PB".
- Entry keys are display names (the BeamMP account name, or a guest's nickname / guest name) : not
  stable ids. Since 2461 only guests can pick a nickname (accounts are back).
- Entry dates look off by the server's UTC offset : `GetCurrentTime()` is
  `os.time(os.date("!*t"))`, which reads a UTC table as local time. Not confirmed on a live
  server ; the API should send real Unix timestamps whatever the cause.

**Only nicknamed/logged-in players on the website (user's choice) : done in 2460/2461, kept as
notes.** Website keeps `"beammp"` (accounts) and `"nickname"` (nicknamed guests) entries. Entries don't record whether their key
is a nickname or a BeamMP name (`getIdentityKey` falls back to the BeamMP name, login being
optional), so they can't be told apart today. Plan : `submitTime` also saves
`identity = "nickname" | "beammp"`, the API passes it on, and the consumer filters (the API stays
general). Entries saved before that are unmarked : leave them off until that player sets a new PB
(simplest, never wrong), or a one-time console command guessing from the player records (a
nickname can equal someone's BeamMP name, so only a guess).

**The user's sync plugin (`BJLeaderboardSync`, a separate plugin).** On start, every map's and
race's board uploaded in full (catching up on anything missed while it was down) ; on
`leaderboardChanged`, that race's board. Keeps `"beammp"` and `"nickname"` entries only. Sends with
`curl` (no HTTP in BeamMP's Lua ; `services/discord.lua` does the same) and a secret token from
its own `config.json`. **Open question :** what the website is. A backend that can take uploads
(POST with the token), or a static site on the same machine (the plugin writes a JSON file it
serves).

**Discord bot (later, same API).** BeamJoy already posts to Discord without a bot (webhooks in
`services/discord.lua`, and `onScriptMessage` for the ChatHook plugin). A real bot (slash
commands : `/leaderboard`, `/online`, `/weather`) is its own program (discord.js / discord.py) :
a bot needs a permanent connection to Discord, which BeamMP's Lua can't hold. It reads BeamJoy
data through a bridge, preferably **the website's own read endpoint** (one pipeline for both, and
it keeps working while the game server restarts) ; or snapshot JSON files a bridge plugin writes,
when the bot runs on the server's machine and there's no website. Bot commands acting on the
server (weather from Discord...) are writes : out of scope for now.

**Order :** the API (with the `identity` marking) → the website sync plugin → the website's read
endpoint → a bot on that endpoint. Each step works on its own.
