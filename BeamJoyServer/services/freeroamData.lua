--- Static, per-map freeroam POI data: energy stations (refuel) and garages (repair). One flat
--- list of each per map, persisted exactly like races (`dao_activity` -> `<map>_stations.json` /
--- `<map>_garages.json`), seeded once from this mod's own bundled content via `dao_bundled`.
---
--- Deliberately close to a two-list rename of services/races.lua's own list-per-map bones (load
--- on boot + map change, sanitize only at save time with a defensive backfill on load, push the
--- full list to every player in `onBJRequestCache`, ack the sender explicitly so the editor's
--- one-use handler never times out silently). The gameplay side (the refuel/repair loop, the
--- in-world markers, the Big Map POIs) is entirely client-side in beamjoy/stations.lua ; nothing
--- here validates or even sees an actual refuel, matching BJI's own "local cosmetic effect on
--- your own vehicle, no server round-trip" treatment.

---@class BJEnergyStation
---@field id integer unique per map
---@field name string
---@field pos {x: number, y: number, z: number} the station's own reference position - the Big Map
---pin always sits here, and (when `pumps` is empty) this is also the single refuel point, exactly
---the pre-pumps behavior
---@field radius number metres, the trigger sphere a vehicle must be inside to refuel - only
---meaningful when `pumps` is empty (see above)
---@field types string[] subset of M.ENERGY_TYPES, only meaningful when `pumps` is empty (see
---above). **Empty = `M.DEFAULT_FUEL_TYPES`** (gasoline, diesel, kerosine, n2o - every
---combustion-side energy; electric is the one thing NOT included by default, so an EV at an
---unmarked pump gets no "recharge" prompt). A non-empty list is an explicit override :
---`{"electricEnergy"}` for an EV charger, `{"diesel"}` for a truck stop,
---`{"gasoline","electricEnergy"}` for a mixed station, etc. The editor leaves this empty unless
---the host opens the advanced per-station override.
---@field pumps BJEnergyPump[]? per direct request : individual pumps/chargers, each its own real
---position a player can walk/drive up to independently, each with its own fuel type(s). Empty/nil
---(the vast majority of stations, and every legacy-imported one - BJI has no equivalent concept)
---keeps the station working exactly as a single point, using pos/radius/types above. Non-empty
---means the station itself no longer contributes its OWN refuel point at all - every pump does
---instead (see beamjoy/stations.lua) ; pos/radius/types on the station stay around purely as the
---Big Map pin location.

---@class BJEnergyPump
---@field pos {x: number, y: number, z: number}
---@field radius number metres, same semantics/bounds as BJEnergyStation.radius
---@field types string[] same semantics as BJEnergyStation.types (empty = DEFAULT_FUEL_TYPES),
---scoped to just this one pump

---@class BJGarage
---@field id integer unique per map
---@field name string
---@field pos {x: number, y: number, z: number}
---@field radius number metres

