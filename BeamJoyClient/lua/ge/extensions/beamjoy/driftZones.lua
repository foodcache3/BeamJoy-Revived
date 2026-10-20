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
---
--- Called "drift spots" to players (direct request), the code keeps its zone names. Each point of the
--- route has its own width (`w`, set by the editor's handles at the ends of its line across the
--- route), the spot's `width` for one without : the corridor narrows and widens from point to point,
--- and the start and finish gates are their points' width. The route is a smooth curve through its
--- points (direct request), drawn and checked alike (curve).
---
--- In the world (direct request) : the start and finish lines are white spray paint across the gates
--- (chalk at first, direct request), the edges painted along the curve in the spot's `edgePaint` (any
--- of beamjoy_props' paints, "none" for no edge lines, white spray paint when unset), and its `signs` (drift signs, at least one a spot : the editor
--- won't save one without) stand where they were placed. Laid by beamjoy_props as its own set
--- ("driftZones", every spot on the map at once, so its signs' collision is rebuilt only when the
--- spots change), the same for every player ; the editor's spots instead while they're edited.

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
-- metres, a point's width (kept in sync with services/driftZones.lua)
local MIN_WIDTH, MAX_WIDTH, DEFAULT_WIDTH = 6, 60, 16
-- metres between the curve's samples, and at most this many per stretch between two points
local CURVE_STEP, CURVE_MAX_SAMPLES = 2.5, 24
-- the paint across the gates, and its width (metres) ; the edges' when a spot has none set
local GATE_PAINT, GATE_PAINT_WIDTH = "sprayWhite", .5
M.DEFAULT_EDGE_PAINT = "sprayWhite"
M.SIGN_SHAPE = "/art/shapes/objects/s_sign_drift.dae"
-- an edge line's points : about this many metres apart (the paint's own spline smooths between
-- them), and one painted line at most this long or with this many points (beamjoy_props'
-- PAINT_MAX_SEGMENTS, about 400 m, and MAX_LINE_NODES), the next going on from its end
local EDGE_STEP, EDGE_MAX_LENGTH, EDGE_MAX_KNOTS = 6, 360, 48

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

---@param v vec3
---@return table
local function xyz(v) return { x = v.x, y = v.y, z = v.z } end

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

--- a point's width (metres) : its own, else the zone's
---@param zone table
---@param i integer
---@return number
local function pointWidth(zone, i)
    local pt = zone.points[i]
    local w = pt and tonumber(pt.w) or tonumber(zone.width) or DEFAULT_WIDTH
    if w ~= w then w = DEFAULT_WIDTH end
    return math.max(MIN_WIDTH, math.min(MAX_WIDTH, w))
end
M.pointWidth = pointWidth

--- a point's line across the route : the way the route goes there (halfway between its two
--- segments' ways ; a gate's own way at the start and the finish) and its half width to the right
---@param zone table
---@param i integer
---@return vec3 pos, vec3 dir, vec3 right
local function pointFrame(zone, i)
    local pts = zone.points
    local n = #pts
    local dir
    if i == 1 then
        dir = flatDir(v3(pts[1]), v3(pts[2]))
    elseif i == n then
        dir = flatDir(v3(pts[n - 1]), v3(pts[n]))
    else
        local after = flatDir(v3(pts[i]), v3(pts[i + 1]))
        dir = flatDir(v3(pts[i - 1]), v3(pts[i])) + after
        dir = dir:length() > 1e-3 and dir:normalized() or after
    end
    return v3(pts[i]), dir, dir:cross(vec3(0, 0, 1)) * (pointWidth(zone, i) / 2)
end
M.pointFrame = pointFrame

---@type table<table, {sig: number, samples: table[]}> zone -> its curve, made again when it moves
local curves = setmetatable({}, { __mode = "k" })

--- the zone's points and widths as one number : changes when the editor moves one
---@param zone table
---@return number
local function curveSignature(zone)
    local sig = #zone.points + (tonumber(zone.width) or 0) * 1e-3
    for i, pt in ipairs(zone.points) do
        sig = sig + i * (pt.x * 1.3 + pt.y * 1.7 + pt.z * 2.9 + (tonumber(pt.w) or 0) * 3.1)
    end
    return sig
