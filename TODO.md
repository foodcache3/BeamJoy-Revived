# TODO / planned features

Ideas that have been discussed and design-approved but deliberately not started yet, or genuine
open follow-ups flagged during other work. Not a backlog of every idea ever mentioned, just things
worth picking up later without re-deriving the design/investigation from scratch. Completed work
belongs in CHANGELOG.md, not here.

## To try in game

Built (see CHANGELOG), not yet tried live. Newest first.

- plugin API security fixes (2726 / 2471) : a guest's nickname matching an account's name (or a
  connected player's) is refused as taken ; a plugin's config tab still saves and its callback
  still gets its secrets ; a plugin text with `{{1+1}}` shows as typed, not "2" ;

- sidebar at the join (2725) : join (and rejoin) West Coast without spawning : the sidebar shows
  as soon as the loading ends, in its place ; the HUD text in its place ; a guest's nickname
  prompt still comes first ; F4 still hides / shows it when the host's ForceHud is off ;
- paint lines (2722) : fresh game, West Coast, the prop editor's Paint tab : pick chevrons (then
  checkered, white, rubber, hazard, spray...) without placing any first : back over the world, the
  ghost shows at once where you were looking (a third of a second late only further away), then
  follows the mouse ; a long drag into new ground never blanks ; far away (another town) the same ;
  a race with paint lines joined as a player shows them ; a map without a terrain (Mondello) as before ;
- skid marks (2724) : Paint tab > Tyre marks, on West Coast and another map : Skid marks, Skid
  marks light, Tyre line one tyre, Tyre lines one car : each shows (dark streaks, not a blank or
  a white line), follows the mouse, fades at its ends, keeps its look made wider ;
- props drawer (2723) : open the race editor's props : the drawer at the screen's left edge, its
  full border, the preview beside it ; config window moved to the far left : beside it instead ;
  moved by its header then "put it back" (and double-click) : back to the left edge ;
- controls bar (2723) : props section, none armed : nothing selected, a prop, several, a group's,
  a line / curb / paint alone with an end then a point held, the gizmo on rotate : each shows its
  own actions ; arming a prop brings the placing bar back ; no props placed : no bar ;
