local M = {}

-- the runners whose `session` is set from joining a lobby until the game is over
local RUNNERS = { "beamjoy_raceRunner", "beamjoy_hunterRunner", "beamjoy_infectedRunner", "beamjoy_derbyRunner" }

---@return boolean in a race, hunt, infected or derby (lobby or game), a delivery job or convoy, or a bus line
local function inActivity()
    for _, name in ipairs(RUNNERS) do
        local runner = extensions[name]
        if runner and runner.session then return true end
    end
    local delivery = extensions.beamjoy_delivery
    if delivery and (delivery.job or delivery.lobby) then return true end
    local bus = extensions.beamjoy_busRun
    return bus ~= nil and bus.run ~= nil
end

local wasInActivity = false
-- the route as it was the frame before joining : setPath always stores a new waypoint table, so a
-- route an activity sets the moment it starts is never this one
local ownRoute

--- a route set before joining an activity (the big map, a POI) is cleared when joining one
local function onUpdate()
    local gm = extensions.core_groundMarkers
    if not gm then return end
    local busy = inActivity()
    if busy and not wasInActivity and gm.endWP and gm.endWP == ownRoute then
        gm.setPath(nil)
    end
    wasInActivity = busy
    ownRoute = not busy and gm.endWP or nil
end

local function onSlowUpdate()
    local mpVeh = beamjoy_vehicles.getCurrent()
    if not mpVeh then return end
    local pos = beamjoy_vehicles.getVehiclePositionRotation(mpVeh.veh)

    local wps = extensions.core_groundMarkers.endWP or {}
    if wps[1] and pos:distance(vec3(wps[1])) < 5 then
        extensions.core_groundMarkers.setPath(table.filter(wps,
            function(_, i) return i > 1 end))
        if extensions.freeroam_bigMapMode.bigMapActive() then
            extensions.freeroam_bigMapMode.setNavFocus(extensions.core_groundMarkers.endWP[1])
        end
    end
end

M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate
-- also used by beamjoy_pursuit : no pursuits while in an activity
M.inActivity = inActivity

return M
