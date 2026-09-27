local M = {
    ALL_PLAYERS = -1,

    LOG_EVENTS_BLACKLIST = { "tick", "trafficRubberbandTick" },

    -- PACING : a message's parts used to go out all at once, and a join's cache burst (well over
    -- half a megabyte, ~27 compressed packets in the same instant) broke the BeamMP launcher
    -- (2.8.1 : "zlib uncompress() failed (code: -3, message: data error)", then "Decompression
    -- failed" and the launcher quits, dropping the player). Packets now queue per target and
    -- drain at SEND_BUDGET bytes per onUpdate (100 ms, so ~400 KB/s) ; a small message still goes
    -- straight out when nothing is queued ahead of it, and one target's messages keep their order
    SEND_BUDGET = 40000,
    SMALL_MESSAGE = 4000,
    --- target playerID (or ALL_PLAYERS) -> packets waiting, oldest first
    ---@type table<integer, {event: string, data: string}[]>
    queues = {},
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

--- sends up to SEND_BUDGET bytes per target (always at least one packet)
local function onUpdate()
    for playerID, q in pairs(M.queues) do
        -- a player who left : nothing to deliver
        if playerID ~= M.ALL_PLAYERS and #(MP.GetPlayerName(playerID) or "") == 0 then
            M.queues[playerID] = nil
        else
            local sent = 0
            while #q > 0 and (sent == 0 or sent + #q[1].data <= M.SEND_BUDGET) do
                local pk = table.remove(q, 1)
                rawSend(playerID, pk.event, pk.data)
                sent = sent + #pk.data
            end
            if #q == 0 then M.queues[playerID] = nil end
        end
    end
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.queues[playerID] = nil
end

local function onSlowUpdate()
    ---@type BJServerTick
    local payload = { time = GetCurrentTime() }
    extensions.hook("onBJRequestServerTickPayload", payload)
    M.sendToPlayer(M.ALL_PLAYERS, "tick", payload)
end

---@param playerID integer
---@param key string
local function sendToPlayer(playerID, key, ...)
    if playerID == M.ALL_PLAYERS or #MP.GetPlayerName(playerID) > 0 then
        local id = UUID()
        local parts = {}
        local payload = #{ ... } > 0 and utils_json.stringifyRaw({ ... }) or ""
        local constants = require("communications/constants")
        while #payload > 0 do
            table.insert(parts, payload:sub(1, constants.PAYLOAD_SIZE_THRESHOLD))
            payload = payload:sub(constants.PAYLOAD_SIZE_THRESHOLD + 1)
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
        enqueue(playerID, packets)
        if not table.includes(M.LOG_EVENTS_BLACKLIST, key) then
            LogDebug(string.format("Event %s sent to %s (ID %d, %d parts data)",
                key, playerID == -1 and services_lang.get("common.all") or
                MP.GetPlayerName(playerID), playerID, #parts))
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

M.onSlowUpdate = onSlowUpdate
M.onUpdate = onUpdate
M.onPlayerDisconnect = onPlayerDisconnect

M.sendToPlayer = sendToPlayer
M.sendByPermissions = sendByPermissions

return M