local M = {
    dependencies = { "dao_activity", "dao_bundled", "services_core" },

    STATIONS_TYPE = "stations",
    GARAGES_TYPE = "garages",

    -- BeamNG tank `energyType` values a station may serve. "electricEnergy" is the game's own key
    -- for a battery, "n2o" its key for a nitrous bottle. Kept in sync with the client's own
    -- beamjoy/stations.lua. (native's own freeroam_gasStations refuels n2o at a plain pump too.)
    ENERGY_TYPES = { "gasoline", "diesel", "kerosine", "n2o", "electricEnergy" },
    -- what an empty `types` list resolves to : every combustion-side energy a pump plausibly
    -- dispenses. Electric is the one exclusion - a host must explicitly list "electricEnergy" to
    -- make a station (also) charge EVs, so an EV at an unmarked pump gets no recharge prompt.
    DEFAULT_FUEL_TYPES = { "gasoline", "diesel", "kerosine", "n2o" },

    MIN_RADIUS = 1,
    MAX_RADIUS = 50,
    DEFAULT_RADIUS = 5,
    MAX_NAME_LEN = 40,

    ---@type BJEnergyStation[] energy stations for the current map
    stations = {},
    ---@type BJGarage[] garages for the current map
    garages = {},
}

---@param pos any
---@return boolean
local function validPos(pos)
    return type(pos) == "table" and type(pos.x) == "number" and
        type(pos.y) == "number" and type(pos.z) == "number"
end

--- assigns a stable unique integer id to every entry missing one (or colliding with an earlier
--- entry's), lowest free value first, exactly like raceSave's own id allocation
---@param list table[]
local function assignIds(list)
    local used = {}
    for _, item in ipairs(list) do
        if type(item.id) == "number" and item.id == math.floor(item.id) and not used[item.id] then
            used[item.id] = true
        else
            item.id = nil
        end
    end
    for _, item in ipairs(list) do
        if item.id == nil then
            local id = 1
            while used[id] do id = id + 1 end
            item.id, used[id] = id, true
        end
    end
end

---@param name any
---@param fallback string
---@return string
local function cleanName(name, fallback)
    if type(name) ~= "string" then return fallback end
    name = name:trim()
    if #name == 0 then return fallback end
    if #name > M.MAX_NAME_LEN then name = name:sub(1, M.MAX_NAME_LEN) end
    return name
end

---@param radius any
---@return number
local function cleanRadius(radius)
    radius = tonumber(radius) or M.DEFAULT_RADIUS
    return math.max(M.MIN_RADIUS, math.min(M.MAX_RADIUS, radius))
end

--- shared by a station's own `types` and each of its pumps' own `types` - same semantics : empty
--- / absent stays empty (the client resolves that to DEFAULT_FUEL_TYPES), a non-empty list is
--- filtered to known types + de-duped.
---@param types any
---@return string[]
local function cleanTypes(types)
    local clean, seen = {}, {}
    if table.isArray(types) then
        for _, t in ipairs(types) do
            if table.includes(M.ENERGY_TYPES, t) and not seen[t] then
                seen[t] = true
                table.insert(clean, t)
            end
        end
    end
    return clean
end

--- mutates `pumps` in place (position/radius/type normalization), dropping any entry with an
--- invalid position outright (unlike a station/garage itself, one bad pump shouldn't fail the
--- whole station's save - it's a sub-item, not independently re-editable once lost)
---@param pumps any
---@return BJEnergyPump[]
local function cleanPumps(pumps)
    local clean = {}
    if table.isArray(pumps) then
        for _, p in ipairs(pumps) do
            if type(p) == "table" and validPos(p.pos) then
                table.insert(clean, {
                    pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z },
                    radius = cleanRadius(p.radius),
                    types = cleanTypes(p.types),
                })
            end
        end
    end
    return clean
end

--- mutates `list` in place (id assignment, name/radius/type/pump normalization) ; returns an error
--- string only for structurally unrecoverable data
---@param list any
---@return string? error
local function sanitizeStations(list)
    if not table.isArray(list) then return "Invalid stations data" end
    for _, s in ipairs(list) do
        if type(s) ~= "table" or not validPos(s.pos) then
            return "Invalid station position data"
        end
    end
    for i, s in ipairs(list) do
        s.pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z }
        s.name = cleanName(s.name, "Station " .. i)
        s.radius = cleanRadius(s.radius)
        s.types = cleanTypes(s.types)
        local pumps = cleanPumps(s.pumps)
        s.pumps = #pumps > 0 and pumps or nil
    end
    assignIds(list)
    return nil
end

---@param list any
---@return string? error
local function sanitizeGarages(list)
    if not table.isArray(list) then return "Invalid garages data" end
    for _, g in ipairs(list) do
        if type(g) ~= "table" or not validPos(g.pos) then
            return "Invalid garage position data"
        end
    end
    for i, g in ipairs(list) do
        g.pos = { x = g.pos.x, y = g.pos.y, z = g.pos.z }
        g.name = cleanName(g.name, "Garage " .. i)
        g.radius = cleanRadius(g.radius)
        g.types = nil -- garages never carry fuel types ; scrub any stray field
    end
    assignIds(list)
    return nil
