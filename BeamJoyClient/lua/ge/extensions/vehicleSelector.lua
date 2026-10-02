local M = {
    dependencies = { "uiHelpers", "beamjoy_vehicles" },

    baseFunctions = {},

    caches = {
        ---@type table?
        vueAllModelsGroups = nil,
    },
}

--- The group's vehicle cap (services/vehicles.lua enforces it too, but a refused spawn there has
--- the game drop the player into the nearest vehicle). `adds` : the pick would be one vehicle more
--- (a new spawn or clone, or replacing the unicycle / nothing). Says so and returns true when full.
---@param adds boolean
---@return boolean
local function capReached(adds)
    if not adds then return false end
    local self = beamjoy_players and beamjoy_players.getSelf()
    if not self then return false end
    local group = beamjoy_groups and Table(beamjoy_groups.data):find(function(g) return g.name == self.group end)
    local cap = group and tonumber(group.vehicleCap)
    if not cap or cap < 0 then return false end
    local count = 0
    for _, v in pairs(self.vehicles or {}) do
        if type(v) == "table" and not v.isAi then count = count + 1 end
    end
    if count < cap then return false end
    toast.error(beamjoy_lang.translate("beamjoy.toast.vehicleSelector.capReached"):gsub("{cap}", tostring(cap)), nil, 6)
    return true
end

--- replacing adds a vehicle when there's nothing real to replace (walking, or no vehicle)
---@return boolean
local function replaceAdds()
    local own = beamjoy_vehicles.getCurrentOwn()
    return not own or own.jbeam == beamjoy_vehicles.WALKING
end

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
    if req.state and not capReached(true) then
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
    if req.state and not capReached(true) then
        return M.baseFunctions.core_vehicles.spawnNewVehicle(model, opt)
    end
end

--- Picking a car while walking. A replace re-spawns the unicycle's own object as the car, which
--- BeamMP sends as an edit of the unicycle, and BeamMP-Server destroys any edit that turns a
--- player's unicycle into something else (TServer.cpp, the 'Oc' case: the car vanished and the game
--- put the player in the nearest vehicle, whatever BeamJoy's own onVehicleEdited answered). So the
--- car is spawned new where the walker stands, and the game's own get-in flow retires the unicycle:
--- entering the car has gameplay_walk deactivate it, which BeamMP deletes and syncs
--- (beammp/multiplayer.lua's onVehicleActiveChanged).
---@param unicycle userdata the player's own unicycle
local function spawnInsteadOfUnicycle(model, opt, unicycle)
    local uniId = unicycle:getID()
    opt = type(opt) == "table" and table.clone(opt) or {}
    opt.pos = vec3(unicycle:getPosition())
    local camDir = core_camera.getQuat() * vec3(0, 1, 0)
    camDir.z = 0
    if camDir:length() > 1e-4 then opt.rot = quatFromDir(camDir:normalized()) end
    opt.visibilityPoint = nil
    local veh, vehs = M.baseFunctions.core_vehicles.spawnNewVehicle(model, opt)
    -- a unicycle gameplay_walk doesn't track (one picked in the selector rather than walked out
    -- on) isn't deactivated by the switch : removed here. A tracked one is left to BeamMP, whose
    -- own deletion doesn't check the object still exists
    if veh and gameplay_walk and gameplay_walk.onSerialize().unicycleId ~= uniId then
        local leftover = getObjectByID(uniId)
        if leftover then leftover:delete() end
    end
    return veh, vehs
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
    if req.state and not capReached(replaceAdds()) then
        local own = beamjoy_vehicles.getCurrentOwn()
        if not otherVeh and own and own.jbeam == beamjoy_vehicles.WALKING and own.veh then
            return spawnInsteadOfUnicycle(model, opt, own.veh)
        end
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
