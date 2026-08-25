local M = {
    -- "gameplay_walk" used to be in this list too, removed : nothing in this file (or anywhere
    -- else in the BJS codebase, confirmed by search) ever actually calls it, and force-preloading
    -- it this early (as part of this extension's own dependency chain, well before a server
    -- connection even exists) is the likely cause of a real reported bug: the unicycle/walking
    -- character spawns (BeamMP registers it fine) but its mesh (BeamMP's own "beamling" content,
    -- vehicles/unicycle/beammp_default.pc) fails to load, ONLY when this mod is loaded ; the exact
    -- same server+map worked with BJS unloaded. BeamMP's own client mod most plausibly configures
    -- gameplay_walk for its custom walking character on ITS OWN first load (e.g. a one-time
    -- onExtensionLoaded-style hook). Preloading it here, ahead of BeamMP's own init, would mean
    -- that hook fires (or is registered) too late to ever see it, leaving gameplay_walk in a
    -- vanilla, unpatched state when the player actually tries to walk. No other preloaded
    -- dependency here is referenced by BeamMP's own multiplayer character system, so this is the
    -- one specifically worth removing rather than the whole preload mechanism.
    preloadedDependencies = { "core_vehicles", "core_vehicle_partmgmt", "core_vehicleBridge" },
    dependencies = {},

    TYPES = {
        CAR = "Car",
        TRUCK = "Truck",
        TRAILER = "Trailer",
        PROP = "Prop",
        TRAFFIC = "Traffic",
    },
    WALKING = "unicycle",

    ---@type tablelib<integer, BJVehicle> index vid
    vehicles = Table(),

    modelTypeCache = {},
}
AddPreloadedDependencies(M)

---@param model string
---@return boolean
local function isAi(model)
    return type(model) == "string" and model:lower():find("traffic") ~= nil
end

local function onInit()
    InitPreloadedDependencies(M)
    beamjoy_communications.addHandler("deleteVehicle", M.delete)
    beamjoy_communications.addHandler("explodeVehicle", M.explode)
    beamjoy_communications.addHandler("launchVehicle", M.launch)
    beamjoy_communications.addHandler("updateVehicleGhost", function(remoteVID, state)
        -- remoteVID is the SENDER's own vid, which is only meaningful as a lookup key in the
        -- sender's own local M.vehicles (each client assigns its own engine-local numeric vid per
        -- vehicle ; a vid reported by another client has no relation to this client's numbering
        -- for that same real vehicle). Matching on remoteVID instead: the cross-client-stable ID
        -- BeamMP itself assigns, mirrored into every client's own copy of that vehicle's record,
        -- is the same resolution pattern spectateAnotherRacer already uses for exactly this reason.
        -- Indexing M.vehicles[remoteVID] directly here (as if it were a local vid) was the actual
        -- root cause of "ghosted on my screen but not on theirs" : it almost always missed
        -- entirely (nil, mpVeh not found, remote copy never actually ghosted) or, worse, hit
        -- whatever unrelated vehicle happened to own that number locally.
        local mpVeh = M.vehicles:find(function(v) return v.remoteVID == remoteVID end)
        if mpVeh then
            M.setGhost(mpVeh.veh, state == true, true)
        end
    end)
end

--- `InitPreloadedDependencies` forces these natives into "manual" unload mode (so they survive
--- in-session map changes without this extension losing access to them), but nothing ever
--- reverted that. They stayed loaded forever, past leaving the server entirely, since
--- `setExtensionUnloadMode(ext, "manual")` only suppresses *automatic* unload, it doesn't stop an
--- explicit one. Symptom seen in-game : after returning to the main menu, the console floods with
--- `core/vehicle/manager.lua:360: attempt to index global 'spawn' (a nil value)` every frame:
--- `spawn` (not preloaded/kept alive by anything here) unloads normally on leaving the level, but
--- `core_vehicle_manager` apparently doesn't (most likely kept alive transitively through the
--- vehicle-related natives below staying loaded), so it keeps ticking and referencing something
--- that's gone. Explicitly unloading these on our own teardown returns them to BeamNG's normal
--- leave-the-level lifecycle instead of leaving them stuck alive indefinitely.
local function onExtensionUnloaded()
    table.forEach(M.preloadedDependencies, function(dep)
        if extensions.isExtensionLoaded(dep) then
            extensions.unload(dep)
        end
    end)
end

---@param vid integer
---@param callback fun(mpVeh: BJVehicle)?
local function registerVehicle(vid, callback)
    callback = callback or function() end
    local veh = be:getObjectByID(vid)
    if not veh then
        M.vehicles[vid] = nil
        return
    end
    core_jobsystem.create(function(job)
        local mpVeh
        repeat
            mpVeh = Table(MPVehicleGE.getVehicles())
                :find(function(v) return v.gameVehicleID == vid end)
            job.sleep(.01)
        until mpVeh and mpVeh.jbeam == veh.jbeam
        mpVeh = mpVeh or {} -- fail safe

        local owner
        while not owner do
            owner = beamjoy_players.players
                :find(function(p) return p.playerID == mpVeh.ownerID end)
            if not owner then job.sleep(.25) end
        end
        local vtype = M.getType(veh.jbeam)
        local aiVeh = isAi(veh.jbeam)
        if aiVeh then
            veh.playerUsable = false
            veh.uiState = 0
        elseif not mpVeh.isLocal and veh.jbeam == M.WALKING then
            veh.playerUsable = false
        end
        M.vehicles[vid] = {
            vid = vid,
            serverVID = mpVeh.serverVehicleID,
            remoteVID = mpVeh.remoteVehID ~= -1 and mpVeh.remoteVehID or vid,
            ownerID = owner.playerID,
            ownerName = owner.playerName,
            tanks = {},
            veh = veh,
            jbeam = veh.jbeam,
            height = veh:getInitialHeight(),
            type = vtype,
            isVehicle = veh.jbeam ~= M.WALKING and
                not table.includes({ M.TYPES.TRAILER, M.TYPES.PROP }, vtype),
            isAi = aiVeh,
            spectators = Table(),
            isDeleted = mpVeh.isDeleted,
            isLocal = mpVeh.isLocal,
            isSpawned = mpVeh.isSpawned,
            protected = mpVeh.protected == "1",
        }

        -- a vehicle spawning WHILE a solo race's visual reversal is active (see
        -- M.soloGhostVisualReversed) needs to show translucent immediately too, same as every
        -- other already-tracked vehicle got when the reversal first turned on. Its own ghost
        -- flag never changes just because it spawned, so nothing else would ever apply this
        if M.soloGhostVisualReversed then
            veh:setMeshAlpha(M.computeDisplayAlpha(vid, veh.ghost == "1"), "")
        end

        callback(M.vehicles[vid])
        extensions.hook("onBJVehicleInstantiated", vid)

        if owner and replay.replayPlayers[owner.playerName] then
            veh:disableCollision()
        end
    end)
end

