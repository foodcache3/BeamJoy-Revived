--- Placed props : static meshes from the game's own art (barriers, cones, signs, flags...) that an
--- activity carries in its data (`race.props` for now) and that each client spawns for itself as
--- TSStatic objects. Nothing goes through BeamMP : they're never synced, owned or knocked about,
--- every client just builds the same objects from the same data. Solid to cars once the game's
--- static collision is rebuilt (`be:reloadCollision`, debounced below), which is done for a running
--- race but not for the editor's preview : the editor's ground snapping raycasts the physics
--- collision, and props it can't see there can't be snapped onto by mistake.
---
--- Entries (see services/races.lua's sanitizeProps for the server-side checks) :
---   { kind = "static", shape, pos, dir, up, scale }
---   { kind = "line", shape, a, b, count, yaw, scale, followGround, heights }
--- A line is saved as itself and spread out here : `count` props evenly from `a` to `b` (both ends
--- included), each facing along the line turned by `yaw` degrees round its own vertical axis.
--- `heights` (one ground height per prop, measured by the editor) is what makes it follow the
--- ground ; without it the props sit on the straight line from `a` to `b`.
---
--- Sets : each consumer shows its props under its own key (`show(key, props, opts)`), so a race and
--- anything later (hunter arenas, passive zones) never clear each other's.

local M = {
    MAX_PROPS = 200,

    --- the props offered in the editors. `yaw` (degrees) turns the mesh so its long side follows
    --- the direction it's placed facing (a mesh's own +Y is that direction, quatFromDir) ;
    --- `length` is the gap between props on a new line ; `zOffset` (mesh units, scaled) lifts a
    --- mesh whose origin isn't at its base ; `collision` is the TSStatic collision type (meshes
    --- with no collision mesh of their own get "None") ; `invisible` ones are drawn as a panel by
    --- the editor, since nothing of them shows in the world.
    CATALOG = {
        { id = "concreteBarrier", shape = "/art/shapes/race/s_concrete_race_barrier.dae", yaw = 90, length = 3.1 },
        { id = "concreteArrowBarrier", shape = "/art/shapes/race/s_concrete_arrow_barrier.dae", yaw = 90, length = 3.1 },
        { id = "roadBarrier", shape = "/art/shapes/garage_and_dealership/Clutter/concrete_road_barrier_a.dae", yaw = 90, length = 3.1 },
        { id = "jerseyBarrier", shape = "/art/shapes/objects/jerseybarrier_3m.dae", yaw = 0, length = 3.2 },
        { id = "jerseyBarrierEnd", shape = "/art/shapes/objects/jerseybarrier_end.dae", yaw = 0, length = 3.4 },
        { id = "precastBlock", shape = "/art/shapes/objects/s_precast_block.dae", yaw = 90, length = 2 },
        { id = "plasticBarrier", shape = "/art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier.DAE", yaw = 90, length = 1.5 },
        { id = "plasticBarrierRed", shape = "/art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier_red.DAE", yaw = 90, length = 1.5 },
        { id = "constructionBarrier", shape = "/art/shapes/objects/constructionbarrier_arrows.dae", yaw = 0, length = 2 },
        { id = "cone", shape = "/art/shapes/garage_and_dealership/Clutter/road_cone.DAE", yaw = 0, length = 2.5 },
        { id = "bollard", shape = "/art/shapes/objects/bollard_yellow.dae", yaw = 0, length = 1.5 },
        { id = "barrel", shape = "/art/shapes/garage_and_dealership/Clutter/clutter_barrels_red.dae", yaw = 0, length = 1 },
        { id = "foamBlock", shape = "/art/shapes/race/dragstrip/dragStrip_FoamBlockReflector.dae", yaw = 0, length = 1.6 },
        { id = "woodCrate", shape = "/art/shapes/objects/s_wood_crate_closed.dae", yaw = 0, length = 3 },
        { id = "arrowSignLeft", shape = "/art/shapes/objects/race_arrowsign_1_L.dae", yaw = 0, length = 3.1 },
        { id = "arrowSignRight", shape = "/art/shapes/objects/race_arrowsign_1_R.dae", yaw = 0, length = 3.1 },
        { id = "constructionSign", shape = "/art/shapes/objects/construction_sign_big_a.DAE", yaw = 0, length = 2.6 },
        { id = "startTree", shape = "/art/shapes/race/rally/rally_assets/s_rally_start_tree.dae", yaw = 0, length = 1 },
        { id = "banner", shape = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_ngrc.dae", yaw = 0, length = 2.6, collision = "None" },
        { id = "flagFeather", shape = "/art/shapes/garage_and_dealership/s_flag_floor_feather_01.dae", yaw = 0, length = 4, collision = "None" },
        { id = "flagTeardrop", shape = "/art/shapes/garage_and_dealership/s_flag_floor_teardrop_01.dae", yaw = 0, length = 4, collision = "None" },
        { id = "invisibleWall", shape = "/assets/meshes/props/misc/invisible_wall_1m.dae", yaw = 0, length = 1, zOffset = .5, invisible = true },
    },

    ---@type table<string, {signature: string?, objects: table[], entries: table[], collision: boolean, pending: table<integer, true>}>
    sets = {},

    -- ms of a frame spent creating props : a race's whole set at once froze the game for a frame
    -- (110 ms measured, 2026-10-08), so they come in a few per frame (at least one a frame)
    SPAWN_BUDGET_MS = 3,
}

