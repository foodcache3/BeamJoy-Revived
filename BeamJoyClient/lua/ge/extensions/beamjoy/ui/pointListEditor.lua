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
                if spec.hasRadius then
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
            end)
        end
    end

    ---@param listKey string?
    ---@param index integer?
    local function updateGizmo(listKey, index)
        gizmo.hide()
        local spec = listKey and specByKey[listKey]
        local item = spec and state.lists[listKey][index]
        if not item then return end
        gizmo.show({
            pos = vec3(item.pos.x, item.pos.y, item.pos.z),
            dir = spec.hasDir and vec3(item.dir.x, item.dir.y, item.dir.z) or vec3(1, 0, 0),
            up = vec3(0, 0, 1),
            scales = vec3(1, 1, 1), -- radius is Angular-side, not the native scale tool ; see file header
        }, function(updated) ---@param updated GizmoObject
            if not config.isActive() then return end
            item.pos = { x = updated.pos.x, y = updated.pos.y, z = updated.pos.z }
            if spec.hasDir then
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
        local dir = spec.hasDir and vec3(item.dir.x, item.dir.y, item.dir.z) or vec3(1, 0, 0)
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
        if spec.hasDir then item.dir = { x = dir.x, y = dir.y, z = 0 } end
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
        if clickType ~= "left" then return end
        if not config.isActive() then return end

        local camPos, rayDir = camera.mouseRay()
        if not camPos then return end
        local bestList, bestIndex, bestAlong

        for _, spec in ipairs(config.lists) do
            for i, item in ipairs(state.lists[spec.key]) do
                local pos = vec3(item.pos.x, item.pos.y, item.pos.z)
                local along = (pos - camPos):dot(rayDir)
                if along > 0 then
                    local closest = camPos + rayDir * along
                    local radius = spec.hasRadius and math.max(1.5, item.radius or spec.defaultRadius or 5) or 1.5
                    if closest:distance(pos) <= radius and (not bestAlong or along < bestAlong) then
                        bestList, bestIndex, bestAlong = spec.key, i, along
                    end
                end
            end
        end

        if bestList and not (bestList == state.activeList and bestIndex == state.activeIndex) then
            onSelect(bestList, bestIndex)
        end
    end

    ---@param snapshot table<string, table[]> the host's own saved data, keyed by list key
    local function open(snapshot)
        snapshot = snapshot or {}
        for _, spec in ipairs(config.lists) do
            state.lists[spec.key] = table.clone(snapshot[spec.key] or {})
        end
        state.activeList, state.activeIndex = nil, nil
        state.dirty = false
        renderAll()
        pushFullState()
    end

    local function close()
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
