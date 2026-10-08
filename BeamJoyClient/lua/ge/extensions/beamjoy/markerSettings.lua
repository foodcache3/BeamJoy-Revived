--- Settings > Visual : a player can hide BeamJoy's in-world markers.
---  - hideActivities : the freeroam activity markers, bus line starts (beamjoy_busRun), delivery
---    depots (beamjoy_delivery), race starts (beamjoy_races) and derby arenas (beamjoy_derby)
---  - hideStations : energy stations and garages (beamjoy_stations)
--- Hidden means not contributed to the game's POI list at all, so the drive-up prompt (start a
--- line, the job board, refuel / repair) goes with the marker. The Big Map pins stay (they're a
--- separate list, onBJRequestBigmapPOIs).
--- Also Settings > Visual's other toggle :
---  - opaqueGhosts : ghosted vehicles (no collisions) are drawn solid instead of see-through
---    (beamjoy_vehicles.computeDisplayAlpha). Only the look : they're still ghosts.
--- Saved on this PC, shared between servers.
--- A passive race run (beamjoy_raceFreeroam) hides the activity markers too while it lasts (direct
--- request) : read activitiesHidden(), not hideActivities, for "are they shown".

local M = {
    hideActivities = false,
    hideStations = false,
    opaqueGhosts = false,
}

local function refreshPOIs()
    if bigmap and bigmap.updatePOIs then
        bigmap.updatePOIs()
    elseif extensions.gameplay_rawPois then
        extensions.gameplay_rawPois.clear()
    end
end

local function sendToUI()
    beamjoy_communications_ui.send("BJUserSettings", {
        markers = {
            hideActivities = M.hideActivities,
            hideStations = M.hideStations,
        },
        visual = {
            opaqueGhosts = M.opaqueGhosts,
        },
    })
end

local function onInit()
    M.hideActivities = localStorage.get(localStorage.GLOBAL_VALUES.HIDE_ACTIVITY_MARKERS) == true
    M.hideStations = localStorage.get(localStorage.GLOBAL_VALUES.HIDE_STATION_MARKERS) == true
    M.opaqueGhosts = localStorage.get(localStorage.GLOBAL_VALUES.OPAQUE_GHOSTS) == true
    beamjoy_communications_ui.addHandler("BJRequestVehicleSettings", sendToUI)
    beamjoy_communications_ui.addHandler("BJUserSettings", function(newSettings)
        local visual = type(newSettings) == "table" and newSettings.visual
        if type(visual) == "table" and type(visual.opaqueGhosts) == "boolean" and
            visual.opaqueGhosts ~= M.opaqueGhosts then
            M.opaqueGhosts = visual.opaqueGhosts
            localStorage.set(localStorage.GLOBAL_VALUES.OPAQUE_GHOSTS, M.opaqueGhosts)
            if beamjoy_vehicles and beamjoy_vehicles.reapplyDisplayAlpha then
                beamjoy_vehicles.reapplyDisplayAlpha()
            end
        end
        local markers = type(newSettings) == "table" and newSettings.markers
        if type(markers) ~= "table" then return end
        local changed = false
        if type(markers.hideActivities) == "boolean" and markers.hideActivities ~= M.hideActivities then
            M.hideActivities = markers.hideActivities
            localStorage.set(localStorage.GLOBAL_VALUES.HIDE_ACTIVITY_MARKERS, M.hideActivities)
            changed = true
        end
        if type(markers.hideStations) == "boolean" and markers.hideStations ~= M.hideStations then
            M.hideStations = markers.hideStations
            localStorage.set(localStorage.GLOBAL_VALUES.HIDE_STATION_MARKERS, M.hideStations)
            changed = true
        end
        if changed then refreshPOIs() end
    end)
end

--- the activity markers are hidden : the player's setting, or a passive race run going on
---@return boolean
function M.activitiesHidden()
    return M.hideActivities == true or (beamjoy_raceFreeroam ~= nil and beamjoy_raceFreeroam.run ~= nil)
end

-- markers go when a passive run starts and come back when it ends
local lastPassiveRun = false
local function onSlowUpdate()
    local running = beamjoy_raceFreeroam ~= nil and beamjoy_raceFreeroam.run ~= nil
    if running ~= lastPassiveRun then
        lastPassiveRun = running
        refreshPOIs()
    end
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate

return M
