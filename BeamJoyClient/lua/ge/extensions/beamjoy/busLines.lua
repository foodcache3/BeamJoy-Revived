--- Client-side mirror of the server's per-map bus-line data (ordered stop lists, see
--- services/busLines.lua). Owns only the synced cache : the in-world editor
--- (ui/busLineEditor.lua) and the drive loop + markers (beamjoy_busRun) both read M.data.lines
--- straight off here, so it stays correct regardless of whether an editor is even open and
--- refreshes for free on every cache push (join, save, map change).
---
--- Mirrors beamjoy/freeroamData.lua's own minimal cache-holder shape.

local M = {
    dependencies = {},

    data = {
        ---@type BJBusLine[]
        lines = {},
    },
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJEditorBusLinesDataRequest", M.pushListToUI)
    -- legacy BJI import bridge : thin passthrough, same shape as beamjoy_hunter's own /
    -- beamjoy_freeroamData's own
    beamjoy_communications_ui.addHandler("BJBusLinesLegacyImportPreviewRequest", M.requestLegacyImportPreview)
    beamjoy_communications_ui.addHandler("BJBusLinesLegacyImportConfirm", M.confirmLegacyImport)
    beamjoy_communications.addHandler("busLinesLegacyImportPreviewResult", M.onLegacyImportPreviewResult)
    beamjoy_communications.addHandler("busLinesLegacyImportDone", M.onLegacyImportDone)
end

local function requestLegacyImportPreview()
    beamjoy_communications.send("busLinesLegacyImportPreview")
end

---@param results table[]
local function onLegacyImportPreviewResult(results)
    beamjoy_communications_ui.send("BJBusLinesLegacyImportPreview", results or {})
end

local function confirmLegacyImport()
    beamjoy_communications.send("busLinesLegacyImportConfirm")
end

---@param imported integer
local function onLegacyImportDone(imported)
    toast.info(string.format(
        beamjoy_lang.translate("beamjoy.window.config.tabs.core.legacyImport.busLines.done"),
        imported or 0), nil, 6)
end

--- lightweight snapshot for the config window's Bus Lines editor : it seeds its own line-list
--- from this on open, and the tab header shows the count
local function pushListToUI()
    beamjoy_communications_ui.send("BJEditorBusLinesData", {
        lines = M.data.lines,
    })
end

---@param caches table
local function retrieveCache(caches)
    if caches.buslines then
        M.data.lines = caches.buslines
        extensions.hook("onBJBusLinesChanged")
        pushListToUI()
    end
end

---@param list table
local function saveBusLines(list)
    beamjoy_communications.send("busLinesSave", list)
end

M.onInit = onInit

M.retrieveCache = retrieveCache
M.pushListToUI = pushListToUI
M.saveBusLines = saveBusLines
M.requestLegacyImportPreview = requestLegacyImportPreview
M.onLegacyImportPreviewResult = onLegacyImportPreviewResult
M.confirmLegacyImport = confirmLegacyImport
M.onLegacyImportDone = onLegacyImportDone

return M
