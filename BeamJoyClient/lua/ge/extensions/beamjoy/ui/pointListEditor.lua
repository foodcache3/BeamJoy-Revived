--- Shared toolkit for "a few named point-lists placed via gizmo + world-click, edited from an
--- Angular sidebar" editors. The pattern `hunterEditor.lua` established for hunter/prey spawns and
--- waypoints, and the pattern future simple-point modes (Infected, Delivery, Bus, ...) will almost
--- certainly want too : a spawn point, a stop, a waypoint are all "a position, maybe a facing,
--- maybe a trigger radius," not a rotatable/scalable volume.
---
--- Deliberately NOT used by `activityEditorSafeZone.lua`. Safe zones are a genuinely different
--- shape (a freely-rotatable, 3-axis-scalable cuboid volume, gizmo scale tool and all), not a
--- simple point marker, and forcing that into this same code path would need per-shape branching
--- at nearly every step (render, gizmo behavior, create defaults), which stops being a real
--- shared abstraction and starts being complexity theater for a shape with exactly one consumer.
--- Kept as its own small, working, unrelated file.
---
--- A consuming module (see `hunterEditor.lua`) owns everything OUTSIDE the point-lists themselves
--- (an `enabled` toggle, gameplay defaults, its own save payload) and calls into an instance of
--- this module for everything about the lists : rendering, gizmo editing, world-click selection,
--- CRUD, ground-snap. The instance neither knows nor cares about `parent.activeEditor` mutual
--- exclusion. That stays the host's own responsibility (its own onOpen/onClose still gate on it
--- exactly like every other editor does), passed in as a plain `isActive()` predicate this module
--- checks before mutating anything.

