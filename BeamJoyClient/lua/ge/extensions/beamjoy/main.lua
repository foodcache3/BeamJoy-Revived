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
along with this program.  If not, see <https://www.gnu.org/licenses/>.

Contact : https://github.com/my-name-is-samael
]]

local M = {
    BUILD = -1,
    VERSION = "INVALID",
    DEBUG = true,
    dependencies = { "loadDefaults", "mpRestrictions",
        -- game utils
        "async", "toast", "sound", "shape", "localStorage", "camera", "uiHelpers",
        "vehicleSelector", "replay", "gizmo", "bigmap", "mods", "icons", "navigation",
        -- beamjoy services
        "beamjoy_lang", "beamjoy_communications", "beamjoy_cache", "beamjoy_context", "beamjoy_clockSync",
        "beamjoy_vehicles", "beamjoy_imgui_manager", "beamjoy_chat", "beamjoy_inputs",
        "beamjoy_restrictions", "beamjoy_config", "beamjoy_permissions", "beamjoy_groups",
        "beamjoy_players", "beamjoy_nametags", "beamjoy_contextMenu", "beamjoy_traffic",
        "beamjoy_activity_manager", "beamjoy_ui_activityEditor", "beamjoy_environment",
        "beamjoy_recoveryPolicy", "beamjoy_uiNav",
        "beamjoy_broadcast", "beamjoy_maps", "beamjoy_mapVote", "beamjoy_kickVote", "beamjoy_automaticLights", "beamjoy_particles", "beamjoy_markerSettings", "beamjoy_pursuit",
        "beamjoy_vehiclePresets", "beamjoy_races", "beamjoy_raceRunner", "beamjoy_raceMarkers",
        "beamjoy_hunter", "beamjoy_hunterRunner", "beamjoy_hunterMarkers",
        "beamjoy_infected", "beamjoy_infectedRunner",
        "beamjoy_derby", "beamjoy_derbyRunner",
        "beamjoy_freeroamData", "beamjoy_stations",
        "beamjoy_busLines", "beamjoy_busRun",
        "beamjoy_deliveryPoints", "beamjoy_delivery", "beamjoy_deliveryPool",
        "beamjoy_crews", "beamjoy_notices", "beamjoy_mainNav", "beamjoy_vehicleInteractions" },

    world_ready = false,
    client_ready = false,
    client_connected = false,
}

local function loadVersion()
    local file = io.open("/lua/ge/extensions/beamjoy/buildversion", "r")
    if file then
        M.BUILD = file:read("*a")
        file:close()
    end

    file = io.open("/lua/ge/extensions/beamjoy/version", "r")
    if file then
        M.VERSION = file:read("*a"):gsub("\n", ""):gsub(" ", "")
        file:close()
    end
end

M.onInit = function()
    loadVersion()
    setExtensionUnloadMode(M, "manual")
    LogInfo(string.format("BeamJoyClient loaded (v%s, build %d)", M.VERSION, M.BUILD))
end

M.onWorldReadyState = function(state)
    M.world_ready = state == 2
    if M.world_ready then
        async.task(function()
            return (tonumber(getConsoleVariable("fps::avg")) or 0) > 5
        end, function()
            M.client_ready = true
            extensions.hook("onBJClientReady")
        end)
    end
end

local lastSlowUpdate = 0
M.onPreRender = function(dtReal, dtSim, dtRaw)
    if M.world_ready and MPGameNetwork.launcherConnected() then
        local ctxt = beamjoy_context.get()
        if ctxt.now - lastSlowUpdate >= 250 then
            lastSlowUpdate = ctxt.now
            extensions.hook("onSlowUpdate", ctxt)
        end
    end
end

M.onServerLeave = function()
    -- belt-and-suspenders : `beamjoy_communications_ui` has its own `onServerLeave` that sends
    -- this same message, but that only works if the engine actually calls `onServerLeave`
    -- separately on every dependency extension (unconfirmed to always happen reliably. The HUD
    -- was seen still on-screen after returning to the main menu, i.e. the "beamjoy" DOM root was
    -- never removed). This one is guaranteed to run, since it's what's firing right now.
    if beamjoy_communications_ui then
        beamjoy_communications_ui.send("BJUnload")
    end
    extensions.unload("beamjoy_main")
end

-- Real bug: current BeamMP's leaveServer (MPCoreNetwork.lua) fires `onBeamMPServerLeave`, and
-- nothing fires `onServerLeave` any more, so none of BeamJoy's leave handlers ran. Disconnecting
-- hid it (BeamMP then reloads all of Lua, BeamJoy with it), but "Exit level" from the pause menu
-- (onClientEndMission -> leaveServer(false)) doesn't reload : BeamJoy stayed loaded at the main
-- menu, its UI still on screen and the game functions it replaces still replaced. Relayed here to
-- every handler ; on a BeamMP that still fires onServerLeave, whichever comes second finds BeamJoy
-- already unloaded (M.onServerLeave above unloads it)
M.onBeamMPServerLeave = function()
    extensions.hook("onServerLeave")
end

return M
