---@class BJMap
---@field label string
---@field base boolean
---@field enabled boolean
---@field archive string?
---@field ignore true? if a modded map is removed, ignore will prevent serving

local M = {
    clientFolder = "",
    mapsFolder = "",

    modsCache = {
        Client = { "BJ.zip" },
        Maps = {},
    },

    ---@type table<string, BJMap>
    data = {
        smallgrid = {
            label = "Small Grid",
            base = true,
            enabled = true,
        },
        gridmap_v2 = {
            label = "Grid Map V2",
            base = true,
            enabled = true,
        },
        automation_test_track = {
            label = "Automation Test Track",
            base = true,
            enabled = true,
        },
        east_coast_usa = {
            label = "East Coast",
            base = true,
            enabled = true,
        },
        hirochi_raceway = {
            label = "Hirochi Raceway",
            base = true,
            enabled = true,
        },
        italy = {
            label = "Italy",
            base = true,
            enabled = true,
        },
        jungle_rock_island = {
            label = "Jungle Rock Island",
            base = true,
            enabled = true,
        },
        industrial = {
            label = "Industrial",
            base = true,
            enabled = true,
        },
        small_island = {
            label = "Small Island",
            base = true,
            enabled = true,
        },
        utah = {
            label = "Utah",
            base = true,
            enabled = true,
        },
        west_coast_usa = {
            label = "West Coast",
            base = true,
            enabled = true,
        },
        driver_training = {
            label = "Driver Training",
            base = true,
            enabled = true,
        },
        derby = {
            label = "Derby Arena",
            base = true,
            enabled = true,
        },
        johnson_valley = {
            label = "Johnson Valley",
            base = true,
            enabled = true,
        }
    }
}

---@return {Client: string[], Maps: string[]}
local function generateCache()
    local res = { Client = {}, Maps = {} }
    for _, mod in ipairs(FS.ListFiles(M.clientFolder)) do
        if mod:find("%.zip$") then
            table.insert(res.Client, mod)
        end
    end
    for _, mod in ipairs(FS.ListFiles(M.mapsFolder)) do
        if mod:find("%.zip$") then
            table.insert(res.Maps, mod)
        end
    end
    table.sort(res.Client)
    table.sort(res.Maps)
    return res
end

