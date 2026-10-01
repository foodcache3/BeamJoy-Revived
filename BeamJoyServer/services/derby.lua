--- Derby arena definitions (static, per map), split from services/derbyGrid.lua (the live games)
--- the same way hunter.lua / infected.lua are split from their grids. Unlike those two, a map holds
--- a LIST of arenas (the Derby map alone has four), so every arena carries its own id and name, and
--- saving or deleting one never touches the others.
---
--- Three modes play on the same arena data (see derbyGrid.lua) : last man standing, timed and
--- sumo. The arena's zone (a circle, rectangle or ellipse) keeps cars in the arena in every mode and shrinks
--- in sumo ; sumo is the only mode that needs one, so an arena without one can host the other two.

---@class BJDerbySpawn
---@field pos {x: number, y: number, z: number}
---@field dir {x: number, y: number, z: number} flat direction vector, same convention as hunter/
---infected spawns

---@class BJDerbyZone the sumo zone at its starting size, centred on pos. Either shape shrinks toward
---pos and keeps its proportions.
---@field shape "circle"|"rect"|"ellipse"
---@field pos {x: number, y: number, z: number}
---@field radius number? circle
---@field dir {x: number, y: number, z: number}? rect / ellipse : flat direction of its length
---@field width number? rect / ellipse : metres across dir
---@field length number? rect / ellipse : metres along dir

---@class BJDerbyDefaults host-configurable at game-start time, same override->default->fallback
---resolution as the other modes (derbyGrid.lua buildSettings)
---@field mode "lms"|"timed"|"sumo"?
---@field lives integer? last man standing and sumo : extra lives, 0-5 ; default 0
---@field roundDuration integer? timed : minutes ; default 5
---@field stuckSeconds integer? a car that can't move for this long is wrecked ; default 20
---@field zoneGraceSeconds integer? seconds outside the arena zone before it's a wreck ; default 3
---@field shrinkEverySeconds integer? sumo : seconds between two steps of the circle ; default 30
---@field shrinkSteps integer? sumo : how many steps down to the smallest circle ; default 6
---@field minRadiusPercent integer? sumo : the smallest zone, as a % of the starting one ; default 25
---@field respawnGhostSeconds integer? ghosted for this long after a respawn ; default 3
---@field vehiclePresetId integer? a vehicle preset everyone drives (services/vehiclePresets.lua)
---@field randomizeVehiclePool boolean? everyone gets a random vehicle from that preset
---@field gridReadyTimeout integer?
---@field gridTimeout integer?
---@field countdown integer?
---@field endTimeout integer?

---@class BJDerbyArena
---@field id integer unique on its map
---@field name string
---@field enabled boolean
---@field startPositions BJDerbySpawn[] one per player : also the arena's player cap
---@field zone BJDerbyZone? the arena zone ; nil = no boundary, and no sumo on this arena
---@field floorDepth number metres below the zone's centre that count as having fallen off (sumo)
---@field defaults BJDerbyDefaults

local M = {
    dependencies = { "dao_activity", "dao_bundled", "services_core", "services_hunter" },

    ACTIVITY_TYPE = "derby",
    MODES = { "lms", "timed", "sumo" },

    -- a derby needs someone to hit
    MINIMUM_PARTICIPANTS = 2,
    MIN_START_POSITIONS = 2,
    NAME_MAX = 40,

    ---@type BJDerbyArena[] the current map's arenas
    data = {},
}

---@param mode any
---@return boolean
local function isMode(mode)
    return table.includes(M.MODES, mode)
end

---@param p any
---@return boolean
local function isPos(p)
    return type(p) == "table" and tonumber(p.x) ~= nil and tonumber(p.y) ~= nil and tonumber(p.z) ~= nil
end

---@param defaults table?
---@return BJDerbyDefaults
local function sanitizeDefaults(defaults)
    local d = type(defaults) == "table" and defaults or {}
    local out = {
        mode = isMode(d.mode) and d.mode or "lms",
        lives = math.clamp(math.floor(tonumber(d.lives) or 0), 0, 5),
        roundDuration = math.clamp(math.floor(tonumber(d.roundDuration) or 5), 1, 60),
        stuckSeconds = math.clamp(math.floor(tonumber(d.stuckSeconds) or 20), 5, 120),
        zoneGraceSeconds = math.clamp(math.floor(tonumber(d.zoneGraceSeconds) or 3), 0, 30),
        shrinkEverySeconds = math.clamp(math.floor(tonumber(d.shrinkEverySeconds) or 30), 5, 300),
        shrinkSteps = math.clamp(math.floor(tonumber(d.shrinkSteps) or 6), 1, 20),
        minRadiusPercent = math.clamp(math.floor(tonumber(d.minRadiusPercent) or 25), 5, 100),
        respawnGhostSeconds = math.clamp(math.floor(tonumber(d.respawnGhostSeconds) or 3), 0, 15),
        randomizeVehiclePool = d.randomizeVehiclePool == true,
        gridReadyTimeout = math.max(0, tonumber(d.gridReadyTimeout) or 15),
        gridTimeout = math.max(10, tonumber(d.gridTimeout) or 120),
        countdown = math.clamp(tonumber(d.countdown) or 10, 0, 600),
        endTimeout = math.max(3, tonumber(d.endTimeout) or 10),
    }
    local presetId = tonumber(d.vehiclePresetId)
    if presetId then out.vehiclePresetId = presetId end
    return out
