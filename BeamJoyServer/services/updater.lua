--- BeamJoy updates from GitHub (direct request) : the server checks for a new version by itself and
--- tells its owners, and an owner (chat /bjupdate) or the server console (bj update) installs it.
---
--- Two channels, chosen with "channel" (saved in BeamJoyData/update/state.json) :
---  - releases (the default) : the latest GitHub release, newer than this server's version, with
---    its BeamJoy-Revived-<version>.zip package (Server/ and Client/ folders) ;
---  - the development branch (direct request, for testing) : its latest commit, whenever it isn't
---    the one installed last. The branch holds the sources, so BJ.zip is built from its
---    BeamJoyClient folder.
---
--- BeamMP's plugin Lua has no HTTP client, so the GitHub requests go through `curl` (built into
--- Windows 10 1803+), and packages are unpacked the way the mod analyzer does it (PowerShell's
--- .NET zip support on Windows, `unzip` on Linux ; `zip` builds BJ.zip there), each run as a small
--- script in the background : the server thread never waits on them, the result is picked up once
--- a second (onSlowUpdate). A missing tool is reported to whoever asked, with how to get it.
---
--- Installing replaces Resources/Server/BeamJoyServer, Resources/Server/BeamJoyServerHooks and
--- Resources/Client/BJ.zip (the previous ones are moved to BeamJoyData/update/backup-...; if any
--- can't be moved, everything goes back). BeamJoyData (races, players, settings...) is never
--- touched. The new version runs once the server restarts ; players get the new BJ.zip when they
--- join after that. Downloads only ever come from this project's own repository.

local M = {
    dependencies = { "services_lang", "services_chat", "services_chatCommands", "services_consoleCommands",
        "services_players" },

    REPO = "foodcache3/BeamJoy-Revived",
    BRANCH = "development",
    CHANNELS = { release = true, development = true },
    --- seconds between automatic checks, and before the first one
    CHECK_INTERVAL = 6 * 3600,
    FIRST_CHECK_DELAY = 60,
    --- seconds a background job may take
    CHECK_TIMEOUT = 60,
    INSTALL_TIMEOUT = 600,

    ---@type BJUpdate? the latest version found, once checked
    latest = nil,
    ---@type {startedAt: integer, timeout: integer, onDone: fun(status: string)}? the running background job
    job = nil,
    nextCheckAt = 0,
    --- owners told since they joined : playerID -> what they were told about (a version's label, or
    --- "restart:" .. the installed one's). Forgotten when they leave, so every join tells them again
    ---@type table<integer, string>
    told = {},
    --- how long the in-game notification stays (ms)
    NOTIFY_TOAST_MS = 15000,
    --- a version installed while running (its label) : the server needs a restart
    ---@type string?
    installed = nil,
    --- tools found (a missing one is looked for again next time, in case it was installed since)
    ---@type table<string, true>
    tools = {},
    --- the automatic check warned about a missing curl already
    warnedNoCurl = false,
    ---@type {channel: "release"|"development", sha: string?}? state.json, once read
    state = nil,
}

---@class BJUpdate
---@field channel "release"|"development"
---@field label string what messages call it : "1.12.0", or "development build abc1234"
---@field version string? a release's version
---@field sha string? a development build's commit
---@field url string? where to download it
---@field newer boolean newer than what this server has

local CONSOLE = "console"

-- PATHS, TOOLS ---------------------------------------------------------------------------------------

---@return boolean
local function isWindows()
    return package.config:sub(1, 1) == "\\"
end

---@param path string
---@return string
local function parent(path)
    return path:match("^(.*)/[^/]+$") or path
end

---@return {work: string, server: string, hooks: string, clientZip: string}
local function paths()
    local serverRoot = parent(BJSPluginPath)
    return {
        work = serverRoot .. "/BeamJoyData/update",
        server = BJSPluginPath,
        hooks = serverRoot .. "/BeamJoyServerHooks",
        clientZip = parent(serverRoot) .. "/Client/BJ.zip",
    }
end

--- an argument quoted for the script's shell
---@param s string
---@return string
local function q(s)
    if isWindows() then return '"' .. s .. '"' end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- a path quoted for the script's shell (Windows' own separators there)
---@param s string
---@return string
local function qp(s)
    if isWindows() then return q((s:gsub("/", "\\"))) end
    return q(s)
end

local TOOL_PROBES = {
    curl = function() return "curl --version" end,
    powershell = function() return "powershell -NoProfile -NonInteractive -Command exit" end,
    unzip = function() return "unzip -v" end,
    zip = function() return "zip -v" end,
}

--- PowerShell (Windows) : .NET's own zip support, the way the mod analyzer does it (FS.ExtractTo)
local PS_PREFIX = 'powershell -NoProfile -NonInteractive -Command "try { ' ..
    'Add-Type -AssemblyName System.IO.Compression.FileSystem; '
local PS_SUFFIX = ' } catch { exit 1 }"'
--- pkg.zip -> extract/
local WINDOWS_UNZIP = PS_PREFIX ..
    "[IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $PWD 'pkg.zip'), (Join-Path $PWD 'extract'))" ..
    PS_SUFFIX
--- extract/<the branch's folder>/BeamJoyClient -> BJ.zip (its contents at the zip's root)
local WINDOWS_BUILD_CLIENT = PS_PREFIX ..
    "$root = Get-ChildItem extract -Directory | Select-Object -First 1; " ..
    "if (Test-Path BJ.zip) { Remove-Item BJ.zip }; " ..
    "[IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $root.FullName 'BeamJoyClient'), (Join-Path $PWD 'BJ.zip'))" ..
    PS_SUFFIX

