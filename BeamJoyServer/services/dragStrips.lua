--- BeamJoy's own drag strips (passive zones step 2, see TODO.md) : made in Config > Freeroam > Drag
--- strips, stored per map like bus lines (`dao_activity` -> `<map>_dragstrips.json`) and run by
--- each player's own game (beamjoy/dragStrips.lua) : the lanes, the on-screen tree, the timers.
--- Runs go on the same Drag boards as the game's own strips (services/freeroamChallenges.lua),
--- under an id that can't collide with the game's ("bj:<id>"), and two players in opposite lanes
--- pair through that same module's drag lanes.

---@class BJDragStrip
---@field id integer unique per map
---@field name string
---@field length "1_4"|"1_8"|"1000" the timed distance : a quarter mile, an eighth, 1000 ft
---@field tree "sportsman"|"pro" sportsman : three ambers half a second apart, then green ; pro :
---the three together, green 0.4 s later
---@field laneWidth number metres
---@field lanes {pos: {x: number, y: number, z: number}, dir: {x: number, y: number, z: number}}[]
---each lane's start line (its middle) and the way the lane runs, 1 to MAX_LANES

local M = {
    dependencies = { "dao_activity", "services_core", "services_players", "services_permissions",
        "services_lang", "communications_rx", "communications_tx" },

    TYPE = "dragstrips",
    LENGTHS = { "1_4", "1_8", "1000" },
    TREES = { "sportsman", "pro" },
    MAX_LANES = 4,
    MAX_STRIPS = 30,
    MAX_NAME_LEN = 40,
    MIN_LANE_WIDTH = 2,
    MAX_LANE_WIDTH = 8,
    DEFAULT_LANE_WIDTH = 4,

    ---@type BJDragStrip[] the current map's strips
    strips = {},
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

--- the strips as they're kept : only well-formed lanes, at least one per strip
---@param list any
---@return BJDragStrip[]? strips, string? err
local function sanitize(list)
    if not table.isArray(list) then return nil, "Invalid drag strip data" end
    if #list > M.MAX_STRIPS then return nil, string.format("Up to %d drag strips per map", M.MAX_STRIPS) end
    local out = {}
    for i, s in ipairs(list) do
        if type(s) ~= "table" then return nil, "Invalid drag strip data" end
        local lanes = {}
        for _, lane in ipairs(type(s.lanes) == "table" and s.lanes or {}) do
            local pos, dir = point(type(lane) == "table" and lane.pos), point(type(lane) == "table" and lane.dir)
            if pos and dir and (dir.x ~= 0 or dir.y ~= 0) and #lanes < M.MAX_LANES then
                local len = math.sqrt(dir.x * dir.x + dir.y * dir.y)
                lanes[#lanes + 1] = { pos = pos, dir = { x = dir.x / len, y = dir.y / len, z = 0 } }
            end
        end
        if #lanes > 0 then
            local name = type(s.name) == "string" and s.name:trim() or ""
            if #name == 0 then name = "Drag strip " .. i end
            out[#out + 1] = {
                id = s.id,
                name = name:sub(1, M.MAX_NAME_LEN),
                length = table.includes(M.LENGTHS, s.length) and s.length or "1_4",
                tree = table.includes(M.TREES, s.tree) and s.tree or "sportsman",
                laneWidth = math.clamp(tonumber(s.laneWidth) or M.DEFAULT_LANE_WIDTH, M.MIN_LANE_WIDTH,
                    M.MAX_LANE_WIDTH),
                lanes = lanes,
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
    M.strips = sanitize(dao_activity.get(services_core.getCurrentMap(), M.TYPE) or {}) or {}
    pushToAll()
end

---@param caches table
local function onBJRequestCache(caches)
    -- every player : each one's own game runs the strips
    caches.dragstrips = M.strips
end

---@param ctxt BJSContext
---@param list table
local function dragStripsSave(ctxt, list)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditFreeroamData) then
        local err = services_lang.get("error.insufficientPermissions", ctxt.sender.lang)
        communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
        return communications_tx.sendToPlayer(ctxt.senderID, "dragStripsSaved", false, err)
    end
    local strips, err = sanitize(list)
    if not strips then
        LogError(string.format("dragStripsSave rejected%s: %s",
            ctxt.sender and (" from " .. ctxt.sender.playerName) or "", err))
        if ctxt.sender then
            communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
            communications_tx.sendToPlayer(ctxt.senderID, "dragStripsSaved", false, err)
        end
        return
    end
    M.strips = strips
    dao_activity.save(services_core.getCurrentMap(), M.TYPE, #strips > 0 and strips or nil)
    if ctxt.sender then communications_tx.sendToPlayer(ctxt.senderID, "dragStripsSaved", true) end
    pushToAll()
end

local function onInit()
    communications_rx.addHandler("dragStripsSave", M.dragStripsSave)
    loadData()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData
M.dragStripsSave = dragStripsSave

return M
