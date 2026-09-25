--- Static, per-map delivery data (Phase 3): delivery points, and the road lengths between them.
--- Persisted like every other freeroam list (`dao_activity` -> `<map>_deliverypoints.json` and
--- `<map>_deliveryroutes.json`), same load-on-boot/map-change, sanitize-at-save, full-list cache
--- push and explicit editor ack as services/freeroamData.lua.
---
--- A point is tagged with what it sends (`provides`) and what it accepts (`receives`). A point that
--- sends anything is a depot: it offers jobs. A job is two legs: pick up at the depot, drop off at
--- a compatible point (a zone with a short hold, see the client runner).
---
--- Route lengths are measured by the saving admin's client (the server has no road graph), once
--- per save, only for the pairs a job could actually use, and sent along with the points. Job
--- generation then never needs a GPS route at runtime. Routes stay server-side: clients only get
--- the points in their cache.

---@class BJDeliverySlot
---@field pos {x: number, y: number, z: number}
---@field dir {x: number, y: number, z: number} flat forward vector, same convention as bus stops

---@class BJDeliveryPoint
---@field id integer unique per map
---@field name string
---@field pos {x: number, y: number, z: number} zone center (pickup and drop-off)
---@field radius number metres, the zone a vehicle must hold inside
---@field provides string[] subset of M.PROVIDE_TYPES ; non-empty = a depot
---@field receives string[] subset of M.RECEIVE_TYPES
---@field slots BJDeliverySlot[]? vehicle-delivery start slots (one per convoy member, max
---M.MAX_SLOTS), only kept when the point provides vehicles

local M = {
    dependencies = { "dao_activity", "services_core" },

    POINTS_TYPE = "deliverypoints",
    ROUTES_TYPE = "deliveryroutes",

    PROVIDE_TYPES = { "packages", "vehicles" },
    RECEIVE_TYPES = { "packages", "cars", "trucks" },

    MIN_RADIUS = 3,
    MAX_RADIUS = 30,
    DEFAULT_RADIUS = 8,
    MAX_NAME_LEN = 40,
    MAX_SLOTS = 4,
    -- sanity cap on a measured route ; anything longer is a broken measurement, not a real road
    MAX_ROUTE_METERS = 100000,

    ---@type BJDeliveryPoint[] delivery points for the current map
    points = {},
    ---@type table<integer, table<integer, number>> routes[fromId][toId] = metres
    routes = {},
}

---@param v any
---@return boolean
local function validVec3(v)
    return type(v) == "table" and type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number"
end

--- same id allocation as freeroamData / busLines / raceSave
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

--- filters to `allowed`, de-duped, in `allowed`'s own order so saves are stable
---@param list any
---@param allowed string[]
---@return string[]
local function cleanTags(list, allowed)
    local present = {}
    if table.isArray(list) then
        for _, t in ipairs(list) do present[t] = true end
    end
    local clean = {}
    for _, t in ipairs(allowed) do
        if present[t] then clean[#clean + 1] = t end
    end
    return clean
end

---@param slots any
---@return BJDeliverySlot[]
local function cleanSlots(slots)
    local clean = {}
    if table.isArray(slots) then
        for _, s in ipairs(slots) do
            if #clean >= M.MAX_SLOTS then break end
            if type(s) == "table" and validVec3(s.pos) and validVec3(s.dir) then
                clean[#clean + 1] = {
                    pos = { x = s.pos.x, y = s.pos.y, z = s.pos.z },
                    dir = { x = s.dir.x, y = s.dir.y, z = s.dir.z },
                }
            end
        end
    end
    return clean
end

--- mutates `list` in place ; returns an error string only for structurally unrecoverable data.
--- Never drops or reorders a point, so the editor's 1-based route indices stay valid across it.
---@param list any
---@return string? error
local function sanitizePoints(list)
    if not table.isArray(list) then return "Invalid delivery points data" end
    for _, p in ipairs(list) do
        if type(p) ~= "table" or not validVec3(p.pos) then
            return "Invalid delivery point position data"
        end
    end
    for i, p in ipairs(list) do
        p.pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z }
        p.name = cleanName(p.name, "Delivery point " .. i)
        p.radius = cleanRadius(p.radius)
        p.provides = cleanTags(p.provides, M.PROVIDE_TYPES)
        p.receives = cleanTags(p.receives, M.RECEIVE_TYPES)
        local slots = table.includes(p.provides, "vehicles") and cleanSlots(p.slots) or {}
        p.slots = #slots > 0 and slots or nil
    end
    assignIds(list)
    return nil
end

---@param point BJDeliveryPoint
---@return boolean
local function isDepot(point)
    return #point.provides > 0
end

--- whether a job could run from `from` to `to`, and which kinds of cargo it could carry
---@param from BJDeliveryPoint
---@param to BJDeliveryPoint
---@return boolean packages, boolean vehicles
local function pairKinds(from, to)
    if from.id == to.id then return false, false end
    local packages = table.includes(from.provides, "packages") and table.includes(to.receives, "packages")
    local vehicles = table.includes(from.provides, "vehicles") and
        (table.includes(to.receives, "cars") or table.includes(to.receives, "trucks"))
    return packages, vehicles
end

---@param from BJDeliveryPoint
---@param to BJDeliveryPoint
---@return boolean
local function isJobPair(from, to)
    local packages, vehicles = pairKinds(from, to)
    return packages or vehicles
end

