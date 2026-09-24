local M = {
    dependencies = { "beamjoy_communications" },

    defaultColor = { 1, 1, 1 },

    ready = false,
    ---@type tablelib<integer, any[]> index 1-N, value printMessage args list
    queue = Table(),

    -- Real, confirmed bug: every chat message on a BJS server - including the player's own, plain,
    -- no-command messages - went through this module and a custom "BJChat" event, understood by
    -- nothing native. A client-side override (ui/.../override/chat.js) had to bridge it into
    -- whichever BeamMP chat UI app happened to be mounted, by calling that app's own global
    -- `addMessage` function directly. BeamMP now ships TWO chat apps side by side (the classic one,
    -- and a newer Vue-based "BeamMP Chat 2") and only the classic one exposes that global - Chat2 is
    -- fully self-contained, so the bridge silently failed whenever Chat2 was the active app (or the
    -- classic one wasn't mounted at all). Since services/chat.lua (server) intercepts ALL chat for
    -- its own crash-workaround relay (see its own header comment) rather than letting BeamMP's own
    -- native broadcast fire, EVERY message - not just BJS's own server messages/command feedback -
    -- depended on this one fragile bridge, matching the reported "nothing appears at all, even my
    -- own plain messages" exactly.
    chatCounter = 0,
}

---@param senderName string?
---@param message string
---@param nameColor number[]? index 1-3, value 0-1 (unused - see printMessage's own comment)
---@param textColor number[] index 1-3, value 0-1 (unused - see printMessage's own comment)
---@param tag string?
local function printMessage(senderName, message, nameColor, textColor, tag)
    -- `guihooks.trigger("onBeamMPChatMessage", {id, message})` is what BOTH chat apps actually
    -- listen for directly (confirmed by reading BeamMP's own UI.lua - the exact call real native
    -- chat messages trigger), so this reaches either one uniformly with no dependency on which is
    -- currently mounted, replacing the old app-specific bridge entirely. Per-message RGB coloring
    -- was already not reproduced through that old bridge either (its own comment said so), so
    -- nothing is lost dropping it here - nameColor/textColor are kept as parameters since callers
    -- (chatMessage/serverMessage/chatEvent/directChat) still compute and pass them, but no longer
    -- used.
    local text = ""
    if senderName then
        if tag then text = text .. "[" .. tag .. "] " end
        text = text .. senderName .. ": "
    end
    text = text .. message

    M.chatCounter = M.chatCounter + 1
    guihooks.trigger("onBeamMPChatMessage", { id = M.chatCounter, message = text })
end

---@param message string
---@param color number[]
local function directChat(message, color)
    M.queue:insert({ nil, message, nil, color })
end

---@param senderName string
---@param message string
local function chatMessage(senderName, message)
    if not beamjoy_config.data.Chat then
        return async.task(function()
            return beamjoy_config.data.Chat ~= nil
        end, function()
            chatMessage(senderName, message)
        end)
    end

    local sender = beamjoy_players.players[senderName]
    if not sender then return end
    local group = beamjoy_groups.getGroup(sender.group)
    if not group then return end
    local tag
    if beamjoy_config.data.Chat.ShowStaffTag and group.staff then
        tag = beamjoy_lang.translate("beamjoy.groups.staffMark")
    end
    M.queue:insert({ senderName, message, group.nameColor, group.textColor, tag })
end

---@param key string
---@param args table?
local function serverMessage(key, args)
    if not beamjoy_config.data.Chat then
        return async.task(function()
            return beamjoy_config.data.Chat ~= nil
        end, function()
            serverMessage(key, args)
        end)
    end

    local nameColor = beamjoy_config.data.Chat.ServerNameColor
    local textColor = beamjoy_config.data.Chat.ServerTextColor
    -- args are literal substitution values (player names, map labels, numbers...), never
    -- translation keys themselves. This used to run them through translate() first, which
    -- looked each one up as if it were a locale key; for an ordinary player/map name that
    -- isn't one, so the substitution silently came back blank/missing instead of the real value.
    local message = string.var(beamjoy_lang.translate(key), args or {})
    M.queue:insert({ beamjoy_lang.translate("beamjoy.chat.senderServer"),
        message, nameColor, textColor })
end

---@param key string
---@param args table?
local function chatEvent(key, args)
    if not beamjoy_config.data.Chat then
        return async.task(function()
            return beamjoy_config.data.Chat ~= nil
        end, function()
            chatEvent(key, args)
        end)
    end

    -- see serverMessage's own comment above: args are literal values, not translation keys
    local message = string.var(beamjoy_lang.translate(key), args or {})
    M.queue:insert({ nil, message, nil, beamjoy_config.data.Chat.EventColor })
end

local function onInit()
    beamjoy_communications.addHandler("chat", M.directChat)
    beamjoy_communications.addHandler("chatMessage", chatMessage)
    beamjoy_communications.addHandler("serverMessage", serverMessage)
    beamjoy_communications.addHandler("chatEvent", chatEvent)

    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJRequestChatData", M.sendChatDataToUI)
end

local function onBJClientReady()
    M.ready = true
end

local function onUpdate(ctxt)
    if M.ready and M.queue[1] then
        printMessage(table.unpack(M.queue[1], 1, 20))
        table.remove(M.queue, 1)
    end
end

local function retrieveCache(caches)
    if caches.config then
        async.delayTask(M.sendChatDataToUI, 0)
    end
end

local function sendChatDataToUI()
    ---@type table
    local payload = table.clone(beamjoy_config.data.Chat)
    payload.ServerNameColor = BJColor():fromArray(payload.ServerNameColor)
    payload.ServerTextColor = BJColor():fromArray(payload.ServerTextColor)
    payload.EventColor = BJColor():fromArray(payload.EventColor)
    payload.BroadcastColor = BJColor():fromArray(payload.BroadcastColor)
    table.forEach(beamjoy_lang.langs, function(lang)
        if not payload.WelcomeMessage[lang] then
            payload.WelcomeMessage[lang] = ""
        end
    end)
    beamjoy_communications_ui.send("BJSendChatData", payload)
end

M.onInit = onInit
M.onBJClientReady = onBJClientReady
M.onUpdate = onUpdate

M.directChat = directChat
M.sendChatDataToUI = sendChatDataToUI
M.retrieveCache = retrieveCache

return M
