# BeamJoy plugin API

Lets your own BeamMP server plugins work with BeamJoy:

- **Read** its data: races, leaderboards, maps, online players, races being run, time and weather.
- **Hear** about events as they happen: a new best time, a lobby opening, the countdown and the
  green light (with server times), every gate and lap, overtakes, resets, racers finishing or
  retiring, a finished race with every lap and sector, a map change, time and weather changes.
- **Take part** in races: refuse a player's joining or ready-up with a reason they see, set the
  order cars start in, take a racer back to not ready.
- **Run** races: open lobbies of your own (scheduled events, league nights, an entry list), start
  or close them, and steward them while they run (time penalties, disqualifications).
- **Build a discipline**: races run as events in [phases](#phases) (practice, qualifying, heats, a
  final, runs, timed races). Your plugin can add formats of its own to the start menu, choose who
  races each phase and in what order, start racers itself, rank them by its own scores, judge a
  phase's result, and end, extend or skip ahead.
- **Show** players an activity overlay where the race HUD goes, in BeamJoy's own look or laid out
  your way, and a line of text across BeamJoy's HUD.
- **Set** the time and weather.
- **Add to BeamJoy's windows**: sections of options in the race start menu and the race editor
  (a race class, league rules), labels on results, leaderboard entries and the race HUD (the
  class, points, a team, a tyre), a tab of your plugin's settings in the config window, and pages of your own in the main
  window (a button on its side rail, a tab in the full window) with buttons and fields players
  use.

Typical uses: a website kept in sync with the leaderboards, a Discord bot, live timing, a
championship or league plugin, race classes, an entry list, a game mode of your own.

API version 1. Plugins can label leaderboard entries and results, give time penalties and
disqualify racers (during a phase, or judging its result : the `phaseResult` hook), but never
change a lap time.

## How it works

Every folder in `Resources/Server` is a separate plugin with its own Lua state. Plugins can't see
each other's variables or call each other's functions; they can only exchange events
(`MP.TriggerGlobalEvent` / `MP.RegisterEvent`). BeamJoy's API is a set of those events, carrying
JSON:

