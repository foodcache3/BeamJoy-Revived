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
    -- BeamJoy Free import (Config > Core > Legacy Import), same bridge as beamjoy_freeroamData's
    beamjoy_communications_ui.addHandler("BJDeliveryPointsLegacyImportPreviewRequest", function()
        beamjoy_communications.send("deliveryPointsLegacyImportPreview")
    end)
    beamjoy_communications_ui.addHandler("BJDeliveryPointsLegacyImportConfirm", function(selection)
        beamjoy_communications.send("deliveryPointsLegacyImportConfirm", selection)
    end)
    beamjoy_communications.addHandler("deliveryPointsLegacyImportPreviewResult", function(results)
        beamjoy_communications_ui.send("BJDeliveryPointsLegacyImportPreview", results or {})
    end)
    beamjoy_communications.addHandler("deliveryPointsLegacyImportDone", M.onLegacyImportDone)
end

--- the new points only get jobs once their road lengths are measured, which happens when the
--- delivery editor saves on that map : the toast says where
---@param count integer
---@param maps string[]
local function onLegacyImportDone(count, maps)
    maps = type(maps) == "table" and maps or {}
    if (count or 0) == 0 then
        return toast.info(beamjoy_lang.translate("beamjoy.window.config.tabs.core.legacyImport.deliveries.doneNone"), nil, 6)
    end
    toast.info(beamjoy_lang.translate("beamjoy.window.config.tabs.core.legacyImport.deliveries.done")
        :gsub("{count}", tostring(count)):gsub("{maps}", table.concat(maps, ", ")), nil, 15)
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
M.onLegacyImportDone = onLegacyImportDone
M.getPoint = getPoint

return M
