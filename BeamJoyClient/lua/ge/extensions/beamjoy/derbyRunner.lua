--- Live derby runtime : follows the session pushed by services/derbyGrid.lua and runs everything a
--- derby needs on the local car, the same shape as infectedRunner.lua (countdown lock, spawn,
--- restrictions, results) plus :
---   - wreck detection : the engine is destroyed, the car hasn't moved for the arena's stuck time
---     (pinned or not : two wrecks resting against each other are still wrecks), or it stayed out
---     of the arena zone / fell below its floor
---   - credit : whoever touched the car last (BeamNG's own per-vehicle collision list,
---     map.objects[vid].objectCollisions) gets the wreck, if that touch came at most
---     CREDIT_WINDOW_MS before the car started going down (stopped moving, left the zone, lost its
---     engine) : a hit that leaves you stuck is credited once the stuck time runs out. The damage
---     the car takes while touching someone is reported as their damage dealt
---   - respawns : a car with a life left (or any car in timed mode) comes back repaired at the free
---     start position furthest from the other cars, ghosted for a few seconds
---   - the arena zone (a circle or a rectangle, optional except for sumo) keeps cars in the arena
---     in every mode : outside it for the grace time, or below its floor, is a wreck. In sumo it
---     shrinks in steps toward its centre
---   - resets : a deliberate reset is a wreck you did to yourself (costs a life ; in timed mode it's
---     a wreck against you), only while nearly stopped. With no life left a reset does nothing and
---     the HUD offers Forfeit instead ; in timed mode Forfeit is always there (no lives to run out)
--- Everything is self-reported, the same accepted trust model as Infected's tags.

local CAMERA_RELEASE_SECONDS = 3
-- a reset only while nearly stopped (m/s), same gate as Infected : it can't be used to escape a hit
local RESET_MAX_SPEED = 2
-- the last car to touch you within this long gets the credit
local CREDIT_WINDOW_MS = 5000
-- damage taken this soon after a touch still counts as that player's damage dealt
local DAMAGE_WINDOW_MS = 600
-- moving further than this (m) restarts the stuck clock
local STUCK_MOVE_DIST = 2
-- the stuck bar shows once this much of the stuck time has run
local STUCK_WARN_SHARE = .25
-- a destroyed engine counts once it's been dead this long (a restart attempt, a glitch)
local ENGINE_CONFIRM_MS = 1500
local ENGINE_POLL_MS = 1000
local DAMAGE_SEND_MS = 1000
-- how long each shrink of the sumo zone takes
local SHRINK_ANIM_MS = 3000
-- warm and fairly solid : a pale see-through blue disappeared into map fog
local ZONE_COLOR = BJColor(1, .6, .1, .2)
local ZONE_COLOR_OUT = BJColor(1, .2, .15, .28)
-- bright rails along the zone's edge, at these heights over its centre's ground
local RAIL_COLOR = BJColor(1, .75, .2, .9)
local RAIL_COLOR_OUT = BJColor(1, .3, .25, .95)
local RAIL_HEIGHTS = { .5, 3 }
local RAIL_WIDTH = .35
local CIRCLE_SEGMENTS = 48
-- a player still in the game with no car (it was deleted, or none was ever spawned) is out after this
local NO_CAR_OUT_MS = 10000