local function onVehicleSpawned(vid)
    registerVehicle(vid, function(mpVeh)
        if mpVeh.isLocal then
            -- exempts the walking-mode "vehicle" (the unicycle) : the collada mesh-load error
            -- chased earlier turned out to be a red herring (confirmed present even in a working,
            -- BJS-absent test where the beamling was visible). The real, reported symptom is
            -- "I don't see my beamling in free cam," and this is the one piece of code in the
            -- whole mod that unconditionally forces the player OUT of free cam the instant ANY
            -- local vehicle spawns, including their own unicycle. Toggling walking mode while
            -- already in (or switching into) free cam specifically to look at yourself is a
            -- normal, expected thing to want to do, unlike spawning an actual car, where forcing
            -- the camera back onto it makes sense, forcing it away from a just-spawned walking
            -- character defeats the one thing free cam is useful for here.
            if mpVeh.jbeam ~= M.WALKING and camera.getCamera() == camera.CAMERAS.FREE then
                camera.toggleFreeCam()
            end
            local self = beamjoy_players.getSelf()
            if not mpVeh.isAi and self and self.froze then
                M.setFreeze(vid, false)
            end
            if not mpVeh.isAi and mpVeh.jbeam ~= M.WALKING then
                M.applyRespawnProtection(vid)
            end
        end
    end)
end

local function onVehicleSwitched(previousVID, newVID)
    if previousVID ~= -1 and M.vehicles[previousVID] then
        local v = M.vehicles[previousVID]
        if v.isLocal then
            if v.jbeam == M.WALKING then
                -- previously scheduled its own delayed deletion of the just-left unicycle here.
                -- Removed. Confirmed via a real captured crash (getting back in a car threw a
                -- FATAL LUA ERROR : "Attempted to call a function on an object that no longer
                -- exists", inside gameplay/walk.lua's getInVehicle -> setWalkingMode ->
                -- originalToggleWalkingMode, itself called from beammp/multiplayer.lua's own
                -- wrapped toggleWalkingMode) that BeamMP's OWN toggleWalkingMode flow already
                -- manages the previous unicycle's lifecycle (including deleting it) as part of
                -- switching back into a vehicle. This block's own independent, differently-timed
                -- deletion was racing that native cleanup, sometimes acting on (or leaving
                -- BeamMP's own code to act on) a unicycle object the other side had already torn
                -- down, which also lines up with a separately reported "unicycle mesh fails to
                -- load" symptom (a corrupted/leftover vehicle-ID state from a botched double
                -- deletion of a previous unicycle plausibly affecting a later one). The 50ms delay
                -- (its own comment already called out "to allow toggleWalk process to complete")
                -- was a workaround for this exact race, not a fix for it. Removing this
                -- redundant deletion outright, rather than tuning the delay further, so there's
                -- only ever one thing (the game's own flow) deleting a unicycle at all.
            else
                -- reset inputs except parking brake
                v.veh:queueLuaCommand([[
                    local parkingbrake = input.state.parkingbrake.val
                    input.init()
                    input.state.parkingbrake.val = parkingbrake
                ]])
            end
        end
        -- re-assert ghost translucency across the switch (BeamNG's own vehicle-focus handling can
        -- reset mesh alpha when a vehicle stops/starts being the active one). Unconditionally
        -- recomputed on BOTH sides of the switch now, not just when v.veh.ghost == "1" : under
        -- M.soloGhostVisualReversed, a non-ghosted OTHER vehicle also needs to show translucent,
        -- so "is this vehicle itself ghosted" alone isn't enough to decide anymore either
        v.veh:setMeshAlpha(M.computeDisplayAlpha(v.vid, v.veh.ghost == "1"), "")
    end
    if newVID ~= -1 then
        local timeout = GetCurrentTimeMillis() + 2000
        async.task(function(job, ctxt)
            if ctxt.now >= timeout then return true end
            local v = M.getVehicle(newVID, true)
            if not v then return false end
            return v.remoteVID ~= nil
        end, function(job, ctxt)
            local v = M.getVehicle(newVID, true)
            if v and replay.replayPlayers[v.ownerName] then
                M.switchToNextVehicle()
                return
            end
            if v and (v.isLocal or v.remoteVID) then
                beamjoy_communications.send("updateCurrentVehicle",
                    v.remoteVID)
            else
                local currentVeh = M.getCurrent()
                if currentVeh and currentVeh.remoteVID ~= beamjoy_players.getSelf().currentVehicle then
                    beamjoy_communications.send("updateCurrentVehicle", currentVeh.remoteVID)
                elseif not currentVeh and beamjoy_players.getSelf().currentVehicle then
                    beamjoy_communications.send("updateCurrentVehicle")
                end
            end
            -- same re-assert as the previousVID side above
            if v then
                v.veh:setMeshAlpha(M.computeDisplayAlpha(v.vid, v.veh.ghost == "1"), "")
            end
        end)
    else
        beamjoy_communications.send("updateCurrentVehicle")
    end
end

local function onVehicleDestroyed(vid)
    M.vehicles[vid] = nil
    M.ghostReasons[vid] = nil
end

local lastShut = {}
local function onSlowUpdate()
    -- speed and damage update process
    M.vehicles:filter(function(v) return v.isVehicle end)
        :forEach(function(v)
            v.veh:queueLuaCommand(string.var([[
                local sp = tostring(obj:getAirflowSpeed());
                obj:queueGameEngineLua("beamjoy_vehicles.updateVehAttribute('speed', {1}, "..sp..")");

                local dmg = serialize(beamstate.damage);
                obj:queueGameEngineLua("beamjoy_vehicles.updateVehAttribute('damages', {1}, "..dmg..")");
            ]], { v.vid }))
        end)

    -- shut vehicles engine process
    M.vehicles:filter(function(v)
        return v.isLocal and not v.isAi and v.isVehicle
    end):forEach(function(v)
        if v.veh.shut == "1" then
            M.setEngine(v.vid, false)
            if not lastShut[v.vid] then
                lastShut[v.vid] = true
            end
        elseif lastShut[v.vid] then
            M.setEngine(v.vid, true)
            lastShut[v.vid] = nil
        end
    end)
end

local lastCollisionsMode = nil

---@param ctxt TickContext
local function onServerTick(ctxt)
    if not ctxt.self then return LogWarn("Vehicle server tick => self not initialized") end
    -- "forced" is a hard admin override of everything CollisionsMode itself controls (zones,
    -- permanent-ghost, respawn protection). It does NOT touch the "race" reason below, which is
    -- driven independently by each race's own ghostOnCountdown setting, same as BJI's own
    -- solo-race permaGhost being separate from its global collision mode
    local collisionsMode = (beamjoy_config.data.Freeroam and beamjoy_config.data.Freeroam.CollisionsMode)
        or "ghosts"

    -- computeDisplayAlpha's own CollisionsMode == "disabled" special case can change WITHOUT any
    -- individual vehicle's own ghost boolean actually flipping (a vehicle already ghosted for
    -- "zone"/"respawn" stays ghosted either way when the mode changes). setGhost's early-return
    -- (`if (veh.ghost == "1") == state then return end`) would otherwise never re-touch that
    -- vehicle's alpha, leaving it stuck translucent (or opaque) until some unrelated ghost-state
    -- change happened to pass through. Detected here and force-reapplied to every currently-
    -- tracked vehicle at once, immediately. Same pattern setSoloGhostVisualReversed already uses
    -- for the identical class of problem.
    if collisionsMode ~= lastCollisionsMode then
        local wasDisabled = lastCollisionsMode == "disabled"
        local isDisabled = collisionsMode == "disabled"
        lastCollisionsMode = collisionsMode
        if wasDisabled ~= isDisabled then
            M.vehicles:forEach(function(mpVeh)
                mpVeh.veh:setMeshAlpha(M.computeDisplayAlpha(mpVeh.vid, mpVeh.veh.ghost == "1"), "")
            end)
        end
    end
    ctxt.self.vehicles:map(function(v)
        return M.vehicles[v.vid]
    end):filter(function(v) ---@param v BJVehicle
        return not v.isAi and v.jbeam ~= M.WALKING
    end):forEach(function(v) ---@param v BJVehicle
        if collisionsMode == "forced" then
            -- the comment above already claimed this clears respawn protection too, but the code
            -- never actually did. A vehicle mid-way through its post-spawn/reset "ghosts" timer
            -- when an admin switched to "forced" stayed ghosted until that timer separately
            -- expired on its own, despite "forced" meaning collisions should be on immediately
            M.setGhostReason(v.vid, "zone", false)
            M.setGhostReason(v.vid, "collisionsDisabled", false)
            M.setGhostReason(v.vid, "respawn", false)
            return
        end

        local inZone = false
        if #beamjoy_activity_manager.data.safeZones > 0 then
            local vPos = M.getVehiclePositionRotation(v.veh) + vec3(0, 0, v.veh:getInitialHeight() / 2)
            ---@param zone GizmoObject
            inZone = table.any(beamjoy_activity_manager.data.safeZones, function(zone)
                local right = zone.dir:cross(zone.up)
                local d = vPos - zone.pos
                local lx = d:dot(right)
                local ly = d:dot(zone.dir)
                local lz = d:dot(zone.up)
                return math.abs(lx) <= zone.scales.x * .5 and
                    math.abs(ly) <= zone.scales.y * .5 and
                    math.abs(lz) <= zone.scales.z * .5
            end)
        end
        M.setGhostReason(v.vid, "zone", inZone)
        M.setGhostReason(v.vid, "collisionsDisabled", collisionsMode == "disabled")
    end)
