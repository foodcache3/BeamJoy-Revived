---@class BJCConfig : BJSConfig
---@field AllowClientMods boolean
---@field DefaultGroup string?
---@field ModelBlacklist string[]
---@field AllowWalking boolean
---@field CEN {Console: boolean, Editor: boolean}
---@field Chat table<string, string>
---@field IntroPanel {enabled: boolean, title: string, content: string, image: string?, onlyFirstConnection: boolean}
---@field DiscordChatHookLang string?
---@field Broadcasts {enabled: boolean, delay: integer, messages: table<string, string>[]}
---@field Whitelist table?

local M = {
    ---@class BJSConfig
    data = {
        AllowClientMods = true,
        DefaultGroup = "default",
        DiscordChatHookLang = "en-US",
        ---@type string[]
        ModelBlacklist = {},
        AllowWalking = true,
        Broadcasts = {
            enabled = false,
            delay = 120,
            messages = {},
        },
        CEN = {
            Console = false,
            Editor = false,
        },
        Console = {
            Lang = "en_US",
        },
        Whitelist = {
            Enabled = false,
            PlayerNames = {},
        },
        IntroPanel = {
            enabled = true,
            title = "Welcome to your server !",
            content =
            [[Hello fellow player, you successfully installed <span style="color:orange;font-weight:bold;">BeamJoy</span> 🥳<br/>If this is your first time, you can set yourself as the owner by entering the following command in the server's console:<br/><pre>bj group {player_name} owner</pre><br/><button class="btn success" onclick="navigator.clipboard.writeText('bj group {player_name} owner')">COPY</button><br/>You can now change this screen content and the image in the configuration window (F4 > Configuration > General).]],
            image = nil,
            onlyFirstConnection = false,
        },
        Traffic = {
            enabled = false,
            amount = 15,
            maxPerPlayer = 1,
            models = { "simple_traffic" },
        },
        Chat = {
            ServerNameColor = { 1, 0, 0 },
            ServerTextColor = { 1, .349, .349 },
            EventColor = { .267, 1, .267 },
            BroadcastColor = { .7, .7, 1 },
            ShowStaffTag = true,
            WelcomeMessage = {
                ["en-US"] = "Welcome to the server !",
                ["de_DE"] = "Willkommen auf dem Server!",
                ["es_419"] = "¡Bienvenido al servidor!",
                ["es_ES"] = "¡Bienvenido al servidor!",
                ["fr_FR"] = "Bienvenue sur le serveur !",
                ["ja_JP"] = "サーバーへようこそ！",
                ["ko_KR"] = "서버에 오신 것을 환영합니다!",
                ["pl_PL"] = "Witamy na serwerze!",
                ["pt_BR"] = "Bem-vindo ao servidor!",
                ["pt_PT"] = "Bem-vindo ao servidor!",
                ["ru_RU"] = "Добро пожаловать на сервер!",
                ["zh_Hans"] = "欢迎来到服务器！",
                ["zh_Hant"] = "歡迎來到伺服器！"
            },
        },
    },
    default = nil,
}

local function saveData()
    local data = table.clone(M.data)
    dao_config.save(data)
end

local function sanitizeOnStart()
    local updated = false
    -- discord hook lang
    if not services_lang.langs[M.data.DiscordChatHookLang] then
        M.data.DiscordChatHookLang = services_lang.defaultLang
        updated = true
    end
    -- broadcasts langs
    table.forEach(M.data.Broadcasts.messages, function(entry)
        table.forEach(entry, function(_, lang)
            if not services_lang.langs[lang] then
                entry[lang] = nil
                updated = true
            end
        end)
    end)
    -- empty broadcasts
    local previousBroadcastsLength = table.length(M.data.Broadcasts.messages)
    M.data.Broadcasts.messages = table.filter(M.data.Broadcasts.messages,
        function(entry)
            return table.length(entry) > 0
        end)
    if table.length(M.data.Broadcasts.messages) < previousBroadcastsLength then
        updated = true
    end
    -- welcome message langs
    table.forEach(M.data.Chat.WelcomeMessage, function(_, lang)
        if not services_lang.langs[lang] then
            M.data.Chat.WelcomeMessage[lang] = nil
            updated = true
        end
    end)
    -- obsolete configs
    table.forEach(M.data, function(_, k)
        if M.default[k] == nil then
            M.data[k] = nil
            updated = true
        end
    end)

    if updated then
        saveData()
    end
end

local function onInit()
    M.default = table.clone(M.data)
    M.data = table.assign(M.data, dao_config.get() or {})
    sanitizeOnStart()

    communications_rx.addHandler("setConfig", M.set)
    communications_rx.addHandler("whitelist", M.toggleWhitelist)
    communications_rx.addHandler("whitelistPlayer", M.toggleWhitelistPlayerName)

    services_consoleCommands.register("stop", "", "commands.stop.desc",
        M.stopServer)
    services_consoleCommands.register("whitelist", "commands.bjwhitelist.args",
        "commands.bjwhitelist.desc", M.consoleWhitelist)
end

---@param caches table
---@param targetID integer?
---@param forced true?
local function onBJRequestCache(caches, targetID, forced)
    caches.config = {
        AllowClientMods = M.data.AllowClientMods,
        ModelBlacklist = M.data.ModelBlacklist,
        CEN = M.data.CEN,
        IntroPanel = M.data.IntroPanel,
        AllowWalking = M.data.AllowWalking,
        Chat = M.data.Chat,
    }
    if forced or (targetID and services_permissions.hasAllPermissions(targetID,
            BJ_PERMISSIONS.SetConfig)) then
        table.assign(caches.config, {
            DefaultGroup = M.data.DefaultGroup,
            DiscordChatHookLang = M.data.DiscordChatHookLang,
            Broadcasts = M.data.Broadcasts
        })
    end
    if forced or (targetID and services_permissions.hasAllPermissions(targetID,
            BJ_PERMISSIONS.Whitelist)) then
        table.assign(caches.config, {
            Whitelist = M.data.Whitelist
        })
    end
end

---@param key string
---@param value any
---@return any value, string? error
local function sanitizeConfigValue(key, value)
    if key == "AllowClientMods" then
        if type(value) ~= "boolean" then return nil, "Value must be a boolean" end
    elseif key == "DefaultGroup" then
        if type(value) ~= "string" then
            return nil, "Value must be a string"
        elseif not services_groups.data[value] then
            return nil, "Group does not exist"
        end
    elseif key == "DiscordChatHookLang" then
        if type(value) ~= "string" then
            return nil, "Value must be a string"
        elseif not services_lang.langs[value] then
            return nil, "Invalid lang"
        end
    elseif key == "ModelBlacklist" then
        if type(value) ~= "table" then return nil, "Value must be a table" end
    elseif key == "Broadcasts" then
        if type(value) ~= "table" then
            return nil, "Value must be a table"
        elseif type(value.enabled) ~= "boolean" then
            return nil, "Enabled must be a boolean"
        elseif type(value.delay) ~= "number" then
            return nil, "Delay must be a number"
        elseif not table.isArray(value.messages) or
            table.any(value.messages, function(entry)
                return not table.isObject(entry) or
                    table.any(entry, function(msg, lang)
                        return not services_lang.langs[lang] or
                            type(msg) ~= "string"
                    end)
            end) then
            return nil, "Invalid messages data"
        end

        table.forEach(value.messages, function(entry, i)
            value.messages[i] = table.filter(entry, function(msg)
                return #msg:trim() > 0
            end)
        end)
        value.messages = table.filter(value.messages, function(entry)
            return table.length(entry) > 0
        end)
    elseif key == "CEN" then
        if type(value) ~= "table" then
            return nil, "Value must be a table"
        elseif table.length(value) ~= 2 or not value.Console or not value.Editor then
            return nil, "Invalid CEN data"
        end
    elseif key == "WelcomeMessage" then
        if type(value) ~= "table" then
            return nil, "Value must be a table"
        elseif table.any(value, function(_, lang)
                return not services_lang.langs[lang]
            end) then
            return nil, "Invalid lang in data"
        elseif table.any(value, function(msg)
                return type(msg) ~= "string"
            end) then
            return nil, "Invalid message type in data"
        end
    elseif key == "Whitelist" then
        if type(value) ~= "table" then
            return nil, "Value must be a table"
        elseif type(value.Enabled) ~= "boolean" then
            return nil, "Enabled must be a boolean"
        end
        value.PlayerNames = M.data.Whitelist.PlayerNames -- do not override playernames here
    end
    return value
end

---@param ctxt BJSContext
---@param key string
---@param value any
---@return string?
local function set(ctxt, key, value)
    if M.data[key] == nil then return end
    if ctxt.senderID then
        if not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.SetConfig) then
            return
        end
    end
    if value == nil then
        -- reset value
        value = M.default[key]
    else
        -- assign new value
        local err
        value, err = sanitizeConfigValue(key, value)
        if err then return LogError(err) end
    end
    M.data[key] = value
    saveData()

    services_players.players:forEach(function(p)
        local caches = {}
        M.onBJRequestCache(caches, p.playerID)
        communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
    end)
    return string.format("%s configuration set to %s", key, tostring(value))
end

---@param ctxt BJSContext
---@param newState boolean?
local function toggleWhitelist(ctxt, newState)
    if ctxt.senderID then
        if not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.SetConfig) then
            return
        end
    end
    if newState == nil then
        newState = not M.data.Whitelist.Enabled
    end
    M.data.Whitelist.Enabled = newState
    saveData()

    local caches = {}
    M.onBJRequestCache(caches, nil, true)
    communications_tx.sendByPermissions({ BJ_PERMISSIONS.Whitelist },
        "sendCache", caches)
