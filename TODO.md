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

- **Phase 3 — deliveries.** Package + vehicle delivery modes, two-point-list editor, minimal
  leaderboard.
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
