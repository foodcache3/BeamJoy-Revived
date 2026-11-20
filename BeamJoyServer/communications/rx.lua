local M = {
    ---@type tablelib<string, {key: string, handlerFn: fun(ctxt: BJSContext, ...: any)}>
    handlers = Table(),
    ---@type table<string, {senderID: integer, created: integer, key?: string, parts?: integer, enc?: string, data?: tablelib<integer, string>}>
    pending = Table(),
}

-- a client's packed message (communications/lzw.lua) : at most this much once unpacked
local MAX_UNPACKED_BYTES = 20 * 1024 * 1024

local function onInit()
    local constants = require("communications/constants")
    MP.RegisterEvent(constants.BASE_EVENT, "_BJSRxEvent")
    MP.RegisterEvent(constants.DATA_EVENT, "_BJSRxData")
    MP.RegisterEvent(constants.ACK_EVENT, "_BJSRxAck")
end

---@param key string
---@param handlerFn fun(ctxt: BJSContext, ...: any)
local function addHandler(key, handlerFn)
    local id = UUID()
    M.handlers[id] = { key = key, handlerFn = handlerFn }
    return id
end

local function removeHandler(id)
    M.handlers[id] = nil
end

---@param key string
---@param ctxt BJSContext
local function dispatch(key, ctxt, ...)
    local data = { ... }
    M.handlers:filter(function(h)
        return h.key == key
    end):forEach(function(h)
        h.handlerFn(ctxt, table.unpack(data, 1, 20))
    end)
end

--- xpcall's message handler for a client message's handlers (below) : runs while the failing call
--- is still on the stack, so the traceback points at the line that actually threw. A plain pcall
--- has already unwound by the time it returns, leaving only the message
---@param err any whatever was thrown
---@return any err the same thing, a string one with its stack appended
local function withTraceback(err)
    -- a table thrown on purpose (a translated error, see the TODO in finalizeCommunication) is
    -- passed through untouched : debug.traceback would hand it back unchanged anyway, and it
    -- isn't a crash to take a stack of
    if type(err) == "table" then return err end
    return debug.traceback(tostring(err), 2)
end

--- what a thrown error reads as in the log
---@param err any
---@return string
local function errorText(err)
    if type(err) ~= "table" then return tostring(err) end
    return string.format("table error (key %s)", tostring(err.key))
end

local function getTimeoutKey(id)
    return string.format("BJSRxEventTimeout-%s", id)
end

local function finalizeCommunication(id)
    local comm = M.pending[id]
    M.pending[id] = nil
    utils_async.removeTask(getTimeoutKey(id))
    local strData = table.join(comm.data)
    if comm.enc == "lzw" then
        local unpacked, unpackedData = pcall(require("communications/lzw").decode, strData, MAX_UNPACKED_BYTES)
        if not unpacked then
            return LogWarn(string.format("Event %s from player %d : invalid data (%s)", tostring(comm.key),
                comm.senderID, tostring(unpackedData)))
        end
        strData = unpackedData
    end
    local parsedOk, parsedData = true, {}
    if #strData > 0 then parsedOk, parsedData = pcall(utils_json.parse, strData) end
    if not parsedOk or type(parsedData) ~= "table" then
        return LogWarn(string.format("Event %s from player %d : invalid data", tostring(comm.key), comm.senderID))
    end
    local ctxt = InitContext(comm.senderID)
    -- Hardening : many handlers check permissions as `ctxt.sender and not hasAllPermissions(...)`,
    -- which lets everything through when the sender isn't a known player. A player's messages
    -- only ever arrive once they're registered (on connecting), so anything else is dropped here,
    -- for every handler at once
    if not ctxt.sender then
        return LogWarn(string.format("Event %s from unknown player %d dropped", tostring(comm.key), comm.senderID))
    end

    if IsDebug() then
        LogDebug(string.format("Event %s received from %s (ID %d, %d parts data)", comm.key,
            ctxt.sender.playerName, comm.senderID,
            comm.parts))
        dump(parsedData)
    end
    -- Real, confirmed blind spot (live report : a race gate that never registered, with nothing
    -- whatsoever in the server log to explain it). This was a bare pcall whose error was assigned
    -- to a local and then dropped on the floor, so a crash in ANY client message handler was
    -- indistinguishable from the message never having arrived : no line, no stack, no trace of it
    -- anywhere. Every handler error is now logged with the event, who sent it and where it threw.
    -- Sending it on to that player as a toast is still to do (type(err) == "table" : an error
    -- meant for them, anything else : error.generic)
    local ok, err = xpcall(dispatch, withTraceback, comm.key, ctxt, table.unpack(parsedData, 1, 20))
    if not ok then
        LogError(string.format("Event %s from %s (ID %d) failed : %s", tostring(comm.key),
            ctxt.sender.playerName, comm.senderID, errorText(err)))
    end
