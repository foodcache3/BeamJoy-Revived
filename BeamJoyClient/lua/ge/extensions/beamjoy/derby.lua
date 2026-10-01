--- Client-side mirror of the current map's derby arenas (a list, unlike hunter/infected's single
--- arena ; see services/derby.lua), plus the Activities tab's trimmed arena info and the legacy
--- import wiring.

local M = {
    dependencies = {},

    ---@type BJDerbyArena[]
    data = {},
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

---@param caches table
local function retrieveCache(caches)
    if caches.derbyArenas ~= nil then
        M.data = type(caches.derbyArenas) == "table" and caches.derbyArenas or {}
        extensions.hook("onBJDerbyArenasChanged")
        pushArenaInfo()
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
M.pushArenaInfo = pushArenaInfo
M.getArena = getArena
M.requestLegacyImportPreview = requestLegacyImportPreview
M.onLegacyImportPreviewResult = onLegacyImportPreviewResult
M.confirmLegacyImport = confirmLegacyImport
M.onLegacyImportDone = onLegacyImportDone

return M