end

--- load both lists for the current map, called on boot and on map change
local function loadData()
    M.stations = dao_activity.get(services_core.getCurrentMap(), M.STATIONS_TYPE) or {}
    M.garages = dao_activity.get(services_core.getCurrentMap(), M.GARAGES_TYPE) or {}
    -- sanitize only ever runs at save time (like races) ; a hand-edited or pre-feature file
    -- could still be missing ids / have an oversized name / carry an invalid fuel type, all of
    -- which flow straight to every client. Normalize once here too. Errors are ignored on load:
    -- a structurally broken file just yields an empty list rather than blocking boot.
    if sanitizeStations(M.stations) then M.stations = {} end
    if sanitizeGarages(M.garages) then M.garages = {} end
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

local function saveStations()
    dao_activity.save(services_core.getCurrentMap(), M.STATIONS_TYPE,
        #M.stations > 0 and M.stations or nil)
end

local function saveGarages()
    dao_activity.save(services_core.getCurrentMap(), M.GARAGES_TYPE,
        #M.garages > 0 and M.garages or nil)
end

--- auto-imports this mod's own bundled default stations/garages for any map that has none saved
--- yet, mirroring services/races.lua's own seedBundledRaces list-based mechanism (per-entry
--- "considered once ever" ledger, keyed by name, so a later deletion is never undone). Runs once
--- at boot for every map dao_bundled ships content for, not just the current one.
---@param activityType string
---@param sanitizer fun(list: table): string?
local function seedBundled(activityType, sanitizer)
    for _, mapName in ipairs(dao_bundled.listMapsForType(activityType)) do
        local bundled = dao_bundled.get(mapName, activityType)
        if table.isArray(bundled) then
            local targetList = dao_activity.get(mapName, activityType) or {}
            local changed = false
            for _, entry in ipairs(bundled) do
                local name = type(entry.name) == "string" and entry.name or ""
                if not dao_bundled.isSeeded(mapName, activityType, name) then
                    if table.any(targetList, function(e) return e.name == name end) then
                        LogInfo(string.format(
                            "seedBundled(%s): skipped %s / %s, an entry with this name already exists",
                            activityType, mapName, name))
                    else
                        local candidate = table.deepcopy(entry)
                        table.insert(targetList, candidate)
                        local err = sanitizer(targetList)
                        if err then
                            table.remove(targetList)
                            LogError(string.format("seedBundled(%s): %s / %s failed sanitation: %s",
                                activityType, mapName, name, err))
                        else
                            changed = true
                            LogInfo(string.format("seedBundled(%s): seeded %s / %s",
                                activityType, mapName, name))
                        end
                    end
                    dao_bundled.markSeeded(mapName, activityType, name)
                end
            end
            if changed then
                dao_activity.save(mapName, activityType, targetList)
            end
        end
    end
end

---@param caches table
local function onBJRequestCache(caches)
    -- visible to every player, not staff-gated : same reasoning as races/hunter/infected (this is
    -- gameplay content, every client renders the markers and runs the refuel/repair loop locally)
    caches.stations = M.stations
    caches.garages = M.garages
end

---@param ctxt BJSContext
---@param key string wire event key the client sent
---@param list table
---@param activityType string
---@param sanitizer fun(list: table): string?
---@param apply fun(list: table)
---@param ackKey string
local function handleSave(ctxt, list, activityType, sanitizer, apply, ackKey)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditFreeroamData) then
        local permErr = services_lang.get("error.insufficientPermissions", ctxt.sender.lang)
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", permErr)
        -- always answer explicitly so the editor's one-use handler resyncs instead of timing out
        -- silently (same bug/fix as infected.lua's infectedArenaSave)
        return communications_tx.sendToPlayer(ctxt.senderID, ackKey, false, permErr)
    end

    if not table.isArray(list) then list = {} end
    local err = sanitizer(list)
    if err then
        LogError(string.format("%s rejected%s: %s", ackKey,
            ctxt.sender and (" from " .. ctxt.sender.playerName) or "", err))
        dump(list)
        if ctxt.sender then
            communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
            return communications_tx.sendToPlayer(ctxt.senderID, ackKey, false, err)
        end
        return
    end

    apply(list)

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, ackKey, true)
    end

    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

