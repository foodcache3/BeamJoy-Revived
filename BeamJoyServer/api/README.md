# BeamJoy plugin API

Lets your own BeamMP server plugins work with BeamJoy:

- **Read** its data: races, leaderboards, maps, online players, races being run, time and weather.
- **Hear** about events as they happen: a new best time, a lobby opening, the countdown and the
  green light (with server times), every lap, racers finishing or retiring, a finished race with
  every lap and sector, a map change, time and weather changes.
- **Take part** in races: refuse a racer's ready-up with a reason they see, set the order cars
  start in, take a racer back to not ready.
- **Show** players an activity overlay where the race HUD goes, in BeamJoy's own look or laid out
  your way, and a line of text across BeamJoy's HUD.
- **Set** the time and weather.

Typical uses: a website kept in sync with the leaderboards, a Discord bot, live timing, a
championship or league plugin, an entry list, a game mode of your own.

API version 1. Nothing here can change leaderboards or race results.

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
- `BJ.json`: the JSON encoder/decoder the helper uses (`BJ.json.stringify`, `BJ.json.parse`).

Two complete example plugins. To try one, copy its folder into `Resources/Server/`, next to
`BeamJoyServer`, and restart the server.

- `example/BJLeaderboardExport/` writes every map's leaderboards (BeamMP accounts and nicknamed
  guests only) to `export/<map>.json` and rewrites them whenever a time changes.
- `example/BJRaceControl/` uses the hooks, race events and overlays: guests without a nickname
  can't ready up, the fastest leaderboard time starts in front, and racers get a live timing
  overlay that turns into the results.

## Methods

Every `map` param is optional and defaults to the map the server is on. Another map's data is
read from BeamJoy's saved files.

Methods that change something (`race.*`, `environment.set`, `overlay.*`, `hud.message`, `hooks.*`)
need your plugin's name in the request's `from`. The helper always sends it.

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

A session is `{sessionId, raceId, raceName, map, state, joinable, private, laps, placementMode,
gridSlots, greenAt?, starter, racers: [racer]}`.

- `state` is `"GRID"` (the lobby), `"COUNTDOWN"`, `"RACE"` or `"FINISHED"`.
- `racers` come in standings order. Each racer is `{id, name, identity, away, vehicle, ready,
  readyChecking, readyBlock?, gridPosition?, position?, lap, finished, dnf, disqualified,
  penaltyMs?, bestLapMs?}`.
- `id` is the racer's player ID ; it's left out while they're `away` (disconnected mid-race, inside
  their rejoin time).
