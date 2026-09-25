--- Client-side mirror of the server's per-map delivery points (see services/deliveryPoints.lua).
--- Owns only the synced cache : the in-world editor (ui/deliveryEditor.lua) and the delivery
--- gameplay read M.data.points straight off here, so it refreshes for free on every cache push
--- (join, save, map change). Route lengths stay server-side.
---
--- Mirrors beamjoy/busLines.lua's own minimal cache-holder shape.

local M = {
    dependencies = {},

    data = {
        ---@type BJDeliveryPoint[]
        points = {},
    },
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
end

---@param caches table
local function retrieveCache(caches)
    if caches.deliveryPoints then
        M.data.points = caches.deliveryPoints
        extensions.hook("onBJDeliveryPointsChanged")
    end
end

---@param id integer
---@return BJDeliveryPoint?
local function getPoint(id)
    for _, p in ipairs(M.data.points) do
        if p.id == id then return p end
    end
end

M.onInit = onInit

M.retrieveCache = retrieveCache
M.getPoint = getPoint

return M