end

--- the route as a smooth curve through its points : between two points a cubic leaving one and
--- reaching the next along their own way (pointFrame's, so the lines across the route and their
--- handles stay square to it), its pull the stretch's length ; the height and width go from one
--- point's to the next's (the width eased, so it holds at each point)
---@param zone table
---@return {pos: vec3, right: vec3, w: number}[] samples from the start to the finish
local function curve(zone)
    local sig = curveSignature(zone)
    local cached = curves[zone]
    if cached and cached.sig == sig then return cached.samples end
    local samples = {}
    local n = #zone.points
    local p0, d0 = pointFrame(zone, 1)
    local w0 = pointWidth(zone, 1)
    table.insert(samples, { pos = p0, right = d0:cross(vec3(0, 0, 1)) * (w0 / 2), w = w0 })
    for i = 2, n do
        local p1, d1 = pointFrame(zone, i)
        local w1 = pointWidth(zone, i)
        local len = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
        local k = math.max(1, math.min(CURVE_MAX_SAMPLES, math.ceil(len / CURVE_STEP)))
        local m0, m1 = d0 * len, d1 * len
        for j = 1, k do
            local t = j / k
            local t2, t3 = t * t, t * t * t
            local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
            local pos = p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11
            pos.z = p0.z + (p1.z - p0.z) * t
            local tan = p0 * (6 * t2 - 6 * t) + m0 * (3 * t2 - 4 * t + 1) + p1 * (6 * t - 6 * t2) +
                m1 * (3 * t2 - 2 * t)
            tan.z = 0
            local dir = tan:length() > 1e-4 and tan:normalized() or flatDir(p0, p1)
            if j == k then dir = d1 end
            local w = w0 + (w1 - w0) * (t2 * (3 - 2 * t))
            table.insert(samples, { pos = pos, right = dir:cross(vec3(0, 0, 1)) * (w / 2), w = w })
        end
        p0, d0, w0 = p1, d1, w1
    end
    curves[zone] = { sig = sig, samples = samples }
    return samples
end
M.curve = curve

--- the paint a zone's edges are lined with, nil for none
---@param zone table
---@return string?
function M.edgePaint(zone)
    local id = zone.edgePaint
    if id == "none" then return nil end
    if type(id) == "string" and beamjoy_props and beamjoy_props.getPaint(id) then return id end
    return M.DEFAULT_EDGE_PAINT
end

---@param pos vec3
---@return vec3 on the surface under (or a little over) pos
local function grounded(pos)
    return shape.onGround(pos, 5)
end

