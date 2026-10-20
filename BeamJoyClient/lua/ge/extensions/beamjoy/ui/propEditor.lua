--- The editors' props (see beamjoy_props for the entries and how they're spawned) : placed with
--- the mouse from the props drawer (PLACING below), moved with the gizmo, copied, grouped... Shared
--- by every editor whose activity has props (direct request : props in Hunter, Infected and Derby
--- arenas as in races) : the race editor and the arena editors attach to it as its host while
--- they're open, and own the props array it edits (their race's, their arena's).
---
--- Only one editor is open at a time (activityEditor.lua), so this is a single module with one
--- host, not one instance per editor ; the UI side (cmps/propEditor) talks to it with BJEditorProps*
--- messages whichever editor it sits in.
---
--- The host gives :
---   getProps()          the props array being edited (edited in place), nil while there's none
---   isActive()          whether the host is the editor open now
---   markDirty()         the host's unsaved changes
---   snap()              whether snapping to the ground is on
---   groundHeightAt(pos) the ground's height under a point, as the host's snapping measures it
---   positionDirection() where you are and which way you look (your car, or the free camera)
---   onSelect()          a prop got selected or armed : the host drops its own selection (a gate,
---                       a point) and anything it's dragging, without touching the gizmo
---   label               what holds the props, in the limit's warning ("A race", "An arena")

---@class BJPropEditorHost
---@field getProps fun(): table[]?
---@field isActive fun(): boolean
---@field markDirty fun()
---@field snap fun(): boolean
---@field groundHeightAt fun(pos: vec3): number
---@field positionDirection fun(): vec3?, vec3?
---@field onSelect fun()?
---@field label string?

local M = {
    ---@type BJPropEditorHost?
    host = nil,
    ---@type integer? the selected prop
    activePropIndex = nil,
    ---@type string? which handle of the selected line the gizmo holds : an end ("a", "b") or one of
    ---its nodes ("n1", "n2"... : LINE NODES below)
    activePropPart = nil,
    --- the props selected together (direct request : multiple selection and groups), indices into
    --- the props in order, the active one among them ; moved, turned, copied and deleted as one
    ---@type integer[]
    propSelection = {},
    --- bumped on every change to the props, so their preview (beamjoy_props) only rebuilds then
    propsRevision = 0,
    --- the editor's props as solid as they'll be when played, to drive into them (direct request).
    --- Off by default and after any edit : the game's collision only follows them on a rebuild, so
    --- one moved or deleted would leave an invisible copy behind (beamjoy_props sync)
    testCollision = false,
}

-- the props drawer's placing mode (PLACING below)
local updatePlacing, disarmProp
-- the props clipboard (CLIPBOARD below)
local pushClipboard
local updatePropGizmo

---@return boolean the host is the editor open now
local function active()
    return M.host ~= nil and M.host.isActive() == true and M.host.getProps() ~= nil
end

---@return table[]? the props being edited
local function props()
    return M.host and M.host.getProps() or nil
end

---@return boolean
local function snapOn()
    return M.host ~= nil and M.host.snap() == true
end

---@param pos vec3
---@return number
local function groundHeightAt(pos)
    return M.host.groundHeightAt(pos)
end

---@return vec3? pos, vec3? dir
local function currentPositionDirection()
    return M.host.positionDirection()
end

--- a prop selected or armed : the host's own selection goes
local function hostSelects()
    if M.host and M.host.onSelect then M.host.onSelect() end
end

--- Ctrl held : a line's handle dragged takes the whole line with it (direct request), a click
--- adds a prop to the selection
---@return boolean
local function ctrlHeld()
    local ok, held = pcall(function()
        local io = ui_imgui.GetIO()
        return io ~= nil and io.KeyCtrl == true
    end)
    return ok and held == true
end

---@return boolean
local function shiftHeld()
    local ok, held = pcall(function()
        local io = ui_imgui.GetIO()
        return io ~= nil and io.KeyShift == true
    end)
    return ok and held == true
end

--- what a click does to the selection, by the keys held (M.onSelectProp)
---@return "add"|"alone"|"addAlone"|nil
local function selectMode()
    local ctrl, shift = ctrlHeld(), shiftHeld()
    if ctrl and shift then return "addAlone" end
    return ctrl and "add" or shift and "alone" or nil
end

--- extends the selected line (LINE NODES below)
---@return boolean
local function altHeld()
    local ok, held = pcall(function()
        local io = ui_imgui.GetIO()
        return io ~= nil and io.KeyAlt == true
    end)
    return ok and held == true
end

-- LINE NODES (direct request : more middle points, as the game's own spline editor takes them ;
-- beamjoy_props.linePath draws the curve) : a line's handles are its two ends ("a", "b") and its
-- nodes in order from a to b ("n1", "n2"...). With a line alone selected, a click on its path adds
-- a node there, Alt+click on the ground adds an end there (its nearer end a node then), Delete takes
-- the held node out. An older line's single bend (`mid`) is its one node, made a real one the first
-- time it's edited

-- how close (metres) a new node may come to its line's other points
local NODE_MIN_SPACING = .3

--- a line's nodes as kept ({x, y, z} tables, in order), an older line's `mid` its one node
---@param line table
---@return table[]
local function lineNodes(line)
    if type(line.nodes) == "table" and #line.nodes > 0 then return line.nodes end
    if type(line.mid) == "table" then return { line.mid } end
    return {}
end

--- a line's nodes to edit : an older line's `mid` made its first node
---@param line table
---@return table[]
local function ensureNodes(line)
    if type(line.nodes) ~= "table" or #line.nodes == 0 then
        line.nodes = type(line.mid) == "table" and { line.mid } or {}
    end
    line.mid = nil
    return line.nodes
end

--- a line without nodes left keeps none (straight again)
---@param line table
local function tidyNodes(line)
    if type(line.nodes) == "table" and #line.nodes == 0 then line.nodes = nil end
end

--- the node a handle names ("n3" : 3), nil for an end
---@param part string?
---@return integer?
local function nodeIndex(part)
    return type(part) == "string" and tonumber(part:match("^n(%d+)$")) or nil
end

--- a line's ends and nodes in order, a to b ({x, y, z} tables)
---@param line table
---@return table[]
local function lineKnots(line)
    local out = { line.a }
    for _, n in ipairs(lineNodes(line)) do out[#out + 1] = n end
    out[#out + 1] = line.b
    return out
end

-- Left Ctrl is the game's node grabber (its default "nodegrabberRender" binding) : held, it took
-- every click (beamjoy_inputs drops clicks while it's on), so Ctrl+click never selected several
-- props (direct report). The node grabber is off while an editor with props is open, as the world
-- editor turns the game's own controls off ; back on when it closes
local NODE_GRABBER_FILTER = "bj_raceEditorNodeGrabber"
local NODE_GRABBER_ACTIONS = { "nodegrabberRender", "nodegrabberGrab", "nodegrabberAction", "nodegrabberStrength",
    "nodegrabberPadGrab", "nodegrabberPadMode" }
local nodeGrabberBlocked = false

---@param on boolean
local function blockNodeGrabber(on)
    if nodeGrabberBlocked == on then return end
    local filter = extensions.core_input_actionFilter
    if not filter or not filter.addAction then return end
    nodeGrabberBlocked = on
    if on then filter.setGroup(NODE_GRABBER_FILTER, NODE_GRABBER_ACTIONS) end
    filter.addAction(0, NODE_GRABBER_FILTER, on)
end

-- OVERLAYS -------------------------------------------------------------------------------------
-- The props' handles (the meshes themselves are spawned by beamjoy_props) : a line's path and its
-- two ends (the one the gizmo holds highlighted), the selected single prop, and every invisible
-- mesh's panel, since nothing of those shows in the world. On a shape layer of their own, so the
-- host's markers (gates, points) and these never clear each other

local OVERLAY_LAYER = "propEditor"
local LINE_COLOR, ACTIVE_COLOR, INVISIBLE_COLOR

local function drawOverlays()
    local draw = shape.layer(OVERLAY_LAYER)
    draw.reset()
    local list = active() and props() or nil
    if not list then
        -- nothing to edit : the hover mark goes too (M.onUpdate stops drawing it)
        shape.layer("propEditorHover").reset()
        return
    end
    if not LINE_COLOR then
        LINE_COLOR = BJColor(1, .55, .1, .8)
        ACTIVE_COLOR = BJColor(0, 1, 1, .9)
        INVISIBLE_COLOR = BJColor(.4, .8, 1, .25)
    end
    local lift = vec3(0, 0, .5)
    -- several selected (a selection, a group) : each highlighted, none with its own handles held
    local selection = M.activePropIndex and M.propSelection or {}
    local several = #selection > 1
    for i, p in ipairs(list) do
        local selected = several and table.includes(selection, i)
        local isActive = i == M.activePropIndex and not several
        if (p.kind == "line" or p.kind == "sweep" or p.kind == "paint") and p.a and p.b then
            local a, b = vec3(p.a.x, p.a.y, p.a.z), vec3(p.b.x, p.b.y, p.b.z)
            local lineColor = (isActive or selected) and ACTIVE_COLOR or LINE_COLOR
            -- its path : a bent line as a few segments along its curve
            local path = beamjoy_props.linePath(p, 16) or { a, b }
            for k = 2, #path do
                draw.addLine(path[k - 1] + lift, .1, path[k] + lift, .1, lineColor)
            end
            for part, pos in pairs({ a = a, b = b }) do
                local held = isActive and M.activePropPart == part
                draw.addSphere(pos + lift, held and .7 or .45, held and ACTIVE_COLOR or LINE_COLOR)
            end
            -- its nodes (LINE NODES), smaller than its ends
            for k, n in ipairs(lineNodes(p)) do
                local held = isActive and M.activePropPart == "n" .. k
                draw.addSphere(vec3(n.x, n.y, n.z) + lift, held and .6 or .35, held and ACTIVE_COLOR or LINE_COLOR)
            end
        elseif (isActive or selected) and p.pos then
            draw.addSphere(vec3(p.pos.x, p.pos.y, p.pos.z) + lift, .5, ACTIVE_COLOR)
        end
    end
    for _, e in ipairs(beamjoy_props.expand(list)) do
        local cat = beamjoy_props.catalogForShape(e.shape)
        if cat and cat.invisible then
            local half = e.scale / 2
            local d, u = e.dir * half, e.up * half
            draw.addQuad(e.pos - d - u, e.pos + d - u, e.pos + d + u, e.pos - d + u, INVISIBLE_COLOR)
        end
    end
end

-- STATE TO THE UI ------------------------------------------------------------------------------

local function pushUpdate()
    local list = props() or {}
    beamjoy_communications_ui.send("BJEditorPropsUpdate", list)
    -- whether cars hit each prop : its own say, else its meshes' (beamjoy_props.isSolid ; direct
    -- report : props whose mesh has no collision said solid)
    local solid = {}
    for i, prop in ipairs(list) do
        solid[i] = beamjoy_props.isSolid(prop)
    end
    beamjoy_communications_ui.send("BJEditorPropsSolid", solid)
end

local function pushActive()
    if not M.activePropIndex then
        M.propSelection = {}
    elseif not table.includes(M.propSelection, M.activePropIndex) then
        M.propSelection = { M.activePropIndex }
    end
    beamjoy_communications_ui.send("BJEditorPropsActive", { index = M.activePropIndex, part = M.activePropPart,
        selected = M.propSelection })
end

--- the props' preview (beamjoy_props) and their handles catch up with a change to the props (or to
--- which are selected : not an edit)
local function propsChanged()
    M.propsRevision = M.propsRevision + 1
    drawOverlays()
    extensions.hook("onBJEditorPropsRefresh")
end

--- any edit made in the editor, the props' or the host's own (a gate moved, a point added) : the
--- props' collision goes back off (see M.testCollision), at once, whatever the edit was
function M.onEdit()
    if not M.testCollision then return end
    M.testCollision = false
    beamjoy_communications_ui.send("BJEditorPropsTestCollision", false)
    propsChanged()
end

local function markDirty()
    M.onEdit()
    if M.host then M.host.markDirty() end
end

--- the props solid or not (see M.testCollision) : not a change to them, so it doesn't go through
--- markDirty, which would turn it straight back off
---@param state boolean
local function onSetTestCollision(state)
    M.testCollision = state == true and active()
    propsChanged()
    beamjoy_communications_ui.send("BJEditorPropsTestCollision", M.testCollision)
end

-- how far ahead of you "move it in front of you" puts a prop, and where teleporting to one lands
local PROP_PLACE_AHEAD = 6

---@param v vec3|table
---@return table
local function xyz(v) return { x = v.x, y = v.y, z = v.z } end

---@param v table? {x, y, z}
---@return vec3?
local function toVec(v) return v and vec3(v.x, v.y, v.z) or nil end

--- a line's point remade (moved, turned, copied) keeps the width it had (a curb's `w`, see
--- beamjoy_props SWEEPS)
---@param point table the new {x, y, z}
---@param from table? the point it was
---@return table point
local function keepWidth(point, from)
    if type(from) == "table" then point.w = from.w end
    return point
end

--- a prop laid along a path by its two ends (and its bend) : a line of props, a curb or a wall
--- (beamjoy_props SWEEPS) or a painted line (PAINTS), edited by the same handles
---@param prop table?
---@return boolean
local function isPath(prop)
    return prop ~= nil and (prop.kind == "line" or prop.kind == "sweep" or prop.kind == "paint")
end

--- one object along its path (a curb, a wall, a painted line), cut in segments by its length
---@param prop table?
---@return boolean
local function isSwept(prop)
    return prop ~= nil and (prop.kind == "sweep" or prop.kind == "paint")
end

