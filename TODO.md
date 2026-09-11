# TODO / planned features

Ideas that have been discussed and design-approved but deliberately not started yet. Not a
backlog of every idea ever mentioned, just things worth picking up later without re-deriving the
design from scratch.

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

## Freeroam editor (BJI port) — Phase 0 + 1: energy stations & garages

**Status (2026-09-11, client build 2398 / server build 2331, local BJ.zip only - 1.9.1 committed,
naming + Phase 2 (bus lines: data + editor + gameplay + first-test fixes + several fix corrections
+ Activities tab split) uncommitted - selector-disappears bug: FIXED, user-confirmed live
("it works perfectly now") on the bus-line picker, and the same pause.vehicleSelector fix has now
been backported to every other freeroam-selector call site in the codebase (race/hunter/infected -
see below) - those three not yet individually retested live):**
build 2368-2376 (marker/prompt arc - confirmed working 2026-09-10):
- Native gas stations were dead in the world on a BJS server: `gameplay_markerInteraction` /
  `freeroam_gasStations` load lazily via a path nothing triggers in MP, AND
  `isStateWithPlaymodeMarkers` rejects the "multiplayer" state. `bigmap.lua` force-loads those
  extensions + wraps the state check.
- Enabling native marker interaction (above) made it fight `interactiveMarker` over the single
  `ui_missionInfo` dialogue - THAT was the "prompt only shows while moving" regression, not an
  OBB/velocity issue. Resolution: **dropped `interactiveMarker` entirely** (file deleted). BJS
  stations/garages are now real POIs via `onGetRawPoiListForLevel` + `markerInfo.missionMarker`,
  rendered and prompt-driven by the game's own system - identical path to the map's gas stations.
  Button added via `onActivityAcceptGatherData`. One driver, no conflict.
- `missionMarker` hardcodes its trigger radius (~1.2m) and builds a ground ring. `stations.lua`'s
  `onUpdate` re-applies each point's configured radius to `marker.radius` and nils
  `groundDecalData` every frame (clusters rebuild on `gameplay_rawPois.clear()`). So the editor
  radius works and it's icon-only.
- Possible future editor toggle: per-station fuel-type override (EV chargers) + "show ground
  ring" - both need the same `pointListEditor` per-item-metadata extension (deferred).

Phase 1 essentially complete and confirmed working in-game:
- Phase 0 (data plumbing), improvements #1/#2/#3/#5/#6 - DONE
- `bigmap.lua` rewritten for `freeroam_vueBigMap` (vanilla POIs restored, missions filtered) - DONE
- Marker/prompt: fully native. `stations.lua` contributes real POIs via `onGetRawPoiListForLevel`
  (`markerInfo.missionMarker`), rendered + prompt-driven by the game's own
  `gameplay_markerInteraction`; button added via `onActivityAcceptGatherData`; native
  `ui_missionInfo` dialogue (BeamNG-styled, controller navigable). `interactiveMarker.lua` deleted.
  Refuel via `core_vehicleBridge`, repair via in-place safeTeleport - DONE, user confirmed working
- `stations.lua` `onUpdate` re-applies each point's configured radius + nils the ground ring - DONE
- Scenario gating centralized in `bigmap.lua getRawPOIs` (drops gasStation/bjEnergyStation/bjGarage
  POIs when `not beamjoy_context.stationsAllowed()`); per-arena `allowStations` opt-in for
  Infected + Hunter, none for races - DONE, user confirmed
- Garages: `groupType = "garage"`, surfaced in the freeroam side menu under a "BeamJoy" section
  (`onBigmapBuildCustomGroupStructures`) so it doesn't read "Garages > Garages" - DONE
- **Editor: Config > Freeroam tab** - `ui/stationEditor.lua` (pointListEditor wrapper, two
  radius-only lists) + `windows/config/freeroam/app.{js,html}` + wired into `activityEditor.lua`
  and `config/app.js` tabsData (perm `EditFreeroamData`, order 7). Live markers hide while it's
  open (`onBJStationEditorState` hook). NEEDS in-game confirmation.
- All 13 client locales (en-US + 12 translated) - DONE
- **Per-point names** (build 2378) - `pointListEditor` gained a `hasName` list flag + `setName`
  event + `onSetName` handler (40-char clamp, world label shows the name when set). Angular side:
  a text input per row when `list.hasName`. `stationEditor`/`freeroam/app.js` opt both lists in.
  Server already sanitized/stored `name` since Phase 0; `stations.lua` already surfaced it on the
  prompt heading + Big Map card. DONE.
- git sync - committed to `BeamJoy-sandbox-main` as "Release 1.9.1: freeroam energy stations &
  garages" (not pushed). DONE.

**Remaining:**
- Confirm the editor in-game (save round-trip, gizmo, radius, name, live-marker suppression)
- Per-station fuel-type override (electric chargers etc.) - deferred, needs a `pointListEditor`
  per-item-metadata extension (the `hasName` work is a template for it). Empty types =
  gasoline/diesel/kerosine/n2o for now.
- Repair currently always offered + tops off fuel on completion - refine to "only if damaged" +
  preserve fuel once the right vehicle field is confirmed
- Consider a dedicated "BeamJoy" Big Map section for stations too (they currently sit in the
  native "Gas Stations" list) - cosmetic, needs `customGroupTags` Scope capped at Phase 0 + Phase 1 (energy stations / garages). Bus lines,
deliveries, derby are later phases with their own plans. Decisions locked in: **one Freeroam
config tab** (collapsible sections), **no reputation/XP system** (BJI gates freeroam content
behind one; BJS drops it entirely). Marker approach REVISED: not a 1:1 port of BJI's
`InteractiveMarkerManager` (see below) — contribute POIs via the native `onGetRawPoiListForLevel`
hook + drive the prompt via `onActivityAcceptGatherData`, OR a self-contained `shape.lua` ring +
direct `ui_missionInfo` call. Leaning the latter for churn-resistance.

### Native API research (2026-09-10, game build 20972)

BJI's `InteractiveMarkerManager` predates a native marker-system rewrite and is NOT safe to port
1:1:

- **Per-marker icon renderer is dead.** BJI creates its own `BeamNGWorldIconsRenderer` per
  marker (`_marker.iconRendererId`, `M.group`). Native `missionMarker:setup()` now ignores that
  and uses shared singletons from `gameplay_playmodeMarkers.getIconRendererObj()`
  (`markerIconRenderer` + `bigmapIconRenderer`). BJI's `createMarkerObject` / group code is a
  no-op against current native.
- **Marker radius hardcoded** to 1.2m in `missionMarker:setup()`; BJI's post-setup
  `_marker.radius = N` still feeds `playerIsInArea` but fights native's own decal-ring scale.