local GROUP_NAME = "BJPropsGroup"
-- the game rebuilds its whole static collision on a reload, a hitch on a big map : one reload
-- after a burst of changes, not one per change
local COLLISION_RELOAD_DELAY_MS = 300

local catalogById, catalogByShape = {}, {}
for _, c in ipairs(M.CATALOG) do
    c.collision = c.collision or "Collision Mesh"
    catalogById[c.id] = c
    catalogByShape[c.shape:lower()] = c
end

---@param id string
---@return table?
function M.getCatalogEntry(id) return catalogById[id] end

---@param shape string
---@return table? the catalog entry for a mesh path (case-insensitive), nil for one not offered
function M.catalogForShape(shape)
    return type(shape) == "string" and catalogByShape[shape:lower()] or nil
end

--- the catalog as the editors' pickers need it
---@return {id: string, shape: string, label: string, invisible: boolean?}[]
function M.catalogForUI()
    return table.map(M.CATALOG, function(c)
        return { id = c.id, shape = c.shape, label = "beamjoy.props.catalog." .. c.id, invisible = c.invisible }
    end)
end

---@param v table? {x, y, z}
---@return vec3?
local function v3(v)
    if type(v) ~= "table" or not tonumber(v.x) or not tonumber(v.y) or not tonumber(v.z) then return nil end
    return vec3(v.x, v.y, v.z)
end

---@param dir vec3
---@param degrees number
---@return vec3 dir turned round the vertical axis
local function turn(dir, degrees)
    local a = math.rad(degrees or 0)
    local c, s = math.cos(a), math.sin(a)
    return vec3(dir.x * c - dir.y * s, dir.x * s + dir.y * c, dir.z)
end
M.turn = turn

---@param line table
---@return integer
local function lineCount(line)
    return math.max(1, math.floor(tonumber(line.count) or 1))
end

--- how many props an entry stands for (a line counts each of its props)
---@param entry table
---@return integer
function M.weight(entry)
    return entry.kind == "line" and lineCount(entry) or 1
end

---@param props table[]?
---@return integer
function M.total(props)
    local n = 0
    for _, e in ipairs(type(props) == "table" and props or {}) do n = n + M.weight(e) end
    return n
end

--- the props of a line, as single placements
---@param line table
---@return {pos: vec3, dir: vec3, up: vec3}[]
function M.linePlacements(line)
    local a, b = v3(line.a), v3(line.b)
    if not a or not b then return {} end
    local count = lineCount(line)
    local along = vec3(b.x - a.x, b.y - a.y, 0)
    if along:length() < 1e-3 then along = vec3(0, 1, 0) end
    local dir = turn(along:normalized(), tonumber(line.yaw) or 0)
    local heights = line.followGround ~= false and type(line.heights) == "table" and #line.heights == count and
        line.heights or nil
    local out = {}
    for i = 1, count do
        local t = count == 1 and .5 or (i - 1) / (count - 1)
        local p = a + (b - a) * t
        if heights and tonumber(heights[i]) then p = vec3(p.x, p.y, heights[i]) end
        out[i] = { pos = p, dir = dir, up = vec3(0, 0, 1) }
    end
    return out
