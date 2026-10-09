local M = {}
--- gc prevention
local col, statusA, statusB, statusC, forward, up, right, base, tip

---@param pos vec3
---@param radius number
---@param shapeColor BJColor?
local function Sphere(pos, radius, shapeColor)
    statusA, pos = pcall(vec3, pos)
    if not statusA or not tonumber(radius) then
        -- invalid position or radius
        LogError("invalid sphere data")
        return
    end
    shapeColor = shapeColor or BJColor(1, 1, 1, .5)

    debugDrawer:drawSphere(vec3(pos), radius, ColorF(shapeColor.r, shapeColor.g, shapeColor.b, shapeColor.a), true)
end

---@param text string
---@param pos vec3
---@param textColor BJColor?
---@param bgColor BJColor?
---@param shadow boolean?
---@param hideBehindObj boolean?
local function Text(text, pos, textColor, bgColor, shadow, hideBehindObj)
    statusA, pos = pcall(vec3, pos)
    if not statusA then
        -- invalid position
        LogError("invalid text position")
        return
    end
    textColor = textColor or BJColor(1, 1, 1, 1)
    bgColor = bgColor or BJColor(0, 0, 0, 1)

    debugDrawer:drawTextAdvanced(pos, String(text),
        ColorF(textColor.r, textColor.g, textColor.b, textColor.a),
        true, false,
        ColorI(bgColor.r * 255, bgColor.g * 255, bgColor.b * 255, bgColor.a * 255),
        shadow == true, hideBehindObj == true)
end

---@param fromPos vec3
---@param fromWidth number
---@param toPos vec3
---@param toWidth number
---@param shapeColor BJColor?
local function SquarePrism(fromPos, fromWidth, toPos, toWidth, shapeColor)
    statusA, fromPos = pcall(vec3, fromPos)
    statusB, toPos = pcall(vec3, toPos)
    if not statusA or not statusB or not tonumber(fromWidth) or not tonumber(toWidth) then
        -- invalid from position or width
        LogError("invalid square prism data")
        return
    end
    shapeColor = shapeColor or BJColor(1, 1, 1, .5)

    debugDrawer:drawSquarePrism(fromPos, toPos,
        Point2F(fromWidth, fromWidth), Point2F(toWidth, toWidth),
        ColorF(shapeColor.r, shapeColor.g, shapeColor.b, shapeColor.a),
        true)
end

---@param bottomPos vec3
---@param topPos vec3
---@param radius number
---@param shapeColor BJColor?
local function Cylinder(bottomPos, topPos, radius, shapeColor)
    statusA, bottomPos = pcall(vec3, bottomPos)
    statusB, topPos = pcall(vec3, topPos)
    if not statusA or not statusB or
        not tonumber(radius) then
        -- invalid position or radius
        LogError("invalid cylinder data")
        return
    end
    shapeColor = shapeColor or BJColor(1, 1, 1, .5)

    debugDrawer:drawCylinder(bottomPos, topPos, radius,
        ColorF(shapeColor.r, shapeColor.g, shapeColor.b, shapeColor.a))
end

---@param camPos vec3
---@param camRot vec3
---@param posA vec3
---@param posB vec3
---@param posC vec3
---@return boolean
local function isTriangleVisible(camPos, camRot, posA, posB, posC)
    local center = vec3(
        (posA.x + posB.x + posC.x) / 3,
        (posA.y + posB.y + posC.y) / 3,
        (posA.z + posB.z + posC.z) / 3
    )
    local view = center - camPos
    return (view.x * camRot.x + view.y * camRot.y + view.z * camRot.z) > 0
end

---@param camPos vec3
---@param posA vec3
---@param posB vec3
---@param posC vec3
---@return boolean
local function isTriangleFaceVisible(camPos, posA, posB, posC)
    local u = posB - posA ---@type vec3
    local v = posC - posA ---@type vec3
    local n = u:cross(v):normalized()
    local center = vec3(
        (posA.x + posB.x + posC.x) / 3,
        (posA.y + posB.y + posC.y) / 3,
        (posA.z + posB.z + posC.z) / 3
    )
    local view = center - camPos
    return (n.x * view.x + n.y * view.y + n.z * view.z) > 0
end

