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

return M
