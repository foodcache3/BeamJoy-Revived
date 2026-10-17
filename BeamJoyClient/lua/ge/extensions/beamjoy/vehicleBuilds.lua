--- The server's shared builds (Server/BeamJoyServer/services/vehiclePresets.lua's BJVehicleBuild :
--- custom setups staff added to a vehicle preset) as files in this game :
--- vehicles/<model>/bjs_<id>.pc, its info file (the selector's name and paint) and a picture (the
--- model's own), the same files the game's own "Save configuration" writes
--- (core/vehicle/partmgmt.lua). That's what puts them in the native vehicle selector and lets
--- anything spawn them by name ("bjs_<id>"), like any factory config. They belong to this server
--- only : removed when leaving it, and a list of what was written (MANIFEST) lets the next join
--- clear what a crash left behind. Only ever touches its own bjs_ files.
---
--- A build only in presets that aren't shown in the selector is still written (an activity's
--- pool may hand it out), but its tile is hidden unless an activity uses one of its presets
--- (onBJRequestCanSpawnVehicle, each runner adding its pool through onBJActiveVehiclePools).

local MANIFEST = "/settings/beamjoy_sharedBuilds.json"

local M = {
    dependencies = { "beamjoy_vehicles", "beamjoy_vehiclePresets" },

    ---@type BJVehicleBuild[]
    data = {},
    --- files this game holds for the builds : path -> true
    written = {},
}

local jbeamIO = require("jbeam/io")

---@param model any
---@return boolean
local function validModel(model)
    return type(model) == "string" and #model > 0 and #model <= 64 and model:match("^[%w_%-]+$") ~= nil
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

local function writeManifest()
    local files = {}
    for path in pairs(M.written) do table.insert(files, path) end
    if #files == 0 then
        pcall(function() FS:removeFile(MANIFEST) end)
    else
        pcall(jsonWriteFile, MANIFEST, { files = files }, true)
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
    -- its picture : the model's own (the game's thumbnail tool takes over the camera and physics)
    for _, ext in ipairs({ "jpg", "png" }) do
        if FS:fileExists(dir .. "default." .. ext) then
            out[dir .. key .. "." .. ext] = { copy = dir .. "default." .. ext }
            break
        end
    end
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
        table.insert(out, { id = b.id, model = b.model, name = b.name, author = b.author, modelLabel = b.modelLabel })
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
        name = beamjoy_vehicles.getConfigLabel(model, key) or key
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
end

M.onInit = onInit
M.onServerLeave = removeAll
M.onExtensionUnloaded = removeAll
M.onPreExit = removeAll
M.onBJRequestCanSpawnVehicle = onBJRequestCanSpawnVehicle

M.retrieveCache = retrieveCache
M.idOf = idOf
M.getById = getById
M.listForUI = listForUI
M.capture = capture

return M