---@param posA vec3
---@param posB vec3
---@param posC vec3
---@param shapeColor BJColor?
---@param camPos vec3?
---@param camRot vec3?
local function Triangle(posA, posB, posC, shapeColor, camPos, camRot)
    statusA, posA = pcall(vec3, posA)
    statusB, posB = pcall(vec3, posB)
    statusC, posC = pcall(vec3, posC)
    if not statusA or not statusB or not statusC then
        -- invalid position
        LogError("invalid triangle data")
        return
    end
    shapeColor = shapeColor or BJColor(1, 1, 1, .5)
    if not camPos or not camRot then
        camPos, camRot = camera.getPositionRotation(true)
    end

    if isTriangleVisible(camPos, camRot, posA, posB, posC) then
        col = color(shapeColor.r * 255, shapeColor.g * 255, shapeColor.b * 255, shapeColor.a * 255)
        if isTriangleFaceVisible(camPos, posA, posB, posC) then
            debugDrawer:drawTriSolid(posA, posB, posC, col)
        else
            debugDrawer:drawTriSolid(posC, posB, posA, col)
        end
    end
end

---@param pos vec3
---@param rot vec3
---@param radius number
---@param shapeColor BJColor?
local function Arrow(pos, rot, radius, shapeColor)
    statusA, pos = pcall(vec3, pos)
    statusB, rot = pcall(vec3, rot)
    if not statusA or not statusB or not tonumber(radius) then
        -- invalid position or rotation or radius
        LogError("invalid arrow data")
        return
    end
    shapeColor = shapeColor or BJColor(1, 1, 1, .5)

    forward = rot * radius
    tip = vec3(pos) + forward
    base = vec3(pos) - forward
    debugDrawer:drawArrow(base, tip,
        ColorI(shapeColor.r * 255, shapeColor.g * 255, shapeColor.b * 255, shapeColor.a * 255), false)
end

-- BASE SHAPES RENDERING

M.Sphere = Sphere
M.Text = Text
M.SquarePrism = SquarePrism
M.Cylinder = Cylinder
M.Triangle = Triangle
M.Arrow = Arrow

-- the game's own GPS destination column (gameplay/markerInteraction.lua's drawDistanceColumn) :
-- white, 1 km tall, wider and more opaque with distance. Gone within BEAM_HIDE_DISTANCE, where the
-- marker it points at is in plain view anyway, fading out over the last BEAM_FADE metres
local BEAM_HIDE_DISTANCE = 100 -- direct request (was 50)
local BEAM_FADE = 15
local beamTop = vec3(0, 0, 1000)
local beamColor = ColorF(1, 1, 1, 1)

---@param pos vec3
---@param camPos vec3
local function Beam(pos, camPos)
    local dist = camPos:distance(pos)
    if dist <= BEAM_HIDE_DISTANCE then return end
    beamColor.alpha = math.max(.1, math.min((dist - BEAM_HIDE_DISTANCE) / 200, .6)) *
        math.min((dist - BEAM_HIDE_DISTANCE) / BEAM_FADE, 1)
    debugDrawer:drawCylinder(pos, pos + beamTop, math.max(dist / 400, .1), beamColor)
end
M.Beam = Beam

--- the point moved onto the surface right below it (or just above it : probed from a few metres up,
--- so a road under a bridge stays the road), or left as it is when there's nothing near
---@param pos vec3
---@param above number? metres above pos the probe starts (default 3)
---@return vec3
function M.onGround(pos, above)
    local h = be:getSurfaceHeightBelow(vec3(pos.x, pos.y, pos.z + (above or 3)))
    if not h or h < pos.z - 20 then return vec3(pos) end
    return vec3(pos.x, pos.y, h)
end

-- DRAW BUFFERS : what's added is redrawn every frame until its layer is reset. The module's own
-- add*/reset functions work on the default layer, which most renderers share (each clears it
-- wholesale before drawing its own content) ; layer(name) gives one that only its owner resets,
-- for drawing that stays up alongside them (the freeroam race start gates, beamjoy_raceMarkers)

local function newBuffer()
    return {
        ---@type tablelib<integer, {pos: vec3, radius: number, color: BJColor}> index 1-N
        spheres = Table(),
        ---@type tablelib<integer, {fromPos: vec3, toPos: vec3, fromWidth: number, toWidth: number, color: BJColor}> index 1-N
        lines = Table(),
        ---@type tablelib<integer, {bottomPos: vec3, topPos: vec3, radius: number, color: BJColor}> index 1-N
        cylinders = Table(),
        ---@type tablelib<integer, {pos: vec3, rot: vec3, radius: number, color: BJColor}> index 1-N
        arrows = Table(),
        ---@type tablelib<integer, {p1: vec3, p2: vec3, p3: vec3, color: BJColor}> index 1-N
        triangles = Table(),
        ---@type tablelib<integer, {text: string, pos: vec3, textColor: BJColor, bgColor: BJColor, shadow: boolean}> index 1-N
        texts = Table(),
        ---@type tablelib<integer, {pos: vec3}> index 1-N
        beams = Table(),
    }
end

---@type table[] every layer's buffer, the default one first
local buffers = {}

