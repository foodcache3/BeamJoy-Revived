local M = {
    baseFunctions = {},

    TABS = {
        ACTIVITIES = {
            -- icon from uiIcons
            icon = "flag",
            order = 1,
        },
        FACILITIES = {
            icon = "fuelPump",
            order = 2,
        },
        OTHERS = {
            icon = "plus",
            order = 3,
        },
    },

    ---@type NGPOI[]
    vanillaPOIs = {},
    ---@type table<string, BJCPOI>
    POIs = {},
    ---@type NGPOI[]
    generatedPOIs = {},
    generatedPOIsGen = 0,
    cachedRoutes = {},

    menuOpened = false,
}

local function generateRawPOIs()
    table.clear(M.generatedPOIs)
    M.generatedPOIsGen = M.generatedPOIsGen + 1

    -- add vanilla POIs
    table.forEach(M.vanillaPOIs, function(poi)
        table.insert(M.generatedPOIs, poi)
    end)

    for id, el in pairs(M.POIs) do
        table.insert(M.generatedPOIs, {
            id = id,
            data = {
                type = "mission",
                missionId = id,
                date = 0,
            },
            markerInfo = {
                bigmapMarker = {
                    cluster = true,
                    icon = el.icon,
                    pos = el.pos,
                    quickTravelPosRotFunction = function()
                        return el.pos, quatFromDir(el.rot or vec3(0, 0, 1))
                    end,
                    thumbnail = el.preview,
                    preview = { el.preview },
                }
            }
        })
    end
end

---@param levelIdentifier string
local function getRawPOIs(levelIdentifier)
    return M.generatedPOIs, M.generatedPOIsGen
end

---@param id string
local function getMissionById(id)
    local poi = M.POIs[id]
    if poi then
        return {
            name = beamjoy_lang.translate(poi.name),
            unlocks = {},
            getWorldPreviewRoute = poi.route and function()
                return poi.route
            end or nil,
        }
    end
    return {
        unlocks = {},
    }
end

