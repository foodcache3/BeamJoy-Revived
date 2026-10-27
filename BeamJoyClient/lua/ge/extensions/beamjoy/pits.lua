--- Race pits (PIT_SYSTEM_PLAN.md) : the pit boxes in the world (the game's own parking-spot marker,
--- its outline and stripes, one per start slot : setBoxes, drawn by raceMarkers.lua), and the damage
--- measure the pit repair time is built on, with its readout : `/bjdamage` (server chat command) asks
--- this client to measure its current car and show the numbers, for the crash tests that set the
--- repair-time curve. And the experimental tyre changes' work on the car (serviceCar : new tyres with
--- the damage kept, or a repair with the old tyres kept), shown on the other players' copies too.
---
--- Earlier measures didn't hold up : deliveries counted parts at integrity 0 (dents never count),
--- derby read map.objects' damage (dissipated energy : uncapped, grows with harmless hits, scales
--- with the car). The game's own part damage (beamstate.getPartDamageData, each part 0..1 from its
--- broken and deformed beams) is normalised per part ; weighted by each part's value it is the
--- share of the car the game itself prices as damaged.

local M = {
    dependencies = { "beamjoy_communications", "beamjoy_vehicles", "toast" },

    ---@type table<integer, fun(result: table)[]> vid -> the callbacks waiting (the pit menu's and a stop's
    ---can overlap : the first reading back answers them all)
    pending = {},
    ---@type table[] the pit boxes' markers shown (scenario/raceMarkers/parkingraceSpotMarker), in order
    boxMarkers = {},
    ---@type table? the race editor's box being placed with the mouse (setGhost), its own marker
    ghostMarker = nil,

    BOX_WIDTH = 2.6,
    BOX_LENGTH = 5.5,
}

-- the game's parking-spot marker (its constructor), loaded the first time a box is shown
local createSpotMarker
-- each marker's scene objects get a name of their own (a reload can leave the last ones behind)
local markerSerial = 0

---@return table a new parking-spot marker, shown
local function newMarker()
    createSpotMarker = createSpotMarker or require("scenario/raceMarkers/parkingraceSpotMarker")
    markerSerial = markerSerial + 1
    local marker = createSpotMarker("bjPitBox" .. markerSerial)
    marker:createMarkers()
    marker:show()
    return marker
end

---@param marker table
---@param box {pos: table, dir: table, width: number?, length: number?, color: table?, height: number?}
local function placeMarker(marker, box)
    local dir = vec3(box.dir.x, box.dir.y, 0)
    dir = dir:length() > 1e-4 and dir:normalized() or vec3(0, 1, 0)
    marker:setSpot(vec3(box.pos.x, box.pos.y, box.pos.z), quatFromDir(dir, vec3(0, 0, 1)),
        vec3(box.width or M.BOX_WIDTH, box.length or M.BOX_LENGTH, .5))
    -- a lower outline than the marker's own (1.2 m, set by setSpot) : its footprint kept
    if box.height then
        for _, id in ipairs(marker.outlineIds) do
            local outline = scenetree.findObjectById(id)
            if outline then
                local scl = vec3(outline:getScale())
                outline:setScaleXYZ(scl.x, scl.y, box.height)
            end
        end
    end
    marker:setColor(box.color or { 1, 1, 1, 1 })
end

--- the pit boxes shown : `{pos, dir, width?, length?, color = {r, g, b, a}}` each ; nil or none
--- hides them. Markers are kept and moved, made or removed only as the count changes
---@param list table[]?
function M.setBoxes(list)
    list = list or {}
    for i, box in ipairs(list) do
        M.boxMarkers[i] = M.boxMarkers[i] or newMarker()
        placeMarker(M.boxMarkers[i], box)
    end
    for i = #M.boxMarkers, #list + 1, -1 do
        M.boxMarkers[i]:clearMarkers()
        M.boxMarkers[i] = nil
    end
end