local M = {
    dependencies = { "beamjoy_derby", "beamjoy_vehicles", "beamjoy_players", "camera" },

    ---@type table? the session this player is in
    session = nil,
    ---@type table? a session watched without playing
    spectatingSession = nil,
    ---@type table[]
    openSessions = {},

    gameStartTimeMs = nil,
    roundDeadlineTargetMs = nil,
    gridReadyTargetMs = nil,
    gridTimeoutTargetMs = nil,
    spectatingGameStartTimeMs = nil,
    spectatingRoundDeadlineTargetMs = nil,

    -- countdown lock, same technique as infectedRunner.lua
    scenarioLocked = false,
    countdownStartMs = nil,
    countdownTotal = nil,
    lastSentSeconds = nil,
    cameraReleased = false,
    previousCamera = nil,
    spawnQueueForced = false,
    previousSpawnQueueSetting = nil,

    ---@type integer? vid of the local player's own derby car
    myVehicleVid = nil,

    -- wreck detection
    anchorPos = nil,
    ---@type integer? when the car last moved (the stuck clock's start)
    anchorSinceMs = nil,
    ---@type integer? since when a player still in the game has had no car
    noCarSinceMs = nil,
    stuckMs = 0,
    lastStuckCheckMs = nil,
    lastAttackerID = nil,
    lastAttackerMs = 0,
    engineDeadSinceMs = nil,
    lastEnginePollMs = 0,
    zoneOutSinceMs = nil,
    ---@type number? metres from the car to the zone's nearest edge, for the HUD
    zoneEdgeM = nil,
    lastDamage = nil,
    ---@type table<string, number> attacker playerID (as a string key) -> damage not sent yet
    pendingDamage = {},
    lastDamageSendMs = 0,
    ---@type integer? no new wreck until then (the respawn, its ghost time)
    downLockUntilMs = nil,
    eliminatedHandled = false,
    lastFeedSeq = 0,
    ---@type table[] fresh kill-feed lines for the HUD, {text parts, atMs}
    feed = {},

    lastHudPushMs = nil,
    lastDerbyInfoPayload = nil,
}

---@return table?
local function getSelfParticipant()
    if not M.session then return nil end
    local selfName = MPConfig.getNickname()
    return table.find(M.session.participants, function(p) return p.playerName == selfName end)
end

---@param session table?
---@param name string
---@return table?
local function participantByName(session, name)
    if not session then return nil end
    return table.find(session.participants or {}, function(p) return p.playerName == name end)
end

local function flushSpawnQueue()
    pcall(function() MPVehicleGE.applyQueuedEvents() end)
end

---@return boolean
local function isGameLocked()
    return M.session ~= nil and (M.session.state == "COUNTDOWN" or M.session.state == "GAME")
end

---@return boolean still driving in a running game
local function isAlive()
    local p = getSelfParticipant()
    return p ~= nil and M.session.state == "GAME" and not p.eliminated
end

---@return BJVehicle?
local function myCurrentVehicle()
    local own = beamjoy_vehicles.getCurrentOwn()
    if own and (not M.myVehicleVid or own.vid == M.myVehicleVid) then return own end
    return M.myVehicleVid and beamjoy_vehicles.getVehicle(M.myVehicleVid) or own
end

---@return string[]
local function gameBlockedCameras()
    return { camera.CAMERAS.BIG_MAP, camera.CAMERAS.FREE, camera.CAMERAS.CINEMATIC, camera.CAMERAS.STEADYCAM }
end

-- SUMO ZONE ---------------------------------------------------------------------------------------

-- zoneOf runs every frame (the walls) : built once per session update
local zoneCache = { arena = nil, settings = nil, zone = nil }

---@param session table
---@return table? the arena zone in world terms : `shape` "circle" (radius), "rect" or "ellipse"
---(fwd/right unit vectors, halfLength/halfWidth), all at full size around pos, plus the shrink schedule
---(`shrinks` : sumo only ; minScale, stepMs, steps) and floorZ. Every mode keeps cars inside it.
local function zoneOf(session)
    if not session or not session.settings then return nil end
    local arena = session.arenaSnapshot or {}
    local zone = arena.zone
    if not zone or not zone.pos then return nil end
    local s = session.settings
    if zoneCache.arena == arena and zoneCache.settings == s then return zoneCache.zone end
    local z = {
        shape = "circle",
        pos = vec3(zone.pos.x, zone.pos.y, zone.pos.z),
        shrinks = s.mode == "sumo",
        minScale = (s.minRadiusPercent or 25) / 100,
        stepMs = (s.shrinkEverySeconds or 30) * 1000,
        steps = s.shrinkSteps or 6,
        floorZ = zone.pos.z - (arena.floorDepth or 10),
    }
    if (zone.shape == "rect" or zone.shape == "ellipse") and zone.dir and tonumber(zone.width) and tonumber(zone.length) then
        local fwd = vec3(zone.dir.x, zone.dir.y, 0)
        z.shape = zone.shape
        z.fwd = fwd:length() > 1e-4 and fwd:normalized() or vec3(1, 0, 0)
        z.right = vec3(z.fwd.y, -z.fwd.x, 0)
        z.halfWidth = zone.width / 2
        z.halfLength = zone.length / 2
    else
        z.radius = zone.radius or 40
    end
    zoneCache.arena, zoneCache.settings, zoneCache.zone = arena, s, z
    return z
end

---@param z table zoneOf
---@param k integer
---@return number the zone's size (1 = its starting size) once k shrinks are done
local function scaleAfter(z, k)
    k = math.max(0, math.min(z.steps, k))
    return 1 - (1 - z.minScale) * k / z.steps
end

---@param z table zoneOf
---@param elapsed number ms into the game
---@return number scale, integer? msToNextShrink
local function zoneScaleAt(z, elapsed)
    if not z.shrinks then return 1, nil end
    if not elapsed or elapsed <= 0 then return 1, z.stepMs end
    local k = math.floor(elapsed / z.stepMs)
    if k >= 1 then
        local into = elapsed - k * z.stepMs
        local scale = scaleAfter(z, k)
        if into < SHRINK_ANIM_MS and k <= z.steps then
            local from = scaleAfter(z, k - 1)
            scale = from + (scale - from) * (into / SHRINK_ANIM_MS)
        end
        if k >= z.steps then return scale, nil end
        return scale, (k + 1) * z.stepMs - elapsed
    end
    return 1, z.stepMs - elapsed
end

--- how far out `pos` is, as a share of the zone at `scale` (along the line from its centre) : under
--- 1 inside, over 1 outside
---@param z table zoneOf
---@param scale number
---@param pos vec3
---@return number
local function zoneReach(z, scale, pos)
    local d = vec3(pos.x - z.pos.x, pos.y - z.pos.y, 0)
    if z.shape == "rect" then
        return math.max(math.abs(d:dot(z.right)) / (z.halfWidth * scale),
            math.abs(d:dot(z.fwd)) / (z.halfLength * scale))
    elseif z.shape == "ellipse" then
        local u, v = d:dot(z.right) / (z.halfWidth * scale), d:dot(z.fwd) / (z.halfLength * scale)
        return math.sqrt(u * u + v * v)
    end
    return d:length() / (z.radius * scale)
end

--- distance from (px, py) to the edge of the ellipse with semi-axes a (x) and b (y), centred on the
--- origin : the closest edge point is found by a few steps of a trig-free iteration (it converges
--- from inside and outside alike ; three steps are well within a centimetre on arena-sized ovals)
---@param px number
---@param py number
---@param a number
---@param b number
---@return number
local function ellipseEdgeDistance(px, py, a, b)
    local qx, qy = math.abs(px), math.abs(py)
    local tx, ty = 0.70710678, 0.70710678
    for _ = 1, 3 do
        local ex = (a * a - b * b) * tx * tx * tx / a
        local ey = (b * b - a * a) * ty * ty * ty / b
        local rx, ry = a * tx - ex, b * ty - ey
        local sx, sy = qx - ex, qy - ey
        local r = math.sqrt(rx * rx + ry * ry)
        local s = math.sqrt(sx * sx + sy * sy)
        if s < 1e-9 then break end
        tx = math.min(1, math.max(0, (sx * r / s + ex) / a))
        ty = math.min(1, math.max(0, (sy * r / s + ey) / b))
        local t = math.sqrt(tx * tx + ty * ty)
        tx, ty = tx / t, ty / t
    end
    local dx, dy = qx - a * tx, qy - b * ty
    return math.sqrt(dx * dx + dy * dy)
end

--- metres from `pos` to the zone's nearest edge, 0 once outside
---@param z table zoneOf
---@param scale number
---@param pos vec3
---@return number
local function zoneEdgeDistance(z, scale, pos)
    local d = vec3(pos.x - z.pos.x, pos.y - z.pos.y, 0)
    local m
    if z.shape == "rect" then
        m = math.min(z.halfWidth * scale - math.abs(d:dot(z.right)),
            z.halfLength * scale - math.abs(d:dot(z.fwd)))
    elseif z.shape == "ellipse" then
        if zoneReach(z, scale, pos) > 1 then return 0 end
        m = ellipseEdgeDistance(d:dot(z.right), d:dot(z.fwd), z.halfWidth * scale, z.halfLength * scale)
    else
        m = z.radius * scale - d:length()
    end
    return math.max(0, m)
end

---@return number? ms into the game, for whichever session this client follows
local function gameElapsed()
    if M.session and M.gameStartTimeMs then return GetCurrentTimeMillis() - M.gameStartTimeMs end
    if M.spectatingSession and M.spectatingGameStartTimeMs then
        return GetCurrentTimeMillis() - M.spectatingGameStartTimeMs
    end
    return nil
end

-- VEHICLE PRESET ----------------------------------------------------------------------------------

---@param veh NGVehicle
---@param pool {model: string, parts: table}[]
---@return boolean
local function vehicleMatchesPool(veh, pool)
    local full = beamjoy_vehicles.getFullConfig(veh)
    if not full then return false end
    return table.find(pool, function(v)
        return v.model == full.model and v.parts ~= nil and table.deepcompare(full.parts or {}, v.parts)
    end) ~= nil
end

-- true while this file spawns the preset's vehicle itself : the countdown lock below refuses
-- every other spawn, and it refused this one too (the handout failed, leaving the player carless)
local forcingVehicle = false

---@param pool {model: string}[]
---@return table[] the entries whose model is installed on this game
local function installedEntries(pool)
    local configs = beamjoy_vehicles.getAllVehicleConfigs(nil, { trailers = true, props = true })
    return table.filter(pool, function(v) return configs[v.model] ~= nil end)
end

---@param pool {model: string, config: string}[]
---@return boolean ok, "missing"|"failed"? why not
local function forceRandomPoolVehicle(pool)
    local available = installedEntries(pool)
    if #available == 0 then return false, "missing" end
    local entry = available[math.random(#available)]
    local pos
    local currVeh = beamjoy_vehicles.getCurrent()
    if currVeh and camera.getCamera() ~= camera.CAMERAS.FREE then
        pos = beamjoy_vehicles.getVehiclePositionRotation(currVeh.veh)
    else
        pos = camera.getPositionRotation(false)
    end
    if beamjoy_vehicles.getCurrentOwn() then beamjoy_vehicles.deleteCurrentOwnVehicle() end
    forcingVehicle = true
    local ok, newVeh = pcall(core_vehicles.spawnNewVehicle, entry.model, { pos = pos, config = entry.config })
    forcingVehicle = false
    if not ok or not newVeh then return false, "failed" end
    be:enterVehicle(0, newVeh)
    if camera.getCamera() == camera.CAMERAS.FREE then camera.toggleFreeCam() end
    return true
end

---@param req RequestAuthorization
---@param model string
---@param config string?
---@param action ("spawn"|"replace"|"clone")?
local function onBJRequestCanSpawnVehicle(req, model, config, action)
    if not M.session then return end
    local pool = M.session.settings.vehiclePool
    if pool and table.find(pool, function(v) return v.model == model and v.config == config end) == nil then
        req.state = false
        return
    end
    -- from the countdown on, the car you're in is the one you play with (bar the preset's handout)
    if isGameLocked() and not forcingVehicle then req.state = false end
end

-- RESTRICTIONS / RESETS ---------------------------------------------------------------------------

---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    if not M.session then return end
    local participant = getSelfParticipant()
    if not participant then return end

    if M.session.state == "LOBBY" or M.session.state == "GAME" then
        restrictions:addAll({ "toggleWalkingMode", "dropPlayerAtCamera", "dropPlayerAtCameraNoReset" }, true)
    end
    if not isGameLocked() then return end

    restrictions:addAll({
        "nodegrabberAction", "nodegrabberGrab", "nodegrabberRender",
        "nodegrabberStrength", "nodegrabberPadGrab", "nodegrabberPadMode",
        "toggle_slow_motion", "slower_motion", "faster_motion", "pause",
    }, true)
    -- every reset that moves the car somewhere else. reset_physics / recover_vehicle stay open :
    -- onBJRequestCurrentVehicleReset turns them into a deliberate wreck. Out of the game, switching
    -- vehicles is how you watch the others
    if not participant.eliminated then
        restrictions:addAll({
            "recover_vehicle_alt", "recover_to_last_road", "loadHome", "reload_vehicle", "recoverVehicle",
            "switch_next_vehicle", "switch_previous_vehicle",
        }, true)
    end
end

-- forward declarations : the wreck flow and the reset hook call each other's helpers
local goDown

---@param req RequestAuthorization
---@param resetType string
local function onBJRequestCurrentVehicleReset(req, resetType)
    if not M.session then return end
    local participant = getSelfParticipant()
    if not participant then return end
    if M.session.state == "COUNTDOWN" then
        req.state = false
        return
    end
    if M.session.state ~= "GAME" then return end
    -- during the game no reset goes through as such : a deliberate one becomes a wreck
    req.state = false
    if participant.eliminated then return end
    local R = beamjoy_inputs.RESET
    local deliberate = resetType == R.RESET_PHYSICS or resetType == R.RESET_ALL_PHYSICS or
        resetType == R.RECOVER or resetType == R.REPAIR or resetType == R.FLIP_UPRIGHT
    if not deliberate then return end
    if M.session.settings.mode ~= "timed" and (participant.lives or 0) <= 0 then
        toast.warn(beamjoy_lang.translate("beamjoy.derby.noLivesToReset"), nil, 4)
        return
    end
    local veh = myCurrentVehicle()
    if veh and veh.veh:getVelocity():length() > RESET_MAX_SPEED then
        toast.warn(beamjoy_lang.translate("beamjoy.derby.stopToReset"), nil, 3)
        return
    end
    goDown("reset")
end

---@param req RequestAuthorization
---@param kind "refuel"|"repair"|nil
local function onBJRequestStationInteraction(req, kind)
    if isGameLocked() then req.state = false end
end

-- CAMERA / LOCK -----------------------------------------------------------------------------------

local function restorePreviousCamera()
    camera.stopForcedCameras()
    if not M.previousCamera then return end
    if not beamjoy_vehicles.getCurrentOwn() then return end
    local nonVehicleCameras = { camera.CAMERAS.FREE, camera.CAMERAS.BIG_MAP,
        camera.CAMERAS.CINEMATIC, camera.CAMERAS.STEADYCAM }
    local target = table.includes(nonVehicleCameras, M.previousCamera) and camera.CAMERAS.ORBIT or
        M.previousCamera
    camera.setCamera(target)
    camera.resetCamera()
    M.previousCamera = nil
end

local function unlockScenario()
    if not M.scenarioLocked then return end
    M.scenarioLocked = false
    M.cameraReleased = false
    M.countdownStartMs = nil
    restorePreviousCamera()
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh then beamjoy_vehicles.setFreeze(myVeh.vid, false) end
    extensions.hook("onBJScenarioChanged")
end

local function resetDetection()
    M.anchorPos = nil
    M.anchorSinceMs = nil
    M.noCarSinceMs = nil
    M.stuckMs = 0
    M.lastStuckCheckMs = nil
    M.engineDeadSinceMs = nil
    M.zoneOutSinceMs = nil
    M.lastDamage = nil
    M.lastAttackerID = nil
    M.lastAttackerMs = 0
end

---@param vid integer
---@param seconds number
local function ghostFor(vid, seconds)
    beamjoy_vehicles.setGhostReason(vid, "derby", true)
    -- the generic respawn protection is ours to manage here
    beamjoy_vehicles.setGhostReason(vid, "respawn", false)
    local task, forceTask = "BJDerbyGhost-" .. vid, "BJDerbyGhostForce-" .. vid
    async.removeTask(task)
    async.removeTask(forceTask)
    async.delayTask(function()
        beamjoy_vehicles.setGhostReason(vid, "derby", false, false, false)
    end, seconds * 1000, task)
    async.delayTask(function()
        beamjoy_vehicles.setGhostReason(vid, "derby", false, true)
    end, seconds * 1000 + 2000, forceTask)
end

---@return boolean
local function clearGameState()
    local hadSession = M.session ~= nil
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    local vid = M.myVehicleVid or (myVeh and myVeh.vid)
    if vid then
        beamjoy_vehicles.setGhostReason(vid, "derby", false)
        async.removeTask("BJDerbyGhost-" .. vid)
        async.removeTask("BJDerbyGhostForce-" .. vid)
        if M.eliminatedHandled and beamjoy_vehicles.getVehicle(vid, true) then
            beamjoy_vehicles.setEngine(vid, true)
            local v = beamjoy_vehicles.getVehicle(vid, true)
            if v then v.veh:queueLuaCommand("electrics.set_warn_signal(0)") end
        end
    end
    M.session = nil
    M.gameStartTimeMs = nil
    M.roundDeadlineTargetMs = nil
    M.gridReadyTargetMs = nil
    M.gridTimeoutTargetMs = nil
    M.myVehicleVid = nil
    M.pendingDamage = {}
    M.downLockUntilMs = nil
    M.eliminatedHandled = false
    M.lastFeedSeq = 0
    M.feed = {}
    resetDetection()
    async.removeTask("BJDerbySpectateSwitch")
    if M.spawnQueueForced then
        M.spawnQueueForced = false
        settings.setValue("enableSpawnQueue", M.previousSpawnQueueSetting)
        M.previousSpawnQueueSetting = nil
    end
    unlockScenario()
    beamjoy_communications_ui.send("BJDerbyCountdown", { active = false })
    camera.stopForcedCameras()
    camera.unblockCameras()
    return hadSession
end

-- UI PUSHES ---------------------------------------------------------------------------------------

---@param session table
---@return integer alive, integer total
local function aliveCounts(session)
    local alive, total = 0, 0
    for _, p in ipairs(session.participants or {}) do
        total = total + 1
        if not p.eliminated then alive = alive + 1 end
    end
    return alive, total + #(session.departed or {})
end

--- the order right now : standings once FINISHED, a live ranking before that
---@param session table
---@return table[]
local function ranking(session)
    if session.state == "FINISHED" and session.standings then return session.standings end
    local all = {}
    for _, p in ipairs(session.participants or {}) do table.insert(all, p) end
    for _, p in ipairs(session.departed or {}) do table.insert(all, p) end
    local timed = session.settings.mode == "timed"
    table.sort(all, function(a, b)
        if timed then
            if (a.wrecks or 0) ~= (b.wrecks or 0) then return (a.wrecks or 0) > (b.wrecks or 0) end
            if (a.deaths or 0) ~= (b.deaths or 0) then return (a.deaths or 0) < (b.deaths or 0) end
        else
            local aOut, bOut = a.eliminated == true, b.eliminated == true
            if aOut ~= bOut then return not aOut end
            if aOut and (a.eliminatedAtMs or 0) ~= (b.eliminatedAtMs or 0) then
                return (a.eliminatedAtMs or 0) > (b.eliminatedAtMs or 0)
            end
            if (a.lives or 0) ~= (b.lives or 0) then return (a.lives or 0) > (b.lives or 0) end
        end
        if (a.damage or 0) ~= (b.damage or 0) then return (a.damage or 0) > (b.damage or 0) end
        return tostring(a.playerName) < tostring(b.playerName)
    end)
    return table.map(all, function(p, i)
        return {
            place = i,
            displayName = p.displayName or p.playerName,
            wrecks = p.wrecks or 0,
            deaths = p.deaths or 0,
            damage = p.damage or 0,
            lives = p.lives or 0,
            eliminated = p.eliminated == true,
            left = p.left == true,
        }
    end)
end

local function pushSessionStatus()
    local session = M.session
    local participant = getSelfParticipant()
    if not session or not participant then
        return beamjoy_communications_ui.send("BJDerbySessionStatus", nil)
    end
    local arena = session.arenaSnapshot or {}
    beamjoy_communications_ui.send("BJDerbySessionStatus", {
        id = session.id,
        state = session.state,
        participantCount = #session.participants,
        maxParticipants = #(arena.startPositions or {}),
        minParticipants = session.minParticipants,
        participants = table.map(session.participants, function(p)
            return {
                playerName = p.playerName,
                displayName = p.displayName,
                playerID = p.playerID,
                ready = p.ready,
                lives = p.lives,
                wrecks = p.wrecks,
                eliminated = p.eliminated,
            }
        end),
        ready = participant.ready,
        isStarter = session.starterID == participant.playerID,
        starterID = session.starterID,
        arenaName = arena.name,
        settings = {
            mode = session.settings.mode,
            lives = session.settings.lives,
            roundDuration = session.settings.roundDuration,
            stuckSeconds = session.settings.stuckSeconds,
            vehicleLabel = session.settings.vehicleLabel,
        },
        gridReadySecondsLeft = M.gridReadyTargetMs and
            math.max(0, math.ceil((M.gridReadyTargetMs - GetCurrentTimeMillis()) / 1000)) or nil,
        gridTimeoutSecondsLeft = M.gridTimeoutTargetMs and
            math.max(0, math.ceil((M.gridTimeoutTargetMs - GetCurrentTimeMillis()) / 1000)) or nil,
    })
end

local lastGridReadySec, lastGridTimeoutSec = nil, nil
local function updateGridCountdown()
    if not (M.gridReadyTargetMs or M.gridTimeoutTargetMs) then return end
    local readySec = M.gridReadyTargetMs and
        math.max(0, math.ceil((M.gridReadyTargetMs - GetCurrentTimeMillis()) / 1000)) or nil
    local timeoutSec = M.gridTimeoutTargetMs and
        math.max(0, math.ceil((M.gridTimeoutTargetMs - GetCurrentTimeMillis()) / 1000)) or nil
    if readySec ~= lastGridReadySec or timeoutSec ~= lastGridTimeoutSec then
        lastGridReadySec, lastGridTimeoutSec = readySec, timeoutSec
        pushSessionStatus()
    end
end

local function pushOpenSessions()
    beamjoy_communications_ui.send("BJDerbyOpenSessions", M.openSessions or {})
end

---@param list table[]
local function onSessionsList(list)
    local previousIds = table.map(M.openSessions or {}, function(s) return s.id end)
    local selfName = MPConfig.getNickname()
    table.forEach(list or {}, function(s)
        if not table.includes(previousIds, s.id) and s.starterName ~= selfName then
            if beamjoy_notices then beamjoy_notices.announce("derby", s) end
        end
    end)
    M.openSessions = list or {}
    pushOpenSessions()
end

local function pushHud()
    local session = M.session or M.spectatingSession
    if not session or session.state ~= "GAME" then
        return beamjoy_communications_ui.send("BJDerbyHud", { active = false })
    end
    local participant = M.session and getSelfParticipant() or nil
    local alive, total = aliveCounts(session)
    local elapsed = gameElapsed() or session.gameElapsedMs or 0
    local targetMs = M.session and M.roundDeadlineTargetMs or
        (M.spectatingSession and M.spectatingRoundDeadlineTargetMs)
    local now = GetCurrentTimeMillis()
    local hud = {
        active = true,
        mode = session.settings.mode,
        arenaName = (session.arenaSnapshot or {}).name,
        gameElapsedMs = elapsed,
        roundSecondsLeft = targetMs and math.max(0, math.ceil((targetMs - now) / 1000)) or nil,
        alive = alive,
        total = total,
        spectating = participant == nil,
        feed = M.feed,
    }
    if participant then
        hud.lives = participant.lives or 0
        hud.wrecks = participant.wrecks or 0
        hud.deaths = participant.deaths or 0
        hud.damage = participant.damage or 0
        hud.eliminated = participant.eliminated == true
        -- timed has no lives to run out : giving up is always there
        hud.canForfeit = not hud.eliminated and (session.settings.mode == "timed" or hud.lives <= 0)
        local stuckLimit = (session.settings.stuckSeconds or 20) * 1000
        if not hud.eliminated and M.stuckMs >= stuckLimit * STUCK_WARN_SHARE then
            hud.stuckSecondsLeft = math.max(0, math.ceil((stuckLimit - M.stuckMs) / 1000))
            hud.stuckShare = math.min(1, M.stuckMs / stuckLimit)
        end
        if not hud.eliminated and M.engineDeadSinceMs then hud.engineDead = true end
        if not hud.eliminated and M.zoneOutSinceMs then
            hud.zoneOutSecondsLeft = math.max(0,
                math.ceil(((session.settings.zoneGraceSeconds or 3) * 1000 - (now - M.zoneOutSinceMs)) / 1000))
        end
        if not hud.eliminated and M.downLockUntilMs and now < M.downLockUntilMs then
            hud.respawnProtected = true
        end
    end
    local z = zoneOf(session)
    if z then
        local scale, nextMs = zoneScaleAt(z, elapsed)
        hud.zoneSizePct = z.shrinks and math.floor(scale * 100 + .5) or nil
        -- a player still in sees how close the edge is, everyone else how big the zone still is
        if participant and not hud.eliminated and M.zoneEdgeM then
            hud.zoneEdge = math.floor(M.zoneEdgeM)
        end
        hud.zoneNextShrinkSec = nextMs and math.max(0, math.ceil(nextMs / 1000)) or nil
    end
    beamjoy_communications_ui.send("BJDerbyHud", hud)
end

local function pushDerbyInfo()
    local session = M.session or M.spectatingSession
    if not session then
        if M.lastDerbyInfoPayload then
            beamjoy_communications_ui.send("BJDerbyInfo", M.lastDerbyInfoPayload)
        end
        return
    end
    if session.state == "LOBBY" or session.state == "COUNTDOWN" then
        M.lastDerbyInfoPayload = nil
        return beamjoy_communications_ui.send("BJDerbyInfo", { active = false })
    end
    local payload = {
        active = true,
        state = session.state,
        mode = session.settings.mode,
        arenaName = (session.arenaSnapshot or {}).name,
        durationMs = session.gameElapsedMs,
        standings = ranking(session),
    }
    if M.session then M.lastDerbyInfoPayload = payload end
    beamjoy_communications_ui.send("BJDerbyInfo", payload)
end

local function pushCountdown()
    if not M.session or M.session.state ~= "COUNTDOWN" then return end
    if M.countdownStartMs and M.lastSentSeconds ~= nil then
        beamjoy_communications_ui.send("BJDerbyCountdown", { active = true, seconds = M.lastSentSeconds })
    end
end

-- KILL FEED ---------------------------------------------------------------------------------------

--- new lines of the session's feed go to the HUD (which fades them), and the ones about you get a
--- short message in the middle of the screen
---@param session table
local function consumeFeed(session)
    local selfName = MPConfig.getNickname()
    local selfP = participantByName(session, selfName)
    local selfShown = selfP and (selfP.displayName or selfP.playerName) or selfName
    for _, entry in ipairs(session.feed or {}) do
        if (entry.seq or 0) > M.lastFeedSeq then
            M.lastFeedSeq = entry.seq
            table.insert(M.feed, {
                seq = entry.seq,
                attacker = entry.attacker,
                victim = entry.victim,
                reason = entry.reason,
                out = entry.out,
                you = entry.attacker == selfShown or entry.victim == selfShown,
                atMs = GetCurrentTimeMillis(),
            })
            if entry.attacker and entry.attacker == selfShown then
                beamjoy_communications_ui.uiBroadcast(beamjoy_lang.translate("beamjoy.derby.youWrecked")
                    :var({ name = entry.victim }), nil, "orange", 3)
            end
        end
    end
    while #M.feed > 5 do table.remove(M.feed, 1) end
end

local function pruneFeed()
    local now = GetCurrentTimeMillis()
    local changed = false
    for i = #M.feed, 1, -1 do
        if now - M.feed[i].atMs > 8000 then
            table.remove(M.feed, i)
            changed = true
        end
    end
    return changed
end

-- WRECK / RESPAWN / ELIMINATION ---------------------------------------------------------------------

--- the free start position furthest from every other car still playing
---@return table? {pos, dir}
local function farthestStart()
    local arena = M.session and M.session.arenaSnapshot or {}
    local starts = arena.startPositions or {}
    if #starts == 0 then return nil end
    local selfName = MPConfig.getNickname()
    local others = {}
    beamjoy_vehicles.vehicles:forEach(function(v)
        if v.ownerName ~= selfName and not v.isAi then
            local p = participantByName(M.session, v.ownerName)
            if p and not p.eliminated then
                local fresh = beamjoy_vehicles.getVehicle(v.vid)
                if fresh and fresh.position then table.insert(others, fresh.position) end
            end
        end
    end)
    local best, bestDist
    for _, s in ipairs(starts) do
        local pos = vec3(s.pos.x, s.pos.y, s.pos.z)
        local nearest = math.huge
        for _, o in ipairs(others) do nearest = math.min(nearest, (o - pos):length()) end
        if not bestDist or nearest > bestDist then best, bestDist = s, nearest end
    end
    return best
end

local function respawn()
    local veh = myCurrentVehicle()
    local spot = farthestStart()
    if not veh or not spot then return end
    local pos = vec3(spot.pos.x, spot.pos.y, spot.pos.z)
    local dir = vec3(spot.dir.x, spot.dir.y, spot.dir.z)
    local cling = false
    -- sumo : a start position the zone has already shrunk past would put you straight out, so
    -- the car comes back on the same side, well inside the zone, facing its centre
    local z = zoneOf(M.session)
    if z then
        local reach = zoneReach(z, zoneScaleAt(z, gameElapsed() or 0), pos)
        if reach > .8 then
            local flat = vec3(pos.x - z.pos.x, pos.y - z.pos.y, 0)
            -- same line from the centre, 60% of the way out to the edge
            pos = vec3(z.pos.x, z.pos.y, z.pos.z) + flat * (.6 / reach)
            dir = flat:normalized() * -1
            cling = true
        end
    end
    -- a teleport resets the car : repaired, the way a respawn should be
    beamjoy_vehicles.setVehiclePositionRotation(veh.veh, pos, dir, vec3(0, 0, 1), { cling = cling })
    ghostFor(veh.vid, M.session.settings.respawnGhostSeconds or 3)
    camera.setCamera(camera.getCamera(), false)
end

--- watching someone still playing (a random one), once you're out
local function spectateSomeone()
    if not M.session then return end
    local selfName = MPConfig.getNickname()
    local candidates = {}
    beamjoy_vehicles.vehicles:forEach(function(v)
        if v.ownerName ~= selfName and not v.isAi then
            local p = participantByName(M.session, v.ownerName)
            if p and not p.eliminated then table.insert(candidates, v.vid) end
        end
    end)
    if #candidates > 0 then beamjoy_vehicles.focusVehicle(candidates[math.random(#candidates)]) end
end

--- you're out : the car stays in the arena as a wreck (engine off, hazards on) and you watch
local function eliminateSelf()
    if M.eliminatedHandled then return end
    M.eliminatedHandled = true
    resetDetection()
    local veh = myCurrentVehicle()
    if veh then
        beamjoy_vehicles.setEngine(veh.vid, false)
        veh.veh:queueLuaCommand("electrics.set_warn_signal(1)")
    end
    beamjoy_communications_ui.uiBroadcast(beamjoy_lang.translate("beamjoy.derby.youAreOut"), nil, "red", 4)
    camera.unblockCameras()
    extensions.beamjoy_restrictions.update()
    async.delayTask(spectateSomeone, 3000, "BJDerbySpectateSwitch")
end

--- the local car is down : report it (credit to whoever touched it last), then respawn or go out
---@param reason string
goDown = function(reason)
    local participant = getSelfParticipant()
    if not participant or M.session.state ~= "GAME" or participant.eliminated or M.eliminatedHandled then return end
    local now = GetCurrentTimeMillis()
    if reason ~= "forfeit" and M.downLockUntilMs and now < M.downLockUntilMs then return end
    -- when this started coming : a hit that leaves the car stuck (or pushed out, or its engine
    -- dying) is credited once the stuck / grace time runs out, not only within seconds of the hit
    local since = ({ stuck = M.anchorSinceMs, engine = M.engineDeadSinceMs, zone = M.zoneOutSinceMs })[reason] or now
    local attacker = M.lastAttackerID and M.lastAttackerMs >= since - CREDIT_WINDOW_MS and M.lastAttackerID or nil
    if reason == "reset" or reason == "forfeit" then attacker = nil end
    beamjoy_communications.send("derbyWrecked", M.session.id, reason, attacker)

    local mode = M.session.settings.mode
    local respawns = reason ~= "forfeit" and (mode == "timed" or (participant.lives or 0) > 0)
    if respawns then
        M.downLockUntilMs = now + ((M.session.settings.respawnGhostSeconds or 3) + 2) * 1000
        -- the server takes the life when it hears about it ; the HUD shows it right away
        if mode ~= "timed" then participant.lives = math.max(0, (participant.lives or 0) - 1) end
        resetDetection()
        respawn()
        local key = mode == "timed" and "beamjoy.derby.respawned" or
            (participant.lives == 0 and "beamjoy.derby.lastLife" or "beamjoy.derby.livesLeft")
        beamjoy_communications_ui.uiBroadcast(beamjoy_lang.translate(key):var({ lives = participant.lives }),
            nil, "orange", 3)
    else
        participant.eliminated = true
        eliminateSelf()
    end
    pushHud()
end

local function forfeit()
    if isAlive() then goDown("forfeit") end
end

--- engine state, answered by the vehicle's own Lua (see pollEngine)
---@param vid integer
---@param dead boolean
local function onEngineState(vid, dead)
    if vid ~= M.myVehicleVid or not isAlive() then return end
    if dead then
        M.engineDeadSinceMs = M.engineDeadSinceMs or GetCurrentTimeMillis()
    else
        M.engineDeadSinceMs = nil
    end
end

local ENGINE_POLL_CMD = [[
local dead = false
local devices = powertrain and powertrain.getDevicesByCategory and powertrain.getDevicesByCategory("engine") or {}
local count = 0
for _, d in pairs(devices) do
    count = count + 1
    if d.isDisabled then dead = true end
end
obj:queueGameEngineLua("beamjoy_derbyRunner.onEngineState(%d, " .. tostring(count > 0 and dead) .. ")")
]]

local function pollEngine(veh)
    veh.veh:queueLuaCommand(string.format(ENGINE_POLL_CMD, veh.vid))
end

--- every frame : who's touching the car, and the damage it takes while they are
local function updateContacts()
    if not isAlive() then return end
    local veh = myCurrentVehicle()
    if not veh then return end
    M.myVehicleVid = M.myVehicleVid or veh.vid
    local data = map and map.objects and map.objects[veh.vid]
    if not data then return end
    local now = GetCurrentTimeMillis()
    for otherVid in pairs(data.objectCollisions or {}) do
        local other = beamjoy_vehicles.vehicles[otherVid]
        if other and not other.isAi then
            local p = participantByName(M.session, other.ownerName)
            if p and not p.eliminated and p.playerName ~= MPConfig.getNickname() then
                M.lastAttackerID = p.playerID
                M.lastAttackerMs = now
            end
        end
    end
    local damage = tonumber(data.damage)
    if damage then
        if M.lastDamage and damage > M.lastDamage and M.lastAttackerID and
            now - M.lastAttackerMs <= DAMAGE_WINDOW_MS then
            local key = tostring(M.lastAttackerID)
            M.pendingDamage[key] = (M.pendingDamage[key] or 0) + (damage - M.lastDamage)
        end
        M.lastDamage = damage
    end
end

local function sendDamage()
    if not M.session or M.session.state ~= "GAME" or next(M.pendingDamage) == nil then return end
    local now = GetCurrentTimeMillis()
    if now - M.lastDamageSendMs < DAMAGE_SEND_MS then return end
    M.lastDamageSendMs = now
    local batch = {}
    for k, v in pairs(M.pendingDamage) do batch[k] = math.floor(v) end
    M.pendingDamage = {}
    beamjoy_communications.send("derbyDamage", M.session.id, batch)
end

--- the slow checks : stuck, engine, sumo zone
local function updateWreckChecks()
    M.zoneEdgeM = nil
    if not isAlive() then return end
    local now = GetCurrentTimeMillis()
    -- no car at all : nothing to wreck, so the game would wait on this player forever
    local veh = myCurrentVehicle()
    if not veh or veh.veh.jbeam == beamjoy_vehicles.WALKING then
        M.noCarSinceMs = M.noCarSinceMs or now
        if now - M.noCarSinceMs >= NO_CAR_OUT_MS then
            M.noCarSinceMs = nil
            toast.warn(beamjoy_lang.translate("beamjoy.derby.noVehicleOut"), nil, 6)
            return goDown("forfeit")
        end
        return
    end
    M.noCarSinceMs = nil
    local protected = M.downLockUntilMs and now < M.downLockUntilMs
    local fresh = beamjoy_vehicles.getVehicle(veh.vid)
    local pos = fresh and fresh.position
    if not pos then return end

    -- stuck : not moved STUCK_MOVE_DIST for stuckSeconds. Contact doesn't pause it any more : two
    -- wrecks resting against each other kept pausing each other's clock forever, and being pinned
    -- that long is the pinner's wreck
    local dt = M.lastStuckCheckMs and (now - M.lastStuckCheckMs) or 0
    M.lastStuckCheckMs = now
    if protected or not M.anchorPos or pos:distance(M.anchorPos) > STUCK_MOVE_DIST then
        M.anchorPos = pos
        M.anchorSinceMs = now
        M.stuckMs = 0
    else
        M.stuckMs = M.stuckMs + dt
    end
    if M.stuckMs >= (M.session.settings.stuckSeconds or 20) * 1000 then
        return goDown("stuck")
    end

    -- engine
    if now - M.lastEnginePollMs >= ENGINE_POLL_MS then
        M.lastEnginePollMs = now
        pollEngine(veh)
    end
    if not protected and M.engineDeadSinceMs and now - M.engineDeadSinceMs >= ENGINE_CONFIRM_MS then
        return goDown("engine")
    end

    -- arena zone
    local z = zoneOf(M.session)
    local scale = z and zoneScaleAt(z, gameElapsed() or 0)
    M.zoneEdgeM = z and zoneEdgeDistance(z, scale, pos) or nil
    if z and not protected then
        if pos.z < z.floorZ then return goDown("fell") end
        if zoneReach(z, scale, pos) > 1 then
            M.zoneOutSinceMs = M.zoneOutSinceMs or now
            if now - M.zoneOutSinceMs >= (M.session.settings.zoneGraceSeconds or 3) * 1000 then
                return goDown("zone")
            end
        else
            M.zoneOutSinceMs = nil
        end
    else
        M.zoneOutSinceMs = nil
    end
end

--- the zone's outline at full size, as flat offsets from its centre (cached on the zone)
---@param z table zoneOf
---@return vec3[]
local function outlineOffsets(z)
    if z.outline then return z.outline end
    local pts = {}
    if z.shape == "rect" then
        local f, r = z.fwd * z.halfLength, z.right * z.halfWidth
        pts = { r + f, f - r, (r + f) * -1, r - f }
    elseif z.shape == "ellipse" then
        for i = 1, CIRCLE_SEGMENTS do
            local a = 2 * math.pi * i / CIRCLE_SEGMENTS
            pts[i] = z.fwd * (math.cos(a) * z.halfLength) + z.right * (math.sin(a) * z.halfWidth)
        end
    else
        for i = 1, CIRCLE_SEGMENTS do
            local a = 2 * math.pi * i / CIRCLE_SEGMENTS
            pts[i] = vec3(math.cos(a) * z.radius, math.sin(a) * z.radius, 0)
        end
    end
    z.outline = pts
    return pts
end

local function renderZone()
    local session = M.session or M.spectatingSession
    if not session or (session.state ~= "GAME" and session.state ~= "COUNTDOWN") then return end
    local z = zoneOf(session)
    if not z then return end
    local scale = zoneScaleAt(z, session.state == "GAME" and (gameElapsed() or 0) or 0)
    local out = M.zoneOutSinceMs ~= nil
    local wall = out and ZONE_COLOR_OUT or ZONE_COLOR
    local rail = out and RAIL_COLOR_OUT or RAIL_COLOR
    local bottom, top = z.floorZ, z.pos.z + 40
    local pts = {}
    for i, o in ipairs(outlineOffsets(z)) do
        pts[i] = vec3(z.pos.x + o.x * scale, z.pos.y + o.y * scale, 0)
    end
    if z.shape == "circle" then
        shape.Cylinder(vec3(z.pos.x, z.pos.y, bottom), vec3(z.pos.x, z.pos.y, top), z.radius * scale, wall)
    else
        -- the game has no rectangle or ellipse wall : one see-through panel per outline segment
        -- (4, or CIRCLE_SEGMENTS round an ellipse), each drawn facing both ways (a triangle only
        -- shows from its front) so they're there from inside the zone and from outside it
        local packed = color(wall.r * 255, wall.g * 255, wall.b * 255, wall.a * 255)
        for i = 1, #pts do
            local a, b = pts[i], pts[i % #pts + 1]
            local a0, b0 = vec3(a.x, a.y, bottom), vec3(b.x, b.y, bottom)
            local a1, b1 = vec3(a.x, a.y, top), vec3(b.x, b.y, top)
            debugDrawer:drawTriSolid(a0, b0, b1, packed)
            debugDrawer:drawTriSolid(a0, b1, a1, packed)
            debugDrawer:drawTriSolid(b1, b0, a0, packed)
            debugDrawer:drawTriSolid(a1, b1, a0, packed)
        end
    end
    -- solid rails along the edge : the see-through wall alone fades into the map's fog
    local railCol = ColorF(rail.r, rail.g, rail.b, rail.a)
    local size = Point2F(RAIL_WIDTH, RAIL_WIDTH)
    for _, h in ipairs(RAIL_HEIGHTS) do
        local height = z.pos.z + h
        for i = 1, #pts do
            local a, b = pts[i], pts[i % #pts + 1]
            debugDrawer:drawSquarePrism(vec3(a.x, a.y, height), vec3(b.x, b.y, height), size, size, railCol, true)
        end
    end
end

-- SESSION UPDATES ---------------------------------------------------------------------------------

---@param session table
local function onSessionUpdate(session)
    local wasInSession = M.session ~= nil
    local wasCountdown = M.session ~= nil and M.session.state == "COUNTDOWN"
    local wasGame = M.session ~= nil and M.session.state == "GAME"
    local wasFinished = M.session ~= nil and M.session.state == "FINISHED"
    M.session = session

    local inLobby = session.state == "LOBBY" and session.joinable
    M.gridReadyTargetMs = inLobby and session.gridReadySecondsLeft ~= nil and
        GetCurrentTimeMillis() + session.gridReadySecondsLeft * 1000 or nil
    M.gridTimeoutTargetMs = inLobby and session.gridTimeoutSecondsLeft ~= nil and
        GetCurrentTimeMillis() + session.gridTimeoutSecondsLeft * 1000 or nil
    M.roundDeadlineTargetMs = session.state == "GAME" and session.roundSecondsLeft ~= nil and
        GetCurrentTimeMillis() + session.roundSecondsLeft * 1000 or nil
    if session.state == "GAME" and session.gameElapsedMs ~= nil then
        M.gameStartTimeMs = GetCurrentTimeMillis() - session.gameElapsedMs
    end

    local participant = getSelfParticipant()
    if not participant then
        clearGameState()
        extensions.hook("onBJScenarioChanged")
        pushHud()
        pushSessionStatus()
        pushDerbyInfo()
        return
    end
    pushSessionStatus()

    -- a vehicle preset : with random vehicles you're given one at the countdown, otherwise you
    -- pick one now (the selector only lists the preset's vehicles, see onBJRequestCanSpawnVehicle)
    local pool = session.settings.vehiclePool
    if session.state == "LOBBY" and not wasInSession and pool then
        local label = session.settings.vehicleLabel or ""
        local cur = beamjoy_vehicles.getCurrentOwn()
        local matches = cur ~= nil and cur.veh.jbeam ~= beamjoy_vehicles.WALKING and vehicleMatchesPool(cur.veh, pool)
        if #installedEntries(pool) == 0 then
            toast.warn(beamjoy_lang.translate("beamjoy.derby.presetMissing"), nil, 8)
        elseif session.settings.randomizeVehiclePool then
            toast.info(beamjoy_lang.translate("beamjoy.derby.presetNotice"):var({ label = label }), nil, 6)
        elseif not matches then
            toast.info(beamjoy_lang.translate("beamjoy.derby.pickPreset"):var({ label = label }), nil, 6)
            -- pause.vehicleSelector : see hunterRunner.lua's lobby steering for why not the
            -- freeroam route
            extensions.ui_vehicleSelector_general.openFromPause("pause.vehicleSelector")
        end
    end

    if session.state == "COUNTDOWN" and not wasCountdown then
        if not M.spawnQueueForced then
            M.spawnQueueForced = true
            M.previousSpawnQueueSetting = settings.getValue("enableSpawnQueue") == true
            settings.setValue("enableSpawnQueue", true)
        end
        flushSpawnQueue()
        beamjoy_communications_ui.closeWindow("config")
        if beamjoy_ui_activityEditor then beamjoy_ui_activityEditor.onClose() end

        if pool then
            local cur = beamjoy_vehicles.getCurrentOwn()
            local matches = cur ~= nil and cur.veh.jbeam ~= beamjoy_vehicles.WALKING and vehicleMatchesPool(cur.veh, pool)
            if session.settings.randomizeVehiclePool or not matches then
                local given, why = forceRandomPoolVehicle(pool)
                if given then
                    toast.info(beamjoy_lang.translate("beamjoy.derby.givenVehicle")
                        :var({ label = session.settings.vehicleLabel or "" }), nil, 6)
                else
                    toast.warn(beamjoy_lang.translate(why == "missing" and "beamjoy.derby.presetMissing"
                        or "beamjoy.derby.presetSpawnFailed"), nil, 8)
                end
            end
        end

        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh then
            M.myVehicleVid = myVeh.vid
            if participant.spawnPos then
                beamjoy_vehicles.setVehiclePositionRotation(myVeh.veh,
                    vec3(participant.spawnPos.x, participant.spawnPos.y, participant.spawnPos.z),
                    vec3(participant.spawnDir.x, participant.spawnDir.y, participant.spawnDir.z),
                    vec3(0, 0, 1), { cling = false })
            end
            beamjoy_vehicles.setGhostReason(myVeh.vid, "derby", true)
        end
        M.scenarioLocked = true
        M.cameraReleased = false
        M.countdownStartMs = GetCurrentTimeMillis()
        M.countdownTotal = session.settings.countdown
        M.lastSentSeconds = nil
        M.previousCamera = camera.getCamera()
        if myVeh then
            camera.setCamera(camera.CAMERAS.EXTERNAL)
            camera.blockCameras(table.unpack(gameBlockedCameras()))
            beamjoy_vehicles.setFreeze(myVeh.vid, true)
        end
        extensions.hook("onBJScenarioChanged")
    end

    if session.state == "GAME" and not wasGame then
        unlockScenario()
        beamjoy_communications_ui.send("BJDerbyCountdown", { active = false })
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        if myVeh then
            M.myVehicleVid = M.myVehicleVid or myVeh.vid
            beamjoy_vehicles.setFreeze(myVeh.vid, false)
            -- everyone lets go of their ghost together : distance-safe, then forced
            ghostFor(myVeh.vid, 0)
        end
        resetDetection()
        M.gameStartTimeMs = GetCurrentTimeMillis() - (session.gameElapsedMs or 0)
        M.lastFeedSeq = session.feedSeq or 0
        beamjoy_communications_ui.uiBroadcast("beamjoy.derby.started", nil, "green", 3)
        extensions.beamjoy_restrictions.update()
    end

    if session.state == "GAME" then
        consumeFeed(session)
        if participant.eliminated and not M.eliminatedHandled then
            eliminateSelf()
        elseif not participant.eliminated and beamjoy_vehicles.getCurrentOwn() then
            camera.blockCameras(table.unpack(gameBlockedCameras()))
        end
    end

    if session.state == "FINISHED" then
        consumeFeed(session)
        unlockScenario()
        camera.unblockCameras()
        local vid = M.myVehicleVid
        if vid then
            beamjoy_vehicles.setGhostReason(vid, "derby", false)
            if M.eliminatedHandled then
                beamjoy_vehicles.setEngine(vid, true)
                local v = beamjoy_vehicles.getVehicle(vid, true)
                if v then v.veh:queueLuaCommand("electrics.set_warn_signal(0)") end
            end
        end
        if not wasFinished then
            -- back in your own car if you were watching someone else's
            async.removeTask("BJDerbySpectateSwitch")
            if M.eliminatedHandled and vid and beamjoy_vehicles.getVehicle(vid, true) then
                beamjoy_vehicles.focusVehicle(vid)
            end
            local winner = session.standings and session.standings[1]
            beamjoy_communications_ui.send("BJDerbyCountdown", {
                active = true,
                finished = true,
                winnerName = winner and winner.displayName or nil,
            })
            async.delayTask(function()
                beamjoy_communications_ui.send("BJDerbyCountdown", { active = false })
            end, 8000, "BJDerbyFinishedPopupHide")
            beamjoy_communications_ui.send("BJDerbyInfoAutoOpen", {})
            if beamjoy_notices then
                beamjoy_notices.results("derby", session.id, winner and winner.displayName or nil,
                    (session.arenaSnapshot or {}).name)
            end
        end
        extensions.beamjoy_restrictions.update()
    end

    pushHud()
    pushDerbyInfo()
end

---@param sessionId string
local function onSessionRemoved(sessionId)
    if not M.session or M.session.id ~= sessionId then return end
    clearGameState()
    extensions.hook("onBJScenarioChanged")
    pushHud()
    pushSessionStatus()
end

---@param session table
local function onSpectateUpdate(session)
    M.spectatingSession = session
    M.spectatingGameStartTimeMs = session.state == "GAME" and session.gameElapsedMs ~= nil and
        GetCurrentTimeMillis() - session.gameElapsedMs or nil
    M.spectatingRoundDeadlineTargetMs = session.state == "GAME" and session.roundSecondsLeft ~= nil and
        GetCurrentTimeMillis() + session.roundSecondsLeft * 1000 or nil
    pushHud()
end

---@param sessionId string
local function onSpectateRemoved(sessionId)
    if M.spectatingSession and M.spectatingSession.id == sessionId then
        M.spectatingSession = nil
        M.spectatingGameStartTimeMs = nil
        M.spectatingRoundDeadlineTargetMs = nil
        pushHud()
    end
end

local function updateCountdown()
    if not M.scenarioLocked or not M.countdownStartMs or not M.countdownTotal then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh and myVeh.veh.froze ~= "1" then beamjoy_vehicles.setFreeze(myVeh.vid, true) end
    local elapsedSec = (GetCurrentTimeMillis() - M.countdownStartMs) / 1000
    local remaining = math.max(0, math.ceil(M.countdownTotal - elapsedSec))
    if remaining ~= M.lastSentSeconds then
        M.lastSentSeconds = remaining
        beamjoy_communications_ui.send("BJDerbyCountdown", { active = true, seconds = remaining })
    end
    if not M.cameraReleased and remaining <= CAMERA_RELEASE_SECONDS then
        M.cameraReleased = true
        if camera.getCamera() == camera.CAMERAS.EXTERNAL then restorePreviousCamera() end
        extensions.hook("onBJScenarioChanged")
    end
end

-- VEHICLE HOOKS -----------------------------------------------------------------------------------

---@param vid integer
local function onVehicleResetted(vid)
    if not M.session or M.session.state ~= "GAME" then return end
    if vid ~= M.myVehicleVid then return end
    -- the respawn manages its own ghost ; the generic respawn protection would outlast it
    beamjoy_vehicles.setGhostReason(vid, "respawn", false)
    M.lastDamage = nil
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    if not M.session then return end
    local participant = getSelfParticipant()
    if not participant then return end
    local mpVeh = beamjoy_vehicles.getVehicle(vid, true)
    if not mpVeh or not mpVeh.isLocal then return end

    if M.session.state == "GAME" then
        M.myVehicleVid = vid
        camera.blockCameras(table.unpack(gameBlockedCameras()))
        camera.resetCamera()
        return
    end
    if M.session.state ~= "COUNTDOWN" then return end
    M.myVehicleVid = vid
    if participant.spawnPos then
        beamjoy_vehicles.setVehiclePositionRotation(mpVeh.veh,
            vec3(participant.spawnPos.x, participant.spawnPos.y, participant.spawnPos.z),
            vec3(participant.spawnDir.x, participant.spawnDir.y, participant.spawnDir.z),
            vec3(0, 0, 1), { cling = false })
    end
    beamjoy_vehicles.setFreeze(vid, true)
    beamjoy_vehicles.setGhostReason(vid, "derby", true)
    beamjoy_vehicles.setGhostReason(vid, "respawn", false)
    if M.scenarioLocked then
        camera.setCamera(camera.CAMERAS.EXTERNAL)
        camera.blockCameras(table.unpack(gameBlockedCameras()))
    end
end

--- a derby player's nametag : greyed once they're out
---@param mpVeh BJVehicle
---@return boolean isOut, BJColor? textColor, BJColor? bgColor
local function derbyNametagColor(mpVeh)
    local session = M.session or M.spectatingSession
    if not session or session.state ~= "GAME" then return false end
    local p = participantByName(session, mpVeh.ownerName)
    if not p or not p.eliminated then return false end
    return true, BJColor(.6, .6, .6, .8), BJColor(0, 0, 0, .35)
end

-- TICKS -------------------------------------------------------------------------------------------

local function onUpdate()
    if M.scenarioLocked then updateCountdown() end
    updateContacts()
    renderZone()
end

local function onSlowUpdate()
    updateGridCountdown()
    updateWreckChecks()
    sendDamage()
    local feedChanged = pruneFeed()
    local session = M.session or M.spectatingSession
    if session and session.state == "GAME" then
        pushHud()
    elseif feedChanged then
        pushHud()
    end
    if M.eliminatedHandled and M.myVehicleVid and M.session and M.session.state == "GAME" then
        -- a wreck stays a wreck
        local v = beamjoy_vehicles.getVehicle(M.myVehicleVid, true)
        if v and v.veh.shut ~= "1" then beamjoy_vehicles.setEngine(M.myVehicleVid, false) end
    end
    if M.spawnQueueForced then flushSpawnQueue() end
end

-- ACTIONS -----------------------------------------------------------------------------------------

---@param opts table? see derbyGrid.lua buildSettings
local function startDerby(opts)
    beamjoy_communications.send("derbyStart", opts or {})
end

---@param sessionId string
local function joinDerby(sessionId)
    beamjoy_communications.send("derbyJoin", sessionId)
end

---@param state boolean
local function ready(state)
    if not M.session then return end
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    local hasCar = myVeh ~= nil and myVeh.veh.jbeam ~= beamjoy_vehicles.WALKING
    local s = M.session.settings
    -- random vehicles from a preset : you're given one at the countdown, nothing to pick
    if state == true and not (s.vehiclePool and s.randomizeVehiclePool) then
        if not hasCar then
            return toast.warn(beamjoy_lang.translate("beamjoy.activities.needVehicleToReady"), nil, 4)
        end
        if s.vehiclePool and not vehicleMatchesPool(myVeh.veh, s.vehiclePool) then
            toast.warn(beamjoy_lang.translate("beamjoy.derby.pickPreset"):var({ label = s.vehicleLabel or "" }), nil, 5)
            return extensions.ui_vehicleSelector_general.openFromPause("pause.vehicleSelector")
        end
    end
    beamjoy_communications.send("derbyReady", M.session.id, state == true, hasCar and myVeh.veh.jbeam or nil)
end

local function leave()
    if not M.session then return end
    beamjoy_communications.send("derbyLeave", M.session.id)
end

local function cancel()
    if not M.session then return end
    beamjoy_communications.send("derbyCancel", M.session.id)
end

local function onInit()
    beamjoy_communications.addHandler("derbySessionUpdate", M.onSessionUpdate)
    beamjoy_communications.addHandler("derbySessionsList", M.onSessionsList)
    beamjoy_communications.addHandler("derbySessionRemoved", M.onSessionRemoved)
    beamjoy_communications.addHandler("derbySpectateUpdate", M.onSpectateUpdate)
    beamjoy_communications.addHandler("derbySpectateRemoved", M.onSpectateRemoved)
    beamjoy_communications.addHandler("derbyLeaderboard", function(data)
        beamjoy_communications_ui.send("BJDerbyLeaderboard", data or {})
    end)

    beamjoy_communications_ui.addHandler("BJDerbyStart", M.startDerby)
    beamjoy_communications_ui.addHandler("BJDerbyJoin", M.joinDerby)
    beamjoy_communications_ui.addHandler("BJDerbyReady", M.ready)
    beamjoy_communications_ui.addHandler("BJDerbyLeave", M.leave)
    beamjoy_communications_ui.addHandler("BJDerbyCancel", M.cancel)
    beamjoy_communications_ui.addHandler("BJDerbyStartNow", function()
        if M.session then beamjoy_communications.send("derbyStartNow", M.session.id) end
    end)
    beamjoy_communications_ui.addHandler("BJDerbyForfeit", M.forfeit)
    beamjoy_communications_ui.addHandler("BJDerbySpectate", function(sessionId)
        beamjoy_communications.send("derbySpectate", sessionId)
    end)
    beamjoy_communications_ui.addHandler("BJDerbyStopSpectate", function()
        beamjoy_communications.send("derbyStopSpectate")
    end)
    beamjoy_communications_ui.addHandler("BJDerbySessionStatusRequest", M.pushSessionStatus)
    beamjoy_communications_ui.addHandler("BJDerbyOpenSessionsRequest", M.pushOpenSessions)
    beamjoy_communications_ui.addHandler("BJDerbyCountdownRequest", M.pushCountdown)
    beamjoy_communications_ui.addHandler("BJDerbyHudRequest", M.pushHud)
    beamjoy_communications_ui.addHandler("BJDerbyInfoRequest", M.pushDerbyInfo)
    -- sort : wins (default), rate, wrecks, damage or games (services/derbyGrid.lua SORTS)
    beamjoy_communications_ui.addHandler("BJDerbyLeaderboardRequest", function(sort)
        beamjoy_communications.send("derbyLeaderboardRequest", sort)
    end)
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onBJRequestCurrentVehicleReset = onBJRequestCurrentVehicleReset
M.onBJRequestCanSpawnVehicle = onBJRequestCanSpawnVehicle
M.onBJRequestStationInteraction = onBJRequestStationInteraction
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onVehicleResetted = onVehicleResetted

M.onSessionUpdate = onSessionUpdate
M.onSessionsList = onSessionsList
M.onSessionRemoved = onSessionRemoved
M.onSpectateUpdate = onSpectateUpdate
M.onSpectateRemoved = onSpectateRemoved
M.onEngineState = onEngineState
M.pushSessionStatus = pushSessionStatus
M.pushOpenSessions = pushOpenSessions
M.pushCountdown = pushCountdown
M.pushHud = pushHud
M.pushDerbyInfo = pushDerbyInfo

M.startDerby = startDerby
M.joinDerby = joinDerby
M.ready = ready
M.leave = leave
M.cancel = cancel
M.forfeit = forfeit

M.derbyNametagColor = derbyNametagColor
M.isGameLocked = isGameLocked

return M
