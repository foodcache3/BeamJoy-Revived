local M = {
    baseFunctions = {},
    baseMPFunctions = {},

    serverMods = {}, ---@type string[]
    state = true,
    process = false,
}

-- shared delayTask key: onBJVehicleModChanged forces a full re-parse of every installed vehicle
-- mod's jbeam files (expensive, and noisy in the log for any broken mod). Several vehicle mods can
-- activate/deactivate within the same moment (e.g. each player in a race bringing in their own
-- custom vehicle) ; using the same key for all of them collapses that burst into a single re-scan
-- instead of one full re-scan per mod.
local VEHICLE_MOD_CHANGED_KEY = "onBJVehicleModChanged"

local function initServerMods()
    M.serverMods = table.filter(MPModManager.getModList(), function(v, k)
        return v.active and tostring(k):find("^multiplayer") ~= nil
    end):keys()
end

---@param modName string?
---@return boolean
local function isServerMod(modName)
    return modName ~= nil and (MPModManager.isModAllowed(modName) or
        MPModManager.isModWhitelisted(modName))
end

---@param callback fun()
local function freeCamRevertWrapper(callback)
    local previousCam = {}
    if camera.getCamera() == camera.CAMERAS.FREE then
        local pos, dir = camera.getPositionRotation()
        previousCam = { pos = pos, dir = dir }
    end
    callback()
    if previousCam.pos then
        camera.setPositionRotation(previousCam.pos, previousCam.dir)
    end
end

--- Remove mods list (or delete), refresh vehicles cache if needed,
--- and then remove invalid owned vehicles
---@param modsToRemove string[]
---@param delete? boolean
local function disableMods(modsToRemove, delete)
    M.process = true
    local changedVehicles = false
    local mods = extensions.core_modmanager.getMods()
    freeCamRevertWrapper(function()
        table.filter(modsToRemove, function(name)
            if #modsToRemove == 1 and mods[name] and isServerMod(name) then
                -- player tries to remove a server mod
                uiHelpers.toastError(beamjoy_lang.translate("beamjoy.toast.mods.cannotDisableMandatory"))
            end
            return mods[name] and not isServerMod(name)
        end):forEach(function(name)
            local mod = mods[name]
            local fn
            if delete then
                fn = M.baseFunctions.core_modmanager.deleteMod
            elseif mod.active then
                fn = extensions.core_modmanager.deactivateMod
            end
            if fn then
                local ok, err = pcall(fn, name)
                if not ok then
                    -- if mod is a vehicle and already spawned, throws this error => continues process
                    LogError(string.format("Error while %s mod '%s': %s",
                        delete and "deleting" or "deactivating", name, err))
                    extensions.hook('onModDeactivated', mod)
                    extensions.core_modmanager.requestState()
                elseif mod.modType == "vehicle" then
                    changedVehicles = true
                end
            end
        end)
        if changedVehicles then
            async.delayTask(function()
                extensions.hook("onBJVehicleModChanged")
            end, 200, VEHICLE_MOD_CHANGED_KEY)
        end
    end)
    M.process = false
    uiHelpers.applyLoading(false)
end

