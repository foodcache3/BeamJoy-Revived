local M = {}

--- the big caches : sent after the rest, in a message of their own. The sidebar and the weather wait
--- on the client's first sendCache (beamjoy_cache.loaded), and with everything in one message they
--- waited on these too (direct report : 7-10 s after the join's UI reload, West Coast's races alone
--- 59 parts of the paced sender's one part per 100 ms)
local LATE = { "races", "vehiclePresets", "vehicleBuilds" }

local function onInit()
    communications_rx.addHandler("clientConnection", M.requestCaches)
    communications_rx.addHandler("requestCaches", M.requestCaches)
end

--- every cache to one player : the small ones first, then the big ones (LATE)
---@param playerID integer
local function sendAll(playerID)
    local res = {}
    extensions.hook("onBJRequestCache", res, playerID)
    local late = {}
    for _, key in ipairs(LATE) do
        if res[key] ~= nil then
            late[key] = res[key]
            res[key] = nil
        end
    end
    if table.length(res) > 0 then
        communications_tx.sendToPlayer(playerID, "sendCache", res)
    end
    if table.length(late) > 0 then
        communications_tx.sendToPlayer(playerID, "sendCache", late)
    end
end

---@param ctxt BJSContext
local function requestCaches(ctxt)
    if ctxt.senderID then sendAll(ctxt.senderID) end
end

M.onInit = onInit

M.requestCaches = requestCaches
M.sendAll = sendAll

return M
