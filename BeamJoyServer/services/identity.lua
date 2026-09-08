--- Two independent, unrelated stopgaps for while BeamMP's own account system isn't reliable:
---
--- 1) A player-chosen "nickname" (see communications/ui.lua's own onUIReady gating client-side,
---    windows/login on the Angular side) used as this player's DISPLAY identity everywhere this
---    mod's own UI shows a name (nametags.lua's own tag text, the player roster, race leaderboard
---    rows - see getIdentityKey for leaderboard, and players.lua's onBJRequestCache's own new
---    `displayName` field for nametags/roster) going forward. Deliberately NOT what anything
---    identity-critical still keys by: bans/mutes/permissions/vehicle ownership and BeamMP's own
---    native chat still use the raw connection playerName, completely unaffected by this. Also
---    explicitly NOT password-protected (a deliberate scope cut - see this feature's own request
---    thread): anyone can type anyone else's nickname and inherit their leaderboard history/tag,
---    same trust model as any LAN-party "just type a name" convention. Only prevents two people
---    CURRENTLY connected from colliding on the same nickname at once.
---
--- 2) Chat-command staff/owner login (`/staff <password>`, `/owner <password>`), gated by a
---    single shared password per tier, set from the server console (never in a chat message or a
---    config file a player could read). Grants the group for the CURRENT session only, exactly
---    like any other group change (services_players.setGroup already persists/broadcasts it) -
---    there's deliberately no separate revocation command here; use the existing `/bj group` or
---    `/setgroup` to demote someone back down.

local M = {
    dependencies = { "dao_staffAuth", "services_players", "services_groups",
        "services_chatCommands", "services_consoleCommands", "services_chat", "services_lang",
        "services_config", "utils_sha", "communications_rx", "communications_tx" },

    NICKNAME_MIN = 2,
    NICKNAME_MAX = 24,
}

---@param nickname any
---@return string? cleaned nil if invalid
local function sanitizeNickname(nickname)
    if type(nickname) ~= "string" then return nil end
    nickname = nickname:trim()
    if #nickname < M.NICKNAME_MIN or #nickname > M.NICKNAME_MAX then return nil end
    -- reject control characters only ; otherwise deliberately permissive (this is just a display
    -- string used as a leaderboard key, not an identifier anything else parses)
    if nickname:find("%c") then return nil end
    return nickname
end

---@param ctxt BJSContext
---@param nickname string
local function login(ctxt, nickname)
    if not ctxt.sender then return end
    local clean = sanitizeNickname(nickname)
    if not clean then
        return communications_tx.sendToPlayer(ctxt.senderID, "identityLoginResult", false, "invalidNickname")
    end
    local collision = services_players.players:any(function(p)
        return p.playerID ~= ctxt.senderID and p.identityNickname == clean
    end)
    if collision then
        return communications_tx.sendToPlayer(ctxt.senderID, "identityLoginResult", false, "nicknameTaken")
    end
    ctxt.sender.identityNickname = clean
    -- refreshes every connected client's view of THIS player (their nametag/roster entry now
    -- shows the chosen nickname instead of the raw connection name), not just the sender's own
    services_players.sendCacheUpdate()
    communications_tx.sendToPlayer(ctxt.senderID, "identityLoginResult", true, clean)
end

--- The identity key everything leaderboard-related should key entries by instead of the raw,
--- possibly-volatile BeamMP display name: the player's own chosen nickname once logged in, same
--- raw connection playerName as before otherwise (nothing changes for a player who skips login).
---@param playerID integer
---@return string?
local function getIdentityKey(playerID)
    local player = services_players.players:find(function(p) return p.playerID == playerID end)
    if not player then return nil end
    return player.identityNickname or player.playerName
end

---@param ctxt BJSContext
---@param command BJChatCommand
local function chatUsage(ctxt, command)
    services_chat.directSend(ctxt.senderID,
        string.format("%s : %s -> %s",
            services_lang.get("chat.command.usage", ctxt.sender.lang),
            services_lang.get(command.commandKey, ctxt.sender.lang),
            services_lang.get(command.descKey, ctxt.sender.lang)),
        services_chat.COLORS.ERROR)
end