--- a pair whose road length is kept : a job pair, or a leg between two package drop-offs
--- (multi-stop jobs go depot -> stop -> stop)
---@param from BJDeliveryPoint
---@param to BJDeliveryPoint
---@return boolean
local function isRoutePair(from, to)
    if from.id == to.id then return false end
    return isJobPair(from, to) or
        (table.includes(from.receives, "packages") and table.includes(to.receives, "packages"))
end

--- flat saved form [[fromId, toId, metres], ...] -> routes[fromId][toId], keeping only pairs that
--- still exist and still make sense as a job (a later tag edit can orphan a stored route)
---@param flat any
---@param points BJDeliveryPoint[]
---@return table<integer, table<integer, number>>
local function indexRoutes(flat, points)
    local byId = {}
    for _, p in ipairs(points) do byId[p.id] = p end
    local routes = {}
    if table.isArray(flat) then
        for _, r in ipairs(flat) do
            local from, to = table.isArray(r) and byId[r[1]], table.isArray(r) and byId[r[2]]
            local meters = table.isArray(r) and tonumber(r[3])
            if from and to and meters and meters > 0 and meters <= M.MAX_ROUTE_METERS and isRoutePair(from, to) then
                routes[from.id] = routes[from.id] or {}
                routes[from.id][to.id] = math.round(meters)
            end
        end
    end
    return routes
end

---@param routes table<integer, table<integer, number>>
---@return table[] flat [[fromId, toId, metres], ...]
local function flattenRoutes(routes)
    local flat = {}
    for fromId, targets in pairs(routes) do
        for toId, meters in pairs(targets) do
            flat[#flat + 1] = { fromId, toId, meters }
        end
    end
    table.sort(flat, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
    return flat
end

local function pushCacheToAll()
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

--- load points + routes for the current map, called on boot and on map change
local function loadData()
    local map = services_core.getCurrentMap()
    M.points = dao_activity.get(map, M.POINTS_TYPE) or {}
    if sanitizePoints(M.points) then M.points = {} end
    M.routes = indexRoutes(dao_activity.get(map, M.ROUTES_TYPE), M.points)
    extensions.hook("onBJDeliveryPointsChanged")
    pushCacheToAll()
end

---@param caches table
local function onBJRequestCache(caches)
    -- visible to every player : every client renders the depot markers and runs its own job
    caches.deliveryPoints = M.points
end

--- payload from the editor : `{points = BJDeliveryPoint[], routes = [[fromIndex, toIndex, metres]]}`
--- with 1-based indices into `points` (new points have no id until assignIds runs here)
---@param ctxt BJSContext
---@param payload table
local function deliveryPointsSave(ctxt, payload)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditFreeroamData) then
        local permErr = services_lang.get("error.insufficientPermissions", ctxt.sender.lang)
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", permErr)
        return communications_tx.sendToPlayer(ctxt.senderID, "deliveryPointsSaved", false, permErr)
    end

    payload = type(payload) == "table" and payload or {}
    local list = table.isArray(payload.points) and payload.points or {}
    local err = sanitizePoints(list)
    if err then
        LogError(string.format("deliveryPointsSaved rejected%s: %s",
            ctxt.sender and (" from " .. ctxt.sender.playerName) or "", err))
        if ctxt.sender then
            communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
            return communications_tx.sendToPlayer(ctxt.senderID, "deliveryPointsSaved", false, err)
        end
        return
    end

    -- index -> id, now that every point has one
    local flat = {}
    if table.isArray(payload.routes) then
        for _, r in ipairs(payload.routes) do
            local from = table.isArray(r) and list[tonumber(r[1]) or 0]
            local to = table.isArray(r) and list[tonumber(r[2]) or 0]
            if from and to then flat[#flat + 1] = { from.id, to.id, r[3] } end
        end
    end

    M.points = list
    M.routes = indexRoutes(flat, list)
    local map = services_core.getCurrentMap()
    dao_activity.save(map, M.POINTS_TYPE, #M.points > 0 and M.points or nil)
    local flatSaved = flattenRoutes(M.routes)
    dao_activity.save(map, M.ROUTES_TYPE, #flatSaved > 0 and flatSaved or nil)

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "deliveryPointsSaved", true)
    end
    extensions.hook("onBJDeliveryPointsChanged")
    pushCacheToAll()
end

--- the editor seeds its "already measured" cache from this on open, so a save only re-measures
--- pairs whose points actually moved
---@param ctxt BJSContext
local function deliveryRoutesRequest(ctxt)
    if not ctxt.sender or not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditFreeroamData) then
        return
    end
    communications_tx.sendToPlayer(ctxt.senderID, "deliveryRoutes", flattenRoutes(M.routes))
end

---@param id integer
---@return BJDeliveryPoint?
local function getPoint(id)
    for _, p in ipairs(M.points) do
        if p.id == id then return p end
    end
end

---@param fromId integer
---@param toId integer
---@return number? metres
local function getRouteLength(fromId, toId)
    return M.routes[fromId] and M.routes[fromId][toId]
end

local function onInit()
    communications_rx.addHandler("deliveryPointsSave", M.deliveryPointsSave)
    communications_rx.addHandler("deliveryRoutesRequest", M.deliveryRoutesRequest)
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData

M.deliveryPointsSave = deliveryPointsSave
M.deliveryRoutesRequest = deliveryRoutesRequest
M.getPoint = getPoint
M.getRouteLength = getRouteLength
M.isDepot = isDepot
M.pairKinds = pairKinds

return M
