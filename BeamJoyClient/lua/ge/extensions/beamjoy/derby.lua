--- Client-side mirror of the current map's derby arenas (a list, unlike hunter/infected's single
--- arena ; see services/derby.lua), plus the Activities tab's trimmed arena info and the legacy
--- import wiring.

local M = {
    dependencies = {},

    ---@type BJDerbyArena[]
    data = {},

    -- the arena marker (world and Big Map) : the game's own crash test icon
    MARKER_ICON = "mission_crash_test",
    --- the arenas behind this client's markers, by marker id
    ---@type table<string, BJDerbyArena>
    arenaByMarkerId = {},
}

--- what the Activities tab needs to start a game : no geometry beyond counts
local function pushArenaInfo()
    local list = {}
    for _, a in ipairs(M.data or {}) do
        table.insert(list, {
            id = a.id,
            name = a.name,
            enabled = a.enabled == true and #(a.startPositions or {}) >= 2,
            places = #(a.startPositions or {}),
            hasZone = a.zone ~= nil,
            defaults = a.defaults or {},
        })
    end
    beamjoy_communications_ui.send("BJDerbyArenaInfo", { arenas = list })
end

--- a playable arena (the ones the Activities tab lets you start) : its first start position
---@param a BJDerbyArena
---@return {pos: table, dir: table}?
local function startOf(a)
    local starts = a.startPositions or {}
    local start = starts[1]
    if a.id and a.enabled == true and #starts >= 2 and start and start.pos then return start end
    return nil
end

