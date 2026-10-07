--- BeamJoy's own drift zones (passive zones step 3, see TODO.md) : made in Config > Freeroam > Drift
--- zones, stored per map like the drag strips (`dao_activity` -> `<map>_driftzones.json`) and run by
--- each player's own game (beamjoy/driftZones.lua), scored by the game's own drift scorer. Runs go
--- on the same Drift boards as the game's own drift spots (services/freeroamChallenges.lua), under
--- an id that can't collide with the game's ("bj:<id>").

---@class BJDriftZone
---@field id integer unique per map
---@field name string
---@field width number metres : the corridor along the route, and the start / finish gates' width
---@field points {x: number, y: number, z: number}[] the route : the start gate, any number of points
---along the way, the finish gate (2 to MAX_POINTS)

local M = {
    dependencies = { "dao_activity", "services_core", "services_players", "services_permissions",
        "services_lang", "communications_rx", "communications_tx" },

    TYPE = "driftzones",
    MAX_ZONES = 30,
    MAX_POINTS = 40,
    MAX_NAME_LEN = 40,
    MIN_WIDTH = 6,
    MAX_WIDTH = 60,
    DEFAULT_WIDTH = 16,

    ---@type BJDriftZone[] the current map's zones
    zones = {},
}

---@param v any
---@return {x: number, y: number, z: number}?
local function point(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = tonumber(v.x), tonumber(v.y), tonumber(v.z)
    if not x or not y or not z or x ~= x or y ~= y or z ~= z then return nil end
    return { x = x, y = y, z = z }
end

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

--- the zones as they're kept : well-formed points only, at least a start and a finish
---@param list any
---@return BJDriftZone[]? zones, string? err
local function sanitize(list)
    if not table.isArray(list) then return nil, "Invalid drift zone data" end
    if #list > M.MAX_ZONES then return nil, string.format("Up to %d drift zones per map", M.MAX_ZONES) end
    local out = {}
    for i, z in ipairs(list) do
        if type(z) ~= "table" then return nil, "Invalid drift zone data" end
        local points = {}
        for _, p in ipairs(type(z.points) == "table" and z.points or {}) do
            local clean = point(p)
            if clean and #points < M.MAX_POINTS then points[#points + 1] = clean end
        end
        if #points >= 2 then
            local name = type(z.name) == "string" and z.name:trim() or ""
            if #name == 0 then name = "Drift zone " .. i end
            out[#out + 1] = {
                id = z.id,
                name = name:sub(1, M.MAX_NAME_LEN),
                width = math.clamp(tonumber(z.width) or M.DEFAULT_WIDTH, M.MIN_WIDTH, M.MAX_WIDTH),
                points = points,
            }
        end
    end
    assignIds(out)
    return out
end

local function pushToAll()
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

local function loadData()
    M.zones = sanitize(dao_activity.get(services_core.getCurrentMap(), M.TYPE) or {}) or {}
    pushToAll()
end

---@param caches table
local function onBJRequestCache(caches)
    -- every player : each one's own game runs the zones
    caches.driftzones = M.zones
end

---@param ctxt BJSContext
---@param list table
local function driftZonesSave(ctxt, list)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditFreeroamData) then
        local err = services_lang.get("error.insufficientPermissions", ctxt.sender.lang)
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
        return communications_tx.sendToPlayer(ctxt.senderID, "driftZonesSaved", false, err)
    end
    local zones, err = sanitize(list)
    if not zones then
        LogError(string.format("driftZonesSave rejected%s: %s",
            ctxt.sender and (" from " .. ctxt.sender.playerName) or "", err))
        if ctxt.sender then
            communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
            communications_tx.sendToPlayer(ctxt.senderID, "driftZonesSaved", false, err)
        end
        return
    end
    M.zones = zones
    dao_activity.save(services_core.getCurrentMap(), M.TYPE, #zones > 0 and zones or nil)
    if ctxt.sender then communications_tx.sendToPlayer(ctxt.senderID, "driftZonesSaved", true) end
    pushToAll()
end

local function onInit()
    communications_rx.addHandler("driftZonesSave", M.driftZonesSave)
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData
M.driftZonesSave = driftZonesSave

return M
