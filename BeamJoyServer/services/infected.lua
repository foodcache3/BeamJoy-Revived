--- Infected arena definition (static, per-map): one arena per map, exactly mirroring
--- services/hunter.lua's own split (services/infectedGrid.lua owns live round instances). Deliberately
--- close to a straight rename of hunter.lua's own arena module rather than a fresh design: Infected
--- and Hunter share almost identical bones (a lobby, a set of role-based spawn points, staff-editable
--- via the same in-world editor pattern), and BJI itself stores both modes' spawn data in the very
--- same per-map file (see the legacy importer below).

---@class BJInfectedSpawn
---@field pos {x: number, y: number, z: number}
---@field dir {x: number, y: number, z: number} matches BJRaceGate.dir's convention (plain direction
---vector, not a quaternion)

---@class BJInfectedDefaults host-configurable at game-start time, same override->default->fallback
---resolution pattern services/hunterGrid.lua's buildSettings already established
---@field initialInfectedCount integer? how many participants start the round already infected,
---drawn randomly at COUNTDOWN unless staff force-assigns specific ones first ; default 1, clamped
---[1, participantCount - 1] at session-build time (needs at least 1 real survivor left over)
---@field survivorsStartDelay integer? seconds survivors stay frozen after GAME start ; default 5
---@field infectedStartDelay integer? seconds the round's ORIGINAL infected stay frozen after GAME
---start (their head start for survivors) ; default 10. A survivor tagged mid-round is never frozen
---at all, they're already driving
---@field roundDuration integer? minutes ; if any survivor is still uninfected when this elapses,
---survivors win by outlasting the clock. BJS-only addition: BJI's own Infected never exposed a round
---timer in anything reachable from this fork's own reference (the client-side settings/BJC panel this
---fork ported both stop short of one), so a round with nobody left to catch would otherwise never end
---on its own ; clamped [1, 120]
---@field gridReadyTimeout integer? seconds, floor on lobby duration even once everyone's ready ;
---default 15 (BJI's own PreparationTimeout default is comparable, though not verified to mean
---exactly the same floor/ceiling split this fork's own Hunter/Race convention already uses)
---@field gridTimeout integer? seconds, hard deadline where anyone still unready is dropped and the
---game starts (or the lobby closes) regardless ; default 120
---@field countdown integer? seconds between spawns being assigned and GAME actually starting ;
---default 10
---@field endTimeout integer? seconds the FINISHED results screen stays up before the session tears
---down ; default 10, matching BJI's own EndTimeout
---@field enableColors boolean? force-repaints every participant's vehicle to a flat role color
---(survivorColor/infectedColor) at spawn/role-change, and disables free paint choice while it does ;
---default false
---@field survivorColor BJColor? RGBA 0-1, default a soft green
---@field infectedColor BJColor? RGBA 0-1, default red
---@field config {model: string, config: string, label: string?, parts: table?}? optional forced
---vehicle, applied to every participant instead of letting them pick freely ; nil = free choice.
---Same {model, config, label, parts} shape services/vehiclePresets.lua's own preset entries already
---use (see hunterGrid.lua's own huntedVehiclePool for the identical convention), just a single
---entry captured straight from the host's own current vehicle rather than a whole named preset.
---Mirrors BJI's own single forced-config field rather than pulling in the vehicle-preset-POOL
---machinery Hunter's huntedVehiclePresetId/huntersVehiclePresetId uses: Infected doesn't need two
---different pools (every role can be forced into the same one config, since nothing here is
---asymmetric except timing), so
---the simpler mechanism is enough

---@class BJInfectedArena
---@field enabled boolean
---@field survivorSpawns BJInfectedSpawn[] plentiful : every non-initially-infected participant needs
---their own slot
---@field infectedSpawns BJInfectedSpawn[] sparse : only ever needed for the round's initial
---infected, since a survivor tagged mid-round stays exactly where they were tagged
---@field defaults BJInfectedDefaults

local M = {
    -- services_hunter : reuses its quatToFlatDir for the legacy importer below, exported there
    -- specifically for this kind of second consumer
    dependencies = { "dao_activity", "dao_bundled", "services_core", "services_hunter" },

    ACTIVITY_TYPE = "infected",

    -- matches BJI's own hardcoded floor (a round needs someone to chase and someone left to catch);
    -- not host-configurable, same as BJI never exposed this as a setting either
    -- TEMPORARY (requested 2026-09-06): lowered to 2 so 2-player testing can actually reach GAME.
    -- resolveInfectedCount already handles 2 participants fine (1 infected, 1 survivor). Revert to
    -- 3 once real 3+-player testing resumes.
    MINIMUM_PARTICIPANTS = 2,
    MIN_SURVIVOR_SPAWNS = 2,
    MIN_INFECTED_SPAWNS = 1,

    ---@type BJInfectedArena?
    data = nil,
}

---@param arena BJInfectedArena
---@return string? error
local function sanitizeArena(arena)
    if not table.isArray(arena.survivorSpawns) then arena.survivorSpawns = {} end
    if not table.isArray(arena.infectedSpawns) then arena.infectedSpawns = {} end

    if table.any(arena.survivorSpawns, function(s)
            return type(s.pos) ~= "table" or type(s.dir) ~= "table"
        end) then
        return "Invalid survivor spawn data"
    elseif table.any(arena.infectedSpawns, function(s)
            return type(s.pos) ~= "table" or type(s.dir) ~= "table"
        end) then
        return "Invalid infected spawn data"
    end

    arena.enabled = arena.enabled == true
    if arena.enabled and (#arena.survivorSpawns < M.MIN_SURVIVOR_SPAWNS or
            #arena.infectedSpawns < M.MIN_INFECTED_SPAWNS) then
        return string.format(
            "Enabling requires at least %d survivor spawns and %d infected spawns",
            M.MIN_SURVIVOR_SPAWNS, M.MIN_INFECTED_SPAWNS)
    end

    arena.defaults = arena.defaults or {}
    arena.defaults.initialInfectedCount = math.max(1, math.floor(tonumber(arena.defaults.initialInfectedCount) or 1))
    arena.defaults.survivorsStartDelay = math.max(0, tonumber(arena.defaults.survivorsStartDelay) or 5)
    arena.defaults.infectedStartDelay = math.max(0, tonumber(arena.defaults.infectedStartDelay) or 10)
    arena.defaults.roundDuration = math.clamp(math.floor(tonumber(arena.defaults.roundDuration) or 10), 1, 120)
    arena.defaults.gridReadyTimeout = math.max(0, tonumber(arena.defaults.gridReadyTimeout) or 15)
    arena.defaults.gridTimeout = math.max(10, tonumber(arena.defaults.gridTimeout) or 120)
    arena.defaults.countdown = math.clamp(tonumber(arena.defaults.countdown) or 10, 0, 600)
    arena.defaults.endTimeout = math.max(3, tonumber(arena.defaults.endTimeout) or 10)
    arena.defaults.enableColors = arena.defaults.enableColors == true
    if type(arena.defaults.survivorColor) ~= "table" then arena.defaults.survivorColor = nil end
    if type(arena.defaults.infectedColor) ~= "table" then arena.defaults.infectedColor = nil end
    if type(arena.defaults.config) ~= "table" or type(arena.defaults.config.model) ~= "string" or
        type(arena.defaults.config.config) ~= "string" then
        arena.defaults.config = nil
    end
end

--- load the current map's arena, called on boot and on map change
local function loadData()
    M.data = dao_activity.get(services_core.getCurrentMap(), M.ACTIVITY_TYPE)
    if M.data and M.data.enabled and (#M.data.survivorSpawns < M.MIN_SURVIVOR_SPAWNS or
            #M.data.infectedSpawns < M.MIN_INFECTED_SPAWNS) then
        -- same defensive backfill reasoning as hunter.lua's own loadData : sanitizeArena only ever
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

--- auto-imports this mod's own bundled default infected arena for a map that doesn't have one
--- saved yet, mirroring hunter.lua's own seedBundledHunterArena exactly (see its own doc for the
--- whole mechanism, including the per-map "only ever considered once" ledger reasoning)
local function seedBundledInfectedArena()
    for _, mapName in ipairs(dao_bundled.listMapsForType(M.ACTIVITY_TYPE)) do
        if not dao_bundled.isSeeded(mapName, M.ACTIVITY_TYPE, "arena") then
            if dao_activity.get(mapName, M.ACTIVITY_TYPE) == nil then
                local bundled = dao_bundled.get(mapName, M.ACTIVITY_TYPE)
                if type(bundled) == "table" then
                    local candidate = table.deepcopy(bundled)
                    local err = sanitizeArena(candidate)
                    if err then
                        LogError(string.format(
                            "seedBundledInfectedArena: %s failed sanitation: %s", mapName, err))
                    else
                        dao_activity.save(mapName, M.ACTIVITY_TYPE, candidate)
                        LogInfo(string.format("seedBundledInfectedArena: seeded %s", mapName))
                    end
                end
            else
                LogInfo(string.format(
                    "seedBundledInfectedArena: skipped %s, already has an arena", mapName))
            end
            dao_bundled.markSeeded(mapName, M.ACTIVITY_TYPE, "arena")
        end
    end
end

---@param caches table
local function onBJRequestCache(caches)
    -- visible to every player, not staff-gated : same reasoning as hunter.lua's own cache (meant to
    -- be played, not just administered)
    caches.infectedArena = M.data
end

---@return BJInfectedArena?
local function getArena()
    return M.data
end

---@param ctxt BJSContext
---@param arena BJInfectedArena
local function infectedArenaSave(ctxt, arena)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditInfectedArenas) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end

    local err = sanitizeArena(arena)
    if err then
        LogError(string.format("infectedArenaSave rejected%s: %s",
            ctxt.sender and (" from " .. ctxt.sender.playerName) or "", err))
        dump(arena)
        if ctxt.sender then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
        end
        return
    end

    M.data = arena
    saveData()

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "infectedArenaSaved", true)
    end

    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

