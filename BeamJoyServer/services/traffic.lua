local M = {
    ---@type tablelib<integer, integer> index playerID, value amount of traffic handled
    playerBalancer = Table(),
    ---@type tablelib<integer, integer> index playerID, value amount of parked vehicles handled
    parkedBalancer = Table(),

    --- the fugitives' full BeamMP vehicle ids ("<ownerID>-<vehicleID>", the same on every client)
    ---@type string[]
    pursuitFugitives = {},
    --- who started each chase, index fugitive id, value police playerID : one chase per police
    --- player at a time
    ---@type table<string, integer>
    pursuitPolice = {},
}

---@return table
local function getConf()
    local conf = services_config.data.Traffic
    conf.amount = tonumber(conf.amount) or conf.amount
    conf.maxPerPlayer = tonumber(conf.maxPerPlayer) or conf.maxPerPlayer
    conf.parkedAmount = tonumber(conf.parkedAmount) or conf.parkedAmount or 0
    conf.parkedMaxPerPlayer = tonumber(conf.parkedMaxPerPlayer) or conf.parkedMaxPerPlayer or 0
    return conf
end

---@param balancer tablelib<integer, integer>
---@param total integer effective target total; pass 0 when the feature (or master enabled toggle) is off
---@param maxPerPlayer integer
---@return tablelib<integer, integer> newBalancer, boolean changed
local function computeBalancer(balancer, total, maxPerPlayer)
    local sum = balancer:reduce(function(acc, amount)
        return acc + amount
    end, 0)

    if total <= 0 then
        if sum > 0 then return Table(), true end
        return balancer, false
    elseif sum ~= total then
        local newBalancer = Table()
        local newSum = 0
        services_players.players:values()
            :forEach(function(p, i)
                local balancedAmount = (total - newSum) /
                    (services_players.players:length() - i + 1)
                if i > 1 and math.floor(balancedAmount) < balancedAmount then
                    balancedAmount = math.ceil(balancedAmount)
                end
                balancedAmount = balancedAmount > maxPerPlayer and
                    maxPerPlayer or balancedAmount
                newBalancer[p.playerID] = math.round(balancedAmount)
                newSum = newSum + balancedAmount
            end)
        return newBalancer, true
    end
    return balancer, false
end

local function updateBalancer()
    local conf = getConf()
    local changes = false

    local newTrafficBalancer, trafficChanged = computeBalancer(
        M.playerBalancer, conf.enabled and conf.amount or 0, conf.maxPerPlayer)
    if trafficChanged then
        M.playerBalancer = newTrafficBalancer
        changes = true
    end

    -- parked vehicles share the master "enabled" toggle but have their own independent
    -- amount/maxPerPlayer, so they can be turned off on their own by setting parkedAmount to 0
    local newParkedBalancer, parkedChanged = computeBalancer(
        M.parkedBalancer, conf.enabled and conf.parkedAmount or 0, conf.parkedMaxPerPlayer)
    if parkedChanged then
        M.parkedBalancer = newParkedBalancer
        changes = true
    end

    if changes then
        services_players.players
            :forEach(function(p)
                local caches = {}
                M.onBJRequestCache(caches, p.playerID)
                communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
            end)
    end
end

local function onInit()
    communications_rx.addHandler("clientConnection", updateBalancer)
    communications_rx.addHandler("trafficSettings", M.rxSettings)

    communications_rx.addHandler("pursuitStart", M.startPursuit)
    communications_rx.addHandler("pursuitStop", M.stopPursuit)
end

