--- BeamJoy's own drift zones (services/driftZones.lua, made in Config > Freeroam > Drift zones) : a
--- start gate, a route and a finish gate, with a corridor along the route. Drive through the start
--- gate the way the route goes and the zone starts ; your drifting is scored by the game's own drift
--- scorer (gameplay/drift : the same points, combos and tiers as its drift spots) until you cross the
--- finish gate, and the score goes on the zone's Drift board (beamjoy/freeroamChallenges.lua, under
--- "bj:<id>"), beside the game's own spots.
---
--- The scorer runs in its freeroam context : the zone resets it at the start and banks the drift
--- still going at the finish, as the game's drift spots do (gameplay/drift/freeroam/driftSpots.lua).
--- Out of the corridor for a couple of seconds, a reset, slowing time, changing gravity or taking
--- too long ends a run with no score. Shown in a small panel of its own (windows/driftZoneHud).

local M = {
    ---@type table[] the current map's zones (the server's cache)
    zones = {},
    --- the zone being driven : {zone, startMs, outSince, vid}
    ---@type table?
    run = nil,
    ---@type table[] zones drawn and watched (near you)
    nearby = {},
    editing = false,
}

local NEAR_DISTANCE = 600
-- seconds out of the corridor before a run ends, metres of slack past its edge
local OUT_GRACE = 2
local CORRIDOR_SLACK = 3
local MAX_RUN_SECONDS = 600
-- a start only counts rolling at least this fast (m/s)
local MIN_START_SPEED = 3
local TELEPORT_DISTANCE = 60
local HUD_PUSH_MS = 100
-- how long the result stays on the panel after a run
local RESULT_SECONDS = 6

local lastLy = {}
local prevFrameMs, frameMs
local lastPos
local lastHud = 0
--- the panel after a run : {zone name, state, score, reason, untilMs}
local result

-- GEOMETRY ------------------------------------------------------------------------------------

---@param p table
---@return vec3
local function v3(p) return vec3(p.x, p.y, p.z) end

---@param a vec3
---@param b vec3
---@return vec3 flat direction from a to b
local function flatDir(a, b)
    local d = vec3(b.x - a.x, b.y - a.y, 0)
    return d:length() > 1e-4 and d:normalized() or vec3(0, 1, 0)
end

--- the zone's start or finish gate : where it is and the way through it
---@param zone table
---@param which "start"|"finish"
---@return vec3 pos, vec3 dir
local function gate(zone, which)
    local pts = zone.points
    if which == "start" then return v3(pts[1]), flatDir(v3(pts[1]), v3(pts[2])) end
    local n = #pts
    return v3(pts[n]), flatDir(v3(pts[n - 1]), v3(pts[n]))
end
M.gate = gate

---@param p vec3
---@param a vec3
---@param b vec3
---@return number flat distance from p to the segment ab
local function segmentDistance(p, a, b)
    local abx, aby = b.x - a.x, b.y - a.y
    local len2 = abx * abx + aby * aby
    local t = len2 > 0 and math.max(0, math.min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2)) or 0
    local cx, cy = a.x + abx * t, a.y + aby * t
    return math.sqrt((p.x - cx) ^ 2 + (p.y - cy) ^ 2)
end

---@param zone table
---@param p vec3
---@return boolean within the corridor along the route
local function inCorridor(zone, p)
    local limit = zone.width / 2 + CORRIDOR_SLACK
    for i = 2, #zone.points do
        if segmentDistance(p, v3(zone.points[i - 1]), v3(zone.points[i])) <= limit then return true end
    end
    return false
end

--- whether the car went through a gate the way it faces since last frame
---@param key string
---@param pos vec3 the gate
---@param dir vec3
---@param width number
---@param p vec3 the car
---@return boolean
local function crossed(key, pos, dir, width, p)
    local right = dir:cross(vec3(0, 0, 1))
    local d = p - pos
    local lx, ly, lz = d:dot(right), d:dot(dir), d.z
    local prev = lastLy[key]
    lastLy[key] = ly
    return prev ~= nil and prev < 0 and ly >= 0 and math.abs(lx) <= width / 2 and math.abs(lz) < 6
end

-- STATE ---------------------------------------------------------------------------------------

---@return BJVehicle?
local function ownCar()
    local v = beamjoy_vehicles.getCurrentOwn()
    if not v or v.jbeam == beamjoy_vehicles.WALKING or v.isAi then return nil end
    return v
end

---@return boolean nothing else going on
local function free()
    if M.editing then return false end
    if navigation and navigation.inActivity and navigation.inActivity() then return false end
    if beamjoy_raceRunner and beamjoy_raceRunner.spectatingSession then return false end
    return not (beamjoy_raceFreeroam and beamjoy_raceFreeroam.run)
end

