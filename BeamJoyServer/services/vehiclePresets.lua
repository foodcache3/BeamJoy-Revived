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
---@field buildId integer? set on an entry that's one of this server's shared builds (see
---BJVehicleBuild below) : `config` is then always "bjs_<buildId>", the file every player's game
---writes for it

---@class BJVehiclePreset
---@field id integer
---@field name string
---@field author string
---@field entries BJVehiclePresetEntry[]
---@field showInSelector boolean? false : its shared builds only show in the vehicle selector while
---an activity uses this preset as its pool (nil, older presets : true)

--- A shared build : a custom setup (a player's own parts, tuning and paint, or a personal saved
--- config, neither of which other players have a file for) that staff added to a preset from the
--- Vehicle Presets tab. The server keeps it and sends it to everyone ; each player's game writes
--- it as vehicles/<model>/bjs_<id>.pc with its info file (beamjoy/vehicleBuilds.lua), so it's a
--- normal tile in the native vehicle selector, spawnable by name like any factory config. One
--- build can be in several presets ; builds no preset uses any more are dropped.
---@class BJVehicleBuild
---@field id integer never reused
---@field model string
---@field modelLabel string the model's name as the game shows it ("Gavril D-Series")
---@field name string 3-32 characters, unique per model (case and spaces ignored)
---@field author string who added it
---@field hash string the parts, tuning and paints : the same build added twice is one build
---@field pc {parts: table<string, string>, vars: table<string, number>, paints: table[], mainPartName: string?}
---the .pc file's content

local BUILD_NAME_MIN, BUILD_NAME_MAX = 3, 32
local MAX_BUILDS = 200
local MAX_PARTS, MAX_VARS = 2000, 600
local MAX_BUILD_BYTES = 96000

local M = {
    dependencies = { "dao_vehiclePresets", "dao_vehicleBuilds", "services_permissions" },

    ---@type BJVehiclePreset[]
    data = {},
    ---@type BJVehicleBuild[]
    builds = {},
    nextBuildId = 1,
}

local function finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