end

--- every prop to spawn for a list of entries, in order, each with what spawning it needs
---@param props table[]?
---@return {shape: string, pos: vec3, dir: vec3, up: vec3, rot: table, scale: number, collision: string, entry: integer}[]
function M.expand(props)
    local out = {}
    for i, e in ipairs(type(props) == "table" and props or {}) do
        local cat = M.catalogForShape(e.shape)
        if type(e.shape) == "string" then
            local scale = math.max(.1, math.min(tonumber(e.scale) or 1, 10))
            local lift = cat and cat.zOffset and cat.zOffset * scale or 0
            local placements
            if e.kind == "line" then
                placements = M.linePlacements(e)
            else
                local pos, dir, up = v3(e.pos), v3(e.dir), v3(e.up) or vec3(0, 0, 1)
                placements = (pos and dir) and { { pos = pos, dir = dir, up = up } } or {}
            end
            for _, p in ipairs(placements) do
                if #out >= M.MAX_PROPS then return out end
                if p.dir:length() > 1e-4 and p.up:length() > 1e-4 then
                    table.insert(out, {
                        shape = e.shape,
                        pos = p.pos + vec3(0, 0, lift),
                        dir = p.dir:normalized(),
                        up = p.up:normalized(),
                        rot = quatFromDir(p.dir, p.up),
                        scale = scale,
                        collision = cat and cat.collision or "Collision Mesh",
                        entry = i,
                    })
                end
            end
        end
    end
    return out
end

-- OBJECTS -------------------------------------------------------------------------------------

local collisionReloadAt = nil

local function scheduleCollisionReload()
    collisionReloadAt = GetCurrentTimeMillis() + COLLISION_RELOAD_DELAY_MS
end

--- props still to be created, in any set
---@return boolean
local function anyPending()
    for _, set in pairs(M.sets) do
        if next(set.pending) then return true end
    end
    return false
end

local function group()
    local g = scenetree.findObject(GROUP_NAME)
    if not g then
        g = createObject("SimGroup")
        g:registerObject(GROUP_NAME)
        g.canSave = false
    end
    return g
end

local missingShapes = {}

---@param shape string
---@return boolean
local function shapeExists(shape)
    if missingShapes[shape] == nil then
        missingShapes[shape] = not FS:fileExists(shape)
        if missingShapes[shape] then
            LogWarn(string.format("beamjoy_props: %s isn't installed, its props are skipped", shape))
        end
    end
    return not missingShapes[shape]
end

local function place(obj, p)
    obj:setPosRot(p.pos.x, p.pos.y, p.pos.z, p.rot.x, p.rot.y, p.rot.z, p.rot.w)
    obj:setScale(vec3(p.scale, p.scale, p.scale))
end

---@param p table an expand() entry
---@return table? obj
local function spawn(p)
    if not shapeExists(p.shape) then return nil end
    local obj = createObject("TSStatic")
    obj:setField("shapeName", 0, p.shape)
    obj:setField("collisionType", 0, p.collision)
    obj:setField("decalType", 0, p.collision)
    obj.canSave = false
    obj:registerObject("")
    if not simObjectExists(obj) then return nil end
    group():addObject(obj)
    place(obj, p)
    return obj
end

local function deleteObject(obj)
    if obj and simObjectExists(obj) then obj:delete() end
end

---@param a table expand() entry
---@param b table expand() entry
---@return boolean same mesh in the same place
local function samePlacement(a, b)
    return a.shape == b.shape and a.collision == b.collision and a.scale == b.scale and
        a.pos:distance(b.pos) < 1e-3 and
        math.abs(a.rot.x - b.rot.x) + math.abs(a.rot.y - b.rot.y) + math.abs(a.rot.z - b.rot.z) +
        math.abs(a.rot.w - b.rot.w) < 1e-5
end