local function initHooks()
    M.baseFunctions = {
        core_modmanager = {
            activateModId = extensions.core_modmanager.activateModId,
            deactivateModId = extensions.core_modmanager.deactivateModId,
            activateAllMods = extensions.core_modmanager.activateAllMods,
            deactivateAllMods = extensions.core_modmanager.deactivateAllMods,
            deleteAllMods = extensions.core_modmanager.deleteAllMods,
            checkUpdate = extensions.core_modmanager.checkUpdate,
            deleteMod = extensions.core_modmanager.deleteMod,
        },
        core_repository = {
            updateOneMod = extensions.core_repository.updateOneMod,
            requestMods = extensions.core_repository.requestMods,
        },
    }
    M.baseMPFunctions = {
        MPModManager = {
            onModActivated = MPModManager.onModActivated,
            onModDeactivated = MPModManager.onModDeactivated,
        }
    }
    local stopProcess = function()
        async.delayTask(function()
            uiHelpers.toastError(beamjoy_lang.translate("beamjoy.toast.mods.managingNotAllowed"))
            uiHelpers.applyLoading(false)
        end, 100)
    end

    -- MANAGER

    extensions.core_modmanager.activateModId = function(...)
        if not M.state then return stopProcess() end
        -- vanilla call does not enable vehicles :'(
        local args, res = { ... }, nil
        freeCamRevertWrapper(function()
            res = M.baseFunctions.core_modmanager.activateModId(table.unpack(args))
        end)
        return res
    end
    extensions.core_modmanager.activateAllMods = function(...)
        if not M.state then return stopProcess() end
        M.process = true
        local args, res = { ... }, nil
        freeCamRevertWrapper(function()
            res = M.baseFunctions.core_modmanager.activateAllMods(table.unpack(args))
        end)
        M.process = false
        local changedVehicles = false
        local mods = extensions.core_modmanager.getMods()
        for name, mod in pairs(mods) do
            if not isServerMod(name) and
                mod.modType == "vehicle" then
                changedVehicles = true
            end
        end
        if changedVehicles then
            extensions.hook("onBJVehicleModChanged")
        end

        return res
    end
    extensions.core_modmanager.deactivateModId = function(mod_id, ...)
        if not M.state then return stopProcess() end
        local name = extensions.core_modmanager.getModNameFromID(mod_id)
        disableMods({ name })
    end
    extensions.core_modmanager.deactivateAllMods = function(...)
        if not M.state then return stopProcess() end
        disableMods(table.keys(extensions.core_modmanager.getMods()))
    end
    extensions.core_modmanager.deleteAllMods = function(...)
        if not M.state then return stopProcess() end
        disableMods(table.keys(extensions.core_modmanager.getMods()), true)
    end
    extensions.core_modmanager.checkUpdate = function(...)
        if not M.state then return stopProcess() end
        return M.baseFunctions.core_modmanager.checkUpdate(...)
    end
    extensions.core_modmanager.deleteMod = function(modName)
        -- Deliberately NOT gated on M.state like its siblings above : this function isn't purely
        -- player-initiated the way activateModId/deactivateModId are. BeamMP's own native
        -- cleanUpSessionMods() (disconnect cleanup) calls back into this same overridden function
        -- to actually remove each session mod ; gating it on M.state (1.8.7, reverted here) blocked
        -- every one of those calls too once AllowClientMods was permanently forced off (1.8.8),
        -- silently breaking real disconnect cleanup instead of just blocking a player's own manual
        -- mod-manager action.
        if isServerMod(modName) then
            uiHelpers.applyLoading(false)
            uiHelpers.toastError(beamjoy_lang.translate("beamjoy.toast.mods.cannotDisableMandatory"))
            return error() -- stop deletion process
        end
        disableMods({ modName }, true)
    end

    -- REPOSITORY

    extensions.core_repository.requestMods = function(...)
        if not M.state then return stopProcess() end
        return M.baseFunctions.core_repository.requestMods(...)
    end
    extensions.core_repository.updateOneMod = function(...)
        if not M.state then return stopProcess() end
        return M.baseFunctions.core_repository.updateOneMod(...)
    end

    -- MP

    MPModManager.onModActivated = nil
    MPModManager.onModDeactivated = nil
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)

    beamjoy_communications_ui.addHandler("BJReady", initServerMods)

    initHooks()
end

local function onUnload()
    RollBackNGFunctionsWrappers(M.baseFunctions)
    MPModManager.onModActivated = M.baseMPFunctions.MPModManager.onModActivated
    MPModManager.onModDeactivated = M.baseMPFunctions.MPModManager.onModDeactivated
end

local function onModActivated(mod)
    if not M.state then
        if not isServerMod(mod.modname) then
            -- enforce only server mods, no matter what
            extensions.core_modmanager.deactivateMod(mod.modname)
        end
        return
    end
    if mod.modType == "vehicle" then
        async.delayTask(function()
            extensions.hook("onBJVehicleModChanged")
        end, 200, VEHICLE_MOD_CHANGED_KEY)
    end
end

local function onModDeactivated(mod)
    if isServerMod(mod.modname) then
        -- enforce server mods, no matter what
        return extensions.core_modmanager.activateMod(mod.modname)
    end
    if not M.state then return end
    if mod.modType == "vehicle" then
        async.delayTask(function()
            extensions.hook("onBJVehicleModChanged")
        end, 200, VEHICLE_MOD_CHANGED_KEY)
    end
end

local function updateState()
    local newState = beamjoy_config.data.AllowClientMods == true
    if newState ~= M.state then
        uiHelpers.applyLoading(true, function()
            ---@param job NGJob
            extensions.core_jobsystem.create(function(job)
                freeCamRevertWrapper(function()
                    if not newState then
                        disableMods(table.keys(extensions.core_modmanager.getMods()))
                    end
                    job.sleep(.2)
                end)
                M.state = newState
                job.sleep(.1)
                uiHelpers.applyLoading(false)
            end)
        end)
    end
end

---@param caches table
local function retrieveCache(caches)
    if caches.config then
        async.delayTask(updateState, 0)
    end
end

M.onInit = onInit
M.onServerLeave = onUnload
M.onModActivated = onModActivated
M.onModDeactivated = onModDeactivated

M.retrieveCache = retrieveCache

return M
