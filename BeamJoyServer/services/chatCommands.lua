---@class BJChatCommand
---@field command string
---@field commandKey string
---@field descKey string
---@field validate fun(ctxt: BJSContext, args: string[]): boolean
---@field callback fun(ctxt: BJSContext, args: string[], command: BJChatCommand)
---@field permissions string[]

local M = {
    prefix = "/",

    ---@type table<string, BJChatCommand>
    commands = {},
}

---@param ctxt BJSContext
local function help(ctxt)
    local lines = {}
    table.insert(lines, services_lang.get("chat.command.help.title", ctxt.sender.lang))
    table.values(M.commands):sort(function(a, b) return a.command < b.command end)
        :filter(function(cmd) ---@param cmd BJChatCommand
            return #cmd.permissions == 0 or
                services_permissions.hasAllPermissions(ctxt.senderID, table.unpack(cmd.permissions))
        end)
        :forEach(function(cmd) ---@param cmd BJChatCommand
            table.insert(lines, string.format("- %s: %s",
                services_lang.get(cmd.commandKey, ctxt.sender.lang),
                services_lang.get(cmd.descKey, ctxt.sender.lang)))
        end)
    table.forEach(lines, function(line) services_chat.directSend(ctxt.senderID, line) end)
end

local function onInit()
    M.addCommand("help", "chat.command.help.desc", help)
    M.addCommand("pm", "chat.command.pm.desc", services_players.chatPrivateMessage,
        { commandKey = "chat.command.pm.command" })
end

---@param ctxt BJSContext
---@param args string[]
local function onBJChatCommand(ctxt, args)
    local command = M.commands[args[1]]
    if not command then
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.notFound", ctxt.sender.lang)
            :var({ command = args[1] }),
            services_chat.COLORS.ERROR)
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.showHelp", ctxt.sender.lang)
            :var({ command = M.prefix .. "help" }))
        return
    end

    -- front-door permission check : previously the "permissions" field was only ever consulted
    -- by /help's own visibility filter, so an unauthorized player invoking a hidden command would
    -- silently fall through to whatever the downstream callback happened to do (most already
    -- self-check and reject, but nothing enforced it here). Matches BJI's own findCommand, which
    -- gates both discovery and execution the same way.
    if #command.permissions > 0 and
        not services_permissions.hasAllPermissions(ctxt.senderID, table.unpack(command.permissions)) then
        services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.error.noPermission", ctxt.sender.lang),
            services_chat.COLORS.ERROR)
        return
    end

    if command.validate(ctxt, args) then
        command.callback(ctxt, table.filter(args, function(_, i) return i > 1 end), command)
    end
end

---@param command string
---@param descKey string
---@param callback fun(ctxt: BJSContext, args: string[], command: BJChatCommand)
---@param options {commandKey: string?, permissions: string[]?, validate: (fun(ctxt: BJSContext, args: string[]): boolean)?}?
local function addCommand(command, descKey, callback, options)
    options = options or {}

    if M.commands[command] then
        LogWarn(string.format("Command '%s' is already registered, skipping...", command))
        return
    end

    M.commands[command] = {
        command = command,
        commandKey = options.commandKey or (M.prefix .. command),
        descKey = descKey,
        validate = options.validate or TrueFn,
        callback = callback,
        permissions = options.permissions or {},
    }
end

M.onInit = onInit
M.onBJChatCommand = onBJChatCommand

M.addCommand = addCommand

return M
