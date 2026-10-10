--- What the editors' prop picker (the props drawer, ui/.../races/editor/propDrawer) needs from the
--- game : a thumbnail of each mesh, its real size, and the list of every mesh the game has.
---
--- Thumbnails are rendered on demand, the way the game's own World Editor asset browser makes its
--- (ShapePreview into a 128 px bitmap, saved as a png under /temp) : one at a time over a few
--- frames, the hovered tile first, then the ones in view. All of it is guarded : without
--- ShapePreview (outside the editor's reach) the drawer keeps its placeholder tiles.
---
--- Framed for each mesh (direct report : props shown end-on, off to one side, or not at all ; the
--- asset browser's own camera, used before, is the same for every mesh) : turned to the long side
--- of its box and a bit off square, centred on that box, at its full detail, and from both sides,
--- the one showing more of it kept (a guardrail is only drawn from its front). No grid, so a
--- render that shows nothing is told apart and the tile keeps its placeholder.
---
--- Made in daylight only (direct report : at night the previews were black). ShapePreview lights the
--- mesh with the map's own sun, which is next to nothing at night, and has no light of its own to
--- set. So at night a missing thumbnail waits (the drawer's tile says so) and is made once it's day ;
--- a render that still comes out black (dusk) isn't kept, and a black one already on disk from
--- before is thrown away the first time it's looked at.
---
--- Sizes come from the mesh's object box (a TSStatic of it, made for a moment far under the map,
--- then deleted), kept in beamjoy_props.meta for its tuning() and saved beside the thumbnails.
---
--- The mesh index ("All game meshes") walks /art/shapes, /assets/meshes and the current map's art,
--- one folder a frame.

local M = {
    THUMB_SIZE = 128,
}

local CACHE_DIR = "/temp/bjPropThumbs"
local META_FILE = CACHE_DIR .. "/meta.json"
-- the thumbnails : v2 since they're framed for each mesh (those made before are left unused, as are
-- the World Editor's own, made with the one camera for all)
local THUMB_DIR = CACHE_DIR .. "/v2"
-- frames the preview is given to load and settle before it's captured (as the asset browser does)
local SETTLE_FRAMES = 3
-- the camera's pitch, and its turn off square to the mesh's long side (so it shows some depth)
local THUMB_PITCH = 0.35
local THUMB_TURN = 0.6
local META_SAVE_DELAY_MS = 2000

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

---@return boolean
local function isNight()
    local ok, state = pcall(function() return core_environment.getLightState() end)
    return ok and type(state) == "table" and state.isNight == true
end

--- what of the mesh a thumbnail shows, sampled on a 16 x 16 grid against its background (the
--- corner's colour)
---@param bitmap any GBitmap
---@return integer seen samples that are the mesh
---@return number brightest of them (luminance, 0 - 255)
local function look(bitmap)
    local w, h = bitmap:getWidth(), bitmap:getHeight()
    if not w or not h or w < 2 or h < 2 then return 0, 0 end
    local c = ColorI(0, 0, 0, 0)
    bitmap:getColor(0, 0, c)
    -- a ColorI's channels are red / green / blue (as the game's own code reads them)
    local br, bg, bb = c.red, c.green, c.blue
    local brightest, seen = 0, 0
    for i = 0, 15 do
        for j = 0, 15 do
            bitmap:getColor(math.floor((w - 1) * i / 15), math.floor((h - 1) * j / 15), c)
            if math.abs(c.red - br) + math.abs(c.green - bg) + math.abs(c.blue - bb) > 24 then
                seen = seen + 1
                brightest = math.max(brightest, .299 * c.red + .587 * c.green + .114 * c.blue)
            end
        end
    end
    return seen, brightest
end

--- a thumbnail too dark to show : nothing but its background, or nothing of the mesh brighter than
--- a dim grey (a black tire still catches some light by day)
---@param bitmap any GBitmap
---@return boolean
local function tooDark(bitmap)
    local seen, brightest = look(bitmap)
    return seen == 0 or brightest < 40
end

---@param path string a png
---@return boolean? too dark (nil : couldn't be read)
local function fileTooDark(path)
    local ok, dark = pcall(function()
        local bitmap = GBitmap()
        if not bitmap:loadFile(path) then return nil end
        return tooDark(bitmap)
    end)
    return ok and dark or nil
end
-- meshes whose size couldn't be read (lower case), not tried again
local unmeasurable = {}
local metaDirtyAt = nil

---@type string[]?
local index = nil
---@type {roots: string[], dirs: string[], found: table<string, string>, level: string?}?
local indexing = nil

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
                beamjoy_props.meta[shape] = { x = m.x, y = m.y, z = m.z, minZ = tonumber(m.minZ) or 0 }
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

--- the mesh's size (its object box, unscaled, in metres), measured the first time it's asked for
---@param shape string
---@return {x: number, y: number, z: number, minZ: number}?
function M.measure(shape)
    if not M.isPlaceable(shape) then return nil end
    local key = shape:lower()
    if beamjoy_props.meta[key] or unmeasurable[key] then return beamjoy_props.meta[key] end
    beamjoy_props.ensureMaterials(shape)
    local box, err = objBox(shape)
    local ok, meta = err == nil, nil
    if box then
        meta = {
            x = round2(box.max.x - box.min.x),
            y = round2(box.max.y - box.min.y),
            z = round2(box.max.z - box.min.z),
            minZ = round2(box.min.z),
        }
    else
        meta = err
    end
    if not ok or not meta then
        unmeasurable[key] = true
        if not ok then LogWarn(string.format("beamjoy_propPicker: %s not measured: %s", shape, tostring(meta))) end
        return nil
    end
    if meta then
        beamjoy_props.meta[key] = meta
        metaDirtyAt = metaDirtyAt or GetCurrentTimeMillis() + META_SAVE_DELAY_MS
    end
    return meta
end

-- THUMBNAILS ------------------------------------------------------------------------------------

---@param shape string
---@return string? url of a thumbnail already on disk
local function cachedThumb(shape)
    local path = THUMB_DIR .. shape .. ".png"
    if not FS:fileExists(path) then return nil end
    if not fileTooDark(path) then return path end
    -- made black anyhow : made again
    pcall(function() FS:removeFile(path) end)
    return nil
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

local function dropJob()
    job = nil
end

--- the camera's turns for a mesh : across its long side and a bit off square, then the same from
--- the other side. At a turn of 0 the preview looks along the mesh's y axis (a race barricade, 10 m
--- along y, was shown end-on)
---@param box table? objBox's
---@return number[]
local function thumbYaws(box)
    local base = 0
    if box and box.max.y - box.min.y > box.max.x - box.min.x then base = math.pi / 2 end
    return { base + THUMB_TURN, base + THUMB_TURN + math.pi }
end

--- points the job's camera for its current view, fitted to the mesh
local function aim()
    local preview = job.preview
    preview:setCamRotation(THUMB_PITCH, job.yaws[job.view])
    preview:fitToShape()
    if job.box then
        -- on the box's centre, whatever fitToShape orbits (a curved barricade came out off to one
        -- side, cut by the tile's edge)
        local min, max = job.box.min, job.box.max
        pcall(function()
            preview:setOrbitPos(Point3F((min.x + max.x) / 2, (min.y + max.y) / 2, (min.z + max.z) / 2))
        end)
    end
end

--- one step of the thumbnail being made ; true once it's done (made or given up)
---@return boolean
local function stepJob()
    local ok, err = pcall(function()
        if job.stage == "start" then
            beamjoy_props.ensureMaterials(job.shape)
            local rect = RectI(0, 0, M.THUMB_SIZE, M.THUMB_SIZE)
            job.rect = rect
            job.box = objBox(job.shape)
            job.yaws, job.view = thumbYaws(job.box), 1
            job.preview = ShapePreview()
            -- no grid (the sixth) : only the background around the mesh, so an empty render shows
            if not pcall(function() job.preview:setRenderState(false, false, false, false, false, false) end) then
                job.preview:setRenderState(false, false, false, false, false)
            end
            job.preview:setCamRotation(THUMB_PITCH, job.yaws[1])
            job.preview:setObjectModel(job.shape)
            -- its full detail : left to the preview, a small tile could get a mesh's lowest level,
            -- or none (forced the way the game's own resource checker does)
            pcall(function()
                job.preview.mFixedDetail = true
                job.preview:setCurrentDetail(0)
            end)
            job.preview:renderWorld(rect)
            aim()
            job.stage, job.frames = "settle", SETTLE_FRAMES
        elseif job.stage == "settle" then
            job.frames = job.frames - 1
            if job.frames <= 0 then
                job.preview:renderWorld(job.rect)
                job.stage = "capture"
            end
        elseif job.stage == "capture" then
            local bitmap = GBitmap()
            bitmap:init(M.THUMB_SIZE, M.THUMB_SIZE)
            job.preview:copyToBmp(bitmap:getPtr())
            local seen, brightest = look(bitmap)
            local okPolys, polys = pcall(function() return tonumber(job.preview.mDetailPolys) end)
            if okPolys and polys == 0 then seen = 0 end
            -- the other side is kept only when it shows clearly more of the mesh
            if seen > 0 and (not job.best or seen > job.best.seen * 1.25) then
                job.best = { bitmap = bitmap, seen = seen, brightest = brightest }
            end
            if job.view < #job.yaws then
                job.view = job.view + 1
                aim()
                job.stage, job.frames = "settle", SETTLE_FRAMES
                return
            end
            if not job.best then
                job.stage = "empty"
                return
            end
            if job.best.brightest < 40 then
                -- unlit (night, or dusk) : not kept, made again by day
                job.stage = "dark"
                return
            end
            FS:directoryCreate(job.path:match("^(.*)/[^/]*$"), true)
            if not job.best.bitmap:saveFile(job.path) then error("not saved") end
            job.stage = "done"
        end
    end)
    if not ok then
        renderBroken = true
        LogWarn(string.format("beamjoy_propPicker: no thumbnails (%s): %s", job.shape, tostring(err)))
        thumbs[job.shape] = false
        return true
    end
    if job.stage == "done" then
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
        -- nothing of it drawn from either side : the placeholder stays
        LogWarn(string.format("beamjoy_propPicker: %s shows nothing in its preview", job.shape))
        thumbs[job.shape] = false
        return true
    end
    return false
end

---@param shape string
---@return boolean sized its size is known, or can't be
local function sized(shape)
    local key = shape:lower()
    return beamjoy_props.meta[key] ~= nil or unmeasurable[key] == true
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
        if not thumbSettled(shape) then table.insert(queue, 1, shape) else notify(shape) end
        return
    end
    if not thumbSettled(shape) then
        if isNight() then return defer(shape) end
        job = { shape = shape, stage = "start", frames = 0, path = THUMB_DIR .. shape .. ".png" }
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

local function startIndex()
    local level = currentLevel()
    local roots = { "/art/shapes/", "/assets/meshes/" }
    if level then table.insert(roots, "/levels/" .. level .. "/art/") end
    indexing = { roots = roots, dirs = {}, found = {}, level = level }
    for _, root in ipairs(roots) do
        collect(root, 0, indexing.found)
        local ok, dirs = pcall(FS.findFiles, FS, root, "*", 0, false, true)
        for _, d in ipairs(ok and type(dirs) == "table" and dirs or {}) do
            table.insert(indexing.dirs, d)
        end
    end
end

--- one folder a frame ; the list goes to the drawer once every folder is walked
local function processIndex()
    if not indexing then return end
    local dir = table.remove(indexing.dirs, 1)
    if dir then
        collect(dir, -1, indexing.found)
        return
    end
    local list = {}
    for _, shape in pairs(indexing.found) do table.insert(list, shape) end
    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    index = list
    local level = indexing.level
    indexing = nil
    beamjoy_communications_ui.send("BJPropIndex", { level = level, shapes = index })
end

local function onIndexRequest()
    if index then
        return beamjoy_communications_ui.send("BJPropIndex", { level = currentLevel(), shapes = index })
    end
    if not indexing then startIndex() end
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
    index, indexing, queue = nil, nil, {}
    deferred, lastNight = {}, nil
    dropJob()
    if metaDirtyAt then saveMeta() end
end

local function onExit()
    if metaDirtyAt then saveMeta() end
end

M.onInit = onInit
M.onUpdate = onUpdate
M.onClientEndMission = onClientEndMission
M.onServerLeave = onClientEndMission
M.onPreExit = onExit
M.onExtensionUnloaded = onExit

return M
