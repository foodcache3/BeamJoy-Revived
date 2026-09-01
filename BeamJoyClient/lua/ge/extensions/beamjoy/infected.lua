--- Client-side cache mirror for the current map's Infected arena (a single object, not an array,
--- same as hunter.lua's own arena mirror); mirrors hunter.lua's own retrieveCache/save shape exactly.

local M = {
    dependencies = {},

    ---@type BJInfectedArena?
    data = nil,
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJInfectedArenaInfoRequest", M.pushArenaInfo)

    -- legacy BeamJoy Free (BJI) arena import: see services/infected.lua's own doc comment (the same
    -- <map>_hunter.json files Hunter's own importer reads, just the other half of the data)
    beamjoy_communications_ui.addHandler("BJInfectedLegacyImportPreviewRequest", M.requestLegacyImportPreview)
    beamjoy_communications_ui.addHandler("BJInfectedLegacyImportConfirm", M.confirmLegacyImport)
    beamjoy_communications.addHandler("infectedLegacyImportPreviewResult", M.onLegacyImportPreviewResult)
    beamjoy_communications.addHandler("infectedLegacyImportDone", M.onLegacyImportDone)
end

local function requestLegacyImportPreview()
    beamjoy_communications.send("infectedLegacyImportPreview")
end

---@param results table[]
local function onLegacyImportPreviewResult(results)
    beamjoy_communications_ui.send("BJInfectedLegacyImportPreview", results or {})
end

local function confirmLegacyImport()
    beamjoy_communications.send("infectedLegacyImportConfirm")
end

---@param imported integer
---@param failed integer
local function onLegacyImportDone(imported, failed)
    if failed and failed > 0 then
        toast.warn(string.format("Infected import : %d map(s) imported, %d failed (see server console)",
            imported or 0, failed), nil, 8)
    else
        toast.warn(string.format("Infected import : %d map(s) imported", imported or 0), nil, 6)
    end
end

--- trimmed {enabled, defaults} summary for the Activities tab's start panel, same reasoning as
--- hunter.lua's own pushArenaInfo : the full arena geometry (spawns) is only ever needed by the
--- in-world editor itself
local function pushArenaInfo()
    beamjoy_communications_ui.send("BJInfectedArenaInfo", {
        enabled = M.data ~= nil and M.data.enabled == true,
        defaults = M.data and M.data.defaults or {},
    })
end

---@param caches table
local function retrieveCache(caches)
    if caches.infectedArena ~= nil then
        M.data = caches.infectedArena
        extensions.hook("onBJInfectedArenaChanged")
        pushArenaInfo()
    end
end

---@param arena BJInfectedArena
local function save(arena)
    beamjoy_communications.send("infectedArenaSave", arena)
end

M.onInit = onInit
M.retrieveCache = retrieveCache
M.pushArenaInfo = pushArenaInfo
M.save = save
M.requestLegacyImportPreview = requestLegacyImportPreview
M.onLegacyImportPreviewResult = onLegacyImportPreviewResult
M.confirmLegacyImport = confirmLegacyImport
M.onLegacyImportDone = onLegacyImportDone

return M
