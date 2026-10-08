local constants = require("ge/extensions/beamjoy/communications/constants")

---@param key string
---@param ... any
return function(key, ...)
    local data = { ... }

    local id = UUID()
    local parts = {}
    local payload = table.length(data) > 0 and jsonEncode(data) or ""
    while #payload > 0 do
        table.insert(parts, payload:sub(1, constants.PAYLOAD_SIZE_THRESHOLD))
        payload = payload:sub(constants.PAYLOAD_SIZE_THRESHOLD + 1)
    end

    TriggerServerEvent(constants.BASE_EVENT, jsonEncode({
        id = id,
        key = key,
        parts = #parts,
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
