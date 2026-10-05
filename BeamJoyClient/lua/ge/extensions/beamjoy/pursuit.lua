local M = {
    interval = {
        min = 60 * 2 * 1000, -- 2 minutes
        max = 60 * 5 * 1000, -- 5 minutes
    },

    ---@type table<integer, string> index vid, value label
    fugitives = {},
    --- the fugitives' full vehicle ids (beamjoy_vehicles.serverKey), index vid : still known when
    --- the car itself is already gone
    ---@type table<integer, string>
    fugitiveKeys = {},
    --- the pursuits this player started (fugitive key -> GetCurrentTimeMillis() when sent) : called
    --- off if they join an activity, and ended as an escape once the fugitive got away (checkEscapes)
    ---@type table<string, integer>
    started = {},
    --- the fugitives the server listed last, index key
    ---@type table<string, true>
    serverListed = {},
    --- Real bug (direct report: after an arrest the fugitive tag stayed until the police drove
    --- away). The server's messages to everyone (the chase's end) and to one player (the fugitive
    --- list) wait in separate queues, so an older list still naming the fugitive could land after
    --- the end and tag it again ; and an arrest that never reached the server left the chase
    --- running until the escape rule ended it. A chase that ended here (an arrest made, or the
    --- server's pursuitStop) isn't tagged again from a list for a while, unless a new chase starts
    --- on that car. GetCurrentTimeMillis() when it ended, index key
    ---@type table<string, integer>
    recentlyEnded = {},
    RECENTLY_ENDED_MS = 15000,
    --- an arrest made here, until the server confirms it : sent again every 3 s, 5 tries at most
    ---@type {key: string, sentAt: integer, tries: integer}?
    pendingArrest = nil,
    --- police side : when each of this player's fugitives got out of reach, index key
    ---@type table<string, integer>
    escapeSince = {},
    --- a fugitive this far from the police player who started the chase (metres), for this long
    --- (seconds), got away
    ESCAPE_DISTANCE = 250,
    ESCAPE_SECONDS = 20,
    --- is current vehicle own and police
    isPolice = false,
    --- m/s a traffic car must be doing to become a fugitive (a parked car never is)
    MIN_TARGET_SPEED = 3,
    --- metres a fugitive may move between two server ticks beyond what its speed explains, before
    --- it counts as moved by a respawn (see checkFugitiveTeleports)
    TELEPORT_MARGIN = 50,
    --- this game's own fugitives : the game's own traffic switches saved while they're held off,
    --- index vid (see setRespawnLock)
    ---@type table<integer, {enableRespawn: any, ignoreForceTeleport: any, roleLockAction: any, roleState: any}>
    respawnLocks = {},
    --- this game's own fugitives : where each was at the last server tick, index vid
    ---@type table<integer, {pos: vec3, at: integer, speed: number}>
    lastFugitivePos = {},
    --- Real bug (direct report: arresting a traffic fugitive didn't work). An arrest needed the
    --- fugitive within 5 m, under 2 m/s, never more than 1 m from where the countdown began, for 5
    --- server ticks in a row, any miss restarting it from zero. Another player's traffic car is a
    --- synced copy here that jitters with every network correction, most of all while the two cars
    --- touch, so the countdown kept restarting. Now closer to the game's own police (20 m, both
    --- under 2.5 m/s) : the nearest fugitive within maxGap and under maxSpeed builds the arrest up,
    --- a slip only takes some back, and it's dropped once the fugitive is beyond dropGap.
    arrest = {
        --- metres between the two cars (their lengths taken off the distance between them)
        maxGap = 8,
        --- m/s
        maxSpeed = 3,
        --- seconds (simulation time) of the above for an arrest
        duration = 5,
        --- metres : further, the arrest in progress is dropped
        dropGap = 15,

        --- seconds built up toward the arrest
        progress = 0,
        ---@type BJVehicle?
        target = nil,
        --- the fugitive's position at the last tick, for its speed when the reported one is missing
        ---@type vec3?
        lastPos = nil,
        --- the arrest was sent, waiting for the server's answer
        sent = false,
        ---@type integer? GetCurrentTimeMillis() of the last server tick
        lastTickAt = nil,
    },
}

