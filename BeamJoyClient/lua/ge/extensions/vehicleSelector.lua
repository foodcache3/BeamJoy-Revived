local M = {
    dependencies = { "uiHelpers", "beamjoy_vehicles" },

    baseFunctions = {},

    caches = {
        ---@type table?
        vueAllModelsGroups = nil,
    },
}

local function cloneCurrent()
    local veh = be:getPlayerVehicle(0)
    if not veh then return end
    local fullConfig = beamjoy_vehicles.getFullConfig(veh)
    if not fullConfig then return end
    local config = fullConfig.key or nil
    local req = CreateRequestAuthorization(true)
    -- "clone": confirmed via the installed game's own source (ui/vehicleSelector/
    -- vehicleOperations.lua, core/vehicles.lua's own cloneCurrent) that this is genuinely additive,
    -- exactly like "spawn" below. It calls spawnNewVehicle internally and never deletes the
    -- original, always leaving the player with two vehicles at once.
    extensions.hook("onBJRequestCanSpawnVehicle", req, veh.jbeam, config, "clone")
    if req.state then
        return M.baseFunctions.core_vehicles.cloneCurrent()
    end
end

local function spawnNewVehicle(model, opt)
    -- The walking-mode "vehicle" (the unicycle) bypasses our own permission hook entirely rather
    -- than being gated like a real vehicle spawn. BeamMP's own multiplayer layer wraps
    -- gameplay_walk's toggleWalkingMode AND core_vehicles.spawnNewVehicle itself (confirmed from a
    -- real captured crash trace elsewhere in this investigation, see onVehicleSwitched's own
    -- comment), so this specific call is already deeply nested inside BeamMP's own wrapper chain
    -- when it reaches us, not a normal player-initiated spawn. Adding our own extra hook/async step
    -- in the middle of that chain was the one remaining untested theory for the reported "unicycle
    -- spawns fine, then gets silently destroyed ~1s later, removed by local player" symptom. The
    -- server already independently enforces whether walking is allowed at all
    -- (services_config.data.AllowWalking, checked in onVehicleSpawn), so there's no meaningful
    -- client-side policy this hook needs to apply here anyway. Skipping it makes BJS's presence in
    -- this one specific call path as close to a no-op as possible, matching the one config (BJS
    -- entirely absent) that's been confirmed to work.
    if model == beamjoy_vehicles.WALKING then
        return M.baseFunctions.core_vehicles.spawnNewVehicle(model, opt)
    end
    local config
    if type(opt) == "table" then
        if type(opt.config) == "string" then
            if opt.config:endswith(".pc") then
                config = string.match(opt.config, "([^./]*).pc")
            else
                config = opt.config
            end
        end
    end
    local req = CreateRequestAuthorization(true)
    -- "spawn": confirmed via the installed game's own source (ui/vehicleSelector/
    -- vehicleOperations.lua's separate "Spawn New" tile action, `spawnOnly` mode) that this is the
    -- genuinely ADDITIVE path. It never deletes any existing vehicle, unlike replaceVehicle below,
    -- which is what a normal tile pick/double-click actually goes through.
    extensions.hook("onBJRequestCanSpawnVehicle", req, model, config, "spawn")
    if req.state then
        return M.baseFunctions.core_vehicles.spawnNewVehicle(model, opt)
    end
end

local function replaceVehicle(model, opt, otherVeh)
    if model == beamjoy_vehicles.WALKING then
        return M.baseFunctions.core_vehicles.replaceVehicle(model, opt, otherVeh)
    end
    local config
    if type(opt) == "table" then
        if type(opt.config) == "string" then
            if opt.config:endswith(".pc") then
                config = string.match(opt.config, "([^./]*).pc")
            else
                config = opt.config
            end
        end
    end
    local req = CreateRequestAuthorization(true)
    -- "replace": confirmed via the installed game's own source that this is what a normal tile
    -- pick/double-click in the selector (and the keybind/console default-vehicle spawn) actually
    -- calls when a vehicle already exists. It deletes the old one itself, so this is never a
    -- "second simultaneous vehicle" concern the way "spawn"/"clone" are.
    extensions.hook("onBJRequestCanSpawnVehicle", req, model, config, "replace")
    if req.state then
        return M.baseFunctions.core_vehicles.replaceVehicle(model, opt, otherVeh)
    end