--- a painted line along `pts` (its ends and the points between as its nodes)
---@param paint string
---@param pts vec3[]
---@param width number? metres, the paint's own when nil
---@return table entry beamjoy_props' paint entry
local function paintEntry(paint, pts, width)
    local e = { kind = "paint", paint = paint, a = xyz(pts[1]), b = xyz(pts[#pts]), followGround = false, width = width }
    if #pts > 2 then
        e.nodes = {}
        for i = 2, #pts - 1 do e.nodes[#e.nodes + 1] = xyz(pts[i]) end
    end
    e.count = beamjoy_props.paintCount(e)
    return e
end

--- the zone's two edges as painted lines' points, on the ground : about every EDGE_STEP metres
--- along the curve, cut into pieces one painted line can take (made again with the curve)
---@param zone table
---@return vec3[][] pieces
local function edgePieces(zone)
    local samples = curve(zone)
    local cached = curves[zone]
    if cached.edges then return cached.edges end
    local pieces = {}
    for _, side in ipairs({ -1, 1 }) do
        local pts, along = {}, 0
        for i, s in ipairs(samples) do
            local p = s.pos + s.right * side
            if i > 1 then along = along + p:distance(samples[i - 1].pos + samples[i - 1].right * side) end
            if i == 1 or i == #samples or along >= EDGE_STEP then
                pts[#pts + 1] = grounded(p)
                along = 0
            end
        end
        local piece, length = { pts[1] }, 0
        for i = 2, #pts do
            length = length + pts[i]:distance(pts[i - 1])
            piece[#piece + 1] = pts[i]
            if i < #pts and (#piece >= EDGE_MAX_KNOTS or length >= EDGE_MAX_LENGTH) then
                pieces[#pieces + 1] = piece
                piece, length = { pts[i] }, 0
            end
        end
        if #piece >= 2 then pieces[#pieces + 1] = piece end
    end
    cached.edges = pieces
    return pieces
end

--- a sign's facing : the way its mesh's +Y points (its painted face looks the other way)
---@param sign table
---@return vec3
function M.signDir(sign)
    local d = type(sign.dir) == "table" and vec3(tonumber(sign.dir.x) or 0, tonumber(sign.dir.y) or 0, 0) or nil
    return (d and d:length() > 1e-4) and d:normalized() or vec3(0, 1, 0)
end

--- what the zone puts in the world : spray paint across its gates, its edge lines, its signs
---@param zone table
---@return table[] beamjoy_props entries
local function worldEntries(zone)
    local out = {}
    if type(zone.points) ~= "table" or #zone.points < 2 then return out end
    for _, i in ipairs({ 1, #zone.points }) do
        local pos, _, right = pointFrame(zone, i)
        out[#out + 1] = paintEntry(GATE_PAINT, { grounded(pos - right), grounded(pos + right) }, GATE_PAINT_WIDTH)
    end
    local edge = M.edgePaint(zone)
    if edge then
        for _, piece in ipairs(edgePieces(zone)) do out[#out + 1] = paintEntry(edge, piece) end
    end
    for _, sign in ipairs(type(zone.signs) == "table" and zone.signs or {}) do
        if tonumber(sign.x) and tonumber(sign.y) and tonumber(sign.z) then
            out[#out + 1] = { kind = "static", shape = M.SIGN_SHAPE, pos = { x = sign.x, y = sign.y, z = sign.z },
                dir = xyz(M.signDir(sign)), up = { x = 0, y = 0, z = 1 } }
        end
    end
    return out
end

local WORLD_SET = "driftZones"
--- the editor's zones while it's open on them (setEditorZones), else nil : the saved ones
local editorZones = nil

--- the spots' paint and signs laid (beamjoy_props), the editor's while it edits them : not solid
--- then, as the prop editor's own
local function showWorld()
    if not beamjoy_props then return end
    local entries = {}
    for _, zone in ipairs(editorZones or M.zones) do
        for _, e in ipairs(worldEntries(zone)) do entries[#entries + 1] = e end
    end
    if #entries == 0 then return beamjoy_props.hide(WORLD_SET) end
    if editorZones then
        beamjoy_props.show(WORLD_SET, entries, { collision = false, collisionType = "None" })
    else
        beamjoy_props.show(WORLD_SET, entries)
    end
end

--- the drift spot editor's zones shown in the world instead of the saved ones (nil : back to them)
---@param zones table[]?
function M.setEditorZones(zones)
    editorZones = zones
    showWorld()
end

---@param p vec3
---@param a vec3
---@param b vec3
---@return number dist flat distance from p to the segment ab, number t where along it (0 to 1)
local function segmentDistance(p, a, b)
    local abx, aby = b.x - a.x, b.y - a.y
    local len2 = abx * abx + aby * aby
    local t = len2 > 0 and math.max(0, math.min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2)) or 0
    local cx, cy = a.x + abx * t, a.y + aby * t
    return math.sqrt((p.x - cx) ^ 2 + (p.y - cy) ^ 2), t
end

---@param zone table
---@param p vec3
---@return boolean within the corridor along the route : its width going from point to point
local function inCorridor(zone, p)
    local samples = curve(zone)
    for i = 2, #samples do
        local a, b = samples[i - 1], samples[i]
        local dist, t = segmentDistance(p, a.pos, b.pos)
        if dist <= (a.w * (1 - t) + b.w * t) / 2 + CORRIDOR_SLACK then return true end
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
        if crossed("finish", pos, dir, pointWidth(run.zone, #run.zone.points), p) then return finish(car) end
        if frameMs - lastHud >= HUD_PUSH_MS then pushHud() end
        return
    end

    local speed = car.veh:getVelocity():length()
    for _, zone in ipairs(M.nearby) do
        local pos, dir = gate(zone, "start")
        if crossed("start" .. tostring(zone.id), pos, dir, pointWidth(zone, 1), p) and speed >= MIN_START_SPEED then
            return start(zone, car)
        end
    end
end

---@param vid integer
local function onVehicleResetted(vid)
    if M.run and M.run.vid == vid then fail("beamjoy.driftZones.failed.reset") end
end

-- THE ZONES IN THE WORLD ----------------------------------------------------------------------
-- Nothing drawn over them : no name (direct request : no nametags on drift spots), and the posts
-- that stood at the gates' ends taken out too (direct request) ; the painted gates, edges and
-- signs show where a spot is (showWorld)

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
    end
end

-- THE CACHE -----------------------------------------------------------------------------------

---@param caches table
local function retrieveCache(caches)
    if not caches.driftzones then return end
    M.zones = table.isArray(caches.driftzones) and caches.driftzones or {}
    M.run = nil
    lastNearKey = nil
    showWorld()
    extensions.hook("onBJDriftZonesChanged")
    if bigmap and bigmap.updatePOIs then bigmap.updatePOIs() end
end

--- a Big Map pin per zone in the BeamJoy section's "Drift zones" group, at its start gate ; quick
--- travel puts the car a little short of the gate, facing through it, and the route shows on the
--- map while the pin is hovered or selected
---@param POIS table<string, table>
local function onBJRequestBigmapPOIs(POIS)
    for _, zone in ipairs(M.zones) do
        if type(zone.points) == "table" and #zone.points >= 2 then
            local pos, dir = gate(zone, "start")
            local points, length = {}, 0
            for i, p in ipairs(zone.points) do
                points[i] = v3(p)
                if i > 1 then length = length + points[i]:distance(points[i - 1]) end
            end
            POIS["bjDriftZone_" .. tostring(zone.id)] = {
                name = zone.name,
                description = string.var(beamjoy_lang.translate("beamjoy.bigmap.driftDescription"),
                    { math.floor(length + .5) }),
                icon = "drift01",
                mapIcon = "mission_drift_triangle",
                groupType = "other",
                customGroupTags = { "bjDriftZones" },
                pos = pos,
                canQuickTravel = true,
                quickTravelPos = pos - dir * 15,
                quickTravelRot = dir,
                previewPoints = points,
            }
        end
    end
end

--- the zones for the Leaderboards window's Drift list (beamjoy/freeroamChallenges.lua)
---@return table[] {id, name, targets}
function M.list()
    return table.map(M.zones, function(z)
        return { id = "bj:" .. tostring(z.id), name = z.name, targets = {} }
    end)
end

--- the Freeroam editor opened or closed (ui/freeroamEditor.lua) : no runs meanwhile
---@param open boolean
local function onBJStationEditorState(open)
    M.editing = open == true
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", retrieveCache)
    beamjoy_communications_ui.addHandler("BJDriftZoneHudRequest", pushHud)
end

local function onServerLeave()
    M.run, M.zones, M.nearby, result = nil, {}, {}, nil
    lastLy, lastPos = {}, nil
    editorZones = nil
    if beamjoy_props then beamjoy_props.hide(WORLD_SET) end
    if bigmap and bigmap.updatePOIs then bigmap.updatePOIs() end
end

--- a map loaded : its spots laid again (beamjoy_props clears every set when a map is left)
---@param state integer
local function onWorldReadyState(state)
    if state == 2 then showWorld() end
end

M.inCorridor = inCorridor
M.onInit = onInit
M.onWorldReadyState = onWorldReadyState
M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate
M.onVehicleResetted = onVehicleResetted
M.onServerLeave = onServerLeave
M.onBJStationEditorState = onBJStationEditorState
M.retrieveCache = retrieveCache
M.onBJRequestBigmapPOIs = onBJRequestBigmapPOIs

return M