---@class BJPointListSpec
---@field key string unique within this editor instance, e.g. "hunterSpawns"
---@field labelKey string locale key for the marker text label and count display
---@field color table BJColor when not the active selection
---@field hasDir boolean? pos+dir (sphere+arrow marker), rotation via gizmo flattened to horizontal
---, mutually exclusive with hasRadius, not both
---@field hasRadius boolean? pos+radius (plain sphere sized to the radius), no facing/rotation ;
---radius itself is edited via an Angular slider/input, not the gizmo's own scale tool (see
---raceEditor.lua's own established reasoning for avoiding that tool)
---@field hasName boolean? each item carries an optional free-text `name`, edited via an Angular
---text input. Shown in place of "<label> <n>" on the world-space text label when set. The host is
---still responsible for persisting/sanitizing it (this module just clamps to 40 chars).
---@field hasTypes boolean? each item carries an optional `types` string array (subset of
---`typeOptions`), edited via an Angular toggle-chip row. Empty/nil is a valid, meaningful value
---(the host decides what it defaults to - e.g. freeroamData's energy stations treat it as "any
---combustion fuel"), so this module never invents a default list on create.
---@field typeOptions { key: string, labelKey: string }[]? only used when hasTypes ; the fixed set
---of togglable type keys and their locale keys, in display order
---@field defaultRadius number? only used when hasRadius ; default 5
---@field min integer? default 0, purely informational (the host's own save-time validation is
---still authoritative: this module never blocks a mutation over it)
---@field max integer? at most this many points (the derby's single sumo circle) ; creating more
---is refused
---@field flatRadius boolean? only with hasRadius : drawn as a flat circle on the ground instead of
---a sphere (a big area like the sumo circle), and picked by its centre only
---@field drawExtra (fun(item: table, color: table))? extra world shapes drawn with each point
---@field drawItem (fun(item: table, color: table, text: string): boolean)? draws an item itself
---instead of the usual marker when it returns true (the derby's rectangular sumo zone)
---
---An item that carries a `dir` of its own (the host set one, e.g. the derby's rectangle) is
---rotated by the gizmo and set from the vehicle's facing the same way as a hasDir list's items.

---@class BJPointListEditorEvents wire event names: explicit, not templated from a shared prefix,
---so a consumer can keep whatever naming it already established (or wants) without this module
---forcing a rename. `BJEditorDirty`/`BJEditorChangeTool` are NOT part of this. Those two are
---already-generic, already-shared event names every editor in this codebase uses as-is.
---@field listsUpdate string Lua -> Angular : full {key -> item[]} snapshot, every list at once
---@field activeUpdate string Lua -> Angular : (listKey, 1-based index) currently selected
---@field select string Angular -> Lua : (listKey, 1-based index)
---@field create string Angular -> Lua : (listKey)
---@field delete string Angular -> Lua : (listKey, 1-based index)
---@field setToVehicle string Angular -> Lua : (listKey, 1-based index)
---@field teleportTo string Angular -> Lua : (listKey, 1-based index) moves the caller's own
---vehicle to the point, mirroring raceEditor.lua's own onTeleportTo
---@field setRadius string? Angular -> Lua : (listKey, 1-based index, radius), only needed if any
---list has hasRadius
---@field setName string? Angular -> Lua : (listKey, 1-based index, name), only needed if any list
---has hasName
---@field setTypes string? Angular -> Lua : (listKey, 1-based index, types[]), only needed if any
---list has hasTypes
---@field snapToGround string Lua -> Angular : (boolean)
---@field snapMethod string Lua -> Angular : ("terrain"|"raycast")
---@field setSnapToGround string Angular -> Lua : (boolean)
---@field setSnapMethod string Angular -> Lua : ("terrain"|"raycast")
---@field requestState string? Angular -> Lua : () re-sends the current lists/active/dirty/snap
---state as-is, without resetting anything (unlike open()). Optional, but every consumer should
---wire it up: `<bj-point-list-editor>` gets torn down and recreated by its host's own `ng-if`
---section-tab switching (e.g. Infected/Hunter's Settings<->Spawns tabs), and a freshly mounted
---instance has no other way to learn state that was already pushed before it existed to hear it -
---see cmps/pointListEditor/app.js's own $onInit for the Angular side of this.

---@class BJPointListEditorConfig
---@field lists BJPointListSpec[]
---@field events BJPointListEditorEvents
---@field isActive fun(): boolean host tells us whether mutating right now is actually legitimate
---(mirrors every other editor's own `parent.activeEditor ~= M` guard)
---@field props (fun(): table[]?)? the host's props, when its activity has some (direct request :
---props in Hunter, Infected and Derby arenas) : this editor is then the props editor's host
---(ui/propEditor.lua) while it's open. Props and points are picked by the same world clicks,
---snapped by the same switch, and only one of them is selected at a time. The host still loads and
---saves the props array itself, and forwards onUpdate / onDeleteKey below
---@field turnWhole boolean? the Rotate tool with nothing selected shows the gizmo on the arena's
---middle, and turning it turns the whole arena (direct request : see onTurnAll)
---@field pivot (fun(): vec3?)? what the whole arena turns round (turnWhole), when not the points'
---middle

local ACTIVE_COLOR = BJColor(1, 1, 1, .9)
local TEXT_BG = BJColor(0, 0, 0, .3)

---@param pos vec3
---@param snapMethod "terrain"|"raycast"
---@return number
local function groundHeightAt(pos, snapMethod)
    if snapMethod ~= "raycast" then
        local h = core_terrain and core_terrain.getTerrainHeight and core_terrain.getTerrainHeight(pos)
        if h then return h end
    end
    return be:getSurfaceHeightBelow(pos + vec3(0, 0, 10))
end

---@param snapToGroundEnabled boolean
---@param snapMethod "terrain"|"raycast"
---@return vec3? pos, vec3? dir
local function currentPositionDirection(snapToGroundEnabled, snapMethod)
    local currVeh = beamjoy_vehicles.getCurrent()
    if not currVeh or camera.getCamera() == camera.CAMERAS.FREE then
        local pos, dir = camera.getPositionRotation(false)
        if pos and snapToGroundEnabled then
            pos = vec3(pos.x, pos.y, groundHeightAt(pos, snapMethod))
        end
        return pos, dir
    end
    return beamjoy_vehicles.getVehiclePositionRotation(currVeh.veh)
end

---@param config BJPointListEditorConfig
---@return table instance : open(snapshot), close(), onInit(), onBJClick(clickType, data),
---getLists(), isDirty(), clearDirty()
local function new(config)
    -- the props editor, for a host with props (config.props)
    local propEditor = config.props and require("ge/extensions/beamjoy/ui/propEditor") or nil
    local specByKey = {}
    for _, spec in ipairs(config.lists) do specByKey[spec.key] = spec end

    local state = {
        ---@type table<string, table[]>
        lists = {},
        ---@type string?
        activeList = nil,
        ---@type integer?
        activeIndex = nil,
        dirty = false,
        snapToGroundEnabled = true,
        ---@type "terrain"|"raycast"
        snapMethod = "terrain",
    }
    for _, spec in ipairs(config.lists) do state.lists[spec.key] = {} end

    local function pushListsUpdate()
        beamjoy_communications_ui.send(config.events.listsUpdate, state.lists)
    end
    local function pushActive()
        -- beamjoy_communications_ui.send only ever takes ONE payload (unlike the variadic
        -- server-facing beamjoy_communications.send). Must be a single table, not two args
        beamjoy_communications_ui.send(config.events.activeUpdate, { list = state.activeList, index = state.activeIndex })
    end
    --- everything a freshly (re)mounted Angular side needs to reconstruct the current state from
    --- scratch : called both by open() (a real reset) and by the requestState handler below (no
    --- reset, just re-announcing whatever's already there)
    local function pushFullState()
        pushListsUpdate()
        pushActive()
        beamjoy_communications_ui.send("BJEditorDirty", state.dirty)
        beamjoy_communications_ui.send(config.events.snapToGround, state.snapToGroundEnabled)
        beamjoy_communications_ui.send(config.events.snapMethod, state.snapMethod)
    end
    local function markDirty()
        -- any edit turns the props' collision back off (propEditor.testCollision)
        if propEditor then propEditor.onEdit() end
        if not state.dirty then
            state.dirty = true
            beamjoy_communications_ui.send("BJEditorDirty", true)
        end
    end

    local function renderAll()
        shape.reset()
        for _, spec in ipairs(config.lists) do
            local label = beamjoy_lang.translate(spec.labelKey)
            table.forEach(state.lists[spec.key], function(item, i)
                local pos = vec3(item.pos.x, item.pos.y, item.pos.z)
                local active = state.activeList == spec.key and state.activeIndex == i
                local color = active and ACTIVE_COLOR or spec.color
                local text = (spec.hasName and type(item.name) == "string" and #item.name > 0)
                    and item.name or string.format("%s %d", label, i)
                if spec.drawItem and spec.drawItem(item, color, text) then
                    -- drawn by the host
                elseif spec.hasRadius and spec.flatRadius then
                    local radius = item.radius or spec.defaultRadius or 5
                    shape.addCylinder(pos - vec3(0, 0, .05), pos + vec3(0, 0, .05), radius, color)
                    shape.addSphere(pos, .5, color)
                    shape.addText(text, pos + vec3(0, 0, 1.5), color, TEXT_BG)
                elseif spec.hasRadius then
                    local radius = item.radius or spec.defaultRadius or 5
                    shape.addSphere(pos, radius, color)
                    shape.addText(text, pos + vec3(0, 0, radius + 1), color, TEXT_BG)
                else
                    shape.addSphere(pos, .5, color)
                    if spec.hasDir then
                        shape.addArrow(pos + vec3(0, 0, .5), vec3(item.dir.x, item.dir.y, item.dir.z):normalized(),
                            2, color)
                    end
                    shape.addText(text, pos + vec3(0, 0, 1.5), color, TEXT_BG)
                end
                if spec.drawExtra then spec.drawExtra(item, color) end
            end)
        end
    end

    ---@param listKey string?
    ---@param index integer?
    local function updateGizmo(listKey, index)
        local spec = listKey and specByKey[listKey]
        local item = spec and state.lists[listKey][index]
        if not item then
            -- no point selected : a selected prop keeps its own gizmo
            if not (propEditor and propEditor.activePropIndex) then gizmo.hide() end
            return
        end
        gizmo.hide()
        local hasDir = spec.hasDir or item.dir ~= nil
        gizmo.show({
            pos = vec3(item.pos.x, item.pos.y, item.pos.z),
            dir = hasDir and vec3(item.dir.x, item.dir.y, item.dir.z) or vec3(1, 0, 0),
            up = vec3(0, 0, 1),
            scales = vec3(1, 1, 1), -- radius is Angular-side, not the native scale tool ; see file header
        }, function(updated) ---@param updated GizmoObject
            if not config.isActive() then return end
            item.pos = { x = updated.pos.x, y = updated.pos.y, z = updated.pos.z }
            if hasDir then
                local flatDir = vec3(updated.dir.x, updated.dir.y, 0)
                if flatDir:length() < 1e-4 then
                    flatDir = vec3(item.dir.x, item.dir.y, 0)
                end
                flatDir = flatDir:normalized()
                item.dir = { x = flatDir.x, y = flatDir.y, z = 0 }
            end
            renderAll()
            markDirty()
        end, function() ---@param updated GizmoObject (unused, re-reads item.pos directly)
            if state.snapToGroundEnabled then
                item.pos.z = groundHeightAt(vec3(item.pos.x, item.pos.y, item.pos.z), state.snapMethod)
                renderAll()
                updateGizmo(listKey, index)
            end
            pushListsUpdate()
        end)
    end

    ---@param listKey string
    ---@param index integer
    local function onSelect(listKey, index)
        if not config.isActive() or not specByKey[listKey] then return end
        if state.activeList == listKey and state.activeIndex == index then
            state.activeList, state.activeIndex = nil, nil
        else
            state.activeList, state.activeIndex = listKey, index
            -- a point selected : the props' selection goes
            if propEditor then propEditor.clearSelection() end
        end
        renderAll()
        updateGizmo(state.activeList, state.activeIndex)
        pushActive()
    end

    ---@param listKey string
    local function onCreate(listKey)
        if not config.isActive() then return end
        local spec = specByKey[listKey]
        if not spec then return end
        if spec.max and #state.lists[listKey] >= spec.max then return end
        local pos, dir = currentPositionDirection(state.snapToGroundEnabled, state.snapMethod)
        if not pos then return end
        local item
        if spec.hasRadius then
            item = { pos = { x = pos.x, y = pos.y, z = pos.z }, radius = spec.defaultRadius or 5 }
        else
            item = { pos = { x = pos.x, y = pos.y, z = pos.z } }
            if spec.hasDir then item.dir = { x = dir.x, y = dir.y, z = 0 } end
        end
        table.insert(state.lists[listKey], item)
        state.activeList, state.activeIndex = listKey, #state.lists[listKey]
        if propEditor then propEditor.clearSelection() end
        renderAll()
        updateGizmo(listKey, state.activeIndex)
        pushListsUpdate()
        pushActive()
        markDirty()
    end

    ---@param listKey string
    ---@param index integer
    local function onTeleportTo(listKey, index)
        if not config.isActive() then return end
        local spec = specByKey[listKey]
        local item = spec and state.lists[listKey][index]
        if not item then return end
        local current = beamjoy_vehicles.getCurrentOwn()
        if not current then return end
        local dir = (spec.hasDir or item.dir) and vec3(item.dir.x, item.dir.y, item.dir.z) or vec3(1, 0, 0)
        beamjoy_vehicles.setVehiclePositionRotation(current.veh,
            vec3(item.pos.x, item.pos.y, item.pos.z), dir, vec3(0, 0, 1))
    end

    ---@param listKey string
    ---@param index integer
    local function onDelete(listKey, index)
        if not config.isActive() or not state.lists[listKey] then return end
        table.remove(state.lists[listKey], index)
        if state.activeList == listKey then
            state.activeList, state.activeIndex = nil, nil
        end
        renderAll()
        updateGizmo(state.activeList, state.activeIndex)
        pushListsUpdate()
        pushActive()
        markDirty()
    end

    ---@param listKey string
    ---@param index integer
    local function onSetToVehicle(listKey, index)
        if not config.isActive() then return end
        local spec = specByKey[listKey]
        local item = spec and state.lists[listKey][index]
        if not item then return end
        local pos, dir = currentPositionDirection(state.snapToGroundEnabled, state.snapMethod)
        if not pos then return end
        item.pos = { x = pos.x, y = pos.y, z = pos.z }
        if spec.hasDir or item.dir then item.dir = { x = dir.x, y = dir.y, z = 0 } end
        renderAll()
        updateGizmo(listKey, index)
        pushListsUpdate()
        markDirty()
    end

    ---@param listKey string
    ---@param index integer
    ---@param radius number
    local function onSetRadius(listKey, index, radius)
        if not config.isActive() then return end
        local spec = specByKey[listKey]
        local item = spec and spec.hasRadius and state.lists[listKey][index]
        if not item then return end
        item.radius = math.max(.5, tonumber(radius) or item.radius)
        renderAll()
        if state.activeList == listKey and state.activeIndex == index then
            updateGizmo(listKey, index)
        end
        pushListsUpdate()
        markDirty()
    end

    ---@param listKey string
    ---@param index integer
    ---@param name string
    local function onSetName(listKey, index, name)
        if not config.isActive() then return end
        local spec = specByKey[listKey]
        local item = spec and spec.hasName and state.lists[listKey][index]
        if not item then return end
        name = type(name) == "string" and name or ""
        if #name > 40 then name = name:sub(1, 40) end
        item.name = #name > 0 and name or nil
        -- no pushListsUpdate : Angular already holds the value via ng-model, and re-pushing on
        -- every keystroke would fight the text input. renderAll keeps the world label in sync.
        renderAll()
        markDirty()
    end

    ---@param listKey string
    ---@param index integer
    ---@param types string[]
    local function onSetTypes(listKey, index, types)
        if not config.isActive() then return end
        local spec = specByKey[listKey]
        local item = spec and spec.hasTypes and state.lists[listKey][index]
        if not item then return end
        local validKeys = {}
        for _, opt in ipairs(spec.typeOptions or {}) do validKeys[opt.key] = true end
        local clean, seen = {}, {}
        if table.isArray(types) then
            for _, t in ipairs(types) do
                if validKeys[t] and not seen[t] then
                    seen[t] = true
                    table.insert(clean, t)
                end
            end
        end
        item.types = #clean > 0 and clean or nil
        pushListsUpdate()
        markDirty()
    end

    ---@param stateValue boolean
    local function onSetSnapToGround(stateValue)
        state.snapToGroundEnabled = stateValue == true
        beamjoy_communications_ui.send(config.events.snapToGround, state.snapToGroundEnabled)
    end

    ---@param method "terrain"|"raycast"
    local function onSetSnapMethod(method)
        state.snapMethod = method == "raycast" and "raycast" or "terrain"
        beamjoy_communications_ui.send(config.events.snapMethod, state.snapMethod)
    end

    --- closest-approach ray↔point test (within each marker's own visual radius), across every
    --- list at once. Simpler than a ray↔quad-plane test since these are plain point markers, not
    --- rectangular gates. Ignores a hit on the already-selected point so re-clicking it in the
    --- world doesn't toggle selection off mid-gizmo-grab (same reasoning raceEditor.lua's own
    --- world-click already established). Uses `camera.mouseRay()` rather than `data.pos` for the
    --- ray itself: real, confirmed bug (same one raceEditor.lua's own world-click selection had) :
    --- `data.pos` only exists when `inputs.lua`'s own raycast actually hit real world geometry, so
    --- looking up at a point marker with open sky behind it made it entirely unselectable.
    ---@param clickType "left"|"middle"|"right"
    ---@param data onBJClickData
    local function onBJClick(clickType, data)
        if not config.isActive() then return end
        -- a prop armed : the click is the placing's
        if propEditor and propEditor.onBJClick(clickType) then return end
        if clickType ~= "left" then return end
        -- a click on the gizmo is for the gizmo
        if gizmo.isHovered and gizmo.isHovered() then return end

        local camPos, rayDir = camera.mouseRay()
        if not camPos then return end
        local bestList, bestIndex, bestAlong

        for _, spec in ipairs(config.lists) do
            for i, item in ipairs(state.lists[spec.key]) do
                local pos = vec3(item.pos.x, item.pos.y, item.pos.z)
                local along = (pos - camPos):dot(rayDir)
                if along > 0 then
                    local closest = camPos + rayDir * along
                    local radius = (spec.hasRadius and not spec.flatRadius) and
                        math.max(1.5, item.radius or spec.defaultRadius or 5) or 1.5
                    if closest:distance(pos) <= radius and (not bestAlong or along < bestAlong) then
                        bestList, bestIndex, bestAlong = spec.key, i, along
                    end
                end
            end
        end

        -- the props' handles (propEditor.pick), when nearer than any point
        local propAlong, propIndex, propPart
        if propEditor then propAlong, propIndex, propPart = propEditor.pick(camPos, rayDir) end
        if propAlong and (not bestAlong or propAlong < bestAlong) then
            return propEditor.clickSelect(propIndex, propPart)
        end

        if bestList and not (bestList == state.activeList and bestIndex == state.activeIndex) then
            onSelect(bestList, bestIndex)
        end
    end

    --- this editor as the props editor's host (see ui/propEditor.lua) : the host's props, snapped
    --- as the points are ; a prop selected drops the point selected (its gizmo the prop's next)
    ---@type BJPropEditorHost?
    local propHost = propEditor and {
        label = "An arena",
        getProps = config.props,
        isActive = config.isActive,
        markDirty = function() markDirty() end,
        snap = function() return state.snapToGroundEnabled end,
        groundHeightAt = function(pos) return groundHeightAt(pos, state.snapMethod) end,
        positionDirection = function()
            return currentPositionDirection(state.snapToGroundEnabled, state.snapMethod)
        end,
        onSelect = function()
            if not state.activeList then return end
            state.activeList, state.activeIndex = nil, nil
            renderAll()
            pushActive()
        end,
    } or nil

    --- what the whole arena turns round : the host's middle (config.pivot : the derby's zone),
    --- else the points', else the props'
    ---@return vec3?
    local function arenaPivot()
        local pivot = config.pivot and config.pivot() or nil
        if pivot then return pivot end
        local sum, n = vec3(0, 0, 0), 0
        for _, spec in ipairs(config.lists) do
            for _, item in ipairs(state.lists[spec.key]) do
                sum, n = sum + vec3(item.pos.x, item.pos.y, item.pos.z), n + 1
            end
        end
        return n > 0 and sum * (1 / n) or (propEditor and propEditor.centre()) or nil
    end

    --- the whole arena turned round its middle (direct request) : every point (and its facing, a
    --- derby zone's too) and the host's props, by `degrees` anticlockwise seen from above. With
    --- snapping on, each point keeps its height above the ground under it
    ---@param degrees number
    local function onTurnAll(degrees)
        if not config.isActive() then return end
        degrees = tonumber(degrees)
        if not degrees or degrees % 360 == 0 then return end
        local pivot = arenaPivot()
        if not pivot then return end
        local rad = math.rad(degrees)
        local c, s = math.cos(rad), math.sin(rad)
        ---@param pos vec3
        ---@return number?
        local function ground(pos)
            local h = groundHeightAt(pos, state.snapMethod)
            return (type(h) == "number" and math.abs(h) < 1e6) and h or nil
        end
        for _, spec in ipairs(config.lists) do
            for _, item in ipairs(state.lists[spec.key]) do
                local was = vec3(item.pos.x, item.pos.y, item.pos.z)
                local x, y = was.x - pivot.x, was.y - pivot.y
                local pos = { x = pivot.x + x * c - y * s, y = pivot.y + x * s + y * c, z = was.z }
                if state.snapToGroundEnabled then
                    local from, to = ground(was), ground(vec3(pos.x, pos.y, was.z))
                    if from and to then pos.z = was.z + to - from end
                end
                item.pos = pos
                if item.dir then
                    item.dir = { x = item.dir.x * c - item.dir.y * s, y = item.dir.x * s + item.dir.y * c,
                        z = item.dir.z or 0 }
                end
            end
        end
        -- the props after the points : a selected prop's gizmo shown again, a selected point's below
        if propEditor and propEditor.host == propHost then propEditor.turnAll(pivot, degrees) end
        renderAll()
        updateGizmo(state.activeList, state.activeIndex)
        pushListsUpdate()
        markDirty()
    end

    --- the gizmo's callback while it's the whole arena's (config.turnWhole)
    ---@type fun(updated: GizmoObject)?
    local wholeTurned
    --- per frame (config.turnWhole) : the Rotate tool with nothing selected (no point, no prop, none
    --- armed) puts the gizmo on the arena's middle, and turning it turns the whole arena (direct
    --- request, instead of turn buttons). The game's gizmo reads a turn only once released, so the
    --- arena turns then, in one go, and the gizmo comes back on its middle the next frame
    ---@param armed boolean a prop being placed
    local function syncWholeGizmo(armed)
        local shown = wholeTurned ~= nil and gizmo.state and gizmo.onChange == wholeTurned
        local wanted = not armed and config.isActive() and gizmo.tool == "rotate" and not state.activeList and
            not (propEditor and propEditor.activePropIndex)
        if not wanted then
            if shown then gizmo.hide() end
            return
        end
        if shown then return end
        local pivot = arenaPivot()
        if not pivot then return end
        wholeTurned = function(updated) ---@param updated GizmoObject
            if not config.isActive() or gizmo.tool ~= "rotate" or not updated.dir then return end
            -- only the turn round the vertical : the gizmo starts facing +y
            local degrees = math.deg(math.atan2(updated.dir.y, updated.dir.x) - math.pi / 2)
            -- whole hundredths : the gizmo's own float noise isn't a turn
            degrees = math.floor(degrees * 100 + .5) / 100
            onTurnAll(degrees)
        end
        gizmo.hide()
        gizmo.show({
            pos = pivot,
            dir = vec3(0, 1, 0),
            up = vec3(0, 0, 1),
            scales = vec3(1, 1, 1),
        }, wholeTurned)
    end

    ---@param snapshot table<string, table[]> the host's own saved data, keyed by list key
    ---@param keepSelection boolean? the same data again (it was just saved) : the selected point
    ---stays selected while it still exists
    local function open(snapshot, keepSelection)
        snapshot = snapshot or {}
        for _, spec in ipairs(config.lists) do
            state.lists[spec.key] = table.clone(snapshot[spec.key] or {})
        end
        local kept = keepSelection and state.activeList and state.lists[state.activeList] and
            state.lists[state.activeList][state.activeIndex]
        if not kept then state.activeList, state.activeIndex = nil, nil end
        state.dirty = false
        renderAll()
        -- the gizmo follows the selection : back on the kept point, or hidden. It used to be left
        -- on screen with nothing selected once a save reloaded the arena
        if propEditor then gizmo.hide() end
        updateGizmo(state.activeList, state.activeIndex)
        -- the host's props, loaded with its points : the props' selection kept the same way (and
        -- its gizmo shown again), a point kept taking the gizmo
        if propEditor then
            if propEditor.host == propHost then
                propEditor.reset(keepSelection and not kept)
            else
                propEditor.attach(propHost)
            end
        end
        pushFullState()
    end

    local function close()
        if propEditor then propEditor.detach(propHost) end
        gizmo.hide()
        shape.reset()
        for _, spec in ipairs(config.lists) do state.lists[spec.key] = {} end
        state.activeList, state.activeIndex = nil, nil
        state.dirty = false
    end

    local function onInit()
        beamjoy_communications_ui.addHandler(config.events.select, onSelect)
        beamjoy_communications_ui.addHandler(config.events.create, onCreate)
        beamjoy_communications_ui.addHandler(config.events.delete, onDelete)
        beamjoy_communications_ui.addHandler(config.events.setToVehicle, onSetToVehicle)
        beamjoy_communications_ui.addHandler(config.events.teleportTo, onTeleportTo)
        if config.events.setRadius then
            beamjoy_communications_ui.addHandler(config.events.setRadius, onSetRadius)
        end
        if config.events.setName then
            beamjoy_communications_ui.addHandler(config.events.setName, onSetName)
        end
        if config.events.setTypes then
            beamjoy_communications_ui.addHandler(config.events.setTypes, onSetTypes)
        end
        beamjoy_communications_ui.addHandler(config.events.setSnapToGround, onSetSnapToGround)
        beamjoy_communications_ui.addHandler(config.events.setSnapMethod, onSetSnapMethod)
        if config.events.requestState then
            beamjoy_communications_ui.addHandler(config.events.requestState, pushFullState)
        end
    end

    return {
        onInit = onInit,
        open = open,
        close = close,
        onBJClick = onBJClick,
        -- re-draw the world shapes + re-show the gizmo + re-push state, without resetting
        -- anything. For a host that hides/re-shows this editor behind its own section switch
        -- (freeroamEditor's Stations <-> Bus Lines): open() would discard unsaved edits, and a
        -- freshly re-mounted Angular side only gets a state re-push (requestState -> pushFullState,
        -- no renderAll), so the 3D shapes would sit stale until the next mutation.
        reassert = function()
            renderAll()
            updateGizmo(state.activeList, state.activeIndex)
            pushFullState()
        end,
        getLists = function() return state.lists end,
        -- per frame, from the host's onUpdate : true while a prop is armed (the mouse is the
        -- placing's, the host's own handles wait)
        onUpdate = function()
            local armed = propEditor ~= nil and propEditor.onUpdate()
            if config.turnWhole then syncWholeGizmo(armed) end
            return armed
        end,
        -- the Delete key (activityEditor's onBJEditorDeleteKey) : the selected props
        onDeleteKey = function()
            if propEditor and config.isActive() then propEditor.onDeleteKey() end
        end,
        -- the selected point : list key, 1-based index (both nil when nothing is selected)
        getActive = function() return state.activeList, state.activeIndex end,
        -- redraw the world shapes (a host setting a drawExtra reads just changed)
        redraw = renderAll,
        isDirty = function() return state.dirty end,
        -- exposed so the host can flag dirty for its OWN non-list fields too (e.g. an `enabled`
        -- toggle or gameplay defaults). Dirty-ness is a whole-arena concept, this module only
        -- owns the list PORTION of it
        markDirty = markDirty,
        clearDirty = function()
            if state.dirty then
                state.dirty = false
                beamjoy_communications_ui.send("BJEditorDirty", false)
            end
        end,
    }
end

return { new = new }