--- the game's drift scorer, loaded if needed (it's loaded with the game's drift spots, which a
--- server may not have on)
---@return boolean ready
local function scorer()
    if not extensions.isExtensionLoaded("gameplay_drift_general") then
        pcall(extensions.load, "gameplay_drift_general")
    end
    local general = extensions.gameplay_drift_general
    if not general or not extensions.gameplay_drift_scoring then return false end
    if general.getContext and not general.getContext() then pcall(general.setContext, "inFreeroam") end
    return true
end

---@return integer score, number combo the run's points so far, the drift still going included
local function liveScore()
    local s = extensions.gameplay_drift_scoring and extensions.gameplay_drift_scoring.getScore()
    if type(s) ~= "table" then return 0, 1 end
    return math.floor((tonumber(s.score) or 0) + (tonumber(s.potentialScore) or 0)), tonumber(s.combo) or 1
end

---@return string? the locale key of what a run may not do right now
local function brokenRule()
    if simTimeAuthority.getPause() or simTimeAuthority.get() ~= 1 then return "beamjoy.driftZones.failed.time" end
    local expected = beamjoy_environment and beamjoy_environment.data and beamjoy_environment.data.gravity
    if expected and math.abs(extensions.core_environment.getGravity() - expected) > 1e-3 then
        return "beamjoy.driftZones.failed.gravity"
    end
    return nil
end

-- THE PANEL ----------------------------------------------------------------------------------

local function pushHud()
    lastHud = frameMs or GetCurrentTimeMillis()
    local run = M.run
    if run then
        local score, combo = liveScore()
        local outFor = run.outSince and math.max(0, OUT_GRACE - (frameMs - run.outSince) / 1000) or nil
        return beamjoy_communications_ui.send("BJDriftZoneHud", {
            active = true,
            state = "running",
            name = run.zone.name,
            score = score,
            combo = combo,
            elapsed = (frameMs - run.startMs) / 1000,
            outFor = outFor,
        })
    end
    if result and frameMs < result.untilMs then
        return beamjoy_communications_ui.send("BJDriftZoneHud", {
            active = true,
            state = result.state,
            name = result.name,
            score = result.score,
            reason = result.reason and beamjoy_lang.translate(result.reason) or nil,
            board = result.board,
        })
    end
    beamjoy_communications_ui.send("BJDriftZoneHud", { active = false })
end

---@param reasonKey string
local function fail(reasonKey)
    local run = M.run
    if not run then return end
    M.run = nil
    lastLy = {}
    result = { name = run.zone.name, state = "failed", reason = reasonKey, untilMs = frameMs + RESULT_SECONDS * 1000 }
    pushHud()
end

---@param zone table
---@param car BJVehicle
local function start(zone, car)
    if not scorer() then return end
    pcall(extensions.gameplay_drift_general.reset)
    M.run = { zone = zone, startMs = frameMs, vid = car.vid }
    result = nil
    lastLy = {}
    pushHud()
end

---@param car BJVehicle
local function finish(car)
    local run = M.run
    M.run = nil
    lastLy = {}
    local scoring = extensions.gameplay_drift_scoring
    if scoring then pcall(scoring.wrapUpWithText) end
    local s = scoring and scoring.getScore()
    local score = math.floor(type(s) == "table" and tonumber(s.score) or 0)
    result = { name = run.zone.name, state = "done", score = score, untilMs = frameMs + RESULT_SECONDS * 1000 }
    if score > 0 then
        local spotId = "bj:" .. tostring(run.zone.id)
        -- the zone's name for the server's "new best" toast (beamjoy/freeroamChallenges.lua)
        if beamjoy_freeroamChallenges then beamjoy_freeroamChallenges.names[spotId] = run.zone.name end
        beamjoy_communications.send("challengeResult", "drift", spotId, {
            score = score,
            vehicle = beamjoy_freeroamChallenges and beamjoy_freeroamChallenges.ownCarLabel() or nil,
        })
    end
    pushHud()
end

