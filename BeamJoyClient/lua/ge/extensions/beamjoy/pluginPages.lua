--- Pages from the server's plugins in the main window (BeamJoy's plugin API, pages.* : the server's
--- services/pluginPages.lua checks them and sends each player the ones they see). Kept here as they
--- come (the UI is rebuilt on every reload, this isn't), and handed whole to windows/main whenever
--- they change or it asks. Each carries how long ago it arrived (ageMs), so a running timer picks
--- up where it was. Opening a page and clicking its buttons go back to the server.

local M = {
    dependencies = { "beamjoy_communications", "beamjoy_communications_ui" },
    ---@type table<string, {data: table, receivedAt: integer}> key ("<plugin>/<id>") -> page
    pages = {},
}

local function push()
    local now = GetCurrentTimeMillis()
    local list = {}
    for _, p in pairs(M.pages) do
        list[#list + 1] = { page = p.data, ageMs = now - p.receivedAt }
    end
    table.sort(list, function(a, b) return (a.page.seq or 0) < (b.page.seq or 0) end)
    beamjoy_communications_ui.send("BJPluginPages", list)
end

---@param action "set"|"remove"
---@param data table|string the page, or the key of the one to take away
local function onMessage(action, data)
    if action == "set" and type(data) == "table" and type(data.key) == "string" then
        M.pages[data.key] = { data = data, receivedAt = GetCurrentTimeMillis() }
    elseif action == "remove" and type(data) == "string" then
        M.pages[data] = nil
    else
        return
    end
    push()
end

--- the full set, with the caches (joining, a reload) : replaces whatever was here
---@param caches table
local function onCache(caches)
    if caches.pluginPages == nil then return end
    M.pages = {}
    local now = GetCurrentTimeMillis()
    if type(caches.pluginPages) == "table" then
        for _, p in pairs(caches.pluginPages) do
            if type(p) == "table" and type(p.key) == "string" then
                M.pages[p.key] = { data = p, receivedAt = now }
            end
        end
    end
    push()
end

local function onInit()
    beamjoy_communications.addHandler("pluginPage", onMessage)
    beamjoy_communications.addHandler("sendCache", onCache)
    beamjoy_communications_ui.addHandler("BJPluginPagesRequest", push)
    beamjoy_communications_ui.addHandler("BJPluginPageOpened", function(plugin, id)
        beamjoy_communications.send("pluginPageOpened", plugin, id)
    end)
    beamjoy_communications_ui.addHandler("BJPluginPageAction", function(plugin, id, action, values)
        beamjoy_communications.send("pluginPageAction", plugin, id, action, values)
    end)
end

local function onServerLeave()
    M.pages = {}
    push()
end

M.onInit = onInit
M.onServerLeave = onServerLeave

return M
