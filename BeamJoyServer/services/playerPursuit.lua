--- Freeroam police chases between players.
---
--- The police player's own game runs the game's police logic (gameplay_police) against the other
--- players' cars around it : it notices the offenses, starts the chase, and decides the arrest or
--- the escape. Their client relays each of those here (playerPursuitEvent), keyed by the fugitive
--- car's serverVID ("ownerID-vid"). This module keeps who chases whom, tells the fugitive's own
--- game (the freeze on arrest, the messages, no resets while chased), counts the stats, and ends a
--- chase when one side leaves.
---
--- Who takes part : each player's own game reports it (playerPursuitAvailable), since only it
--- knows whether its player is in an activity, and it holds the player's "Police chases" setting.
--- It covers both sides : a player who's out is neither chased nor chasing (traffic chases
--- included, see services/traffic.lua). The fugitive's game also withdraws from a chase that
--- slipped through anyway.
---
--- Several police players can chase the same car : it escapes once every one of them lost it.
---
--- Stats (arrests made as police, escapes as a fugitive) are kept in the player's saved data,
--- player.data.pursuit.
---
--- Security fix : the police side was trusted outright, so anyone could start a chase on any player
--- and arrest them at once (a 5 s freeze, and an arrest counted). Each start and arrest now names
--- the sender's police car, which must be theirs and a police car, and the server checks what it
--- can see itself : the distance between the cars (BeamMP's positions), the fugitive's speed at the
--- arrest, and how long that police player has been in the chase.

local M = {
    --- seconds a car can't be chased again after a chase on it ended (an arrest, an escape, a
    --- refusal), so the game's offense check doesn't restart one the moment a fugitive drives off
    COOLDOWN = 30,
    MAX_OFFENSES = 12,
    --- metres between the police car and the fugitive for a chase to start (the game's police only
    --- notice offenses well inside this)
    START_RANGE = 300,
    --- the game arrests within 20 m, both cars under 2.5 m/s, after 5 s : these leave room for the
    --- position lag
    ARREST_RANGE = 35,
    ARREST_SPEED = 5,
    ARREST_MIN_SECONDS = 4,

    ---@type table<string, {fugitiveID: integer, police: table<integer, {car: integer, since: integer}>, startedAt: integer, offenses: string[]}> index fugitive serverVID
    chases = {},
    ---@type table<integer, true> players whose own game says they can't be chased right now
    unavailable = {},
    ---@type table<string, integer> index serverVID, value GetCurrentTime() until which it can't be chased
    cooldowns = {},
}

---@param serverVID any
---@return integer? ownerID
local function parseOwner(serverVID)
    local ownerID = tostring(serverVID or ""):match("^(%d+)%-%d+$")
    return tonumber(ownerID)
end

---@param playerID integer
---@return BJSPlayer?
local function playerByID(playerID)
    return services_players.players:find(function(p) return p.playerID == playerID end)
end

---@param serverVID any
---@return integer? ownerID, integer? vehicleID
local function parseKey(serverVID)
    local ownerID, vehID = tostring(serverVID or ""):match("^(%d+)%-(%d+)$")
    return tonumber(ownerID), tonumber(vehID)
end

local POLICE_MARKERS = { "police", "polizei", "polizia", "gendarmerie" }

---@param s any
---@return boolean
local function hasPoliceMarker(s)
    if type(s) ~= "string" then return false end
    s = s:lower()
    for _, marker in ipairs(POLICE_MARKERS) do
        if s:find(marker, 1, true) then return true end
    end
    return false
end

