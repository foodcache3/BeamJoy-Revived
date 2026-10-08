--- Importing the races a map comes with (direct request) : Config > Races > "Import map races".
---
--- A map ships its races in two forms, both read here from the game's own files (this client has
--- the map loaded ; the server never has the map's files) :
---   - quickraces : `levels/<map>/quickrace/<track>.json`, a list of checkpoint names (lapConfig,
---     plus start / finish checkpoints) and spawn spheres. The checkpoints are BeamNGWaypoint
---     objects, either in the track's own prefabs (`<track>.prefab`, `<track>_forward.prefab`, the
---     ones it lists ; Torque text or .prefab.json lines) or in the level itself (scenetree). Same
---     lookup as the game's own conversion (gameplay/race/path.lua's fromTrack), without spawning
---     the prefabs : they may hold cones as vehicles, which BeamMP would send to everyone.
---     A quickrace folder may also hold `<track>.race.json` files, read like the next form.
---   - time trial missions : `gameplay/missions/<map>/timeTrial/<id>/info.json` and its race file
---     (`race.race.json`, the game's race path : pathnodes, segments, start positions).
---
--- Each becomes a BeamJoy race : a checkpoint becomes a gate (its sphere's diameter as the width,
--- facing its direction when it has one, else along the route), the route's segments become the
--- gates' order (or their parents, for a branching route), a circuit stays a circuit with the
--- map's lap count, and the map's start becomes grid slot 1 with more slots behind it (two by two,
--- dropped where the ground isn't road-level). A reversible track is offered reversed too, not
--- ticked by default. The props a track places (barriers, cones) aren't imported.
---
--- Nothing is overwritten : the server adds the ticked races (services/races.lua's raceMapImport),
--- and skips one whose name is already used.

local M = {
    -- the most races one scan offers (a map with more lists the first ones)
    MAX_RACES = 100,
    -- grid slots made behind the map's start
    GRID_SLOTS = 8,
    -- m : a gate's width and height from its checkpoint's radius, within these
    MIN_WIDTH = 4,
    MAX_WIDTH = 30,
    MIN_HEIGHT = 4,
    MAX_HEIGHT = 12,
    -- a prefab bigger than this isn't read (a whole level's worth of objects)
    MAX_PREFAB_BYTES = 8 * 1024 * 1024,

    --- the last scan's races, by key, ready to send
    ---@type table<string, table>
    found = {},
}

-- MATHS (plain {x, y, z} tables) ------------------------------------------------------------------

local function v(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
local function add(a, b) return v(a.x + b.x, a.y + b.y, a.z + b.z) end
local function sub(a, b) return v(a.x - b.x, a.y - b.y, a.z - b.z) end
local function mul(a, s) return v(a.x * s, a.y * s, a.z * s) end
local function len(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

--- horizontal and unit length, or nil when there's no horizontal direction
local function flat(a)
    if not a then return nil end
    local l = math.sqrt(a.x * a.x + a.y * a.y)
    if l < 1e-3 then return nil end
    return v(a.x / l, a.y / l, 0)
end

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

---@param t any {x,y,z} or {1,2,3}
local function toV(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t.x or t[1]), tonumber(t.y or t[2]), tonumber(t.z or t[3])
    if not x or not y or not z then return nil end
    return v(x, y, z)
end

--- the row `c` (1-3) of a 3x3 rotationMatrix : the object's own axis `c` in the world. Checked
--- against the game's own data : hirochi_raceway's fullcircuit1_standing_spawn ("0.856 0.516 0
--- -0.516 0.856 0 0 0 1") faces the way its race leaves (the time trials starting there head
--- for (-155, 123), and their start position faces the same way) only this way round
---@param m number[] 9 numbers
---@param c integer
local function axis(m, c)
    return v(m[3 * c - 2], m[3 * c - 1], m[3 * c])
end

-- READING THE MAP'S OBJECTS ----------------------------------------------------------------------

---@class BJMapObject
---@field class string
---@field pos table
---@field radius number the largest of its scales (the game's getSceneWaypointRadius)
---@field xAxis table? its own x axis in the world (a directional waypoint's facing)
---@field yAxis table? its own y axis in the world (a spawn sphere faces -y)
---@field directional boolean

---@param s string?
---@return number[]
local function numbers(s)
    local out = {}
    for n in tostring(s or ""):gmatch("[-%d%.eE+]+") do
        local x = tonumber(n)
        if x then out[#out + 1] = x end
    end
    return out
end

---@param class string
---@param fields table<string, any> position, scale, rotationMatrix, directionalWaypoint as read
---@return BJMapObject?
local function makeObject(class, fields)
    local pos = type(fields.position) == "table" and toV(fields.position) or toV(numbers(fields.position))
    if not pos then return nil end
    local scale = type(fields.scale) == "table" and fields.scale or numbers(fields.scale)
    local radius = 0
    for _, s in ipairs(scale) do radius = math.max(radius, tonumber(s) or 0) end
    local m = type(fields.rotationMatrix) == "table" and fields.rotationMatrix or numbers(fields.rotationMatrix)
    local obj = {
        class = class,
        pos = pos,
        radius = radius > 0 and radius or 1,
        directional = fields.directionalWaypoint == true or tostring(fields.directionalWaypoint) == "1",
    }
    if #m == 9 then
        obj.xAxis, obj.yAxis = axis(m, 1), axis(m, 2)
    else
        obj.xAxis, obj.yAxis = v(1, 0, 0), v(0, 1, 0)
    end
    return obj
end

local WANTED = { BeamNGWaypoint = true, SpawnSphere = true }

--- a Torque prefab (`new Class(name) { field = "value"; ... };`) : its waypoints and spawn spheres
---@param text string
---@param into table<string, BJMapObject>
local function parsePrefabText(text, into)
    local at = 1
    while true do
        local s, e, class, name = text:find("new%s+([%w_]+)%s*%(%s*([^%)]-)%s*%)%s*{", at)
        if not s then break end
        at = e + 1
        if WANTED[class] and name ~= "" then
            -- these classes hold no children : their block ends at the first "};"
            local close = text:find("};", e, true) or #text
            local fields = {}
            for k, val in text:sub(e + 1, close):gmatch("([%w_]+)%s*=%s*\"(.-)\"%s*;") do
                fields[k] = val
            end
            into[name] = into[name] or makeObject(class, fields)
        end
    end
end

--- a .prefab.json (one JSON object per line)
---@param text string
---@param into table<string, BJMapObject>
local function parsePrefabJson(text, into)
    for line in text:gmatch("[^\r\n]+") do
        if line:find("BeamNGWaypoint", 1, true) or line:find("SpawnSphere", 1, true) then
            local ok, o = pcall(jsonDecode, line)
            if ok and type(o) == "table" and WANTED[o.class] then
                local name = o.name or o.internalName
                if type(name) == "string" and name ~= "" then
                    into[name] = into[name] or makeObject(o.class, o)
                end
            end
        end
    end
end

---@param path string
---@param into table<string, BJMapObject>
local function readPrefab(path, into)
    if not path or not FS:fileExists(path) then return end
    local text = readFile(path)
    if type(text) ~= "string" or #text > M.MAX_PREFAB_BYTES then return end
    if path:lower():find("%.json$") then
        parsePrefabJson(text, into)
    else
        parsePrefabText(text, into)
    end
end

--- an object of the level itself, already in the scene
---@param name string
---@return BJMapObject?
local function sceneObject(name)
    local o = scenetree and scenetree.findObject(name)
    if not o then return nil end
    local class = o.getClassName and o:getClassName() or ""
    if not WANTED[class] then return nil end
    local pos = o:getPosition()
    local scale = o:getScale()
    local q = quat(o:getRotation())
    local x, y = q * vec3(1, 0, 0), q * vec3(0, 1, 0)
    return {
        class = class,
        pos = v(pos.x, pos.y, pos.z),
        radius = math.max(scale.x, scale.y, scale.z),
        xAxis = v(x.x, x.y, x.z),
        yAxis = v(y.x, y.y, y.z),
        directional = tostring(o:getField("directionalWaypoint", 0)) == "1",
    }
end

--- the track's own prefabs first (several tracks of a map often reuse the same checkpoint names,
--- each in its own prefab), then the level
---@param objs table<string, BJMapObject>
---@param name string?
---@param class string
---@return BJMapObject?
local function findObject(objs, name, class)
    if type(name) ~= "string" or name == "" then return nil end
    local o = objs[name]
    if o and o.class == class then return o end
    o = sceneObject(name)
    if o and o.class == class then return o end
    return nil
end

-- TRACKS ----------------------------------------------------------------------------------------

---@class BJMapTrack the map's race, as read, before it becomes a BeamJoy race
---@field name string
---@field fallbackName string
---@field nodes {pos: table, radius: number, normal: table?}[]
---@field segs {a: integer, b: integer}[]
---@field startNode integer
---@field endNode integer?
---@field closed boolean
---@field laps integer?
---@field start {pos: table, dir: table, front: boolean}? front : pos is the car's front (the
---race path's start positions), not its middle (a quickrace spawn sphere)
---@field reverseStart {pos: table, dir: table, front: boolean}?

--- "004-cliff_road" -> "Cliff road"
---@param s string
local function prettify(s)
    s = tostring(s or ""):gsub("^%d+[-_ ]*", ""):gsub("[-_]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return (s:gsub("^%l", string.upper))
end

--- a translation key the game knows becomes its text ; one it doesn't (a mod map's untranslated
--- key) falls back to the file's name
---@param raw any
---@param fallback string
local function displayName(raw, fallback)
    local name = type(raw) == "string" and raw or ""
    if name ~= "" and beamjoy_lang then
        name = beamjoy_lang.translate(name, name) or name
    end
    name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    -- still a key ("quickrace.italy.cliffRoad1.title")
    if name == "" or (not name:find(" ") and name:find("%.[%w_]+%.")) then
        name = prettify(fallback)
    end
    if #name > 40 then name = name:sub(1, 40):gsub("%s+$", "") end
    if #name < 3 then name = (name .. " race"):sub(1, 40) end
    return name
end

--- the game's race path (.race.json) : pathnodes, segments and start positions refer to each other
--- by their `oldId`
---@param data table
---@param name string
---@param fallbackName string
---@param closed boolean?
---@param laps integer?
---@return BJMapTrack?, string? reason
local function fromRacePath(data, name, fallbackName, closed, laps)
    if type(data) ~= "table" or type(data.pathnodes) ~= "table" or type(data.segments) ~= "table" then
        return nil, "no route"
    end
    local track = { name = name, fallbackName = fallbackName, nodes = {}, segs = {} }
    local byId = {}
    for _, pn in ipairs(data.pathnodes) do
        local pos = toV(pn.pos)
        if pos then
            track.nodes[#track.nodes + 1] = {
                pos = pos,
                radius = tonumber(pn.radius) or 4,
                normal = toV(pn.normal),
            }
            if pn.oldId ~= nil then byId[pn.oldId] = #track.nodes end
        end
    end
    for _, seg in ipairs(data.segments) do
        local a, b = byId[seg.from], byId[seg.to]
        if a and b and a ~= b then track.segs[#track.segs + 1] = { a = a, b = b } end
    end
    track.startNode = byId[data.startNode] or 1
    track.endNode = byId[data.endNode]
    if #track.nodes < 2 or #track.segs == 0 then return nil, "no route" end

    local cls = type(data.classification) == "table" and data.classification or {}
    track.closed = closed == true or (closed == nil and cls.closed == true)
    track.laps = tonumber(laps) or tonumber(data.defaultLaps)

    local function startPos(id)
        if id == nil then return nil end
        for _, sp in ipairs(data.startPositions or {}) do
            if sp.oldId == id then
                local pos, r = toV(sp.pos), sp.rot
                if pos and type(r) == "table" and #r == 4 then
                    -- the game's start position faces its own +y (quatFromDir(dir, up))
                    local fwd = quat(r[1], r[2], r[3], r[4]) * vec3(0, 1, 0)
                    local dir = flat(v(fwd.x, fwd.y, fwd.z))
                    if dir then return { pos = pos, dir = dir, front = true } end
                end
            end
        end
    end
    track.start = startPos(data.defaultStartPosition)
    track.reverseStart = startPos(data.reverseStartPosition)
    return track
end

--- a quickrace .json : checkpoint names, found in its prefabs or the level
---@param info table the .json
---@param file string its path
---@param level string
---@return BJMapTrack?, string? reason
local function fromQuickrace(info, file, level)
    if info.lapConfigBranches or info.procedural or type(info.lapConfig) ~= "table" then
        return nil, "unsupported"
    end
    local dir, trackName = file:match("^(.*/)([^/]-)%.json$")
    if not dir then return nil, "unsupported" end

    local objs = {}
    local function prefabPath(p)
        if type(p) ~= "string" or p == "" then return nil end
        if FS:fileExists(p) then return p end
        for _, ext in ipairs({ ".prefab", ".prefab.json" }) do
            local f = "/levels/" .. level .. "/" .. p .. ext
            if FS:fileExists(f) then return f end
        end
    end
    for _, suf in ipairs({ "", "_forward" }) do
        for _, ext in ipairs({ ".prefab", ".prefab.json" }) do
            readPrefab(dir .. trackName .. suf .. ext, objs)
        end
    end
    for _, list in ipairs({ info.prefabs, info.forwardPrefabs }) do
        for _, p in ipairs(type(list) == "table" and list or {}) do readPrefab(prefabPath(p), objs) end
    end

    local track = { name = displayName(info.name, trackName), fallbackName = trackName, nodes = {}, segs = {} }
    local missing
    local function node(name)
        local wp = findObject(objs, name, "BeamNGWaypoint")
        if not wp then
            missing = missing or name
            return nil
        end
        track.nodes[#track.nodes + 1] = {
            pos = wp.pos,
            radius = wp.radius,
            normal = wp.directional and wp.xAxis or nil,
        }
        return #track.nodes
    end

    -- the route, as the game's fromTrack builds it : a circuit runs its lapConfig, then its finish
    -- line, then back to the first checkpoint ; a point to point runs from its start line (if any)
    -- through its lapConfig to its finish line
    local closed = info.closed == true
    local order = {}
    local startCP = type(info.startLineCheckpoint) == "string" and info.startLineCheckpoint ~= "" and info.startLineCheckpoint
    local finishCP = type(info.finishLineCheckpoint) == "string" and info.finishLineCheckpoint ~= "" and info.finishLineCheckpoint
    if closed then
        -- the finish line is where a lap starts
        if finishCP then order[#order + 1] = node(finishCP) end
        for _, cp in ipairs(info.lapConfig) do order[#order + 1] = node(cp) end
    else
        if startCP then order[#order + 1] = node(startCP) end
        for _, cp in ipairs(info.lapConfig) do order[#order + 1] = node(cp) end
        if finishCP then order[#order + 1] = node(finishCP) end
    end
    if missing then return nil, "missing checkpoint " .. tostring(missing) end
    -- the same checkpoint twice in a row (a start line that's also the first checkpoint)
    local route = {}
    for _, n in ipairs(order) do
        local last = route[#route]
        if not last or len(sub(track.nodes[n].pos, track.nodes[last].pos)) > 1 then
            route[#route + 1] = n
        end
    end
    if #route < 2 then return nil, "no route" end
    for i = 1, #route - 1 do track.segs[#track.segs + 1] = { a = route[i], b = route[i + 1] } end
    if closed then track.segs[#track.segs + 1] = { a = route[#route], b = route[1] } end
    track.startNode = route[1]
    track.endNode = not closed and route[#route] or nil
    track.closed = closed
    track.laps = closed and tonumber(info.lapCount) or nil

    local spheres = type(info.spawnSpheres) == "table" and info.spawnSpheres or {}
    local function spawn(name)
        local o = findObject(objs, name, "SpawnSphere")
        local dir = o and flat(mul(o.yAxis, -1))
        if dir then return { pos = o.pos, dir = dir, front = false } end
    end
    track.start = spawn(spheres.standing or (trackName .. "_standing_spawn"))
    if info.reversible == true then
        track.reverseStart = spawn(spheres.standingReverse or (trackName .. "_standingReverse_spawn"))
    end
    return track
end

--- the same track driven the other way : every segment turned round. A point to point starts from
--- its finish ; a circuit keeps its start / finish line
---@param track BJMapTrack
---@return BJMapTrack?
local function reversed(track)
    if not track.reverseStart then return nil end
    local r = {
        name = track.name,
        fallbackName = track.fallbackName,
        nodes = track.nodes,
        segs = {},
        closed = track.closed,
        laps = track.laps,
        start = track.reverseStart,
    }
    for i, s in ipairs(track.segs) do r.segs[i] = { a = s.b, b = s.a } end
    if track.closed then
        r.startNode = track.startNode
    else
        if not track.endNode then return nil end
        r.startNode, r.endNode = track.endNode, track.startNode
    end
    return r
end

-- CONVERSION --------------------------------------------------------------------------------------

--- the ground under a point, near its height (a bridge, a tunnel), or nil
---@param pos table
---@param above number? how far above pos to look down from
---@return number?
local function groundAt(pos, above)
    local h
    if be and be.getSurfaceHeightBelow then
        h = be:getSurfaceHeightBelow(vec3(pos.x, pos.y, pos.z + (above or 2)))
    end
    if (not h or h < -1e6) and core_terrain and core_terrain.getTerrainHeight then
        h = core_terrain.getTerrainHeight(vec3(pos.x, pos.y, pos.z))
    end
    if not h or h < -1e6 then return nil end
    return h
end
M.groundAt = groundAt

---@param t table
local function plain(t)
    return { x = t.x, y = t.y, z = t.z }
end

--- a track becomes a BeamJoy race (see BJRace in services/races.lua), or nil and why not
---@param track BJMapTrack
---@return table?, string? reason
local function toRace(track)
    local succ, pred = {}, {}
    for i = 1, #track.nodes do succ[i], pred[i] = {}, {} end
    for _, s in ipairs(track.segs) do
        table.insert(succ[s.a], s.b)
        table.insert(pred[s.b], s.a)
    end

    -- the gates, in the route's order from its start (checkpoints it never reaches are left out)
    local order, index = { track.startNode }, { [track.startNode] = 1 }
    local i = 1
    while order[i] do
        for _, n in ipairs(succ[order[i]]) do
            if not index[n] then
                order[#order + 1] = n
                index[n] = #order
            end
        end
        i = i + 1
    end
    if #order < 2 then return nil, "no route" end

    local closed = track.closed or #pred[track.startNode] > 0
    -- the links that close a lap don't count as a fork
    local function realPreds(n)
        local out = {}
        for _, p in ipairs(pred[n]) do
            if index[p] and n ~= track.startNode then out[#out + 1] = p end
        end
        return out
    end
    local branching = false
    for _, n in ipairs(order) do
        if #succ[n] > 1 or #realPreds(n) > 1 then branching = true end
    end

    local gates = {}
    for gi, n in ipairs(order) do
        local node = track.nodes[n]
        local prev = (n ~= track.startNode or closed) and pred[n][1] or nil
        local nxt = succ[n][1]
        local routeDir
        if prev and nxt then
            routeDir = flat(sub(track.nodes[nxt].pos, track.nodes[prev].pos))
        end
        routeDir = routeDir or (nxt and flat(sub(track.nodes[nxt].pos, node.pos))) or
            (prev and flat(sub(node.pos, track.nodes[prev].pos))) or v(0, 1, 0)
        -- a directional checkpoint's own facing (the side a car leaves it by) ; kept along the
        -- route if a map has it backwards
        local dir = flat(node.normal)
        if dir and dot(dir, routeDir) < 0 then dir = mul(dir, -1) end
        dir = dir or routeDir

        local radius = tonumber(node.radius) or 4
        local pos = v(node.pos.x, node.pos.y, node.pos.z)
        -- a gate stands on the ground ; a checkpoint is a sphere around the road
        local ground = groundAt(pos, 2)
        if ground and pos.z - ground <= math.max(3, radius) and ground - pos.z <= 2 then pos.z = ground end

        local gate = {
            pos = plain(pos),
            dir = plain(dir),
            width = clamp(math.floor(radius * 4 + .5) / 2, M.MIN_WIDTH, M.MAX_WIDTH),
            height = clamp(math.floor(radius * 3 + .5) / 2, M.MIN_HEIGHT, M.MAX_HEIGHT),
        }
        if branching then
            local parents = {}
            for _, p in ipairs(realPreds(n)) do parents[#parents + 1] = index[p] end
            if n == track.startNode or #parents == 0 then parents = { 0 } end
            gate.parents = parents
            if not closed and (#succ[n] == 0 or n == track.endNode) then gate.isFinish = true end
        else
            gate.step, gate.parents = gi, { gi - 1 }
            gate.isFinish = (not closed and gi == #order) or nil
        end
        gates[gi] = gate
    end
    if not closed and #gates < 2 then return nil, "no route" end

    -- the grid : the map's start as slot 1, then two by two behind it
    local first = gates[1]
    local start = track.start
    local base, fwd
    if start then
        fwd = start.dir
        -- the game's race start is the car's front, BeamJoy's its middle
        base = start.front and sub(start.pos, mul(fwd, 2.5)) or v(start.pos.x, start.pos.y, start.pos.z)
    else
        fwd = flat(first.dir) or v(0, 1, 0)
        base = sub(first.pos, mul(fwd, 8))
    end
    local right = v(fwd.y, -fwd.x, 0)
    local baseGround = groundAt(base, 3)
    if baseGround and math.abs(baseGround - base.z) <= 3 then base.z = baseGround end
    local startPositions = { { pos = plain(base), dir = plain(fwd) } }
    for k = 2, M.GRID_SLOTS do
        local row = math.floor(k / 2)
        local side = (k % 2 == 0) and -1 or 1
        local pos = add(sub(base, mul(fwd, 7 * row)), mul(right, 2 * side))
        local h = groundAt(pos, 3 + row)
        -- ground far off the start's height : a wall, a drop, off the road
        if h and math.abs(h - base.z) <= 1.5 + row * 1.2 then
            pos.z = h
            startPositions[#startPositions + 1] = { pos = plain(pos), dir = plain(fwd) }
        end
    end

    local laps = closed and math.max(1, math.floor(tonumber(track.laps) or 3)) or 3
    local race = {
        name = track.name,
        mode = "grid",
        loopable = closed,
        branchingEnabled = branching,
        gates = gates,
        startPositions = startPositions,
        sectorCount = 3,
        defaults = { laps = laps, joinable = #startPositions > 1 },
    }
    local ok, raceEditor = pcall(require, "ge/extensions/beamjoy/ui/raceEditor")
    race.distance = ok and raceEditor.computeRaceDistance and raceEditor.computeRaceDistance(race) or 0
    return race
end

-- SCAN ------------------------------------------------------------------------------------------

---@param level string
---@return {track: BJMapTrack?, reason: string?, source: string, file: string}[]
local function readTracks(level)
    local out = {}
    -- time trial missions first : the newer form, kept over a quickrace of the same track
    local missionDir = "/gameplay/missions/" .. level .. "/timeTrial/"
    if FS:directoryExists(missionDir) then
        for _, infoFile in ipairs(FS:findFiles(missionDir, "info.json", -1, true, false)) do
            local info = jsonReadFile(infoFile)
            if type(info) == "table" and info.missionType == "timeTrial" then
                local folder = infoFile:match("^(.*/)[^/]+$")
                local mtd = type(info.missionTypeData) == "table" and info.missionTypeData or {}
                local raceFile = type(mtd.raceFile) == "string" and mtd.raceFile or "race.race.json"
                if not raceFile:find("^/") and not raceFile:find("^levels/") and not raceFile:find("^gameplay/") then
                    -- a mission's files are looked for in its layers, in order : its own folder,
                    -- then shared ones (west_coast_usa's career time trials keep their race in
                    -- /levels/<map>/gameplay/trackLayers/...)
                    local dirs = { folder }
                    for _, layer in ipairs(type(info.layers) == "table" and info.layers or {}) do
                        if type(layer) == "table" and type(layer.dir) == "string" then
                            dirs[#dirs + 1] = layer.dir:find("/$") and layer.dir or (layer.dir .. "/")
                        end
                    end
                    local name = raceFile
                    raceFile = folder .. name
                    for _, d in ipairs(dirs) do
                        if FS:fileExists(d .. name) then
                            raceFile = d .. name
                            break
                        end
                    end
                end
                local id = folder:match("([^/]+)/$") or "race"
                local track, reason = fromRacePath(jsonReadFile(raceFile),
                    displayName(info.name, id), id, mtd.closed, mtd.defaultLaps)
                if track and mtd.reversible == false then track.reverseStart = nil end
                out[#out + 1] = { track = track, reason = reason, source = "timeTrial", file = infoFile,
                    name = track and track.name or displayName(info.name, id) }
            end
        end
    end
    local quickDir = "/levels/" .. level .. "/quickrace/"
    if FS:directoryExists(quickDir) then
        local files = FS:findFiles(quickDir, "*.json", -1, true, false)
        table.sort(files)
        for _, file in ipairs(files) do
            local lower = file:lower()
            if not lower:find("%.prefab%.json$") then
                local data = jsonReadFile(file)
                if type(data) == "table" then
                    local track, reason
                    local base = file:match("([^/]-)%.race%.json$") or file:match("([^/]-)%.json$") or "race"
                    local isPath = lower:find("%.race%.json$") ~= nil
                    if isPath then
                        track, reason = fromRacePath(data, displayName(data.name, base), base)
                    elseif data.lapConfig then
                        track, reason = fromQuickrace(data, file, level)
                    end
                    -- any other .json there isn't a race
                    if isPath or data.lapConfig then
                        out[#out + 1] = { track = track, reason = reason, source = "quickrace", file = file,
                            name = track and track.name or displayName(data.name, base) }
                    end
                end
            end
        end
    end
    return out
end

--- the same track twice (a quickrace and its time trial mission) : same kind, starting and
--- finishing at the same places
local function sameCourse(a, b)
    if a.loopable ~= b.loopable then return false end
    local function near(p, q) return len(sub(p, q)) < 30 end
    return near(a.gates[1].pos, b.gates[1].pos) and near(a.gates[#a.gates].pos, b.gates[#b.gates].pos)
end

--- reads the current map's races, keeps them in M.found and sends the list to the UI
local function scan()
    M.found = {}
    local level = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
    local rows = {}
    if not level then
        beamjoy_communications_ui.send("BJMapRacesScan", { level = "", rows = rows })
        return
    end
    local translate = function(key, default)
        return beamjoy_lang and beamjoy_lang.translate(key, default) or default
    end
    local existing = {}
    for _, r in ipairs(beamjoy_races and beamjoy_races.data or {}) do
        if type(r.name) == "string" then existing[r.name:lower()] = true end
    end

    local kept = {}
    local count = 0
    local function offer(entry, track, reverse)
        if count >= M.MAX_RACES then return end
        local group = translate("beamjoy.mapRaces.source." .. entry.source, entry.source)
        local key = entry.file .. (reverse and "#reverse" or "")
        local row = { key = key, group = group }
        local race, reason
        if track then race, reason = toRace(track) else reason = entry.reason end
        if race and reverse then
            race.name = (race.name .. " " .. translate("beamjoy.mapRaces.reverse", "(reverse)")):sub(1, 40)
        end
        row.label = race and race.name or (entry.name .. (reverse and " (reverse)" or ""))
        if race then
            for _, other in ipairs(kept) do
                if other.reverse == (reverse == true) and sameCourse(other.race, race) then return end
            end
            kept[#kept + 1] = { race = race, reverse = reverse == true }
            local detail = translate("beamjoy.mapRaces.counts", "{gates} gates, {slots} grid slots")
                :gsub("{gates}", tostring(#race.gates)):gsub("{slots}", tostring(#race.startPositions))
            local shape = race.loopable and
                translate("beamjoy.mapRaces.circuit", "circuit, {laps} laps"):gsub("{laps}", tostring(race.defaults.laps)) or
                translate("beamjoy.mapRaces.pointToPoint", "point to point")
            local parts = { detail, shape }
            if race.branchingEnabled then parts[#parts + 1] = translate("beamjoy.mapRaces.branching", "branching route") end
            if race.distance and race.distance > 0 then
                parts[#parts + 1] = race.distance >= 1000 and string.format("%.1f km", race.distance / 1000) or
                    string.format("%d m", race.distance)
            end
            row.detail = table.concat(parts, " · ")
            if existing[race.name:lower()] then
                row.disabled, row.tag = true, translate("beamjoy.mapRaces.nameUsed", "name already used")
            end
            -- a reversed track is offered, not ticked
            if reverse then row.checked = false end
            M.found[key] = race
        else
            row.disabled = true
            row.tag = translate("beamjoy.mapRaces.invalid", "can't be read")
            row.detail = tostring(reason or "")
        end
        rows[#rows + 1] = row
        count = count + 1
    end

    for _, entry in ipairs(readTracks(level)) do
        local ok, err = pcall(function()
            offer(entry, entry.track, false)
            local back = entry.track and reversed(entry.track)
            if back then offer(entry, back, true) end
        end)
        if not ok then
            LogError("beamjoy_mapRaces: " .. tostring(entry.file) .. ": " .. tostring(err))
        end
    end
    beamjoy_communications_ui.send("BJMapRacesScan", { level = level, rows = rows })
end

--- `keys` : the ticked rows
---@param keys string[]
local function import(keys)
    local races = {}
    for _, key in ipairs(type(keys) == "table" and keys or {}) do
        if M.found[key] then races[#races + 1] = M.found[key] end
    end
    if #races == 0 then return end
    beamjoy_communications.send("raceMapImport", races)
end

---@param imported integer
---@param skipped integer
---@param failed integer
local function onImportDone(imported, skipped, failed)
    imported, skipped, failed = tonumber(imported) or 0, tonumber(skipped) or 0, tonumber(failed) or 0
    local text = beamjoy_lang.translate("beamjoy.mapRaces.done", "Map races : {imported} imported")
        :gsub("{imported}", tostring(imported))
    if skipped > 0 then
        text = text .. ", " .. beamjoy_lang.translate("beamjoy.mapRaces.doneSkipped", "{skipped} skipped (name already used)")
            :gsub("{skipped}", tostring(skipped))
    end
    if failed > 0 then
        text = text .. ", " .. beamjoy_lang.translate("beamjoy.mapRaces.doneFailed", "{failed} failed (see the server console)")
            :gsub("{failed}", tostring(failed))
    end
    if skipped > 0 or failed > 0 then toast.warn(text, nil, 8) else toast.success(text, nil, 6) end
end

local function onInit()
    beamjoy_communications_ui.addHandler("BJMapRacesScanRequest", function()
        local ok, err = pcall(scan)
        if not ok then
            LogError("beamjoy_mapRaces: scan failed: " .. tostring(err))
            beamjoy_communications_ui.send("BJMapRacesScan", { level = "", rows = {}, error = true })
        end
    end)
    beamjoy_communications_ui.addHandler("BJMapRacesImport", import)
    beamjoy_communications.addHandler("raceMapImportDone", onImportDone)
end

M.onInit = onInit
M.scan = scan
M.import = import
-- for tests
M.parsePrefabText = parsePrefabText
M.parsePrefabJson = parsePrefabJson
M.fromRacePath = fromRacePath
M.fromQuickrace = fromQuickrace
M.reversed = reversed
M.toRace = toRace
M.displayName = displayName

return M
