--- Vehicle-delivery pool, admin side (see services/deliveries.lua's VEHICLE POOL section).
---
--- The server has no vehicle list, so an admin's client (SetConfig) builds the pool from its own
--- installed vehicles and uploads it. BJS clients only ever have stock vehicles + server mods
--- active (beamjoy mods.lua disables everything else), so what this client has is what every
--- player has. Uploaded automatically once when the server has no pool yet, and again whenever the
--- admin presses "Refresh" in Config > General > Deliveries (after adding vehicle mods).
---
--- Eligible : every Car / Truck model (trucks by the model's own Type), configs whose "Config
--- Type" is Factory, Service or unset - and when a model has none of those (common for mods), its
--- Custom ones. Police / Race / Rally / Drift builds are left out : they're not what a depot ships.

local M = {
    dependencies = { "beamjoy_vehicles", "beamjoy_permissions" },

    ALLOWED_CONFIG_TYPES = { Factory = true, Service = true },
    ---@type table? last summary from the server, for the settings panel
    summary = nil,
    autoUploaded = false,
    building = false,
}

---@param config table NGVehicleConfig
---@return string?
local function configType(config)
    local t = config["Config Type"]
    if type(t) == "string" then return t end
    local agg = config.aggregates and config.aggregates["Config Type"]
    if type(agg) == "table" then return next(agg) end
end

---@param model table NGVehicleModel
---@return table[] eligible configs
local function eligibleConfigs(model)
    local primary, custom = {}, {}
    for key, config in pairs(model.configs or {}) do
        local t = configType(config)
        if t == nil or M.ALLOWED_CONFIG_TYPES[t] then
            primary[#primary + 1] = { key = key, label = config.label or key }
        elseif t == "Custom" then
            custom[#custom + 1] = { key = key, label = config.label or key }
        end
    end
    return #primary > 0 and primary or custom
end

--- builds and uploads the pool in a background job (the vehicle database is large)
local function buildAndUpload()
    if M.building then return end
    M.building = true
    beamjoy_communications_ui.send("BJDeliveryPoolBuilding", true)
    core_jobsystem.create(function(job)
        local list = {}
        local models = beamjoy_vehicles.getAllVehicleConfigs(job, { cars = true, trucks = true })
        for key, model in pairs(models) do
            local kind = model.Type == beamjoy_vehicles.TYPES.TRUCK and "trucks"
                or model.Type == beamjoy_vehicles.TYPES.CAR and "cars" or nil
            if kind then
                for _, c in ipairs(eligibleConfigs(model)) do
                    list[#list + 1] = {
                        model = key,
                        config = c.key,
                        label = string.format("%s %s", model.label or key, c.label),
                        modelLabel = model.label or key,
                        configLabel = c.label,
                        kind = kind,
                    }
                end
            end
            job.yield()
        end
        beamjoy_communications.send("deliveryPoolSave", list)
        M.building = false
        beamjoy_communications_ui.send("BJDeliveryPoolBuilding", false)
    end)
end

local function pushToUI()
    beamjoy_communications_ui.send("BJDeliveryPool", M.summary or { count = 0, models = {} })
end

---@param caches table
local function retrieveCache(caches)
    if not caches.deliveryPool then return end
    M.summary = caches.deliveryPool
    pushToUI()
    -- first admin to connect to a server with no pool yet fills it, once per session
    if (M.summary.count or 0) == 0 and not M.autoUploaded and
        beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.SetConfig) then
        M.autoUploaded = true
        buildAndUpload()
    end
end

--- a whole model (config nil) or one of its configs
---@param model string
---@param blacklisted boolean
---@param config string?
local function setBlacklisted(model, blacklisted, config)
    beamjoy_communications.send("deliveryPoolBlacklist", model, blacklisted == true, config)
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", retrieveCache)
    beamjoy_communications_ui.addHandler("BJDeliveryPoolRequest", pushToUI)
    beamjoy_communications_ui.addHandler("BJDeliveryPoolRefresh", buildAndUpload)
    beamjoy_communications_ui.addHandler("BJDeliveryPoolBlacklist", setBlacklisted)
end

M.onInit = onInit
M.buildAndUpload = buildAndUpload

return M
