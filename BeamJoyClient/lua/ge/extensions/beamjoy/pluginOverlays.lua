--- Activity overlays from the server's plugins, and the GPS route one can set (the API's gps.set).
--- Activity overlays from the server's plugins (BeamJoy's plugin API, overlay.show : the server's
--- services/pluginOverlay.lua checks and sends them). Kept here as they come (the UI is rebuilt on
--- every reload, this isn't), and handed whole to windows/pluginOverlays whenever they change or it
--- asks. Each carries how long ago it arrived (ageMs), so a running timer or a time limit picks up
--- where it was, not from when the UI happened to get it.

local M = {
    dependencies = { "beamjoy_communications", "beamjoy_communications_ui" },
    ---@type table<string, {data: table, receivedAt: integer}> key ("<plugin>/<id>") -> overlay
    overlays = {},
}

local function push()
    local now = GetCurrentTimeMillis()
    local list = {}
    for key, o in pairs(M.overlays) do
        local age = now - o.receivedAt
        -- its time limit ran out : the UI took it down already, and it's gone here too
        if type(o.data.remainingMs) == "number" and age >= o.data.remainingMs then
            M.overlays[key] = nil
        else
            list[#list + 1] = { overlay = o.data, ageMs = age }
        end
    end
    table.sort(list, function(a, b) return (a.overlay.seq or 0) < (b.overlay.seq or 0) end)
    beamjoy_communications_ui.send("BJPluginOverlays", list)
end

--- the API's gps.set : the game's own route to a point, or nothing (cleared). The same native
--- route BeamJoy's own deliveries and stations set (core_groundMarkers.setPath), so a plugin's
--- route and one of those replace each other rather than stacking - last one set wins
---@param data table {pos: {x, y, z}?, plugin: string}
local function onGps(data)
    if not extensions.core_groundMarkers then return end
    local pos = type(data) == "table" and type(data.pos) == "table" and data.pos or nil
    local ok, err = pcall(extensions.core_groundMarkers.setPath,
        pos and vec3(pos.x, pos.y, pos.z) or nil)
    if not ok then
        LogError("beamjoy_pluginOverlays : the plugin's GPS route couldn't be set : " .. tostring(err))
    end
end

---@param action "show"|"hide"
---@param data table|string the overlay, or the key of the one to take down
local function onMessage(action, data)
    if action == "show" and type(data) == "table" and type(data.key) == "string" then
        M.overlays[data.key] = { data = data, receivedAt = GetCurrentTimeMillis() }
    elseif action == "hide" and type(data) == "string" then
        M.overlays[data] = nil
    else
        return
    end
    push()
end

--- the full set, with the caches (joining, a reload) : replaces whatever was here
---@param caches table
local function onCache(caches)
    if caches.pluginOverlays == nil then return end
    M.overlays = {}
    local now = GetCurrentTimeMillis()
    if type(caches.pluginOverlays) == "table" then
        for _, o in pairs(caches.pluginOverlays) do
            if type(o) == "table" and type(o.key) == "string" then
                M.overlays[o.key] = { data = o, receivedAt = now }
            end
        end
    end
    push()
end

local function onInit()
    beamjoy_communications.addHandler("pluginOverlay", onMessage)
    beamjoy_communications.addHandler("pluginGps", onGps)
    beamjoy_communications.addHandler("sendCache", onCache)
    beamjoy_communications_ui.addHandler("BJPluginOverlaysRequest", push)
end

local function onServerLeave()
    M.overlays = {}
    push()
end

M.onInit = onInit
M.onServerLeave = onServerLeave

return M