end

local function onVehicleResetted(vid)
    local mpVeh = M.vehicles[vid]
    if not mpVeh or not mpVeh.isLocal or mpVeh.isAi then return end
    if mpVeh.veh.froze then
        M.setFreeze(vid, false)
    end
    if mpVeh.jbeam ~= M.WALKING then
        M.applyRespawnProtection(vid)
    end
end

---@param req RequestAuthorization
---@param model string
---@param config string?
local function onBJRequestCanSpawnVehicle(req, model, config)
    local canSpawnTrailers = beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.SpawnTrailers)
    local canSpawnProps = beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.SpawnProps)
    if not M.allVehicleConfigs then
        M.getAllVehicleConfigs()
    end
    if not canSpawnTrailers and M.allTrailerConfigs[model] then
        req.state = false
    elseif not canSpawnProps and M.allPropConfigs[model] then
        req.state = false
    elseif not M.allVehicleConfigs[model] and
        not M.allTrailerConfigs[model] and
        not M.allPropConfigs[model] and
        model ~= M.WALKING then
        -- was `not model == M.WALKING`, which Lua parses as `(not model) == M.WALKING` (unary
        -- `not` binds tighter than `==`). `model` is always a non-nil string here, so `not model`
        -- is always `false`, and `false == "unicycle"` is always false regardless of what `model`
        -- actually is. That silently made this entire branch dead code : req.state = false could
        -- never fire here for ANY model, not just the walking exemption it was trying to carve
        -- out, so a genuinely unknown/unlisted model was never actually being rejected by this
        -- check at all. Coincidentally harmless for `model == M.WALKING` specifically (both the
        -- broken and correct forms evaluate to false there, which is why this wasn't what was
        -- blocking unicycle spawning), but a real hole for everything else.
        req.state = false
    end
end

local function onBJVehicleModChanged()
    local allModels = beamjoy_vehicles.getAllVehicleConfigs(nil,
        { cars = true, trucks = true, trailers = true, props = true, forced = true })
    beamjoy_vehicles.vehicles:filter(function(v) ---@param v BJVehicle
        -- Find owned and invalid vehicles
        return v.isLocal and not v.isAi and
            v.jbeam ~= beamjoy_vehicles.WALKING and
            not allModels[v.jbeam]
    end):forEach(function(v) ---@param v BJVehicle
        beamjoy_vehicles.delete(v.vid)
    end)
end

---@param jbeam string
---@return string
local function getType(jbeam)
    if M.modelTypeCache[jbeam] then
        return M.modelTypeCache[jbeam]
    end

    if not M.allVehicleConfigs then
        M.getAllVehicleConfigs()
    end

    local finalType
    if M.allVehicleConfigs[jbeam] then
        finalType = M.allVehicleConfigs[jbeam].Type
    elseif M.allTrailerConfigs[jbeam] then
        finalType = M.allTrailerConfigs[jbeam].Type
    elseif M.allPropConfigs[jbeam] then
        finalType = M.allPropConfigs[jbeam].Type
    end
    M.modelTypeCache[jbeam] = finalType
    return finalType
end

---@param vid integer
---@param light boolean?
---@return BJVehicle?
local function getVehicle(vid, light)
    local v = M.vehicles[vid]
    if M.vehicles[vid] and not light then
        v.position, v.rotation = M.getVehiclePositionRotation(v.veh)
        v.spectators = beamjoy_context.get().players
            :filter(function(p) return p.currentVehicle == v.remoteVID end)
            :map(function() return true end)
    end
    return v
end

---@param remoteVID integer
---@param withPosition boolean?
---@return BJVehicle?
local function getVehicleByRemoteID(remoteVID, withPosition)
    local mpVeh = Table(MPVehicleGE.getVehicles())
        :find(function(v) return v.remoteVehID == remoteVID end)
    if mpVeh then
        return getVehicle(mpVeh.gameVehID, not withPosition)
    end
end

---@param veh NGVehicle
---@return vec3 pos, vec3 dir, vec3 up
local function getVehiclePositionRotation(veh)
    return vec3(be:getObjectOOBBCenterXYZ(veh:getID())) -
        veh:getDirectionVectorUp() * veh:getInitialHeight() / 2,
        veh:getDirectionVector(), veh:getDirectionVectorUp()
end

---@param veh NGVehicle
---@param pos vec3
---@param dir vec3?
---@param up vec3?
---@param options {cling: false?, autoEnterVehicle: true?, safe: false?, noReset: true?}?
local function setVehiclePositionRotation(veh, pos, dir, up, options)
    options = options or {}
    options.cling = options.cling ~= false -- default true
    options.autoEnterVehicle = options.autoEnterVehicle == true
    options.safe = options.safe ~= false   -- default true
    options.noReset = options.noReset == true

    if options.cling then
        pos.z = be:getSurfaceHeightBelow(pos + vec3(0, 0, 10))
    end
    if not dir then
        local _
        _, dir, up = M.getVehiclePositionRotation(veh)
    end

    local rot = quatFromDir(dir * -1, up)
    if options.noReset then
        local vehRot = quat(veh:getClusterRotationSlow(veh:getRefNodeId()))
        local diffRot = vehRot:inversed() * rot
        veh:setClusterPosRelRot(veh:getRefNodeId(), pos.x, pos.y, pos.z,
            diffRot.x, diffRot.y, diffRot.z, diffRot.w)
        veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 0, 0, 0, 0)
    else
        veh:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
        local center = rot * veh.initialNodePosBB:getCenter()
        local refnode = rot * veh:getInitialNodePosition(veh:getRefNodeId())
        local centerToRefnode = refnode - center
        pos = pos + centerToRefnode
        if options.safe then
            rot = rot * quat(0, 0, 1, 0)
            spawn.safeTeleport(veh, pos, rot, false)
        else
            veh:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
            veh:resetBrokenFlexMesh()
        end
    end
end

---@class NGVehicleConfig
---@field label string
---@field custom boolean
---@field value integer?

---@class NGVehicleModel
---@field label string
---@field type string
---@field custom boolean
---@field paints table<string, NGPaint>
---@field configs table<string, NGVehicleConfig> index config_key
---@field preview string

