--- Race pits (PIT_SYSTEM_PLAN.md) : the pit boxes in the world (the game's own parking-spot marker,
--- its outline and stripes, one per start slot : setBoxes, drawn by raceMarkers.lua), and the damage
--- measure the pit repair time is built on, with its readout : `/bjdamage` (server chat command) asks
--- this client to measure its current car and show the numbers, for the crash tests that set the
--- repair-time curve.
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

local function onUpdate(dtReal)
    for _, marker in ipairs(M.boxMarkers) do marker:update(dtReal) end
    if M.ghostMarker then M.ghostMarker:update(dtReal) end
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
    local out = { parts = {}, zones = {}, flatTyres = 0, engine = {}, powertrain = {} }
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
--- (their names, % damaged), flat tyres, an engine or powertrain fault
---@param r table measureDamage's
---@param maxS number
---@return {seconds: number, share: number, parts: {name: string, pct: integer}[], flatTyres: integer, fault: boolean}
function M.damageSummary(r, maxS)
    local parts = {}
    for i = 1, math.min(3, #(r.parts or {})) do
        parts[i] = { name = tostring(r.parts[i].name), pct = math.floor((tonumber(r.parts[i].damage) or 0) * 100 + .5) }
    end
    return {
        seconds = M.repairSeconds(r, maxS),
        share = tonumber(r.valueShare) or 0,
        parts = parts,
        flatTyres = tonumber(r.flatTyres) or 0,
        fault = #(r.engine or {}) > 0 or #(r.powertrain or {}) > 0,
    }
end

--- a repair's time, seconds, from measureDamage's readings : the share of the car's value damaged
--- times `maxS`, 4 s a flat tyre, 10 s for an engine or powertrain fault, up to `maxS`. Provisional :
--- the curve is set from the crash tests (PIT_SYSTEM_PLAN.md §6)
---@param r table
---@param maxS number
---@return number
function M.repairSeconds(r, maxS)
    if type(r) ~= "table" or r.error or maxS <= 0 then return 0 end
    local s = (tonumber(r.valueShare) or 0) * maxS + 4 * (tonumber(r.flatTyres) or 0)
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

local function onInit()
    beamjoy_communications.addHandler("debugDamage", onDebugDamage)
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onClientEndMission = onClientEndMission
M.onExtensionUnloaded = onClientEndMission

return M