--- Real, cleaner fix, per direct request ("is there a better way to disable the whole map mode
--- during a race"): the previous approach only ever blocked the "bigMap" CAMERA name, via
--- camera.lua's own reactive blockedCameras mechanism. That's a poll-based catch, one frame late
--- at best (onUpdate detects the camera actually changed, then switches it back), and native
--- freeroam/bigMapMode.lua's own entry points call core_camera.setByName directly inside their own
--- transition code, a path this mod's camera.lua wrapper never sees at all, so the block could at
--- best clean up AFTER big map had already started opening (transition animation, UI overlay,
--- ui_visibility/input remapping), not actually prevent it.
---
--- `enterBigMap` (confirmed by reading the installed game's own freeroam/bigMapMode.lua) is the
--- true common funnel every real entry path goes through before any of that starts: the default
--- keybind's own toggleBigMap() calls it, but so does core/quickAccess.lua's map icon action
--- (DIRECTLY, bypassing toggleBigMap()'s own separate isCurrentlyProcessingStep check entirely),
--- and so does career code opening big map for its own missions. `enterBigMap` itself already
--- refuses outright the instant `gameplay_missions_missionManager.getCurrentTaskdataTypeOrNil()`
--- returns anything truthy (the same check a vanilla mission/scenario already relies on to block
--- big map for itself). That function has exactly one caller in the entire game (confirmed by
--- search), so wrapping it here to also return truthy while race/hunt/infected-locked covers every
--- real entry path at once, with zero side effects anywhere else. The camera-level block in
--- raceRunner.lua/hunterRunner.lua/infectedRunner.lua stays in place too, as a second, independent
--- layer, in case some other path ever manages to switch the active camera to "bigMap" regardless.
---
--- Real bug: this never got updated when Infected mode was added, so the map stayed fully
--- openable (transition animation, UI overlay, and all) during an active Infected round, unlike
--- Races and Hunter, both of which were already covered here.
---@return string?
local function getCurrentTaskdataTypeOrNil()
    if (beamjoy_raceRunner and beamjoy_raceRunner.isRaceLocked()) or
        (beamjoy_hunterRunner and beamjoy_hunterRunner.isHuntLocked()) or
        (beamjoy_infectedRunner and beamjoy_infectedRunner.isGameLocked()) then
        return "beamjoySandbox"
    end
    return M.baseFunctions.gameplay_missions_missionManager.getCurrentTaskdataTypeOrNil()
end

local vanillaIcons = {
    spawnPoint = 'fastTravel',
    garage = 'garage01',
    gasStation = 'fuelPump',
    dealership = 'carDealer',
    logisticsParking = 'boxTruckFast',
    logisticsOffice = 'boxTruckFast',
    driftSpot = 'drift01',
    dragstrip = 'drag02',
    crawl = 'mission_rockcrawling01_triangle',
    playerVehicle = 'carStarred',
    other = 'info',
}
---@param payload {filterData: table, poiData: table}
---@param canSetRoute boolean
---@param canQT boolean
local function formatVanillaPOIs(payload, canSetRoute, canQT)
    table.forEach(M.vanillaPOIs, function(poi)
        table.find(payload.filterData, function(t)
            -- missions are removed
            local tab
            if poi.data.type == "spawnPoint" then
                tab = M.TABS.OTHERS
            else
                tab = M.TABS.FACILITIES
            end
            return M.TABS[t.key] == tab
        end, function(tab)
            local group = table.find(tab.groups, function(g)
                return g.id == poi.data.type
            end)
            local bmi = poi.markerInfo.bigmapMarker or {}
            if not group then
                table.insert(tab.groups, {
                    id = poi.data.type,
                    label = beamjoy_lang.translate(bmi.name),
                    elements = {},
                })
                group = tab.groups[#tab.groups]
            end
            payload.poiData[poi.id] = {
                id = poi.id,
                icon = bmi.cardIcon and vanillaIcons[bmi.cardIcon] or nil,
                name = bmi.name,
                label = "",
                description = bmi.description,
                aggregatePrimary = bmi.aggregatePrimary,
                aggregateSecondary = bmi.aggregateSecondary,
                quickTravelAvailable = bmi.quickTravelPosRotFunction ~= nil and
                    canQT,
                quickTravelUnlocked = bmi.quickTravelPosRotFunction ~= nil and
                    canQT,
                canSetRoute = bmi.pos ~= nil and canSetRoute,
                thumbnailFile = bmi.thumbnail,
                previewFiles = bmi.previews,
                pos = bmi.pos,
            }
            table.insert(group.elements, poi.id)
        end)
    end)
end

---@param payload {filterData: table, poiData: table}
---@param canSetRoute boolean
---@param canQT boolean
local function formatCustomPOIs(payload, canSetRoute, canQT)
    for id, poi in pairs(M.POIs) do
        table.find(payload.filterData, function(tab)
            return M.TABS[tab.key] == poi.tab
        end, function(tab)
            local group = table.find(tab.groups, function(g)
                return g.id == poi.group
            end)
            if not group then
                table.insert(tab.groups, {
                    id = poi.group,
                    label = beamjoy_lang.translate(poi.group),
                    elements = {},
                })
                group = tab.groups[#tab.groups]
            end
            payload.poiData[id] = {
                id = id,
                name = beamjoy_lang.translate(poi.name),
                icon = poi.icon,
                label = poi.label and beamjoy_lang.translate(poi.label) or "",
                description = poi.description and beamjoy_lang.translate(
                    poi.description) or "",
                ratings = poi.attempts and {
                    type = "attempts",
                    attempts = poi.attempts,
                } or nil,
                aggregatePrimary = poi.aggregatePrimary,
                aggregateSecondary = poi.aggregateSecondary,
                quickTravelAvailable = poi.pos ~= nil and poi.rot ~= nil and
                    poi.canQuickTravel and canQT,
                quickTravelUnlocked = poi.pos ~= nil and poi.rot ~= nil and
                    poi.canQuickTravel and canQT,
                canSetRoute = poi.pos ~= nil and
                    poi.canSetRoute and canSetRoute,
                thumbnailFile = poi.preview,
                previewFiles = poi.preview and { poi.preview } or nil,
                pos = poi.pos,
            }
            table.insert(group.elements, id)
        end)
    end
end

local function sendCurrentLevelMissionsToBigmap()
    local requestCanSetRoute = CreateRequestAuthorization(true)
    extensions.hook("onBJRequestSetRouteState", requestCanSetRoute)
    local res = {
        branchIcons = {},
        rules = {
            canSetRoute = requestCanSetRoute.state,
        },
        gameMode = "freeroam",
        levelData = table.find(extensions.core_levels.getList(), function(lvl)
            return lvl.levelName == getCurrentLevelIdentifier()
        end),
        poiData = {},
        filterData = {},
    }

    res.filterData = table.map(M.TABS, function(tab, key)
            return table.assign({ key = tostring(key) }, tab)
        end)
        :sort(function(a, b) return a.order < b.order end)
        :map(function(tab)
            return {
                key = tab.key,
                icon = tab.icon,
                groups = {},
            }
        end)

    local requestCanQT = CreateRequestAuthorization(true)
    extensions.hook("onBJRequestQuicktravelState", requestCanQT)

    formatVanillaPOIs(res, requestCanSetRoute.state, requestCanQT.state)
    formatCustomPOIs(res, requestCanSetRoute.state, requestCanQT.state)

    -- add custom POIs
    table.forEach(res.filterData, function(tab)
        table.forEach(tab.groups, function(group)
            table.sort(group.elements, function(idA, idB)
                return res.poiData[idA].name:lower() < res.poiData[idB].name:lower()
            end)
        end)
    end)
    res.filterData = table.filter(res.filterData, function(tab)
        -- remove empty tabs
        return #tab.groups > 0
    end)

    guihooks.trigger("BigmapMissionData", res)
end

local function onInit()
    M.baseFunctions = {
        freeroam_bigMapPoiProvider = {
            sendCurrentLevelMissionsToBigmap = extensions.freeroam_bigMapPoiProvider.sendCurrentLevelMissionsToBigmap,
        },
        gameplay_rawPois = {
            getRawPoiListByLevel = extensions.gameplay_rawPois.getRawPoiListByLevel,
        },
        gameplay_missions_missions = {
            getMissionById = extensions.gameplay_missions_missions.getMissionById
        },
        gameplay_missions_missionManager = {
            getCurrentTaskdataTypeOrNil = extensions.gameplay_missions_missionManager.getCurrentTaskdataTypeOrNil,
        },
    }
    extensions.gameplay_rawPois.getRawPoiListByLevel = getRawPOIs
    extensions.gameplay_missions_missions.getMissionById = getMissionById
    extensions.freeroam_bigMapPoiProvider.sendCurrentLevelMissionsToBigmap = sendCurrentLevelMissionsToBigmap
    extensions.gameplay_missions_missionManager.getCurrentTaskdataTypeOrNil = getCurrentTaskdataTypeOrNil

    beamjoy_communications_ui.addHandler("BJReady", function()
        M.vanillaPOIs = table.filter(M.baseFunctions.gameplay_rawPois
            .getRawPoiListByLevel(getCurrentLevelIdentifier()), function(poi)
                return poi.data.type ~= "mission" and poi.markerInfo.bigmapMarker ~= nil
            end)
        M.updatePOIs()
    end)
end

local function onExtensionUnloaded()
    RollBackNGFunctionsWrappers(M.baseFunctions)
end

---@param positions vec3[]
---@return table
local function createNavGraphRoute(positions)
    local route = require('/lua/ge/extensions/gameplay/route/route')()
    route:setRouteParams(M._routeParams.cutOffDrivability, M._routeParams.dirMult,
        M._routeParams.penaltyAboveCutoff, M._routeParams.penaltyBelowCutoff,
        M._routeParams.wD, M._routeParams.wZ)
    route:setupPathMulti(positions)
    return route.path
end

local function updatePOIs()
    table.clear(M.POIs)
    extensions.hook("onBJRequestBigmapPOIs", M.POIs)

    generateRawPOIs()
end

M.onInit = onInit
M.onExtensionUnloaded = onExtensionUnloaded
M.onBeforeBigMapActivated = function()
    M.menuOpened = true
end
M.onDeactivateBigMapCallback = function()
    M.menuOpened = false
end

M.createNavGraphRoute = createNavGraphRoute
M.updatePOIs = updatePOIs

return M

--[[
To create custom POIs, add the "onBJRequestBigmapPOIs" method in your extension, example:

---@param POIS table<string, BJCPOI>
M.onBJRequestBigmapPOIs = function(POIS)
    POIS["test_poi"] = {
        id = "test_poi",
        tab = bigmap.TABS.ACTIVITIES,
        group = "My awesome group",
        name = "My test activity",
        label = "My activity label", -- label is displayed over the name
        description = "My activity description",
        icon = icons.ICONS.mission_route_triangle, -- icon from iconAtlas (icons.ICONS)
        pos = vec3(.267, .185, 36.5),
        canSetRoute = true,
        canQuickTravel = false,
        preview = "/levels/east_coast_usa/east_coast_usa_preview1_v2.jpg", -- path to any mounted image
    }
    POIS["test_poi_2"] = {
        id = "test_poi_2",
        tab = bigmap.TABS.OTHERS,
        group = "myext.poi.act2.group.label_key",
        name = "myext.poi.act2.name_key",
        label = "myext.poi.act2.label_key",
        description = "myext.poi.act2.description_key",
        icon = icons.ICONS.poi_exclamationmark_round,
        pos = vec3(-397, -480, 38.5),
        canSetRoute = true,
        rot = vec3(-0.71, 0.7, .01), -- mandatory for quicktravels
        canQuickTravel = true,
        preview = "/levels/driver_training/driver_training_preview_2.jpg",
    }
end
]]