---@param job NGJob?
---@param data {cars: boolean?, trucks: boolean?, trailers: boolean?, props: boolean?, traffic: boolean?, forced: boolean?}?
---@return table<string, NGVehicleModel> allConfigs index model_key
local function getAllVehicleConfigs(job, data)
    data = data or {}
    data.cars = data.cars ~= false
    data.trucks = data.trucks ~= false

    if not data.forced and M.allVehicleConfigs then
        -- cached data
        local configs = {}
        if data.cars then
            table.assign(configs, Table(M.allVehicleConfigs):clone()
                :filter(function(v) return v.Type == M.TYPES.CAR end))
        end
        if data.trucks then
            table.assign(configs, Table(M.allVehicleConfigs):clone()
                :filter(function(v) return v.Type == M.TYPES.TRUCK end))
        end
        if data.trailers then
            table.assign(configs, Table(M.allTrailerConfigs):clone())
        end
        if data.props then
            table.assign(configs, Table(M.allPropConfigs):clone())
        end
        if data.traffic then
            table.assign(configs, Table(M.allTrafficConfigs):clone())
        end
        return configs
    end

    local time = GetCurrentTimeMillis()
    local frameSkip = function()
        if job and GetCurrentTimeMillis() > time + 1 then
            job.sleep(.01)
            time = GetCurrentTimeMillis()
        end
    end

    -- data gathering
    local vehicles = {}
    local trailers = {}
    local props = {}
    local traffic = {}
    local vehs = extensions.core_vehicles.getVehicleList().vehicles
    for _, veh in ipairs(vehs) do
        if veh.model then
            local isVeh = true -- Truck | Car
            local isTraffic = veh.model.Type == M.TYPES.TRAFFIC and veh.model.key:lower():find("traffic")
            M.modelTypeCache[veh.model.key] = veh.model.Type
            if table.includes({ M.TYPES.TRAILER, M.TYPES.PROP }, M.modelTypeCache[veh.model.key]) or
                M.modelTypeCache[veh.model.key] == M.TYPES.TRAFFIC then
                isVeh = false
            end

            if table.includes({
                    M.WALKING,
                    "roof_crush_tester"
                }, veh.model.key) then
                -- do not use
                goto skipVeh
            end

            if veh.model.aggregates.Source.Mod then
                local jbeamIO = require('jbeam/io')
                local function tryLoadVeh()
                    if not jbeamIO.getMainPartName(jbeamIO.startLoading({
                            string.var("/vehicles/{1}/", { veh.model.key }),
                            "/vehicles/common/"
                        })) then
                        error()
                    end
                end
                if not pcall(tryLoadVeh) then
                    -- vehicle lot loaded
                    goto skipVeh
                end
            end

            local target
            if isVeh then
                target = vehicles
            elseif isTraffic then
                target = traffic
            elseif veh.model.Type == M.TYPES.TRAILER then
                target = trailers
            elseif veh.model.Type == M.TYPES.PROP then
                target = props
            end
            local brandPrefix = ""
            if veh.model.Brand then
                brandPrefix = veh.model.Brand .. " "
            end
            local yearsSuffix = ""
            if veh.model.Years and veh.model.Years.min then
                yearsSuffix = string.format(" (%s)", tostring(veh.model.Years.min))
            end

            target[veh.model.key] = table.clone(veh.model)
            table.assign(target[veh.model.key], {
                label = string.format("%s%s%s", brandPrefix, veh.model.Name, yearsSuffix),
                type = veh.model.Type,
                custom = veh.model.aggregates.Source.Mod,
                paints = target[veh.model.key].paints or {},
                configs = {},
                preview = veh.model.preview,
            })

            local configs = target[veh.model.key].configs
            for key, config in pairs(veh.configs) do
                if config.key then
                    local label = (config.Configuration or config.key):gsub("_", " ")
                    if not config.key:lower():endswith("_parked") then
                        configs[key] = table.clone(config)
                        table.assign(configs[key], {
                            label = label,
                            custom = not target[veh.model.key].custom and
                                config.Source ~= "BeamNG - Official",
                            value = config.aggregates and config.aggregates.Value or nil
                        })
                    end
                end
            end
            frameSkip()
        end
        ::skipVeh::
    end
    M.allVehicleConfigs = vehicles
    M.allTrailerConfigs = trailers
    M.allPropConfigs = props
    M.allTrafficConfigs = traffic

    -- LABELS

    M.allVehicleLabels = {}
    for model, d in pairs(vehicles) do
        M.allVehicleLabels[model] = d.label or model
    end
    frameSkip()
    M.allTrailerLabels = {}
    for model, d in pairs(trailers) do
        M.allTrailerLabels[model] = d.label or model
    end
    frameSkip()
    M.allPropLabels = {}
    for model, d in pairs(props) do
        M.allPropLabels[model] = d.label or model
    end
    frameSkip()
    M.allTrafficLabels = {}
    for model, d in pairs(traffic) do
        M.allTrafficLabels[model] = d.label or model
    end

    extensions.hook("onBJVehiclesCacheUpdate")

    data.forced = nil
    -- return cached data
    return M.getAllVehicleConfigs(job, data)
end

---@param job NGJob?
---@param data {cars: boolean?, trucks: boolean?, trailers: boolean?, props: boolean?, traffic: boolean?, forced: boolean?}?
---@return table<string, string>
local function getAllVehicleLabels(job, data)
    data = data or {}
    if data.forced or not M.allVehicleConfigs then
        M.getAllVehicleConfigs(job, { forced = true })
    end
    local labels = table.clone(M.allVehicleLabels)
    if job then job.sleep(.01) end
    if data.trailers then
        for k, v in pairs(M.allTrailerLabels) do
            labels[k] = v
        end
        if job then job.sleep(.01) end
    end
    if data.props then
        for k, v in pairs(M.allPropLabels) do
            labels[k] = v
        end
        if job then job.sleep(.01) end
    end
    if data.traffic then
        for k, v in pairs(M.allTrafficLabels) do
            labels[k] = v
        end
        if job then job.sleep(.01) end
    end
    return labels
end

---@param model? string
---@param withTechName? boolean
---@return string
local function getModelLabel(model, withTechName)
    model = model or M.getCurrentModel()
    if type(model) ~= "string" then
        return "?"
    end

    if not M.allVehicleConfigs then
        M.getAllVehicleConfigs()
    end

    local label
    if M.allVehicleLabels[model] then
        label = M.allVehicleLabels[model]
    elseif M.allTrailerLabels[model] then
        label = M.allTrailerLabels[model]
    elseif M.allPropLabels[model] then
        label = M.allPropLabels[model]
    elseif M.allTrafficLabels[model] then
        label = M.allTrafficLabels[model]
    end
    if label == model then
        return model
    elseif not withTechName then
        return label or "?"
    else
        return string.var("{1} - {2}", { model, label or "?" })
    end
end

---@param model string
---@param configKey string
---@return string
local function getConfigLabel(model, configKey)
    if type(model) ~= "string" or type(configKey) ~= "string" then
        return "?"
    end

    local modelData = M.getAllVehicleConfigs(nil,
        { trailers = true, props = true, traffic = true })[model] or {}
    return (modelData.configs and modelData.configs[configKey]) and
        modelData.configs[configKey].label or "?"
end

---@return BJVehicle?
local function getCurrent()
    local current = be:getPlayerVehicle(0)
    if current then
        return M.getVehicle(current:getID(), true)
    end
