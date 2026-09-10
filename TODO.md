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

**Status (2026-09-10, client build 2377 / server 1.9.1, local BJ.zip only - not git):**
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
- All 13 client locales (en-US + 12 translated) - DONE (build 2377)

**Remaining:**
- Confirm the editor in-game (save round-trip, gizmo, radius, live-marker suppression)
- Per-station fuel-type override (electric chargers etc.) - deferred, needs a `pointListEditor`
  per-item-metadata extension. Empty types = gasoline/diesel/kerosine/n2o for now.
- Repair currently always offered + tops off fuel on completion - refine to "only if damaged" +
  preserve fuel once the right vehicle field is confirmed
- git sync (nothing since v1.9.0 is committed) + cut release
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

### Later phases (not started, no plan yet)

- Phase 2 — bus lines (`busMissionRunner.lua`, ordered stop-list editor, ACTIVITIES POI).
- Phase 3 — deliveries (package + vehicle modes, two-point-list editor, minimal leaderboard).
- Phase 4 — derby (full 4th competitive gamemode: `services/derby.lua` + `services/derbyGrid.lua`
  + `derbyRunner.lua` + HUD/countdown/results, arena browse-list editor). Bigger than 1-3
  combined.
- Phase 5 — polish: quick-travel + GPS-to-nearest wiring, per-type legacy BJI import.