end

local function removeCurrent(...)
    local current = beamjoy_vehicles.getCurrent()
    if current then
        if current.isLocal then
            beamjoy_vehicles:deleteCurrentOwnVehicle()
        else
            uiHelpers.popup(beamjoy_lang.translate("beamjoy.toast.vehicleSelector.removeOtherVeh"), {
                uiHelpers.popupButton(beamjoy_lang.translate("beamjoy.common.cancel")),
                uiHelpers.popupButton(beamjoy_lang.translate("beamjoy.common.confirm"),
                    beamjoy_vehicles.deleteCurrentOthersVehicle),
            })
        end
    end
end

-- Called when "Remove Others" button is clicked<br/>
-- We do not override core_vehicles here because BeamMP is doing it already
local function onVehicleSelectorRemoveOthers()
    beamjoy_vehicles.deleteOtherOwnVehicles()
end

---@param itemData {model:string, config: string}
---@return boolean
local function passesFilters(itemData)
    -- Real, confirmed bug ("vehicle selector search/type filters don't work at all"): this used to
    -- REPLACE the native passesFilters outright instead of wrapping it, so the native filter
    -- module's own search text / type / range filters (ge/extensions/ui/gridSelectorUtils/
    -- filterModule.lua, which this whole function's real logic lives in) were never consulted at
    -- all. Every item "passed" purely based on spawn authorization, regardless of what was typed
    -- or toggled in the selector UI. Both now have to agree: the native filter has to actually
    -- match, and spawning it has to be authorized.
    if not M.baseFunctions.ui_vehicleSelector_general.passesFilters(itemData) then
        return false
    end
    local req = CreateRequestAuthorization(true)
    -- "replace": a shown, pickable tile's actual eventual action (double-click/confirm) is
    -- replaceVehicle, not spawnNewVehicle. Passing anything else here would make every tile fail
    -- a "you already have a vehicle" check the instant one exists, hiding the entire grid for the
    -- overwhelmingly common case of opening the selector to swap cars.
    extensions.hook("onBJRequestCanSpawnVehicle", req, itemData.model, itemData.config, "replace")
    return req.state
end

local function onInit()
    M.baseFunctions = {
        core_vehicles = {
            cloneCurrent = extensions.core_vehicles.cloneCurrent,
            spawnNewVehicle = extensions.core_vehicles.spawnNewVehicle,
            replaceVehicle = extensions.core_vehicles.replaceVehicle,
            removeCurrent = extensions.core_vehicles.removeCurrent,
        },
        ui_vehicleSelector_general = {
            passesFilters = extensions.ui_vehicleSelector_general.passesFilters,
        },
    }
    core_vehicles.cloneCurrent = cloneCurrent
    core_vehicles.spawnNewVehicle = spawnNewVehicle
    core_vehicles.replaceVehicle = replaceVehicle
    core_vehicles.removeCurrent = removeCurrent
    extensions.ui_vehicleSelector_general.passesFilters = passesFilters
end

local function resetCache()
    M.caches = {}
end

local function onUnload()
    RollBackNGFunctionsWrappers(M.baseFunctions)
end

M.onInit = onInit
M.onExtensionUnloaded = onUnload
M.onBJVehiclesCacheUpdate = resetCache
M.onBJPermissionsUpdate = resetCache
M.onBJUpdateSelf = resetCache
M.onVehicleSelectorRemoveOthers = onVehicleSelectorRemoveOthers

return M