end

---@return BJVehicle?
local function getCurrentOwn()
    local current = getCurrent()
    return (current and current.isLocal) and current or nil
end

-- return the current vehicle model key
---@return string?
local function getCurrentModel()
    local current = getCurrent()
    return current and current.jbeam or nil
end

---@param vid integer
local function delete(vid)
    local veh = be:getObjectByID(vid)
    if veh then veh:delete() end
end

local function deleteCurrentOthersVehicle()
    ---@type NGVehicle?
    local current = be:getPlayerVehicle(0)
    if current and M.vehicles[current:getID()] and
        not M.vehicles[current:getID()].isLocal then
        M.delete(current:getID())
    end
end

local function deleteCurrentOwnVehicle()
    ---@type NGVehicle?
    local current = be:getPlayerVehicle(0)
    if current and M.vehicles[current:getID()] and
        M.vehicles[current:getID()].isLocal then
        M.delete(current:getID())
    end
end

local function deleteOtherOwnVehicles()
    local own = M.vehicles:filter(function(v)
        return v.isLocal and not v.isAi
    end):keys()
    ---@type NGVehicle?
    local current = be:getPlayerVehicle(0)
    if current then
        own = own:filter(function(v) return v ~= current:getID() end)
    end
    own:forEach(M.delete)
end

---@param vid integer
---@param state boolean?
local function setFreeze(vid, state)
    local v = M.getVehicle(vid, true)
    if v and v.isLocal then
        if state == nil then
            state = v.veh.froze ~= "1"
        end
        local finalState = state and 1 or 0
        v.veh:queueLuaCommand(string.format("controller.setFreeze(%d)", finalState))
        v.veh:setDynDataFieldbyName("froze", 0, tostring(finalState))
    end
end

---@param vid integer
---@param state boolean
local function setEngine(vid, state)
    local v = M.getVehicle(vid, true)
    if v and v.isLocal then
        if state == nil then
            state = v.veh.shut == "1"
        end
        if state then
            v.veh:queueLuaCommand('controller.mainController.setStarter(true)')
        end
        v.veh:queueLuaCommand(string.format(
            "if controller.mainController.setEngineIgnition then controller.mainController.setEngineIgnition(%s) end",
            tostring(state)
        ))
        local wasForceShut = v.veh.shut == "1"
        v.veh:setDynDataFieldbyName("shut", 0, state and "0" or "1")
        if state and wasForceShut then
            core_jobsystem.create(function(job)
                job.sleep(1)
                v.veh:queueLuaCommand('controller.mainController.setStarter(true)')
            end)
        end
    end
end

---@param vid integer
---@param state boolean
---@param allLights boolean?
local function setLights(vid, state, allLights)
    local v = M.getVehicle(vid, true)
    if v and v.isLocal then
        local finalState = state == true and 1 or 0

        if finalState == 1 then
            v.veh:queueLuaCommand("electrics.setLightsState(1)")
            v.veh:queueLuaCommand("electrics.setLightsState(2)")
        else
            v.veh:queueLuaCommand("electrics.setLightsState(0)")
            if allLights then
                v.veh:queueLuaCommand(string.var("electrics.set_warn_signal({1})", { finalState }))
                v.veh:queueLuaCommand(string.var("electrics.set_lightbar_signal({1})", { finalState }))
                v.veh:queueLuaCommand(string.var("electrics.set_fog_lights({1})", { finalState }))
            end
        end
    end
end

local function focusVehicle(vid)
    local mpVeh = M.vehicles[vid]
    if mpVeh then
        be:enterVehicle(0, mpVeh.veh)
        if camera.getCamera() == camera.CAMERAS.FREE then
            camera.toggleFreeCam()
        end
    end
end

---@param jbeam string
---@return string
local function getLabelByModel(jbeam)
    if not M.allVehicleLabels then
        -- TODO optimization
        return jbeam
    end

    return M.allVehicleLabels[jbeam] or
        M.allTrailerLabels[jbeam] or
        M.allPropLabels[jbeam] or
        jbeam
end

---@param callback fun(mpVeh: BJVehicle)
local function waitForSpawn(callback)
    core_jobsystem.create(function(job)
        job.sleep(.2)
        local timeout = GetCurrentTimeMillis() + 20000

        local mpVeh = M.getCurrent()
        while ui_imgui.GetIO().Framerate < 5 or not mpVeh or
            not mpVeh.veh.damages or tonumber(mpVeh.veh.damages) > 100 do
            job.sleep(.01)
            mpVeh = mpVeh or M.getCurrent()
            if GetCurrentTimeMillis() >= timeout then
                LogError("waitForSpawn timed out")
                return
            end
        end

        callback(mpVeh)
    end)
end

---@param key string
---@param vid integer
---@param value any
local function updateVehAttribute(key, vid, value)
    if M.vehicles[vid] then
        M.vehicles[vid].veh:setDynDataFieldbyName(key, 0, tostring(value))
    end
end

---@param remoteVID integer
local function explode(remoteVID)
    local mpVeh = M.vehicles:find(function(v) return v.remoteVID == remoteVID end)
    if mpVeh then
        if mpVeh.isLocal then
            mpVeh.veh:applyClusterVelocityScaleAdd(mpVeh.veh:getRefNodeId(), 1, 0, 0, 3)
            core_jobsystem.create(function(job)
                job.sleep(.2)
                if M.vehicles[mpVeh.vid] then
                    mpVeh.veh:queueLuaCommand("beamstate.breakAllBreakgroups()")
                end
            end)
        end
        mpVeh.veh:queueLuaCommand("fire.explodeVehicle()")
    end
end

---@param remoteVID integer
local function launch(remoteVID)
    local mpVeh = M.vehicles:find(function(v) return v.remoteVID == remoteVID end)
    if mpVeh and mpVeh.isLocal then
        local angle = math.random() * 2 * math.pi
        local horizontalForce = 15
        local upwardForce = 40
        mpVeh.veh:applyClusterVelocityScaleAdd(mpVeh.veh:getRefNodeId(), 1,
            math.cos(angle) * horizontalForce, math.sin(angle) * horizontalForce, upwardForce)
    end
end

local function switchToNextVehicle()
    be:enterNextVehicle(0, 1)
end

--- several independent subsystems (safe zones, the server-wide CollisionsMode setting, race-grid
--- COUNTDOWN, spawn/reset protection) can each want a given vehicle ghosted at the same time.
--- routing every one of them through this single reason registry instead of each calling setGhost
--- directly means one subsystem clearing its own reason can never accidentally un-ghost a vehicle
--- another subsystem still legitimately wants hidden (the vehicle stays ghosted as long as ANY
--- reason is still active).
---@type table<integer, table<string, true>> vid -> set of active ghost reasons
M.ghostReasons = {}