end

---@param arena table
---@return string? error
local function sanitizeArena(arena)
    if type(arena) ~= "table" then return "Invalid arena" end
    if not table.isArray(arena.startPositions) then arena.startPositions = {} end
    for _, s in ipairs(arena.startPositions) do
        if not isPos(s.pos) or not isPos(s.dir) then return "Invalid start position data" end
    end
    arena.startPositions = table.map(arena.startPositions, function(s)
        return {
            pos = { x = tonumber(s.pos.x), y = tonumber(s.pos.y), z = tonumber(s.pos.z) },
            dir = { x = tonumber(s.dir.x), y = tonumber(s.dir.y), z = tonumber(s.dir.z) },
        }
    end)

    local zone = type(arena.zone) == "table" and isPos(arena.zone.pos) and arena.zone or nil
    local zonePos = zone and { x = tonumber(zone.pos.x), y = tonumber(zone.pos.y), z = tonumber(zone.pos.z) }
    if zone and (zone.shape == "rect" or zone.shape == "ellipse") and tonumber(zone.width) and tonumber(zone.length) then
        -- flat and unit length ; a zero or broken direction falls back to east
        local dx = type(zone.dir) == "table" and tonumber(zone.dir.x) or 0
        local dy = type(zone.dir) == "table" and tonumber(zone.dir.y) or 0
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 1e-4 then dx, dy, len = 1, 0, 1 end
        arena.zone = {
            shape = zone.shape,
            pos = zonePos,
            dir = { x = dx / len, y = dy / len, z = 0 },
            width = math.clamp(tonumber(zone.width), 10, 2000),
            length = math.clamp(tonumber(zone.length), 10, 2000),
        }
    elseif zone and tonumber(zone.radius) then
        arena.zone = { shape = "circle", pos = zonePos, radius = math.clamp(tonumber(zone.radius), 5, 1000) }
    else
        arena.zone = nil
    end
    arena.floorDepth = math.clamp(tonumber(arena.floorDepth) or 10, 1, 500)

    arena.name = type(arena.name) == "string" and arena.name:trim() or ""
    if #arena.name > M.NAME_MAX then arena.name = arena.name:sub(1, M.NAME_MAX) end
    if #arena.name == 0 then return "The arena needs a name" end

    arena.enabled = arena.enabled == true
    if arena.enabled and #arena.startPositions < M.MIN_START_POSITIONS then
        return string.format("Enabling requires at least %d start positions", M.MIN_START_POSITIONS)
    end
    arena.defaults = sanitizeDefaults(arena.defaults)
    -- sumo can't be an arena's default without a zone to play in
    if arena.defaults.mode == "sumo" and not arena.zone then arena.defaults.mode = "lms" end
    return nil
end

---@param list any
---@return BJDerbyArena[]
local function normalizeList(list)
    if not table.isArray(list) then return {} end
    local out, usedIds = {}, {}
    for _, arena in ipairs(list) do
        if type(arena) == "table" and not sanitizeArena(arena) then
            local id = math.floor(tonumber(arena.id) or 0)
            if id < 1 or usedIds[id] then id = 0 end
            arena.id = id
            table.insert(out, arena)
            if id > 0 then usedIds[id] = true end
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

---@param list BJDerbyArena[]
---@return integer
local function nextIdOf(list)
    local id = 0
    for _, a in ipairs(list) do id = math.max(id, a.id or 0) end
    return id + 1
end

---@param id any
---@return BJDerbyArena?, integer?
local function getArena(id)
    id = tonumber(id)
    for i, a in ipairs(M.data) do
        if a.id == id then return a, i end
    end
    return nil, nil
end

--- an arena a game can start on right now
---@param arena BJDerbyArena?
---@return boolean
local function isPlayable(arena)
    return arena ~= nil and arena.enabled and #arena.startPositions >= M.MIN_START_POSITIONS
end

local function pushCacheToAll()
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

local function loadData()
    M.data = normalizeList(dao_activity.get(services_core.getCurrentMap(), M.ACTIVITY_TYPE))
    pushCacheToAll()
end

