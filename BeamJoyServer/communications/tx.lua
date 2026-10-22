local M = {
    ALL_PLAYERS = -1,

    LOG_EVENTS_BLACKLIST = { "tick", "trafficRubberbandTick", "clockSync" },

    --- small, time-critical replies that must not wait behind a backlog in the pacing queue
    --- below. clockSync : the client times the round trip, and a reply held up behind queued race
    --- updates looks like a slow return leg, skewing its estimate of the server clock (see
    --- services/clockSync.lua). Skipping ahead only reorders it against other messages, which
    --- doesn't matter for a standalone reply like this one
    IMMEDIATE_KEYS = { clockSync = true },

    -- PACING : a message's parts used to go out all at once, and a join's cache burst (well over
    -- half a megabyte, ~27 compressed packets in the same instant) broke the BeamMP launcher
    -- (2.8.1 : "zlib uncompress() failed (code: -3, message: data error)", then "Decompression
    -- failed" and the launcher quits, dropping the player). Packets now queue per target and
    -- drain at SEND_BUDGET bytes per onUpdate (100 ms, so ~400 KB/s) ; a small message still goes
    -- straight out when nothing is queued ahead of it, and one target's messages keep their order
    SEND_BUDGET = 40000,
    SMALL_MESSAGE = 4000,

    -- FLOW CONTROL. Real bug (direct report : one player saving a vehicle preset crashed ANOTHER
    -- player's launcher). Every game then asked for the new builds' photos (up to 200 KB each),
    -- more than that player's connection took at the pace above. BeamMP's server writes to a
    -- player's connection from more than one thread with no lock (BeamMP-Server src/TNetwork.cpp
    -- TCPSend : a single player's messages from this Lua, messages to everyone and other players'
    -- vehicle changes from that player's own sending thread) ; once the connection is full a write
    -- goes out in pieces, another slips in between, and the launcher reads a broken packet
    -- ("Decompression failed", then a garbage length, and it quits). Paced packets now go on their
    -- own events (constants.lua's PACED_*), the game acknowledges what it got (ACK_EVENT), and no
    -- more than WINDOW bytes are ever on their way to one player : the connection never fills up
    -- with ours, whatever its speed
    WINDOW = 64000,
    --- onUpdates (100 ms) without an acknowledgement before what's on its way counts as arrived
    --- anyway (acknowledgements lost, a game busy loading) : slower, never stuck
    ACK_TIMEOUT_TICKS = 30,
    --- target playerID -> packets waiting, oldest first
    ---@type table<integer, {event: string, data: string}[]>
    queues = {},
    --- playerID -> bytes sent paced and not acknowledged yet, onUpdates since the last acknowledgement
    ---@type table<integer, {inFlight: integer, idleTicks: integer}>
    flow = {},
    --- players whose game's BeamJoy is up (it sent us something) : who a paced message to
    --- everyone goes to
    ---@type table<integer, true>
    clients = {},
}

---@param playerID integer
---@param event string
---@param data string
local function rawSend(playerID, event, data)
    MP.TriggerClientEvent(playerID, event, data)
end

---@param playerID integer
---@param packets {event: string, data: string}[]
local function enqueue(playerID, packets)
    local q = M.queues[playerID]
    local size = 0
    for _, pk in ipairs(packets) do size = size + #pk.data end
    -- nothing waiting ahead of it and small : right away (the tick, live updates)
    if (not q or #q == 0) and size <= M.SMALL_MESSAGE then
        for _, pk in ipairs(packets) do rawSend(playerID, pk.event, pk.data) end
        return
    end
    q = q or {}
    for _, pk in ipairs(packets) do q[#q + 1] = pk end
    M.queues[playerID] = q
end

---@param playerID integer
---@return {inFlight: integer, idleTicks: integer}
local function flowOf(playerID)
    local flow = M.flow[playerID]
    if not flow then
        flow = { inFlight = 0, idleTicks = 0 }
        M.flow[playerID] = flow
    end
    return flow
end

--- sends up to SEND_BUDGET bytes per player, never more than WINDOW of them unacknowledged
--- (always at least one packet when nothing is)
local function onUpdate()
    local constants = require("communications/constants")
    for _, flow in pairs(M.flow) do
        if flow.inFlight > 0 then
            flow.idleTicks = flow.idleTicks + 1
            if flow.idleTicks >= M.ACK_TIMEOUT_TICKS then flow.inFlight, flow.idleTicks = 0, 0 end
        end
    end
    for playerID, q in pairs(M.queues) do
        -- a player who left : nothing to deliver
        if #(MP.GetPlayerName(playerID) or "") == 0 then
            M.queues[playerID] = nil
        else
            local flow = flowOf(playerID)
            local sent = 0
            while #q > 0 and (sent == 0 or sent + #q[1].data <= M.SEND_BUDGET) and
                (flow.inFlight == 0 or flow.inFlight + #q[1].data <= M.WINDOW) do
                local pk = table.remove(q, 1)
                rawSend(playerID, pk.event == constants.BASE_EVENT and constants.PACED_BASE_EVENT or
                    constants.PACED_DATA_EVENT, pk.data)
                sent = sent + #pk.data
                if flow.inFlight == 0 then flow.idleTicks = 0 end
                flow.inFlight = flow.inFlight + #pk.data
            end
            if #q == 0 then M.queues[playerID] = nil end
        end
    end
end

--- the player's game got this many bytes of what was sent paced (communications/rx.lua)
---@param playerID integer
---@param bytes integer?
local function acknowledge(playerID, bytes)
    local flow = M.flow[playerID]
    if not flow or not bytes or bytes ~= bytes or bytes <= 0 then return end
    flow.inFlight = math.max(0, flow.inFlight - math.floor(bytes))
    flow.idleTicks = 0
end

--- the player's game sent us something : its BeamJoy is up (communications/rx.lua)
---@param playerID integer
local function markClient(playerID)
    M.clients[playerID] = true
end

local function onInit()
    -- a reload with players on : their games are up
    for playerID in pairs(MP.GetPlayers() or {}) do M.clients[playerID] = true end
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.queues[playerID] = nil
    M.flow[playerID] = nil
    M.clients[playerID] = nil
end

local function onSlowUpdate()
    ---@type BJServerTick
    local payload = { time = GetCurrentTime() }
    extensions.hook("onBJRequestServerTickPayload", payload)
    M.sendToPlayer(M.ALL_PLAYERS, "tick", payload)
end

---@param playerID integer
---@param playerID integer
---@return boolean
local function isReachable(playerID)
    return playerID == M.ALL_PLAYERS or #MP.GetPlayerName(playerID) > 0
end

--- encodes one message into its wire packets (a header, then the payload in parts). The packets
--- don't depend on who receives them, so one encoding can go to any number of players
---@param key string
---@return {event: string, data: string}[] packets, integer partCount
local function buildPackets(key, ...)
    local constants = require("communications/constants")
    local id = UUID()
    local payload = #{ ... } > 0 and utils_json.stringifyRaw({ ... }) or ""
    -- sliced by index : cutting the front off the remainder each time copied the whole rest of a
    -- big payload once per part
    local parts = {}
    local size = constants.PAYLOAD_SIZE_THRESHOLD
    for i = 1, #payload, size do
        parts[#parts + 1] = payload:sub(i, i + size - 1)
    end

    local packets = { {
        event = constants.BASE_EVENT,
        data = utils_json.stringifyRaw({ id = id, key = key, parts = #parts }),
    } }
    for i, p in ipairs(parts) do
        packets[#packets + 1] = {
            event = constants.DATA_EVENT,
            data = utils_json.stringifyRaw({ id = id, part = i, data = p }),
        }
    end
    return packets, #parts
end

--- a message to everyone : straight out in one go when it's small and nobody has anything
--- waiting (BeamMP passes it on to each player), else into each player's own queue. Not a queue of
--- its own : what BeamMP passes on goes out from each player's sending thread, outside the flow
--- control above
---@param packets {event: string, data: string}[]
local function broadcast(packets)
    local size = 0
    for _, pk in ipairs(packets) do size = size + #pk.data end
    if size <= M.SMALL_MESSAGE and next(M.queues) == nil then
        for _, pk in ipairs(packets) do rawSend(M.ALL_PLAYERS, pk.event, pk.data) end
        return
    end
    for playerID in pairs(M.clients) do enqueue(playerID, packets) end
end

---@param playerID integer
---@param key string
---@param packets {event: string, data: string}[]
---@param partCount integer
local function deliver(playerID, key, packets, partCount)
    if M.IMMEDIATE_KEYS[key] then
        for _, pk in ipairs(packets) do rawSend(playerID, pk.event, pk.data) end
    elseif playerID == M.ALL_PLAYERS then
        broadcast(packets)
    else
        enqueue(playerID, packets)
    end
    if not table.includes(M.LOG_EVENTS_BLACKLIST, key) then
        LogDebug(string.format("Event %s sent to %s (ID %d, %d parts data)",
            key, playerID == -1 and services_lang.get("common.all") or
            MP.GetPlayerName(playerID), playerID, partCount))
    end
end

---@param playerID integer
---@param key string
local function sendToPlayer(playerID, key, ...)
    if isReachable(playerID) then
        deliver(playerID, key, buildPackets(key, ...))
    end
end

--- the same message to several players, encoded once. Sending the identical payload with
--- sendToPlayer in a loop re-encoded it for every recipient : for a busy race's session updates
--- that was most of the server's time (see raceGrid.lua's pushSessionUpdate)
---@param playerIDs integer[]
---@param key string
local function sendToPlayers(playerIDs, key, ...)
    local packets, partCount
    for _, playerID in ipairs(playerIDs) do
        if isReachable(playerID) then
            if not packets then packets, partCount = buildPackets(key, ...) end
            deliver(playerID, key, packets, partCount)
        end
    end
end

---@param permissions string[]
---@param key string
local function sendByPermissions(permissions, key, ...)
    local data = { ... }
    services_players.players:filter(function(p)
        return services_permissions.hasAllPermissions(p.playerID, table.unpack(permissions, 1, 20))
    end):forEach(function(p)
        M.sendToPlayer(p.playerID, key, table.unpack(data, 1, 20))
    end)
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate
M.onUpdate = onUpdate
M.onPlayerDisconnect = onPlayerDisconnect

M.acknowledge = acknowledge
M.markClient = markClient

M.sendToPlayer = sendToPlayer
M.sendToPlayers = sendToPlayers
M.sendByPermissions = sendByPermissions

return M