--- true while this client should render its OWN vehicle normally and every OTHER vehicle
--- translucent instead, reversed specifically for a solo race's full-duration ghost (see
--- raceRunner.lua's own COUNTDOWN/RACE-transition comments for why solo alone stays ghosted the
--- whole race), per direct request : a solo racer doesn't want to stare at their own half-
--- invisible car for an entire race, and every OTHER vehicle nearby genuinely can't stop them
--- (that's the whole point of the ghost), so flagging THOSE as the visually-odd ones reads better.
--- Purely a local rendering choice. The real ghost/collision flag and its cross-client sync are
--- completely unaffected ; every OTHER client still sees this player's own vehicle as the
--- (correctly, per the real synced ghost flag) translucent one, exactly as before.
M.soloGhostVisualReversed = false

---@param vid integer
---@param isGhosted boolean the vehicle's own real ghost/collision state, as already known by the
---caller (M.ghostReasons only ever tracks reasons for locally-owned vehicles, never a remote
---vehicle's ghost state, so this can't just be re-derived from it in general)
---@return number
local function computeDisplayAlpha(vid, isGhosted)
    -- CollisionsMode == "disabled" ghosts literally every vehicle, permanently, for as long as
    -- it's set. The translucency visual exists to flag a TEMPORARY, situational ghost (respawn
    -- protection, a safe zone, a race countdown), which stops meaning anything once it's just the
    -- server's permanent baseline state instead ; every vehicle staying translucent forever reads
    -- as a rendering bug, not useful information. Per direct request.
    local freeroam = beamjoy_config.data.Freeroam
    if freeroam and freeroam.CollisionsMode == "disabled" then return 1 end
    if M.soloGhostVisualReversed then
        -- real bug, found from a live report ("ghosting doesn't seem to apply to traffic") : this
        -- used to check mpVeh.isLocal, which is BeamMP's own "not owned by a remote player" flag,
        -- true for every vehicle that exists on THIS client, not just the one actually being
        -- driven. Local AI traffic (each client spawns its own, never synced from another player)
        -- satisfies isLocal just as much as the racer's own car does, so every traffic vehicle was
        -- silently exempted from the translucent treatment right alongside it. Fixed by checking
        -- against the actual currently-controlled vehicle (be:getPlayerVehicle(0)) instead. The
        -- real "is this the racer's own car" question, which traffic can never satisfy.
        local current = be:getPlayerVehicle(0)
        return (current and current:getID() == vid) and 1 or 0.5
    end
    return isGhosted and 0.5 or 1
end

---@param state boolean
local function setSoloGhostVisualReversed(state)
    if M.soloGhostVisualReversed == state then return end
    M.soloGhostVisualReversed = state
    -- re-applies to every currently-tracked vehicle at once, immediately, rather than waiting for
    -- each one's own ghost flag to happen to change next. A bystander's car that was never
    -- ghosted at all still needs to flip to translucent (or back) the instant reversal toggles
    M.vehicles:forEach(function(mpVeh)
        mpVeh.veh:setMeshAlpha(computeDisplayAlpha(mpVeh.vid, mpVeh.veh.ghost == "1"), "")
    end)
end

