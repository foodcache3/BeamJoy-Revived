--- The server's shared builds (Server/BeamJoyServer/services/vehiclePresets.lua's BJVehicleBuild :
--- custom setups staff added to a vehicle preset) as files in this game :
--- vehicles/<model>/bjs_<id>.pc, its info file (the selector's name and paint) and a picture (the
--- photo taken when it was added, fetched from the server once ; the model's own until then, or
--- for a build without one), the same files the game's own "Save configuration" writes
--- (core/vehicle/partmgmt.lua). That's what puts them in the native vehicle selector and lets
--- anything spawn them by name ("bjs_<id>"), like any factory config. They belong to this server
--- only : removed when leaving it, and a list of what was written (MANIFEST) lets the next join
--- clear what a crash left behind. Only ever touches its own bjs_ files.
---
--- A build only in presets that aren't shown in the selector is still written (an activity's
--- pool may hand it out), but its tile is hidden unless an activity uses one of its presets
--- (onBJRequestCanSpawnVehicle, each runner adding its pool through onBJActiveVehiclePools).

local MANIFEST = "/settings/beamjoy_sharedBuilds.json"
local PHOTO_DIR = "/temp/beamjoy"
-- the game's own thumbnails : 500x281, a 20 degree lens (util/screenshotCreator.lua)
local PHOTO_FOV = 20
local PHOTO_RES = { 500, 281 }
-- the server takes up to this much (services/vehiclePresets.lua)
local MAX_PHOTO_CHARS = 200000
-- slow updates (250ms) to wait for a photo before giving up
local PHOTO_TIMEOUT_TICKS = 24

local M = {
    dependencies = { "beamjoy_vehicles", "beamjoy_vehiclePresets" },

    ---@type BJVehicleBuild[]
    data = {},
    --- files this game holds for the builds : path -> true
    written = {},
    --- the photos among them : path -> the build's photo hash it holds (nil : not read yet)
    photos = nil,
    --- photos asked of the server : build id -> photo hash
    requested = {},
    --- photos written since the selector was last refreshed, and that count a slow update ago
    photoArrivals = 0,
    photoArrivalsSeen = 0,
    --- the photo being taken : {callback, path, ticks}
    pendingPhoto = nil,
}

local jbeamIO = require("jbeam/io")

---@param model any
---@return boolean
local function validModel(model)
    return type(model) == "string" and #model > 0 and #model <= 64 and model:match("^[%w_%-]+$") ~= nil
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:byte(i)] = i - 1 end