local RING_RAIL_HEIGHTS = { .5, 3 }
local RING_WALL_HEIGHT = 4
local RING_WALL_DEPTH = 1

--- the drawing functions over one buffer
---@param shapes table newBuffer()
---@return table
local function bufferApi(shapes)
    local api = {}

    function api.reset()
        for _, arr in pairs(shapes) do
            arr:clear()
        end
    end

    ---@param centerPos vec3
    ---@param radius number
    ---@param color BJColor?
    function api.addSphere(centerPos, radius, color)
        shapes.spheres:insert({ pos = centerPos, radius = radius, color = color })
    end

    ---@param fromPos vec3
    ---@param fromWidth number
    ---@param toPos vec3
    ---@param toWidth number
    ---@param color BJColor?
    function api.addLine(fromPos, fromWidth, toPos, toWidth, color)
        shapes.lines:insert({ fromPos = fromPos, fromWidth = fromWidth, toPos = toPos, toWidth = toWidth, color = color })
    end

    ---@param bottomPos vec3
    ---@param topPos vec3
    ---@param radius number
    ---@param color BJColor?
    function api.addCylinder(bottomPos, topPos, radius, color)
        shapes.cylinders:insert({ bottomPos = bottomPos, topPos = topPos, radius = radius, color = color })
    end

    ---@param pos vec3
    ---@param rot vec3
    ---@param radius number
    ---@param color BJColor?
    function api.addArrow(pos, rot, radius, color)
        shapes.arrows:insert({ pos = pos, rot = rot, radius = radius, color = color })
    end

    ---@param p1 vec3
    ---@param p2 vec3
    ---@param p3 vec3
    ---@param color BJColor?
    function api.addTriangle(p1, p2, p3, color)
        shapes.triangles:insert({ p1 = p1, p2 = p2, p3 = p3, color = color })
    end

    ---@param p1 vec3
    ---@param p2 vec3
    ---@param p3 vec3
    ---@param p4 vec3
    ---@param color BJColor?
    function api.addQuad(p1, p2, p3, p4, color)
        api.addTriangle(p1, p2, p3, color)
        api.addTriangle(p1, p3, p4, color)
    end

    ---@param centerPos vec3
    ---@param dir vec3
    ---@param scales vec3 (x = width, y = height, z = length)
    ---@param up vec3?
    ---@param color BJColor?
    function api.addCuboid(centerPos, dir, scales, up, color)
        ---@param v vec3
        ---@param r vec3
        ---@param baseUp vec3?
        ---@return vec3
        local function _rotate(v, r, baseUp)
            local needUp  = not baseUp
            local finalUp = (baseUp or vec3(0, 0, 1)):normalized()
            forward       = r:normalized()
            right         = finalUp:cross(forward):normalized()
            if needUp then
                finalUp = forward:cross(right)
            end

            return vec3(
                v.x * right.x + v.y * finalUp.x + v.z * forward.x,
                v.x * right.y + v.y * finalUp.y + v.z * forward.y,
                v.x * right.z + v.y * finalUp.z + v.z * forward.z
            )
        end

        local baseVerts = {
            { x = -0.5, y = -0.5, z = -0.5 },
            { x = 0.5,  y = -0.5, z = -0.5 },
            { x = 0.5,  y = 0.5,  z = -0.5 },
            { x = -0.5, y = 0.5,  z = -0.5 },
            { x = -0.5, y = -0.5, z = 0.5 },
            { x = 0.5,  y = -0.5, z = 0.5 },
            { x = 0.5,  y = 0.5,  z = 0.5 },
            { x = -0.5, y = 0.5,  z = 0.5 },
        }
        local verts = {}
        for i, v in ipairs(baseVerts) do
            local scaled = vec3(
                v.x * scales.x,
                v.y * scales.y,
                v.z * scales.z
            )
            local rotated = _rotate(scaled, dir, up)
            verts[i] = {
                x = rotated.x + centerPos.x,
                y = rotated.y + centerPos.y,
                z = rotated.z + centerPos.z,
            }
        end

        api.addQuad(verts[1], verts[2], verts[3], verts[4], color)
        api.addQuad(verts[5], verts[6], verts[7], verts[8], color)
        api.addQuad(verts[1], verts[2], verts[6], verts[5], color)
        api.addQuad(verts[3], verts[4], verts[8], verts[7], color)
        api.addQuad(verts[2], verts[3], verts[7], verts[6], color)
        api.addQuad(verts[1], verts[4], verts[8], verts[5], color)
    end

    --- a line painted on the ground from one point to another : cut into pieces of about `step`
    --- metres, each end set on the surface below it, so it follows the road's slope and camber
    --- instead of cutting through a crest or floating over a dip
    ---@param fromPos vec3
    ---@param toPos vec3
    ---@param width number
    ---@param color BJColor?
    ---@param lift number? metres above the surface (default .05)
    ---@param step number? metres per piece (default 6)
    function api.addGroundLine(fromPos, toPos, width, color, lift, step)
        fromPos, toPos = vec3(fromPos), vec3(toPos)
        lift = vec3(0, 0, lift or .05)
        local n = math.max(1, math.ceil(fromPos:distance(toPos) / (step or 6)))
        local prev = M.onGround(fromPos) + lift
        for i = 1, n do
            local p = M.onGround(fromPos + (toPos - fromPos) * (i / n)) + lift
            api.addLine(prev, width, p, width, color)
            prev = p
        end
    end

    ---@param text string
    ---@param pos vec3
    ---@param textColor BJColor?
    ---@param bgColor BJColor?
    ---@param shadow boolean?
    function api.addText(text, pos, textColor, bgColor, shadow)
        shapes.texts:insert({ text = text, pos = pos, textColor = textColor, bgColor = bgColor, shadow = shadow })
    end

    --- a GPS-style beam standing on pos (see Beam above), redrawn every frame for its distance fade
    ---@param pos vec3
    function api.addBeam(pos)
        shapes.beams:insert({ pos = vec3(pos) })
    end

    --- a waypoint circle in the derby sumo zone's style : a see-through wall round the circle plus
    --- two solid rails along its edge (the wall alone fades into the map's fog). The wall is one
    --- open panel per segment, not a cylinder : the game's cylinder has end caps, a lid at this height
    ---@param pos vec3 the circle's centre, on the ground
    ---@param radius number
    ---@param tint BJColor only its rgb is used : the wall and rails get their own opacities
    function api.addRing(pos, radius, tint)
        pos = vec3(pos)
        local wall = BJColor(tint.r, tint.g, tint.b, .2)
        local rail = BJColor(tint.r, tint.g, tint.b, .9)
        local segments = radius < 15 and 32 or 48
        local railWidth = radius < 5 and .2 or .3
        local edge = {}
        for i = 0, segments do
            local a = 2 * math.pi * i / segments
            edge[i] = vec3(pos.x + math.cos(a) * radius, pos.y + math.sin(a) * radius, pos.z)
        end
        local bottom, top = vec3(0, 0, -RING_WALL_DEPTH), vec3(0, 0, RING_WALL_HEIGHT)
        for i = 1, segments do
            local a, b = edge[i - 1], edge[i]
            api.addQuad(a + bottom, b + bottom, b + top, a + top, wall)
        end
        for _, h in ipairs(RING_RAIL_HEIGHTS) do
            local up = vec3(0, 0, h)
            for i = 1, segments do
                api.addLine(edge[i - 1] + up, railWidth, edge[i] + up, railWidth, rail)
            end
        end
    end

    return api
end

---@param shapes table
---@param camPos vec3
---@param camRot vec3
local function drawBuffer(shapes, camPos, camRot)
    shapes.spheres:forEach(function(el)
        M.Sphere(el.pos, el.radius, el.color)
    end)

    shapes.lines:forEach(function(el)
        M.SquarePrism(el.fromPos, el.fromWidth, el.toPos, el.toWidth, el.color)
    end)

    shapes.cylinders:forEach(function(el)
        M.Cylinder(el.bottomPos, el.topPos, el.radius, el.color)
    end)

    shapes.arrows:forEach(function(el)
        M.Arrow(el.pos, el.rot, el.radius, el.color)
    end)

    shapes.triangles:forEach(function(el)
        M.Triangle(el.p1, el.p2, el.p3, el.color, camPos, camRot)
    end)

    shapes.texts:forEach(function(el)
        M.Text(el.text, el.pos, el.textColor, el.bgColor, el.shadow)
    end)

    if #shapes.beams > 0 then
        local beamCamPos = core_camera.getPosition()
        shapes.beams:forEach(function(el) Beam(el.pos, beamCamPos) end)
    end
end

local function onUpdate()
    local camPos, camRot = camera.getPositionRotation(true)
    for _, shapes in ipairs(buffers) do
        drawBuffer(shapes, camPos, camRot)
    end
end

-- the default layer : this module's own add*/reset
local defaultBuffer = newBuffer()
table.insert(buffers, defaultBuffer)
for k, fn in pairs(bufferApi(defaultBuffer)) do M[k] = fn end

---@type table<string, table>
local layers = {}

--- a layer of its own (the same add*/reset functions), drawn along with the default one
---@param name string
---@return table
function M.layer(name)
    if not layers[name] then
        local buffer = newBuffer()
        table.insert(buffers, buffer)
        layers[name] = bufferApi(buffer)
    end
    return layers[name]
end

M.onUpdate = onUpdate

return M