---@param vid integer
---@param reason string
---@param active boolean
---@param force boolean? bypasses setGhost's own distance-safety retry entirely when this reason
---being cleared is what actually brings the vehicle to fully un-ghosted (no-op if some OTHER
---reason is still keeping it ghosted, or if `active` is true). See applyRespawnProtection's own
---bounded-timeout fallback for why this exists
---@param checkGhostedBystanders boolean? passed straight through to setGhost. See its own doc
local function setGhostReason(vid, reason, active, force, checkGhostedBystanders)
    local mpVeh = M.vehicles[vid]
    if not mpVeh then return end
    M.ghostReasons[vid] = M.ghostReasons[vid] or {}
    M.ghostReasons[vid][reason] = active or nil
    M.setGhost(mpVeh.veh, next(M.ghostReasons[vid]) ~= nil, force, checkGhostedBystanders)

    -- scoped to reason == "race" specifically (not respawn/zone/disabled ghosting, which can
    -- affect multiple unrelated vehicles at once and has no single "the racer" to treat
    -- specially) and to a real solo session (participants <= 1). Multiplayer's own shared
    -- COUNTDOWN grid-ghost is unaffected. Every "race"-reason call already always targets the
    -- local player's own vehicle (raceRunner.lua never calls this for anyone else's), but checked
    -- explicitly anyway rather than assumed.
    if reason == "race" and mpVeh.isLocal then
        local session = beamjoy_raceRunner and beamjoy_raceRunner.session
        M.setSoloGhostVisualReversed(active and session ~= nil and #session.participants <= 1)
    end
end

---@param vid integer
local function applyRespawnProtection(vid)
    local freeroam = beamjoy_config.data.Freeroam or {}
    local collisionsMode = freeroam.CollisionsMode or "ghosts"
    if collisionsMode ~= "ghosts" then return end
    M.setGhostReason(vid, "respawn", true)
    local taskName = "ghostRespawnProtect-" .. vid
    local forceTaskName = "ghostRespawnProtectForce-" .. vid
    async.removeTask(taskName)
    async.removeTask(forceTaskName)
    -- explicit enable flag now (Freeroam.RespawnGhostTimeoutEnabled), not a magic "slide the
    -- timer to its max value" sentinel. That convention turned out fragile in practice (a value
    -- of exactly the slider's own max had no real server-side meaning and could trip config-save
    -- validation).
    --
    -- Off is documented (and intended) as "wait indefinitely for RespawnGhostDistance to clear
    -- instead of a fixed duration", NOT "never even try to clear at all." Real, confirmed bug :
    -- this used to just `return` here, which never once called setGhostReason(false) at all when
    -- the timer was off, so setGhost's own distance/contact check (the thing that's actually
    -- supposed to decide when it's safe to un-ghost) never got invoked, leaving a vehicle ghosted
    -- forever even standing completely alone with nothing nearby. Fixed by attempting the clear
    -- immediately instead of skipping it : setGhostReason(false) hands off to setGhost's own
    -- distance-safety retry (every 200ms, no bound, no force fallback in this branch), which
    -- un-ghosts right away if already clear or keeps retrying until it genuinely is, exactly the
    -- "wait indefinitely for distance" behavior this was always meant to have.
    if freeroam.RespawnGhostTimeoutEnabled == false then
        M.setGhostReason(vid, "respawn", false)
        return
    end
    local timeoutSec = freeroam.RespawnGhostTimeout
    if timeoutSec == nil then timeoutSec = 10 end
    async.delayTask(function() M.setGhostReason(vid, "respawn", false) end, timeoutSec * 1000, taskName)
    -- setGhost's own RespawnGhostDistance safety check (below) retries un-ghosting every 200ms
    -- with NO bound of its own until genuinely clear of every other vehicle. Appropriate when the
    -- timer above is disabled (documented as "wait indefinitely"), but with a real timer enabled
    -- this could otherwise strand a vehicle ghosted far longer than the configured duration just by
    -- being parked somewhere crowded, defeating the point of a bounded timeout. A short grace
    -- period past the timer's own deadline gives the distance check a fair chance to resolve
    -- cleanly on its own first (the common case, nobody's actually still there) ; past that,
    -- force through regardless of what's still nearby. Per direct request.
    async.delayTask(function()
        M.setGhostReason(vid, "respawn", false, true)
    end, timeoutSec * 1000 + 3000, forceTaskName)
end

---@param veh NGVehicle
---@param state boolean
---@param force boolean? real, confirmed bug fixed here (live report : ghosting could disable
---while two vehicles were still physically inside each other, at both a race's countdown->RACE
---transition and generally). `force` used to skip this WHOLE safety check, including literal
---bounding-radius contact, not just the extra configurable buffer on top of it. That's a
---reasonable trade for the wider ghosting system's own force-fallback (`applyRespawnProtection`'s
---timeout+3s) : a single freshly-spawned vehicle is rarely placed in genuine, literal contact with
---another one in the first place, so forcing through in the rare case it IS still crowded nearby
---is a minor, harmless bump at worst. It's NOT a reasonable trade for a race's own grid-start
---un-ghost fallback (raceRunner.lua's RACE transition, 2s after the green light) : a starting grid
---is DELIBERATELY packed tight by design, so genuine bounding-radius overlap at the exact moment
---every participant un-ghosts together is a real, likely case, not a rare edge case. Forcing
---straight through it launches two solid bodies that are still literally superimposed, which is a
---collision explosion, not a minor bump. Same underlying mechanism, very different odds of actually
---triggering it, which is why this only ever showed up as a race problem in practice. Fixed once,
---for both : `force` now only ever skips the extra CONFIGURABLE buffer above the two vehicles' own
---real bounding radii. Literal radius-to-radius contact still blocks un-ghosting unconditionally,
---so this can never launch two vehicles that are still genuinely inside each other, only skip past
---an overly generous EXTRA safety margin once the caller's own timeout says it's waited long enough.
---@param checkGhostedBystanders boolean? default true : a bystander vehicle that's currently
---ghosted itself is normally skipped by the overlap check below (a ghost-ghost overlap can't
---collide, so it's harmless to ignore). Pass false to check real distance against EVERY nearby
---vehicle regardless of its own ghost flag. Needed specifically for the race-start un-ghost (see
---raceRunner.lua's RACE transition) : every participant transitions to solid together, so each
---client's own locally-known ghost flag for a fellow racer can be a few ms stale (their own
---un-ghost sync hasn't arrived yet). Both sides could otherwise perceive each other as "still
---ghosted, safe to ignore" and clear simultaneously while actually overlapping.
local function setGhost(veh, state, force, checkGhostedBystanders)
    if checkGhostedBystanders == nil then checkGhostedBystanders = true end
    if (veh.ghost == "1") == state then return end
    local mpVeh = M.vehicles[veh:getID()]
    local processName = "ghostRecover-" .. tostring(veh:getID())
    -- per direct request : a trailer attached to the local vehicle skips this whole distance/
    -- contact safety check entirely, un-ghosting immediately regardless of what's nearby (not
    -- even a literal-contact exemption, the full check is bypassed). A trailer's own separate
    -- bounding length routinely overlaps whatever it's hitched to and anything else nearby in a
    -- busy spawn/pits area, which could otherwise strand a towing vehicle ghosted indefinitely,
    -- the exact same "retries forever" failure mode the timer-fallback fix above exists to guard
    -- against, just triggered by trailer geometry instead of a crowded area.
    local hasTrailer = mpVeh and mpVeh.isLocal and #M.getAttachedTrailers(veh:getID()) > 0
    if mpVeh and mpVeh.isLocal and not state and not hasTrailer then
        local p1 = M.getVehiclePositionRotation(veh)
        local r1 = veh:getInitialLength() / 2
        -- configurable buffer on top of the two vehicles' own bounding radii (Freeroam.
        -- RespawnGhostDistance, default 0 = only literal contact blocks un-ghosting, matching the
        -- original behavior). Same role as BJI's own CollisionsManager.ghostsRadius. `force`
        -- zeroes this OUT specifically, never the base r1+r2 radii themselves. See this
        -- function's own `force` doc comment above for why.
        local distanceBuffer = force and 0 or
            ((beamjoy_config.data.Freeroam and beamjoy_config.data.Freeroam.RespawnGhostDistance) or 0)
        if M.vehicles:any(function(v)
                if v.vid == veh:getID() then return false end
                if checkGhostedBystanders and v.veh.ghost == "1" then return false end
                local p2 = M.getVehiclePositionRotation(v.veh)
                local r2 = v.veh:getInitialLength() / 2
                return p1:distance(p2) < r1 + r2 + distanceBuffer
            end) then
            async.removeTask(processName)
            async.delayTask(function() setGhost(veh, false, force, checkGhostedBystanders) end, 200, processName)
            return
        end
    end
    async.removeTask(processName)
    veh:queueLuaCommand("obj:setGhostEnabled(" .. tostring(state) .. ")")
    veh:setDynDataFieldbyName("ghost", 0, state and "1" or "0")
    -- translucency on the vehicle itself, always, including the one currently being driven,
    -- matching BJI's own ghost visual intent (its setAlpha), just via veh:setMeshAlpha instead of
    -- core_vehicle_partmgmt.setHighlightedPartsVisiblity (what this fork AND BJI both originally
    -- used here) : that function only ever affects whichever parts are in the vehicle's own
    -- "highlighted parts" set. Real state belonging to the parts-tuning UI, not something this
    -- vehicle's own alpha visually not changing at all when nothing had ever populated/selected
    -- it (a real, confirmed-by-testing no-op, not a "current vehicle" special case like round 1's
    -- HUD-icon guess). setMeshAlpha (confirmed via the installed game's own gameplay/walk.lua and
    -- gameplay/traffic/vehicle.lua, both already using it for exactly this kind of fade) sets a
    -- vehicle's actual mesh transparency directly, unconditionally, regardless of any parts-
    -- selection state. The reliable primitive this should have used from the start.
    veh:setMeshAlpha(M.computeDisplayAlpha(veh:getID(), state), "")
    if mpVeh and mpVeh.isLocal then
        -- remoteVID, not vid. See the "updateVehicleGhost" handler's own comment above (onInit)
        -- for why vid alone doesn't identify this vehicle correctly on any OTHER client
        beamjoy_communications.send("updateVehicleGhost", mpVeh.remoteVID, state)
    end
end

---@param vid integer
---@return integer[] VIDs
local function getAttachedTrailers(vid)
    local mpVeh = M.vehicles[vid]
    if not mpVeh then return {} end
    local res = {}
    local function _processAttached(vehData, level)
        level = level or 1
        if level > 10 then return end
        if vehData.vehId ~= vid and
            not table.includes(res, vehData.vehId) then
            table.insert(res, vehData.vehId)
        end
        if vehData.children and #vehData.children > 0 then
            for _, c in ipairs(vehData.children) do
                _processAttached(c, level + 1)
            end
        end
    end
    _processAttached(core_vehicles.generateAttachedVehiclesTree(vid))
    return res
end

-- config is optionnal
---@param veh NGVehicle
---@return boolean
local function isConfigCustom(veh)
    return not veh.partConfig:endswith(".pc")
end

---@param tree table
---@return table<string, string>
local function convertPartsTree(tree)
    local parts = {}
    local function recursParts(data)
        if not data then return end
        for k, v in pairs(data) do
            if v.chosenPartName then
                parts[k] = v.chosenPartName
            end
            if v.children then
                recursParts(v.children)
            end
        end
    end
    recursParts(tree.children)
    return parts
end

--- return the full config raw data
---@param veh NGVehicle
---@return ClientVehicleConfig?
local function getFullConfig(veh)
    local rawConfig = extensions.core_vehicle_manager.getVehicleData(veh:getID())
    if not rawConfig or not rawConfig.config or not rawConfig.config.partsTree then return end

    local model = rawConfig.config.model
    local isCustom = isConfigCustom(veh)
    local key = not isCustom and tostring(rawConfig.config.partConfigFilename)
        :gsub("^vehicles/.*/", ""):gsub("%.pc$", "") or nil

    local modelLabel = M.getModelLabel(model)
    local label = (not isCustom and key) and
        string.var("{1} {2}", { modelLabel, M.getConfigLabel(model, key) }) or modelLabel
    return {
        model = model,
        label = label,
        key = key,
        parts = convertPartsTree(rawConfig.config.partsTree),
        -- both legitimately nil for a vehicle with no runtime tuning/paint overrides (the common
        -- case, not an edge case). Defaulted to empty tables here, at the source, rather than
        -- trusting every caller to handle a nil vars/paints itself ; a real, confirmed bug
        -- (raceRunner.lua's restoreSavedVehicle passing a bare nil straight into
        -- core_vehicles.spawnNewVehicle's config crashed the native spawn code entirely) traced
        -- back to exactly this
        vars = rawConfig.config.vars or {},
        paints = rawConfig.config.paints or {},
    }
end

--- human-readable "Model - Config" (or "Model (custom)" once the live setup no longer matches any
--- saved .pc config, BeamNG's own isConfigCustom check, same one getFullConfig already uses)
--- label for whatever's actually currently equipped. Used for the race leaderboard's vehicle
--- column, per direct request ("read what config the user has chosen, and if it doesn't fit a
--- config, say (custom)"). Not stored/localized server-side, this whole formatted string is
--- computed once here and sent as-is, matching how vehicle/config names are never localized
--- anywhere else in this codebase either.
---@param veh NGVehicle
---@return string
local function getCurrentConfigDisplayLabel(veh)
    local rawConfig = extensions.core_vehicle_manager.getVehicleData(veh:getID())
    local model = rawConfig and rawConfig.config and rawConfig.config.model
    if not model then return "?" end
    local modelLabel = M.getModelLabel(model)
    if isConfigCustom(veh) then
        return string.format("%s (custom)", modelLabel)
    end
    local key = tostring(rawConfig.config.partConfigFilename)
        :gsub("^vehicles/.*/", ""):gsub("%.pc$", "")
    return string.format("%s - %s", modelLabel, M.getConfigLabel(model, key))
end

--- model + normalized config key + display label for whatever's currently equipped, or nil if
--- it's a custom (unsaved .pc) setup. Used by the race editor's "vehicle restriction" feature
--- (pool mode) to capture a saved-config vehicle from whatever the host currently happens to be
--- sitting in, referenced by model+config key rather than a full parts snapshot ("single" mode,
--- below via getFullConfig, captures the whole parts tree instead. The two modes have different
--- needs, see their own doc comments). Deliberately refuses a custom config entirely (returns nil,
--- same as "no vehicle") rather than capturing something : a pool entry has to be something the
--- native vehicle selector can actually present as a real, clickable tile, and a custom setup has
--- no saved file to be one. Shares its model/key derivation with getCurrentConfigDisplayLabel
--- above.
---@param veh NGVehicle
---@return {model: string, config: string, label: string}?
local function getCurrentConfigIdentity(veh)
    local rawConfig = extensions.core_vehicle_manager.getVehicleData(veh:getID())
    local model = rawConfig and rawConfig.config and rawConfig.config.model
    if not model or isConfigCustom(veh) then return nil end
    local key = tostring(rawConfig.config.partConfigFilename)
        :gsub("^vehicles/.*/", ""):gsub("%.pc$", "")
    return {
        model = model,
        config = key,
        label = string.format("%s - %s", M.getModelLabel(model), M.getConfigLabel(model, key)),
    }
end

--- a config being non-custom (isConfigCustom above) only means it was loaded from a real .pc file
--- ON THIS COMPUTER. It says nothing about whether anyone ELSE has that exact file. A player's own
--- "Save Configuration" preset (from the tuning UI) is just as real a .pc as a factory config,
--- purely local to their own profile, never bundled or distributed anywhere. The pool mode
--- vehicle restriction (a joining participant PICKS a config from the native selector, so it has
--- to actually exist for them) needs to tell these apart, or a host could add a personal preset
--- that's silently invisible to everyone else. Same signal the installed game's own vehicle
--- selector already uses to classify a config's "Source" as Custom vs BeamNG-Official/Mod (see
--- core/vehicles.lua : every config gets an `infoFilename` if (and only if) it ships an
--- `info_<name>.json` sidecar alongside the .pc: a personal save never does, since it's a raw
--- dump with no such metadata file).
---@param model string
---@param configKey string
---@return boolean true if this config ships with the base game or a mod (guaranteed present for
---anyone who has the model) ; false if it's a personal, local-only save
local function isConfigShareable(model, configKey)
    local modelData = core_vehicles.getModel(model)
    local config = modelData and modelData.configs and modelData.configs[configKey]
    return config ~= nil and config.infoFilename ~= nil
end

---@param mpVeh BJVehicle
---@return boolean
local function isPolice(mpVeh)
    local policeMarkers = Table({ "police", "polizei", "polizia", "gendarmerie" })
    local conf = M.getFullConfig(mpVeh.veh)
    if not conf then return false end
    return policeMarkers:any(function(str) return conf.model:lower():find(str) ~= nil end) or
        Table(conf.parts):any(function(v, k)
            return policeMarkers:any(function(str)
                return (tostring(k):lower():find(str) ~= nil and #v > 0) or
                    tostring(v):lower():find(str) ~= nil
            end)
        end)
end

---@param veh NGVehicle
---@return NGPaint[]
local function getAllPaints(veh)
    local model = M.getAllVehicleConfigs(nil,
        {
            cars = true,
            trucks = true,
            trailers = true,
            props = true,
            traffic = true
        })[veh.jbeam]
    return model and model.paints or {}
end

---@param veh NGVehicle
---@param paintData NGPaint[] max 3 indices
local function paint(veh, paintData)
    for i = 1, 3 do
        if paintData[i] then
            extensions.core_vehicle_manager.liveUpdateVehicleColors(
                veh:getID(), veh, i, paintData[i])
        end
    end
end

M.onInit = onInit
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onSlowUpdate = onSlowUpdate
M.onServerTick = onServerTick
M.onVehicleResetted = onVehicleResetted
M.onBJRequestCanSpawnVehicle = onBJRequestCanSpawnVehicle
M.onBJVehicleModChanged = onBJVehicleModChanged

M.getVehicle = getVehicle
M.getType = getType
M.getVehicleByRemoteID = getVehicleByRemoteID
M.getVehiclePositionRotation = getVehiclePositionRotation
M.setVehiclePositionRotation = setVehiclePositionRotation
M.getAllVehicleConfigs = getAllVehicleConfigs
M.getAllVehicleLabels = getAllVehicleLabels
M.getModelLabel = getModelLabel
M.getConfigLabel = getConfigLabel
M.getCurrentConfigDisplayLabel = getCurrentConfigDisplayLabel
M.getCurrentConfigIdentity = getCurrentConfigIdentity
M.isConfigShareable = isConfigShareable
M.getCurrent = getCurrent
M.getCurrentOwn = getCurrentOwn
M.getCurrentModel = getCurrentModel
M.delete = delete
M.deleteCurrentOthersVehicle = deleteCurrentOthersVehicle
M.deleteCurrentOwnVehicle = deleteCurrentOwnVehicle
M.deleteOtherOwnVehicles = deleteOtherOwnVehicles
M.setFreeze = setFreeze
M.setEngine = setEngine
M.setLights = setLights
M.focusVehicle = focusVehicle
M.getLabelByModel = getLabelByModel
M.waitForSpawn = waitForSpawn
M.updateVehAttribute = updateVehAttribute
M.explode = explode
M.launch = launch
M.switchToNextVehicle = switchToNextVehicle
M.setGhost = setGhost
M.setGhostReason = setGhostReason
M.applyRespawnProtection = applyRespawnProtection
M.computeDisplayAlpha = computeDisplayAlpha
M.setSoloGhostVisualReversed = setSoloGhostVisualReversed
M.getAttachedTrailers = getAttachedTrailers
M.getFullConfig = getFullConfig
M.isPolice = isPolice
M.getAllPaints = getAllPaints
M.paint = paint

return M
