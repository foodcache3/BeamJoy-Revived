--[[
BeamJoyAbstract for BeamMP
Copyright (C) 2025 TontonSamael

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

Contact : https://github.com/my-name-is-samael
]]

require("utils/log")
require("utils/lua")
require("utils/string")
require("utils/table")
require("utils/math")
require("utils/mp")
require("utils/FS")

BJSPluginPath = debug.getinfo(1).source:gsub("\\", "/")
BJSPluginPath = BJSPluginPath:sub(1, (BJSPluginPath:find("BeamJoyServer.lua")) - 2)

local M = {
    BUILD = -1,
    VERSION = "INVALID",
    dependencies = { "utils_async", "utils_sha", "utils_json", "utils_toml",
        "dao_main", "dao_core", "dao_config", "dao_groups", "dao_players",
        "dao_permissions", "dao_groups", "dao_environment", "dao_activity", "dao_bundled",
        "dao_maps", "dao_vehiclePresets",
        "services_core", "services_lang", "services_config", "services_groups",
        "services_players", "services_vehicles", "services_chat", "services_cache",
        "services_permissions", "services_traffic", "services_consoleCommands",
        "services_activityConfig", "services_chatCommands", "services_environment",
        "services_broadcast", "services_maps", "services_mapVote", "services_kickVote",
        "services_vehiclePresets", "services_races", "services_raceGrid",
        "services_hunter", "services_hunterGrid",
        "services_infected", "services_infectedGrid",
        "services_freeroamData",
        "services_busLines", "services_busRuns",
        "services_identity",
        "communications_rx", "communications_tx" },
}

local function loadVersion()
    local file = io.open(BJSPluginPath .. "/buildversion", "r")
    if file then
        M.BUILD = file:read("*number")
        file:close()
    else
        LogError("buildversion file not found")
    end

    file = io.open(BJSPluginPath .. "/version", "r")
    if file then
        M.VERSION = file:read("*a"):gsub("\n", ""):gsub(" ", "")
        file:close()
    else
        LogError("version file not found")
    end
end
loadVersion()

local function drawArt()
    -- https://patorjk.com/software/taag/#p=display&h=3&v=3&f=Slant&t=BeamJoy%20Sandbox
    LogDebug([[

    ____                           __               _____                 ____
   / __ )___  ____  ____ ___      / /___  __  __   / ___/____  ____  ____/ / /_  ____  _  __
  / __  / _ \/ __ `/ __ `__ \__  / / __ \/ / / /   \__ \/ __ `/ __ \/ __  / __ \/ __ \| |/_/
 / /_/ /  __/ /_/ / / / / / / /_/ / /_/ / /_/ /   ___/ / /_/ / / / / /_/ / /_/ / /_/ _>  <
/_____/\___/\__,_/_/ /_/ /_/\____/\____/\__, /   /____/\__,_/_/ /_/\__,_/_.___/\____/_/|_|
                                       /____/
]])
end

local function checkWritePermissions()
    local target = BJSPluginPath .. "/tmp"
    if not FS.Exists(target) then
        FS.CreateDirectory(target)
        if not FS.Exists(target) then
            return false
        end
        FS.RemoveDirectory(target)
    else
        FS.RemoveDirectory(target)
        if FS.Exists(target) then
            return false
        end
    end

    return true
end

local function loadExtensions()
    _G.extensions = _G.extensions or {}
    local reserved = { "hook", "hookWithReturn" }
    local function _load(deps)
        for _, rawDep in pairs(deps) do
            local dep = Table(rawDep:split2("_")):join("/")
            if table.includes(reserved, dep) then
                LogError(string.format("Extension \"%s\" cannot be loaded (reserved keyword)", dep))
            elseif not _G[rawDep] then
                _G[rawDep] = require(dep)
                extensions[rawDep] = _G[rawDep]
                if type(extensions[rawDep].dependencies) == "table" then
                    _load(extensions[rawDep].dependencies)
                end
            end
        end
    end
    _load(M.dependencies)
    ---@param key string
    extensions.hook = function(key, ...)
        for extName, ext in pairs(_G.extensions) do
            if type(ext) == "table" and type(ext[key]) == "function" then
                local ok, res = pcall(ext[key], ...)
                if not ok then
                    LogError(string.format("Error firing event %s.%s : %s", extName, key, res))
                end
            end
        end
    end
    ---@param key string
    ---@return any
    extensions.hookWithReturn = function(key, ...)
        for extName, ext in pairs(_G.extensions) do
            if type(ext) == "table" and type(ext[key]) == "function" then
                local ok, res = pcall(ext[key], ...)
                if not ok then
                    LogError(string.format("Error firing event %s.%s : %s", extName, key, res))
                elseif res ~= nil then
                    return res
                end
            end
        end
    end
    extensions.hook("onPreInit")
    extensions.hook("onInit")
end

local function loadHooks()
    for hook, data in pairs({
        BJSUpdate = { handler = "onUpdate", timer = 100 },
        BJSSlowUpdate = { handler = "onSlowUpdate", timer = 1000 },
        onBJSChatMessage = { handler = "onChatMessage" },
        onBJSConsoleInput = { handler = "onConsoleInput" },
        onPlayerAuth = { handler = "onPlayerAuth", withReturn = true },
        onPlayerConnecting = { handler = "onPlayerConnecting" },
        onPlayerJoining = { handler = "onPlayerJoining" },
        onPlayerJoin = { handler = "onPlayerJoin" },
        onPlayerDisconnect = { handler = "onPlayerDisconnect" },
        onVehicleSpawn = { handler = "onVehicleSpawn", withReturn = true },
        onVehicleReset = { handler = "onVehicleReset" },
        onVehicleEdited = { handler = "onVehicleEdited", withReturn = true },
        onVehiclePaintChanged = { handler = "onVehiclePaintChanged" },
        onVehicleDeleted = { handler = "onVehicleDeleted" },
    }) do
        _G[data.handler] = function(...)
            if data.withReturn then
                return extensions.hookWithReturn(data.handler, ...)
            else
                extensions.hook(data.handler, ...)
            end
        end
        MP.RegisterEvent(hook, data.handler)
        if data.timer then
            MP.CreateEventTimer(hook, data.timer)
        end
    end
end

function _G.onInit() ---@diagnostic disable-line
    LogInfo(string.format("Loading BeamJoyServer (v%s, build %d)", M.VERSION, M.BUILD))
    drawArt()
    if not CheckServerVersion(3, 9) then
        LogError("BeamJoySandbox requires BeamMP Server v3.9.0+")
        return
    end
    if not checkWritePermissions() then
        LogError("BeamJoy requires write permissions, please fix before restarting the server")
        return
    end
    loadExtensions()
    loadHooks()
    LogInfo(string.format("BeamJoyServer loaded (v%s, build %d)", M.VERSION, M.BUILD))
end

BeamJoyServer = M
