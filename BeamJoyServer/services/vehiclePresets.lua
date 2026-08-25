--- Server-wide, map-independent vehicle pool presets : named, reusable lists of saved-config
--- vehicles (model+config, never a custom setup: see BJVehiclePresetEntry below), managed from
--- their own dedicated Config tab and referenced by id from anything that needs a pickable pool of
--- vehicles. Races' own "pool" vehicle restriction mode is the first consumer (see services/
--- races.lua's vehicleRestrictionPoolPresetId and raceGrid.lua's buildSettings), but this module is
--- deliberately generic/standalone, not owned by or dependent on the race system at all, so a
--- future gamemode (vehicle delivery, hunter, infected, ...) can reference the exact same presets
--- via M.getById without this module ever needing to know those modes exist.
---
--- Global rather than per-map (unlike services/races.lua's dao_activity storage) : a pool of
--- vehicles has nothing to do with track geometry or which map is currently loaded, so a preset
--- created once should stay available regardless of map changes. Same storage pattern as
--- services/groups.lua and services/permissions.lua (a single dao_main-backed JSON file, loaded
--- once at boot, no onMapChanged hook needed).

---@class BJVehiclePresetEntry
---@field model string jbeam model key
---@field config string normalized config key (see vehicles.lua's getCurrentConfigIdentity), always
---a real, shareable (base game or mod) saved configuration, never a personal local-only save or a
---custom (never saved) setup, so every player picking from this preset is guaranteed to actually
---have the file ; used to filter the native vehicle selector down to just this preset's entries, so
---a joining participant can actually pick this one. NOT used for post-spawn matching (see
---`parts` below for why)
---@field label string human-readable "Model - Config" display label, captured alongside for display
---@field parts table<string, string> the entry's own captured parts tree (see vehicles.lua's
---getFullConfig), snapshotted alongside model/config/label at the moment it was added to the
---preset. This, not `config` above, is what a joining participant's currently-equipped vehicle is
---actually matched against (raceRunner.lua's vehicleMatchesRestriction). Real, confirmed bug this
---fixes : BeamNG resets a vehicle's config-file identity to "custom" on ANY live edit (parts,
---tuning, OR paint alike: core/vehicle/partmgmt.lua's mergeConfigOfVehicle blanks partConfig
---regardless of what actually changed), so matching by `config` identity broke the instant a player
---so much as repainted or tweaked a tuning slider after picking their vehicle from the selector.
---Matching by the actual parts tree instead (same technique "single" mode restrictions already use)
---means only a genuine parts swap counts as leaving the restriction; tuning and paint stay always
---freely changeable, by default. Absent on a legacy entry saved before this field existed ; such an
---entry is simply never matched (correctly falls through as "not this one") rather than erroring.
---@field vars table<string, number>? the entry's own captured tuning variables, snapshotted
---alongside `parts`, only ever compared when a race's own `allowTuning` setting is off (see
---BJRaceDefaults.allowTuning), since tuning is freely changeable by default same as paint always
---is ; absent (nil) on any entry captured before this field existed, same graceful-no-match
---treatment as a missing `parts`

---@class BJVehiclePreset
---@field id integer
---@field name string
---@field author string
---@field entries BJVehiclePresetEntry[]

local M = {
    dependencies = { "dao_vehiclePresets", "services_permissions" },

    ---@type BJVehiclePreset[]
    data = {},
}