--- Legacy BeamJoy Free (BJI) arena import: BJI stores Hunter and Infected spawn data in the SAME
--- `<mapName>_hunter.json` file per map (majorPositions/minorPositions are shared by both modes
--- there), gated by its own separate `enabledInfected` flag ; only `waypoints` is Hunter-exclusive.
--- An admin migrating from BJI copies that whole `scenarii` folder into this fork's own
--- `BeamJoyData/db/` first, same as services/hunter.lua's own importer expects. Deliberately reuses
--- services_hunter.quatToFlatDir rather than re-deriving the same fragile, already-debugged rotation
--- math a second time (see that function's own doc comment for the whole story).
local LEGACY_DIR = "scenarii"

---@param entries {pos: {x:number,y:number,z:number}, rot: {x:number,y:number,z:number,w:number}}[]?
---@return BJInfectedSpawn[]
local function convertLegacySpawns(entries)
    local result = {}
    if type(entries) == "table" then
        for _, e in ipairs(entries) do
            if type(e) == "table" and type(e.pos) == "table" then
                table.insert(result, {
                    pos = { x = tonumber(e.pos.x) or 0, y = tonumber(e.pos.y) or 0, z = tonumber(e.pos.z) or 0 },
                    dir = type(e.rot) == "table" and services_hunter.quatToFlatDir(e.rot) or { x = 1, y = 0, z = 0 },
                })
            end
        end
    end
    return result
end

--- Hunter-only fields (waypoints, enabledHunter) are silently ignored: this only ever produces an
--- Infected arena, never anything Hunter-related.
---@param oldData table raw parsed <map>_hunter.json (BJI format)
---@return BJInfectedArena?
local function convertLegacyArena(oldData)
    if type(oldData) ~= "table" then return nil end
    return {
        enabled = oldData.enabledInfected == true,
        survivorSpawns = convertLegacySpawns(oldData.majorPositions),
        infectedSpawns = convertLegacySpawns(oldData.minorPositions),
        defaults = {},
    }
end

---@return {map: string, survivorSpawnCount: integer, infectedSpawnCount: integer, enabled: boolean, conflict: boolean}[]
local function scanLegacyArenas()
    local results = {}
    local dir = dao_main.dbPath .. "/" .. LEGACY_DIR
    if not FS.Exists(dir) then return results end
    for _, filename in pairs(FS.ListFiles(dir)) do
        -- same source file Hunter's own importer reads (<map>_hunter.json holds both modes' spawns)
        local mapName = filename:match("^(.+)_hunter%.json$")
        if mapName then
            local raw = dao_main.get(LEGACY_DIR .. "/" .. filename)
            local converted = convertLegacyArena(raw)
            if converted and (#converted.survivorSpawns > 0 or #converted.infectedSpawns > 0) then
                local existing = dao_activity.get(mapName, M.ACTIVITY_TYPE)
                local existingHasContent = existing ~= nil and (#(existing.survivorSpawns or {}) > 0 or
                    #(existing.infectedSpawns or {}) > 0)
                table.insert(results, {
                    map = mapName,
                    survivorSpawnCount = #converted.survivorSpawns,
                    infectedSpawnCount = #converted.infectedSpawns,
                    enabled = converted.enabled,
                    conflict = existingHasContent,
                })
            end
        end
    end
    return results
end

---@param ctxt BJSContext
local function infectedLegacyImportPreview(ctxt)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditInfectedArenas) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end
    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "infectedLegacyImportPreviewResult", scanLegacyArenas())
    end
end

---@param ctxt BJSContext
local function infectedLegacyImportConfirm(ctxt)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditInfectedArenas) then
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
                if converted and (#converted.survivorSpawns > 0 or #converted.infectedSpawns > 0) then
                    local err = sanitizeArena(converted)
                    if err then
                        LogError(string.format("infectedLegacyImportConfirm: %s failed sanitation: %s",
                            mapName, err))
                        failed = failed + 1
                    else
                        dao_activity.save(mapName, M.ACTIVITY_TYPE, converted)
                        imported = imported + 1
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
        communications_tx.sendToPlayer(ctxt.senderID, "infectedLegacyImportDone", imported, failed)
    end
end

local function onInit()
    communications_rx.addHandler("infectedArenaSave", M.infectedArenaSave)
    communications_rx.addHandler("infectedLegacyImportPreview", M.infectedLegacyImportPreview)
    communications_rx.addHandler("infectedLegacyImportConfirm", M.infectedLegacyImportConfirm)
    seedBundledInfectedArena()
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData

M.getArena = getArena
M.infectedArenaSave = infectedArenaSave
M.infectedLegacyImportPreview = infectedLegacyImportPreview
M.infectedLegacyImportConfirm = infectedLegacyImportConfirm

return M