--- Real, confirmed annoyance (direct report): "pursuit tick shouldn't apply to parked vehicles."
--- Parked traffic is still `isAi`, so the target filter below happily picked a car sat in a parking
--- space and started a pursuit against something that was never driving anywhere. Two sources,
--- because the two spawners are separate: BJS's own parked pool (beamjoy_traffic.parkedVehs, the
--- cars this client spawned into parking spots - see traffic.lua's own updateParkedVehs) and
--- native's (gameplay_parking's own list, which also covers a level's pre-placed parked cars).
--- Both are plain vid lists, and both only know this game's own cars : another player's parked
--- traffic isn't in either (see MIN_TARGET_SPEED in pursuitTick, and startPursuit's owner check).
---@param v BJVehicle
---@return boolean
local function isParked(v)
    if not v or not v.vid then return true end
    local bjParked = beamjoy_traffic and beamjoy_traffic.parkedVehs
    if bjParked and bjParked.includes and bjParked:includes(v.vid) then return true end
    local parking = extensions.gameplay_parking
    if parking and parking.getParkedCarsList then
        local ok, list = pcall(parking.getParkedCarsList)
        if ok and type(list) == "table" and table.includes(list, v.vid) then return true end
    end
    return false
end

---@return boolean in a race, hunt, infected or derby (lobby or game), a delivery or a bus line
local function inActivity()
    return navigation ~= nil and navigation.inActivity ~= nil and navigation.inActivity() == true
end

---@return boolean Settings > Vehicle > "Police chases" is off : no traffic chases from this player
local function chasesOff()
    return beamjoy_playerPursuit ~= nil and beamjoy_playerPursuit.policeChasesOn ~= nil and
        not beamjoy_playerPursuit.policeChasesOn()
end

-- A road route to a target may run this much over the straight-line distance : an overpass, a
-- parallel road or the far side of a barrier is much further by road
local ROAD_DETOUR_FACTOR = 1.6
local ROAD_DETOUR_MARGIN = 60

--- a clear line of sight between two positions (the game's own police use the same static raycast,
--- gameplay/traffic/vehicle.lua checkRayCast)
---@param from vec3
---@param to vec3
---@return boolean
local function inSight(from, to)
    local a, b = from + vec3(0, 0, 1.5), to + vec3(0, 0, 1)
    local dir = b - a
    local len = dir:length()
    if len < 0.01 then return true end
    return castRayStatic(a, dir * (1 / len), len) >= len - 1
end

--- metres from one position to another over the road network ; nil when the map has none (the
--- check is then skipped), math.huge when no route is found
---@param from vec3
---@param to vec3
---@return number?
local function roadDistance(from, to)
    if not map or not map.getPointToPointPath or not map.getMap then return nil end
    local nodes = map.getMap().nodes
    if type(nodes) ~= "table" or next(nodes) == nil then return nil end
    local path = map.getPointToPointPath(from, to)
    if type(path) ~= "table" or #path == 0 then return math.huge end
    local dist, last = 0, from
    for _, name in ipairs(path) do
        local node = nodes[name]
        if node and node.pos then
            dist = dist + last:distance(node.pos)
            last = node.pos
        end
    end
    return dist + last:distance(to)
end