- **Area test is OBB now** — `playerIsInArea` -> `overlapsOBB_Sphere(bbCenter, bbHalfAxis0..2,
  pos, radius)`, needs those 4 vecs in the update payload. BJI 2.0.8's `fastTick` was updated to
  supply them, so BJI isn't fully broken here, but its custom render tick now duplicates work
  `gameplay_markerInteraction.onPreRender` already does natively every frame.
- **The native path is the single driver:** `gameplay_markerInteraction.onPreRender` ->
  quadtree cull -> `gameplay_playmodeMarkers` cluster -> `getMarkerForCluster` -> `update` ->
  `interactInPlayMode` -> `openViewDetailPrompt` -> `extensions.hook("onActivityAcceptGatherData",
  elemData, activityData)` -> `ui_missionInfo.openActivityAcceptDialogue`. Running BJI's parallel
  tick risks double prompts / `ui_missionInfo` state fights.
- **POIs are contributed via `extensions.hook("onGetRawPoiListForLevel", level, elements)`**
  (fired by `gameplay_rawPois`), NOT by wrapping `getRawPoiListByLevel` (what BJS's `bigmap.lua`
  still does — stale). Each element: `{ id, data = {type=...}, markerInfo = { missionMarker = {pos,
  rot, icon}, bigmapMarker = {...} } }`.
- **Native already does freeroam refuel** — `freeroam/gasStations.lua` contributes gas-station
  POIs + a refuel button, gated on `settings.getValue("enableGasStationsInFreeroam")` or career.
  Fuel is applied via `core_vehicleBridge.executeAction(veh, 'setEnergyStorageEnergy', tank.name,
  tank.maxEnergy)` (tank list from `core_vehicleBridge.requestValue(veh, cb, 'energyStorage')`) —
  NOT `BJI_Veh.setFuel`. Native garages route to `gameplay_garageMode.start(true)` (full career
  garage UI), not a quick repair, so BJS's "garage = repair here" stays our own.
- `ui_missionInfo.openActivityAcceptDialogue(content)` still exists; it stores each entry's
  `buttonFun` in `M.buttonsTable[i]`, invoked by `onSelectDetailPromptClicked(i)`.
