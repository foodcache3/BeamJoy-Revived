# BeamJoy plugin API

Lets your own BeamMP server plugins read BeamJoy's data: races, leaderboards, maps, online
players, time and weather. Your plugins also hear about events as they happen: a new best time,
a finished race, a map change. A typical use is keeping a website's leaderboards in sync, or
feeding a Discord bot.

**Read-only** for now (API version 1). Nothing here can change BeamJoy's data.

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
- `BJ.json`: the JSON encoder/decoder the helper uses (`BJ.json.stringify`, `BJ.json.parse`).

`example/BJLeaderboardExport/` is a complete plugin. It writes every map's leaderboards
(nicknamed players only) to `export/<map>.json` and rewrites them whenever a time changes. To try
it, copy that folder into `Resources/Server/`, next to `BeamJoyServer`, and restart the server.

## Methods

Every `map` param is optional and defaults to the map the server is on. Another map's data is
read from BeamJoy's saved files.

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

### `players.online`
→ `{players: [{id, name, displayName, nickname, guest, group, staff}]}`

- `name` is the BeamMP name.
- `nickname` is the BeamJoy nickname, if the player picked one.

### `environment.get`
→ `{timeOfDay, clock, timeSync, dayNightCycle, dayLengthS, date, simSpeed, simPause, gravity, gravitySync, weatherSync, weather}`

- `timeOfDay` uses the game's own scale: `0` is noon and `0.5` is midnight. `clock` is the same
  time as `"HH:MM"`.
- `weather` only appears while weather sync is on. It holds the weather panel's own fields.

### Leaderboard entries

`{rank, name, timeMs, model, date, identity}`

| Field | |
|---|---|
| `rank` | 1 is the fastest |
| `name` | the BeamJoy nickname if the player had picked one when they set the time, otherwise the BeamMP name |
| `timeMs` | best lap time, in milliseconds |
| `model` | the vehicle's model, like `"etk800"`, if known |
| `date` | Unix time, in seconds |
| `identity` | what `name` is (below) |

`identity` is one of:
- `"nickname"`: a BeamJoy nickname.
- `"beammp"`: a BeamMP account name.
- `"guest"`: a BeamMP guest name. These change every time the guest restarts their launcher.
- `"unknown"`: the time was saved before BeamJoy started recording this.

To show only nicknamed players, keep the `"nickname"` entries and number them again yourself.

Names are display names, not permanent IDs: a player can change their nickname.

### Errors

| `code` | When |
|---|---|
| `unknownMethod` | the method doesn't exist |
| `badParams` | a param is missing or invalid; `message` says which |
| `notFound` | the race doesn't exist |
| `internal` | something failed on BeamJoy's side (also logged in the server console) |
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

**`LeaderboardChanged`** carries the race's whole board, so you can replace your copy of that
board. `change.kind` is:
- `"pb"`: a new personal best.
- `"restored"`: staff disqualified a run, and the time it had replaced came back. A leaderboard
  can get worse, not only better.

**`RacesChanged`** means a map's races were added, edited, deleted or imported. **Editing a race
clears its times.** Fetch the map again (`races.leaderboards`).

**`RaceFinished`** results come in finishing order. Each result is
`{position, name, identity, vehicle, finished, disqualified, totalMs, bestLapMs, penaltyMs, newPB, newRecord, leaderboardRank}`.
Racers who didn't finish, or were disqualified, come last and have no `position`.

**`PlayerJoined`** fires before the player picks a nickname. Use `players.online` when you need
nicknames.

## Notes

- A plugin that keeps a copy of the data should do a full sync in `onReady`. Events sent while it
  wasn't running are lost.
- Every answer goes to every plugin, and the helper drops the ones that aren't yours. Big answers,
  like a whole map's leaderboards, are fine: plugins on one server exchange them in memory.
- Without the helper: fire `BJAPI_Request` with a JSON string, register `BJAPI_Response`, and
  match your `id`. BeamJoy sends `BJAPI_Ready` once it has loaded. If your plugin starts after
  BeamJoy, it won't see that event, so send `server.info` yourself at start and treat the answer
  as "ready".
