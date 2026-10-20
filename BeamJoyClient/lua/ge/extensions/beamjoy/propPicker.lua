--- What the editors' prop picker (the props drawer, ui/modModules/beamjoy/cmps/propDrawer) needs from the
--- game : a thumbnail of each mesh, its real size, and the list of every mesh the game has.
---
--- Thumbnails are rendered on demand, the way the game's own World Editor asset browser makes its
--- (ShapePreview into a 128 px bitmap, saved as a png under /temp) : one at a time over a few
--- frames, the hovered tile first, then the ones in view. All of it is guarded : without
--- ShapePreview (outside the editor's reach) the drawer keeps its placeholder tiles.
---
--- Framed for each mesh (direct report : props shown end-on, off to one side, or not at all ; the
--- asset browser's own camera, used before, is the same for every mesh) : turned to the long side
--- of its box and a bit off square, at its full detail, and from both sides, the one showing more
--- of it kept (a guardrail is only drawn from its front). Rendered larger than the tile, then the
--- square around what's drawn is cut out and scaled to the tile, so every mesh is centred and fills
--- it whatever fitToShape made of it (direct report : the preview's own orbit centring left props
--- off to one side, and put the camera inside some). No grid, so a render that shows nothing is
--- told apart and the tile keeps its placeholder.
---
--- A curated mesh can ask for a view of its own (beamjoy_props.CATALOG's `thumbTurn`, `thumbLying`) :
--- turned round to its face, or, for one the preview draws lying on its back (its file stands it up
--- with an up axis or a node rotation the preview doesn't apply, the world does : the flag markers,
--- the metal fence ; direct report : "fallen over"), looked at from above and the picture turned
--- upside down, which is the view of it standing from in front and a little above. At a turn of 0
--- the camera is on the mesh's +y side (the signs' faces, on -y, came out from the back), so looking
--- down from there its top, toward +y, is at the bottom of the picture.
---
--- Made in daylight only (direct report : at night the previews were black). ShapePreview lights the
--- mesh with the map's own sun, which is next to nothing at night, and has no light of its own to
--- set. So at night a missing thumbnail waits (the drawer's tile says so) and is made once it's day,
--- night as the game's own light state has it, when it starts and again when it's captured. Not
--- judged by how dark the render looks (direct report : the black tire stacks, the dark tarp and the
--- city bin waited for a daylight they already had, and the dark ones on disk were thrown away and
--- made again every time they were looked at).
---
--- Sizes come from the mesh's object box (a TSStatic of it, made for a moment far under the map,
--- then deleted), kept in beamjoy_props.meta for its tuning() and saved beside the thumbnails.
---
--- The mesh index ("All game meshes") walks /art/shapes, /assets/meshes and the current map's art ;
--- the other maps' art has an index of its own, made only once the drawer's "Other maps" is on
--- (direct request : a search for "tire" missed the tire stacks of Hirochi and Automation Test
--- Track). Stock maps only : a modded map's meshes are missing for whoever hasn't got that mod.
--- Walked a few milliseconds a frame.

local M = {
    THUMB_SIZE = 128,
}

local CACHE_DIR = "/temp/bjPropThumbs"
local META_FILE = CACHE_DIR .. "/meta.json"
-- the thumbnails : v4 since the shared meshes borrow their missing materials (those made before are
-- left unused, some pictured with "no material" ; as are the World Editor's own, one camera for all),
-- v5 since some curated meshes have a view of their own, v6 since 0.40 turned the preview's camera
-- round (PREVIEW_YAW), v7 since more of them have one
local THUMB_DIR = CACHE_DIR .. "/v7"
-- frames the preview is given to load and settle before it's captured (as the asset browser does)
local SETTLE_FRAMES = 3
-- the render the thumbnail is cut from (px), and the margin left around the mesh (of its size)
local RENDER_SIZE = 256
local CROP_MARGIN = .12
-- the smallest square cut (px of the render) : a tiny mesh is enlarged at most this much
local CROP_MIN = 56
-- time a frame may spend scaling the cut into the thumbnail (ms)
local COMPOSE_BUDGET_MS = 4
-- a render that shows nothing is kept here, both sides, with what the preview said of it in the log,
-- to find out why (direct report : some meshes show nothing one session and fine the next ; a retry
-- would only hide it). Found that way : shaders compiled in the background, see render()
local DEBUG_DIR = CACHE_DIR .. "/empty"
-- thumbnails made between two timing lines in the log
local STATS_EVERY = 20
-- the camera's pitch, and its turn off square to the mesh's long side (so it shows some depth)
local THUMB_PITCH = 0.35
local THUMB_TURN = 0.6
-- added to every turn : 0.40's preview puts its camera on the other side of the mesh for the same
-- turn (direct report : the arrow boards shown from the back ; the signs' and the corner markers'
-- set views showed their backs too, the lying flag markers and metal fence came out upside down)
local PREVIEW_YAW = math.pi
local META_SAVE_DELAY_MS = 2000
-- the mesh's shaders compiled in the background first (direct report : the drawer froze up to a
-- second a mesh, scrolling it after 0.40 had emptied the shader cache) : its preview rendered as the
-- game does, every frame, until it shows the mesh (a material whose shaders aren't compiled yet
-- isn't drawn at all), the same for WARM_STILL_FRAMES, and no new shader has come meanwhile (at
-- least WARM_MIN_FRAMES, at most WARM_MAX_FRAMES) ; only then made again with them compiled on the
-- spot, which then has next to nothing left to compile. The game says nothing of the shaders it's
-- still compiling : those are the signs it gives
local WARM_MIN_FRAMES = 4
local WARM_STILL_FRAMES = 8
local WARM_MAX_FRAMES = 150
-- a step of a thumbnail taking longer is logged (ms)
local SLOW_STEP_MS = 50
-- the next meshes waiting (this many) get their shaders compiled in the background meanwhile, each
-- shown to a preview of its own (direct request), so they're mostly ready by their turn ; drawn
-- again every PREFETCH_RENDER_EVERY frames while they wait
local PREFETCH = 2
local PREFETCH_RENDER_EVERY = 3

-- shape (as asked) -> url of its thumbnail, false once it couldn't be made
local thumbs = {}
-- shapes waiting for a thumbnail and/or a size, in order
local queue = {}
---@type {shape: string, stage: string, frames: integer, preview: any, path: string}?
local job = nil
-- ShapePreview failed once : no more rendering this session (sizes still come)
local renderBroken = false
-- shapes whose thumbnail waits for daylight (true) ; the drawer asks again once it's day
local deferred = {}
-- night as last seen (onUpdate, once a second), and when it was looked at
local lastNight, nightCheckedAt = nil, 0
-- thumbnails made this session get a fresh url : the UI may still hold the black one by its path
local made = 0
-- shapes measured (a TSStatic of them made and deleted) the frame before their thumbnail starts
local measuredNow = {}
-- what the last thumbnails took (direct question : how much slower framing made them), logged
-- every STATS_EVERY : wall time, frames, and the Lua work in them
local stats = { n = 0, ms = 0, frames = 0, work = 0, worst = 0 }

---@return boolean
local function isNight()
    local ok, state = pcall(function() return core_environment.getLightState() end)
    return ok and type(state) == "table" and state.isNight == true
end

---@class BJThumbLook
---@field seen integer samples that are the mesh
---@field x0 integer the mesh's extent in the image (px), when seen
---@field y0 integer
---@field x1 integer
---@field y1 integer
---@field step integer between samples (px)
---@field bg integer[] the background's colour

--- where the mesh is in an image, sampled every `step` px against its background : the colour most
--- of the border has (the corner's colour, used before, was the mesh's own when a mesh reached it :
--- a jersey barrier came out as "nothing")
---@param bitmap any GBitmap
---@param samples integer? per side (16)
---@return BJThumbLook
local function look(bitmap, samples)
    local w, h = bitmap:getWidth(), bitmap:getHeight()
    local out = { seen = 0, x0 = 0, y0 = 0, x1 = 0, y1 = 0, step = 1, bg = { 0, 0, 0 } }
    if not w or not h or w < 2 or h < 2 then return out end
    local step = math.max(1, math.floor(math.min(w, h) / (samples or 16)))
    out.step = step
    -- a ColorI's channels are red / green / blue (as the game's own code reads them)
    local c = ColorI(0, 0, 0, 0)
    local counts, most = {}, 0
    local function vote(x, y)
        bitmap:getColor(x, y, c)
        local key = math.floor(c.red / 8) * 1024 + math.floor(c.green / 8) * 32 + math.floor(c.blue / 8)
        local n = (counts[key] or 0) + 1
        counts[key] = n
        if n > most then most, out.bg = n, { c.red, c.green, c.blue } end
    end
    for x = 0, w - 1, step do
        vote(x, 0)
        vote(x, h - 1)
    end
    for y = step, h - 2, step do
        vote(0, y)
        vote(w - 1, y)
    end
    local br, bg, bb = out.bg[1], out.bg[2], out.bg[3]
    local x0, y0, x1, y1 = w, h, -1, -1
    for y = 0, h - 1, step do
        for x = 0, w - 1, step do
            bitmap:getColor(x, y, c)
            if math.abs(c.red - br) + math.abs(c.green - bg) + math.abs(c.blue - bb) > 24 then
                out.seen = out.seen + 1
                if x < x0 then x0 = x end
                if x > x1 then x1 = x end
                if y < y0 then y0 = y end
                if y > y1 then y1 = y end
            end
        end
    end
    if out.seen > 0 then out.x0, out.y0, out.x1, out.y1 = x0, y0, x1, y1 end
    return out
end

-- meshes whose size couldn't be read (lower case), not tried again
local unmeasurable = {}
local metaDirtyAt = nil

---@type string[]?
local index = nil
-- the other stock maps' meshes, once asked for
---@type string[]?
local othersIndex = nil
---@alias BJMeshIndexing {roots: string[], dirs: string[], found: table<string, string>, level: string?, others: boolean}
---@type BJMeshIndexing?
local indexing = nil
-- the other kind, waiting for this one to finish
---@type boolean?
local othersAsked = nil
-- time a frame may spend walking folders (ms)
local INDEX_BUDGET_MS = 4

--- a mesh from the game's own art, as the server accepts in a race (services/races.lua saneShape)
---@param shape any
---@return boolean
function M.isPlaceable(shape)
    return type(shape) == "string" and #shape <= 200 and not shape:find("..", 1, true) and
        (shape:find("^/art/") or shape:find("^/assets/") or shape:find("^/levels/")) ~= nil and
        (shape:lower():find("%.dae$") or shape:lower():find("%.cdae$")) ~= nil and
        FS:fileExists(shape)
end

-- SIZES -----------------------------------------------------------------------------------------

local function loadMeta()
    local ok, data = pcall(jsonReadFile, META_FILE)
    if ok and type(data) == "table" then
        for shape, m in pairs(data) do
            if type(m) == "table" and tonumber(m.x) and tonumber(m.y) and tonumber(m.z) then
                beamjoy_props.meta[shape] = { x = m.x, y = m.y, z = m.z, minZ = tonumber(m.minZ) or 0,
                    minX = tonumber(m.minX), maxX = tonumber(m.maxX), minY = tonumber(m.minY), maxY = tonumber(m.maxY) }
                -- its own collision (meshHasCollision) ; not `type(m.col) == "boolean" and m.col or
                -- nil`, which is never false
                if m.col == true or m.col == false then beamjoy_props.meta[shape].col = m.col end
            end
        end
    end
end

local function saveMeta()
    metaDirtyAt = nil
    local ok, err = pcall(function()
        FS:directoryCreate(CACHE_DIR, true)
        jsonWriteFile(META_FILE, beamjoy_props.meta, false)
    end)
    if not ok then LogWarn("beamjoy_propPicker: sizes not saved: " .. tostring(err)) end
end

---@param v number
---@return number
local function round2(v) return math.floor(v * 100 + .5) / 100 end

--- the mesh's object box (unscaled, in metres), from a TSStatic of it made for a moment far under
--- the map
---@param shape string
---@return {min: {x: number, y: number, z: number}, max: {x: number, y: number, z: number}}?
---@return any? error
local function objBox(shape)
    local obj
    local ok, box = pcall(function()
        obj = createObject("TSStatic")
        obj:setField("shapeName", 0, shape)
        obj:setField("collisionType", 0, "None")
        obj:setField("decalType", 0, "None")
        obj.canSave = false
        obj:registerObject("")
        if not simObjectExists(obj) then return nil end
        obj:setPosRot(0, 0, -5000, 0, 0, 0, 1)
        local b = obj:getObjBox()
        local min, max = b.minExtents, b.maxExtents
        local x, y, z = max.x - min.x, max.y - min.y, max.z - min.z
        if not (x == x and y == y and z == z) or x <= 0 and y <= 0 and z <= 0 or
            math.max(x, y, z) > 10000 then
            return nil
        end
        return {
            min = { x = min.x, y = min.y, z = min.z },
            max = { x = max.x, y = max.y, z = max.z },
        }
    end)
    if obj and simObjectExists(obj) then pcall(function() obj:delete() end) end
    if not ok then return nil, box end
    return box
end

--- the mesh's size (its object box, unscaled, in metres) and where its box sits round its origin
--- (`minX`... : how far a line's props reach along it, beamjoy_props.linePlacements), measured the
--- first time it's asked for ; again for one measured before those were kept
---@param shape string
---@return {x: number, y: number, z: number, minZ: number, minX: number, maxX: number, minY: number, maxY: number}?
function M.measure(shape)
    if not M.isPlaceable(shape) then return nil end
    local key = shape:lower()
    local known = beamjoy_props.meta[key]
    if unmeasurable[key] then return known end
    if known and known.minX ~= nil then
        -- whether it has a collision of its own (direct report : the drawer called every game mesh
        -- solid), read for one measured before that was kept
        if known.col == nil then
            beamjoy_props.meshHasCollision(shape)
            metaDirtyAt = metaDirtyAt or GetCurrentTimeMillis() + META_SAVE_DELAY_MS
        end
        return known
    end
    beamjoy_props.ensureMaterials(shape)
    local box, err = objBox(shape)
    local ok, meta = err == nil, nil
    if box then
        meta = {
            x = round2(box.max.x - box.min.x),
            y = round2(box.max.y - box.min.y),
            z = round2(box.max.z - box.min.z),
            minZ = round2(box.min.z),
            minX = round2(box.min.x),
            maxX = round2(box.max.x),
            minY = round2(box.min.y),
            maxY = round2(box.max.y),
        }
    else
        meta = err
    end
    if not ok or not meta then
        unmeasurable[key] = true
        if not ok then LogWarn(string.format("beamjoy_propPicker: %s not measured: %s", shape, tostring(meta))) end
        return known
    end
    if meta then
        beamjoy_props.meta[key] = meta
        beamjoy_props.meshHasCollision(shape) -- kept in it as `col`
        metaDirtyAt = metaDirtyAt or GetCurrentTimeMillis() + META_SAVE_DELAY_MS
    end
    return meta
end

-- THUMBNAILS ------------------------------------------------------------------------------------

---@param shape string
---@return string? url of a thumbnail already on disk
local function cachedThumb(shape)
    local path = THUMB_DIR .. shape .. ".png"
    return FS:fileExists(path) and path or nil
end

---@param shape string
local function notify(shape)
    local url = thumbs[shape]
    beamjoy_communications_ui.send("BJPropThumb", {
        shape = shape,
        url = url or nil,
        size = beamjoy_props.meta[shape:lower()],
        -- waits for daylight (the drawer asks again then)
        deferred = deferred[shape] == true or nil,
    })
end

--- its thumbnail waits for daylight
---@param shape string
local function defer(shape)
    thumbs[shape] = nil
    deferred[shape] = true
    notify(shape)
end

-- the one preview every thumbnail is rendered with (direct report : the game's VRAM only ever went
-- up, tools:Texture at 1.7 GB). A ShapePreview has render targets of its own, freed only once Lua's
-- garbage collector gets to it, and a small userdata gives it no hurry : one made per thumbnail,
-- they piled up. Its mesh is let go after each thumbnail
local sharedPreview = nil

--- lets go of a preview's mesh (and what it holds of its materials)
---@param preview any? ShapePreview
local function release(preview)
    if preview then pcall(function() preview:clearShape() end) end
end

local function dropJob()
    if job then
        release(job.preview)
        release(job.fresh)
    end
    job = nil
end

--- the camera's turns for a mesh : across its long side and a bit off square, then the same from
--- the other side. At a turn of 0 the preview looks along the mesh's y axis (a race barricade, 10 m
--- along y, was shown end-on). A curated mesh's own view (see the top of this file) : the one turn
--- it asks for, or, lying, from above and turned upside down
---@param size table? beamjoy_props.meta's {x, y, z}
---@param shape string
---@return number[] yaws, number pitch, boolean upsideDown
local function thumbYaws(size, shape)
    local cat = beamjoy_props.catalogForShape(shape)
    if cat and cat.thumbLying then return { PREVIEW_YAW }, math.pi / 2 - THUMB_PITCH, true end
    local base = PREVIEW_YAW
    if size and tonumber(size.x) and tonumber(size.y) and size.y > size.x then base = base + math.pi / 2 end
    if cat and tonumber(cat.thumbTurn) then return { base + THUMB_TURN + math.rad(cat.thumbTurn) }, THUMB_PITCH, false end
    return { base + THUMB_TURN, base + THUMB_TURN + math.pi }, THUMB_PITCH, false
end

-- whether the game let async shader compilation be switched off (logged once)
local syncReported = false

--- runs `fn` with the game's shaders compiled on the spot. The game compiles a shader it hasn't got
--- yet in the background and draws nothing with it meanwhile ; the first mesh shown with a material
--- new to the session came out empty, both sides, when the next using it was fine (direct report :
--- the jersey barrier, the 6 m tape but not the 8 m ; the Hirochi tire stack but not its green and
--- white ones). The game's own captures turn that off the same way (tech/techCore.lua,
--- util/precompileShaders.lua). Around the mesh's loading too, where its materials are set up : only
--- around the render (build 2665) changed nothing. Back on at once, the game has no getter for it
---@param fn function
local function synced(fn)
    local sync, syncErr = pcall(function() Engine.Render.setAsyncShaderCompilation(false) end)
    if not syncReported then
        syncReported = true
        log("I", "beamjoy_propPicker", "shaders compiled on the spot for previews : " ..
            (sync and "yes" or ("no (" .. tostring(syncErr) .. ")")))
    end
    local ok, err = pcall(fn)
    if sync then pcall(function() Engine.Render.setAsyncShaderCompilation(true) end) end
    if not ok then error(err, 0) end
