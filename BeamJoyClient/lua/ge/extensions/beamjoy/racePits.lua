--- Race pits, the racing side (PIT_SYSTEM_PLAN.md §5) : what this player's game sees of the pit lane
--- and reports to the server (services/raceGrid.lua's racePit), and what the pits do to the car.
---
--- - PIT IN (right after the lane's fromStep), the start/finish line where it continues across the
---   lane, PIT OUT : plane crossings like the gates', sent as "entry", "line", "exit". The route's own
---   gates don't count in the lane (raceRunner.lua skips them while `inPit`) : the server credits the
---   steps the lane skips
--- - in the lane : the game's own speed limiter (vehicleController's temporary top speed), and the
---   car ghosted (settings.pitGhost) ; both reasserted, a reset turns the limiter off
--- - the stop : stopped in your own box, the car is held while the plan's work is done (fuel at
---   settings.pitFuelRatePct of the tank a second, repair by the car's damage), then "stop"
--- - towed to the pits ("tow") : put in your box, held for the drive back, then the stop as usual
--- - after the phase (settings.pitReturn) : back to your box ("returned"), held there until the next
---   phase's countdown
---
--- The server decides : this module sends what it saw and follows the session's `inPit`, `towUntilMs`,
--- `pitReturnPending` and `pitReturned`. The pit plan (M.plan) is this player's own, kept for the session.

local M = {
    dependencies = { "beamjoy_vehicles", "beamjoy_pits", "beamjoy_communications", "beamjoy_raceRunner", "beamjoy_uiNav",
        "camera", "toast" },

    ---@type {refuel: boolean, fuelAdd: number, repair: boolean} what a stop does : fuelAdd is a share of
    ---the tank (1 : fill it up), capped at what fits when you stop
    plan = { refuel = true, fuelAdd = 1, repair = true },

    --- in the pit lane, as this game sees it (ahead of the server's echo after a crossing)
    inPit = false,
    ---@type {lineDue: boolean, stopped: boolean, entryConfirmBy: number?}? this pass through the lane
    pass = nil,
    ---@type "tow"|"returned"|nil held in the box : towed (until towUntilMs), or back after the phase
    holding = nil,
    ---@type table? the stop under way : {startMs, endMs, work, previousCamera, measured}
    stop = nil,

    ---@type {kind: "fuel"|"battery", stored: number, capacity: number}? the car's tanks last read
    ---(litres, or kWh a battery), and whose
    tank = nil,
    tankVid = nil,
    --- the pit menu (windows/pitControl) is open : it has the pad
    menuOpen = false,
    ---@type table? the car's damage as the menu shows it (beamjoy_pits.damageSummary)
    menuDamage = nil,
}

-- the server's view last seen, for its changes (followed on a change only : a crossing here is
-- ahead of its echo)
local serverInPit, serverReturned
-- the phase this state belongs to (raceRunner.lua's phaseKey)
local statePhase
-- the towUntilMs a tow was handled for
local towHandled
-- the last step sent as crossed (raceRunner.lua's gates), the lane's fromStep reached ahead of the echo
local lastGate
-- after PIT OUT : the step the server credits last, until its echo
local afterExitGate
-- each line's last signed distance (planeCrossed)
local lastLy = {}
-- the race time last frame and this one (a crossing placed between them, like the gates')
local prevElapsedMs, elapsedMs
-- the limiter and ghost as last set
local limiterKmh, ghostOn, lastLimiterMs
-- the UI status last sent, and when
local lastStatusJson, lastStatusMs
-- a tow's hold end on this client's clock, when there's no shared clock
local towLocalUntilMs
-- when this player last asked for a tow (a tow that finished their race has no hold to show it)
local towAskedMs

--- how far across the pit lane the start/finish line counts (raceGrid.lua's PIT_LINE_REACH)
local LINE_REACH = 150
--- stopped : under this speed, m/s
local STOP_SPEED = .5
--- an entry the server didn't take (no inPit back) is dropped after this long
local ENTRY_CONFIRM_MS = 3000
--- a tow's hold on top of the drive back (raceGrid.lua's PIT_TOW_BASE_MS)
local TOW_BASE_MS = 10000

-- ---------------------------------------------------------------------------------------------
-- the session

---@return {EntrySpeedPenalty: integer, SpeedTolerance: integer}
local function pitConfig()
    local cfg = beamjoy_config and beamjoy_config.data and beamjoy_config.data.RacePits
    return type(cfg) == "table" and cfg or { EntrySpeedPenalty = 5, SpeedTolerance = 5 }
end

--- this player's race with usable pits, nil otherwise
---@return {session: table, participant: table, race: table, settings: table}?
local function context()
    local runner = beamjoy_raceRunner
    local session = runner and runner.session
    if not session or not session.settings or session.settings.pits ~= true then return nil end
    local participant = runner.getSelfParticipant()
    if not participant or participant.sittingOut or participant.dnf or participant.disqualified then return nil end
    local race = runner.getRace()
    if not race or not race.pit or not race.pit.entry or not race.pit.exit then return nil end
    return { session = session, participant = participant, race = race, settings = session.settings }
end

---@param session table
---@return string
local function phaseKey(session)
    return string.format("%s#%d", session.id, session.phaseIndex or 1)
end

--- the route steps a pass through the lane skips (raceGrid.lua's pitSteps) : after `from` (0 : the
--- line first) up to toStep, not included
---@param race table
---@param from integer
---@return integer[]
local function pitSteps(race, from)
    local n, out, step = #race.gates, {}, from
    for _ = 1, n do
        step = step % n + 1
        if step == race.pit.toStep then break end
        out[#out + 1] = step
    end
    return out
end

---@param a table
---@param b table
---@return number
local function pointDistance(a, b)
    local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- a tow's hold from where a racer is (raceGrid.lua's routeToPit) : the route from their last gate
--- to PIT IN at the race's tow speed (settings.pitTowSpeed), plus the base. What the HUD's Tow
--- shows ; the server's own is what holds them
---@param race table
---@param participant table
---@param kmh number?
---@return integer ms
function M.towHoldMs(race, participant, kmh)
    local n, pit = #race.gates, race.pit
    if n == 0 then return TOW_BASE_MS end
    local step = participant.currentGate or 0
    local last = step >= 1 and race.gates[step] and race.gates[step].pos or
        (participant.startPosition or race.startPositions[1] or {}).pos or pit.entry.pos
    local d = 0
    for _ = 1, n do
        if step == pit.fromStep then break end
        step = step % n + 1
        d = d + pointDistance(last, race.gates[step].pos)
        last = race.gates[step].pos
    end
    d = d + pointDistance(last, pit.entry.pos)
    return TOW_BASE_MS + math.floor(d / (math.max(10, tonumber(kmh) or 50) / 3.6) * 1000)
end

---@param ctx table
---@return table? the racer's box : {pos, dir, width?, length?}
local function ownBox(ctx)
    local slot = ctx.participant.pitSlot
    local sp = slot and ctx.race.startPositions[slot]
    return sp and sp.pit and sp.pit.pos and sp.pit or nil
end

---@param action string
---@param ms number?
---@param data table?
local function send(action, ms, data)
    local session = beamjoy_raceRunner.session
    if not session then return end
    beamjoy_communications.send("racePit", session.id, action, ms and math.max(0, math.floor(ms)) or nil, data)
end

--- the server's shared clock now (beamjoy_clockSync), nil unsynced
---@return number?
local function serverNow()
    return beamjoy_clockSync and beamjoy_clockSync.serverNowMs() or nil
end

-- ---------------------------------------------------------------------------------------------
-- the car

--- the game's own speed limiter, on at `kmh`, or off (nil). The vehicle's Lua drops it on a reset,
--- so it's set again every half second while on (update)
---@param veh table? NGVehicle
---@param kmh number?
local function setLimiter(veh, kmh)
    limiterKmh = kmh
    lastLimiterMs = GetCurrentTimeMillis()
    if not veh then return end
    if kmh then
        veh:queueLuaCommand(string.format([[
local c = controller.mainController
if c and c.setTopSpeedLimitTemporary then c.setTopSpeedLimitTemporary(%f) c.setTopSpeedLimitTemporaryActive(true) end]],
            kmh / 3.6))
    else
        veh:queueLuaCommand([[
local c = controller.mainController
if c and c.setTopSpeedLimitTemporaryActive then c.setTopSpeedLimitTemporaryActive(false) end]])
    end
end

--- the pit lane's ghost on the player's car (settings.pitGhost), its own reason. Lifted carefully,
--- as the green light's is : once clear of other cars, forced after a few seconds
---@param vid integer
---@param on boolean
local function setGhost(vid, on)
    if ghostOn == on then return end
    ghostOn = on
    local task = "BJRacePitGhostForce-" .. vid
    async.removeTask(task)
    if on then
        beamjoy_vehicles.setGhostReason(vid, "racePit", true)
    else
        beamjoy_vehicles.setGhostReason(vid, "racePit", false, false, false)
        async.delayTask(function()
            beamjoy_vehicles.setGhostReason(vid, "racePit", false, true)
        end, 3000, task)
    end
end

--- whether the car sits in the box : its centre within the box (by as much as the car's smaller
--- than it, half a metre more), lined up with it either way. A car bigger than its box counts once
--- centred on it
---@param veh table NGVehicle
---@param box table
---@return boolean
local function inBox(veh, box)
    local pos = beamjoy_vehicles.getVehiclePositionRotation(veh)
    local dir = vec3(box.dir.x, box.dir.y, 0)
    if dir:length() < 1e-4 then return false end
    dir = dir:normalized()
    local right = dir:cross(vec3(0, 0, 1))
    local d = pos - vec3(box.pos.x, box.pos.y, box.pos.z)
    if math.abs(d.z) > 3 then return false end
    local width, length = box.width or beamjoy_pits.BOX_WIDTH, box.length or beamjoy_pits.BOX_LENGTH
    local slackL = math.max(0, length - veh:getInitialLength()) / 2 + .5
    local slackW = math.max(0, width - veh:getInitialWidth()) / 2 + .5
    if math.abs(d:dot(dir)) > slackL or math.abs(d:dot(right)) > slackW then return false end
    local heading = vec3(veh:getDirectionVector().x, veh:getDirectionVector().y, 0)
    return heading:length() > 1e-4 and math.abs(heading:normalized():dot(dir)) >= .94
end

--- puts the car in its box : the game's own placement (the unwrapped spawn.safeTeleport, so the
--- reset gate in beamjoy_inputs doesn't take it for a player's repair), repaired or not
---@param myVeh table
---@param box table
---@param repair boolean
local function placeInBox(myVeh, box, repair)
    local base = beamjoy_inputs and beamjoy_inputs.baseFunctions and beamjoy_inputs.baseFunctions.extensions and
        beamjoy_inputs.baseFunctions.extensions.spawn
    local safeTeleport = base and base.safeTeleport or spawn.safeTeleport
    beamjoy_raceRunner.expectReset(myVeh.vid)
    local dir = vec3(box.dir.x, box.dir.y, box.dir.z)
    safeTeleport(myVeh.veh, vec3(box.pos.x, box.pos.y, box.pos.z), quatFromDir(dir:normalized()),
        nil, nil, nil, true, repair)
end

--- repairs the car where it stands, as the game's own recovery prompt does (its damage gone, the fuel
--- kept : the race keeps it on resets, beamjoy_vehicles)
---@param myVeh table
local function repairInPlace(myVeh)
    local base = beamjoy_inputs and beamjoy_inputs.baseFunctions and beamjoy_inputs.baseFunctions.extensions and
        beamjoy_inputs.baseFunctions.extensions.spawn
    local safeTeleport = base and base.safeTeleport or spawn.safeTeleport
    beamjoy_raceRunner.expectReset(myVeh.vid)
    local veh = myVeh.veh
    safeTeleport(veh, veh:getPosition(), quatFromDir(veh:getDirectionVector()), nil, nil, nil, nil, true)
end

-- ---------------------------------------------------------------------------------------------
-- tanks

---@type table<integer, fun(tanks: table[])[]> vid -> the callbacks waiting (the first reading back
---answers them all)
local pendingTanks = {}

-- runs in the vehicle's Lua : its fuel tanks and batteries
local TANKS_CMD = [[
local out = {}
for name, s in pairs(energyStorage.getStorages()) do
    if (s.type == "fuelTank" or s.type == "electricBattery") and (s.energyCapacity or 0) > 0 then
        out[#out + 1] = { name = name, type = s.type, energyType = s.energyType, stored = s.storedEnergy,
            max = s.energyCapacity, capacity = s.capacity }
    end
end
obj:queueGameEngineLua(string.format("beamjoy_racePits.onTanks(%d, %%q)", jsonEncode(out)))
]]

--- the car's tanks : `{name, type, energyType, stored, max (J), capacity (L, or kWh a battery)}` each
---@param myVeh table
---@param callback fun(tanks: table[])
function M.readTanks(myVeh, callback)
    pendingTanks[myVeh.vid] = pendingTanks[myVeh.vid] or {}
    table.insert(pendingTanks[myVeh.vid], callback)
    myVeh.veh:queueLuaCommand(string.format(TANKS_CMD, myVeh.vid))
end

--- the tanks summed as the HUD and the pit menu show them : fuel in litres (any fuel tank), else a
--- battery in kWh ; nil without either
---@param tanks table[]
---@return {kind: "fuel"|"battery", stored: number, capacity: number}?
local function tankSummary(tanks)
    local fuel = { kind = "fuel", stored = 0, capacity = 0 }
    local battery = { kind = "battery", stored = 0, capacity = 0 }
    for _, t in ipairs(tanks) do
        if t.type == "fuelTank" and (t.capacity or 0) > 0 then
            fuel.capacity = fuel.capacity + t.capacity
            fuel.stored = fuel.stored + t.capacity * math.max(0, math.min(1, t.stored / t.max))
        elseif t.type == "electricBattery" then
            battery.capacity = battery.capacity + t.max / 3600000
            battery.stored = battery.stored + math.max(0, t.stored) / 3600000
        end
    end
    if fuel.capacity > 0 then return fuel end
    return battery.capacity > 0 and battery or nil
end

---@param vid integer
---@param json string
function M.onTanks(vid, json)
    local callbacks = pendingTanks[vid] or {}
    pendingTanks[vid] = nil
    local ok, tanks = pcall(jsonDecode, json)
    tanks = ok and type(tanks) == "table" and tanks or {}
    -- the last seen, for the HUD's plan line (its litres) and the menu
    M.tank, M.tankVid = tankSummary(tanks), vid
    for _, callback in ipairs(callbacks) do callback(tanks) end
end

--- sets each tank's energy (name -> J) in the vehicle's Lua (interactEnergyStorage's own assignment)
---@param veh table NGVehicle
---@param energies table<string, number>
local function setTankEnergies(veh, energies)
    local parts = {}
    for name, energy in pairs(energies) do
        parts[#parts + 1] = string.format("do local s = energyStorage.getStorage(%q) if s then s.storedEnergy = %f end end",
            name, energy)
    end
    if #parts > 0 then veh:queueLuaCommand(table.concat(parts, "\n")) end
end

--- every tank to `ratio` of its capacity (a phase's start fuel, settings.startFuelPct)
---@param myVeh table
---@param ratio number
local function setFuelLevel(myVeh, ratio)
    M.readTanks(myVeh, function(tanks)
        local energies = {}
        for _, t in ipairs(tanks) do energies[t.name] = t.max * ratio end
        setTankEnergies(myVeh.veh, energies)
    end)
end

--- what a stop does to this car, from its tanks and damage : the fuel each tank gets, the repair,
--- and how long each takes (ms)
---@param settings table
---@param tanks table[]
---@param damage table? beamjoy_pits.measureDamage's
---@return {energies: table<string, number>, fuelL: number, fuelMs: integer, repair: boolean, repairMs: integer, damage: table?}
function M.planWork(settings, tanks, damage)
    local work = { energies = {}, fuelL = 0, fuelMs = 0, repair = false, repairMs = 0, damage = damage }
    local plan = M.plan
    if settings.pitRefuel ~= false and plan.refuel then
        local add = math.max(0, math.min(1, tonumber(plan.fuelAdd) or 0))
        local rate = math.max(1, settings.pitFuelRatePct or 5) / 100
        for _, t in ipairs(tanks) do
            local room = math.max(0, 1 - t.stored / t.max)
            local share = math.min(add, room)
            if share > 0.001 then
                work.energies[t.name] = t.stored + share * t.max
                work.fuelMs = math.max(work.fuelMs, math.ceil(share / rate * 1000))
                if t.type == "fuelTank" then work.fuelL = work.fuelL + share * (t.capacity or 0) end
            end
        end
    end
    if settings.pitRepair ~= false and plan.repair and damage then
        local seconds = beamjoy_pits.repairSeconds(damage, settings.pitRepairMaxS or 60)
        if seconds > 0 then
            work.repair = true
            work.repairMs = math.ceil(seconds * 1000)
        end
    end
    return work
end

-- ---------------------------------------------------------------------------------------------
-- the pass through the lane

--- this game puts the player in the lane : a crossing of PIT IN, a tow, a start from the box
---@param ctx table
---@param from integer the step the lane's skipped steps follow (0 : a start from the box)
local function enterPit(ctx, from)
    M.inPit = true
    local due = false
    for _, step in ipairs(pitSteps(ctx.race, from)) do
        if step == 1 then due = true end
    end
    -- a start from the box isn't a stop : the car's standing in it at the green light
    M.pass = { lineDue = due, stopped = from == 0 }
    afterExitGate = nil
    lastLy = {}
end

--- out of the lane (PIT OUT, or back the way they came)
local function leavePit()
    M.inPit = false
    M.pass = nil
    lastLy = {}
end

--- a line crossed between last frame and this one (the gates' own test, raceRunner.lua) : its
--- direction, and the race time it happened at
---@param key string
---@param line table {pos, dir, width?, height?}
---@param vPos vec3
---@param myVeh table
---@param reach number? sideways reach without the line's own width (the start/finish line across the lane)
---@return boolean crossed, boolean forward, number? crossingMs
local function planeCrossed(key, line, vPos, myVeh, reach)
    local pos = vec3(line.pos.x, line.pos.y, line.pos.z)
    local dir = vec3(line.dir.x, line.dir.y, line.dir.z):normalized()
    local up = vec3(0, 0, 1)
    local d = vPos - pos
    local lx, ly, lz = d:dot(dir:cross(up)), d:dot(dir), d:dot(up)
    local prevLy = lastLy[key]
    lastLy[key] = ly
    if prevLy == nil or (prevLy < 0) == (ly < 0) then return false, false end
    local leniencyX = myVeh.veh:getInitialWidth() / 4
    local leniencyZ = myVeh.veh:getInitialHeight() / 4
    local halfWidth = reach or (line.width or 8) / 2
    local height = math.max(line.height or 4, reach and 5 or 0)
    if math.abs(lx) > halfWidth + leniencyX or lz < -leniencyZ - (reach and 3 or 0) or lz > height + leniencyZ then
        return false, false
    end
    lastLy[key] = nil
    local span = math.abs(prevLy) + math.abs(ly)
    local overshoot = span > 0 and (math.abs(ly) / span) or 0
    local now = elapsedMs or 0
    return true, prevLy < 0, now - overshoot * (now - (prevElapsedMs or now))
end

-- ---------------------------------------------------------------------------------------------
-- holds and the stop

--- the car frozen (reasserted : resets and other holds release it)
---@param myVeh table
local function holdCar(myVeh)
    if myVeh.veh.froze ~= "1" then beamjoy_vehicles.setFreeze(myVeh.vid, true) end
end

---@param myVeh table?
local function releaseCar(myVeh)
    if not myVeh then return end
    -- a reset penalty still being served keeps it (raceRunner.lua's own lock releases it)
    if beamjoy_raceRunner.resetPenaltyLockedUntilMs then return end
    beamjoy_vehicles.setFreeze(myVeh.vid, false)
end

--- the stop ends early (out of the race, the phase over) : nothing's done, the car's let go
---@param myVeh table?
local function abortStop(myVeh)
    local stop = M.stop
    if not stop then return end
    M.stop = nil
    releaseCar(myVeh)
    if stop.previousCamera and camera.getCamera() == camera.CAMERAS.EXTERNAL then
        camera.setCamera(stop.previousCamera)
    end
    -- the box's colour (raceMarkers.lua)
    extensions.hook("onBJRaceMarkersRefresh")
end

--- stopped in the box : the car's held on the external camera, its tanks and damage read, then the
--- plan's work timed (update finishes it)
---@param ctx table
---@param myVeh table
local function startStop(ctx, myVeh)
    M.pass.stopped = true
    local previous = camera.getCamera()
    M.stop = { startMs = GetCurrentTimeMillis(), previousCamera = previous ~= camera.CAMERAS.EXTERNAL and previous or nil }
    holdCar(myVeh)
    camera.setCamera(camera.CAMERAS.EXTERNAL)
    extensions.hook("onBJRaceMarkersRefresh")
    local stop = M.stop
    M.readTanks(myVeh, function(tanks)
        local function measured(damage)
            if M.stop ~= stop then return end
            stop.work = M.planWork(ctx.settings, tanks, damage)
            stop.endMs = GetCurrentTimeMillis() + stop.work.fuelMs + stop.work.repairMs
        end
        if ctx.settings.pitRepair ~= false and M.plan.repair then
            beamjoy_pits.measureDamage(myVeh, measured)
        else
            measured(nil)
        end
    end)
    -- the readings never came back (the car went) : nothing to do then
    async.delayTask(function()
        if M.stop == stop and not stop.work then
            stop.work = { energies = {}, fuelL = 0, fuelMs = 0, repair = false, repairMs = 0 }
            stop.endMs = GetCurrentTimeMillis()
        end
    end, 3000, "BJRacePitStopReadings")
end

--- the stop's time is up : the repair, then the fuel (after the repair's reset), "stop", the car let go
---@param myVeh table
local function finishStop(myVeh)
    local stop = M.stop
    M.stop = nil
    local work = stop.work
    if work.repair then repairInPlace(myVeh) end
    local energies = work.energies
    async.delayTask(function()
        local own = beamjoy_vehicles.getCurrentOwn()
        if own and own.vid == myVeh.vid and next(energies) then setTankEnergies(own.veh, energies) end
    end, work.repair and 400 or 0, "BJRacePitStopFuel")
    send("stop", elapsedMs, {
        fuelL = math.floor(work.fuelL * 10 + .5) / 10,
        repair = work.repair,
        durationMs = work.fuelMs + work.repairMs,
    })
    if work.fuelMs + work.repairMs > 0 then
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Fueling_Petrol_Simple')
    end
    toast.info(beamjoy_lang.translate("beamjoy.race.pit.stopDone"), nil, 3)
    releaseCar(myVeh)
    if stop.previousCamera and camera.getCamera() == camera.CAMERAS.EXTERNAL then
        camera.setCamera(stop.previousCamera)
    end
    extensions.hook("onBJRaceMarkersRefresh")
end

-- ---------------------------------------------------------------------------------------------
-- the state, kept with the server's

--- everything this module holds off (out of a pit race, or a new phase)
---@param myVeh table?
local function clearAll(myVeh)
    abortStop(myVeh)
    if M.holding then releaseCar(myVeh) end
    M.holding = nil
    leavePit()
    afterExitGate, lastGate, towHandled, towLocalUntilMs = nil, nil, nil, nil
    if limiterKmh then setLimiter(myVeh and myVeh.veh, nil) end
    if myVeh and ghostOn then setGhost(myVeh.vid, false) end
    ghostOn = nil
end

--- the server's view, followed where it changed : in the lane (a start from the box, a tow, a new
--- phase), a tow's hold, back in the box after the phase
---@param ctx table
---@param myVeh table?
local function followServer(ctx, myVeh)
    local p = ctx.participant
    local key = phaseKey(ctx.session)
    if statePhase ~= key then
        -- a new phase (or a first sighting) : its own state, from scratch
        clearAll(myVeh)
        statePhase = key
        serverInPit, serverReturned = nil, nil
    end
    local inPit = p.inPit == true
    if inPit ~= serverInPit then
        serverInPit = inPit
        if inPit and not M.inPit then
            enterPit(ctx, p.currentGate == 0 and 0 or ctx.race.pit.fromStep)
            -- a tow that ended their race (the steps it credited finished it) : no hold, but to the box
            local box = ownBox(ctx)
            if p.finished and not p.towUntilMs and towAskedMs and GetCurrentTimeMillis() - towAskedMs < 5000 and
                myVeh and box then
                towAskedMs = nil
                placeInBox(myVeh, box, false)
            end
        elseif not inPit and M.inPit and not (M.pass and M.pass.entryConfirmBy) then
            leavePit()
        end
    end
    if M.pass and M.pass.entryConfirmBy and inPit then M.pass.entryConfirmBy = nil end
    if afterExitGate and p.currentGate == afterExitGate then afterExitGate = nil end

    -- towed : into the box, held for the drive back
    if p.towUntilMs and p.towUntilMs ~= towHandled then
        towHandled = p.towUntilMs
        local box = ownBox(ctx)
        if myVeh and box and not p.finished then
            abortStop(myVeh)
            placeInBox(myVeh, box, false)
            enterPit(ctx, ctx.race.pit.fromStep)
            M.holding = "tow"
            local now = serverNow()
            towLocalUntilMs = GetCurrentTimeMillis() +
                (now and math.max(0, p.towUntilMs - now) or M.towHoldMs(ctx.race, p, ctx.settings.pitTowSpeed))
            toast.info(beamjoy_lang.translate("beamjoy.race.pit.towed"):var({
                seconds = math.ceil((towLocalUntilMs - GetCurrentTimeMillis()) / 1000) }), nil, 6)
        end
    end

    -- back in the box after the phase (driven there, or towed : then put there)
    local returned = p.pitReturned == true
    if returned ~= serverReturned then
        serverReturned = returned
        if returned and myVeh then
            local box = ownBox(ctx)
            if box and not inBox(myVeh.veh, box) then
                abortStop(myVeh)
                placeInBox(myVeh, box, false)
            end
            if M.holding ~= "returned" then
                toast.info(beamjoy_lang.translate("beamjoy.race.pit.returned"), nil, 6)
            end
            M.holding = "returned"
            if not M.inPit then enterPit(ctx, ctx.race.pit.fromStep) end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- the UI : the race HUD's pit line and Tow / Pit buttons, the pit menu (windows/pitControl)

--- the game's own volume unit : the menu and the HUD show gallons (US) then
---@return boolean
local function gallons()
    return settings.getValue("uiUnitVolume") == "gal"
end

--- the pit status for the HUD : nil out of a pit race
---@param ctx table?
---@return table?
local function statusOf(ctx)
    if not ctx then return nil end
    local p, s = ctx.participant, ctx.settings
    local now = GetCurrentTimeMillis()
    local status = {
        tank = M.tank,
        gallons = gallons(),
        slot = p.pitSlot,
        inPit = M.inPit,
        limitKmh = ctx.race.pit.speedLimitKmh,
        stops = p.pitStops or 0,
        required = s.pitStops or 0,
        canTow = s.pitTow ~= false and not M.inPit and not M.holding and
            ((not p.finished and ctx.session.state == "RACE") or (p.finished and p.pitReturnPending == true and
                (ctx.session.state == "RACE" or ctx.session.state == "BREAK"))),
        towHoldMs = (not p.finished) and M.towHoldMs(ctx.race, p, s.pitTowSpeed) or 0,
        returnPending = p.pitReturnPending == true and not M.holding,
        plan = M.plan,
        refuel = s.pitRefuel ~= false,
        repair = s.pitRepair ~= false,
    }
    if M.stop then
        status.stage = "stop"
        local w = M.stop.work
        if w then
            status.fuelMs, status.repairMs, status.fuelL = w.fuelMs, w.repairMs, w.fuelL
            status.leftMs = math.max(0, (M.stop.endMs or now) - now)
        end
    elseif M.holding == "tow" then
        status.stage = "towed"
        status.leftMs = math.max(0, (towLocalUntilMs or now) - now)
    elseif M.holding == "returned" then
        status.stage = "held"
    elseif M.inPit then
        status.stage = "lane"
    else
        status.stage = "track"
    end
    return status
end

--- sends the status when it changed (timers : every quarter second), or now (`force`)
---@param force boolean?
function M.pushStatus(force)
    local now = GetCurrentTimeMillis()
    if not force and lastStatusMs and now - lastStatusMs < 250 then return end
    lastStatusMs = now
    local status = statusOf(context())
    local json = status and jsonEncode(status) or "null"
    if not force and json == lastStatusJson then return end
    lastStatusJson = json
    beamjoy_communications_ui.send("BJRacePitStatus", status or { active = false })
end

-- the menu has the pad while it's open (its rows, B to close)
local MENU_NAV_OWNER = "pitControl"
-- the car read again this often while the menu's open (its damage changes), and given up on after
local MENU_READ_MS, MENU_READ_TIMEOUT_MS = 2000, 3000
local menuReadAtMs, menuReading

--- what the menu shows : the plan, the race's pit rules, the car's tanks and damage
local function pushMenu()
    local ctx = context()
    if not M.menuOpen or not ctx then
        return beamjoy_communications_ui.send("BJRacePitMenu", { open = false })
    end
    local p, s = ctx.participant, ctx.settings
    beamjoy_communications_ui.send("BJRacePitMenu", {
        open = true,
        slot = p.pitSlot,
        stops = p.pitStops or 0,
        required = s.pitStops or 0,
        refuelAllowed = s.pitRefuel ~= false,
        repairAllowed = s.pitRepair ~= false,
        ratePct = s.pitFuelRatePct or 5,
        repairMaxS = s.pitRepairMaxS or 60,
        plan = M.plan,
        tank = M.tankVid == (beamjoy_vehicles.getCurrentOwn() or {}).vid and M.tank or nil,
        damage = M.menuDamage,
        gallons = gallons(),
    })
end

--- the car's tanks and damage read for the menu (one reading at a time), then shown
---@param ctx table
---@param myVeh table
local function readForMenu(ctx, myVeh)
    local now = GetCurrentTimeMillis()
    if menuReading and now - (menuReadAtMs or 0) < MENU_READ_TIMEOUT_MS then return end
    menuReading, menuReadAtMs = true, now
    local maxS = ctx.settings.pitRepairMaxS or 60
    M.readTanks(myVeh, function()
        if ctx.settings.pitRepair == false then
            menuReading = false
            return pushMenu()
        end
        beamjoy_pits.measureDamage(myVeh, function(r)
            menuReading = false
            M.menuDamage = not r.error and beamjoy_pits.damageSummary(r, maxS) or nil
            pushMenu()
        end)
    end)
end

--- the HUD's Pit : the menu opens with the pad (a racer in a race with pits)
function M.openMenu()
    local ctx = context()
    if not ctx then return end
    M.menuOpen = true
    beamjoy_uiNav.acquire(MENU_NAV_OWNER)
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    if myVeh then readForMenu(ctx, myVeh) end
    pushMenu()
end

function M.closeMenu()
    if not M.menuOpen then return end
    M.menuOpen = false
    beamjoy_uiNav.release(MENU_NAV_OWNER)
    pushMenu()
end

--- the plan from the pit menu (saved as it's changed)
---@param plan table
function M.setPlan(plan)
    if type(plan) ~= "table" then return end
    M.plan = {
        refuel = plan.refuel ~= false,
        fuelAdd = math.max(0, math.min(1, tonumber(plan.fuelAdd) or 1)),
        repair = plan.repair ~= false,
    }
    M.pushStatus(true)
end

--- the HUD's Tow to pits : asked of the server, which decides (the car moves once it says so)
function M.requestTow()
    local ctx = context()
    if not ctx or ctx.settings.pitTow == false or M.inPit or M.holding then return end
    local p, state = ctx.participant, ctx.session.state
    -- racing, or finished and asked back to the box (racing still, or the break)
    if p.finished then
        if not p.pitReturnPending or (state ~= "RACE" and state ~= "BREAK") then return end
    elseif state ~= "RACE" then
        return
    end
    local runner = beamjoy_raceRunner
    if runner.personalAt and runner.personalStage ~= "go" then return end
    towAskedMs = GetCurrentTimeMillis()
    send("tow", runner.raceElapsedNowMs() or 0)
end

-- ---------------------------------------------------------------------------------------------
-- for raceRunner.lua

--- whether the route's gates are left alone : in the lane, the server credits them
---@return boolean
function M.skipsGates()
    return M.inPit and context() ~= nil
end

--- the step a racer's next gate follows : the server's, or after PIT OUT the lane's last credited
--- step until its echo
---@param participant table
---@return integer
function M.currentGate(participant)
    return afterExitGate or participant.currentGate or 0
end

--- a gate crossing just sent (its step)
---@param step integer
function M.onGateSent(step)
    lastGate = step
    afterExitGate = nil
end

--- where a reset in the pit lane puts the car : its box (nil : not in the lane)
---@return {pos: table, dir: table}?
function M.resetTarget()
    if not M.inPit then return nil end
    local ctx = context()
    return ctx and ownBox(ctx) or nil
end

--- puts the car in its box (a "last road" reset in the lane), repaired or not
---@param myVeh table
---@param repair boolean
function M.toBox(myVeh, repair)
    local ctx = context()
    local box = ctx and ownBox(ctx)
    if box and myVeh then placeInBox(myVeh, box, repair) end
end

--- whether the car is meant to stand still (a stop, a hold) : not a stall
---@return boolean
function M.holdsCar()
    return M.inPit
end

--- whether resets keep the fuel (beamjoy_vehicles) : in a race with pits, the tanks are the pits' to fill
---@return boolean
function M.keepsFuel()
    local ctx = context()
    if not ctx then return false end
    local state = ctx.session.state
    return state == "COUNTDOWN" or state == "RACE" or state == "BREAK"
end

--- a session update reached raceRunner.lua (after its own transitions) : the phase's countdown sets the
--- tanks to its start fuel (below 100 %), the HUD's told
---@param previousState string?
function M.onSessionUpdate(previousState)
    local ctx = context()
    if not ctx then return M.pushStatus() end
    if ctx.session.state == "COUNTDOWN" and previousState ~= "COUNTDOWN" then
        beamjoy_vehicles.refreshResetPreserveFlags()
        local myVeh = beamjoy_vehicles.getCurrentOwn()
        local pct = ctx.settings.startFuelPct or 100
        -- after the grid placement (a reset) has gone through ; 100 % leaves the tank as the car's
        -- set up (its tuning's fuel, direct report : it was filled)
        if myVeh and pct < 100 then
            async.delayTask(function()
                local own = beamjoy_vehicles.getCurrentOwn()
                if own and own.vid == myVeh.vid then setFuelLevel(own, math.max(.05, math.min(1, pct / 100))) end
            end, 600, "BJRacePitStartFuel")
        end
    end
    if ctx.participant.finished and ctx.participant.pitReturnPending and M.askedReturn ~= statePhase then
        M.askedReturn = statePhase
        toast.info(beamjoy_lang.translate("beamjoy.race.pit.returnAsk"), nil, 8)
    end
    M.pushStatus()
end

-- ---------------------------------------------------------------------------------------------

local active = false
-- the tanks last read for the HUD (its plan line), when there's no menu reading them
local TANK_READ_MS = 5000
local tankReadAtMs = 0

local function onUpdate()
    local ctx = context()
    local myVeh = beamjoy_vehicles.getCurrentOwn()
    local state = ctx and ctx.session.state
    if not ctx or (state ~= "COUNTDOWN" and state ~= "RACE" and state ~= "BREAK") then
        if active then
            active = false
            clearAll(myVeh)
            statePhase = nil
            M.closeMenu()
            M.menuDamage = nil
            M.pushStatus(true)
        end
        return
    end
    active = true
    followServer(ctx, myVeh)
    local now = GetCurrentTimeMillis()
    if myVeh and M.menuOpen and now - (menuReadAtMs or 0) >= MENU_READ_MS then
        readForMenu(ctx, myVeh)
    elseif myVeh and M.tankVid ~= myVeh.vid and now - tankReadAtMs >= TANK_READ_MS then
        tankReadAtMs = now
        M.readTanks(myVeh, function() end)
    end
    local p, race, pit = ctx.participant, ctx.race, ctx.race.pit

    -- an entry the server didn't take : back on track
    if M.pass and M.pass.entryConfirmBy and GetCurrentTimeMillis() > M.pass.entryConfirmBy then
        leavePit()
    end

    prevElapsedMs = elapsedMs
    elapsedMs = beamjoy_raceRunner.raceElapsedNowMs()

    if myVeh then
        -- the limiter and the ghost follow the lane
        local wantKmh = M.inPit and pit.speedLimitKmh or nil
        if wantKmh ~= limiterKmh or (wantKmh and GetCurrentTimeMillis() - (lastLimiterMs or 0) > 500) then
            setLimiter(myVeh.veh, wantKmh)
        end
        setGhost(myVeh.vid, M.inPit and ctx.settings.pitGhost ~= false)

        -- held : towed until the hold's over, or back in the box after the phase until the next one
        if M.holding == "tow" then
            local until_ = p.towUntilMs
            local now = serverNow()
            local over = (now and until_ and now >= until_) or GetCurrentTimeMillis() >= (towLocalUntilMs or 0)
            if over or p.finished then
                M.holding = nil
                releaseCar(myVeh)
            else
                holdCar(myVeh)
            end
        elseif M.holding == "returned" then
            holdCar(myVeh)
        end

        -- the stop under way
        if M.stop then
            holdCar(myVeh)
            if state ~= "RACE" or p.finished then
                abortStop(myVeh)
            elseif M.stop.endMs and GetCurrentTimeMillis() >= M.stop.endMs then
                finishStop(myVeh)
            end
        end
    end

    local runner = beamjoy_raceRunner
    -- racing : the lane's timed ; finished (racing or the break) : only the way back to the box
    local racing = state == "RACE" and not p.finished and not runner.resumePending and
        not (runner.personalAt and runner.personalStage ~= "go")
    local moving = racing or (p.finished and (state == "RACE" or state == "BREAK"))
    if moving and myVeh and not M.holding and not M.stop then
        local vPos = beamjoy_vehicles.getVehiclePositionRotation(myVeh.veh) +
            vec3(0, 0, myVeh.veh:getInitialHeight() / 2)
        local returning = p.finished and p.pitReturnPending == true
        if not M.inPit then
            -- PIT IN : right after the lane's fromStep (its echo may still be on its way), or on the way
            -- back to the box after the phase
            local due = returning or (racing and (p.currentGate == pit.fromStep or lastGate == pit.fromStep))
            if due then
                local crossed, forward, ms = planeCrossed("entry", pit.entry, vPos, myVeh)
                if crossed and forward then
                    enterPit(ctx, pit.fromStep)
                    M.pass.entryConfirmBy = GetCurrentTimeMillis() + ENTRY_CONFIRM_MS
                    send("entry", ms, { speedKmh = math.floor(myVeh.veh:getVelocity():length() * 3.6 * 10) / 10 })
                end
            else
                lastLy.entry = nil
            end
        else
            -- back out through PIT IN : the lane's left (the server ends the pass at the next gate)
            local crossedIn, forwardIn = planeCrossed("entry", pit.entry, vPos, myVeh)
            if crossedIn and not forwardIn then
                leavePit()
            else
                local crossed, forward, ms = planeCrossed("exit", pit.exit, vPos, myVeh)
                if crossed and forward then
                    -- the server credits the lane's steps up to toStep's : the next gate is toStep
                    if not p.finished then
                        afterExitGate = (pit.toStep - 2) % #race.gates + 1
                    end
                    leavePit()
                    send("exit", ms)
                elseif M.pass and M.pass.lineDue and racing then
                    -- the start/finish line, where it continues across the lane
                    local g = race.gates[1]
                    local lineCrossed, lineForward, lineMs = planeCrossed("line", g, vPos, myVeh, LINE_REACH)
                    if lineCrossed and (lineForward or not race.oneWayGates) then
                        M.pass.lineDue = false
                        send("line", lineMs)
                    end
                end
                -- stopped in the box : the stop (racing), or back after the phase
                local box = ownBox(ctx)
                if M.inPit and M.pass and not M.pass.stopped and box and
                    myVeh.veh:getVelocity():length() < STOP_SPEED and inBox(myVeh.veh, box) then
                    if returning then
                        M.pass.stopped = true
                        M.holding = "returned"
                        holdCar(myVeh)
                        send("returned", elapsedMs)
                    elseif racing then
                        startStop(ctx, myVeh)
                    end
                end
            end
        end
    else
        lastLy = {}
    end
    M.pushStatus()
end

local function onInit()
    beamjoy_communications_ui.addHandler("BJRacePitTow", M.requestTow)
    beamjoy_communications_ui.addHandler("BJRacePitSetPlan", M.setPlan)
    beamjoy_communications_ui.addHandler("BJRacePitStatusRequest", function() M.pushStatus(true) end)
    beamjoy_communications_ui.addHandler("BJRacePitMenuOpen", M.openMenu)
    beamjoy_communications_ui.addHandler("BJRacePitMenuClose", M.closeMenu)
    beamjoy_communications_ui.addHandler("BJRacePitMenuRequest", pushMenu)
end

-- a car change mid-race (a new car) : nothing held over
local function onVehicleSwitched()
    lastLy = {}
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched

return M
