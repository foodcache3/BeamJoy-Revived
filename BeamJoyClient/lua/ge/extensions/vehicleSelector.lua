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

--- FIRST theory here (now confirmed wrong, kept for the record): pre-warming
--- `ui_vehicleSelector_general.getUiData()` on the assumption its own `initializeVehicleData()`
--- was the expensive first-open build being raced. It genuinely is expensive-once, but it's BJS/
--- native's own UI-side filter/grouping wrapper, layered ON TOP of a separate, lower-level cache -
--- not what the route mount itself waits on. Kept below (harmless, still worth warming) but
--- confirmed NOT the fix : the glitch reproduced again after this shipped.
local function prewarmVehicleSelectorData()
    if extensions.ui_vehicleSelector_general and extensions.ui_vehicleSelector_general.getUiData then
        pcall(extensions.ui_vehicleSelector_general.getUiData)
    end
end

--- Narrows one real (but, per a later stack-trace capture, not the only) window this glitch can
--- exploit - found by reading the actual mount path (util/asyncBulkLoader.lua +
--- ui/vehicleSelector/general.lua) after two live BeamNG.log repros kept showing the router
--- mounting "menu.vehiclesnew" a SECOND time ~1.6-2.7s after the first mount had already
--- completed cleanly (no error either time, in the second capture). The ACTUAL definitive root
--- cause was found afterward by wrapping ui_router.navigate to log a stack trace on every call
--- (now removed - see git history / TODO.md for the full writeup): that second navigate comes
--- from BeamNG's own CEF/Vue vehicle-selector UI itself (an engineLua callback, no Lua-side
--- caller at all - traceback shows only "main chunk of line"), fired by the PLAYER clicking into
--- a grid item's own sub-path (a brand/model folder, or a bus's config list) - confirmed from the
--- unminified Vue source (VehicleSelector.vue's onGridNavigateRequest). Since "menu.vehiclesnew"
--- has no child route to drill into (unlike the pause selector), that click re-navigates the SAME
--- root route with an updated path param instead, and it occasionally loses its own race against
--- the router's 1-second "routerStart" phase timeout (`route_navigation_not_started`) - a native
--- engine bug BJS has no lever to prevent.
--- Kept below anyway since a warm catalog genuinely does remove ONE way this can be hit :
---
--- Every vehicle-selector root route mount (`M.onRootRouteMount`) calls
--- `beginAsyncPauseRouteMount()`, which calls `util_asyncBulkLoader.loadVehicles()`. That returns
--- `"alreadyLoaded"` (fast, synchronous, emits the grid snapshot next tick - no race) UNLESS
--- `core_vehicles.isModelsDataLoaded()` is still false, which is true only for the session's very
--- first open. In that cold case it instead kicks off an async `core_jobsystem` job and returns
--- immediately with nothing mounted yet ; the job's own completion handler
--- (`asyncVehicleLoadComplete` -> `emitPauseRouteSnapshot`) explicitly, silently DISCARDS the
--- whole grid snapshot if the router's current route no longer matches the route that was pending
--- when the job started (`isPendingPauseRouteStillCurrent`). A second mount of the same route
--- landing inside that window - exactly what both logs show - is a real way to hit that mismatch:
--- the completion callback fires, checks the (by-then-stale) pending entry against whatever the
--- router considers current, and drops the payload with no error, leaving the grid permanently
--- empty. A second attempt always takes the instant "alreadyLoaded" path since the catalog is
--- warm by then, matching the user's own "second time works fine" report exactly.
---
--- Fix: force `loadVehicles()` this early - well before the player can possibly reach a bus stop
--- - so `core_vehicles.isModelsDataLoaded()` is already true by the time ANY filtered-selector
--- open happens, collapsing every open (first included) onto the same safe, synchronous path a
--- working retry already takes. busRun.lua's own M.startLine has a defensive fallback in case this
--- prewarm hasn't finished yet for some reason (fast reconnect, hot reload).
local function prewarmVehicleModelList()
    if extensions.util_asyncBulkLoader and extensions.util_asyncBulkLoader.loadVehicles then
        pcall(extensions.util_asyncBulkLoader.loadVehicles)
    end
end

local function prewarm()
    prewarmVehicleSelectorData()
    prewarmVehicleModelList()
end

local function onUnload()
    RollBackNGFunctionsWrappers(M.baseFunctions)
end

M.onInit = onInit
M.onExtensionUnloaded = onUnload
M.onBJClientReady = prewarm
M.onBJVehiclesCacheUpdate = resetCache
M.onBJPermissionsUpdate = resetCache
M.onBJUpdateSelf = resetCache
M.onVehicleSelectorRemoveOthers = onVehicleSelectorRemoveOthers

return M
