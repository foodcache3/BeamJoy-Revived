local defaultData = { -- inject default data per map
    gridmap_v2 = {
        safeZones = {},
    }
}

local M = {
    dependencies = { "services_core" },
    ACTIVITY_TYPE = {
        SAFE_ZONES = "safeZones",
    },

    safeZones = {
        ---@type GizmoObject[]?
        data = nil,
    },
}

---@param ctxt BJSContext
---@param newZones GizmoObject[]
function M.safeZones.save(ctxt, newZones)
    if not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditSafeZones) then
        return
    end

    local previous = M.safeZones.data
    M.safeZones.data = newZones
    local ok = pcall(dao_activity.save, services_core.getCurrentMap(),
        M.ACTIVITY_TYPE.SAFE_ZONES, M.safeZones.data)
    if not ok then
        M.safeZones.data = previous
    end
    communications_tx.sendToPlayer(ctxt.senderID, "safeZonesSaved", ok,
        ok and M.safeZones.data or nil)
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches, p.playerID)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

--- load activity data after the server boot and a map change
local function loadData()
    local map = services_core.getCurrentMap()

    table.forEach(M.ACTIVITY_TYPE, function(acType)
        M[acType].data = dao_activity.get(map, acType)
        if not M[acType].data then
            M[acType].data = defaultData[map] and defaultData[map][acType] or {}
        end
    end)
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches, p.playerID)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

local function onInit()
    communications_rx.addHandler("safeZonesSave", M.safeZones.save)

    loadData()
end

---@param caches table
local function onBJRequestCache(caches, targetID)
    caches.activities = {}
    table.forEach(M.ACTIVITY_TYPE, function(acType)
        caches.activities[acType] = M[acType].data
    end)

    -- TODO per group data filtering if necessary
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onMapChanged = loadData

return M
