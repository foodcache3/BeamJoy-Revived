--- Hunter arena definitions (static, per-map): a map holds a LIST of arenas, each carrying its
--- own id and name, the same shape services/derby.lua already uses (and races' array-of-many).
--- Owns only the STATIC config ; services/hunterGrid.lua owns live round instances, exactly
--- mirroring the races.lua / raceGrid.lua split.
---
--- This was one arena per map until server build 2504, stored as a single object. `normalizeList`
--- reads that shape back as a one-entry list (named DEFAULT_NAME), and the first save of any
--- arena on that map writes the file out as a list : nothing has to be migrated by hand, and an
--- untouched map keeps working off its old file until then.

---@alias BJHunterStationRoles "both"|"hunted"|"hunters"|"none" which side of a hunt a station
---interaction is allowed for ; see BJHunterDefaults.stationRefuelRoles/stationRepairRoles

---@class BJHunterSpawn
---@field pos {x: number, y: number, z: number}
---@field dir {x: number, y: number, z: number} matches BJRaceGate.dir's convention (plain direction
---vector, not a quaternion)

---@class BJHunterWaypoint
---@field pos {x: number, y: number, z: number}
---@field radius number trigger radius, meters

---@class BJHunterDefaults host-configurable at hunt-start time, same override->default->fallback
---resolution pattern services/raceGrid.lua's buildSettings already established for races
---@field waypointCount integer? how many of the arena's stored waypoint pool are actually sampled
---for a given round (see hunterGrid.lua's pickWaypointRoute, ported from BJI's own "farthest half
---of what's left, then random" selection) ; default 5, clamped [2, #arena.waypoints]
---@field huntedStuckTimeout integer? seconds the fugitive may remain within huntedStuckDistance of
---their own last-recorded position before being auto-eliminated ; default 10. Ported from BJI's own
---design, but actually wired through end-to-end this time: BJI's own admin slider for this never
---reached its own client at all (see the plan's "improvements over BJI")
---@field huntedStuckDistance number? meters of movement needed to reset the stuck timer ; default .5
---@field huntedStartDelay integer? seconds before the fugitive unfreezes at HUNT start ; default 0
---@field huntersStartDelay integer? seconds before hunters unfreeze at HUNT start (the fugitive's
---built-in head start) ; default 5
---@field huntersRespawnDelay integer? seconds a hunter is frozen + camera-locked to external view
---after crashing/resetting ; default 10
---@field revealProximityDistance number? meters ; any hunter within this distance of the fugitive
---reveals them (nametag + minimap + live GPS ping) for everyone, until every hunter is farther away
---again ; default 500, clamped [10, 2500] in increments of 50
---@field revealResetDuration integer? seconds the fugitive is revealed for after their own crash/
---reset ; default 5
---@field revealOnFinalWaypoint boolean? once the fugitive reaches their second-to-last waypoint,
---reveal turns on permanently for the rest of the round (a "final stretch" tension mechanic) ;
---default true
---@field gpsOnReveal boolean? when true, every hunter's own native GPS automatically points at the
---fugitive's live position for as long as they're revealed (any trigger - proximity, final
---waypoint, or post-reset), and clears the instant the reveal ends ; default false, since this is a
---significant tracking aid on top of the nametag/minimap reveal itself
---@field huntedResetDistanceThreshold number? meters ; the fugitive cannot reset/recover their own
---vehicle while any hunter is within this distance (0 = never allowed to reset at all) ; default 150
---@field velocityGatedResets boolean? opt-in, matching Infected's own always-on speed gate
---(RESET_MAX_SPEED in infectedRunner.lua): when true, EVERY reset/recover type (recover_vehicle,
---recover_vehicle_alt, recover_to_last_road, reset_physics, reset_all_physics) is blocked outright
---for whichever role is resetting while that participant's own vehicle is moving faster than
---hunterRunner.lua's RESET_MAX_SPEED, for both hunter and hunted alike. Applies ON TOP OF the
---existing distance gate (hunted) and respawn-delay penalty (hunters) below, not instead of either
---; default false, since (unlike Infected, which never had a plain "always allowed" reset in the
---first place) this changes hunters' own long-standing "reset freely, just pay the delay" behavior
---for anyone who turns it on
---@field allowStations boolean? when true, freeroam energy stations and garages (BJS-placed AND
---the map's own gas stations) stay usable during a hunt. Default false : a hunt otherwise hides
---their markers and refuses refuel/repair
---@field stationRefuelRoles BJHunterStationRoles? which role may refuel at a station once
---`allowStations` is on. Default "both", exactly what that toggle did on its own
---@field stationRepairRoles BJHunterStationRoles? which role may repair at a garage once
---`allowStations` is on (direct request : a hunt where only the fugitive gets to patch itself up,
---or only the hunters do, is a different game from one where both can). Default "both" - the same
---behaviour `allowStations` had before this existed - and "none" leaves refuelling working while
---refusing repairs outright
---@field huntedVehiclePresetId integer? optional BJVehiclePreset id restricting which vehicle the
---fugitive may spawn in (see services/vehiclePresets.lua) ; nil = free choice
---@field huntersVehiclePresetId integer? optional BJVehiclePreset id restricting hunter vehicles ;
---nil = free choice
---@field gridTimeout integer? seconds, hard deadline where anyone still unready is dropped and the
---hunt starts (or the lobby closes) regardless ; default 180
---@field gridReadyTimeout integer? seconds, floor on lobby duration even once everyone's ready ;
---default 10
---@field countdown integer? seconds ; default 10
---@field vehicleConfirmTimeout integer? seconds, hard ceiling on how long the pre-hunt countdown
---waits for every participant to confirm a vehicle matching their freshly-drawn role before starting
---anyway regardless of who hasn't ; default 20. See hunterGrid.lua's own startCountdownTimer /
---hunterVehicleConfirmed for why this gate exists (a mismatched pick can only be known once roles
---are committed at COUNTDOWN start, so the countdown itself now waits for confirmation instead of
---running while a player is still mid-reselect)
---@field randomizeVehiclePool boolean? when a vehicle-pool restriction is set for a role
---(huntedVehiclePresetId/huntersVehiclePresetId), automatically force-spawns each participant a
---random entry from their own resolved pool instead of steering them to the native vehicle selector
---to pick one themselves ; applied client-side the moment the pool actually resolves for that
---participant (hunt start, once roles are drawn; see hunterRunner.lua's COUNTDOWN handling) ;
---default false
---@field respawnPenaltyIncrement number? seconds added to huntersRespawnDelay per reset a hunter has
---already taken THIS hunt, escalating every crash : penalty = huntersRespawnDelay +
---respawnPenaltyIncrement * hunterResetCount (1-based, so the very first reset already gets one
---increment's worth) ; default 0 (no escalation, flat huntersRespawnDelay every time, matching the
---original behavior)
---@field hunterRespawnStrategy ("free"|"nearestSpawn"|"hubs")? where a hunter's own vehicle is placed
---once their crash/reset penalty resolves (independent of whether huntersRespawnDelay/
---respawnPenaltyIncrement even amount to a real delay) ; "free" leaves it wherever it recovered/
---reset, "nearestSpawn" (default) teleports to the closest entry in arena.hunterSpawns, preferring
---one that's also outside the fugitive's own huntedResetDistanceThreshold if any qualify, so
---respawning a hunter doesn't just extend the fugitive's own reset-lock the instant they reappear
---nearby (falls back to the plain closest spawn if none clear that distance) ; "hubs" teleports to
---the closest entry in arena.respawnHubs instead (falling back to hunterSpawns if none are
---configured for the current arena, with no "clear of the fugitive" preference applied there)
---@field hunterNametagFadeDistance number? meters ; a hunter's own nametag fades out (to fully
---invisible) as the viewer's distance to them grows toward this value, applied on top of (not
---instead of) the viewer's own generic client-side nametag-fade setting; see nametags.lua's
---drawNametag. 0 (default) disables this entirely : a hunter's nametag renders exactly like any
---other vehicle's, with no Hunter-specific distance limit
---@field winCondition ("waypoints"|"timed")? "waypoints" (default) : the fugitive wins by reaching
---every waypoint in the round's route, same as originally built. "timed" : no waypoint route at all;
---the fugitive simply has to survive uncaught for timedModeDuration minutes, at which point the
---hunt ends as a fugitive win regardless of position ; hunters still win immediately the instant the
---fugitive is actually caught (stuck-timer elimination), exactly as before
---@field timedModeDuration integer? minutes hunters have to catch the fugitive before they
---automatically win by survival, when winCondition == "timed" ; default 10, clamped [1, 120]

---@class BJHunterArena
---@field id integer unique on its map
---@field name string
---@field enabled boolean
---@field hunterSpawns BJHunterSpawn[]
---@field preySpawns BJHunterSpawn[]
---@field waypoints BJHunterWaypoint[]
---@field respawnHubs BJHunterSpawn[] optional, separate from hunterSpawns: a garage/police-station
---style set of respawn points, only ever used when hunterRespawnStrategy == "hubs"
---@field defaults BJHunterDefaults

local M = {
    dependencies = { "dao_activity", "dao_bundled", "services_core", "services_vehiclePresets" },

    ACTIVITY_TYPE = "hunter",

    -- deliberately not "5 hunter spawns" like BJI's own minimum: this fork's own join-time
    -- capacity cap (see hunterGrid.lua's hunterJoin) makes the hunter-spawn count the actual, real
    -- lobby capacity rather than an arbitrary editor minimum, so 2 is enough to make the mode
    -- functionally meaningful (at least 1 hunter can join alongside the fugitive) without forcing
    -- an arena author to place spawns they don't have room/desire for yet
    MIN_HUNTER_SPAWNS = 2,
    MIN_PREY_SPAWNS = 2,
    MIN_WAYPOINTS = 2,
    NAME_MAX = 40,
    --- what the one arena a map used to have is called once it's one of several, and what BJI's
    --- own single imported arena is called : re-importing or re-reading it finds the same arena
    --- again instead of making another one
    DEFAULT_NAME = "Main arena",

    ---@type BJHunterArena[] the current map's arenas
    data = {},
}

--- one of the four station-role values, anything else (including nil, and anything a raw request
--- invents) falling back to "both" : that's what `allowStations` on its own always meant, so an
--- arena saved before these existed keeps behaving exactly as it did
---@param value any
---@return BJHunterStationRoles
local function sanitizeStationRoles(value)
    if value == "hunted" or value == "hunters" or value == "none" then return value end
    return "both"
end

---@param arena BJHunterArena
---@return string? error
local function sanitizeArena(arena)
    if not table.isArray(arena.hunterSpawns) then arena.hunterSpawns = {} end
    if not table.isArray(arena.preySpawns) then arena.preySpawns = {} end
    if not table.isArray(arena.waypoints) then arena.waypoints = {} end
    if not table.isArray(arena.respawnHubs) then arena.respawnHubs = {} end

    if table.any(arena.hunterSpawns, function(s)
            return type(s.pos) ~= "table" or type(s.dir) ~= "table"
        end) then
        return "Invalid hunter spawn data"
    elseif table.any(arena.preySpawns, function(s)
            return type(s.pos) ~= "table" or type(s.dir) ~= "table"
        end) then
        return "Invalid prey spawn data"
    elseif table.any(arena.waypoints, function(w)
            return type(w.pos) ~= "table" or type(w.radius) ~= "number" or w.radius <= 0
        end) then
        return "Invalid waypoint data"
    elseif table.any(arena.respawnHubs, function(s)
            return type(s.pos) ~= "table" or type(s.dir) ~= "table"
        end) then
        return "Invalid respawn hub data"
    end

    -- placed props (services/props.lua), spawned by each client for the arena's games
    local props, propsErr = services_props.sanitize(arena.props, "An arena")
    if not props then return propsErr end
    arena.props = props

    arena.name = type(arena.name) == "string" and arena.name:trim() or ""
    if #arena.name > M.NAME_MAX then arena.name = arena.name:sub(1, M.NAME_MAX) end
    if #arena.name == 0 then return "The arena needs a name" end

    arena.enabled = arena.enabled == true
    if arena.enabled and (#arena.hunterSpawns < M.MIN_HUNTER_SPAWNS or
            #arena.preySpawns < M.MIN_PREY_SPAWNS or #arena.waypoints < M.MIN_WAYPOINTS) then
        return string.format(
            "Enabling requires at least %d hunter spawns, %d prey spawns, and %d waypoints",
            M.MIN_HUNTER_SPAWNS, M.MIN_PREY_SPAWNS, M.MIN_WAYPOINTS)
    end

    arena.defaults = arena.defaults or {}
    arena.defaults.waypointCount = math.max(2, math.min(
        math.floor(tonumber(arena.defaults.waypointCount) or 5), math.max(2, #arena.waypoints)))
    arena.defaults.huntedStuckTimeout = math.max(3, tonumber(arena.defaults.huntedStuckTimeout) or 10)
    arena.defaults.huntedStuckDistance = math.max(.1, tonumber(arena.defaults.huntedStuckDistance) or .5)
    arena.defaults.huntedStartDelay = math.max(0, tonumber(arena.defaults.huntedStartDelay) or 0)
    arena.defaults.huntersStartDelay = math.max(0, tonumber(arena.defaults.huntersStartDelay) or 5)
    arena.defaults.huntersRespawnDelay = math.max(0, tonumber(arena.defaults.huntersRespawnDelay) or 10)
    -- Real bug: the Config UI's bj-slider only enforces "increments of 50m" (per its own tooltip)
    -- as a client-side widget behavior while actively dragging/typing in it; nothing server-side
    -- ever rounds the stored value, so anything saved before that widget behavior existed, or set
    -- by any other path, keeps whatever precision it already had, silently, forever. Also, unlike
    -- every other field here, this one previously had NO upper clamp at all server-side - a value
    -- typed past the slider's own hard-max (a client-only widget limit, easily bypassed by sending
    -- a raw request) would be accepted and stored as-is, unbounded.
    arena.defaults.revealProximityDistance = math.clamp(
        math.round((tonumber(arena.defaults.revealProximityDistance) or 500) / 50) * 50, 10, 2500)
    arena.defaults.revealResetDuration = math.max(0, tonumber(arena.defaults.revealResetDuration) or 5)
    arena.defaults.revealOnFinalWaypoint = arena.defaults.revealOnFinalWaypoint ~= false
    arena.defaults.gpsOnReveal = arena.defaults.gpsOnReveal == true
    -- same "Increments of 10m" tooltip promise as revealProximityDistance above, same gap
    arena.defaults.huntedResetDistanceThreshold = math.max(0,
        math.round((tonumber(arena.defaults.huntedResetDistanceThreshold) or 150) / 10) * 10)
    arena.defaults.velocityGatedResets = arena.defaults.velocityGatedResets == true
    arena.defaults.allowStations = arena.defaults.allowStations == true
    arena.defaults.stationRefuelRoles = sanitizeStationRoles(arena.defaults.stationRefuelRoles)
    arena.defaults.stationRepairRoles = sanitizeStationRoles(arena.defaults.stationRepairRoles)
    if arena.defaults.huntedVehiclePresetId ~= nil then
        arena.defaults.huntedVehiclePresetId = tonumber(arena.defaults.huntedVehiclePresetId)
        if not arena.defaults.huntedVehiclePresetId or
            not services_vehiclePresets.getById(arena.defaults.huntedVehiclePresetId) then
            arena.defaults.huntedVehiclePresetId = nil
        end
    end
    if arena.defaults.huntersVehiclePresetId ~= nil then
        arena.defaults.huntersVehiclePresetId = tonumber(arena.defaults.huntersVehiclePresetId)
        if not arena.defaults.huntersVehiclePresetId or
            not services_vehiclePresets.getById(arena.defaults.huntersVehiclePresetId) then
            arena.defaults.huntersVehiclePresetId = nil
        end
    end
    arena.defaults.gridTimeout = math.max(10, tonumber(arena.defaults.gridTimeout) or 180)
    arena.defaults.gridReadyTimeout = math.max(0, tonumber(arena.defaults.gridReadyTimeout) or 10)
    arena.defaults.countdown = math.clamp(tonumber(arena.defaults.countdown) or 10, 0, 600)
    arena.defaults.vehicleConfirmTimeout = math.max(3, tonumber(arena.defaults.vehicleConfirmTimeout) or 20)
    arena.defaults.randomizeVehiclePool = arena.defaults.randomizeVehiclePool == true
    arena.defaults.respawnPenaltyIncrement = math.max(0, tonumber(arena.defaults.respawnPenaltyIncrement) or 0)
    -- must check "free" too, not just the other two: otherwise an author's own EXPLICIT choice
    -- of "free" would get silently overwritten by the fallback below on every save, since "free" is
    -- neither "nearestSpawn" nor "hubs" either
    if arena.defaults.hunterRespawnStrategy ~= "free" and arena.defaults.hunterRespawnStrategy ~= "nearestSpawn"
        and arena.defaults.hunterRespawnStrategy ~= "hubs" then
        arena.defaults.hunterRespawnStrategy = "nearestSpawn"
    end
    -- same "Increments of 10m" tooltip promise as revealProximityDistance above, same gap
    arena.defaults.hunterNametagFadeDistance = math.max(0,
        math.round((tonumber(arena.defaults.hunterNametagFadeDistance) or 0) / 10) * 10)
    if arena.defaults.winCondition ~= "waypoints" and arena.defaults.winCondition ~= "timed" then
        arena.defaults.winCondition = "waypoints"
    end
    arena.defaults.timedModeDuration = math.max(1, math.min(120, tonumber(arena.defaults.timedModeDuration) or 10))
end

--- a stored file's contents as a list of valid, uniquely-identified arenas. Mirrors derby.lua's
--- own normalizeList, with one extra job : the single object a hunter file held before several
--- arenas per map existed reads back as that map's first arena.
---@param stored any
---@return BJHunterArena[]
local function normalizeList(stored)
    local list = stored
    if type(stored) == "table" and not table.isArray(stored) then list = { stored } end
    if not table.isArray(list) then return {} end
    local out, usedIds = {}, {}
    for _, arena in ipairs(list) do
        if type(arena) == "table" then
            -- the old single arena had no name of its own : it gets the one the editor and the
            -- importer both use, so there is exactly one "Main arena" per map however it got there
            if type(arena.name) ~= "string" or #arena.name:trim() == 0 then arena.name = M.DEFAULT_NAME end
            -- a hand-edited or otherwise corrupted file can claim enabled=true under the real
            -- minimums. sanitizeArena REFUSES that outright, which here would drop the arena from
            -- the list altogether, so the claim is cleared first and the arena survives as a
            -- disabled one : exactly what loadData used to do by hand before this was a list
            if arena.enabled == true and (
                    #(arena.hunterSpawns or {}) < M.MIN_HUNTER_SPAWNS or
                    #(arena.preySpawns or {}) < M.MIN_PREY_SPAWNS or
                    #(arena.waypoints or {}) < M.MIN_WAYPOINTS) then
                arena.enabled = false
            end
            if not sanitizeArena(arena) then
                local id = math.floor(tonumber(arena.id) or 0)
                if id < 1 or usedIds[id] then id = 0 end
                arena.id = id
                table.insert(out, arena)
                if id > 0 then usedIds[id] = true end
            end
        end
    end
    -- anything without a usable id gets a fresh one
    local nextId = 1
    for id in pairs(usedIds) do nextId = math.max(nextId, id + 1) end
    for _, arena in ipairs(out) do
        if arena.id == 0 then
            arena.id = nextId
            nextId = nextId + 1
        end
    end
    return out
end

---@param list BJHunterArena[]
---@return integer
local function nextIdOf(list)
    local id = 0
    for _, a in ipairs(list) do id = math.max(id, a.id or 0) end
    return id + 1
end

local function pushCacheToAll()
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

--- load the current map's arenas, called on boot and on map change
local function loadData()
    M.data = normalizeList(dao_activity.get(services_core.getCurrentMap(), M.ACTIVITY_TYPE))
    pushCacheToAll()
end

local function saveData()
    dao_activity.save(services_core.getCurrentMap(), M.ACTIVITY_TYPE, M.data)
end

--- the mod's own bundled arenas (bundledContent/activities/<map>_hunter.json, one object or a
--- list of them), each seeded into a map's live data once, ever (dao_bundled's ledger, keyed by
--- the arena's name exactly as derby.lua's own seeding is) : an arena an admin deleted doesn't
--- come back, and one with the same name as an existing arena is skipped.
---
--- Before several arenas per map, this ledger held one marker per map, keyed "arena", set on the
--- one and only pass a map ever got. That marker still counts : a map carrying it has already had
--- its chance, so every bundled name there is marked without seeding anything. Otherwise an
--- arena a server's admin deleted years ago would reappear the first boot after this update.
local function seedBundledHunterArenas()
    for _, mapName in ipairs(dao_bundled.listMapsForType(M.ACTIVITY_TYPE)) do
        local bundled = dao_bundled.get(mapName, M.ACTIVITY_TYPE)
        if type(bundled) == "table" and not table.isArray(bundled) then bundled = { bundled } end
        if table.isArray(bundled) then
            local consideredBefore = dao_bundled.isSeeded(mapName, M.ACTIVITY_TYPE, "arena")
            local live = normalizeList(dao_activity.get(mapName, M.ACTIVITY_TYPE))
            local changed = false
            for _, raw in ipairs(bundled) do
                local name = type(raw) == "table" and raw.name or M.DEFAULT_NAME
                if type(name) == "string" and not dao_bundled.isSeeded(mapName, M.ACTIVITY_TYPE, name) then
                    local exists = table.any(live, function(a) return a.name == name end)
                    if consideredBefore then
                        LogInfo(string.format(
                            "seedBundledHunterArenas: skipped %s / %s, this map was seeded before",
                            mapName, name))
                    elseif not exists then
                        local candidate = table.deepcopy(raw)
                        candidate.name = name
                        local err = sanitizeArena(candidate)
                        if err then
                            LogError(string.format("seedBundledHunterArenas: %s / %s failed sanitation: %s",
                                mapName, name, err))
                        else
                            candidate.id = nextIdOf(live)
                            table.insert(live, candidate)
                            changed = true
                            LogInfo(string.format("seedBundledHunterArenas: seeded %s / %s", mapName, name))
                        end
                    end
                    dao_bundled.markSeeded(mapName, M.ACTIVITY_TYPE, name)
                end
            end
            if changed then dao_activity.save(mapName, M.ACTIVITY_TYPE, live) end
        end
    end
end

---@param caches table
local function onBJRequestCache(caches)
    -- visible to every player, not staff-gated : same reasoning as races.lua's own cache (meant to
    -- be played, not just administered)
    caches.hunterArenas = M.data
end

---@param id any
---@return BJHunterArena?, integer? its index in M.data
local function getArena(id)
    id = tonumber(id)
    for i, a in ipairs(M.data) do
        if a.id == id then return a, i end
    end
    return nil, nil
end

--- an arena a hunt can start on right now
---@param arena BJHunterArena?
---@return boolean
local function isPlayable(arena)
    return arena ~= nil and arena.enabled == true and
        #(arena.hunterSpawns or {}) >= M.MIN_HUNTER_SPAWNS and
        #(arena.preySpawns or {}) >= M.MIN_PREY_SPAWNS and
        #(arena.waypoints or {}) >= M.MIN_WAYPOINTS
end

--- the first arena a hunt could start on : what a client with no arena of its own in mind gets
---@return BJHunterArena?
local function firstPlayable()
    for _, a in ipairs(M.data) do
        if isPlayable(a) then return a end
    end
    return nil
end

--- saves one arena : an existing one (by id) is replaced, one without an id is added. Always
--- answers "hunterArenaSaved" (ok, error, id) so the editor can resync on a refusal
---@param ctxt BJSContext
---@param arena BJHunterArena
local function hunterArenaSave(ctxt, arena)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditHunterArenas) then
        local permErr = services_lang.get("error.insufficientPermissions", ctxt.sender.lang)
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", permErr)
        -- Real bug (same one infected.lua's own infectedArenaSave had): this used to return here
        -- with no "hunterArenaSaved" response at all, so the editor's one-use handler for it just
        -- expired silently 5s later (see communications.lua's own addOneUseHandler : a timed-out
        -- handler is dropped, never called with a failure value) - the editor kept showing
        -- whatever unsaved edit the player just tried to make forever, with no indication the
        -- server never actually accepted it. Always answering explicitly lets onSave resync the
        -- editor back to the real, still-untouched server data instead.
        return communications_tx.sendToPlayer(ctxt.senderID, "hunterArenaSaved", false, permErr)
    end

    local err = sanitizeArena(arena)
    local name = type(arena) == "table" and arena.name or nil
    if not err and table.any(M.data, function(a) return a.name == name and a.id ~= tonumber(arena.id) end) then
        err = "Another arena on this map already has that name"
    end
    if err then
        LogError(string.format("hunterArenaSave rejected%s: %s",
            ctxt.sender and (" from " .. ctxt.sender.playerName) or "", err))
        dump(arena)
        if ctxt.sender then
            communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
            return communications_tx.sendToPlayer(ctxt.senderID, "hunterArenaSaved", false, err)
        end
        return
    end

    local _, index = getArena(arena.id)
    if index then
        M.data[index] = arena
    else
        arena.id = nextIdOf(M.data)
        table.insert(M.data, arena)
    end
    saveData()

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "hunterArenaSaved", true, "", arena.id)
    end

    pushCacheToAll()
end

---@param ctxt BJSContext
---@param id integer
local function hunterArenaDelete(ctxt, id)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditHunterArenas) then
        local permErr = services_lang.get("error.insufficientPermissions", ctxt.sender.lang)
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", permErr)
        return communications_tx.sendToPlayer(ctxt.senderID, "hunterArenaDeleted", false, permErr)
    end
    local _, index = getArena(id)
    if not index then return end
    table.remove(M.data, index)
    saveData()
    if ctxt.sender then communications_tx.sendToPlayer(ctxt.senderID, "hunterArenaDeleted", true) end
    pushCacheToAll()
end

--- Legacy BeamJoy Free (BJI) arena import: BJI stores one `<mapName>_hunter.json` file per map
--- under `<dbPath>/scenarii/`, shared with Infected (majorPositions/minorPositions are reused by
--- both modes there ; only `waypoints` is Hunter-exclusive). An admin migrating from BJI copies
--- that whole `scenarii` folder into this fork's own `BeamJoyData/db/` first: this only ever
--- reads it from there, never reaches outside this fork's own data folder. Per direct request,
--- this always operates on EVERY map found at once (no per-map picker); see the plan file's own
--- design notes for why. If/when a second mode (e.g. Infected) gets its own importer, extracting a
--- shared "scan legacy scenarii files for a given suffix" helper would make sense then ; not
--- worth it for a single consumer.
local LEGACY_DIR = "scenarii"

--- BeamNG's vehicle-local forward axis is +Y (X=right, Y=forward, Z=up), confirmed by reading how
--- BJI itself captures/applies this same value (`ctxt.veh.rotation`, the vehicle's own raw native
--- rotation quaternion, passed straight through to `veh:setPosRot` with no correction anywhere in
--- that whole path) ; standard quaternion-rotate-vector formula applied to that local forward axis.
---
--- Uses the CONJUGATE of the stored quaternion, not the raw value: a real, since-fixed bug here
--- used the raw quat directly, which produced a graduated error (correct near one heading, up to
--- ~180 degrees off near a perpendicular one) rather than a uniform offset : that specific "small
--- error near 0/180 degrees of actual rotation, large error near 90/270" pattern is the textbook
--- signature of a quaternion-handedness mismatch (rotating by q instead of by its inverse q^-1),
--- since a wrongly-inverted rotation coincides with the correct one exactly at 0 and 180 degrees
--- and diverges most at 90 degrees. Negating the vector part (x,y,z, keeping w) is the standard
--- conjugate/inverse-rotation fix for exactly this symptom.
---
--- Local reference axis is -Y, not +Y, confirmed by live testing after the conjugate fix above:
--- that fix alone left every converted spawn a UNIFORM 180 degrees off (correct handedness, wrong
--- starting facing) rather than the earlier graduated error, and rotating the axis vector by 180
--- degrees flips every result by the same fixed amount (rotation is linear, so rotating -v gives
--- exactly -v' for the same quaternion). This is that correction, not a second independent bug.
---@param quat {x: number, y: number, z: number, w: number}
---@return {x: number, y: number, z: number} flat horizontal direction, matching BJHunterSpawn.dir's
---own convention (z always 0, same flattening this fork's own gate/start rotate-drag already
---applies) ; a degenerate result (rotated to point straight up/down) falls back to a plain +X
---facing rather than a zero-length vector
local function quatToFlatDir(quat)
    local vx, vy, vz = 0, -1, 0
    local qx, qy, qz, qw = -(tonumber(quat.x) or 0), -(tonumber(quat.y) or 0), -(tonumber(quat.z) or 0),
        tonumber(quat.w) or 1
    local tx = 2 * (qy * vz - qz * vy)
    local ty = 2 * (qz * vx - qx * vz)
    local tz = 2 * (qx * vy - qy * vx)
    local rx = vx + qw * tx + (qy * tz - qz * ty)
    local ry = vy + qw * ty + (qz * tx - qx * tz)
    local len = math.sqrt(rx * rx + ry * ry)
    if len < 1e-4 then return { x = 1, y = 0, z = 0 } end
    return { x = rx / len, y = ry / len, z = 0 }
end

---@param entries {pos: {x:number,y:number,z:number}, rot: {x:number,y:number,z:number,w:number}}[]?
---@return BJHunterSpawn[]
local function convertLegacySpawns(entries)
    local result = {}
    if type(entries) == "table" then
        for _, e in ipairs(entries) do
            if type(e) == "table" and type(e.pos) == "table" then
                table.insert(result, {
                    pos = { x = tonumber(e.pos.x) or 0, y = tonumber(e.pos.y) or 0, z = tonumber(e.pos.z) or 0 },
                    dir = type(e.rot) == "table" and quatToFlatDir(e.rot) or { x = 1, y = 0, z = 0 },
                })
            end
        end
    end
    return result
end

---@param entries {pos: {x:number,y:number,z:number}, radius: number}[]?
---@return BJHunterWaypoint[]
local function convertLegacyWaypoints(entries)
    local result = {}
    if type(entries) == "table" then
        for _, e in ipairs(entries) do
            if type(e) == "table" and type(e.pos) == "table" and tonumber(e.radius) then
                table.insert(result, {
                    pos = { x = tonumber(e.pos.x) or 0, y = tonumber(e.pos.y) or 0, z = tonumber(e.pos.z) or 0 },
                    radius = tonumber(e.radius),
                })
            end
        end
    end
    return result
end

--- Infected-only fields (enabledInfected, and majorPositions/minorPositions when Infected is the
--- only mode that ever used them on a given map) are silently ignored: this only ever produces a
--- Hunter arena, never anything Infected-related.
---@param oldData table raw parsed <map>_hunter.json (BJI format)
---@return BJHunterArena?
local function convertLegacyArena(oldData)
    if type(oldData) ~= "table" then return nil end
    return {
        -- BJI has one arena per map and no name for it : DEFAULT_NAME, so a re-import replaces
        -- the arena it made last time (and the one a pre-2504 file migrated into) instead of
        -- stacking up copies of it
        name = M.DEFAULT_NAME,
        enabled = oldData.enabledHunter == true,
        hunterSpawns = convertLegacySpawns(oldData.majorPositions),
        preySpawns = convertLegacySpawns(oldData.minorPositions),
        waypoints = convertLegacyWaypoints(oldData.waypoints),
        defaults = {},
    }
end

---@return {map: string, hunterSpawnCount: integer, preySpawnCount: integer, waypointCount: integer, enabled: boolean, conflict: boolean}[]
local function scanLegacyArenas()
    local results = {}
    local dir = dao_main.dbPath .. "/" .. LEGACY_DIR
    if not FS.Exists(dir) then return results end
    for _, filename in pairs(FS.ListFiles(dir)) do
        local mapName = filename:match("^(.+)_hunter%.json$")
        if mapName then
            local raw = dao_main.get(LEGACY_DIR .. "/" .. filename)
            local converted = convertLegacyArena(raw)
            if converted and (#converted.hunterSpawns > 0 or #converted.preySpawns > 0 or
                    #converted.waypoints > 0) then
                -- a conflict is the arena this import would replace : the one already called
                -- DEFAULT_NAME on that map, whatever else is there
                local existing = table.find(normalizeList(dao_activity.get(mapName, M.ACTIVITY_TYPE)),
                    function(a) return a.name == M.DEFAULT_NAME end)
                local existingHasContent = existing ~= nil and (#(existing.hunterSpawns or {}) > 0 or
                    #(existing.preySpawns or {}) > 0 or #(existing.waypoints or {}) > 0)
                table.insert(results, {
                    key = mapName,
                    map = mapName,
                    name = M.DEFAULT_NAME,
                    hunterSpawnCount = #converted.hunterSpawns,
                    preySpawnCount = #converted.preySpawns,
                    waypointCount = #converted.waypoints,
                    enabled = converted.enabled,
                    conflict = existingHasContent,
                })
            end
        end
    end
    return results
end

---@param ctxt BJSContext
local function hunterLegacyImportPreview(ctxt)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditHunterArenas) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end
    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "hunterLegacyImportPreviewResult", scanLegacyArenas())
    end
end

---@param ctxt BJSContext
---@param selection string[]? the ticked maps ; nil = all
local function hunterLegacyImportConfirm(ctxt, selection)
    local picked = ImportSelection(selection)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditHunterArenas) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end

    local dir = dao_main.dbPath .. "/" .. LEGACY_DIR
    local imported, failed = 0, 0
    if FS.Exists(dir) then
        for _, filename in pairs(FS.ListFiles(dir)) do
            local mapName = filename:match("^(.+)_hunter%.json$")
            if mapName and (not picked or picked[mapName]) then
                local raw = dao_main.get(LEGACY_DIR .. "/" .. filename)
                local converted = convertLegacyArena(raw)
                if converted and (#converted.hunterSpawns > 0 or #converted.preySpawns > 0 or
                        #converted.waypoints > 0) then
                    local err = sanitizeArena(converted)
                    if err then
                        LogError(string.format("hunterLegacyImportConfirm: %s failed sanitation: %s",
                            mapName, err))
                        failed = failed + 1
                    else
                        -- the map's own arena called DEFAULT_NAME is replaced in place, keeping
                        -- its id (a lobby's arena reference stays valid) ; every other arena on
                        -- that map is left exactly as it is
                        local live = normalizeList(dao_activity.get(mapName, M.ACTIVITY_TYPE))
                        local existingIndex
                        for i, a in ipairs(live) do
                            if a.name == M.DEFAULT_NAME then existingIndex = i end
                        end
                        if existingIndex then
                            converted.id = live[existingIndex].id
                            live[existingIndex] = converted
                        else
                            converted.id = nextIdOf(live)
                            table.insert(live, converted)
                        end
                        dao_activity.save(mapName, M.ACTIVITY_TYPE, live)
                        imported = imported + 1
                        -- the currently-loaded map's own in-memory M.data (and every connected
                        -- client's cache of it) needs an explicit refresh: every OTHER map's file
                        -- was just written straight to disk with nothing in memory to update, since
                        -- services_hunter.lua only ever tracks the current map's own arenas
                        if mapName == services_core.getCurrentMap() then
                            M.data = live
                            pushCacheToAll()
                        end
                    end
                end
            end
        end
    end

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "hunterLegacyImportDone", imported, failed)
    end
end

local function onInit()
    communications_rx.addHandler("hunterArenaSave", M.hunterArenaSave)
    communications_rx.addHandler("hunterArenaDelete", M.hunterArenaDelete)
    communications_rx.addHandler("hunterLegacyImportPreview", M.hunterLegacyImportPreview)
    communications_rx.addHandler("hunterLegacyImportConfirm", M.hunterLegacyImportConfirm)
    seedBundledHunterArenas()
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData

M.getArena = getArena
M.isPlayable = isPlayable
M.firstPlayable = firstPlayable
M.hunterArenaSave = hunterArenaSave
M.hunterArenaDelete = hunterArenaDelete
M.hunterLegacyImportPreview = hunterLegacyImportPreview
M.hunterLegacyImportConfirm = hunterLegacyImportConfirm
-- exported for reuse by services/races.lua's own legacy importer: this quaternion-to-flat-
-- direction conversion is the same tricky, already-verified math (handedness bug found and fixed
-- once already, see its own comment) either importer needs for a genuine facing (start/spawn
-- positions), rather than risking a fresh re-derivation of the same fragile math a second time
M.quatToFlatDir = quatToFlatDir
M.sanitizeStationRoles = sanitizeStationRoles

return M
