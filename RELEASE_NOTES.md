# BeamJoy Sandbox — release notes

- **Version:** 2.1.0
- **Builds:** server **2496**, client **2785**
- **Previous public release:** 2.0.1 (client 2752)

---

## Updating

This release changes **both the server and the client**. Updating only the client leaves the new
race settings, Hunter's station settings and Infected's pre-assignment half-wired.

### Automatic, from in game

BeamJoy checks this project's GitHub for a new version by itself, every 6 hours, and tells the
server's owners in game when it finds one.

1. An owner types **`/bjupdate`** in chat, or **`bj update`** in the server console. `/bjupdate
   check` only looks for a version without installing it.
2. **Restart the BeamMP server** once it reports the install finished.

It replaces `Resources/Server/BeamJoyServer`, `Resources/Server/BeamJoyServerHooks` and
`Resources/Client/BJ.zip`, moving the previous ones to `BeamJoyData/update/backup-...`; if any of
them can't be moved, everything goes back as it was. **`BeamJoyData` — races, players, settings and
leaderboards — is never touched.**

- Players install nothing themselves: their game downloads the server's `BJ.zip` the next time they
  join. They should clear their cache before rejoining, and each needs to **restart BeamNG once**
  for this release's translations, which are read at load.
- Updates come from GitHub releases by default. `bj update channel development` follows the
  development branch instead, and `bj update channel` says which is in use.
- It needs `curl`, built into Windows 10 1803 and later, and on Linux `unzip` and `zip`. A missing
  tool is reported to whoever asked for the update, with how to install it.

### Manual

1. **Server:** replace `Resources/Server/BeamJoyServer` and `Resources/Server/BeamJoyServerHooks`,
   and put the new `BJ.zip` in `Resources/Client`. That is the copy players download in multiplayer,
   so a stale one there leaves the whole server on the old client.
2. **Restart the BeamMP server.**
3. **Singleplayer, or testing a client build:** `BJ.zip` into your own BeamNG mods folder.
4. **Restart BeamNG once.** Translations are read at load, and this release changes the file they
   live in.

### Important Note

Servers that are updating **keep their recorded times** on the East Coast USA Races.
A race an admin edited themselves will be overwritten.

---

## Highlights

- **Race phases.** A race session can be an event of up to 20 phases — practice, qualifying, heats,
  a final — each with its own start, length, ranking, grid and rules.
- **Five new start types:** a five-light gantry with jump-start penalties, releases in waves, one
  racer at a time, flying starts and out laps.
- **Driving your own car works again on BeamNG 0.40.** Dead controls, a hidden driver camera and
  sitting in the passenger seat were all one cause.
- **Translations work again on BeamNG 0.40**, community language packs included, and Italian is a
  new language.
- **Framerate optimizations** in nametags, the race, the vehicle selector, and two stutters that
  recurred on a timer.
- **Drift spots can be driven in either direction**, sharing one leaderboard, as the game's own do.
- **A larger plugin API:** race control and stewarding, plugin-run lobbies and phases, GPS,
  the whitelist and labels on the race HUD. New rallycross plugin with joker lap example.

---

## Races

### Events and phases

- **Phases.** A race session is an event of one or more phases (20 at most). Each has its own start
  (together from the grid, one at a time, or open runs), length (laps, a time limit, or both),
  ranking (race order, best lap, total time), grid (the lobby's, an earlier phase's result or the
  standings, reversed or not), who races it (the top *n* of an earlier phase: knockouts and finals),
  rules and break. The event's result is its last counted phase, or every counted phase added up.
  **A race started the way it always was is one phase and behaves exactly as before.**
- **Formats** in the start menu: race, qualifying + race, practice + qualifying + race, sprint +
  feature (reversed grid), time attack, knockout qualifying + race, two runs added up — all editable
  in the phase editor. A race can carry its own phases as its default.
- **Saved formats.** Save a format of your own from the start menu's Format list (50 at most, kept
  in your own game's settings).
- **Timed races.** Length can be laps, a time limit, or both, with a choice of what happens when the
  time runs out: the leader's lap, everyone's own lap, or stop at once. The HUD counts it down.
- **Between phases.** A break showing that phase's results — a tab per phase and one for the event —
  then a countdown to the next, which the leader can start early. Cars taken away come back.
- **Knockouts.** The finish popup tells you the place you finished in and whether it puts you
  through. The results tab draws a line under the ones advancing: green for through, red for out.
- **Point-to-point tracks.** Practice and qualifying become repeat runs from the first slot, each on
  its own clock, until the runs or the time are up.
