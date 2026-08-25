local M = {
    dependencies = { "beamjoy_communications" },

    defaultColor = { 1, 1, 1 },

    ready = false,
    ---@type tablelib<integer, any[]> index 1-N, value printMessage args list
    queue = Table(),

}

---@param payload {sender: {text: string, color: number[], tag: string?, tagColor: number[]}?, message: {text: string, color: number[]}}
local function addImguiMessage(payload)
    -- multiplayer.ui.chat was removed in BeamNG 0.39 (chat moved to Vue).
    -- Messages are now sent to the frontend via BJChat event in printMessage,
    -- so this ImGui path is no longer needed.
end

---@param senderName string?
---@param message string
---@param nameColor number[]? index 1-3, value 0-1
---@param textColor number[] index 1-3, value 0-1
---@param tag string?
local function printMessage(senderName, message, nameColor, textColor, tag)
    nameColor = nameColor or M.defaultColor
    textColor = textColor or M.defaultColor
    local payload = {
        sender = senderName and {
            text = senderName,
            color = nameColor,
            tag = tag,
            tagColor = beamjoy_config.data.Chat.ServerNameColor,
        } or nil,
        message = {
            text = message,
            color = textColor,
        }
    }
    beamjoy_communications_ui.send("BJChat", jsonEncode(payload))
    addImguiMessage(payload)
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
