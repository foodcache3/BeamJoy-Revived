--- What the editors' prop picker (the props drawer, ui/.../races/editor/propDrawer) needs from the
--- game : a thumbnail of each mesh, its real size, and the list of every mesh the game has.
---
--- Thumbnails are rendered on demand, the way the game's own World Editor asset browser makes its
--- (ShapePreview into a 128 px bitmap, saved as a png under /temp) : one at a time over a few
--- frames, the hovered tile first, then the ones in view. A thumbnail the World Editor already made
--- is used as it is. All of it is guarded : without ShapePreview (outside the editor's reach) the
--- drawer keeps its placeholder tiles.
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
-- the World Editor asset browser's own cache (editor/assetBrowser.lua)
local EDITOR_CACHE_DIR = "/temp/assetBrowser/thumbnails"
-- frames the preview is given to load and settle before it's captured (as the asset browser does)
local SETTLE_FRAMES = 3
local META_SAVE_DELAY_MS = 2000

-- shape (as asked) -> url of its thumbnail, false once it couldn't be made
local thumbs = {}
-- shapes waiting for a thumbnail and/or a size, in order
local queue = {}
---@type {shape: string, stage: string, frames: integer, preview: any, path: string}?
local job = nil
-- ShapePreview failed once : no more rendering this session (sizes still come)
local renderBroken = false
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

--- the mesh's size (its object box, unscaled, in metres), measured the first time it's asked for
---@param shape string
---@return {x: number, y: number, z: number, minZ: number}?
function M.measure(shape)
    if not M.isPlaceable(shape) then return nil end
    local key = shape:lower()
    if beamjoy_props.meta[key] or unmeasurable[key] then return beamjoy_props.meta[key] end
    local obj
    local ok, meta = pcall(function()
        obj = createObject("TSStatic")
        obj:setField("shapeName", 0, shape)
        obj:setField("collisionType", 0, "None")
        obj:setField("decalType", 0, "None")
        obj.canSave = false
        obj:registerObject("")
        if not simObjectExists(obj) then return nil end
        obj:setPosRot(0, 0, -5000, 0, 0, 0, 1)
        local box = obj:getObjBox()
        local min, max = box.minExtents, box.maxExtents
        local x, y, z = max.x - min.x, max.y - min.y, max.z - min.z
        if not (x == x and y == y and z == z) or x <= 0 and y <= 0 and z <= 0 or
            math.max(x, y, z) > 10000 then
            return nil
        end
        return { x = round2(x), y = round2(y), z = round2(z), minZ = round2(min.z) }
    end)
    if obj and simObjectExists(obj) then pcall(function() obj:delete() end) end
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
    for _, path in ipairs({ CACHE_DIR .. shape .. ".png", EDITOR_CACHE_DIR .. shape .. ".png" }) do
        if FS:fileExists(path) then return path end
    end
    return nil
end

---@param shape string
local function notify(shape)
    local url = thumbs[shape]
    beamjoy_communications_ui.send("BJPropThumb", {
        shape = shape,
        url = url or nil,
        size = beamjoy_props.meta[shape:lower()],
    })
end

local function dropJob()
    job = nil
end

--- one step of the thumbnail being made ; true once it's done (made or given up)
---@return boolean
local function stepJob()
    local ok, err = pcall(function()
        if job.stage == "start" then
            local rect = RectI(0, 0, M.THUMB_SIZE, M.THUMB_SIZE)
            job.rect = rect
            job.preview = ShapePreview()
            job.preview:setRenderState(false, false, false, false, false)
            job.preview:setCamRotation(0.3, 0)
            job.preview:setObjectModel(job.shape)
            job.preview:renderWorld(rect)
            job.preview:fitToShape()
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
            FS:directoryCreate(job.path:match("^(.*)/[^/]*$"), true)
            if not bitmap:saveFile(job.path) then error("not saved") end
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
        thumbs[job.shape] = job.path
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
        job = { shape = shape, stage = "start", frames = 0, path = CACHE_DIR .. shape .. ".png" }
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