local function saveData()
    dao_activity.save(services_core.getCurrentMap(), M.ACTIVITY_TYPE, M.data)
end

--- the mod's own bundled arenas (bundledContent/activities/<map>_derby.json), each seeded into a
--- map's live data once, ever (dao_bundled's ledger) : an arena an admin deleted doesn't come back,
--- and one with the same name as an existing arena is skipped
local function seedBundledArenas()
    for _, mapName in ipairs(dao_bundled.listMapsForType(M.ACTIVITY_TYPE)) do
        local bundled = dao_bundled.get(mapName, M.ACTIVITY_TYPE)
        if table.isArray(bundled) then
            local live = normalizeList(dao_activity.get(mapName, M.ACTIVITY_TYPE))
            local changed = false
            for _, raw in ipairs(bundled) do
                local name = type(raw) == "table" and raw.name
                if type(name) == "string" and not dao_bundled.isSeeded(mapName, M.ACTIVITY_TYPE, name) then
                    local exists = table.any(live, function(a) return a.name == name end)
                    if not exists then
                        local candidate = table.deepcopy(raw)
                        local err = sanitizeArena(candidate)
                        if err then
                            LogError(string.format("seedBundledDerbyArenas: %s / %s failed sanitation: %s",
                                mapName, name, err))
                        else
                            candidate.id = nextIdOf(live)
                            table.insert(live, candidate)
                            changed = true
                            LogInfo(string.format("seedBundledDerbyArenas: seeded %s / %s", mapName, name))
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
    -- visible to every player : meant to be played, not just administered
    caches.derbyArenas = M.data
end

---@param ctxt BJSContext
---@return boolean
local function canEdit(ctxt)
    return not ctxt.sender or services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.EditDerbyArenas)
end

---@param ctxt BJSContext
---@param event string
local function refuse(ctxt, event)
    local permErr = services_lang.get("error.insufficientPermissions", ctxt.sender.lang)
    communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", permErr)
    communications_tx.sendToPlayer(ctxt.senderID, event, false, permErr)
end

--- saves one arena : an existing one (by id) is replaced, one without an id is added. Always
--- answers "derbyArenaSaved" (ok, error, id) so the editor can resync on a refusal
---@param ctxt BJSContext
---@param arena BJDerbyArena
local function derbyArenaSave(ctxt, arena)
    if not canEdit(ctxt) then return refuse(ctxt, "derbyArenaSaved") end

    local err = sanitizeArena(arena)
    local name = type(arena) == "table" and arena.name or nil
    if not err and table.any(M.data, function(a) return a.name == name and a.id ~= tonumber(arena.id) end) then
        err = "Another arena on this map already has that name"
    end
    if err then
        LogError(string.format("derbyArenaSave rejected%s: %s",
            ctxt.sender and (" from " .. ctxt.sender.playerName) or "", err))
        if ctxt.sender then
            communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
            communications_tx.sendToPlayer(ctxt.senderID, "derbyArenaSaved", false, err)
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
        communications_tx.sendToPlayer(ctxt.senderID, "derbyArenaSaved", true, "", arena.id)
    end
    pushCacheToAll()
end

---@param ctxt BJSContext
---@param id integer
local function derbyArenaDelete(ctxt, id)
    if not canEdit(ctxt) then return refuse(ctxt, "derbyArenaDeleted") end
    local _, index = getArena(id)
    if not index then return end
    table.remove(M.data, index)
    saveData()
    if ctxt.sender then communications_tx.sendToPlayer(ctxt.senderID, "derbyArenaDeleted", true) end
    pushCacheToAll()
end

--- Legacy BeamJoy Free (BJI) import : BJI keeps every derby arena of a map in
--- `scenarii/<map>_derby.json` (an admin migrating copies that folder into BeamJoyData/db/, same as
--- the hunter/infected importers). Its arenas are {name, enabled, previewPosition, centerPosition,
--- radius, startPositions = {pos, rot}[]} : the centre and radius become the sumo circle, and BJI's
--- own floor rule (half the radius below the centre) becomes floorDepth.
local LEGACY_DIR = "scenarii"

---@param raw table
---@return BJDerbyArena?
local function convertLegacyArena(raw)
    if type(raw) ~= "table" or type(raw.name) ~= "string" then return nil end
    local starts = {}
    if type(raw.startPositions) == "table" then
        for _, e in ipairs(raw.startPositions) do
            if type(e) == "table" and isPos(e.pos) then
                table.insert(starts, {
                    pos = { x = tonumber(e.pos.x), y = tonumber(e.pos.y), z = tonumber(e.pos.z) },
                    dir = type(e.rot) == "table" and services_hunter.quatToFlatDir(e.rot) or { x = 1, y = 0, z = 0 },
                })
            end
        end
    end
    local radius = tonumber(raw.radius)
    local zone = isPos(raw.centerPosition) and radius and radius > 0 and {
        pos = { x = tonumber(raw.centerPosition.x), y = tonumber(raw.centerPosition.y), z = tonumber(raw.centerPosition.z) },
        radius = radius,
    } or nil
    return {
        name = raw.name,
        enabled = raw.enabled == true,
        startPositions = starts,
        zone = zone,
        floorDepth = radius and radius / 2 or 10,
        defaults = {},
    }
