local M = {
    RESET = {
        RECOVER = "recover_vehicle",
        RECOVER_ALT = "recover_vehicle_alt",
        RECOVER_LAST_ROAD = "recover_to_last_road",
        SAVE_HOME = "saveHome",
        LOAD_HOME = "loadHome",
        DROP_AT_CAMERA = "dropPlayerAtCamera",
        DROP_AT_CAMERA_NO_RESET = "dropPlayerAtCameraNoReset",
        RESET_PHYSICS = "reset_physics",
        RESET_ALL_PHYSICS = "reset_all_physics",
        RELOAD = "reload_vehicle",
        RELOAD_ALL = "reload_all_vehicles",
        -- Not a real BeamNG input action id (no keybind/actionFilter entry exists for it at all):
        -- the ESC-menu pause UI's own "Repair" tile (ui/pause/providers/vehicleTabInteractions.lua's
        -- tryRepairVehicleHere) calls spawn.safeTeleport(vehicle, itsOwnCurrentPos, itsOwnCurrentRot,
        -- nil, nil, nil, nil, true) directly - a dead giveaway "reset in place via teleport" call,
        -- confirmed by reading safeTeleport's own body (resetVehicle=true does veh:setPosRot(...)
        -- then veh:resetBrokenFlexMesh(), exactly recover_vehicle's own effect) - with ZERO gating
        -- of its own: not through resetGameplay, not through the action filter (there's no key
        -- press here at all), and the tile's own "disabled" flag (see canModifyVehicles) is purely
        -- cosmetic - the click callback never re-checks it. See overrideSafeTeleport's own doc
        -- comment for how this is actually caught.
        REPAIR = "repairVehicleHere",
    },

    baseFunctions = {},
    init = false,

    isNodegrabberRenderActive = false,
}

local function onExtensionLoaded()
    extensions.core_input_categories.beamjoy = {
        order = -100,
        icon = "tag_faces",
        title = "ui.options.controls.bindings.beamjoy",
    }
end

---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions) end

---@class onBJClickData
---@field pos vec3?
---@field distance number?
---@field mpVeh BJVehicle?
---@field static any?