--- the same test as the client's beamjoy_vehicles.isPolice (its model, or a part slot or part
--- named after the police), on the config the server was sent
---@param parts any
---@param depth integer
---@return boolean
local function partsArePolice(parts, depth)
    if type(parts) ~= "table" or depth > 6 then return false end
    for slot, part in pairs(parts) do
        if hasPoliceMarker(part) then return true end
        if hasPoliceMarker(slot) and ((type(part) == "string" and #part > 0) or type(part) == "table") then
            return true
        end
        if type(part) == "table" and partsArePolice(part, depth + 1) then return true end
    end
    return false
end

---@param v table? a server vehicle record (services_players.players[...].vehicles[...])
---@return boolean
local function isPoliceVehicle(v)
    return v ~= nil and (hasPoliceMarker(v.jbeam) or partsArePolice(v.parts, 0))
end

--- the sender's police car, from the key their game sent : theirs, a police car, not traffic
---@param ctxt BJSContext
---@param key any
---@return integer? vehicleID
local function senderPoliceCar(ctxt, key)
    local ownerID, vehID = parseKey(key)
    if ownerID ~= ctxt.senderID or not vehID then return nil end
    local v = ctxt.sender.vehicles[vehID]
    if not v or v.isAi or not isPoliceVehicle(v) then return nil end
    return vehID
end

--- MP.GetPositionRaw's second value is its error : an empty string when there's none (real bug :
--- reading any value there as an error threw every position away)
---@param err any
---@return boolean
local function positionError(err)
    return err ~= nil and err ~= ""
end

--- BeamMP's own position and velocity for a vehicle, or nil when it can't tell
---@param ownerID integer
---@param vehID integer
---@return {pos: number[], vel: number[]?}?
local function rawPosition(ownerID, vehID)
    if not MP.GetPositionRaw then return nil end
    local ok, raw, err = pcall(MP.GetPositionRaw, ownerID, vehID)
    if not ok or positionError(err) or type(raw) ~= "table" or type(raw.pos) ~= "table" then return nil end
    return raw
end

---@param a {pos: number[]}
---@param b {pos: number[]}
---@return number
local function distance(a, b)
    local dx = (tonumber(a.pos[1]) or 0) - (tonumber(b.pos[1]) or 0)
    local dy = (tonumber(a.pos[2]) or 0) - (tonumber(b.pos[2]) or 0)
    local dz = (tonumber(a.pos[3]) or 0) - (tonumber(b.pos[3]) or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

---@param raw {vel: number[]?}
---@return number
local function speed(raw)
    local v = type(raw.vel) == "table" and raw.vel or {}
    local x, y, z = tonumber(v[1]) or 0, tonumber(v[2]) or 0, tonumber(v[3]) or 0
    return math.sqrt(x * x + y * y + z * z)
end

---@return boolean
local function enabled()
    local fr = services_config.data.Freeroam
    return not fr or fr.PlayerPursuits ~= false
end

---@param offenses any
---@return string[]
local function cleanOffenses(offenses)
    local res = {}
    if type(offenses) ~= "table" then return res end
    for _, o in ipairs(offenses) do
        if type(o) == "string" and #o <= 40 and o:match("^[%w_]+$") then
            res[#res + 1] = o
            if #res >= M.MAX_OFFENSES then break end
        end
    end
    return res
end

---@return table
local function cachePayload()
    local chases = {}
    for serverVID, c in pairs(M.chases) do
        local police = {}
        for id in pairs(c.police) do police[#police + 1] = id end
        chases[#chases + 1] = { vid = serverVID, fugitiveID = c.fugitiveID, police = police }
    end
    local unavailable = {}
    for id in pairs(M.unavailable) do unavailable[#unavailable + 1] = id end
    return { chases = chases, unavailable = unavailable }
end

local function push()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache",
        { playerPursuit = cachePayload() })
end

---@param playerID integer
---@param kind string
---@param serverVID string
---@param data table?
local function notify(playerID, kind, serverVID, data)
    communications_tx.sendToPlayer(playerID, "playerPursuitNotice", kind, serverVID, data or {})
end

---@param playerID integer
---@param field "arrests"|"escapes"
local function addStat(playerID, field)
    local p = playerByID(playerID)
    if not p then return end
    p.data = type(p.data) == "table" and p.data or {}
    local stats = type(p.data.pursuit) == "table" and p.data.pursuit or {}
    stats[field] = (tonumber(stats[field]) or 0) + 1
    p.data.pursuit = stats
    services_players.savePlayer(p)
    communications_tx.sendToPlayer(playerID, "sendCache", { playerPursuitStats = stats })
end

--- ends a chase : every police player in it and the fugitive are told how it ended
---@param serverVID string
---@param kind "arrest"|"escape"|"over"
---@param data table?
local function endChase(serverVID, kind, data)
    local c = M.chases[serverVID]
    if not c then return end
    M.chases[serverVID] = nil
    M.cooldowns[serverVID] = GetCurrentTime() + M.COOLDOWN
    notify(c.fugitiveID, kind, serverVID, data)
    for id in pairs(c.police) do notify(id, kind, serverVID, data) end
    push()
end

--- a police player stops chasing this car (lost it, or called it off) : the chase ends when no
--- police is left on it, as an escape when the last one lost it
---@param serverVID string
---@param policeID integer
---@param escaped boolean
local function removePolice(serverVID, policeID, escaped)
    local c = M.chases[serverVID]
    if not c or not c.police[policeID] then return end
    c.police[policeID] = nil
    if next(c.police) then
        notify(policeID, escaped and "lost" or "over", serverVID)
        return push()
    end
    if escaped then
        addStat(c.fugitiveID, "escapes")
        endChase(serverVID, "escape")
    else
        endChase(serverVID, "over")
    end
end

---@param ctxt BJSContext
---@param event "start"|"arrest"|"evade"|"evading"|"reset"
---@param serverVID string
---@param data table?
local function playerPursuitEvent(ctxt, event, serverVID, data)
    if not ctxt.sender then return end
    serverVID = tostring(serverVID or "")
    local ownerID = parseOwner(serverVID)
    if not ownerID or ownerID == ctxt.senderID then return end
    data = type(data) == "table" and data or {}

    if event == "start" then
        local now = GetCurrentTime()
        local owner = playerByID(ownerID)
        local _, fugitiveVehID = parseKey(serverVID)
        local policeCar = senderPoliceCar(ctxt, data.police)
        local refused = not enabled() or not owner or M.unavailable[ownerID] or M.unavailable[ctxt.senderID] or
            (M.cooldowns[serverVID] and M.cooldowns[serverVID] > now) or
            not policeCar or not owner.vehicles[fugitiveVehID] or owner.vehicles[fugitiveVehID].isAi
        if not refused then
            local fugitivePos = rawPosition(ownerID, fugitiveVehID)
            local policePos = rawPosition(ctxt.senderID, policeCar)
            if fugitivePos and policePos and distance(fugitivePos, policePos) > M.START_RANGE then
                refused = true
            end
        end
        -- a fugitive can't be police in someone else's chase at the same time
        if not refused then
            for _, c in pairs(M.chases) do
                if c.fugitiveID == ctxt.senderID then
                    refused = true
                    break
                end
            end
        end
        if refused then
            return notify(ctxt.senderID, "refused", serverVID)
        end
        local c = M.chases[serverVID]
        if c then
            local joined = c.police[ctxt.senderID]
            c.police[ctxt.senderID] = { car = policeCar, since = joined and joined.since or now }
            notify(ctxt.senderID, "joined", serverVID, { fugitiveID = ownerID })
        else
            c = {
                fugitiveID = ownerID,
                police = { [ctxt.senderID] = { car = policeCar, since = now } },
                startedAt = now,
                offenses = cleanOffenses(data.offenses),
            }
            M.chases[serverVID] = c
            notify(ownerID, "start", serverVID, {
                policeID = ctxt.senderID,
                policeName = ctxt.sender.playerName,
                offenses = c.offenses,
            })
            notify(ctxt.senderID, "joined", serverVID, { fugitiveID = ownerID })
        end
        push()
    elseif event == "arrest" then
        local c = M.chases[serverVID]
        local entry = c and c.police[ctxt.senderID]
        if not entry then return end
        local policeCar = senderPoliceCar(ctxt, data.police)
        local _, fugitiveVehID = parseKey(serverVID)
        local refused = policeCar ~= entry.car or GetCurrentTime() - entry.since < M.ARREST_MIN_SECONDS
        if not refused then
            local fugitivePos = rawPosition(ownerID, fugitiveVehID)
            local policePos = rawPosition(ctxt.senderID, policeCar)
            if fugitivePos and policePos and (distance(fugitivePos, policePos) > M.ARREST_RANGE or
                    speed(fugitivePos) > M.ARREST_SPEED) then
                refused = true
            end
        end
        if refused then
            LogWarn(string.format("playerPursuit : arrest of %s by %s refused", serverVID,
                ctxt.sender.playerName))
            -- removePolice only tells this police player when others stay on the chase
            local others = false
            for id in pairs(c.police) do
                if id ~= ctxt.senderID then others = true end
            end
            if not others then notify(ctxt.senderID, "over", serverVID) end
            return removePolice(serverVID, ctxt.senderID, false)
        end
        addStat(ctxt.senderID, "arrests")
        endChase(serverVID, "arrest", {
            policeID = ctxt.senderID,
            policeName = ctxt.sender.playerName,
            ticket = data.ticket == true,
            offenses = #cleanOffenses(data.offenses) > 0 and cleanOffenses(data.offenses) or c.offenses,
        })
    elseif event == "evade" then
        removePolice(serverVID, ctxt.senderID, true)
    elseif event == "evading" then
        -- a police player's escape countdown on this car (seconds left, none when it sees it) : the
        -- fugitive is told the longest one while every police car in the chase is losing it, and
        -- nothing (back in sight) otherwise
        local c = M.chases[serverVID]
        local entry = c and c.police[ctxt.senderID]
        if not entry then return end
        local left = tonumber(data.left)
        entry.evadeLeft = left and math.max(1, math.min(300, math.floor(left))) or nil
        local time
        for _, p in pairs(c.police) do
            if not p.evadeLeft then
                time = nil
                break
            end
            time = math.max(time or 0, p.evadeLeft)
        end
        notify(c.fugitiveID, "escaping", serverVID, { time = time })
    elseif event == "reset" then
        removePolice(serverVID, ctxt.senderID, false)
    end
end

--- the fugitive's own game refuses or leaves a chase (in an activity, opted out, out of that car,
--- the car deleted) : called off, no stats
---@param ctxt BJSContext
---@param serverVID string
local function playerPursuitWithdraw(ctxt, serverVID)
    if not ctxt.sender then return end
    serverVID = tostring(serverVID or "")
    local c = M.chases[serverVID]
    if not c or c.fugitiveID ~= ctxt.senderID then return end
    endChase(serverVID, "over")
end

---@param ctxt BJSContext
---@param available boolean
local function playerPursuitAvailable(ctxt, available)
    if not ctxt.sender then return end
    local unavailable = available == false or nil
    if M.unavailable[ctxt.senderID] == unavailable then return end
    M.unavailable[ctxt.senderID] = unavailable
    if unavailable then
        for serverVID, c in pairs(M.chases) do
            if c.fugitiveID == ctxt.senderID then
                endChase(serverVID, "over")
            elseif c.police[ctxt.senderID] then
                -- out as police too
                removePolice(serverVID, ctxt.senderID, false)
            end
        end
    end
    push()
end

local function endAll()
    for serverVID in pairs(M.chases) do endChase(serverVID, "over") end
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.unavailable[playerID] = nil
    for serverVID, c in pairs(M.chases) do
        if c.fugitiveID == playerID then
            endChase(serverVID, "over")
        elseif c.police[playerID] then
            removePolice(serverVID, playerID, false)
        end
    end
    push()
end

---@param playerID integer
---@param vehID integer
local function onVehicleDeleted(playerID, vehID)
    local serverVID = string.format("%d-%d", playerID, vehID)
    if M.chases[serverVID] then endChase(serverVID, "over") end
    -- the owner's next car can get the same ID : it starts with a clean slate
    M.cooldowns[serverVID] = nil
end

local function onSlowUpdate()
    if next(M.chases) and not enabled() then endAll() end
    local now = GetCurrentTime()
    for serverVID, untilTime in pairs(M.cooldowns) do
        if untilTime <= now then M.cooldowns[serverVID] = nil end
    end
end

---@param caches table
---@param targetID integer?
local function onBJRequestCache(caches, targetID)
    caches.playerPursuit = cachePayload()
    local p = targetID and playerByID(targetID)
    caches.playerPursuitStats = p and type(p.data) == "table" and type(p.data.pursuit) == "table" and
        p.data.pursuit or {}
end

local function onInit()
    communications_rx.addHandler("playerPursuitEvent", M.playerPursuitEvent)
    communications_rx.addHandler("playerPursuitWithdraw", M.playerPursuitWithdraw)
    communications_rx.addHandler("playerPursuitAvailable", M.playerPursuitAvailable)
end

M.onInit = onInit
M.onPlayerDisconnect = onPlayerDisconnect
M.onVehicleDeleted = onVehicleDeleted
M.onSlowUpdate = onSlowUpdate
M.onBJRequestCache = onBJRequestCache

M.playerPursuitEvent = playerPursuitEvent
M.playerPursuitWithdraw = playerPursuitWithdraw
M.playerPursuitAvailable = playerPursuitAvailable
--- the player takes part in police chases right now (services/traffic.lua checks it too)
---@param playerID integer
---@return boolean
M.isAvailable = function(playerID) return not M.unavailable[playerID] end

return M
