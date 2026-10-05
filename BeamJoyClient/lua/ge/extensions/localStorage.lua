local M = {
    -- global values are shared between all beamjoy servers
    GLOBAL_VALUES = {
        UI_SCALE = {
            key = "beamjoy.ui_scale",
            default = 1,
        },

        AUTOMATIC_LIGHTS = {
            key = "beamjoy.vehicle.automatic_lights",
            default = false,
        },
        -- Settings > Visual > Dust and particles, 0-100 % (beamjoy/particles.lua)
        PARTICLE_AMOUNT = {
            key = "beamjoy.vehicle.particle_amount",
            default = 100,
        },
        -- Settings > Vehicle > Lock my vehicles (beamjoy/vehicleInteractions.lua)
        LOCK_VEHICLES = {
            key = "beamjoy.vehicle.lock_vehicles",
            default = false,
        },
        -- Settings > Visual (beamjoy/markerSettings.lua)
        HIDE_ACTIVITY_MARKERS = {
            key = "beamjoy.markers.hide_activities",
            default = false,
        },
        HIDE_STATION_MARKERS = {
            key = "beamjoy.markers.hide_stations",
            default = false,
        },
        -- Settings > Visual > Disable ghost transparency (beamjoy/markerSettings.lua)
        OPAQUE_GHOSTS = {
            key = "beamjoy.visual.opaque_ghosts",
            default = false,
        },
        -- Settings > Vehicle > Police chases (beamjoy/playerPursuit.lua, beamjoy/pursuit.lua)
        ALLOW_POLICE_CHASES = {
            key = "beamjoy.pursuit.allow_chases",
            default = true,
        },

        NAMETAGS_COLOR_PLAYER_TEXT = {
            key = "beamjoy.nametags.colors.player.text",
            default = BJColor(1, 1, 1),
        },
        NAMETAGS_COLOR_PLAYER_BG = {
            key = "beamjoy.nametags.colors.player.bg",
            default = BJColor(0, 0, 0),
        },
        NAMETAGS_COLOR_IDLE_TEXT = {
            key = "beamjoy.nametags.colors.idle.text",
            default = BJColor(1, .6, 0),
        },
        NAMETAGS_COLOR_IDLE_BG = {
            key = "beamjoy.nametags.colors.idle.bg",
            default = BJColor(0, 0, 0),
        },
        NAMETAGS_COLOR_SPEC_TEXT = {
            key = "beamjoy.nametags.colors.spec.text",
            default = BJColor(.6, .6, 1),
        },
        NAMETAGS_COLOR_SPEC_BG = {
            key = "beamjoy.nametags.colors.spec.bg",
            default = BJColor(0, 0, 0),
        },

        FREECAM_SMOOTH = {
            key = "beamjoy.freecam.smooth",
            default = false,
        },
        FREECAM_FOV = {
            key = "beamjoy.freecam.fov",
            default = 65,
        },
        FREECAM_SPEED = {
            key = "beamjoy.freecam.speed",
            default = 30,
        },
    },

    -- values are specific to a server
    VALUES = {},

    data = {
        global = {},
        values = {},
    },
}
local VALUES_KEY = "beamjoy.values"

local function getServerIP()
    local srvData = GetServerInfos()
    return srvData and string.format("%s:%s", srvData.ip, tostring(srvData.port)) or nil
end

local function onInit()
    ---@param parent table
    ---@param storageKey string
    ---@param cacheKey string
    ---@param defaultValue any
    local function initStorageKey(parent, storageKey, cacheKey, defaultValue)
        local value = settings.getValue(storageKey)
        if value == nil then
            parent[cacheKey] = defaultValue
            local payload = type(defaultValue) == "table" and
                jsonEncode(defaultValue) or
                tostring(defaultValue)
            LogDebug(string.format("Assigning default setting value \"%s\" to \"%s\"", cacheKey, tostring(payload)))
            settings.setValue(storageKey, payload)
        else
            if type(defaultValue) == "table" then
                parent[cacheKey] = jsonDecode(value)
            elseif type(defaultValue) == "number" then
                parent[cacheKey] = tonumber(value)
            elseif type(defaultValue) == "boolean" then
                parent[cacheKey] = value == "true" and true or false
            else
                parent[cacheKey] = value
            end
        end
    end
    ---@param el LocalStorageElement
    table.forEach(M.GLOBAL_VALUES, function(el)
        initStorageKey(M.data.global, el.key, el.key, el.default)
    end)

    local srvIP = getServerIP()
    if srvIP then
        ---@param el LocalStorageElement
        table.forEach(M.VALUES, function(el)
            local key = string.format("%s-%s-%s", VALUES_KEY, srvIP, el.key)
            initStorageKey(M.data.values, key, el.key, el.default)
        end)
    end
end

---@param key LocalStorageElement
---@return any
local function get(key)
    if type(key) ~= "table" or not key.key then
        LogError(string.format("Invalid key \"%s\"", key and key.key or "nil"), M._name)
        return nil
    end
    local parent = table.find(M.GLOBAL_VALUES, function(el) return el == key end) and M.data.global or
        table.find(M.VALUES, function(el) return el == key end) and M.data.values or nil
    if not parent then
        LogError(string.format("Invalid key \"%s\"", key and key.key or "nil"), M._name)
        return nil
    end

    local value = parent[key.key]
    if type(value) == "table" then
        return table.clone(value)
    end
    return value
end

---@param key LocalStorageElement
---@param value? any
local function set(key, value)
    if type(key) ~= "table" or not key.key then
        LogError(string.format("Invalid key \"%s\"", key and key.key or "nil"), M._name)
        return nil
    end
    local parent = table.find(M.GLOBAL_VALUES, function(el) return el == key end) and M.data.global or
        table.find(M.VALUES, function(el) return el == key end) and M.data.values or nil
    if not parent then
        LogError(string.format("Invalid key \"%s\"", key and key.key or "nil"), M._name)
        return nil
    end

    if table.includes({ "function", "userdata", "cdata" }, type(value)) then
        LogError(string.format("Invalid value type for key %s : %s", key.key, type(value)), M._name)
        return
    end

    parent[key.key] = value
    local parsed
    if type(value) == "table" then
        parsed = jsonEncode(value)
    elseif value ~= nil then
        parsed = tostring(value)
    end
    local storageKey = parent == M.data.global and key.key or
        string.format("%s-%s-%s", VALUES_KEY, getServerIP(), key.key)
    settings.setValue(storageKey, parsed)
end

M.onInit = onInit

M.get = get
M.set = set

return M