- **Race control.** Staff can end a phase (a red flag), add 5 minutes to a timed phase or a lap to
  one on laps, and hand out penalties.

### Starts

- **Lights.** A five-light gantry replaces the counted countdown: one light a second, held lit for a
  moment the server picks fresh every time (0.2–3 s, so it can't be learnt), then out together for
  the green. Your car is released as the first light comes on, so holding it on the brake is your
  job — and moving off early is a jump start, worth a penalty you set in seconds.
- **Waves.** The grid is released a few cars at a time, each wave a set interval after the last,
  every car timed from its own start.
- **One at a time.** Each racer does their whole phase alone before the next is released. The others
  either wait on their slots or, by default, have their cars put away and watch whoever is on track —
  and everyone starts from the first slot, the first racer included, to keep it fair. "You're up
  next" warns the racer whose turn is coming.
- **Time offset.** Every racer starts from the first slot a set interval apart, several on track at
  once, for time trials and hill climbs.
- **Flying starts.** On a point-to-point track, choose whether a racer's time starts as they're
  released or as they cross the first checkpoint. The lap clock waits at 0 for the line.
- **Out lap.** A circuit can give everyone an untimed lap from the grid first, each racer's time
  starting as they cross the line at its end. Its laps and sectors count for nothing.
- **The start lights hang near the top of the screen** instead of sitting in the middle of it, over
  the stretch of track you're about to launch down.

### Race settings

- **A reset speed limit.** A tickbox and a speed: resetting or recovering only works below it, so a
  reset can't be used as an airbrake — press it mid-crash and you keep the crash. A refused reset
  says so on screen rather than the key quietly doing nothing, and every way of asking for one is
  covered, down to the pause menu's own Repair and Flip upright buttons. Off by default, and hidden
  when the race has resets turned off.
- **Reset in place.** A new respawn option: whatever the racer presses, the car is rebuilt and
  repaired where it stands, upright and facing the way it was. A crash costs its time but never
  sends anyone back to a checkpoint.
- **Hide other racers.** Every other racer's car is simply not drawn on your client — not
  translucent, gone — with their nametags, and your own car ghosted so you can't hit what you can't
  see. Cars outside the race are left alone, since traffic is part of the track. Meant as a
  qualifying rule, so quali runs on an empty track and the race that follows doesn't.
- **Players can join mid-race**, per race and per phase. Off by default.
- Settings can be set for a whole race, in a race's own defaults in the editor, in the lobby's
  "Change settings", or as one phase's rule.

### The race browser and editor

- **The race list searches and sorts.** One icon opens a name box that filters as you type, another
  cycles the order between A–Z, Newest and Oldest. Closing the box clears the filter, so a hidden
  one can't make races look missing.
- **Drag start positions into order.** The Start positions list has the same drag handles as the
  gates — the first is pole, so this is the grid order. In the lobby, manual placement still lets
  racers pick their own slot.
- **The start form's Phases button** sits right under the format list.

### Race fixes

- **Joining a race already under way takes you to its lobby**, where the "ready up to start" button
  lives, instead of just closing the menu. The same for a hunt, an infected game or a derby.
- **A late joiner's next gate turns green.** The route now also leads the way while they're still
  waiting to ready up, rather than leaving them a track of plain gates.
- **A race with collisions off ghosts everyone else, not you.** The look is recomputed from the race
  itself, so swapping cars at the grid, rejoining in another one, spectating or another player's
  mid-race reset no longer leaves the wrong car solid.
- **A number typed past a slider's maximum is no longer lost.** A race time of 86400 used to empty
  the box and fall back to three laps; a typed value is brought down to the maximum instead.
- **Older vehicle presets no longer refuse the right car.** When a preset's captured parts don't
  match, its configuration is checked as the game has it today. Stock configurations match too.
- **Saving a race no longer claims the name is taken when it's the same race.** Servers that ended up
  with two copies of each bundled race could save neither; extra copies are now cleaned up once, on
  the next start — only exact duplicates with no recorded times, and the original keeps its id, times,
  settings and props.
- **A rejected race save no longer prints the whole race to the server console.** It logs the reason
  and the race's shape instead of hundreds of lines of coordinates.
- **East Coast USA's races, tidied up.** Eight get their props cleaned up, "Street Stage" has its
  grid moved back onto the road, and "Street Course (reverse)" gets a stray gate and seven missing
  grid slots put back. Recorded times are kept.
- **Bundled races are credited properly** — the 95 credited to a guest account now to BeamNG, and
  four Utah races to yep. No race was renamed.

---

## Hunter and Infected

- **A Hunter's parked car no longer gives the fugitive away.** With the reveal distance at 150 m the
  fugitive kept getting shown while the nearest hunter was 200–500 m off: a player's name is on
  everything they own, so the car they left at the lobby, a trailer, a walking unicycle or any
  traffic they spawned all counted as that hunter standing there. Each hunter's own driven car is
  what's measured now. The same loose lookup could hold the fugitive's reset lock shut and could put
  the wrong one of their vehicles on the minimap, or point a hunter's GPS at a trailer.
- **Hunter can let one side repair at garages and not the other.** "Allow fuel stations & garages"
  is now two settings — who may refuel and who may repair — each of Both, Fugitive only, Hunters
  only or Nobody. Both default to Both, so nothing changes until you narrow one.
- **Pre-assigning an Infected player as infected now actually takes, and says so.** The roster marks
  them ("Starts infected"), clicking again cancels it, and more pre-assignments than the round's
  infected count raise that count to fit — up to the arena's spawns, and never so far that nobody is
  left to survive.
- **Derby, Hunter and Infected start on "GO" like races do.** Their start was a server timer firing
  up to ~2 s after the countdown players saw; they now count down to the same shared clock races use
  and release each car as "GO" shows. Hunter's start-delay countdown also stood still instead of
  counting down.

---

## Drift, drag and derby

- **Drift spots run either way now.** The route's two ends are two lines, the way the game's own
  freeroam spots work: cross either one to start, the other ends the run, and both directions share
  one leaderboard. Spots already saved all read as two-way, and a spot meant to run one way has a
  "Both directions" toggle to turn off. Each gate draws an arrow both ways in the editor.
- **The signs at a drift finish face the way the spot runs.** Signs already placed keep their angle.
- **The game's own drift spots show their UI again.** Since 0.40 the game draws drift and drag
  scores inside two container apps that BeamMP's multiplayer layout doesn't have, so a drift spot ran
  with nowhere to show. They're added to the layout when needed.
- **Turn a whole Derby arena with the Rotate tool.** Pick Rotate with nothing selected and the gizmo
  sits on the arena's middle: turning it rotates every start position with its facing, the zone, and
  every prop, line, curb and painted line. With snapping on, each point keeps its height above the
  ground. An ordinary unsaved edit until you save.

---

## Deliveries

- **Jobs can run without a time limit.** A new switch in Config › General › Deliveries; off, a job
  no longer fails at twice its target time, though a slow delivery still scores less. Jobs already
  running are spared either way.
- **The delivery HUD's buttons aren't squashed** when the HUD is focused — the "B to go back to
  driving" hint takes its own line instead of crushing Hold to abandon into a sliver.

---

## Freeroam and the car you're in

- **Driving your own car works again.** Behind dead controls, a hidden driver camera and sitting
  in the passenger seat was one cause: since 0.40 the game decides what you may do from your
  *presence* in the car, several of its fallbacks land on "passenger", and in a BeamMP session
  there was no way back — the game only recomputes a presence when it changes, and re-entering the
  same car is a no-op. BeamJoy now checks its own player every second and on every switch: a
  passenger in a car of their own goes back to unrestricted, and a passenger seat with the driver's
  seat free is swapped for the driver's. Another player's car is never touched, so riding along
  still works.
- **Nothing fills your car with occupants any more.** Reported for vehicle presets and again for
  spawning traffic, and it was one cause with many triggers: an empty seat's figure is hidden by
  nothing but its transparency, and several parts of the game write a blanket transparency across
  every mesh a car has. Rather than chase each trigger, the figures are checked against what BeamJoy
  last set and put back when they don't match.
- **Another player's car no longer shows a driver after they got out to walk.** The game's seat
  figures are your own game's players only, so the figure in their car was yours, seated by looking
  at it. Other players' cars show no seat figures now.
- **A garage repair leaves the car facing the way it was** instead of spinning it on the spot, and
  sets it upright on its wheels as a garage repair should.
- **Teleporting to a player could quietly teleport you to yourself.** Reported as "admin can't
  teleport to owner", and nothing to do with permissions — teleport isn't rank-gated. A player's car
  was looked up by an id that is the car's number in its *owner's* game, not an identity, so two
  games on the same map routinely share numbers and the lookup could land on your own car. Every
  lookup of that shape now matches the owner too: Teleport To, the Teleport From summon, `/tp`, the
  player list's spectate/focus action and a bus run's mirroring. Teleport also stopped failing in
  silence, and a teleport that couldn't have worked no longer burns a player's cooldown.
- **The activity overlays can be moved to any corner.** Every panel — race, bus, drag, derby,
  hunter, infected, delivery and drift zone — used to hardcode the top-right corner. Settings › Menu
  gains "Activity overlay position": a corner for the whole cluster plus a gap from each edge. It
  applies the moment it's made, with nothing to restart. A plugin's panel keeps whichever corner the
  plugin chose; one that never asked follows yours. Kept on this PC.
- **An error message no longer stays on screen until you restart the game.** Error toasts were sent
  with no timeout and the game's toasts can't be clicked away; they fade after 10 seconds now. That
  was every editor's "couldn't save" message.
- **No more repeating freeze in one particular spot.** Parked cars are kept clear of bus stops two
  ways, and the two disagreed about where a car was — so a bay just outside a stop could pass as
  free, get a car placed just inside it, have it removed, replaced and removed again, once a second,
  forever, each turn costing a spawn and a camera reset.
- **Traffic spawns when you're alone on the server**, and no longer stays off until a restart. A
  car's search for a spot gives up after 3 s instead of holding the traffic lock forever, and every
  5 s each game tops its own share back up.

---

## Performance

- **Nametags cost a fraction of what they did.** They were the mod's biggest per-frame allocator:
  every tag deep-cloned its two colours out of storage, re-asked which camera is active and who you
  are, rebuilt its distance text, and built the spectator list under it through three closures and a
  new table — twice over. Nothing about what a tag says, where it sits or what colour it is changed.
- **The race's own per-frame work costs a fraction of what it did.** Roughly sixteen throwaway
  vectors and tables per frame, your own identity looked up three or four times, and helpers in the
  crossing test that built a fresh closure per gate. Steady state is now no allocation at all, with
  not one rule of the crossing test changed.
- **Opening the vehicle selector no longer hitches.** The selector asks whether you may spawn each
  vehicle once per tile — over fifteen hundred on a stock install, every time the grid is built or
  you type in its search box — and each question re-read your rank from scratch.
- **A small stutter every five seconds is gone.** The game tops its traffic back up every five
  seconds, and the first thing that check did was count every node in the map's road network just to
  find out whether the map had roads.
- **Less work repeated every second of play.** Reading one of BeamJoy's own settings searched the
  whole list of setting names to find where it lived, on every read — and the nametag colours alone
  are read six times a second.

---

## Server and admin

- **The whitelist has a file of its own**: `BeamJoyData/db/whitelist.json`, no longer inside
  `config.json`. Names in the old file are moved on start. Edited by hand while the server runs,
  it's picked up within 5 s and whenever a player connects, and staff's whitelist panel follows. A
  broken file is logged once and the whitelist stays as it was; a deleted one is written again.
  Names match in any case.
- **Fix: `bj whitelist add` only took connected players.** It now adds the name as typed.
- **Fix: guests got in with the whitelist on** — the refusal was built but never returned.
- **Console and chat commands find every player.** A name holding `-`, `(`, `[`, `%`, `+`, `*` or
  `?` was only found in its exact case, since the typed part was read as a pattern. Names now match
  as plain text, in any case, and by a guest's nickname; `bob` picks Bob over Bobby when only one is
  called that. `/votemap` had the same fault with map names. A player also keeps the exact name they
  connected under, which on Windows could be renamed by saved data under another capitalisation.
- **Fix: one player saving a vehicle preset crashed another player's BeamMP launcher.** Every game
  then downloads the new shared builds' photos, and the server sent them at a fixed rate whatever
  the connection could take; BeamMP's server writes to a connection from several threads with no
  lock, so a full connection meant a broken packet and a launcher quit. The server now sends at each
  player's own pace, with no more than 64 KB in flight to one player, and a game that stops
  acknowledging slows down rather than stalls.
- **A game's own big messages are paced too** — a preset carrying its photos can be a megabyte.
- **Fix: every boot warned about the bundled content files.** The bundled mirror emptied its folder
  and copied the same files back in, and BeamMP's hot reload monitor caught them mid-swap. Each file
  is written in place now, and only when its bytes differ.
- **The one-time bundled race sync is only for servers updating from before 2.0.** A server that ran
  2.0.0 already had its sync, and a new server seeds the races as they ship.

---

## Translations

- **BeamJoy reads the game's language again on BeamNG 0.40.** Not the languages — the file name.
  Since 0.40 the game only reads per-language files named `*.translation.json`; ours was
  `beamjoy.json`, so from 0.40 on every window stayed English whatever the game was set to. **One
  game restart is needed**, since translations are read at load.
- **Community language packs are supported too.** A language the game has no translation of its own for comes
  from the Translations mod as one legacy file that the game reads only while no modern translation
  file sits beside it — so BeamJoy's file alone would have taken the whole language down with it.
  The mod's file is now copied beside ours and both are loaded, only ever for the language actually
  in use, and never into a folder that already holds a real translation file.
- **Italian.** Client and server `it_IT.json`, machine-translated and then fixed by hand. BeamNG has
  no Italian of its own, so players see it with an Italian language pack mod.
- A BeamJoy language the game doesn't have is a debug line in the log now, not a warning.

---

## Plugin API

See `BeamJoyServer/api/README.md` for the full reference.

- **Racer keys.** Every racer and result carries a `racerKey` that is theirs for the whole event —
  away, back under a new player ID, every phase — so points, resets and penalties a plugin keeps
  survive a disconnect.
- **Race control and stewarding.** `race.penalize`, `race.clearPenalties`, `race.disqualify`,
  `race.reinstate` while a phase runs, shown on the HUD at once, with the plugin's reason given to
  the racer. Staff and plugin actions both send a `RaceControl` event.
- **A plugin's own lobbies.** `race.open` (with the start menu's options, an entry list, and a held
  start), `race.startNow`, `race.close`.
