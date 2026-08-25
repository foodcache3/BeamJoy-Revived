local M = {}

local counter = 0
local broadcastIndex = 1

local function trigger(conf)
    if broadcastIndex > #conf.messages or not conf.messages[broadcastIndex] then
        broadcastIndex = 1
    end
    local entry = table.map(conf.messages[broadcastIndex], function(msg, lang)
        return {
            lang = lang,
            message = msg,
        }
    end):values():sort(function(a, b)
        if a.lang == "en_US" then return true end
        if b.lang == "en_US" then return false end
        return a.lang < b.lang
    end)
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "chatBroadcast", entry,
        services_config.data.Chat.BroadcastColor)
    broadcastIndex = broadcastIndex + 1
end

local function onSlowUpdate()
    local conf = services_config.data.Broadcasts
    if conf.enabled and #conf.messages > 0 then
        if MP.GetPlayerCount() == 0 then return end
        counter = counter + 1
        if counter >= conf.delay then
            counter = 0
            trigger(conf)
        end
    else
        counter = 0
    end
end

M.onSlowUpdate = onSlowUpdate

return M
