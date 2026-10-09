local constants = require("ge/extensions/beamjoy/communications/constants")
local lzw = require("ge/extensions/beamjoy/communications/lzw")

-- bytes : a message longer than this goes packed (communications/lzw.lua : BeamMP's server warns
-- on, and over-allocates for, any packet that compresses more than 5 times, as a race's props do)
local PACK_OVER = 4096
-- the BeamMP launcher aborts (closes, the game dropped from the server) on any packet over 500 bytes
-- holding these two letters (BeamMP-Launcher src/Network/GlobalHandler.cpp ServerSend) : a message
-- holding them goes packed whatever its size, the packed text never has a capital Z
local LAUNCHER_ABORTS_ON = "Zp"

---@param key string
---@param ... any
return function(key, ...)
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

    TriggerServerEvent(constants.BASE_EVENT, jsonEncode({
        id = id,
        key = key,
        parts = #parts,
        enc = enc,
    }))
    for i, p in ipairs(parts) do
        TriggerServerEvent(constants.DATA_EVENT, jsonEncode({
            id = id,
            part = i,
            data = p,
        }))
    end

    if not (beamjoy_communications and table.includes(beamjoy_communications.TX_LOG_EVENTS_BLACKLIST or {}, key)) then
        LogDebug(string.format("Event %s sent (%d parts data)", key, #parts))
    end
    if beamjoy_main.DEBUG then
        PrintObj(data)
    end
end