- **Phases.** `race.setPhases`, `race.endPhase` / `extendPhase` / `nextPhase`, formats of a plugin's
  own, phases a plugin starts and scores itself, the `phaseResult` and `gridOrder` hooks, and race
  options with a value per phase.
- **Finer events.** `RacerGate` (lap time so far, delta to their best, sectors, place),
  `RacerReset`, `RacePositionsChanged`, `RacePhaseFinished`, `RacerStarted`, `RacerJoinedPhase`,
  `RacerJumpStart`.
- **`raceJoin` hook.** A plugin may refuse a player joining a lobby or a running event, with a
  reason they see.
- **`hud.message`** to one player, or to a race's racers and/or spectators, or one racer of it.
- **`gps.set`.** Put the game's own route on a player's screen, or clear it, targeted like
  `hud.message`.
- **Labels on the race HUD.** A plugin's field marked `hud` shows beside the racer's name on
  BeamJoy's race HUD — every standings row, your own, and the cars either side. Two per racer.
  Players can turn them off.
- **The chequered flag and penalty tags in custom overlays**, so a plugin's own standings table can
  look like the race HUD's.
- **Whitelist.** `whitelist.get`, `whitelist.add` / `remove`, `whitelist.setEnabled`, and a
  `WhitelistChanged` event.