local function onUpdate()
    prevFrameMs = frameMs
    frameMs = GetCurrentTimeMillis()
    local car = ownCar()
    local run = M.run
    if run then
        if not car or car.vid ~= run.vid then return fail("beamjoy.driftZones.failed.car") end
        if not free() then return fail("beamjoy.driftZones.failed.busy") end
        local rule = brokenRule()
        if rule then return fail(rule) end
        if frameMs - run.startMs > MAX_RUN_SECONDS * 1000 then return fail("beamjoy.driftZones.failed.timeout") end
    elseif result and frameMs >= result.untilMs then
        result = nil
        pushHud()
    end
    if not car or (not run and (#M.nearby == 0 or not free())) then return end

    local p = beamjoy_vehicles.getVehiclePositionRotation(car.veh) + vec3(0, 0, .5)
    local jumped = lastPos ~= nil and p:distance(lastPos) > TELEPORT_DISTANCE
    lastPos = p
    if jumped then
        lastLy = {}
        if run then fail("beamjoy.driftZones.failed.moved") end
        return
    end

    if run then
        if inCorridor(run.zone, p) then
            run.outSince = nil
        else
            run.outSince = run.outSince or frameMs
            if frameMs - run.outSince > OUT_GRACE * 1000 then return fail("beamjoy.driftZones.failed.left") end
        end
        local pos, dir = gate(run.zone, "finish")
        if crossed("finish", pos, dir, run.zone.width, p) then return finish(car) end
        if frameMs - lastHud >= HUD_PUSH_MS then pushHud() end
        return
    end

    local speed = car.veh:getVelocity():length()
    for _, zone in ipairs(M.nearby) do
        local pos, dir = gate(zone, "start")
        if crossed("start" .. tostring(zone.id), pos, dir, zone.width, p) and speed >= MIN_START_SPEED then
            return start(zone, car)
        end
    end
end

---@param vid integer
local function onVehicleResetted(vid)
    if M.run and M.run.vid == vid then fail("beamjoy.driftZones.failed.reset") end
end

-- THE ZONES IN THE WORLD ----------------------------------------------------------------------

local LAYER = "driftZones"

local function draw()
    local layer = shape.layer(LAYER)
    layer.reset()
    if M.editing or (beamjoy_markerSettings and beamjoy_markerSettings.activitiesHidden()) then return end
    local startColor = BJColor(.2, 1, .4, .85)
    local finishColor = BJColor(1, 1, 1, .9)
    local edgeColor = BJColor(1, .45, .1, .45)
    local textColor, textBg = BJColor(1, 1, 1, .9), BJColor(0, 0, 0, .4)
    local lift = vec3(0, 0, .05)
    for _, zone in ipairs(M.nearby) do
        local half = zone.width / 2
        for _, which in ipairs({ "start", "finish" }) do
            local pos, dir = gate(zone, which)
            local right = dir:cross(vec3(0, 0, 1)) * half
            local color = which == "start" and startColor or finishColor
            layer.addLine(pos - right + lift, .2, pos + right + lift, .2, color)
            layer.addLine(pos - right, .12, pos - right + vec3(0, 0, 2.5), .12, color)
            layer.addLine(pos + right, .12, pos + right + vec3(0, 0, 2.5), .12, color)
        end
        -- the corridor's edges, segment by segment
        for i = 2, #zone.points do
            local a, b = v3(zone.points[i - 1]), v3(zone.points[i])
            local right = flatDir(a, b):cross(vec3(0, 0, 1)) * half
            layer.addLine(a - right + lift, .08, b - right + lift, .08, edgeColor)
            layer.addLine(a + right + lift, .08, b + right + lift, .08, edgeColor)
        end
        local pos = gate(zone, "start")
        layer.addText(zone.name, pos + vec3(0, 0, 3), textColor, textBg)
    end
end

local lastNearKey
local function onSlowUpdate()
    local car = beamjoy_vehicles.getCurrentOwn()
    local pos = car and beamjoy_vehicles.getVehiclePositionRotation(car.veh) or
        (core_camera and core_camera.getPosition())
    local nearby = {}
    if pos and (M.run or free()) then
        for _, zone in ipairs(M.zones) do
            if type(zone.points) == "table" and #zone.points >= 2 and
                pos:distance(v3(zone.points[1])) <= NEAR_DISTANCE then
                nearby[#nearby + 1] = zone
            end
        end
    end
    M.nearby = nearby
    local key = table.concat(table.map(nearby, function(z) return tostring(z.id) end), ",")
    if key ~= lastNearKey then
        lastNearKey = key
        for k in pairs(lastLy) do
            if k ~= "finish" then lastLy[k] = nil end
        end
        draw()
    end
end

-- THE CACHE -----------------------------------------------------------------------------------

---@param caches table
local function retrieveCache(caches)
    if not caches.driftzones then return end
    M.zones = table.isArray(caches.driftzones) and caches.driftzones or {}
    M.run = nil
    lastNearKey = nil
    extensions.hook("onBJDriftZonesChanged")
end

--- the zones for the Leaderboards window's Drift list (beamjoy/freeroamChallenges.lua)
---@return table[] {id, name, targets}
function M.list()
    return table.map(M.zones, function(z)
        return { id = "bj:" .. tostring(z.id), name = z.name, targets = {} }
    end)
end

--- the Freeroam editor opened or closed (ui/freeroamEditor.lua) : its drawing replaces these
---@param open boolean
local function onBJStationEditorState(open)
    M.editing = open == true
    draw()
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", retrieveCache)
    beamjoy_communications_ui.addHandler("BJDriftZoneHudRequest", pushHud)
end

local function onServerLeave()
    M.run, M.zones, M.nearby, result = nil, {}, {}, nil
    lastLy, lastPos = {}, nil
    shape.layer(LAYER).reset()
end

M.inCorridor = inCorridor
M.onInit = onInit
M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate
M.onVehicleResetted = onVehicleResetted
M.onServerLeave = onServerLeave
M.onBJStationEditorState = onBJStationEditorState
M.retrieveCache = retrieveCache

return M
