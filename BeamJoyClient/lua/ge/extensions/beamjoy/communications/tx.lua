local constants = require("ge/extensions/beamjoy/communications/constants")
local lzw = require("ge/extensions/beamjoy/communications/lzw")

-- bytes : a message longer than this goes packed (communications/lzw.lua : BeamMP's server warns
-- on, and over-allocates for, any packet that compresses more than 5 times, as a race's props do)
local PACK_OVER = 4096
-- the BeamMP launcher aborts (closes, the game dropped from the server) on any packet over 500 bytes
-- holding these two letters (BeamMP-Launcher src/Network/GlobalHandler.cpp ServerSend) : a message
-- holding them goes packed whatever its size, the packed text never has a capital Z
local LAUNCHER_ABORTS_ON = "Zp"

-- PACING, as the server's own communications/tx.lua does it. A message's parts all went out in
-- the same instant : a preset carrying its builds' photos (up to 200 KB each) is easily a megabyte
-- or more, all of it at once into the player's own connection. Packets now queue and drain at SEND_BUDGET
-- bytes per WINDOW_MS (~400 KB/s) ; a small message still goes straight out when nothing is queued
-- ahead of it, and messages keep their order. The server waits 30 s for each next part
-- (communications/rx.lua), far more than a paced part takes
local SEND_BUDGET = 40000
local WINDOW_MS = 100
local SMALL_MESSAGE = 4000
--- small, time-critical messages that must not wait behind a backlog (clockSync times its own
--- round trip, see clockSync.lua)
local IMMEDIATE_KEYS = { clockSync = true }

---@type {event: string, data: string}[] packets waiting, oldest first
local queue = {}
local windowStart, sentInWindow = 0, 0

--- sends up to SEND_BUDGET bytes per WINDOW_MS (always at least one packet a window)
local function drain()
    if #queue == 0 then return end
    local now = GetCurrentTimeMillis()
    if now - windowStart >= WINDOW_MS then windowStart, sentInWindow = now, 0 end
    while #queue > 0 and (sentInWindow == 0 or sentInWindow + #queue[1].data <= SEND_BUDGET) do
        local pk = table.remove(queue, 1)
        TriggerServerEvent(pk.event, pk.data)
        sentInWindow = sentInWindow + #pk.data
    end
end

--- the connection is gone : what was waiting goes nowhere
local function clear()
    queue = {}
end

---@param key string
---@param ... any
local function send(key, ...)
    local data = { ... }

    local id = UUID()
    local parts = {}
    local payload = table.length(data) > 0 and jsonEncode(data) or ""
    local enc
    if #payload > PACK_OVER or payload:find(LAUNCHER_ABORTS_ON, 1, true) then
        payload = lzw.encode(payload)
        enc = "lzw"
    end
    while #payload > 0 do
        table.insert(parts, payload:sub(1, constants.PAYLOAD_SIZE_THRESHOLD))
        payload = payload:sub(constants.PAYLOAD_SIZE_THRESHOLD + 1)
    end

    local packets = { { event = constants.BASE_EVENT, data = jsonEncode({
        id = id,
        key = key,
        parts = #parts,
        enc = enc,
    }) } }
    local size = #packets[1].data
    for i, p in ipairs(parts) do
        packets[#packets + 1] = { event = constants.DATA_EVENT, data = jsonEncode({
            id = id,
            part = i,
            data = p,
        }) }
        size = size + #packets[#packets].data
    end
    if IMMEDIATE_KEYS[key] or (#queue == 0 and size <= SMALL_MESSAGE) then
        for _, pk in ipairs(packets) do TriggerServerEvent(pk.event, pk.data) end
    else
        for _, pk in ipairs(packets) do queue[#queue + 1] = pk end
        drain()
    end

    if not (beamjoy_communications and table.includes(beamjoy_communications.TX_LOG_EVENTS_BLACKLIST or {}, key)) then
        LogDebug(string.format("Event %s sent (%d parts data)", key, #parts))
    end
    if beamjoy_main.DEBUG then
        PrintObj(data)
    end
end

return { send = send, drain = drain, clear = clear }
