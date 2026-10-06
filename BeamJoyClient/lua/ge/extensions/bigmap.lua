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
---
--- A third wrap, `getGroups`, strips native's own unconditional `type_other` fallback membership
--- back out of the already-built result for anything that also has its own `customGroupTags`
--- group - see that function's own comment for the full story, including a first attempt (wrapping
--- `processNonMissionPoi` itself) that turned out to be a no-op due to how that function is called
--- internally.

local M = {
    baseFunctions = {},

    --- BJS custom Big Map POIs, keyed by id, rebuilt from the `onBJRequestBigmapPOIs` hook by
    --- updatePOIs(). See the doc block at the bottom of this file for the entry shape.
    ---@type table<string, table>
    POIs = {},

    menuOpened = false,

    -- updatePOIs() only asks for a rebuild : it happens once things are quiet for this long...
    REBUILD_QUIET_MS = 300,
    -- ...or at the latest this long after the first request
    REBUILD_MAX_WAIT_MS = 1000,
    ---@type integer? when the pending rebuild was first asked for
    rebuildRequestedAt = nil,
    ---@type integer? the latest request
    rebuildLastRequestAt = nil,

    -- ROUTE PREVIEW (a POI's `previewPoints`, drawn when it's hovered or selected) : between two
    -- points closer than this, a straight line (no road search)
    ROUTE_MIN_ROAD_DIST = 50,
    -- the road route between two points is used unless it's longer than the straight line times
    -- this, plus ROUTE_DETOUR_SLACK metres (off-road checkpoints, rally stages, tracks off the
    -- road network : the nearest road would be a silly detour)
    ROUTE_MAX_DETOUR = 1.6,
    ROUTE_DETOUR_SLACK = 100,
    ---@type table<string, table[]> POI id -> built path ({pos} points), until the POIs rebuild
    routeCache = {},
    ---@type string? the selected POI whose route is shown
    routeSelectedId = nil,
    --- a route of ours is on the map right now
    routeShown = false,
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
            -- quick travel to the map's own gas stations too (direct request) : the game only gives
            -- its garages one. Lands on the station's middle ; the game's safe teleport moves the
            -- car off anything in the way
            local bm = t == "gasStation" and p.markerInfo and p.markerInfo.bigmapMarker
            if bm and bm.pos and not bm.quickTravelPosRotFunction then
                local qtPos = vec3(bm.pos)
                bm.quickTravelPosRotFunction = function() return qtPos, quat(0, 0, 0, 1) end
            end
            out[#out + 1] = p
        end
    end

    for id, el in pairs(M.POIs) do
        if el.pos then
            local pos = vec3(el.pos.x, el.pos.y, el.pos.z)
            local icon = el.icon or "info"
            -- real, confirmed bug (a depot showed in the sidebar list but never as its own pin on
            -- the map, only inside a numbered cluster) : the pin is drawn from the marker ICON
            -- ATLAS (bigmapMarker.lua -> iconRendererObj:addIcon(cluster.icon), names like
            -- "poi_fuel_round", core/art/gui/images/iconAtlas.json), a different set from the
            -- sidebar card's UI icon font ("fuelPump", "bus", "deliveryTruck"). An unknown atlas
            -- name draws nothing ; a cluster draws its own generic numbered pin, which is why
            -- only stacked POIs ever showed. `mapIcon` is the atlas name for the pin, `icon`
            -- stays the card's.
            local mapIcon = el.mapIcon or icon
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
                        icon = mapIcon,
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

--- rebuild M.POIs from every extension that implements onBJRequestBigmapPOIs, and have the game
--- rebuild its POI list (world markers included) from it
local function flushPOIs()
    M.rebuildRequestedAt, M.rebuildLastRequestAt = nil, nil
    table.clear(M.POIs)
    table.clear(M.routeCache)
    extensions.hook("onBJRequestBigmapPOIs", M.POIs)
    if extensions.gameplay_rawPois then
        extensions.gameplay_rawPois.clear() -- force the provider to rebuild with our new set
    end
end

--- Call after the underlying data changes. Coalesced : one activity change used to rebuild 3 to 6
--- times in the same frame (stations, delivery, bus lines, races, derby each refreshing) and once
--- more ~200 ms later (races / derby polling the activity state), and each rebuild reran every
--- provider and made gameplay_markerInteraction rebuild every world marker (3-10 ms and ~500 KB of
--- garbage each). Now one rebuild, once the requests settle (onUpdate), or right away when the Big
--- Map opens.
local function updatePOIs()
    local now = GetCurrentTimeMillis()
    M.rebuildRequestedAt = M.rebuildRequestedAt or now
    M.rebuildLastRequestAt = now
end

local function onUpdate()
    if not M.rebuildRequestedAt then return end
    local now = GetCurrentTimeMillis()
    if now - M.rebuildLastRequestAt >= M.REBUILD_QUIET_MS or
        now - M.rebuildRequestedAt >= M.REBUILD_MAX_WAIT_MS then
        flushPOIs()
    end
end

--- `freeroam_vueBigMap.processNonMissionPoi` (native) classifies every non-mission POI into
--- exactly one native group bucket via an elseif chain on `poi.data.type`, unconditionally
--- falling to `type_other` for anything that doesn't match one of its ~11 known types - real,
--- confirmed via reading its own source, no way around it from `onBJRequestBigmapPOIs` alone
--- (customGroupTags only ever ADDS a group, it can't remove `type_other`). That's why a bus line
--- (no native type fits "bus line") always also showed up in "Other" alongside its own "Bus
--- Lines" group.
---
--- FIRST attempt at this fix (build 2400, confirmed NOT working by live test) wrapped
--- `processNonMissionPoi` itself the same way `getRawPoiListByLevel`/`getCurrentTaskdataTypeOrNil`
--- above are wrapped. That doesn't work for THIS function specifically: `buildPoiDataCache` (the
--- only caller) invokes it as a bare local reference -
--- `formatted, filterData = processNonMissionPoi(poi, groupData)` - resolved lexically at parse
--- time to vueBigMap.lua's own local, completely bypassing whatever `extensions.freeroam_vueBigMap
--- .processNonMissionPoi` happens to point to. Reassigning that table field only affects code that
--- calls it BY that field (external callers going through `extensions.<module>.<fn>`), never a
--- module's own internal calls to its own locals - a real Lua monkey-patching limitation, not a
--- logic bug in the wrap itself. It silently did nothing at all, every time.
---
--- SECOND attempt (the getGroups wrap, still in place below) correctly stripped bus lines back out
--- of "type_other" - confirmed working - but relied on native's own OWN custom-group-structure
--- mechanism (M.onBigmapBuildCustomGroupStructures below, feeding the "BeamJoy" section) to give
--- them somewhere else to land, and that turned out unreliable enough in practice that bus lines
--- ended up in NEITHER group live (confirmed by direct report). Rather than keep chasing exactly
--- which native-side quirk caused that, this now builds the "Bus Lines" group directly, ourselves,
--- from the exact ids already being stripped out of "type_other" - those ids are guaranteed
--- accurate (native's own type_other tagging already resolved which ones are real/valid this
--- frame), so this can't drift from whatever native's own custom-group pipeline does or doesn't do.
--- M.onBigmapBuildGroupData/M.onBigmapBuildCustomGroupStructures stay defined below regardless -
--- harmless, and `onBigmapBuildGroupData` specifically still fires and still matters (it's what
--- makes native accept "bjBusLines" as a valid group tag on a POI at all, instead of logging
--- "Unknown group tag" and dropping it) - only the SECTION they used to try to build is now
--- superseded by CUSTOM_GROUPS below.
---
--- THIRD fix (still live): the group CUSTOM_GROUPS builds initially landed in its OWN new section
--- (key = "beamjoy_" .. tag), separate from the "beamjoy" section garages already get via
--- M.onBigmapBuildCustomGroupStructures below - both titled "BeamJoy", but two distinct section
--- objects, which a live report showed rendering as two separate sidebar boxes (native doesn't
--- merge sections by matching title text, only by being the same object). Fixed by having
--- getGroups look for an existing section keyed "beamjoy" and append into ITS groups list instead
--- of creating a new section - so garages and bus lines now always share one "BeamJoy" box,
--- regardless of which of the two pipelines (native's custom-group-structure vs. this file's own
--- CUSTOM_GROUPS) happens to run first.
---
--- CUSTOM_GROUPS is the one place a tag's label/icon lives ; a future second custom-group-tag
--- consumer just adds an entry here and gets the same "ids pulled out of Other, merged into the
--- shared BeamJoy section" treatment for free, without needing its own copy of this logic.
---@type table<string, {label: string, icon: string}>
local CUSTOM_GROUPS = {
    bjBusLines = { label = "beamjoy.buslines.edit.lines", icon = "bus" },
    bjDeliveryDepots = { label = "beamjoy.delivery.depots", icon = "deliveryTruck" },
    bjRaces = { label = "beamjoy.bigmap.races", icon = "raceFlag" },
    bjDerbyArenas = { label = "beamjoy.bigmap.derbyArenas", icon = "carCrash" },
}

---@return table[]?
local function getGroups()
    local groups = M.baseFunctions.freeroam_vueBigMap.getGroups()
    if type(groups) ~= "table" then return groups end
    ---@type table<string, string[]> tag -> element ids pulled out of type_other for it
    local customIds = {}
    for _, section in ipairs(groups) do
        local kept = {}
        for _, group in ipairs(section.groups or {}) do
            if group.key == "type_other" and type(group.elementIds) == "table" then
                local keptIds = {}
                for _, id in ipairs(group.elementIds) do
                    local tags = M.POIs[id] and M.POIs[id].customGroupTags
                    local claimed = false
                    if type(tags) == "table" then
                        for _, tag in ipairs(tags) do
                            if CUSTOM_GROUPS[tag] then
                                customIds[tag] = customIds[tag] or {}
                                table.insert(customIds[tag], id)
                                claimed = true
                            end
                        end
                    end
                    if not claimed then table.insert(keptIds, id) end
                end
                group.elementIds = keptIds
            end
            if not group.elementIds or #group.elementIds > 0 then
                table.insert(kept, group)
            end
        end
        section.groups = kept
    end
    -- merge into the SAME "beamjoy" section garages already land in (via native's own
    -- custom-group-structure pipeline, M.onBigmapBuildCustomGroupStructures below) instead of
    -- appending a second section - two section objects both titled "BeamJoy" still render as two
    -- separate sidebar boxes (native groups by array position/key, not by matching title text),
    -- which is exactly what a live report showed: bus lines and garages each in their own
    -- "BeamJoy" category instead of sharing one.
    local beamjoySection
    for _, section in ipairs(groups) do
        if section.key == "beamjoy" then
            beamjoySection = section
            break
        end
    end
    for tag, ids in pairs(customIds) do
        local def = CUSTOM_GROUPS[tag]
        local newGroup = { key = tag, label = tr(def.label), icon = def.icon, elementIds = ids, visible = true }
        if not beamjoySection then
            beamjoySection = { key = "beamjoy", icon = "star", title = "BeamJoy", groups = {} }
            table.insert(groups, beamjoySection)
        end
        table.insert(beamjoySection.groups, newGroup)
    end
    return groups
end

--- Real, confirmed bug: the getGroups wrap above (installed once, from onInit) kept NOT taking
--- effect for the user despite being logically correct - same class of problem as
--- `enablePlaymodeMarkersInMultiplayer`'s own gasStations/markerInteraction gap this file already
--- documents: `freeroam_vueBigMap` isn't guaranteed loaded yet at mod-init time (it's the Big Map
--- UI's own GE-side counterpart - native only loads it lazily, on/around the map actually being
--- opened). `onInit` runs long before the player ever opens the Big Map, so
--- `extensions.freeroam_vueBigMap` was nil then, the wrap-install's own `if` guard silently
--- skipped it, and the ORIGINAL native `getGroups` stayed in place for the rest of the session -
--- explaining why bus lines kept showing under "Other" even after the wrap logic itself was fixed.
--- Force-load it (safe/no-op if already loaded, exactly like the gasStations force-load already
--- does) and (re)install the wrap here AND right before every Big Map open
--- (`onBeforeBigMapActivated`), not just once from onInit - cheap, idempotent (checks the field
--- isn't already pointing at `getGroups` before touching it), and guarantees it's actually in place
--- by the time native calls it, regardless of exactly when `freeroam_vueBigMap` itself first loads.
local function installBigMapGroupsWrap()
    if not extensions.freeroam_vueBigMap then
        pcall(extensions.load, "freeroam_vueBigMap")
    end
    local vbm = extensions.freeroam_vueBigMap
    if not vbm or not vbm.getGroups or vbm.getGroups == getGroups then return end
    M.baseFunctions.freeroam_vueBigMap = { getGroups = vbm.getGroups }
    vbm.getGroups = getGroups
end

-- ROUTE PREVIEW ---------------------------------------------------------------------------------
-- Direct request ("show a race's route on the map like BeamJoy 2.0.9 did") : a race's or bus
-- line's whole route, drawn on the Big Map when its pin is hovered or selected. The game only does
-- this itself for real missions (freeroam_bigMapMode's showMissionWorldPreview asks the mission
-- for getWorldPreviewRoute), and BJS POIs can't be missions (see this file's header : FATAL). It
-- draws whatever freeroam_bigMapMode.setRoutePreview is given, though, so : selecting one of ours
-- (the onPoiSelectedFromBigmap hook) shows its route, and hovering one in the list does too
-- (poiHovered, wrapped : the game clears the preview when a hover ends, ours is put back).

--- the road route through `points`, a straight line wherever the road would be a detour
---@param points vec3[]
---@return table[] path {pos: vec3}[] as gameplay/route builds them (what setRoutePreview takes)
local function buildPreviewPath(points)
    local path = {}
    local function add(pos)
        local last = path[#path]
        if not last or last.pos:squaredDistance(pos) > 1 then path[#path + 1] = { pos = vec3(pos) } end
    end
    for i = 1, #points - 1 do
        local a, b = points[i], points[i + 1]
        local straight = a:distance(b)
        local segment
        if straight >= M.ROUTE_MIN_ROAD_DIST then
            local ok, roadPath = pcall(function()
                local route = require('/lua/ge/extensions/gameplay/route/route')()
                route:setupPathMulti({ a, b })
                return route.path
            end)
            if ok and type(roadPath) == "table" and #roadPath >= 2 then
                local length = 0
                for j = 2, #roadPath do length = length + roadPath[j - 1].pos:distance(roadPath[j].pos) end
                if length <= straight * M.ROUTE_MAX_DETOUR + M.ROUTE_DETOUR_SLACK then segment = roadPath end
            end
        end
        if segment then
            for _, wp in ipairs(segment) do add(wp.pos) end
        else
            add(a)
            add(b)
        end
    end
    return path
end

--- shows a POI's route, if it has one
---@param poiId string?
---@return boolean shown
local function showRoutePreview(poiId)
    local el = poiId and M.POIs[poiId]
    local bmm = extensions.freeroam_bigMapMode
    if not el or type(el.previewPoints) ~= "table" or #el.previewPoints < 2 or not bmm or
        not bmm.setRoutePreview then
        return false
    end
    if not M.routeCache[poiId] then
        local ok, path = pcall(buildPreviewPath, el.previewPoints)
        if not ok then
            LogError("beamjoy bigmap: building a route preview failed: " .. tostring(path))
            path = {}
        end
        M.routeCache[poiId] = path
    end
    if #M.routeCache[poiId] < 2 then return false end
    bmm.setRoutePreview(M.routeCache[poiId])
    M.routeShown = true
    return true
end

local function clearOurRoutePreview()
    local bmm = extensions.freeroam_bigMapMode
    if M.routeShown and bmm and bmm.clearRoutePreview then bmm.clearRoutePreview() end
    M.routeShown = false
end

--- a pin selected on the Big Map (nil : deselected)
---@param poiId string?
M.onPoiSelectedFromBigmap = function(poiId)
    if showRoutePreview(poiId) then
        M.routeSelectedId = poiId
    else
        -- something without a route of ours : don't leave the last one up
        M.routeSelectedId = nil
        clearOurRoutePreview()
    end
end

--- freeroam_bigMapMode.poiHovered, wrapped : the list's hover shows that pin's route too, and the
--- selected one's comes back when the hover ends (the game clears it, it only knows missions)
local function poiHovered(poiIdInCluster, hovered, ...)
    local res = M.baseFunctions.freeroam_bigMapMode.poiHovered(poiIdInCluster, hovered, ...)
    if hovered then
        showRoutePreview(poiIdInCluster)
    elseif M.routeSelectedId then
        showRoutePreview(M.routeSelectedId)
    else
        M.routeShown = false -- the game cleared it
    end
    return res
end

--- same install-whenever-it-exists approach as installBigMapGroupsWrap
local function installRoutePreviewWrap()
    if not extensions.freeroam_bigMapMode then
        pcall(extensions.load, "freeroam_bigMapMode")
    end
    local bmm = extensions.freeroam_bigMapMode
    if not bmm or not bmm.poiHovered or bmm.poiHovered == poiHovered then return end
    M.baseFunctions.freeroam_bigMapMode = { poiHovered = bmm.poiHovered }
    bmm.poiHovered = poiHovered
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
    installBigMapGroupsWrap()
    installRoutePreviewWrap()
    enablePlaymodeMarkersInMultiplayer()

    beamjoy_communications_ui.addHandler("BJReady", function()
        enablePlaymodeMarkersInMultiplayer() -- re-assert after a reconnect
        installBigMapGroupsWrap()
        installRoutePreviewWrap()
        flushPOIs() -- right away : the first set of markers for this session
    end)
end

local function onExtensionUnloaded()
    RollBackNGFunctionsWrappers(M.baseFunctions)
end

--- Registers "bjBusLines" as a KNOWN group tag with native (buildPoiDataCache auto-creates an
--- unlabeled fallback group and logs "Unknown group tag" for any tag it's never told about
--- otherwise) - still worth keeping purely for that, even though the group it used to build here
--- is no longer what actually surfaces bus lines in the sidebar (see getGroups' own CUSTOM_GROUPS
--- above : real, confirmed bug, native's own custom-group-structure pipeline this used to depend
--- on - see onBigmapBuildCustomGroupStructures below - turned out unreliable enough in practice
--- that bus lines stopped showing anywhere at all ; getGroups now builds that group itself,
--- directly, instead).
---@param groupData table<string, table>
M.onBigmapBuildGroupData = function(groupData)
    groupData.bjBusLines = { label = tr("beamjoy.buslines.edit.lines"), icon = "bus" }
    groupData.bjDeliveryDepots = { label = tr("beamjoy.delivery.depots"), icon = "deliveryTruck" }
    groupData.bjRaces = { label = tr("beamjoy.bigmap.races"), icon = "raceFlag" }
    groupData.bjDerbyArenas = { label = tr("beamjoy.bigmap.derbyArenas"), icon = "carCrash" }
end

--- vueBigMap's freeroam-mode side menu only lists `type_garage` when a career is active (see its
--- own buildGroupStructure), so this "BeamJoy" section is still needed for garages. Bus lines used
--- to ride along in this same section too ("groupIds" listed both) until a live report showed them
--- vanishing from the sidebar entirely - confirmed (by reading vueBigMap.lua's own source) that
--- this whole custom-group-structure mechanism is real and DOES fire on a BJS/freeroam server, but
--- something about depending on it specifically for bus lines wasn't reliable ; rather than keep
--- chasing the exact native-side reason, bus lines are now built directly by getGroups' own
--- CUSTOM_GROUPS (bigmap.lua's own file, doesn't depend on this hook or on native's visibility-
--- state defaulting at all), and are deliberately no longer listed here to avoid ever showing a
--- duplicate section if native's own path happens to start working too. getGroups finds THIS
--- section by its "beamjoy" key and appends the bus-lines group into it, so both still end up
--- sharing one sidebar box regardless of which pipeline builds it.
--- Dropped automatically when a group has no elements.
---@param structures table[]
M.onBigmapBuildCustomGroupStructures = function(structures)
    structures[#structures + 1] = {
        key = "beamjoy",
        icon = "star",
        title = "BeamJoy",
        groupIds = { "type_garage" },
    }
end

M.onInit = onInit
M.onExtensionUnloaded = onExtensionUnloaded
M.onPreExit = onExtensionUnloaded
M.onBeforeBigMapActivated = function()
    installBigMapGroupsWrap() -- see its own comment - freeroam_vueBigMap may only just now exist
    installRoutePreviewWrap()
    -- the map shows what's current, not what's still waiting on updatePOIs' coalescing
    if M.rebuildRequestedAt then flushPOIs() end
    M.menuOpened = true
end
M.onDeactivateBigMapCallback = function()
    M.menuOpened = false
    clearOurRoutePreview()
    M.routeSelectedId = nil
end

M.getRawPOIs = getRawPOIs
M.updatePOIs = updatePOIs
M.flushPOIs = flushPOIs
M.onUpdate = onUpdate

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
        previewPoints = { vec3(...), ... },   -- optional : a route (start, checkpoints...) drawn
                                              -- on the map, along the roads, while the pin is
                                              -- hovered or selected
    }
end

Then call `bigmap.updatePOIs()` whenever the source data changes (the rebuild is coalesced, within
~300 ms ; `bigmap.flushPOIs()` rebuilds right away). POIs get a real Big Map marker,
a list card, a working "Set route", and (if canQuickTravel) quick travel - all handled by the
native `freeroam_vueBigMap` / `freeroam_bigMapMode` from the shape above. They do NOT get an
in-world 3D marker (draw that yourself if you want one).
]]