end

---@param filename string
---@return string? mapName
local function legacyMapOf(filename)
    return filename:match("^(.+)_derby%.json$")
end

---@return table[] one row per legacy arena : {key, map, name, startCount, hasZone, enabled, conflict}
local function scanLegacyArenas()
    local results = {}
    local dir = dao_main.dbPath .. "/" .. LEGACY_DIR
    if not FS.Exists(dir) then return results end
    for _, filename in pairs(FS.ListFiles(dir)) do
        local mapName = legacyMapOf(filename)
        local raw = mapName and dao_main.get(LEGACY_DIR .. "/" .. filename)
        if table.isArray(raw) then
            local live = normalizeList(dao_activity.get(mapName, M.ACTIVITY_TYPE))
            for _, entry in ipairs(raw) do
                local converted = convertLegacyArena(entry)
                if converted and #converted.startPositions > 0 then
                    table.insert(results, {
                        key = mapName .. "|" .. converted.name,
                        map = mapName,
                        name = converted.name,
                        startCount = #converted.startPositions,
                        hasZone = converted.zone ~= nil,
                        enabled = converted.enabled,
                        conflict = table.any(live, function(a) return a.name == converted.name end),
                    })
                end
            end
        end
    end
    return results
end

---@param ctxt BJSContext
local function derbyLegacyImportPreview(ctxt)
    if not canEdit(ctxt) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end
    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "derbyLegacyImportPreviewResult", scanLegacyArenas())
    end
end

--- imports the ticked arenas ; one that shares a name with an existing arena replaces it (its id
--- is kept, so a lobby's arena reference stays valid)
---@param ctxt BJSContext
---@param selection string[]? "<map>|<name>" keys ; nil = all
local function derbyLegacyImportConfirm(ctxt, selection)
    local picked = ImportSelection(selection)
    if not canEdit(ctxt) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end

    local dir = dao_main.dbPath .. "/" .. LEGACY_DIR
    local imported, failed = 0, 0
    if FS.Exists(dir) then
        for _, filename in pairs(FS.ListFiles(dir)) do
            local mapName = legacyMapOf(filename)
            local raw = mapName and dao_main.get(LEGACY_DIR .. "/" .. filename)
            if table.isArray(raw) then
                local live = normalizeList(dao_activity.get(mapName, M.ACTIVITY_TYPE))
                local changed = false
                for _, entry in ipairs(raw) do
                    local converted = convertLegacyArena(entry)
                    if converted and #converted.startPositions > 0 and
                        (not picked or picked[mapName .. "|" .. converted.name]) then
                        local err = sanitizeArena(converted)
                        if err then
                            LogError(string.format("derbyLegacyImportConfirm: %s / %s failed sanitation: %s",
                                mapName, converted.name, err))
                            failed = failed + 1
                        else
                            local existingIndex
                            for i, a in ipairs(live) do
                                if a.name == converted.name then existingIndex = i end
                            end
                            if existingIndex then
                                converted.id = live[existingIndex].id
                                live[existingIndex] = converted
                            else
                                converted.id = nextIdOf(live)
                                table.insert(live, converted)
                            end
                            imported = imported + 1
                            changed = true
                        end
                    end
                end
                if changed then
                    dao_activity.save(mapName, M.ACTIVITY_TYPE, live)
                    if mapName == services_core.getCurrentMap() then
                        M.data = live
                        pushCacheToAll()
                    end
                end
            end
        end
    end

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "derbyLegacyImportDone", imported, failed)
    end
end

local function onInit()
    communications_rx.addHandler("derbyArenaSave", M.derbyArenaSave)
    communications_rx.addHandler("derbyArenaDelete", M.derbyArenaDelete)
    communications_rx.addHandler("derbyLegacyImportPreview", M.derbyLegacyImportPreview)
    communications_rx.addHandler("derbyLegacyImportConfirm", M.derbyLegacyImportConfirm)
    seedBundledArenas()
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData

M.isMode = isMode
M.getArena = getArena
M.isPlayable = isPlayable
M.sanitizeDefaults = sanitizeDefaults
M.derbyArenaSave = derbyArenaSave
M.derbyArenaDelete = derbyArenaDelete
M.derbyLegacyImportPreview = derbyLegacyImportPreview
M.derbyLegacyImportConfirm = derbyLegacyImportConfirm

return M
