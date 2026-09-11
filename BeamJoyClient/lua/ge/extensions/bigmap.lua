--- Big Map integration.
---
--- Rewritten 2026-09-10 for the game's current Big Map (`freeroam_vueBigMap`, which replaced the
--- old `freeroam_bigMapPoiProvider`). The previous version froze a snapshot of vanilla POIs at
--- BJReady, replaced `sendCurrentLevelMissionsToBigmap` with its own 3-tab UI, and tagged every
--- custom POI as `data.type = "mission"`. Against the current game that last part FATALs
--- (`freeroam_vueBigMap.processMissionPoi` -> `gameplay_missions_progress.formatSaveDataForUi`
--- indexes a nil `saveData`, because there is no real mission behind the id), and the FATAL aborts
--- the whole POI cache build - taking every vanilla POI down with it.
---
--- Now it does the minimum: pass the real, live POI list through - MINUS `data.type == "mission"`
--- entries (career missions / scenarios / challenges / time trials), which a sandbox server
--- doesn't want cluttering the map (this matches the old version's intent, it just used to filter
--- them at a frozen snapshot) - and append BJS custom POIs with a valid non-mission `data.type`
--- and the `markerInfo.bigmapMarker` shape `freeroam_vueBigMap.processNonMissionPoi` expects.
--- Custom POIs carry only a `bigmapMarker` (no `missionMarker`/clusterType), so
--- `gameplay_playmodeMarkers` never builds an in-world marker for them and the mission path is
--- never touched. In-world markers for BJS activities are drawn by their own modules
--- (raceMarkers, hunterMarkers, beamjoy_stations, ...).
---
--- The one other override kept is `getCurrentTaskdataTypeOrNil` - the "you can't open the Big Map
--- mid-scenario" block. That still works and is unrelated to the POI provider.

local M = {
    baseFunctions = {},

    --- BJS custom Big Map POIs, keyed by id, rebuilt from the `onBJRequestBigmapPOIs` hook by
    --- updatePOIs(). See the doc block at the bottom of this file for the entry shape.
    ---@type table<string, table>
    POIs = {},

    menuOpened = false,
}

--- resolve a lang key (or return the string unchanged if it isn't one / lang isn't up yet)
---@param s string?
---@return string?
local function tr(s)
    if type(s) ~= "string" then return s end
    if beamjoy_lang and beamjoy_lang.translate then return beamjoy_lang.translate(s) end
    return s
end