---@param archivePath string
---@return {name: string, archive: string, label: string}[]
local function extractLevelData(archivePath)
    ---@type any
    local archiveName = archivePath:split2("/")
    archiveName = archiveName[#archiveName]

    local dstPath = BJSPluginPath:gsub("Server/BeamJoyServer", "tmp")
    if FS.Exists(dstPath) then FS.RemoveDirectory(dstPath) end
    LogInfo("Analyzing " .. archivePath .. " ...")
    FS.ExtractTo(archivePath, dstPath)

    local res = {}

    if table.includes(FS.ListDirectories(dstPath), "levels") then
        for _, name in ipairs(FS.ListDirectories(dstPath .. "/levels")) do
            ---@type string?
            local label
            if FS.Exists(dstPath .. "/levels/" .. name .. "/info.json") then
                local file = io.open(dstPath .. "/levels/" .. name .. "/info.json", "r")
                if file then
                    local ok = pcall(function()
                        local content = utils_json.parse(file:read("*a")) or {}
                        label = content.title
                    end)
                    if not ok then
                        LogError(string.format("Error while reading %s/levels/%s/info.json : Maformed JSON file", dstPath,
                            name))
                    end
                    file:close()
                end
            end
            table.insert(res, { name = name, archive = archiveName, label = label or name })
        end
    end
    FS.RemoveDirectory(dstPath)
    return res
end

--- mapsData index is mapName
---@return table<string, {archive: string, label: string}> mapsData, boolean rebootNeeded
local function sanitizeAndRetrieveModdedMaps()
    local currentMap = services_core.getCurrentMap()
    local rebootNeeded = false
    local skipped = {} -- archives already analyzed and moved/copied to idle
    local res = {}
    for _, mod in ipairs(FS.ListFiles(M.clientFolder)) do
        if mod:find("%.zip$") then
            local maps
            if table.includes(M.modsCache.Client, mod) or table.includes(M.modsCache.Maps, mod) then
                -- already cached maps
                maps = table.filter(M.data, function(map, name)
                    return map.archive == mod
                end):map(function(map, name)
                    return {
                        name = name,
                        archive = map.archive,
                        label = map.label,
                    }
                end):values()
            else
                local ok, extracted = pcall(extractLevelData, M.clientFolder .. "/" .. mod)
                if ok then
                    maps = extracted
                else
                    -- one bad archive (eg. a path/name the OS can't fully process) must not abort
                    -- the whole scan and leave every other map unregistered.
                    LogError(string.format("Error analyzing mod %s : %s", mod, tostring(extracted)))
                    maps = {}
                end
            end
            if table.length(maps) > 0 then
                if not FS.Exists(M.mapsFolder .. "/" .. mod) then
                    -- copy to maps folder if not already there
                    FS.Copy(M.clientFolder .. "/" .. mod, M.mapsFolder .. "/" .. mod)
                    table.insert(skipped, mod)
                end
                if not table.any(maps, function(data)
                        return data.name == currentMap
                    end) then
                    -- modded map is active and not the current one
                    if FS.Exists(M.mapsFolder .. "/" .. mod) then
                        FS.Remove(M.clientFolder .. "/" .. mod)
                    end
                    rebootNeeded = true
                    table.insert(skipped, mod)
                end
                table.forEach(maps, function(data)
                    res[data.name] = {
                        archive = data.archive,
                        label = data.label,
                    }
                end)
            end
        end
    end
    for _, mod in ipairs(FS.ListFiles(M.mapsFolder)) do
        if mod:find("%.zip$") and not table.includes(skipped, mod) then
            local maps
            if table.includes(M.modsCache.Maps, mod) then
                -- already cached maps
                maps = table.filter(M.data, function(map, name)
                    return map.archive == mod
                end):map(function(map, name)
                    return {
                        name = name,
                        archive = map.archive,
                        label = map.label,
                    }
                end):values()
            else
                local ok, extracted = pcall(extractLevelData, M.mapsFolder .. "/" .. mod)
                if ok then
                    maps = extracted
                else
                    LogError(string.format("Error analyzing mod %s : %s", mod, tostring(extracted)))
                    maps = {}
                end
            end
            if table.length(maps) > 0 then
                if table.any(maps, function(data)
                        return data.name == currentMap
                    end) and not FS.Exists(M.clientFolder .. "/" .. mod) then
                    -- modded map is the current one and is not active
                    FS.Copy(M.mapsFolder .. "/" .. mod, M.clientFolder .. "/" .. mod)
                    rebootNeeded = true
                end
                table.forEach(maps, function(data)
                    res[data.name] = {
                        archive = data.archive,
                        label = data.label,
                    }
                end)
            end
        end
    end
    return res, rebootNeeded
end

---@param onRebootNeeded fun()? called instead of the default exit()-after-3s behavior if this
---scan determines a reboot/reload is needed. Pass a no-op if the caller is already about to
---reload/restart mods anyway for its own separate reason (eg. switchMap already calling
---FS.SendConsoleCommand("reloadmods") for the specific map it's switching to), since otherwise
---whatever this scan additionally found would still schedule its own independent exit() on top.
local function scanNewMods(onRebootNeeded)
    LogWarn(services_lang.get("maps.scan.start"))
    local modded, rebootNeeded = sanitizeAndRetrieveModdedMaps()
    local changed = false
    table.forEach(modded, function(data, name)
        if not M.data[name] then
            -- new modded map
            M.data[name] = {
                label = data.label,
                enabled = true,
                base = false,
                archive = data.archive,
            }
            changed = true
        elseif M.data[name].ignore then
            -- re-enable modded map
            M.data[name].ignore = nil
            changed = true
        end
    end)
    table.forEach(M.data, function(map, name)
        if not map.base and not modded[name] then
            -- disable obsolete modded map
            M.data[name].ignore = true
            changed = true
        end
    end)

    if changed then
        dao_maps.save(M.data)
    end

    if rebootNeeded then
        LogWarn(services_lang.get("maps.scan.done.withReboot"))
        if onRebootNeeded then
            onRebootNeeded()
        else
            utils_async.delayTask(exit, 3)
        end
    else
        LogInfo(services_lang.get("maps.scan.done"))
    end
end

---@param onRebootNeeded fun()? forwarded to scanNewMods, see its own doc comment
local function refreshModsIfChanged(onRebootNeeded)
    local cache = generateCache()
    if not table.compare(M.modsCache, cache, true) then
        -- set MaxPlayers to 0 to prevent connections during the scan
        local maxPlayers = services_core.data.MaxPlayers
        MP.Set(MP.Settings.MaxPlayers, 0)
        -- pcall'd so one bad mod (eg. an OS-level Unicode path issue) can't leave MaxPlayers
        -- stuck at 0 and abort the caller before it can finish its own remaining work
        local ok, err = pcall(scanNewMods, onRebootNeeded)
        if not ok then
            LogError("Error scanning mods, aborting this scan : " .. tostring(err))
        end
        M.modsCache = generateCache()
        dao_maps.saveModsCache(M.modsCache)
        MP.Set(MP.Settings.MaxPlayers, maxPlayers)
    end
end

local function onInit()
    M.clientFolder = BJSPluginPath:gsub("Server/BeamJoyServer", "Client")
    M.mapsFolder = BJSPluginPath:gsub("Server/BeamJoyServer", "Maps")
    if not FS.Exists(M.mapsFolder) then
        FS.CreateDirectory(M.mapsFolder)
    end

    table.assign(M.data, dao_maps.get() or {})

    table.assign(M.modsCache, dao_maps.getModsCache() or {})
    refreshModsIfChanged()

    if not M.data[services_core.getCurrentMap()] or
        M.data[services_core.getCurrentMap()].ignore then
        -- invalid current map
        LogWarn(services_lang.get("maps.start.fallback"):var({
            newMap = "gridmap_v2"
        }))
        services_core.setMap("gridmap_v2")
    end

    communications_rx.addHandler("setMaps", M.setMaps)
    communications_rx.addHandler("switchMap", M.switchMap)

    services_consoleCommands.register("map", "commands.map.args", "commands.map.desc", M.consoleMap)

    services_chatCommands.addCommand("map", "chat.command.map.desc", M.chatMap,
        { commandKey = "chat.command.map.command", permissions = { BJ_PERMISSIONS.SwitchMap } })
end

---@param caches table<string, any>
---@param playerID integer
local function onBJRequestCache(caches, playerID)
    if services_permissions.hasAllPermissions(playerID, BJ_PERMISSIONS.SetMaps) then
        caches.maps = M.data
    elseif services_permissions.hasAnyPermission(playerID, BJ_PERMISSIONS.SwitchMap, BJ_PERMISSIONS.VoteMap) then
        -- VoteMap holders need the enabled map list too, to build a map-vote picker: they can't
        -- switch directly, but they can still see what's pickable
        caches.maps = table.filter(M.data, function(map)
            return map.enabled
        end)
    end
end

---@param ctxt BJSContext
---@param mapsData table<string, BJMap>
local function setMaps(ctxt, mapsData)
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.SetMaps) then
        return
    end

    table.forEach(mapsData, function(map, name)
        if not M.data[name] then
            -- ensure only existing maps
            mapsData[name] = nil
        else
            -- force restricted fields values
            local current = M.data[name]
            map.base = current.base
            map.ignore = current.ignore
            map.archive = current.archive
            if current.ignore then
                map.enabled = current.enabled
            end
        end
    end)
    -- ensure base maps are present
    table.filter(M.data, function(m) return m.base end)
        :forEach(function(map, name)
            if not mapsData[name] then
                mapsData[name] = map
            end
        end)

    if not table.compare(M.data, mapsData, true) then
        M.data = mapsData
        dao_maps.save(M.data)

        services_players.players:forEach(function(p)
            local caches = {}
            M.onBJRequestCache(caches, p.playerID)
            communications_tx.sendToPlayer(p.playerID, "sendCache", caches)
        end)
    end
end

---@param ctxt BJSContext
---@param newMapName string
---@param onComplete fun()? called once the switch has actually finished: once mods have been
---reloaded (Windows), right before the process exits to let the host restart it (Linux), or
---immediately (a non-modded-to-non-modded switch has nothing to reload/restart). Never called at
---all if the switch is rejected outright (bad permissions/invalid/no-op map) before the kick
---countdown even starts. MaxPlayers is kept at 0 for the whole switch regardless of whether this
---is passed, and is always restored right before this fires, whether or not a caller wants a
---callback.
local function switchMap(ctxt, newMapName, onComplete)
    local currentMapName = services_core.getCurrentMap()
    if ctxt.sender and not services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.SwitchMap) then
        return
    elseif not M.data[newMapName] or currentMapName == newMapName then
        return
    end

    local currentMap = M.data[currentMapName]
    local newMap = M.data[newMapName]

    -- Block new connections for the ENTIRE switch (kick countdown + reload/restart), not just the
    -- reloadmods sub-step itself. Otherwise a player could connect mid-countdown, or in the gap
    -- before Windows' reloadmods actually runs, and get served whatever mix of old/new archives is
    -- sitting in M.clientFolder at that moment. Mirrors the temporary-MaxPlayers-0 pattern
    -- refreshModsIfChanged already uses for its own scan, captured once here (before anything
    -- touches it) so `complete()` below restores the real original value regardless of what
    -- refreshModsIfChanged's own internal capture/restore does with it in the meantime.
    local maxPlayers = services_core.data.MaxPlayers
    MP.Set(MP.Settings.MaxPlayers, 0)
    local complete = function()
        MP.Set(MP.Settings.MaxPlayers, maxPlayers)
        if onComplete then onComplete() end
    end

    if not currentMap.base then
        -- current is modded, remove archive
        FS.Remove(M.clientFolder .. "/" .. currentMap.archive)
        M.modsCache = generateCache()
        dao_maps.saveModsCache(M.modsCache)
    end
    if not newMap.base then
        -- new map is modded, copy archive
        FS.Copy(M.mapsFolder .. "/" .. newMap.archive,
            M.clientFolder .. "/" .. newMap.archive)
        M.modsCache = generateCache()
        dao_maps.saveModsCache(M.modsCache)
    end
    services_core.setMap(newMapName)

    local finishProcess = function()
        -- Always fires now (previously only for a non-modded switch, via the OTHER branch this
        -- used to have). The modded-switch branch used to call exit() right after its own
        -- onMapChangedWithReboot hook, so activityConfig/races/hunter's own onMapChanged listeners
        -- (which reload their per-map data) never actually ran for a modded switch. Harmless
        -- before, since the process died immediately after anyway, but a real gap now that it doesn't.
        extensions.hook("onMapChanged", currentMapName, newMapName)
        if not currentMap.base or not newMap.base then
            -- Previous or next map is modded : the mod archive was already moved in/out of
            -- M.clientFolder above, so newly-connecting players need BeamMP-Server to re-serve
            -- what's actually there now.
            if FS.isWindows() then
                -- Confirmed (via a BeamMP dev, then live-tested) this doesn't require a full
                -- process restart. FS.SendConsoleCommand("reloadmods") gets the same result live,
                -- with the server never actually going down. Windows-only: it works by injecting
                -- keystrokes into BeamMP-Server.exe's own attached console (AttachConsole/
                -- WriteConsoleInput), which has no Linux equivalent wired up here.
                --
                -- Also re-runs the same mods-changed scan onInit runs at startup (skipped
                -- otherwise now that a modded switch no longer restarts the process, which used to
                -- be what triggered it again as a side effect). An onRebootNeeded no-op is passed
                -- since reloadmods is already about to run regardless, covering whatever this scan
                -- finds too, without it also scheduling its own separate exit().
                refreshModsIfChanged(function() end)
                LogWarn(services_lang.get("maps.switch.reloadingMods"))
                FS.SendConsoleCommand("reloadmods")
                complete()
            else
                -- Linux host (or anything else FS.isWindows() doesn't recognize): no console-
                -- injection path exists here, so fall back to the original behavior from before
                -- reloadmods was added. Exit and let the host's own process supervisor (systemd/
                -- pm2/the hoster's own panel, etc.) restart BeamMP-Server, which will pick up the
                -- already-swapped archive in M.clientFolder on its own.
                LogWarn(services_lang.get("maps.switch.rebootWarn"))
                -- Restore MaxPlayers and fire onComplete now, not after the delayed exit: the
                -- process is about to die regardless, so there's nothing left to usefully wait on,
                -- and leaving MaxPlayers at 0 across the exit would persist into the config
                -- BeamMP-Server reads back on restart, permanently locking it at 0 players until
                -- someone manually fixes it.
                complete()
                utils_async.delayTask(exit, 3)
            end
        else
            -- non-modded-to-non-modded switch : nothing to reload/restart, the switch is already
            -- fully done at this point
            complete()
        end
    end
    -- warn and kick all players
    for i = 11, 1, -1 do
        utils_async.delayTask(function()
            if i == 11 then
                -- kick all
                services_players.players:forEach(function(p) ---@param p BJSPlayer
                    services_players.drop(p.playerID, "auth.kick.mapChanged")
                end)
                finishProcess()
            else
                if services_players.players:length() == 0 and
                    MP.GetPlayerCount() == 0 then
                    for j = 11, i + 1, -1 do
                        utils_async.removeTask(string.format("mapChangeKickCountdown-%d", j))
                    end
                    finishProcess()
                    return
                end
                services_players.players:forEach(function(p) ---@param p BJSPlayer
                    services_players.sendBroadcast(p.playerID, "beamjoy.broadcasts.mapChangeKick",
                        { time = 10 - i + 1 })
                    services_chat.sendServerChat(p.playerID, "beamjoy.broadcasts.mapChangeKick",
                        { time = 10 - i + 1 })
                end)
            end
        end, i, string.format("mapChangeKickCountdown-%d", i))
    end
end

---@param args string[]
local function consoleMap(args)
    if not args[1] then
        local current = services_core.getCurrentMap()
        local out = "\n" .. services_lang.get("commands.map.current")
            :var({ map = M.data[current] and M.data[current].label or current })
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_BLUE) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
        return
    end
    local matches
    if M.data[args[1]] then
        -- exact match
        matches = { args[1] }
    else
        -- fuzzy matches
        matches = table.keys(M.data):filter(function(name)
            return tostring(name):lower():find(args[1]:lower()) ~= nil
        end)
    end
    if #matches == 0 then
        local out = "\n" .. services_lang.get("commands.map.notFound")
        out = out .. "\n" .. table.keys(M.data):sort():join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
        return
    elseif #matches > 1 then
        local out = "\n" .. services_lang.get("commands.map.ambiguous")
        out = out .. "\n" .. matches:sort():join(" ")
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_RED) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
        return
    end

    -- Reported via the onComplete callback, not immediately after this call. switchMap's own
    -- kick-countdown/mods-reload-or-restart sequence is async, so printing this right away would
    -- claim the switch is done before it actually is (previously printed right here, misleadingly
    -- appearing BEFORE the "reloading mods"/"reboot" warning and the actual reload/restart).
    M.switchMap(InitContext(), matches[1], function()
        local out = "\n" .. services_lang.get("commands.map.current")
            :var({ map = M.data[matches[1]] and M.data[matches[1]].label or matches[1] })
        print(GetConsoleColor(CONSOLE_COLORS.FOREGROUNDS.LIGHT_GREEN) ..
            out .. GetConsoleColor(CONSOLE_COLORS.STYLES.RESET))
    end)
