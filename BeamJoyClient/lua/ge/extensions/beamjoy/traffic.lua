local M = {
    preloadedDependencies = { "gameplay_traffic", "gameplay_parking" },
    dependencies = { "beamjoy_communications", "beamjoy_communications_ui" },

    data = {
        enabled = false,
        amount = 0,
        total = 20,
        maxPerPlayer = 10,
        models = { "simple_traffic" },
        -- per-source (raw model key or "vehGroup:<id>") rarity weight, 0-100, mirroring Agent's
        -- own Traffic Tool "Rarity" slider convention (Rare=10/Medium=50/Common=100). A source is
        -- picked with probability proportional to its own weight relative to the total, then a
        -- config is picked uniformly within that source; missing here defaults to 100 (Common),
        -- so newly-added sources aren't unexpectedly quiet until the admin dials one down.
        ---@type table<string, number>
        weights = {},
        -- population/region-weighted config picking (mirrors native's own "Smart Selection"
        -- traffic setting); only meaningful when every candidate config actually has that
        -- metadata, which BJS can only guarantee for stock simple_traffic
        smartSelection = false,
        -- this player's own share of parked vehicles, server-computed like `amount` above
        parkedAmount = 0,
        parkedTotal = 0,
        parkedMaxPerPlayer = 1,
    },
    ---@type tablelib<integer, integer> index 1-N, value vid
    vehs = Table(), -- owned AI vehs
    ---@type tablelib<integer, integer> index 1-N, value vid
    parkedVehs = Table(), -- owned parked vehs, separate budget/pool from moving traffic

    ---@type tablelib<string, {name: string, entries: tablelib<integer, {model: string, config: string, paintName: string?}>}>
    -- discovered *.vehGroup.json bundles (native BeamNG's own curated model+config lists, e.g. a
    -- themed/regional subset of an existing model's configs), keyed by their relative path with
    -- the extension stripped. Selectable in Config's traffic models list alongside raw model
    -- names, prefixed with VEHGROUP_PREFIX so the two key spaces never collide.
    vehGroups = Table(),

    baseFunctions = {},
}
AddPreloadedDependencies(M)

local VEHGROUP_PREFIX = "vehGroup:"

---@return tablelib<string, {name: string, entries: tablelib<integer, {model: string, config: string, paintName: string?}>}>
local function scanVehGroups()
    local groups = Table()
    -- Same discovery convention as native's own trafficUtils.lua:getTrafficGroupFromFile, so any
    -- vehGroup drop-in (e.g. the "Stock Traffic US/EU" bundles that curate a regional subset of
    -- simple_traffic's own configs) becomes selectable as its own traffic vehicle source instead
    -- of only being usable by picking every config an already-supported model has.
    local files = FS:findFiles('/vehicleGroups/', '*.vehGroup.json', -1, true, true) or {}
    for _, filePath in ipairs(files) do
        local ok, group = pcall(jsonReadFile, filePath)
        if ok and group and type(group.data) == "table" then
            local id = filePath:gsub("/vehicleGroups/", ""):gsub("%.vehGroup%.json$", "")
            local entries = Table(group.data):filter(function(e)
                return type(e) == "table" and e.model and e.config
            end)
            if entries:length() > 0 then
                groups[id] = { name = group.name or id, entries = entries }
            end
        end
    end
    return groups
end

-- ge/extensions/gameplay/traffic/trafficUtils.lua:getLevelInfo() reads the exact same file; that
-- function isn't exposed on M though, and its country-of-origin logic is meant for weighting
-- across DIFFERENT models (e.g. an American brand vs a Japanese one), which doesn't apply within
-- one model's own configs the way region does, so only region is worth porting here.
---@return string?
local function getMapRegion()
    local fileName = path.getPathLevelInfo(getCurrentLevelIdentifier() or '')
    local info = fileName and jsonReadFile(fileName)
    return info and info.region or nil
end

-- Mirrors native's own per-config weighting (core/multiSpawn.lua:getPopulationFactor +
-- setPopulationData), scoped down to a single model's own configs: each stock simple_traffic
-- config carries real Population/Region metadata (see e.g. vehicles/simple_traffic's own
-- info_bastion_base.json: {"Population":10000,"Region":["northAmerica"]}), which third-party
-- vehGroup/model content generally doesn't, hence this only ever gets used for simple_traffic.
---@param config table
---@param mapRegion string?
---@return number weight, 0 meaning "never pick this one"
local function getSmartSelectionWeight(config, mapRegion)
    local population = tonumber(config.Population) or 0
    if population <= 0 then return 0 end
    local regionFactor = 1
    if mapRegion and type(config.Region) == "table" and #config.Region > 0 then
        regionFactor = table.includes(config.Region, mapRegion) and 1 or .25
    end
    return population * regionFactor
end

-- Generic: used both for per-config weighting (Smart Selection) and per-source weighting
-- (rarity), any table shape with a numeric .weight field works.
---@generic T: {weight: number}
---@param candidates tablelib<integer, T>
---@return T
local function weightedRandomPick(candidates)
    local total = candidates:reduce(function(acc, c) return acc + c.weight end, 0)
    if total <= 0 then return candidates:random() end
    local r = math.random() * total
    for _, c in ipairs(candidates) do
        if r < c.weight then return c end
        r = r - c.weight
    end
    return candidates[candidates:length()]
end

---@return tablelib<integer, {pos: vec3, dir: vec3, speed: number}> index vid, value pos
local function getPlayersPositions()
    return beamjoy_vehicles.vehicles:filter(function(v)
        if (not v.isVehicle and
                v.jbeam ~= beamjoy_vehicles.WALKING) or
            v.isAi then
            return false
        end
        local mpVeh = beamjoy_vehicles.getVehicle(v.vid)
        return mpVeh ~= nil and mpVeh.spectators:length() > 0
    end):map(function(v) --- @param v BJVehicle
        return {
            pos = vec3(be:getObjectOOBBCenterXYZ(v.vid)),
            dir = v.veh:getDirectionVector(),
            speed = tonumber(v.veh.speed) or 0,
        }
    end)
end

---@param speed number meter/sec
---@return integer minDist, integer maxDist
local function getMinMaxDistFromPlayer(speed)
    return math.scale(speed * 3.6, 20, 200, 50, 200, true),
        math.scale(speed * 3.6, 20, 200, 150, 400, true)
end

-- Matches ge/extensions/gameplay/traffic.lua's own speed-based falloff (native traffic biases
-- spawns ahead of the player's travel direction at speed instead of picking a fully random road).
-- Without this, spawns stay uniformly random around the player even at highway speed, so most of
-- the fixed traffic budget lands somewhere behind/beside the player and is never driven past,
-- reading as "traffic got sparse" once the min/max band above also widens with speed.
---@param speed number meter/sec
---@return number
local function getPathRandomization(speed)
    return math.scale(speed * 3.6, 20, 200, 1, .15, true)
end

-- ge/extensions/gameplay/traffic/trafficUtils.lua:findSafeSpawnPoint(), the same spawn-point
-- search native's own live traffic uses (route-ahead-of-travel-direction first, radial fallback).
---@param job NGJob?
---@return vec3? pos, quat? rot
local function getNewRandomSpawn(job)
    local mapNodes = map.getMap().nodes
    if table.length(mapNodes) == 0 then return end

    local playerPositions = getPlayersPositions()

    local valid = false
    local origin, spawnData, onRoute
    local tries, threshold = 0, 10
    repeat
        tries = tries + 1
        if playerPositions:length() == 0 then
            local min, max = M.getMinMaxDistFromPlayer(0)
            origin = {
                pos = table.random(mapNodes).pos,
                dir = vec3(0, 1, 0),
                speed = 0,
                minDistance = min,
                maxDistance = max,
                pathRandomization = M.getPathRandomization(0),
            }
        else
            origin = playerPositions:random()
            origin.minDistance, origin.maxDistance = M.getMinMaxDistFromPlayer(origin.speed)
            origin.pathRandomization = M.getPathRandomization(origin.speed)
        end
        -- findSafeSpawnPoint (native's own gameplay_traffic.lua live spawn maintenance uses this,
        -- not the raw radial search) tries a route ahead of origin.dir along the road graph first,
        -- only falling back to "anywhere nearby" radial search if no such route point validates.
        -- The plain radial search this used to call could land a vehicle on any nearby road,
        -- including one behind the player or one that curves into direct view around a bend,
        -- which is what caused both the sparse-at-speed and pop-in-view symptoms.
        --
        -- targetDist is the point past which the search stops requiring the spot be hidden from
        -- the camera (see checkRayCast in trafficUtils.lua). Native's own call site uses the
        -- midpoint of the min/max band (clamp(lerp(minDist, maxDist, 0.5), 120, 500)); mirror that
        -- instead of a narrower quarter-point so occlusion is required over as much of the search
        -- band as native itself relies on, cutting down on spawns landing in plain sight.
        local targetDist = math.clamp(
            (origin.minDistance + origin.maxDistance) / 2, 120, 500)
        spawnData, onRoute = extensions.gameplay_traffic_trafficUtils
            .findSafeSpawnPoint(origin.pos, origin.dir,
                origin.minDistance, origin.maxDistance, targetDist,
                { pathRandomization = origin.pathRandomization, minDrivability = .1 })
        if onRoute then
            local playersDistances = playerPositions:map(function(pData)
                return {
                    distance = vec3(spawnData.pos):distance(pData.pos),
                    minDistance = pData.minDistance,
                    maxDistance = pData.maxDistance,
                }
            end)
            if playerPositions:length() == 0 or
                (playersDistances:every(function(pData)
                        return pData.distance > pData.minDistance
                    end) and
                    playersDistances:any(function(pData)
                        return pData.distance < pData.maxDistance
                    end)) then
                valid = true
            end
        end
        if not valid and job then job.sleep(.01) end
    until valid or tries >= threshold

    if valid then
        local pos, dir = extensions.gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir,
            spawnData.n1, spawnData.n2, {
                legalDirection = true,
            })
        if job then job.sleep(.01) end
        local normal = map.surfaceNormal(pos, 1)
        return pos, quatFromDir(vec3(0, 1, 0):rotated(quatFromDir(dir, normal)), normal)
    end