---@param dir vec3?
---@return vec3 dir made horizontal (straight ahead on the y axis if there's nothing left)
local function flatDir(dir)
    local flat = dir and vec3(dir.x, dir.y, 0) or vec3(0, 1, 0)
    if flat:length() < 1e-4 then return vec3(0, 1, 0) end
    return flat:normalized()
end

---@param h number
---@return number
local function round3(h) return math.floor(h * 1000 + .5) / 1000 end

---@param v number
---@return number
local function round2(v) return math.floor(v * 100 + .5) / 100 end

-- GROUND TILT (direct request : props laid on the ground's tilt, in lines especially) : a prop's
-- up is the ground's under its footprint, from the ground's height at its two ends and its two
-- sides, so a fence panel runs from the ground at one end to the ground at the other

-- how far either side of a prop the ground's side slope is measured (metres)
local TILT_HALF_WIDTH = .5

--- the ground's up under a footprint
---@param centre vec3
---@param way vec3 flat, the footprint's length along it
---@param halfLength number metres
---@param halfWidth number metres
---@return vec3
local function groundUp(centre, way, halfLength, halfWidth)
    local hl = math.max(.3, math.min(halfLength, 10))
    local hw = math.max(.3, math.min(halfWidth, 5))
    local left = vec3(-way.y, way.x, 0)
    local along = vec3(way.x * 2 * hl, way.y * 2 * hl,
        groundHeightAt(centre + way * hl) - groundHeightAt(centre - way * hl))
    local side = vec3(left.x * 2 * hw, left.y * 2 * hw,
        groundHeightAt(centre + left * hw) - groundHeightAt(centre - left * hw))
    local n = along:cross(side)
    if n:length() < 1e-6 then return vec3(0, 0, 1) end
    if n.z < 0 then n = -n end
    return n:normalized()
end

--- an up as a line keeps it (beamjoy_props.tiltOf : its x and y), nil when it's straight up
---@param up vec3
---@return {x: number, y: number}?
local function tiltKept(up)
    local m = beamjoy_props.MAX_TILT
    local x, y = math.max(-m, math.min(up.x, m)), math.max(-m, math.min(up.y, m))
    if math.abs(x) < .002 and math.abs(y) < .002 then return nil end
    return { x = round3(x), y = round3(y) }
end

--- a single prop laid on the ground under it, as it faces : its up the ground's, its facing kept
--- (only tilted)
---@param prop table a single prop entry
local function tiltSingle(prop)
    local pos, dir = toVec(prop.pos), toVec(prop.dir)
    if not pos or not dir then return end
    local flat = flatDir(dir)
    local meta = beamjoy_propPicker.measure(prop.shape)
    local scale = tonumber(prop.scale) or 1
    -- its footprint : the mesh's box, its +Y along its facing
    local halfLength, halfWidth, centre = 1, TILT_HALF_WIDTH, pos
    if meta and meta.minX then
        local right = vec3(flat.y, -flat.x, 0)
        halfLength = (meta.maxY - meta.minY) / 2 * scale
        halfWidth = (meta.maxX - meta.minX) / 2 * scale
        centre = pos + flat * ((meta.minY + meta.maxY) / 2 * scale) + right * ((meta.minX + meta.maxX) / 2 * scale)
    end
    local up = groundUp(centre, flat, halfLength, halfWidth)
    local kept = tiltKept(up)
    up = beamjoy_props.tiltOf(kept)
    local d = (flat - up * flat:dot(up)):normalized()
    prop.up = xyz(up)
    prop.dir = xyz(d)
end

-- a curb or a wall stands level across its path : each of its heights is lifted to the highest
-- ground found across its width (direct report : on ground not quite level, one edge of a sawtooth
-- curb went under it), at most this much above the ground under its middle (a probe landing on
-- something tall beside it)
local SWEEP_MAX_LIFT = .3

--- the ground's height under a curb's or a wall's point : the highest across its width
---@param p table a point (beamjoy_props.sweepPoints)
---@param halfWidth number
---@return number
local function sweepGroundAt(p, halfWidth)
    local h = groundHeightAt(p.pos)
    if halfWidth <= 0 then return h end
    local right = vec3(p.way.y, -p.way.x, 0)
    local top = h
    for _, f in ipairs({ -1, -.5, .5, 1 }) do
        local side = groundHeightAt(p.pos + right * (halfWidth * f))
        if side and side > top and side <= h + SWEEP_MAX_LIFT then top = side end
    end
    return top
end

--- a line's ground heights and tilts, one per prop (beamjoy_props.linePlacements), measured here
--- so a running game never has to : the editor's preview isn't in the static collision (see
--- beamjoy_props), so the probes can't land on the line's own props
---@param line table
local function updateLineHeights(line)
    if line.followGround == false then
        line.heights, line.normals = nil, nil
        return
    end
    -- a curb, a wall or a painted line : the ground's height at each end of its segments
    if isSwept(line) then
        line.normals = nil
        -- a curb's or a wall's footprint : its outline's widest at the ground (a painted line lies
        -- flat on it, measured under its middle)
        local halfWidth = 0
        local profile = line.kind == "sweep" and beamjoy_props.getSweep(line.profile)
        if profile then
            for _, o in ipairs(profile.outline) do
                if o[2] >= 0 then halfWidth = math.max(halfWidth, math.abs(o[1])) end
            end
        end
        line.heights = table.map(beamjoy_props.sweepPoints(line, true), function(p)
            return round3(sweepGroundAt(p, halfWidth * (p.w or 1)))
        end)
        return
    end
    -- where its props stand : on a curve that depends on their meshes' length
    local straight = beamjoy_props.linePlacements({ a = line.a, b = line.b, mid = line.mid, nodes = line.nodes,
        count = line.count,
        gap = line.gap, followGround = false, shape = line.shape, alt = line.alt, yaw = line.yaw,
        altYaw = line.altYaw, scale = line.scale, stretch = line.stretch })
    line.heights = table.map(straight, function(p) return round3(groundHeightAt(p.pos)) end)
    local any = false
    local normals = table.map(straight, function(p)
        local way = p.way or vec3(0, 1, 0)
        local back, ahead = p.back or -1, p.ahead or 1
        local kept = tiltKept(groundUp(p.pos + way * ((back + ahead) / 2), way, (ahead - back) / 2, TILT_HALF_WIDTH))
        any = any or kept ~= nil
        return kept or { x = 0, y = 0 }
    end)
    line.normals = any and normals or nil
end

---@param extra integer
---@return boolean room for that many more props
local function propBudget(extra)
    if beamjoy_props.total(props()) + extra <= beamjoy_props.MAX_PROPS then return true end
    toast.warn(string.format("%s can hold up to %d props", M.host and M.host.label or "This",
        beamjoy_props.MAX_PROPS), nil, 4)
    return false
end

-- a line's fixed gap (metres), within these
local GAP_MIN, GAP_MAX = .2, 100

--- a line with a fixed gap (direct request : guardrails chained on a line) holds as many props as
--- its length takes, within the props' limit : fitted again whenever its length changes
---@param line table a line of the props
local function fitLineCount(line)
    -- a curb or a wall : cut about every metre (a painted line every 2), within the props' limit
    -- (it weighs one prop every beamjoy_props.SWEEP_WEIGHT_SEGMENTS segments ; past that, its
    -- segments get longer)
    if isSwept(line) then
        local others = beamjoy_props.total(props()) - beamjoy_props.weight(line)
        local room = math.max(1, beamjoy_props.MAX_PROPS - others) * beamjoy_props.SWEEP_WEIGHT_SEGMENTS
        line.count = math.max(1, math.min(beamjoy_props.pathCount(line), room))
        return
    end
    local gap = tonumber(line.gap)
    if line.kind ~= "line" or not gap then return end
    local each = 1 + (type(line.parts) == "table" and #line.parts or 0)
    local caps = (type(line.capA) == "string" and 1 or 0) + (type(line.capB) == "string" and 1 or 0)
    local others = beamjoy_props.total(props()) - beamjoy_props.weight(line)
    local room = math.max(1, math.floor((beamjoy_props.MAX_PROPS - others - caps) / each))
    line.count = math.max(1, math.min(beamjoy_props.gapCount(line, gap), room))
end

--- the props selected with a prop : its group, or itself alone
---@param index integer
---@return integer[]
local function groupOf(index)
    local g = tonumber(props()[index] and props()[index].group)
    if not g then return { index } end
    local out = {}
    for i, p in ipairs(props()) do
        if tonumber(p.group) == g then out[#out + 1] = i end
    end
    return out
end

--- a group left with a single prop (the others ungrouped or deleted) is no group : that prop's
--- dropped too
local function pruneGroups()
    local members = {}
    for _, p in ipairs(props() or {}) do
        local g = tonumber(p.group)
        if g then members[g] = (members[g] or 0) + 1 end
    end
    for _, p in ipairs(props() or {}) do
        local g = tonumber(p.group)
        if g and members[g] < 2 then p.group = nil end
    end
end

--- selects a prop (direct request : multiple selection and groups). A prop of a group brings its
--- group ; "add" (Ctrl+click) adds it to what's selected, or takes it away when it was in ;
--- "alone" (Shift+click) selects it without its group, to edit one of a group ; "addAlone"
--- (Ctrl+Shift+click, direct request) adds or takes away that one prop of a group, its group left
---@param index integer?
---@param part string? a line's handle (its first end by default : LINE NODES)
---@param mode "add"|"alone"|"addAlone"|nil
function M.onSelectProp(index, part, mode)
    if not props() then return end
    local prop = index and props()[index]
    -- nothing to drop : the host's own selection (and its gizmo) stays
    if not prop and not M.activePropIndex then return end
    if index then disarmProp() end
    if not prop then
        M.activePropIndex, M.propSelection = nil, {}
    elseif (mode == "add" or mode == "addAlone") and M.activePropIndex then
        local members = mode == "addAlone" and { index } or groupOf(index)
        local removing = table.includes(M.propSelection, index)
        local selection = {}
        for _, i in ipairs(M.propSelection) do
            if not (removing and table.includes(members, i)) then selection[#selection + 1] = i end
        end
        if not removing then
            for _, i in ipairs(members) do
                if not table.includes(selection, i) then selection[#selection + 1] = i end
            end
        end
        M.propSelection = table.sort(selection)
        if removing then
            M.activePropIndex = table.includes(M.propSelection, M.activePropIndex) and M.activePropIndex or
                M.propSelection[#M.propSelection]
        else
            M.activePropIndex = index
        end
    else
        M.propSelection = (mode == "alone" or mode == "addAlone") and { index } or groupOf(index)
        M.activePropIndex = index
    end
    local chosen = M.activePropIndex and props()[M.activePropIndex]
    -- a line's handles while it's alone in the selection, the whole selection's gizmo otherwise
    local function handle()
        if part == "b" then return "b" end
        -- an older UI's middle : the first node
        local k = nodeIndex(part == "mid" and "n1" or part)
        if k and lineNodes(chosen)[k] then return "n" .. k end
        return "a"
    end
    M.activePropPart = chosen and isPath(chosen) and #M.propSelection <= 1 and handle() or nil
    if chosen then hostSelects() end
    updatePropGizmo()
    pushActive()
    propsChanged()
end

--- every point of a line (its ends, its nodes, an older line's bend) replaced by `fn`'s
---@param line table
---@param fn fun(p: table): table a point {x, y, z} to its new {x, y, z}
local function mapPathPoints(line, fn)
    for _, key in ipairs({ "a", "b", "mid" }) do
        if line[key] then line[key] = keepWidth(fn(line[key]), line[key]) end
    end
    if type(line.nodes) == "table" then
        local moved = {}
        for k, p in ipairs(line.nodes) do moved[k] = keepWidth(fn(p), p) end
        line.nodes = moved
    end
end

--- every point of a line moved by the same offset
---@param line table
---@param delta vec3
local function shiftLine(line, delta)
    mapPathPoints(line, function(p) return xyz(toVec(p) + delta) end)
end

--- after a whole line was moved : every point of it back on the ground
---@param line table
local function snapLine(line)
    mapPathPoints(line, function(p) return { x = p.x, y = p.y, z = groundHeightAt(toVec(p)) } end)
end

--- a line edited by its handles stops following the ground with the editor's snapping off (direct
--- report : a line laid with snapping on still followed the ground, edited with it off), and keeps
--- its own "Follow the ground" with it on (direct report : turned off, it came back on at the next
--- move) ; measured again
---@param line table
local function lineEdited(line)
    if not snapOn() then line.followGround = false end
    fitLineCount(line)
    updateLineHeights(line)
end

--- the points a prop stands on : a single prop's position, a line's ends and its nodes
---@param prop table
---@return vec3[]
local function propPoints(prop)
    if isPath(prop) then
        local out = {}
        for _, key in ipairs({ "a", "b", "mid" }) do
            if prop[key] then out[#out + 1] = toVec(prop[key]) end
        end
        if type(prop.nodes) == "table" then
            for _, n in ipairs(prop.nodes) do out[#out + 1] = toVec(n) end
        end
        return out
    end
    return prop.pos and { toVec(prop.pos) } or {}
end

--- the gizmo on several props (a selection, a group) : moved and turned as one round their
--- middle, each from where it was when the gizmo was shown. Snapping keeps them as they stand
--- together (direct request : stacked trusses), the whole lot lifted or lowered with the ground
--- under their middle, instead of each dropped on the ground
local function showSelectionGizmo()
    local before, sum, n = {}, vec3(0, 0, 0), 0
    for _, i in ipairs(M.propSelection) do
        local prop = props()[i]
        if prop then
            before[i] = table.clone(prop)
            for _, p in ipairs(propPoints(prop)) do sum, n = sum + p, n + 1 end
        end
    end
    if n == 0 then return end
    local pivot = sum * (1 / n)
    local up = vec3(0, 0, 1)
    local offset = vec3(0, 0, 0)
    ---@param q table? a turn round the pivot
    ---@param delta vec3 a move
    local function apply(q, delta)
        local function place(p)
            local v = toVec(p) - pivot
            return xyz(pivot + delta + (q and q * v or v))
        end
        for i, was in pairs(before) do
            local prop = props()[i]
            if prop then
                if isPath(prop) then
                    for _, key in ipairs({ "a", "b", "mid" }) do
                        if was[key] then prop[key] = keepWidth(place(was[key]), was[key]) end
                    end
                    if type(was.nodes) == "table" then
                        local nodes = {}
                        for k, n in ipairs(was.nodes) do nodes[k] = keepWidth(place(n), n) end
                        prop.nodes = nodes
                    end
                    prop.heights, prop.normals = nil, nil
                elseif was.pos then
                    prop.pos = place(was.pos)
                    if q then
                        prop.dir = xyz(q * toVec(was.dir))
                        prop.up = xyz(q * (toVec(was.up) or up))
                    end
                end
            end
        end
    end
    gizmo.show({
        pos = pivot,
        dir = vec3(0, 1, 0),
        up = up,
        scales = vec3(1, 1, 1),
    }, function(updated) ---@param updated GizmoObject
        if not active() then return end
        if gizmo.tool == "rotate" then
            apply(quatFromDir(updated.dir, updated.up), vec3(0, 0, 0))
        else
            offset = updated.pos - pivot
            apply(nil, offset)
        end
        markDirty()
        propsChanged()
    end, function()
        if snapOn() and gizmo.tool ~= "rotate" then
            -- the height they stood at above the ground under their middle, kept
            local rise = groundHeightAt(pivot + offset) - groundHeightAt(pivot)
            apply(nil, vec3(offset.x, offset.y, rise))
        end
        for i in pairs(before) do
            local prop = props()[i]
            if isPath(prop) then
                fitLineCount(prop)
                updateLineHeights(prop)
            end
        end
        pushUpdate()
        updatePropGizmo()
        propsChanged()
    end)
end

updatePropGizmo = function()
    gizmo.hide()
    if not props() or not M.activePropIndex then return end
    if #M.propSelection > 1 then return showSelectionGizmo() end
    local prop = M.activePropIndex and props()[M.activePropIndex]
    if not prop then return end
    local up = vec3(0, 0, 1)
    local node = isPath(prop) and nodeIndex(M.activePropPart)
    if node and lineNodes(prop)[node] then
        -- a node (LINE NODES) : the line curves through it, facing from the point before to the one
        -- after
        local knots = lineKnots(prop)
        local whole = false
        gizmo.show({
            pos = toVec(knots[node + 1]),
            dir = flatDir(toVec(knots[node + 2]) - toVec(knots[node])),
            up = up,
            scales = vec3(1, 1, 1),
        }, function(updated) ---@param updated GizmoObject
            if not active() then return end
            if ctrlHeld() then
                -- the whole line, its shape kept
                shiftLine(prop, updated.pos - toVec(lineNodes(prop)[node]))
                whole = true
            else
                local nodes = ensureNodes(prop)
                nodes[node] = keepWidth(xyz(updated.pos), nodes[node])
            end
            prop.heights, prop.normals = nil, nil -- measured again once dropped
            fitLineCount(prop)
            markDirty()
            propsChanged()
        end, function()
            local held = lineNodes(prop)[node]
            if whole and snapOn() then
                snapLine(prop)
            elseif held and snapOn() then
                held.z = groundHeightAt(toVec(held))
            end
            lineEdited(prop)
            pushUpdate()
            updatePropGizmo()
            propsChanged()
        end)
    elseif isPath(prop) then
        local part = M.activePropPart == "b" and "b" or "a"
        local knots = lineKnots(prop)
        local pos = toVec(prop[part])
        local whole = false
        gizmo.show({
            pos = pos,
            -- facing its neighbour (the next node, the other end without one)
            dir = flatDir(toVec(part == "a" and knots[2] or knots[#knots - 1]) - pos),
            up = up,
            scales = vec3(1, 1, 1),
        }, function(updated) ---@param updated GizmoObject
            if not active() then return end
            -- an end only moves : the line's props face along it whatever the gizmo was turned to ;
            -- with Ctrl held the whole line moves with it
            if ctrlHeld() then
                shiftLine(prop, updated.pos - toVec(prop[part]))
                whole = true
            else
                prop[part] = keepWidth(xyz(updated.pos), prop[part])
            end
            prop.heights, prop.normals = nil, nil -- straight while dragging, measured again once dropped
            fitLineCount(prop)
            markDirty()
            propsChanged()
        end, function()
            if whole and snapOn() then
                snapLine(prop)
            elseif snapOn() then
                prop[part].z = groundHeightAt(toVec(prop[part]))
            end
            lineEdited(prop)
            pushUpdate()
            updatePropGizmo()
            propsChanged()
        end)
    else
        gizmo.show({
            pos = toVec(prop.pos),
            dir = toVec(prop.dir),
            up = toVec(prop.up) or up,
            scales = vec3(1, 1, 1),
        }, function(updated) ---@param updated GizmoObject
            if not active() then return end
            prop.pos = xyz(updated.pos)
            prop.dir = xyz(updated.dir)
            prop.up = xyz(updated.up)
            markDirty()
            propsChanged()
        end, function()
            -- dropped on the ground with snapping on ; one following the ground (its own switch,
            -- direct request) is on it and laid on its tilt wherever it's moved or turned to
            local follow = prop.followGround == true
            if gizmo.tool ~= "rotate" and (snapOn() or follow) then
                prop.pos.z = groundHeightAt(toVec(prop.pos))
            end
            if follow then tiltSingle(prop) end
            pushUpdate()
            updatePropGizmo()
            propsChanged()
        end)
    end
end

---@return vec3? at where a new prop goes, vec3? facing your flat facing
local function propPlacement()
    local pos, dir = currentPositionDirection()
    if not pos then return nil end
    local facing = flatDir(dir)
    local at = pos + facing * PROP_PLACE_AHEAD
    at = vec3(at.x, at.y, snapOn() and groundHeightAt(at) or pos.z)
    return at, facing
end

-- a prop placed alone stands as one of a line drawn left to right across your view, its long side
-- across (direct report : alone, many came end on, a quarter turn off the same prop in a line). The
-- tuning yaw lays a mesh's long side along a direction : a line's, or this one, your right
local SINGLE_ACROSS = -90

---@param facing vec3 your flat facing
---@param yaw number the mesh's tuning yaw plus any turn of yours (degrees)
---@return vec3 dir the prop's
local function singleDir(facing, yaw)
    return beamjoy_props.turn(facing, yaw + SINGLE_ACROSS)
end

---@param prop table a single prop
---@return vec3 along its long side, as a line of it would run
local function singleAlong(prop)
    return beamjoy_props.turn(flatDir(toVec(prop.dir)), -beamjoy_props.tuning(prop.shape).yaw)
end

---@param prop table
---@param unselected boolean? added as it is, nothing selected (the props drawer placing on)
local function addProp(prop, unselected)
    table.insert(props(), prop)
    if unselected then
        markDirty()
        pushUpdate()
        propsChanged()
        return
    end
    M.activePropIndex = #props()
    M.activePropPart = isPath(prop) and "b" or nil
    M.propSelection = {}
    hostSelects()
    updatePropGizmo()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

---@return integer a group no prop has yet
local function newGroupId()
    local id = 0
    for _, p in ipairs(props()) do id = math.max(id, tonumber(p.group) or 0) end
    return id + 1
end

--- several entries added at once (a group eyedropped, the clipboard pasted) : their groups kept
--- together, apart from the props' own groups ; selected together unless `unselected`
---@param list table[]
---@param unselected boolean?
local function addProps(list, unselected)
    local base, groups = newGroupId() - 1, {}
    local first = #props() + 1
    for _, prop in ipairs(list) do
        -- its own tables (a line's ends, its heights) : nobody else's
        local copy = deepcopy(prop)
        local g = tonumber(copy.group)
        if g then
            if not groups[g] then
                base = base + 1
                groups[g] = base
            end
            copy.group = groups[g]
        end
        table.insert(props(), copy)
    end
    if not unselected then
        M.propSelection = {}
        for i = first, #props() do M.propSelection[#M.propSelection + 1] = i end
        M.activePropIndex, M.activePropPart = first, nil
        hostSelects()
        updatePropGizmo()
    end
    markDirty()
    pushUpdate()
    if not unselected then pushActive() end
    propsChanged()
end

---@param index integer
---@param partial table scale / count / yaw / followGround / gap (metres) / fixedGap (on : a gap
---of the line's own spacing now ; off : its count kept) / width (a painted line's, metres)
local function onSetProp(index, partial)
    local prop = props() and props()[index]
    if not prop or type(partial) ~= "table" then return end
    if partial.scale ~= nil and not isSwept(prop) then
        prop.scale = round2(math.max(.1, math.min(tonumber(partial.scale) or 1, 10)))
    end
    -- a single prop (a prefab too) following the ground (direct request) : on it, laid on its
    -- tilt ; off, stood straight up again, its heading kept
    if not isPath(prop) and partial.followGround ~= nil and prop.pos and prop.dir then
        prop.followGround = partial.followGround == true
        if prop.followGround then
            prop.pos.z = groundHeightAt(toVec(prop.pos))
            tiltSingle(prop)
        else
            prop.dir = xyz(flatDir(toVec(prop.dir)))
            prop.up = { x = 0, y = 0, z = 1 }
        end
        updatePropGizmo()
    end
    if prop.kind == "paint" and tonumber(partial.width) then
        prop.width = round2(math.max(beamjoy_props.PAINT_WIDTH_MIN,
            math.min(tonumber(partial.width), beamjoy_props.PAINT_WIDTH_MAX)))
    end
    if isSwept(prop) then
        if partial.followGround ~= nil then prop.followGround = partial.followGround == true end
        fitLineCount(prop)
        updateLineHeights(prop)
    end
    if prop.kind == "line" then
        if partial.fixedGap ~= nil then
            if partial.fixedGap == true and not prop.gap then
                -- its props end to end, no gap between them (direct request) ; for a mesh not
                -- measured, the line's own spacing now
                local spacing = beamjoy_props.gaplessGap(prop)
                if not spacing then
                    local count = math.max(1, tonumber(prop.count) or 1)
                    spacing = count > 1 and beamjoy_props.lineLength(prop) / (count - 1) or
                        beamjoy_props.tuning(prop.shape).length * (prop.scale or 1)
                end
                prop.gap = math.max(GAP_MIN, math.min(round2(spacing), GAP_MAX))
            elseif partial.fixedGap == false then
                prop.gap = nil
            end
        end
        if partial.gap ~= nil and prop.gap and tonumber(partial.gap) then
            prop.gap = round2(math.max(GAP_MIN, math.min(tonumber(partial.gap), GAP_MAX)))
        end
        if partial.count ~= nil and not prop.gap then
            local others = beamjoy_props.total(props()) - beamjoy_props.weight(prop)
            -- each of its props with its parts (a line of prefabs)
            local each = 1 + (type(prop.parts) == "table" and #prop.parts or 0)
            prop.count = math.max(1, math.min(math.floor(tonumber(partial.count) or prop.count),
                math.floor((beamjoy_props.MAX_PROPS - others) / each)))
        end
        if partial.yaw ~= nil then
            prop.yaw = round2(((tonumber(partial.yaw) or 0) + 180) % 360 - 180)
        end
        if partial.followGround ~= nil then prop.followGround = partial.followGround == true end
        fitLineCount(prop)
        updateLineHeights(prop)
    end
    markDirty()
    pushUpdate()
    propsChanged()
end

--- cars hit the prop, or drive through it (direct request), whatever its mesh : one with no
--- collision of its own gets its visible mesh's (beamjoy_props collisionOf). The editor's own
--- preview is only solid while its collision switch is on (M.testCollision) : this shows there and
--- in the race. A prop of a selection of several : the whole selection set so (direct request),
--- whatever each was
---@param index integer
---@param solid boolean
local function onSetPropSolid(index, solid)
    if not props() or not props()[index] then return end
    local targets = (#M.propSelection > 1 and table.includes(M.propSelection, index)) and M.propSelection or
        { index }
    local want = solid == true
    local any = false
    for _, i in ipairs(targets) do
        local prop = props()[i]
        -- a curb or a wall is always solid (beamjoy_props SWEEPS), a painted line never
        if prop and not isSwept(prop) then
            -- kept only where it differs from its meshes' own ; not `cond and x or nil`, which is
            -- never false
            if want == beamjoy_props.solidByDefault(prop) then
                prop.solid = nil
            else
                prop.solid = want
            end
            any = true
        end
    end
    if not any then return end
    markDirty()
    pushUpdate()
    propsChanged()
end

---@param index integer
local function onDeleteProp(index)
    if not props() or not props()[index] then return end
    table.remove(props(), index)
    pruneGroups()
    M.activePropIndex, M.activePropPart, M.propSelection = nil, nil, {}
    gizmo.hide()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

--- every selected prop goes (the Delete key, the selection's Delete)
local function onDeleteSelectedProps()
    if not props() or #M.propSelection == 0 then return end
    local doomed = table.sort(table.clone(M.propSelection), function(a, b) return a > b end)
    for _, i in ipairs(doomed) do
        if props()[i] then table.remove(props(), i) end
    end
    pruneGroups()
    M.activePropIndex, M.activePropPart, M.propSelection = nil, nil, {}
    gizmo.hide()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

--- the selected props become a group (direct request) : selected and moved together from then on,
--- a prop of another group leaving it
local function onGroupProps()
    if not props() or #M.propSelection < 2 then return end
    local id = 0
    for _, p in ipairs(props()) do id = math.max(id, tonumber(p.group) or 0) end
    for _, i in ipairs(M.propSelection) do
        if props()[i] then props()[i].group = id + 1 end
    end
    pruneGroups()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

--- the selected props leave their groups (they stay selected) : a whole group, or some of it
--- picked alone (Shift+click, Ctrl+Shift+click ; direct request)
local function onUngroupProps()
    if not props() then return end
    for _, i in ipairs(M.propSelection) do
        if props()[i] then props()[i].group = nil end
    end
    pruneGroups()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

--- a copy beside the original : a single prop one of its own lengths on along its long side (as the
--- next of a line), a line 4 m to the right of its direction
---@param index integer
local function onDuplicateProp(index)
    local prop = props() and props()[index]
    if not prop or not propBudget(beamjoy_props.weight(prop)) then return end
    local copy = table.clone(prop)
    if isPath(prop) then
        local a, b = toVec(prop.a), toVec(prop.b)
        local offset = flatDir(b - a):cross(vec3(0, 0, 1)) * 4
        local na, nb = a + offset, b + offset
        if snapOn() then
            na = vec3(na.x, na.y, groundHeightAt(na))
            nb = vec3(nb.x, nb.y, groundHeightAt(nb))
        end
        copy.a, copy.b = keepWidth(xyz(na), prop.a), keepWidth(xyz(nb), prop.b)
        copy.mid, copy.nodes = nil, nil
        for _, key in ipairs({ "mid", "nodes" }) do
            if prop[key] then
                local was = { [key] = deepcopy(prop[key]) }
                mapPathPoints(was, function(p)
                    local nm = toVec(p) + offset
                    if snapOn() then nm = vec3(nm.x, nm.y, groundHeightAt(nm)) end
                    return xyz(nm)
                end)
                copy[key] = was[key]
            end
        end
        updateLineHeights(copy)
    else
        local pos = toVec(prop.pos) + singleAlong(prop) * (beamjoy_props.tuning(prop.shape).length * (prop.scale or 1))
        if snapOn() then pos = vec3(pos.x, pos.y, groundHeightAt(pos)) end
        copy.pos = xyz(pos)
    end
    addProp(copy)
end

--- a bent line goes straight again (every node dropped)
---@param index integer
local function onStraightenPropLine(index)
    local line = props() and props()[index]
    if not isPath(line) or #lineNodes(line) == 0 then return end
    line.mid, line.nodes = nil, nil
    if index == M.activePropIndex and nodeIndex(M.activePropPart) then M.activePropPart = "a" end
    fitLineCount(line)
    updateLineHeights(line)
    updatePropGizmo()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

--- a line's points changed (a node added or taken out, an end added) : measured again, the handle
--- `part` held
---@param index integer
---@param part string
local function lineReshaped(index, part)
    local line = props()[index]
    tidyNodes(line)
    fitLineCount(line)
    updateLineHeights(line)
    M.activePropIndex, M.activePropPart = index, part
    if #M.propSelection > 1 or not table.includes(M.propSelection, index) then M.propSelection = { index } end
    updatePropGizmo()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

---@param line table
---@return boolean room for one more node
local function nodeRoom(line)
    if #lineNodes(line) < beamjoy_props.MAX_LINE_NODES then return true end
    toast.warn(string.format("A line can have up to %d nodes", beamjoy_props.MAX_LINE_NODES), nil, 4)
    return false
end

--- a node added to a line at a point of its path, in its span `span` (between its point `span` and
--- the next, beamjoy_props.linePath's knotAt) : held next
---@param index integer
---@param span integer
---@param pos vec3
---@return integer? node the node added
local function insertNode(index, span, pos)
    local line = props() and props()[index]
    if not isPath(line) or not nodeRoom(line) then return end
    local nodes = ensureNodes(line)
    span = math.max(1, math.min(span, #nodes + 1))
    local at = vec3(pos.x, pos.y, pos.z)
    if snapOn() then at.z = groundHeightAt(at) end
    -- a curb's width there (its ends' and nodes', eased between them), so adding it changes nothing
    local w
    if line.kind == "sweep" then
        local best
        for _, sp in ipairs(beamjoy_props.sweepPoints(line, true)) do
            local d = vec3(sp.pos.x - at.x, sp.pos.y - at.y, 0):length()
            if not best or d < best then best, w = d, sp.w end
        end
        w = w and math.abs(w - 1) > 1e-3 and round3(w) or nil
    end
    local node = xyz(at)
    node.w = w
    table.insert(nodes, span, node)
    lineReshaped(index, "n" .. span)
    return span
end

--- a line made longer to a point : a new end there, the end it's nearer a node now (as the game's
--- spline editor adds a node off its spline)
---@param index integer
---@param pos vec3
---@param first boolean the new end is its first
---@return string? key the end made ("a" / "b")
local function extendLine(index, pos, first)
    local line = props() and props()[index]
    if not isPath(line) or not nodeRoom(line) then return end
    local at = vec3(pos.x, pos.y, pos.z)
    if snapOn() then at.z = groundHeightAt(at) end
    local key = first and "a" or "b"
    if toVec(line[key]):distance(at) < NODE_MIN_SPACING then return end
    local nodes = ensureNodes(line)
    if first then
        table.insert(nodes, 1, line.a)
    else
        nodes[#nodes + 1] = line.b
    end
    line[key] = keepWidth(xyz(at), first and nodes[1] or nodes[#nodes])
    lineReshaped(index, key)
    return key
end

--- a line's node taken out (its curve then runs from the point before to the one after) ; the
--- point before held next
---@param index integer
---@param node integer
local function removeNode(index, node)
    local line = props() and props()[index]
    if not isPath(line) or not lineNodes(line)[node] then return end
    table.remove(ensureNodes(line), node)
    lineReshaped(index, node > 1 and "n" .. (node - 1) or "a")
end

--- the point halfway along a line's span `span` (along its curve)
---@param line table
---@param span integer
---@return vec3?
local function spanMiddle(line, span)
    local path, knotAt = beamjoy_props.linePath(line, 64)
    if not path or not knotAt[span + 1] then return nil end
    local from, to = knotAt[span], knotAt[span + 1]
    local total = 0
    for k = from + 1, to do total = total + path[k]:distance(path[k - 1]) end
    local run = 0
    for k = from + 1, to do
        local seg = path[k]:distance(path[k - 1])
        if run + seg >= total / 2 then
            local f = seg > 1e-6 and (total / 2 - run) / seg or 0
            return path[k - 1] + (path[k] - path[k - 1]) * f
        end
        run = run + seg
    end
    return path[to]
end

--- the props list's "Add node" : a node halfway along the span after the handle held (before it,
--- for the last end)
---@param index integer
local function onAddPropNode(index)
    local line = props() and props()[index]
    if not isPath(line) then return end
    local spans = #lineNodes(line) + 1
    local part = index == M.activePropIndex and M.activePropPart or "a"
    local span = part == "b" and spans or (nodeIndex(part) or 0) + 1
    span = math.max(1, math.min(span, spans))
    local at = spanMiddle(line, span)
    if at then insertNode(index, span, at) end
end

--- the props list's "Remove node" : the node held
---@param index integer
local function onRemovePropNode(index)
    local node = index == M.activePropIndex and nodeIndex(M.activePropPart)
    if node then removeNode(index, node) end
end

--- a prop's place in the list taken by others, selected together (and grouped, as they were one)
---@param index integer
---@param singles table[]
---@param group integer? the group they make
local function replaceProp(index, singles, group)
    table.remove(props(), index)
    for i, single in ipairs(singles) do
        single.group = group
        table.insert(props(), index + i - 1, single)
    end
    M.activePropIndex = #singles > 0 and index or nil
    M.activePropPart = nil
    M.propSelection = {}
    for i = 1, #singles do M.propSelection[i] = index + i - 1 end
    updatePropGizmo()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

--- a line becomes its props, one by one, each where it was (a line of prefabs, its prefabs)
---@param index integer
local function onSplitPropLine(index)
    local line = props() and props()[index]
    if not line or line.kind ~= "line" then return end
    local singles = table.map(beamjoy_props.linePlacements(line), function(p, k)
        -- a line with another mesh every other prop (see onSetPropAlt) keeps it
        local other = type(line.alt) == "string" and k % 2 == 0
        return {
            kind = "static",
            shape = other and line.alt or line.shape,
            pos = xyz(p.pos),
            dir = xyz(other and beamjoy_props.turn(p.dir, tonumber(line.altYaw) or 0) or p.dir),
            up = xyz(p.up),
            scale = line.scale or 1,
            lift = other and line.altLift or line.lift,
            stretch = line.stretch and table.clone(line.stretch) or nil,
            solid = line.solid,
            parts = not other and type(line.parts) == "table" and table.clone(line.parts) or nil,
            prefab = not other and line.prefab or nil,
            -- on the ground as the line was
            followGround = line.followGround ~= false or nil,
        }
    end)
    -- its end caps, where they were
    for _, c in ipairs(beamjoy_props.lineCaps(line, beamjoy_props.linePlacements(line))) do
        singles[#singles + 1] = {
            kind = "static",
            shape = c.shape,
            pos = xyz(c.pos),
            dir = xyz(c.dir),
            up = xyz(c.up),
            scale = line.scale or 1,
            lift = c.lift,
            stretch = line.stretch and table.clone(line.stretch) or nil,
            solid = line.solid,
            followGround = line.followGround ~= false or nil,
        }
    end
    replaceProp(index, singles, tonumber(line.group))
end

--- a prefab becomes its meshes (direct request), each where it was : a group of them, to move
--- together still or (Shift+click) one by one
---@param index integer
local function onSplitPrefab(index)
    local prop = props() and props()[index]
    if not prop or isPath(prop) or type(prop.parts) ~= "table" then return end
    local singles = table.map(beamjoy_props.expand({ prop }), function(e)
        return {
            kind = "static",
            shape = e.shape,
            pos = xyz(e.pos),
            dir = xyz(e.dir),
            up = xyz(e.up),
            scale = prop.scale or 1,
            stretch = prop.stretch and table.clone(prop.stretch) or nil,
            -- already lifted as the prefab stood
            lift = 0,
            solid = prop.solid,
        }
    end)
    if #singles == 0 then return end
    replaceProp(index, singles, tonumber(prop.group) or newGroupId())
end

--- your car a few metres short of the prop (a line's first end), facing it
---@param index integer
local function onTeleportToProp(index)
    local prop = props() and props()[index]
    local current = beamjoy_vehicles.getCurrentOwn()
    if not prop or not current then return end
    local target, facing
    if isPath(prop) then
        target = toVec(prop.a)
        facing = flatDir(toVec(prop.b) - target)
    else
        target = toVec(prop.pos)
        -- facing it as it was placed (its long side across ; a prefab, the way it faces)
        facing = type(prop.parts) == "table" and flatDir(toVec(prop.dir)) or
            beamjoy_props.turn(singleAlong(prop), -SINGLE_ACROSS)
    end
    beamjoy_vehicles.setVehiclePositionRotation(current.veh, target - facing * (PROP_PLACE_AHEAD + 2), facing,
        vec3(0, 0, 1))
end

--- a single prop moves to where a new one would go (ahead of you, facing your way)
---@param index integer
local function onSetPropToVehicle(index)
    local prop = props() and props()[index]
    if not prop or isPath(prop) then return end
    local at, facing = propPlacement()
    if not at then return end
    prop.pos = xyz(at)
    prop.dir = xyz(singleDir(facing, beamjoy_props.tuning(prop.shape).yaw))
    prop.up = { x = 0, y = 0, z = 1 }
    if prop.followGround == true then
        prop.pos.z = groundHeightAt(at)
        tiltSingle(prop)
    end
    updatePropGizmo()
    markDirty()
    pushUpdate()
    propsChanged()
end

-- PLACING --------------------------------------------------------------------------------------
-- The props drawer's armed prop (direct request) : a ghost of it follows the mouse over the world ;
-- a click places one there, a click-and-drag lays a line of them. The wheel turns it (or, while
-- dragging, spaces the line out), Ctrl on release keeps it armed for the next one, a right-click
-- or Esc stops. Per frame : one ray against the static collision (castRayStatic : neither the ghost
-- nor the editor's preview props are in it, see beamjoy_props) and the ghost moved (one
-- no-collision TSStatic, a line's worth while dragging).

local PLACE_RAY_DISTANCE = 1000
-- a shorter drag is a click : one prop
local PLACE_LINE_MIN = 1.5
local PLACE_LINE_MAX_COUNT = 60
local PLACE_ROTATE_STEP = 15
-- Ctrl + wheel (direct request : fine rotation control)
local PLACE_ROTATE_FINE = 1
local PLACE_SPACING_MIN, PLACE_SPACING_MAX = .5, 4
local GHOST_SET = "editorGhost"

---@type {shape: string, rot: number, spacing: number, hit: vec3?, facing: vec3?, drag: {a: vec3, b: vec3, facing: vec3}?}?
M.placing = nil
--- the drawer's "Keep placing" (direct request) : a prop stays armed after each one placed, as with
--- Ctrl held, until it's turned off or placing stops. The player's own choice, kept by the drawer
M.keepPlacing = false
local lastPlacingPush = nil


--- the drawer's "Fixed rotation" (direct request : trusses) : a prop placed alone keeps the turn
--- the wheel gave it, whichever way the camera looks (at 0, as if placed looking north). The
--- player's own choice, kept by the drawer
M.fixedRotation = false
local NORTH = vec3(0, 1, 0)

---@param degrees number
---@return number in -180..180
local function wrapYaw(degrees) return (degrees + 180) % 360 - 180 end

---@param v vec3
---@return number the heading of a direction, as turn() counts it from north (degrees)
local function headingOf(v)
    return math.deg(math.atan2(-v.x, v.y))
end

--- a mesh's own lift, kept on the entry for one the catalog doesn't tune (its lift was measured
--- here, so every player stands it the same) ; nil otherwise
---@param shape string
---@param tuning table beamjoy_props.tuning(shape)
---@return number?
local function entryLift(shape, tuning)
    if beamjoy_props.catalogForShape(shape) or math.abs(tuning.lift) < 1e-3 then return nil end
    return round3(tuning.lift)
end

--- how what's armed is laid down : a mesh's tuning, or a prefab's (its yaw in a line, its length)
---@param p table M.placing
---@return {yaw: number, length: number, lift: number}
local function placingTuning(p)
    if p.prefab then
        local t = beamjoy_props.prefabTuning(p.prefab)
        return { yaw = t.yaw, length = t.length, lift = 0 }
    end
    return beamjoy_props.tuning(p.shape)
end

-- a curb, a wall or a painted line placed with a click (no drag) : this long, across your view
local SWEEP_CLICK_LENGTH = 10

--- what a release would place with a curb, a wall or a paint armed : one along the line dragged,
--- or (a click) one SWEEP_CLICK_LENGTH long across your view, turned by the wheel. Within the
--- props' limit : a long one past it has longer segments, none is placed once the props are full
---@param p table M.placing
---@return table? entry, number meters
local function sweepPlacingEntry(p)
    local d = p.drag
    local a, b
    if d and d.a:distance(d.b) >= PLACE_LINE_MIN then
        a, b = vec3(d.a), vec3(d.b)
    else
        local at, facing = d and d.a or p.hit, d and d.facing or p.facing
        if not at or not facing then return nil, 0 end
        local along = beamjoy_props.turn(M.fixedRotation and NORTH or facing, p.rot + SINGLE_ACROSS)
        a = at - along * (SWEEP_CLICK_LENGTH / 2)
        b = at + along * (SWEEP_CLICK_LENGTH / 2)
        if snapOn() then
            a.z = groundHeightAt(a)
            b.z = groundHeightAt(b)
        end
    end
    local sweep
    if p.paint then
        -- its width : the one eyedropped, else the paint's own
        local width = tonumber(p.width) or beamjoy_props.getPaint(p.paint).width
        sweep = { kind = "paint", paint = p.paint, a = xyz(a), b = xyz(b), width = width, followGround = snapOn() }
    else
        sweep = { kind = "sweep", profile = p.sweep, a = xyz(a), b = xyz(b), followGround = snapOn() }
    end
    local room = (beamjoy_props.MAX_PROPS - beamjoy_props.total(props())) * beamjoy_props.SWEEP_WEIGHT_SEGMENTS
    local wanted = beamjoy_props.pathCount(sweep)
    p.capped = wanted > room
    if room < 1 then return nil, 0 end
    sweep.count = math.min(wanted, room)
    updateLineHeights(sweep)
    return sweep, beamjoy_props.lineLength(sweep)
end

--- what a release would place with a group eyedropped (armGroup) : its copies, their middle at the
--- mouse, turned round it by the wheel, as high above what the mouse is on as their middle stood
--- above the ground (stacked props stay stacked). Their lines measured on the ground again only
--- once the mouse or the turn moved (the ghost asks every frame)
---@param p table M.placing
---@return table[]? entries
local function groupPlacingEntries(p)
    local g = p.group
    local at = p.drag and p.drag.a or p.hit
    if not at then return nil end
    local turnBy = p.rot % 360
    local last = g.last
    if last and last.at:distance(at) < .02 and last.turnBy == turnBy and last.snap == snapOn() then
        p.capped = last.capped
        if last.capped then return nil end
        return deepcopy(last.entries)
    end
    g.lift = g.lift or g.centre.z - groundHeightAt(g.centre)
    local target = vec3(at.x, at.y, at.z + g.lift)
    local function place(v)
        local o = beamjoy_props.turn(toVec(v) - g.centre, turnBy)
        return xyz(target + o)
    end
    local function turned(v)
        return v and xyz(beamjoy_props.turn(toVec(v), turnBy)) or nil
    end
    local entries = {}
    for k, e in ipairs(g.entries) do
        local copy = deepcopy(e)
        if isPath(copy) then
            mapPathPoints(copy, place)
            updateLineHeights(copy)
        elseif copy.pos then
            copy.pos = place(copy.pos)
            copy.dir = turned(copy.dir)
            copy.up = turned(copy.up)
        end
        entries[k] = copy
    end
    p.capped = beamjoy_props.total(entries) > beamjoy_props.MAX_PROPS - beamjoy_props.total(props())
    g.last = { at = vec3(at), turnBy = turnBy, snap = snapOn(), capped = p.capped, entries = entries }
    if p.capped then return nil end
    return deepcopy(entries)
end

--- what a release would place now : one entry (a single prop or a line), with the line's length.
--- A prefab is laid in a line too (direct request), one every its own length, the gap fixed so a
--- longer line takes more of them (a guardrail stays one rail). What the eyedropper picked up
--- (`template` : the prop's scale, collision, other mesh...) goes with it
---@return table? entry, number meters
local function placingEntry()
    local p = M.placing
    -- the line being dragged holds fewer props than its length asks for : the props are nearly full
    p.capped = false
    -- a group eyedropped : a list of entries
    if p.group then return groupPlacingEntries(p), 0 end
    if p.sweep or p.paint then return sweepPlacingEntry(p) end
    local tpl = p.template or {}
    local scale = tonumber(tpl.scale) or 1
    local prefab = p.prefab and beamjoy_props.prefabEntry(p.prefab)
    if p.prefab and not prefab then return nil, 0 end
    local t = placingTuning(p)
    local yaw = wrapYaw(t.yaw + p.rot)
    -- a mesh's own measured lift, or the prefab's (beamjoy_props.PREFABS `lift`)
    local lift
    if prefab then lift = prefab.lift else lift = entryLift(p.shape, t) end
    local each = prefab and 1 + #prefab.parts or 1
    local d = p.drag
    if d then
        local meters = d.a:distance(d.b)
        if meters >= PLACE_LINE_MIN then
            local room = math.floor((beamjoy_props.MAX_PROPS - beamjoy_props.total(props())) / each)
            local step = t.length * scale * p.spacing
            local fixed = prefab ~= nil or tpl.gap == true
            local line = {
                kind = "line",
                shape = prefab and prefab.shape or p.shape,
                prefab = prefab and prefab.prefab or nil,
                parts = prefab and prefab.parts or nil,
                a = xyz(d.a),
                b = xyz(d.b),
                gap = fixed and math.max(GAP_MIN, round2(step)) or nil,
                yaw = yaw,
                scale = scale,
                stretch = tpl.stretch,
                solid = tpl.solid,
                alt = not prefab and tpl.alt or nil,
                altYaw = not prefab and tpl.altYaw or nil,
                altLift = not prefab and tpl.altLift or nil,
                capA = tpl.capA,
                capAYaw = tpl.capAYaw,
                capALift = tpl.capALift,
                capB = tpl.capB,
                capBYaw = tpl.capBYaw,
                capBLift = tpl.capBLift,
                -- the editor's snap to ground decides (direct report : lines followed the ground
                -- with it off) ; off, a straight line between the two points clicked
                followGround = snapOn(),
                lift = lift,
            }
            local wanted = fixed and beamjoy_props.gapCount(line, line.gap) or math.floor(meters / step + .5) + 1
            wanted = math.min(wanted, PLACE_LINE_MAX_COUNT)
            local least = fixed and 1 or 2
            p.capped = room < least or wanted > room
            if room >= least then
                line.count = math.max(least, math.min(wanted, room))
                updateLineHeights(line)
                return line, meters
            end
        end
    end
    local at, facing = d and d.a or p.hit, d and d.facing or p.facing
    if not at or not facing then return nil, 0 end
    if tpl.line then
        -- the eyedropped line, copied whole : its middle here, turned as the wheel turned it since
        local turnBy = (p.rot - tpl.line.rot) % 360
        -- measured on the ground again only once the mouse or the turn moved (the ghost asks every
        -- frame, each prop of the line probing the ground)
        local last = tpl.line.last
        if last and last.at:distance(at) < .02 and last.turnBy == turnBy and last.snap == snapOn() then
            p.capped = last.capped
            if last.capped then return nil, 0 end
            return deepcopy(last.line), last.meters
        end
        local line = deepcopy(tpl.line.entry)
        ---@param off vec3
        local function placed(off)
            local o = beamjoy_props.turn(off, turnBy)
            local pt = vec3(at.x + o.x, at.y + o.y, at.z + o.z)
            if snapOn() then pt.z = groundHeightAt(pt) end
            return xyz(pt)
        end
        local was = tpl.line.entry
        for _, key in ipairs({ "a", "b", "mid" }) do
            local off = tpl.line.offsets[key]
            line[key] = off and keepWidth(placed(off), was[key]) or nil
        end
        line.nodes = tpl.line.offsets.nodes and table.map(tpl.line.offsets.nodes, function(off, k)
            return keepWidth(placed(off), was.nodes and was.nodes[k])
        end) or nil
        -- its props keep their turn along it (its yaw is the line's own : turning it too turned
        -- them twice, direct report). Its own "Follow the ground" kept, off with snapping off
        if not snapOn() then line.followGround = false end
        local room = math.floor((beamjoy_props.MAX_PROPS - beamjoy_props.total(props())))
        p.capped = beamjoy_props.weight(line) > room
        local meters = 0
        if not p.capped then
            updateLineHeights(line)
            meters = beamjoy_props.lineLength(line)
        end
        tpl.line.last = { at = vec3(at), turnBy = turnBy, snap = snapOn(), capped = p.capped,
            line = line, meters = meters }
        if p.capped then return nil, 0 end
        return deepcopy(line), meters
    end
    local base = M.fixedRotation and NORTH or facing
    if prefab then
        -- a prefab : one at the click, turned by the wheel
        prefab.kind = "static"
        prefab.pos = xyz(at)
        prefab.dir = xyz(beamjoy_props.turn(base, p.rot))
        prefab.up = { x = 0, y = 0, z = 1 }
        prefab.scale = scale
        prefab.stretch = tpl.stretch
        prefab.solid = tpl.solid
        -- laid on the ground's tilt, snapping on, and following it from then on
        prefab.followGround = snapOn() or nil
        if snapOn() then tiltSingle(prefab) end
        return prefab, 0
    end
    local dir = singleDir(base, yaw)
    -- a mesh standing to one side of its origin (the catalog's `xOffset` : the flip ramps), centred
    -- where it's placed as the others are : its origin moved along its own x
    local cat = beamjoy_props.catalogForShape(p.shape)
    if cat and tonumber(cat.xOffset) then
        local stretchX = type(tpl.stretch) == "table" and tonumber(tpl.stretch.x) or 1
        local right = vec3(dir.y, -dir.x, 0)
        at = at + right * (cat.xOffset * scale * stretchX)
        if snapOn() then at.z = groundHeightAt(at) end
    end
    local single = {
        kind = "static",
        shape = p.shape,
        pos = xyz(at),
        dir = xyz(dir),
        up = { x = 0, y = 0, z = 1 },
        scale = scale,
        stretch = tpl.stretch,
        solid = tpl.solid,
        lift = lift,
    }
    single.followGround = snapOn() or nil
    if snapOn() then tiltSingle(single) end
    return single, 0
end

-- an invisible mesh's ghost is drawn as the panel the editor shows for a placed one
-- (drawOverlays, same colour), every frame since it follows the mouse
local GHOST_PANEL_COLOR = { 102, 204, 255, 90 }

---@param entry table the placing entry
local function drawGhostPanels(entry)
    local cat = beamjoy_props.catalogForShape(entry.shape)
    if not cat or not cat.invisible then return end
    local packed = color(GHOST_PANEL_COLOR[1], GHOST_PANEL_COLOR[2], GHOST_PANEL_COLOR[3], GHOST_PANEL_COLOR[4])
    for _, e in ipairs(beamjoy_props.expand({ entry })) do
        local half = e.scale / 2
        local d, u = e.dir * half, e.up * half
        local p1, p2, p3, p4 = e.pos - d - u, e.pos + d - u, e.pos + d + u, e.pos - d + u
        -- both faces, so it shows from either side
        debugDrawer:drawTriSolid(p1, p2, p3, packed)
        debugDrawer:drawTriSolid(p1, p3, p4, packed)
        debugDrawer:drawTriSolid(p3, p2, p1, packed)
        debugDrawer:drawTriSolid(p4, p3, p1, packed)
    end
end

--- the drawer's placing strip : what's armed, and what a release would place
---@param entry table?
---@param meters number?
local function pushPlacing(entry, meters)
    local p = M.placing
    local state = p and {
        armed = true,
        shape = p.shape,
        prefab = p.prefab,
        sweep = p.sweep,
        paint = p.paint,
        -- a group eyedropped is placed where the click went down, not dragged
        dragging = p.drag ~= nil and not p.group,
        -- a group : its entries listed
        count = entry and (entry[1] and beamjoy_props.total(entry) or beamjoy_props.weight(entry)) or 0,
        meters = math.floor((meters or 0) + .5),
        rot = p.rot,
        spacing = round2(p.spacing),
        overWorld = p.hit ~= nil,
        capped = p.drag ~= nil and p.capped == true,
        keepPlacing = M.keepPlacing,
        fixedRotation = M.fixedRotation,
        picked = p.template ~= nil,
        group = p.group and #p.group.entries or nil,
    } or { armed = false }
    local key = p and string.format("%s|%s|%s|%s|%s|%s|%d|%d|%d|%.2f|%s|%s|%s|%s|%s", tostring(state.group),
        tostring(p.shape),
        tostring(p.prefab), tostring(p.sweep), tostring(p.paint),
        tostring(state.dragging), state.count,
        state.meters, state.rot, state.spacing, tostring(state.overWorld), tostring(state.capped),
        tostring(state.keepPlacing), tostring(state.fixedRotation), tostring(state.picked)) or "off"
    if key == lastPlacingPush then return end
    lastPlacingPush = key
    beamjoy_communications_ui.send("BJEditorPropsPlacing", state)
end

---@param dropLineOnly boolean? while dragging, only drop the line being laid (stay armed)
disarmProp = function(dropLineOnly)
    if not M.placing then return end
    if dropLineOnly and M.placing.drag then
        M.placing.drag = nil
        return
    end
    M.placing = nil
    beamjoy_props.hide(GHOST_SET)
    pushPlacing()
end

--- nothing stays selected while placing, the host's own selection neither (the gizmo would take
--- the clicks)
local function unselectForPlacing()
    hostSelects()
    gizmo.hide()
    if M.activePropIndex or #M.propSelection > 0 then
        M.activePropIndex, M.activePropPart, M.propSelection = nil, nil, {}
        pushActive()
        drawOverlays()
    end
end

--- the drawer arms a mesh : nothing stays selected while placing (the gizmo would take the clicks)
---@param shape string
local function onArmProp(shape)
    if not active() then return end
    if not beamjoy_propPicker.isPlaceable(shape) then return end
    if not propBudget(1) then return disarmProp() end
    -- measured now, so the ghost already stands the way it'll be placed
    beamjoy_propPicker.measure(shape)
    local rot = M.placing and M.placing.shape == shape and M.placing.rot or 0
    M.placing = { shape = shape, rot = rot, spacing = 1 }
    unselectForPlacing()
    pushPlacing()
end

--- the drawer's Prefabs tab arms a prefab : placed like a mesh, its whole ghost following the mouse
---@param id string
local function onArmPrefab(id)
    if not active() then return end
    local template = beamjoy_props.prefabEntry(id)
    if not template or not beamjoy_propPicker.isPlaceable(template.shape) then return end
    for _, part in ipairs(template.parts) do
        if not beamjoy_propPicker.isPlaceable(part.shape) then return end
    end
    if not propBudget(beamjoy_props.weight(template)) then return disarmProp() end
    -- measured now, so a line of it is spaced by its own size (beamjoy_props.prefabTuning)
    beamjoy_propPicker.measure(template.shape)
    for _, part in ipairs(template.parts) do beamjoy_propPicker.measure(part.shape) end
    local rot = M.placing and M.placing.prefab == id and M.placing.rot or 0
    M.placing = { shape = template.shape, prefab = id, rot = rot, spacing = 1 }
    unselectForPlacing()
    pushPlacing()
end

--- the drawer's Curbs & walls tab arms a profile (beamjoy_props SWEEPS) : dragged along the ground
--- like a line, or clicked for a short straight one
---@param id string
local function onArmSweep(id)
    if not active() or not beamjoy_props.getSweep(id) then return end
    if not propBudget(1) then return disarmProp() end
    local rot = M.placing and M.placing.sweep == id and M.placing.rot or 0
    M.placing = { sweep = id, rot = rot, spacing = 1 }
    unselectForPlacing()
    pushPlacing()
end

--- the drawer's Paint tab arms a paint (beamjoy_props PAINTS) : dragged along the ground like a
--- curb, or clicked for a short straight one
---@param id string
---@param width number? the eyedropped line's width (metres), else the paint's own
local function onArmPaint(id, width)
    if not active() or not beamjoy_props.getPaint(id) then return end
    if not propBudget(1) then return disarmProp() end
    -- its anchors laid now (beamjoy_props PAINTS), around where it'll most likely go : where you
    -- look, under you, where the mouse last was over the world
    local spots = {}
    pcall(function()
        local camPos, fwd = core_camera.getPosition(), core_camera.getForward()
        local dist = castRayStatic(camPos, fwd, PLACE_RAY_DISTANCE)
        if dist and dist > 0 and dist < PLACE_RAY_DISTANCE then spots[#spots + 1] = camPos + fwd * dist end
        local down = castRayStatic(camPos, vec3(0, 0, -1), PLACE_RAY_DISTANCE)
        if down and down > 0 and down < PLACE_RAY_DISTANCE then spots[#spots + 1] = camPos + vec3(0, 0, -down) end
    end)
    if M.placing and M.placing.hit then spots[#spots + 1] = M.placing.hit end
    beamjoy_props.anchorPaint(id, spots)
    local rot = M.placing and M.placing.paint == id and M.placing.rot or 0
    M.placing = { paint = id, width = tonumber(width), rot = rot, spacing = 1 }
    unselectForPlacing()
    pushPlacing()
end

--- a placed painted line takes another paint, its path kept, at the new paint's own width (a
--- white line made a zebra crossing is wide)
---@param index integer
---@param id string
local function onSetPaint(index, id)
    local prop = props() and props()[index]
    local paint = beamjoy_props.getPaint(id)
    if not prop or prop.kind ~= "paint" or prop.paint == id or not paint then return end
    prop.paint = id
    prop.width = paint.width
    markDirty()
    pushUpdate()
    propsChanged()
end

--- a placed curb or wall takes another profile (a kerb painted blue, a low wall made a tall one),
--- its path kept
---@param index integer
---@param id string
local function onSetSweepProfile(index, id)
    local prop = props() and props()[index]
    if not prop or prop.kind ~= "sweep" or prop.profile == id or not beamjoy_props.getSweep(id) then return end
    prop.profile = id
    updateLineHeights(prop)
    markDirty()
    pushUpdate()
    propsChanged()
end

--- a curb's or a wall's end or node made wider or narrower (direct request) : its `w`, the
--- profile's own width times it (beamjoy_props SWEEPS) ; 1 drops it
---@param index integer
---@param part string "a", "b" or "n<k>"
---@param w number
local function onSetHandleWidth(index, part, w)
    local line = props() and props()[index]
    w = tonumber(w)
    if not line or line.kind ~= "sweep" or not w or w ~= w then return end
    local node = nodeIndex(part)
    local point = node and lineNodes(line)[node] or ((part == "a" or part == "b") and line[part]) or nil
    if type(point) ~= "table" then return end
    w = math.max(beamjoy_props.SWEEP_WIDTH_MIN, math.min(w, beamjoy_props.SWEEP_WIDTH_MAX))
    w = math.abs(w - 1) > 1e-3 and round3(w) or nil
    if point.w == w then return end
    point.w = w
    updateLineHeights(line)
    markDirty()
    pushUpdate()
    propsChanged()
end

--- the eyedropper on a group or a selection of several (direct request) : copies of them all armed,
--- placed together where they stood round their middle, at the mouse, turned by the wheel
---@param members integer[]
local function armGroup(members)
    local entries, sum, n = {}, vec3(0, 0, 0), 0
    for _, i in ipairs(members) do
        local prop = props()[i]
        if prop then
            local copy = deepcopy(prop)
            copy.heights, copy.normals = nil, nil
            entries[#entries + 1] = copy
            for _, p in ipairs(propPoints(prop)) do sum, n = sum + p, n + 1 end
        end
    end
    if n == 0 then return end
    if not propBudget(beamjoy_props.total(entries)) then return disarmProp() end
    for _, e in ipairs(entries) do
        if e.shape then beamjoy_propPicker.measure(e.shape) end
    end
    local first = entries[1]
    M.placing = {
        -- what the drawer shows armed : the first of them
        shape = first.shape,
        rot = 0,
        spacing = 1,
        group = { entries = entries, centre = sum * (1 / n) },
    }
    unselectForPlacing()
    pushPlacing()
end

--- the eyedropper (direct request, in place of Duplicate) : a placed prop's mesh or prefab armed,
--- with what makes it that prop (its scale, collision, a line's other mesh and fixed gap, its turn
--- along a line). A single prop's own heading too while Fixed rotation is on. A prop of a group,
--- or of a selection of several : all of them (armGroup), unless `alone` (Shift+click)
---@param index integer
---@param alone boolean?
local function onEyedropProp(index, alone)
    local prop = props() and props()[index]
    if not prop then return end
    -- Shift on the eyedropper, as the UI's click or the game sees it
    if alone ~= true and not shiftHeld() then
        local members = (#M.propSelection > 1 and table.includes(M.propSelection, index)) and
            table.clone(M.propSelection) or groupOf(index)
        if #members > 1 then return armGroup(members) end
    end
    -- a curb or a wall : its profile armed ; a painted line : its paint, at its width
    if prop.kind == "sweep" then return onArmSweep(prop.profile) end
    if prop.kind == "paint" then return onArmPaint(prop.paint, prop.width) end
    if type(prop.prefab) == "string" and type(prop.parts) == "table" and beamjoy_props.getPrefab(prop.prefab) then
        onArmPrefab(prop.prefab)
    else
        onArmProp(prop.shape)
    end
    local p = M.placing
    if not p then return end
    p.template = {
        scale = prop.scale,
        stretch = prop.stretch and table.clone(prop.stretch) or nil,
        solid = prop.solid,
    }
    local t = placingTuning(p)
    if prop.kind == "line" then
        p.template.alt, p.template.altYaw, p.template.altLift = prop.alt, prop.altYaw, prop.altLift
        p.template.capA, p.template.capAYaw, p.template.capALift = prop.capA, prop.capAYaw, prop.capALift
        p.template.capB, p.template.capBYaw, p.template.capBLift = prop.capB, prop.capBYaw, prop.capBLift
        p.template.gap = prop.gap ~= nil
        p.rot = math.floor((tonumber(prop.yaw) or 0) - t.yaw + .5) % 360
        -- the whole line too (direct request : the eyedropper copies lines) : a click lays a copy
        -- of it, its middle at the mouse, turned by the wheel from where it was
        local a, b = toVec(prop.a), toVec(prop.b)
        if a and b then
            local centre = (a + b) * .5
            local copy = deepcopy(prop)
            copy.group, copy.heights, copy.normals = nil, nil, nil
            p.template.line = {
                entry = copy,
                offsets = { a = a - centre, b = b - centre, mid = toVec(prop.mid) and toVec(prop.mid) - centre or nil,
                    nodes = type(prop.nodes) == "table" and #prop.nodes > 0 and table.map(prop.nodes, function(n)
                        return toVec(n) - centre
                    end) or nil },
                rot = p.rot,
            }
        end
    elseif M.fixedRotation and prop.dir then
        local heading = headingOf(flatDir(toVec(prop.dir)))
        -- placed as singleDir turns it (a prefab : as it is)
        local rot = p.prefab and heading or heading - t.yaw - SINGLE_ACROSS
        p.rot = math.floor(rot + .5) % 360
    end
    pushPlacing()
end

--- what's being placed goes into the props ; armed still with Ctrl held, else the new prop is
--- selected (its gizmo for fine adjustments)
local function placeNow()
    local entry = placingEntry()
    M.placing.drag = nil
    if not entry then return end
    -- a group eyedropped : its entries
    local many = entry[1] ~= nil
    if not propBudget(many and beamjoy_props.total(entry) or beamjoy_props.weight(entry)) then return end
    local io = ui_imgui.GetIO()
    -- the drawer's "Keep placing" (on until turned off), or Ctrl held for this one (direct request :
    -- Shift turns the props while dragging)
    local keepArmed = M.keepPlacing or (io ~= nil and io.KeyCtrl == true)
    if keepArmed then
        if many then addProps(entry, true) else addProp(entry, true) end
        if beamjoy_props.total(props()) >= beamjoy_props.MAX_PROPS then disarmProp() end
    else
        disarmProp()
        if many then addProps(entry) else addProp(entry) end
    end
end

---@return boolean escPressed
local function escPressed()
    local ok, pressed = pcall(function()
        return ui_imgui.IsKeyPressed(ui_imgui.GetKeyIndex(ui_imgui.Key_Escape))
    end)
    return ok and pressed == true
end

---@return number the mouse wheel's turn this frame (0 without one)
local function mouseWheel(io)
    local ok, wheel = pcall(function() return io.MouseWheel end)
    return ok and tonumber(wheel) or 0
end

--- per frame while a prop is armed ; false when none is (the editor's own mouse handling runs)
---@return boolean
updatePlacing = function()
    local p = M.placing
    if not p then return false end
    if not active() then
        disarmProp()
        return false
    end
    if escPressed() then
        disarmProp(true)
        if not M.placing then return true end
    end

    local io = ui_imgui.GetIO()
    local overUI = (getCEFFocusMouse and getCEFFocusMouse() == true) or (io ~= nil and io.WantCaptureMouse == true)
    p.hit = nil
    -- a line being dragged keeps following the mouse, even over the UI
    if not overUI or p.drag then
        local camPos, rayDir = camera.mouseRay()
        if camPos then
            local dist = castRayStatic(camPos, rayDir, PLACE_RAY_DISTANCE)
            if dist and dist > 0 and dist < PLACE_RAY_DISTANCE then
                p.hit = camPos + rayDir * dist
                p.facing = flatDir(rayDir)
            end
        end
    end

    if not overUI then
        local wheel = io and mouseWheel(io) or 0
        if wheel ~= 0 then
            -- Shift + wheel turns them while a line is dragged too (direct request), Ctrl + wheel
            -- turns them a degree at a time
            local shift = io ~= nil and io.KeyShift == true
            local fine = ctrlHeld()
            if p.drag and not p.group and not shift and not fine then
                -- wheel up : more props on the line (closer together), down : fewer (direct request)
                p.spacing = math.max(PLACE_SPACING_MIN, math.min(p.spacing * (wheel > 0 and 1 / 1.1 or 1.1),
                    PLACE_SPACING_MAX))
            else
                p.rot = (p.rot + (wheel > 0 and 1 or -1) * (fine and PLACE_ROTATE_FINE or PLACE_ROTATE_STEP)) % 360
            end
        end
    end

    if p.drag then
        if p.hit then p.drag.b = p.hit end
        if ui_imgui.IsMouseReleased(ui_imgui.MouseButton_Left) then
            placeNow()
            if not M.placing then return true end
        end
    elseif p.hit and not overUI and ui_imgui.IsMouseClicked(ui_imgui.MouseButton_Left) and
        not (gizmo.isHovered and gizmo.isHovered()) then
        p.drag = { a = p.hit, b = p.hit, facing = p.facing }
    end

    local entry, meters
    if p.hit or p.drag then entry, meters = placingEntry() end
    if entry then
        local list = entry[1] and entry or { entry }
        beamjoy_props.show(GHOST_SET, list, { collision = false, collisionType = "None" })
        for _, e in ipairs(list) do drawGhostPanels(e) end
    else
        beamjoy_props.hide(GHOST_SET)
    end
    pushPlacing(entry, meters)
    return true
end

-- DELETE KEY -----------------------------------------------------------------------------------
-- the selected prop goes with the Delete key (direct request). A game key binding ("Editor : delete
-- selected", core/input/actions/beamjoy.json, forwarded by activityEditor), so like every other
-- binding it doesn't fire while a text box has the keyboard (a race's name...), and it can be
-- rebound in the game's controls

local function onBJEditorDeleteKey()
    if not active() or not M.activePropIndex then return end
    -- a line's node held : that node goes (as the game's spline editor does), not the line
    local node = #M.propSelection <= 1 and nodeIndex(M.activePropPart)
    if node and isPath(props()[M.activePropIndex]) then return removeNode(M.activePropIndex, node) end
    onDeleteSelectedProps()
end

-- CLIPBOARD ------------------------------------------------------------------------------------
-- Props copied from one race or arena and pasted into another (direct request) : the selection, or
-- every prop when nothing is selected. Kept in a file, so it outlives the session ; pasted on
-- the map they were copied on only, where they stand.

local CLIPBOARD_FILE = "/temp/bjPropClipboard.json"
-- a Paste arriving again this soon after the last is the same press (direct report : 357 props
-- copied, 714 pasted into a race that had none, the second half selected) : dropped, and logged
local PASTE_REPEAT_MS = 400
---@type {map: string?, props: table[]}?
local clipboard = nil
local clipboardRead = false
local lastPaste = -math.huge

---@return string? the map being played, lower case
local function currentMap()
    local ok, level = pcall(function() return getCurrentLevelIdentifier and getCurrentLevelIdentifier() end)
    return ok and type(level) == "string" and level ~= "" and level:lower() or nil
end

local function readClipboard()
    if clipboardRead then return end
    clipboardRead = true
    local ok, data = pcall(jsonReadFile, CLIPBOARD_FILE)
    if ok and type(data) == "table" and type(data.props) == "table" and table.isArray(data.props) then
        clipboard = { map = data.map, props = data.props }
    end
end

--- what the clipboard holds, for the Paste button
pushClipboard = function()
    readClipboard()
    local held = clipboard and clipboard.props or {}
    beamjoy_communications_ui.send("BJEditorPropsClipboard", {
        entries = #held,
        count = beamjoy_props.total(held),
        sameMap = clipboard ~= nil and clipboard.map == currentMap(),
    })
end

local function onCopyProps()
    if not props() then return end
    local copied = {}
    if #M.propSelection > 0 then
        for _, i in ipairs(M.propSelection) do
            if props()[i] then copied[#copied + 1] = deepcopy(props()[i]) end
        end
    else
        for _, prop in ipairs(props()) do copied[#copied + 1] = deepcopy(prop) end
    end
    if #copied == 0 then return end
    clipboardRead = true
    clipboard = { map = currentMap(), props = copied }
    pcall(jsonWriteFile, CLIPBOARD_FILE, clipboard, false)
    toast.success(string.format("%d props copied", beamjoy_props.total(copied)), nil, 3)
    pushClipboard()
end

--- the clipboard's props added where they were, selected ; their groups kept apart from the props'
--- own
local function onPasteProps()
    readClipboard()
    if not props() or not clipboard or #clipboard.props == 0 then return end
    if clipboard.map ~= currentMap() then
        toast.warn("Those props were copied on another map", nil, 4)
        return
    end
    local now = GetCurrentTimeMillis()
    if now - lastPaste < PASTE_REPEAT_MS then
        log("W", "beamjoy_propEditor", string.format("a second Paste %d ms after the first dropped",
            now - lastPaste))
        return
    end
    if not propBudget(beamjoy_props.total(clipboard.props)) then return end
    lastPaste = now
    log("I", "beamjoy_propEditor", string.format("pasting %d entries into %d", #clipboard.props, #props()))
    disarmProp()
    addProps(clipboard.props)
end

--- a placed prop takes another mesh (the drawer's "Swap mesh"), kept where it is and turned by the
--- difference between the two meshes' own facings
---@param index integer
---@param shape string
local function onSwapPropShape(index, shape)
    local prop = props() and props()[index]
    if not prop or isSwept(prop) or prop.shape == shape or not beamjoy_propPicker.isPlaceable(shape) then
        return
    end
    beamjoy_propPicker.measure(prop.shape)
    beamjoy_propPicker.measure(shape)
    local before, after = beamjoy_props.tuning(prop.shape), beamjoy_props.tuning(shape)
    local delta = after.yaw - before.yaw
    prop.shape = shape
    if prop.kind == "line" then
        prop.yaw = wrapYaw((tonumber(prop.yaw) or 0) + delta)
        -- the other mesh keeps its own facing : the line's turn taken back off it
        if prop.alt == shape then
            prop.alt, prop.altYaw, prop.altLift = nil, nil, nil
        elseif prop.alt then
            prop.altYaw = wrapYaw((tonumber(prop.altYaw) or 0) - delta)
        end
    elseif prop.dir then
        prop.dir = xyz(beamjoy_props.turn(toVec(prop.dir), delta))
    end
    prop.lift = entryLift(shape, after)
    updatePropGizmo()
    markDirty()
    pushUpdate()
    propsChanged()
end

--- a line's every other prop is another mesh (direct request : red and white barriers in turn), or
--- (no shape) all the line's own again. Turned and lifted as that mesh is laid down, measured now
--- so every player stands it the same
---@param index integer
---@param shape string?
local function onSetPropAlt(index, shape)
    local prop = props() and props()[index]
    if not prop or prop.kind ~= "line" then return end
    if type(shape) ~= "string" or shape == "" or shape == prop.shape then
        prop.alt, prop.altYaw, prop.altLift = nil, nil, nil
    else
        if not beamjoy_propPicker.isPlaceable(shape) then return end
        beamjoy_propPicker.measure(prop.shape)
        beamjoy_propPicker.measure(shape)
        local own, other = beamjoy_props.tuning(prop.shape), beamjoy_props.tuning(shape)
        prop.alt = shape
        local yaw = wrapYaw(other.yaw - own.yaw)
        prop.altYaw = yaw ~= 0 and yaw or nil
        prop.altLift = entryLift(shape, other)
    end
    markDirty()
    pushUpdate()
    propsChanged()
end

--- a line's end cap (direct request) : a mesh at its first ("a") or last ("b") end, facing out of
--- the line, laid down as that mesh is (its tuning yaw, its lift) ; none (no shape) takes it away
---@param index integer
---@param which "a"|"b"
---@param shape string?
local function onSetPropCap(index, which, shape)
    local prop = props() and props()[index]
    if not prop or prop.kind ~= "line" or (which ~= "a" and which ~= "b") then return end
    local k = which == "a" and "A" or "B"
    if type(shape) ~= "string" or shape == "" then
        prop["cap" .. k], prop["cap" .. k .. "Yaw"], prop["cap" .. k .. "Lift"] = nil, nil, nil
    else
        if not beamjoy_propPicker.isPlaceable(shape) then return end
        if not prop["cap" .. k] and not propBudget(1) then return end
        beamjoy_propPicker.measure(shape)
        local t = beamjoy_props.tuning(shape)
        prop["cap" .. k] = shape
        local yaw = wrapYaw(t.yaw)
        prop["cap" .. k .. "Yaw"] = yaw ~= 0 and yaw or nil
        prop["cap" .. k .. "Lift"] = entryLift(shape, t)
    end
    markDirty()
    pushUpdate()
    propsChanged()
end

--- a line's end cap turned a quarter round, still butting against the line's end (direct report :
--- turned half round, a cap the same front and back looked untouched, as if the button did nothing)
---@param index integer
---@param which "a"|"b"
local function onFlipPropCap(index, which)
    local prop = props() and props()[index]
    local k = which == "a" and "A" or which == "b" and "B" or nil
    if not prop or prop.kind ~= "line" or not k or not prop["cap" .. k] then return end
    local yaw = wrapYaw((tonumber(prop["cap" .. k .. "Yaw"]) or 0) + 90)
    prop["cap" .. k .. "Yaw"] = yaw ~= 0 and yaw or nil
    markDirty()
    pushUpdate()
    propsChanged()
end


-- WORLD CLICKS ---------------------------------------------------------------------------------
-- The host's world click (beamjoy_inputs onBJClick, forwarded by activityEditor) picks among its
-- own markers and the props : `pick` says which prop's handle the mouse ray meets and how far along
-- it, so the host keeps whichever is nearest

---@param pos {x: number, y: number, z: number}
---@param radius number
---@param camPos vec3
---@param rayDir vec3
---@return number? t distance along the ray to the closest approach, only if within radius, number?
---off how far off the ray it passes for its distance (how near the mouse it looks on screen)
local function rayHitsHandle(pos, radius, camPos, rayDir)
    -- the handles are drawn half a metre above the ground (drawOverlays)
    local p = vec3(pos.x, pos.y, pos.z) + vec3(0, 0, .5)
    local t = (p - camPos):dot(rayDir)
    if t <= 0 then return nil end
    local off = (camPos + rayDir * t):distance(p)
    if off <= radius then return t, off / t end
    return nil
end

-- a mesh's box is grown this much (metres) for a click : a thin one (a pole, a sign) still takes it
local PICK_BOX_PAD = .1
-- a line's handle wins over a mesh the mouse is also on when the mouse is on the sphere drawn
-- (within this of its middle, metres ; drawOverlays) and the mesh isn't PICK_HANDLE_MARGIN nearer :
-- the end prop's own mesh stands round its handle. Further off, the mesh wins
local PICK_HANDLE_ON = .7
local PICK_HANDLE_MARGIN = 2
-- how near the mouse ray a curb, a wall or a painted line's path takes a click (metres)
local PICK_PATH_RADIUS = .8

--- where the mouse ray enters a placed mesh's box (beamjoy_props.expand's entry, the mesh measured)
---@param e table
---@param camPos vec3
---@param rayDir vec3
---@return number? t
local function rayHitsMesh(e, camPos, rayDir)
    local m = type(e.shape) == "string" and beamjoy_props.meta[e.shape:lower()] or nil
    if not m or m.minX == nil or m.minZ == nil or not m.z then return nil end
    -- its axes as quatFromDir sets them : y its dir, x dir x up, z x x dir
    local y = e.dir:normalized()
    local x = y:cross(e.up)
    if x:length() < 1e-6 then return nil end
    x = x:normalized()
    local z = x:cross(y):normalized()
    local s = e.scales or vec3(e.scale, e.scale, e.scale)
    local o = camPos - e.pos
    local tmin, tmax = 0, math.huge
    for _, slab in ipairs({ { x, m.minX * s.x, m.maxX * s.x }, { y, m.minY * s.y, m.maxY * s.y },
        { z, m.minZ * s.z, (m.minZ + m.z) * s.z } }) do
        local axis = slab[1]
        local lo = math.min(slab[2], slab[3]) - PICK_BOX_PAD
        local hi = math.max(slab[2], slab[3]) + PICK_BOX_PAD
        local oo, dd = o:dot(axis), rayDir:dot(axis)
        if math.abs(dd) < 1e-8 then
            if oo < lo or oo > hi then return nil end
        else
            local t1, t2 = (lo - oo) / dd, (hi - oo) / dd
            if t1 > t2 then t1, t2 = t2, t1 end
            tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
            if tmin > tmax then return nil end
        end
    end
    return tmin
end

--- where the mouse ray passes within PICK_PATH_RADIUS of a curb's, a wall's or a painted line's
--- path (it has no meshes of its own to hit)
---@param p table
---@param camPos vec3
---@param rayDir vec3
---@return number? t
local function rayHitsPath(p, camPos, rayDir)
    local path = beamjoy_props.linePath(p, 16)
    if not path then return nil end
    local best
    for k = 2, #path do
        local a, b = path[k - 1] + vec3(0, 0, .2), path[k] + vec3(0, 0, .2)
        local seg = b - a
        local len2 = seg:dot(seg)
        if len2 > 1e-8 then
            -- the closest points of the ray and the segment
            local w = camPos - a
            local bb, c = rayDir:dot(seg), seg:dot(seg)
            local d, e = rayDir:dot(w), seg:dot(w)
            local denom = c - bb * bb
            local u = denom > 1e-8 and math.max(0, math.min(1, (e - bb * d) / denom)) or 0
            local q = a + seg * u
            local t = (q - camPos):dot(rayDir)
            if t > 0 and (camPos + rayDir * t):distance(q) <= PICK_PATH_RADIUS and (not best or t < best) then
                best = t
            end
        end
    end
    return best
end

-- how near the mouse ray the selected line's path takes a click adding a node (metres)
local PICK_INSERT_RADIUS = .6

--- where the mouse ray passes nearest a line's path, drawn `lift` above it (drawOverlays), within
--- `radius` of it
---@param p table
---@param camPos vec3
---@param rayDir vec3
---@param lift number
---@param radius number
---@return number? t, vec3? at the point on the path (not lifted), integer? span the span it's in
---(between the line's point `span` and the next : beamjoy_props.linePath's knotAt)
local function rayNearPath(p, camPos, rayDir, lift, radius)
    local path, knotAt = beamjoy_props.linePath(p, 64)
    if not path then return nil end
    local up = vec3(0, 0, lift)
    local bestT, bestAt, bestK, bestOff
    for k = 2, #path do
        local a = path[k - 1] + up
        local seg = path[k] - path[k - 1]
        local c = seg:dot(seg)
        if c > 1e-8 then
            -- the closest points of the ray and the segment
            local w = camPos - a
            local bb, d, e = rayDir:dot(seg), rayDir:dot(w), seg:dot(w)
            local denom = c - bb * bb
            local u = denom > 1e-8 and math.max(0, math.min(1, (e - bb * d) / denom)) or 0
            local q = a + seg * u
            local t = (q - camPos):dot(rayDir)
            local off = t > 0 and (camPos + rayDir * t):distance(q) or math.huge
            if off <= radius and (not bestOff or off < bestOff) then
                bestT, bestAt, bestK, bestOff = t, q - up, k - 1, off
            end
        end
    end
    if not bestT then return nil end
    local span = 1
    for i = 1, #knotAt - 1 do
        if knotAt[i] <= bestK then span = i end
    end
    return bestT, bestAt, span
end

--- the line alone in the selection, nil otherwise
---@return table?, integer?
local function selectedLine()
    if not M.activePropIndex or #M.propSelection > 1 then return nil end
    local line = props() and props()[M.activePropIndex]
    if not isPath(line) then return nil end
    return line, M.activePropIndex
end

--- what a click would do to the selected line (LINE NODES) : with Alt held, an end added where the
--- ground is under the mouse ; else, the mouse on its path (not on one of its handles), a node added
--- there
---@param camPos vec3
---@param rayDir vec3
---@return {kind: "insert"|"extend", index: integer, t: number, pos: vec3, span: integer?, first: boolean?, from: vec3?}?
local function lineAction(camPos, rayDir)
    if M.placing then return nil end
    local line, index = selectedLine()
    if not line then return nil end
    if altHeld() then
        local dist = castRayStatic(camPos, rayDir, PLACE_RAY_DISTANCE)
        if not dist or dist <= 0 or dist >= PLACE_RAY_DISTANCE then return nil end
        local hit = camPos + rayDir * dist
        local a, b = toVec(line.a), toVec(line.b)
        local first = hit:distance(a) < hit:distance(b)
        return { kind = "extend", index = index, t = 0, pos = hit, first = first, from = first and a or b }
    end
    -- its handles are for selecting them
    for _, k in ipairs(lineKnots(line)) do
        local t, off = rayHitsHandle(k, PICK_HANDLE_ON, camPos, rayDir)
        if t and off * t <= PICK_HANDLE_ON then return nil end
    end
    local t, at, span = rayNearPath(line, camPos, rayDir, .5, PICK_INSERT_RADIUS)
    if not t then return nil end
    for _, k in ipairs(lineKnots(line)) do
        if toVec(k):distance(at) < NODE_MIN_SPACING then return nil end
    end
    return { kind = "insert", index = index, t = t, pos = at, span = span }
end

-- a line's handle clicked follows the mouse while the button stays down (direct request), as the
-- game's spline editor does : a node or an end just added, or one already there (its ends too,
-- direct request). Over the ground with snapping on, else level at its own height ; the gizmo comes
-- back on it once let go, and a plain click leaves it where it was
---@type {index: integer, part: string, moved: boolean}?
local handleDrag = nil

--- a line's handle (its end "a" / "b", its node "n<k>") as it stands
---@param line table
---@param part string
---@return table? point
local function handlePoint(line, part)
    local node = nodeIndex(part)
    if node then return lineNodes(line)[node] end
    if part == "a" or part == "b" then return line[part] end
    return nil
end

--- the button went down on a line's handle : it follows the mouse until let go
---@param index integer
---@param part string?
local function startHandleDrag(index, part)
    local line = props() and props()[index]
    if not part or not isPath(line) or not handlePoint(line, part) then return end
    handleDrag = { index = index, part = part, moved = false }
    gizmo.hide()
end

--- per frame while a line's handle is held ; false when none is
---@return boolean
local function updateHandleDrag()
    local d = handleDrag
    if not d then return false end
    local line = active() and props() and props()[d.index]
    local held = isPath(line) and handlePoint(line, d.part)
    if not held then
        handleDrag = nil
        return false
    end
    if not ui_imgui.IsMouseDown(ui_imgui.MouseButton_Left) then
        handleDrag = nil
        if d.moved then
            if snapOn() then held.z = groundHeightAt(toVec(held)) end
            lineEdited(line)
            pushUpdate()
            propsChanged()
        end
        updatePropGizmo()
        return true
    end
    if not d.moved and not ui_imgui.IsMouseDragging(ui_imgui.MouseButton_Left) then return true end
    local camPos, rayDir = camera.mouseRay()
    if not camPos then return true end
    local at
    if snapOn() then
        local dist = castRayStatic(camPos, rayDir, PLACE_RAY_DISTANCE)
        if dist and dist > 0 and dist < PLACE_RAY_DISTANCE then at = camPos + rayDir * dist end
    elseif math.abs(rayDir.z) > 1e-4 then
        local t = (held.z - camPos.z) / rayDir.z
        if t > 0 and t < PLACE_RAY_DISTANCE then at = camPos + rayDir * t end
    end
    if not at then return true end
    d.moved = true
    held.x, held.y, held.z = at.x, at.y, at.z
    line.heights, line.normals = nil, nil -- measured again once let go
    fitLineCount(line)
    markDirty()
    propsChanged()
    return true
end

-- what a click would do to the selected line, shown where the mouse is (drawn over the overlays)
local HOVER_LAYER = "propEditorHover"
local HOVER_COLOR
local hoverShown = false

--- per frame : lineAction's mark under the mouse (a node to add on the path, the new end and its
--- link from the line's nearer end)
local function updateHover()
    local action
    if active() then
        local io = ui_imgui.GetIO()
        local overUI = (getCEFFocusMouse and getCEFFocusMouse() == true) or (io ~= nil and io.WantCaptureMouse == true)
        local busy = ui_imgui.IsMouseDown(ui_imgui.MouseButton_Left) or (gizmo.isHovered and gizmo.isHovered())
        if not overUI and not busy then
            local camPos, rayDir = camera.mouseRay()
            if camPos then action = lineAction(camPos, rayDir) end
        end
    end
    if not action and not hoverShown then return end
    local draw = shape.layer(HOVER_LAYER)
    draw.reset()
    hoverShown = action ~= nil
    if not action then return end
    HOVER_COLOR = HOVER_COLOR or BJColor(1, 1, 1, .85)
    local lift = vec3(0, 0, .5)
    if action.kind == "insert" then
        draw.addSphere(action.pos + lift, .3, HOVER_COLOR)
    else
        draw.addLine(action.from + lift, .08, action.pos + lift, .08, HOVER_COLOR)
        draw.addSphere(action.pos + lift, .45, HOVER_COLOR)
    end
end

--- the prop under the mouse ray (direct report : with props close together, the click took the
--- wrong one, the nearest handle sphere along the ray rather than what the mouse was on) : a line's
--- end or node handle the mouse is on ; else the nearest mesh the ray goes into (a single prop, a
--- prefab's part, a line's prop or end cap) or curb, wall or painted line it passes over ; else the
--- handle at a single prop's base nearest the mouse (a mesh not measured, an invisible one). The
--- selected line's own clicks first (LINE NODES) : Alt+click adds an end, a click on its path a
--- node (M.clickSelect does it, `M.pickAction` saying where)
---@param camPos vec3
---@param rayDir vec3
---@return number? t, integer? index, string? part a line's handle, or "insert" / "extend"
function M.pick(camPos, rayDir)
    M.pickAction = nil
    -- the click is on a line's handle itself (not its props, which also give the handle held)
    M.pickHandle = false
    local list = active() and props() or nil
    if not list then return nil end
    local action = lineAction(camPos, rayDir)
    if action and action.kind == "extend" then
        M.pickAction = action
        return action.t, action.index, "extend"
    end
    -- the handles : the one nearest the mouse on screen
    local handleT, handleOff, handleIndex, handlePart
    local baseT, baseOff, baseIndex
    for i, p in ipairs(list) do
        if isPath(p) then
            local function try(pos, part)
                local t, off = rayHitsHandle(pos, 1.2, camPos, rayDir)
                if t and (not handleOff or off < handleOff) then
                    handleT, handleOff, handleIndex, handlePart = t, off, i, part
                end
            end
            if p.a then try(p.a, "a") end
            if p.b then try(p.b, "b") end
            -- its nodes
            for k, n in ipairs(lineNodes(p)) do try(n, "n" .. k) end
        elseif p.pos then
            local t, off = rayHitsHandle(p.pos, 1.5, camPos, rayDir)
            if t and (not baseOff or off < baseOff) then
                baseT, baseOff, baseIndex = t, off, i
            end
        end
    end
    -- the meshes and paths : the nearest one the ray meets
    local meshT, meshIndex
    for _, e in ipairs(beamjoy_props.expand(list)) do
        local t = rayHitsMesh(e, camPos, rayDir)
        if t and (not meshT or t < meshT) then meshT, meshIndex = t, e.entry end
    end
    for i, p in ipairs(list) do
        if isSwept(p) then
            local t = rayHitsPath(p, camPos, rayDir)
            if t and (not meshT or t < meshT) then meshT, meshIndex = t, i end
        end
    end
    local handleOn = handleT and handleOff * handleT <= PICK_HANDLE_ON
    if handleT and (handleOn or not action) and
        (not meshT or (handleOn and meshT >= handleT - PICK_HANDLE_MARGIN)) then
        M.pickHandle = handlePart ~= nil
        return handleT, handleIndex, handlePart
    end
    -- the selected line's path : a node added there, its own props round it
    if action and (not meshT or action.t <= meshT + PICK_HANDLE_MARGIN) then
        M.pickAction = action
        return action.t, action.index, "insert"
    end
    if meshT then
        -- a line hit on its props : the handle it's held by stays the one held
        return meshT, meshIndex, meshIndex == M.activePropIndex and M.activePropPart or nil
    end
    return baseT, baseIndex, nil
end

--- a prop clicked in the world : Ctrl+click adds it to the selection (or takes it out), Shift+click
--- picks one of a group alone (direct request : multiple selection and groups). A click on the
--- handle already held does nothing : it's meant for the gizmo drawn on it
---@param index integer
---@param part string? a line's handle, or "insert" / "extend" (M.pick)
function M.clickSelect(index, part)
    local mode = selectMode()
    local action = M.pickAction
    local onHandle = M.pickHandle == true
    M.pickAction, M.pickHandle = nil, false
    if part == "insert" or part == "extend" then
        if not mode and action and action.index == index then
            if action.kind == "insert" then
                local node = insertNode(index, action.span, action.pos)
                if node then startHandleDrag(index, "n" .. node) end
                return
            end
            local key = extendLine(index, action.pos, action.first)
            if key then startHandleDrag(index, key) end
            return
        end
        part = nil
    end
    if not mode and index == M.activePropIndex and part == M.activePropPart then
        if onHandle then startHandleDrag(index, part) end
        return
    end
    M.onSelectProp(index, part, mode)
    -- a line's end or node, alone selected : held, it's dragged
    if onHandle and not mode and index == M.activePropIndex and part and part == M.activePropPart and
        #M.propSelection <= 1 then
        startHandleDrag(index, part)
    end
end

--- a world click while a prop is armed is the placing's own (it reads the mouse every frame), a
--- right-click stops placing : the host leaves those alone
---@param clickType "left"|"middle"|"right"
---@return boolean taken
function M.onBJClick(clickType)
    if not M.placing or not active() then return false end
    if clickType == "right" then disarmProp(true) end
    return true
end

-- the host's snapping to the ground as last seen (followSnap), nil until seen since it attached
local lastSnap = nil

--- the host's snapping switched : what's selected follows the ground with it, as its own "Follow
--- the ground" would (direct request : snapping off turns it off, on turns it on again), lines too
local function followSnap()
    local on = snapOn()
    if lastSnap == nil or on == lastSnap then
        lastSnap = on
        return
    end
    lastSnap = on
    local list = props()
    if not list then return end
    local selected = #M.propSelection > 0 and M.propSelection or { M.activePropIndex }
    for _, i in ipairs(selected) do
        if list[i] then onSetProp(i, { followGround = on }) end
    end
end

--- per frame, from the host's onUpdate : true while a prop is armed (the mouse is the placing's,
--- the host's own handles wait)
---@return boolean
function M.onUpdate()
    followSnap()
    if updateHandleDrag() then return true end
    local placing = updatePlacing()
    updateHover()
    return placing
end

--- the Delete key (forwarded by activityEditor through the host)
function M.onDeleteKey()
    onBJEditorDeleteKey()
end

-- HOST -----------------------------------------------------------------------------------------

--- the selection goes, without touching the gizmo (the host shows its own next) ; nothing armed
function M.clearSelection()
    disarmProp()
    if M.activePropIndex or #M.propSelection > 0 then
        M.activePropIndex, M.activePropPart, M.propSelection = nil, nil, {}
        pushActive()
        drawOverlays()
    end
end

--- everything the UI shows, as it is (a props panel shown again)
local function pushState()
    pushUpdate()
    pushActive()
    pushClipboard()
    lastPlacingPush = nil
    pushPlacing()
    beamjoy_communications_ui.send("BJEditorPropCatalog", beamjoy_props.catalogForUI())
    beamjoy_communications_ui.send("BJEditorPropsTestCollision", M.testCollision)
end

--- the host's props were replaced (another race or arena opened, a code imported, saved again) :
--- nothing selected (or, `keepSelection`, what's selected while it's still there), collision off
---@param keepSelection boolean?
function M.reset(keepSelection)
    disarmProp()
    handleDrag = nil
    local list = props() or {}
    local kept = keepSelection and M.activePropIndex and list[M.activePropIndex] ~= nil
    if kept then
        local selection = {}
        for _, i in ipairs(M.propSelection) do
            if list[i] ~= nil then selection[#selection + 1] = i end
        end
        M.propSelection = selection
    else
        M.activePropIndex, M.activePropPart, M.propSelection = nil, nil, {}
    end
    M.testCollision = false
    if kept then updatePropGizmo() end
    propsChanged()
    pushState()
end

--- an editor with props opens : it's the host until it closes
---@param host BJPropEditorHost
function M.attach(host)
    if M.host and M.host ~= host then M.detach(M.host) end
    M.host = host
    lastSnap = nil
    blockNodeGrabber(true)
    M.reset()
end

--- the host closes : its props' preview and handles go with it
---@param host BJPropEditorHost
function M.detach(host)
    if not M.host or M.host ~= host then return end
    disarmProp()
    handleDrag = nil
    M.host = nil
    lastSnap = nil
    shape.layer(HOVER_LAYER).reset()
    hoverShown = false
    blockNodeGrabber(false)
    M.activePropIndex, M.activePropPart, M.propSelection = nil, nil, {}
    M.testCollision = false
    propsChanged()
end

--- the props being edited (the preview's, beamjoy_props), nil while no editor with props is open
---@return table[]?
function M.editing()
    return active() and props() or nil
end

local function onInit()
    local ui = beamjoy_communications_ui
    ui.addHandler("BJEditorPropsRequestState", function()
        if active() then pushState() end
    end)
    ui.addHandler("BJEditorPropsSelect", function(index, part, mode)
        -- a row's click : the keys as the game sees them too, should the UI's click not carry them
        if mode ~= "add" and mode ~= "alone" and mode ~= "addAlone" and (part == nil or part == "") then
            mode = index and selectMode() or nil
        end
        -- a plain click on the selected row unselects. Decided here, with the keys known (direct
        -- report : the UI's click didn't carry Ctrl, so Ctrl+click on the selected row cleared the
        -- whole selection instead of taking that row out)
        if index and not mode and (part == nil or part == "") and index == M.activePropIndex then
            index = nil
        end
        M.onSelectProp(index, part, mode)
    end)
    ui.addHandler("BJEditorPropsSet", onSetProp)
    ui.addHandler("BJEditorPropsDelete", onDeleteProp)
    ui.addHandler("BJEditorPropsDeleteSelected", onDeleteSelectedProps)
    ui.addHandler("BJEditorPropsGroup", onGroupProps)
    ui.addHandler("BJEditorPropsUngroup", onUngroupProps)
    ui.addHandler("BJEditorPropsSetSolid", onSetPropSolid)
    ui.addHandler("BJEditorPropsSetTestCollision", onSetTestCollision)
    ui.addHandler("BJEditorPropsSplitPrefab", onSplitPrefab)
    ui.addHandler("BJEditorPropsEyedrop", onEyedropProp)
    ui.addHandler("BJEditorPropsCopy", onCopyProps)
    ui.addHandler("BJEditorPropsPaste", onPasteProps)
    ui.addHandler("BJEditorPropsClipboardRequest", pushClipboard)
    ui.addHandler("BJEditorPropsDuplicate", onDuplicateProp)
    ui.addHandler("BJEditorPropsSplitLine", onSplitPropLine)
    ui.addHandler("BJEditorPropsStraightenLine", onStraightenPropLine)
    ui.addHandler("BJEditorPropsAddNode", onAddPropNode)
    ui.addHandler("BJEditorPropsRemoveNode", onRemovePropNode)
    ui.addHandler("BJEditorPropsTeleportTo", onTeleportToProp)
    ui.addHandler("BJEditorPropsSetToVehicle", onSetPropToVehicle)
    ui.addHandler("BJEditorPropsArm", onArmProp)
    ui.addHandler("BJEditorPropsArmPrefab", onArmPrefab)
    ui.addHandler("BJEditorPropsArmSweep", onArmSweep)
    ui.addHandler("BJEditorPropsSetProfile", onSetSweepProfile)
    ui.addHandler("BJEditorPropsSetHandleWidth", onSetHandleWidth)
    ui.addHandler("BJEditorPropsArmPaint", onArmPaint)
    ui.addHandler("BJEditorPropsSetPaint", onSetPaint)
    ui.addHandler("BJEditorPropsDisarm", function() disarmProp() end)
    ui.addHandler("BJEditorPropsSwapShape", onSwapPropShape)
    ui.addHandler("BJEditorPropsSetAlt", onSetPropAlt)
    ui.addHandler("BJEditorPropsSetCap", onSetPropCap)
    ui.addHandler("BJEditorPropsFlipCap", onFlipPropCap)
    ui.addHandler("BJEditorPropsSetKeepPlacing", function(state)
        M.keepPlacing = state == true
        if M.placing then pushPlacing() end
    end)
    ui.addHandler("BJEditorPropsSetFixedRotation", function(state)
        M.fixedRotation = state == true
        if M.placing then pushPlacing() end
    end)
end

M.onInit = onInit

return M