--- shows a set of props, replacing what that set showed before. Objects are reused where the mesh
--- is the same (moved if needed), so dragging one prop in the editor only touches that one
---@param key string the set
---@param props table[]? entries (see the top of this file)
---@param opts {signature: string?, collision: boolean?}? `signature` : nothing is done while it's
---the one the set already shows ; `collision` (default true) : cars hit them (a static collision
---reload follows any change)
function M.show(key, props, opts)
    opts = opts or {}
    local set = M.sets[key]
    if set and opts.signature and set.signature == opts.signature then return end
    set = set or { objects = {}, entries = {}, collision = false, pending = {} }
    M.sets[key] = set
    local collision = opts.collision ~= false

    local wanted = M.expand(props)
    local changed = false
    for i, p in ipairs(wanted) do
        local old, obj = set.entries[i], set.objects[i]
        if old and obj and simObjectExists(obj) and old.shape == p.shape and old.collision == p.collision then
            if not samePlacement(old, p) then
                place(obj, p)
                changed = true
            end
        else
            -- created in onUpdate, a few a frame
            deleteObject(obj)
            set.objects[i] = nil
            set.pending[i] = true
            changed = true
        end
        set.entries[i] = p
    end
    for i = #set.entries, #wanted + 1, -1 do
        deleteObject(set.objects[i])
        set.objects[i], set.entries[i], set.pending[i] = nil, nil, nil
        changed = true
    end

    if (changed and collision) or collision ~= set.collision then
        scheduleCollisionReload()
    end
    set.collision = collision
    set.signature = opts.signature
end

---@param key string
function M.hide(key)
    local set = M.sets[key]
    if not set then return end
    for _, obj in pairs(set.objects) do deleteObject(obj) end
    if set.collision and #set.entries > 0 then scheduleCollisionReload() end
    M.sets[key] = nil
end

local function hideAll()
    for key in pairs(table.clone(M.sets)) do M.hide(key) end
end

--- creates waiting props within the frame's budget ; true when some are still waiting
---@return boolean
local function spawnPending()
    local started = os.clock()
    local spawned = 0
    for _, set in pairs(M.sets) do
        for i in pairs(set.pending) do
            if spawned > 0 and (os.clock() - started) * 1000 >= M.SPAWN_BUDGET_MS then return true end
            set.pending[i] = nil
            local p = set.entries[i]
            if p and not set.objects[i] then set.objects[i] = spawn(p) end
            spawned = spawned + 1
        end
    end
    return false
end

--- props come in a few per frame ; then the static collision catches up with them (debounced, see
--- scheduleCollisionReload : it waits for the last prop)
local function onUpdate()
    if anyPending() then
        if spawnPending() then
            if collisionReloadAt then scheduleCollisionReload() end
            return
        end
        if collisionReloadAt then scheduleCollisionReload() end
    end
    if collisionReloadAt and GetCurrentTimeMillis() >= collisionReloadAt then
        collisionReloadAt = nil
        be:reloadCollision()
    end
end

-- RACES ---------------------------------------------------------------------------------------

local raceEditor = require("ge/extensions/beamjoy/ui/raceEditor")

--- a race's props : the race being edited (a preview, no collision), else the race you're in or
--- watching, from its grid until it ends. Follows the same refresh hook as the race markers
local function syncRace()
    if raceEditor.race then
        return M.show("race", raceEditor.race.props,
            { signature = "editor:" .. tostring(raceEditor.propsRevision), collision = false })
    end
    local session = beamjoy_raceRunner and (beamjoy_raceRunner.session or beamjoy_raceRunner.spectatingSession)
    local race = session and beamjoy_races and
        table.find(beamjoy_races.data, function(r) return r.id == session.raceId end)
    if race and type(race.props) == "table" and #race.props > 0 then
        return M.show("race", race.props, { signature = string.format("session:%s:%s", session.id, race.id) })
    end
    M.hide("race")
end

local function cleanup()
    hideAll()
    M.sets = {}
    if collisionReloadAt then
        collisionReloadAt = nil
        if be then be:reloadCollision() end
    end
end

M.onUpdate = onUpdate
M.onBJRaceMarkersRefresh = syncRace
M.onServerLeave = cleanup
M.onClientEndMission = cleanup
M.onExtensionUnloaded = cleanup
M.onPreExit = cleanup

return M
