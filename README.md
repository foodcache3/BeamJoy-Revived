# BeamJoy-Revived
<p align="center">
  <img src="./assets/cover.jpg" style="width: 49%; height: auto;" />
</p>
  
<p align="center">
This mod is a more refined version of the vanilla BeamMP (sandbox) experience. It allows for moderation and server administration in sandbox mode.<br/>
Since this mod provides a sandbox experience, it should be compatible with all of your previously installed mods (with minor exceptions).
</p>

<p align="center">
⚠️ This mod is not compatible with any other BeamJoy version. ⚠️<br/>
⚠️ Please ensure you removed any other version before running this mod. ⚠️
</p>

## Community

<p align="center">
  <a target="_blank" href="https://discord.gg/TMsegWBY74">
    <img src="https://img.shields.io/badge/Discord-Join%20the%20server-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Join our Discord" />
  </a>
</p>

<p align="center">
Come say hi for troubleshooting help, to suggest features, or for sneak peeks at what's coming next.
</p>

## How to install

Just like the free version, you can download the latest release [HERE](https://github.com/foodcache3/BeamJoy-Revived/releases/latest) and extract it inside your server's `Resources` folder.<br/>
Updates never replace server or player data.

Once installed, the server keeps itself up to date: it checks GitHub for new releases, tells
owners in game, and installs one with `/bjupdate` (`/bjupdate channel development` follows test
builds instead).

## Importing from BeamJoy Free

If you're moving from an old BeamJoy Free (BJI) server, you don't have to rebuild your Hunter
arenas, races or delivery points by hand: Legacy Import converts them over automatically.

1. On your old BeamJoy Free server, find its data folder's own `scenarii` subfolder (inside its
   `BeamJoyData/db/` folder).
2. Copy that whole `scenarii` folder into **this** server's own `BeamJoyData/db/` folder, so you
   end up with `BeamJoyData/db/scenarii/<map>_hunter.json` and/or `<map>_races.json` files.