- **Fix: a plugin's points stopped when a racer left.** `phase.setScores` refused the whole call when
  one player ID in it was no longer in the race, so nobody's points updated after a racer left
  between heats.
- **New example plugins:** `BJRaceDirector` (a lobby every half hour, penalties for resets past the
  free ones), `BJRallycross` (heats for points, a final, and joker laps enforced from the API),
  `BJShootout` (a plugin-run, plugin-scored phase and the 107% rule), `BJHudLabels`.

---

## Work in progress — not part of this release

Both are in the branch and carry no version bump of their own. They are listed here so the omission
is deliberate and visible, not because they are ready.

- **Pits for circuit races.** A pit lane drawn in the race editor with PIT IN and PIT OUT lines, a
  speed limit and a pit box per start slot; the start/finish line carrying on across the lane; a pit
  menu from the race HUD for fuel and repairs, with the repair's time taken from the car's damage;
  required stops, tow to pits, pit entry penalties; and a plugin API for all of it. A race without a
  pit lane runs exactly as before.
- **Experimental tyre changes in the pits**, off by default: a Tyres row in the pit menu, new tyres
  that keep the car's damage and a repair that keeps the old tyres, the damage synced to other
  players as a compact plan, and a plugin API for tyre sets.
  - *Known issue:* in one test run of three, a tyre change counted about 60 more broken beams than
    the car had (5.4% damage read as 10.2%). Under watch while it's experimental.

---

## Notes

- Several entries above are **server-side** and need the server deployed and restarted, not just the
  client: the race settings' storage, Hunter's per-role station settings, Infected's pre-assignment,
  the whitelist file, the bundled race and course fixes, and every plugin API addition.
- A race, hunt, infected game or derby already running when the server restarts does not survive it.
