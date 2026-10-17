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
    -- the shared builds' names, for the editor to say when one's taken
    if beamjoy_vehicleBuilds then
        beamjoy_communications_ui.send("BJVehicleBuildList", beamjoy_vehicleBuilds.listForUI())
    end
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

--- captures whatever the player is currently driving as an entry for the preset editor :
--- - a base game or mod configuration (every player has its file) : {model, config, label, parts, vars}
--- - one of this server's shared builds, picked from the selector : that build ({buildId, name})
--- - anything else (a custom setup, a personal saved config) : a new shared build, with its .pc
---   content (`pc`) and a name to give it in the editor. The server keeps it and every player's
---   game writes it as a file (see beamjoy/vehicleBuilds.lua), so it's a real, pickable tile for
---   everyone. Refused when it uses parts from a mod the server doesn't send.
--- `parts`/`vars`, what a joining participant's equipped vehicle actually gets matched against
--- (see BJVehiclePresetEntry's own doc in services/vehiclePresets.lua for why), are captured
--- alongside every kind.
---@param existingEntries table[]? the editor's own currently-held (unsaved) entries list, so a
---duplicate can be caught and toasted here. Lua has no other visibility into the Angular-only
---editing state a preset is being built up in
local function onCaptureVehicle(existingEntries)
    local mpVeh = beamjoy_vehicles.getCurrentOwn()
    if not mpVeh then
        toast.warn("You need to be in a vehicle to capture it", nil, 4)
        return
    end
    local entries = table.isArray(existingEntries) and existingEntries or {}
    local function already(matchFn)
        if table.any(entries, matchFn) then
            toast.warn("Already in this preset", nil, 3)
            return true
        end
        return false
    end
    local full = beamjoy_vehicles.getFullConfig(mpVeh.veh)
    local identity = beamjoy_vehicles.getCurrentConfigIdentity(mpVeh.veh)
    local buildId = identity and beamjoy_vehicleBuilds.idOf(identity.config)

    -- one of this server's shared builds
    local build = beamjoy_vehicleBuilds.getById(buildId)
    if build then
        if already(function(e) return e.buildId == build.id end) then return end
        beamjoy_communications_ui.send("BJVehiclePresetCapturedVehicle", {
            model = build.model,
            config = "bjs_" .. tostring(build.id),
            buildId = build.id,
            name = build.name,
            label = string.format("%s - %s", build.modelLabel, build.name),
            parts = full and full.parts or {},
            vars = full and full.vars or {},
        })
        return
    end

    -- a base game or mod configuration
    if identity and not buildId and beamjoy_vehicles.isConfigShareable(identity.model, identity.config) then
        if already(function(e)
                return e.model == identity.model and e.config == identity.config
            end) then
            return
        end
        identity.parts = full and full.parts or {}
        -- captured alongside parts, only ever actually compared when a race's own allowTuning setting
        -- is off (see BJRaceDefaults.allowTuning). Tuning stays freely changeable by default, same
        -- reasoning single mode's own captured vars already have
        identity.vars = full and full.vars or {}
        beamjoy_communications_ui.send("BJVehiclePresetCapturedVehicle", identity)
        return
    end

    -- a custom setup or a personal saved config : a new shared build
    local entry, err = beamjoy_vehicleBuilds.capture(mpVeh.veh)
    if not entry then
        toast.warn(err, nil, 8)
        return
    end
    if already(function(e)
            return e.pc ~= nil and e.model == entry.model and
                table.compare(e.pc.parts or {}, entry.pc.parts, true) and
                table.compare(e.pc.vars or {}, entry.pc.vars, true) and
                table.compare(e.pc.paints or {}, entry.pc.paints, true)
        end) then
        return
    end
    beamjoy_communications_ui.send("BJVehiclePresetCapturedVehicle", entry)
end

M.onInit = onInit

M.retrieveCache = retrieveCache
M.pushListToUI = pushListToUI
M.getById = getById
M.save = save
M.delete = delete
M.onCaptureVehicle = onCaptureVehicle

return M
