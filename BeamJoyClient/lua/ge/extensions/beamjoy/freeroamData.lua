--- Client-side mirror of the server's per-map freeroam POI data (energy stations + garages, see
--- services/freeroamData.lua). Owns only the synced cache : the in-world editor
--- (ui/freeroamEditor.lua) and the refuel/repair gameplay + markers (beamjoy_stations) both read
--- M.data straight off here, so it stays correct regardless of whether an editor is even open and
--- refreshes for free on every cache push (join, save, map change).
---
--- Mirrors beamjoy/races.lua's own minimal cache-holder shape.

local M = {
    dependencies = {},

    data = {
        ---@type BJEnergyStation[]
        stations = {},
        ---@type BJGarage[]
        garages = {},
    },
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJEditorFreeroamDataRequest", M.pushListToUI)
end

--- lightweight snapshot for the config window's Freeroam tab sidebar : the editor seeds its own
--- point-lists from this on open, and the tab header shows the counts
local function pushListToUI()
    beamjoy_communications_ui.send("BJEditorFreeroamData", {
        stations = M.data.stations,
        garages = M.data.garages,
    })
end

---@param caches table
local function retrieveCache(caches)
    local changed = false
    if caches.stations then
        M.data.stations = caches.stations
        changed = true
    end
    if caches.garages then
        M.data.garages = caches.garages
        changed = true
    end
    if changed then
        extensions.hook("onBJFreeroamDataChanged")
        pushListToUI()
    end
end

---@param list table
local function saveStations(list)
    beamjoy_communications.send("energyStationsSave", list)
end

---@param list table
local function saveGarages(list)
    beamjoy_communications.send("garagesSave", list)
end

M.onInit = onInit

M.retrieveCache = retrieveCache
M.pushListToUI = pushListToUI
M.saveStations = saveStations
M.saveGarages = saveGarages

return M
