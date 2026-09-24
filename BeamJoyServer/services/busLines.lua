--- Static, per-map bus-line data: an ordered list of stops per line. Persisted exactly like races
--- / freeroam stations (`dao_activity` -> `<map>_buslines.json`), seeded once from this mod's own
--- bundled content via `dao_bundled`.
---
--- Deliberately close to services/freeroamData.lua's single-list half (load on boot + map change,
--- sanitize only at save time with a defensive backfill on load, push the full list to every
--- player in `onBJRequestCache`, ack the sender explicitly). The gameplay side - picking a line,
--- driving it, the HUD, the markers - is entirely client-side in beamjoy/busRun.lua ; nothing
--- here validates or even sees an actual run, matching BJI's own "local activity, no server round
--- trip, no reward" treatment (BJI's BusMissionReward tx is not ported - BJS has no XP system).

---@class BJBusStop
---@field name string
---@field pos {x: number, y: number, z: number}
---@field dir {x: number, y: number, z: number} facing (forward vector, horizontal) - matches the
---rest of BJS's editors (hunter spawns etc.) ; the gameplay side feeds it straight to
---setVehiclePositionRotation, no quat conversion
---@field radius number metres, the trigger sphere the bus must stop inside

---@class BJBusLine
---@field id integer unique per map
---@field name string
---@field loopable boolean whether the last stop chains back to the first
---@field stops BJBusStop[] ordered, always >= 2 (a shorter line is dropped at sanitize time)

local M = {
    -- services_hunter is only needed for its quatToFlatDir helper (the legacy BJI importer below,
    -- converting a stop's quaternion rotation to BJS's own flat forward-vector convention)
    dependencies = { "dao_activity", "dao_bundled", "services_core", "services_hunter" },

    BUSLINES_TYPE = "buslines",

    MIN_RADIUS = 1,
    MAX_RADIUS = 10,
    DEFAULT_RADIUS = 3,
    MAX_NAME_LEN = 40,
    MIN_STOPS = 2,

    ---@type BJBusLine[] bus lines for the current map
    lines = {},
}

---@param v any
---@return boolean
local function validVec3(v)
    return type(v) == "table" and type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number"
end

--- assigns a stable unique integer id to every line missing one (or colliding), lowest free value
--- first - identical to freeroamData.assignIds / raceSave's own id allocation
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

