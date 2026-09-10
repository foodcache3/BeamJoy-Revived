local M = {
    dependencies = { "camera", "beamjoy_vehicles", "beamjoy_players" },

    lastGen = 0,
    ---@type TickContext?
    ctxt = nil,
}

local function onVehicleDestroyed(vid)
    if M.ctxt and M.ctxt.mpVeh and M.ctxt.mpVeh.vid == vid then
        M.ctxt.mpVeh = nil
    end
end

---@return TickContext
local function get()
    local now = GetCurrentTimeMillis()
    local gen = math.round(now / 100)
    if not M.ctxt or M.lastGen < gen then
        local mpVeh = beamjoy_vehicles.getCurrent()
        M.ctxt = {
            now = now,
            camera = camera.getCamera(),
            self = beamjoy_players.getSelf(),
            players = beamjoy_players.players,
            mpVeh = mpVeh,
        }
        M.lastGen = gen
    end
    return M.ctxt
end

--- true whenever a BJS activity (Race, Hunter, Infected) is in its frozen/locked window
--- (COUNTDOWN through the active state) : the one window where scenario-integrity restrictions
--- apply and freeroam conveniences (Big Map, refuel/repair, ...) should be suppressed. Each
--- runner owns its own identically-shaped predicate ; this is the single place the three get
--- OR'd so a new mode (derby, ...) only has to be added here, not hunted down across every
--- consumer. Runner globals are referenced defensively (not declared deps) exactly as
--- bigmap.lua already does : all runners are loaded before anything calls this at runtime.
---
--- NOT an authorization decision : a per-interaction "may THIS happen" call (e.g. Hunter allowing
--- refuel but not repair) goes through its own request hook, not this boolean. See
--- onBJRequestStationInteraction.
---@return boolean
local function isScenarioLocked()
    return (beamjoy_raceRunner and beamjoy_raceRunner.isRaceLocked()) or
        (beamjoy_hunterRunner and beamjoy_hunterRunner.isHuntLocked()) or
        (beamjoy_infectedRunner and beamjoy_infectedRunner.isGameLocked()) or
        false
end

--- whether freeroam energy stations / garages (BJS-placed AND the map's own gas stations) are
--- usable right now. Freeroam : always. During a round : no, unless that mode's arena has its
--- `allowStations` default on (races have no opt-in). The active runner answers via the
--- `onBJRequestStationInteraction` hook (kind == nil). Used by both bigmap.lua (POI/marker
--- filtering) and beamjoy_stations.
---@return boolean
local function stationsAllowed()
    if not isScenarioLocked() then return true end
    local req = CreateRequestAuthorization(true)
    extensions.hook("onBJRequestStationInteraction", req, nil)
    return req.state
end

M.onVehicleDestroyed = onVehicleDestroyed

M.get = get
M.isScenarioLocked = isScenarioLocked
M.stationsAllowed = stationsAllowed

return M