--- a line of text a player typed : control characters and runs of spaces collapsed
---@param s any
---@return string?
local function cleanLine(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("%c", " "):gsub("%s+", " "):trim()
    return s
end

---@param s string
---@return integer?
local function charCount(s)
    return utf8 and utf8.len(s) or #s
end

--- what makes two build names the same : case and spaces don't count
---@param name string
---@return string
local function nameKey(name)
    return (cleanLine(name) or ""):lower()
end

---@param model any
---@return boolean
local function validModel(model)
    return type(model) == "string" and #model > 0 and #model <= 64 and model:match("^[%w_%-]+$") ~= nil
end

---@param p any
---@return table?
local function cleanPaint(p)
    if type(p) ~= "table" or type(p.baseColor) ~= "table" then return nil end
    local out = { baseColor = {} }
    for i = 1, 4 do
        if not finite(p.baseColor[i]) then return nil end
        out.baseColor[i] = p.baseColor[i]
    end
    for _, k in ipairs({ "metallic", "roughness", "clearcoat", "clearcoatRoughness" }) do
        if p[k] ~= nil then
            if not finite(p[k]) then return nil end
            out[k] = p[k]
        end
    end
    return out
end

--- a build's .pc content as the editor sent it, checked : plain names and numbers only
---@param pc any
---@return table? pc, string? error
local function cleanPc(pc)
    if type(pc) ~= "table" or type(pc.parts) ~= "table" then return nil, "Invalid build" end
    local out = { parts = {}, vars = {}, paints = {} }
    local count = 0
    for slot, part in pairs(pc.parts) do
        if type(slot) ~= "string" or #slot == 0 or #slot > 160 or slot:find("%c") or
            type(part) ~= "string" or #part > 160 or part:find("%c") then
            return nil, "Invalid build parts"
        end
        count = count + 1
        if count > MAX_PARTS then return nil, "This build has too many parts" end
        out.parts[slot] = part
    end
    if count == 0 then return nil, "Invalid build parts" end
    if pc.vars ~= nil then
        if type(pc.vars) ~= "table" then return nil, "Invalid build tuning" end
        count = 0
        for k, v in pairs(pc.vars) do
            if type(k) ~= "string" or #k == 0 or #k > 128 or k:find("%c") or not finite(v) then
                return nil, "Invalid build tuning"
            end
            count = count + 1
            if count > MAX_VARS then return nil, "This build has too many tuning values" end
            out.vars[k] = v
        end
    end
    if pc.paints ~= nil then
        if type(pc.paints) ~= "table" then return nil, "Invalid build paint" end
        for i = 1, 3 do
            if pc.paints[i] == nil then break end
            local paint = cleanPaint(pc.paints[i])
            if not paint then return nil, "Invalid build paint" end
            out.paints[i] = paint
        end
    end
    if pc.mainPartName ~= nil then
        if type(pc.mainPartName) ~= "string" or #pc.mainPartName > 128 or
            not pc.mainPartName:match("^[%w_%-%.]+$") then
            return nil, "Invalid build"
        end
        out.mainPartName = pc.mainPartName
    end
    return out
end

--- the same value always gives the same text : keys sorted, numbers rounded past float noise
local function canonical(v)
    local t = type(v)
    if t == "number" then return string.format("%.6g", v) end
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    keys = table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do
        out[#out + 1] = tostring(k) .. "=" .. canonical(v[k])
    end
    return "{" .. table.concat(out, ",") .. "}"
end

---@param model string
---@param pc table
---@return string
local function buildHash(model, pc)
    return tostring(utils_sha.sha256(model .. "|" .. canonical(pc.parts) .. "|" .. canonical(pc.vars) ..
        "|" .. canonical(pc.paints)))
end

---@param id integer
---@return BJVehicleBuild?
local function getBuild(id)
    return table.find(M.builds, function(b) return b.id == id end)
end

---@param build BJVehicleBuild
---@return string
local function buildLabel(build)
    return string.format("%s - %s", build.modelLabel, build.name)
end

--- Works out the preset's shared builds before anything changes : new ones (`pc`, just captured),
--- renamed ones (`buildId` with another `name`), the same build captured again (reused, name and
--- all). Names are unique per model across every build. Rewrites each such entry to point at its
--- build ; returns what to create and rename, or why it can't be saved.
---@param preset table
---@param author string
---@return {creates: table[], renames: table<integer, string>}? plan, string? error
local function planBuilds(preset, author)
    local plan = { creates = {}, renames = {} }
    -- every name in use once this save is done : "<model>|<name key>" -> build id (or create)
    local names = {}
    for _, b in ipairs(M.builds) do names[b.model .. "|" .. nameKey(b.name)] = b end
    local byHash = {}
    for _, b in ipairs(M.builds) do byHash[b.hash] = b end

    local function claim(model, name, owner)
        local key = model .. "|" .. nameKey(name)
        local current = names[key]
        if current and current ~= owner then
            return string.format("\"%s\" is already a shared build for this vehicle (by %s)", name,
                current.author or "?")
        end
        names[key] = owner
    end

    -- renames first : a rename can free a name a new build then uses
    for _, e in ipairs(preset.entries) do
        if e.buildId ~= nil then
            local build = getBuild(tonumber(e.buildId) or -1)
            if not build or build.model ~= e.model then return nil, "A shared build in this preset no longer exists" end
            e.buildId = build.id
            local name = cleanLine(e.name) or build.name
            if name ~= build.name then
                local len = charCount(name)
                if not len or len < BUILD_NAME_MIN or len > BUILD_NAME_MAX then
                    return nil, string.format("A build name needs %d to %d characters", BUILD_NAME_MIN, BUILD_NAME_MAX)
                end
                if nameKey(name) ~= nameKey(build.name) then
                    names[build.model .. "|" .. nameKey(build.name)] = nil
                    local err = claim(build.model, name, build)
                    if err then return nil, err end
                end
                plan.renames[build.id] = name
            end
        end
    end

    local total = #M.builds
    for _, e in ipairs(preset.entries) do
        if e.buildId == nil and e.pc ~= nil then
            if not validModel(e.model) then return nil, "Invalid vehicle" end
            local pc, err = cleanPc(e.pc)
            if not pc then return nil, err end
            local hash = buildHash(e.model, pc)
            local existing = byHash[hash]
            if existing then
                -- the same build : reuse it, its file and its name
                e.buildId = existing.id or existing
            else
                local name = cleanLine(e.name) or ""
                local len = charCount(name)
                if not len or len < BUILD_NAME_MIN or len > BUILD_NAME_MAX then
                    return nil, string.format("A build name needs %d to %d characters", BUILD_NAME_MIN, BUILD_NAME_MAX)
                end
                local modelLabel = cleanLine(e.modelLabel) or e.model
                if charCount(modelLabel) == nil or #modelLabel == 0 or #modelLabel > 96 then modelLabel = e.model end
                local create = { model = e.model, modelLabel = modelLabel, name = name, author = author,
                    hash = hash, pc = pc }
                local claimErr = claim(e.model, name, create)
                if claimErr then return nil, claimErr end
                local encoded = utils_json.stringifyRaw(pc) or ""
                if #encoded > MAX_BUILD_BYTES then return nil, "This build is too big to share" end
                total = total + 1
                if total > MAX_BUILDS then
                    return nil, string.format("This server already has %d shared builds", MAX_BUILDS)
                end
                byHash[hash] = create
                table.insert(plan.creates, create)
                e.buildId = create
            end
        end
    end
    return plan
end

---@param preset BJVehiclePreset
---@param author string
---@return string? error, table? plan
local function sanitizePreset(preset, author)
    if type(preset) ~= "table" then return "Invalid preset" end
    if type(preset.name) ~= "string" or #preset.name:trim() < 3 or #preset.name:trim() > 40 then
        return "Invalid name"
    end
    preset.name = preset.name:trim()
    preset.showInSelector = preset.showInSelector ~= false

    if not table.isArray(preset.entries) then preset.entries = {} end
    preset.entries = table.filter(preset.entries, function(e)
        if type(e) ~= "table" or type(e.model) ~= "string" or #e.model == 0 then return false end
        -- a shared build : an existing one (buildId) or one just captured (pc)
        if e.buildId ~= nil or e.pc ~= nil then return true end
        -- "bjs_" names are the shared builds' files, only ever reached through buildId
        return type(e.config) == "string" and #e.config > 0 and not e.config:find("^bjs_") and
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

    local plan, err = planBuilds(preset, author)
    if err then return err end
    return nil, plan
end

--- applies a checked plan : new builds get their ids, renamed ones their names, and every
--- build entry (in every preset) its config key and label
---@param preset BJVehiclePreset
---@param plan {creates: table[], renames: table<integer, string>}
local function commitBuilds(preset, plan)
    for _, create in ipairs(plan.creates) do
        create.id = M.nextBuildId
        M.nextBuildId = M.nextBuildId + 1
        table.insert(M.builds, create)
    end
    for id, name in pairs(plan.renames) do
        local build = getBuild(id)
        if build then build.name = name end
    end
    -- the editor's own entries : the build's id (a create is a table until now), nothing else of
    -- the build kept in the preset ; the same build twice in one preset is once
    local seen = {}
    preset.entries = table.filter(preset.entries, function(e)
        if e.buildId == nil then return true end
        if type(e.buildId) == "table" then e.buildId = e.buildId.id end
        if seen[e.buildId] then return false end
        seen[e.buildId] = true
        e.pc = nil
        return true
    end):values()
end

--- every build entry's config key, label and name, from its build (names change on rename)
local function refreshBuildEntries()
    for _, preset in ipairs(M.data) do
        preset.entries = table.filter(preset.entries, function(e)
            if e.buildId == nil then return true end
            local build = getBuild(e.buildId)
            if not build then return false end
            e.model = build.model
            e.config = "bjs_" .. tostring(build.id)
            e.label = buildLabel(build)
            -- for the editor : the name to change, the model it's for
            e.name = build.name
            e.modelLabel = build.modelLabel
            return true
        end):values()
    end
end

--- builds no preset uses any more go
local function dropUnusedBuilds()
    local used = {}
    for _, preset in ipairs(M.data) do
        for _, e in ipairs(preset.entries) do
            if e.buildId ~= nil then used[e.buildId] = true end
        end
    end
    M.builds = table.filter(M.builds, function(b) return used[b.id] == true end):values()
end

local function loadData()
    M.data = dao_vehiclePresets.get() or {}
    local stored = dao_vehicleBuilds.get() or {}
    M.builds = table.isArray(stored.builds) and stored.builds or {}
    M.nextBuildId = tonumber(stored.nextId) or 1
    for _, b in ipairs(M.builds) do
        if b.id >= M.nextBuildId then M.nextBuildId = b.id + 1 end
    end
    refreshBuildEntries()
end

local function saveData()
    dao_vehiclePresets.save(M.data)
    dao_vehicleBuilds.save({ nextId = M.nextBuildId, builds = M.builds })
end

---@param caches table
local function onBJRequestCache(caches)
    -- visible to every player, not staff-gated : same reasoning as races.lua's own cache: these
    -- are meant to be picked from (race start panel, race editor's pool dropdown, any future
    -- gamemode's own preset picker), not just administered
    caches.vehiclePresets = M.data
    -- every player's game writes these as files (beamjoy/vehicleBuilds.lua), so they're in the
    -- vehicle selector and spawnable by name, for everyone
    caches.vehicleBuilds = M.builds
end

local function broadcastCaches()
    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
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

    local author = ctxt.sender and ctxt.sender.playerName or "console"
    local err, plan = sanitizePreset(preset, author)
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

    commitBuilds(preset, plan)
    if existingIndex then
        preset.author = M.data[existingIndex].author
        M.data[existingIndex] = preset
    else
        preset.author = author
        table.insert(M.data, preset)
    end
    refreshBuildEntries()
    dropUnusedBuilds()
    saveData()

    if ctxt.sender then
        communications_tx.sendToPlayer(ctxt.senderID, "vehiclePresetSaved", true, preset.id)
    end

    broadcastCaches()

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
    dropUnusedBuilds()
    saveData()

    broadcastCaches()
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
M.getBuild = getBuild
M.presetSave = presetSave
M.presetDelete = presetDelete

return M
