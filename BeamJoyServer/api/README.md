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
- **Add to BeamJoy's windows**: sections of options in the race start menu and the race editor
  (a race class, league rules), labels on results and leaderboard entries (the class, points, a
  team), a tab of your plugin's settings in the config window, and pages of your own in the main
  window (a button on its side rail, a tab in the full window) with buttons and fields players
  use.

Typical uses: a website kept in sync with the leaderboards, a Discord bot, live timing, a
championship or league plugin, race classes, an entry list, a game mode of your own.

API version 1. Plugins can label leaderboard entries and results, but never change a time or a
result.

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

Two complete example plugins. To try one, copy its folder into `Resources/Server/`, next to
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

## Methods

Every `map` param is optional and defaults to the map the server is on. Another map's data is
read from BeamJoy's saved files.

Methods that change something (`race.*`, `environment.set`, `overlay.*`, `hud.message`, `hooks.*`,
`raceOptions.*`, `results.setFields`, `leaderboard.setFields`, `config.*`, `pages.*`) need your
plugin's name in the request's `from`. The helper always sends it.

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
placementMode, gridSlots, greenAt?, starter, racers: [racer]}`.

- `state` is `"GRID"` (the lobby), `"COUNTDOWN"`, `"RACE"` or `"FINISHED"`.
- `racers` come in standings order. Each racer is `{id, name, identity, away, vehicle, ready,
  readyChecking, readyBlock?, gridPosition?, position?, lap, finished, dnf, disqualified,
  penaltyMs?, bestLapMs?, fields}`.
- `options` is the plugins' [race options](#race-options) for this race: `{plugin: {option:
  value}}`, every option of every plugin running, filled in. Every race event carries it too.
- `fields` is the racer's [labels](#fields) (a list, maybe empty).
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

### `raceOptions.register` `{sections}` / `raceOptions.unregister`
Your sections of options in the race start menu and race editor (replacing any you registered
before). See [Race options](#race-options). → `{sections}`

### `results.setFields` `{sessionId, playerId, fields, replace?}`
Labels on a racer's result in a race being run, shown in the game's results and in the race
events. When that race already put their time on the leaderboard, the entry gets them too. See
[Fields](#fields). → `{sessionId, playerId}`

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

### `hud.message` `{text, color?, durationS?, players?}`
A line of text across BeamJoy's own HUD for a few seconds (default 5, 1 to 30). `players` is a
list of player IDs ; everyone when left out, nobody when empty (players connected now only).

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
| `ConfigChanged` | `{plugin, values, changed, by}` : a plugin's config tab was saved |
| `ConfigAction` | `{plugin, action, by: {id, name}}` : a button on a plugin's config tab was clicked |
| `PageOpened` | `{plugin, page, by: {id, name}}` : a player opened a plugin's [page](#pages) |
| `PageAction` | `{plugin, page, action, values, by: {id, name}}` : a button on a plugin's page was clicked |

Every race event (`RaceGridOpened` to `RaceClosed`) also carries `options`: the plugins' [race
options](#race-options) for that race.

**`LeaderboardChanged`** carries the race's whole board, so you can replace your copy of that
board. `change.kind` is:
- `"pb"`: a new personal best.
- `"restored"`: staff disqualified a run, and the time it had replaced came back. A leaderboard
  can get worse, not only better.
- `"fields"`: a plugin changed an entry's [labels](#fields) ; the times are as they were.

**`RacesChanged`** means a map's races were added, edited, deleted or imported. **Editing a race
clears its times.** Fetch the map again (`races.leaderboards`).

**`RaceFinished`** is `{sessionId, raceId, raceName, map, laps, at, greenAt, results}`. Results
come in finishing order. Each result is
`{position, id, name, identity, vehicle, finished, disqualified, totalMs, bestLapMs, penaltyMs, newPB, newRecord, leaderboardRank, fields, laps, bestSectorsMs}`.
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
- `where`: `"both"` (default), `"editor"` (set per race, the start menu can't change it) or
  `"start"` (chosen at each start only).
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