---@param name string
---@return boolean
local function hasTool(name)
    if M.tools[name] then return true end
    local probe = TOOL_PROBES[name]() .. (isWindows() and " >NUL 2>&1" or " >/dev/null 2>&1")
    local ok, r = pcall(os.execute, probe)
    if ok and (r == true or r == 0) then
        M.tools[name] = true
        return true
    end
    return false
end

---@param install boolean
---@param channel string
---@return string[] missing tools
local function missingTools(install, channel)
    local needed = { "curl" }
    if install then
        if isWindows() then
            needed[#needed + 1] = "powershell"
        else
            needed[#needed + 1] = "unzip"
            if channel == "development" then needed[#needed + 1] = "zip" end
        end
    end
    local missing = {}
    for _, name in ipairs(needed) do
        if not hasTool(name) then missing[#missing + 1] = name end
    end
    return missing
end

-- STATE -----------------------------------------------------------------------------------------------

---@return {channel: "release"|"development", sha: string?}
local function state()
    if not M.state then
        local file = io.open(paths().work .. "/state.json", "r")
        local raw = file and file:read("*a")
        if file then file:close() end
        -- no file yet (never switched channel nor installed) : the defaults, without handing the
        -- JSON reader nothing (it logs a warning for that)
        local ok, data = false, nil
        if type(raw) == "string" and #raw > 0 then ok, data = pcall(utils_json.parse, raw) end
        data = ok and type(data) == "table" and data or {}
        M.state = {
            channel = M.CHANNELS[data.channel] and data.channel or "release",
            sha = type(data.sha) == "string" and data.sha:match("^%x+$") and data.sha or nil,
        }
    end
    return M.state
end

local function saveState()
    local p = paths()
    if not FS.Exists(p.work) then FS.CreateDirectory(p.work) end
    local file = io.open(p.work .. "/state.json", "w")
    if not file then return LogError("BeamJoy update : couldn't save " .. p.work .. "/state.json") end
    file:write(utils_json.stringify(state()))
    file:close()
end

-- MESSAGES ---------------------------------------------------------------------------------------------

---@param requester integer|string|nil
---@return string? lang
local function langOf(requester)
    if type(requester) ~= "number" then return nil end
    local player = services_players.players:find(function(p) return p.playerID == requester end)
    return player and player.lang
end

--- tells whoever asked : the console, a player (in their language), or nobody (an automatic check :
--- errors go to the console log)
---@param requester integer|string|nil playerID, CONSOLE, or nil
---@param key string
---@param vars table?
---@param isError boolean?
local function reply(requester, key, vars, isError)
    if requester == nil then
        if isError then LogWarn("BeamJoy update : " .. services_lang.get(key):var(vars or {})) end
        return
    end
    if requester == CONSOLE then
        local text = services_lang.get(key):var(vars or {})
        if isError then LogWarn(text) else LogInfo(text) end
        return
    end
    local player = services_players.players:find(function(p) return p.playerID == requester end)
    if not player then return end
    services_chat.directSend(requester, services_lang.get(key, player.lang):var(vars or {}),
        isError and services_chat.COLORS.ERROR or nil)
end

---@param requester integer|string|nil
---@param missing string[]
---@param install boolean
local function reportMissingTools(requester, missing, install)
    local lang = langOf(requester)
    for _, tool in ipairs(missing) do
        local hint = string.format("update.tool.%s.%s", tool, isWindows() and "windows" or "linux")
        reply(requester, "update.toolMissing", {
            action = services_lang.get(install and "update.action.install" or "update.action.check", lang),
            tool = tool,
            hint = services_lang.get(hint, lang),
        }, true)
    end
end

---@param requester integer|string|nil
---@param channel string
---@return string
local function channelName(requester, channel)
    return services_lang.get("update.channel." .. channel, langOf(requester))
end

-- VERSIONS -------------------------------------------------------------------------------------------

---@param serverPath string? a BeamJoyServer folder, this one by default
---@return string
local function versionIn(serverPath)
    local file = io.open((serverPath or BJSPluginPath) .. "/version", "r")
    if not file then return "0.0.0" end
    local v = file:read("*a"):gsub("%s", "")
    file:close()
    return v
end

---@param v string
---@return integer[]?
local function parseVersion(v)
    local a, b, c = tostring(v or ""):match("^v?(%d+)%.(%d+)%.(%d+)")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
end

---@param a string
---@param b string
---@return boolean a is newer than b
local function isNewer(a, b)
    local pa, pb = parseVersion(a), parseVersion(b)
    if not pa or not pb then return false end
    for i = 1, 3 do
        if pa[i] ~= pb[i] then return pa[i] > pb[i] end
    end
    return false
end

-- BACKGROUND JOBS -----------------------------------------------------------------------------------

--- runs a shell script in the background ; its last act writes a status word to job.done
---@param windowsLines string[]
---@param shLines string[]
---@param timeout integer seconds
---@param onDone fun(status: string) "ok", a failed step's name, or "timeout"
local function runJob(windowsLines, shLines, timeout, onDone)
    local p = paths()
    if not FS.Exists(p.work) then FS.CreateDirectory(p.work) end
    local donePath = p.work .. "/job.done"
    if FS.Exists(donePath) then FS.Remove(donePath) end
    local scriptPath = p.work .. (isWindows() and "/job.bat" or "/job.sh")
    local file = io.open(scriptPath, "w")
    if not file then
        return onDone("script")
    end
    local lines = isWindows() and windowsLines or shLines
    local header = isWindows() and { "@echo off", "cd /d " .. qp(p.work) } or { "cd " .. qp(p.work) .. " || exit 1" }
    file:write(table.concat(header, "\n") .. "\n" .. table.concat(lines, "\n") .. "\n")
    file:close()
    M.job = { startedAt = GetCurrentTime(), timeout = timeout, onDone = onDone }
    if isWindows() then
        os.execute('start "" /b cmd /c ' .. qp(scriptPath) .. " >NUL 2>&1")
    else
        os.execute("sh " .. qp(scriptPath) .. " >/dev/null 2>&1 &")
    end
end

local function pollJob()
    local job = M.job
    if not job then return end
    local file = io.open(paths().work .. "/job.done", "r")
    local status = file and file:read("*a"):match("%a+")
    if file then file:close() end
    if not status and GetCurrentTime() - job.startedAt > job.timeout then status = "timeout" end
    if status then
        M.job = nil
        local ok, err = pcall(job.onDone, status)
        if not ok then LogError("BeamJoy update failed : " .. tostring(err)) end
    end
end

-- CHECK ------------------------------------------------------------------------------------------------

--- the latest release (from GitHub's releases/latest answer)
---@param data table
---@return BJUpdate?
local function readRelease(data)
    if not parseVersion(data.tag_name) then return nil end
    local version = tostring(data.tag_name):gsub("^v", "")
    local found = { channel = "release", label = version, version = version,
        newer = isNewer(version, versionIn()) }
    local want = string.format("BeamJoy-Revived-%s.zip", version)
    -- only this repository's own downloads, with nothing a shell would read
    local prefix = string.format("https://github.com/%s/releases/download/", M.REPO)
    for _, asset in ipairs(type(data.assets) == "table" and data.assets or {}) do
        local url = type(asset) == "table" and asset.browser_download_url
        if asset.name == want and type(url) == "string" and url:sub(1, #prefix) == prefix and
            url:match("^[%w%.%-_/:]+$") then
            found.url = url
        end
    end
    return found
end

--- the development branch's latest commit (from GitHub's commits/<branch> answer)
---@param data table
---@return BJUpdate?
local function readBuild(data)
    local sha = type(data.sha) == "string" and data.sha:match("^%x+$") and #data.sha == 40 and data.sha
    if not sha then return nil end
    return {
        channel = "development",
        label = "development build " .. sha:sub(1, 7),
        sha = sha,
        -- that exact commit, so what's installed is what was checked
        url = string.format("https://github.com/%s/archive/%s.zip", M.REPO, sha),
        newer = sha ~= state().sha,
    }
end

---@param requester integer|string|nil
---@param onNewer fun(found: BJUpdate)? called with a newer version, instead of telling about it
local function check(requester, onNewer)
    if M.job then return reply(requester, "update.busy", nil, true) end
    local channel = state().channel
    local missing = missingTools(false, channel)
    if #missing > 0 then
        if requester == nil then
            if not M.warnedNoCurl then
                M.warnedNoCurl = true
                reportMissingTools(CONSOLE, missing, false)
            end
            return
        end
        return reportMissingTools(requester, missing, false)
    end
    local api = channel == "development" and
        string.format("https://api.github.com/repos/%s/commits/%s", M.REPO, M.BRANCH) or
        string.format("https://api.github.com/repos/%s/releases/latest", M.REPO)
    local curl = "curl -s -L --fail --max-time 30 -H " .. q("User-Agent: BeamJoy-Server") ..
        " -o latest.json " .. q(api)
    runJob({
        "if exist latest.json del /q latest.json",
        curl,
        "if errorlevel 1 (echo download> job.done) else (echo ok> job.done)",
    }, {
        "rm -f latest.json",
        "if " .. curl .. "; then echo ok > job.done; else echo download > job.done; fi",
    }, M.CHECK_TIMEOUT, function(status)
        local found
        if status == "ok" then
            local file = io.open(paths().work .. "/latest.json", "r")
            local raw = file and file:read("*a")
            if file then file:close() end
            local ok, data = false, nil
            if type(raw) == "string" and #raw > 0 then ok, data = pcall(utils_json.parse, raw) end
            if ok and type(data) == "table" then
                found = channel == "development" and readBuild(data) or readRelease(data)
            end
        end
        if not found then
            return reply(requester, "update.checkFailed", nil, true)
        end
        M.latest = found
        local current = versionIn()
        if found.newer then
            if onNewer then return onNewer(found) end
            -- an automatic check : the console hears it (owners online, see tellOwners)
            local key = type(requester) == "number" and "update.available" or "update.availableConsole"
            reply(requester or CONSOLE, key, { version = found.label, current = current })
        elseif channel == "development" then
            reply(requester, "update.upToDateBuild", { version = found.label })
        else
            reply(requester, "update.upToDate", { current = current })
        end
    end)
end

-- INSTALL ----------------------------------------------------------------------------------------------

---@param path string
---@return boolean
local function isFile(path)
    local file = io.open(path, "r")
    if file then file:close() end
    return file ~= nil
end

--- moves `from` to `to` (a folder or a file), replacing nothing
---@param from string
---@param to string
---@return boolean
local function move(from, to)
    local ok, res = pcall(FS.Rename, from, to)
    return ok and res ~= false and FS.Exists(to) and not FS.Exists(from)
end

--- where the downloaded copies are, once unpacked
---@param found BJUpdate
---@return {server: string, hooks: string, clientZip: string}
local function unpacked(found)
    local work = paths().work
    if found.channel == "release" then
        return {
            server = work .. "/extract/Server/BeamJoyServer",
            hooks = work .. "/extract/Server/BeamJoyServerHooks",
            clientZip = work .. "/extract/Client/BJ.zip",
        }
    end
    -- a branch archive holds one folder, the repository's sources (BJ.zip was built from them)
    local root
    local ok, dirs = pcall(FS.ListDirectories, work .. "/extract")
    if ok and type(dirs) == "table" then
        for _, d in pairs(dirs) do root = root or d end
    end
    root = work .. "/extract/" .. (root or (M.REPO:match("[^/]+$") .. "-" .. found.sha))
    return {
        server = root .. "/BeamJoyServer",
        hooks = root .. "/BeamJoyServerHooks",
        clientZip = work .. "/BJ.zip",
    }
end

--- swaps the downloaded copies in : each current copy goes to the backup folder first, and if a
--- step fails, everything moved so far goes back
---@param found BJUpdate
---@return boolean ok, string? backup folder, or why it failed
local function applyUpdate(found)
    local p = paths()
    local new = unpacked(found)
    if not isFile(new.server .. "/BeamJoyServer.lua") or not isFile(new.clientZip) then
        return false, "the download doesn't have BeamJoyServer and BJ.zip"
    end
    if found.channel == "release" and versionIn(new.server) ~= found.version then
        return false, string.format("the package holds version %s, not %s", versionIn(new.server), found.version)
    end

    local backup = string.format("%s/backup-%s-%d", p.work, versionIn(), GetCurrentTime())
    FS.CreateDirectory(backup)
    if not FS.Exists(parent(p.clientZip)) then FS.CreateDirectory(parent(p.clientZip)) end
    local steps = {
        { current = p.server, new = new.server, saved = backup .. "/BeamJoyServer" },
        { current = p.hooks, new = new.hooks, saved = backup .. "/BeamJoyServerHooks", optional = true },
        { current = p.clientZip, new = new.clientZip, saved = backup .. "/BJ.zip" },
    }
    local done = {}
    local function rollBack()
        for i = #done, 1, -1 do
            local s = done[i]
            if s.placed then move(s.current, s.new) end
            if s.moved then move(s.saved, s.current) end
        end
    end
    for _, s in ipairs(steps) do
        if not (s.optional and not FS.Exists(s.new)) then
            local entry = { current = s.current, new = s.new, saved = s.saved }
            done[#done + 1] = entry
            if FS.Exists(s.current) then
                if not move(s.current, s.saved) then
                    rollBack()
                    return false, "couldn't move " .. s.current .. " (is a file open?)"
                end
                entry.moved = true
            end
            if not move(s.new, s.current) then
                rollBack()
                return false, "couldn't put the new " .. s.current .. " in place"
            end
            entry.placed = true
        end
    end
    return true, backup
end

---@param requester integer|string
---@param found BJUpdate
local function download(requester, found)
    if not found.url then
        return reply(requester, "update.noPackage", { version = found.label }, true)
    end
    reply(requester, "update.downloading", { version = found.label })
    local dev = found.channel == "development"
    local curl = "curl -s -L --fail --max-time 300 -o pkg.zip " .. q(found.url)
    local windows = {
        "if exist extract rmdir /s /q extract",
        "if exist pkg.zip del /q pkg.zip",
        "if exist BJ.zip del /q BJ.zip",
        curl,
        "if errorlevel 1 (echo download> job.done & exit /b)",
        WINDOWS_UNZIP,
        "if errorlevel 1 (echo extract> job.done & exit /b)",
    }
    local sh = {
        "rm -rf extract pkg.zip BJ.zip",
        "if ! " .. curl .. "; then echo download > job.done; exit 0; fi",
        "mkdir extract",
        "if ! unzip -q -o pkg.zip -d extract; then echo extract > job.done; exit 0; fi",
    }
    if dev then
        windows[#windows + 1] = WINDOWS_BUILD_CLIENT
        windows[#windows + 1] = "if errorlevel 1 (echo package> job.done & exit /b)"
        sh[#sh + 1] = 'root=$(ls -d extract/*/ | head -n 1)'
        sh[#sh + 1] = 'if ! (cd "${root}BeamJoyClient" && zip -q -r ../../../BJ.zip .); then echo package > job.done; exit 0; fi'
    end
    windows[#windows + 1] = "echo ok> job.done"
    sh[#sh + 1] = "echo ok > job.done"
    runJob(windows, sh, M.INSTALL_TIMEOUT, function(status)
        if status ~= "ok" then
            local key = ({ download = "update.downloadFailed", extract = "update.extractFailed",
                package = "update.packageFailed", timeout = "update.timeout" })[status] or "update.downloadFailed"
            return reply(requester, key, { version = found.label }, true)
        end
        local ok, info = applyUpdate(found)
        if not ok then
            return reply(requester, "update.installFailed", { version = found.label, reason = info }, true)
        end
        M.installed = found.label
        -- a development build is told apart by its commit ; a release clears it
        state().sha = found.sha
        saveState()
        local vars = { version = found.label, backup = info, number = versionIn() }
        local key = dev and "update.installedBuild" or "update.installed"
        reply(requester, key, vars)
        if requester ~= CONSOLE then reply(CONSOLE, key, vars) end
        -- every owner online hears it, not only the one who asked (and isn't reminded to restart on
        -- top of it : owners joining later are, see tellOwners)
        services_players.players:forEach(function(p)
            if p.group == "owner" then
                M.told[p.playerID] = "restart:" .. found.label
                if p.playerID ~= requester then reply(p.playerID, key, vars) end
            end
        end)
    end)
end

---@param requester integer|string
local function install(requester)
    if M.installed then
        return reply(requester, "update.restartNeeded", { version = M.installed }, true)
    end
    if M.job then return reply(requester, "update.busy", nil, true) end
    local missing = missingTools(true, state().channel)
    if #missing > 0 then return reportMissingTools(requester, missing, true) end
    reply(requester, "update.checking")
    check(requester, function(found) download(requester, found) end)
end

---@param requester integer|string
---@param channel string?
local function setChannel(requester, channel)
    channel = channel and channel:lower()
    if channel == "dev" then channel = "development" end
    if not channel then
        return reply(requester, "update.channel.current", { channel = channelName(requester, state().channel) })
    end
    if not M.CHANNELS[channel] then return reply(requester, "update.usage", nil, true) end
    if M.job then return reply(requester, "update.busy", nil, true) end
    state().channel = channel
    saveState()
    M.latest = nil
    M.told = {}
    reply(requester, "update.channel.set", { channel = channelName(requester, channel) })
end

-- COMMANDS --------------------------------------------------------------------------------------------

---@param requester integer|string
---@param args string[]
local function command(requester, args)
    local arg = args[1] and args[1]:lower()
    if arg == "check" then
        if M.installed then return reply(requester, "update.restartNeeded", { version = M.installed }, true) end
        reply(requester, "update.checking")
        check(requester)
    elseif arg == nil or arg == "install" then
        install(requester)
    elseif arg == "channel" then
        setChannel(requester, args[2])
    else
        reply(requester, "update.usage", nil, true)
    end
end

--- owners only : installing software on the server machine isn't something a permission edit
--- should hand out
---@param ctxt BJSContext
---@return boolean
local function chatValidate(ctxt)
    if ctxt.sender and ctxt.sender.group == "owner" then return true end
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.error.noPermission", ctxt.sender and ctxt.sender.lang),
        services_chat.COLORS.ERROR)
    return false
end

---@param ctxt BJSContext
---@param args string[]
local function chatCommand(ctxt, args)
    command(ctxt.senderID, args)
end

---@param args string[]
local function consoleCommand(args)
    command(CONSOLE, args)
end

-- HOOKS -------------------------------------------------------------------------------------------------

--- an owner hears it in game : a notification on screen (direct request) and the same in chat
---@param p BJSPlayer
---@param key string
---@param vars table
local function notifyOwner(p, key, vars)
    reply(p.playerID, key, vars)
    communications_tx.sendToPlayer(p.playerID, "toast", "info",
        services_lang.get(key, p.lang):var(vars), M.NOTIFY_TOAST_MS,
        services_lang.get("update.toastTitle", p.lang))
end

--- every owner, each time they join (or become owner), hears about a newer version, or about an
--- installed one waiting for a restart
local function tellOwners()
    local key, vars, subject
    if M.installed then
        key, vars, subject = "update.restartNeeded", { version = M.installed }, "restart:" .. M.installed
    elseif M.latest and M.latest.newer then
        key, vars, subject = "update.available", { version = M.latest.label, current = versionIn() }, M.latest.label
    else
        return
    end
    services_players.players:forEach(function(p)
        if p.group == "owner" and p.ready and M.told[p.playerID] ~= subject then
            M.told[p.playerID] = subject
            notifyOwner(p, key, vars)
        end
    end)
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.told[playerID] = nil
end

local function onSlowUpdate()
    pollJob()
    local now = GetCurrentTime()
    if not M.job and not M.installed and now >= M.nextCheckAt then
        M.nextCheckAt = now + M.CHECK_INTERVAL
        check(nil)
    end
    tellOwners()
end

local function onInit()
    M.nextCheckAt = GetCurrentTime() + M.FIRST_CHECK_DELAY
    services_chatCommands.addCommand("bjupdate", "chat.command.bjupdate.desc", chatCommand, {
        commandKey = "chat.command.bjupdate.command",
        permissions = { BJ_PERMISSIONS.SetCore },
        validate = chatValidate,
    })
    services_consoleCommands.register("update", "commands.bjupdate.args", "commands.bjupdate.desc", consoleCommand)
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate
M.onPlayerDisconnect = onPlayerDisconnect

M.isNewer = isNewer
M.command = command

return M