- prop picker previews (2718) : scroll the full mesh list (other maps' meshes too) on a fresh
  0.40 shader cache : no freeze, the previews still come (none empty, none half-drawn) ; scroll
  away mid-way : no stutter ; by night none is made ; VRAM steady ; the log's "N thumbnails : ..."
  line gives each batch's longest frame (expected well under 100 ms) ;
- passive race settings (2718 / 2719) : Settings > Passive races : take part off, a nearby start
  gate goes at once, driving through it starts nothing, a run going on ends (no toast) ; back on,
  the gates come back ; kept after a restart and on another server ; a passive run shows no beam
  at all (the minimap shows the next gate), a grid race of the same race still has its beams ;
- lamps (2717) : at night, from the prop picker's meshes, each lamp lights where its bulb is and
  its bulb glows (lamp posts, sidewalk and hanging lamps, wall lantern, the three floodlights,
  Italy's airport and port masts) ; dark by day ; on West Coast too ; Curated > Scenery lists the
  eight ; Prefabs > Scenery the five bracketed floodlights stand right, lit at night, moved /
  turned / deleted as one ;
- temperature (2717 / 2470) : weather sync on, an admin moves the panel's average / daily low /
  daily high : another player's panel and car (tyre / engine temperatures) follow ; a player
  moving it goes back to the synced one ; the admin's reset puts everyone on the map's own ; a
  player joining later gets it ; a map change starts on the new map's own ;
- 0.40 (2716) : the welcome panel opens with its title, image and text, COPY works, Continue (and
  a controller) closes it ; a bus stop display's text in its usual font ; a door / the horn on
  another player's car ; a seat box on another player's stopped car (the owner keeps driving) ;
  walk, then pick a car in the selector (no unicycle left, no error) ; Disconnect (no "could not
  reload extension" in the log) ; a blocked replay shows as not loaded in the replay browser ;
- drift spots (2715 / 2469) : no name over a spot ; "drift spots" and "dragstrips" everywhere ;
  the handles at each end of a point's line drag its width (Ctrl both sides), saved and seen by
  others ; a run leaves the spot where it's narrow ; the slider sets them all ;
- join loading (2713 / 2468) : the sidebar and the weather within a second or two of the UI
  reload on West Coast ; a race's props show for its racers and spectators (a race joined just
  after the join too), in the editor, after the race is saved again, and shared / exported with a
  race code ; the race list still shows each race's prop count ;
- date at midnight (2713 / 2468) : with time sync on and a short day, the moon doesn't jump at
  midnight and the panel's date goes on a day (on every client, and after a rejoin) ; month and
  year ends ; with time sync off, the same on the engine's own clock ;
- paint looks (2708, 2711) : yellow and black stripes look like the drawer's, chevrons are V's,
  Track rubber is one wide dark band (on another map too), the rubber and dirt marks fade at their
  ends ;
- drag (2709) : after a run, the Focus control lights Open timeslip, A opens it, B lets go ; in the
  timeslip left / right / A work and B closes it, and the pad drives again once it's closed ;
- shared builds (2703 to 2707 / 2466) : a custom car added, named, saved : its tile in another
  player's selector (name, author, photo, paint), spawns right, shown right to others ; the same
  in a race pool, derby and hunter, with "Show in the selector" off too ; leaving the server
  removes the files (a killed game's go on the next join) ; a repo mod's part refused with its
  name, the server's own mods' parts accepted ; "Retake photo", the game's UI only blinking while
  it's taken, a ghosted car solid in the photo ;
- plugin API (server 2460 to 2465, client 2700 to 2702) : BeamMP's cross-plugin events and
  `dofile` on a real server ; the example plugins (`api/example/BJRaceControl`, `BJClasses`) ;
  overlays' look and the race HUD hiding ; plugin options in the start menu, editor and config
  window (the editor not marking a race edited on open) ; field tags in results and leaderboards ;
  plugin pages on the rail (height, label cut), panel and tab, buttons, the controller on a page ;
- curbs, walls and painted lines (2680 / 2681) : a curb or wall only solid once placed (not the
  editor's preview) ; stripes' colours and the concrete's look ; the rumble ground model on curbs ;
  paint drawn over the map's own lines and asphalt, and over mesh roads ;
- deliveries (client 2497 to 2509) : a package run end to end, the gamepad not driving the car
  while a window is open, the server's position check ; vehicle jobs' spawn facing, part
  conditions read in MP freeroam, garages refusing during the job ; a convoy with two clients end
  to end, cohesion getting positions, the interact chord while driving, Unstuck's landing spot.

## Join loading: the pacing (fix 3)

Fixes 1 and 2 are built (2713). Left : the paced sender (`communications/tx.lua`) sends half what
it meant to. SEND_BUDGET is 40000 bytes per tick, but a 20 KB part grows to about 23 KB once
wrapped and escaped (`{id, part, data}` as JSON), so only one part fits per tick : about 230 KB/s,
not the 400 KB/s its comment says. A budget that fits two wrapped parts gives about 460 KB/s. The
pacing is the guard against the BeamMP launcher's "zlib uncompress() failed" crash on big bursts
(27 packets at once), so test it with a few players joining at once.

## Weather sync: follow-ups

- **Rain.** The game's panel has no rain control, so `numOfDrops` (core_environment's
  `setPrecipitation`) isn't synced. Would need a BJS control (config panel slider). Only maps with
  a `Precipitation` object can rain: West Coast USA, East Coast USA, Italy, Jungle Rock Island,
  Small Island, Industrial, Driver Training (not Utah, Johnson Valley, Gridmap...).
- **Automatic weather** (the server shifting between weather states on a timer, lerped on every
  client). The user chose static weather for now. The game's own weather presets
  (`art/weather/defaults.json`) also set the time of day, so a dynamic mode would send the weather
  fields only, never preset names.

## Freeroam: police chases between players: follow-ups

- A GPS route to the nearest fugitive for the police player (old BeamJoy had one).
- A police / fugitive leaderboard (the counts are already saved in `player.data.pursuit`).

## Freeroam: passive zones: follow-ups

- Drift zones : no score targets (bronze / silver / gold) on ours. The game's own drift messages
  ("Nice drift!") may show during a zone : they're its freeroam ones.
- Drag strips : no dial-in (bracket racing) on ours. Results are trusted from the player's game,
  as for the game's own strips (no server-side check of the car's position at the marks).
- Passive races : a race's props don't show during its freeroam runs (they'd appear out of
  nowhere as you start, and be in everyone else's way) : to decide. No Big Map pin of their own : a
  freeroam race shows through its grid start's pin.
- Props for the passive zones (a drag strip's tree, a drift zone's signs) : the props framework
  can carry them, not built.

## Races: props: your own prefabs

Direct request, 2026-10-09 : "add the prefab saving to the todo". Multi-select, groups and copy /
paste are built ; this is the part left.

- **Save as prefab** : the selection stored relative to an anchor (its middle and a facing), every
  prop as it is : lines stay lines (count, curve, alternate mesh, lift, follow ground), single
  props keep their turn, scale and stretch. Named by the player.
- **Placing one** : the drawer's Prefabs tab lists the built-in ones and "Mine" (rename, delete) ;
  picking one arms it like a mesh, its whole ghost follows the cursor, the wheel turns it, a click
  places it. Placed as one prop made of several meshes (the same entry kind the built-in prefabs
  use), so it selects, moves and deletes as one ; "Split" makes it separate props again. Every
  mesh counts toward the race's 500.
- **Where they're kept** : per player on their own PC by default (simplest, client only) ; a
  shared library on the server (every editor sees the same ones) would need server storage, a
  permission for adding / deleting, and syncing. Ask which before building.

## Races: curbs and walls: follow-ups

A profile's side (a kerb sloped toward the track only), tilting with the ground across the path
(it's sunk 0.4 m instead), a tyre-wall profile, eyedropping a whole sweep.

## Vehicle presets: shared builds: if wanted

Players submitting builds for staff to approve (a separate permission), "Save this car" on another
player's car, and the server making a preset pack zip from favourite builds (sent by BeamMP like
any mod, so players keep them after leaving).

## Main window: follow-ups

- A on the race start form opens the lobby directly (today A presses the focused element) ; text
  inputs need a keyboard.
- Known debt : the hosted old components register `$rootScope.$on` listeners without cleanup, and
  panels mount / unmount them often ; fix as each is restyled.

## Deliveries: follow-ups

- **Parking spots as a drop-off option** : per point, a zone or 1-4 parking spots, using the
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
- BJI (UX/process shape reference only, not the marker layer):
  `X:\beam\essentials\beamjoy-2.0.8` -> `Client/BJI.zip` -> `StationsManager.lua`,
  `ui/windows/ScenarioEditor/{Stations,Garages,BusLines}.lua`.

## Plugin API: next steps

The API itself is built (steps 1 to 4, see CHANGELOG and `BeamJoyServer/api/README`).

**Order :** the user's website sync plugin → the website's read endpoint → a Discord bot on that
endpoint. Each step works on its own.

**The user's sync plugin (`BJLeaderboardSync`, a separate plugin).** On start, every map's and
race's board uploaded in full (catching up on anything missed while it was down) ; on
`leaderboardChanged`, that race's board. Keeps `"beammp"` and `"nickname"` entries only. Sends with
`curl` (no HTTP in BeamMP's Lua ; `services/discord.lua` does the same) and a secret token from
its own `config.json`. **Open question :** what the website is. A backend that can take uploads
(POST with the token), or a static site on the same machine (the plugin writes a JSON file it
serves).

**Discord bot.** BeamJoy already posts to Discord without a bot (webhooks in
`services/discord.lua`, and `onScriptMessage` for the ChatHook plugin). A real bot (slash
commands : `/leaderboard`, `/online`, `/weather`) is its own program (discord.js / discord.py) :
a bot needs a permanent connection to Discord, which BeamMP's Lua can't hold. It reads BeamJoy
data through a bridge, preferably **the website's own read endpoint** (one pipeline for both, and
it keeps working while the game server restarts) ; or snapshot JSON files a bridge plugin writes,
when the bot runs on the server's machine and there's no website. Bot commands acting on the
server (weather from Discord...) are writes : out of scope for now.

**Worth adding to the API (suggested, not asked for yet) :**
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
- Buttons on overlays (a click comes back to the plugin as an event).
- Leaderboard views by a field (only the GT entries, say) in the game's leaderboard window.
- Who may write : an allowlist in BeamJoy's config of the plugins allowed to use the hooks and
  write methods (today any plugin on the server can ; plugins are the server owner's own).

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

## Hauling: trailer delivery and tow trucks (future version)

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