- `readyBlock` is `{reason, by}` when a plugin refused their last ready-up.
- `greenAt`, and every `at` in the race events, is a moment as `{unixMs, clockMs}` (see
  [Times](#times)).

### `race.setGridOrder` `{sessionId, order}`
Sets the order cars start in, while the session is still a lobby: `order` is a list of player
IDs, first on the grid first. Racers it leaves out start behind, in BeamJoy's own order. An answer
to the `gridOrder` hook, if a plugin gives one, comes first. → `{sessionId, order}`

### `race.unready` `{playerId, reason?}`
Takes a racer in a lobby back to not ready. They see `reason` in the lobby and as a message (their
car no longer qualifies, an entry they haven't paid...). → `{playerId}`. Error `refused` when
they're not in a lobby.

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
  `fogAtmosphereHeight`, `groundWind {x, y, z}`, `cloudWindDirection {x, y}`. Only the ones sent
  change. Players only see it while `weatherSync` is on.

### `overlay.show` / `overlay.hide` / `overlay.clear`
An activity overlay: what the race HUD is to races, for an activity of your own (or extra
information beside a BeamJoy race). See [Overlays](#overlays).

### `hud.message` `{text, color?, durationS?, players?}`
A line of text across BeamJoy's own HUD for a few seconds (default 5, 1 to 30). `players` is a
list of player IDs ; everyone when left out.

### Leaderboard entries

`{rank, name, timeMs, model, date, identity}`

| Field | |
|---|---|
| `rank` | 1 is the fastest |
| `name` | the BeamMP account name, or for a guest, the BeamJoy nickname if they had picked one when they set the time (otherwise their guest name) |
| `timeMs` | best lap time, in milliseconds |
| `model` | the vehicle's model, like `"etk800"`, if known |
| `date` | Unix time, in seconds |
| `identity` | what `name` is (below) |

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
| `RaceFinished` | `{map, raceId, raceName, laps, results: [result]}` |
| `MapChanged` | `{from, to}` |
| `PlayerJoined` | `{id, name, guest, players}` |
| `PlayerLeft` | `{id, name, players}` |
| `EnvironmentChanged` | the same as `environment.get`, plus `by` |
| `RaceGridOpened` | a session (see `races.sessions`) |
| `RaceCountdown` | `{sessionId, raceId, raceName, map, at, greenAt, countdownS, orderedBy?, grid: [racer]}` |
| `RaceGreenLight` | `{sessionId, raceId, raceName, map, at, greenAt, laps, racers: [racer]}` |
| `RacerLap` | `{sessionId, raceId, raceName, map, at, racer, lap, lapMs, sectorsMs, raceMs, bestLap, position}` |
| `RacerFinished` | `{sessionId, raceId, raceName, map, at, racer, finishOrder, raceMs, totalMs, laps, newPB, newRecord}` |
| `RacerOut` | `{sessionId, raceId, raceName, map, at, racer, reason, laps}` |
| `RaceClosed` | `{sessionId, raceId, raceName, map, at, state}` |

**`LeaderboardChanged`** carries the race's whole board, so you can replace your copy of that
board. `change.kind` is:
- `"pb"`: a new personal best.
- `"restored"`: staff disqualified a run, and the time it had replaced came back. A leaderboard
  can get worse, not only better.

**`RacesChanged`** means a map's races were added, edited, deleted or imported. **Editing a race
clears its times.** Fetch the map again (`races.leaderboards`).

**`RaceFinished`** is `{sessionId, raceId, raceName, map, laps, at, greenAt, results}`. Results
come in finishing order. Each result is
`{position, id, name, identity, vehicle, finished, disqualified, totalMs, bestLapMs, penaltyMs, newPB, newRecord, leaderboardRank, laps, bestSectorsMs}`.
Racers who didn't finish, or were disqualified, come last and have no `position`.

**Laps and sectors**: `laps` is `[{lap, timeMs, sectorsMs}]`, every lap the racer completed ;
`sectorsMs` lists that lap's sector times in order (the race's own sectors, as its creator set
them) ; `bestSectorsMs` is the racer's best time in each sector.

**`RaceCountdown`** gives the grid in order (`gridPosition` 1 first) and `greenAt`, when the lights
go green (BeamJoy's clients start on that moment themselves). `orderedBy` names the plugin whose
order it is, if one gave it. **`RaceGreenLight`** follows when the race starts.

**`RacerLap`** fires for every lap, the last one included (then `RacerFinished`). `raceMs` is the
racer's race time so far ; `position` their place in the standings right then.

**`RacerFinished`**: `totalMs` is `raceMs` plus any time penalties ; the standings go by it.

**`RacerOut`**: `reason` is `"retired"` (they retired, or BeamJoy retired them for not moving),
`"disconnected"` (they left and didn't come back in time) or `"disqualified"` (by staff ; also
sent for a racer who had already finished).

**`RaceClosed`** means a session ended without a result: the lobby was cancelled, everyone left,
or nobody was ready in time. `state` is where it was. A finished race sends `RaceFinished` instead.

**`EnvironmentChanged`**: `by` lists who changed it since the last one (player names,
`"plugin:<name>"`, or `"server"` for BeamJoy itself, e.g. on a map change). It isn't sent for the
clock simply moving on.

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
| `raceReady` | a racer readies up in a lobby (the leader's "Start now" too) | `{session, racer}` ; `racer.vehicle` is what they're in, `racer.leaderboardMs` their time on this race | `{allow = false, reason = "..."}` refuses ; anything else allows |
| `gridOrder` | the grid is about to be placed (2 racers or more) | `{session, racers, defaultOrder}` ; each racer has `leaderboardMs` and `joinIndex` ; `defaultOrder` is the player IDs in BeamJoy's own order | `{order = {playerId, ...}}` first on the grid first ; nothing keeps BeamJoy's order |

- **`raceReady`**: the racer shows "Checking…" while plugins are asked. A refusal shows them the
  reason in the lobby, and as a message. When several plugins answer, the first to refuse (in
  the order they registered) gives the reason.
- **`gridOrder`**: the lobby is held while plugins are asked (nobody joins, nobody's ready state
  changes). Racers your order leaves out start behind, in BeamJoy's order. When several plugins
  answer, the first order given wins. `race.setGridOrder` is used when no answer gives one.

```lua
BJ.hook("raceReady", function(q)
    if not q.racer.vehicle:find("Pessima", 1, true) then
        return { allow = false, reason = "Pessima only tonight" }
    end
    return { allow = true }
end)
```

## Overlays

`overlay.show {id, layout?, players?, position?, hides?, durationS?, ...}` shows an overlay, or
replaces the one you showed with the same `id`. `overlay.hide {id, players?}` takes it down (for
those players only, when given) ; `overlay.clear {}` takes all of yours down.

- `id`: your own name for it (letters, digits, `_ - .`). A plugin can show 8 at once.
- `players`: player IDs ; everyone when left out (players who join later too).
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
| `rows` | up to 30 `{pos?, name, value?, playerId?, you?, out?, flag?, pen?, color?}` standings ; the player whose `playerId` it is sees their row highlighted |
| `footer` | `{label, name?, value?}` (fastest lap) |

**`layout = "custom"`**: your own blocks, top to bottom: `{width? (em, 8 to 40), background?,
accent?, blocks}`. Up to 40 blocks:

| Block | |
|---|---|
| `{type = "text", text, size?, color?, align?, bold?, italic?, display?}` | `size` `"s"`, `"m"`, `"l"`, `"xl"` ; `display` uses the race HUD's numbers font |
| `{type = "row", cells}` | up to 6 cells side by side: text, or `{text, color?, align?, bold?, grow?, size?}` |
| `{type = "timer", mode, ms, size?, color?, align?}` | a timer |
| `{type = "plate", text, sub?, color?}` | a position plate |
| `{type = "bar", value, color?}` | 0 to 1 |
| `{type = "segments", items}` | like the default layout's |
| `{type = "table", columns?, rows}` | `columns` up to 6 `{label, align?}` ; `rows` up to 30 `{cells, playerId?, you?, color?}` |
| `{type = "divider"}` | a line |

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
  as "ready".
