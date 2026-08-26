local M = {
    dependencies = {},

    ---@type BJRace[] races for the current map
    data = {},

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

local function confirmLegacyImport()
    beamjoy_communications.send("raceLegacyImportConfirm")
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
local function requestLeaderboard(raceId)
    beamjoy_communications.send("raceLeaderboardRequest", raceId)
end

---@param raceId integer
---@param entries {playerName: string, time: integer, model: string, date: integer, rank: integer}[]
---@param selfEntry {playerName: string, time: integer, model: string, date: integer, rank: integer}?
local function onLeaderboardReceived(raceId, entries, selfEntry)
    beamjoy_communications_ui.send("BJRaceLeaderboard", {
        raceId = raceId,
        entries = entries,
        selfEntry = selfEntry,
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

---@param caches table
local function retrieveCache(caches)
    if caches.races then
        M.data = caches.races
        extensions.hook("onBJRacesChanged")
        pushListToUI()
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
