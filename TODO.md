# TODO / planned features

Ideas that have been discussed and design-approved but deliberately not started yet. Not a
backlog of every idea ever mentioned, just things worth picking up later without re-deriving the
design from scratch.

## Race share codes

**Status:** planned, not started. User wants this, but explicitly not right now.

Shareable text codes for a single race (and possibly Hunter arenas later), the same idea as a
CS2 crosshair code or an Arena Breakout loadout code, adapted to how much bigger race data
actually is.

### Design (agreed during planning discussion)

- **Format:** serialize the race using the exact same shape already produced/consumed internally
  (the flat `gates` array with index-based `parents`, not a new schema), round every float to 3
  decimal places (real-world precision loss is irrelevant for a gate trigger), gzip the compact
  JSON, then base64-encode the gzipped bytes into a single pasteable string. A short version
  prefix (e.g. `BJRACE1:`) in front so a future format change can be detected on import instead
  of failing confusingly.
- **Why gzip is not optional:** measured against real bundled race data (see below), gzip+base64
  is consistently ~3.5-4x smaller than base64 of the raw JSON. Skipping it makes anything but a
  trivial race impractical to paste.
- **Scope:** one race per code, not a whole map's worth (this fork's own native storage is
  already per-race, unlike the "whole map in one file" shape used internally for BJI import).
- **Export:** a button in Config > Races (and the race editor) that builds the code and copies it
  via `navigator.clipboard.writeText` (already used elsewhere in this Angular UI).
- **Import:** a "paste code" input that decodes/decompresses it and runs the result through the
  *existing* `sanitizeRace` validation (services/races.lua) before ever saving it, same as every
  other race-creation path already goes through. Never trust a pasted code blindly.
- **Validation of the approach:** measured real sizes from the actual bundled race data
  (`Server/BeamJoyServer/bundledContent/activities/*.json`), not guesses:

  | Encoding | Typical (~10 gates) | Big race (50 gates, real) | ~60 gates (extrapolated) |
  |---|---|---|---|
  | Raw plaintext JSON, full precision | ~4,000 chars | 10,000 chars | ~12,000 |
  | Raw base64, full precision | ~5,000 chars | 13,336 chars | ~16,000 |
  | Raw base64, floats rounded to 3dp | ~4,000 chars | 9,860 chars | ~11,800 |
  | **Rounded + gzip, then base64** | **~1,300 chars** | **2,724 chars** | **~3,200** |

  The 50-gate data point is a real bundled race ("Industrial Rally Stage Reverse",
  `industrial_races.json`), not extrapolated.

### Open questions for when this is actually picked up
- Whether to extend the same mechanism to Hunter arenas (`sanitizeArena`), or races only for v1.
- Whether the version prefix should also carry a schema/content hash for a friendlier "this code
  is corrupted" error vs. a generic parse failure.

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
