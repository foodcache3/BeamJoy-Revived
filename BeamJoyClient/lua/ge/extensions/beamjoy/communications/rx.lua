local function getTimeoutKey(id)
    return string.format("BJRxEventTimeout-%s", tostring(id))
end

-- the JSON parser change number keys to strings, so update recursively
local function parsePayload(obj)
    if type(obj) == "table" then
        local cpy = {}
        for k, v in pairs(obj) do
            local finalKey = tonumber(k) or k
            cpy[finalKey] = parsePayload(v)
        end
        return cpy
    end
    return obj
end

local pending = {}
local function tryFinalizingEvent(id)
    local event = pending[id]
    if event then
        if not event.key or event.parts > #event.data then
            -- not ready yet
            return
        end

        local dataStr = table.join(event.data)
        local data = #dataStr > 0 and jsonDecode(dataStr) or {}
        data = parsePayload(data)
        beamjoy_communications.dispatch(event.key, table.unpack(data, 1, 20))
    end

    pending[id] = nil
    async.removeTask(getTimeoutKey(id))
end

local function retrieveEvent(strData)
    local data = jsonDecode(strData)
    if not data or type(data) ~= "table" or
        not data.id or not data.parts or not data.key then
        LogError("Invalid event")
        dump(data)
        return
    end

    local event = pending[data.id]
    if event then
        event.parts = data.parts
        event.key = data.key
        if not event.data then
            event.data = {}
        end
    else
        pending[data.id] = {
            parts = data.parts,
            key = data.key,
            data = {},
        }
    end
    if data.parts == 0 or
        pending[data.id].parts == table.length(pending[data.id].data) then
        tryFinalizingEvent(data.id)
    else
        async.delayTask(function()
            pending[data.id] = nil
        end, 30000, getTimeoutKey(data.id))
    end
end

local function retrieveEventPart(strData)
    local data = jsonDecode(strData)
    if not data or type(data) ~= "table" or
        not data.id or not data.part or
        not data.data then
        LogError("Invalid event part")
        dump(data)
        return
    end

    local event = pending[data.id]
    if event then
        if event.data then
            event.data[data.part] = data.data
        else
            event.data = { [data.part] = data.data }
        end
    else
        pending[data.id] = {
            data = { [data.part] = data.data }
        }
    end
    if pending[data.id].key and
        pending[data.id].parts == table.length(pending[data.id].data) then
        tryFinalizingEvent(data.id)
    else
        async.delayTask(function()
            pending[data.id] = nil
        end, 30000, getTimeoutKey(data.id))
    end
end

--- bytes received on the paced events since communications.lua last acknowledged them (the
--- server's communications/tx.lua sends no more until enough of it is acknowledged)
local received = 0

local constants = require("ge/extensions/beamjoy/communications/constants")
AddEventHandler(constants.BASE_EVENT, retrieveEvent)
AddEventHandler(constants.DATA_EVENT, retrieveEventPart)
AddEventHandler(constants.PACED_BASE_EVENT, function(strData)
    received = received + #strData
    retrieveEvent(strData)
end)
AddEventHandler(constants.PACED_DATA_EVENT, function(strData)
    received = received + #strData
    retrieveEventPart(strData)
end)

return {
    --- what arrived paced since the last call
    ---@return integer
    takeReceived = function()
        local n = received
        received = 0
        return n
    end,
}