---@param caches table
---@param targetID integer
local function onBJRequestCache(caches, targetID)
    local conf = getConf()
    caches.traffic = {
        enabled = conf.enabled,
        amount = M.playerBalancer[targetID] or 0,
        total = conf.amount,
        maxPerPlayer = conf.maxPerPlayer,
        models = conf.models,
        weights = conf.weights,
        smartSelection = conf.smartSelection,
        parkedAmount = M.parkedBalancer[targetID] or 0,
        parkedTotal = conf.parkedAmount,
        parkedMaxPerPlayer = conf.parkedMaxPerPlayer,
        plateFrontUsage = conf.plateFrontUsage,
        plateShape = conf.plateShape,
        plateDesign = conf.plateDesign,
    }
    caches.pursuitFugitives = M.pursuitFugitives
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.playerBalancer[playerID] = nil
    M.parkedBalancer[playerID] = nil
    updateBalancer()
    -- the chases a leaving police player started end, their fugitives get away
    local ended = {}
    for key, policeID in pairs(M.pursuitPolice) do
        if policeID == playerID then ended[#ended + 1] = key end
    end
    for _, key in ipairs(ended) do M.stopPursuit({}, key, 0) end
end

--- a fugitive car that's gone (its owner left, or removed it) leaves the list : its owner's game
--- can't say so once the player has left
---@param playerID integer
---@param vehID integer
local function onVehicleDeleted(playerID, vehID)
    local key = string.format("%d-%d", playerID, vehID)
    if table.includes(M.pursuitFugitives, key) then M.stopPursuit({}, key, 2) end
end

--- Sends traffic rubberband to a player (avoid multiple players teleporting vehicles to a same spot)
local function onSlowUpdate()
    local conf = getConf()
    if conf.enabled and services_players.players:length() > 0 then
        local playersIDs = services_players.players:reduce(function(acc, pData)
            if M.playerBalancer[pData.playerID] and M.playerBalancer[pData.playerID] > 0 then
                acc:insert(pData.playerID)
            end
            return acc
        end, Table()):sort()
        if playersIDs:length() > 0 then
            if playersIDs:length() == 1 then
                communications_tx.sendToPlayer(playersIDs[1], "trafficRubberbandTick")
            else
                local playerID = playersIDs[GetCurrentTime() % playersIDs:length() + 1]
                communications_tx.sendToPlayer(playerID, "trafficRubberbandTick")
            end
        end
    end
end

---@param ctxt BJSContext
---@param settings {enabled: boolean, amount: integer, maxPerPlayer: integer, models: string[], weights: table<string, number>?, smartSelection: boolean?, parkedAmount: integer?, parkedMaxPerPlayer: integer?, plateFrontUsage: string?, plateShape: string?, plateDesign: string?}
local function rxSettings(ctxt, settings)
    if not ctxt.sender or (not services_permissions.isStaff(ctxt.sender.playerName) and
            not services_permissions.hasAnyPermission(ctxt.senderID, BJ_PERMISSIONS.SetConfig)) then
        return
    end
    local conf = getConf()
    conf.enabled = settings.enabled
    conf.amount = tonumber(settings.amount) or conf.amount
    conf.maxPerPlayer = tonumber(settings.maxPerPlayer) or conf.maxPerPlayer
    conf.models = settings.models
    conf.weights = settings.weights or conf.weights
    conf.smartSelection = settings.smartSelection and true or false
    conf.parkedAmount = tonumber(settings.parkedAmount) or conf.parkedAmount
    conf.parkedMaxPerPlayer = tonumber(settings.parkedMaxPerPlayer) or conf.parkedMaxPerPlayer
    conf.plateFrontUsage = settings.plateFrontUsage or conf.plateFrontUsage
    conf.plateShape = settings.plateShape or conf.plateShape
    conf.plateDesign = settings.plateDesign or conf.plateDesign

    if not conf.enabled then
        table.clear(M.pursuitFugitives)
    end

    services_config.save()
    services_players.players
        :forEach(function(p)
            local caches = {}
            M.onBJRequestCache(caches, p.playerID)
            communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
        end)

    updateBalancer()
end

--- at most this many traffic cars chased at once on the server
local MAX_FUGITIVES = 30

---@param key any full vehicle id "ownerID-vehicleID"
---@return BJSPlayer? owner, table? vehicle
local function vehicleByKey(key)
    local ownerID, vehID = tostring(key or ""):match("^(%d+)%-(%d+)$")
    ownerID, vehID = tonumber(ownerID), tonumber(vehID)
    if not ownerID then return nil, nil end
    local owner = services_players.players:find(function(p) return p.playerID == ownerID end)
    return owner, owner and owner.vehicles[vehID] or nil
end

--- Security fix : any player could name any car here, and the owner's game then handed that car
--- to the flee AI, a player's own car included. The fugitive must be a traffic car (or one of the
--- sender's own : traffic whose model isn't named "traffic" is only known as such by its owner's
--- game, and the owner's game never hands a car that isn't traffic to the AI), and the police car
--- the sender's own
---@param ctxt BJSContext
---@param fugitiveVID string full vehicle id
---@param policeVID string full vehicle id
local function startPursuit(ctxt, fugitiveVID, policeVID)
    local conf = getConf()
    if not conf.enabled or not ctxt.sender then return end
    if type(fugitiveVID) ~= "string" or type(policeVID) ~= "string" then return end
    -- a refusal is answered (the police player's game forgets that start at once, instead of
    -- waiting for it) and logged with its reason
    local function refuse(reason)
        LogWarn(string.format("traffic chase on %s by %s refused : %s", fugitiveVID, ctxt.sender.playerName, reason))
        communications_tx.sendToPlayer(ctxt.senderID, "pursuitRefused", fugitiveVID)
    end
    local fugitiveOwner, fugitive = vehicleByKey(fugitiveVID)
    local policeOwner, police = vehicleByKey(policeVID)
    if not fugitive or not (fugitive.isAi or fugitiveOwner.playerID == ctxt.senderID) then
        return refuse("not a traffic car")
    end
    if not police or police.isAi or not policeOwner or policeOwner.playerID ~= ctxt.senderID then
        return refuse("the police car isn't the sender's own")
    end
    if #M.pursuitFugitives >= MAX_FUGITIVES then return refuse("too many chases running") end
    -- a player who turned "Police chases" off (or is in an activity) chases nothing
    if services_playerPursuit and not services_playerPursuit.isAvailable(ctxt.senderID) then
        return refuse("Police chases off, or in an activity")
    end
    -- Real bug (direct report: the fugitive tag landed on two cars at once) : one chase per police
    -- player at a time, whatever their game sends (a second tick loop, an older client)
    for key, policeID in pairs(M.pursuitPolice) do
        if policeID == ctxt.senderID and key ~= fugitiveVID then return refuse("already chasing " .. key) end
    end

    if not table.includes(M.pursuitFugitives, fugitiveVID) then
        table.insert(M.pursuitFugitives, fugitiveVID)
        M.pursuitPolice[fugitiveVID] = ctxt.senderID
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "pursuitStart", fugitiveVID, policeVID)
        services_players.players
            :forEach(function(p)
                local caches = {}
                M.onBJRequestCache(caches, p.playerID)
                communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
            end)
    end
