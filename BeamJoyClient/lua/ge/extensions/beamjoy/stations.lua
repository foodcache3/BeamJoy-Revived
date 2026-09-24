--- Freeroam energy stations (refuel) and garages (repair). Client-only gameplay on top of the
--- per-map data synced by beamjoy_freeroamData (server: services/freeroamData.lua).
---
--- Fully native : stations/garages are contributed as real POIs via `onGetRawPoiListForLevel`
--- with a `missionMarker`, so the game's own gameplay_playmodeMarkers / gameplay_markerInteraction
--- render them and drive the drive-up prompt - exactly the path the map's own gas stations use,
--- which is the one that reliably works with parked vehicles in multiplayer. The Refuel / Repair
--- button is added through `onActivityAcceptGatherData`, the same hook native gas stations use.
--- The ground ring is suppressed each frame so it's just the floating icon (per preference).
---
--- Refuel uses `core_vehicleBridge` ; repair is an in-place `spawn.safeTeleport` reset routed
--- through beamjoy_inputs' own REPAIR gate. Big Map presence is the `onBJRequestBigmapPOIs` hook
--- (see bigmap.lua). Everything is local : nothing here round-trips to the server.
---
--- During a Race / Hunter / Infected round all of this (and the map's OWN gas stations) is hidden
--- and refused, unless the mode's arena has `allowStations` on (races: never). The actual filter
--- is in bigmap.lua's getRawPOIs - it strips every fuel/repair POI from the one list every
--- consumer reads - gated on beamjoy_context.stationsAllowed().

local M = {
    dependencies = { "beamjoy_lang", "beamjoy_freeroamData", "beamjoy_context", "beamjoy_vehicles" },

    -- kept in sync with services/freeroamData.lua
    ENERGY_TYPES = { gasoline = true, diesel = true, kerosine = true, n2o = true, electricEnergy = true },
    DEFAULT_FUEL_TYPES = { "gasoline", "diesel", "kerosine", "n2o" },

    -- the subset of ENERGY_TYPES that actually strands you when empty - n2o is a boost consumable,
    -- not something the low-fuel HUD warning / emergency refuel should ever react to
    PROPULSION_TYPES = { gasoline = true, diesel = true, kerosine = true, electricEnergy = true },

    LOW_FUEL_RATIO = 0.15,         -- "set GPS to nearest station" HUD button appears at/below this
    EMPTY_FUEL_RATIO = 0.02,       -- "emergency refuel" HUD button appears at/below this
    EMERGENCY_REFUEL_RATIO = 0.15, -- how full an emergency refuel leaves the tank - just enough to
                                    -- reach a real station, not a free full fill
    EMERGENCY_REFUEL_COOLDOWN_MS = 5 * 60 * 1000, -- fallback default, overridden by the host-
                                    -- configurable Freeroam.EmergencyRefuelCooldown when set
    EMERGENCY_REFUEL_HOLD_SECONDS = 10, -- per direct request : same freeze-and-hold as a real refuel

    ---@type { kind: "refuel"|"repair", vid: integer, endMs: integer, item: table }?
    process = nil,

    -- last state pushed to the HUD (BJFuelStatus) ; only re-sent on change, not every poll
    fuelStatus = { low = false, empty = false, type = nil },
    -- vid -> GetCurrentTimeMillis() of the last emergency refuel granted to that vehicle instance
    lastEmergencyRefuel = {},

    -- vid -> {tankName -> currentEnergy}, captured ONCE per vehicle instance, the moment it's
    -- ready (onBJVehicleInstantiated below) - see applyRefuel's own doc comment for why
    spawnFuelLevels = {},

    --- true while ui/freeroamEditor.lua is open : it draws its own markers, so our POIs stand down
    editorActive = false,

    ---@type table<string, table> our POI id -> station/garage, for onActivityAcceptGatherData
    itemById = {},
}

--- alias : beamjoy_context owns this (bigmap.lua's POI filter uses it too)
local function stationsAllowed()
    return beamjoy_context.stationsAllowed()
end

-- DATA ---------------------------------------------------------------------------------------

---@param item table a station OR a pump - both share the same `types` field/semantics
---@return table<string, true> energyType set this item fills
local function resolveStationTypes(item)
    local set = {}
    local src = (type(item.types) == "table" and #item.types > 0) and item.types or M.DEFAULT_FUEL_TYPES
    for _, t in ipairs(src) do
        if M.ENERGY_TYPES[t] then set[t] = true end
    end
    return set
end

---@return table[] garages
local function allGarages()
    local data = beamjoy_freeroamData.data
    local garages = {}
    for _, g in ipairs(data.garages or {}) do garages[#garages + 1] = g end
    return garages
end

--- Per direct request : individual pumps/chargers, each its own real world position with its own
--- fuel type(s), not just one shared type list for the whole station. A station with pumps stops
--- contributing its OWN single refuel point entirely - every pump does instead, each a genuinely
--- separate marker/prompt/trigger a player walks up to independently. A station with NO pumps
--- (every legacy-imported one, and the vast majority of newly-placed ones) behaves exactly as
--- before : one point, at the station's own pos/radius/types.
---@return table[] refuelPoints each `{pos, radius, types, name, id}` - a real station (no pumps) or
---a synthetic per-pump view (`id` = "<stationId>_<pumpIndex>", `name` = the station's own name)
local function allRefuelPoints()
    local data = beamjoy_freeroamData.data
    local points = {}
    for _, s in ipairs(data.stations or {}) do
        if type(s.pumps) == "table" and #s.pumps > 0 then
            for pi, p in ipairs(s.pumps) do
                points[#points + 1] = {
                    id = tostring(s.id) .. "_" .. tostring(pi),
                    pos = p.pos,
                    radius = p.radius,
                    types = p.types,
                    name = s.name,
                    pumpIndex = pi,
                }
            end
        else
            points[#points + 1] = s
        end
    end
    return points
end

--- force the raw-POI provider to rebuild so our onGetRawPoiListForLevel result is picked up
local function refreshPOIs()
    if bigmap and bigmap.updatePOIs then
        bigmap.updatePOIs() -- also clears gameplay_rawPois
    elseif extensions.gameplay_rawPois then
        extensions.gameplay_rawPois.clear()
    end
end

-- NATIVE POI CONTRIBUTION -------------------------------------------------------------------

--- native hook, fired by gameplay_rawPois : one missionMarker POI per station/garage
---@param levelIdentifier string
---@param elements table[]
local function onGetRawPoiListForLevel(levelIdentifier, elements)
    table.clear(M.itemById)
    if M.editorActive or not stationsAllowed() then return end

    local refuelPoints, garages = allRefuelPoints(), allGarages()
    local rot = quat(0, 0, 0, 1)

    local function add(list, prefix, icon, kind)
        for _, p in ipairs(list) do
            if p.id and p.pos then
                local id = prefix .. tostring(p.id)
                M.itemById[id] = p
                elements[#elements + 1] = {
                    id = id,
                    data = { type = kind, id = id },
                    markerInfo = {
                        missionMarker = { pos = vec3(p.pos.x, p.pos.y, p.pos.z), rot = rot, icon = icon },
                    },
                }
            end
        end
    end

    add(refuelPoints, "bjStation_", "poi_fuel_round", "bjEnergyStation")
    add(garages, "bjGarage_", "poi_garage_2_round", "bjGarage")
end

--- Per-frame touch-up of our own clusters' markers : `missionMarker` hardcodes its trigger radius
--- (~1.2m) and builds a ground ring in setup, and clusters get rebuilt whenever
--- gameplay_rawPois.clear() bumps the generation. Every frame we (re)apply the point's configured
--- radius to `marker.radius` (what `playerIsInArea` actually tests against) and drop the ring so
--- it's just the floating icon. Cheap - only the couple of markers we own.
-- forward-declared : called from pollFuelStatus below, not actually defined (needs
-- interceptRefuelCar, itself needing startProcess) until further down still. Confirmed live that
-- both onUpdate (every frame) and onSlowUpdate/pollFuelStatus (~250ms) genuinely tick here - either
-- would work for this ; left in pollFuelStatus since that's where it already landed.
local tryHookGasStations

local lastLocked
local function onUpdate()
    -- POIs are cached by generation ; when a round starts / ends, force a rebuild so the markers
    -- appear/disappear. onBJScenarioChanged also does this, but this cheap poll catches every
    -- transition regardless of which hooks fired.
    local locked = beamjoy_context.isScenarioLocked()
    if lastLocked ~= nil and locked ~= lastLocked then
        refreshPOIs()
    end
    lastLocked = locked

    local pm = extensions.gameplay_playmodeMarkers
    if not pm or not pm.getPlaymodeClusters or not next(M.itemById) then return end
    local ok, clusters = pcall(pm.getPlaymodeClusters)
    if not ok or type(clusters) ~= "table" then return end
    for _, cluster in ipairs(clusters) do
        if cluster.containedIdsLookup then
            for cid in pairs(cluster.containedIdsLookup) do
                local item = M.itemById[cid]
                if item then
                    local marker = pm.getMarkerForCluster(cluster)
                    if marker then
                        marker.radius = math.max(1, tonumber(item.radius) or 5)
                        if marker.groundDecalData then marker.groundDecalData = nil end
                    end
                    break
                end
            end
        end
    end
end

-- REFUEL / REPAIR PROCESS --------------------------------------------------------------------

---@param kind "refuel"|"repair"|"emergency"
---@return integer seconds
local function processDuration(kind)
    if kind == "emergency" then return M.EMERGENCY_REFUEL_HOLD_SECONDS end
    local fr = (beamjoy_config and beamjoy_config.data and beamjoy_config.data.Freeroam) or {}
    if kind == "refuel" then return math.max(0, tonumber(fr.RefuelDuration) or 5) end
    return math.max(0, tonumber(fr.RepairDuration) or 5)
end

-- forward-declared : the "emergency refuel" HUD action (below) reuses this same freeze-and-hold
-- flow, and is defined lexically before startProcess's own definition further down
local startProcess

local function endProcess()
    if not M.process then return end
    local vid = M.process.vid
    -- per direct request : every hold (station refuel/repair, not just the emergency one) gets the
    -- external camera, same "one-time set, not locked, restore only if the player never manually
    -- switched away themselves" pattern raceRunner.lua's own countdown camera already uses
    if M.process.previousCamera and camera.getCamera() == camera.CAMERAS.EXTERNAL then
        camera.setCamera(M.process.previousCamera)
    end
    M.process = nil
    beamjoy_vehicles.setFreeze(vid, false)
    beamjoy_vehicles.setEngine(vid, true)
end

--- Real, confirmed bug (direct report): refuelling always filled every tank to its raw
--- `maxEnergy`, ignoring that BeamNG's own vehicle tuning menu can configure a SMALLER starting
--- amount per tank - e.g. citybus's own "$fuel" variable ("Fuel Volume" under Chassis in the
--- config menu), which drives its fuel tank's jbeam `startingFuelCapacity` field, a genuinely
--- separate concept from the tank's raw `fuelCapacity`. A player who deliberately tuned their
--- tank down to a partial load got it silently topped back up to full on every refuel, overriding
--- that choice every time.
---
--- Fixed by refuelling back to what the tank actually STARTED with (`M.spawnFuelLevels`, captured
--- once per vehicle instance in `onBJVehicleInstantiated` below, before the player's ever touched
--- it) instead of its raw capacity - this needs no knowledge of the tuning variable's own name
--- (different per vehicle/mod, same reasoning as the strict-bus-stops door detection elsewhere in
--- this codebase), since "what it started with" already reflects whatever that variable resolved
--- to. Falls back to the tank's own `maxEnergy` only if no snapshot exists yet (refuelling in the
--- narrow window before the one-shot capture has resolved).
---@param station table
local function applyRefuel(station)
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or not station then return end
    local allowed = resolveStationTypes(station)
    local snap = M.spawnFuelLevels[own.vid]
    core_vehicleBridge.requestValue(own.veh, function(ret)
        local tanks = ret and ret[1] or {}
        local filled = 0
        for _, tank in ipairs(tanks) do
            if allowed[tank.energyType] and tank.name and tank.maxEnergy then
                local target = (snap and snap[tank.name]) or tank.maxEnergy
                core_vehicleBridge.executeAction(own.veh, 'setEnergyStorageEnergy', tank.name, target)
                filled = filled + 1
            end
        end
        if filled > 0 then
            Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Fueling_Petrol_Simple')
            toast.info(beamjoy_lang.translate("beamjoy.stations.toastRefuelled"), nil, 4)
        else
            toast.info(beamjoy_lang.translate("beamjoy.stations.toastNothingToFill"), nil, 4)
        end
    end, 'energyStorage')
end

local function applyRepair()
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own then return end
    spawn.safeTeleport(own.veh, own.veh:getPosition(), own.veh:getRotation(), nil, nil, nil, nil, true)
    toast.info(beamjoy_lang.translate("beamjoy.stations.toastRepaired"), nil, 4)
end

-- LOW FUEL / EMERGENCY REFUEL HUD -------------------------------------------------------------
-- One button on the main BJS panel (next to the vote button), from old BeamJoy: a gas-pump icon
-- that appears once the current vehicle's own fuel/energy is running low. Green while there's
-- still some left - click sets a native GPS route to the nearest station carrying that energy
-- type. Turns red once actually empty - click instead does a free "emergency refuel" (tops the
-- tank up just enough to reach a station, no station visit required), holding the vehicle in
-- place for EMERGENCY_REFUEL_HOLD_SECONDS through the same freeze-and-hold flow a real station
-- refuel already uses (startProcess, below).

---@param tanks table[] energyStorage entries (name, energyType, currentEnergy, maxEnergy)
---@return number? ratio, string? energyType the lowest-ratio PROPULSION_TYPES tank, if any
local function lowestPropulsionTank(tanks)
    local best, bestType
    for _, t in ipairs(tanks) do
        if t.name and M.PROPULSION_TYPES[t.energyType] and (t.maxEnergy or 0) > 0 then
            local ratio = (t.currentEnergy or 0) / t.maxEnergy
            if not best or ratio < best then
                best, bestType = ratio, t.energyType
            end
        end
    end
    return best, bestType
end

---@param energyType string
---@param fromPos table vec3
---@return table? nearest refuel point ({pos={x,y,z}, name}, BJS's own or a real map gas station)
local function nearestStation(energyType, fromPos)
    local best, bestDist
    for _, p in ipairs(allRefuelPoints()) do
        if p.pos and resolveStationTypes(p)[energyType] then
            local d = (vec3(p.pos.x, p.pos.y, p.pos.z) - fromPos):length()
            if not bestDist or d < bestDist then
                best, bestDist = p, d
            end
        end
    end

    -- Per direct request : also consider the map's OWN vanilla gas stations, not just BJS's own
    -- custom-placed ones. `freeroam_facilities`/`freeroam_gasStations` are the same native modules
    -- that already drive the map's own drive-up refuel prompt and Big Map pins - a station's real
    -- position is the center of its own pump cluster (`gasStationCenterRadius`, confirmed by
    -- reading the installed game's own `freeroam/gasStations.lua`), not some single fixed point.
    local level = getCurrentLevelIdentifier()
    local facilities = level and extensions.freeroam_facilities and
        extensions.freeroam_facilities.getFacilities(level)
    if facilities and extensions.freeroam_gasStations then
        for _, gs in ipairs(facilities.gasStations or {}) do
            local types = gs.energyTypes or { "any" }
            local matches = false
            for _, t in ipairs(types) do
                if t == "any" or t == energyType then
                    matches = true
                    break
                end
            end
            if matches then
                local center = extensions.freeroam_gasStations.gasStationCenterRadius(gs)
                if center then
                    local d = (center - fromPos):length()
                    if not bestDist or d < bestDist then
                        best = { pos = { x = center.x, y = center.y, z = center.z }, name = gs.name }
                        bestDist = d
                    end
                end
            end
        end
    end

    return best
end

--- polled every onSlowUpdate ; pushes BJFuelStatus to the UI only when low/empty actually changes.
--- Confirmed live (via a temporary tick diagnostic, since removed) that onSlowUpdate genuinely
--- dispatches here reliably.
local function pollFuelStatus()
    tryHookGasStations()
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or own.isAi or not stationsAllowed() then
        if M.fuelStatus.low or M.fuelStatus.empty then
            M.fuelStatus = { low = false, empty = false, type = nil }
            beamjoy_communications_ui.send("BJFuelStatus", M.fuelStatus)
        end
        return
    end
    core_vehicleBridge.requestValue(own.veh, function(ret)
        -- the vehicle may have changed (or the player may have gotten out) while this was in
        -- flight ; re-check instead of trusting the closed-over `own` is still the current one
        local stillOwn = beamjoy_vehicles.getCurrentOwn()
        if not stillOwn or stillOwn.veh:getID() ~= own.veh:getID() then return end

        local tanks = ret and ret[1] or {}
        local ratio, energyType = lowestPropulsionTank(tanks)
        local low = ratio ~= nil and ratio <= M.LOW_FUEL_RATIO
        local empty = ratio ~= nil and ratio <= M.EMPTY_FUEL_RATIO
        if low ~= M.fuelStatus.low or empty ~= M.fuelStatus.empty or energyType ~= M.fuelStatus.type then
            M.fuelStatus = { low = low, empty = empty, type = energyType }
            beamjoy_communications_ui.send("BJFuelStatus", M.fuelStatus)
        end
    end, 'energyStorage')
end

--- UI action : "set GPS to nearest station" HUD button
local function onBJFuelSetWaypoint()
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or not stationsAllowed() or not M.fuelStatus.type then return end

    local station = nearestStation(M.fuelStatus.type, own.veh:getPosition())
    if not station then
        toast.warn(beamjoy_lang.translate("beamjoy.stations.toastNoStationFound"), nil, 4)
        return
    end
    if not extensions.core_groundMarkers then return end
    extensions.core_groundMarkers.setPath(vec3(station.pos.x, station.pos.y, station.pos.z),
        { clearPathOnReachingTarget = true })
    toast.info(beamjoy_lang.translate("beamjoy.stations.toastWaypointSet"), nil, 4)
end

--- Actual top-up, dispatched from startProcess's own completion callback (below) once the
--- EMERGENCY_REFUEL_HOLD_SECONDS hold finishes - separated out the same way applyRefuel/
--- applyRepair already are for the other two process kinds.
local function applyEmergencyRefuel()
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own then return end
    core_vehicleBridge.requestValue(own.veh, function(ret)
        local tanks = ret and ret[1] or {}
        local filled = 0
        for _, tank in ipairs(tanks) do
            if tank.name and M.PROPULSION_TYPES[tank.energyType] and (tank.maxEnergy or 0) > 0 then
                local ratio = (tank.currentEnergy or 0) / tank.maxEnergy
                if ratio <= M.EMPTY_FUEL_RATIO then
                    core_vehicleBridge.executeAction(own.veh, 'setEnergyStorageEnergy', tank.name,
                        tank.maxEnergy * M.EMERGENCY_REFUEL_RATIO)
                    filled = filled + 1
                end
            end
        end
        if filled > 0 then
            M.lastEmergencyRefuel[own.veh:getID()] = GetCurrentTimeMillis()
            Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Fueling_Petrol_Simple')
            toast.info(beamjoy_lang.translate("beamjoy.stations.toastEmergencyRefuelled"), nil, 4)
        end
    end, 'energyStorage')
end

---@return integer ms
local function emergencyRefuelCooldownMs()
    local fr = (beamjoy_config and beamjoy_config.data and beamjoy_config.data.Freeroam) or {}
    local secs = tonumber(fr.EmergencyRefuelCooldown)
    return (secs and math.max(0, secs) or (M.EMERGENCY_REFUEL_COOLDOWN_MS / 1000)) * 1000
end

--- UI action : "emergency refuel" (the same HUD button, turned red) - free, only while actually
--- empty, cooldown-gated per vehicle instance (host-configurable, Freeroam.EmergencyRefuelCooldown)
--- so it's a real emergency measure, not a substitute for driving to a station. Holds the vehicle in
--- place for EMERGENCY_REFUEL_HOLD_SECONDS on the external camera - routed through the same
--- freeze-and-hold `startProcess` flow a real station refuel already uses (which now applies the
--- same external-camera hold to every kind, not just this one), rather than an instant top-up.
local function onBJFuelEmergencyRefuel()
    if M.process then return end
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or not M.fuelStatus.empty then return end

    local vid = own.veh:getID()
    local now = GetCurrentTimeMillis()
    local last = M.lastEmergencyRefuel[vid]
    local cooldownMs = emergencyRefuelCooldownMs()
    if last and now - last < cooldownMs then
        local secsLeft = math.ceil((cooldownMs - (now - last)) / 1000)
        toast.warn(string.var(beamjoy_lang.translate("beamjoy.stations.toastEmergencyCooldown"),
            { secsLeft }), nil, 4)
        return
    end

    startProcess("emergency", {})
end

---@param kind "refuel"|"repair"|"emergency"
---@param item table the station or garage - an empty table for "emergency" (no real item)
startProcess = function(kind, item)
    if M.process then return end
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or not item then return end

    local req = CreateRequestAuthorization(true)
    extensions.hook("onBJRequestStationInteraction", req, kind, beamjoy_vehicles.getCurrent())
    if not req.state then
        toast.warn(beamjoy_lang.translate("beamjoy.stations.toastBlocked"), nil, 4)
        return
    end

    local vid = own.veh:getID()
    beamjoy_vehicles.setFreeze(vid, true)
    beamjoy_vehicles.setEngine(vid, false)

    local dur = processDuration(kind)
    -- per direct request : every hold (station refuel/repair, not just emergency) switches to the
    -- external camera for its duration - see endProcess's own comment for the restore side
    local previousCamera = camera.getCamera()
    M.process = {
        kind = kind, vid = vid, item = item, endMs = GetCurrentTimeMillis() + dur * 1000,
        previousCamera = previousCamera,
    }
    camera.setCamera(camera.CAMERAS.EXTERNAL)
    local promptKey = kind == "refuel" and "beamjoy.stations.promptRefuelling"
        or kind == "emergency" and "beamjoy.stations.promptEmergencyRefuelling"
        or "beamjoy.stations.promptRepairing"
    toast.info(beamjoy_lang.translate(promptKey), nil, dur)

    async.delayTask(function()
        local stillOwn = beamjoy_vehicles.getCurrentOwn()
        if M.process and stillOwn and stillOwn.veh:getID() == vid then
            if kind == "refuel" then applyRefuel(M.process.item)
            elseif kind == "emergency" then applyEmergencyRefuel()
            else applyRepair() end
        end
        endProcess()
    end, dur * 1000, "BJStationProcess")
end

-- Real, confirmed bug (direct report): a vehicle with no tank compatible with a given station's
-- own fuel types (e.g. a gas car at an electric-only charger) still got the FULL freeze/camera/
-- "Refuelling..." hold, only to be told "Tanks already full" at the very end - technically true
-- (nothing WAS filled), but a misleading reason, and a wasted multi-second hold for something
-- knowable upfront. Checks for at least one compatible tank BEFORE starting the hold at all now -
-- rejects immediately with a clear "wrong fuel type" message if there's none, and only ever starts
-- the real hold once it's already confirmed the refuel can actually succeed. Shared by both the
-- vanilla-station hook below and this file's own BJS-station activity prompt further down -
-- "repair" has no fuel-type concept at all, so it still goes through startProcess directly.
---@param item table {types, name, ...} - same shape startProcess itself expects for a "refuel"
local function startRefuelProcess(item)
    if M.process then return end
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or not item then return end
    local allowed = resolveStationTypes(item)
    core_vehicleBridge.requestValue(own.veh, function(ret)
        -- the vehicle/hold state may have changed while this was in flight - re-check instead of
        -- trusting the closed-over `own` is still current, same defensive pattern pollFuelStatus
        -- already uses for the same kind of async gap
        local stillOwn = beamjoy_vehicles.getCurrentOwn()
        if M.process or not stillOwn or stillOwn.veh:getID() ~= own.veh:getID() then return end
        local tanks = ret and ret[1] or {}
        if table.any(tanks, function(t) return allowed[t.energyType] end) then
            startProcess("refuel", item)
        else
            toast.warn(beamjoy_lang.translate("beamjoy.stations.toastWrongFuelType"), nil, 4)
        end
    end, 'energyStorage')
end

-- VANILLA GAS STATION HOOK ---------------------------------------------------------------------
-- Real, confirmed bug (direct report): using one of the MAP'S OWN vanilla gas stations (as opposed
-- to a BJS-placed one) filled the tank instantly, to raw maxEnergy, with no camera hold at all -
-- none of the refuel fixes above applied. Root cause: those only ever run through startProcess,
-- which is only ever reached via THIS file's own onActivityAcceptGatherData, for BJS's own
-- "bjEnergyStation" markers. A vanilla gas station is a completely separate native POI type
-- ("gasStation") contributed by the installed game's own freeroam/gasStations.lua, whose OWN
-- onActivityAcceptGatherData pushes a button calling ITS OWN `refuelCar` directly - both hooks
-- share the same native gameplay_markerInteraction dispatcher, but neither sees the other's markers
-- or intercepts the other's button. Confirmed via direct report + reading that installed file:
-- `refuelCar` unconditionally does `setEnergyStorageEnergy(tank.name, tank.maxEnergy)`, synchronously,
-- with no hold/camera/tuning-awareness whatsoever - and since real maps ship with plenty of these
-- and players naturally use whichever pump is nearest, this was the far more commonly hit path in
-- practice, not an edge case.
--
-- Fixed by overriding `extensions.freeroam_gasStations.refuelCar` itself (same pattern
-- environment.lua already uses for `core_environment.setState`/`setTimeOfDay`) and routing it
-- through the exact same startProcess/applyRefuel flow as a BJS-placed station - same 5s hold, same
-- external camera, same initialStoredEnergy-aware fill amount, same toasts. Falls back to the real
-- native behavior when BJS's own station system is disabled server-side (`stationsAllowed()`) or a
-- hold is already in progress, so this never just silently eats the player's refuel attempt.
local baseRefuelCar

---@param gasStation table native activity-item object ({type, id, facility={name, energyTypes,
---pumps, ...}}, per the installed game's own onActivityAcceptGatherData/formatGasStationPoi -
---NOT the facility itself, the facility's own fields (like its name) live one level down at
---gasStation.facility)
---@param fuelTypes table lookup dict {energyType: true, ...} - "any" means literally any type,
---matching the installed game's own `fuelTypes['any']` semantics in refuelCar
---@param veh table
local function interceptRefuelCar(gasStation, fuelTypes, veh)
    local own = beamjoy_vehicles.getCurrentOwn()
    if not stationsAllowed() or M.process or (career_career and career_career.isActive and career_career.isActive())
        or not own or not veh or own.veh:getID() ~= veh:getID() then
        baseRefuelCar(gasStation, fuelTypes, veh)
        return
    end

    local types = {}
    if fuelTypes and fuelTypes["any"] then
        -- vanilla's own "any" matches every tank regardless of type (including electric) - carry
        -- that over explicitly rather than falling through to resolveStationTypes' own
        -- DEFAULT_FUEL_TYPES fallback, which deliberately excludes electricEnergy for BJS' own
        -- stations (opt-in only there) and would otherwise silently skip EV tanks here
        for t in pairs(M.ENERGY_TYPES) do types[#types + 1] = t end
    else
        for t in pairs(fuelTypes or {}) do
            if M.ENERGY_TYPES[t] then types[#types + 1] = t end
        end
    end
    -- Real, confirmed bug (found while diagnosing an unrelated report): this read gasStation.name -
    -- but gasStation here is the ACTIVITY-ITEM (per onActivityAcceptGatherData's own `elem`), whose
    -- own name-bearing field is one level down at gasStation.facility.name (confirmed via the
    -- installed game's own formatGasStationPoi). Always nil as written - harmless today (nothing
    -- currently displays this station's name mid-refuel), but wrong regardless.
    local name = gasStation and gasStation.facility and gasStation.facility.name
    startRefuelProcess({ types = types, name = name })
end

-- ACTIVITY PROMPT --------------------------------------------------------------------------

--- native hook, fired by gameplay_markerInteraction when the player is stopped in a marker area.
--- `elemData` is a list of each nearby marker's `poi.data`.
---@param elemData table[]
---@param activityData table[]
local function onActivityAcceptGatherData(elemData, activityData)
    if M.process or not stationsAllowed() then return end
    for _, elem in ipairs(elemData) do
        local isStation = elem.type == "bjEnergyStation"
        if isStation or elem.type == "bjGarage" then
            local item = M.itemById[elem.id]
            if item then
                local labelKey = isStation and "beamjoy.stations.markerStation" or "beamjoy.stations.markerGarage"
                local preheadings = { beamjoy_lang.translate(labelKey) }
                -- a synthetic per-pump refuel point (see allRefuelPoints) - tag which pump this is,
                -- since several can now share the same station name
                if item.pumpIndex then
                    table.insert(preheadings,
                        string.format("%s %d", beamjoy_lang.translate("beamjoy.stations.pump"), item.pumpIndex))
                end
                activityData[#activityData + 1] = {
                    icon = isStation and "poi_fuel_round" or "poi_garage_2_round",
                    heading = (item.name and #item.name > 0) and item.name or beamjoy_lang.translate(labelKey),
                    preheadings = preheadings,
                    buttonLabel = beamjoy_lang.translate(isStation
                        and "beamjoy.stations.buttonRefuel" or "beamjoy.stations.buttonRepair"),
                    buttonSoundClass = "bng_hover_generic",
                    sorting = { type = elem.type, id = elem.id },
                    buttonFun = function()
                        if isStation then startRefuelProcess(item) else startProcess("repair", item) end
                    end,
                }
            end
        end
    end
end

-- BIG MAP POIs -------------------------------------------------------------------------------

---@param POIS table<string, table>
local function onBJRequestBigmapPOIs(POIS)
    -- one pin per STATION regardless of pumps (Big Map is a zoomed-out overview - individual pumps
    -- a few metres apart would just clutter it), always at the station's own reference pos
    local data = beamjoy_freeroamData.data
    for _, s in ipairs(data.stations or {}) do
        if s.id then
            POIS["bjStation_" .. tostring(s.id)] = {
                name = (s.name and #s.name > 0) and s.name or "beamjoy.stations.markerStation",
                icon = "fuelPump", groupType = "gasStation", pos = vec3(s.pos.x, s.pos.y, s.pos.z),
            }
        end
    end
    for _, g in ipairs(allGarages()) do
        if g.id then
            POIS["bjGarage_" .. tostring(g.id)] = {
                name = (g.name and #g.name > 0) and g.name or "beamjoy.stations.markerGarage",
                icon = "garage01", groupType = "garage", pos = vec3(g.pos.x, g.pos.y, g.pos.z),
            }
        end
    end
end

-- LIFECYCLE ------------------------------------------------------------------------------

local function onBJClientReady()
    refreshPOIs()
end

local function onBJFreeroamDataChanged()
    refreshPOIs()
end

local function onBJScenarioChanged()
    refreshPOIs()
end

---@param active boolean
local function onBJStationEditorState(active)
    M.editorActive = active == true
    refreshPOIs()
end

--- Captures each local, non-AI vehicle's own TRUE starting fuel/energy level, for applyRefuel's own
--- use (see its doc comment).
---
--- Real, confirmed bug (direct report): refuelling didn't match the tuning menu's value. The
--- previous version captured `currentEnergy` via core_vehicleBridge's async 'energyStorage' lookup ;
--- that callback's actual arrival is delayed by registerVehicle's own job (polls MPVehicleGE/owner
--- data in .01-.25s steps), and if the engine's running and burning fuel during that window, the
--- snapshot lands LOWER than the true tuned starting amount - refuelling then filled back to less
--- than what the tuning menu set, not the full tuned amount.
---
--- Fixed by reading each tank's own `initialStoredEnergy` instead : a vehicle-side energyStorage
--- field written once at tank init from the tuned starting-capacity variable and never touched by
--- consumption afterward, so it's correct no matter how late this callback lands. core_vehicleBridge's
--- own 'energyStorage' lookup doesn't expose it (only currentEnergy/maxEnergy - confirmed via the
--- game's own interactEnergyStorage.lua), so this goes straight to VE lua and reports back through
--- `obj:queueGameEngineLua`, the same VE->GE callback primitive the engine's own vehicle-side modules
--- (beamstate.lua, bdebugImpl.lua) use for exactly this purpose.
---@param vid integer
local function onBJVehicleInstantiated(vid)
    local mpVeh = beamjoy_vehicles.vehicles[vid]
    if not mpVeh or not mpVeh.isLocal or mpVeh.isAi then return end
    mpVeh.veh:queueLuaCommand(string.var([[
local _bjSnap = {}
for name, storage in pairs(energyStorage.getStorages()) do
    _bjSnap[name] = storage.initialStoredEnergy
end
obj:queueGameEngineLua("extensions.hook('onBJInitialFuelLevels'," .. {1} .. "," .. serialize(_bjSnap) .. ")")
]], { vid }))
end

---@param vid integer
---@param snap table<string, number>
local function onBJInitialFuelLevels(vid, snap)
    M.spawnFuelLevels[vid] = snap
end

-- Real, confirmed bug (direct report: "nothing changed", "same issue", "vanilla had the same issue
-- as before" - across several rounds, each with its own wrong-in-hindsight theory: first that
-- onInit was too early (true, but not the whole story), then that onUpdate never dispatches at all
-- (directly disproven live - it ticks every frame, confirmed via its own diagnostic). A capture
-- spanning an actual refuel click, with BOTH onUpdate's and onSlowUpdate's own tick diagnostics
-- firing reliably throughout, still showed neither of THIS function's own two possible log lines -
-- meaning `baseRefuelCar` must already have been truthy (the one-shot "already hooked" guard
-- returning early every time, silently) from some earlier, unlogged success - yet the vanilla
-- achievement still fired instantly on the actual click, with no `interceptRefuelCar` output
-- anywhere near it. The only way both of those are true together: the hook DID succeed once, onto
-- a `freeroam_gasStations` table that was the live one AT THE TIME - but the installed game later
-- swapped in a fresh, unhooked one (a level transition or reconnect reloading that extension), and
-- this function's own one-shot "already hooked, never check again" guard had no way to notice.
-- Fixed by never treating a past success as permanent: every call now checks whether the CURRENTLY
-- installed refuelCar is still actually this file's own interceptor, and (re)installs it if not -
-- self-healing against any number of future reloads, at the cost of one cheap identity check per
-- ~250ms tick.
tryHookGasStations = function()
    local gs = extensions.freeroam_gasStations
    if not gs or not gs.refuelCar or gs.refuelCar == interceptRefuelCar then return end
    baseRefuelCar = gs.refuelCar
    gs.refuelCar = interceptRefuelCar
end

local function onInit()
    beamjoy_communications_ui.addHandler("BJFuelSetWaypoint", onBJFuelSetWaypoint)
    beamjoy_communications_ui.addHandler("BJFuelEmergencyRefuel", onBJFuelEmergencyRefuel)
    tryHookGasStations()
end

M.onInit = onInit
M.onBJClientReady = onBJClientReady
M.onUpdate = onUpdate
M.onSlowUpdate = pollFuelStatus
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onBJInitialFuelLevels = onBJInitialFuelLevels

M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.onBJRequestBigmapPOIs = onBJRequestBigmapPOIs
M.onBJFreeroamDataChanged = onBJFreeroamDataChanged
M.onBJScenarioChanged = onBJScenarioChanged
M.onBJStationEditorState = onBJStationEditorState

M.refreshPOIs = refreshPOIs

return M
