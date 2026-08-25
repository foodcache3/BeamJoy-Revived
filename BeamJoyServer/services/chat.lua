local M = {
    DISCORD_CHAT_HOOK_EVENTS_BLACKLIST = {
        "beamjoy.chat.event.playerJoined",
        "beamjoy.chat.event.playerLeft",
    },

    COLORS = {
        DEFAULT = { 1, 1, 1 },
        ERROR = { 1, .4, .4 },
        MP = { .7, .7, 1 },
        DISABLED = { .7, .7, .7 },
    },
}

---@param senderID integer
---@param senderName string
---@param chatMessage string
local function onChatMessage(senderID, senderName, chatMessage)
    local ctxt = InitContext(senderID)
    if not ctxt.sender then return end

    if chatMessage:trim():find("^" .. services_chatCommands.prefix) then
        local command = chatMessage:trim():sub(#services_chatCommands.prefix + 1):trim()
        while command:find("  ") do command = command:gsub("  ", " ") end
        if #command > 0 then
            extensions.hook("onBJChatCommand", ctxt, command:split2(" "))
        end
        return
    end

    if ctxt.sender.muted or ctxt.group.muted then
        if ctxt.sender.muted and ctxt.sender.muteReason and
            #ctxt.sender.muteReason > 0 then
            M.sendServerChat(senderID, "error.mutedWithReason",
                { reason = ctxt.sender.muteReason })
        else
            M.sendServerChat(senderID, "error.muted")
        end
        return
    end

    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "chatMessage",
        senderName, chatMessage)
end

---@param playerID integer
---@param message string
---@param color number[]?
local function directSend(playerID, message, color)
    color = color or M.COLORS.DEFAULT
    communications_tx.sendToPlayer(playerID, "chat", message, color)
end

---@param playerID integer
---@param message string
---@param messageParams table?
local function sendServerChat(playerID, message, messageParams)
    if playerID ~= communications_tx.ALL_PLAYERS and not services_players.players
        :any(function(p) return p.playerID == playerID end) then
        return
    end
    communications_tx.sendToPlayer(playerID, "serverMessage", message, messageParams)
end

---@param eventKey string
---@param eventParams table?
local function sendEvent(eventKey, eventParams)
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "chatEvent", eventKey, eventParams)

    -- Discord ChatHook Mod integration (https://github.com/OfficialLambdax/BeamMP-ChatHook)
    if not table.includes(M.DISCORD_CHAT_HOOK_EVENTS_BLACKLIST, eventKey) then
        -- eventParams are literal substitution values (player names, map labels...), never
        -- translation keys themselves. Looking each one up via services_lang.get() first (as
        -- this used to) only works if the value happens to also BE a locale key; an
        -- ordinary player/map name isn't, silently blanking the substitution instead
        local discordMessage = services_lang.get(eventKey, services_config.data.DiscordChatHookLang)
            :var(eventParams or {})
        MP.TriggerGlobalEvent("onScriptMessage", discordMessage, "BeamJoy")
    end
end

local function sendWelcomeMessage(playerName)
    local player = services_players.players[playerName]
    if not player then return end
    local message = services_config.data.Chat.WelcomeMessage[player.lang] or
        services_config.data.Chat.WelcomeMessage[services_lang.defaultLang]
    if message then
        communications_tx.sendToPlayer(player.playerID, "chatEvent", message)
    end
end

M.onChatMessage = onChatMessage

M.directSend = directSend
M.sendServerChat = sendServerChat
M.sendEvent = sendEvent
M.sendWelcomeMessage = sendWelcomeMessage

return M