end

---@param senderID integer
---@param dataStr string
function _BJSRxEvent(senderID, dataStr)
    local data = utils_json.parse(dataStr) or {}
    if #MP.GetPlayerName(senderID) == 0 then
        LogError(string.format("Invalid senderID %d", senderID))
        return
    end
    communications_tx.markClient(senderID)
    if not data.id or not data.key or not data.parts then
        LogError("Invalid event: ")
        return dump(data)
    end

    if M.pending[data.id] then
        -- a message's parts must all come from one player : anyone else reusing its id is ignored
        if M.pending[data.id].senderID ~= senderID or M.pending[data.id].key then
            return LogWarn(string.format("Event id reused by player %d, ignored", senderID))
        end
        table.assign(M.pending[data.id], {
            key = data.key,
            parts = data.parts,
            enc = data.enc,
        })
    else
        M.pending[data.id] = {
            senderID = senderID,
            created = GetCurrentTime(),
            key = data.key,
            parts = data.parts,
            enc = data.enc,
            data = Table(),
        }
    end

    if data.parts == 0 or
        M.pending[data.id].parts == table.length(M.pending[data.id].data) then
        finalizeCommunication(data.id)
    else
        utils_async.delayTask(function()
            LogWarn(string.format("Communication timed out : player %d ; event %s", senderID, data.key))
            M.pending[data.id] = nil
        end, 30, getTimeoutKey(data.id))
    end
end

---@param senderID integer
---@param dataStr string
function _BJSRxData(senderID, dataStr)
    local data = utils_json.parse(dataStr) or {}
    if #MP.GetPlayerName(senderID) == 0 then
        LogError(string.format("Invalid senderID %d", senderID))
        return
    end
    communications_tx.markClient(senderID)
    if not data.id or not data.part or not data.data then
        LogError("Invalid event: ")
        return dump(data)
    end

    if M.pending[data.id] then
        if M.pending[data.id].senderID ~= senderID then
            return LogWarn(string.format("Event part from player %d for another player's event, ignored", senderID))
        end
        table.assign(M.pending[data.id].data, { [data.part] = data.data })
    else
        M.pending[data.id] = {
            senderID = senderID,
            created = GetCurrentTime(),
            data = Table({ [data.part] = data.data }),
        }
    end

    if M.pending[data.id].key and
        M.pending[data.id].parts == table.length(M.pending[data.id].data) then
        finalizeCommunication(data.id)
    else
        utils_async.delayTask(function()
            LogWarn(string.format("Communication timed out : player %d ; event %s", senderID, data.key))
            M.pending[data.id] = nil
        end, 30, getTimeoutKey(data.id))
    end
end

--- how much of what the server sent paced the player's game got (communications/tx.lua's flow
--- control)
---@param senderID integer
---@param dataStr string
function _BJSRxAck(senderID, dataStr)
    if #MP.GetPlayerName(senderID) == 0 then return end
    communications_tx.markClient(senderID)
    communications_tx.acknowledge(senderID, tonumber(dataStr))
end

M.onInit = onInit

M.addHandler = addHandler
M.removeHandler = removeHandler
M.dispatch = dispatch

return M
