--- In-world derby arena editor, a host around the shared `pointListEditor.lua` toolkit like
--- infectedEditor.lua, with one difference : a map holds several derby arenas, so this edits one
--- of them at a time (picked from a list, or a new one), each saved on its own.
---
--- Point lists : the start positions (one per player) and the sumo zone (at most one, at its
--- starting size). The zone is a circle (its radius), or a rectangle or an ellipse (width, length, and a facing
--- the gizmo's rotate tool turns : the item carries a `dir`, see pointListEditor.lua). A selected
--- rectangle or ellipse also gets the race editor's edge handles : drag a side to resize it. The arena's
--- floor (how far below the zone's centre counts as having fallen off) is drawn as a second, lower
--- copy of the zone.

local pointListEditor = require("ge/extensions/beamjoy/ui/pointListEditor")

---@class BJActivityEditorDerby: BJActivityEditor
local M = {
    ---@type integer? the arena being edited ; nil for a new one not saved yet
    arenaId = nil,
    name = "",
    enabled = false,
    floorDepth = 10,
    defaults = {},
}
---@type BJActivityEditorCommon?
local parent

local FLOOR_COLOR = BJColor(1, .3, .2, .35)
local RECT_MIN, RECT_MAX = 10, 2000
local ELLIPSE_SEGMENTS = 48
-- the shapes sized by width / length and turned by the rotate tool (the item carries a `dir`)
local DIRECTED = { rect = true, ellipse = true }

---@param item table a rectangle or ellipse zone item
---@return vec3[] its outline at ground level, in order around it : 4 corners, or ELLIPSE_SEGMENTS points
local function outlinePoints(item)
    local fwd = vec3(item.dir.x, item.dir.y, 0)
    fwd = fwd:length() > 1e-4 and fwd:normalized() or vec3(1, 0, 0)
    local right = vec3(fwd.y, -fwd.x, 0)
    local hl, hw = (item.length or 80) / 2, (item.width or 80) / 2
    local c = vec3(item.pos.x, item.pos.y, item.pos.z)
    if item.shape ~= "ellipse" then
        local f, r = fwd * hl, right * hw
        return { c + r + f, c - r + f, c - r - f, c + r - f }
    end
    local pts = {}
    for i = 1, ELLIPSE_SEGMENTS do
        local a = 2 * math.pi * i / ELLIPSE_SEGMENTS
        pts[i] = c + fwd * (math.cos(a) * hl) + right * (math.sin(a) * hw)
    end
    return pts
end

--- a flat outline (a fan of triangles from the centre) with its edge, raised by zOffset
---@param item table
---@param zOffset number
---@param color table
local function drawOutline(item, zOffset, color)
    local pts = outlinePoints(item)
    local up = vec3(0, 0, zOffset)
    local c = vec3(item.pos.x, item.pos.y, item.pos.z) + up
    for i = 1, #pts do
        local a, b = pts[i] + up, pts[i % #pts + 1] + up
        shape.addTriangle(c, a, b, color)
        shape.addLine(a, .3, b, .3, color)
    end
end

-- EDGE HANDLES ------------------------------------------------------------------------------------
-- The race editor's gate handles (raceEditor.lua) on a selected rectangle or ellipse : a bar on each
-- side (a rectangle's whole edge, a short bar at each end of an ellipse's axes). Dragging one moves
-- that side, the opposite one stays put : the front / back change the length, the sides the width.
-- Custom geometry, hit-tested and dragged by hand from the mouse ray every frame like the race
-- editor's, not the engine gizmo's scale tool.

local HANDLE_COLOR = BJColor(0, 1, 1, .9)
local HANDLE_THICKNESS = .35
-- an ellipse's bars : this share of the other semi-axis, either way
local ELLIPSE_BAR = .35

---@type {key: "width"|"length", anchor: vec3, axis: vec3}? the opposite side's middle and the direction out to the dragged one
local draggingHandle = nil

--- the zone's 4 handles, each a segment (a, b) with what dragging it changes
---@param item table a rectangle or ellipse zone item
---@return {a: vec3, b: vec3, key: "width"|"length", anchor: vec3, axis: vec3}[]
local function zoneHandles(item)
    local fwd = vec3(item.dir.x, item.dir.y, 0)
    fwd = fwd:length() > 1e-4 and fwd:normalized() or vec3(1, 0, 0)
    local right = vec3(fwd.y, -fwd.x, 0)
    local hl, hw = (item.length or 80) / 2, (item.width or 80) / 2
    -- just above the ground : drawn over the zone's own fill
    local c = vec3(item.pos.x, item.pos.y, item.pos.z + .1)
    local bar = item.shape == "ellipse"
    local handles = {}
    local function add(out, along, halfLen, key, size)
        local mid = c + out * (size / 2)
        handles[#handles + 1] = {
            a = mid - along * halfLen, b = mid + along * halfLen,
            key = key, anchor = mid - out * size, axis = out,
        }
    end
    add(fwd, right, bar and hw * ELLIPSE_BAR or hw, "length", hl * 2)
    add(fwd * -1, right, bar and hw * ELLIPSE_BAR or hw, "length", hl * 2)
    add(right, fwd, bar and hl * ELLIPSE_BAR or hl, "width", hw * 2)
    add(right * -1, fwd, bar and hl * ELLIPSE_BAR or hl, "width", hw * 2)
    return handles
end

--- signed distance along the line (origin, unit dir) to its point closest to the camera ray ;
--- the same maths as raceEditor.lua's closestLineParam
---@return number
local function closestLineParam(camPos, rayDir, lineOrigin, lineDir)
    local r = camPos - lineOrigin
    local b = rayDir:dot(lineDir)
    local f = lineDir:dot(r)
    local c = rayDir:dot(r)
    local denom = 1 - b * b
    if math.abs(denom) < 1e-5 then return f end
    if (b * f - c) / denom < 0 then return f end
    return (f - b * c) / denom
end

--- distance from the camera ray to a segment ; raceEditor.lua's closestRayToSegmentDistance
---@return number
local function rayToSegmentDistance(camPos, rayDir, segStart, segEnd)
    local segVec = segEnd - segStart
    local segLen = segVec:length()
    if segLen < 1e-5 then
        local t = math.max(0, rayDir:dot(segStart - camPos))
        return (camPos + rayDir * t):distance(segStart)
    end
    local segDir = segVec / segLen
    local r = camPos - segStart
    local b = rayDir:dot(segDir)
    local f = segDir:dot(r)
    local c = rayDir:dot(r)
    local denom = 1 - b * b
    local t, s
    if math.abs(denom) < 1e-5 then
        t, s = 0, math.max(0, math.min(segLen, f))
    else
        t = math.max(0, (b * f - c) / denom)
        s = math.max(0, math.min(segLen, (f - b * c) / denom))
    end
    return (camPos + rayDir * t):distance(segStart + segDir * s)
end

local listEditor

---@return table? the selected zone item, when it's a shape with handles
local function handleZone()
    local list, index = listEditor.getActive()
    if list ~= "zone" then return nil end
    local item = (listEditor.getLists().zone or {})[index]
    return item and DIRECTED[item.shape] and item or nil
end

--- the handle under the mouse ray. Arena zones are big and usually seen from far off : the grab
--- distance grows with the distance to the handle
---@return table?
local function handleUnderRay(item, camPos, rayDir)
    local best, bestDist
    for _, h in ipairs(zoneHandles(item)) do
        local dist = rayToSegmentDistance(camPos, rayDir, h.a, h.b)
        local tolerance = math.max(.6, camPos:distance((h.a + h.b) / 2) * .012)
        if dist <= tolerance and (not bestDist or dist < bestDist) then best, bestDist = h, dist end
    end
    return best
end

listEditor = pointListEditor.new({
    lists = {
        {
            key = "startPositions",
            labelKey = "beamjoy.window.config.tabs.derbyArena.startPosition",
            color = BJColor(1, .6, 0, .8),
            hasDir = true,
        },
        {
            key = "zone",
            labelKey = "beamjoy.window.config.tabs.derbyArena.zone",
            color = BJColor(.3, .55, 1, .35),
            hasRadius = true,
            flatRadius = true,
            defaultRadius = 40,
            max = 1,
            drawItem = function(item, color, text)
                if not DIRECTED[item.shape] then return false end
                local pos = vec3(item.pos.x, item.pos.y, item.pos.z)
                drawOutline(item, 0, color)
                shape.addSphere(pos, .5, color)
                shape.addText(text, pos + vec3(0, 0, 1.5), color, BJColor(0, 0, 0, .3))
                if handleZone() == item then
                    for _, h in ipairs(zoneHandles(item)) do
                        shape.addLine(h.a, HANDLE_THICKNESS, h.b, HANDLE_THICKNESS, HANDLE_COLOR)
                    end
                end
                return true
            end,
            drawExtra = function(item)
                if DIRECTED[item.shape] then return drawOutline(item, -M.floorDepth, FLOOR_COLOR) end
                local pos = vec3(item.pos.x, item.pos.y, item.pos.z - M.floorDepth)
                shape.addCylinder(pos - vec3(0, 0, .05), pos + vec3(0, 0, .05), item.radius or 40, FLOOR_COLOR)
            end,
        },
    },
    events = {
        listsUpdate = "BJEditorDerbyArenaListsUpdate",
        activeUpdate = "BJEditorDerbyArenaActiveUpdate",
        select = "BJEditorDerbyArenaSelect",
        create = "BJEditorDerbyArenaCreate",
        delete = "BJEditorDerbyArenaDelete",
        setToVehicle = "BJEditorDerbyArenaSetToVehicle",
        teleportTo = "BJEditorDerbyArenaTeleportTo",
        setRadius = "BJEditorDerbyArenaSetWaypointRadius",
        snapToGround = "BJEditorDerbyArenaSnapToGround",
        snapMethod = "BJEditorDerbyArenaSnapMethod",
        setSnapToGround = "BJEditorDerbyArenaSetSnapToGround",
        setSnapMethod = "BJEditorDerbyArenaSetSnapMethod",
        requestState = "BJEditorDerbyArenaRequestState",
    },
    isActive = function() return parent ~= nil and parent.activeEditor == M end,
})

local function pushMeta()
    beamjoy_communications_ui.send("BJEditorDerbyArenaMetaUpdate", {
        arenas = table.map(beamjoy_derby.data or {}, function(a)
            return { id = a.id, name = a.name, enabled = a.enabled == true }
        end),
        arenaId = M.arenaId,
        isNew = M.arenaId == nil,
        blank = M.blank == true,
        name = M.name,
        enabled = M.enabled,
        floorDepth = M.floorDepth,
        defaults = M.defaults,
    })
end

--- loads an arena (or a blank new one) into the editor, dropping unsaved edits
---@param arena BJDerbyArena?
---@param keepSelection boolean? the same arena again (it was just saved) : the selected point stays
local function load(arena, keepSelection)
    -- nothing to edit (a map without arenas) : the UI shows its empty state
    M.blank = arena == nil
    arena = arena or {}
    M.arenaId = arena.id
    M.name = arena.name or ""
    M.enabled = arena.enabled == true
    M.floorDepth = tonumber(arena.floorDepth) or 10
    M.defaults = table.clone(arena.defaults or {})
    listEditor.open({
        startPositions = arena.startPositions,
        zone = arena.zone and { arena.zone } or {},
    }, keepSelection)
    pushMeta()
end

local function onOpen()
    if not parent then return end
    if parent.activeEditor and parent.activeEditor ~= M then
        parent.activeEditor.onClose()
    end
    parent.activeEditor = M
    beamjoy_communications_ui.send("BJEditorChangeTool", gizmo.tool)
    -- the arena last edited, or the first one
    local arena = M.arenaId and beamjoy_derby.getArena(M.arenaId) or (beamjoy_derby.data or {})[1]
    load(arena)
end

--- a fresh arena list from the server (a save, a delete, an import) : the list always refreshes,
--- the arena being edited only when it has no unsaved changes
local function onArenasChanged()
    if not parent or parent.activeEditor ~= M then return end
    if listEditor.isDirty() then return pushMeta() end
    local arena = M.arenaId and beamjoy_derby.getArena(M.arenaId)
    if arena then
        load(arena, true)
    elseif M.arenaId then
        load((beamjoy_derby.data or {})[1])
    else
        pushMeta()
    end
end

---@param id integer
local function onSelectArena(id)
    if not parent or parent.activeEditor ~= M then return end
    load(beamjoy_derby.getArena(tonumber(id)))
end

local function onNewArena()
    if not parent or parent.activeEditor ~= M then return end
    load({
        name = beamjoy_lang.translate("beamjoy.window.config.tabs.derbyArena.newName"),
        floorDepth = 10,
        -- the same values the server falls back on (services/derby.lua sanitizeDefaults)
        defaults = {
            mode = "lms", lives = 0, roundDuration = 5, stuckSeconds = 20, zoneGraceSeconds = 3,
            shrinkEverySeconds = 30, shrinkSteps = 6, minRadiusPercent = 25, respawnGhostSeconds = 3,
            randomizeVehiclePool = false, gridReadyTimeout = 15, gridTimeout = 120, countdown = 10, endTimeout = 10,
        },
    })
    listEditor.markDirty()
end

local function onDeleteArena()
    if not parent or parent.activeEditor ~= M then return end
    if not M.arenaId then
        -- a new arena that was never saved : just drop it
        return load((beamjoy_derby.data or {})[1])
    end
    local deleted = M.arenaId
    beamjoy_communications.send("derbyArenaDelete", deleted)
    -- on to another arena right away (the list itself refreshes when the server answers)
    load(table.find(beamjoy_derby.data or {}, function(a) return a.id ~= deleted end))
end

---@param meta {name: string?, enabled: boolean?, floorDepth: number?}
local function onSetMeta(meta)
    if not parent or parent.activeEditor ~= M or type(meta) ~= "table" then return end
    if type(meta.name) == "string" then M.name = meta.name:sub(1, 40) end
    if meta.enabled ~= nil then M.enabled = meta.enabled == true end
    if tonumber(meta.floorDepth) then
        M.floorDepth = math.max(1, tonumber(meta.floorDepth))
        listEditor.redraw()
    end
    listEditor.markDirty()
end

--- the zone's shape and, for a rectangle or an ellipse, its size (from the Positions panel)
---@param opts {shape: string?, width: number?, length: number?}
local function onSetZoneShape(opts)
    if not parent or parent.activeEditor ~= M or type(opts) ~= "table" then return end
    local item = (listEditor.getLists().zone or {})[1]
    if not item then return end
    local wasDirected = DIRECTED[item.shape] == true
    if DIRECTED[opts.shape] then
        -- fresh from a circle : the square around it, or the same circle as an ellipse
        local side = (item.radius or 40) * 2
        item.shape = opts.shape
        item.width = math.clamp(tonumber(opts.width) or item.width or side, RECT_MIN, RECT_MAX)
        item.length = math.clamp(tonumber(opts.length) or item.length or side, RECT_MIN, RECT_MAX)
        item.dir = item.dir or { x = 1, y = 0, z = 0 }
    else
        item.shape = "circle"
        item.radius = item.radius or 40
        item.dir = nil
    end
    if wasDirected ~= (DIRECTED[item.shape] == true) then
        -- the gizmo gains or loses its facing, the sidebar its radius box
        listEditor.reassert()
    else
        listEditor.redraw()
    end
    listEditor.markDirty()
end

---@param defaults table
local function onSetDefaults(defaults)
    if not parent or parent.activeEditor ~= M then return end
    M.defaults = type(defaults) == "table" and defaults or {}
    listEditor.markDirty()
end

local function onSave()
    if not parent then return end
    local lists = listEditor.getLists()
    local zone = lists.zone and lists.zone[1]
    local payload = {
        id = M.arenaId,
        name = M.name,
        enabled = M.enabled,
        startPositions = table.map(lists.startPositions, math.roundPosRotDirUp),
        zone = zone and (DIRECTED[zone.shape] and {
            shape = zone.shape,
            pos = { x = zone.pos.x, y = zone.pos.y, z = zone.pos.z },
            dir = { x = zone.dir.x, y = zone.dir.y, z = 0 },
            width = zone.width,
            length = zone.length,
        } or {
            shape = "circle",
            pos = { x = zone.pos.x, y = zone.pos.y, z = zone.pos.z },
            radius = zone.radius or 40,
        }) or nil,
        floorDepth = M.floorDepth,
        defaults = M.defaults,
    }
    beamjoy_communications.send("derbyArenaSave", payload)
    beamjoy_communications.addOneUseHandler("derbyArenaSaved", function(status, err, id)
        if status then
            M.arenaId = tonumber(id) or M.arenaId
            listEditor.clearDirty()
            pushMeta()
        else
            toast.error(err or "Failed to save data")
        end
    end, 5000)
end

---@param activityEditor BJActivityEditorCommon
local function onInit(activityEditor)
    parent = activityEditor
    listEditor.onInit()

    beamjoy_communications_ui.addHandler("BJEditorDerbyArenaOpen", onOpen)
    beamjoy_communications_ui.addHandler("BJEditorDerbyArenaClose", parent.onClose)
    beamjoy_communications_ui.addHandler("BJEditorDerbyArenaPick", onSelectArena)
    beamjoy_communications_ui.addHandler("BJEditorDerbyArenaNew", onNewArena)
    beamjoy_communications_ui.addHandler("BJEditorDerbyArenaRemove", onDeleteArena)
    beamjoy_communications_ui.addHandler("BJEditorDerbyArenaSetMeta", onSetMeta)
    beamjoy_communications_ui.addHandler("BJEditorDerbyArenaSetDefaults", onSetDefaults)
    beamjoy_communications_ui.addHandler("BJEditorDerbyArenaSetZoneShape", onSetZoneShape)
    beamjoy_communications_ui.addHandler("BJEditorDerbyArenaSave", onSave)
end

--- per-frame handle grab / drag, delegated from activityEditor.lua's onUpdate (the race editor's
--- own handle polling works the same way)
local function onUpdate()
    local item = parent and parent.activeEditor == M and handleZone() or nil
    if not item then
        draggingHandle = nil
        return
    end
    if draggingHandle then
        if ui_imgui.IsMouseReleased(ui_imgui.MouseButton_Left) then
            draggingHandle = nil
            -- whole metres, like the sidebar sliders
            item.width = math.floor(item.width + .5)
            item.length = math.floor(item.length + .5)
            listEditor.markDirty()
            -- the gizmo back on the moved centre, the sidebar on the new size
            listEditor.reassert()
            return
        end
        local camPos, rayDir = camera.mouseRay()
        if not camPos then return end
        local h = draggingHandle
        local size = math.clamp(closestLineParam(camPos, rayDir, h.anchor, h.axis), RECT_MIN, RECT_MAX)
        local centre = h.anchor + h.axis * (size / 2)
        item[h.key] = size
        item.pos.x, item.pos.y = centre.x, centre.y
        listEditor.redraw()
        return
    end
    if ui_imgui.IsMouseClicked(ui_imgui.MouseButton_Left) then
        local camPos, rayDir = camera.mouseRay()
        local h = camPos and handleUnderRay(item, camPos, rayDir)
        if h then draggingHandle = { key = h.key, anchor = h.anchor, axis = h.axis } end
    end
end

--- world click selection, unless the click is on (or dragging) a handle
local function onBJClick(...)
    if draggingHandle then return end
    local item = handleZone()
    if item then
        local camPos, rayDir = camera.mouseRay()
        if camPos and handleUnderRay(item, camPos, rayDir) then return end
    end
    return listEditor.onBJClick(...)
end

local function onClose()
    if not parent then return end
    if parent.activeEditor == M then
        listEditor.close()
    end
end

M.onInit = onInit
M.onClose = onClose
M.onUpdate = onUpdate
M.onBJClick = onBJClick
M.onBJDerbyArenasChanged = onArenasChanged

return M