---@param preset BJVehiclePreset
---@return string? error
local function sanitizePreset(preset)
    if type(preset.name) ~= "string" or #preset.name:trim() < 3 or #preset.name:trim() > 40 then
        return "Invalid name"
    end
    preset.name = preset.name:trim()

    if not table.isArray(preset.entries) then preset.entries = {} end
    preset.entries = table.filter(preset.entries, function(e)
        return type(e) == "table" and
            type(e.model) == "string" and #e.model > 0 and
            type(e.config) == "string" and #e.config > 0 and
            type(e.label) == "string" and #e.label > 0
    end):values()
    if #preset.entries == 0 then
        return "A preset needs at least 1 vehicle"
    end
    -- neither `parts` nor `vars` is required at this layer: a legacy entry captured before these
    -- fields existed (or a malformed one) stays a valid, savable entry, it's simply never matched
    -- against any vehicle (see raceRunner.lua's vehicleMatchesRestriction) until re-captured.
    -- Normalized rather than left as whatever garbage might have arrived : `parts` to nil unless a
    -- real non-empty table (a vehicle always has SOME parts, so empty can only mean "never really
    -- captured") ; `vars` to nil only if not a table at all, since an empty `{}` is itself a
    -- legitimate, common capture (a vehicle with no runtime tuning overrides: see vehicles.lua's
    -- own getFullConfig, which defaults it the same way).
    table.forEach(preset.entries, function(e)
        if type(e.parts) ~= "table" or table.length(e.parts) == 0 then
            e.parts = nil
        end
        if type(e.vars) ~= "table" then
            e.vars = nil
        end
    end)

    local duplicate = table.find(M.data, function(p)
        return p.id ~= preset.id and p.name:lower() == preset.name:lower()
    end)
    if duplicate then return "A preset with this name already exists" end
end

local function loadData()
    M.data = dao_vehiclePresets.get() or {}
end

local function saveData()
    dao_vehiclePresets.save(M.data)
end

---@param caches table
local function onBJRequestCache(caches)
    -- visible to every player, not staff-gated : same reasoning as races.lua's own cache: these
    -- are meant to be picked from (race start panel, race editor's pool dropdown, any future
    -- gamemode's own preset picker), not just administered
    caches.vehiclePresets = M.data
end

---@param presetId integer
---@return BJVehiclePreset?
local function getById(presetId)
    return table.find(M.data, function(p) return p.id == presetId end)
end

---@param ctxt BJSContext
---@param preset BJVehiclePreset
local function presetSave(ctxt, preset)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditVehiclePresets) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end

    local err = sanitizePreset(preset)
    if err then
        LogError(string.format("vehiclePresetSave rejected%s: %s",
            ctxt.sender and (" from " .. ctxt.sender.playerName) or "", err))
        if ctxt.sender then
            return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error", err)
        end
        return
    end

    local existingIndex
    if preset.id == nil then
        local id = 1
        while table.any(M.data, function(p) return p.id == id end) do
            id = id + 1
        end
        preset.id = id
    else
        local _, idx = table.find(M.data, function(p) return p.id == preset.id end)
        existingIndex = idx
    end

    if existingIndex then
        preset.author = M.data[existingIndex].author
        M.data[existingIndex] = preset
    else
        preset.author = ctxt.sender and ctxt.sender.playerName or "console"
        table.insert(M.data, preset)
    end
    saveData()

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "vehiclePresetSaved", true, preset.id)
    end

    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)

    return preset.id
end

---@param ctxt BJSContext
---@param presetId integer
local function presetDelete(ctxt, presetId)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.EditVehiclePresets) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end

    local _, index = table.find(M.data, function(p) return p.id == presetId end)
    if not index then return end

    table.remove(M.data, index)
    saveData()

    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
end

local function onInit()
    communications_rx.addHandler("vehiclePresetSave", M.presetSave)
    communications_rx.addHandler("vehiclePresetDelete", M.presetDelete)
end

-- loaded in onPreInit, not onInit : services_races' own onInit (loadData) resolves
-- vehicleRestrictionPoolPresetId against M.data via getById, and extensions.hook("onInit") iterates
-- every loaded module in an unspecified (plain Lua pairs()) order, so there's no guarantee this
-- module's own onInit would run before services_races' does if both loaded there. onPreInit is a
-- fully separate phase that completes for every module before onInit begins for any of them (same
-- reason services_core loads its own M.data there, for the exact same "another service's onInit
-- reads my data" reason via getCurrentMap()), so this guarantees M.data is ready in time regardless
-- of iteration order.
M.onPreInit = loadData
M.onInit = onInit
M.onBJRequestCache = onBJRequestCache

M.getById = getById
M.presetSave = presetSave
M.presetDelete = presetDelete

return M
