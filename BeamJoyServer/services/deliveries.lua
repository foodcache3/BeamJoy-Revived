--- Live delivery jobs (Phase 3). Static data (points, route lengths) lives in
--- services/deliveryPoints.lua ; this module owns what happens on top of it :
---   - each depot's **job board** : a few offers shared by everyone, generated lazily when someone
---     first looks, replaced the moment one is taken and rotated out after a few minutes untaken.
---     Anyone viewing a board gets pushed the new one whenever it changes. A depot offers package
---     jobs if it sends packages, and vehicle jobs if it sends vehicles AND has a start slot.
---   - the **vehicle pool** for vehicle jobs : the server has no vehicle list, so an admin's client
---     uploads every eligible config it has installed (BJS clients only ever have stock vehicles +
---     server mods active, so that's what every player has), kept with its own delivery blacklist
---     (separate from the spawn ModelBlacklist, which also applies) in `deliveryPool.json` : whole
---     models (which also covers configs a later refresh adds) and single configs.
---   - **jobs** : one per player. The server owns the clock (start time, hard deadline at 2x the
---     target) and checks the player's position at pickup and drop-off, so a client can't report
---     an arrival it didn't make.
---   - **convoys** : up to 4 players on one offer, one piece of cargo (or one vehicle) each. A
---     convoy forms in a lobby at the depot (ready-up, a countdown, "Start now" for the leader,
---     joining from the depot or by invite), then every member runs their own job. The first
---     delivery opens a grace period ; members delivering inside it get the convoy bonus and their
---     cohesion bonus (share of 1 s samples within 200 m of another member), later ones don't.
---   - **scoring** and **per-type score totals** (one total per player per cargo kind, all maps
---     combined), persisted in `deliveryScores.json` ; the Jobs section reads them as leaderboards
---     (`deliveryLeaderboardRequest`) and lists every depot's open jobs (`deliveryDepotsRequest`).
---
--- **Multi-stop** package jobs : 2 or 3 drop-offs in a row (depot -> stop -> stop), each leg within
--- the route distances ; the offer's destId is the last stop, `stops` lists them all in order.
--- The client holds at each stop in turn (`deliveryLegArrive`, position-checked like the final
--- arrival) ; they pay more than the extra distance alone (STOP_BONUS).
---
--- Scoring (per the Phase 3 design) : base = 100 per route km (min 50) x time factor
--- (target / actual, clamped 0.5 - 1.25) x condition (vehicle jobs : broken parts share, banded
--- Pristine 1.0 / Minor <=5% 0.85 / Moderate <=15% 0.6 / Heavy 0.3) x convoy (+10% per extra
--- member, on time only) x cohesion (up to +20%, on time only).

---@class BJDeliveryVehicle
---@field model string
---@field config string config key
---@field label string model + config label
---@field configLabel string?
---@field kind "cars"|"trucks"

---@class BJDeliveryOffer
---@field id integer
---@field depotId integer
---@field destId integer
---@field kind "packages"|"vehicles"
---@field cargo string? cargo type key (packages)
---@field vehicle BJDeliveryVehicle? (vehicles)
---@field meters integer route length (all legs)
---@field stops integer[]? multi-stop : every drop-off in order (the last one is destId)
---@field legMeters integer[]? multi-stop : each leg's length
---@field targetSec integer
---@field expiresAt integer GetCurrentTime() seconds

---@class BJDeliveryJob
---@field offer BJDeliveryOffer
---@field startedAt integer GetCurrentTime() seconds
---@field deadlineAt integer GetCurrentTime() seconds ; the job fails past this
---@field serverVid any the vehicle carrying the cargo, as the client reported it
---@field convoyId integer?
---@field slot integer? convoy member index (vehicle convoys : the start slot)
---@field leg integer? multi-stop : the stop being driven to (1-based)

---@class BJDeliveryScore
---@field total integer
---@field count integer
---@field failed integer?
---@field meters integer?
---@field resets integer?
---@field vehicles table<string, integer>? packages : vehicle label -> jobs

---@class BJDeliveryConvoyMember
---@field ready boolean
---@field serverVid any

---@class BJDeliveryConvoy
---@field id integer
---@field offer BJDeliveryOffer
---@field state "lobby"|"running"
---@field leaderID integer
---@field order integer[] playerIDs, join order
---@field members table<integer, BJDeliveryConvoyMember>
---@field lobbyEndsAt integer
---@field readyHold integer? seconds that were left when everyone got ready (restored if someone un-readies)
---@field leaderStarted boolean? the leader pressed Start now : the short countdown sticks
---@field invites table<integer, integer> playerID -> expiresAt
---@field size integer? members at the start
---@field startedAt integer?
---@field firstArrivalAt integer?
---@field graceEndsAt integer?
---@field samples table<integer, {near: integer, total: integer}>?
---@field rows table<integer, table>? playerID -> results row

local M = {
    dependencies = { "services_deliveryPoints", "services_core", "services_config", "dao_main" },

    SCORES_FILE = "deliveryScores.json",
    POOL_FILE = "deliveryPool.json",
    PACKAGE_CARGO = { "parcels", "food", "shopSupplies", "officeSupplies", "mechanicalParts" },
    MIN_TARGET_SEC = 60,
    DEADLINE_FACTOR = 2,
    MAX_POOL = 5000,
    -- broken-parts share -> condition band and score factor, first match wins
    CONDITION_BANDS = {
        { band = "pristine", maxShare = 0, factor = 1.0 },
        { band = "minor", maxShare = 0.05, factor = 0.85 },
        { band = "moderate", maxShare = 0.15, factor = 0.6 },
        { band = "heavy", maxShare = 1, factor = 0.3 },
    },
    -- slack on top of a zone's radius for the server-side position checks : the server's copy of a
    -- vehicle position lags the client's a little, and the depot prompt's own area is generous
    START_SLACK = 40,
    ARRIVE_SLACK = 25,

    -- vehicle jobs : the clock starts this long after the job, so every freshly spawned delivery
    -- vehicle has synced to the other players before anyone can drive (frozen until then)
    VEHICLE_SYNC_SEC = 8,
    MAX_CONVOY = 4,
    LEADERBOARD_SIZE = 100,
    -- multi-stop : chance a package offer tries to be one, and the score factor per stop count
    MULTI_STOP_CHANCE = 0.35,
    STOP_BONUS = { 1, 1.15, 1.3 },
    -- an unanswered convoy invite lapses after this : the leader's picker offers Invite again
    INVITE_SEC = 15,
    -- everyone ready, or the leader's "Start now" : the countdown drops to this
    QUICK_START_SEC = 5,
    -- grace period after the first delivery : this share of the target, clamped
    GRACE_SHARE = 0.2,
    GRACE_MIN = 45,
    GRACE_MAX = 180,
    CONVOY_BONUS = 0.1,
    COHESION_RADIUS = 200,
    COHESION_SKIP_SEC = 20,
    COHESION_BONUS = 0.2,

    ---@type table<integer, BJDeliveryOffer[]> depotId -> its current offers
    boards = {},
    ---@type table<integer, BJDeliveryJob> playerID -> active job
    jobs = {},
    ---@type table<integer, integer> playerID -> depotId whose board they have open
    viewers = {},
    -- per player : points, jobs delivered, jobs failed (ran out of time or abandoned), metres of
    -- delivered routes, and for packages the resets during delivered jobs and how many jobs each
    -- vehicle did (the favorite is the most used). Entries from older builds only have total/count
    ---@type {packages: table<string, BJDeliveryScore>, vehicles: table<string, BJDeliveryScore>}
    scores = { packages = {}, vehicles = {} },
    ---@type {vehicles: BJDeliveryVehicle[], blacklist: string[], configBlacklist: {model: string, config: string}[]}
    pool = { vehicles = {}, blacklist = {}, configBlacklist = {} },
    nextOfferId = 1,
    ---@type table<integer, BJDeliveryConvoy>
    convoys = {},
    ---@type table<integer, integer> playerID -> convoyId (lobby, or running while their job runs)
    memberOf = {},
    nextConvoyId = 1,
}

---@return table
local function settings()
    return services_config.data.Deliveries
end

---@param playerID integer
---@return string
local scoreKey

local function nameOf(playerID)
    local ok, name = pcall(MP.GetPlayerName, playerID)
    return ok and type(name) == "string" and #name > 0 and name or "?"
end

---@param playerID integer
---@return boolean busy in a delivery job or a convoy
local function isBusy(playerID)
    return M.jobs[playerID] ~= nil or M.memberOf[playerID] ~= nil
end

-- SCORES ----------------------------------------------------------------------------------------

local function loadScores()
    local saved = dao_main.get(M.SCORES_FILE)
    M.scores = {
        packages = type(saved) == "table" and type(saved.packages) == "table" and saved.packages or {},
        vehicles = type(saved) == "table" and type(saved.vehicles) == "table" and saved.vehicles or {},
    }
end

---@param kind string
---@param playerName string
---@return integer rank 1-based, integer players on the board
--- the name a player's delivery scores are kept under, or nil when they can't keep any
---@param ctxt BJSContext
---@return string?
scoreKey = function(ctxt)
    local key = services_identity and services_identity.getIdentityKey(ctxt.senderID) or ctxt.sender.playerName
    if ctxt.sender.guest and not ctxt.sender.identityNickname then return nil end
    return key
end

--- a delivered or failed job, on the player's score entry
---@param kind string
---@param playerName string?
---@param fn fun(entry: BJDeliveryScore)
local function updateScore(kind, playerName, fn)
    if not playerName or not M.scores[kind] then return end
    local entry = M.scores[kind][playerName] or { total = 0, count = 0 }
    fn(entry)
    M.scores[kind][playerName] = entry
    dao_main.save(M.SCORES_FILE, M.scores)
end

--- a job ran out of time or was given up : counts against the success rate
---@param playerID integer
---@param kind string
local function recordFailed(playerID, kind)
    local ok, ctxt = pcall(InitContext, playerID)
    if not ok or not ctxt or not ctxt.sender then return end
    updateScore(kind, scoreKey(ctxt), function(entry) entry.failed = (entry.failed or 0) + 1 end)
end

local MAX_VEHICLE_LABELS = 20

local function rankOf(kind, playerName)
    local board = M.scores[kind] or {}
    local mine = board[playerName] and board[playerName].total or 0
    local rank, count = 1, 0
    for name, entry in pairs(board) do
        count = count + 1
        if name ~= playerName and (entry.total or 0) > mine then rank = rank + 1 end
    end
    return rank, count
end

-- VEHICLE POOL ----------------------------------------------------------------------------------

local function loadPool()
    local saved = dao_main.get(M.POOL_FILE)
    M.pool = {
        vehicles = type(saved) == "table" and table.isArray(saved.vehicles) and saved.vehicles or {},
        blacklist = type(saved) == "table" and table.isArray(saved.blacklist) and saved.blacklist or {},
        configBlacklist = type(saved) == "table" and table.isArray(saved.configBlacklist) and
            saved.configBlacklist or {},
    }
end

---@param model string
---@param config string
---@return integer? index in configBlacklist
local function configBlacklistIndex(model, config)
    for i, e in ipairs(M.pool.configBlacklist) do
        if e.model == model and e.config == config then return i end
    end
end

local function savePool()
    dao_main.save(M.POOL_FILE, M.pool)
end

--- not blacklisted as a model, as that config, or by the spawn ModelBlacklist
---@param v {model: string, config: string}
---@return boolean
local function vehicleAllowed(v)
    return not table.includes(M.pool.blacklist, v.model) and
        not configBlacklistIndex(v.model, v.config) and
        not table.includes(services_config.data.ModelBlacklist or {}, v.model)
end

---@param kinds table<string, true> "cars"/"trucks" the destination accepts
---@return BJDeliveryVehicle?
local function pickVehicle(kinds)
    local eligible = {}
    for _, v in ipairs(M.pool.vehicles) do
        if kinds[v.kind] and vehicleAllowed(v) then eligible[#eligible + 1] = v end
    end
    if #eligible == 0 then return nil end
    return eligible[math.random(#eligible)]
end

--- summary for the admin's Deliveries settings panel : one row per model
---@return table
local function poolSummary()
    local byModel, order = {}, {}
    local cars, trucks = 0, 0
    for _, v in ipairs(M.pool.vehicles) do
        if v.kind == "trucks" then trucks = trucks + 1 else cars = cars + 1 end
        local row = byModel[v.model]
        if not row then
            row = { model = v.model, label = v.modelLabel or v.model, kind = v.kind, configs = 0,
                blocked = 0, blacklisted = table.includes(M.pool.blacklist, v.model), list = {} }
            byModel[v.model] = row
            order[#order + 1] = row
        end
        row.configs = row.configs + 1
        local off = configBlacklistIndex(v.model, v.config) ~= nil
        if off then row.blocked = row.blocked + 1 end
        local label = v.configLabel
        if not label and v.modelLabel and v.label:sub(1, #v.modelLabel + 1) == v.modelLabel .. " " then
            label = v.label:sub(#v.modelLabel + 2)
        end
        row.list[#row.list + 1] = { config = v.config, label = label or v.label, blacklisted = off }
    end
    for _, row in ipairs(order) do
        table.sort(row.list, function(a, b) return a.label:lower() < b.label:lower() end)
    end
    table.sort(order, function(a, b) return a.label:lower() < b.label:lower() end)
    return { count = #M.pool.vehicles, cars = cars, trucks = trucks, models = order }
end

---@param playerID integer
local function sendPoolToAdmin(playerID)
    if services_permissions.hasAllPermissions(playerID, BJ_PERMISSIONS.SetConfig) then
        communications_tx.sendToPlayer(playerID, "sendCache", { deliveryPool = poolSummary() })
    end
end

local function sendPoolToAdmins()
    services_players.players:forEach(function(p) sendPoolToAdmin(p.playerID) end)
end

--- rebuilds every board, e.g. after the pool changed (vehicle offers may appear or vanish)
local resetBoards
local sendLobbyTo
local updateReadyCountdown

---@param ctxt BJSContext
---@param list table[] {model, config, label, modelLabel, kind}
local function deliveryPoolSave(ctxt, list)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.SetConfig) then
        return
    end
    local clean = {}
    for _, v in ipairs(table.isArray(list) and list or {}) do
        if #clean >= M.MAX_POOL then break end
        if type(v) == "table" and type(v.model) == "string" and type(v.config) == "string" and
            (v.kind == "cars" or v.kind == "trucks") then
            clean[#clean + 1] = {
                model = v.model,
                config = v.config,
                label = type(v.label) == "string" and v.label:sub(1, 80) or v.model,
                modelLabel = type(v.modelLabel) == "string" and v.modelLabel:sub(1, 60) or v.model,
                configLabel = type(v.configLabel) == "string" and v.configLabel:sub(1, 60) or nil,
                kind = v.kind,
            }
        end
    end
    M.pool.vehicles = clean
    savePool()
    resetBoards()
    sendPoolToAdmins()
    if ctxt.sender then
        LogInfo(string.format("delivery vehicle pool updated by %s : %d configs", ctxt.sender.playerName, #clean))
    end
end

--- blocks or allows a whole model (config nil ; also covers configs a later refresh adds) or a
--- single config of it
---@param ctxt BJSContext
---@param model string
---@param blacklisted boolean
---@param config string?
local function deliveryPoolBlacklist(ctxt, model, blacklisted, config)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.SetConfig) then
        return
    end
    if type(model) ~= "string" then return end
    if type(config) == "string" then
        local index = configBlacklistIndex(model, config)
        if blacklisted and not index then
            table.insert(M.pool.configBlacklist, { model = model, config = config })
        elseif not blacklisted and index then
            table.remove(M.pool.configBlacklist, index)
        else
            return
        end
    else
        local index = table.indexOf(M.pool.blacklist, model)
        if blacklisted and not index then
            table.insert(M.pool.blacklist, model)
        elseif not blacklisted and index then
            table.remove(M.pool.blacklist, index)
        else
            return
        end
    end
    savePool()
    resetBoards()
    sendPoolToAdmins()
end

-- BOARDS ----------------------------------------------------------------------------------------

---@param meters number
---@return integer
local function targetSeconds(meters)
    local mps = settings().ReferenceSpeed / 3.6
    return math.max(M.MIN_TARGET_SEC, math.round(meters / mps))
end

---@param point BJDeliveryPoint
---@return boolean
local function offersPackages(point)
    return table.includes(point.provides, "packages")
end

---@param point BJDeliveryPoint
---@return boolean
local function offersVehicles(point)
    return table.includes(point.provides, "vehicles") and type(point.slots) == "table" and #point.slots > 0
end

---@param point BJDeliveryPoint
---@return boolean
local function hasJobs(point)
    return offersPackages(point) or offersVehicles(point)
end

--- every (destination, kind) a job from `depot` could run to, within the configured distances
---@param depot BJDeliveryPoint
---@return {dest: BJDeliveryPoint, meters: integer, kind: string}[]
local function candidates(depot)
    local list = {}
    local s = settings()
    local canPackages, canVehicles = offersPackages(depot), offersVehicles(depot) and #M.pool.vehicles > 0
    for _, p in ipairs(services_deliveryPoints.points) do
        local packages, vehicles = services_deliveryPoints.pairKinds(depot, p)
        local meters = (packages or vehicles) and services_deliveryPoints.getRouteLength(depot.id, p.id)
        if meters and meters >= s.MinRouteDistance and meters <= s.MaxRouteDistance then
            if packages and canPackages then list[#list + 1] = { dest = p, meters = meters, kind = "packages" } end
            if vehicles and canVehicles then list[#list + 1] = { dest = p, meters = meters, kind = "vehicles" } end
        end
    end
    return list
end

--- a multi-stop route starting depot -> first : up to `count` stops in all, each further leg a
--- package drop-off not yet on the route (nor the depot) within the route distances ; nil when it
--- can't get past one stop
---@param depot BJDeliveryPoint
---@param first BJDeliveryPoint
---@param firstMeters integer
---@param count integer
---@return integer[]? stops, integer[]? legMeters
local function extendStops(depot, first, firstMeters, count)
    local s = settings()
    local stops, legs = { first.id }, { firstMeters }
    local visited = { [depot.id] = true, [first.id] = true }
    local prev = first
    while #stops < count do
        local options = {}
        for _, p in ipairs(services_deliveryPoints.points) do
            if not visited[p.id] and table.includes(p.receives, "packages") then
                local m = services_deliveryPoints.getRouteLength(prev.id, p.id)
                if m and m >= s.MinRouteDistance and m <= s.MaxRouteDistance then
                    options[#options + 1] = { point = p, meters = m }
                end
            end
        end
        if #options == 0 then break end
        local pick = options[math.random(#options)]
        stops[#stops + 1] = pick.point.id
        legs[#legs + 1] = pick.meters
        visited[pick.point.id] = true
        prev = pick.point
    end
    if #stops < 2 then return nil end
    return stops, legs
end

--- tops a depot's board up to OffersPerDepot, preferring (destination, kind) pairs not already on it
---@param depot BJDeliveryPoint
---@return boolean changed
local function fillBoard(depot)
    local board = M.boards[depot.id] or {}
    M.boards[depot.id] = board
    if not hasJobs(depot) then return false end
    local want = settings().OffersPerDepot
    if #board >= want then return false end

    local used = {}
    for _, o in ipairs(board) do used[o.destId .. o.kind] = true end
    local pool = {}
    for _, c in ipairs(candidates(depot)) do
        if not used[c.dest.id .. c.kind] then pool[#pool + 1] = c end
    end

    local changed = false
    local now = GetCurrentTime()
    local rotation = settings().OfferRotation * 60
    while #board < want and #pool > 0 do
        local c = table.remove(pool, math.random(#pool))
        local offer = {
            id = M.nextOfferId,
            depotId = depot.id,
            destId = c.dest.id,
            kind = c.kind,
            meters = c.meters,
            targetSec = targetSeconds(c.meters),
            -- staggered so a whole board never rotates out in the same second
            expiresAt = now + math.round(rotation * (0.75 + math.random() * 0.5)),
        }
        if c.kind == "vehicles" then
            local kinds = {}
            for _, k in ipairs(c.dest.receives) do kinds[k] = true end
            offer.vehicle = pickVehicle(kinds)
        else
            offer.cargo = M.PACKAGE_CARGO[math.random(#M.PACKAGE_CARGO)]
            if math.random() < M.MULTI_STOP_CHANCE then
                local stops, legs = extendStops(depot, c.dest, c.meters, math.random(2, 3))
                if stops then
                    offer.stops = stops
                    offer.legMeters = legs
                    offer.destId = stops[#stops]
                    offer.meters = 0
                    for _, m in ipairs(legs) do offer.meters = offer.meters + m end
                    -- each stop's hold counts toward the target too
                    offer.targetSec = targetSeconds(offer.meters) + (#stops - 1) * (settings().HoldDuration + 5)
                end
            end
        end
        if c.kind ~= "vehicles" or offer.vehicle then
            board[#board + 1] = offer
            M.nextOfferId = M.nextOfferId + 1
            changed = true
        end
    end
    return changed
end

---@param offer BJDeliveryOffer
---@return table
local function offerPayload(offer)
    local dest = services_deliveryPoints.getPoint(offer.destId)
    local stops
    if offer.stops then
        stops = {}
        for i, id in ipairs(offer.stops) do
            local p = services_deliveryPoints.getPoint(id)
            stops[i] = { id = id, name = p and p.name or "?", meters = offer.legMeters and offer.legMeters[i] }
        end
    end
    return {
        id = offer.id,
        kind = offer.kind,
        cargo = offer.cargo,
        vehicle = offer.vehicle,
        stops = stops,
        destId = offer.destId,
        destName = dest and dest.name or "?",
        meters = offer.meters,
        targetSec = offer.targetSec,
        expiresIn = math.max(0, offer.expiresAt - GetCurrentTime()),
    }
end

---@param offer BJDeliveryOffer
---@return integer
local function maxPlayers(offer)
    if offer.kind == "vehicles" then
        local depot = services_deliveryPoints.getPoint(offer.depotId)
        local slots = depot and type(depot.slots) == "table" and #depot.slots or 1
        return math.max(1, math.min(M.MAX_CONVOY, slots))
    end
    return M.MAX_CONVOY
end

--- a lobby as everyone else sees it (depot prompt, board, Jobs section)
---@param c BJDeliveryConvoy
---@return table
local function convoySummary(c)
    local p = offerPayload(c.offer)
    p.offerId = p.id
    p.id = c.id
    p.depotId = c.offer.depotId
    p.leaderName = nameOf(c.leaderID)
    p.count = #c.order
    p.max = maxPlayers(c.offer)
    return p
end

---@param depotId integer?
---@return table[] lobbies forming (at that depot, or everywhere)
local function formingConvoys(depotId)
    local list = {}
    for _, c in pairs(M.convoys) do
        if c.state == "lobby" and (not depotId or c.offer.depotId == depotId) then
            list[#list + 1] = convoySummary(c)
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

---@param playerID integer
---@param depotId integer
local function sendBoard(playerID, depotId)
    local depot = services_deliveryPoints.getPoint(depotId)
    local offers = {}
    for _, o in ipairs(M.boards[depotId] or {}) do
        local p = offerPayload(o)
        p.maxPlayers = maxPlayers(o)
        offers[#offers + 1] = p
    end
    communications_tx.sendToPlayer(playerID, "deliveryBoard", {
        depotId = depotId,
        depotName = depot and depot.name or "?",
        offers = offers,
        convoys = formingConvoys(depotId),
    })
end

---@param depotId integer
local function pushBoardToViewers(depotId)
    for playerID, viewing in pairs(M.viewers) do
        if viewing == depotId then sendBoard(playerID, depotId) end
    end
end

---@param offerId integer
---@return BJDeliveryOffer?, integer? index
local function findOffer(offerId)
    for _, board in pairs(M.boards) do
        for i, o in ipairs(board) do
            if o.id == offerId then return o, i end
        end
    end
end

-- POSITION CHECKS -------------------------------------------------------------------------------

--- the server's own copy of a vehicle's position, or nil when BeamMP can't tell us (in which case
--- the check is skipped rather than blocking a legitimate player)
---@param playerID integer
---@param serverVid any
---@return {x: number, y: number, z: number}?
local function vehiclePosition(playerID, serverVid)
    -- BeamMP's client-side serverVehicleID can be "<playerID>-<vehicleID>" ; the server API wants
    -- just the vehicle part
    serverVid = tonumber(tostring(serverVid or ""):match("(%d+)$"))
    if not serverVid or not MP.GetPositionRaw then return nil end
    local ok, raw, err = pcall(MP.GetPositionRaw, playerID, serverVid)
    if not ok or err or type(raw) ~= "table" or type(raw.pos) ~= "table" then return nil end
    return { x = raw.pos[1], y = raw.pos[2], z = raw.pos[3] }
end

---@param pos {x: number, y: number, z: number}?
---@param point BJDeliveryPoint
---@param slack number
---@return boolean
local function near(pos, point, slack)
    if not pos then return true end
    local dx, dy = pos.x - point.pos.x, pos.y - point.pos.y
    return math.sqrt(dx * dx + dy * dy) <= point.radius + slack
end

-- JOBS ------------------------------------------------------------------------------------------

--- the point the job is driving to now : the current stop of a multi-stop job, else the destination
---@param job BJDeliveryJob
---@return integer
local function currentStopId(job)
    local stops = job.offer.stops
    return stops and stops[math.min(job.leg or 1, #stops)] or job.offer.destId
end

---@param job BJDeliveryJob
---@return table?
local function convoyInfo(job)
    local c = job.convoyId and M.convoys[job.convoyId]
    if not c then return nil end
    local now = GetCurrentTime()
    return {
        id = c.id,
        size = c.size,
        slot = job.slot,
        graceEndsIn = c.graceEndsAt and math.max(0, c.graceEndsAt - now) or nil,
    }
end

---@param job BJDeliveryJob
---@return table
local function jobPayload(job)
    local from = services_deliveryPoints.getPoint(job.offer.depotId)
    local to = services_deliveryPoints.getPoint(currentStopId(job))
    local stops
    if job.offer.stops then
        stops = {}
        for i, id in ipairs(job.offer.stops) do
            local p = services_deliveryPoints.getPoint(id)
            stops[i] = { id = id, name = p and p.name or "?" }
        end
    end
    return {
        kind = job.offer.kind,
        stops = stops,
        leg = job.leg or 1,
        cargo = job.offer.cargo,
        vehicle = job.offer.vehicle,
        meters = job.offer.meters,
        targetSec = job.offer.targetSec,
        deadlineSec = job.deadlineAt - job.startedAt,
        elapsedSec = GetCurrentTime() - job.startedAt,
        from = from and { id = from.id, name = from.name, pos = from.pos, radius = from.radius, slots = from.slots } or nil,
        to = to and { id = to.id, name = to.name, pos = to.pos, radius = to.radius } or nil,
        convoy = convoyInfo(job),
    }
end

-- CONVOY RUN ------------------------------------------------------------------------------------

---@param c BJDeliveryConvoy
---@return table
local function convoyResultsPayload(c)
    local rows = {}
    for _, pid in ipairs(c.order) do
        local row = c.rows[pid]
        if row then rows[#rows + 1] = row end
    end
    return {
        convoyId = c.id,
        size = c.size,
        targetSec = c.offer.targetSec,
        graceSec = c.graceEndsAt and c.firstArrivalAt and (c.graceEndsAt - c.firstArrivalAt) or nil,
        rows = rows,
    }
end

--- every member gets the table (the ones with their results open show it) ; a convoy whose
--- members have all finished is dropped
---@param c BJDeliveryConvoy
local function pushConvoyResults(c)
    local payload = convoyResultsPayload(c)
    local finished = true
    for _, pid in ipairs(c.order) do
        communications_tx.sendToPlayer(pid, "deliveryConvoyResults", payload)
        if c.rows[pid] and c.rows[pid].status == "driving" then finished = false end
    end
    if finished then
        M.convoys[c.id] = nil
        for _, pid in ipairs(c.order) do
            if M.memberOf[pid] == c.id then M.memberOf[pid] = nil end
        end
    end
end

---@param playerID integer
---@param status string failed|left
local function convoyMemberOut(playerID, status)
    local c = M.convoys[M.memberOf[playerID] or -1]
    if not c or c.state ~= "running" then return end
    local row = c.rows[playerID]
    if row and row.status == "driving" then row.status = status end
    M.memberOf[playerID] = nil
    pushConvoyResults(c)
end

---@param playerID integer
---@param reason string
local function endJob(playerID, reason)
    local job = M.jobs[playerID]
    if not job then return end
    M.jobs[playerID] = nil
    if reason == "timedOut" or reason == "abandoned" then recordFailed(playerID, job.offer.kind) end
    communications_tx.sendToPlayer(playerID, "deliveryEnded", reason)
    convoyMemberOut(playerID, reason == "timedOut" and "failed" or "left")
end

---@param ctxt BJSContext
---@param depotId integer
local function deliveryBoardOpen(ctxt, depotId)
    if not ctxt.sender then return end
    local depot = services_deliveryPoints.getPoint(tonumber(depotId))
    if not depot or not hasJobs(depot) then return end
    M.viewers[ctxt.senderID] = depot.id
    fillBoard(depot)
    sendBoard(ctxt.senderID, depot.id)
end

---@param ctxt BJSContext
local function deliveryBoardClose(ctxt)
    if not ctxt.sender then return end
    M.viewers[ctxt.senderID] = nil
end

--- when a new job's clock starts : now, or after the sync delay for vehicle jobs
---@param offer BJDeliveryOffer
---@return integer
local function startTime(offer)
    return GetCurrentTime() + (offer.kind == "vehicles" and M.VEHICLE_SYNC_SEC or 0)
end

---@param ctxt BJSContext
---@param reason string
local function refuseStart(ctxt, reason)
    communications_tx.sendToPlayer(ctxt.senderID, "deliveryStartRefused", reason)
end

---@param ctxt BJSContext
---@param offerId integer
---@param serverVid integer the client's own current vehicle, as BeamMP's server knows it
local function deliveryStart(ctxt, offerId, serverVid)
    if not ctxt.sender then return end
    if isBusy(ctxt.senderID) then return refuseStart(ctxt, "alreadyInJob") end
    local offer, index = findOffer(tonumber(offerId))
    if not offer then return refuseStart(ctxt, "offerGone") end
    local depot = services_deliveryPoints.getPoint(offer.depotId)
    local dest = services_deliveryPoints.getPoint(offer.destId)
    if not depot or not dest then return refuseStart(ctxt, "offerGone") end
    if offer.kind == "vehicles" and (not offersVehicles(depot) or not offer.vehicle or
            not vehicleAllowed(offer.vehicle)) then
        return refuseStart(ctxt, "offerGone")
    end
    if not near(vehiclePosition(ctxt.senderID, serverVid), depot, M.START_SLACK) then
        return refuseStart(ctxt, "notAtDepot")
    end
    if services_crews.pullSize(ctxt.senderID) > maxPlayers(offer) then
        return refuseStart(ctxt, "crewTooBig")
    end

    table.remove(M.boards[offer.depotId], index)
    fillBoard(depot)
    M.viewers[ctxt.senderID] = nil
    pushBoardToViewers(depot.id)

    local now = startTime(offer)
    local job = {
        offer = offer,
        startedAt = now,
        deadlineAt = now + offer.targetSec * M.DEADLINE_FACTOR,
        serverVid = serverVid,
    }
    M.jobs[ctxt.senderID] = job
    communications_tx.sendToPlayer(ctxt.senderID, "deliveryJob", jobPayload(job))
end

--- the client reports the vehicle's broken parts at arrival (vehicle jobs) ; nil when the game
--- couldn't read them, which scores the condition as untouched rather than guessing
---@param condition any {broken: integer, total: integer}?
---@return table? {band, broken, total, factor}
local function conditionOf(condition)
    if type(condition) ~= "table" then return nil end
    local total = math.floor(tonumber(condition.total) or 0)
    local broken = math.floor(tonumber(condition.broken) or -1)
    if total <= 0 or broken < 0 or broken > total then return nil end
    local share = broken / total
    for _, b in ipairs(M.CONDITION_BANDS) do
        if share <= b.maxShare then
            return { band = b.band, broken = broken, total = total, factor = b.factor }
        end
    end
end

---@param ctxt BJSContext
---@param serverVid integer
---@param condition table? vehicle jobs : {broken, total}
---@param stats table? {resets: integer, vehicle: string} the client's count for this job
local function deliveryArrive(ctxt, serverVid, condition, stats)
    if not ctxt.sender then return end
    local job = M.jobs[ctxt.senderID]
    if not job then return end
    if job.offer.stops and (job.leg or 1) < #job.offer.stops then
        return communications_tx.sendToPlayer(ctxt.senderID, "deliveryArriveRefused")
    end
    local dest = services_deliveryPoints.getPoint(job.offer.destId)
    if not dest then return endJob(ctxt.senderID, "pointRemoved") end
    if not near(vehiclePosition(ctxt.senderID, serverVid), dest, M.ARRIVE_SLACK) then
        -- the client thinks it's there but the server doesn't agree : let it keep trying
        return communications_tx.sendToPlayer(ctxt.senderID, "deliveryArriveRefused")
    end

    M.jobs[ctxt.senderID] = nil
    local offer = job.offer
    local now = GetCurrentTime()
    local actual = math.max(1, now - job.startedAt)
    local base = math.max(50, math.round(offer.meters / 1000 * 100))
    local timeFactor = math.max(0.5, math.min(1.25, offer.targetSec / actual))
    local cond = offer.kind == "vehicles" and conditionOf(condition) or nil

    -- convoy : the first delivery opens the grace period ; on time = inside it
    local c = job.convoyId and M.convoys[job.convoyId]
    if c and c.state ~= "running" then c = nil end
    local convoy
    if c then
        local first = c.firstArrivalAt == nil
        if first then
            c.firstArrivalAt = now
            local grace = math.max(M.GRACE_MIN, math.min(M.GRACE_MAX,
                math.round(offer.targetSec * M.GRACE_SHARE)))
            c.graceEndsAt = now + grace
        end
        local onTime = now <= c.graceEndsAt
        local sample = c.samples[ctxt.senderID]
        local share = c.size > 1 and sample and sample.total > 0 and sample.near / sample.total or nil
        convoy = {
            id = c.id,
            size = c.size,
            onTime = onTime,
            first = first,
            graceSec = c.graceEndsAt - c.firstArrivalAt,
            sizeFactor = (onTime and c.size > 1) and math.round(1 + M.CONVOY_BONUS * (c.size - 1), 2) or 1,
            cohesionShare = share and math.round(share, 2) or nil,
            cohesionFactor = (onTime and share) and math.round(1 + share * M.COHESION_BONUS, 2) or 1,
        }
        if first then
            -- everyone still driving learns the grace clock started
            for _, pid in ipairs(c.order) do
                if pid ~= ctxt.senderID and M.jobs[pid] and M.jobs[pid].convoyId == c.id then
                    communications_tx.sendToPlayer(pid, "deliveryConvoyGrace", {
                        firstName = ctxt.sender.playerName,
                        graceEndsIn = c.graceEndsAt - now,
                    })
                end
            end
        end
    end

    local stopCount = offer.stops and #offer.stops or 1
    local stopFactor = M.STOP_BONUS[stopCount] or M.STOP_BONUS[#M.STOP_BONUS]
    local score = math.round(base * timeFactor * (cond and cond.factor or 1) * stopFactor *
        (convoy and convoy.sizeFactor or 1) * (convoy and convoy.cohesionFactor or 1))

    local kind = offer.kind
    -- scores follow the player's identity (their chosen nickname when they logged in with one,
    -- the account name otherwise ; see services/identity.lua) so a BeamMP guest with a nickname
    -- keeps a stable place. A guest without one has a throwaway name : nothing to keep
    local playerName = scoreKey(ctxt)
    local total, rank, players
    if playerName then
        stats = type(stats) == "table" and stats or {}
        updateScore(kind, playerName, function(entry)
            entry.total = entry.total + score
            entry.count = entry.count + 1
            entry.meters = (entry.meters or 0) + math.round(tonumber(offer.meters) or 0)
            if kind == "packages" then
                entry.resets = (entry.resets or 0) + math.max(0, math.floor(tonumber(stats.resets) or 0))
                local label = type(stats.vehicle) == "string" and stats.vehicle:sub(1, 60) or ""
                if #label > 0 then
                    entry.vehicles = entry.vehicles or {}
                    entry.vehicles[label] = (entry.vehicles[label] or 0) + 1
                    -- keep the list short : the least used goes
                    if table.length(entry.vehicles) > MAX_VEHICLE_LABELS then
                        local least, leastN
                        for l, n in pairs(entry.vehicles) do
                            if l ~= label and (not leastN or n < leastN) then least, leastN = l, n end
                        end
                        if least then entry.vehicles[least] = nil end
                    end
                end
            end
            total = entry.total
        end)
        rank, players = rankOf(kind, playerName)
    end

    local from = services_deliveryPoints.getPoint(offer.depotId)
    communications_tx.sendToPlayer(ctxt.senderID, "deliveryResult", {
        kind = kind,
        cargo = offer.cargo,
        vehicle = offer.vehicle,
        fromName = from and from.name or "?",
        toName = dest.name,
        toId = dest.id,
        toIsDepot = hasJobs(dest),
        meters = offer.meters,
        targetSec = offer.targetSec,
        actualSec = actual,
        base = base,
        timeFactor = math.round(timeFactor, 2),
        condition = cond,
        conditionUnknown = offer.kind == "vehicles" and cond == nil,
        stops = stopCount > 1 and stopCount or nil,
        stopFactor = stopCount > 1 and stopFactor or nil,
        score = score,
        total = total,
        rank = rank,
        players = players,
        convoy = convoy,
    })

    if c then
        c.rows[ctxt.senderID] = {
            name = ctxt.sender.playerName,
            status = convoy.onTime and "delivered" or "late",
            actualSec = actual,
            band = cond and cond.band or nil,
            cohesion = convoy.cohesionShare,
            score = score,
        }
        M.memberOf[ctxt.senderID] = nil
        pushConvoyResults(c)
    end
end

--- multi-stop : the client held inside the current (not last) stop ; checked like the final
--- arrival, then the job moves on to the next stop
---@param ctxt BJSContext
---@param serverVid any
local function deliveryLegArrive(ctxt, serverVid)
    if not ctxt.sender then return end
    local job = M.jobs[ctxt.senderID]
    if not job or not job.offer.stops or (job.leg or 1) >= #job.offer.stops then return end
    local stop = services_deliveryPoints.getPoint(currentStopId(job))
    if not stop then return endJob(ctxt.senderID, "pointRemoved") end
    if not near(vehiclePosition(ctxt.senderID, serverVid), stop, M.ARRIVE_SLACK) then
        return communications_tx.sendToPlayer(ctxt.senderID, "deliveryArriveRefused")
    end
    job.leg = (job.leg or 1) + 1
    local nextStop = services_deliveryPoints.getPoint(currentStopId(job))
    if not nextStop then return endJob(ctxt.senderID, "pointRemoved") end
    communications_tx.sendToPlayer(ctxt.senderID, "deliveryLeg", {
        leg = job.leg,
        doneName = stop.name,
        to = { id = nextStop.id, name = nextStop.name, pos = nextStop.pos, radius = nextStop.radius },
    })
end

--- the client's delivery vehicle registered (vehicle jobs spawn a new one after the start) ;
--- the cohesion sampling reads positions from it
---@param ctxt BJSContext
---@param serverVid any
local function deliveryVehicleReady(ctxt, serverVid)
    if not ctxt.sender then return end
    local job = M.jobs[ctxt.senderID]
    if job and serverVid ~= nil then job.serverVid = serverVid end
end

-- CONVOY LOBBY ----------------------------------------------------------------------------------

local function broadcastConvoys()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "deliveryConvoys", formingConvoys())
end

---@param c BJDeliveryConvoy
---@param playerID integer
sendLobbyTo = function(c, playerID)
    local depot = services_deliveryPoints.getPoint(c.offer.depotId)
    local members = {}
    for _, pid in ipairs(c.order) do
        members[#members + 1] = {
            playerID = pid,
            name = nameOf(pid),
            ready = c.members[pid].ready,
            leader = pid == c.leaderID,
            you = pid == playerID,
        }
    end
    local offer = offerPayload(c.offer)
    communications_tx.sendToPlayer(playerID, "deliveryLobby", {
        id = c.id,
        depotId = c.offer.depotId,
        depotName = depot and depot.name or "?",
        depotPos = depot and depot.pos or nil,
        depotRadius = depot and depot.radius or nil,
        kind = offer.kind,
        cargo = offer.cargo,
        vehicle = offer.vehicle,
        destName = offer.destName,
        meters = offer.meters,
        targetSec = offer.targetSec,
        startsIn = math.max(0, c.lobbyEndsAt - GetCurrentTime()),
        max = maxPlayers(c.offer),
        isLeader = playerID == c.leaderID,
        members = members,
    })
end

---@param c BJDeliveryConvoy
local function pushLobby(c)
    for _, pid in ipairs(c.order) do sendLobbyTo(c, pid) end
    pushBoardToViewers(c.offer.depotId)
    broadcastConvoys()
end

---@param c BJDeliveryConvoy
---@param playerID integer
local function closeInvite(c, playerID)
    if c.invites[playerID] then
        c.invites[playerID] = nil
        communications_tx.sendToPlayer(playerID, "deliveryInviteClosed", c.id)
    end
end

---@param c BJDeliveryConvoy
---@param reason string sent to whoever is still in it
local function disbandLobby(c, reason)
    M.convoys[c.id] = nil
    for _, pid in ipairs(c.order) do
        if M.memberOf[pid] == c.id then M.memberOf[pid] = nil end
        communications_tx.sendToPlayer(pid, "deliveryLobbyClosed", reason)
    end
    for pid in pairs(c.invites) do closeInvite(c, pid) end
    local depot = services_deliveryPoints.getPoint(c.offer.depotId)
    if depot then fillBoard(depot) end
    pushBoardToViewers(c.offer.depotId)
    broadcastConvoys()
end

--- removes a member from a lobby ; the next one in line leads when the leader goes
---@param c BJDeliveryConvoy
---@param playerID integer
---@param reason string? told to the one removed
local function removeFromLobby(c, playerID, reason)
    local index = table.indexOf(c.order, playerID)
    if not index then return end
    table.remove(c.order, index)
    c.members[playerID] = nil
    if M.memberOf[playerID] == c.id then M.memberOf[playerID] = nil end
    if reason then communications_tx.sendToPlayer(playerID, "deliveryLobbyClosed", reason) end
    if #c.order == 0 then
        disbandLobby(c, "disbanded")
        return
    end
    if c.leaderID == playerID then c.leaderID = c.order[1] end
    updateReadyCountdown(c)
    pushLobby(c)
end

---@param c BJDeliveryConvoy
---@param playerID integer
---@param serverVid any
local function addToLobby(c, playerID, serverVid)
    c.order[#c.order + 1] = playerID
    c.members[playerID] = { ready = false, serverVid = serverVid }
    M.memberOf[playerID] = c.id
    closeInvite(c, playerID)
    M.viewers[playerID] = nil
    updateReadyCountdown(c)
    pushLobby(c)
end

---@param c BJDeliveryConvoy
local function everyoneReady(c)
    for _, pid in ipairs(c.order) do
        if not c.members[pid].ready then return false end
    end
    return #c.order > 0
end

---@param c BJDeliveryConvoy
local function quickStart(c)
    c.lobbyEndsAt = math.min(c.lobbyEndsAt, GetCurrentTime() + M.QUICK_START_SEC)
end

--- everyone ready : the countdown drops to the short one, remembering what was left ; someone
--- un-readying (or an unready player joining) puts back what was left then. The leader's Start
--- now sticks either way.
---@param c BJDeliveryConvoy
updateReadyCountdown = function(c)
    local now = GetCurrentTime()
    if everyoneReady(c) then
        if not c.readyHold and not c.leaderStarted then
            c.readyHold = math.max(0, c.lobbyEndsAt - now)
        end
        quickStart(c)
    elseif c.readyHold then
        if not c.leaderStarted then c.lobbyEndsAt = now + c.readyHold end
        c.readyHold = nil
    end
end

--- the lobby's countdown ran out : every member gets their own job on the offer. Members don't
--- have to be at the depot : each client brings its player there as the job starts (vehicle
--- convoys : member i's delivery vehicle spawns on start slot i ; package convoys : member i's
--- car is moved to slot i, or next to the depot)
---@param c BJDeliveryConvoy
local function startConvoy(c)
    local depot = services_deliveryPoints.getPoint(c.offer.depotId)
    local dest = services_deliveryPoints.getPoint(c.offer.destId)
    if not depot or not dest then return disbandLobby(c, "pointRemoved") end
    for pid in pairs(c.invites) do closeInvite(c, pid) end

    local now = startTime(c.offer)
    c.state = "running"
    c.size = #c.order
    c.startedAt = now
    c.samples = {}
    c.rows = {}
    for i, pid in ipairs(c.order) do
        local job = {
            offer = c.offer,
            startedAt = now,
            deadlineAt = now + c.offer.targetSec * M.DEADLINE_FACTOR,
            serverVid = c.members[pid].serverVid,
            convoyId = c.id,
            slot = i,
        }
        M.jobs[pid] = job
        c.samples[pid] = { near = 0, total = 0 }
        c.rows[pid] = { name = nameOf(pid), status = "driving" }
        communications_tx.sendToPlayer(pid, "deliveryJob", jobPayload(job))
    end
    pushBoardToViewers(c.offer.depotId)
    broadcastConvoys()
end

---@param ctxt BJSContext
---@param offerId integer
---@param serverVid any
local function deliveryConvoyCreate(ctxt, offerId, serverVid)
    if not ctxt.sender then return end
    if isBusy(ctxt.senderID) then return refuseStart(ctxt, "alreadyInJob") end
    local offer, index = findOffer(tonumber(offerId))
    if not offer then return refuseStart(ctxt, "offerGone") end
    local depot = services_deliveryPoints.getPoint(offer.depotId)
    if not depot or not services_deliveryPoints.getPoint(offer.destId) then return refuseStart(ctxt, "offerGone") end
    if offer.kind == "vehicles" and (not offersVehicles(depot) or not offer.vehicle or
            not vehicleAllowed(offer.vehicle)) then
        return refuseStart(ctxt, "offerGone")
    end
    if not near(vehiclePosition(ctxt.senderID, serverVid), depot, M.START_SLACK) then
        return refuseStart(ctxt, "notAtDepot")
    end

    table.remove(M.boards[offer.depotId], index)
    fillBoard(depot)
    local c = {
        id = M.nextConvoyId,
        offer = offer,
        state = "lobby",
        leaderID = ctxt.senderID,
        order = {},
        members = {},
        lobbyEndsAt = GetCurrentTime() + settings().LobbyDuration,
        invites = {},
    }
    M.nextConvoyId = M.nextConvoyId + 1
    M.convoys[c.id] = c
    addToLobby(c, ctxt.senderID, serverVid)
    -- the leader's crew comes along (services/crews.lua)
    services_crews.pullIn(ctxt.senderID, "convoy", c.id)
end

---@param ctxt BJSContext
---@param convoyId integer
---@param serverVid any
---@param viaInvite boolean?
local function deliveryConvoyJoin(ctxt, convoyId, serverVid, viaInvite)
    if not ctxt.sender then return end
    local c = M.convoys[tonumber(convoyId) or -1]
    if not c or c.state ~= "lobby" then return refuseStart(ctxt, "convoyGone") end
    if M.memberOf[ctxt.senderID] == c.id then return end
    if isBusy(ctxt.senderID) then return refuseStart(ctxt, "alreadyInJob") end
    if #c.order >= maxPlayers(c.offer) then return refuseStart(ctxt, "convoyFull") end
    -- joinable from anywhere (depot prompt, board, Jobs section, invite) : every member is
    -- brought to the depot when the convoy leaves
    addToLobby(c, ctxt.senderID, serverVid)
end

---@param ctxt BJSContext
---@param ready boolean
---@param serverVid any
local function deliveryConvoyReady(ctxt, ready, serverVid)
    if not ctxt.sender then return end
    local c = M.convoys[M.memberOf[ctxt.senderID] or -1]
    if not c or c.state ~= "lobby" then return end
    local member = c.members[ctxt.senderID]
    if serverVid ~= nil then member.serverVid = serverVid end
    -- no position check : a member away from the depot is brought there at the start
    member.ready = ready == true
    updateReadyCountdown(c)
    pushLobby(c)
end

---@param ctxt BJSContext
local function deliveryConvoyStartNow(ctxt)
    if not ctxt.sender then return end
    local c = M.convoys[M.memberOf[ctxt.senderID] or -1]
    if not c or c.state ~= "lobby" or c.leaderID ~= ctxt.senderID then return end
    c.leaderStarted = true
    quickStart(c)
    pushLobby(c)
end

---@param ctxt BJSContext
local function deliveryConvoyLeave(ctxt)
    if not ctxt.sender then return end
    local c = M.convoys[M.memberOf[ctxt.senderID] or -1]
    if not c or c.state ~= "lobby" then return end
    removeFromLobby(c, ctxt.senderID, "left")
end

--- everyone the sender could invite, busy ones included (shown as busy)
---@param ctxt BJSContext
local function deliveryConvoyInviteList(ctxt)
    if not ctxt.sender then return end
    local c = M.convoys[M.memberOf[ctxt.senderID] or -1]
    if not c or c.state ~= "lobby" then return end
    local list = {}
    services_players.players:forEach(function(p)
        if p.playerID ~= ctxt.senderID and not c.members[p.playerID] then
            list[#list + 1] = {
                playerID = p.playerID,
                name = p.playerName,
                busy = isBusy(p.playerID),
                invited = c.invites[p.playerID] ~= nil,
            }
        end
    end)
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    communications_tx.sendToPlayer(ctxt.senderID, "deliveryInviteList", list)
end

---@param ctxt BJSContext
---@param targetID integer
local function deliveryConvoyInvite(ctxt, targetID)
    if not ctxt.sender then return end
    targetID = tonumber(targetID)
    local c = M.convoys[M.memberOf[ctxt.senderID] or -1]
    if not c or c.state ~= "lobby" or not targetID or targetID == ctxt.senderID then return end
    if nameOf(targetID) == "?" or c.members[targetID] then return end
    if isBusy(targetID) then
        communications_tx.sendToPlayer(ctxt.senderID, "deliveryStartRefused", "inviteeBusy")
    elseif #c.order >= maxPlayers(c.offer) then
        communications_tx.sendToPlayer(ctxt.senderID, "deliveryStartRefused", "convoyFull")
    else
        c.invites[targetID] = GetCurrentTime() + M.INVITE_SEC
        local offer = offerPayload(c.offer)
        local depot = services_deliveryPoints.getPoint(c.offer.depotId)
        communications_tx.sendToPlayer(targetID, "deliveryInvite", {
            convoyId = c.id,
            fromName = ctxt.sender.playerName,
            kind = offer.kind,
            cargo = offer.cargo,
            vehicle = offer.vehicle,
            destName = offer.destName,
            depotId = c.offer.depotId,
            depotName = depot and depot.name or "?",
            meters = offer.meters,
            slotsLeft = maxPlayers(c.offer) - #c.order,
            expiresIn = M.INVITE_SEC,
        })
    end
    deliveryConvoyInviteList(ctxt)
end

---@param ctxt BJSContext
---@param convoyId integer
---@param accept boolean
---@param serverVid any
local function deliveryConvoyInviteReply(ctxt, convoyId, accept, serverVid)
    if not ctxt.sender then return end
    local c = M.convoys[tonumber(convoyId) or -1]
    if not c or not c.invites[ctxt.senderID] then
        if accept then refuseStart(ctxt, "convoyGone") end
        return
    end
    c.invites[ctxt.senderID] = nil
    if accept then deliveryConvoyJoin(ctxt, c.id, serverVid, true) end
end

---@param now integer
local function tickConvoys(now)
    for _, c in pairs(M.convoys) do
        if c.state == "lobby" then
            for pid, expiresAt in pairs(c.invites) do
                if now >= expiresAt or nameOf(pid) == "?" then closeInvite(c, pid) end
            end
            if now >= c.lobbyEndsAt then startConvoy(c) end
        elseif c.state == "running" and c.size > 1 and not c.firstArrivalAt and
            now - c.startedAt >= M.COHESION_SKIP_SEC then
            -- cohesion : one sample per member per second, near = within range of any other
            -- member still driving ; no position (unknown vehicle) = no sample
            local positions = {}
            for _, pid in ipairs(c.order) do
                local job = M.jobs[pid]
                if job and job.convoyId == c.id then
                    positions[pid] = vehiclePosition(pid, job.serverVid)
                end
            end
            for pid, pos in pairs(positions) do
                local sample = c.samples[pid]
                sample.total = sample.total + 1
                for other, otherPos in pairs(positions) do
                    if other ~= pid then
                        local dx, dy, dz = pos.x - otherPos.x, pos.y - otherPos.y, pos.z - otherPos.z
                        if math.sqrt(dx * dx + dy * dy + dz * dz) <= M.COHESION_RADIUS then
                            sample.near = sample.near + 1
                            break
                        end
                    end
                end
            end
        end
    end
end

-- JOBS SECTION ----------------------------------------------------------------------------------

--- every depot with its open jobs by kind (boards are filled on the way, as if someone looked)
---@param ctxt BJSContext
local function deliveryDepotsRequest(ctxt)
    if not ctxt.sender then return end
    local list = {}
    for _, p in ipairs(services_deliveryPoints.points) do
        if hasJobs(p) then
            fillBoard(p)
            local packages, vehicles = 0, 0
            for _, o in ipairs(M.boards[p.id] or {}) do
                if o.kind == "vehicles" then vehicles = vehicles + 1 else packages = packages + 1 end
            end
            list[#list + 1] = {
                id = p.id,
                sendsPackages = offersPackages(p),
                sendsVehicles = offersVehicles(p),
                packages = packages,
                vehicles = vehicles,
            }
        end
    end
    communications_tx.sendToPlayer(ctxt.senderID, "deliveryDepots", list)
end

--- what the leaderboard can be ranked by : higher first, except resets (fewest per job first)
local SORTS = {
    total = function(r) return r.total end,
    count = function(r) return r.count end,
    rate = function(r)
        local tries = r.count + r.failed
        return tries > 0 and r.count / tries or 0
    end,
    meters = function(r) return r.meters end,
    resets = function(r) return r.count > 0 and -((r.resets or 0) / r.count) or -math.huge end,
}

---@param vehicles table<string, integer>?
---@return string?
local function favoriteOf(vehicles)
    local best, bestN
    for label, n in pairs(vehicles or {}) do
        if not bestN or n > bestN or (n == bestN and label < best) then best, bestN = label, n end
    end
    return best
end

--- both leaderboards : the top LEADERBOARD_SIZE, plus the sender's own place, ranked by `sort`
--- (points by default ; see SORTS)
---@param ctxt BJSContext
---@param sort string?
local function deliveryLeaderboardRequest(ctxt, sort)
    if not ctxt.sender then return end
    sort = SORTS[sort] and sort or "total"
    local value = SORTS[sort]
    local me = scoreKey(ctxt) or ctxt.sender.playerName
    local payload = { sort = sort }
    for _, kind in ipairs({ "packages", "vehicles" }) do
        local rows = {}
        for name, entry in pairs(M.scores[kind] or {}) do
            rows[#rows + 1] = {
                name = name,
                total = entry.total or 0,
                count = entry.count or 0,
                failed = entry.failed or 0,
                meters = entry.meters or 0,
                resets = kind == "packages" and (entry.resets or 0) or nil,
                vehicle = kind == "packages" and favoriteOf(entry.vehicles) or nil,
            }
        end
        table.sort(rows, function(a, b)
            local va, vb = value(a), value(b)
            if va ~= vb then return va > vb end
            if a.total ~= b.total then return a.total > b.total end
            return a.name:lower() < b.name:lower()
        end)
        local top, mine = {}, nil
        for i, row in ipairs(rows) do
            row.rank = i
            if row.name == me then
                row.you = true
                mine = row
            end
            if i <= M.LEADERBOARD_SIZE then top[#top + 1] = row end
        end
        -- five places either side of the sender (the "Around you" view), from the full list
        local around = {}
        if mine then
            for i = math.max(1, mine.rank - 5), math.min(#rows, mine.rank + 5) do around[#around + 1] = rows[i] end
        end
        payload[kind] = { rows = top, players = #rows, mine = mine, around = around }
    end
    communications_tx.sendToPlayer(ctxt.senderID, "deliveryLeaderboard", payload)
end

---@param ctxt BJSContext
---@param reason string? client-side reason, logged only
local function deliveryAbandon(ctxt, reason)
    if not ctxt.sender then return end
    -- the job's vehicle couldn't spawn : not the player's failure
    endJob(ctxt.senderID, reason == "spawnFailed" and "spawnFailed" or "abandoned")
end

--- a reconnecting/reloading client asks whether it still has a job (a UI reload keeps the player
--- connected, so the job survives it)
---@param ctxt BJSContext
local function deliveryStateRequest(ctxt)
    if not ctxt.sender then return end
    local job = M.jobs[ctxt.senderID]
    if job then
        local payload = jobPayload(job)
        -- the vehicle already exists : don't spawn another one
        payload.resumed = true
        communications_tx.sendToPlayer(ctxt.senderID, "deliveryJob", payload)
    end
    communications_tx.sendToPlayer(ctxt.senderID, "deliveryConvoys", formingConvoys())
    local c = M.convoys[M.memberOf[ctxt.senderID] or -1]
    if c and c.state == "lobby" then sendLobbyTo(c, ctxt.senderID) end
end

-- LIFECYCLE -------------------------------------------------------------------------------------

---@param caches table
---@param targetID integer?
local function onBJRequestCache(caches, targetID)
    if targetID and services_permissions.hasAllPermissions(targetID, BJ_PERMISSIONS.SetConfig) then
        caches.deliveryPool = poolSummary()
    end
end

local function onSlowUpdate()
    local now = GetCurrentTime()
    -- rotate expired offers, only for boards someone has actually generated
    for depotId, board in pairs(M.boards) do
        local changed = false
        for i = #board, 1, -1 do
            if board[i].expiresAt <= now then
                table.remove(board, i)
                changed = true
            end
        end
        if changed then
            local depot = services_deliveryPoints.getPoint(depotId)
            if depot then fillBoard(depot) end
            pushBoardToViewers(depotId)
        end
    end
    for playerID, job in pairs(M.jobs) do
        if now > job.deadlineAt then endJob(playerID, "timedOut") end
    end
    tickConvoys(now)
end

resetBoards = function()
    M.boards = {}
    for playerID, depotId in pairs(M.viewers) do
        local depot = services_deliveryPoints.getPoint(depotId)
        if depot then
            fillBoard(depot)
            sendBoard(playerID, depotId)
        else
            M.viewers[playerID] = nil
        end
    end
end

--- points were edited or the map changed : every board is rebuilt from scratch, and a job whose
--- depot or destination no longer exists is ended
local function onBJDeliveryPointsChanged()
    for playerID, job in pairs(M.jobs) do
        local gone = not services_deliveryPoints.getPoint(job.offer.depotId) or
            not services_deliveryPoints.getPoint(job.offer.destId)
        for _, id in ipairs(job.offer.stops or {}) do
            if not services_deliveryPoints.getPoint(id) then gone = true end
        end
        if gone then endJob(playerID, "pointRemoved") end
    end
    for _, c in pairs(M.convoys) do
        if c.state == "lobby" and (not services_deliveryPoints.getPoint(c.offer.depotId) or
                not services_deliveryPoints.getPoint(c.offer.destId)) then
            disbandLobby(c, "pointRemoved")
        end
    end
    resetBoards()
end

local function onMapChanged()
    for playerID in pairs(M.jobs) do endJob(playerID, "mapChanged") end
    for _, c in pairs(M.convoys) do
        if c.state == "lobby" then disbandLobby(c, "mapChanged") end
    end
    M.convoys = {}
    M.memberOf = {}
    M.viewers = {}
    M.boards = {}
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.viewers[playerID] = nil
    local c = M.convoys[M.memberOf[playerID] or -1]
    if c and c.state == "lobby" then
        removeFromLobby(c, playerID)
    elseif M.jobs[playerID] then
        M.jobs[playerID] = nil
        convoyMemberOut(playerID, "left")
    end
    M.memberOf[playerID] = nil
    for _, other in pairs(M.convoys) do other.invites[playerID] = nil end
end

local function onInit()
    loadScores()
    loadPool()
    communications_rx.addHandler("deliveryBoardOpen", M.deliveryBoardOpen)
    communications_rx.addHandler("deliveryBoardClose", M.deliveryBoardClose)
    communications_rx.addHandler("deliveryStart", M.deliveryStart)
    communications_rx.addHandler("deliveryArrive", M.deliveryArrive)
    communications_rx.addHandler("deliveryAbandon", M.deliveryAbandon)
    communications_rx.addHandler("deliveryStateRequest", M.deliveryStateRequest)
    communications_rx.addHandler("deliveryPoolSave", M.deliveryPoolSave)
    communications_rx.addHandler("deliveryPoolBlacklist", M.deliveryPoolBlacklist)
    communications_rx.addHandler("deliveryVehicleReady", M.deliveryVehicleReady)
    communications_rx.addHandler("deliveryLegArrive", M.deliveryLegArrive)
    communications_rx.addHandler("deliveryDepotsRequest", M.deliveryDepotsRequest)
    communications_rx.addHandler("deliveryLeaderboardRequest", M.deliveryLeaderboardRequest)
    communications_rx.addHandler("deliveryConvoyCreate", M.deliveryConvoyCreate)
    communications_rx.addHandler("deliveryConvoyJoin", M.deliveryConvoyJoin)
    communications_rx.addHandler("deliveryConvoyReady", M.deliveryConvoyReady)
    communications_rx.addHandler("deliveryConvoyStartNow", M.deliveryConvoyStartNow)
    communications_rx.addHandler("deliveryConvoyLeave", M.deliveryConvoyLeave)
    communications_rx.addHandler("deliveryConvoyInviteList", M.deliveryConvoyInviteList)
    communications_rx.addHandler("deliveryConvoyInvite", M.deliveryConvoyInvite)
    communications_rx.addHandler("deliveryConvoyInviteReply", M.deliveryConvoyInviteReply)
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onSlowUpdate = onSlowUpdate
M.onMapChanged = onMapChanged
M.onPlayerDisconnect = onPlayerDisconnect
M.onBJDeliveryPointsChanged = onBJDeliveryPointsChanged

M.deliveryBoardOpen = deliveryBoardOpen
M.deliveryBoardClose = deliveryBoardClose
M.deliveryStart = deliveryStart
M.deliveryArrive = deliveryArrive
M.deliveryAbandon = deliveryAbandon
M.deliveryStateRequest = deliveryStateRequest
M.deliveryPoolSave = deliveryPoolSave
M.deliveryPoolBlacklist = deliveryPoolBlacklist
M.deliveryVehicleReady = deliveryVehicleReady
M.deliveryLegArrive = deliveryLegArrive
M.deliveryDepotsRequest = deliveryDepotsRequest
M.deliveryLeaderboardRequest = deliveryLeaderboardRequest
M.deliveryConvoyCreate = deliveryConvoyCreate
M.deliveryConvoyJoin = function(ctxt, convoyId, serverVid) deliveryConvoyJoin(ctxt, convoyId, serverVid) end
M.deliveryConvoyReady = deliveryConvoyReady
M.deliveryConvoyStartNow = deliveryConvoyStartNow
M.deliveryConvoyLeave = deliveryConvoyLeave
M.isBusy = isBusy
M.deliveryConvoyInviteList = deliveryConvoyInviteList
M.deliveryConvoyInvite = deliveryConvoyInvite
M.deliveryConvoyInviteReply = deliveryConvoyInviteReply

return M