--- mutates `list` in place (id assignment, name/loopable/stop normalization, dropping lines with
--- fewer than MIN_STOPS usable stops) ; returns an error string only for structurally
--- unrecoverable data
---@param list any
---@return string? error
local function sanitizeBusLines(list)
    if not table.isArray(list) then return "Invalid bus lines data" end
    for _, line in ipairs(list) do
        if type(line) ~= "table" or not table.isArray(line.stops) then
            return "Invalid bus line data"
        end
        for _, s in ipairs(line.stops) do
            if type(s) ~= "table" or not validVec3(s.pos) or not validVec3(s.dir) then
                return "Invalid bus stop data"
            end
        end
    end

    local kept = {}
    for i, line in ipairs(list) do
        local stops = {}
        for j, s in ipairs(line.stops) do
            stops[#stops + 1] = {
                name = cleanName(s.name, "Stop " .. j),
                pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z },
                dir = { x = s.dir.x, y = s.dir.y, z = s.dir.z },
                radius = cleanRadius(s.radius),
            }
        end
        if #stops >= M.MIN_STOPS then
            kept[#kept + 1] = {
                id = line.id,
                name = cleanName(line.name, "Line " .. i),
                loopable = line.loopable == true,
                stops = stops,
            }
        else
            LogInfo(string.format("sanitizeBusLines: dropped line %d (%s) - only %d stop(s)",
                i, tostring(line.name), #stops))
        end
    end
    -- rewrite the list in place with just the kept lines
    for k = #list, 1, -1 do list[k] = nil end
    for k, line in ipairs(kept) do list[k] = line end
    assignIds(list)
    return nil
end

--- load the list for the current map, called on boot and on map change
local function loadData()
    M.lines = dao_activity.get(services_core.getCurrentMap(), M.BUSLINES_TYPE) or {}
    -- sanitize only ever runs at save time (like races) ; a hand-edited or pre-feature file could
    -- still be missing ids / oversized names / a 1-stop line, all of which flow straight to every
    -- client. Normalize once here too. A structurally broken file just yields an empty list.
    if sanitizeBusLines(M.lines) then M.lines = {} end
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

local function saveBusLines()
    dao_activity.save(services_core.getCurrentMap(), M.BUSLINES_TYPE,
        #M.lines > 0 and M.lines or nil)
end

--- auto-imports this mod's own bundled default bus lines for any map that has none saved yet -
--- identical to services/freeroamData.lua's own seedBundled (per-entry "considered once ever"
--- ledger keyed by name, so a later deletion is never undone). Runs once at boot for every map
--- dao_bundled ships content for.
local function seedBundled()
    for _, mapName in ipairs(dao_bundled.listMapsForType(M.BUSLINES_TYPE)) do
        local bundled = dao_bundled.get(mapName, M.BUSLINES_TYPE)
        if table.isArray(bundled) then
            local targetList = dao_activity.get(mapName, M.BUSLINES_TYPE) or {}
            local changed = false
            for _, entry in ipairs(bundled) do
                local name = type(entry.name) == "string" and entry.name or ""
                if not dao_bundled.isSeeded(mapName, M.BUSLINES_TYPE, name) then
                    if table.any(targetList, function(e) return e.name == name end) then
                        LogInfo(string.format(
                            "seedBundled(buslines): skipped %s / %s, an entry with this name already exists",
                            mapName, name))
                    else
                        local candidate = table.deepcopy(entry)
                        table.insert(targetList, candidate)
                        local err = sanitizeBusLines(targetList)
                        if err then
                            table.remove(targetList)
                            LogError(string.format("seedBundled(buslines): %s / %s failed sanitation: %s",
                                mapName, name, err))
                        else
                            changed = true
                            LogInfo(string.format("seedBundled(buslines): seeded %s / %s", mapName, name))
                        end
                    end
                    dao_bundled.markSeeded(mapName, M.BUSLINES_TYPE, name)
                end
            end
            if changed then
                dao_activity.save(mapName, M.BUSLINES_TYPE, targetList)
            end
        end
    end
end

---@param caches table
local function onBJRequestCache(caches)
    -- visible to every player, not staff-gated : same reasoning as races / freeroam data (gameplay
    -- content, every client renders the markers and runs the drive loop locally)
    caches.buslines = M.lines
end

---@param ctxt BJSContext
---@param list table
local function busLinesSave(ctxt, list)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditBusLines) then
        local permErr = services_lang.get("error.insufficientPermissions", ctxt.sender.lang)
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", permErr)
        return communications_tx.sendToPlayer(ctxt.senderID, "busLinesSaved", false, permErr)
    end

    if not table.isArray(list) then list = {} end
    local err = sanitizeBusLines(list)
    if err then
        LogError(string.format("busLinesSaved rejected%s: %s",
            ctxt.sender and (" from " .. ctxt.sender.playerName) or "", err))
        dump(list)
        if ctxt.sender then
            communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
            return communications_tx.sendToPlayer(ctxt.senderID, "busLinesSaved", false, err)
        end
        return
    end

    M.lines = list
    saveBusLines()

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "busLinesSaved", true)
    end

    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

--- Legacy BeamJoy Improved (BJI) bus-lines importer. Confirmed against BJI's own real source
--- (`BeamJoyCore/dao/DaoFile/FileScenario.lua`, `my-name-is-samael/BeamJoy` on GitHub):
--- `<dbPath>/scenarii/<mapName>_buslines.json` (`_TYPES.BUS_LINES = "_buslines"`, concatenated
--- directly onto the map name with no separator - the underscore is baked into the suffix), a
--- plain JSON array of line objects, one file per map. NON-DESTRUCTIVE like every sibling
--- importer - every convertible line is ADDED as a new line, nothing already saved is touched.
--- No separate preview step, same reasoning as freeroamData.lua's own importer (nothing
--- meaningful to preview beyond the same counts the "done" toast reports - bus lines have no
--- name-collision concept either).
---
--- One real conversion needed: BJI stores each stop's facing as a quaternion (`rot`), not BJS's
--- own flat forward-vector `dir`. `services_hunter.quatToFlatDir` already does exactly this
--- conversion (the same helper races'/hunter's own legacy importers trust for the identical
--- purpose), reused here rather than re-deriving the same math a third time.
local LEGACY_DIR = "scenarii"
local LEGACY_BUSLINE_SUFFIX = "_buslines.json"

