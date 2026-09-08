--- Hunter arena definition (static, per-map): one arena per map, unlike races' array-of-many (see
--- the plan's own design decision : BJI's own model, kept simple rather than adding a name/browse-
--- list layer this mode doesn't need). Owns only the STATIC config ; services/hunterGrid.lua owns
--- live round instances, exactly mirroring the races.lua / raceGrid.lua split.

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
---again ; default 50
---@field revealResetDuration integer? seconds the fugitive is revealed for after their own crash/
---reset ; default 5
---@field revealOnFinalWaypoint boolean? once the fugitive reaches their second-to-last waypoint,
---reveal turns on permanently for the rest of the round (a "final stretch" tension mechanic) ;
---default true
---@field huntedResetDistanceThreshold number? meters ; the fugitive cannot reset/recover their own
---vehicle while any hunter is within this distance (0 = never allowed to reset at all) ; default 150
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

    ---@type BJHunterArena?
    data = nil,
}

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
    -- Real bug: the Config UI's bj-slider only enforces "increments of 10m" (per its own tooltip)
    -- as a client-side widget behavior while actively dragging/typing in it; nothing server-side
    -- ever rounds the stored value, so anything saved before that widget behavior existed, or set
    -- by any other path, keeps whatever precision it already had, silently, forever.
    arena.defaults.revealProximityDistance = math.max(10,
        math.round((tonumber(arena.defaults.revealProximityDistance) or 50) / 10) * 10)
    arena.defaults.revealResetDuration = math.max(0, tonumber(arena.defaults.revealResetDuration) or 5)
    arena.defaults.revealOnFinalWaypoint = arena.defaults.revealOnFinalWaypoint ~= false
    -- same "Increments of 10m" tooltip promise as revealProximityDistance above, same gap
    arena.defaults.huntedResetDistanceThreshold = math.max(0,
        math.round((tonumber(arena.defaults.huntedResetDistanceThreshold) or 150) / 10) * 10)
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

--- load the current map's arena, called on boot and on map change
local function loadData()
    M.data = dao_activity.get(services_core.getCurrentMap(), M.ACTIVITY_TYPE)
    if M.data and M.data.enabled and (#M.data.hunterSpawns < M.MIN_HUNTER_SPAWNS or
            #M.data.preySpawns < M.MIN_PREY_SPAWNS or #M.data.waypoints < M.MIN_WAYPOINTS) then
        -- same defensive backfill reasoning as races.lua's own loadData : sanitizeArena only ever
        -- runs at actual save time, never on load, so a hand-edited or otherwise-corrupted file
        -- could still claim enabled=true under the real minimums
        M.data.enabled = false
    end
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

local function saveData()
    dao_activity.save(services_core.getCurrentMap(), M.ACTIVITY_TYPE, M.data)
end

--- auto-imports this mod's own bundled default hunter arena for a map that doesn't have one
--- saved yet, per direct request (see races.lua's own seedBundledRaces and dao/bundled.lua's own
--- doc for the whole mechanism). Unlike races (an array, several per map), a map only ever has ONE
--- hunter arena, so there's no per-item name to dedupe by: only seeds a map that has genuinely
--- never had an arena saved at all (dao_activity.get returns nil), and only ever considers a given
--- map once (dao_bundled's own ledger, itemName fixed to "arena" since there's only ever the one),
--- so an admin explicitly clearing/disabling their own arena later never causes it to silently
--- come back.
local function seedBundledHunterArena()
    for _, mapName in ipairs(dao_bundled.listMapsForType(M.ACTIVITY_TYPE)) do
        if not dao_bundled.isSeeded(mapName, M.ACTIVITY_TYPE, "arena") then
            if dao_activity.get(mapName, M.ACTIVITY_TYPE) == nil then
                local bundled = dao_bundled.get(mapName, M.ACTIVITY_TYPE)
                if type(bundled) == "table" then
                    local candidate = table.deepcopy(bundled)
                    local err = sanitizeArena(candidate)
                    if err then
                        LogError(string.format(
                            "seedBundledHunterArena: %s failed sanitation: %s", mapName, err))
                    else
                        dao_activity.save(mapName, M.ACTIVITY_TYPE, candidate)
                        LogInfo(string.format("seedBundledHunterArena: seeded %s", mapName))
                    end
                end
            else
                LogInfo(string.format(
                    "seedBundledHunterArena: skipped %s, already has an arena", mapName))
            end
            -- marked regardless of outcome (map already had an arena, or a validation failure) :
            -- a map is only ever considered once, ever
            dao_bundled.markSeeded(mapName, M.ACTIVITY_TYPE, "arena")
        end
    end
end

---@param caches table
local function onBJRequestCache(caches)
    -- visible to every player, not staff-gated : same reasoning as races.lua's own cache (meant to
    -- be played, not just administered)
    caches.hunterArena = M.data
end

---@return BJHunterArena?
local function getArena()
    return M.data
end

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

    M.data = arena
    saveData()

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "hunterArenaSaved", true)
    end

    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
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
                local existing = dao_activity.get(mapName, M.ACTIVITY_TYPE)
                local existingHasContent = existing ~= nil and (#(existing.hunterSpawns or {}) > 0 or
                    #(existing.preySpawns or {}) > 0 or #(existing.waypoints or {}) > 0)
                table.insert(results, {
                    map = mapName,
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
local function hunterLegacyImportConfirm(ctxt)
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
            if mapName then
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
                        dao_activity.save(mapName, M.ACTIVITY_TYPE, converted)
                        imported = imported + 1
                        -- the currently-loaded map's own in-memory M.data (and every connected
                        -- client's cache of it) needs an explicit refresh: every OTHER map's file
                        -- was just written straight to disk with nothing in memory to update, since
                        -- services_hunter.lua only ever tracks the current map's own arena
                        if mapName == services_core.getCurrentMap() then
                            M.data = converted
                            services_players.players:forEach(function(p)
                                local caches = {}
                                M.onBJRequestCache(caches)
                                communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
                            end)
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
    communications_rx.addHandler("hunterLegacyImportPreview", M.hunterLegacyImportPreview)
    communications_rx.addHandler("hunterLegacyImportConfirm", M.hunterLegacyImportConfirm)
    seedBundledHunterArena()
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData

M.getArena = getArena
M.hunterArenaSave = hunterArenaSave
M.hunterLegacyImportPreview = hunterLegacyImportPreview
M.hunterLegacyImportConfirm = hunterLegacyImportConfirm
-- exported for reuse by services/races.lua's own legacy importer: this quaternion-to-flat-
-- direction conversion is the same tricky, already-verified math (handedness bug found and fixed
-- once already, see its own comment) either importer needs for a genuine facing (start/spawn
-- positions), rather than risking a fresh re-derivation of the same fragile math a second time
M.quatToFlatDir = quatToFlatDir

return M
