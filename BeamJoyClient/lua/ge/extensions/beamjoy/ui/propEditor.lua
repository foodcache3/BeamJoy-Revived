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
    ---@type "a"|"b"|"mid"|nil which handle of the selected line the gizmo holds (an end, or its
    ---middle : dragging that bends the line)
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
    if not list then return end
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
        if p.kind == "line" and p.a and p.b then
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
            -- the middle (bend) handle : on the selected line, and on any bent one
            if isActive or p.mid then
                local mid = p.mid and vec3(p.mid.x, p.mid.y, p.mid.z) or (a + b) * .5
                local held = isActive and M.activePropPart == "mid"
                draw.addSphere(mid + lift, held and .6 or .35, held and ACTIVE_COLOR or LINE_COLOR)
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

--- a line's ground heights and tilts, one per prop (beamjoy_props.linePlacements), measured here
--- so a running game never has to : the editor's preview isn't in the static collision (see
--- beamjoy_props), so the probes can't land on the line's own props
---@param line table
local function updateLineHeights(line)
    if line.followGround == false then
        line.heights, line.normals = nil, nil
        return
    end
    -- where its props stand : on a curve that depends on their meshes' length
    local straight = beamjoy_props.linePlacements({ a = line.a, b = line.b, mid = line.mid, count = line.count,
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

--- selects a prop (direct request : multiple selection and groups). A prop of a group brings its
--- group ; "add" (Ctrl+click) adds it to what's selected, or takes it away when it was in ;
--- "alone" (Shift+click) selects it without its group, to edit one of a group
---@param index integer?
---@param part "a"|"b"|"mid"|nil a line's handle (its first end by default)
---@param mode "add"|"alone"|nil
function M.onSelectProp(index, part, mode)
    if not props() then return end
    local prop = index and props()[index]
    -- nothing to drop : the host's own selection (and its gizmo) stays
    if not prop and not M.activePropIndex then return end
    if index then disarmProp() end
    if not prop then
        M.activePropIndex, M.propSelection = nil, {}
    elseif mode == "add" and M.activePropIndex then
        local members = groupOf(index)
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
        M.propSelection = mode == "alone" and { index } or groupOf(index)
        M.activePropIndex = index
    end
    local chosen = M.activePropIndex and props()[M.activePropIndex]
    -- a line's handles while it's alone in the selection, the whole selection's gizmo otherwise
    M.activePropPart = chosen and chosen.kind == "line" and #M.propSelection <= 1 and
        ((part == "b" or part == "mid") and part or "a") or nil
    if chosen then hostSelects() end
    updatePropGizmo()
    pushActive()
    propsChanged()
end

--- every point of a line moved by the same offset (its ends, and its middle when it's bent)
---@param line table
---@param delta vec3
local function shiftLine(line, delta)
    for _, key in ipairs({ "a", "b", "mid" }) do
        local p = toVec(line[key])
        if p then line[key] = xyz(p + delta) end
    end
end

--- after a whole line was moved : every point of it back on the ground
---@param line table
local function snapLine(line)
    for _, key in ipairs({ "a", "b", "mid" }) do
        if line[key] then line[key].z = groundHeightAt(toVec(line[key])) end
    end
end

--- a line edited by its handles follows the ground as the editor's snapping says (direct report :
--- a line laid with snapping on still followed the ground, edited with it off), measured again
---@param line table
local function lineEdited(line)
    line.followGround = snapOn()
    fitLineCount(line)
    updateLineHeights(line)
end

--- the points a prop stands on : a single prop's position, a line's ends and its bend
---@param prop table
---@return vec3[]
local function propPoints(prop)
    if prop.kind == "line" then
        local out = {}
        for _, key in ipairs({ "a", "b", "mid" }) do
            if prop[key] then out[#out + 1] = toVec(prop[key]) end
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
                if prop.kind == "line" then
                    for _, key in ipairs({ "a", "b", "mid" }) do
                        if was[key] then prop[key] = place(was[key]) end
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
            if prop and prop.kind == "line" then updateLineHeights(prop) end
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
    if prop.kind == "line" and M.activePropPart == "mid" then
        -- the middle : where the curve passes halfway (the straight line's middle until it's bent)
        local a, b = toVec(prop.a), toVec(prop.b)
        local whole = false
        gizmo.show({
            pos = toVec(prop.mid) or (a + b) * .5,
            dir = flatDir(b - a),
            up = up,
            scales = vec3(1, 1, 1),
        }, function(updated) ---@param updated GizmoObject
            if not active() then return end
            if ctrlHeld() then
                -- the whole line, its bend kept (a straight one stays straight)
                local before = toVec(prop.mid) or (toVec(prop.a) + toVec(prop.b)) * .5
                shiftLine(prop, updated.pos - before)
                whole = true
            else
                prop.mid = xyz(updated.pos)
            end
            prop.heights, prop.normals = nil, nil -- measured again once dropped
            fitLineCount(prop)
            markDirty()
            propsChanged()
        end, function()
            if whole and snapOn() then
                snapLine(prop)
            elseif prop.mid and snapOn() then
                prop.mid.z = groundHeightAt(toVec(prop.mid))
            end
            lineEdited(prop)
            pushUpdate()
            updatePropGizmo()
            propsChanged()
        end)
    elseif prop.kind == "line" then
        local part = M.activePropPart == "b" and "b" or "a"
        local other = part == "a" and "b" or "a"
        local pos = toVec(prop[part])
        local whole = false
        gizmo.show({
            pos = pos,
            dir = flatDir(toVec(prop[other]) - pos),
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
                prop[part] = xyz(updated.pos)
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
            if snapOn() and gizmo.tool ~= "rotate" then
                prop.pos.z = groundHeightAt(toVec(prop.pos))
                tiltSingle(prop)
            end
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
    M.activePropPart = prop.kind == "line" and "b" or nil
    M.propSelection = {}
    hostSelects()
    updatePropGizmo()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

---@param index integer
---@param partial table scale / count / yaw / followGround / gap (metres) / fixedGap (on : a gap
---of the line's own spacing now ; off : its count kept)
local function onSetProp(index, partial)
    local prop = props() and props()[index]
    if not prop or type(partial) ~= "table" then return end
    if partial.scale ~= nil then
        prop.scale = math.max(.1, math.min(tonumber(partial.scale) or 1, 10))
    end
    if prop.kind == "line" then
        if partial.fixedGap ~= nil then
            if partial.fixedGap == true and not prop.gap then
                local count = math.max(1, tonumber(prop.count) or 1)
                local spacing = count > 1 and beamjoy_props.lineLength(prop) / (count - 1) or
                    beamjoy_props.tuning(prop.shape).length * (prop.scale or 1)
                prop.gap = math.max(GAP_MIN, math.min(round2(spacing), GAP_MAX))
            elseif partial.fixedGap == false then
                prop.gap = nil
            end
        end
        if partial.gap ~= nil and prop.gap and tonumber(partial.gap) then
            prop.gap = math.max(GAP_MIN, math.min(tonumber(partial.gap), GAP_MAX))
        end
        if partial.count ~= nil and not prop.gap then
            local others = beamjoy_props.total(props()) - beamjoy_props.weight(prop)
            -- each of its props with its parts (a line of prefabs)
            local each = 1 + (type(prop.parts) == "table" and #prop.parts or 0)
            prop.count = math.max(1, math.min(math.floor(tonumber(partial.count) or prop.count),
                math.floor((beamjoy_props.MAX_PROPS - others) / each)))
        end
        if partial.yaw ~= nil then
            prop.yaw = ((tonumber(partial.yaw) or 0) + 180) % 360 - 180
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
--- in the race
---@param index integer
---@param solid boolean
local function onSetPropSolid(index, solid)
    local prop = props() and props()[index]
    if not prop then return end
    -- kept only where it differs from its meshes' own ; not `cond and x or nil`, which is never false
    local want = solid == true
    if want == beamjoy_props.solidByDefault(prop) then
        prop.solid = nil
    else
        prop.solid = want
    end
    markDirty()
    pushUpdate()
    propsChanged()
end

---@param index integer
local function onDeleteProp(index)
    if not props() or not props()[index] then return end
    table.remove(props(), index)
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
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

--- the selected props leave their groups (they stay selected)
local function onUngroupProps()
    if not props() then return end
    for _, i in ipairs(M.propSelection) do
        if props()[i] then props()[i].group = nil end
    end
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
    if prop.kind == "line" then
        local a, b = toVec(prop.a), toVec(prop.b)
        local offset = flatDir(b - a):cross(vec3(0, 0, 1)) * 4
        local na, nb = a + offset, b + offset
        if snapOn() then
            na = vec3(na.x, na.y, groundHeightAt(na))
            nb = vec3(nb.x, nb.y, groundHeightAt(nb))
        end
        copy.a, copy.b = xyz(na), xyz(nb)
        if prop.mid then
            local nm = toVec(prop.mid) + offset
            if snapOn() then nm = vec3(nm.x, nm.y, groundHeightAt(nm)) end
            copy.mid = xyz(nm)
        end
        updateLineHeights(copy)
    else
        local pos = toVec(prop.pos) + singleAlong(prop) * (beamjoy_props.tuning(prop.shape).length * (prop.scale or 1))
        if snapOn() then pos = vec3(pos.x, pos.y, groundHeightAt(pos)) end
        copy.pos = xyz(pos)
    end
    addProp(copy)
end

--- a bent line goes straight again (its middle handle dropped)
---@param index integer
local function onStraightenPropLine(index)
    local line = props() and props()[index]
    if not line or line.kind ~= "line" or not line.mid then return end
    line.mid = nil
    fitLineCount(line)
    updateLineHeights(line)
    updatePropGizmo()
    markDirty()
    pushUpdate()
    propsChanged()
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

---@return integer a group no prop has yet
local function newGroupId()
    local id = 0
    for _, p in ipairs(props()) do id = math.max(id, tonumber(p.group) or 0) end
    return id + 1
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
        }
    end
    replaceProp(index, singles, tonumber(line.group))
end

--- a prefab becomes its meshes (direct request), each where it was : a group of them, to move
--- together still or (Shift+click) one by one
---@param index integer
local function onSplitPrefab(index)
    local prop = props() and props()[index]
    if not prop or prop.kind == "line" or type(prop.parts) ~= "table" then return end
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
    if prop.kind == "line" then
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
    if not prop or prop.kind == "line" then return end
    local at, facing = propPlacement()
    if not at then return end
    prop.pos = xyz(at)
    prop.dir = xyz(singleDir(facing, beamjoy_props.tuning(prop.shape).yaw))
    prop.up = { x = 0, y = 0, z = 1 }
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

--- what a release would place now : one entry (a single prop or a line), with the line's length.
--- A prefab is laid in a line too (direct request), one every its own length, the gap fixed so a
--- longer line takes more of them (a guardrail stays one rail). What the eyedropper picked up
--- (`template` : the prop's scale, collision, other mesh...) goes with it
---@return table? entry, number meters
local function placingEntry()
    local p = M.placing
    -- the line being dragged holds fewer props than its length asks for : the props are nearly full
    p.capped = false
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
        for _, key in ipairs({ "a", "b", "mid" }) do
            local off = tpl.line.offsets[key]
            if off then
                local o = beamjoy_props.turn(off, turnBy)
                local pt = vec3(at.x + o.x, at.y + o.y, at.z + o.z)
                if snapOn() then pt.z = groundHeightAt(pt) end
                line[key] = xyz(pt)
            else
                line[key] = nil
            end
        end
        line.yaw = wrapYaw((tonumber(line.yaw) or 0) + turnBy)
        line.followGround = snapOn()
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
        -- laid on the ground's tilt, snapping on
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
        dragging = p.drag ~= nil,
        count = entry and beamjoy_props.weight(entry) or 0,
        meters = math.floor((meters or 0) + .5),
        rot = p.rot,
        spacing = round2(p.spacing),
        overWorld = p.hit ~= nil,
        capped = p.drag ~= nil and p.capped == true,
        keepPlacing = M.keepPlacing,
        fixedRotation = M.fixedRotation,
        picked = p.template ~= nil,
    } or { armed = false }
    local key = p and string.format("%s|%s|%s|%d|%d|%d|%.2f|%s|%s|%s|%s|%s", p.shape, tostring(p.prefab),
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

--- the eyedropper (direct request, in place of Duplicate) : a placed prop's mesh or prefab armed,
--- with what makes it that prop (its scale, collision, a line's other mesh and fixed gap, its turn
--- along a line). A single prop's own heading too while Fixed rotation is on
---@param index integer
local function onEyedropProp(index)
    local prop = props() and props()[index]
    if not prop then return end
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
                offsets = { a = a - centre, b = b - centre, mid = toVec(prop.mid) and toVec(prop.mid) - centre or nil },
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
    if not entry or not propBudget(beamjoy_props.weight(entry)) then return end
    local io = ui_imgui.GetIO()
    -- the drawer's "Keep placing" (on until turned off), or Ctrl held for this one (direct request :
    -- Shift turns the props while dragging)
    local keepArmed = M.keepPlacing or (io ~= nil and io.KeyCtrl == true)
    if keepArmed then
        addProp(entry, true)
        if beamjoy_props.total(props()) >= beamjoy_props.MAX_PROPS then disarmProp() end
    else
        disarmProp()
        addProp(entry)
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
            if p.drag and not shift and not fine then
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
        beamjoy_props.show(GHOST_SET, { entry }, { collision = false, collisionType = "None" })
        drawGhostPanels(entry)
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
    onDeleteSelectedProps()
end

-- CLIPBOARD ------------------------------------------------------------------------------------
-- Props copied from one race or arena and pasted into another (direct request) : the selection, or
-- every prop when nothing is selected. Kept in a file, so it outlives the session ; pasted on
-- the map they were copied on only, where they stand.

local CLIPBOARD_FILE = "/temp/bjPropClipboard.json"
---@type {map: string?, props: table[]}?
local clipboard = nil
local clipboardRead = false

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
            if props()[i] then copied[#copied + 1] = table.clone(props()[i]) end
        end
    else
        for _, prop in ipairs(props()) do copied[#copied + 1] = table.clone(prop) end
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
    if not propBudget(beamjoy_props.total(clipboard.props)) then return end
    disarmProp()
    local base, groups = newGroupId() - 1, {}
    local first = #props() + 1
    for _, prop in ipairs(clipboard.props) do
        local copy = table.clone(prop)
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
    M.propSelection = {}
    for i = first, #props() do M.propSelection[#M.propSelection + 1] = i end
    M.activePropIndex, M.activePropPart = first, nil
    hostSelects()
    updatePropGizmo()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

--- a placed prop takes another mesh (the drawer's "Swap mesh"), kept where it is and turned by the
--- difference between the two meshes' own facings
---@param index integer
---@param shape string
local function onSwapPropShape(index, shape)
    local prop = props() and props()[index]
    if not prop or prop.shape == shape or not beamjoy_propPicker.isPlaceable(shape) then return end
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

--- a line's end cap turned half round (a mesh made facing the other way)
---@param index integer
---@param which "a"|"b"
local function onFlipPropCap(index, which)
    local prop = props() and props()[index]
    local k = which == "a" and "A" or which == "b" and "B" or nil
    if not prop or prop.kind ~= "line" or not k or not prop["cap" .. k] then return end
    local yaw = wrapYaw((tonumber(prop["cap" .. k .. "Yaw"]) or 0) + 180)
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
---@return number? t distance along the ray to the closest approach, only if within radius
local function rayHitsHandle(pos, radius, camPos, rayDir)
    -- the handles are drawn half a metre above the ground (drawOverlays)
    local p = vec3(pos.x, pos.y, pos.z) + vec3(0, 0, .5)
    local t = (p - camPos):dot(rayDir)
    if t <= 0 then return nil end
    if (camPos + rayDir * t):distance(p) <= radius then return t end
    return nil
end

--- the prop under the mouse ray : a single one round its base, a line by either end or its middle
---@param camPos vec3
---@param rayDir vec3
---@return number? t, integer? index, "a"|"b"|"mid"|nil part
function M.pick(camPos, rayDir)
    local list = active() and props() or nil
    if not list then return nil end
    local bestT, bestIndex, bestPart
    for i, p in ipairs(list) do
        if p.kind == "line" then
            for _, part in ipairs({ "a", "b" }) do
                local t = p[part] and rayHitsHandle(p[part], 1.2, camPos, rayDir)
                if t and (not bestT or t < bestT) then
                    bestT, bestIndex, bestPart = t, i, part
                end
            end
            -- its middle (bend) handle, drawn on the selected line or a bent one
            local midPos = p.mid or (p.a and p.b and i == M.activePropIndex and
                { x = (p.a.x + p.b.x) / 2, y = (p.a.y + p.b.y) / 2, z = (p.a.z + p.b.z) / 2 })
            local tm = midPos and rayHitsHandle(midPos, 1.2, camPos, rayDir)
            if tm and (not bestT or tm < bestT) then
                bestT, bestIndex, bestPart = tm, i, "mid"
            end
        elseif p.pos then
            local t = rayHitsHandle(p.pos, 1.5, camPos, rayDir)
            if t and (not bestT or t < bestT) then
                bestT, bestIndex, bestPart = t, i, nil
            end
        end
    end
    return bestT, bestIndex, bestPart
end

--- a prop clicked in the world : Ctrl+click adds it to the selection (or takes it out), Shift+click
--- picks one of a group alone (direct request : multiple selection and groups). A click on the
--- handle already held does nothing : it's meant for the gizmo drawn on it
---@param index integer
---@param part "a"|"b"|"mid"|nil
function M.clickSelect(index, part)
    local mode = ctrlHeld() and "add" or shiftHeld() and "alone" or nil
    if not mode and index == M.activePropIndex and part == M.activePropPart then return end
    M.onSelectProp(index, part, mode)
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

--- per frame, from the host's onUpdate : true while a prop is armed (the mouse is the placing's,
--- the host's own handles wait)
---@return boolean
function M.onUpdate()
    return updatePlacing()
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
    blockNodeGrabber(true)
    M.reset()
end

--- the host closes : its props' preview and handles go with it
---@param host BJPropEditorHost
function M.detach(host)
    if not M.host or M.host ~= host then return end
    disarmProp()
    M.host = nil
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
        if mode ~= "add" and mode ~= "alone" and (part == nil or part == "") then
            mode = index and (ctrlHeld() and "add" or shiftHeld() and "alone") or nil
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
    ui.addHandler("BJEditorPropsTeleportTo", onTeleportToProp)
    ui.addHandler("BJEditorPropsSetToVehicle", onSetPropToVehicle)
    ui.addHandler("BJEditorPropsArm", onArmProp)
    ui.addHandler("BJEditorPropsArmPrefab", onArmPrefab)
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