--- our replacement for `gameplay_rawPois.getRawPoiListByLevel`. Delegates to the real one for
--- everything the game already knows about (this is what fires `onGetRawPoiListForLevel`, so
--- vanilla facilities/spawns/native contributors all come through live and fresh), then appends
--- BJS custom POIs.
---@param levelIdentifier string
---@return table pois, integer generation
local function getRawPOIs(levelIdentifier)
    local pois, generation = M.baseFunctions.gameplay_rawPois.getRawPoiListByLevel(levelIdentifier)

    -- during a Race / Hunter / Infected round, drop every fuel-station / garage POI - BJS-placed
    -- AND the map's own gas stations - unless the mode allows them. Doing it here (the one
    -- getRawPoiListByLevel everything calls) covers both the world marker and the refuel prompt
    -- in one place, regardless of extension load order.
    local dropStations = beamjoy_context and beamjoy_context.stationsAllowed
        and not beamjoy_context.stationsAllowed()
    -- bus lines are freeroam-only, no per-mode opt-in : drop their start POIs during ANY locked
    -- round (beamjoy_busRun gates its own contributions too - this is the same second layer
    -- dropStations is for the fuel stations)
    local dropBus = beamjoy_context and beamjoy_context.isScenarioLocked
        and beamjoy_context.isScenarioLocked()

    local out = {}
    for _, p in ipairs(pois or {}) do
        local t = p.data and p.data.type
        -- drop career missions / scenarios / challenges (a BJS sandbox doesn't run them), and
        -- fuel/repair/bus POIs mid-round per above
        if t ~= "mission"
            and not (dropStations and (t == "gasStation" or t == "bjEnergyStation" or t == "bjGarage"))
            and not (dropBus and t == "bjBusLineStart") then
            out[#out + 1] = p
        end
    end

    for id, el in pairs(M.POIs) do
        if el.pos then
            local pos = vec3(el.pos.x, el.pos.y, el.pos.z)
            local icon = el.icon or "info"
            local qtFn
            if el.canQuickTravel and el.quickTravelPos then
                local qtPos = vec3(el.quickTravelPos.x, el.quickTravelPos.y, el.quickTravelPos.z)
                local qtRot = el.quickTravelRot and
                    quatFromDir(vec3(el.quickTravelRot.x, el.quickTravelRot.y, el.quickTravelRot.z)) or
                    quat(0, 0, 0, 1)
                qtFn = function() return qtPos, qtRot end
            end
            out[#out + 1] = {
                id = id,
                -- must NOT be "mission" : that routes into freeroam_vueBigMap.processMissionPoi,
                -- which assumes a real registered mission exists. A known facility type lands in
                -- its own group ; anything else falls into "type_other" - unavoidably, in ADDITION
                -- to any customGroupTags below (vueBigMap's own processNonMissionPoi always tags
                -- one native bucket first, elseif-chained on data.type, THEN separately unions in
                -- customGroupTags ; there's no way to opt an element out of the native bucket).
                -- customGroupTags is how a genuinely custom category (not one of vueBigMap's fixed
                -- type_* names) gets an element into it anyway - pair with M.onBigmapBuildGroupData
                -- (below) defining the group and M.onBigmapBuildCustomGroupStructures surfacing it
                -- as a menu section, exactly the mechanism the old "BeamJoy > Garages" section used
                -- for a NATIVE group vueBigMap otherwise hides outside career mode.
                data = { type = el.groupType or "other", customGroupTags = el.customGroupTags },
                markerInfo = {
                    bigmapMarker = {
                        cluster = el.cluster ~= false,
                        name = tr(el.name) or id,
                        description = tr(el.description),
                        cardIcon = icon,
                        icon = icon,
                        pos = pos,
                        thumbnail = el.preview,
                        previews = el.preview and { el.preview } or nil,
                        quickTravelPosRotFunction = qtFn,
                    },
                },
            }
        end
    end

    return out, generation
end

--- `getCurrentTaskdataTypeOrNil` is the single funnel every real Big Map entry path goes through
--- (`freeroam/vueBigMap.lua`'s `enterBigMap` refuses outright the instant this returns anything
--- truthy - the same check a vanilla mission already relies on to keep the map shut for itself).
--- Wrapping it to also return truthy while a BJS scenario is locked covers the keybind, the quick-
--- access map icon and any career path at once. The camera-level block in
--- raceRunner/hunterRunner/infectedRunner stays as an independent second layer.
---
--- The "which BJS activity is locked" test lives in one place now - beamjoy_context - so the next
--- mode added is covered here for free (it used to be an inline OR that had to be hand-patched
--- when Infected was added).
---@return string?
local function getCurrentTaskdataTypeOrNil()
    if beamjoy_context and beamjoy_context.isScenarioLocked() then
        return "beamjoySandbox"
    end
    return M.baseFunctions.gameplay_missions_missionManager.getCurrentTaskdataTypeOrNil()
end

--- Two problems keep the map's own gas stations from working in the world on a BJS server:
---  1. `gameplay_markerInteraction` (the per-frame driver for in-world POI markers + the drive-up
---     prompt) is loaded lazily, via `core_gameContext.getGameContext` - which nothing calls in a
---     no-mission BeamMP freeroam session, so it never loads. `freeroam_gasStations` (which
---     contributes the refuel button) is in the same boat.
---  2. Even once loaded, `gameplay_markerInteraction.onPreRender` bails unless
---     `gameplay_playmodeMarkers.isStateWithPlaymodeMarkers()` - true only for "freeroam"/"career",
---     never "multiplayer" (what BeamMP sets).
--- BJI patched the same two gaps. Force-load the extensions, then wrap the state check to also
--- accept "multiplayer" (function wrap, rolled back on unload, survives the state table being
--- rebuilt).
local function enablePlaymodeMarkersInMultiplayer()
    for _, name in ipairs({ "gameplay_markerInteraction", "gameplay_playmodeMarkers", "freeroam_gasStations" }) do
        if not extensions[name] then pcall(extensions.load, name) end
    end
    local pm = extensions.gameplay_playmodeMarkers
    if not pm or not pm.isStateWithPlaymodeMarkers or M.baseFunctions.gameplay_playmodeMarkers then
        return
    end
    M.baseFunctions.gameplay_playmodeMarkers = { isStateWithPlaymodeMarkers = pm.isStateWithPlaymodeMarkers }
    pm.isStateWithPlaymodeMarkers = function()
        if M.baseFunctions.gameplay_playmodeMarkers.isStateWithPlaymodeMarkers() then return true end
        return core_gamestate and core_gamestate.state and core_gamestate.state.state == "multiplayer" or false
    end
end

--- rebuild M.POIs from every extension that implements onBJRequestBigmapPOIs. Call after the
--- underlying data changes ; getRawPOIs reads M.POIs live on the next Big Map open / POI refresh.
local function updatePOIs()
    table.clear(M.POIs)
    extensions.hook("onBJRequestBigmapPOIs", M.POIs)
    if extensions.gameplay_rawPois then
        extensions.gameplay_rawPois.clear() -- force the provider to rebuild with our new set
    end
end

local function onInit()
    M.baseFunctions = {
        gameplay_rawPois = {
            getRawPoiListByLevel = extensions.gameplay_rawPois.getRawPoiListByLevel,
        },
        gameplay_missions_missionManager = {
            getCurrentTaskdataTypeOrNil = extensions.gameplay_missions_missionManager.getCurrentTaskdataTypeOrNil,
        },
    }
    extensions.gameplay_rawPois.getRawPoiListByLevel = getRawPOIs
    extensions.gameplay_missions_missionManager.getCurrentTaskdataTypeOrNil = getCurrentTaskdataTypeOrNil
    enablePlaymodeMarkersInMultiplayer()

    beamjoy_communications_ui.addHandler("BJReady", function()
        enablePlaymodeMarkersInMultiplayer() -- re-assert after a reconnect
        M.updatePOIs()
    end)
end

local function onExtensionUnloaded()
    RollBackNGFunctionsWrappers(M.baseFunctions)
end

--- adds a genuinely custom group (not one of vueBigMap's fixed type_* names) for bus lines : no
--- native `data.type` fits them, so they'd otherwise only ever land in the "Other" catch-all (see
--- getRawPOIs' own comment on customGroupTags above). Every entry in `groupData` gets `.elements`
--- initialized right after this hook runs, same as every native entry, so this needs nothing more
--- than a label + icon to become a real, poppable group.
---@param groupData table<string, table>
M.onBigmapBuildGroupData = function(groupData)
    groupData.bjBusLines = { label = tr("beamjoy.buslines.edit.lines"), icon = "bus" }
end

--- vueBigMap's freeroam-mode side menu only lists `type_garage` when a career is active (see its
--- buildGroupStructure), and has no native bucket for bus lines at all. Surface both here under
--- one "BeamJoy" section. vueBigMap always renders the section title AND each group's own label,
--- so the title has to differ from "Garages" (or it'd read "Garages > Garages").
--- Dropped automatically when a group has no elements.
---@param structures table[]
M.onBigmapBuildCustomGroupStructures = function(structures)
    structures[#structures + 1] = {
        key = "beamjoy",
        icon = "star",
        title = "BeamJoy",
        groupIds = { "type_garage", "bjBusLines" },
    }
end

M.onInit = onInit
M.onExtensionUnloaded = onExtensionUnloaded
M.onBeforeBigMapActivated = function()
    M.menuOpened = true
end
M.onDeactivateBigMapCallback = function()
    M.menuOpened = false
end

M.getRawPOIs = getRawPOIs
M.updatePOIs = updatePOIs

return M

--[[
To add custom Big Map POIs, implement `onBJRequestBigmapPOIs` in your extension and fill the
passed table, keyed by a unique id:

---@param POIS table<string, table>
M.onBJRequestBigmapPOIs = function(POIS)
    POIS["myext_thing_1"] = {
        name = "My activity",                 -- string or lang key
        description = "myext.thing.desc",      -- optional, string or lang key
        icon = "flag",                        -- UI icon name (see freeroam/vueBigMap.lua's
                                              -- poiTypeIcons: fuelPump, garage01, flag, info, ...)
        pos = vec3(-397, -480, 38.5),         -- required (map marker + set-route target)
        groupType = "other",                  -- optional; a vueBigMap non-mission type
                                              -- (gasStation/garage/spawnPoint/...) or "other"
        customGroupTags = { "myext_group" },  -- optional; extra group id(s) this POI ALSO joins,
                                              -- on top of whatever groupType maps to (that mapping
                                              -- always applies too - there's no opting out of it).
                                              -- Use this for a genuinely custom category no native
                                              -- groupType fits: define the group via
                                              -- M.onBigmapBuildGroupData (add a groupData entry
                                              -- keyed by the same id, {label, icon}) and surface it
                                              -- with M.onBigmapBuildCustomGroupStructures (see
                                              -- bigmap.lua's own "beamjoy"/bjBusLines for a worked
                                              -- example).
        cluster = true,                       -- optional, default true (map-side clustering)
        preview = "/levels/east_coast_usa/east_coast_usa_preview1_v2.jpg", -- optional
        canQuickTravel = false,               -- optional
        quickTravelPos = vec3(...),           -- required if canQuickTravel
        quickTravelRot = vec3(0, 1, 0),       -- optional facing dir for the quick-travel spawn
    }
end

Then call `bigmap.updatePOIs()` whenever the source data changes. POIs get a real Big Map marker,
a list card, a working "Set route", and (if canQuickTravel) quick travel - all handled by the
native `freeroam_vueBigMap` / `freeroam_bigMapMode` from the shape above. They do NOT get an
in-world 3D marker (draw that yourself if you want one).
]]