end

--- chat-command equivalent of consoleMap : same fuzzy exact-then-substring name matching against
--- M.data's keys, just reporting via services_chat.directSend instead of print()
---@param ctxt BJSContext
---@param args string[] "<map_name>"
---@param command BJChatCommand
local function chatMap(ctxt, args, command)
    if #args < 1 then
        services_chat.directSend(ctxt.senderID,
            string.format("%s : %s -> %s",
                services_lang.get("chat.command.usage", ctxt.sender.lang),
                services_lang.get(command.commandKey, ctxt.sender.lang),
                services_lang.get(command.descKey, ctxt.sender.lang)),
            services_chat.COLORS.ERROR)
        return
    end

    local matches
    if M.data[args[1]] then
        matches = { args[1] }
    else
        matches = table.keys(M.data):filter(function(name)
            return tostring(name):lower():find(args[1]:lower()) ~= nil
        end)
    end

    if #matches == 0 then
        services_chat.directSend(ctxt.senderID,
            services_lang.get("commands.map.notFound", ctxt.sender.lang),
            services_chat.COLORS.ERROR)
        return
    elseif #matches > 1 then
        services_chat.directSend(ctxt.senderID,
            services_lang.get("commands.map.ambiguous", ctxt.sender.lang)
            .. "\n" .. matches:sort():join(", "),
            services_chat.COLORS.ERROR)
        return
    end

    -- Deliberately NOT deferred to switchMap's own onComplete callback like consoleMap's
    -- equivalent print now is. The sender gets kicked along with everyone else as part of the
    -- switch's own kick-countdown, so they'd never actually be connected to receive a confirmation
    -- sent after the fact. Sent immediately instead, worded as in-progress rather than
    -- already-done, since that's the only true thing that can be said before they're disconnected.
    M.switchMap(ctxt, matches[1])
    services_chat.directSend(ctxt.senderID,
        services_lang.get("commands.map.switching", ctxt.sender.lang)
        :var({ map = M.data[matches[1]] and M.data[matches[1]].label or matches[1] }))
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache

M.setMaps = setMaps
M.switchMap = switchMap
M.consoleMap = consoleMap
M.chatMap = chatMap

return M
