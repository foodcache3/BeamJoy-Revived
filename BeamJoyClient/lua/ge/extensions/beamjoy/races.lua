local M = {
    dependencies = {},

    ---@type BJRace[] races for the current map
    data = {},

    -- the race start marker (world and Big Map) : the game's own time-trial mission icon
    MARKER_ICON = "mission_timeTrials_triangle",
    --- the races behind this client's start markers, by marker id
    ---@type table<string, BJRace>
    raceByMarkerId = {},

    --- quick console-driven race builder, ahead of the real in-world editor. Call these from
    --- BeamNG's Lua console while positioned/facing where you want each gate/start, e.g.
    --- `beamjoy_races.testAddGate()`, then `beamjoy_races.testAddStart()`, then
    --- `beamjoy_races.testFinish("My Test Race")`, which logs the assigned id once the server
    --- confirms the save (or `beamjoy_races.findByName("My Test Race")` any time after).
    testBuilder = {
        mode = "grid",
        ---@type BJRaceGate[]
        gates = {},
        ---@type {pos: {x:number,y:number,z:number}, dir: {x:number,y:number,z:number}}[]
        startPositions = {},
    },
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJEditorRaceListRequest", M.pushListToUI)
    beamjoy_communications_ui.addHandler("BJRaceLeaderboardRequest", M.requestLeaderboard)
    beamjoy_communications.addHandler("raceLeaderboard", M.onLeaderboardReceived)
    beamjoy_communications_ui.addHandler("BJRaceLeaderboardSummaryRequest", function()
        beamjoy_communications.send("raceLeaderboardSummaryRequest")
    end)
    beamjoy_communications.addHandler("raceLeaderboardSummary", function(list)
        beamjoy_communications_ui.send("BJRaceLeaderboardSummary", list or {})
    end)

    -- legacy BeamJoy Free (BJI) race import. See services/races.lua's own doc comment for the full
    -- design (non-destructive: always ADDS new races, never overwrites). Preview is relayed
    -- straight through to Angular (the confirm dialog is an Angular-only concept, see
    -- beamjoyConfirm). "Done" is just toasted directly here, no need to round-trip through Angular
    -- for a one-shot result summary. Mirrors beamjoy_hunter.lua's identical pattern.
    beamjoy_communications_ui.addHandler("BJRaceLegacyImportPreviewRequest", M.requestLegacyImportPreview)
    beamjoy_communications_ui.addHandler("BJRaceLegacyImportConfirm", M.confirmLegacyImport)
    beamjoy_communications.addHandler("raceLegacyImportPreviewResult", M.onLegacyImportPreviewResult)
    beamjoy_communications.addHandler("raceLegacyImportDone", M.onLegacyImportDone)
end

local function requestLegacyImportPreview()
    beamjoy_communications.send("raceLegacyImportPreview")
end

---@param results table[]
local function onLegacyImportPreviewResult(results)
    beamjoy_communications_ui.send("BJRaceLegacyImportPreview", results or {})
end

--- `selection` : the keys ticked in the import checklist
local function confirmLegacyImport(selection)
    beamjoy_communications.send("raceLegacyImportConfirm", selection)
end

---@param imported integer
---@param skipped integer
---@param failed integer
local function onLegacyImportDone(imported, skipped, failed)
    imported, skipped, failed = imported or 0, skipped or 0, failed or 0
    if failed > 0 then
        toast.warn(string.format("Race import : %d imported, %d skipped (name already used), %d failed (see server console)",
            imported, skipped, failed), nil, 8)
    elseif skipped > 0 then
        toast.warn(string.format("Race import : %d imported, %d skipped (name already used)",
            imported, skipped), nil, 8)
    else
        toast.warn(string.format("Race import : %d imported", imported), nil, 6)
    end
end

---@param raceId integer
---@param board string? "grid" (default) or "freeroam" (the race's freeroam runs)
local function requestLeaderboard(raceId, board)
    beamjoy_communications.send("raceLeaderboardRequest", raceId, board == "freeroam" and "freeroam" or "grid")
end

---@param raceId integer
---@param entries {playerName: string, time: integer, model: string, date: integer, rank: integer}[]
---@param selfEntry {playerName: string, time: integer, model: string, date: integer, rank: integer, fromRank: integer?}?
---@param around table[]? the entries five places either side of selfEntry
---@param players integer? everyone on the board
---@param board string? which board : "grid" or "freeroam"
---@param freeroam boolean? the race has freeroam runs (so both boards)
local function onLeaderboardReceived(raceId, entries, selfEntry, around, players, board, freeroam)
    beamjoy_communications_ui.send("BJRaceLeaderboard", {
        raceId = raceId,
        entries = entries,
        selfEntry = type(selfEntry) == "table" and selfEntry or nil,
        around = around or {},
        players = players or (entries and #entries or 0),
        board = board == "freeroam" and "freeroam" or "grid",
        freeroam = freeroam == true,
    })
end

--- lightweight {id, name, mode, gates, distance, defaults} list for the config window's race
--- browser/editor AND the main window's race-start browser (which seeds its start-options panel
--- from a race's own saved defaults, not generic hardcoded values). Owned here (not by either UI
--- module) so it stays correct regardless of whether an editor is even open, and refreshes for
--- free on every cache push (join, save, delete, map change), not just after actions taken
--- through the editor itself
local function pushListToUI()
    beamjoy_communications_ui.send("BJEditorRaceList", table.map(M.data, function(r)
        return {
            id = r.id,
            name = r.name,
            author = r.author,
            mode = r.mode,
            -- Real root cause of "the laps option doesn't appear at all, even for loopable races"
            -- (not the tooltip/mutation-observer theory from the previous round): this trimmed
            -- summary object never included `loopable` in the first place. This function's own doc
            -- comment even lists the exact field set, and loopable was never one of them. The
            -- start-options panel's `ng-if="race.loopable"` (added on the assumption this field was
            -- already here) was therefore always evaluating undefined, hiding the row
            -- unconditionally for every race regardless of whether it was actually loopable. The
            -- race editor's own laps row was unaffected: it reads $ctrl.race, the FULL race object
            -- (BJEditorRaceUpdate), not this summary.
            loopable = r.loopable,
            -- lets the start-options panel hide the "limit visible gates" control for a branching
            -- race (ambiguous once a route can fork, see raceGrid.lua's own buildSettings, which
            -- already forces the actual setting off server-side regardless of this UI hint)
            branchingEnabled = r.branchingEnabled,
            -- Shown as a read-only note on the race-start panel and browse list (per direct
            -- request: a race can restrict itself to one exact vehicle or a pool of allowed ones,
            -- e.g. a spec-car challenge or a class race). Only what's needed for display; the
            -- actual enforcement (raceRunner.lua) reads the full parts/pool data straight off the
            -- FULL race object (beamjoy_races.data, via getRace()), never this trimmed summary.
            vehicleRestrictionMode = r.vehicleRestrictionMode,
            vehicleRestrictionLabel = r.vehicleRestrictionLabel,
            -- "pool" mode only stores a reference to a shared BJVehiclePreset now (see
            -- services/vehiclePresets.lua). Angular resolves the preset's own name/entries from
            -- the separately-broadcast BJVehiclePresetList cache, keyed by this id, rather than
            -- this summary carrying its own copy of the pool
            vehicleRestrictionPoolPresetId = r.vehicleRestrictionPoolPresetId,
            gates = #r.gates,
            -- lets it hide "joinable" for single-slot races (can never actually be joined,
            -- raceStart already forces joinable=false server-side too, this is just the matching
            -- UI hint) and lets the race list show grid-slot count without sending full positions
            startPositions = #r.startPositions,
            distance = r.distance,
            defaults = r.defaults,
        }
    end):values())
end

--- a race the Activities tab lets you start (grid races ; passive ones aren't listed there) :
--- its grid slot 1, the solo start too
---@param r BJRace
---@return {pos: table, dir: table}?
local function startOf(r)
    if not r.id or r.mode ~= "grid" or type(r.startPositions) ~= "table" then return nil end
    local start = r.startPositions[1]
    return start and start.pos and start or nil
end

---@param r BJRace
---@return string
local function describe(r)
    return string.var(beamjoy_lang.translate("beamjoy.bigmap.raceDescription"),
        { #(r.gates or {}), #r.startPositions })
end

local function refreshPOIs()
    if bigmap and bigmap.updatePOIs then
        bigmap.updatePOIs()
    elseif extensions.gameplay_rawPois then
        extensions.gameplay_rawPois.clear()
    end
end

--- no start markers in the world while in an activity (a race lobby included), or with
--- Settings > Visual's activity markers hidden
---@return boolean
local function markersSuppressed()
    if beamjoy_markerSettings and beamjoy_markerSettings.activitiesHidden() then return true end
    return navigation ~= nil and navigation.inActivity ~= nil and navigation.inActivity() == true
end

--- native hook, fired by gameplay_rawPois : a mission marker at each race's start, with a drive-up
--- prompt (onActivityAcceptGatherData)
---@param level string
---@param elements table[]
local function onGetRawPoiListForLevel(level, elements)
    table.clear(M.raceByMarkerId)
    if markersSuppressed() then return end
    for _, r in ipairs(M.data or {}) do
        local start = startOf(r)
        if start then
            local id = "bjRaceStart_" .. tostring(r.id)
            M.raceByMarkerId[id] = r
            elements[#elements + 1] = {
                id = id,
                -- date : the game sorts overlapping mission markers by data.date (see stations.lua)
                data = { type = "bjRaceStart", id = id, date = 0 },
                markerInfo = {
                    missionMarker = { pos = vec3(start.pos.x, start.pos.y, start.pos.z),
                        rot = quat(0, 0, 0, 1), icon = M.MARKER_ICON },
                },
            }
        end
    end
end

--- the Activities tab on that race, its start form open
---@param raceId integer
local function openStart(raceId)
    beamjoy_communications_ui.send("BJOpenActivityStart", { kind = "race", id = raceId })
    beamjoy_mainNav.focusOn("play", "races")
end

--- the "Open race" button on the drive-up prompt
---@param elemData table[]
---@param activityData table[]
local function onActivityAcceptGatherData(elemData, activityData)
    if markersSuppressed() then return end
    for _, elem in ipairs(elemData) do
        local r = elem.type == "bjRaceStart" and M.raceByMarkerId[elem.id]
        if r then
            activityData[#activityData + 1] = {
                icon = M.MARKER_ICON,
                heading = r.name,
                preheadings = { beamjoy_lang.translate("beamjoy.bigmap.races"), describe(r) },
                buttonLabel = beamjoy_lang.translate("beamjoy.markers.openRace"),
                buttonSoundClass = "bng_hover_generic",
                sorting = { type = elem.type, id = elem.id },
                buttonFun = function() openStart(r.id) end,
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

--- the race's route for the Big Map preview : the start, the checkpoints in order (a branching
--- race's first alternate at each step), and back to the first checkpoint for a lap race
---@param r BJRace
---@param start table
---@return vec3[]?
local function previewPoints(r, start)
    local byStep, maxStep = {}, 0
    for i, g in ipairs(r.gates or {}) do
        local step = tonumber(g.step) or i
        if g.pos and not byStep[step] then byStep[step] = vec3(g.pos.x, g.pos.y, g.pos.z) end
        if step > maxStep then maxStep = step end
    end
    local points = { vec3(start.pos.x, start.pos.y, start.pos.z) }
    for step = 1, maxStep do
        if byStep[step] then points[#points + 1] = byStep[step] end
    end
    if r.loopable and byStep[1] then points[#points + 1] = byStep[1] end
    return #points >= 2 and points or nil
end

--- a Big Map pin per race in the BeamJoy section's "Races" group, at the race's own grid slot 1
--- (the solo start too) ; quick travel puts the car there, facing the way the race starts. Its
--- route shows on the map while it's hovered or selected
---@param POIS table<string, table>
local function onBJRequestBigmapPOIs(POIS)
    for _, r in ipairs(M.data or {}) do
        local start = startOf(r)
        if start then
            local pos = vec3(start.pos.x, start.pos.y, start.pos.z)
            POIS["bjRace_" .. tostring(r.id)] = {
                name = r.name,
                description = describe(r),
                icon = "raceFlag",
                mapIcon = M.MARKER_ICON,
                groupType = "other",
                customGroupTags = { "bjRaces" },
                pos = pos,
                canQuickTravel = true,
                quickTravelPos = pos,
                quickTravelRot = start.dir,
                previewPoints = previewPoints(r, start),
            }
        end
    end
end

---@param caches table
local function retrieveCache(caches)
    if caches.races then
        M.data = caches.races
        extensions.hook("onBJRacesChanged")
        pushListToUI()
        refreshPOIs()
    end
end

---@param race BJRace
local function save(race)
    beamjoy_communications.send("raceSave", race)
end

---@param raceId integer
local function delete(raceId)
    beamjoy_communications.send("raceDelete", raceId)
end

---@param name string
---@return BJRace?
local function findByName(name)
    return table.find(M.data, function(r) return r.name == name end)
end

---@return vec3? pos, vec3? dir
local function builderPositionDirection()
    local current = beamjoy_vehicles.getCurrentOwn()
    if not current then
        LogError("beamjoy_races test builder: no current vehicle")
        return nil
    end
    local pos, dir = beamjoy_vehicles.getVehiclePositionRotation(current.veh)
    return pos, dir
end

---@param width number?
---@param height number?
---@param lap true?
local function testAddGate(width, height, lap)
    local pos, dir = builderPositionDirection()
    if not pos then return end
    table.insert(M.testBuilder.gates, {
        pos = { x = pos.x, y = pos.y, z = pos.z },
        dir = { x = dir.x, y = dir.y, z = dir.z },
        width = width or 6,
        height = height or 3,
        lap = lap or nil,
    })
    LogInfo(string.format("beamjoy_races test builder: gate %d added", #M.testBuilder.gates))
    extensions.hook("onBJRaceMarkersRefresh")
end

local function testAddStart()
    local pos, dir = builderPositionDirection()
    if not pos then return end
    table.insert(M.testBuilder.startPositions, {
        pos = { x = pos.x, y = pos.y, z = pos.z },
        dir = { x = dir.x, y = dir.y, z = dir.z },
    })
    LogInfo(string.format("beamjoy_races test builder: start position %d added",
        #M.testBuilder.startPositions))
    extensions.hook("onBJRaceMarkersRefresh")
end

local function testClear()
    M.testBuilder = { mode = "grid", gates = {}, startPositions = {} }
    LogInfo("beamjoy_races test builder: cleared")
    extensions.hook("onBJRaceMarkersRefresh")
end

---@param name string
---@param loopable boolean?
---@param respawnStrategy string?
local function testFinish(name, loopable, respawnStrategy)
    if #M.testBuilder.gates < 2 then
        return LogError("beamjoy_races test builder: need at least 2 gates")
    end
    if #M.testBuilder.startPositions < 1 then
        return LogError("beamjoy_races test builder: need at least 1 start position")
    end
    ---@type BJRace
    local race = {
        name = name or "Test Race",
        author = MPConfig.getNickname(),
        mode = M.testBuilder.mode,
        distance = 0, -- not computed by this quick tool
        loopable = loopable == true,
        gates = M.testBuilder.gates,
        startPositions = M.testBuilder.startPositions,
        defaults = {
            respawnStrategy = respawnStrategy or "lastcheckpoint",
            joinable = false,
        },
    }
    M.save(race)
    M.testClear()
    LogInfo("beamjoy_races test builder: race sent, waiting on server confirmation...")
    async.delayTask(function()
        local saved = M.findByName(race.name)
        if saved then
            LogInfo(string.format(
                "beamjoy_races test builder: \"%s\" saved as id %d, use beamjoy_raceRunner.startRace(%d)",
                race.name, saved.id, saved.id))
        else
            LogError("beamjoy_races test builder: race not found after saving. Check for a permission/validation toast")
        end
    end, 1500, "BJRaceTestFinishReport")
end

M.onInit = onInit

M.retrieveCache = retrieveCache
M.onBJRequestBigmapPOIs = onBJRequestBigmapPOIs
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.onSlowUpdate = onSlowUpdate
M.openStart = openStart
M.pushListToUI = pushListToUI
M.save = save
M.delete = delete
M.findByName = findByName
M.requestLeaderboard = requestLeaderboard
M.onLeaderboardReceived = onLeaderboardReceived
M.requestLegacyImportPreview = requestLegacyImportPreview
M.onLegacyImportPreviewResult = onLegacyImportPreviewResult
M.confirmLegacyImport = confirmLegacyImport
M.onLegacyImportDone = onLegacyImportDone

M.testAddGate = testAddGate
M.testAddStart = testAddStart
M.testClear = testClear
M.testFinish = testFinish

return M