end

---@param ctxt BJSContext
---@param vid string full vehicle id
---@param state 0|1|2 0: escaped, 1: caught, 2: removed
local function stopPursuit(ctxt, vid, state)
    local conf = getConf()
    if not conf.enabled then return end
    if type(vid) ~= "string" or (state ~= 0 and state ~= 1 and state ~= 2) then return end
    if not table.includes(M.pursuitFugitives, vid) then
        -- already over (a repeated arrest, or the other side ended it first) : nothing to do
        return LogInfo(string.format("traffic chase stop for %s ignored : not running", vid))
    end

    if table.includes(M.pursuitFugitives, vid) then
        M.pursuitPolice[vid] = nil
        M.pursuitFugitives = table.filter(M.pursuitFugitives, function(v)
            return v ~= vid
        end)
        if state < 2 then
            communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "pursuitStop", vid, state == 1)
        end
        services_players.players
            :forEach(function(p)
                local caches = {}
                M.onBJRequestCache(caches, p.playerID)
                communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
            end)
    end
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onPlayerDisconnect = onPlayerDisconnect
M.onVehicleDeleted = onVehicleDeleted
M.onSlowUpdate = onSlowUpdate

M.rxSettings = rxSettings
M.startPursuit = startPursuit
M.stopPursuit = stopPursuit

return M
