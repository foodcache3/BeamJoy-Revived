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

    ---@type { kind: "refuel"|"repair", vid: integer, endMs: integer, item: table }?
    process = nil,

    --- true while ui/stationEditor.lua is open : it draws its own markers, so our POIs stand down
    editorActive = false,

    ---@type table<string, table> our POI id -> station/garage, for onActivityAcceptGatherData
    itemById = {},
}

--- alias : beamjoy_context owns this (bigmap.lua's POI filter uses it too)
local function stationsAllowed()
    return beamjoy_context.stationsAllowed()
end

-- DATA ---------------------------------------------------------------------------------------

---@param station table
---@return table<string, true> energyType set this station fills
local function resolveStationTypes(station)
    local set = {}
    local src = (type(station.types) == "table" and #station.types > 0) and station.types or M.DEFAULT_FUEL_TYPES
    for _, t in ipairs(src) do
        if M.ENERGY_TYPES[t] then set[t] = true end
    end
    return set
end

---@return table[] stations, table[] garages
local function allPoints()
    local data = beamjoy_freeroamData.data
    local stations, garages = {}, {}
    for _, s in ipairs(data.stations or {}) do stations[#stations + 1] = s end
    for _, g in ipairs(data.garages or {}) do garages[#garages + 1] = g end
    return stations, garages
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

    local stations, garages = allPoints()
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

    add(stations, "bjStation_", "poi_fuel_round", "bjEnergyStation")
    add(garages, "bjGarage_", "poi_garage_2_round", "bjGarage")
end

--- Per-frame touch-up of our own clusters' markers : `missionMarker` hardcodes its trigger radius
--- (~1.2m) and builds a ground ring in setup, and clusters get rebuilt whenever
--- gameplay_rawPois.clear() bumps the generation. Every frame we (re)apply the point's configured
--- radius to `marker.radius` (what `playerIsInArea` actually tests against) and drop the ring so
--- it's just the floating icon. Cheap - only the couple of markers we own.
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

---@param kind "refuel"|"repair"
---@return integer seconds
local function processDuration(kind)
    local fr = (beamjoy_config and beamjoy_config.data and beamjoy_config.data.Freeroam) or {}
    if kind == "refuel" then return math.max(0, tonumber(fr.RefuelDuration) or 5) end
    return math.max(0, tonumber(fr.RepairDuration) or 5)
end

local function endProcess()
    if not M.process then return end
    local vid = M.process.vid
    M.process = nil
    beamjoy_vehicles.setFreeze(vid, false)
    beamjoy_vehicles.setEngine(vid, true)
end

---@param station table
local function applyRefuel(station)
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or not station then return end
    local allowed = resolveStationTypes(station)
    core_vehicleBridge.requestValue(own.veh, function(ret)
        local tanks = ret and ret[1] or {}
        local filled = 0
        for _, tank in ipairs(tanks) do
            if allowed[tank.energyType] and tank.name and tank.maxEnergy then
                core_vehicleBridge.executeAction(own.veh, 'setEnergyStorageEnergy', tank.name, tank.maxEnergy)
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

---@param kind "refuel"|"repair"
---@param item table the station or garage
local function startProcess(kind, item)
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
    M.process = { kind = kind, vid = vid, item = item, endMs = GetCurrentTimeMillis() + dur * 1000 }
    toast.info(beamjoy_lang.translate(kind == "refuel"
        and "beamjoy.stations.promptRefuelling" or "beamjoy.stations.promptRepairing"), nil, dur)

    async.delayTask(function()
        local stillOwn = beamjoy_vehicles.getCurrentOwn()
        if M.process and stillOwn and stillOwn.veh:getID() == vid then
            if kind == "refuel" then applyRefuel(M.process.item) else applyRepair() end
        end
        endProcess()
    end, dur * 1000, "BJStationProcess")
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
                activityData[#activityData + 1] = {
                    icon = isStation and "poi_fuel_round" or "poi_garage_2_round",
                    heading = (item.name and #item.name > 0) and item.name or beamjoy_lang.translate(labelKey),
                    preheadings = { beamjoy_lang.translate(labelKey) },
                    buttonLabel = beamjoy_lang.translate(isStation
                        and "beamjoy.stations.buttonRefuel" or "beamjoy.stations.buttonRepair"),
                    buttonSoundClass = "bng_hover_generic",
                    sorting = { type = elem.type, id = elem.id },
                    buttonFun = function() startProcess(isStation and "refuel" or "repair", item) end,
                }
            end
        end
    end
end

-- BIG MAP POIs -------------------------------------------------------------------------------

---@param POIS table<string, table>
local function onBJRequestBigmapPOIs(POIS)
    local stations, garages = allPoints()
    for _, s in ipairs(stations) do
        if s.id then
            POIS["bjStation_" .. tostring(s.id)] = {
                name = (s.name and #s.name > 0) and s.name or "beamjoy.stations.markerStation",
                icon = "fuelPump", groupType = "gasStation", pos = vec3(s.pos.x, s.pos.y, s.pos.z),
            }
        end
    end
    for _, g in ipairs(garages) do
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

M.onBJClientReady = onBJClientReady
M.onUpdate = onUpdate

M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.onBJRequestBigmapPOIs = onBJRequestBigmapPOIs
M.onBJFreeroamDataChanged = onBJFreeroamDataChanged
M.onBJScenarioChanged = onBJScenarioChanged
M.onBJStationEditorState = onBJStationEditorState

M.refreshPOIs = refreshPOIs

return M