---@param ctxt BJSContext
---@param list table
local function energyStationsSave(ctxt, list)
    handleSave(ctxt, list, M.STATIONS_TYPE, sanitizeStations, function(sane)
        M.stations = sane
        saveStations()
    end, "energyStationsSaved")
end

---@param ctxt BJSContext
---@param list table
local function garagesSave(ctxt, list)
    handleSave(ctxt, list, M.GARAGES_TYPE, sanitizeGarages, function(sane)
        M.garages = sane
        saveGarages()
    end, "garagesSaved")
end

--- Legacy BeamJoy Improved (BJI) stations/garages importer. Confirmed against BJI's own real
--- source (`BeamJoyCore/dao/DaoFile/FileScenario.lua`, `my-name-is-samael/BeamJoy` on GitHub) -
--- earlier revisions of this importer guessed at the file layout from client-only source and got
--- it wrong (see below), which is why a real BJI install always reported "none found".
---
--- Real layout: BOTH energy stations AND garages live in the SAME file, `<mapName>_stations.json`
--- under `<dbPath>/scenarii/` (`_TYPES.STATIONS = "_stations"`, concatenated directly onto the map
--- name with no separator - the underscore is baked into the suffix). Its content is NOT a plain
--- array like every other legacy scenario file: it's a single object `{EnergyStations: [...],
--- Garages: [...]}` (`FileScenario.lua`'s `_loadMapStations`/`EnergyStations.save`/`Garages.save`
--- all read-modify-write that same one file). There is no separate `_garages.json` at all - the
--- earlier version of this importer invented that filename, and its `table.isArray(raw)` check on
--- the combined object always failed (an object with string keys is not an array), so real BJI
--- data silently matched nothing. NON-DESTRUCTIVE like every sibling importer: every convertible
--- entry is ADDED, nothing already saved is ever touched or overwritten. Unlike races, there's no
--- name-collision concept to check here at all - stations/garages were never unique-by-name to
--- begin with, so every structurally valid entry just gets appended.
local LEGACY_DIR = "scenarii"
local LEGACY_STATIONS_SUFFIX = "_stations.json"

---@param filename string
---@param suffix string
---@return string? mapName
local function matchLegacyFilename(filename, suffix)
    return filename:match("^(.+)" .. suffix:gsub("%.", "%%.") .. "$")
end

---@param old table raw BJI entry {name, pos, radius, types?}
---@return table?
local function convertLegacyStation(old)
    if type(old) ~= "table" or not validPos(old.pos) then return nil end
    return {
        name = old.name,
        pos = { x = old.pos.x, y = old.pos.y, z = old.pos.z },
        radius = old.radius,
        types = table.isArray(old.types) and old.types or nil,
    }
end

---@param old table raw BJI entry {name, pos, radius}
---@return table?
local function convertLegacyGarage(old)
    if type(old) ~= "table" or not validPos(old.pos) then return nil end
    return {
        name = old.name,
        pos = { x = old.pos.x, y = old.pos.y, z = old.pos.z },
        radius = old.radius,
    }
end

---@return table<string, {stations: table[], garages: table[]}>
local function scanLegacyFreeroamData()
    local byMap = {}
    local dir = dao_main.dbPath .. "/" .. LEGACY_DIR
    if not FS.Exists(dir) then return byMap end
    for _, filename in pairs(FS.ListFiles(dir)) do
        local mapName = matchLegacyFilename(filename, LEGACY_STATIONS_SUFFIX)
        if mapName then
            local raw = dao_main.get(LEGACY_DIR .. "/" .. filename)
            if type(raw) == "table" then
                local entry = { stations = {}, garages = {} }
                if table.isArray(raw.EnergyStations) then
                    for _, s in ipairs(raw.EnergyStations) do
                        local converted = convertLegacyStation(s)
                        if converted then table.insert(entry.stations, converted) end
                    end
                end
                if table.isArray(raw.Garages) then
                    for _, g in ipairs(raw.Garages) do
                        local converted = convertLegacyGarage(g)
                        if converted then table.insert(entry.garages, converted) end
                    end
                end
                if #entry.stations > 0 or #entry.garages > 0 then
                    byMap[mapName] = entry
                end
            end
        end
    end
    return byMap
end

---@return {map: string, stationCount: integer, garageCount: integer}[]
local function previewLegacyFreeroamData()
    local results = {}
    for mapName, entries in pairs(scanLegacyFreeroamData()) do
        if #entries.stations > 0 or #entries.garages > 0 then
            table.insert(results, { map = mapName, stationCount = #entries.stations,
                garageCount = #entries.garages })
        end
    end
    return results
end

---@param ctxt BJSContext
local function freeroamDataLegacyImportPreview(ctxt)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditFreeroamData) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end
    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "freeroamDataLegacyImportPreviewResult",
            previewLegacyFreeroamData())
    end
end

--- operates on every map found at once, not just the currently-loaded one, same as every sibling
--- legacy importer - an admin migrating a whole server's worth of old data shouldn't have to
--- switch maps repeatedly to import each one.
---@param ctxt BJSContext
local function freeroamDataLegacyImportConfirm(ctxt)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditFreeroamData) then
        local permErr = services_lang.get("error.insufficientPermissions", ctxt.sender.lang)
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", permErr)
        return communications_tx.sendToPlayer(ctxt.senderID, "freeroamDataLegacyImportDone", 0, 0)
    end

    local importedStations, importedGarages = 0, 0
    for mapName, entries in pairs(scanLegacyFreeroamData()) do
        local isCurrentMap = mapName == services_core.getCurrentMap()
        if #entries.stations > 0 then
            local target = isCurrentMap and M.stations or (dao_activity.get(mapName, M.STATIONS_TYPE) or {})
            for _, s in ipairs(entries.stations) do
                table.insert(target, s)
                importedStations = importedStations + 1
            end
            sanitizeStations(target)
            if isCurrentMap then M.stations = target end
            dao_activity.save(mapName, M.STATIONS_TYPE, #target > 0 and target or nil)
        end
        if #entries.garages > 0 then
            local target = isCurrentMap and M.garages or (dao_activity.get(mapName, M.GARAGES_TYPE) or {})
            for _, g in ipairs(entries.garages) do
                table.insert(target, g)
                importedGarages = importedGarages + 1
            end
            sanitizeGarages(target)
            if isCurrentMap then M.garages = target end
            dao_activity.save(mapName, M.GARAGES_TYPE, #target > 0 and target or nil)
        end
    end

    if importedStations > 0 or importedGarages > 0 then
        services_players.players:forEach(function(p)
            local caches = {}
            M.onBJRequestCache(caches)
            communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
        end)
    end

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "freeroamDataLegacyImportDone",
            importedStations, importedGarages)
    end
end

local function onInit()
    communications_rx.addHandler("energyStationsSave", M.energyStationsSave)
    communications_rx.addHandler("garagesSave", M.garagesSave)
    communications_rx.addHandler("freeroamDataLegacyImportPreview", M.freeroamDataLegacyImportPreview)
    communications_rx.addHandler("freeroamDataLegacyImportConfirm", M.freeroamDataLegacyImportConfirm)
    seedBundled(M.STATIONS_TYPE, sanitizeStations)
    seedBundled(M.GARAGES_TYPE, sanitizeGarages)
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData

M.energyStationsSave = energyStationsSave
M.garagesSave = garagesSave
M.freeroamDataLegacyImportPreview = freeroamDataLegacyImportPreview
M.freeroamDataLegacyImportConfirm = freeroamDataLegacyImportConfirm

return M