- `getCurrentTaskdataTypeOrNil` (bigmap.lua's big-map-block wrap target) still exists — that wrap
  is fine.

### Goal

Server-owner-placed energy stations (refuel) and garages (repair) shown as BeamNG world markers
+ Big Map POIs, with a "drive up -> press to refuel/repair" prompt, gated off during BJS
scenarios (race/hunt/infected). Edited from an in-world editor in a new Freeroam config tab. The
groundwork (POI contribution, the freeroam-data service, a scenario-lock authorization hook) is
built to carry bus lines / deliveries / derby later.

### Non-goals this phase

Bus lines, deliveries, derby, quick-travel-to-POI, GPS-to-nearest-station, reputation/XP, legacy
BJI import of station data.

### What BJS already has (reuse, don't rebuild)

- In-world editor framework: `ui/activityEditor.lua` + `ui/pointListEditor.lua` + per-activity
  wrappers (race/hunter/infected). `pointListEditor` already supports `hasRadius` point lists
  (no facing) — exactly the station/garage shape.
- Activity persistence: `dao_activity` reads/writes arbitrary `<map>_<type>.json`; `dao_bundled`
  seeds shipped defaults once via a ledger. Fully generic already.
- Big Map POI hooks: `bigmap.lua` wraps `getRawPoiListByLevel` wholesale (stale approach — the
  modern one is the additive `onGetRawPoiListForLevel` hook) and exposes its own
  `onBJRequestBigmapPOIs` hook, **implemented by nothing in BJS**. See improvement #1.
- Config plumbing (`services/config.lua` -> client `config.lua` -> Angular accordions),
  permission keys, per-service cache push, the races/hunter/infected legacy-import pattern.

### Phase 0 — DONE 2026-09-10 (data plumbing, not deployed)

- Server `services/freeroamData.lua` (new) — owns per-map station + garage lists; load / sanitize
  / seed (`dao_bundled`) / cache / save + `energyStationsSave` / `garagesSave` RX handlers gated
  on the new permission. Modeled on `services/races.lua`.
- Server `services/permissions.lua` — `EditFreeroamData` key (rank `mod`).
- Server `services/config.lua` — `Freeroam` block + `RefuelDuration` / `RepairDuration` /
  `PreserveEnergyOnRefuel` with validation + backfill.
- Server `BeamJoyServer.lua` — `services_freeroamData` in load order.
- Client `beamjoy/freeroamData.lua` (new) — mirrors `stations` / `garages` caches, fires
  `onBJFreeroamDataChanged`, pushes a snapshot to the config UI.
- Client `beamjoy/main.lua` — `beamjoy_freeroamData` in load order.
- Client `beamjoy/permissions.lua` — `EditFreeroamData` key + folded into `canOpenConfig`.

### Phase 1 — to build (markers + refuel/repair)

#### New files — client `lua/ge/extensions/beamjoy/`

- `stations.lua` — the whole client feature. Reads `beamjoy_freeroamData.data`; contributes a POI
  per station/garage (via `onGetRawPoiListForLevel` if going native-marker, or draws its own
  `shape.lua` ring + proximity check if going self-contained); implements
  `onActivityAcceptGatherData` (add a refuel/repair button when our elem is present, the player
  owns a slow/stopped vehicle, the gate passes, and tank/damage state warrants it); runs the
  freeze -> external-cam -> countdown -> apply process. Refuel = `core_vehicleBridge` energyStorage
  read + `setEnergyStorageEnergy`. Repair = an in-place reset through `beamjoy_inputs` (which
  already has the `REPAIR` / preserve-energy plumbing). Local-only, no server round-trip. Gate is
  a hook (see improvement #3), not a hardcoded boolean.
- `ui/stationEditor.lua` — `pointListEditor` wrapper: two `hasRadius` lists (`energyStations`,
  `garages`). Per-station energy-type override — see improvement #5 (default to "any", make the
  multiselect an optional advanced field, so `pointListEditor` needn't be extended yet).

NOTE: `interactiveMarker.lua` (the BJI `InteractiveMarkerManager` port) is CUT — the native
system it wrapped no longer works the way BJI assumes. See "Native API research" above.

#### New files — client UI `ui/modModules/beamjoy/`

- `windows/config/freeroam/app.{js,html}` — the Freeroam tab shell (collapsible sections; Phase 1
  has one: "Stations & Garages").
- `windows/config/freeroam/stations/app.{js,html}` — Angular sidebar (list rows, radius slider,
  energy-type buttons, add/goto/delete, snap toggle), modeled on `config/infectedArena`.
- Register in `beamjoy.js`, `windows/config/app.js` import list + `tabsData`. Tab visible only to
  `EditFreeroamData` holders + staff, like the other editor tabs.

#### Server — done in Phase 0 (see above). Phase 1 adds nothing server-side except optional
bundled `<map>_stations.json` / `<map>_garages.json` — see improvement #6 (may skip entirely).

#### Locales

- `Client/BJ/beamjoy_locales/*.json` (13) — Freeroam tab, editor labels, marker/prompt text,
  toasts ("Refueled", "Repaired", "Tank already full", ...). en-US first, then the other 12 per
  the established localization-pass convention.
- `Server/BeamJoyServer/locales/*.json` — save-rejection error strings.

### Data schemas

```
<map>_stations.json : [ { id:int, name:string, pos:{x,y,z}, radius:number,
                          types:[ "gasoline"|"diesel"|"kerosine"|"electricEnergy" ] } ]
<map>_garages.json  : [ { id:int, name:string, pos:{x,y,z}, radius:number } ]
```

One file per type (BJS `dao_activity` convention), `id` unique per map, same seed-once ledger as
races.

### Wiring into existing systems

- POI contribution: implement `onGetRawPoiListForLevel` in `beamjoy_stations` (native path), OR
  draw a `shape.lua` ring + own the proximity check (self-contained path). For the Big Map, feed
  the same data through `bigmap.lua` (see improvement #1 — migrate it to `onGetRawPoiListForLevel`
  first).
- `activityEditor.lua` — add `stationEditor` to `editors`; forward a new `onBJFreeroamDataChanged`
  (same pattern as `onBJInfectedArenaChanged`).
- `restrictions.lua` — during an active refuel/repair process, block vehicle switch / camera
  change / free cam / big map / photo mode; released when the process ends or is cancelled.
- `inputs.lua` — repair does an in-place reset; cancel the process cleanly on reset / switch /
  leave-radius mid-countdown.

### Improvement opportunities (found during the API research)

1. **DONE 2026-09-10 (build 2363).** `bigmap.lua` rewritten for the game's current Big Map
   (`freeroam_vueBigMap`, which replaced `freeroam_bigMapPoiProvider`). It now delegates
   `getRawPoiListByLevel` to the real (saved) one - so vanilla POIs and native contributors pass
   through live - and appends BJS custom POIs with `data.type` = a real non-mission type
   (`gasStation` / `garage` / `other`) plus the `markerInfo.bigmapMarker` shape
   `vueBigMap.processNonMissionPoi` / `formatPoiForBigmap` expects. Removed: the `data.type =
   "mission"` tag (the FATAL cause - `formatSaveDataForUi` on a nonexistent mission, which also
   wiped every vanilla POI), the dead `sendCurrentLevelMissionsToBigmap` and `getMissionById`
   overrides, the stale BJReady `vanillaPOIs` freeze, the unused `TABS` / `generatedPOIs` /
   `createNavGraphRoute` (the last was already broken - `_routeParams` undefined). Kept: the
   `getCurrentTaskdataTypeOrNil` scenario map-block. Also filters `data.type == "mission"` from
   the passed-through list (career missions / scenarios / challenges - a sandbox doesn't run them,
   matches the old version's intent). `beamjoy_stations` re-enabled its `onBJRequestBigmapPOIs`:
   stations -> `type_gasStation`, garages -> `type_other` (vueBigMap's freeroam side menu only
   surfaces `type_garage` when a career is active). Confirmed in-game 2026-09-10: vanilla POIs
   back, missions gone, test station shows.
   FOLLOW-UP: BJS points currently mix into the native gasStation / other groups. A dedicated
   "BeamJoy" side-menu section would be cleaner - `bigmap.lua` can add it via
   `onBigmapBuildGroupData` + `onBigmapBuildCustomGroupStructures`, with custom POIs carrying
   `data.customGroupTags`. Deferred (cosmetic).
2. **DONE 2026-09-10.** `beamjoy_context.isScenarioLocked()` — single OR of the three runner
   predicates (`isRaceLocked`/`isHuntLocked`/`isGameLocked`, already identical in shape).
   `bigmap.lua`'s big-map-block repointed at it. Only existing call site was `bigmap.lua`; no
   runner changes needed. New Phase 1 code uses it for "suppress this during any scenario" checks.
3. **DONE 2026-09-10 (infra).** `onBJRequestStationInteraction(req, kind)` hook — `kind` is
   `"refuel"` | `"repair"`. Handlers added to all three runners (each denies both kinds for its
   own locked window, colocated with its reset-auth hook). Fires nowhere until `stations.lua`
   lands; then that file calls it before starting the process instead of hardcoding a lock check.
4. **Guidance (nothing to build now).** Don't port BJI's `Stations.lua` free-cam-only placement;
   use `pointListEditor` (place-at-vehicle, gizmo, ground-snap, teleport-to). Applies when
   `ui/stationEditor.lua` is built.
5. **DONE 2026-09-10.** `services/freeroamData.lua`: station `types` empty/absent resolves to
   `DEFAULT_FUEL_TYPES` = `{gasoline, diesel, kerosine, n2o}` — everything except electric (an EV
   at an unmarked pump gets no recharge prompt; electric is opt-in via `{"electricEnergy"}`).
   Offerable set `ENERGY_TYPES` includes n2o. A non-empty list is an explicit override. The editor
   leaves it empty unless the host opens an advanced per-station override — so `pointListEditor`
   needn't be extended for Phase 1. `stations.lua` implements the resolution.
6. **DONE 2026-09-10 (native-gate half).** `stations.lua` wraps
   `freeroam_gasStations.onActivityAcceptGatherData` to contribute nothing while
   `isScenarioLocked()` — so a map's own pumps can't be used mid-race/hunt/infected either.
   Restored on unload via `RollBackNGFunctionsWrappers`. No bundled station data is shipped
   (admins place their own; the console test-builder covers pre-editor testing).

### Sequencing (Phase 1)

1. (improvement #1) migrate `bigmap.lua` to `onGetRawPoiListForLevel`; verify existing behavior
   unchanged.
2. (improvement #2/#3) add `isScenarioLocked()` + the `onBJRequestStationInteraction` hook,
   implemented by the three runners.
3. `beamjoy_stations`: POI contribution + `onActivityAcceptGatherData` + the freeze/countdown/
   apply process. Test at a console-inserted station.
4. `ui/stationEditor.lua` + Freeroam tab + station section — full editor round-trip.
5. Restrictions during process; process-cancel edge cases.
6. Locales (13).
7. Deploy: bump client + server `version`/`buildversion`, `UI_BUILD`, CHANGELOG,
   `7z u ../BJ.zip`, sync to `BeamJoy-sandbox-main`.

### Reference source

- Current game: `E:\Steam Library\steamapps\common\BeamNG.drive\lua\ge\extensions\` —
  `gameplay/markerInteraction.lua`, `gameplay/playmodeMarkers.lua`, `gameplay/rawPois.lua`,
  `gameplay/markers/missionMarker.lua`, `gameplay/markers/gasStationMarker.lua`,
  `freeroam/gasStations.lua`, `freeroam/facilities.lua`, `ui/missionInfo.lua`.
- BJI (for the editor UX + process shape only, NOT the marker layer):
  `X:\beam\essentials\beamjoy-2.0.8` -> `Client/BJI.zip` -> `StationsManager.lua`,
  `ui/windows/ScenarioEditor/Stations.lua` + `Garages.lua`.

### Later phases

- Phase 3 — deliveries (package + vehicle modes, two-point-list editor, minimal leaderboard).
- Phase 4 — derby (full 4th competitive gamemode: `services/derby.lua` + `services/derbyGrid.lua`
  + `derbyRunner.lua` + HUD/countdown/results, arena browse-list editor). Bigger than 1-3
  combined.
- Phase 5 — polish: quick-travel + GPS-to-nearest wiring, per-type legacy BJI import.


## Bus lines — Phase 2 (IN PROGRESS, started 2026-09-10)

Server-owner-defined bus routes: an ordered list of stops per line, per map. A player picks a
line, spawns/gets a `citybus`, and drives the route stop-to-stop with GPS guidance; arriving and
holding briefly in each stop's radius advances it; the last stop finishes (or loops if the line
is `loopable`). Solo activity, entirely client-side gameplay (like stations - no server round
trip for the drive itself). **No rewards / XP / reputation** (BJS dropped that whole system;
BJI's `BusMissionReward` tx is not ported).

### Reference

- BJI: `beamjoy-2.0.9/BJI.zip` -> `lua/ge/extensions/BJI/scenario/ScenarioBusMission.lua`
  (gameplay loop), `ui/windows/ScenarioEditor/BusLines.lua` (editor), `BusMissionPreparation.lua`
  (line picker), `managers/BusUIManager.lua` (the in-bus HUD glue: kneel / doors / request-stop
  via `core_vehicleBridge` on the `citybus` controller).
- Native: `E:\Steam Library\...\lua\ge\extensions\core\busRouteManager.lua` +
  `gameplay/missionTypes/busMode/`. Maps MAY ship `buslines/*.buslines.json` + a `busstops`
  SimGroup of `BeamNGTrigger`s (east/west_coast_usa, italy have them; most maps don't). We do
  NOT depend on those - own gizmo-placed stops, works on every map. A "pull in this map's native
  bus stops" import is a possible later convenience.

### Data shape

```
<map>_buslines.json : [ {
    id: int,                       -- unique per map (assignIds, like stations)
    name: string,                  -- <= 40 chars, cleanName fallback "Line N"
    loopable: bool,
    stops: [ { name: string,       -- <= 40, fallback "Stop N"
               pos: {x,y,z},
               dir: {x,y,z},        -- facing (forward vector), same convention as hunter spawns
               radius: number } ]   -- [1,10], default 3 ; >= 2 stops per line or the line is dropped
} ]
```

One file per map (`dao_activity`), seed-once ledger (`dao_bundled`) - identical machinery to
`services/freeroamData.lua`.

### Phase 2.0 — foundation (DONE 2026-09-10)

- Server `services/busLines.lua` (new) - load / sanitize / seed / cache / `busLinesSave` RX
  handler, gated on new perm. Cloned from `services/freeroamData.lua`'s single-list half.
- Server `services/permissions.lua` - `EditBusLines` key (rank `mod`).
- Server `BeamJoyServer.lua` - `services_busLines` in load order.
- Client `beamjoy/busLines.lua` (new) - cache holder, fires `onBJBusLinesChanged`, pushes a
  snapshot to the config UI. Cloned from `beamjoy/freeroamData.lua`.
- Client `beamjoy/main.lua` - `beamjoy_busLines` in load order.
- Client `beamjoy/permissions.lua` - `EditBusLines` key + into `canOpenConfig`.

### Decisions (locked 2026-09-10)

1. **Editor home:** a second collapsible section ("Bus Lines") in the existing **Config >
   Freeroam** tab, below "Stations & Garages". `EditBusLines` still gates that section's own
   visibility (the tab shows if you hold EditFreeroamData OR EditBusLines).
2. **Activity entry:** BOTH - a Big Map POI per line (name, stop count, route length; Set route
   + Start) AND a drive-up prompt at stop 1 (`onActivityAcceptGatherData`, exactly like the fuel
   stations).
3. **Bus vehicle:** any bus, not just citybus. "Is a bus" for a spawned vehicle =
   `core_vehicles.getVehicleDetails(vid).model['Body Style'] == 'Bus'` ; for a model/config in
   the selector = `(core_vehicles.getModel(model).model or {})['Body Style'] == 'Bus'` (the
   game's own test - covers citybus, schoolbus, and any bus mod that declares itself one). If the
   player is already in a bus, start in it. Otherwise **open the vehicle selector pre-filtered to
   buses** - NOT a citybus spawn offer. Mechanism is exactly raceRunner's "pool" restriction
   (raceRunner.lua ~L1622): `busRun` sets a "needs a bus" flag, registers an
   `onBJRequestCanSpawnVehicle(req, model, config, mode)` hook that denies every non-bus model
   while the flag is set, then calls
   `extensions.ui_vehicleSelector_general.openVehicleSelectorForFreeroam()` - `vehicleSelector.lua`'s
   `passesFilters` wrapper already routes the grid through that same hook, so the selector shows
   only buses with no manual search/filter state. When the player lands in a bus
   (`onVehicleSwitched` / the `onUpdate` bus check), clear the flag and begin the route.
4. **Corner markers:** the simpler path - a single ground ring (`shape`) + the native POI marker
   at the current target stop, matching where `stations.lua` landed. NOT BJI's 4 bus-sized
   `BeamNGWorldObject` corner markers.

### Phase 2.1 — editor (DONE 2026-09-10, client build 2380, uncommitted)

`pointListEditor` didn't fit (flat, no reordering), so bus lines got their own editor:

- `stationEditor.lua` -> **renamed `freeroamEditor.lua`** : now the coordinator for the whole
  Config > Freeroam tab. Owns the one `activityEditor.activeEditor` slot, tracks a `section`
  ("stations" | "buslines"), dispatches onBJClick / save / close / cache-change to the live
  section. Stations still via a `pointListEditor` instance; bus lines via `busLineEditor`.
- `beamjoy/ui/busLineEditor.lua` (new) - a sub-module (NOT an `activityEditor` slot), driven by
  `freeroamEditor`. `state.lines` (each `{id?, name, loopable, stops=[{name,pos,dir,radius}]}`),
  `activeLine` / `activeStop`. Full `BJEditorBusLines*` handler set: select/add/delete line +
  stop, rename, loopable, drag-and-drop reorder (`onMoveStop`, lifted from raceEditor.lua's onReorderGates via cmps/sortable), radius, set-to-vehicle, teleport-to,
  world-click select, own snap toolbar wiring. Renders the active line as connected `shape.addLine`
  segments + a facing arrow + labelled sphere per stop; a dim single marker for inactive lines;
  an orange loop-closing segment when `loopable`. Own gizmo for the selected stop (pos + flattened
  `dir`).
- `pointListEditor.lua` gained a `reassert()` (re-render + re-push without reset) so switching
  back to the Stations section restores its 3D shapes.
- `activityEditor.lua` forwards a new `onBJBusLinesChanged` to the active editor.
- Angular: `bjConfigFreeroam` rebuilt with a section bar (Stations & Garages / Bus Lines), one
  panel shown at a time, each with its own snap toolbar. Switching sections is disabled while
  dirty (Save / Discard buttons in the pinned header). `bjConfigBusLines` (new, same file) is the
  bus sidebar - line rows with inline name + loopable + delete, and for the selected line an
  indented ordered stop list, drag-to-reorder (cmps/sortable, same as the race editor), name, radius, car/teleport/delete.
- `config/app.js` Freeroam tab now visible to `EditFreeroamData` OR `EditBusLines`.
- 15 locale keys (`beamjoy.buslines.*`, `freeroam.sections.*`, reworded `hint`/`confirmDiscard`)
  across all 13 languages.

### Phase 2.2 — gameplay (DONE 2026-09-10, client build 2381, uncommitted)

- Client `beamjoy/busRun.lua` (new, `beamjoy_busRun` in main.lua). Not a full BJS "runner" (no
  lobby / grid / MP sync) - a local process like `stations.lua`. `M.startLine(line)` -> if
  `currentIsBus()` (`core_vehicles.getModel(model).model['Body Style'] == 'Bus'`) begin
  immediately, else set `needBus` + open `openVehicleSelectorForFreeroam()` (the
  `onBJRequestCanSpawnVehicle` hook filters the grid to buses; 30 s deadline so a
  closed-without-picking selector never wedges vehicle spawning). `onSlowUpdate` (250 ms):
  horizontal distance to `stops[nextStop]`, hold `holdSeconds()` (`Freeroam.BusStopHoldDuration`,
  default 3) inside the radius -> `advance()` -> finish, or loop to stop 1 if `line.loopable`.
  `nextStop` starts at 1 (drive to the first stop first) so it works from anywhere. Native GPS
  via `core_groundMarkers.setPath`; a translucent `shape` sphere at the target stop; both
  re-issued only on target change.
- Entry: Big Map POI per line (`onBJRequestBigmapPOIs`, icon `bus`, groupType `other`) + a
  drive-up "Start line" button at stop 1 (`onGetRawPoiListForLevel` missionMarker +
  `onActivityAcceptGatherData`, `data.type = "bjBusLineStart"`). All three contribution hooks
  bail while a run is active / the freeroam editor is open / a round is locked.
- HUD: `windows/busHud/app.{js,html}` (`bjBusHud`, registered in beamjoy.js) - line name,
  "stop N / total", progress bar, "approaching" cue while holding, End-run button (`BJBusHudStop`).
  Modelled on `hunterHud`.
- Restrictions while driving (`onBJRequestRestrictions` + `beamjoy_restrictions.update()` on
  start/stop): `switch_next_vehicle` / `switch_previous_vehicle` (also closes the ESC-menu
  vehicle panel = no repair / delete / paint) + `toggleWalkingMode`.
- Gate: `beamjoy_context.isScenarioLocked()` - refuses to start, auto-stops a running line, and
  drops every POI during a Race / Hunter / Infected round (busRun's own gate + a second layer in
  `bigmap.lua getRawPOIs`, `dropBus`).

### Phase 2.3 — locales (DONE 2026-09-10)

`beamjoy.buslines.*` (editor + play/flash + HUD) + `freeroam.sections.*` - 28 keys total across
all 13 languages (823 keys each).

### Phase 2 — bug fixes from first in-game test (2026-09-10, client build 2385)

- **"Only city buses showed in the selector."** Real, confirmed bug: `"Body Style"` is frequently
  a per-CONFIG field, not a model-level one - `citybus`'s own base info.json declares it directly,
  but `md_series` (the truck platform behind the schoolbus/prisonbus/derbybus configs) does NOT ;
  only each config's own `info_md_*.json` sidecar sets it. The old `isBusModel(model)` only ever
  checked the model level (same narrow test native's own `isBus(vehId)` uses), so every
  config-level bus was invisible to the filter.
  **First attempt at the fix (build 2383) was itself wrong** - `getModel(model).configs[config]`
  as a direct table index, on the unverified assumption `.configs` is keyed by the bare config
  string. It isn't necessarily: `core_vehicles.getConfig(modelName, configKey)` - the real native
  accessor, confirmed by reading its own body - `pairs()`-iterates `.configs` matching each
  entry's own `.key` field, never a raw index. The first fix silently kept resolving to the base
  model (still no Body Style for md_series) and changed nothing, which is why "now it's only
  showing the Wentward bus" (citybus) was reported again after that build.
  **Build 2385 fix:** `isBusModelConfig`/`currentIsBus` now call `core_vehicles.getConfig()`
  directly - the exact accessor native's OWN "busRoute" vehicle-selector restriction mode
  (`ui/vehicleSelector/general.lua`'s `vehiclePassesFilters`, a real, purpose-built native filter
  for "buses for a route") resolves a config through. That native mode additionally requires
  `Commercial Class == "Transit Bus"`, which excludes the schoolbus/prisonbus/derbybus configs too
  (they're `Class 7 Truck`) - deliberately NOT adopted, since the user explicitly asked for "any
  bus type", broader than native's own transit-only definition.
- **"It said I must choose a bus" after picking one.** Was the pre-existing `beamjoy.buslines.play.pickBus`
  toast (6s duration) still on screen, not a new rejection.
- **"The vehicle selector went away" (build 2385 theory was wrong ; real fix in 2386).** Build
  2385's theory (a lazy-init race on the FIRST-ever selector open each session) didn't match the
  real trigger the user pinned down: it happens on clicking ANY config, every time, not just
  once per session - so the pre-warm in `vehicleSelector.lua` (kept, harmless, but not the fix).
  Real cause: every OTHER caller of `openVehicleSelectorForFreeroam()`
  (raceRunner/hunterRunner's own vehicle-pool steering) calls `beamjoy_vehicles.deleteCurrentOwnVehicle()`
  FIRST, and busRun didn't. `vehicleSelector.lua`'s own comments confirm a normal tile
  pick/double-click routes through `core_vehicles.replaceVehicle` specifically "when a vehicle
  already exists" - a different native path than picking with nothing there. Leaving the player's
  existing (non-bus) vehicle in place while the selector was open took that "replace" path, and
  that's what closed the selector as soon as any config was clicked. Fix: `M.startLine` now
  deletes the current vehicle before opening the selector too, matching the established pattern
  exactly instead of guessing further at selector internals.
  **Build 2386 still wasn't the real fix either** - it recurred. A BeamNG.log capture from the
  user nailed the actual mechanism: two `ui_router` transitions to `menu.vehiclesnew` back to
  back, ~2.7s apart, nothing else logged in between - the first one completes cleanly
  (211.894->212.121), the second one (214.834) is what breaks
  (`[RouteScopeValidator] targetScope "grid-selector-grid" not found after mount`) and times out/
  cancels ~3s later. Navigating to a route the router is ALREADY sitting on corrupts its Vue
  scope mounting. Root cause: `M.startLine` had no guard against being re-entered while
  `M.needBus` was already true - a second call (world prompt re-showing/re-triggering while the
  player is briefly on foot after their vehicle was just deleted, most likely) re-ran the whole
  branch and called `openVehicleSelectorForFreeroam()` a SECOND time on top of the still-active
  first one. **Build 2387 fix:** `M.startLine` now also bails if `M.needBus` is already true, and
  `contributionsSuppressed()` (gating `onGetRawPoiListForLevel` / `onActivityAcceptGatherData` /
  `onBJRequestBigmapPOIs`) now includes `M.needBus` too, so the "Start line" button can't even be
  offered again while a pick is already pending, whatever re-triggers it.
  **Build 2388 test: the guard held (confirmed no second BJS-side open call - only one
  `Vehicle:delete`), but the glitch still happened.** Fresh BeamNG.log from that test shows the
  FIRST transition itself reporting "Transition completed" cleanly, then ~4s later a
  `RouteScopeValidator` warning that its own `"grid-selector-grid"` scope mounted under the wrong
  parent (`actual: "root"`), followed by what reads like the engine's own recovery attempt -
  another transition to the same route, which then fails outright ("not found after mount"). No
  BJS code (all of races/hunter/infected/busRun checked) calls `openVehicleSelectorForFreeroam`
  more than once per attempt, so this isn't a second call from Lua. **Build 2389 (untested):**
  theory shifted to timing - `deleteCurrentOwnVehicle()` kicks off a same-frame cascade (vehicle
  destroy -> switch to -1 -> input rebind, all within ~10ms in the log) AND leaves the camera in
  FREE cam (confirmed by the user - NOT walking mode, an earlier assumption in this same
  investigation was wrong about that) that `openVehicleSelectorForFreeroam()` used to be called
  into IMMEDIATELY afterward, in the same tick. Deferred it by 200ms (`async.delayTask`) so that
  cascade settles first - genuinely new, not attempted anywhere else in this codebase before.
  race/hunter/infected still call the two back to back with no delay, so if this fixes it, the
  same 200ms defer should get backported to them too (the user reports hitting this exact glitch
  in hunter mode already). Still awaiting a test result on build 2389.
  **User precisely re-characterized the bug, ruling out vehicle deletion/camera timing
  entirely: it's specifically the FIRST time the filtered selector is opened in a session that
  can glitch ; retrying (a second open) reliably works.** Reverted the 200ms defer (wrong
  premise). Real fix (build 2390, untested): the `M.needBus` re-entry guard from 2387 was too
  blunt - it silently blocked ANY second attempt for up to the full 30s `needBusUntil` deadline,
  even a legitimate retry after the first one had ALREADY visibly failed, which fights the user's
  own working workaround. Added `onSelectorRoute()` (`extensions.ui_router.getCurrent().request.name
  == "menu.vehiclesnew"`) so `M.startLine` can tell "a prior attempt is still genuinely showing,
  don't touch it" apart from "it already ended somehow, a fresh attempt is safe" - only refuses a
  retry while the router is still actually sitting on the selector's own route. Deliberately NOT
  applied to `onSlowUpdate`'s own polling (a same-tick-window false negative there - checking
  before the route has even had a chance to update after the call - would incorrectly abandon a
  still-forming, otherwise-fine attempt; a manual retry click happens long enough after the fact,
  by human reaction time, for this race to not matter there).
  **Build 2390 confirmed NOT the fix.** A fresh log from that test still showed the same pattern:
  `menu.vehiclesnew` transition completes cleanly (proper `mountReady` phase, no warnings this
  time), then a SECOND `menu.vehiclesnew` transition starts ~1.8s later with no preceding warning
  and no `mountReady` phase of its own - i.e. the router really is re-mounting the identical route
  a second time, for reasons outside BJS's own call sites (all of races/hunter/infected/busRun
  re-checked; none call `openVehicleSelectorForFreeroam` more than once here, and `onSelectorRoute()`
  would have refused a second BJS-originated call anyway). Crucially, `VehicleSelectorDataLoaded`
  (the CEF/Vue event that actually populates the grid) never fires at all this attempt - confirmed
  absent from the log, whereas two unrelated, working pause-menu selector opens earlier in the
  SAME log both show it firing ~40-150ms after their own transition completed. So the router
  considers the mount a success while the grid's own data never arrives - a UI-data-hydration
  miss, not a router/mount failure as previously assumed.
  **Build 2391 (untested) - actual root cause, found by reading the real mount code path**
  (`util/asyncBulkLoader.lua` + `ui/vehicleSelector/general.lua`): every vehicle-selector route
  mount (`M.onRootRouteMount`) calls `beginAsyncPauseRouteMount()` -> `util_asyncBulkLoader.loadVehicles()`.
  If `core_vehicles.isModelsDataLoaded()` is already true (every open after the first), that
  returns `"alreadyLoaded"` and the grid snapshot is emitted next tick, no race. The session's
  FIRST open ever finds it false, so it instead kicks off an async `core_jobsystem` job and waits
  for `asyncVehicleLoadComplete` to fire later - and that completion handler
  (`emitPauseRouteSnapshot`) explicitly, silently DISCARDS the entire grid snapshot if the
  router's current route no longer matches the route that was pending when the job started
  (`isPendingPauseRouteStillCurrent`). A second mount of the same route landing inside that
  window - exactly what both captured logs show - is a real way to hit that exact mismatch and
  explains a mount that "succeeds" while the grid never populates, with zero errors anywhere.
  Fix: `vehicleSelector.lua`'s `onBJClientReady` now also force-calls
  `util_asyncBulkLoader.loadVehicles()` (new `prewarmVehicleModelList`, alongside the old
  `getUiData()` prewarm from 2385 - confirmed a DIFFERENT, unrelated cache, kept but not the fix)
  well before the player can possibly reach a bus stop, so `isModelsDataLoaded()` is already true
  by the time any filtered selector opens - collapsing every open, first included, onto the same
  safe path a working retry already takes. `busRun.lua`'s `M.startLine` also got a defensive
  fallback (checks `isModelsDataLoaded()` itself, kicks the load and retries after 500ms if
  somehow still false) in case the prewarm hasn't finished yet for some reason. If this holds,
  backport the SAME `onBJClientReady` prewarm reasoning to confirm race/hunter/infected are
  covered too (they share `vehicleSelector.lua`, so they already get it for free - no separate
  fix needed there, just needs confirming).
  **Correction, logged here to avoid re-reading this section as still accurate below:** the
  second navigate's trigger (next few bullets) was first mis-attributed to an automatic Vue
  boot-time self-navigate. User pushback + confirmation against the unminified Vue source
  (`VehicleSelector.vue`'s `onGridNavigateRequest`) showed it's actually the PLAYER clicking into
  a grid item's own sub-path (a brand/model folder, or a bus's config list) shortly after the
  selector opens - `"menu.vehiclesnew"` has no child route to drill into (unlike the pause
  selector), so that click re-navigates the SAME root route with an updated `path` param instead.
  Doesn't change the mechanism, the fix, or anything below - only who/what fires the second call.
  **Build 2391's prewarm confirmed NOT sufficient.** A fresh test still hit the identical failure:
  `menu.vehiclesnew` mounts and completes cleanly, then mounts a SECOND time ~1.2s later with
  nothing logged in between explaining why, and this time the actual failure signature shows up
  explicitly - `[RouteScopeValidator] Route "menu.vehiclesnew": targetScope "grid-selector-grid"
  not found after mount` + `scope "grid-selector-details" declared but not rendered after mount`,
  both logged from inside BeamNG's own minified CEF/Vue bundle (`ui-vue/dist/base.js`) with no
  Lua-side hook to listen for. `VehicleSelectorDataLoaded` never fires. The prewarm narrows the
  race window this can exploit but evidently doesn't close it, and there's no further Lua-visible
  signal left to chase into un-inspectable minified JS.
  **Build 2392 (untested) - stopped trying to prevent the glitch, automated the workaround
  instead.** Every single capture so far, without exception, shows the SAME recovery working: back
  out of the selector, try again, it works. New `watchdogReopenSelector()` in `busRun.lua`
  schedules itself 1.5s after `M.startLine` opens the selector (well past the ~150ms a working
  open's own `VehicleSelectorDataLoaded` has always fired by, comfortably before the
  RouteScopeValidator failure becomes observable at ~4-5s) - if still waiting on a bus pick and
  still sitting on the selector's own route at that point, it calls `ui_router.back()` then
  reopens `openVehicleSelectorForFreeroam()` fresh, exactly mirroring the manual workaround. A
  `selectorWatchToken` counter invalidates any stale scheduled watchdog if a newer `M.startLine`
  attempt (a real user retry) supersedes it first. If a first attempt is actually fine, this is
  just a harmless ~1.5s-later flicker.
  **Build 2392's 1.5s watchdog confirmed working** (user: "well it worked because it closed then
  reopened again") but the user asked to keep digging for the actual root cause rather than stop
  at the workaround.
  **DEFINITIVE root cause found (build 2393 diagnostic + 2394 wider-window follow-up).** Wrapped
  `extensions.ui_router.navigate` in `vehicleSelector.lua` to log a full Lua stack trace on every
  call to `"menu.vehiclesnew"`. Two captures with this wrap nailed it precisely: BJS's own first
  navigate (traced cleanly to `busRun.lua`'s `M.startLine`) always mounts fine. ~1.5s later, a
  SECOND navigate to the same route fires with a traceback showing only `"main chunk of line"` -
  no Lua-side caller at all, meaning it's BeamNG's own CEF/Vue vehicle-selector UI calling back
  into Lua directly via the engineLua bridge, carrying a drilldown `path` param (almost certainly
  restoring its last-viewed category once it finishes booting). The router's log then shows
  exactly why this breaks: `Transition timeout for route: menu.vehiclesnew reason:
  route_navigation_not_started ... phase: routerStart phaseElapsed: 1.01s` - the router's own
  internal 1-second budget for that phase's CEF handoff ack expires, and the ROUTER ITSELF force-
  cancels the transition. `RouteScopeValidator`'s "not found/wrong parent" warnings are just the
  downstream symptom of this. It was also observed recurring a third time within a single capture
  before finally sticking. This is entirely inside BeamNG's own compiled router timeout logic and
  CEF boot sequencing - there is no Lua-side lever to prevent it. Removed the diagnostic
  `navigate` wrap (mission accomplished). Hardened `watchdogReopenSelector` from a single 1.5s
  shot into a bounded multi-round retry (`WATCHDOG_INTERVAL_MS = 2500`, `WATCHDOG_MAX_ROUNDS = 3`)
  to match the observed can-take-more-than-one-round behavior - shipped as build 2395, still not
  confirmed fixed live. vehicleSelector.lua's model-catalog prewarm (2391) is kept since it still
  closes one distinct, real race, just not this one.
  **User ran both suggested control tests. Results settle two separate open questions at once:**
  - **Test A ("don't touch anything" after opening):** the selector kept auto-reopening every
    ~2.5s for all 3 of build 2395's watchdog rounds. This did NOT reproduce the underlying engine
    glitch passively (consistent with the corrected "it's the click that triggers it" theory) - it
    exposed a REAL BUG IN THE WATCHDOG ITSELF instead: `onSelectorRoute()` can only tell "still on
    the selector's route", not "actually broken", so a perfectly fine grid the player simply
    hasn't picked from yet looks IDENTICAL to a stuck one from that check's perspective. The
    watchdog was needlessly forcing reopens on a working selector the whole time.
  - **Test B (console-triggered `openVehicleSelectorForFreeroam()`, zero BJS filtering - `M.needBus`
    never set so `onBJRequestCanSpawnVehicle` never restricts anything):** opened clean, then
    clicking into a vehicle's configs ~22s later hit the IDENTICAL failure -
    `Transition timeout for route: menu.vehiclesnew reason: route_navigation_not_started ...
    phase: routerStart phaseElapsed: 1.00s`. Decisive: this is airtight confirmation the bug is
    100% native and has NOTHING to do with BJS's filter hook, `isBusModelConfig`/`getConfig()`
    cost, or any BJS code path at all.
  - **Resolves "why only the first time":** it's not "first bus attempt" - it's the first time
    THIS SPECIFIC code path (clicking into configs on the no-child-route freeroam selector) gets
    exercised in the session at all. Normal vehicle switching goes through the PAUSE menu's own
    selector (a different route, with a real child route for viewing configs), so it never
    exercises this path - BJS's freeroam selector opens are likely the only thing in normal play
    that ever hits "menu.vehiclesnew" directly, which is why the bug looks bus-line-specific even
    though it demonstrably isn't.
  **Build 2396 - redesigned recovery, event-driven instead of timer-guessed.** Fixed the real bug
  Test A found: replaced the polling `watchdogReopenSelector` (WATCHDOG_INTERVAL_MS/MAX_ROUNDS,
  `selectorWatchToken`, all removed) with `M.routeChangeCancelled`, wired to BeamNG's own router
  hook (`Constants.RouterHooks.ROUTE_CHANGE_CANCELLED` = `"routeChangeCancelled"`, fired by
  `ui/router.lua`'s `cancelActiveTransition` on every cancelled transition, timeout included).
  Recovery now fires the instant the router itself confirms a `"menu.vehiclesnew"` transition
  actually got cancelled (checked via `payload.toRoute.name`), while `M.needBus` is true - never
  on a guess, never on a working-but-idle grid. Still not confirmed fixed live.
  **Build 2397 - the actual fix, not just better recovery.** User asked whether the PAUSE vehicle
  selector could be used instead (it has a real child route for viewing configs), or whether
  freeroam's `menu.vehiclesnew` could somehow be given one via arguments. The second isn't
  possible - lacking a `children` table is a structural property of that route's own definition
  (`ui/router/routes/menu.lua`), not a call-time option a mod can inject. The first is exactly
  right: `ui/router/routes/pause.lua`'s `["vehicleSelector"]` entry (`pause.vehicleSelector`) DOES
  have `children = { vehicle = { screenId = "pause.vehicleSelector.vehicle", ... } }` - clicking
  into a vehicle's configs there navigates to a genuinely different route, never re-navigating the
  same one, which is the exact precondition this whole bug family needs. `M.startLine` now opens
  `pause.vehicleSelector` via `openFromPause()` instead of `openVehicleSelectorForFreeroam()`.
  Filtering is unaffected (`passesFilters`/`onBJRequestCanSpawnVehicle` gate every tile at the
  grid-selector level regardless of which route opened it). Strong empirical backing too: this is
  the exact route the player's own client already uses for every normal (non-BJS) vehicle change
  all session, including config drilldowns, and it never once failed in any capture. One real,
  minor UX change: cancelling without picking now lands in the general pause menu instead of
  straight back to driving (`pause.vehicleSelector`'s own `backTarget = "pause"`). `onSelectorRoute()`
  and `M.routeChangeCancelled` updated to match the new route (+ its child); the event-driven
  recovery from 2396 is kept as a defensive safety net regardless, since it costs nothing when
  idle and there's no proof this route can NEVER fail, just that it hasn't yet. Still not
  confirmed fixed live.
  **User confirmed live: "okay it works perfectly now."**
  **Build 2398 - backported to every other freeroam-selector call site.** `raceRunner.lua` (1
  site), `hunterRunner.lua` (2 sites - LOBBY-join steering and COUNTDOWN per-role reselect), and
  `infectedRunner.lua` (1 site) all shared the exact same vulnerable pattern (delete vehicle ->
  `openVehicleSelectorForFreeroam()`) - the user had already reported hitting this same glitch in
  hunter mode specifically. All four switched to `openFromPause("pause.vehicleSelector")`, same as
  busRun.lua. None of these three files had busRun.lua's own re-entrancy guard or recovery hook
  (`onSelectorRoute()`/`M.routeChangeCancelled`) to begin with, and none needed one added: their
  own entry points are already naturally guarded by one-shot state-transition flags
  (`wasInSession`, `wasCountdown`), unlike busRun's drive-up prompt which could re-show and
  re-trigger `M.startLine` while a pick was still pending. Not yet individually retested live
  (race/hunter/infected all still need their own confirmation), but the underlying fix is
  identical to the one just confirmed working for bus lines.
- **"Only the [Wentward-badged school] bus shows" - the user corrected the read on this: after
  the `getConfig()` fix (2385/2386) it flipped to the OPPOSITE failure - citybus stopped showing,
  only the md_series school bus config did (also Wentward-branded, hence the confusion). Real
  cause, build 2388 fix: the fallback in `isBusModelConfig`/`currentIsBus` picked the config's
  WHOLE data table over the model's whenever `getConfig()` found anything at all, instead of
  falling back field-by-field. citybus's own default "city" config entry doesn't carry its own
  `"Body Style"` key (just a livery, inheriting it from the base model), so `resolved["Body
  Style"]` came out nil for it - wrongly excluding citybus, which DOES declare it at the model
  level. Each md_series bus config's own `info_md_*.json` happens to be a full standalone blob
  that repeats `"Body Style"` itself, so those kept passing, masking the bug. Re-read native's own
  "busRoute" filter again and it's a field-level fallback all along -
  `configOrModel['Body Style'] or model['Body Style']` - now matched exactly instead of an
  object-level one.
- **Bus lines only ever showed under the Big Map's "Other" category.** No native vueBigMap
  `data.type` fits "bus line", so that catch-all bucket is unavoidable - but they're now ALSO
  surfaced in their own "Bus Lines" group, via a new `data.customGroupTags` passthrough in
  `bigmap.lua getRawPOIs` + `M.onBigmapBuildGroupData` (defines the `bjBusLines` group) +
  the existing `M.onBigmapBuildCustomGroupStructures` "BeamJoy" section (now lists
  `{"type_garage", "bjBusLines"}`). They'll still also appear under "Other" - vueBigMap's own
  grouping always tags one native bucket first and `customGroupTags` only ever adds to that, never
  replaces it (see the comment on `getRawPOIs` for the full explanation).

### Main window: Activities tab split per gamemode (DONE 2026-09-10, client build 2384)

The Main window's "races" tab (id `races`, titled "Activities" - `beamjoy.window.main.tabs.races.title`)
was races-only ; its own header comment already anticipated more activity types slotting in later.
Split into one sub-tab per gamemode instead of a single growing list:

- `windows/main/activities/app.{js,html}` (new) - `bjMainActivities`, a section-bar wrapper
  (same pattern as Config > Freeroam's Stations & Garages / Bus Lines split) hosting the existing
  `<bj-main-races>` (completely untouched) and a new `<bj-main-bus-lines>` side by side.
  `windows/main/app.js`'s `races` tab entry now templates to `<bj-main-activities>` instead of
  `<bj-main-races>` directly ; tab id/title/order unchanged.
- `windows/main/activities/busLines/app.{js,html}` (new) - `bjMainBusLines`, a third entry point
  for starting a line (alongside the Big Map POI and the drive-up prompt) : browse list (name,
  stop count, loop indicator) with a Start button per line, and a "Currently running: X" banner +
  Stop button when one is active. Reuses existing wire events with zero new Lua data plumbing -
  `BJEditorBusLinesData`/`Request` (already pushed by beamjoy/busLines.lua) for the list,
  `BJBusHud`/`BJBusHudStop` (already pushed/handled by busRun.lua) for run status.
- `busRun.lua` gained one new handler, `onMainStartBusLine` (wire event `BJMainStartBusLine`) -
  resolves a line by id against the live synced list and calls the same `M.startLine` the other
  two entry points use.
- 3 new locale keys (`window.main.tabs.races.sections.{races,busLines}`,
  `buslines.main.currentlyRunning`) across all 13 languages (826 keys each).

### Phase 2 — remaining

- In-game confirmation of the whole loop (start from POI + from prompt, bus filter now
  config-aware, GPS, hold, advance, loop, finish, mid-round auto-stop).
- Possible polish: require the bus to be near-stationary (not just inside the radius) before the
  hold counts; a bundled example line for a map or two; server `BusStopHoldDuration` config key
  (busRun already reads it, defaults 3 - nothing writes it yet).
- git sync + a real release cut (1.10.0 - the whole Phase 2 + the earlier naming work).