--- Real annoyance (direct report: "the suspect is sometimes out of view, far away on a different
--- road, and impossible to catch") : the target used to be any traffic car within a straight-line
--- distance, picked at random, so an overpass, a parallel road or a car behind buildings could be
--- picked. Now the police must see it, and it must be reachable by road without a long detour ;
--- the nearest such car is picked.
---@param pos vec3 the police car
---@param targetPos vec3
---@return boolean catchable, "sight"|"road"|nil why not
local function catchable(pos, targetPos)
    local ok, result, why = pcall(function()
        if not inSight(pos, targetPos) then return false, "sight" end
        local straight = pos:distance(targetPos)
        local road = roadDistance(pos, targetPos)
        if road ~= nil and road > straight * ROAD_DETOUR_FACTOR + ROAD_DETOUR_MARGIN then return false, "road" end
        return true
    end)
    if not ok then
        LogError("beamjoy_pursuit: target check failed: " .. tostring(result))
        return true -- the old behaviour rather than no chases at all
    end
    return result, why
end

-- Tick to find a fugitive to start a pursuit : traffic near this player's own police car, this
-- client's own or another player's (the owner's client drives it, fleeing from this police car)
local function pursuitTick()
    -- never in an activity : a race, a hunt, a lobby... are no place for traffic pursuits
    -- and not while this police player chases a player (beamjoy_playerPursuit)
    local chasingPlayer = beamjoy_playerPursuit ~= nil and beamjoy_playerPursuit.isChasing()
    if beamjoy_traffic.data.enabled and not inActivity() and not chasingPlayer and not chasesOff() then
        LogDebug("Pursuit tick")
        local mpVeh = beamjoy_vehicles.getCurrent()
        if mpVeh and M.isPolice then
            local pos = beamjoy_vehicles.getVehiclePositionRotation(mpVeh.veh)

            -- Real bug (direct report: the fugitive tag was on two cars at once) : a new chase used
            -- to start whenever no fugitive was near this police car, while the previous one, out of
            -- reach but not respawned, stayed a fugitive. One chase at a time per police player ;
            -- checkEscapes ends the previous one once it got away
            if next(M.started) == nil and (table.length(M.fugitives) == 0 or not table.any(M.fugitives, function(_, fugitiveVID)
                    ---@type BJVehicle?
                    local v = beamjoy_vehicles.vehicles[fugitiveVID]
                    if not v or not v.isAi then return false end
                    local vPos = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
                    local _, maxDist = beamjoy_traffic.getMinMaxDistFromPlayer(tonumber(v.veh.speed) or 0)
                    return pos:distance(vPos) < maxDist
                end)) then
                local candidates = beamjoy_vehicles.vehicles:filter(function(v)
                    if not v.isAi or not v.veh then return false end
                    if isParked(v) then return false end -- see isParked's own comment
                    -- Real bug (direct report: fugitive status still landed on parked cars) :
                    -- isParked only knows this game's own parked cars, and another player's parked
                    -- traffic looks like any traffic car here. Every game measures every car's
                    -- speed, remote copies included, so only a car actually driving is picked
                    if (tonumber(v.veh.speed) or 0) < M.MIN_TARGET_SPEED then return false end
                    -- Real bug: another player's traffic used to be kept only when this police
                    -- car's vid equalled the owner's currentVehicle, two ids from two different
                    -- games that essentially never match (and it errored when the owner wasn't in
                    -- the player list, which stopped the tick for good). It was standing in for
                    -- the real problem, fixed in startPursuit : the fleeing car was never told whom
                    -- to flee from, so it fled from its owner's own car
                    local vPos = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
                    local minDist = beamjoy_traffic.getMinMaxDistFromPlayer(tonumber(v.veh.speed) or 0)
                    return pos:distance(vPos) < minDist
                end):values()
                -- nearest first : the first one the police can see and reach by road (see catchable)
                local byDistance = {}
                for _, v in pairs(candidates) do
                    local vPos = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
                    byDistance[#byDistance + 1] = { v = v, pos = vPos, dist = pos:distance(vPos) }
                end
                table.sort(byDistance, function(a, b) return a.dist < b.dist end)
                ---@type BJVehicle?
                local target
                local blocked = { sight = 0, road = 0 }
                for _, c in ipairs(byDistance) do
                    local can, why = catchable(pos, c.pos)
                    if can then
                        target = c.v
                        break
                    elseif why then
                        blocked[why] = blocked[why] + 1
                    end
                end
                if not target then
                    -- a tick that finds no suspect says why in the log, for "no chases start" reports
                    LogInfo(string.format("beamjoy_pursuit: no suspect this time (%d moving traffic cars in range, %d out of sight, %d too far by road)",
                        #byDistance, blocked.sight, blocked.road))
                end
                -- Real bug (direct report: arresting another player's traffic car left it there) :
                -- cars were named by remoteVID, the car's id in its owner's game. Every game loads
                -- the same map and hands out nearly the same ids, so another player's traffic car
                -- often shares its number with a car of this game or of the owner's, and the start
                -- or the stop landed on whichever came first. The full BeamMP id is the same on
                -- every game and names one car only
                local targetKey = target and beamjoy_vehicles.serverKey(target)
                local policeKey = beamjoy_vehicles.serverKey(mpVeh)
                if targetKey and policeKey then
                    M.started[targetKey] = GetCurrentTimeMillis()
                    beamjoy_communications.send("pursuitStart", targetKey, policeKey)
                end
            end
        end
    end
end

-- Real bug: the next tick was only scheduled at the end of the tick, so a single error in it
-- stopped pursuits for the rest of the session
local function tick()
    -- a reload of this extension leaves the previous copy's loop scheduled (the delayed task can't be
    -- named : a task rescheduling itself under its own name cancels the new one) : only the live
    -- copy ticks, the old loop stops here
    if beamjoy_pursuit ~= M then return end
    local ok, err = pcall(pursuitTick)
    if not ok then LogError("beamjoy_pursuit: tick failed: " .. tostring(err)) end
    async.delayTask(tick, math.random(M.interval.min, M.interval.max))
end

local function onInit()
    tick()

    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications.addHandler("pursuitStart", M.startPursuit)
    beamjoy_communications.addHandler("pursuitStop", M.stopPursuit)
    beamjoy_communications.addHandler("pursuitRefused", M.onPursuitRefused)
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    local current = beamjoy_vehicles.getCurrent()
    ---@type BJVehicle?
    local mpVeh = beamjoy_vehicles.vehicles[vid]
    if current ~= nil and mpVeh ~= nil and
        current == mpVeh then
        M.isPolice = mpVeh.isLocal and
            beamjoy_vehicles.isPolice(mpVeh)
    end
end

local function onVehicleSwitched(_, newVID)
    ---@type BJVehicle?
    local mpVeh = beamjoy_vehicles.vehicles[newVID]
    M.isPolice = mpVeh ~= nil and mpVeh.isLocal and
        beamjoy_vehicles.isPolice(mpVeh)
end

--- Real bug (direct report: a fleeing fugitive got respawned elsewhere by the traffic system, kept
--- its fugitive tag, stopped fleeing, and couldn't be arrested). Besides BeamJoy's own rubberband
--- (which ends the chase, onBJTrafficVehicleResetted), the game's own traffic system moves cars
--- that are out of sight (gameplay_traffic : tryRespawn / forceTeleport), telling no one, and resets
--- their AI to plain traffic. A fugitive of this game's own traffic is held out of it, through the
--- same per-car switches the game reads, until its chase ends.
---
--- Real bug (direct report: rammed and pinned, the fugitive stopped, "exchanged insurance
--- information", and was never arrested) : the car's own traffic behaviour (gameplay_traffic's
--- "standard" role) kept running during the chase. A collision made it pull over, follow, then
--- exchange insurance, each switching its AI off the flee BeamJoy gave it. Held off too : actions
--- locked (the role's own lockAction) and the role skipped altogether (its onTrafficTick / onUpdate
--- return at once while its state is "disabled"). Given back when the chase ends, its crash memory
--- cleared so it doesn't pull over afterwards for a bump from the chase.
---@param vid integer
---@param locked boolean
local function setRespawnLock(vid, locked)
    local gt = extensions.gameplay_traffic
    local data = gt and gt.getTrafficData and gt.getTrafficData()
    local tv = type(data) == "table" and data[vid] or nil
    local role = tv and type(tv.role) == "table" and tv.role or nil
    if locked then
        if tv and not M.respawnLocks[vid] then
            M.respawnLocks[vid] = {
                enableRespawn = tv.enableRespawn,
                ignoreForceTeleport = tv.ignoreForceTeleport,
                roleLockAction = role and role.lockAction,
                roleState = role and role.state,
            }
            tv.enableRespawn = false
            tv.ignoreForceTeleport = true
            if role then
                role.lockAction = true
                role.state = "disabled"
            end
        end
    else
        local saved = M.respawnLocks[vid]
        M.respawnLocks[vid] = nil
        if tv and saved then
            tv.enableRespawn = saved.enableRespawn
            tv.ignoreForceTeleport = saved.ignoreForceTeleport
            if role then
                role.lockAction = saved.roleLockAction == true
                role.state = saved.roleState ~= "disabled" and saved.roleState or "none"
                if type(role.flags) == "table" then table.clear(role.flags) end
                if type(role.driver) == "table" then role.driver.eventType = "none" end
                if not role.lockAction and role.resetAction then pcall(role.resetAction, role) end
            end
        end
    end
end

--- safety net, on the owner's game, once a server tick : a fugitive of this game's traffic that
--- moved further than it could have driven since the last tick was moved by something this file
--- wasn't told about. Its chase ends as an escape (the fugitive tag goes for everyone)
local function checkFugitiveTeleports()
    local now = GetCurrentTimeMillis()
    for vid in pairs(M.lastFugitivePos) do
        if not M.fugitives[vid] then M.lastFugitivePos[vid] = nil end
    end
    for vid in pairs(M.fugitives) do
        local v = beamjoy_vehicles.vehicles[vid]
        if v and v.isLocal and v.isAi and v.veh then
            local pos = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
            local speed = tonumber(v.veh.speed) or 0
            local last = M.lastFugitivePos[vid]
            local moved = false
            if last then
                local dt = math.max(0.1, (now - last.at) / 1000)
                local couldDrive = math.max(speed, last.speed) * dt * 1.5 + M.TELEPORT_MARGIN
                moved = pos:distance(last.pos) > couldDrive
            end
            if moved then
                M.lastFugitivePos[vid] = nil
                if M.fugitiveKeys[vid] then
                    beamjoy_communications.send("pursuitStop", M.fugitiveKeys[vid], 0)
                end
            else
                M.lastFugitivePos[vid] = { pos = pos, at = now, speed = speed }
            end
        end
    end
end

---@param vid integer
local function onBJTrafficVehicleDeleted(vid)
    if M.fugitives[vid] and M.fugitiveKeys[vid] then
        beamjoy_communications.send("pursuitStop", M.fugitiveKeys[vid], 2)
    end
    M.respawnLocks[vid] = nil
    M.lastFugitivePos[vid] = nil
end

---@param veh NGVehicle
local function onBJTrafficVehicleResetted(veh)
    local vid = veh:getID()
    if M.fugitives[vid] and M.fugitiveKeys[vid] then
        beamjoy_communications.send("pursuitStop", M.fugitiveKeys[vid], 0)
    end
end
local resetArrestation = function()
    M.arrest.progress = 0
    M.arrest.target = nil
    M.arrest.lastPos = nil
    M.arrest.sent = false
end

--- joining an activity, or turning "Police chases" off, calls off the pursuits this player
--- started (the fugitives escape)
local function callOffPursuits()
    for key in pairs(M.started) do
        beamjoy_communications.send("pursuitStop", key, 0)
    end
    table.clear(M.started)
    resetArrestation()
end

--- police side, once a server tick : a fugitive of a chase this player started that has been out of
--- reach (further than ESCAPE_DISTANCE from this player, or gone) for ESCAPE_SECONDS got away. Before
--- this, a chase only ended when the fugitive's owner respawned or removed the car, which depends
--- on where the owner is, not the police
local function checkEscapes()
    local now = GetCurrentTimeMillis()
    -- a start the server never listed (refused by an older server, or lost) : forgotten after 10 s,
    -- so it can't hold this player's next chase back (see onPursuitRefused)
    for key, sentAt in pairs(M.started) do
        if not M.serverListed[key] and now - (tonumber(sentAt) or 0) > 10000 then M.started[key] = nil end
    end
    for key in pairs(M.escapeSince) do
        if not M.started[key] then M.escapeSince[key] = nil end
    end
    local current = beamjoy_vehicles.getCurrent()
    local pos = current and current.veh and beamjoy_vehicles.getVehiclePositionRotation(current.veh)
    for key in pairs(M.started) do
        local v = beamjoy_vehicles.getByServerKey(key)
        local far = not pos or not v or not v.veh or
            pos:distance(beamjoy_vehicles.getVehiclePositionRotation(v.veh)) > M.ESCAPE_DISTANCE
        if not far then
            M.escapeSince[key] = nil
        elseif not M.escapeSince[key] then
            M.escapeSince[key] = now
        elseif now - M.escapeSince[key] >= M.ESCAPE_SECONDS * 1000 then
            M.escapeSince[key] = nil
            M.started[key] = nil
            beamjoy_communications.send("pursuitStop", key, 0)
        end
        -- getting away : a countdown (direct report: hard to tell when a suspect was escaping)
        if M.escapeSince[key] then
            local left = math.max(1, math.ceil(M.ESCAPE_SECONDS - (now - M.escapeSince[key]) / 1000))
            beamjoy_communications_ui.uiBroadcast("beamjoy.pursuit.suspectEscaping", { time = left }, nil, 1.2)
        end
    end
end

--- police side, once a server tick : the arrest of the nearest fugitive (see M.arrest)
---@param now integer GetCurrentTimeMillis()
---@param dt number seconds of simulation time since the last tick
local function arrestTick(now, dt)
    if not M.isPolice or table.length(M.fugitives) == 0 then
        if M.arrest.target then resetArrestation() end
        return
    end
    local veh = beamjoy_vehicles.getCurrent()
    if not veh or not veh.veh then return end
    local pos = beamjoy_vehicles.getVehiclePositionRotation(veh.veh)
    local radius = veh.veh:getInitialLength() / 2

    -- the nearest fugitive
    local target, gap, fPos
    for vid in pairs(M.fugitives) do
        local v = beamjoy_vehicles.vehicles[vid]
        if v and v.veh then
            local p = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
            local g = pos:distance(p) - (radius + v.veh:getInitialLength() / 2)
            if not gap or g < gap then target, gap, fPos = v, g, p end
        end
    end
    if not target or gap > M.arrest.dropGap then
        -- diagnostic : near but beyond the arrest's reach (a wrong distance would show here)
        if target and gap <= 40 and (not M.arrest.lastLogAt or now - M.arrest.lastLogAt >= 2000) then
            M.arrest.lastLogAt = now
            LogInfo(string.format("beamjoy_pursuit: arrest check : nearest fugitive %.1f m away (centres %.1f m apart, lengths %.1f + %.1f)",
                gap, pos:distance(fPos), radius * 2, target.veh:getInitialLength()))
        end
        if M.arrest.target then resetArrestation() end
        return
    end
    if M.arrest.target ~= target then
        resetArrestation()
        M.arrest.target = target
    end
    if M.arrest.sent then return end

    -- its speed : the lower of the one its game reports and how far it moved since the last tick (a
    -- wrong reported value, or a jittery synced copy, can't hold an arrest back on its own : the
    -- distance limit still applies)
    local reported = tonumber(target.veh.speed)
    local measured = (M.arrest.lastPos and dt > 0) and M.arrest.lastPos:distance(fPos) / dt or nil
    local speed = math.min(reported or math.huge, measured or math.huge)
    if speed == math.huge then speed = 0 end
    M.arrest.lastPos = fPos

    -- Diagnostic (direct report: "I'm not getting the arrest prompt" while pinned against the
    -- fugitive) : every 2 s near a fugitive, what the check sees, in the game's log
    if not M.arrest.lastLogAt or now - M.arrest.lastLogAt >= 2000 then
        M.arrest.lastLogAt = now
        LogInfo(string.format("beamjoy_pursuit: arrest check : gap %.1f m (needs %d), speed %.1f m/s (reported %s, measured %s, needs %d), %.1f / %d s",
            gap, M.arrest.maxGap, speed, tostring(reported), measured and string.format("%.1f", measured) or "-",
            M.arrest.maxSpeed, M.arrest.progress, M.arrest.duration))
    end

    if gap <= M.arrest.maxGap and speed <= M.arrest.maxSpeed then
        M.arrest.progress = M.arrest.progress + dt
        if M.arrest.progress >= M.arrest.duration then
            -- arrested : the tag goes at once here, the server's pursuitStop ends the chase for
            -- everyone (sent again until it does, see pendingArrest)
            local key = M.fugitiveKeys[target.vid] or beamjoy_vehicles.serverKey(target)
            if key then
                M.arrest.sent = true
                M.pendingArrest = { key = key, sentAt = now, tries = 1 }
                M.recentlyEnded[key] = now
                M.fugitives[target.vid] = nil
                target.veh.uiState = 0
                beamjoy_communications.send("pursuitStop", key, 1)
                beamjoy_communications_ui.uiBroadcast('ui.traffic.suspectArrest', nil, nil, 3)
                resetArrestation()
            end
        else
            local remaining = math.ceil(M.arrest.duration - M.arrest.progress)
            beamjoy_communications_ui.uiBroadcast("beamjoy.pursuit.arrestIn", { time = remaining }, nil, 1.2)
        end
    else
        -- a slip (it got going again, or moved off) takes some back rather than starting over
        M.arrest.progress = math.max(0, M.arrest.progress - dt)
    end
end

local function onServerTick()
    -- the owner's side, whatever this player is doing (another player chases this game's traffic)
    local ok, err = pcall(checkFugitiveTeleports)
    if not ok then LogError("beamjoy_pursuit: teleport check failed: " .. tostring(err)) end
    if inActivity() or chasesOff() then
        if next(M.started) then callOffPursuits() end
        if M.arrest.target then resetArrestation() end
        return
    end
    ok, err = pcall(checkEscapes)
    if not ok then LogError("beamjoy_pursuit: escape check failed: " .. tostring(err)) end
    -- seconds since the last server tick (simulation time), for the arrest's build-up
    local now = GetCurrentTimeMillis()
    -- an arrest the server hasn't confirmed yet : sent again
    local pa = M.pendingArrest
    if pa and now - pa.sentAt >= 3000 then
        if pa.tries >= 5 then
            M.pendingArrest = nil
        else
            pa.tries, pa.sentAt = pa.tries + 1, now
            beamjoy_communications.send("pursuitStop", pa.key, 1)
        end
    end
    local dt = M.arrest.lastTickAt and math.min(2, (now - M.arrest.lastTickAt) / 1000) or 0
    M.arrest.lastTickAt = now
    if simTimeAuthority.getPause() then dt = 0 else dt = dt * (tonumber(simTimeAuthority.get()) or 1) end

    ok, err = pcall(arrestTick, now, dt)
    if not ok then LogError("beamjoy_pursuit: arrest check failed: " .. tostring(err)) end
end

---@param caches table
local function retrieveCache(caches)
    if caches.pursuitFugitives then
        local previousFugitivesLength = table.length(M.fugitives)
        local newVIDs = table.map(caches.pursuitFugitives, function(key)
            local mpVeh = beamjoy_vehicles.getByServerKey(key)
            if mpVeh then M.fugitiveKeys[mpVeh.vid] = tostring(key) end
            return mpVeh and mpVeh.vid or nil
        end)
        -- remove obsolete fugitives : their minimap marker too (a chase dropped without a
        -- pursuitStop, like the owner refusing a parked car, never reached stopPursuit)
        table.forEach(M.fugitives, function(_, vid)
            if not table.includes(newVIDs, vid) then
                M.fugitives[vid] = nil
                local v = beamjoy_vehicles.vehicles[vid]
                if v and v.veh then v.veh.uiState = 0 end
            end
        end)
        for vid in pairs(M.fugitiveKeys) do
            if not table.includes(newVIDs, vid) then M.fugitiveKeys[vid] = nil end
        end
        -- this player's chases the server no longer has (dropped without a pursuitStop : a car
        -- removed, an owner refusing a parked car...) : forgotten, so they don't block a new one.
        -- A start just sent gets a few seconds for the server's answer
        local listed = {}
        for _, key in ipairs(caches.pursuitFugitives) do listed[tostring(key)] = true end
        M.serverListed = listed
        local now = GetCurrentTimeMillis()
        for key, sentAt in pairs(M.started) do
            if not listed[key] and now - (tonumber(sentAt) or 0) > 5000 then M.started[key] = nil end
        end
        -- an arrest the server no longer lists is done ; chases ended a while ago are forgotten
        if M.pendingArrest and not listed[M.pendingArrest.key] then M.pendingArrest = nil end
        for key, endedAt in pairs(M.recentlyEnded) do
            if now - endedAt >= M.RECENTLY_ENDED_MS then M.recentlyEnded[key] = nil end
        end
        -- add new labels (not a chase that just ended here : an older list arriving late)
        table.forEach(newVIDs, function(vid)
            local key = M.fugitiveKeys[vid]
            if key and M.recentlyEnded[key] then return end
            if not M.fugitives[vid] then
                local mpVeh = beamjoy_vehicles.vehicles[vid]
                if not mpVeh then return end
                local fullConfig = beamjoy_vehicles.getFullConfig(mpVeh.veh)
                if not fullConfig then return end
                if fullConfig.key then
                    M.fugitives[vid] = beamjoy_vehicles.getConfigLabel(fullConfig.model, fullConfig.key)
                else
                    M.fugitives[vid] = beamjoy_vehicles.getModelLabel(fullConfig.model)
                end
            end
        end)
        if M.isPolice and previousFugitivesLength > 0 and table.length(M.fugitives) == 0 then
            local current = beamjoy_vehicles.getCurrent()
            if current then
                -- stop siren and lights
                current.veh:queueLuaCommand('electrics.set_lightbar_signal(0)')
            end
        end
    end
end

---@param fugitiveKey string full vehicle id, see beamjoy_vehicles.serverKey
---@param policeKey string
local function startPursuit(fugitiveKey, policeKey)
    -- a new chase on a car whose previous one just ended : it can be tagged again
    M.recentlyEnded[tostring(fugitiveKey)] = nil
    local v = beamjoy_vehicles.getByServerKey(fugitiveKey)
    if not v then return end
    -- the owner's game knows its parked cars : a chase on one (from an older police client, or a
    -- car that had only just stopped) is dropped at once, before anyone tags it
    if v.isLocal and v.isAi and isParked(v) then
        return beamjoy_communications.send("pursuitStop", tostring(fugitiveKey), 2)
    end
    M.fugitiveKeys[v.vid] = tostring(fugitiveKey)
    async.task(function()
        return M.fugitives[v.vid] ~= nil
    end, function()
        -- show fugitive on minimap
        v.veh.uiState = 1
        -- only ever this game's own traffic : the server checks it too, but a player's own car must
        -- never be handed to the flee AI, whatever arrives
        if v.isLocal and v.isAi then
            -- Real bug: the target was sent to the police car itself instead of the fleeing
            -- one. Without a target, the game's flee AI picks this client's active vehicle
            -- (vehicle/ai.lua updatePlayerData) : another player's traffic fled from its
            -- owner's own car, not from the police. The police car's id here is this game's
            -- id for it (its copy, when it's another player's)
            local policeVeh = beamjoy_vehicles.getByServerKey(policeKey)
            setRespawnLock(v.vid, true)
            v.veh:queueLuaCommand([[
                ai.setMode("flee");
                ai.driveInLane("off");
                ai.setSpeedMode("off");
            ]])
            if policeVeh then
                v.veh:queueLuaCommand("ai.setTargetObjectID(" .. tostring(policeVeh.vid) .. ")")
            end
        end
        if M.isPolice then
            local current = beamjoy_vehicles.getCurrent()
            if not current then return end
            local pos = beamjoy_vehicles.getVehiclePositionRotation(current.veh)
            local fPos = beamjoy_vehicles.getVehiclePositionRotation(v.veh)
            local _, maxDist = beamjoy_traffic.getMinMaxDistFromPlayer(tonumber(v.veh.speed) or 0)
            if pos:distance(fPos) < maxDist then
                if extensions.gameplay_traffic.showMessages then
                    ui_message(string.var("{1} {2}", {
                        translateLanguage('ui.traffic.suspectFlee',
                            'A suspect is fleeing from you! Vehicle:'),
                        M.fugitives[v.vid],
                    }), 5, 'traffic', 'traffic')
                end
                if localStorage.get(localStorage.GLOBAL_VALUES.AUTOMATIC_LIGHTS) then
                    -- auto enable siren and lights
                    current.veh:queueLuaCommand('electrics.set_lightbar_signal(2)')
                end
            end
        end
    end)
end

---@param key string full vehicle id, see beamjoy_vehicles.serverKey
---@param caught boolean
local function stopPursuit(key, caught)
    M.started[tostring(key)] = nil
    M.recentlyEnded[tostring(key)] = GetCurrentTimeMillis()
    if M.pendingArrest and M.pendingArrest.key == tostring(key) then M.pendingArrest = nil end
    local v = beamjoy_vehicles.getByServerKey(key)
    if not v then return end
    -- Real bug (direct report: after an arrest the fugitive tag stayed over the car, and was
    -- still there when it respawned) : the pursuit's end only ever cleared the fugitive through
    -- the separate fugitive-list cache that follows this message. That's the list's own job,
    -- but the tag must not depend on it : the pursuit is over the moment this arrives
    M.fugitives[v.vid] = nil
    -- hide fugitive on minimap
    v.veh.uiState = 0
    if v.isLocal and v.isAi then
        setRespawnLock(v.vid, false)
        M.lastFugitivePos[v.vid] = nil
        if caught then
            local vid = v.vid
            async.delayTask(function()
                beamjoy_traffic.markForRespawn(vid)
            end, 5000)
        end
        -- caught : stopped until it respawns elsewhere. Escaped : back to driving as traffic (it used
        -- to be told to stop too, and stayed parked in the road)
        v.veh:queueLuaCommand(string.format([[
            ai.setMode("%s")
            ai.setTargetObjectID(-1)
            ai.driveInLane("on")
            ai.setSpeedMode("legal")
        ]], caught and "stop" or "traffic"))
    end
    if M.isPolice then
        if table.length(M.fugitives) == 0 then
            local current = beamjoy_vehicles.getCurrent()
            if current then
                -- stop siren and lights
                current.veh:queueLuaCommand('electrics.set_lightbar_signal(0)')
            end
        end
        if extensions.gameplay_traffic.showMessages then
            ui_message(caught and 'ui.traffic.suspectArrest' or
                'ui.traffic.suspectEvade', 5, 'traffic', 'traffic')
        end
        if M.arrest.target and M.arrest.target.vid == v.vid then
            resetArrestation()
            beamjoy_communications_ui.uiBroadcast('ui.traffic.suspectArrest',
                nil, nil, 3)
        end
    end
end

--- the server refused a chase this player's tick asked for (it says why in its own log) : forgotten
--- at once, so the next tick can try again
---@param key string
local function onPursuitRefused(key)
    M.started[tostring(key)] = nil
end

M.onInit = onInit
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onVehicleSwitched = onVehicleSwitched
M.onBJTrafficVehicleDeleted = onBJTrafficVehicleDeleted
M.onBJTrafficVehicleResetted = onBJTrafficVehicleResetted
M.onServerTick = onServerTick

M.retrieveCache = retrieveCache
M.startPursuit = startPursuit
M.onPursuitRefused = onPursuitRefused
M.stopPursuit = stopPursuit

return M