end

---@param ctxt BJSContext
---@param playerName string
---@return string?
local function toggleWhitelistPlayerName(ctxt, playerName)
    if ctxt.senderID then
        if not services_permissions.hasAllPermissions(ctxt.senderID,
                BJ_PERMISSIONS.Whitelist) then
            return
        end
    end
    local pos = table.indexOf(M.data.Whitelist.PlayerNames, playerName)
    if pos then
        table.remove(M.data.Whitelist.PlayerNames, pos)
    else
        table.insert(M.data.Whitelist.PlayerNames, playerName)
    end
    saveData()

    local caches = {}
    M.onBJRequestCache(caches, nil, true)
    communications_tx.sendByPermissions({ BJ_PERMISSIONS.Whitelist },
        "sendCache", caches)
end

local function stopServer()
    if MP.GetPlayerCount() == 0 then
        return exit()
    end
    for i = 0, 10 do
        utils_async.delayTask(function()
            if i == 10 or MP.GetPlayerCount() == 0 then
                if i == 10 and MP.GetPlayerCount() > 0 then
                    services_players.players:forEach(function(p)
                        services_players.drop(p.playerID, "commands.stop.kickMessage")
                    end)
                end
                return exit()
            end
            local remaining = 10 - i
            services_players.players:forEach(function(p)
                services_players.sendBroadcast(p.playerID, "beamjoy.broadcasts.stop.countdownBroadcast",
                    { seconds = remaining })
                services_chat.sendServerChat(p.playerID, "beamjoy.broadcasts.stop.countdownBroadcast",
                    { seconds = remaining })
            end)
        end, i + 1)
    end