---@param a BJDerbyArena
---@return string
local function describe(a)
    return string.var(beamjoy_lang.translate("beamjoy.bigmap.derbyDescription"),
        { #(a.startPositions or {}) })
end

local function refreshPOIs()
    if bigmap and bigmap.updatePOIs then
        bigmap.updatePOIs()
    elseif extensions.gameplay_rawPois then
        extensions.gameplay_rawPois.clear()
    end
end

--- no arena markers in the world while in an activity, or with Settings > Visual's activity
--- markers hidden
---@return boolean
local function markersSuppressed()
    if beamjoy_markerSettings and beamjoy_markerSettings.hideActivities then return true end
    return navigation ~= nil and navigation.inActivity ~= nil and navigation.inActivity() == true
end

--- native hook, fired by gameplay_rawPois : a mission marker at each playable arena, with a
--- drive-up prompt (onActivityAcceptGatherData)
---@param level string
---@param elements table[]
local function onGetRawPoiListForLevel(level, elements)
    table.clear(M.arenaByMarkerId)
    if markersSuppressed() then return end
    for _, a in ipairs(M.data or {}) do
        local start = startOf(a)
        if start then
            local id = "bjDerbyStart_" .. tostring(a.id)
            M.arenaByMarkerId[id] = a
            elements[#elements + 1] = {
                id = id,
                -- date : the game sorts overlapping mission markers by data.date (see stations.lua)
                data = { type = "bjDerbyStart", id = id, date = 0 },
                markerInfo = {
                    missionMarker = { pos = vec3(start.pos.x, start.pos.y, start.pos.z),
                        rot = quat(0, 0, 0, 1), icon = M.MARKER_ICON },
                },
            }
        end
    end
end

--- the Activities tab on that arena, its start form open (or its Join button, a game being on)
---@param arenaId integer
local function openStart(arenaId)
    beamjoy_communications_ui.send("BJOpenActivityStart", { kind = "derby", id = arenaId })
    beamjoy_mainNav.focusOn("play", "derby")
end

--- the "Open derby" button on the drive-up prompt
---@param elemData table[]
---@param activityData table[]
local function onActivityAcceptGatherData(elemData, activityData)
    if markersSuppressed() then return end
    for _, elem in ipairs(elemData) do
        local a = elem.type == "bjDerbyStart" and M.arenaByMarkerId[elem.id]
        if a then
            activityData[#activityData + 1] = {
                icon = M.MARKER_ICON,
                heading = a.name,
                preheadings = { beamjoy_lang.translate("beamjoy.bigmap.derbyArenas"), describe(a) },
                buttonLabel = beamjoy_lang.translate("beamjoy.markers.openDerby"),
                buttonSoundClass = "bng_hover_generic",
                sorting = { type = elem.type, id = elem.id },
                buttonFun = function() openStart(a.id) end,
            }
        end
    end
end

-- markers come and go as the player joins and leaves activities
local lastSuppressed
local function onSlowUpdate()
    local suppressed = markersSuppressed()
    if lastSuppressed ~= nil and suppressed ~= lastSuppressed then refreshPOIs() end
    lastSuppressed = suppressed
end

--- a Big Map pin per playable arena in the BeamJoy section's "Derby arenas" group, at the arena's
--- own first start position ; quick travel puts the car there
---@param POIS table<string, table>
local function onBJRequestBigmapPOIs(POIS)
    for _, a in ipairs(M.data or {}) do
        local start = startOf(a)
        if start then
            local pos = vec3(start.pos.x, start.pos.y, start.pos.z)
            POIS["bjDerbyArena_" .. tostring(a.id)] = {
                name = a.name,
                description = describe(a),
                icon = "carCrash",
                mapIcon = M.MARKER_ICON,
                groupType = "other",
                customGroupTags = { "bjDerbyArenas" },
                pos = pos,
                canQuickTravel = true,
                quickTravelPos = pos,
                quickTravelRot = start.dir,
            }
        end
    end
end

---@param caches table
local function retrieveCache(caches)
    if caches.derbyArenas ~= nil then
        M.data = type(caches.derbyArenas) == "table" and caches.derbyArenas or {}
        extensions.hook("onBJDerbyArenasChanged")
        pushArenaInfo()
        refreshPOIs()
    end
end

---@param id integer
---@return BJDerbyArena?
local function getArena(id)
    for _, a in ipairs(M.data or {}) do
        if a.id == id then return a end
    end
end

local function requestLegacyImportPreview()
    beamjoy_communications.send("derbyLegacyImportPreview")
end

---@param results table[]
local function onLegacyImportPreviewResult(results)
    beamjoy_communications_ui.send("BJDerbyLegacyImportPreview", results or {})
end

--- `selection` : the keys ticked in the import checklist
local function confirmLegacyImport(selection)
    beamjoy_communications.send("derbyLegacyImportConfirm", selection)
end

---@param imported integer
---@param failed integer
local function onLegacyImportDone(imported, failed)
    if failed and failed > 0 then
        toast.warn(string.format("Derby import : %d arena(s) imported, %d failed (see server console)",
            imported or 0, failed), nil, 8)
    else
        toast.warn(string.format("Derby import : %d arena(s) imported", imported or 0), nil, 6)
    end
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJDerbyArenaInfoRequest", M.pushArenaInfo)
    beamjoy_communications_ui.addHandler("BJDerbyLegacyImportPreviewRequest", M.requestLegacyImportPreview)
    beamjoy_communications_ui.addHandler("BJDerbyLegacyImportConfirm", M.confirmLegacyImport)
    beamjoy_communications.addHandler("derbyLegacyImportPreviewResult", M.onLegacyImportPreviewResult)
    beamjoy_communications.addHandler("derbyLegacyImportDone", M.onLegacyImportDone)
end

M.onInit = onInit
M.retrieveCache = retrieveCache
M.onBJRequestBigmapPOIs = onBJRequestBigmapPOIs
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.onSlowUpdate = onSlowUpdate
M.openStart = openStart
M.pushArenaInfo = pushArenaInfo
M.getArena = getArena
M.requestLegacyImportPreview = requestLegacyImportPreview
M.onLegacyImportPreviewResult = onLegacyImportPreviewResult
M.confirmLegacyImport = confirmLegacyImport
M.onLegacyImportDone = onLegacyImportDone

return M
