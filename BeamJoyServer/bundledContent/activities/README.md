# Bundled default activities

This folder ships as part of the mod package itself. On every server boot, `dao/bundled.lua`
mirrors its contents into `BeamJoyData/db/bundled/`, then `services/races.lua` and
`services/hunter.lua` each auto-import anything here that hasn't already been seeded into a given
map's live data before (tracked persistently, once per map/item, forever, see both files' own
`seedBundledRaces`/`seedBundledHunterArena` and `dao/bundled.lua`'s own doc comment for the full
mechanism).

This is intentionally separate from `BeamJoyData/db/activities/` (an admin's own live, editable
race/arena data): nothing here ever overwrites or removes anything an admin has already created,
edited, or deliberately deleted. A file added here in a later mod update is picked up automatically
on the next boot, no migration step, no admin action needed. Content only ever gets added TO a
server's live data, once, automatically, never modified or removed again after that.

## File naming

- `<mapName>_races.json`: a JSON array of race objects, for that one map.
- `<mapName>_hunter.json`: a single hunter arena object, for that one map. Unlike races, a map only
  ever has ONE hunter arena, so this only ever seeds a map that has genuinely never had an arena
  saved at all; it will never overwrite an admin's own arena, even a disabled/incomplete one.

`mapName` must exactly match the map's own folder name under `/levels/` (e.g. `west_coast_usa`,
`italy`, `utah`), same as `services_core.getCurrentMap()`'s own return value, and the same
convention `BeamJoyData/db/activities/` already uses.

## Schema

Same native shape this mod already saves to `BeamJoyData/db/activities/<mapName>_races.json` /
`<mapName>_hunter.json`, i.e. exactly what the in-game race/arena editor itself produces. The
easiest way to author a bundled entry is to build it normally in-game (Config > Races/Hunter Arena
editor) on the target map, then copy the relevant object(s) out of the resulting
`BeamJoyData/db/activities/<mapName>_....json` file on your own test server into this folder.

Do NOT include `id` or `leaderboard` on a bundled race, they're assigned automatically at seed
time, matching how a brand-new admin-authored race is handled. A race name colliding with one
that's already on the target map (admin-authored or previously seeded) is skipped, not overwritten.

No content is bundled yet, this folder just establishes the convention for future rounds.