--- the race editor's box being placed with the mouse, where it would go (as setBoxes takes one) ;
--- nil hides it (kept for the next one : the mouse over the sidebar hides it too). Called every
--- frame : moved only when it moved
---@param box table?
function M.setGhost(box)
    local marker = M.ghostMarker
    if not box then
        if marker and marker.visible then marker:hide() end
        return
    end
    if not marker then
        marker = newMarker()
        M.ghostMarker = marker
    elseif not marker.visible then
        marker:show()
    end
    local last = marker.bjLast
    if last and last.pos:distance(box.pos) < .01 and last.dir:dot(box.dir) > .99999 then return end
    marker.bjLast = { pos = vec3(box.pos.x, box.pos.y, box.pos.z), dir = vec3(box.dir.x, box.dir.y, box.dir.z) }
    placeMarker(marker, box)
end

-- the tyre test's steps (below)
local updateTyreTest

local function onUpdate(dtReal)
    for _, marker in ipairs(M.boxMarkers) do marker:update(dtReal) end
    if M.ghostMarker then M.ghostMarker:update(dtReal) end
    updateTyreTest()
end

-- the level's objects go with it
local function onClientEndMission()
    M.setBoxes(nil)
    if M.ghostMarker then
        M.ghostMarker:clearMarkers()
        M.ghostMarker = nil
    end
end

-- engine faults worth a mechanic's time (damageTracker "engine" flags the game sets)
local ENGINE_FLAGS = { "engineDisabled", "engineLockedUp", "engineHydrolocked", "blockMelted",
    "cylinderWallsMelted", "headGasketDamaged", "pistonRingsDamaged", "rodBearingsDamaged",
    "engineReducedTorque", "impactDamage", "radiatorLeak", "oilpanLeak", "oilRadiatorLeak",
    "exhaustBroken", "turbochargerDamaged", "superchargerDamaged", "inductionSystemDamaged" }

-- runs in the vehicle's Lua : every reading, sent back as one JSON string
local MEASURE_CMD = [[
local ok, res = pcall(function()
    local out = { parts = {}, zones = {}, flatTyres = 0, brokenWheels = 0, engine = {}, powertrain = {} }
    local damaged = beamstate.getPartDamageData and beamstate.getPartDamageData() or {}
    local valueSum, valueDmg, beamSum, beamDmg = 0, 0, 0, 0
    for path, partName in pairs(v.data.activeParts or {}) do
        local part = v.data.activePartsData and v.data.activePartsData[partName]
        if part then
            local value = part.information and part.information.value or 0
            local beams = part.beams and tableSize(part.beams) or 0
            local d = damaged[path] and damaged[path].damage or 0
            valueSum, valueDmg = valueSum + value, valueDmg + value * d
            beamSum, beamDmg = beamSum + beams, beamDmg + beams * d
            if d > 0 then
                table.insert(out.parts, { name = damaged[path].name, damage = d, value = value })
            end
        end
    end
    table.sort(out.parts, function(a, b) return a.damage * (a.value + 1) > b.damage * (b.value + 1) end)
    while #out.parts > 8 do table.remove(out.parts) end
    out.valueShare = valueSum > 0 and valueDmg / valueSum or 0
    out.beamShare = beamSum > 0 and beamDmg / beamSum or 0
    out.valueDamaged, out.valueTotal = valueDmg, valueSum
    out.zones = beamstate.getBodyZoneDamage and beamstate.getBodyZoneDamage() or {}
    for _, wd in pairs(wheels.wheels or {}) do
        if wd.isTireDeflated then out.flatTyres = out.flatTyres + 1 end
        if wd.isBroken then out.brokenWheels = out.brokenWheels + 1 end
    end
    for _, flag in ipairs(%s) do
        if damageTracker.getDamage("engine", flag) then table.insert(out.engine, flag) end
    end
    for _, device in pairs(powertrain.getDevices and powertrain.getDevices() or {}) do
        if damageTracker.getDamage("powertrain", device.name) then table.insert(out.powertrain, device.name) end
    end
    out.energy = beamstate.damage or 0
    return out
end)
obj:queueGameEngineLua(string.format("beamjoy_pits.onDamageMeasured(%d, %%q)", jsonEncode(ok and res or { error = tostring(res) })))
]]