end

---@param preview any? ShapePreview (the job's)
local function render(preview)
    synced(function() (preview or job.preview):renderWorld(job.rect) end)
end

--- the shaders the game has made so far (nil when it doesn't say)
---@return number?
local function shadersMade()
    local ok, n = pcall(function() return Engine.Render.getShaderGenerationCount() end)
    return ok and tonumber(n) or nil
end

--- a preview of the job's mesh, set up for a thumbnail : no grid, its largest drawn detail level.
--- The shared one, or one of its own for an empty render's probe (a preview made anew). Its
--- materials set up with their shaders compiled on the spot, or, `background`, as the game does
---@param own boolean?
---@param background boolean?
---@return any ShapePreview
local function newPreview(own, background)
    local preview = own and ShapePreview() or sharedPreview or ShapePreview()
    if not own then sharedPreview = preview end
    return M.setUpPreview(preview, job.shape, job.pitch, job.yaws[1], background)
end

--- sets a preview up for a thumbnail of `shape` (see newPreview)
---@param preview any ShapePreview
---@param shape string
---@param pitch number
---@param yaw number
---@param background boolean?
---@return any preview
function M.setUpPreview(preview, shape, pitch, yaw, background)
    -- no grid (the sixth) : only the background around the mesh, so an empty render shows
    if not pcall(function() preview:setRenderState(false, false, false, false, false, false) end) then
        preview:setRenderState(false, false, false, false, false)
    end
    preview:setCamRotation(pitch, yaw)
    if background then
        preview:setObjectModel(shape)
    else
        synced(function() preview:setObjectModel(shape) end)
    end
    -- its full detail : left to the preview, a small tile could get a mesh's lowest level, or none
    -- (forced the way the game's own resource checker does). The largest level drawn (its size 0 or
    -- more), by the shape's own list as the shape editor reads it : the first level isn't always
    -- one (collision ones come first in some meshes)
    pcall(function()
        local detail, best = 0, -1
        local okInfo, info = pcall(function() return preview:getTSShapeInfo() end)
        if okInfo and type(info) == "table" and type(info.details) == "table" then
            for i, d in pairs(info.details) do
                local size = type(d) == "table" and tonumber(d.size)
                if size and size >= 0 and size > best then detail, best = i - 1, size end
            end
        end
        preview.mFixedDetail = true
        preview:setCurrentDetail(detail)
    end)
    return preview
end

--- what a preview says it drew
---@param p any ShapePreview
---@return string
local function saidBy(p)
    local said = {}
    for _, field in ipairs({ "mCurrentDL", "mDetailPolys", "mDetailSize", "mPixelSize", "mNumDrawCalls", "mNumMaterials" }) do
        local okField, value = pcall(function() return p[field] end)
        said[#said + 1] = field:sub(2) .. "=" .. (okField and tostring(value) or "?")
    end
    local okName, name = pcall(function() return p:getCurentDetailName() end)
    said[#said + 1] = "detail=" .. (okName and tostring(name) or "?")
    return table.concat(said, " ")
end

--- the material each of a preview's material slots is bound to, and the file it came from
---@param p any ShapePreview
---@return string
local function materialsOf(p)
    local okN, names = pcall(function() return p:getMaterialNames() end)
    if not okN or type(names) ~= "table" then return "materials unknown" end
    local byMap = {}
    local set = Sim.getMaterialSet()
    for i = 0, set:size() - 1 do
        local mat = set:at(i)
        if mat then
            local to = mat:getField("mapTo", 0)
            if type(to) ~= "string" or to == "" or to == "unmapped_mat" then to = mat:getName() end
            byMap[to] = byMap[to] or {}
            table.insert(byMap[to], mat)
        end
    end
    local out = {}
    for _, n in ipairs(names) do
        local parts = {}
        for _, mat in ipairs(byMap[n] or {}) do
            local okF, file = pcall(function() return mat:getFileName() end)
            parts[#parts + 1] = string.format("%s from %s", mat:getName(), okF and tostring(file) or "?")
        end
        out[#out + 1] = tostring(n) .. " -> " .. (#parts > 0 and table.concat(parts, " + ") or "nothing")
    end
    return table.concat(out, " ; ")
end

-- an empty preview's probes : the same preview rendered every frame up to this many frames, to see
-- whether its mesh ever shows (something still loading) or not
local PROBE_FRAMES = 90
-- frames a fresh preview gets before its capture (as the first)
local PROBE_FRESH_FRAMES = SETTLE_FRAMES + 1

--- points the job's camera for its current view, fitted to the mesh
local function aim()
    job.preview:setCamRotation(job.pitch, job.yaws[job.view])
    job.preview:fitToShape()
end

--- the square of the render cut out around the mesh, with a margin : {x, y, side} (px, may reach
--- past the render's edge, filled with its background there)
---@param seen BJThumbLook
---@return {x: number, y: number, side: number}
local function cropOf(seen)
    local w = seen.x1 - seen.x0 + seen.step
    local h = seen.y1 - seen.y0 + seen.step
    local side = math.max(CROP_MIN, math.max(w, h) * (1 + 2 * CROP_MARGIN))
    local cx, cy = seen.x0 + w / 2, seen.y0 + h / 2
    return { x = cx - side / 2, y = cy - side / 2, side = side }
end

--- scales rows of the cut into the thumbnail until the frame's budget is spent : true once done.
--- Shrunk with 4 samples a pixel, enlarged with the nearest ; turned upside down for a lying mesh
---@return boolean
local function compose()
    local src, out, crop, bg = job.best.bitmap, job.out, job.crop, job.best.seen.bg
    local n = M.THUMB_SIZE
    local srcW, srcH = src:getWidth(), src:getHeight()
    local scale = crop.side / n
    local c, o = ColorI(0, 0, 0, 255), ColorI(0, 0, 0, 255)
    local offsets = scale >= 2 and { -scale / 4, scale / 4 } or { 0 }
    local deadline = os.clock() + COMPOSE_BUDGET_MS / 1000
    while job.row < n do
        local j = job.row
        for i = 0, n - 1 do
            local r, g, b, k = 0, 0, 0, 0
            local si, sj = i, j
            if job.upsideDown then si, sj = n - 1 - i, n - 1 - j end
            local cx, cy = crop.x + (si + .5) * scale, crop.y + (sj + .5) * scale
            for _, dy in ipairs(offsets) do
                for _, dx in ipairs(offsets) do
                    local x, y = math.floor(cx + dx), math.floor(cy + dy)
                    if x >= 0 and y >= 0 and x < srcW and y < srcH then
                        src:getColor(x, y, c)
                        r, g, b = r + c.red, g + c.green, b + c.blue
                    else
                        r, g, b = r + bg[1], g + bg[2], b + bg[3]
                    end
                    k = k + 1
                end
            end
            o.red, o.green, o.blue, o.alpha = math.floor(r / k + .5), math.floor(g / k + .5), math.floor(b / k + .5), 255
            out:setColor(i, j, o)
        end
        job.row = j + 1
        if os.clock() > deadline then break end
    end
    return job.row >= n
end

--- one step of the thumbnail being made ; true once it's done (made or given up)
---@return boolean
local function stepJob()
    local workFrom = os.clock()
    job.steps = (job.steps or 0) + 1
    local ok, err = pcall(function()
        if job.stage == "start" then
            beamjoy_props.ensureMaterials(job.shape)
            local rect = RectI(0, 0, RENDER_SIZE, RENDER_SIZE)
            job.rect = rect
            job.yaws, job.pitch, job.upsideDown = thumbYaws(beamjoy_props.meta[job.shape:lower()], job.shape)
            job.view = 1
            -- its shaders first compiled in the background (see WARM_MIN_FRAMES)
            job.preview = newPreview(false, true)
            aim()
            job.preview:renderWorld(job.rect)
            job.stage, job.frames, job.still, job.shaders = "warm", 0, 0, shadersMade()
            job.shown, job.shownStill = nil, 0
            -- nothing in it to draw (an invisible wall) : it would never show
            local okPolys, polys = pcall(function() return job.preview.mDetailPolys end)
            job.nothing = okPolys and tonumber(polys) == 0
        elseif job.stage == "warm" then
            job.frames = job.frames + 1
            -- what it shows (its last render), at 16 samples a side, then drawn again
            job.warmBitmap = job.warmBitmap or GBitmap()
            if not job.warmBitmapReady then
                job.warmBitmap:init(RENDER_SIZE, RENDER_SIZE)
                job.warmBitmapReady = true
            end
            job.preview:copyToBmp(job.warmBitmap:getPtr())
            local seen = look(job.warmBitmap, 16)
            local shown = seen.seen > 0 and
                string.format("%d %d %d %d %d", seen.seen, seen.x0, seen.y0, seen.x1, seen.y1) or nil
            if shown ~= job.shown then
                job.shown, job.shownStill = shown, 0
            else
                job.shownStill = job.shownStill + 1
            end
            job.preview:renderWorld(job.rect)
            local n = shadersMade()
            if n ~= job.shaders then
                job.shaders, job.still = n, 0
            else
                job.still = job.still + 1
            end
            local settled = (job.nothing or shown ~= nil and job.shownStill >= WARM_STILL_FRAMES) and
                (n == nil or job.still >= WARM_STILL_FRAMES)
            if job.frames >= WARM_MAX_FRAMES or job.frames >= WARM_MIN_FRAMES and settled then
                -- made again as before, compiled on the spot : what's left of its shaders, if any
                job.warmed = job.frames
                job.preview = newPreview()
                render()
                aim()
                job.stage, job.frames = "settle", SETTLE_FRAMES
            end
        elseif job.stage == "settle" then
            job.frames = job.frames - 1
            if job.frames <= 0 then
                render()
                job.stage = "capture"
            end
        elseif job.stage == "capture" then
            local bitmap = GBitmap()
            bitmap:init(RENDER_SIZE, RENDER_SIZE)
            job.preview:copyToBmp(bitmap:getPtr())
            -- 32 samples a side : the cut is placed to 8 px of the render, inside its margin
            local seen = look(bitmap, 32)
            -- what the preview says it drew (kept for an empty render's report)
            local p = job.preview
            job.views = job.views or {}
            job.views[job.view] = { bitmap = bitmap, seen = seen, said = saidBy(p) }
            -- nothing in it to draw (an invisible wall) : its placeholder, nothing to report
            local okPolys, polys = pcall(function() return p.mDetailPolys end)
            if okPolys and tonumber(polys) == 0 then
                job.stage = "empty"
                return
            end
            -- the other side is kept only when it shows clearly more of the mesh
            if seen.seen > 0 and (not job.best or seen.seen > job.best.seen.seen * 1.25) then
                job.best = { bitmap = bitmap, seen = seen }
            end
            if job.view < #job.yaws then
                -- the mesh is loaded by now : the other side is rendered at once, captured next frame
                job.view = job.view + 1
                aim()
                render()
                return
            end
            if not job.best then
                -- both renders kept, and what the preview said, to see why
                pcall(function()
                    local base = DEBUG_DIR .. job.shape:gsub("%.[^.]*$", "")
                    FS:directoryCreate(base:match("^(.*)/[^/]*$"), true)
                    local lines = {}
                    for i, v in ipairs(job.views) do
                        v.bitmap:saveFile(base .. ".view" .. i .. ".png")
                        lines[#lines + 1] = string.format("view %d : %d of %d samples off the background (%d,%d,%d), %s",
                            i, v.seen.seen, 32 * 32, v.seen.bg[1], v.seen.bg[2], v.seen.bg[3], v.said)
                    end
                    LogWarn(string.format("beamjoy_propPicker: %s shows nothing in its preview (%d frames since it was "
                        .. "loaded, measured %s) : %s ; materials : %s ; renders kept in %s", job.shape, job.steps,
                        job.measuredNow and "just before" or "earlier", table.concat(lines, " | "),
                        materialsOf(p), DEBUG_DIR))
                end)
                -- probed, to find out why (the thumbnail stays a placeholder whatever they find)
                job.view = 1
                aim()
                render()
                job.stage, job.frames = "probe", 0
                return
            end
            if isNight() then
                -- night fell meanwhile : unlit, not kept, made again by day
                job.stage = "dark"
                return
            end
            job.crop = cropOf(job.best.seen)
            job.out = GBitmap()
            job.out:init(M.THUMB_SIZE, M.THUMB_SIZE)
            job.row = 0
            job.stage = "compose"
        elseif job.stage == "probe" then
            -- the same preview, rendered every frame : the frame its mesh first shows, if it does
            job.frames = job.frames + 1
            local bitmap = GBitmap()
            bitmap:init(RENDER_SIZE, RENDER_SIZE)
            job.preview:copyToBmp(bitmap:getPtr())
            local seen = look(bitmap, 32)
            if seen.seen > 0 or job.frames >= PROBE_FRAMES then
                job.probe = string.format("the same preview %s", seen.seen > 0 and
                    string.format("shows it %d frames later (%d samples ; %s)", job.frames, seen.seen, saidBy(job.preview)) or
                    string.format("still shows nothing %d frames later (%s)", job.frames, saidBy(job.preview)))
                if seen.seen > 0 then
                    pcall(function()
                        bitmap:saveFile(DEBUG_DIR .. job.shape:gsub("%.[^.]*$", "") .. ".later.png")
                    end)
                end
                -- then a preview made anew, now, the way the first was
                job.fresh = newPreview(true)
                render(job.fresh)
                job.fresh:setCamRotation(job.pitch, job.yaws[1])
                job.fresh:fitToShape()
                job.stage, job.frames = "probeFresh", PROBE_FRESH_FRAMES
                return
            end
            render()
        elseif job.stage == "probeFresh" then
            job.frames = job.frames - 1
            if job.frames > 0 then
                if job.frames == 1 then render(job.fresh) end
                return
            end
            local bitmap = GBitmap()
            bitmap:init(RENDER_SIZE, RENDER_SIZE)
            job.fresh:copyToBmp(bitmap:getPtr())
            local seen = look(bitmap, 32)
            LogWarn(string.format("beamjoy_propPicker: %s probed : %s ; a new preview of it %s (%s) ; materials : %s",
                job.shape, job.probe, seen.seen > 0 and string.format("shows it (%d samples)", seen.seen) or "shows nothing",
                saidBy(job.fresh), materialsOf(job.fresh)))
            pcall(function()
                bitmap:saveFile(DEBUG_DIR .. job.shape:gsub("%.[^.]*$", "") .. ".fresh.png")
            end)
            release(job.fresh)
            job.fresh = nil
            job.stage = "empty"
        elseif job.stage == "compose" then
            if not compose() then return end
            FS:directoryCreate(job.path:match("^(.*)/[^/]*$"), true)
            if not job.out:saveFile(job.path) then error("not saved") end
            job.stage = "done"
        end
    end)
    if not ok then
        renderBroken = true
        LogWarn(string.format("beamjoy_propPicker: no thumbnails (%s): %s", job.shape, tostring(err)))
        thumbs[job.shape] = false
        return true
    end
    local stepMs = (os.clock() - workFrom) * 1000
    job.work = (job.work or 0) + stepMs
    if stepMs > (job.worst or 0) then job.worst = stepMs end
    if stepMs >= SLOW_STEP_MS then
        log("I", "beamjoy_propPicker", string.format("%s : a step took %.0f ms (now %s, %s frames warming)",
            job.shape, stepMs, job.stage, tostring(job.warmed or job.frames)))
    end
    if job.stage == "done" then
        stats.n, stats.frames, stats.work = stats.n + 1, stats.frames + job.steps, stats.work + job.work
        stats.ms = stats.ms + (GetCurrentTimeMillis() - (job.startedAt or GetCurrentTimeMillis()))
        stats.worst = math.max(stats.worst, job.worst or 0)
        if stats.n >= STATS_EVERY then
            log("I", "beamjoy_propPicker", string.format(
                "%d thumbnails : %.0f ms each, %.1f frames, %.1f ms of Lua work, its longest frame %.0f ms",
                stats.n, stats.ms / stats.n, stats.frames / stats.n, stats.work / stats.n, stats.worst))
            stats = { n = 0, ms = 0, frames = 0, work = 0, worst = 0 }
        end
        made = made + 1
        deferred[job.shape] = nil
        thumbs[job.shape] = job.path .. "?v=" .. made
        return true
    end
    if job.stage == "dark" then
        deferred[job.shape] = true
        thumbs[job.shape] = nil
        return true
    end
    if job.stage == "empty" then
        -- nothing of it drawn from either side (reported, renders kept) : the placeholder stays
        thumbs[job.shape] = false
        return true
    end
    return false
end

---@param shape string
---@return boolean sized its size is known, or can't be
local function sized(shape)
    local key = shape:lower()
    local meta = beamjoy_props.meta[key]
    return meta ~= nil and meta.col ~= nil or unmeasurable[key] == true
end

--- looks for a thumbnail already on disk ; true when there's nothing left to make for it
---@param shape string
---@return boolean
local function thumbSettled(shape)
    if thumbs[shape] == nil then
        thumbs[shape] = cachedThumb(shape)
        if thumbs[shape] == nil and (renderBroken or not rawget(_G, "ShapePreview")) then
            renderBroken = true
            thumbs[shape] = false
        end
    end
    return thumbs[shape] ~= nil
end

-- the prefetch's previews (PREFETCH of them, made once, kept : see sharedPreview), each with the
-- mesh it warms, if any
---@type {preview: any, shape: string?, stage: string?, frames: integer}[]
local warmSlots = {}
-- a prefetch failed : none more this session (the thumbnails don't need it)
local prefetchBroken = false

---@param slot table
local function freeSlot(slot)
    if slot.shape then release(slot.preview) end
    slot.shape, slot.stage, slot.frames = nil, nil, 0
end

local function freeSlots()
    for _, slot in ipairs(warmSlots) do freeSlot(slot) end
end

--- the next meshes waiting get their shaders compiled in the background (see PREFETCH) : a mesh no
--- longer waiting, or now being made, lets its preview go ; at most one new mesh started a frame
--- (its materials one frame, its loading the next), as the game shows anything
local function prefetch()
    if prefetchBroken or renderBroken or not rawget(_G, "ShapePreview") then return end
    -- the next ones waiting with no picture yet (by day : by night none is made)
    local want, wanted = {}, 0
    if lastNight ~= true then
        for _, shape in ipairs(queue) do
            if wanted >= PREFETCH then break end
            if not (job and job.shape == shape) and not deferred[shape] and not thumbSettled(shape) then
                want[shape] = true
                wanted = wanted + 1
            end
        end
    end
    local ok, err = pcall(function()
        local warming = {}
        for _, slot in ipairs(warmSlots) do
            if slot.shape and not want[slot.shape] then freeSlot(slot) end
            if slot.shape then warming[slot.shape] = true end
        end
        local started = false
        for _, slot in ipairs(warmSlots) do
            if slot.stage == "materials" then
                -- loaded, and drawn as the game draws : its shaders asked for
                M.setUpPreview(slot.preview, slot.shape, THUMB_PITCH, THUMB_TURN, true)
                slot.preview:fitToShape()
                slot.preview:renderWorld(RectI(0, 0, RENDER_SIZE, RENDER_SIZE))
                slot.stage, slot.frames = "warm", 0
                started = true
            elseif slot.stage == "warm" then
                slot.frames = slot.frames + 1
                if slot.frames % PREFETCH_RENDER_EVERY == 0 then
                    slot.preview:renderWorld(RectI(0, 0, RENDER_SIZE, RENDER_SIZE))
                end
            end
        end
        if started then return end
        for shape in pairs(want) do
            if not warming[shape] then
                local slot
                for _, s in ipairs(warmSlots) do
                    if not s.shape then slot = s break end
                end
                if not slot and #warmSlots < PREFETCH then
                    slot = { preview = ShapePreview(), frames = 0 }
                    table.insert(warmSlots, slot)
                end
                if not slot then return end
                -- its materials first (borrowed from their map if need be), loaded next frame
                beamjoy_props.ensureMaterials(shape)
                slot.shape, slot.stage, slot.frames = shape, "materials", 0
                return
            end
        end
    end)
    if not ok then
        prefetchBroken = true
        LogWarn("beamjoy_propPicker: no more shaders compiled ahead : " .. tostring(err))
        pcall(freeSlots)
    end
end

--- one thing a frame : a size, or a step of a thumbnail
local function processQueue()
    if job then
        if stepJob() then
            local shape = job.shape
            dropJob()
            notify(shape)
        end
        return
    end
    local shape = table.remove(queue, 1)
    if not shape then return end
    if not sized(shape) then
        M.measure(shape)
        -- its thumbnail next frame
        if not thumbSettled(shape) then
            table.insert(queue, 1, shape)
            measuredNow[shape] = true
        else
            notify(shape)
        end
        return
    end
    if not thumbSettled(shape) then
        if isNight() then return defer(shape) end
        job = {
            shape = shape, stage = "start", frames = 0, path = THUMB_DIR .. shape .. ".png",
            startedAt = GetCurrentTimeMillis(), measuredNow = measuredNow[shape],
        }
        measuredNow[shape] = nil
        return
    end
    notify(shape)
end

--- the drawer's tiles in view, the hovered one first : what's known is answered at once, the rest
--- is queued (replacing what the last request queued)
---@param shapes string[]
local function onThumbsRequest(shapes)
    if type(shapes) ~= "table" then return end
    queue = {}
    local known = {}
    for _, shape in ipairs(shapes) do
        if #known + #queue >= 200 then break end
        if M.isPlaceable(shape) and not (job and job.shape == shape) then
            if thumbSettled(shape) and sized(shape) then
                table.insert(known, {
                    shape = shape,
                    url = thumbs[shape] or nil,
                    size = beamjoy_props.meta[shape:lower()],
                })
            else
                table.insert(queue, shape)
            end
        end
    end
    if #known > 0 then beamjoy_communications_ui.send("BJPropThumbs", known) end
end

-- MESH INDEX ------------------------------------------------------------------------------------

---@return string?
local function currentLevel()
    local ok, level = pcall(function() return getCurrentLevelIdentifier and getCurrentLevelIdentifier() end)
    return ok and type(level) == "string" and level ~= "" and level or nil
end

---@param dir string
---@param depth integer
---@param found table<string, string>
local function collect(dir, depth, found)
    for _, pattern in ipairs({ "*.dae", "*.DAE" }) do
        local ok, files = pcall(FS.findFiles, FS, dir, pattern, depth, true, false)
        for _, f in ipairs(ok and type(files) == "table" and files or {}) do
            if type(f) == "string" and #f <= 200 and not f:find("..", 1, true) then
                found[f:lower()] = found[f:lower()] or f
            end
        end
    end
end

--- the art folders of every stock map but this one
---@param level string?
---@return string[]
local function otherMapRoots(level)
    local roots = {}
    local ok, dirs = pcall(FS.findFiles, FS, "/levels/", "*", 0, false, true)
    for _, dir in ipairs(ok and type(dirs) == "table" and dirs or {}) do
        local name = type(dir) == "string" and dir:match("([^/]+)/?$")
        if name and (not level or name:lower() ~= level:lower()) then
            local stock = pcall(function() return isOfficialContentVPath("/levels/" .. name .. "/") end) and
                isOfficialContentVPath("/levels/" .. name .. "/")
            if stock and FS:directoryExists("/levels/" .. name .. "/art/") then
                table.insert(roots, "/levels/" .. name .. "/art/")
            end
        end
    end
    return roots
end

---@param others boolean? the other maps' index
local function startIndex(others)
    local level = currentLevel()
    local roots
    if others then
        roots = otherMapRoots(level)
    else
        roots = { "/art/shapes/", "/assets/meshes/" }
        if level then table.insert(roots, "/levels/" .. level .. "/art/") end
    end
    indexing = { roots = roots, dirs = {}, found = {}, level = level, others = others == true }
    for _, root in ipairs(roots) do
        collect(root, 0, indexing.found)
        local ok, dirs = pcall(FS.findFiles, FS, root, "*", 0, false, true)
        for _, d in ipairs(ok and type(dirs) == "table" and dirs or {}) do
            table.insert(indexing.dirs, d)
        end
    end
end

--- folders until the frame's budget is spent ; the list goes to the drawer once every folder is
--- walked
local function processIndex()
    if not indexing then return end
    local deadline = os.clock() + INDEX_BUDGET_MS / 1000
    repeat
        local dir = table.remove(indexing.dirs, 1)
        if not dir then break end
        collect(dir, -1, indexing.found)
    until os.clock() > deadline
    if #indexing.dirs > 0 then return end
    local list = {}
    for _, shape in pairs(indexing.found) do table.insert(list, shape) end
    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    local level, others = indexing.level, indexing.others
    indexing = nil
    if others then othersIndex = list else index = list end
    beamjoy_communications_ui.send("BJPropIndex", { level = level, shapes = list, others = others or nil })
    -- the other kind, asked for meanwhile
    if othersAsked ~= nil then
        local next = othersAsked
        othersAsked = nil
        startIndex(next)
    end
end

---@param data table? {others = true} : the other maps' meshes
local function onIndexRequest(data)
    local others = type(data) == "table" and data.others == true
    local done = others and othersIndex or not others and index
    if done then
        return beamjoy_communications_ui.send("BJPropIndex", { level = currentLevel(), shapes = done, others = others or nil })
    end
    if indexing then
        if indexing.others ~= others then othersAsked = others end
        return
    end
    startIndex(others)
end

-- HOOKS -----------------------------------------------------------------------------------------

local function onUpdate()
    -- daybreak : the thumbnails that waited for it are asked for again
    local now = GetCurrentTimeMillis()
    if now - nightCheckedAt >= 1000 then
        nightCheckedAt = now
        local night = isNight()
        if lastNight and not night and next(deferred) then
            deferred = {}
            beamjoy_communications_ui.send("BJPropThumbsRetry", {})
        end
        lastNight = night
    end
    if job or #queue > 0 then
        local ok, err = pcall(processQueue)
        if not ok then
            LogError("beamjoy_propPicker: " .. tostring(err))
            dropJob()
        end
    end
    -- (with nothing waiting, it lets the last ones go)
    if #queue > 0 or #warmSlots > 0 then prefetch() end
    if indexing then
        local ok, err = pcall(processIndex)
        if not ok then
            LogError("beamjoy_propPicker: mesh index failed: " .. tostring(err))
            indexing = nil
        end
    end
    if metaDirtyAt and GetCurrentTimeMillis() >= metaDirtyAt then saveMeta() end
end

local function onInit()
    loadMeta()
    beamjoy_communications_ui.addHandler("BJPropThumbsRequest", onThumbsRequest)
    beamjoy_communications_ui.addHandler("BJPropIndexRequest", onIndexRequest)
end

-- a map's own meshes only exist on it : its index is made again on the next map
local function onClientEndMission()
    index, othersIndex, indexing, othersAsked, queue = nil, nil, nil, nil, {}
    deferred, lastNight = {}, nil
    dropJob()
    freeSlots()
    if metaDirtyAt then saveMeta() end
end

local function onExit()
    if metaDirtyAt then saveMeta() end
    dropJob()
    release(sharedPreview)
    sharedPreview = nil
    freeSlots()
    warmSlots = {}
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onClientEndMission = onClientEndMission
M.onServerLeave = onClientEndMission
M.onPreExit = onExit
M.onExtensionUnloaded = onExit

return M