end

--- overrides ge/extensions/core/multiSpawn.lua:createGroup():285
---@param job NGJob
---@param amount integer
---@return {model: string, config: string, paintName: string?}[]
local function createGroup(job, amount)
    if type(amount) ~= "number" or amount < 1 then return {} end

    local selectedModels = table.filter(M.data.models, function(m)
        return not string.startswith(m, VEHGROUP_PREFIX)
    end)
    local selectedVehGroupIds = table.filter(M.data.models, function(m)
        return string.startswith(m, VEHGROUP_PREFIX)
    end):map(function(m) return m:sub(#VEHGROUP_PREFIX + 1) end)

    -- Population/region-weighted picking only makes sense when every candidate actually has that
    -- metadata, which BJS can only guarantee for stock simple_traffic; skip straight to the
    -- regular uniform pool below for any other selection, including a mix that adds vehGroups.
    if M.data.smartSelection and selectedVehGroupIds:length() == 0 and
        table.compare(selectedModels, { "simple_traffic" }) then
        local configs = beamjoy_vehicles.getAllVehicleConfigs(job, { traffic = true }).simple_traffic
        local mapRegion = getMapRegion()
        local candidates = configs and Table(configs.configs):map(function(config, key)
            return { config = key, weight = getSmartSelectionWeight(config, mapRegion) }
        end):values():filter(function(c) return c.weight > 0 end) or Table()
        if candidates:length() > 0 then
            local res = {}
            repeat
                table.insert(res, { model = "simple_traffic", config = weightedRandomPick(candidates).config })
            until #res == amount
            return res
        end
        -- no config had usable Population data (e.g. a modified simple_traffic install); fall
        -- through to the regular uniform pool below instead of returning an empty group
    end

    -- One source per selected raw model and per selected vehGroup (additive: a vehGroup doesn't
    -- replace the model list, it's one more pickable source alongside it), each carrying its own
    -- full config list and its own rarity weight. A source is picked weighted by M.data.weights
    -- (default 100/Common when unset), then a config is picked uniformly within that source, so
    -- e.g. a 128-config pack and a 5-config pack can be balanced against each other instead of the
    -- bigger one dominating purely by having more configs.
    local sources = Table()
    table.filter(beamjoy_vehicles.getAllVehicleConfigs(job, { traffic = true }),
        function(_, model) return table.includes(selectedModels, model) end)
        :forEach(function(data, model)
            local configs = table.keys(data.configs):map(function(config)
                return { model = model, config = config }
            end)
            if configs:length() > 0 then
                sources:insert({ configs = configs, weight = M.data.weights[model] or 100 })
            end
        end)
    selectedVehGroupIds:forEach(function(id)
        local group = M.vehGroups[id]
        if group then
            local configs = group.entries:map(function(entry)
                return {
                    model = entry.model,
                    config = entry.config,
                    -- vehGroup files use the literal string "random" to mean "no override", the
                    -- same behavior spawnNewTrafficVehicles already falls back to when unset
                    paintName = entry.paintName ~= "random" and entry.paintName or nil,
                }
            end)
            if configs:length() > 0 then
                local key = VEHGROUP_PREFIX .. id
                sources:insert({ configs = configs, weight = M.data.weights[key] or 100 })
            end
        end
    end)

    if sources:length() < 1 then
        LogError("Invalid traffic models")
        dump(M.data.models)
        return {}
    end

    local res = {}
    repeat
        table.insert(res, weightedRandomPick(sources).configs:random())
    until #res == amount
    return res
end

local function createPostSpawnMergeCheck(vid)
    local event = string.format("TrafficMergeCheck-%d", vid)
    async.removeTask(event)
    async.delayTask(function()
        ---@type NGVehicle?
        local v = be:getObjectByID(vid)
        local damages = v and tonumber(v.damages)
        if damages and damages >= 1 then
            M.markForRespawn(vid)
        end
    end, 500, event)
end

local spawnLock = false
---@param amount? integer 1-N
local function spawnNewTrafficVehicles(amount)
    if spawnLock then return end                             -- already spawning traffic
    if table.length(map.getMap().nodes) == 0 then return end -- map has no routes

    spawnLock = true
    amount = amount or 1
    core_jobsystem.create(function(job)
        local vehConfigs = createGroup(job, amount)
        uiHelpers.toastInfo(beamjoy_lang.translate("beamjoy.toast.traffic.waitForSpawn"))
        uiHelpers.applyLoading(true)
        job.sleep(.3)
        for i = 1, amount do
            local vehConfig = vehConfigs[i]
            if vehConfig then
                local options = {}
                options.vehicleName = "traffic"
                options.cling = true
                options.autoEnterVehicle = false

                local pos, rot
                while not pos do
                    pos, rot = getNewRandomSpawn(job)
                    if not pos then job.sleep(.01) end
                end
                job.sleep(.01)
                local coreModel = extensions.core_vehicles.getModel(vehConfig.model)
                job.sleep(.01)
                local paintNames = table.keys(coreModel.model.paints or {})
                for j = 1, 3 do
                    local pickName
                    if j == 1 and vehConfig.paintName and coreModel.model.paints[vehConfig.paintName] then
                        -- vehGroup-provided override for the primary paint slot
                        pickName = vehConfig.paintName
                    else
                        pickName = table.random(paintNames)
                    end
                    if coreModel.model.paints[pickName] then
                        local key = "paintName"
                        if j > 1 then key = key .. tostring(j) end
                        options[key] = pickName
                        key = "paint"
                        if j > 1 then key = key .. tostring(j) end
                        options[key] = coreModel.model.paints[pickName]
                    end
                end
                job.sleep(.01)
                local pathConfig = string.format("vehicles/%s/%s.pc", vehConfig.model, vehConfig.config)
                local veh = spawn.spawnVehicle(vehConfig.model, pathConfig, pos, rot, options)
                -- beamjoy_vehicles' own isAi() only recognizes a model as traffic by its name
                -- containing "traffic" (simple_traffic, agent_traffic_eu2, ...), which a vehGroup
                -- can easily name off a model that doesn't follow that convention at all (e.g.
                -- SimpleNG's SNG_120a). Without this, that spawn gets treated exactly like the
                -- local player spawning their own car (forced out of free cam, respawn protection
                -- applied, an orange "You" nametag), and traffic.lua's own wait loop below never
                -- sees it land in M.vehs, spinning forever and leaking spawnLock=true, wedging
                -- every future traffic setting change. Called unconditionally, before any
                -- job.sleep gives beamjoy_vehicles.registerVehicle's own async job a chance to
                -- classify this vid first.
                beamjoy_vehicles.markVehicleAsAi(veh:getID())
                job.sleep(.01)
                extensions.hook("onBJTrafficVehicleSpawned", veh)
                core_vehicleBridge.executeAction(veh, 'setAIMode', "traffic")
                job.sleep(.01)
                createPostSpawnMergeCheck(veh:getID())
                -- Bounded defensively: this used to wait unconditionally, and any future gap in
                -- getting a spawned vid recognized as AI (like the SimpleNG case above) would spin
                -- forever here, never releasing spawnLock and permanently wedging every later
                -- traffic setting change until a restart. 10s is generous for a single registration
                -- that normally completes in well under a second.
                local waitDeadline = GetCurrentTimeMillis() + 10000
                while i == amount and not M.vehs:includes(veh:getID()) and
                    GetCurrentTimeMillis() < waitDeadline do
                    job.sleep(.2)
                end
            end
        end
        uiHelpers.applyLoading(false)
        spawnLock = false
        extensions.hook("onBJTrafficUpdated")
    end)
end

-- Parked vehicles are sourced exclusively from stock simple_traffic's own "_parked" configs
-- (e.g. bastion_base_parked.pc), which beamjoy_vehicles' own scan deliberately excludes from the
-- regular traffic config list, and are placed via native's gameplay_parking extension (real
-- hand-authored parking-spot markers on the map), not the road-graph search moving traffic uses.
---@return tablelib<string, table> index config key, value config data
local function getParkedConfigs()
    local coreModel = extensions.core_vehicles.getModel("simple_traffic") -- {model=.., configs=..}
    if not coreModel or not coreModel.configs then return Table() end
    return Table(coreModel.configs):filter(function(config, key)
        return type(key) == "string" and key:lower():endswith("_parked")
    end)
end

---@param amount integer
---@return {model: string, config: string}[]?
local function createParkedGroup(amount)
    local configs = getParkedConfigs()
    if configs:length() == 0 then return nil end

    if M.data.smartSelection then
        local mapRegion = getMapRegion()
        local candidates = configs:map(function(config, key)
            return { config = key, weight = getSmartSelectionWeight(config, mapRegion) }
        end):values():filter(function(c) return c.weight > 0 end)
        if candidates:length() > 0 then
            local res = {}
            repeat
                table.insert(res, { model = "simple_traffic", config = weightedRandomPick(candidates).config })
            until #res == amount
            return res
        end
        -- fall through to uniform if none of them had usable Population data
    end

    local keys = configs:keys()
    local res = {}
    repeat
        table.insert(res, { model = "simple_traffic", config = keys:random() })
    until #res == amount
    return res
end

-- gameplay_parking.setupVehicles has no incremental "spawn N more" primitive: every call fully
-- replaces this client's own current parked set (it runs its own deleteVehicles() first unless
-- keepCurrent is passed, which this never does), so unlike moving traffic's
-- spawnNewTrafficVehicles/updateVehs this always does a full resize rather than diffing, and never
-- fires M.onVehicleGroupSpawned at all when target is 0 (setupVehicles bails out before spawning
-- anything) - clear M.parkedVehs up front instead of waiting on that hook to do it.
local function updateParkedVehs()
    local target = M.data.enabled and M.data.parkedAmount or 0
    if target == M.parkedVehs:length() then return end

    local group = target > 0 and createParkedGroup(target) or nil
    if target > 0 and not group then
        LogError("Invalid parked vehicle configs")
        return
    end
    for _, vid in pairs(M.parkedVehs) do
        extensions.hook("onBJTrafficVehicleDeleted", vid)
    end
    M.parkedVehs:clear()
    extensions.gameplay_parking.setupVehicles(target, { vehGroup = group })
end

---@param forceReset boolean? if traffic models have changed
local function updateVehs(forceReset)
    if spawnLock then
        -- process lock system
        async.removeTask("updateTrafficVehs")
        async.task(function() return not spawnLock end, function()
            updateVehs(forceReset)
        end, "updateTrafficVehs")
        return
    end

    -- onBJVehicleInstantiated's isAi check can't distinguish a moving-traffic config from a
    -- parked one (both come off the same "simple_traffic" model), so a parked vehicle can
    -- transiently land in M.vehs before M.onVehicleGroupSpawned claims it into M.parkedVehs.
    -- Reconciling here, regardless of which hook fired first, keeps the moving-traffic budget
    -- accurate instead of miscounting parked cars against it.
    M.vehs = M.vehs:filter(function(vid) return not M.parkedVehs:includes(vid) end)

    local function clearVehs()
        for _, vid in pairs(M.vehs) do
            beamjoy_vehicles.delete(vid)
            extensions.hook("onBJTrafficVehicleDeleted", vid)
        end
        M.vehs:clear()
    end
    if M.data.enabled and forceReset then
        clearVehs()
    end
    if M.data.enabled and M.vehs:length() ~= M.data.amount then
        if M.vehs:length() > M.data.amount then
            for i = M.vehs:length(), M.data.amount + 1, -1 do
                local vid = M.vehs:remove(i)
                beamjoy_vehicles.delete(vid)
                extensions.hook("onBJTrafficVehicleDeleted", vid)
            end
        elseif M.vehs:length() < M.data.amount then
            spawnNewTrafficVehicles(M.data.amount - M.vehs:length())
        end
    elseif not M.data.enabled and M.vehs:length() > 0 then
        clearVehs()
    end
end

local function saveAndSend(payload)
    local newData = table.clone(M.data)
    table.assign(newData, payload)
    newData.amount = nil
    newData.parkedAmount = nil
    if payload.amount then newData.total = payload.amount end
    if payload.parkedAmount then newData.parkedTotal = payload.parkedAmount end
    if payload.models then newData.models = payload.models end
    local dirty = not table.compare(newData, M.data)
    if dirty then
        beamjoy_communications.send("trafficSettings", {
            enabled = newData.enabled,
            amount = newData.total,
            maxPerPlayer = newData.maxPerPlayer,
            models = newData.models,
            weights = newData.weights,
            smartSelection = newData.smartSelection,
            parkedAmount = newData.parkedTotal,
            parkedMaxPerPlayer = newData.parkedMaxPerPlayer,
        })
    end
end

local function sendSettingsToUI()
    extensions.core_jobsystem.create(function(job)
        local models = beamjoy_vehicles.getAllVehicleConfigs(job,
                { cars = false, trucks = false, traffic = true })
            :map(function(v)
                return v.label
            end)
        -- vehGroups appear as extra entries in this same key->label dict, so the existing
        -- Config UI multi-select (models/modelOptions in windows/config/general/traffic/app.js)
        -- lists and validates them exactly like raw model names, with no frontend changes needed.
        M.vehGroups:forEach(function(group, id)
            models[VEHGROUP_PREFIX .. id] = group.name
        end)
        beamjoy_communications_ui.send("BJTrafficSettings", {
            data = {
                enabled = M.data.enabled,
                amount = M.data.total,
                maxPerPlayer = M.data.maxPerPlayer,
                models = M.data.models,
                weights = M.data.weights,
                smartSelection = M.data.smartSelection,
                parkedAmount = M.data.parkedTotal,
                parkedMaxPerPlayer = M.data.parkedMaxPerPlayer,
            },
            models = models
        })
        local newModels = table.filter(table.clone(M.data.models), function(m)
            return models[m] ~= nil
        end)
        if not table.compare(newModels, M.data.models) then
            if #newModels == 0 then table.insert(newModels, "simple_traffic") end
            saveAndSend({ models = newModels })
        end
    end)
end

local function toggleTraffic()
    if beamjoy_permissions.isStaff() then
        saveAndSend({ enabled = not M.data.enabled })
    end
end

local function overrideNGHooks()
    M.baseFunctions = {
        gameplay_traffic = {
            toggle = extensions.gameplay_traffic.toggle,
            activate = extensions.gameplay_traffic.activate,
            deactivate = extensions.gameplay_traffic.deactivate,
            deleteVehicles = extensions.gameplay_traffic.deleteVehicles,
            setupTrafficWaitForUi = extensions.gameplay_traffic.setupTrafficWaitForUi,
        }
    }

    -- keybind
    extensions.gameplay_traffic.toggle = toggleTraffic
    -- radial play
    extensions.gameplay_traffic.activate = function()
        if not M.data.enabled then toggleTraffic() end
    end
    -- radial pause
    extensions.gameplay_traffic.deactivate = function()
        if M.data.enabled then toggleTraffic() end
    end
    -- radial remove traffic
    extensions.gameplay_traffic.deleteVehicles = function()
        if M.data.enabled then toggleTraffic() end
    end
    -- radial spawn traffic
    extensions.gameplay_traffic.setupTrafficWaitForUi = function(withPolice)
        if not M.data.enabled then
            if withPolice then
                uiHelpers.toastWarning(beamjoy_lang.translate("beamjoy.toast.traffic.policeDisabled"))
            end
            toggleTraffic()
        end
    end
end

-- BeamMP server mods (ge/extensions/mods.lua) can activate well after this extension's own onInit
-- has already run and cached M.vehGroups, e.g. a Resources/Client traffic pack that only gets
-- mounted once the client actually connects and downloads it. Rescanning on the same
-- onBJVehicleModChanged event beamjoy_vehicles already uses for the equivalent problem (see
-- vehicles.lua:onBJVehicleModChanged) keeps the vehGroup list from going stale after connecting.
local function onBJVehicleModChanged()
    M.vehGroups = scanVehGroups()
end

local function onInit()
    InitPreloadedDependencies(M)

    M.vehGroups = scanVehGroups()

    beamjoy_communications.addHandler("sendCache", function(caches)
        if caches.traffic then
            M.retrieveCache(caches.traffic)
        end
    end)
    beamjoy_communications_ui.addHandler("BJReady", function()
        updateVehs()
        updateParkedVehs()
    end)
    beamjoy_communications_ui.addHandler("BJRequestTrafficSettings", sendSettingsToUI)
    beamjoy_communications_ui.addHandler("BJTrafficSettings", saveAndSend)
    beamjoy_communications.addHandler("trafficRubberbandTick", M.onRubberbandTick)

    overrideNGHooks()
end

local function onExtensionUnloaded()
    RollBackNGFunctionsWrappers(M.baseFunctions)
end

---@param restrictions tablelib<integer, string> index 1-N
local function onBJRequestRestrictions(restrictions)
    if not beamjoy_permissions.isStaff() then
        restrictions:insert("toggleTraffic")
    end
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    local mpVeh = beamjoy_vehicles.vehicles[vid]
    if mpVeh and mpVeh.isLocal then
        if mpVeh.isAi and not M.vehs:includes(vid) then
            M.vehs:insert(vid)
            mpVeh.playerUsable = false
            mpVeh.uiState = 0
        end
    elseif not mpVeh.isAi and M.vehs:includes(vid) then
        M.vehs:remove(vid)
        mpVeh.playerUsable = true
        mpVeh.uiState = 1
    end
end

-- Native gameplay_parking broadcasts this (core/multiSpawn.lua:spawnGroup) once its own async
-- spawn job for a group finishes; "autoParking" is the groupName gameplay_parking.setupVehicles
-- always uses internally, not something BJS's own call gets to choose. This is how M.parkedVehs
-- actually gets populated, since setupVehicles has no synchronous return of what it spawned.
---@param vehIds integer[]
---@param groupId integer
---@param groupName string
local function onVehicleGroupSpawned(vehIds, groupId, groupName)
    if groupName ~= "autoParking" then return end
    Table(vehIds):forEach(function(vid)
        if not M.parkedVehs:includes(vid) then
            M.parkedVehs:insert(vid)
        end
        -- any cross-contamination into M.vehs (see updateVehs' own reconciliation comment) gets
        -- cleaned up there via a value-filter, not here: tablelib:remove is plain Lua
        -- table.remove underneath, which is INDEX-based, not value-based, so calling it with a
        -- vehicle id directly would remove whatever happens to sit at that index instead
        local mpVeh = beamjoy_vehicles.vehicles[vid]
        if mpVeh then
            mpVeh.playerUsable = false
            mpVeh.uiState = 0
        end
    end)
end

local cachesPaints = {}

---@param job NGJob
---@param vid integer
local function rubberband(job, vid)
    if not M.vehs:includes(vid) then return end
    local target = beamjoy_vehicles.vehicles[vid]
    if not target or not target.isAi or not target.isLocal then return end

    local pos, rot = getNewRandomSpawn(job)
    if pos then
        if not cachesPaints[target.jbeam] then
            cachesPaints[target.jbeam] = table.values(beamjoy_vehicles.getAllPaints(target.veh))
        end
        if table.length(cachesPaints[target.jbeam]) > 0 then
            beamjoy_vehicles.paint(target.veh,
                { table.random(cachesPaints[target.jbeam]) })
        end
        spawn.safeTeleport(target.veh, pos, rot, true, nil, false, nil, true)
        core_vehicleBridge.executeAction(target.veh, 'setAIMode', "traffic")
        extensions.hook("onBJTrafficVehicleResetted", target.veh)
        createPostSpawnMergeCheck(target.veh:getID())
    end
end

local function onRubberbandTick()
    core_jobsystem.create(function(job)
        local playerPositions = getPlayersPositions()
        if playerPositions:length() > 0 then
            local selfAis = M.vehs:map(function(vid) return beamjoy_vehicles.vehicles[vid] end)
            -- Previously rubberbanded only a single (and, due to a dead distance-tracking bug,
            -- effectively arbitrary) vehicle per tick, which this server-throttled event fires at
            -- most once/second for. At speed, a player can leave several owned traffic vehicles
            -- beyond their max distance in the same tick; capping repositioning to one at a time
            -- left the rest invisible out of range for multiple seconds, reading as sparse traffic.
            -- Rubberbanding every out-of-range vehicle in one pass fixes the throughput, not just
            -- the spawn direction bias fixed by getPathRandomization above.
            local targetsToRubberband = selfAis:filter(function(v)
                local pos = vec3(be:getObjectOOBBCenterXYZ(v.vid))
                return playerPositions:every(function(data)
                    local _, maxDist = M.getMinMaxDistFromPlayer(data.speed)
                    return pos:distance(data.pos) >= maxDist
                end)
            end)
            targetsToRubberband:forEach(function(v)
                rubberband(job, v.vid)
            end)
        end
    end)
end

local function retrieveCache(cache)
    if not table.compare(cache, M.data, true) then
        local previousModels = table.clone(M.data.models)
        M.data = cache
        sendSettingsToUI()
        updateVehs(not table.compare(previousModels, M.data.models))
        updateParkedVehs()
    end
end

local function markForRespawn(vid)
    if M.vehs:includes(vid) then
        core_jobsystem.create(function(job)
            job.sleep(.01)
            rubberband(job, vid)
        end)
    end
end

M.onInit = onInit
M.onExtensionUnloaded = onExtensionUnloaded
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onBJVehicleModChanged = onBJVehicleModChanged
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onRubberbandTick = onRubberbandTick

M.getMinMaxDistFromPlayer = getMinMaxDistFromPlayer
M.getPathRandomization = getPathRandomization
M.retrieveCache = retrieveCache
M.markForRespawn = markForRespawn

M.createGroup = createGroup

return M