---@param filename string
---@param suffix string
---@return string? mapName
local function matchLegacyFilename(filename, suffix)
    return filename:match("^(.+)" .. suffix:gsub("%.", "%%.") .. "$")
end

---@param old table raw BJI line {name, loopable, stops: {name,pos,rot,radius}[]}
---@return table?
local function convertLegacyBusLine(old)
    if type(old) ~= "table" or not table.isArray(old.stops) then return nil end
    local stops = {}
    for _, s in ipairs(old.stops) do
        if type(s) == "table" and validVec3(s.pos) then
            stops[#stops + 1] = {
                name = s.name,
                pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z },
                dir = type(s.rot) == "table" and services_hunter.quatToFlatDir(s.rot) or { x = 1, y = 0, z = 0 },
                radius = s.radius,
            }
        end
    end
    if #stops < M.MIN_STOPS then return nil end
    return { name = old.name, loopable = old.loopable == true, stops = stops }
end

---@return table<string, table[]> map name -> converted lines
local function scanLegacyBusLines()
    local byMap = {}
    local dir = dao_main.dbPath .. "/" .. LEGACY_DIR
    if not FS.Exists(dir) then return byMap end
    for _, filename in pairs(FS.ListFiles(dir)) do
        local mapName = matchLegacyFilename(filename, LEGACY_BUSLINE_SUFFIX)
        if mapName then
            local raw = dao_main.get(LEGACY_DIR .. "/" .. filename)
            if table.isArray(raw) then
                byMap[mapName] = byMap[mapName] or {}
                for _, oldLine in ipairs(raw) do
                    local converted = convertLegacyBusLine(oldLine)
                    if converted then table.insert(byMap[mapName], converted) end
                end
            end
        end
    end
    return byMap
end

---@return {map: string, lineCount: integer}[]
local function previewLegacyBusLines()
    local results = {}
    for mapName, lines in pairs(scanLegacyBusLines()) do
        if #lines > 0 then
            table.insert(results, { map = mapName, lineCount = #lines })
        end
    end
    return results
end

---@param ctxt BJSContext
local function busLinesLegacyImportPreview(ctxt)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditBusLines) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end
    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "busLinesLegacyImportPreviewResult",
            previewLegacyBusLines())
    end
end

---@param ctxt BJSContext
local function busLinesLegacyImportConfirm(ctxt)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditBusLines) then
        local permErr = services_lang.get("error.insufficientPermissions", ctxt.sender.lang)
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", permErr)
        return communications_tx.sendToPlayer(ctxt.senderID, "busLinesLegacyImportDone", 0)
    end

    local imported = 0
    for mapName, lines in pairs(scanLegacyBusLines()) do
        if #lines > 0 then
            local isCurrentMap = mapName == services_core.getCurrentMap()
            local target = isCurrentMap and M.lines or (dao_activity.get(mapName, M.BUSLINES_TYPE) or {})
            for _, line in ipairs(lines) do
                table.insert(target, line)
                imported = imported + 1
            end
            sanitizeBusLines(target)
            if isCurrentMap then M.lines = target end
            dao_activity.save(mapName, M.BUSLINES_TYPE, #target > 0 and target or nil)
        end
    end

    if imported > 0 then
        services_players.players:forEach(function(p)
            local caches = {}
            M.onBJRequestCache(caches)
            communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
        end)
    end

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "busLinesLegacyImportDone", imported)
    end
end

local function onInit()
    communications_rx.addHandler("busLinesSave", M.busLinesSave)
    communications_rx.addHandler("busLinesLegacyImportPreview", M.busLinesLegacyImportPreview)
    communications_rx.addHandler("busLinesLegacyImportConfirm", M.busLinesLegacyImportConfirm)
    seedBundled()
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData

M.busLinesSave = busLinesSave
M.busLinesLegacyImportPreview = busLinesLegacyImportPreview
M.busLinesLegacyImportConfirm = busLinesLegacyImportConfirm

return M
