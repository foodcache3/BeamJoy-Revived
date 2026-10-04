local M = {
    dependencies = { "beamjoy_communications_ui" },
    handlers = Table(),
    oneUseHandlers = Table(),

    RX_LOG_EVENTS_BLACKLIST = { "tick", "trafficRubberbandTick" },
}

local function onInit()
    require("ge/extensions/beamjoy/communications/rx")

    ---@param serverTick BJServerTick
    M.addHandler("tick", function(serverTick)
        extensions.hook("onServerTick", beamjoy_context.get(), serverTick)
    end)

    beamjoy_communications_ui.addHandler("BJDirectSend", M.send)
end

---@param key string
---@param handlerFn fun(...)
---@return string
local function addHandler(key, handlerFn)
    local id = UUID()
    M.handlers[id] = { key = key, handlerFn = handlerFn }
    return id
end

---@param key string
---@param handlerFn fun(...)
---@param timeout? integer in ms
---@return string
local function addOneUseHandler(key, handlerFn, timeout)
    local id = UUID()
    M.oneUseHandlers[id] = { key = key, handlerFn = handlerFn }
    if timeout and timeout > 0 then
        async.delayTask(function()
            if M.oneUseHandlers[id] then
                M.oneUseHandlers[id] = nil
            end
        end, timeout, "bj-comm-handler-timeout-" .. id)
    end
    return id
end

local function removeHandler(id)
    M.handlers[id] = nil
    M.oneUseHandlers[id] = nil
end

--- Real bug: one handler erroring stopped every handler after it for that message. "sendCache"
--- alone has a dozen (each module takes its own part), run in no set order, so one module's error
--- randomly left others with stale state - a pursuit's fugitive tag outliving the pursuit, for one.
--- Each handler now runs on its own ; an error is logged and the rest still run.
---@param key string
---@param handlerFn function
---@param data table
local function runHandler(key, handlerFn, data)
    local ok, err = xpcall(function() handlerFn(table.unpack(data, 1, 20)) end, debug.traceback)
    if not ok then
        LogError(string.format("beamjoy_communications: a handler for %s failed: %s", key, tostring(err)))
    end
end

local function dispatch(key, ...)
    local data = { ... }
    local countHandlers = 0
    M.handlers:filter(function(h)
        return h.key == key
    end):forEach(function(h)
        countHandlers = countHandlers + 1
        runHandler(key, h.handlerFn, data)
    end)
    M.oneUseHandlers:filter(function(h)
        return h.key == key
    end):forEach(function(h, id)
        countHandlers = countHandlers + 1
        M.oneUseHandlers[id] = nil
        async.removeTask("bj-comm-handler-timeout-" .. id)
        runHandler(key, h.handlerFn, data)
    end)
    if not table.includes(M.RX_LOG_EVENTS_BLACKLIST, key) then
        LogDebug(string.format("Event %s received (%d handlers, %d args)",
            key, countHandlers, #{ ... }))
    end
end

local tx = require("ge/extensions/beamjoy/communications/tx")
local function send(key, ...)
    tx(key, ...)
    LogDebug(string.format("Event %s sent (%d args)", key, #{ ... }))
end

M.onInit = onInit

M.addHandler = addHandler
M.addOneUseHandler = addOneUseHandler
M.removeHandler = removeHandler
M.dispatch = dispatch
M.send = send

return M