---@param data string
---@return string
local function b64encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2 = math.floor(v / 262144) % 64, math.floor(v / 4096) % 64
        local c3, c4 = math.floor(v / 64) % 64, v % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1) ..
            (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

---@param text string
---@return string? nil when it isn't base64
local function b64decode(text)
    text = text:gsub("=+$", "")
    if text:find("[^%w%+/]") or #text % 4 == 1 then return nil end
    local out = {}
    for i = 1, #text, 4 do
        local n, v = 0, 0
        for j = i, math.min(i + 3, #text) do
            v = v * 64 + B64_INDEX[text:byte(j)]
            n = n + 1
        end
        for _ = n + 1, 4 do v = v * 64 end
        local a, b, c = math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256
        out[#out + 1] = string.char(a) .. (n > 2 and string.char(b) or "") .. (n > 3 and string.char(c) or "")
    end
    return table.concat(out)
end

---@param path string
---@return string?
local function readBinary(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--- writeFile writes text : on Windows a picture's bytes would come out changed
---@param path string
---@param data string
---@return boolean
local function writeBinary(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

--- our own files, nothing else : bjs_<id>.pc, info_bjs_<id>.json, bjs_<id>.jpg/.png
---@param path any
---@return boolean
local function isOurs(path)
    if type(path) ~= "string" then return false end
    return path:match("^/vehicles/[%w_%-]+/bjs_%d+%.pc$") ~= nil or
        path:match("^/vehicles/[%w_%-]+/info_bjs_%d+%.json$") ~= nil or
        path:match("^/vehicles/[%w_%-]+/bjs_%d+%.jpg$") ~= nil or
        path:match("^/vehicles/[%w_%-]+/bjs_%d+%.png$") ~= nil
end

--- "bjs_12" -> 12
---@param config any
---@return integer?
local function idOf(config)
    return type(config) == "string" and tonumber(config:match("^bjs_(%d+)$")) or nil
end

---@param id integer?
---@return BJVehicleBuild?
local function getById(id)
    if id == nil then return nil end
    for _, b in ipairs(M.data) do
        if b.id == id then return b end
    end
end

---@return table<string, true>
local function readManifest()
    local out = {}
    local ok, data = pcall(jsonReadFile, MANIFEST)
    if ok and type(data) == "table" and type(data.files) == "table" then
        for _, path in ipairs(data.files) do
            if isOurs(path) then out[path] = true end
        end
    end
    return out
end

--- which build photo each of our pictures holds (a model's own picture stands in until it comes)
---@return table<string, string>
local function readManifestPhotos()
    local out = {}
    local ok, data = pcall(jsonReadFile, MANIFEST)
    if ok and type(data) == "table" and type(data.photos) == "table" then
        for path, hash in pairs(data.photos) do
            if isOurs(path) and type(hash) == "string" then out[path] = hash end
        end
    end
    return out
end

local function writeManifest()
    local files = {}
    for path in pairs(M.written) do table.insert(files, path) end
    if #files == 0 then
        pcall(function() FS:removeFile(MANIFEST) end)
    else
        local photos = {}
        for path, hash in pairs(M.photos or {}) do
            if M.written[path] then photos[path] = hash end
        end
        pcall(jsonWriteFile, MANIFEST, { files = files, photos = photos }, true)
    end
end

--- the game's vehicle lists read files once : after a change they're read again, like after the
--- game's own "Save configuration"
local function refreshCaches()
    if extensions.core_vehicles and extensions.core_vehicles.clearCache then
        pcall(extensions.core_vehicles.clearCache)
    end
    if extensions.ui_vehicleSelector_general and extensions.ui_vehicleSelector_general.clearCache then
        pcall(extensions.ui_vehicleSelector_general.clearCache)
    end
    -- BeamJoy's own list of models and configs : read again the next time it's needed
    beamjoy_vehicles.allVehicleConfigs = nil
    extensions.hook("onBJVehiclesCacheUpdate")
    -- the selector's first open needs the game's catalog warm (see vehicleSelector.lua's prewarm)
    if beamjoy_main and beamjoy_main.client_ready and vehicleSelector and vehicleSelector.prewarm then
        pcall(vehicleSelector.prewarm)
    end
end

--- the files one build needs : path -> {content = text} or {copy = source path}
---@param build BJVehicleBuild
---@param out table
local function filesFor(build, out)
    local key = "bjs_" .. tostring(build.id)
    local dir = "/vehicles/" .. build.model .. "/"
    local paints = type(build.pc.paints) == "table" and build.pc.paints or {}
    local pc = {
        format = 2,
        model = build.model,
        mainPartName = build.pc.mainPartName,
        parts = build.pc.parts,
        vars = build.pc.vars or {},
        paints = #paints > 0 and paints or nil,
    }
    local info = {
        Configuration = string.format("%s (%s)", build.name, build.author or "?"),
        Description = beamjoy_lang.translate("beamjoy.vehicleBuilds.description",
            "Shared on this server by {author}"):gsub("{author}", build.author or "?"),
    }
    if #paints > 0 and extensions.core_vehiclePaints and extensions.core_vehiclePaints.writePcPaintsAsInfoPaints then
        -- the selector spawns a config in its info file's paints : the build's own
        pcall(extensions.core_vehiclePaints.writePcPaintsAsInfoPaints, { paints = deepcopy(paints) }, info, key)
    end
    out[dir .. key .. ".pc"] = { content = jsonEncode(pc) }
    out[dir .. "info_" .. key .. ".json"] = { content = jsonEncode(info) }
    -- its picture : its photo (asked of the server, the model's own .jpg standing in until it
    -- comes), else the model's own. Only ever one : the selector shows a .png before a .jpg
    if type(build.photo) == "string" then
        out[dir .. key .. ".jpg"] = { photo = build.photo, buildId = build.id,
            standIn = FS:fileExists(dir .. "default.jpg") and dir .. "default.jpg" or nil }
        return
    end
    for _, ext in ipairs({ "jpg", "png" }) do
        if FS:fileExists(dir .. "default." .. ext) then
            out[dir .. key .. "." .. ext] = { copy = dir .. "default." .. ext }
            break
        end
    end
end

---@param id integer
---@param hash string
local function requestPhoto(id, hash)
    if M.requested[id] == hash then return end
    M.requested[id] = hash
    beamjoy_communications.send("vehicleBuildPhoto", id)
end

--- this game's files match the server's builds : new and changed ones written, gone ones removed
local function sync()
    local wanted = {}
    for _, build in ipairs(M.data) do
        if type(build) == "table" and type(build.id) == "number" and validModel(build.model) and
            type(build.pc) == "table" and type(build.pc.parts) == "table" and type(build.name) == "string" and
            FS:directoryExists("/vehicles/" .. build.model) then
            filesFor(build, wanted)
        end
    end

    local changed = false
    if not M.photos then M.photos = readManifestPhotos() end
    local known = readManifest()
    for path in pairs(M.written) do known[path] = true end
    for path in pairs(known) do
        if not wanted[path] and isOurs(path) and FS:fileExists(path) then
            FS:removeFile(path)
            changed = true
        end
    end

    M.written = {}
    for path, file in pairs(wanted) do
        if file.content then
            if readFile(path) ~= file.content then
                pcall(function() FS:directoryCreate(path:match("^(.*)/[^/]+$"), true) end)
                if writeFile(path, file.content) then changed = true end
            end
        elseif file.photo then
            if M.photos[path] ~= file.photo or not FS:fileExists(path) then
                if M.photos[path] ~= nil then
                    -- an older photo : the stand-in until the new one comes
                    M.photos[path] = nil
                    if FS:fileExists(path) then FS:removeFile(path) end
                end
                if not FS:fileExists(path) and file.standIn then
                    FS:copyFile(file.standIn, path)
                    changed = true
                end
                requestPhoto(file.buildId, file.photo)
            end
        elseif not FS:fileExists(path) then
            FS:copyFile(file.copy, path)
            changed = true
        end
        M.written[path] = true
    end
    writeManifest()
    if changed then refreshCaches() end
end

--- leaving : this server's builds go with it
local function removeAll()
    local known = readManifest()
    for path in pairs(M.written) do known[path] = true end
    local any = false
    for path in pairs(known) do
        if isOurs(path) and FS:fileExists(path) then
            FS:removeFile(path)
            any = true
        end
    end
    M.written = {}
    M.photos = {}
    M.requested = {}
    writeManifest()
    if any and extensions.core_vehicles and extensions.core_vehicles.clearCache then
        pcall(extensions.core_vehicles.clearCache)
    end
end

---@param caches table
local function retrieveCache(caches)
    if caches.vehicleBuilds then
        M.data = table.isArray(caches.vehicleBuilds) and caches.vehicleBuilds or {}
        sync()
        beamjoy_vehiclePresets.pushListToUI()
    end
end

--- the builds as the preset editor needs them (names in use, who added them)
---@return {id: integer, model: string, name: string, author: string}[]
local function listForUI()
    local out = {}
    for _, b in ipairs(M.data) do
        -- photo : its hash once this game holds it (the editor shows it, the hash keeping CEF's cache honest)
        local held = type(b.photo) == "string" and M.photos ~= nil and
            M.photos["/vehicles/" .. tostring(b.model) .. "/bjs_" .. tostring(b.id) .. ".jpg"] == b.photo
        table.insert(out, { id = b.id, model = b.model, name = b.name, author = b.author, modelLabel = b.modelLabel,
            photo = held and b.photo or nil })
    end
    return out
end

--- where a part's file comes from, when other players may not have it : nil for the game's own
--- and for mods this server sends (BeamMP keeps them in mods/multiplayer), else what to name
---@param file string
---@return string?
local function foreignSource(file)
    local ok, real = pcall(function() return FS:getFileRealPath(file) end)
    if not ok or type(real) ~= "string" or real == "" then return nil end
    real = real:gsub("\\", "/")
    local lower = real:lower()
    local game = tostring(FS:getGamePath() or ""):gsub("\\", "/"):lower()
    if #game > 0 and lower:sub(1, #game) == game then return nil end
    if lower:find("/mods/multiplayer/", 1, true) then return nil end
    return real:match("([^/]+%.[zZ][iI][pP])") or
        beamjoy_lang.translate("beamjoy.vehicleBuilds.ownFiles", "your own vehicle files")
end

--- A photo of a car where it stands, for its build's tile : the game's own thumbnail framing and
--- camera (util/screenshotCreator.lua's frameVehicle and takeThumbnailScreenshot, what its "Save
--- configuration" preview uses). That camera is a separate view : the player's own camera, the
--- car and the physics aren't touched (unlike the screenshot creator's batch work, which respawns
--- cars and speeds physics up). The game's UI hides for a moment while it's taken, and a ghosted
--- car shows solid for it (beamjoy_vehicles.setPhotoSubject : only the look, not its collisions).
---@param veh NGVehicle
---@param callback fun(photo: string?) the JPEG as base64, nil when it couldn't be taken
local function takePhoto(veh, callback)
    if M.pendingPhoto then
        callback(nil)
        return
    end
    if not extensions.isExtensionLoaded("util_screenshotCreator") then
        pcall(extensions.load, "util_screenshotCreator")
    end
    local creator = extensions.util_screenshotCreator
    if not veh or not creator or not creator.frameVehicle or not creator.takeThumbnailScreenshot then
        callback(nil)
        return
    end
    local okFrame, pos, rot = pcall(creator.frameVehicle, veh, PHOTO_FOV, 0.1, PHOTO_RES[1] / PHOTO_RES[2], PHOTO_RES)
    if not okFrame or not pos or not rot then
        callback(nil)
        return
    end
    pcall(function() FS:directoryCreate(PHOTO_DIR, true) end)
    local path = string.format("%s/buildPhoto%d.jpg", PHOTO_DIR, math.random(100000, 999999))
    -- a ghosted car is see-through : solid for the shot, its real look back after
    local setSubject = beamjoy_vehicles and beamjoy_vehicles.setPhotoSubject
    local pending = { path = path, ticks = 0 }
    pending.finish = function(success)
        if M.pendingPhoto ~= pending then return end
        M.pendingPhoto = nil
        if setSubject then pcall(setSubject, nil) end
        local data = success and readBinary(path) or nil
        pcall(function() FS:removeFile(path) end)
        local photo = data and #data > 0 and data:sub(1, 3) == "\255\216\255" and b64encode(data) or nil
        if photo and #photo > MAX_PHOTO_CHARS then photo = nil end
        callback(photo)
    end
    M.pendingPhoto = pending
    if setSubject then pcall(setSubject, veh:getID()) end
    local ok = pcall(creator.takeThumbnailScreenshot, path,
        { pos = pos, rot = rot, fov = PHOTO_FOV, screenshotDelay = 0.2 },
        function(success) pending.finish(success == true) end, "beamjoyBuild")
    if not ok then pending.finish(false) end
end

--- the car you're in is this build : the same model, parts and paints
---@param veh NGVehicle
---@param model string
---@param pc table the build's .pc content
---@return boolean
local function isThisBuild(veh, model, pc)
    local data = veh and extensions.core_vehicle_manager.getVehicleData(veh:getID())
    local cfg = data and data.config
    if not cfg or not cfg.partsTree or (cfg.model or veh.jbeam) ~= model or type(pc) ~= "table" then
        return false
    end
    local parts = extensions.core_vehicle_partmgmt.partsTreeToPartsMap(cfg.partsTree)
    if not table.compare(parts, pc.parts or {}, true) then return false end
    for i, paint in ipairs(type(pc.paints) == "table" and pc.paints or {}) do
        local mine = type(cfg.paints) == "table" and cfg.paints[i]
        if type(mine) ~= "table" or type(mine.baseColor) ~= "table" or type(paint.baseColor) ~= "table" then
            return false
        end
        for c = 1, 4 do
            if math.abs((tonumber(mine.baseColor[c]) or 0) - (tonumber(paint.baseColor[c]) or 0)) > 0.002 then
                return false
            end
        end
    end
    return true
end

--- a build's photo, from the server
---@param id integer
---@param hash string
---@param photo string base64
local function onPhoto(id, hash, photo)
    local build = getById(tonumber(id))
    if not build or build.photo ~= hash or type(photo) ~= "string" or #photo > MAX_PHOTO_CHARS or
        not validModel(build.model) then
        return
    end
    local data = b64decode(photo)
    if not data or data:sub(1, 3) ~= "\255\216\255" then return end
    local path = "/vehicles/" .. build.model .. "/bjs_" .. tostring(build.id) .. ".jpg"
    if not FS:directoryExists("/vehicles/" .. build.model) then return end
    if not writeBinary(path, data) then return end
    M.photos = M.photos or {}
    M.photos[path] = hash
    M.written[path] = true
    writeManifest()
    M.photoArrivals = M.photoArrivals + 1
end

--- the selector reads pictures again once photos stop coming (they come one by one on joining) ;
--- a photo being taken gives up after a while
local function onSlowUpdate()
    if M.photoArrivals > 0 then
        if M.photoArrivals == M.photoArrivalsSeen then
            M.photoArrivals, M.photoArrivalsSeen = 0, 0
            refreshCaches()
            beamjoy_vehiclePresets.pushListToUI()
        else
            M.photoArrivalsSeen = M.photoArrivals
        end
    end
    local pending = M.pendingPhoto
    if pending then
        pending.ticks = pending.ticks + 1
        if pending.ticks > PHOTO_TIMEOUT_TICKS then pending.finish(false) end
    end
end

--- The car you're in, as a shared build for the preset editor : its parts as a .pc file has them,
--- its tuning and paints. Refused when other players couldn't build it (a part from a mod this
--- server doesn't send).
---@param veh NGVehicle
---@return table? entry, string? error
local function capture(veh)
    local data = extensions.core_vehicle_manager.getVehicleData(veh:getID())
    local cfg = data and data.config
    if not cfg or not cfg.partsTree then
        return nil, beamjoy_lang.translate("beamjoy.vehicleBuilds.noData", "Can't read this vehicle's setup")
    end
    local model = cfg.model or veh.jbeam
    if not validModel(model) then
        return nil, beamjoy_lang.translate("beamjoy.vehicleBuilds.noData", "Can't read this vehicle's setup")
    end
    local parts = extensions.core_vehicle_partmgmt.partsTreeToPartsMap(cfg.partsTree)

    local foreign, seen = {}, {}
    local function check(partName)
        if type(partName) ~= "string" or partName == "" or not data.ioCtx then return end
        local ok, _, file = pcall(jbeamIO.getPart, data.ioCtx, partName)
        if not ok or type(file) ~= "string" then return end
        local source = foreignSource(file)
        if source and not seen[source] then
            seen[source] = true
            table.insert(foreign, source)
        end
    end
    check(cfg.mainPartName)
    for _, partName in pairs(parts) do check(partName) end
    if #foreign > 0 then
        return nil, beamjoy_lang.translate("beamjoy.vehicleBuilds.foreignParts",
            "Other players can't build this car: it uses parts from {sources}, which this server doesn't send")
            :gsub("{sources}", table.concat(foreign, ", "))
    end

    local full = beamjoy_vehicles.getFullConfig(veh) or {}
    local modelLabel = beamjoy_vehicles.getModelLabel(model)
    -- a personal saved config : its name to start with
    local name = ""
    local partConfig = tostring(veh.partConfig or "")
    if partConfig:endswith(".pc") then
        local key = partConfig:gsub("^.*/", ""):gsub("%.pc$", "")
        -- the name it was saved under (getConfigLabel says "?" for a save it hasn't cached)
        local modelData = core_vehicles.getModel(model)
        local config = modelData and modelData.configs and modelData.configs[key]
        name = config and type(config.Configuration) == "string" and config.Configuration or key
    end
    local paints = {}
    for i = 1, 3 do
        if type(cfg.paints) == "table" and type(cfg.paints[i]) == "table" then paints[i] = cfg.paints[i] else break end
    end
    return {
        model = model,
        modelLabel = modelLabel,
        name = name,
        label = string.format("%s - %s", modelLabel, name),
        pc = { parts = parts, vars = cfg.vars or {}, paints = paints, mainPartName = cfg.mainPartName },
        -- what a joining racer's car is matched against, like every preset entry
        parts = full.parts or {},
        vars = full.vars or {},
    }
end

--- A build's tile shows for everyone when one of its presets says so ; otherwise only while an
--- activity uses one of its presets as the pool (it may hand the build out). A bjs_ name that
--- isn't one of this server's builds is refused.
---@param req RequestAuthorization
---@param model string
---@param config string?
local function onBJRequestCanSpawnVehicle(req, model, config)
    local id = idOf(config)
    if not id then return end
    local build = getById(id)
    if not build or build.model ~= model then
        req.state = false
        return
    end
    for _, preset in ipairs(beamjoy_vehiclePresets.data or {}) do
        if preset.showInSelector ~= false then
            for _, e in ipairs(preset.entries or {}) do
                if e.buildId == id then return end
            end
        end
    end
    local pools = {}
    extensions.hook("onBJActiveVehiclePools", pools)
    for _, pool in ipairs(pools) do
        for _, e in ipairs(pool) do
            if e.model == model and e.config == config then return end
        end
    end
    req.state = false
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications.addHandler("vehicleBuildPhoto", M.onPhoto)
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate
M.onServerLeave = removeAll
M.onExtensionUnloaded = removeAll
M.onPreExit = removeAll
M.onBJRequestCanSpawnVehicle = onBJRequestCanSpawnVehicle

M.retrieveCache = retrieveCache
M.idOf = idOf
M.getById = getById
M.listForUI = listForUI
M.capture = capture
M.takePhoto = takePhoto
M.isThisBuild = isThisBuild
M.onPhoto = onPhoto
M.b64encode = b64encode
M.b64decode = b64decode

return M