local rightMouseHoldStart
local function onUpdate()
    -- nodegrabber state detection process
    local nodegrabberUpdate = Table(ActionMap.getInputCommands())
        :find(function(ac)
            return ac[1] == "nodegrabberRender"
        end)
    if nodegrabberUpdate then
        M.isNodegrabberRenderActive = nodegrabberUpdate[4] == 1
    end

    local type
    if ui_imgui.IsMouseClicked(ui_imgui.MouseButton_Left) then
        type = "left"
    elseif ui_imgui.IsMouseClicked(ui_imgui.MouseButton_Middle) then
        type = "middle"
    elseif ui_imgui.IsMouseClicked(ui_imgui.MouseButton_Right) then
        rightMouseHoldStart = GetCurrentTimeMillis()
    elseif rightMouseHoldStart and ui_imgui.IsMouseReleased(ui_imgui.MouseButton_Right) then
        -- after released to avoid the game engine centering the mouse
        local delay = GetCurrentTimeMillis() - rightMouseHoldStart
        if delay < 200 then
            type = "right"
        end
        rightMouseHoldStart = nil
    end
    local isClickWithinGame = false
    if not M.isNodegrabberRenderActive and type then
        local mousePos = ui_imgui.GetMousePos()
        local viewport = ui_imgui.GetWindowViewport()
        mousePos = ImVec2(mousePos.x - viewport.Pos.x,
            mousePos.y - viewport.Pos.y)
        isClickWithinGame = mousePos.x > 0 and
            mousePos.x < viewport.Size.x and
            mousePos.y > 0 and
            mousePos.y < viewport.Size.y
    end
    if isClickWithinGame then
        local currentCamera = camera.getCamera()
        local currentVeh = be:getPlayerVehicle(0)

        local ray
        local throughSelf = currentVeh and currentCamera ~= camera.CAMERAS.FREE
        if throughSelf then currentVeh:disableCollision() end
        ray = cameraMouseRayCast(true, ui_imgui.flags(SOTStaticObject, SOTVehicle), 200)
        if throughSelf then currentVeh:enableCollision() end

        ---@type BJVehicle?, any?
        local veh, static
        if ray and ray.object then
            if ray.object:getClassName() == "BeamNGVehicle" then
                veh = beamjoy_vehicles.vehicles[ray.object:getID()]
            else
                static = ray.object
            end
        end
        -- Real, confirmed bug: this used to bail out entirely (`if not ray then return end`)
        -- whenever the raycast found nothing within range, e.g. the cursor pointing at open sky.
        -- That silently starved every onBJClick consumer of the click, not just handed it a nil
        -- pos: a consumer whose targeting genuinely needs a real hit (contextMenu.lua's vehicle
        -- targeting) already guards on `data.mpVeh` being present and is unaffected either way,
        -- but one whose own hit-test reconstructs the camera ray itself against authored
        -- world-space geometry rather than trusting whatever the raycast actually found
        -- (raceEditor.lua/pointListEditor.lua's world-click selection, via camera.mouseRay())
        -- never even got called in that case, which is exactly what made a gate/point
        -- unselectable while looking steeply up at it.
        extensions.hook("onBJClick", type, {
            pos = ray and ray.pos or nil,
            distance = ray and ray.distance or nil,
            mpVeh = veh,
            static = static
        })
    end
end

local function overrideResetInputs()
    M.baseFunctions = {
        resetGameplay = resetGameplay,
        extensions = {
            core_vehicle_manager = {
                reloadVehicle = extensions.core_vehicle_manager.reloadVehicle,
                reloadAllVehicles = extensions.core_vehicle_manager.reloadAllVehicles,
            },
            commands = {
                dropPlayerAtCamera = extensions.commands.dropPlayerAtCamera,
                dropPlayerAtCameraNoReset = extensions.commands.dropPlayerAtCameraNoReset,
            },
            spawn = {
                teleportToLastRoad = extensions.spawn.teleportToLastRoad,
                safeTeleport = extensions.spawn.safeTeleport,
            },
        },
    }

    ---@param resetType string
    local function override(resetType)
        local mpVeh = beamjoy_vehicles.getCurrent()
        if not mpVeh then return end
        if mpVeh.isLocal then
            M.onReset(resetType)
        else
            -- not owned vehicle
            M.onReset(M.RESET.RECOVER, true)
        end
    end

    extensions.core_vehicle_manager.reloadVehicle = function(localPlayerID)
        override(M.RESET.RELOAD)
    end
    extensions.core_vehicle_manager.reloadAllVehicles = function()
        M.onReset(M.RESET.RELOAD_ALL)
    end
    extensions.commands.dropPlayerAtCamera = function(localPID)
        override(M.RESET.DROP_AT_CAMERA)
    end
    extensions.commands.dropPlayerAtCameraNoReset = function(localPID)
        override(M.RESET.DROP_AT_CAMERA_NO_RESET)
    end
    extensions.spawn.teleportToLastRoad = function(veh, options)
        override(M.RESET.RECOVER_LAST_ROAD)
    end

    -- See M.RESET.REPAIR's own doc comment for the full "why" this exists at all: the ESC-menu
    -- Repair tile reaches this function directly, with no keybind/action-filter/resetGameplay
    -- involved anywhere in its call chain. Narrow fingerprint match only : any call that doesn't
    -- look EXACTLY like tryRepairVehicleHere's own "teleport my own current vehicle to its own
    -- current position/rotation with resetVehicle=true" signature passes straight through
    -- completely unmodified below, since safeTeleport is used constantly for entirely unrelated,
    -- legitimate purposes (native vehicle spawning, traffic, this mod's own
    -- beamjoy_vehicles.setVehiclePositionRotation) that must never be affected by this.
    extensions.spawn.safeTeleport = function(veh, pos, rot, checkOnlyStatics_, visibilityPoint_,
            removeTraffic_, centeredPosition, resetVehicle, player, unlimitedSafeSpawnRange)
        local looksLikeRepairCall = resetVehicle == true and checkOnlyStatics_ == nil and
            visibilityPoint_ == nil and removeTraffic_ == nil and centeredPosition == nil and
            player == nil and unlimitedSafeSpawnRange == nil
        local myVeh = looksLikeRepairCall and be and be:getPlayerVehicle(0) or nil
        local isOwnVehicle = myVeh and veh and veh:getID() == myVeh:getID()
        local isNearOwnCurrentPos = isOwnVehicle and pos and
            (pos - myVeh:getPosition()):length() < 3
        if isNearOwnCurrentPos then
            local mpVeh = beamjoy_vehicles.getCurrent()
            local req = CreateRequestAuthorization(true)
            extensions.hook("onBJRequestCurrentVehicleReset", req, M.RESET.REPAIR, mpVeh)
            -- denied : silently swallowed, same "key press, nothing happens" feel every other
            -- blocked reset type here already has - the real safeTeleport never runs at all
            if not req.state then return end
        end
        return M.baseFunctions.extensions.spawn.safeTeleport(veh, pos, rot, checkOnlyStatics_,
            visibilityPoint_, removeTraffic_, centeredPosition, resetVehicle, player, unlimitedSafeSpawnRange)
    end

    ---@diagnostic disable-next-line: lowercase-global
    resetGameplay = function(localPlayerID)
        if localPlayerID == -1 then
            M.onReset(M.RESET.RESET_ALL_PHYSICS)
        else
            override(M.RESET.RESET_PHYSICS)
        end
    end
end

-- override base resets
local function onBJClientReady()
    if M.init then return end
    async.task(function()
        return table.every({ "core_vehicle_manager", "commands", "spawn" },
            function(obj) return extensions[obj] ~= nil end)
    end, function()
        overrideResetInputs()
        M.init = true
    end)
end

local function onServerLeave()
    -- Do not rollback since setting any method in extensions.spawn breaks the game engine
    --RollBackNGFunctionsWrappers(M.baseFunctions.extensions)
    resetGameplay = M.baseFunctions.resetGameplay
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    if not M.init then
        async.task(function()
            return M.init
        end, function()
            onBJVehicleInstantiated(vid)
        end)
        return
    end

    ---@type BJVehicle
    local mpVeh = beamjoy_vehicles.vehicles[vid]
    if not mpVeh then return end

    -- backs up methods
    mpVeh.veh:queueLuaCommand([[
        recovery.reset = {
            startRecovering = recovery.startRecovering,
            stopRecovering = recovery.stopRecovering,
            saveHome = recovery.saveHome,
            loadHome = recovery.loadHome,
        }
    ]])
    if mpVeh.isLocal then
        mpVeh.veh:queueLuaCommand([[
                recovery.startRecovering = function(alt)
                    if alt then
                        obj:queueGameEngineLua('beamjoy_inputs.onReset("]] ..
            M.RESET.RECOVER_ALT .. [[")')
                    else
                        obj:queueGameEngineLua('beamjoy_inputs.onReset("]] ..
            M.RESET.RECOVER .. [[")')
                    end
                end
                recovery.stopRecovering = function()
                    obj:queueGameEngineLua('beamjoy_inputs.onStopRecovering()')
                end
                recovery.saveHome = function()
                    obj:queueGameEngineLua('beamjoy_inputs.onReset("]] .. M.RESET.SAVE_HOME .. [[")')
                end
                recovery.loadHome = function()
                    obj:queueGameEngineLua('beamjoy_inputs.onReset("]] .. M.RESET.LOAD_HOME .. [[")')
                end
            ]])
    else
        mpVeh.veh:queueLuaCommand([[
                recovery.startRecovering = function(alt)
                    if alt then
                        obj:queueGameEngineLua('beamjoy_inputs.onReset("]] ..
            M.RESET.RECOVER .. [[", true)')
                    else
                        obj:queueGameEngineLua('beamjoy_inputs.onReset("]] ..
            M.RESET.RECOVER .. [[", true)')
                    end
                end
                recovery.stopRecovering = function() end
                recovery.saveHome = function() end
                recovery.loadHome = function()
                    obj:queueGameEngineLua('beamjoy_inputs.onReset("]] ..
            M.RESET.RECOVER .. [[", true)')
                end
            ]])
    end
end

local rewindProcess = false
---@param resetType string beeamjoy_inputs.RESET entry
---@param release boolean? does input should be released right after pressed
local function onReset(resetType, release)
    if (resetType == M.RESET.RECOVER or resetType == M.RESET.RECOVER_ALT) and
        not release then
        rewindProcess = true
    end
    local mpVeh = beamjoy_vehicles.getCurrent()
    if not mpVeh and
        not table.includes({ M.RESET.RESET_ALL_PHYSICS, M.RESET.RELOAD_ALL }, resetType) then
        return
    end
    local req = CreateRequestAuthorization(true)
    extensions.hook("onBJRequestCurrentVehicleReset", req, resetType, mpVeh)
    if req.state then
        if resetType == M.RESET.RESET_ALL_PHYSICS then
            M.baseFunctions.resetGameplay(-1)
        elseif resetType == M.RESET.RELOAD_ALL then
            M.baseFunctions.extensions.core_vehicle_manager.reloadAllVehicles()
        elseif resetType == M.RESET.RECOVER and mpVeh then
            mpVeh.veh:queueLuaCommand("recovery.reset.startRecovering()")
        elseif resetType == M.RESET.RECOVER_ALT and mpVeh then
            mpVeh.veh:queueLuaCommand("recovery.reset.startRecovering(true)")
        elseif resetType == M.RESET.RECOVER_LAST_ROAD then
            M.baseFunctions.extensions.spawn.teleportToLastRoad()
        elseif resetType == M.RESET.SAVE_HOME and mpVeh then
            mpVeh.veh:queueLuaCommand("recovery.reset.saveHome()")
        elseif resetType == M.RESET.LOAD_HOME and mpVeh then
            mpVeh.veh:queueLuaCommand("recovery.reset.loadHome()")
        elseif resetType == M.RESET.DROP_AT_CAMERA then
            M.baseFunctions.extensions.commands.dropPlayerAtCamera(0)
        elseif resetType == M.RESET.DROP_AT_CAMERA_NO_RESET then
            M.baseFunctions.extensions.commands.dropPlayerAtCameraNoReset(0)
        elseif resetType == M.RESET.RESET_PHYSICS then
            M.baseFunctions.resetGameplay(0)
        elseif resetType == M.RESET.RELOAD then
            M.baseFunctions.extensions.core_vehicle_manager.reloadVehicle(0)
        end
    end
    if resetType == M.RESET.RECOVER and mpVeh and release then
        mpVeh.veh:queueLuaCommand("recovery.reset.stopRecovering()")
    end
end

local function onStopRecovering()
    local mpVeh = beamjoy_vehicles.getCurrent()
    if not mpVeh then return end
    if rewindProcess then
        async.delayTask(function()
            mpVeh.veh:queueLuaCommand("recovery.reset.stopRecovering()")
        end, 50)
    else
        mpVeh.veh:queueLuaCommand("recovery.reset.stopRecovering()")
    end
end

M.onExtensionLoaded = onExtensionLoaded
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onUpdate = onUpdate
M.onBJClientReady = onBJClientReady
M.onServerLeave = onServerLeave
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onReset = onReset
M.onStopRecovering = onStopRecovering

return M