3. Restart this server (or make sure it's picked up the new files).
4. In-game, open Config → Core, scroll to the **Legacy Import** section, and click the button for
   whichever you want to import (Hunter arenas, races, delivery points). A preview lists every map found, with
   counts and any conflicts, before anything is actually imported. Nothing happens until you
   confirm it. The section's own ⓘ button repeats these steps in-game.

Hunter arenas import **one per map** and will **overwrite** this fork's existing arena for any map
that already has one (the preview flags this). Races are different: every convertible race is
added as a **brand-new** race, never overwriting anything already in your list. A race whose name
is already used is skipped instead, so importing is always safe to re-run.

## About this fork

This is an actively developed, upgraded version of BeamJoy Sandbox, updated to run on
BeamNG.drive 0.40 and BeamMP 4.23.1. On top of the sandbox/moderation feature set below, it's
building toward a set of racing- and gameplay-focused features.

**New in 2.0**: deliveries and convoys, Derby, crews, a redesigned main window with controller
support, a props editor for races and arenas, passive races, drift spots and dragstrips, police
chases between players, Discord webhooks, a plugin API and a self-updating server. See the
[2.0.0 release notes](https://github.com/foodcache3/BeamJoy-Revived/releases/tag/v2.0.0) for
everything that changed.

## Features

- **Main window**: a rail on the right edge of the screen opens small panels (Now, Activities,
  Players, Crew, Settings, ...), or the fullscreen window with Home, Activities, Players, Leaderboards
  and Settings. Invites and new lobbies show up as cards beside the rail with Join and Dismiss.
  Everything is HTML (faster than the free version's IMGUI), resizable and movable, and 100% compatible with
  a gamepad: the **Focus** control (RB + X) allows you to interact with the UI with a controller.
- **Deliveries and convoys**: delivery points with depots and drop-offs (import the map's own
  delivery locations, or use the ones bundled for nine maps). Pick package or vehicle jobs from a
  depot's job board, scored on route distance, time and the vehicle's condition, or take a job
  together as a convoy of up to 4 players. A Jobs window lists every depot's open jobs, with
  package and vehicle delivery leaderboards
- **Derby**: Last man standing, Timed and Sumo (the arena shrinks) on the map's derby arenas, with
  wreck credit, a kill feed, results and a Derby leaderboard. Several arenas per map, each with its
  own start positions, zone and default settings
- **Crews**: groups of up to 8 players. When the leader opens a race, hunt, infected game, derby or
  convoy, every free crewmate joins automatically
- **Passive races, drift spots and dragstrips**: passive races start when you drive through the
  start gate in freeroam, no lobby needed. Drift spots have a painted corridor and drift signs;
  dragstrips have a choice of 1/4 mile, 1/8 mile or 1000 ft, a sportsman or pro tree, live times
  and a timeslip. All of them have leaderboards (the game's own drift spots and drag strips
  included) and pins on the Big Map
- **Racing**: full grid-based racing (solo hotlapping and head-to-head), with join/ready/leave/
  cancel/retire, gate-crossing detection, lap and sector timing, a live leaderboard, DNF handling,
  and configurable respawn strategies. Includes an in-world 3D gate/start editor (translate/rotate
  gizmos, edge-resize handles, a switchable terrain/raycast ground-snap, and a reverse-race
  button), manual sector boundaries, ghost backmarkers, a disable-collisions option, configurable
  phase timers, and a live race-info panel (standings while racing, results and lap breakdown
  after)
  - **Props editor**: place props with the mouse in races and in Hunter, Infected and Derby arenas.
    Hundreds of curated props (barriers, cushions, guardrails, signs, lights, rocks, prefabs) plus
    every mesh in the game, lines that curve through any number of nodes, curbs and walls, road
    paint and skid marks, copy and paste between races. Up to 1000 props per race
  - **316 bundled races on 14 maps**, most dressed with props, ready on a fresh install. **Import
    map races** brings in the map's own time trials and quick races, modded maps included
  - **Rejoin after a disconnect** (back at your last checkpoint, in your exact car), a shared
    green light, **race control** for staff (time penalties, disqualify), three HUD layouts built
    for full grids, and gates on the minimap
  - **Persistent leaderboards**: per-race personal-best/record tracking (top 100, with your own
    rank pinned separately if you're outside it), a new-PB/new-record popup on finish, and a
    Leaderboards tab with Races, Deliveries, Derby, Drift and Drag boards
  - **Vehicle restrictions**: optionally lock a race to one exact vehicle (Single Config,
    force-spawned for every participant, custom setups included) or a host-curated pool of
    allowed vehicles to pick from, either baked into the race itself or chosen fresh each time
    it's started
- **Hunter**: asymmetric hide-and-seek chase mode, one random player becomes the hunted
  fugitive, everyone else hunts. Stuck-timer elimination (no direct collision "tag"), a
  three-trigger reveal system (proximity, final-waypoint tension, post-crash), asymmetric grid
  release (fugitive gets a head start), native GPS routing plus an in-world beacon guiding the
  fugitive to their next waypoint, a hunter crash-reset penalty, and a staff force-fugitive
  reassignment tool. Includes its own in-world arena editor (hunter/prey spawns, waypoints)
- **Infected**: one or more players start infected (count configurable), everyone else is a
  survivor. Infection spreads by direct vehicle contact, not a "tag" button, so a stray bump can
  turn the round. The original infected get a short freeze after the round starts (a head start
  for survivors); a round timer means survivors can also win outright by outlasting the clock.
  Role-based nametag colors (green survivor / red infected by default, both host-configurable),
  with an option to hide infected nametags entirely so the color itself doesn't give them away.
  Shares its in-world arena editor (spawns) with Hunter's own pattern
- **Vehicle presets**: admin-curated, shareable vehicle lists (captured model/config/parts/tuning)
  usable to restrict a race, Hunter or Infected session to one exact vehicle or a host-picked
  pool, with matching that tolerates post-spawn paint and tuning changes. **Shared builds**: add
  the car you're driving, custom setup included, and every player can pick it in their vehicle
  selector
- **Police chases between players**: from your own police car, chase players who break the law
  near you, using the game's police rules (players can opt out). Players in a race, hunt,
  infected game or derby can be ghosted from freeroam players
- **Discord webhooks**: post race results and records, hunter, infected and derby results,
  deliveries, votes, joins and leaves, and chat to your Discord channels, no extra plugin needed
- **Plugin API**: your own BeamMP server plugins can read BeamJoy's data, hear about race events
  as they happen, take part in races, show overlays, set the time and weather, and add options
  and pages to BeamJoy's windows. See the [plugin API documentation](BeamJoyServer/api/README.md)
- **Self-updater**: the server checks GitHub for new releases and installs them with `/bjupdate`
  or `bj update` in the server console
- **Legacy import**: convert an old BeamJoy Free (BJI) server's Hunter arenas, races and delivery
  points straight into this fork's own format, see the section above for the full walkthrough
- **Freeroam energy stations and garages**: server-owner-placed refuel/repair points, synced per
  map and registered as real BeamNG POIs, so the game's own marker system, drive-up prompt, and
  Big Map both show them exactly like the map's own vanilla gas stations (which now behave the
  same way, not just BJS-placed ones). Refuelling respects each vehicle's own tuned starting fuel
  amount instead of always topping to max, and a station's fuel type is configurable (gasoline/
  diesel/kerosine/n2o by default, electric opt-in); a vehicle with no compatible tank is rejected
  immediately instead of running the hold for nothing. Both refuel and repair take a configurable
  duration with the vehicle held on the external camera. Includes an in-world editor (place, name
  and resize via gizmo), a low-fuel HUD warning with a "set GPS to nearest station" button, and a
  free, cooldown-gated "emergency refuel" for when you're stranded. Disabled during Race/Hunter/
  Infected rounds unless the arena opts in
- **Bus lines**: drive a server-defined route stop-to-stop with native GPS guidance, holding
  briefly inside each stop's radius to advance; loops automatically if the line is configured to.
  Works with any vehicle the game itself classifies as a bus. Two ways in: a Big Map pin per line,
  or a drive-up "Start line" prompt at the first stop. Includes an in-world line editor and an
  optional strict-stops mode
- **Map voting** (`/votemap`) and **vote-kick** (`/votekick`), both with configurable thresholds
  and timeouts and a live status panel
- **Teleportation**: self-teleport to another player (rate-limited) and a moderator-relayed
  "summon", plus `/tp`/`/tpfrom` chat command equivalents
- **Server-distributed traffic**:
  - Allowed players can toggle it with menus, keybinds and radial menu
  - Customizable (max traffic vehicle, max vehicles per player, vehicles models)
  - Automatic lights with day & night cycle
  - Pursuits and arrests (random events when driving a police vehicle)
- Group system with permissions and configuration UI
- Players moderation tools (mute/kick/ban/temporary ban/remove vehicle(s)/...)
- Players database UI to manage offline players
- Built-in mods analyzer and modded maps detector
- In-game map switch with permission:
  - UI to edit maps labels
  - Each map can be toggled on or off to allow or prevent switching to it
- Customizable yet powerful welcome window
- Support for replay mode (players watching replays and their vehicles are not visible by others until they play again)
- Fixed and fully integrated vehicle selector (hide presets from disabled mods, filtered by permissions, fixed action buttons)
- Messages and labels internationalization (English source plus 12 client and 7 server
  translations, all kept at full key parity)
- Disabled multiplayer-conflicting features (desynced pause, force field)
- LocalStorage to keep personal data and settings between servers
- Contextual menu when right-clicking another vehicle (disabled while nodegrabbing or dragging view)
- Fast vehicle switch with a middle-click (mouse-wheel)
- Custom nametags system:
  - Different and customizable colors for active vehicles, idle vehicles and spectators (shared accross all beamjoy servers and versions)
  - Disabled for props
  - Disabled for trailers when the owner's vehicle is attached to it
- Server commands (`help` or `bj help` for the complete list), including racing (`/race
  ready|leave|cancel|retire`), moderation (`/kick`, `/mute`, `/ban`, `/tempban`, `/setgroup`,
  `/freeze`, ...), and utility (`/map`, `/tp`, `/tpfrom`) chat commands. `/help` only lists what
  the caller actually has permission for
- Whitelist with an UI configuration panel
- HUD UI App (icons + broadcast with colors)
- Safe zones (zones without collisions):
  - When a vehicle is exiting a safe zone, it stays a ghost until not colliding with another vehicle anymore (prevents vehicles merging)
- Configurable respawn-ghost protection (timeout and buffer distance vehicles must clear before
  un-ghosting after spawning/resetting near others), with a global collisions mode
  (forced/disabled/respawn-protection-only)
- Synced pause and simulation speed:
  - Editable by staff members
  - Is triggered by game bindings (default : `J`=pause, `Alt`+`Up`/`Down`=toggle, `Alt`+`Left`/`Right`=presets swap)
  - Simulation speed will fallback to default (x1) if all staff members leave
- Time of day and gravity synced:
  - Can be toggle on/off
  - Editable by staff members
  - Can be edited via UI, menus and radial menu
  - Gravity will resets to default (Earth) if all staff members leave
  - Customizable day/night cycle duration
  - Configurable night speed (0.1x to 10x), with a live readout of the resulting full cycle length
  - Night follows each map's real sunset and sunrise, and the calendar date is synced too
  - Weather sync: everyone sees the same clouds, fog, wind and temperature
- Trailers and Props spawning permissions
- Vehicle models blacklist
- Toggle allowing players mods:
  - Those mods are client-side only, similar to vanilla BeamMP
  - With advanced mods features, now players:
    -  can activate a single mod (if the server configurations allows it) instead of enabling all their collection.
    -  can download a mod and it will be disabled automatically if the server doesn't allow it.
    -  cannot disable nor remove server served mods.
    -  can disable a specific mod (not a server served one) and it will impact their own vehicles (if the mod was a vehicle one).
- Server core settings UI
- Custom chat (show staff tag, with colors)
- Chat commands (permissionned, easy-to-add system):
  - `/help` : Shows the complete list of available commands
  - `/pm <player_name> <message>` : Sends a private message to someone (a copy is also send to staff members for safety purposes)
- DiscordHook mod chat events integration
- Toggleable chat broadcasts:
  - Configurable delay between messages
  - Messages can be translated

## Planned features

Long-term roadmap: not scoped to any particular release, and not yet implemented. This section
will move into Features as things ship.

**Racing**
- Pit road / pit paddock options
- Reset/teleport to pits option
- Repair / refuel in pits, with configurable times for each
- Per-race environment customization (time and weather planner)

**Drag Racing**
- Half / full mile options
- Heads-up / bracket racing

**Gameplay**
- Trailer delivery
- Rideshare / taxi

## Support Samael

<p align="center">
  <a target="_blank" href="https://coff.ee/tontonsamael" alt="Buy me a coffee">
    <img src="https://github.com/my-name-is-samael/BeamJoy/blob/main/assets/buymeacoffee.png?raw=" width="250" alt="Buy me a coffee" />
  </a>
</p>

---

## AI disclosure

Significant portions of this fork (new features, bug fixes, and refactors) were written with
the assistance of AI coding tools (Claude Code). AI-assisted changes were reviewed and tested
in-game before being committed, but this project does not carry the same guarantees as fully
hand-audited code. If you find a bug, inconsistency, or something that looks like it was made
without enough scrutiny, please open an issue or let me know in the Discord.
