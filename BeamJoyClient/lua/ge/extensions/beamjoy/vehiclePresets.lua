--- Client-side cache mirror of the server's shared, map-independent vehicle pool presets (see
--- Server/BeamJoyServer/services/vehiclePresets.lua). Same pattern as races.lua's own cache
--- module, kept as its own standalone extension (not owned by or dependent on the race system)
--- since a future gamemode may want to read M.data / M.getById directly without pulling in
--- anything race-specific.

local M = {
    dependencies = {},

    ---@type BJVehiclePreset[]
    data = {},
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJVehiclePresetListRequest", M.pushListToUI)
    beamjoy_communications_ui.addHandler("BJVehiclePresetCaptureVehicle", M.onCaptureVehicle)
end

local function pushListToUI()
    beamjoy_communications_ui.send("BJVehiclePresetList", M.data)
end

---@param caches table
local function retrieveCache(caches)
    if caches.vehiclePresets then
        M.data = caches.vehiclePresets
        pushListToUI()
    end
end

---@param presetId integer
---@return BJVehiclePreset?
local function getById(presetId)
    return table.find(M.data, function(p) return p.id == presetId end)
end

---@param preset BJVehiclePreset
local function save(preset)
    beamjoy_communications.send("vehiclePresetSave", preset)
end

---@param presetId integer
local function delete(presetId)
    beamjoy_communications.send("vehiclePresetDelete", presetId)
end

--- captures whatever the player is currently driving as a {model, config, label, parts, vars}
--- entry for the preset editor. Same refuse-a-custom-config-outright reasoning the race editor's
--- own (now removed) pool-authoring UI used : a preset entry has to be something the native
--- vehicle selector can actually present as a real, pickable tile for every OTHER player too, so
--- both a fully custom (never saved) setup and a personal local-only save are rejected, not just
--- the former. `config` is still captured (needed for the selector filter), but `parts`/`vars`,
--- what a joining participant's equipped vehicle actually gets matched against, see
--- BJVehiclePresetEntry's own doc in services/vehiclePresets.lua for why, are captured alongside
--- it here too, free : the player is already sitting in a real vehicle to derive `identity` from.
---@param existingEntries {model:string, config:string, label:string, parts:table?, vars:table?}[]?
---the editor's own currently-held (unsaved) entries list, so a duplicate can be caught and toasted
---here. Lua has no other visibility into the Angular-only editing state a preset is being built up in
local function onCaptureVehicle(existingEntries)
    local mpVeh = beamjoy_vehicles.getCurrentOwn()
    if not mpVeh then
        toast.warn("You need to be in a vehicle to capture it", nil, 4)
        return
    end
    local identity = beamjoy_vehicles.getCurrentConfigIdentity(mpVeh.veh)
    if not identity then
        toast.warn(
            "This is a custom (unsaved) configuration and can't be added to a preset. Use a base game or mod configuration instead.",
            nil, 6)
        return
    end
    if not beamjoy_vehicles.isConfigShareable(identity.model, identity.config) then
        toast.warn(
            "This is a personal saved configuration. Other players don't have this file, so it can't be added to a preset. Use a base game or mod configuration instead.",
            nil, 7)
        return
    end
    if table.isArray(existingEntries) and table.any(existingEntries, function(e)
            return e.model == identity.model and e.config == identity.config
        end) then
        toast.warn("Already in this preset", nil, 3)
        return
    end
    local full = beamjoy_vehicles.getFullConfig(mpVeh.veh)
    identity.parts = full and full.parts or {}
    -- captured alongside parts, only ever actually compared when a race's own allowTuning setting
    -- is off (see BJRaceDefaults.allowTuning). Tuning stays freely changeable by default, same
    -- reasoning single mode's own captured vars already have
    identity.vars = full and full.vars or {}
    beamjoy_communications_ui.send("BJVehiclePresetCapturedVehicle", identity)
end

M.onInit = onInit

M.retrieveCache = retrieveCache
M.pushListToUI = pushListToUI
M.getById = getById
M.save = save
M.delete = delete
M.onCaptureVehicle = onCaptureVehicle

return M