| Direction | Event | Payload |
|---|---|---|
| your plugin → BeamJoy | `BJAPI_Request` | `{"id": "...", "from": "YourPlugin", "method": "races.list", "params": {...}}` |
| BeamJoy → every plugin | `BJAPI_Response` | `{"v": 1, "id": "...", "to": "YourPlugin", "ok": true, "result": {...}}`<br>or `"ok": false, "error": {"code": "...", "message": "..."}` |
| BeamJoy → every plugin | `BJAPI_<Event>` | `{"v": 1, "event": "<Event>", "instance": "...", "data": {...}}` |
| BeamJoy → every plugin | `BJAPI_Hook` | a question (see [Hooks](#hooks)) ; the plugins asked answer with `hooks.answer` |

You don't need to deal with any of that yourself. **`BeamJoyAPI.lua`** (in this folder) does it for
you: it matches answers to calls, waits for BeamJoy if your plugin starts first, and times out
calls that get no answer.

This folder ships with BeamJoy, at `Resources/Server/BeamJoyServer/api/`. BeamMP only runs the
`.lua` files at the top of a plugin's folder, so nothing in here runs by itself. A BeamJoy update
replaces this whole folder: don't keep your own files in it.

## Quick start

```
Resources/Server/
  BeamJoyServer/
    api/BeamJoyAPI.lua      the helper, shipped with BeamJoy
  MyPlugin/
    main.lua                your plugin
```

Load the helper from BeamJoy's folder rather than copying it into your plugin. That way it always
matches the BeamJoy version installed, through updates. Each plugin that loads it gets its own
copy in memory.

```lua
-- this file's path (Resources/Server/MyPlugin/main.lua), then Resources/Server's
local here = debug.getinfo(1).source:gsub("^@", ""):gsub("\\", "/")
local BJ = dofile(here:match("^(.*)/[^/]+/[^/]+$") .. "/BeamJoyServer/api/BeamJoyAPI.lua")

function onInit()
    BJ.init("MyPlugin") -- your plugin's name : letters, digits, _ and -

    BJ.onReady(function(info)
        print("BeamJoy " .. info.beamjoy.version .. " on " .. info.map.name)
        BJ.call("races.leaderboard", { raceId = 1 }, function(ok, result)
            if not ok then return print(result.code .. " : " .. tostring(result.message)) end
            for _, e in ipairs(result.entries) do print(e.rank, e.name, e.timeMs) end
        end)
    end)

    BJ.on("LeaderboardChanged", function(data)
        print(data.change.name .. " set a time on " .. data.raceName)
    end)
end
```

- `BJ.call(method, params, callback)`: the callback gets `(true, result)` or `(false, error)`.
  Calls made before BeamJoy is up wait for it. A call with no answer after `BJ.timeout` seconds
  (default 10) fails with `{code = "timeout"}`.
- `BJ.on(event, fn)`: `fn(data, message)` for every event of that name.
- `BJ.onReady(fn)`: `fn(info)` once BeamJoy is up (`info` is `server.info`'s result). Do your
  full sync here.
- `BJ.hook(name, fn, opts)`: answers one of BeamJoy's questions (see [Hooks](#hooks)). `fn(question,
  answer)` returns its answer (a table), or returns nothing and calls `answer(table)` later.
  `opts.timeoutMs` is how long BeamJoy waits for it (default 2000, at most 10000). `BJ.unhook(name)`
  stops.
- `BJ.raceOptions(sections)`: your options in the race start menu and race editor (see
  [Race options](#race-options)). Registered again by itself whenever BeamJoy restarts.
- `BJ.tyreOptions(list)`: the tyre sets racers can pick at a pit stop (see
  [Tyre options](#tyre-options)). Registered again by itself whenever BeamJoy restarts.
- `BJ.configTab(tab, onChange)`: your tab in the config window (see [Config tabs](#config-tabs)).
  `onChange(values, changed, by)` gets the values once registered (`changed` and `by` nil then),
  and again whenever someone saves the tab. `BJ.onConfigAction(fn)`: `fn(action, by)` when one of
  its buttons is clicked.
- `BJ.page(page)`: a page in the main window (see [Pages](#pages)), registered again by itself
  whenever BeamJoy restarts. `BJ.updatePage(id, blocks, players?, callback?)` changes its content
  (everyone's, or those players' own), `BJ.removePage(id?)` takes it away.
  `BJ.onPageOpened(fn)`: `fn(pageId, by)` when a player opens it ; `BJ.onPageAction(fn)`:
  `fn(pageId, action, values, by)` when they click one of its buttons.
- `BJ.json`: the JSON encoder/decoder the helper uses (`BJ.json.stringify`, `BJ.json.parse`).

Complete example plugins. To try one, copy its folder into `Resources/Server/`, next to
`BeamJoyServer`, and restart the server.

- `example/BJLeaderboardExport/` writes every map's leaderboards (BeamMP accounts and nicknamed
  guests only) to `export/<map>.json` and rewrites them whenever a time changes.
- `example/BJRaceControl/` uses the hooks, race events and overlays: guests without a nickname
  can't ready up, the fastest leaderboard time starts in front, and racers get a live timing
  overlay that turns into the results.
- `example/BJClasses/` adds race classes: a class picked in the race editor and the start menu,
  the cars of each class set in a config tab, cars outside the class refused at ready-up, the
  class and league points shown on results and leaderboard entries, and a League page in the main
  window with the standings (each player's own place, a class to pick).
- `example/BJHudLabels/` puts labels beside racers' names on the race HUD: their class (kept on
  their result and leaderboard entry) and the places they've gained since the start (HUD only).
  A config tab picks the HUD: BeamJoy's own, or an extended one of the plugin's (an overlay in the
  race HUD's look, standing in for BeamJoy's) with the same labels.
- `example/BJRallycross/` is a discipline of its own on [phases](#phases): a "Rallycross" format
  (two heats for points, the second on a reversed grid, then a final for the top 6 gridded on
  points), the points beside the names on the HUD, and the event's result set by the plugin.
- `example/BJShootout/` runs a phase itself: one lap each, alone on track, the plugin starting
  each racer in turn and scoring them, the 107% rule through the `phaseResult` hook, then the
  race on that grid.
- `example/BJRaceDirector/` runs races of its own: a lobby every half hour (`race.open`), a time
  penalty for each reset past the free ones (`RacerReset`, `race.penalize`), and the new leader
  told on their own HUD (`RacePositionsChanged`, `hud.message` to one player).

## Methods

Every `map` param is optional and defaults to the map the server is on. Another map's data is
read from BeamJoy's saved files.

Methods that change something (`race.*`, `phase.*`, `formats.*`, `environment.set`, `overlay.*`,
`hud.message`, `hooks.*`, `raceOptions.*`, `tyres.*`, `results.setFields`, `leaderboard.setFields`,
`config.*`, `pages.*`) need your plugin's name in the request's `from`. The helper always sends
it.

### `server.info`
→ `{api, instance, beamjoy: {version, build}, map: {name, label}, players, methods[], events[]}`

`instance` changes every time the server starts.

### `maps.list`
→ `{maps: [{name, label, modded, enabled, current}]}`

### `races.list` `{map?}`
→ `{map, races: [race]}`, where each race is:

| Field | |
|---|---|
| `id`, `name`, `author` | |
| `distanceM` | metres, straight lines gate to gate |
| `loopable`, `laps` | `laps` is the race's default lap count |
| `gates` | how many gates |
| `freeroam` | whether it can also be run from freeroam |
| `vehicleRestriction` | `"free"`, `"single"` or `"pool"` |
| `options` | plugins' [race options](#race-options) as set for this race in the editor: `{plugin: {option: value}}` |
| `times` | `{grid, freeroam}` : how many players have a time on each board |
| `records` | `{grid, freeroam}` : each board's best entry, if any |

### `races.leaderboard` `{raceId, map?, board?, limit?}`
→ `{map, raceId, raceName, board, total, entries: [entry]}`

- `board` is `"grid"` (races run from the race lobby, the default) or `"freeroam"` (runs started
  by driving through the start gate).
- `limit` defaults to 100. `total` is the full count either way.

### `races.leaderboards` `{map?, board?}`
→ `{map, races: [{raceId, raceName, boards: {grid: {total, entries}, freeroam: {total, entries}}}]}`

Every race of a map, with both boards in full (or only `board` when given). Made for a full sync.

### `races.sessions`
→ `{sessions: [session]}` : the races being run right now, lobbies included.

A session is `{sessionId, raceId, raceName, map, options, state, joinable, private, laps,
timeLimitMin?, placementMode, gridSlots, greenAt?, endsAt?, timeUpAt?, breakEndsAt?, starter?,
hostedBy?, hostName?, holdStart?, phaseIndex, phase, phaseCount, format?, phases, result,
phaseResults, eventStandings?, racers: [racer]}`. `format` is a plugin's [format](#formats) it
runs (`"plugin:id"`), if it does. `hostedBy` is the plugin whose lobby it is (`race.open`) : it has
no `starter`.

- `state` is `"GRID"` (the lobby), `"COUNTDOWN"`, `"RACE"`, `"BREAK"` (between two
  [phases](#phases)) or `"FINISHED"`.
- `laps`, `timeLimitMin`, `endsAt` (a timed phase's end) and `timeUpAt` (when its time ran out)
  are the phase under way's. `laps` is left out for a phase timed only.
- `phase` is the phase under way (in the lobby, the first), `phases` all of them, `phaseResults`
  the ones run so far (`[{phase, results}]`), `eventStandings` the event's result so far.
- `racers` come in the phase's standings order. Each racer is `{id, racerKey, name, identity, away, vehicle,
  ready, readyChecking, readyBlock?, gridPosition?, position?, lap, finished, dnf, disqualified,
  penaltyMs?, bestLapMs?, totalMs?, inPhase, startAt?, awaitingStart?, score?, scoreDisplay?,
  fields}`. `inPhase` is false for a racer sitting the phase out (its `takes` left them out, or
  they're out of the event) ; `startAt` is a start of their own (a staggered start, their next
  run, a mid-phase join).
- `options` is the plugins' [race options](#race-options) for this race: `{plugin: {option:
  value}}`, every option of every plugin running, filled in. Every race event carries it too.
- `fields` is the racer's [labels](#fields) (a list, maybe empty).
- `id` is the racer's player ID ; it's left out while they're `away` (disconnected mid-race, inside
  their rejoin time). A racer who comes back gets a new one, often.
- `racerKey` is the racer's for the whole event : away, back under a new player ID, in every phase.
  Results have it too. Every method that takes a racer's `playerId` takes a `racerKey` instead, and
  lists or maps of racers (grid orders, scores, hook answers) are by racer key with `by =
  "racerKey"` : use it for anything you keep across a disconnect (points, resets, penalties). It's
  only that session's : another event starts its own.
- `readyBlock` is `{reason, by}` when a plugin refused their last ready-up.
- `greenAt`, and every `at` in the race events, is a moment as `{unixMs, clockMs}` (see
  [Times](#times)).

### `race.setGridOrder` `{sessionId, order, by?}`
Sets the order cars start in, while the session is still a lobby: `order` is a list of player
IDs (racer keys with `by = "racerKey"`), first on the grid first. Racers it leaves out start behind, in BeamJoy's own order. An answer
to the `gridOrder` hook, if a plugin gives one, comes first. → `{sessionId, order}`

### `race.unready` `{playerId, reason?}` or `{sessionId, racerKey, reason?}`
Takes a racer in a lobby back to not ready. They see `reason` in the lobby and as a message (their
car no longer qualifies, an entry they haven't paid...). → `{playerId}`. Error `refused` when
they're not in a lobby.

### `race.setPhases` `{sessionId, phases, result?}`
A lobby's [phases](#phases), and how the event's result comes from them, checked like a start's.
Everyone goes back to not ready. → `{sessionId, phases, result}`. Error `refused` once it's no
longer a lobby.

### `race.endPhase` `{sessionId}` / `race.extendPhase` `{sessionId, minutes}` or `{sessionId, laps}` / `race.nextPhase` `{sessionId}`
The phase under way ends now (a red flag, a judged run over : laps under way don't count) ; a
timed phase gets `minutes` more (less, negative ; not once its time is up) → `{sessionId, endsAt}`,
or a phase on laps gets `laps` more (runs on a point-to-point track ; fewer, negative, never under
what anyone's done ; not once someone's finished it) → `{sessionId, laps}` ; between two phases,
the next one's countdown starts now. Error `refused` when the session isn't in that state.

### `race.startRacer` `{sessionId, playerId | racerKey, countdownS?, from?}` / `race.stopRacer` `{sessionId, playerId | racerKey}`
In a phase with `start = "plugin"`, racers wait on their grid slot until you start them :
`countdownS` (default 5, 0 to 30) of their own countdown, from their grid slot (`from = "grid"`,
default) or the first one (`"first"`). → `{sessionId, playerId, racerKey, startAt}`. `race.stopRacer` ends
a racer's phase (any phase) : finished with the laps or runs they completed, out without any
(`RacerOut` reason `"stopped"`).

### `phase.setScores` `{sessionId, scores, better?, display?, event?, by?}`
Your scores for racers : `scores` is `{[playerId] = number}` (`{[racerKey] = number}` with `by =
"racerKey"`), `better` `"high"` or `"low"`
(default), `display` `{[playerId] = text}` what the HUD and results show instead ("86 pts", 16
characters at most). A phase ranked `"plugin"` places its racers by them ; with `event = true`
they're the event's, for a `result = "plugin"` event. Call again whenever they change ; changes
within 100 ms go out together. A racer who left the event still takes event scores under the
player ID (or racer key) an earlier phase's result gave them ; one that isn't a racer of this event (or,
for a phase's scores, no longer in the race) is left out, the others still set. → `{sessionId,
count, skipped?}` : `count` the scores set, `skipped` the ones left out

### `race.penalize` `{sessionId, playerId | racerKey, ms, reason?}`
Race control, while the phase runs : `ms` of time penalty on the racer's race time (taken off with
a negative ; never under none, an hour in all at most ; 600000 at most at once). It shows on the
race HUD straight away and counts in the standings, as a penalty staff give. The racer is told
("Race control : a 5 s penalty...", then your `reason`). → `{sessionId, playerId, racerKey,
penaltyMs, changeMs}` : `penaltyMs` their penalties now. Error `refused` when no phase is running,
the racer sits it out or is disqualified, or nothing changes.

### `race.clearPenalties` / `race.disqualify` / `race.reinstate` `{sessionId, playerId | racerKey, reason?}`
Clears a racer's penalties ; disqualifies them (one still racing is stopped, one who finished keeps
their laps but drops to the bottom and loses this phase's leaderboard time) ; reinstates them
(a finisher's time goes back on the leaderboard ; one stopped by it stays out). As staff watching
the race can, while the phase runs. The racer is told, with your `reason`. → the same as
`race.penalize`, with `disqualified`. A disqualification sends `RacerOut` too, and every one of
these `RaceControl`.

### `race.open` `{raceId, options?, name?, holdStart?, entrants?}`
Opens a lobby of your own on a race of the current map : a scheduled event, a league night. It
has no leader (nobody changes its settings or starts it early) and stays open while empty, until
its time runs out. Then it starts with whoever's ready, or closes when nobody is. → the session
(as `races.sessions` gives them), with `invited`.

- `options`: the race start menu's options, as a start sends them : `laps`, `timeLimitMin`,
  `phases`, `format`, `result`, `respawnStrategy`, `placementMode`, `countdown`, `gridTimeout`
  (seconds the lobby stays open), `gridReadyTimeout`, `vehicleRestrictionMode` (`"free"`,
  `"raceDefined"`, `"pool"` with `vehicleRestrictionPoolPresetId`), `disableCollisions`,
  `lateJoin`, your [race options](#race-options) under `plugins`... What's left out is the race's
  own, as for any start.
- `name`: what the lobby lists show instead of a leader's name ("League night"; your plugin's name
  by default).
- `holdStart = true`: it starts only when its time's up or you say (`race.startNow`), not once
  everyone's been ready a moment.
- `entrants`: player IDs, its entry list : only they may join. It isn't listed : each gets an
  invite in their notifications (`invited` : the ones connected and free right now). For
  conditions of your own (licences, a class), answer the `raceJoin` [hook](#hooks) instead.

Error `refused` when the race isn't a grid race on this map, or has fewer than 2 grid slots.

### `race.startNow` `{sessionId}` / `race.close` `{sessionId, reason?}`
`race.startNow` starts a lobby now, as when its time runs out : whoever isn't ready is left out,
and nobody ready closes it. → `{sessionId, state}` (`"CLOSED"` then). `race.close` ends any
session now, a lobby or an event under way (`RaceClosed` follows) ; its racers are told, with
your `reason`. → `{sessionId}`

### `formats.register` `{formats}` / `formats.unregister`
Your formats in the race start menu, replacing the ones you registered before. See
[Formats](#formats). → `{formats}`

### `raceOptions.register` `{sections}` / `raceOptions.unregister`
Your sections of options in the race start menu and race editor (replacing any you registered
before). See [Race options](#race-options). → `{sections}`

### `tyres.register` `{options}` / `tyres.unregister`
Your tyre sets for the pit menu (replacing any you registered before). See
[Tyre options](#tyre-options). → `{options}`

### `results.setFields` `{sessionId, playerId | racerKey, fields, replace?}` / `{sessionId, racers, replace?, by?}`
Labels on a racer's result in a race being run, shown in the game's results and in the race
events, and on the race HUD for the ones marked `hud`. When that race already put their time on
the leaderboard, the entry gets them too. `racers` sets several racers' at once: `{[playerId] =
fields}` (`{[racerKey] = fields}` with `by = "racerKey"`), or a list of `{playerId | racerKey,
fields, replace?}` (64 at most ; one wrong racer and nothing changes). See [Fields](#fields). →
`{sessionId, playerId}` (`racers`: `{sessionId, playerIds}`)

### `leaderboard.setFields` `{raceId, name, fields, board?, replace?}`
Labels on a leaderboard entry of the current map's race (`name` is the entry's name, `board`
`"grid"` by default). See [Fields](#fields). → `{raceId, board, name}` ; `LeaderboardChanged`
follows with `change.kind` `"fields"`.

### `config.register` `{title, sections}` / `config.unregister`
Your tab in the config window. See [Config tabs](#config-tabs). → `{values}`

### `config.get` / `config.set` `{values}`
Your config tab's values (the stored ones, your defaults for the rest, secrets included) ;
`config.set` changes the ones given. → `{values}` (and `changed`, the options `config.set`
changed ; `ConfigChanged` follows with `by` `"plugin:<name>"`)

### `pages.register` `{id, title, ...}` / `pages.update` `{id, blocks, players?}` / `pages.unregister` `{id?}`
A page of yours in the main window, its content, and taking it (or, without `id`, all of yours)
away. See [Pages](#pages). → `{id}` (`pages.unregister` without `id`: `{removed}`)

### `players.online`
→ `{players: [{id, name, displayName, nickname, guest, group, staff}]}`

- `name` is the BeamMP name.
- `nickname` is the BeamJoy nickname, if the player picked one. Only guests can: a player
  logged in to a BeamMP account keeps their account name.

### `environment.get`
→ `{timeOfDay, clock, timeSync, dayNightCycle, dayLengthS, date, simSpeed, simPause, gravity, gravitySync, weatherSync, weather}`

- `timeOfDay` uses the game's own scale: `0` is noon and `0.5` is midnight. `clock` is the same
  time as `"HH:MM"`.
- `weather` only appears while weather sync is on. It holds the weather panel's own fields.

### `environment.set` `{clock?, timeOfDay?, dayNightCycle?, dayLengthS?, timeSync?, date?, weatherSync?, weather?}`
Changes the time and weather, the same as staff in BeamJoy's environment panel. Only the fields
sent change. → the same as `environment.get`, after the change.

- `clock` is `"HH:MM"` ; `timeOfDay` is the game's own scale (`0` noon) ; send one or the other.
- `date` is `{year, month, day}`.
- `weather` holds the weather panel's fields: `cloudCover`, `fogDensity`, `windSpeed`,
  `fogAtmosphereHeight`, `groundWind {x, y, z}`, `cloudWindDirection {x, y}`, and
  `temperatureCurveOverrideC`, the day's temperature: `[[time, °C], ...]` points in time order
  (`time` on the game's scale, `0` noon, `.5` midnight ; at least 2 points, at most 96, -50 to
  60 °C), or `false` for the map's own. Only the ones sent change. Players only see it while
  `weatherSync` is on.

### `overlay.show` / `overlay.hide` / `overlay.clear`
An activity overlay: what the race HUD is to races, for an activity of your own (or extra
information beside a BeamJoy race). See [Overlays](#overlays).

### `hud.message` `{text, color?, durationS?, players? | playerId? | sessionId?, audience?, racerKey?}`
A line of text across BeamJoy's own HUD for a few seconds (default 5, 1 to 30), to everyone, or
one of :

- `players`: a list of player IDs (nobody when empty) ;
- `playerId`: one player ;
- `sessionId`: a race's players, `audience` `"racers"`, `"spectators"` (the players watching it)
  or `"all"` (both, the default) ; with `racerKey`, that one racer.

Players connected now only : BeamMP gives a player's ID to the next one who connects after they
leave.

### Leaderboard entries

`{rank, name, timeMs, model, date, identity, fields}`

| Field | |
|---|---|
| `rank` | 1 is the fastest |
| `name` | the BeamMP account name, or for a guest, the BeamJoy nickname if they had picked one when they set the time (otherwise their guest name) |
| `timeMs` | best lap time, in milliseconds |
| `model` | the vehicle's model, like `"etk800"`, if known |
| `date` | Unix time, in seconds |
| `identity` | what `name` is (below) |
| `fields` | plugins' [labels](#fields) on the run that set it (a list, maybe empty) |

`identity` is one of these (racers in the race events and `races.sessions` have it too):
- `"nickname"`: a guest's BeamJoy nickname.
- `"beammp"`: a BeamMP account name.
- `"guest"`: a BeamMP guest name. These change every time the guest restarts their launcher.
- `"unknown"`: the time was saved before BeamJoy started recording this.

To leave out guests without a nickname, keep the `"beammp"` and `"nickname"` entries and number
them again yourself.

Names are display names, not permanent IDs: a guest can change their nickname.

### Errors

| `code` | When |
|---|---|
| `unknownMethod` | the method doesn't exist |
| `badParams` | a param is missing or invalid; `message` says which |
| `notFound` | the race doesn't exist |
| `internal` | something failed on BeamJoy's side (also logged in the server console) |
| `refused` | the change can't be made now (`message` says why) |
| `timeout` | from the helper: BeamJoy didn't answer |

## Events

| Event | `data` |
|---|---|
| `Ready` | same as `server.info`. Sent once BeamJoy has loaded |
| `LeaderboardChanged` | `{map, raceId, raceName, board, change: {kind, name}, total, entries}` |
| `RacesChanged` | `{map}` |
| `RacePhaseFinished` | `{sessionId, ..., at, phaseIndex, phase, results, eventStandings?, nextPhase?, breakS?}` |
| `RaceFinished` | `{map, raceId, raceName, laps, results: [result]}` |
| `MapChanged` | `{from, to}` |
| `PlayerJoined` | `{id, name, guest, players}` |
| `PlayerLeft` | `{id, name, players}` |
| `EnvironmentChanged` | the same as `environment.get`, plus `by` |
| `RaceGridOpened` | a session (see `races.sessions`) |
| `RaceCountdown` | `{sessionId, raceId, raceName, map, at, greenAt, countdownS, orderedBy?, grid: [racer]}` |
| `RaceGreenLight` | `{sessionId, raceId, raceName, map, at, greenAt, laps, timeLimitMin?, endsAt?, racers: [racer]}` |
| `RacerStarted` | `{sessionId, ..., at, racer, startAt, run}` : a start of a racer's own was set (their next run, a plugin's start, a mid-phase join) |
| `RacerJoinedPhase` | `{sessionId, ..., at, racer}` : a player who joined mid-event is in the phase |
| `RacerGate` | `{sessionId, ..., at, racer, gate, step, lap, lapComplete, outLap?, lapMs?, deltaMs?, sectors, position}` : a racer went through a gate |
| `RacerLap` | `{sessionId, raceId, raceName, map, at, racer, lap, lapMs, sectorsMs, raceMs, bestLap, position}` |
| `RacerFinished` | `{sessionId, raceId, raceName, map, at, racer, finishOrder, raceMs, totalMs, laps, newPB, newRecord}` |
| `RacerOut` | `{sessionId, raceId, raceName, map, at, racer, reason, laps}` |
| `RacerReset` | `{sessionId, ..., at, racer, lap, lastGate?, respawn, penaltyMs?, holdS?}` : a racer reset |
| `RacePositionsChanged` | `{sessionId, ..., at, changes: [{racer, from, to}]}` : places changed |
| `RacerPitEntry` | `{sessionId, ..., at, racer, lap, speedKmh}` : in through PIT IN |
| `RacerPitStop` | `{sessionId, ..., at, racer, lap, fuelL, repair, tyres?, tyreOption?, durationMs, servedMs, towed?}` : a stop made in their box, once the server saw the car standing there. `durationMs` : the work's time the racer's game reported (at least the tyres', at most the race's longest), `servedMs` : how long the server saw the car stand in its box. `tyres` : new tyres (experimental tyre changes only), `tyreOption` : your set's `"plugin:id"` |
| `RacerPitExit` | `{sessionId, ..., at, racer, lap, stopped}` : out through PIT OUT |
| `RacerPitPenalty` | `{sessionId, ..., at, racer, lap, reason, penaltyMs}` : `reason` `"entrySpeed"`, `"transit"`, `"missingStops"` or `"stopShort"` (a stop more than 3 s shorter than its work) |
| `RacerPitTow` | `{sessionId, ..., at, racer, lap, holdMs, metres}` : towed to their box |
| `RacerPitReturned` | `{sessionId, ..., at, racer, lap, towed}` : back in their box after the phase |
| `RaceControl` | `{sessionId, ..., at, racer, action, ms?, penaltyMs, by, reason?}` : staff or a plugin stewarded a racer |
| `RaceClosed` | `{sessionId, raceId, raceName, map, at, state}` |
| `ConfigChanged` | `{plugin, values, changed, by}` : a plugin's config tab was saved |
| `ConfigAction` | `{plugin, action, by: {id, name}}` : a button on a plugin's config tab was clicked |
| `PageOpened` | `{plugin, page, by: {id, name}}` : a player opened a plugin's [page](#pages) |
| `PageAction` | `{plugin, page, action, values, by: {id, name}}` : a button on a plugin's page was clicked |

Every race event (`RaceGridOpened` to `RaceClosed`) also carries `options`: the plugins' [race
options](#race-options) for that race, and `phaseIndex`, `phase` and `phaseCount` : the
[phase](#phases) it's about, and `format` when it runs a plugin's format.

**One session, several phases**: `RaceCountdown`, `RaceGreenLight`, `RacerLap`, `RacerFinished`
and `RacerOut` fire for every phase, so an event of several phases has several green lights.
Check `phaseIndex` (or `phase.ranking`) when that matters to you. A race started as before is one
phase : nothing changes for it.

**`RacePhaseFinished`** is a phase's final result (after the `phaseResult` hook), the event's
standings so far, and what comes next (`nextPhase` and the break before it, none after the last).

**`LeaderboardChanged`** carries the race's whole board, so you can replace your copy of that
board. `change.kind` is:
- `"pb"`: a new personal best.
- `"restored"`: staff disqualified a run, and the time it had replaced came back. A leaderboard
  can get worse, not only better.
- `"fields"`: a plugin changed an entry's [labels](#fields) ; the times are as they were.

**`RacesChanged`** means a map's races were added, edited, deleted or imported. **Editing a race
clears its times.** Fetch the map again (`races.leaderboards`).

**`RaceFinished`** is `{sessionId, raceId, raceName, map, laps, at, greenAt, result, results,
phases}`. `results` is the event's result (see [Phases](#phases) : the last phase that counts,
times added up, or your scores), `phases` every phase's own (`[{phase, results}]`). Results come
in order. Each result is
`{position, id, name, identity, vehicle, finished, disqualified, totalMs, bestLapMs, penaltyMs, newPB, newRecord, leaderboardRank, fields, laps, bestSectorsMs, score?, scoreDisplay?, phasesDone?}`.
Racers without a place (didn't finish, no lap time in a phase ranked by best lap, disqualified)
come last and have no `position` ; `finished` is whether they have one. `totalMs` is left out for
a phase ranked by best lap ; `phasesDone` is how many counted phases a racer has a time in (an
event whose times are added up).

**Laps and sectors**: `laps` is `[{lap, timeMs, sectorsMs}]`, every lap the racer completed ;
`sectorsMs` lists that lap's sector times in order (the race's own sectors, as its creator set
them) ; `bestSectorsMs` is the racer's best time in each sector.

**`RaceCountdown`** gives the grid in order (`gridPosition` 1 first) and `greenAt`, when the lights
go green (BeamJoy's clients start on that moment themselves). `orderedBy` names the plugin whose
order it is, if one gave it. **`RaceGreenLight`** follows when the race starts.

**`RacerLap`** fires for every lap, the last one included (then `RacerFinished`). `raceMs` is the
racer's race time so far ; `position` their place in the standings right then.

**`RacerFinished`**: `totalMs` is `raceMs` plus any time penalties ; the standings go by it.

**`RacerGate`** fires for every gate a racer goes through, in the order they're meant to (a gate
crossed out of order, or twice, doesn't count : no event). `gate` is the gate's number in the race,
`step` its place along the lap (the same as `gate`, except on a race with branches), `lap` the lap
it's on. `lapMs` is the time into that lap, `deltaMs` against the racer's own best lap at that
point (negative : faster ; none before they have one), `sectors` the sectors this gate completed
(`[{sector, ms}]`, most often none or one), `position` their place right after. The line closing a
lap has `lapComplete`, and comes after `RacerLap` (and `RacerFinished`, or `RacerStarted` for a
next run). An out lap's gates have `outLap` and no times. One event per gate per racer : on a long
race with many racers, that's several a second.

**`RacerReset`**: the racer recovered or reset during a phase, as their game reports it (once per
reset, however it was done). `respawn` is the race's respawn rule (`"lastcheckpoint"`, `"all"`,
`"flipupright"`, `"lastroad"`...), `lastGate` the last gate they went through, `penaltyMs` the time
penalty the race's own reset rule added (`holdS` : the seconds it holds them instead). Your
penalties come on top (`race.penalize`).

**`RacePositionsChanged`**: places in the phase's standings changed since the last update : an
overtake at a gate, a finish, a penalty, a disqualification. `changes` lists only the racers whose
place changed, best place first. A phase's first update, and a racer joining mid-phase, set where
they are without an event.

**`RaceControl`**: `action` is `"penalty"` (`ms` added, or taken off when negative),
`"clearPenalties"` (`ms` taken off), `"disqualify"` or `"reinstate"` ; `penaltyMs` the racer's
penalties now ; `by` `"staff:<name>"` or `"plugin:<name>"`. A reset's own penalty isn't one of
these (`RacerReset`).

**`RacerOut`**: `reason` is `"retired"` (they retired, or BeamJoy retired them for not moving),
`"disconnected"` (they left and didn't come back in time), `"disqualified"` (by staff, a plugin's
`race.disqualify` or a `phaseResult` answer ; also sent for a racer who had already finished), `"timeUp"` (a timed phase
ended before they completed a lap) or `"stopped"` (`race.stopRacer`, without a lap). Out of a
phase isn't out of the event : they're back for the next one.

**`RaceClosed`** means a session ended without a result: the lobby was cancelled (by its leader,
staff or `race.close`), everyone left, or nobody was ready in time. `state` is where it was. A
finished race sends `RaceFinished` instead.

**`EnvironmentChanged`**: `by` lists who changed it since the last one (player names,
`"plugin:<name>"`, or `"server"` for BeamJoy itself, e.g. on a map change). It isn't sent for the
clock simply moving on.

**`ConfigChanged`** and **`ConfigAction`** go to every plugin like any event ; `plugin` says whose
tab it was (`BJ.configTab` and `BJ.onConfigAction` only pass on your own). `values` leaves secret
options empty, `secretsSet` saying which are set : every plugin gets this event. Read them with
`config.get` (`BJ.configTab`'s callback does, and gets them all).

**Text from players**: names (`name`, `by.name`), race names, and what players type in a page's
fields are theirs. Escape them before putting them on a web page, and take `@everyone` / `@here`
out before posting them to Discord. A leaderboard entry's `identity` says what kind of name it is
(`"beammp"`: a BeamMP account ; a guest's nickname can't be an account's name). In what you send
BeamJoy, `{{` gets an invisible space between its braces : the game runs what's in `{{ }}` as
code.

**`PageOpened`** and **`PageAction`** go to every plugin too (`BJ.onPageOpened` and
`BJ.onPageAction` only pass on your own). `values` are the page's fields as that player set them,
checked against the fields they were shown.

**`PlayerJoined`** fires before a guest picks a nickname. Use `players.online` when you need
nicknames.

## Hooks

A hook is a question BeamJoy asks the plugins that registered for it, before it goes on. Register
with `BJ.hook(name, fn)` (the helper registers again by itself whenever BeamJoy restarts). BeamJoy
waits for every registered plugin to answer, up to its `timeoutMs`; a plugin that doesn't answer in
time is left out of that decision. One that misses 3 times in a row is dropped (registering again
brings it back), so a removed or broken plugin can't hold races up.

| Hook | Asked when | Question | Answer |
|---|---|---|---|
| `raceJoin` | a player joins a lobby, or an event under way (a phase's `lateJoin`) | `{session, player, midway}` ; `player` is `{id, name, displayName, nickname, guest, group, staff, identity, leaderboardMs}` ; `midway` whether the event's under way | `{allow = false, reason = "..."}` refuses ; anything else lets them in |
| `raceReady` | a racer readies up in a lobby (the leader's "Start now" too) | `{session, racer}` ; `racer.vehicle` is what they're in, `racer.leaderboardMs` their time on this race | `{allow = false, reason = "..."}` refuses ; anything else allows |
| `gridOrder` | a phase's grid is about to be placed (2 racers or more) | `{session, racers, defaultOrder, phaseIndex, phase, previous, event}` ; each racer has `leaderboardMs` and `joinIndex` ; `defaultOrder` is the player IDs in BeamJoy's own order (the phase's `order`) ; `previous` the phases run so far `[{phase, results}]`, `event` the event's standings | `{order = {playerId, ...}}` first on the grid first ; `{take = {playerId, ...}}` only these race the phase ; nothing keeps BeamJoy's |
| `phaseResult` | a phase is over, before its result is final | `{session, phaseIndex, phase, results, previous}` ; `results` as BeamJoy has them | `{adjustMs = {[playerId] = ms}}` time added (taken off, negative) ; `{out = {playerId, ...}}` disqualified ; `{order = {playerId, ...}}` placed first, in this order ; nothing keeps BeamJoy's result |

- **`raceJoin`**: the player is in once every plugin's answered (or the time's up), if nothing
  changed meanwhile (the lobby full, started) ; a refusal shows them the reason as a message. An
  entry list, licences, a class, a ban from your league.
- **`raceReady`**: the racer shows "Checking…" while plugins are asked. A refusal shows them the
  reason in the lobby, and as a message. When several plugins answer, the first to refuse (in
  the order they registered) gives the reason.
- **`gridOrder`**: asked before every phase. The lobby (or the break) is held while plugins are
  asked (nobody joins, nobody's ready state changes). Racers your order leaves out start behind,
  in BeamJoy's order ; racers your `take` leaves out sit the phase out and watch it. When several
  plugins answer, the first order (and the first take) given wins. `race.setGridOrder` is used
  when no answer gives one (in the lobby, or a break for the next phase).
- **`phaseResult`**: everyone's adjustments add up, every `out` counts, the first `order` wins. An
  order places the racers it names first, in its order, whatever their time : judged disciplines,
  stewards' decisions. A racer put out loses this phase's leaderboard time, as with staff.
- **By racer key**: an answer with `by = "racerKey"` names racers by their racer key everywhere in
  it (`order`, `take`, `adjustMs`, `out`) ; the questions' racers and results all have `racerKey`.

```lua
BJ.hook("raceReady", function(q)
    if not q.racer.vehicle:find("Pessima", 1, true) then
        return { allow = false, reason = "Pessima only tonight" }
    end
    return { allow = true }
end)
```

## Phases

A race session is an event of one or more phases : practice, qualifying then the race, a sprint
then a feature race on a reversed grid, heats then a final, two runs added up, a judged run. The
starter picks a format in the start menu and changes its phases as they like ; a race can have its
own (the race editor), and your plugin can add [formats](#formats). A race started as before is a
single phase ending on laps, and behaves as it always did.

```
GRID (lobby, ready once) ─▶ COUNTDOWN ─▶ RACE ─▶ BREAK ─▶ COUNTDOWN ─▶ RACE ─▶ … ─▶ FINISHED
                           └──────── phase 1 ────────┘   └──── phase 2 ────┘
```

A phase is :

| Field | |
|---|---|
| `name` | shown on the HUD and results ("Q2", "Heat 1") |
| `start` | `"grid"` everyone together ; `"individual"` (the start menu's "Time offset") from the first slot, `intervalS` apart, in grid order, several on track at once ; `"sequential"` ("One at a time") from the first slot in grid order, alone : each racer's whole phase (its laps or runs, a time limit counted from their own start) before the next is released ; `"open"` together, and on a point-to-point track each finish sends the racer back for another run ; `"plugin"` each waits until you `race.startRacer` them |
| `laps` | laps on a circuit, runs on a point-to-point track (not raced from the grid) ; left out : no limit |
| `timeLimitMin` | left out : no limit. Laps and time : whichever comes first. Neither : only with `start = "plugin"`, you end it |
| `afterTime` | once the time's up : `"leader"` the leader's next crossing ends their race, then everyone's own (racing rules, `ranking = "position"` only) ; `"own"` everyone finishes the lap they're on, it counts ; `"stop"` it ends at once |
| `ranking` | `"position"` laps done then race time ; `"best"` best lap or run (retiring keeps it) ; `"total"` every lap or run added up ; `"plugin"` your scores (`phase.setScores`) |
| `order` | the grid : `{from = "lobby"}` the lobby's own ; `{from = "phase", phase = n, reverse = r}` an earlier phase's result ; `{from = "event", reverse = r}` the event's standings so far. `reverse` : 0 none, n the first n turned around, -1 all |
| `takes` | `{from = n, top = k}` only the first k of phase n race it (`from` left out : the event's standings) ; the others watch it |
| `lateJoin` | players may join while it runs, or in the break before it : they ready up and start on their own after a short countdown. In a race their time counts from its green light |
| `leaderboard` | its laps go on the race's leaderboard (default true) |
| `countsToEvent` | part of the event's result (default true ; off for practice and qualifying) |
| `breakS` | seconds of results after it (default 30) ; the leader can start the next one sooner |
| `rules` | this phase's own `respawnStrategy`, `dnfEnabled`, `dnfTimeout`, `resetPenaltyEnabled`, `resetPenaltySeconds`, `resetPenaltyMode`, `ghostOnCountdown`, `disableCollisions`, `ghostBackmarkers`, `autoSpectateOnFinish` ; the rest are the event's |
| `options` | your [race options](#race-options) `where = "phase"` (`plugins` when you send phases) |

Up to 20 phases. The vehicle restriction, the anti-cheat settings and the lobby's are the event's.
A racer out of a phase (retired, disqualified) is back for the next one ; one who disconnects keeps
their place for the rejoin time, across phases, and is out of the event once it runs out.

The event's result (`result`) : `"last"` the last phase that counts ; `"sum"` every counted
phase's time added up, the ones with a time in each first ; `"plugin"` your scores
(`phase.setScores` with `event = true`).

### Formats

A format is a phase list in the start menu, with a name : the built-in ones (race, qualifying and
race, practice qualifying and race, sprint and feature, time attack, knockout, two runs) and
yours.

```lua
BJ.formats({
    { id = "rallycross", name = "Rallycross", description = "Two heats, then the final on points",
      track = "loop", result = "plugin", locked = { "phases", "ranking" },
      phases = {
          { name = "Heat 1", laps = 4, breakS = 20 },
          { name = "Heat 2", laps = 4, order = { from = "phase", phase = 1, reverse = -1 }, breakS = 20 },
          { name = "Final", laps = 6, order = { from = "event" } },
      } },
})
```

`locked` is `true` (all of it stays as you set it), or what the starter can't change : `"phases"`
(how many, their order), `"name"`, `"start"`, `"length"`, `"ranking"`, `"order"`, `"takes"`,
`"lateJoin"`, `"leaderboard"`, `"countsToEvent"`, `"breakS"`, `"rules"`, `"plugins"`. BeamJoy keeps
them as you set them whatever the start menu sends. `track` : `"any"` (default), `"loop"` or
`"pointToPoint"`, the races it's offered for. 16 formats per plugin. `BJ.formats` registers them
again whenever BeamJoy restarts.

### A discipline of your own

- **Points across heats** : rank each phase by position, give points on `RacePhaseFinished`,
  `phase.setScores` with `event = true` and `result = "plugin"`, and grid the final by points
  through the `gridOrder` hook (or `order = {from = "event"}`).
- **Judged runs** (drift, gymkhana) : `start = "plugin"`, `ranking = "plugin"`, no laps or time.
  `race.startRacer` each in turn, `race.stopRacer` when their run's judged, `phase.setScores`, and
  `race.endPhase` when everyone's been.
- **Stewards** : `race.penalize` and `race.disqualify` while a phase runs (track limits from
  `RacerGate`, too many resets from `RacerReset`), or answer `phaseResult` with time penalties,
  racers out, or an order once it's over.
- **Scheduled events** : `race.open` on a timer of your own, with `holdStart` and the lobby's
  `gridTimeout` ; an entry list with `entrants` or the `raceJoin` hook.
- **A knockout** : `takes = {from = 1, top = 10}`, or pick the racers yourself with the
  `gridOrder` hook's `take`.

## Overlays

`overlay.show {id, layout?, players?, position?, hides?, durationS?, ...}` shows an overlay, or
replaces the one you showed with the same `id`. `overlay.hide {id, players?}` takes it down (for
those players only, when given) ; `overlay.clear {}` takes all of yours down.

- `id`: your own name for it (letters, digits, `_ - .`). A plugin can show 8 at once.
- `players`: player IDs ; everyone when left out (players who join later too), nobody when empty.
  Only players connected now count : BeamMP gives a player's ID to the next one who connects
  after they leave, so an ID you kept from before is skipped.
- `position`: `"top-right"` (default, where the race HUD is), `"top-left"`, `"bottom-right"`,
  `"bottom-left"`, `"top"`, `"bottom"`, `"left"`, `"right"`. Overlays at the same place stack.
- `hides`: BeamJoy overlays yours stands in for while it's up. `{"race"}` hides BeamJoy's race HUD.
- `durationS`: taken down by itself after that long.
- **Colours** are `#rgb` / `#rrggbb` / `#rrggbbaa`, or BeamJoy's own: `"accent"`, `"muted"`,
  `"good"`, `"bad"`, `"warn"`, `"purple"`, `"white"`.
- **Timers**: `{mode, ms}`. `"up"` counts on from `ms`, `"down"` counts it down to 0, `"static"`
  shows it as it is. Players' screens count them by themselves : send a timer once, not every
  second.
- Everything shows as plain text (no HTML). Text that's too long is cut.

**`layout = "default"`**: BeamJoy's race HUD look, with your values. Every field is optional:

| Field | |
|---|---|
| `eyebrow`, `title` | the small orange line and the title |
| `plate` | `{text, sub?, color?}` the big position plate (`"P2"`, `"of 8"`) |
| `lines` | up to 3 `{value, unit?, label?, arrow? ("up"/"down"), soft?}` beside the plate (gaps) |
| `progress` | `{text, of?}` (`"Lap 2"`, `"/5"`) |
| `timer` | a timer |
| `delta` | `{text, kind}`, `kind` `"faster"` (green), `"slower"` (red) or `"neutral"` |
| `segments` | up to 20 of `"done"`, `"best"`, `"live"`, `""` (the sector strip) |
| `info` | `{left?, right?}` small line (last / best) |
| `bar` | 0 to 1, a progress bar |
| `rows` | up to 30 `{pos?, name, value?, playerId?, you?, out?, flag?, pen?, color?, fields?}` standings ; the player whose `playerId` it is sees their row highlighted. `fields`: labels beside the name, as [results.setFields](#fields) takes them (the first 2 shown, as on the race HUD ; `hud` doesn't matter here) |
| `footer` | `{label, name?, value?}` (fastest lap) |

**`layout = "custom"`**: your own blocks, top to bottom: `{width? (em, 8 to 40), background?,
accent?, blocks}`. Up to 40 blocks:

| Block | |
|---|---|
| `{type = "text", text, size?, color?, align?, bold?, italic?, display?}` | `size` `"s"`, `"m"`, `"l"`, `"xl"` ; `display` uses the race HUD's numbers font |
| `{type = "row", cells}` | up to 6 cells side by side: text, or `{text, color?, align?, bold?, grow?, size?, flag?, pen?}` ; `flag = true` puts the chequered flag after the text, `pen` a red penalty tag (`"+5s"`), as on the race HUD's standings (a cell can be only one of them) |
| `{type = "timer", mode, ms, size?, color?, align?}` | a timer |
| `{type = "plate", text, sub?, color?}` | a position plate |
| `{type = "bar", value, color?}` | 0 to 1 |
| `{type = "segments", items}` | like the default layout's |
| `{type = "table", columns?, rows}` | `columns` up to 6 `{label, align?}` ; `rows` up to 30 `{cells, playerId?, you?, color?}`, cells as a row's |
| `{type = "divider"}` | a line |

## Race options

Sections of your own settings in the race start menu and the race editor, drawn by BeamJoy like
its own: a race class, league rules, anything your plugin needs to know about a race.

```lua
BJ.raceOptions({
    { id = "league", title = "League", note = "Set by the league plugin", options = {
        { id = "class", type = "select", label = "Class", choices = { "GT", "Touring", "Street" },
          default = "Street", field = true },
        { id = "points", type = "toggle", label = "League points", where = "editor", default = true },
        { id = "fuel", type = "number", label = "Fuel", min = 10, max = 100, step = 10, unit = "%", where = "start" },
    } },
})
```

- In the **race editor**, the values are the race's own (saved with it ; editing a race still
  clears its times). In the **start menu**, the starter can change them for that race, starting
  from the race's own. The values chosen come with the race: `options[yourPlugin][optionId]` in
  `races.sessions`, every race event and every hook question.
- `where`: `"both"` (default), `"editor"` (set per race, the start menu can't change it),
  `"start"` (chosen at each start only) or `"phase"` (a value of its own for every [phase](#phases)
  of an event, set in the phase editor : `phase.options[yourPlugin][optionId]`, not in `options`).
- `field = true`: the option's value shows on every racer's result and goes on their leaderboard
  entry with their time, like a [field](#fields) (a toggle shows its label while on).
- Up to 4 sections, 16 options each. Option ids are yours across your sections.
- A race keeps its values for a plugin that isn't running (restarting, or removed for a while).
  BeamJoy only uses the options of the plugins running now.

**Options** (race options and config tabs alike):

| Option | |
|---|---|
| `{id, type = "toggle", label, default?}` | on / off |
| `{id, type = "select", label, choices, default?}` | `choices` up to 24, `"GT"` or `{value, label}` ; 5 or fewer show as buttons, more as a dropdown |
| `{id, type = "number", label, min, max, step?, unit?, default?}` | a slider |
| `{id, type = "text", label, maxLength?, placeholder?, default?}` | up to 500 characters (100 by default) |
| `{id, type = "button", label, confirm?}` | config tabs only: a click sends `ConfigAction` ; `confirm` asks first |

Every option can have a `tooltip`. `id` is a word: a letter, then letters, digits, `_` or `-`.

## Tyre options

**Experimental**: only while the server's **Experimental tyre changes** are on (Config > General >
Pits, off by default), and a race allows tyre changes. The pit menu then has a Tyres row, apart from
the repair: Keep, or a new set. With your sets registered, the row offers Keep and each of them.

```lua
BJ.tyreOptions({
    { id = "soft", label = "Soft", seconds = 12 },
    { id = "medium", label = "Medium" },
    { id = "hard", label = "Hard", seconds = 8 },
})
```

At most 8 sets. `label` is up to 32 characters ; `seconds` (0 to 120) is that set's fitting time
instead of the race's Tyre change time.

BeamJoy never changes the car's parts. It fits fresh tyres (flats fixed, the game's tyre state new)
and keeps the car's damage, then passes the choice on:

- `RacerPitStop` has `tyres = true` and `tyreOption = "yourPlugin:soft"`.
- In the racer's game, the game-engine hook `onBJPitService(vehicleId, work)`, and in the car's
  own Lua `onBJPitServiceStart(work)` before its reset and `onBJPitServiceDone(work)` after it.
  `work` is `{tyres, repair, tyreOption}`, what happened to the car: a repair together with new tyres
  (or a repair with tyre changes off) is the game's own reset, so `tyres` is true then too. A tyre
  mod can apply your set's compound there, or keep its wear through a repair alone (`tyres` false).

## Fields

Labels on a racer's result and their leaderboard entry: `"GT"`, `"25 pts"`, `"Team Red"`. They
show as small tags beside the name, in the game's results and leaderboards, and come with the API
(`fields` on results, racers and leaderboard entries).

A leaderboard keeps **one entry per player per race**, their best time, and fields don't change
that: they describe the run that set the time. A new best replaces the entry, fields included
(with the new run's own). To show a class's best times, read the entries with that class.

```lua
BJ.call("results.setFields", { sessionId = id, playerId = racer.id, fields = {
    { key = "points", label = "Points", value = "25 pts", color = "accent" },
} })
```

- `fields` is a list of `{key, value, label?, color?, showLabel?}`, or `{key = value}` /
  `{key = {value, label?, ...}}`. Up to 8 per plugin on one result or entry.
- A field's tag shows `value` ; `showLabel = true` shows `label value`. Hovering shows both.
- Your fields are merged into the ones you set before (`replace = true` replaces them all). A
  field sent with an empty value is removed. Other plugins' fields are never touched.
- `color` as for [overlays](#overlays).
- Setting a racer's fields before their time goes on the leaderboard puts them on the entry with
  it ; after (on `RacerFinished`, say), the entry gets them too.

### On the race HUD

`hud` puts a racer's field beside their name on BeamJoy's race HUD as well:

```lua
BJ.call("results.setFields", { sessionId = id, racers = {
    [3] = { { key = "class", value = "GT", hud = true },                        -- HUD, results, leaderboard
            { key = "tyre", label = "Tyre", value = "Soft", color = "bad", hud = "only" } }, -- HUD only
    [7] = { { key = "class", value = "Touring", hud = true } },
} })
```

- `hud = true`: on the race HUD, the results and the leaderboard entry.
- `hud = "only"`: on the race HUD only, for the race's live information (a tyre, a pit stop,
  places gained). Never on a result once the race is over, nor on a leaderboard entry, nor in the
  game's results window.
- Left out: results and leaderboard only, as before. Race options marked `field` aren't on the
  HUD (they're the same for every racer).
- **Where they show**: every standings row (standard and full layouts), the player's own (their
  row ; in the header on a race run alone ; under the position in the compact layout), and the
  first one beside the cars ahead and behind.
- **Two per racer** are shown, the first two in order (by plugin name, then the order you sent
  them). Each is cut past about 6 characters' width (hovering shows it whole) ; a long name gives
  way first, and keeps a few characters. Keep HUD labels short: `"GT"`, `"+2"`, `"S"`, `"P"`.
- **Live**: a change shows within about a tenth of a second. Changes made within the same 100 ms
  go out as one update, however many racers they're for, but every update sends the race's
  standings to everyone in it: update on events (a lap, a pit stop), not on a timer.
- Players can turn plugins' labels off (Settings > Menu > "Show plugin labels on the race HUD").

## Config tabs

A tab of your plugin's settings in BeamJoy's config window, for staff holding the
`EditPluginConfig` permission (admins, unless changed in the Permissions tab). BeamJoy stores the
values (in `BeamJoyData/db/pluginConfig.json`), so your plugin needs no settings file.

```lua
BJ.configTab({ title = "Website", sections = {
    { id = "site", title = "Website", options = {
        { id = "url", type = "text", label = "Address", placeholder = "https://..." },
        { id = "key", type = "text", label = "API key", secret = true },
        { id = "sync", type = "button", label = "Sync now" },
    } },
} }, function(values, changed, by)
    siteUrl, apiKey = values.url, values.key
end)
BJ.onConfigAction(function(action, by)
    if action == "sync" then syncEverything() end
end)
```

- Up to 8 sections, 40 options in all ; the [options](#race-options) as above.
- `secret = true` on a text option: its value never goes to a player's game. The tab shows
  whether one is set, and leaving it empty keeps it.
- Saving sends `ConfigChanged` (every value but the secrets) ; values only change for options your tab has.

## Pages

A page of your own in BeamJoy's main window: a button on its side rail opening a panel, a tab in
the full window, or both. You describe it in blocks, BeamJoy draws it in its own look: standings,
an entry list, a player's league card, a few buttons and choices.

```lua
BJ.page({ id = "league", title = "League", icon = "trophy", blocks = {
    { type = "heading", text = "Standings", sub = "This season" },
    { type = "field", control = "select", id = "class", label = "Class", choices = { "All", "GT" }, default = "All" },
    { type = "buttons", items = { { id = "show", label = "Show", style = "primary" } } },
    { type = "table", columns = { { label = "#" }, { label = "Driver" }, { label = "Points", align = "right" } },
      rows = { { cells = { "1", "Bob", "25" }, playerId = 3 } } },
} })
BJ.onPageOpened(function(pageId, by)
    -- their own version : their place, their stats
    BJ.updatePage("league", myBlocksFor(by.name), { by.id })
end)
BJ.onPageAction(function(pageId, action, values, by)
    if action == "show" then BJ.updatePage("league", myBlocksFor(by.name, values.class), { by.id }) end
end)
```

`pages.register {id, title, label?, icon?, where?, order?, wide?, staffOnly?, players?, blocks}`
adds a page, or replaces yours with the same `id`:

- `id`: a word (a letter, then letters, digits, `_` or `-`). A plugin can have 4 pages.
- `title`: the panel's title and the tab's name (32 characters). `label`: the word under the rail
  button (10, the title cut by default).
- `icon`: one of `plug` (the default), `trophy`, `flag`, `chart`, `car`, `info`, `star`,
  `calendar`, `users`, `globe`, `chat`, `list`, `clock`, `map`, `shield`, `bolt`, `heart`,
  `gauge`.
- `where`: `"both"` (default), `"rail"` (a panel only) or `"full"` (a full window tab only). The
  rail shows 4 plugin pages at most, the full window 6, in `order` (lowest first, then the order
  they were added).
- `wide = true`: a wider panel. `staffOnly = true`: staff only (it follows promotions within a
  second). `players`: only those player IDs (connected now : one from a player who left is
  skipped).
- `blocks`: the content everyone sees.

`pages.update {id, blocks, players?}` changes the content: everyone's, or with `players`, those
players' own (they see it instead of everyone's until the page is removed or they leave).
`players` without `blocks` puts them back on everyone's. Players' screens follow straight away ;
`PageOpened` is the moment to give a player their own.

**Blocks**, top to bottom, up to 60 (32 KB once encoded): all of the [overlays'](#overlays) custom
blocks (`text`, `row`, `timer`, `plate`, `bar`, `segments`, `table`, `divider` ; a table row with
your `playerId` is highlighted for you), and:

| Block | |
|---|---|
| `{type = "heading", text, sub?}` | a section title ; `sub`, a line of smaller text under it |
| `{type = "field", control, id, label, ...}` | an input: `control` is an [option](#race-options)'s type (`toggle`, `select`, `number`, `text`) with its settings (`choices`, `min`, `max`, `default`...). Up to 12 per page |
| `{type = "buttons", items}` | up to 4 buttons in a row, `{id, label, style?, confirm?, disabled?, tooltip?}` ; `style` `"primary"`, `"secondary"` (default) or `"danger"` ; `confirm` asks first. Up to 16 per page |

A click sends you `PageAction` with the button's `id` and the page's fields as that player set
them. What a player picked stays while you update the page, as long as it still fits. Clicks and
page openings faster than a person would make them are dropped. The page shows that it comes from
your plugin.

## Times

Moments in the race events (`at`, `greenAt`) are `{unixMs, clockMs}`:

- `clockMs` is BeamJoy's shared race clock, the one its clients start the race on. The time between
  two moments is exact to the millisecond: use it for intervals.
- `unixMs` is the same moment as a Unix time in milliseconds (for dates on a website). It's right to
  about a second.

Lap and race times (`lapMs`, `raceMs`, `totalMs`...) are the racers' own timing, as BeamJoy records
it for the leaderboards.

## Notes

- A plugin that keeps a copy of the data should do a full sync in `onReady`. Events sent while it
  wasn't running are lost.
- Every answer goes to every plugin, and the helper drops the ones that aren't yours. Big answers,
  like a whole map's leaderboards, are fine: plugins on one server exchange them in memory.
- Without the helper: fire `BJAPI_Request` with a JSON string, register `BJAPI_Response`, and
  match your `id`. BeamJoy sends `BJAPI_Ready` once it has loaded. If your plugin starts after
  BeamJoy, it won't see that event, so send `server.info` yourself at start and treat the answer
  as "ready". Check that your handlers get a string (see [Security](#security)).

## Security

- **Server plugins are trusted.** A plugin in `Resources/Server` runs with the server's full
  rights: it can read every file, BeamJoy's database included, and kick or message anyone,
  with or without this API. Only install plugins you trust (read them, they're plain Lua). The API
  doesn't add to what a plugin can do there, and doesn't sandbox it either: `from` is the name a
  plugin gives, not a checked one.
- **Nothing reaches players' games as code.** Everything a plugin shows (messages, overlays,
  options, labels, config tabs, pages) is plain text drawn by BeamJoy: HTML shows as typed, scripts
  never run, colors are BeamJoy's names or hex codes. Players' games only ever run BeamJoy's own
  code; to run code there, a client mod (a zip in `Resources/Client`) is needed, and every player
  downloads it like BeamJoy.
- **Players can't use the API.** A player's game can fire any server event, `BJAPI_Request`
  included, but BeamMP then passes the player's ID first (a number) where a plugin passes the
  JSON string: BeamJoy ignores those (and logs who tried), and so does the helper on BeamJoy's
  events. Without the helper, ignore anything that isn't a string in your own handlers.
- **What players send is checked on the server.** Race option values are checked against the
  plugin's definitions (types, choices, ranges, lengths) ; config tabs need the
  `EditPluginConfig` permission to read, save or click. A page's click only counts for a button on
  the page that player sees (a staff page's buttons don't work for anyone else), its values are
  checked against that page's fields, and clicks or page openings faster than a person would make
  them are dropped.
- **Secrets stay on the server.** `secret` config options are never sent to a game, defaults
  included ; they are kept in `BeamJoyData/db/pluginConfig.json` in plain text, like any
  server setting, so protect the server's files.
- **Players' data.** Plugins get players' names, in-game IDs, groups and identity (`beammp`, `nickname`,
  `guest`), never IP addresses. A plugin that sends data elsewhere (a website, Discord) should say
  so, and use `https://`.
