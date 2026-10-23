--- What the server's plugins add to BeamJoy's windows (the plugin API : the server's
--- services/pluginUi.lua) : race option sections for the start menu and the race editor, and
--- config tabs, and event formats (services/racePhases.lua). Kept here as they come and handed to the UI (cmps/pluginOptions) whenever they change
--- or it asks ; a config tab's values only reach staff allowed to edit them, on request.

local M = {
    dependencies = { "beamjoy_communications", "beamjoy_communications_ui" },
    ---@type {race: table[], config: table[], formats: table[]}
    data = { race = {}, config = {}, formats = {} },
}

local function push()
    beamjoy_communications_ui.send("BJPluginUi", M.data)
end

---@param data table
local function set(data)
    if type(data) ~= "table" then return end
    M.data = {
        race = type(data.race) == "table" and data.race or {},
        config = type(data.config) == "table" and data.config or {},
        formats = type(data.formats) == "table" and data.formats or {},
    }
    push()
end

---@param caches table
local function onCache(caches)
    if caches.pluginUi ~= nil then set(caches.pluginUi) end
end

---@param plugin string
---@param values table
---@param secrets table which secret options have a value stored (never the values themselves)
local function onConfigValues(plugin, values, secrets)
    beamjoy_communications_ui.send("BJPluginConfigValues", { plugin = plugin, values = values or {},
        secrets = secrets or {} })
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", onCache)
    beamjoy_communications.addHandler("pluginUi", set)
    beamjoy_communications.addHandler("pluginConfigValues", onConfigValues)
    beamjoy_communications_ui.addHandler("BJPluginUiRequest", push)
    beamjoy_communications_ui.addHandler("BJPluginConfigValuesRequest", function(plugin)
        beamjoy_communications.send("pluginConfigValuesRequest", plugin)
    end)
    beamjoy_communications_ui.addHandler("BJPluginConfigSave", function(plugin, values)
        beamjoy_communications.send("pluginConfigSave", plugin, values)
    end)
    beamjoy_communications_ui.addHandler("BJPluginConfigAction", function(plugin, action)
        beamjoy_communications.send("pluginConfigAction", plugin, action)
    end)
end

local function onServerLeave()
    M.data = { race = {}, config = {}, formats = {} }
    push()
end

M.onInit = onInit
M.onServerLeave = onServerLeave

return M
