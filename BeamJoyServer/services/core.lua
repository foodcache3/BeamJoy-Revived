local M = {
    data = {
        Debug = false,
        Private = true,
        MaxCars = 200,
        MaxPlayers = 10,
        Map = "/levels/gridmap_v2/info.json",
        Name = "My Awesome BeamJoy Server",
        Description = "This server is not configured yet but can you play with it !",
        InformationPacket = false,
    },
    default = {},
}

---@return table
local function retrieveEnvConfig()
    if os.getenv("BEAMMP_NAME") ~= nil then
        return {
            Debug = os.getenv("BEAMMP_DEBUG"),
            Private = os.getenv("BEAMMP_PRIVATE"),
            MaxCars = os.getenv("BEAMMP_MAX_CARS"),
            MaxPlayers = os.getenv("BEAMMP_MAX_PLAYERS"),
            Map = os.getenv("BEAMMP_MAP"),
            Name = os.getenv("BEAMMP_NAME"),
            Description = os.getenv("BEAMMP_DESCRIPTION"),
            InformationPacket = os.getenv("BEAMMP_INFORMATION_PACKET"),
        }
    end
    LogWarn(
        "Your BeamMP hosting provider is preventing BeamJoy from reading the configuration. It will be reset to default, and you will need to update it manually using the interface or by editing the 'Server/BeamJoyData/db/core.json' file."
    )
    return M.data
end

local function onPreInit()
    M.default = table.clone(M.data)
    local tomlConfig = dao_core.getServerConfig()
    local loaded = tomlConfig and tomlConfig.General or dao_core.get()
    if not loaded then
        M.data = retrieveEnvConfig()
        dao_core.save(M.data)
    else
        M.data = table.assign(M.data, loaded)
        -- was `M.data.MaxCars == 200 and M.data.MaxCars or 200` : both branches of that ternary
        -- evaluate to 200 regardless of the loaded value, unconditionally discarding whatever the
        -- admin actually configured (ServerConfig.toml, env var, or the core config UI) and
        -- silently re-pushing 200 into BeamMP-Server's real MaxCars setting via MP.Set below on
        -- every server start. Only fall back to the default when the loaded value is missing/
        -- invalid, same as every other coercion in this codebase.
        M.data.MaxCars = tonumber(M.data.MaxCars) or 200
        table.forEach(M.data, function(v, k)
            if MP.Settings[k] and
                MP.Get(MP.Settings[k]) ~= v then
                MP.Set(MP.Settings[k], v)
            elseif not MP.Settings[k] then
                M.data[k] = nil
            end
        end)
        if not table.compare(M.data, loaded) then
            dao_core.save(M.data)
        end
    end
end

local function onInit()
    communications_rx.addHandler("setCore", M.set)
end

---@param caches table
---@param targetID integer?
local function onBJRequestCache(caches, targetID)
    if targetID and services_permissions.hasAllPermissions(targetID,
            BJ_PERMISSIONS.SetCore) then
        caches.core = {
            Name = M.data.Name,
            Description = M.data.Description,
            Private = M.data.Private,
            Debug = M.data.Debug,
            MaxPlayers = M.data.MaxPlayers,
            InformationPacket = M.data.InformationPacket,
        }
    end
end

---@param key string
---@param value any
---@return any value
local function parseConfigValue(key, value)
    -- numbers
    if table.includes({ "MaxPlayers" }, key) then
        return tonumber(value) and math.round(value) or nil
    end
    -- booleans
    if table.includes({ "Debug", "Private", "InformationPacket" }, key) then
        if type(value) == "string" then
            if value == "true" then return true end
            if value == "false" then return false end
        elseif type(value) == "boolean" then
            return value == true
        end
        return
    end
    -- strings
    if table.includes({ "Name", "Description" }, key) then
        if type(value) == "string" then
            if key == "Name" then
                value = value:gsub("%^p", "") -- remove newline codes
            end
            return value
        end
        return
    end
end

---@param key string
---@param value any
---@return boolean
local function validateConfig(key, value)
    -- invalid fields
    if not MP.Settings[key] then return false end
    -- reserved fields
    if table.includes({ "MaxCars", "Map" }, key) then return false end
    -- value validator
    if table.includes({ "MaxPlayers" }, key) then
        return type(value) == "number" and value > 0
    elseif table.includes({ "Debug", "Private", "InformationPacket" }, key) then
        return type(value) == "boolean"
    elseif table.includes({ "Name", "Description" }, key) then
        if type(value) ~= "string" then return false end
        if key == "Name" and (#value < 3 or #value > 150) then return false end
        if key == "Description" and (#value < 3 or #value > 500) then return false end
        return true
    end
    return false
end

---@param ctxt BJSContext
---@param key string
---@param value any
local function set(ctxt, key, value)
    if ctxt.sender then
        if not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.SetCore) then
            return
        end
    end

    local finalValue
    if value == nil then
        finalValue = M.default[key]
    else
        finalValue = parseConfigValue(key, value)
        if not validateConfig(key, finalValue) then
            LogError(string.format("Invalid value for key %s : %s (parsed to %s)",
                key, tostring(value), tostring(finalValue)))
            return
        end
    end

    if M.data[key] ~= finalValue then
        M.data[key] = finalValue
        MP.Set(MP.Settings[key], finalValue)
        dao_core.save(M.data)
    end

    services_players.players:filter(function(p)
        return services_permissions.hasAllPermissions(p.playerID,
            BJ_PERMISSIONS.SetCore)
    end):forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches, p.playerID)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

---@return string
local function getCurrentMap()
    local res = tostring(M.data.Map)
        :gsub("^/levels/", "")
        :gsub("/info.json$", "")
    return res
end

local function setMap(name)
    local fullname = string.format("/levels/%s/info.json", name)
    if fullname ~= M.data.Map then
        M.data.Map = fullname
        MP.Set(MP.Settings.Map, fullname)
        dao_core.save(M.data)
    end
end

M.onPreInit = onPreInit
M.onInit = onInit
M.onBJRequestCache = onBJRequestCache

M.getCurrentMap = getCurrentMap
M.set = set
M.setMap = setMap

return M
