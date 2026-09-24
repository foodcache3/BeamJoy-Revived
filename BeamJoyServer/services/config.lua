---@class BJCConfig : BJSConfig
---@field AllowClientMods boolean forced permanently false (see sanitizeConfigValue) after the
---player-vehicle-mod re-scan mechanism it enables (mods.lua's onModActivated/onModDeactivated ->
---onBJVehicleModChanged) was found causing a real, severe client-side stall ; no longer a real
---per-server toggle, kept only so the rest of this codebase (mods.lua's M.state, etc.) doesn't need
---a separate code path
---@field DefaultGroup string?
---@field ModelBlacklist string[]
---@field AllowWalking boolean
---@field CEN {Console: boolean, Editor: boolean}
---@field Chat table<string, string>
---@field IntroPanel {enabled: boolean, title: string, content: string, image: string?, onlyFirstConnection: boolean}
---@field DiscordChatHookLang string?
---@field Broadcasts {enabled: boolean, delay: integer, messages: table<string, string>[]}
---@field Whitelist table?
---@field Freeroam {TeleportDelay: integer, CollisionsMode: "forced"|"disabled"|"ghosts", RespawnGhostTimeoutEnabled: boolean, RespawnGhostTimeout: integer, RespawnGhostDistance: integer, RefuelDuration: integer, RepairDuration: integer, PreserveEnergyOnRefuel: boolean, StrictBusStops: boolean, PreserveFuelOnReset: boolean, EmergencyRefuelCooldown: integer}
---CollisionsMode : "forced" = collisions always on, ghosting never happens ; "disabled" = every
---player vehicle permanently ghosted (free-for-all, no vehicle-vehicle collision at all) ;
---"ghosts" (default) = respawn protection: a vehicle briefly ghosts on spawn/reset, only
---un-ghosting once clear of other vehicles, so nobody gets exploded by materializing inside
---someone. Independent of this, a race participant is also always ghosted for the COUNTDOWN grid
---phase of any race (see BJRaceDefaults.ghostOnCountdown), regardless of this setting.
---RespawnGhostTimeoutEnabled : whether a "ghosts"-mode spawn/reset protection ghost ever expires
---on its own at all ; off means it only ever clears via some other reason (leaving/mode change
---etc.). Same effective behavior as the previous design's "slide the timer to max" convention,
---replaced because that was fragile (real, reported: setting it that way threw config-save errors,
---since a value of exactly the client's own RESPAWN_GHOST_TIMEOUT_MAX had no server-side meaning
---of its own and never should have needed one). Same enabled-toggle + conditional-slider shape as
---dnfEnabled/dnfTimeout elsewhere in this codebase, deliberately.
---RespawnGhostTimeout : seconds a "ghosts"-mode spawn/reset protection ghost lasts before it's
---allowed to clear (subject to RespawnGhostDistance below still being satisfied). Only meaningful
---while RespawnGhostTimeoutEnabled is true.
---RespawnGhostDistance : extra buffer distance (meters), on top of the two vehicles' own bounding
---radii, a spawn/reset-protected vehicle must clear of every other vehicle before un-ghosting.
---0 (default) matches the original behavior (only literal contact blocks it).
---StrictBusStops : when on, a BJS bus-line stop also requires the bus's own doors to be open, and
---kneeling active on any bus that actually supports it, before it counts as "arrived" (matching how
---a real, vanilla scripted bus stop behaves) - off (default), proximity alone is enough, same as
---before this setting existed.
---@field RaceAuthorshipRestriction boolean when on, non-staff race editors may only save/delete
---races they authored themselves (services/races.lua's raceSave/raceDelete) ; when off (default),
---anyone with EditRaces can manage any race, same as before this restriction ever existed
---@field RaceEditorShowOnlyEditable boolean when on, the Config > Races browse list only shows
---races the current player can actually manage (staff sees everything regardless) ; purely a
---client-side display filter, doesn't change who can manage what: that's RaceAuthorshipRestriction
---@field ForceHud boolean forces the main BeamJoy window open and non-closable for every player,
---the same treatment staff already always get ; default on
---@field ShowHudAtStart boolean opens the main BeamJoy window automatically on connect (still
---player-closable afterward, unlike ForceHud) ; moot while ForceHud is on, matters when it's off ;
---default on
---@field Voting {MapVoteThresholdPercent: number, MapVoteTimeout: integer, KickVoteThresholdPercent: number, KickVoteTimeout: integer}
---ThresholdPercent : percentage (1-100) of eligible voters needed to pass ; Timeout : seconds a
---vote stays open before it's automatically considered failed. Defaults (51%, 30s) match what
---mapVote.lua/kickVote.lua originally hardcoded before this became configurable.

local M = {
    ---@class BJSConfig
    data = {
        AllowClientMods = false,
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
            weights = {},
            smartSelection = false,
            parkedAmount = 0,
            parkedMaxPerPlayer = 1,
            plateFrontUsage = "normal",
            plateShape = "eu",
            plateDesign = "",
        },
        Freeroam = {
            TeleportDelay = 30,
            CollisionsMode = "ghosts",
            RespawnGhostTimeoutEnabled = true,
            RespawnGhostTimeout = 10,
            RespawnGhostDistance = 0,
            -- Energy-station / garage interaction (see services/freeroamData.lua). Seconds the
            -- refuel/repair "process" holds the vehicle frozen before completing ; both clamped
            -- [0, 60] client-side too. PreserveEnergyOnRefuel keeps the vehicle's fuel level
            -- across the in-place reset a garage repair performs (a repair otherwise refills it).
            RefuelDuration = 5,
            RepairDuration = 5,
            PreserveEnergyOnRefuel = true,
            StrictBusStops = false,
            -- From old BeamJoy. Native BeamNG vehicle reset (Ctrl+R "Recover Vehicle") always
            -- refills every energy storage back to spawn state (see the installed game's own
            -- lua/vehicle/main.lua onVehicleReset, which calls energyStorage.reset()
            -- unconditionally) - there is no vanilla setting to stop it. When on, BJS snapshots
            -- the local player's own vehicle's fuel immediately before a reset and restores it
            -- immediately after, synchronously, so resetting a stuck/flipped vehicle doesn't also
            -- give it free fuel.
            --
            -- A "PreserveDamageOnReset" companion was attempted and removed (direct report:
            -- "doesn't even work"). Structural, not a bug to fix: damage repair on reset happens at
            -- the native physics/engine level (actual node position restoration), not through any
            -- Lua-side function this mod can intercept - `damageTracker.reset()`/`beamstate.reset()`
            -- (the only Lua-side hooks available) are just bookkeeping for the damage tracker's own
            -- UI/scoring records, not the repair mechanism itself. Skipping them left the vehicle
            -- physically repaired anyway while the damage tracker's own records went stale/wrong -
            -- worse than doing nothing.
            PreserveFuelOnReset = false,
            -- Free "emergency refuel" HUD button, only while actually empty : cooldown before it
            -- can be used again on the same vehicle instance. Seconds, clamped [0, 3600] client-side.
            EmergencyRefuelCooldown = 300,
        },
        RaceAuthorshipRestriction = false,
        RaceEditorShowOnlyEditable = false,
        ForceHud = true,
        ShowHudAtStart = true,
        Voting = {
            MapVoteThresholdPercent = 51,
            MapVoteTimeout = 30,
            KickVoteThresholdPercent = 51,
            KickVoteTimeout = 30,
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
        Freeroam = M.data.Freeroam,
        -- Visible to every player, not SetConfig-gated: each one needs to be readable client-side
        -- to gate ordinary UI (race edit/delete buttons, the race browse list filter, whether the
        -- main window opens forced/at-start), not just editable by an admin.
        RaceAuthorshipRestriction = M.data.RaceAuthorshipRestriction,
        RaceEditorShowOnlyEditable = M.data.RaceEditorShowOnlyEditable,
        ForceHud = M.data.ForceHud,
        ShowHudAtStart = M.data.ShowHudAtStart,
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
        return nil, "AllowClientMods has been disabled and can no longer be changed"
    elseif key == "AllowWalking" or
        key == "RaceAuthorshipRestriction" or key == "RaceEditorShowOnlyEditable" or
        key == "ForceHud" or key == "ShowHudAtStart" then
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
    elseif key == "Freeroam" then
        if type(value) ~= "table" then
            return nil, "Value must be a table"
        end
        -- Defensive coercion, same class of fix already applied at several other numeric UI input
        -- sites in this codebase (gate width/height, sectorCount): bj-slider's typable number-box
        -- can hand back a string in this CEF build even though the slider itself always produces a
        -- real number, silently failing the strict type(...) == "number" checks below on every save
        -- regardless of the actual value typed/dragged. Coerced here, once, rather than trusting
        -- every client call site to remember to, since this whole table is saved atomically: one
        -- bad field (even one the player never touched this session, e.g. RespawnGhostDistance
        -- sitting at its own already-fine default) would otherwise silently reject unrelated fields
        -- bundled in the same payload (CollisionsMode, RespawnGhostTimeoutEnabled) too.
        if type(value.TeleportDelay) == "string" then value.TeleportDelay = tonumber(value.TeleportDelay) end
        if type(value.RespawnGhostTimeout) == "string" then value.RespawnGhostTimeout = tonumber(value.RespawnGhostTimeout) end
        if type(value.RespawnGhostDistance) == "string" then value.RespawnGhostDistance = tonumber(value.RespawnGhostDistance) end
        if type(value.RefuelDuration) == "string" then value.RefuelDuration = tonumber(value.RefuelDuration) end
        if type(value.RepairDuration) == "string" then value.RepairDuration = tonumber(value.RepairDuration) end
        if type(value.EmergencyRefuelCooldown) == "string" then value.EmergencyRefuelCooldown = tonumber(value.EmergencyRefuelCooldown) end
        -- backfill : a config saved before these keys existed omits them entirely, and this whole
        -- table saves atomically, so a missing key would otherwise reject the unrelated fields
        -- bundled with it (same reasoning as the string coercion above)
        if value.RefuelDuration == nil then value.RefuelDuration = M.data.Freeroam.RefuelDuration end
        if value.RepairDuration == nil then value.RepairDuration = M.data.Freeroam.RepairDuration end
        if value.PreserveEnergyOnRefuel == nil then value.PreserveEnergyOnRefuel = M.data.Freeroam.PreserveEnergyOnRefuel end
        if value.StrictBusStops == nil then value.StrictBusStops = M.data.Freeroam.StrictBusStops end
        if value.PreserveFuelOnReset == nil then value.PreserveFuelOnReset = M.data.Freeroam.PreserveFuelOnReset end
        if value.EmergencyRefuelCooldown == nil then value.EmergencyRefuelCooldown = M.data.Freeroam.EmergencyRefuelCooldown end
        if type(value.TeleportDelay) ~= "number" then
            return nil, "TeleportDelay must be a number"
        elseif value.CollisionsMode ~= "forced" and value.CollisionsMode ~= "disabled" and
            value.CollisionsMode ~= "ghosts" then
            return nil, "Invalid CollisionsMode"
        elseif type(value.RespawnGhostTimeoutEnabled) ~= "boolean" then
            return nil, "RespawnGhostTimeoutEnabled must be a boolean"
        elseif type(value.RespawnGhostTimeout) ~= "number" or value.RespawnGhostTimeout < 0 then
            return nil, "RespawnGhostTimeout must be a positive number"
        elseif type(value.RespawnGhostDistance) ~= "number" or value.RespawnGhostDistance < 0 then
            return nil, "RespawnGhostDistance must be a positive number"
        elseif type(value.RefuelDuration) ~= "number" or value.RefuelDuration < 0 or value.RefuelDuration > 60 then
            return nil, "RefuelDuration must be a number between 0 and 60"
        elseif type(value.RepairDuration) ~= "number" or value.RepairDuration < 0 or value.RepairDuration > 60 then
            return nil, "RepairDuration must be a number between 0 and 60"
        elseif type(value.PreserveEnergyOnRefuel) ~= "boolean" then
            return nil, "PreserveEnergyOnRefuel must be a boolean"
        elseif type(value.StrictBusStops) ~= "boolean" then
            return nil, "StrictBusStops must be a boolean"
        elseif type(value.PreserveFuelOnReset) ~= "boolean" then
            return nil, "PreserveFuelOnReset must be a boolean"
        elseif type(value.EmergencyRefuelCooldown) ~= "number" or value.EmergencyRefuelCooldown < 0
            or value.EmergencyRefuelCooldown > 3600 then
            return nil, "EmergencyRefuelCooldown must be a number between 0 and 3600"
        end
    elseif key == "Voting" then
        if type(value) ~= "table" then
            return nil, "Value must be a table"
        elseif table.any({ "MapVoteThresholdPercent", "KickVoteThresholdPercent" }, function(k)
                return type(value[k]) ~= "number" or value[k] < 1 or value[k] > 100
            end) then
            return nil, "ThresholdPercent must be a number between 1 and 100"
        elseif table.any({ "MapVoteTimeout", "KickVoteTimeout" }, function(k)
                return type(value[k]) ~= "number" or value[k] < 1
            end) then
            return nil, "Timeout must be a positive number"
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
