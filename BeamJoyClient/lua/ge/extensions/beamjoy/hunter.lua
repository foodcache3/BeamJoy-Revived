--- Client-side cache mirror for the current map's Hunter arena (a single object, not an array,
--- see the plan's design decision); mirrors races.lua's own retrieveCache/save shape.

local M = {
    dependencies = {},

    ---@type BJHunterArena?
    data = nil,
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJHunterArenaInfoRequest", M.pushArenaInfo)

    -- legacy BeamJoy Free (BJI) arena import: see services/hunter.lua's own doc comment for the
    -- full design. Preview is relayed straight through to Angular (the confirm dialog is an
    -- Angular-only concept, see beamjoyConfirm); "done" is just toasted directly here, no need to
    -- round-trip through Angular for a one-shot result summary.
    beamjoy_communications_ui.addHandler("BJHunterLegacyImportPreviewRequest", M.requestLegacyImportPreview)
    beamjoy_communications_ui.addHandler("BJHunterLegacyImportConfirm", M.confirmLegacyImport)
    beamjoy_communications.addHandler("hunterLegacyImportPreviewResult", M.onLegacyImportPreviewResult)
    beamjoy_communications.addHandler("hunterLegacyImportDone", M.onLegacyImportDone)
end

local function requestLegacyImportPreview()
    beamjoy_communications.send("hunterLegacyImportPreview")
end

---@param results table[]
local function onLegacyImportPreviewResult(results)
    beamjoy_communications_ui.send("BJHunterLegacyImportPreview", results or {})
end

local function confirmLegacyImport()
    beamjoy_communications.send("hunterLegacyImportConfirm")
end

---@param imported integer
---@param failed integer
local function onLegacyImportDone(imported, failed)
    if failed and failed > 0 then
        toast.warn(string.format("Hunter import : %d map(s) imported, %d failed (see server console)",
            imported or 0, failed), nil, 8)
    else
        toast.warn(string.format("Hunter import : %d map(s) imported", imported or 0), nil, 6)
    end
end

--- trimmed {enabled, defaults} summary for the Activities tab's start panel (whether Hunter is even
--- available on this map, and the arena's own saved defaults to seed the start-options panel):
--- the full arena geometry (spawns/waypoints) is only ever needed by the in-world editor itself
local function pushArenaInfo()
    beamjoy_communications_ui.send("BJHunterArenaInfo", {
        enabled = M.data ~= nil and M.data.enabled == true,
        defaults = M.data and M.data.defaults or {},
        -- just a count, not the full geometry (that's the in-world editor's own job): lets the
        -- start-options panel hide the "Respawn hubs" strategy option when none are placed, same
        -- as the editor itself does from its own live list data
        respawnHubCount = M.data and #(M.data.respawnHubs or {}) or 0,
    })
end

---@param caches table
local function retrieveCache(caches)
    if caches.hunterArena ~= nil then
        M.data = caches.hunterArena
        extensions.hook("onBJHunterArenaChanged")
        pushArenaInfo()
    end
end

---@param arena BJHunterArena
local function save(arena)
    beamjoy_communications.send("hunterArenaSave", arena)
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
