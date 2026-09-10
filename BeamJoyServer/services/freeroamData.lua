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
---@field pos {x: number, y: number, z: number}
---@field radius number metres, the trigger sphere a vehicle must be inside to refuel
---@field types string[] subset of M.ENERGY_TYPES. **Empty = `M.DEFAULT_FUEL_TYPES`** (gasoline,
---diesel, kerosine, n2o - every combustion-side energy; electric is the one thing NOT included by
---default, so an EV at an unmarked pump gets no "recharge" prompt). A non-empty list is an
---explicit override : `{"electricEnergy"}` for an EV charger, `{"diesel"}` for a truck stop,
---`{"gasoline","electricEnergy"}` for a mixed station, etc. The editor leaves this empty unless
---the host opens the advanced per-station override.

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

--- mutates `list` in place (id assignment, name/radius/type normalization) ; returns an error
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
        -- empty / absent stays empty : the client resolves that to DEFAULT_FUEL_TYPES (everything
        -- but electric - see BJEnergyStation doc). Only a non-empty list overrides, and it's
        -- filtered to known types + de-duped.
        local types, seen = {}, {}
        if table.isArray(s.types) then
            for _, t in ipairs(s.types) do
                if table.includes(M.ENERGY_TYPES, t) and not seen[t] then
                    seen[t] = true
                    table.insert(types, t)
                end
            end
        end
        s.types = types
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

local function onInit()
    communications_rx.addHandler("energyStationsSave", M.energyStationsSave)
    communications_rx.addHandler("garagesSave", M.garagesSave)
    seedBundled(M.STATIONS_TYPE, sanitizeStations)
    seedBundled(M.GARAGES_TYPE, sanitizeGarages)
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData

M.energyStationsSave = energyStationsSave
M.garagesSave = garagesSave

return M