--- measures a vehicle's damage ; `callback` gets the readings (see MEASURE_CMD)
---@param veh table BJ vehicle (beamjoy_vehicles)
---@param callback fun(result: table)
function M.measureDamage(veh, callback)
    if not veh or not veh.veh then return end
    M.pending[veh.vid] = M.pending[veh.vid] or {}
    table.insert(M.pending[veh.vid], callback)
    local flags = {}
    for _, f in ipairs(ENGINE_FLAGS) do flags[#flags + 1] = string.format("%q", f) end
    veh.veh:queueLuaCommand(string.format(MEASURE_CMD, "{" .. table.concat(flags, ",") .. "}", veh.vid))
end

---@param vid integer
---@param json string
function M.onDamageMeasured(vid, json)
    local callbacks = M.pending[vid] or {}
    M.pending[vid] = nil
    local ok, result = pcall(jsonDecode, json)
    if not ok or type(result) ~= "table" then return end
    for _, callback in ipairs(callbacks) do callback(result) end
end

--- the readings as the pit menu shows them : the repair's time, the share damaged, the 3 worst parts
--- (their names, % damaged), flat tyres, wheels torn off, an engine or powertrain fault
---@param r table measureDamage's
---@param maxS number
---@param tyresApart boolean? tyre changes apart from repairs : flats aren't the repair's
---@return {seconds: number, share: number, parts: {name: string, pct: integer}[], flatTyres: integer, brokenWheels: integer, fault: boolean}
function M.damageSummary(r, maxS, tyresApart)
    local parts = {}
    for i = 1, math.min(3, #(r.parts or {})) do
        parts[i] = { name = tostring(r.parts[i].name), pct = math.floor((tonumber(r.parts[i].damage) or 0) * 100 + .5) }
    end
    return {
        seconds = M.repairSeconds(r, maxS, tyresApart),
        share = tonumber(r.valueShare) or 0,
        parts = parts,
        flatTyres = tonumber(r.flatTyres) or 0,
        brokenWheels = tonumber(r.brokenWheels) or 0,
        fault = #(r.engine or {}) > 0 or #(r.powertrain or {}) > 0,
    }
end

--- a repair's time, seconds, from measureDamage's readings : the share of the car's value damaged
--- times `maxS`, 4 s a flat tyre (not with tyre changes apart : the tyres' own time then), 10 s for
--- an engine or powertrain fault, up to `maxS`. Provisional : the curve is set from the crash tests
--- (PIT_SYSTEM_PLAN.md §6)
---@param r table
---@param maxS number
---@param tyresApart boolean?
---@return number
function M.repairSeconds(r, maxS, tyresApart)
    if type(r) ~= "table" or r.error or maxS <= 0 then return 0 end
    local s = (tonumber(r.valueShare) or 0) * maxS + (tyresApart and 0 or 4 * (tonumber(r.flatTyres) or 0))
    if #(r.engine or {}) > 0 or #(r.powertrain or {}) > 0 then s = s + 10 end
    return math.min(maxS, s)
end

local function pct(x) return string.format("%.1f%%", (tonumber(x) or 0) * 100) end

--- `/bjdamage` : the readout, as a toast and one log line to copy from
local function onDebugDamage()
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own then return toast.warn("No vehicle to measure", nil, 5) end
    M.measureDamage(own, function(r)
        LogInfo("[BJDamage] " .. (own.jbeam or "?") .. " " .. jsonEncode(r))
        if r.error then return toast.error("Damage measure failed : " .. r.error, nil, 8) end
        local parts = {}
        for i = 1, math.min(3, #r.parts) do
            parts[#parts + 1] = string.format("%s %s", r.parts[i].name, pct(r.parts[i].damage))
        end
        local zones = {}
        for _, z in ipairs({ "FL", "FR", "ML", "MR", "RL", "RR" }) do
            zones[#zones + 1] = string.format("%s %.2f", z, tonumber(r.zones[z]) or 0)
        end
        toast.info(string.format("By value %s · by beams %s · %d damaged parts\n%s\nZones %s\nFlat tyres %d · engine %s · powertrain %s · energy %.0f kJ",
            pct(r.valueShare), pct(r.beamShare), #r.parts,
            #parts > 0 and table.concat(parts, ", ") or "no part damage",
            table.concat(zones, " "), r.flatTyres,
            #r.engine > 0 and table.concat(r.engine, ", ") or "ok",
            #r.powertrain > 0 and table.concat(r.powertrain, ", ") or "ok",
            (tonumber(r.energy) or 0) / 1000), "Damage (" .. (own.jbeam or "?") .. ")", 20)
    end)
end

-- ---------------------------------------------------------------------------------------------
-- the experimental tyre changes (the server's RacePits.ExperimentalTyres) : new tyres with the
-- car's damage kept, or a repair with its old tyres kept. The work runs in the car's own Lua
-- (lua/vehicle/extensions/beamjoy/tyreChange.lua, loaded for the one stop) : its snapshot, then the
-- game's reset here, then the shape put back during that reset (before the latches arm) and the
-- damage record written again. `/bjtyretest tyres|repair` runs it on its own, measured after.

local TYRE_EXT = "beamjoy_tyreChange"
-- the car settles after it all before the test measures it again
local TYRE_MEASURE_DELAY_MS = 1500
-- the car's Lua never answered (it went, or the extension failed to load) : given up after this
local SERVICE_TIMEOUT_MS = 8000

--- the server's experimental tyre changes are on
---@return boolean
function M.experimentalTyres()
    local cfg = beamjoy_config and beamjoy_config.data and beamjoy_config.data.RacePits
    return type(cfg) == "table" and cfg.ExperimentalTyres == true
end

---@type {vid: integer, mode: "tyres"|"repair", reset: fun(veh: userdata), applied: fun(ok: boolean, err: string?), at: integer, answered: boolean?}?
local service = nil
---@type {vid: integer, mode: "tyres"|"repair", before: table, measureAt: integer?, info: string?}?
local tyreTest = nil

---@param r table measureDamage's
---@return string
local function tyreTestLine(r)
    return string.format("value %s · %d parts · flats %d · wheels off %d · engine %s · powertrain %s",
        pct(r.valueShare), #(r.parts or {}), tonumber(r.flatTyres) or 0, tonumber(r.brokenWheels) or 0,
        #(r.engine or {}) > 0 and table.concat(r.engine, ", ") or "ok",
        #(r.powertrain or {}) > 0 and table.concat(r.powertrain, ", ") or "ok")
end

---@param veh userdata?
local function unloadTyreExt(veh)
    if veh then veh:queueLuaCommand(string.format("extensions.unload(%q)", TYRE_EXT)) end
end

--- the game's own reset in place, unwrapped (the reset gate in beamjoy_inputs doesn't take it for a
--- player's own reset)
---@param veh userdata
function M.resetInPlace(veh)
    local base = beamjoy_inputs and beamjoy_inputs.baseFunctions and beamjoy_inputs.baseFunctions.extensions and
        beamjoy_inputs.baseFunctions.extensions.spawn
    local safeTeleport = base and base.safeTeleport or spawn.safeTeleport
    safeTeleport(veh, veh:getPosition(), quatFromDir(veh:getDirectionVector()), nil, nil, nil, nil, true)
end

--- new tyres with the damage kept ("tyres"), or a repair with the old tyres kept ("repair"), on the
--- player's own car where it stands : `reset(veh)` is called to reset it (the caller's own reset,
--- racePits.lua's tells raceRunner it's coming), `applied(ok, err)` once the shape is back (the car
--- can go), or it failed. One at a time
---@param myVeh table BJ vehicle (beamjoy_vehicles), the player's own
---@param mode "tyres"|"repair"
---@param reset fun(veh: userdata)
---@param applied fun(ok: boolean, err: string?)
---@return boolean started
function M.serviceCar(myVeh, mode, reset, applied)
    if service or not myVeh or not myVeh.veh then return false end
    service = { vid = myVeh.vid, mode = mode, reset = reset, applied = applied, at = GetCurrentTimeMillis() }
    myVeh.veh:queueLuaCommand(string.format("extensions.load(%q) ; %s.prepare(%q)", TYRE_EXT, TYRE_EXT, mode))
    return true
end

---@param ok boolean
---@param err string?
local function serviceApplied(ok, err)
    local sv = service
    if not sv or sv.answered then return end
    sv.answered = true
    local done, res = pcall(sv.applied, ok, err)
    if not done then LogError("[BJTyres] applied callback failed : " .. tostring(res)) end
end

--- `/bjtyretest tyres|repair` : your car, where it stands. Not in an activity : it's a free reset
---@param mode string?
local function onDebugTyres(mode)
    mode = mode == "repair" and mode or "tyres"
    if not M.experimentalTyres() then return toast.warn("Experimental tyre changes are off", nil, 5) end
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own then return toast.warn("No vehicle to test", nil, 5) end
    if navigation and navigation.inActivity and navigation.inActivity() then
        return toast.warn("Not during a race or another activity", nil, 5)
    end
    if tyreTest or service then return toast.warn("A tyre change is already running", nil, 5) end
    M.measureDamage(own, function(before)
        if before.error then return toast.error("Damage measure failed : " .. before.error, nil, 8) end
        tyreTest = { vid = own.vid, mode = mode, before = before }
        M.serviceCar(own, mode, M.resetInPlace, function(ok, err)
            if not ok then
                toast.error("Tyre test failed : " .. tostring(err), nil, 10)
                tyreTest = nil
            end
        end)
    end)
end

-- the other players' copies : BeamMP resets them pristine and passes on only break groups, so the
-- change's plan (the vehicle extension's json : moved nodes in mm, beams, breaks, dents) goes
-- through the server, and each copy is reset again with it put back. Bounded on both ends (the
-- server relays a player's own car's plan only, at this size at most)
local TYRE_SHAPE_MAX_CHARS = 200000
-- a copy that doesn't answer is given up after this
local TYRE_REMOTE_TIMEOUT_MS = 15000
-- an armed copy waits this long for BeamMP's own reset of it (the owner's reset, on its way at the
-- same time as the plan) to put the plan back during ; none came : it's reset here. Resetting it
-- at once could have BeamMP's reset land after and wipe the shape again
local TYRE_REMOTE_WAIT_MS = 400
-- BeamMP's reset of the copy came this recently (usually before the plan) : no wait, reset now
local TYRE_REMOTE_RECENT_RESET_MS = 2000
---@type table<integer, {at: integer, armedAt: integer?, applied: boolean?}> copy's vid -> its state
local tyreRemote = {}
---@type table<integer, integer> vid -> its last reset
local lastResetAt = {}

---@param vid integer
---@param json string
local function sendTyreShape(vid, json)
    -- BeamMP's full id, "<ownerID>-<vehicleID>" (serverVID alone is only the vehicle part : every
    -- player numbers their cars from 0)
    local key = beamjoy_vehicles.serverKey(beamjoy_vehicles.vehicles[vid])
    if not key then return end
    if #json > TYRE_SHAPE_MAX_CHARS then
        return LogWarn(string.format("[BJTyreSync] plan too big to send (%d chars)", #json))
    end
    LogInfo(string.format("[BJTyreSync] plan sent for %s (%d chars)", key, #json))
    beamjoy_communications.send("tyreShape", key, json)
end

--- another player's change : their car's plan, put on our copy of it
---@param key string BeamMP's full id, "<ownerID>-<vehicleID>"
---@param json string
local function onTyreShape(key, json)
    if not M.experimentalTyres() then return end
    if type(key) ~= "string" or type(json) ~= "string" or #json > TYRE_SHAPE_MAX_CHARS then return end
    local copy = beamjoy_vehicles.getByServerKey(key)
    if not copy or copy.isLocal then
        return LogWarn("[BJTyreSync] no copy of " .. key .. " here")
    end
    local veh = getObjectByID(copy.vid)
    -- one at a time per copy : a plan arriving mid-way is dropped
    if veh and not tyreRemote[copy.vid] then
        LogInfo(string.format("[BJTyreSync] plan received for %s (%d chars)", key, #json))
        tyreRemote[copy.vid] = { at = GetCurrentTimeMillis() }
        veh:queueLuaCommand(string.format("extensions.load(%q) ; %s.armRemote(%q)", TYRE_EXT, TYRE_EXT, json))
    end
end

--- a copy's answer : armed (then BeamMP's reset, or ours, puts the plan back during it), applied,
--- or done
---@param vid integer
---@param step string
---@param err string
---@param info string
function M.onTyreRemoteStep(vid, step, err, info)
    if not tyreRemote[vid] then return end
    local veh = getObjectByID(vid)
    if err ~= "" or not veh then
        LogWarn("[BJTyreSync] copy " .. tostring(vid) .. ", " .. step .. " failed : " .. tostring(err))
        tyreRemote[vid] = nil
        unloadTyreExt(veh)
        return
    end
    if step == "armed" then
        local now = GetCurrentTimeMillis()
        if lastResetAt[vid] and now - lastResetAt[vid] < TYRE_REMOTE_RECENT_RESET_MS then
            M.resetInPlace(veh)
        else
            tyreRemote[vid].armedAt = now
        end
    elseif step == "applied" then
        tyreRemote[vid].applied = true
        LogInfo(string.format("[BJTyreSync] copy %d : shape in %d ms after the plan came",
            vid, GetCurrentTimeMillis() - tyreRemote[vid].at))
    elseif step == "restore" then
        LogInfo("[BJTyreSync] copy " .. tostring(vid) .. " | " .. info)
        tyreRemote[vid] = nil
        unloadTyreExt(veh)
    end
end

--- the own car's answer to a step : snapshot (then the reset), applied (the shape's back), shape
--- (the plan, for the other players), restore (all done, the figures) ; `err` empty when it went well
---@param vid integer
---@param step string
---@param err string
---@param info string
function M.onTyreStep(vid, step, err, info)
    local sv = service
    if not sv or sv.vid ~= vid then return end
    local veh = getObjectByID(vid)
    if err ~= "" or not veh then
        err = err ~= "" and err or "the car went"
        LogError(string.format("[BJTyres] %s, %s failed : %s", sv.mode, step, err))
        service = nil
        if tyreTest and tyreTest.vid == vid then tyreTest = nil end
        unloadTyreExt(veh)
        -- after the shape went back (the record's step failed) : the car's already let go
        if not sv.answered then
            sv.answered = true
            pcall(sv.applied, false, err)
        end
        return
    end
    if step == "snapshot" then
        sv.reset(veh)
    elseif step == "applied" then
        serviceApplied(true)
    elseif step == "shape" then
        -- during the reset, as soon as the plan is built : the other players' copies follow at once
        sendTyreShape(vid, info)
    elseif step == "restore" then
        LogInfo(string.format("[BJTyres] %s | %s", sv.mode, info))
        service = nil
        unloadTyreExt(veh)
        if tyreTest and tyreTest.vid == vid then
            tyreTest.info = info
            tyreTest.measureAt = GetCurrentTimeMillis() + TYRE_MEASURE_DELAY_MS
        end
    end
end

updateTyreTest = function()
    local now = GetCurrentTimeMillis()
    for vid, r in pairs(tyreRemote) do
        if r.armedAt and not r.applied and now - r.armedAt > TYRE_REMOTE_WAIT_MS then
            r.armedAt = nil
            local veh = getObjectByID(vid)
            if veh then M.resetInPlace(veh) end
        end
        if now - r.at > TYRE_REMOTE_TIMEOUT_MS then
            LogWarn("[BJTyreSync] copy " .. tostring(vid) .. " gave no answer")
            tyreRemote[vid] = nil
            unloadTyreExt(getObjectByID(vid))
        end
    end
    if service and now - service.at > SERVICE_TIMEOUT_MS then
        M.onTyreStep(service.vid, "answer", "no answer from the car", "")
    end
    if not tyreTest or not tyreTest.measureAt or now < tyreTest.measureAt then return end
    local veh = getObjectByID(tyreTest.vid)
    if not veh then
        tyreTest = nil
        return
    end
    tyreTest.measureAt = nil
    local test = tyreTest
    M.measureDamage({ vid = test.vid, veh = veh }, function(after)
        tyreTest = nil
        local title = test.mode == "repair" and "Repair only (old tyres kept)" or "Tyres only (damage kept)"
        local text = string.format("Before : %s\nAfter : %s\n%s", tyreTestLine(test.before),
            after.error and ("measure failed : " .. after.error) or tyreTestLine(after), test.info or "")
        LogInfo("[BJTyreTest] " .. test.mode .. " | " .. text:gsub("\n", " | "))
        toast.info(text, title, 20)
    end)
end

local function onInit()
    beamjoy_communications.addHandler("debugDamage", onDebugDamage)
    beamjoy_communications.addHandler("debugTyres", onDebugTyres)
    beamjoy_communications.addHandler("tyreShape", onTyreShape)
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onVehicleResetted = function(vid) lastResetAt[vid] = GetCurrentTimeMillis() end
M.onClientEndMission = onClientEndMission
M.onExtensionUnloaded = onClientEndMission

return M