end

---@param args string[]
---@param printUsage fun()
local function consoleWhitelist(args, printUsage)
    if not args[1] then -- bj whitelist > display status
        local whitelistedGroups = table.filter(services_groups.data, function(g)
            return g.whitelisted or g.staff
        end):keys()
        print("\n" .. services_lang.get("commands.bjwhitelist.status")
            :var({
                state = services_lang.get(M.data.Whitelist.Enabled and
                    "common.enabled" or "common.disabled"),
                playerslist = #M.data.Whitelist.PlayerNames > 0 and
                    table.join(M.data.Whitelist.PlayerNames, " ") or
                    services_lang.get("common.none"),
                groupslist = #whitelistedGroups > 0 and
                    whitelistedGroups:join(" ") or
                    services_lang.get("common.none")
            }))
    elseif args[1] == "set" then -- bj whitelist set <boolean>
        if not args[2] or (args[2] ~= "true" and args[2] ~= "false") then
            print("\n" .. string.format("\n%s : bj whitelist set [true|false]", services_lang.get("commands.usage")))
        else
            local newState = args[2] == "true"
            M.toggleWhitelist(InitContext(), newState)
            print(services_lang.get("commands.bjwhitelist.set")
                :var({ state = services_lang.get(newState and "common.enabled" or "common.disabled") }))
        end
    elseif args[1] == "add" then -- bj whitelist add <playername>
        if not args[2] then
            print("\n" ..
                string.format("\n%s : bj whitelist add <playername>", services_lang.get("commands.usage")))
        else
            local targets = services_players.getConnectedByName(args[2])
            if #targets == 0 then
                local out = "\n" .. services_lang.get("commands.bjwhitelist.playerNotFound")
                out = out .. "\n" .. (services_players.players:length() > 0 and
                    services_players.players:keys():join(" ") or
                    services_lang.get("common.none"))
                print(out)
            elseif #targets > 1 then
                local out = "\n" .. services_lang.get("commands.bjwhitelist.playerAmbiguity")
                out = out .. "\n" .. targets:map(function(p) return p.playerName end):join(" ")
                print(out)
            else
                if M.data.Whitelist.PlayerNames:includes(targets[1].playerName) then
                    print("\n" .. services_lang.get("commands.bjwhitelist.alreadyWhitelisted"))
                else
                    toggleWhitelistPlayerName(InitContext(), targets[1].playerName)
                    print("\n" .. services_lang.get("commands.bjwhitelist.add")
                        :var({ playername = targets[1].playerName }))
                end
            end
            print()
        end
    elseif args[1] == "remove" then -- bj whitelist remove <playername>
        if not args[2] then
            print("\n" ..
                string.format("\n%s : bj whitelist add <playername>", services_lang.get("commands.usage")))
        else
            local exactMatch = table.find(M.data.Whitelist.PlayerNames, function(name) return name == args[2] end)
            local targets = exactMatch and Table({ exactMatch }) or
                table.filter(M.data.Whitelist.PlayerNames,
                    function(name) return name:lower():find(args[2]:lower()) end)
            if #targets == 0 then
                local out = "\n" .. services_lang.get("commands.bjwhitelist.playerNotFound")
                out = out .. "\n" .. (table.length(M.data.Whitelist.PlayerNames) > 0 and
                    table.join(M.data.Whitelist.PlayerNames, " ") or
                    services_lang.get("common.none"))
                print(out)
            elseif #targets > 1 then
                local out = "\n" .. services_lang.get("commands.bjwhitelist.playerAmbiguity")
                out = out .. "\n" .. targets:join(" ")
                print(out)
            else
                toggleWhitelistPlayerName(InitContext(), targets[1])
                print("\n" .. services_lang.get("commands.bjwhitelist.remove")
                    :var({ playername = targets[1] }))
            end
            print()
        end
    else -- invalid command
        printUsage()
    end
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache

M.set = set
M.toggleWhitelist = toggleWhitelist
M.toggleWhitelistPlayerName = toggleWhitelistPlayerName
M.save = saveData
M.stopServer = stopServer
M.consoleWhitelist = consoleWhitelist

return M