--- first group with staff == true, in configured order (default bundled groups: "mod") ; resolved
--- by flag rather than a hardcoded group name so a host who renamed/reordered the default groups
--- still gets sensible behavior
---@return string?
local function getStaffGroupName()
    local group = table.find(services_groups.data, function(g) return g.staff == true end)
    return group and group.name or nil
end

--- the single highest-ranked configured group (default bundled groups: "owner") ; same
--- rename-tolerant reasoning as getStaffGroupName
---@return string?
local function getOwnerGroupName()
    local group = services_groups.data[#services_groups.data]
    return group and group.name or nil
end

---@param ctxt BJSContext
---@param args string[] "<password...>"
---@param command BJChatCommand
---@param hashField "staffHash"|"ownerHash"
---@param groupName string?
local function chatPasswordLogin(ctxt, args, command, hashField, groupName)
    if #args < 1 then return chatUsage(ctxt, command) end
    if not groupName then return end
    local auth = dao_staffAuth.get() or {}
    if not auth[hashField] then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.login.notConfigured", ctxt.sender.lang),
            services_chat.COLORS.ERROR)
    end
    local password = table.join(args, " ")
    if utils_sha.sha256(password) ~= auth[hashField] then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.login.wrongPassword", ctxt.sender.lang),
            services_chat.COLORS.ERROR)
    end
    -- InitContext() with no senderID => origin "cmd" => setGroup's own permission gate (which
    -- would otherwise require the CALLER to already have SetGroup) never triggers, same trick
    -- services_players.consoleGroup already relies on for the identical reason
    services_players.setGroup(InitContext(), ctxt.sender.playerName, groupName)
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.login.success", ctxt.sender.lang):var({ group = groupName }))
end

---@param ctxt BJSContext
---@param args string[]
---@param command BJChatCommand
local function chatStaffLogin(ctxt, args, command)
    chatPasswordLogin(ctxt, args, command, "staffHash", getStaffGroupName())
end

---@param ctxt BJSContext
---@param args string[]
---@param command BJChatCommand
local function chatOwnerLogin(ctxt, args, command)
    chatPasswordLogin(ctxt, args, command, "ownerHash", getOwnerGroupName())
end

---@param args string[]
---@param printUsage fun()
---@param hashField "staffHash"|"ownerHash"
---@param successKey string
local function consoleSetPassword(args, printUsage, hashField, successKey)
    if not args[1] then return printUsage() end
    local password = table.join(args, " ")
    local auth = dao_staffAuth.get() or {}
    auth[hashField] = utils_sha.sha256(password)
    dao_staffAuth.save(auth)
    -- never echoes the password itself back to the console, only confirms it was set
    print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_GREEN) ..
        "\n" .. services_lang.get(successKey, services_config.data.Console.Lang) ..
        GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
end

---@param args string[]
---@param printUsage fun()
local function consoleSetStaffPassword(args, printUsage)
    consoleSetPassword(args, printUsage, "staffHash", "commands.bjstaffpassword.success")
end

---@param args string[]
---@param printUsage fun()
local function consoleSetOwnerPassword(args, printUsage)
    consoleSetPassword(args, printUsage, "ownerHash", "commands.bjownerpassword.success")
end

local function onInit()
    communications_rx.addHandler("identityLogin", login)

    services_consoleCommands.register("staffpassword", "commands.bjstaffpassword.args",
        "commands.bjstaffpassword.desc", M.consoleSetStaffPassword)
    services_consoleCommands.register("ownerpassword", "commands.bjownerpassword.args",
        "commands.bjownerpassword.desc", M.consoleSetOwnerPassword)

    -- deliberately no `permissions` field on either command : the entire point is that a player
    -- with NO permissions yet can use these to gain some, same as /help and /pm which are the
    -- only other two chat commands registered with no permission gate
    services_chatCommands.addCommand("staff", "chat.command.staff.desc", M.chatStaffLogin,
        { commandKey = "chat.command.staff.command" })
    services_chatCommands.addCommand("owner", "chat.command.owner.desc", M.chatOwnerLogin,
        { commandKey = "chat.command.owner.command" })
end

M.onInit = onInit

M.login = login
M.getIdentityKey = getIdentityKey

M.chatStaffLogin = chatStaffLogin
M.chatOwnerLogin = chatOwnerLogin
M.consoleSetStaffPassword = consoleSetStaffPassword
M.consoleSetOwnerPassword = consoleSetOwnerPassword

return M
