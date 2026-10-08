--- In-world race editor. Replaces the console-driven test builder
--- (`beamjoy_races.testBuilder`) as the real way to author gates/start positions, following the
--- same pattern as `activityEditorSafeZone.lua` (gizmo-driven 3D placement plus an Angular
--- sidebar over the `beamjoy_communications_ui` bridge). This is not a port of BJRally's own
--- editor (see the project plan's "don't 1:1 copy BJRally" constraint). BJRally's click-to-place/
--- mouse-wheel-rotate flow is replaced with this fork's own "create at my current position/
--- facing, then adjust with the gizmo" convention, already proven by the safe-zone editor.
---
--- Lua owns the working race object (`M.race`) as the single source of truth. The gizmo mutates
--- gate/start `pos`/`dir` directly and only triggers a marker redraw (`onBJRaceMarkersRefresh`).
--- Angular never displays position, so there's no need to push a full snapshot on every drag
--- frame (mirrors safe-zone editor's `updateGizmo`, which does the same; gate width/height via the
--- gizmo's scale tool is the one exception, see `updateGizmo` below). Every other field
--- (name/mode/loopable/defaults/gate width-height-lap) is mutated via discrete
--- `BJEditorRaceSet*` messages from Angular, each followed by a full `BJEditorRaceUpdate` push
--- back so the UI always reflects Lua-authoritative state.
---
--- Confirmation prompts (save-overwrite, discard-on-close, delete, duplicate) are NOT handled
--- here. They used to go through `uiHelpers.popupConfirm` (a native BeamNG dialogue), but that
--- rendered without actually responding to clicks, and couldn't block the rest of the CEF UI
--- (closing the config window, switching tabs underneath it) since it lives outside the Angular
--- layer entirely. Confirmation now happens Angular-side (`beamjoyConfirm`, `cmps/confirm/`)
--- *before* any of the messages below get sent at all. Everything here just performs the action
--- unconditionally once asked.

---@class BJActivityEditorRace: BJActivityEditor
local M = {
    ---@type BJRace?
    race = nil,
    ---@type BJRace? snapshot of the last-saved (or just-opened) state, for the per-gate/per-start
    ---"reset to saved state" action, not the same thing as reloading the whole editor
    savedRace = nil,
    ---@type integer? id of the race being edited server-side ; nil while authoring a new race
    id = nil,
    ---@type integer?
    activeGateIndex = nil,
    ---@type integer?
    activeStartIndex = nil,
    ---@type integer? the selected prop (race.props, see beamjoy_props)
    activePropIndex = nil,
    ---@type "a"|"b"|"mid"|nil which handle of the selected line the gizmo holds (an end, or its
    ---middle : dragging that bends the line)
    activePropPart = nil,
    --- bumped on every change to the props, so their preview (beamjoy_props) only rebuilds then
    propsRevision = 0,
    dirty = false,
    -- editor-session preference, not saved to the race itself. When on, dragging a gate/start
    -- with the gizmo re-snaps it to the ground the moment the drag ends, replacing the old
    -- manual "snap to ground" button, per direct request.
    snapToGroundEnabled = true,
    -- Which ground-height source snapping uses, also editor-session-only. Neither is universally
    -- correct. "terrain" (core_terrain.getTerrainHeight, the default) reads the raw terrain
    -- heightmap directly, immune to anything sitting on top of it, fixing gates that snapped into
    -- tree/foliage collision (a real reported bug). But on a map where the drivable surface isn't
    -- real terrain at all (Gridmap's own visible grid plane is a static mesh floating over a
    -- mostly-irrelevant underlying terrain, confirmed by live testing: gates snapped straight down
    -- to whatever's under the map), "terrain" mode gives a far-too-low height. "raycast" (the old
    -- be:getSurfaceHeightBelow behavior) instead hits whatever's physically there, correct for a
    -- static-mesh "ground" like Gridmap's, at the cost of being just as vulnerable to snagging on
    -- a tree/prop as before. No single default is right for every map, so this is switchable.
    -- BeamNG's own stock rally editor (editor/rallyEditor/zSnap.lua) exposes this same tradeoff as
    -- a real user setting, not just an internal implementation detail.
    ---@type "terrain"|"raycast"
    snapMethod = "terrain",
}
---@type BJActivityEditorCommon?
local parent

--- edge-handle drag state (width/height resize by grabbing a gate's left/right/top edge
--- directly, drawn by `raceMarkers.lua`'s `drawGateHandles`). Deliberately NOT the native engine
--- gizmo's scale tool, which was tried once already and reported broken (see `updateGizmo` below).
--- These are fully custom hit-tested and dragged via raw `ui_imgui` mouse state + a manual
--- camera-ray raycast every frame, the same primitives `inputs.lua`'s own click detection already
--- uses, not a new input mechanism.
---@type {kind:"left"|"right"|"top", anchor:vec3, axis:vec3, min:number, max:number}?
local draggingHandle = nil
local lastHandlePush = 0
-- the props drawer's placing mode (PLACING below)
local updatePlacing, disarmProp

--- A race's length in metres, following its route. The route runs from gate to gate through
--- each gate's `parents` (the gate(s) it's reached from ; 0 = the start), taking the shortest
--- branch where the route splits. A circuit's length is one lap : back round to the first gate.
--- A point-to-point race also counts the run from the grid to its first gate. Measured on every
--- save.
---@param race table gates with pos (and, while branching is on, parents/step/isFinish)
---@return integer
local function computeRaceDistance(race)
    local gates = race.gates
    if type(gates) ~= "table" or #gates == 0 then return 0 end
    local function dist(a, b)
        local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    local branching = race.branchingEnabled == true
    local function parentsOf(i)
        local p = gates[i].parents
        if branching and type(p) == "table" and #p > 0 then return p end
        return { i - 1 }
    end
    local function stepOf(i)
        return branching and tonumber(gates[i].step) or i
    end
    local order = {}
    for i = 1, #gates do order[i] = i end
    table.sort(order, function(a, b)
        local sa, sb = stepOf(a), stepOf(b)
        if sa ~= sb then return sa < sb end
        return a < b
    end)

    local start = type(race.startPositions) == "table" and race.startPositions[1] and race.startPositions[1].pos
    local best, firsts, hasChild = {}, {}, {}
    for _, i in ipairs(order) do
        for _, p in ipairs(parentsOf(i)) do
            p = tonumber(p)
            local via
            if p == 0 then
                firsts[#firsts + 1] = i
                via = (race.loopable or not start) and 0 or dist(start, gates[i].pos)
            elseif p and gates[p] and best[p] then
                hasChild[p] = true
                via = best[p] + dist(gates[p].pos, gates[i].pos)
            end
            if via and (not best[i] or via < best[i]) then best[i] = via end
        end
    end

    local total
    for i = 1, #gates do
        if best[i] then
            if race.loopable then
                -- a gate the route doesn't continue from closes the lap, back to a first gate
                if not hasChild[i] then
                    for _, f in ipairs(firsts) do
                        if f ~= i then
                            local lap = best[i] + dist(gates[i].pos, gates[f].pos)
                            if not total or lap < total then total = lap end
                        end
                    end
                end
            elseif (branching and gates[i].isFinish) or (not branching and i == #gates) then
                if not total or best[i] < total then total = best[i] end
            end
        end
    end
    if not total then
        -- a route that can't be followed (broken links) : gate to gate, in list order
        total = 0
        for i = 2, #gates do total = total + dist(gates[i - 1].pos, gates[i].pos) end
    end
    return math.floor(total + .5)
end

local function computeDistance()
    M.race.distance = computeRaceDistance(M.race)
end

--- client-side mirror of services/races.lua's own deriveStepsFromParents (same algorithm,
--- kept in sync by hand). Needed here too so the EDITOR's own live preview (gate role labels,
--- the "(Step N)" badge, world-marker rendering) reflects the real derived step immediately,
--- without waiting on a save+reload round-trip through the server's own authoritative copy. See
--- the server-side function's own comment for the real bug this fixes : `step` used to be a
--- separately-editable field an author had to remember to keep in sync with `parents` by hand,
--- which a branch alternate created later than its siblings has no way to do correctly on its own
--- default value alone (confirmed by a real report: "when I went through 3, it said 6").
---@param race BJRace
local function deriveStepsFromParents(race)
    local resolved = {}
    -- Grants step 1 any time "Start" (0) is present among a gate's parents, regardless of whatever
    -- real gates are also listed alongside it. See the server-side twin of this function for the
    -- real bug this fixes: a second real parent used to silently strip step-1 status even with
    -- Start still listed, and replacing Start with a real link to the route's own last gate left
    -- nothing at step 1 at all, so a lap could never be detected as complete.
    for i, g in ipairs(race.gates) do
        if table.includes(g.parents, 0) then
            resolved[i] = 1
        end
    end
    local changed, iterations = true, 0
    while changed and iterations < #race.gates do
        changed, iterations = false, iterations + 1
        for i, g in ipairs(race.gates) do
            if not resolved[i] then
                local ready, maxParentStep = true, 0
                for _, p in ipairs(g.parents) do
                    if p ~= 0 then
                        if resolved[p] then
                            maxParentStep = math.max(maxParentStep, resolved[p])
                        else
                            ready = false
                        end
                    end
                end
                if ready then
                    resolved[i] = maxParentStep + 1
                    changed = true
                end
            end
        end
    end
    -- Fallback guaranteed to never coincide with a real step (every real step is <= #race.gates).
    -- See the server-side twin of this function for the real bug this fixes: falling back to the
    -- gate's own array position could silently mislabel an unrelated gate (e.g. array position 1)
    -- as a genuine step-1 Start/Finish once a cycle formed through a shared multi-parent node.
    for i, g in ipairs(race.gates) do
        g.step = resolved[i] or (#race.gates + i)
    end
end

local function pushUpdate()
    if not M.race then return end
    -- Re-derived on every push, not just certain handlers, so it can never end up stale
    -- regardless of which mutation triggered this. Cheap and idempotent given the current
    -- parents/gates data; see the function's own comment for why this exists at all.
    if M.race.branchingEnabled and table.isArray(M.race.gates) then
        deriveStepsFromParents(M.race)
    end
    computeDistance()
    beamjoy_communications_ui.send("BJEditorRaceUpdate", M.race)
end

local function markDirty()
    if not M.dirty then
        M.dirty = true
        beamjoy_communications_ui.send("BJEditorDirty", M.dirty)
    end
end

--- used only by the reset-to-saved-state actions : an ordinary edit always just latches dirty
--- true (matches every other mutation here), but a *revert* can legitimately bring the whole
--- race back to exactly its saved shape, so it's worth actually checking rather than leaving the
--- Save button misleadingly enabled after undoing the only change that was made
local function refreshDirty()
    local newDirty = M.savedRace == nil or not table.deepcompare(M.race, M.savedRace)
    if newDirty ~= M.dirty then
        M.dirty = newDirty
        beamjoy_communications_ui.send("BJEditorDirty", M.dirty)
    end
end

local function pushActive()
    beamjoy_communications_ui.send("BJEditorRaceActiveGate", M.activeGateIndex)
    beamjoy_communications_ui.send("BJEditorRaceActiveStart", M.activeStartIndex)
    beamjoy_communications_ui.send("BJEditorRaceActiveProp", { index = M.activePropIndex, part = M.activePropPart })
end

--- the props' preview and the markers catch up with a change to the props
local function propsChanged()
    M.propsRevision = M.propsRevision + 1
    extensions.hook("onBJRaceMarkersRefresh")
end

--- ground-height query for snapping, routed through M.snapMethod (see its own comment above for
--- the full tradeoff). "terrain" reads the raw heightmap directly (immune to trees/props but
--- wrong on a map whose real ground isn't terrain at all), "raycast" is the old
--- be:getSurfaceHeightBelow behavior. Also the terrain fallback path whenever a map has no terrain
--- object at all (core_terrain.getTerrainHeight returns nil there regardless of mode).
---@param pos vec3
---@return number
local function groundHeightAt(pos)
    if M.snapMethod ~= "raycast" then
        local h = core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(pos)
        if h then return h end
    end
    return be:getSurfaceHeightBelow(pos + vec3(0, 0, 10))
end

---@return vec3? pos, vec3? dir
local function currentPositionDirection()
    local currVeh = beamjoy_vehicles.getCurrent()
    if not currVeh or camera.getCamera() == camera.CAMERAS.FREE then
        local pos, dir = camera.getPositionRotation(false)
        -- Free camera floats wherever you happen to be looking from, unlike a vehicle's own
        -- position (already grounded), so a gate/start created here would otherwise spawn
        -- hovering in mid-air. Respects the same snap-to-ground preference the gizmo's own
        -- drag-end auto-snap uses, rather than always forcing it unconditionally.
        if pos and M.snapToGroundEnabled then
            local grounded = groundHeightAt(pos)
            pos = vec3(pos.x, pos.y, grounded)
        end
        return pos, dir
    end
    return beamjoy_vehicles.getVehiclePositionRotation(currVeh.veh)
end

-- how many straight-down probes to spread across the gate's own width when ground-snapping. A
-- single center-only ray leaves the gate's flat bottom edge floating above any dip in uneven
-- terrain that happens to fall left/right of center instead of directly under it
local GROUND_SNAP_SAMPLES = 5

--- scans several points across the gate's own width (not just its center point) and snaps to
--- whichever one hit the LOWEST terrain, instead of a single straight-down ray at the center,
--- per direct request, so an uneven strip of terrain under the gate can't leave part of its
--- bottom edge visibly floating above a dip that a center-only probe would never have found.
--- Trades the opposite risk (the gate may now clip slightly into a high point elsewhere along its
--- width) deliberately, matching what was actually asked for. Start positions have no width
--- concept and keep the plain single-point snap in updateGizmo's own drag-end callback.
---@param gate BJRaceGate
local function snapGateToLowestPoint(gate)
    local pos = vec3(gate.pos.x, gate.pos.y, gate.pos.z)
    local dir = vec3(gate.dir.x, gate.dir.y, gate.dir.z):normalized()
    local right = dir:cross(vec3(0, 0, 1))
    local halfWidth = (tonumber(gate.width) or 2) / 2
    local lowest
    for i = 0, GROUND_SNAP_SAMPLES - 1 do
        local t = (GROUND_SNAP_SAMPLES == 1) and 0 or ((i / (GROUND_SNAP_SAMPLES - 1)) * 2 - 1)
        local sample = pos + right * (halfWidth * t)
        local h = groundHeightAt(vec3(sample.x, sample.y, sample.z))
        if h and (not lowest or h < lowest) then lowest = h end
    end
    if lowest then gate.pos.z = lowest end
end

---@param kind "gate"|"start"
---@param index integer?
local function updateGizmo(kind, index)
    gizmo.hide()
    local item = index and (kind == "gate" and M.race.gates[index] or M.race.startPositions[index])
    if not item then return end
    gizmo.show({
        pos = vec3(item.pos.x, item.pos.y, item.pos.z),
        dir = vec3(item.dir.x, item.dir.y, item.dir.z),
        up = vec3(0, 0, 1),
        scales = vec3(1, 1, 1), -- width/height are sidebar sliders only, see below. The gizmo's
        -- own "scale" tool was tried first and reported broken (no way to verify the exact native
        -- per-frame scale-delta semantics without live access), so this reverted to slider-only
        -- rather than risk shipping another unreliable native-gizmo-dependent control.
    }, function(updated) ---@param updated GizmoObject
        if not parent or parent.activeEditor ~= M then return end
        item.pos = { x = updated.pos.x, y = updated.pos.y, z = updated.pos.z }
        -- Gates/starts only ever store a horizontal facing (dir.z always 0) and are always
        -- rendered/crossed assuming true world-up, but the native rotate gizmo exposes full
        -- 3-axis rotation with no documented way to restrict it to a single (yaw) ring, so a
        -- stray drag on the pitch/roll ring could otherwise tip the stored direction up/down or
        -- roll it. Constrained here instead, regardless of which ring was actually grabbed:
        -- discard any vertical component and re-normalize, so the stored dir can never end up
        -- anything but horizontal even if the widget itself was rotated off-axis.
        local flatDir = vec3(updated.dir.x, updated.dir.y, 0)
        if flatDir:length() < 1e-4 then
            -- Degenerate (rotated to point straight up/down): keep the previous horizontal
            -- facing rather than storing an undefined/zero-length direction.
            flatDir = vec3(item.dir.x, item.dir.y, 0)
        end
        flatDir = flatDir:normalized()
        item.dir = { x = flatDir.x, y = flatDir.y, z = 0 }
        markDirty()
        extensions.hook("onBJRaceMarkersRefresh")
    end, function() ---@param updated GizmoObject (unused, re-reads item.pos/dir directly)
        -- Fires once when the drag actually ends, not every frame during it, via gizmo.lua's
        -- onDragEnd. Auto-snap-to-ground toggle (position only), replacing the old manual button.
        local wasRotate = gizmo.tool == "rotate"
        if M.snapToGroundEnabled then
            if kind == "gate" then
                snapGateToLowestPoint(item)
            else
                item.pos.z = groundHeightAt(vec3(item.pos.x, item.pos.y, item.pos.z))
            end
        end
        if not M.snapToGroundEnabled and not wasRotate then return end
        -- Re-show: ground-snap just moved the position (if enabled), and/or a rotate drag's dir
        -- was flattened to horizontal in the onChange callback above. The widget itself doesn't
        -- know about that correction (the native gizmo just visually shows whatever 3D
        -- orientation was actually dragged to, pitch/roll included), so rebuilding it here from
        -- the corrected item.pos/dir snaps it back to visually match what's actually stored.
        pushUpdate()
        updateGizmo(kind, index)
        extensions.hook("onBJRaceMarkersRefresh")
    end)
end

--- same corner math as `raceMarkers.lua`'s `drawGate`/`drawGateHandles`, kept in exact sync
--- (non-normalized `right`) so hit-testing lines up with what's actually drawn on screen.
---@param gate BJRaceGate
---@return {pos:vec3, right:vec3, bottomLeft:vec3, bottomRight:vec3, topLeft:vec3, topRight:vec3}
local function gateFrame(gate)
    local pos = vec3(gate.pos.x, gate.pos.y, gate.pos.z)
    local dir = vec3(gate.dir.x, gate.dir.y, gate.dir.z):normalized()
    local up = vec3(0, 0, 1)
    local right = dir:cross(up)
    local halfWidth = gate.width / 2
    local bottomLeft = pos - right * halfWidth
    local bottomRight = pos + right * halfWidth
    return {
        pos = pos,
        right = right,
        bottomLeft = bottomLeft,
        bottomRight = bottomRight,
        topLeft = bottomLeft + up * gate.height,
        topRight = bottomRight + up * gate.height,
    }
end

--- closest-point-between-two-lines math (camera ray vs. a handle's one allowed axis of motion,
--- treated as an infinite line through its anchor), the same thing a real 3D gizmo drag would do
--- internally, done by hand here since these handles are custom-drawn geometry, not something
--- `worldEditorCppApi` can hit-test or drag for us.
---@param camPos vec3
---@param rayDir vec3 unit
---@param lineOrigin vec3
---@param lineDir vec3 unit
---@return number u signed distance along lineDir from lineOrigin to the point closest to the ray
local function closestLineParam(camPos, rayDir, lineOrigin, lineDir)
    local r = camPos - lineOrigin
    local b = rayDir:dot(lineDir)
    local f = lineDir:dot(r)
    local c = rayDir:dot(r)
    local denom = 1 - b * b
    if math.abs(denom) < 1e-5 then
        -- Ray is nearly parallel to the handle's axis. Fall back to projecting the camera
        -- position onto the line rather than dividing by ~0.
        return f
    end
    local t = (b * f - c) / denom
    if t < 0 then
        -- Closest approach would be behind the camera; project the camera position instead.
        return f
    end
    return (f - b * c) / denom
end

--- ray↔vertical-plane intersection, used only for the height-drag axis. `closestLineParam`
--- above degenerates when the ray is parallel to the target LINE, which for a purely vertical
--- line is exactly what happens as the player drags the mouse toward the top of the screen to
--- reach a greater height : the ray tilts closer to vertical, hits that same degenerate fallback
--- (returns the camera's own height, a low, roughly-fixed value, instead of continuing to track
--- the mouse), and height dragging hits a real, reproducible ceiling right around there. A live
--- report confirmed this exactly ("caps out... setting the slider higher, you can no longer use
--- the handle"). A ray↔PLANE intersection instead only degenerates when the ray is parallel to
--- the whole plane (near-horizontal AND aimed sideways along it), which normal upward dragging
--- never approaches, so this has no equivalent ceiling for realistic camera angles.
---@param camPos vec3
---@param rayDir vec3 unit
---@param anchor vec3 any point on the target vertical line (the u=0 reference)
---@return number? u height above anchor.z where the ray hits the vertical plane through anchor,
---nil if the ray is (near-)parallel to that plane or the hit is behind the camera
local function verticalDragParam(camPos, rayDir, anchor)
    local toCam = camPos - anchor
    toCam = vec3(toCam.x, toCam.y, 0)
    -- Plane faces the camera (horizontally) and contains the full vertical line through anchor.
    -- Falls back to an arbitrary horizontal normal only in the degenerate case of looking
    -- straight down/up the line itself, which shouldn't occur during normal handle dragging.
    local normal = toCam:length() > 1e-3 and toCam:normalized() or vec3(1, 0, 0)
    local denom = rayDir:dot(normal)
    if math.abs(denom) < 1e-5 then return nil end
    local t = (anchor - camPos):dot(normal) / denom
    if t < 0 then return nil end
    local hit = camPos + rayDir * t
    return hit.z - anchor.z
end

--- distance from a camera ray to a bounded segment (used only to hit-test a mousedown against a
--- handle's actual drawn extent ; the drag itself, once started, uses the unbounded
--- `closestLineParam` above so the handle can be dragged past its own current endpoint)
---@return number dist
local function closestRayToSegmentDistance(camPos, rayDir, segStart, segEnd)
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

local HANDLE_HIT_TOLERANCE = .5

---@param camPos vec3
---@param rayDir vec3
---@return "left"|"right"|"top"|nil
local function hitTestHandles(camPos, rayDir)
    if not M.race or not M.activeGateIndex then return nil end
    local gate = M.race.gates[M.activeGateIndex]
    if not gate then return nil end
    local f = gateFrame(gate)
    local candidates = {
        { kind = "left",  a = f.bottomLeft,  b = f.topLeft },
        { kind = "right", a = f.bottomRight, b = f.topRight },
        { kind = "top",   a = f.topLeft,     b = f.topRight },
    }
    local bestKind, bestDist = nil, HANDLE_HIT_TOLERANCE
    for _, c in ipairs(candidates) do
        local dist = closestRayToSegmentDistance(camPos, rayDir, c.a, c.b)
        if dist < bestDist then
            bestDist, bestKind = dist, c.kind
        end
    end
    return bestKind
end

---@param kind "left"|"right"|"top"
local function beginHandleDrag(kind)
    local gate = M.race and M.race.gates[M.activeGateIndex]
    if not gate then return end
    local f = gateFrame(gate)
    if kind == "left" then
        draggingHandle = { kind = "left", anchor = f.bottomRight, axis = f.right, min = 2, max = 30 }
    elseif kind == "right" then
        draggingHandle = { kind = "right", anchor = f.bottomLeft, axis = f.right, min = 2, max = 30 }
    else
        draggingHandle = {
            kind = "top", anchor = f.pos, axis = vec3(0, 0, 1), min = 1, max = 30,
            -- Only used by the mouse-delta fallback in updateHandleDrag below, for whenever the
            -- camera is looking too steeply upward/downward for the ray-plane math to stay
            -- well-conditioned.
            lastMouseY = nil,
        }
    end
end

---@param camPos vec3
---@param rayDir vec3
local function updateHandleDrag(camPos, rayDir)
    local gate = M.race and M.race.gates[M.activeGateIndex]
    if not gate or not draggingHandle then return end
    if draggingHandle.kind == "top" then
        local u = verticalDragParam(camPos, rayDir, draggingHandle.anchor)
        if u then
            gate.height = math.max(draggingHandle.min, math.min(draggingHandle.max, u))
            draggingHandle.lastMouseY = nil -- fresh reference next time the fallback kicks in
        else
            -- Ray-plane is inherently degenerate here, not just imprecise. Any vertical plane
            -- through the handle's axis necessarily contains a perfectly vertical ray, so looking
            -- straight up/down at the handle has no well-conditioned plane orientation to fall
            -- back on at all (confirmed by a live report: steep upward angles specifically).
            -- Falls back to raw mouse-Y screen-space delta instead of freezing. Not pixel-exact,
            -- but always produces some reasonable response regardless of camera angle. Scaled
            -- by distance to the handle so drag speed feels roughly consistent whether close up
            -- or far away.
            local mousePos = ui_imgui.GetMousePos()
            if draggingHandle.lastMouseY then
                -- Screen Y decreases upward, so this is positive when the mouse moves up.
                local deltaPixels = draggingHandle.lastMouseY - mousePos.y
                local dist = camPos:distance(draggingHandle.anchor)
                -- Empirical, not derived from exact FOV/viewport math (not available here), just
                -- scaled to feel roughly consistent across distances.
                local sensitivity = dist * 0.0025
                gate.height = math.max(draggingHandle.min, math.min(draggingHandle.max,
                    gate.height + deltaPixels * sensitivity))
            end
            draggingHandle.lastMouseY = mousePos.y
        end
    else
        local u = closestLineParam(camPos, rayDir, draggingHandle.anchor, draggingHandle.axis)
        local newWidth = math.max(draggingHandle.min, math.min(draggingHandle.max,
            draggingHandle.kind == "left" and -u or u))
        local half = draggingHandle.axis * (newWidth / 2)
        local newCenter = draggingHandle.kind == "left"
            and (draggingHandle.anchor - half)
            or (draggingHandle.anchor + half)
        gate.width = newWidth
        gate.pos.x, gate.pos.y = newCenter.x, newCenter.y
    end
    extensions.hook("onBJRaceMarkersRefresh")
    -- Throttled UI sync during the drag, same ~150ms convention the old scale-gizmo slider-sync
    -- used. The sliders are live-visible in the sidebar, unlike raw pos/dir which never display
    -- as numbers, so some sync (just not full per-frame rate) is worth it here.
    local now = GetCurrentTimeMillis()
    if now - lastHandlePush > 150 then
        lastHandlePush = now
        pushUpdate()
    end
end

local function endHandleDrag()
    if not draggingHandle then return end
    local kind = draggingHandle.kind
    draggingHandle = nil
    -- Ground-snapping the width handles too, per direct request. Previously only the sidebar
    -- slider (onSetGate) and the translate gizmo's own drag-end auto-snapped. Dragging a gate's
    -- edge directly in 3D is the more natural way to resize one and had no equivalent. Runs
    -- exactly once here, at mouse-release (this function is only ever called from onUpdate right
    -- after ui_imgui.IsMouseReleased fires, never mid-drag), not per-frame during the drag itself.
    -- groundHeightAt is a plain synchronous call with nothing to "finish" later, but sampling it
    -- every frame while the width is still actively changing would be wasteful and risks the
    -- sampled span not matching the width the drag actually settles on. left/right changes
    -- gate.width (what the scan spans); top (height) doesn't, so skip it there.
    if kind ~= "top" and M.snapToGroundEnabled then
        local gate = M.race and M.race.gates[M.activeGateIndex]
        if gate then snapGateToLowestPoint(gate) end
    end
    markDirty()
    pushUpdate()
    -- Left/right drags can shift gate.pos; re-sync the translate/rotate gizmo's transform to it.
    updateGizmo("gate", M.activeGateIndex)
    extensions.hook("onBJRaceMarkersRefresh")
end

-- camera-ray computation (hit-independent, unlike `cameraMouseRayCast`) lives in camera.lua's own
-- `mouseRay()` now, shared with pointListEditor.lua's world-click selection which needed the same
-- fix for the same reason ; see that function's own doc comment for the full rationale.

--- per-frame handle hit-test/drag polling, delegated from `activityEditor.lua`'s `onUpdate` the
--- same way `gizmo.lua`'s own per-frame drag polling works. These handles are plain custom
--- geometry though, not a real engine gizmo, so there's no native widget to ask "was this click on
--- you" ; raw `ui_imgui` mouse state + `camera.mouseRay()` stand in for that.
local function onUpdate()
    if updatePlacing() then
        draggingHandle = nil
        return
    end
    if not parent or parent.activeEditor ~= M or not M.race or not M.activeGateIndex then
        draggingHandle = nil
        return
    end

    if draggingHandle then
        if ui_imgui.IsMouseReleased(ui_imgui.MouseButton_Left) then
            endHandleDrag()
            return
        end
        local camPos, rayDir = camera.mouseRay()
        if camPos then
            updateHandleDrag(camPos, rayDir)
        end
        return
    end

    if ui_imgui.IsMouseClicked(ui_imgui.MouseButton_Left) then
        local camPos, rayDir = camera.mouseRay()
        if not camPos then return end
        local kind = hitTestHandles(camPos, rayDir)
        if kind then beginHandleDrag(kind) end
    end
end

---@param raceId integer?
--- Backfills every optional/defaults field a race might be missing with the same fallback value
--- the "new race" template below already uses, so sliders/toggles never start from nil/NaN.
--- Shared by onOpen's own "existing race" branch (a race authored before these fields existed,
--- e.g. via the old console test builder, or a stale cached copy opened before a server reload)
--- and onImportCode below (a share code from an older exporter, or a hand-edited one : see
--- onImportCode's own doc comment for why this can't be trusted to already be complete either).
--- Defensive only for the gates' own step/parents backfill specifically: the server's own
--- normalizeGateSteps already guarantees every gate has a real step/parents/isFinish for any race
--- that actually reached this client through the normal save/load path, this is a pure safety net.
---@param race BJRace
local function backfillRaceDefaults(race)
    race.defaults = race.defaults or {}
    race.defaults.laps = race.defaults.laps or 3
    if race.defaults.dnfEnabled == nil then race.defaults.dnfEnabled = true end
    race.defaults.dnfTimeout = race.defaults.dnfTimeout or 30
    race.defaults.rejoinGraceMinutes = race.defaults.rejoinGraceMinutes or 10
    if race.defaults.resetPenaltyEnabled == nil then race.defaults.resetPenaltyEnabled = false end
    race.defaults.resetPenaltySeconds = race.defaults.resetPenaltySeconds or 5
    if race.defaults.resetPenaltyMode ~= "time" then race.defaults.resetPenaltyMode = "hold" end
    if race.defaults.disableNodegrabber == nil then race.defaults.disableNodegrabber = true end
    if race.defaults.disableCameras == nil then race.defaults.disableCameras = true end
    if race.defaults.disableGravityChange == nil then race.defaults.disableGravityChange = true end
    if race.defaults.ghostOnCountdown == nil then race.defaults.ghostOnCountdown = true end
    if race.defaults.disableCollisions == nil then race.defaults.disableCollisions = false end
    if race.defaults.ghostBackmarkers == nil then race.defaults.ghostBackmarkers = false end
    if race.defaults.showGateNametags == nil then race.defaults.showGateNametags = false end
    if race.defaults.limitVisibleGates == nil then race.defaults.limitVisibleGates = true end
    race.defaults.visibleGateCount = race.defaults.visibleGateCount or 2
    if race.defaults.showGates == nil then race.defaults.showGates = true end
    if race.defaults.waypointBeams == nil then race.defaults.waypointBeams = true end
    if race.defaults.allowTuning == nil then race.defaults.allowTuning = true end
    if race.defaults.randomizeVehiclePool == nil then race.defaults.randomizeVehiclePool = false end
    -- mirrors services/races.lua's own RESPAWN_STRATEGIES values (no shared constant across the
    -- Lua/JS split here, same as this file's other hand-synced mirrors, e.g. deriveStepsFromParents)
    if not table.includes({ "all", "norespawn", "lastcheckpoint" }, race.defaults.respawnStrategy) then
        race.defaults.respawnStrategy = "lastcheckpoint"
    end
    if race.defaults.placementMode == nil then race.defaults.placementMode = "random" end
    if race.defaults.joinable == nil then race.defaults.joinable = false end
    race.defaults.gridTimeout = race.defaults.gridTimeout or 180
    race.defaults.gridReadyTimeout = race.defaults.gridReadyTimeout or 10
    race.defaults.countdown = race.defaults.countdown or 10
    if race.manualSectors == nil then race.manualSectors = false end
    race.sectorCount = race.sectorCount or 3
    if race.vehicleRestrictionMode == nil then race.vehicleRestrictionMode = "free" end
    if race.branchingEnabled == nil then race.branchingEnabled = false end
    if race.oneWayGates == nil then race.oneWayGates = false end
    if race.freeroam == nil then race.freeroam = false end
    if type(race.props) ~= "table" or not table.isArray(race.props) then race.props = {} end
    table.forEach(race.gates, function(g, i)
        if type(g.step) ~= "number" then g.step = i end
        if not table.isArray(g.parents) then g.parents = { i - 1 } end
    end)
end

local function onOpen(raceId)
    if not parent then return end
    if parent.activeEditor and parent.activeEditor ~= M then
        parent.activeEditor.onClose()
    end
    parent.activeEditor = M
    beamjoy_communications_ui.send("BJEditorChangeTool", gizmo.tool)
    disarmProp()

    M.id = raceId
    local existing = raceId and table.find(beamjoy_races.data, function(r) return r.id == raceId end)
    if existing then
        M.race = table.clone(existing)
        backfillRaceDefaults(M.race)
    else
        M.id = nil
        M.race = {
            name = "",
            mode = "grid",
            loopable = false,
            freeroam = false,
            distance = 0,
            sectorCount = 3,
            manualSectors = false,
            branchingEnabled = false,
            oneWayGates = false,
            vehicleRestrictionMode = "free",
            gates = {},
            startPositions = {},
            props = {},
            defaults = {
                respawnStrategy = "lastcheckpoint",
                joinable = false,
                gridTimeout = 180,
                gridReadyTimeout = 10,
                countdown = 10,
                -- Always concrete (not nil) so the laps slider never starts from NaN once
                -- "loopable" gets toggled on. Only actually applied server-side when
                -- race.loopable is true (sanitizeRace doesn't require it otherwise).
                laps = 3,
                dnfEnabled = true,
                dnfTimeout = 30,
                rejoinGraceMinutes = 10,
                resetPenaltyEnabled = false,
                resetPenaltySeconds = 5,
                resetPenaltyMode = "hold",
                disableNodegrabber = true,
                disableCameras = true,
                disableGravityChange = true,
                ghostOnCountdown = true,
                disableCollisions = false,
                ghostBackmarkers = false,
                showGateNametags = false,
                limitVisibleGates = true,
                visibleGateCount = 2,
                showGates = true,
                waypointBeams = true,
                allowTuning = true,
                randomizeVehiclePool = false,
            },
        }
    end
    M.activeGateIndex = nil
    M.activeStartIndex = nil
    M.activePropIndex, M.activePropPart = nil, nil
    M.dirty = false
    propsChanged()
    pushUpdate()
    pushActive()
    beamjoy_communications_ui.send("BJEditorPropCatalog", beamjoy_props.catalogForUI())
    M.savedRace = table.clone(M.race) -- after pushUpdate, so .distance is already computed
    beamjoy_communications_ui.send("BJEditorDirty", M.dirty)
    beamjoy_communications_ui.send("BJEditorRaceSnapToGround", M.snapToGroundEnabled)
    beamjoy_communications_ui.send("BJEditorRaceSnapMethod", M.snapMethod)
end

---@param partial table
local function onSetMeta(partial)
    if not M.race then return end
    table.assign(M.race, partial)
    markDirty()
    pushUpdate()
end

--- "single config" vehicle restriction capture, per direct request : the host sits in the exact
--- vehicle/config they want to require and clicks a button, rather than being handed a full
--- vehicle/config browser to build here from scratch. Unlike "pool" mode's own preset entries
--- (captured from the dedicated Vehicle Presets tab instead, see vehiclePresets.lua), this uses the
--- FULL parts/vars/paints snapshot (getFullConfig, same as saveCurrentVehicleForRespawn) rather
--- than just a saved-config reference. Per direct request, "single" mode force-spawns every
--- joining participant into this exact capture directly (raceRunner.lua), so nothing ever needs to
--- present it as a pickable option ; that's precisely what makes a fully custom (never saved)
--- setup capturable here, unlike a pool preset entry.
local function onCaptureVehicleRestriction()
    if not M.race then return end
    local mpVeh = beamjoy_vehicles.getCurrentOwn()
    if not mpVeh then
        toast.warn("You need to be in a vehicle to capture it", nil, 4)
        return
    end
    local full = beamjoy_vehicles.getFullConfig(mpVeh.veh)
    if not full then
        toast.warn("Couldn't read this vehicle's configuration", nil, 4)
        return
    end
    M.race.vehicleRestrictionModel = full.model
    M.race.vehicleRestrictionParts = full.parts or {}
    M.race.vehicleRestrictionVars = full.vars or {}
    M.race.vehicleRestrictionPaints = full.paints or {}
    M.race.vehicleRestrictionLabel = full.label
    markDirty()
    pushUpdate()
end

-- "pool" vehicle restriction used to capture its own inline list of vehicles right here, the same
-- way "single" above still does. Replaced with a reference to a shared, reusable BJVehiclePreset
-- (see services/vehiclePresets.lua / lua/ge/extensions/beamjoy/vehiclePresets.lua and their own
-- dedicated Config tab), so the same preset can be picked for multiple races (and, later, other
-- gamemodes) instead of every race re-capturing its own private copy. The race now just stores
-- vehicleRestrictionPoolPresetId (a plain integer), diffed/sent through the normal
-- BJEditorRaceSetMeta path alongside vehicleRestrictionMode. No dedicated add/remove handlers
-- needed here anymore.

---@param index integer
---@param partial table
local function onSetGate(index, partial)
    if not M.race or not M.race.gates[index] then return end
    -- Defensive coercion. bj-slider's typable number-box can hand back a string in this CEF build,
    -- and a stray string here silently breaks arithmetic against a native vec3 several calls
    -- downstream (raceMarkers.lua's drawGate). Catching it here is much easier than tracing an
    -- error that points at the vec3 math instead of this.
    if partial.width ~= nil then partial.width = tonumber(partial.width) or partial.width end
    if partial.height ~= nil then partial.height = tonumber(partial.height) or partial.height end
    -- Real bug fixed here, confirmed via a live console capture: removing "Start" from a gate's
    -- own [0, 6] parents echoed back as [6, 6] instead of [6], which threw a hard Angular
    -- "ngRepeat:dupes" error the instant that duplicate reached the "reachable from" chip list. A
    -- thrown error mid-digest leaves ng-repeat's rendering stuck on stale DOM, explaining the
    -- reported "Start disappeared from the parent list" symptom. `table.assign` (below) does a
    -- recursive per-key merge for any table-valued field, not a wholesale replace, so a shorter
    -- new `parents` array only overwrote the first N indices of the old, longer array, leaving
    -- its own stale trailing elements in place and silently duplicating whatever value was there.
    -- `parents` is always sent as a complete replacement array from the editor's own diff, never a
    -- sparse partial update, so it's replaced wholesale here before table.assign ever sees it,
    -- instead of being merged key-by-key into the old one.
    if partial.parents ~= nil then
        M.race.gates[index].parents = partial.parents
        partial.parents = nil
    end
    table.assign(M.race.gates[index], partial)
    -- Per direct request: a width change alone can change which patch of ground the gate's own
    -- span sits above, so re-snap automatically here too, not just at the end of a position drag.
    -- Otherwise widening/narrowing a gate on uneven terrain could leave it floating or clipped
    -- until the next unrelated drag re-triggered a snap. Runs after the assign above so it snaps
    -- against the gate's own already-updated width.
    if partial.width ~= nil and M.snapToGroundEnabled then
        snapGateToLowestPoint(M.race.gates[index])
    end
    markDirty()
    pushUpdate()
    extensions.hook("onBJRaceMarkersRefresh")
end

local function onSelectGate(index)
    if not M.race then return end
    if index then disarmProp() end
    draggingHandle = nil
    M.activeGateIndex = (index and M.race.gates[index]) and index or nil
    M.activeStartIndex = nil
    M.activePropIndex, M.activePropPart = nil, nil
    updateGizmo("gate", M.activeGateIndex)
    pushActive()
    pushUpdate() -- picks up anything a throttled scale-drag push may have missed
    extensions.hook("onBJRaceMarkersRefresh")
end

local function onSelectStart(index)
    if not M.race then return end
    if index then disarmProp() end
    draggingHandle = nil
    M.activeStartIndex = (index and M.race.startPositions[index]) and index or nil
    M.activeGateIndex = nil
    M.activePropIndex, M.activePropPart = nil, nil
    updateGizmo("start", M.activeStartIndex)
    pushActive()
    extensions.hook("onBJRaceMarkersRefresh")
end

--- click-to-select in world space, via the generic `onBJClick` hook (`inputs.lua`, fires on every
--- in-viewport click, previously used for vehicle/context-menu targeting, not yet for anything
--- editor-related). Our gates/starts are debug-drawn geometry (`shape.lua`), not real scene
--- objects, so `data.pos` (wherever a raycast against real world geometry actually hit, if
--- anything) was never actually usable here anyway ; this does a real ray↔plane intersection
--- against each gate's own authored plane instead, independent of what's actually rendered behind
--- it. Uses `camera.mouseRay()` rather than `data.pos` for the ray itself too now : real, confirmed
--- bug (same root cause as the height-handle drag fix above) : `data.pos` only exists when
--- `inputs.lua`'s own raycast hit something, so looking up at a gate with open sky behind it made
--- it entirely unselectable, not just imprecise, since this whole function never even ran.
---@param clickType "left"|"middle"|"right"
---@param data onBJClickData
local function onWorldClick(clickType, data)
    if not parent or parent.activeEditor ~= M or not M.race then return end
    if M.placing then
        if clickType == "right" then disarmProp(true) end
        return
    end
    if clickType ~= "left" then return end

    local camPos, rayDir = camera.mouseRay()
    if not camPos then return end

    ---@param pos {x:number,y:number,z:number}
    ---@param dir {x:number,y:number,z:number}
    ---@param width number
    ---@param height number
    ---@return number? t distance along the ray to the hit, only if inside the quad's bounds
    local function rayHitsQuad(pos, dir, width, height)
        local p = vec3(pos.x, pos.y, pos.z)
        local n = vec3(dir.x, dir.y, dir.z):normalized()
        local denom = rayDir:dot(n)
        if math.abs(denom) < 1e-5 then return nil end -- ray parallel to the gate's plane
        local t = (p - camPos):dot(n) / denom
        if t <= 0 then return nil end -- behind the camera
        local up = vec3(0, 0, 1)
        local right = n:cross(up)
        local d = (camPos + rayDir * t) - p
        local lx, lz = d:dot(right), d:dot(up)
        if math.abs(lx) <= width / 2 and lz >= 0 and lz <= height then
            return t
        end
        return nil
    end

    ---@param pos {x:number,y:number,z:number}
    ---@param radius number
    ---@return number? t distance along the ray to the closest approach, only if within radius
    local function rayHitsSphere(pos, radius)
        -- matches raceMarkers.lua's start-position sphere, drawn 0.5m above the stored position
        local p = vec3(pos.x, pos.y, pos.z) + vec3(0, 0, 0.5)
        local t = (p - camPos):dot(rayDir)
        if t <= 0 then return nil end
        local closest = camPos + rayDir * t
        if closest:distance(p) <= radius then return t end
        return nil
    end

    local bestT, bestKind, bestIndex = math.huge, nil, nil
    table.forEach(M.race.gates, function(g, i)
        local t = rayHitsQuad(g.pos, g.dir, g.width, g.height)
        if t and t < bestT then
            bestT, bestKind, bestIndex = t, "gate", i
        end
    end)
    -- Generous 1m click tolerance around the marker, since a start position has no width/height
    -- of its own to test against precisely.
    table.forEach(M.race.startPositions, function(s, i)
        local t = rayHitsSphere(s.pos, 1)
        if t and t < bestT then
            bestT, bestKind, bestIndex = t, "start", i
        end
    end)

    -- A hit on whatever's already selected is ignored, not reselected. That gate/start's own
    -- gizmo/handles are drawn right on top of it, so a click landing there is far more likely
    -- meant for those (grabbing a drag handle) than for re-clicking the thing already active. The
    -- menu/sidebar selection wins that conflict rather than this raycast fighting it. A hit on any
    -- other gate/start still switches selection to it, world-click included, even while something
    -- else is currently active.
    -- props : a single one round its base, a line by either end (selecting that end)
    local bestPart
    table.forEach(M.race.props or {}, function(p, i)
        if p.kind == "line" then
            for _, part in ipairs({ "a", "b" }) do
                local t = p[part] and rayHitsSphere(p[part], 1.2)
                if t and t < bestT then
                    bestT, bestKind, bestIndex, bestPart = t, "prop", i, part
                end
            end
            -- its middle (bend) handle, drawn on the selected line or a bent one
            local midPos = p.mid or (p.a and p.b and i == M.activePropIndex and
                { x = (p.a.x + p.b.x) / 2, y = (p.a.y + p.b.y) / 2, z = (p.a.z + p.b.z) / 2 })
            local tm = midPos and rayHitsSphere(midPos, 1.2)
            if tm and tm < bestT then
                bestT, bestKind, bestIndex, bestPart = tm, "prop", i, "mid"
            end
        elseif p.pos then
            local t = rayHitsSphere(p.pos, 1.5)
            if t and t < bestT then
                bestT, bestKind, bestIndex, bestPart = t, "prop", i, nil
            end
        end
    end)

    if bestKind == "gate" and bestIndex == M.activeGateIndex then return end
    if bestKind == "start" and bestIndex == M.activeStartIndex then return end
    if bestKind == "prop" and bestIndex == M.activePropIndex and bestPart == M.activePropPart then return end

    if bestKind == "gate" then
        onSelectGate(bestIndex)
    elseif bestKind == "start" then
        onSelectStart(bestIndex)
    elseif bestKind == "prop" then
        M.onSelectProp(bestIndex, bestPart)
    end
end

local function onCreateGate()
    if not M.race then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    local previousLastIndex = #M.race.gates
    table.insert(M.race.gates, {
        pos = { x = pos.x, y = pos.y, z = pos.z },
        dir = { x = dir.x, y = dir.y, z = dir.z },
        width = 6,
        height = 3,
        -- Sensible starting values, appended at the end. "Child of the previous last gate" (0 if
        -- this is the very first gate) matches what a plain linear append has always meant. The
        -- author can freely re-link via the parent/child controls once branchingEnabled is on.
        -- `step` itself is purely a transient placeholder here: pushUpdate() (called at the end of
        -- this function) immediately re-derives it from `parents` for any branching race (see
        -- deriveStepsFromParents), so this value only matters for a non-branching race, where it's
        -- never re-derived, matching sanitizeRace's own "step == array index" rule.
        step = previousLastIndex + 1,
        parents = { previousLastIndex },
        isFinish = false,
    })
    M.activeGateIndex = #M.race.gates
    M.activeStartIndex = nil
    M.activePropIndex, M.activePropPart = nil, nil
    updateGizmo("gate", M.activeGateIndex)
    markDirty()
    pushUpdate()
    pushActive()
    extensions.hook("onBJRaceMarkersRefresh")
end

local function onCreateStart()
    if not M.race then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    table.insert(M.race.startPositions, {
        pos = { x = pos.x, y = pos.y, z = pos.z },
        dir = { x = dir.x, y = dir.y, z = dir.z },
    })
    M.activeStartIndex = #M.race.startPositions
    M.activeGateIndex = nil
    M.activePropIndex, M.activePropPart = nil, nil
    updateGizmo("start", M.activeStartIndex)
    markDirty()
    pushUpdate()
    pushActive()
    extensions.hook("onBJRaceMarkersRefresh")
end

--- fixes up every gate's own `parents` references after a gate at `deletedIndex` is removed :
--- drops any now-dangling reference to that exact index, and shifts down every reference to an
--- index that came after it (everything above `deletedIndex` moved back by one array slot). Only
--- meaningful while `branchingEnabled` is on. Non-branching gates have their own `parents`
--- force-normalized to the plain implicit shape on next save regardless, so there's nothing
--- worth fixing up for them here.
---@param deletedIndex integer
local function remapParentsAfterDelete(deletedIndex)
    if not M.race.branchingEnabled then return end
    table.forEach(M.race.gates, function(g)
        if not table.isArray(g.parents) then return end
        local remapped = {}
        for _, p in ipairs(g.parents) do
            if p == deletedIndex then
                -- dangling reference to the now-deleted gate: dropped
            elseif p > deletedIndex then
                table.insert(remapped, p - 1)
            else
                table.insert(remapped, p)
            end
        end
        g.parents = remapped
    end)
end

local function onDeleteGate(index)
    if not M.race or not M.race.gates[index] then return end
    draggingHandle = nil
    table.remove(M.race.gates, index)
    remapParentsAfterDelete(index)
    M.activeGateIndex = nil
    updateGizmo("gate", nil)
    markDirty()
    pushUpdate()
    pushActive()
    extensions.hook("onBJRaceMarkersRefresh")
end

local function onDeleteStart(index)
    if not M.race or not M.race.startPositions[index] then return end
    table.remove(M.race.startPositions, index)
    M.activeStartIndex = nil
    updateGizmo("start", nil)
    markDirty()
    pushUpdate()
    pushActive()
    extensions.hook("onBJRaceMarkersRefresh")
end

---@param fromIndex integer
---@param toIndex integer
local function onReorderGates(fromIndex, toIndex)
    if not M.race or not M.race.gates[fromIndex] then return end

    -- Computed before mutating the array, so `parents` references (which point at old array
    -- positions) can be remapped through the exact same permutation the reorder applies. Only
    -- meaningful while branchingEnabled is on, same reasoning as remapParentsAfterDelete above.
    local oldToNew
    if M.race.branchingEnabled then
        local oldOrder = {}
        for i = 1, #M.race.gates do oldOrder[i] = i end
        local movedOld = table.remove(oldOrder, fromIndex)
        local finalIndexForOrder = toIndex > fromIndex and (toIndex - 1) or toIndex
        finalIndexForOrder = math.max(1, math.min(finalIndexForOrder, #oldOrder + 1))
        table.insert(oldOrder, finalIndexForOrder, movedOld)
        oldToNew = {}
        for newPos, oldIdx in ipairs(oldOrder) do oldToNew[oldIdx] = newPos end
    end

    local gate = table.remove(M.race.gates, fromIndex)
    local finalIndex = toIndex > fromIndex and (toIndex - 1) or toIndex
    finalIndex = math.max(1, math.min(finalIndex, #M.race.gates + 1))
    table.insert(M.race.gates, finalIndex, gate)

    if oldToNew then
        table.forEach(M.race.gates, function(g)
            if not table.isArray(g.parents) then return end
            g.parents = table.map(g.parents, function(p)
                return p == 0 and 0 or (oldToNew[p] or p)
            end)
        end)
    end

    M.activeGateIndex = nil
    updateGizmo("gate", nil)
    markDirty()
    pushUpdate()
    pushActive()
    extensions.hook("onBJRaceMarkersRefresh")
end

--- flips the whole gate sequence : reverses gate order and flips each gate's own facing (negated
--- horizontal dir, matching the "always horizontal" invariant the rotate gizmo's own onChange
--- already enforces elsewhere in this file) so driving through in the new order faces the right
--- way at every gate. For a loopable race the new gate 1 (the old last gate) automatically becomes
--- the start/finish line via gateRole's existing index-based convention, no separate "which gate
--- is the start" flag to update. Per-gate flags (sector, width/height) travel with their own
--- gate object unchanged, just reordered ; a manually-flagged sector boundary keeps marking the
--- same physical gate, though its meaning relative to the new direction of travel may need manual
--- re-checking afterward. Start positions are deliberately left untouched: where the grid should
--- actually sit for the reversed direction is a track-specific authoring decision this can't safely
--- guess, so the UI flags it as something to double check rather than silently repositioning them.
local function onReverseGates()
    -- Deliberately unsupported for a branching race: correctly reversing a route with real forks
    -- means flipping every `parents` edge's own direction too (an old parent becomes a child and
    -- vice versa), a nontrivial graph transform out of scope for this flat, minimal branching
    -- pass. The Angular side hides/disables the button whenever branchingEnabled is on; this is
    -- just the matching Lua-side backstop in case it's ever called anyway.
    if not M.race or #M.race.gates < 2 or M.race.branchingEnabled then return end
    local gates = M.race.gates
    local reversed = {}
    if M.race.loopable then
        -- A loopable race always treats gate 1 as the fixed start/finish line (see
        -- raceMarkers.lua's own gateRole convention, and the "make the start/finish line explicit"
        -- round). Reversing the direction of travel around the loop should keep racing through
        -- that same physical gate first, not relocate the start/finish line to wherever the old
        -- last gate was. Gate 1 stays in place; every other gate (2..N) reverses order after it,
        -- per direct report ("reverse gates should keep the same start/finish line").
        table.insert(reversed, gates[1])
        for i = #gates, 2, -1 do
            table.insert(reversed, gates[i])
        end
    else
        -- Point-to-point: reversing genuinely means starting where you used to finish and vice
        -- versa, so a full reversal (including which gate is index 1) is exactly what's wanted.
        for i = #gates, 1, -1 do
            table.insert(reversed, gates[i])
        end
    end
    -- Every gate is now approached from the opposite direction regardless of loopable, so its own
    -- facing needs to flip too, including gate 1 on a loopable race, which stays in the same spot
    -- but is now crossed the other way.
    for _, gate in ipairs(reversed) do
        gate.dir.x = -gate.dir.x
        gate.dir.y = -gate.dir.y
    end
    M.race.gates = reversed
    M.activeGateIndex = nil
    updateGizmo("gate", nil)
    markDirty()
    pushUpdate()
    pushActive()
    extensions.hook("onBJRaceMarkersRefresh")
end

---@param state boolean
local function onSetSnapToGround(state)
    M.snapToGroundEnabled = state == true
    beamjoy_communications_ui.send("BJEditorRaceSnapToGround", M.snapToGroundEnabled)
end

---@param method "terrain"|"raycast"
local function onSetSnapMethod(method)
    M.snapMethod = method == "raycast" and "raycast" or "terrain"
    beamjoy_communications_ui.send("BJEditorRaceSnapMethod", M.snapMethod)
end

---@param kind "gate"|"start"
---@param index integer
local function onSetToVehiclePosition(kind, index)
    local item = kind == "gate" and M.race and M.race.gates[index]
        or kind == "start" and M.race and M.race.startPositions[index]
    if not item then return end
    local pos, dir = currentPositionDirection()
    if not pos then return end
    item.pos = { x = pos.x, y = pos.y, z = pos.z }
    item.dir = { x = dir.x, y = dir.y, z = dir.z }
    markDirty()
    pushUpdate()
    updateGizmo(kind, index)
    extensions.hook("onBJRaceMarkersRefresh")
end

local function onSetGateToVehicle(index) onSetToVehiclePosition("gate", index) end
local function onSetStartToVehicle(index) onSetToVehiclePosition("start", index) end

---@param kind "gate"|"start"
---@param index integer
local function onTeleportTo(kind, index)
    local item = kind == "gate" and M.race and M.race.gates[index]
        or kind == "start" and M.race and M.race.startPositions[index]
    if not item then return end
    local current = beamjoy_vehicles.getCurrentOwn()
    if not current then return end
    -- Gates/starts only ever store `dir`, never `up` (matches raceRunner.lua's own
    -- teleport-to-start-position call). World up is always the right assumption; both are
    -- rendered as vertical geometry regardless.
    beamjoy_vehicles.setVehiclePositionRotation(current.veh,
        vec3(item.pos.x, item.pos.y, item.pos.z),
        vec3(item.dir.x, item.dir.y, item.dir.z),
        vec3(0, 0, 1))
end

local function onTeleportToGate(index) onTeleportTo("gate", index) end
local function onTeleportToStart(index) onTeleportTo("start", index) end

---@param kind "gate"|"start"
---@param index integer
local function onReset(kind, index)
    if not M.race or not M.savedRace then return end
    local saved = kind == "gate" and M.savedRace.gates[index] or M.savedRace.startPositions[index]
    local current = kind == "gate" and M.race.gates[index] or M.race.startPositions[index]
    -- No saved counterpart (e.g. a gate created since the last save): nothing to revert to.
    -- Delete is the right tool for undoing that instead.
    if not saved or not current then return end
    current.pos = table.clone(saved.pos)
    current.dir = table.clone(saved.dir)
    if kind == "gate" then
        current.width = saved.width
        current.height = saved.height
    end
    refreshDirty()
    pushUpdate()
    updateGizmo(kind, index)
    extensions.hook("onBJRaceMarkersRefresh")
end

local function onResetGate(index) onReset("gate", index) end
local function onResetStart(index) onReset("start", index) end

local function onSave()
    if not M.race then return end
    local race = table.clone(M.race)
    race.id = M.id
    beamjoy_communications.send("raceSave", race)
    -- List refresh is automatic. A successful save triggers a `sendCache` push to every connected
    -- player (including the sender), which `beamjoy_races.retrieveCache` turns back into a
    -- `BJEditorRaceList` broadcast on its own. No explicit re-request needed here.
    beamjoy_communications.addOneUseHandler("raceSaved", function(status, raceId)
        if status then
            M.id = raceId
            M.dirty = false
            M.savedRace = table.clone(M.race)
            beamjoy_communications_ui.send("BJEditorDirty", M.dirty)
        end
    end, 5000)
end

--- saves the currently-open race (including any unsaved in-progress edits) as a brand-new race
--- under an explicit player-chosen name, and switches this editor over to it, so it can be
--- immediately repositioned/renamed further without touching the original. Replaces the old
--- "Duplicate" flow, which auto-appended " (copy)" with no uniqueness check of its own. A name
--- collision (e.g. duplicating twice) hit the server's existing duplicate-name rejection in
--- `raceSave`/`sanitizeRace` with no visible link back to the click, the likely explanation for
--- it being reported as "doesn't function." Angular already prompted for and confirmed the name
--- before sending this ; a collision here still surfaces as the same server-side toast, just now
--- clearly tied to the name the player actually typed.
---@param name string
local function onSaveAsNew(name)
    if not M.race or not name or name == "" then return end
    local copy = table.clone(M.race)
    copy.id = nil
    copy.name = name
    -- Leaderboard is never actually present client-side to begin with (server strips it from the
    -- general race cache broadcast, see races.lua's onBJRequestCache), but explicit here anyway:
    -- a new race hasn't earned the original's times.
    copy.leaderboard = nil
    beamjoy_communications.send("raceSave", copy)
    beamjoy_communications.addOneUseHandler("raceSaved", function(status, raceId)
        if not status then return end
        -- Switch straight to editing the new copy, without waiting on a `sendCache` round-trip
        -- to find it in `beamjoy_races.data` first; we already have its exact content right here.
        M.id = raceId
        M.race = copy
        M.activeGateIndex = nil
        M.activeStartIndex = nil
        M.activePropIndex, M.activePropPart = nil, nil
        M.dirty = false
        gizmo.hide()
        propsChanged()
        pushUpdate()
        pushActive()
        M.savedRace = table.clone(M.race)
        beamjoy_communications_ui.send("BJEditorDirty", M.dirty)
        beamjoy_communications_ui.send("BJEditorRaceSavedAsNew", raceId)
    end, 5000)
end

--- Race Share Codes (see TODO.md's own "Race share codes" plan for the full design). Angular
--- decodes the pasted code entirely client-side (gzip+base64, the `raceShare*` module-scope
--- helpers at the top of windows/config/races/editor/app.js) and hands the plain decoded table
--- straight to this handler ; nothing here trusts it any further than a brand-new race authored
--- from scratch would be, it still goes through the exact same `sanitizeRace` gate at actual Save
--- time (see raceSave, services/races.lua) before anything persists here. Always opened as a NEW
--- race (M.id stays nil regardless of what the payload contains) : id/author/leaderboard never
--- travel in a code to begin with (see that file's own raceShareStrip()), so there's no path here
--- that could overwrite or claim authorship of an existing race just by importing a code.
--- Replaces whatever the editor currently holds outright, same as opening a different race would
--- (Angular already confirms with the player before calling this if there was anything worth
--- losing, see that same file's own importShareCode()).
---@param race table decoded share-code payload : name/mode/loopable/sectorCount/manualSectors/
---branchingEnabled/gates/startPositions/defaults, the same shape strip() produces. May be missing
---any field a race exported by an older version of this feature (or a hand-edited code) would
---also lack ; backfillRaceDefaults covers exactly that, same as it already does for a legacy save.
local function onImportCode(race)
    if not M.race or type(race) ~= "table" then return end
    if not table.isArray(race.gates) or not table.isArray(race.startPositions) then
        toast.warn("Invalid race code", nil, 4)
        return
    end

    M.id = nil
    M.race = {
        name = type(race.name) == "string" and race.name or "",
        mode = type(race.mode) == "string" and race.mode or "grid",
        loopable = race.loopable == true,
        freeroam = race.freeroam == true,
        distance = 0, -- recomputed by pushUpdate below from the real imported gate positions
        sectorCount = race.sectorCount,
        manualSectors = race.manualSectors,
        branchingEnabled = race.branchingEnabled,
        oneWayGates = race.oneWayGates,
        vehicleRestrictionMode = nil, -- never travels in a code (an author-local capture/preset ref)
        gates = race.gates,
        startPositions = race.startPositions,
        props = race.props,
        defaults = race.defaults,
    }
    backfillRaceDefaults(M.race)

    M.activeGateIndex = nil
    M.activeStartIndex = nil
    M.activePropIndex, M.activePropPart = nil, nil
    updateGizmo("gate", nil) -- hides the gizmo ; nothing from the old selection still applies
    markDirty()
    propsChanged()
    pushUpdate()
    pushActive()
end

-- PROPS ----------------------------------------------------------------------------------------
-- race.props (see beamjoy_props for the entries and how they're spawned). Placed with the mouse
-- from the props drawer (PLACING below), turned by the mesh's own yaw so a barrier's long side
-- follows the way it faces, then moved with the gizmo : a single prop as a whole (rotation in
-- every axis), a line by either of its two ends (translation only : a line's props face along it,
-- turned by its own yaw)

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

--- a line's ground heights, one per prop (beamjoy_props.linePlacements), measured here so a
--- running race never has to : the editor's preview isn't in the static collision (see
--- beamjoy_props), so the probes can't land on the line's own props
---@param line table
local function updateLineHeights(line)
    if line.followGround == false then
        line.heights = nil
        return
    end
    local straight = beamjoy_props.linePlacements({ a = line.a, b = line.b, mid = line.mid, count = line.count,
        followGround = false })
    line.heights = table.map(straight, function(p) return round3(groundHeightAt(p.pos)) end)
end

---@param extra integer
---@return boolean room for that many more props
local function propBudget(extra)
    if beamjoy_props.total(M.race.props) + extra <= beamjoy_props.MAX_PROPS then return true end
    toast.warn(string.format("A race can hold up to %d props", beamjoy_props.MAX_PROPS), nil, 4)
    return false
end

local updatePropGizmo
---@param index integer?
---@param part "a"|"b"|nil a line's end (its first by default)
function M.onSelectProp(index, part)
    if not M.race then return end
    if index then disarmProp() end
    draggingHandle = nil
    local prop = index and M.race.props[index]
    M.activePropIndex = prop and index or nil
    M.activePropPart = prop and prop.kind == "line" and ((part == "b" or part == "mid") and part or "a") or nil
    M.activeGateIndex, M.activeStartIndex = nil, nil
    updatePropGizmo()
    pushActive()
    propsChanged()
end

updatePropGizmo = function()
    gizmo.hide()
    local prop = M.race and M.activePropIndex and M.race.props[M.activePropIndex]
    if not prop then return end
    local up = vec3(0, 0, 1)
    if prop.kind == "line" and M.activePropPart == "mid" then
        -- the middle : where the curve passes halfway (the straight line's middle until it's bent)
        local a, b = toVec(prop.a), toVec(prop.b)
        gizmo.show({
            pos = toVec(prop.mid) or (a + b) * .5,
            dir = flatDir(b - a),
            up = up,
            scales = vec3(1, 1, 1),
        }, function(updated) ---@param updated GizmoObject
            if not parent or parent.activeEditor ~= M then return end
            prop.mid = xyz(updated.pos)
            prop.heights = nil -- measured again once dropped
            markDirty()
            propsChanged()
        end, function()
            if prop.mid and M.snapToGroundEnabled then
                prop.mid.z = groundHeightAt(toVec(prop.mid))
            end
            updateLineHeights(prop)
            pushUpdate()
            updatePropGizmo()
            propsChanged()
        end)
    elseif prop.kind == "line" then
        local part = M.activePropPart == "b" and "b" or "a"
        local other = part == "a" and "b" or "a"
        local pos = toVec(prop[part])
        gizmo.show({
            pos = pos,
            dir = flatDir(toVec(prop[other]) - pos),
            up = up,
            scales = vec3(1, 1, 1),
        }, function(updated) ---@param updated GizmoObject
            if not parent or parent.activeEditor ~= M then return end
            -- an end only moves : the line's props face along it whatever the gizmo was turned to
            prop[part] = xyz(updated.pos)
            prop.heights = nil -- straight while dragging, measured again once dropped
            markDirty()
            propsChanged()
        end, function()
            if M.snapToGroundEnabled then
                prop[part].z = groundHeightAt(toVec(prop[part]))
            end
            updateLineHeights(prop)
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
            if not parent or parent.activeEditor ~= M then return end
            prop.pos = xyz(updated.pos)
            prop.dir = xyz(updated.dir)
            prop.up = xyz(updated.up)
            markDirty()
            propsChanged()
        end, function()
            if M.snapToGroundEnabled and gizmo.tool ~= "rotate" then
                prop.pos.z = groundHeightAt(toVec(prop.pos))
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
    at = vec3(at.x, at.y, M.snapToGroundEnabled and groundHeightAt(at) or pos.z)
    return at, facing
end

---@param prop table
---@param unselected boolean? added as it is, nothing selected (the props drawer placing on)
local function addProp(prop, unselected)
    table.insert(M.race.props, prop)
    if unselected then
        markDirty()
        pushUpdate()
        propsChanged()
        return
    end
    M.activePropIndex = #M.race.props
    M.activePropPart = prop.kind == "line" and "b" or nil
    M.activeGateIndex, M.activeStartIndex = nil, nil
    updatePropGizmo()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

---@param index integer
---@param partial table scale / count / yaw / followGround
local function onSetProp(index, partial)
    local prop = M.race and M.race.props[index]
    if not prop or type(partial) ~= "table" then return end
    if partial.scale ~= nil then
        prop.scale = math.max(.1, math.min(tonumber(partial.scale) or 1, 10))
    end
    if prop.kind == "line" then
        if partial.count ~= nil then
            local others = beamjoy_props.total(M.race.props) - beamjoy_props.weight(prop)
            prop.count = math.max(1, math.min(math.floor(tonumber(partial.count) or prop.count),
                beamjoy_props.MAX_PROPS - others))
        end
        if partial.yaw ~= nil then
            prop.yaw = ((tonumber(partial.yaw) or 0) + 180) % 360 - 180
        end
        if partial.followGround ~= nil then prop.followGround = partial.followGround == true end
        if partial.count ~= nil or partial.followGround ~= nil then updateLineHeights(prop) end
    end
    markDirty()
    pushUpdate()
    propsChanged()
end

---@param index integer
local function onDeleteProp(index)
    if not M.race or not M.race.props[index] then return end
    table.remove(M.race.props, index)
    M.activePropIndex, M.activePropPart = nil, nil
    gizmo.hide()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

--- a copy beside the original : a single prop one of its own lengths to its right, a line 4 m to
--- the right of its direction
---@param index integer
local function onDuplicateProp(index)
    local prop = M.race and M.race.props[index]
    if not prop or not propBudget(beamjoy_props.weight(prop)) then return end
    local copy = table.clone(prop)
    if prop.kind == "line" then
        local a, b = toVec(prop.a), toVec(prop.b)
        local offset = flatDir(b - a):cross(vec3(0, 0, 1)) * 4
        local na, nb = a + offset, b + offset
        if M.snapToGroundEnabled then
            na = vec3(na.x, na.y, groundHeightAt(na))
            nb = vec3(nb.x, nb.y, groundHeightAt(nb))
        end
        copy.a, copy.b = xyz(na), xyz(nb)
        if prop.mid then
            local nm = toVec(prop.mid) + offset
            if M.snapToGroundEnabled then nm = vec3(nm.x, nm.y, groundHeightAt(nm)) end
            copy.mid = xyz(nm)
        end
        updateLineHeights(copy)
    else
        local dir = flatDir(toVec(prop.dir))
        local pos = toVec(prop.pos) + dir:cross(vec3(0, 0, 1)) * (beamjoy_props.tuning(prop.shape).length * (prop.scale or 1))
        if M.snapToGroundEnabled then pos = vec3(pos.x, pos.y, groundHeightAt(pos)) end
        copy.pos = xyz(pos)
    end
    addProp(copy)
end

--- a bent line goes straight again (its middle handle dropped)
---@param index integer
local function onStraightenPropLine(index)
    local line = M.race and M.race.props[index]
    if not line or line.kind ~= "line" or not line.mid then return end
    line.mid = nil
    updateLineHeights(line)
    updatePropGizmo()
    markDirty()
    pushUpdate()
    propsChanged()
end

--- a line becomes its props, one by one, each where it was
---@param index integer
local function onSplitPropLine(index)
    local line = M.race and M.race.props[index]
    if not line or line.kind ~= "line" then return end
    local singles = table.map(beamjoy_props.linePlacements(line), function(p)
        return {
            kind = "static",
            shape = line.shape,
            pos = xyz(p.pos),
            dir = xyz(p.dir),
            up = xyz(p.up),
            scale = line.scale or 1,
        }
    end)
    table.remove(M.race.props, index)
    for i, single in ipairs(singles) do
        table.insert(M.race.props, index + i - 1, single)
    end
    M.activePropIndex = #singles > 0 and index or nil
    M.activePropPart = nil
    updatePropGizmo()
    markDirty()
    pushUpdate()
    pushActive()
    propsChanged()
end

--- your car a few metres short of the prop (a line's first end), facing it
---@param index integer
local function onTeleportToProp(index)
    local prop = M.race and M.race.props[index]
    local current = beamjoy_vehicles.getCurrentOwn()
    if not prop or not current then return end
    local target, facing
    if prop.kind == "line" then
        target = toVec(prop.a)
        facing = flatDir(toVec(prop.b) - target)
    else
        target = toVec(prop.pos)
        facing = beamjoy_props.turn(flatDir(toVec(prop.dir)), -beamjoy_props.tuning(prop.shape).yaw)
    end
    beamjoy_vehicles.setVehiclePositionRotation(current.veh, target - facing * (PROP_PLACE_AHEAD + 2), facing,
        vec3(0, 0, 1))
end

--- a single prop moves to where a new one would go (ahead of you, facing your way)
---@param index integer
local function onSetPropToVehicle(index)
    local prop = M.race and M.race.props[index]
    if not prop or prop.kind == "line" then return end
    local at, facing = propPlacement()
    if not at then return end
    prop.pos = xyz(at)
    prop.dir = xyz(beamjoy_props.turn(facing, beamjoy_props.tuning(prop.shape).yaw))
    prop.up = { x = 0, y = 0, z = 1 }
    updatePropGizmo()
    markDirty()
    pushUpdate()
    propsChanged()
end

-- PLACING --------------------------------------------------------------------------------------
-- The props drawer's armed prop (direct request) : a ghost of it follows the mouse over the world ;
-- a click places one there, a click-and-drag lays a line of them. The wheel turns it (or, while
-- dragging, spaces the line out), Shift on release keeps it armed for the next one, a right-click
-- or Esc stops. Per frame : one ray against the static collision (castRayStatic : neither the ghost
-- nor the editor's preview props are in it, see beamjoy_props) and the ghost moved (one
-- no-collision TSStatic, a line's worth while dragging).

local PLACE_RAY_DISTANCE = 1000
-- a shorter drag is a click : one prop
local PLACE_LINE_MIN = 1.5
local PLACE_LINE_MAX_COUNT = 60
local PLACE_ROTATE_STEP = 15
local PLACE_SPACING_MIN, PLACE_SPACING_MAX = .5, 4
local GHOST_SET = "editorGhost"

---@type {shape: string, rot: number, spacing: number, hit: vec3?, facing: vec3?, drag: {a: vec3, b: vec3, facing: vec3}?}?
M.placing = nil
--- the drawer's "Keep placing" (direct request) : a prop stays armed after each one placed, as with
--- Shift held, until it's turned off or placing stops. The player's own choice, kept by the drawer
M.keepPlacing = false
local lastPlacingPush = nil

---@param v number
---@return number
local function round2(v) return math.floor(v * 100 + .5) / 100 end

---@param degrees number
---@return number in -180..180
local function wrapYaw(degrees) return (degrees + 180) % 360 - 180 end

--- a mesh's own lift, kept on the entry for one the catalog doesn't tune (its lift was measured
--- here, so every player stands it the same) ; nil otherwise
---@param shape string
---@param tuning table beamjoy_props.tuning(shape)
---@return number?
local function entryLift(shape, tuning)
    if beamjoy_props.catalogForShape(shape) or math.abs(tuning.lift) < 1e-3 then return nil end
    return round3(tuning.lift)
end

--- what a release would place now : one entry (a single prop or a line), with the line's length
---@return table? entry, number meters
local function placingEntry()
    local p = M.placing
    -- the line being dragged holds fewer props than its length asks for : the race is nearly full
    p.capped = false
    local t = beamjoy_props.tuning(p.shape)
    local yaw = wrapYaw(t.yaw + p.rot)
    local lift = entryLift(p.shape, t)
    local d = p.drag
    if d then
        local meters = d.a:distance(d.b)
        local room = beamjoy_props.MAX_PROPS - beamjoy_props.total(M.race.props)
        if meters >= PLACE_LINE_MIN then
            p.capped = room < 2 or
                math.min(math.floor(meters / (t.length * p.spacing) + .5) + 1, PLACE_LINE_MAX_COUNT) > room
        end
        if meters >= PLACE_LINE_MIN and room >= 2 then
            local count = math.floor(meters / (t.length * p.spacing) + .5) + 1
            local line = {
                kind = "line",
                shape = p.shape,
                a = xyz(d.a),
                b = xyz(d.b),
                count = math.max(2, math.min(count, PLACE_LINE_MAX_COUNT, room)),
                yaw = yaw,
                scale = 1,
                followGround = true,
                lift = lift,
            }
            updateLineHeights(line)
            return line, meters
        end
    end
    local at, facing = d and d.a or p.hit, d and d.facing or p.facing
    if not at or not facing then return nil, 0 end
    return {
        kind = "static",
        shape = p.shape,
        pos = xyz(at),
        dir = xyz(beamjoy_props.turn(facing, yaw)),
        up = { x = 0, y = 0, z = 1 },
        scale = 1,
        lift = lift,
    }, 0
end

-- an invisible mesh's ghost is drawn as the panel the editor shows for a placed one
-- (raceMarkers.lua drawPropOverlays, same colour), every frame since it follows the mouse
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
        dragging = p.drag ~= nil,
        count = entry and beamjoy_props.weight(entry) or 0,
        meters = math.floor((meters or 0) + .5),
        rot = p.rot,
        spacing = round2(p.spacing),
        overWorld = p.hit ~= nil,
        capped = p.drag ~= nil and p.capped == true,
        keepPlacing = M.keepPlacing,
    } or { armed = false }
    local key = p and string.format("%s|%s|%d|%d|%d|%.2f|%s|%s|%s", p.shape, tostring(state.dragging), state.count,
        state.meters, state.rot, state.spacing, tostring(state.overWorld), tostring(state.capped),
        tostring(state.keepPlacing)) or "off"
    if key == lastPlacingPush then return end
    lastPlacingPush = key
    beamjoy_communications_ui.send("BJEditorRacePlacing", state)
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

--- the drawer arms a mesh : nothing stays selected while placing (the gizmo would take the clicks)
---@param shape string
local function onArmProp(shape)
    if not M.race or not parent or parent.activeEditor ~= M then return end
    if not beamjoy_propPicker.isPlaceable(shape) then return end
    if not propBudget(1) then return disarmProp() end
    -- measured now, so the ghost already stands the way it'll be placed
    beamjoy_propPicker.measure(shape)
    local rot = M.placing and M.placing.shape == shape and M.placing.rot or 0
    M.placing = { shape = shape, rot = rot, spacing = 1 }
    draggingHandle = nil
    if M.activeGateIndex or M.activeStartIndex or M.activePropIndex then
        M.activeGateIndex, M.activeStartIndex = nil, nil
        M.activePropIndex, M.activePropPart = nil, nil
        gizmo.hide()
        pushActive()
        extensions.hook("onBJRaceMarkersRefresh")
    end
    pushPlacing()
end

--- what's being placed goes into the race ; armed still with Shift held, else the new prop is
--- selected (its gizmo for fine adjustments)
local function placeNow()
    local entry = placingEntry()
    M.placing.drag = nil
    if not entry or not propBudget(beamjoy_props.weight(entry)) then return end
    local io = ui_imgui.GetIO()
    -- the drawer's "Keep placing" (on until turned off), or Shift held for this one
    local keepArmed = M.keepPlacing or (io ~= nil and io.KeyShift == true)
    if keepArmed then
        addProp(entry, true)
        if beamjoy_props.total(M.race.props) >= beamjoy_props.MAX_PROPS then disarmProp() end
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
    if not parent or parent.activeEditor ~= M or not M.race then
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
            if p.drag then
                p.spacing = math.max(PLACE_SPACING_MIN, math.min(p.spacing * (wheel > 0 and 1.1 or 1 / 1.1),
                    PLACE_SPACING_MAX))
            else
                p.rot = (p.rot + (wheel > 0 and 1 or -1) * PLACE_ROTATE_STEP) % 360
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
-- binding it doesn't fire while a text box has the keyboard (the race's name...), and it can be
-- rebound in the game's controls

local function onBJEditorDeleteKey()
    if not parent or parent.activeEditor ~= M or not M.race or not M.activePropIndex then return end
    onDeleteProp(M.activePropIndex)
end

--- a placed prop takes another mesh (the drawer's "Swap mesh"), kept where it is and turned by the
--- difference between the two meshes' own facings
---@param index integer
---@param shape string
local function onSwapPropShape(index, shape)
    local prop = M.race and M.race.props[index]
    if not prop or prop.shape == shape or not beamjoy_propPicker.isPlaceable(shape) then return end
    beamjoy_propPicker.measure(prop.shape)
    beamjoy_propPicker.measure(shape)
    local before, after = beamjoy_props.tuning(prop.shape), beamjoy_props.tuning(shape)
    local delta = after.yaw - before.yaw
    prop.shape = shape
    if prop.kind == "line" then
        prop.yaw = wrapYaw((tonumber(prop.yaw) or 0) + delta)
    elseif prop.dir then
        prop.dir = xyz(beamjoy_props.turn(toVec(prop.dir), delta))
    end
    prop.lift = entryLift(shape, after)
    updatePropGizmo()
    markDirty()
    pushUpdate()
    propsChanged()
end

---@param activityEditor BJActivityEditorCommon
local function onInit(activityEditor)
    parent = activityEditor

    beamjoy_communications_ui.addHandler("BJEditorRaceOpen", onOpen)
    beamjoy_communications_ui.addHandler("BJEditorRaceClose", parent.onClose)
    beamjoy_communications_ui.addHandler("BJEditorRaceSetMeta", onSetMeta)
    beamjoy_communications_ui.addHandler("BJEditorRaceCaptureVehicleRestriction", onCaptureVehicleRestriction)
    beamjoy_communications_ui.addHandler("BJEditorRaceSetGate", onSetGate)
    beamjoy_communications_ui.addHandler("BJEditorRaceSelectGate", onSelectGate)
    beamjoy_communications_ui.addHandler("BJEditorRaceSelectStart", onSelectStart)
    beamjoy_communications_ui.addHandler("BJEditorRaceCreateGate", onCreateGate)
    beamjoy_communications_ui.addHandler("BJEditorRaceCreateStart", onCreateStart)
    beamjoy_communications_ui.addHandler("BJEditorRaceDeleteGate", onDeleteGate)
    beamjoy_communications_ui.addHandler("BJEditorRaceDeleteStart", onDeleteStart)
    beamjoy_communications_ui.addHandler("BJEditorRaceReorderGates", onReorderGates)
    beamjoy_communications_ui.addHandler("BJEditorRaceReverseGates", onReverseGates)
    beamjoy_communications_ui.addHandler("BJEditorRaceSetSnapToGround", onSetSnapToGround)
    beamjoy_communications_ui.addHandler("BJEditorRaceSetSnapMethod", onSetSnapMethod)
    beamjoy_communications_ui.addHandler("BJEditorRaceSetGateToVehicle", onSetGateToVehicle)
    beamjoy_communications_ui.addHandler("BJEditorRaceSetStartToVehicle", onSetStartToVehicle)
    beamjoy_communications_ui.addHandler("BJEditorRaceTeleportToGate", onTeleportToGate)
    beamjoy_communications_ui.addHandler("BJEditorRaceTeleportToStart", onTeleportToStart)
    beamjoy_communications_ui.addHandler("BJEditorRaceResetGate", onResetGate)
    beamjoy_communications_ui.addHandler("BJEditorRaceResetStart", onResetStart)
    beamjoy_communications_ui.addHandler("BJEditorRaceSave", onSave)
    beamjoy_communications_ui.addHandler("BJEditorRaceSaveAsNew", onSaveAsNew)
    beamjoy_communications_ui.addHandler("BJEditorRaceImportCode", onImportCode)
    beamjoy_communications_ui.addHandler("BJEditorRaceSelectProp", function(index, part) M.onSelectProp(index, part) end)
    beamjoy_communications_ui.addHandler("BJEditorRaceSetProp", onSetProp)
    beamjoy_communications_ui.addHandler("BJEditorRaceDeleteProp", onDeleteProp)
    beamjoy_communications_ui.addHandler("BJEditorRaceDuplicateProp", onDuplicateProp)
    beamjoy_communications_ui.addHandler("BJEditorRaceSplitPropLine", onSplitPropLine)
    beamjoy_communications_ui.addHandler("BJEditorRaceStraightenPropLine", onStraightenPropLine)
    beamjoy_communications_ui.addHandler("BJEditorRaceTeleportToProp", onTeleportToProp)
    beamjoy_communications_ui.addHandler("BJEditorRaceSetPropToVehicle", onSetPropToVehicle)
    beamjoy_communications_ui.addHandler("BJEditorRaceArmProp", onArmProp)
    beamjoy_communications_ui.addHandler("BJEditorRaceDisarmProp", function() disarmProp() end)
    beamjoy_communications_ui.addHandler("BJEditorRaceSwapPropShape", onSwapPropShape)
    beamjoy_communications_ui.addHandler("BJEditorRaceSetKeepPlacing", function(state)
        M.keepPlacing = state == true
        if M.placing then pushPlacing() end
    end)
end

local function onClose()
    if not parent then return end
    if parent.activeEditor == M then
        disarmProp()
        gizmo.hide()
        draggingHandle = nil
        M.race = nil
        M.savedRace = nil
        M.id = nil
        M.activeGateIndex = nil
        M.activeStartIndex = nil
        M.activePropIndex, M.activePropPart = nil, nil
        M.dirty = false
        propsChanged()
    end
end

M.onInit = onInit
M.onClose = onClose
M.onUpdate = onUpdate
M.onBJClick = onWorldClick
M.onBJEditorDeleteKey = onBJEditorDeleteKey
-- also measures the races the map importer builds (beamjoy/mapRaces.lua)
M.computeRaceDistance = computeRaceDistance

return M
