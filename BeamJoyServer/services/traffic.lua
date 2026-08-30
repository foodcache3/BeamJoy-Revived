local M = {
    ---@type tablelib<integer, integer> index playerID, value amount of traffic handled
    playerBalancer = Table(),
    ---@type tablelib<integer, integer> index playerID, value amount of parked vehicles handled
    parkedBalancer = Table(),

    ---@type integer[] vids
    pursuitFugitives = {},
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
    }
    caches.pursuitFugitives = M.pursuitFugitives
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.playerBalancer[playerID] = nil
    M.parkedBalancer[playerID] = nil
    updateBalancer()
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
---@param settings {enabled: boolean, amount: integer, maxPerPlayer: integer, models: string[], weights: table<string, number>?, smartSelection: boolean?, parkedAmount: integer?, parkedMaxPerPlayer: integer?}
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

---@param ctxt BJSContext
---@param fugitiveVID integer
---@param policeVID integer
local function startPursuit(ctxt, fugitiveVID, policeVID)
    local conf = getConf()
    if not conf.enabled then return end

    if not table.includes(M.pursuitFugitives, fugitiveVID) then
        table.insert(M.pursuitFugitives, fugitiveVID)
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
---@param vid integer
---@param state 0|1|2 0: escaped, 1: caught, 2: removed
local function stopPursuit(ctxt, vid, state)
    local conf = getConf()
    if not conf.enabled then return end

    if table.includes(M.pursuitFugitives, vid) then
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
M.onSlowUpdate = onSlowUpdate

M.rxSettings = rxSettings
M.startPursuit = startPursuit
M.stopPursuit = stopPursuit

return M
