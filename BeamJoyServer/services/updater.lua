--- BeamJoy updates from GitHub (direct request) : the server checks for a new release by itself and
--- tells its owners, and an owner (chat /bjupdate) or the server console (bj update) installs it.
---
--- BeamMP's plugin Lua has no HTTP client, so the GitHub requests go through `curl` (built into
--- Windows 10 1803+), and the package is unpacked the way the mod analyzer does it (PowerShell's
--- .NET zip support on Windows, `unzip` on Linux), each run as a small script in the background :
--- the server thread never waits on them, the result is picked up once a second (onSlowUpdate). A
--- missing tool is reported to whoever asked, with how to get it.
---
--- Installing replaces Resources/Server/BeamJoyServer, Resources/Server/BeamJoyServerHooks and
--- Resources/Client/BJ.zip with the release's copies (the previous ones are moved to
--- BeamJoyData/update/backup-<version>). BeamJoyData (races, players, settings...) is never
--- touched. The new version runs once the server restarts ; players get the new BJ.zip when they
--- join after that.
---
--- Only releases carrying the package BeamJoy publishes (BeamJoy-Revived-<version>.zip, with the
--- Server/ and Client/ folders) can be installed, and only from this project's own repository.

local M = {
    dependencies = { "services_lang", "services_chat", "services_chatCommands", "services_consoleCommands",
        "services_players" },

    REPO = "foodcache3/BeamJoy-Revived",
    --- seconds between automatic checks, and before the first one
    CHECK_INTERVAL = 6 * 3600,
    FIRST_CHECK_DELAY = 60,
    --- seconds a background job may take
    CHECK_TIMEOUT = 60,
    INSTALL_TIMEOUT = 600,

    ---@type {version: string, assetUrl: string?}? the latest release, once checked
    latest = nil,
    ---@type {startedAt: integer, timeout: integer, onDone: fun(status: string)}? the running background job
    job = nil,
    nextCheckAt = 0,
    --- owners already told about a version : playerName -> version
    ---@type table<string, string>
    told = {},
    --- a version installed while running : the server needs a restart
    ---@type string?
    installed = nil,
    --- tools found (a missing one is looked for again next time, in case it was installed since)
    ---@type table<string, true>
    tools = {},
    --- the automatic check warned about a missing curl already
    warnedNoCurl = false,
}

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
}

--- unpacks pkg.zip into extract/ on Windows : .NET's own zip support through PowerShell, the same
--- way the mod analyzer does (FS.ExtractTo), in the background script
local WINDOWS_UNZIP = 'powershell -NoProfile -NonInteractive -Command "try { ' ..
    'Add-Type -AssemblyName System.IO.Compression.FileSystem; ' ..
    "[IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $PWD 'pkg.zip'), (Join-Path $PWD 'extract')) " ..
    '} catch { exit 1 }"'

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
---@return string[] missing tools
local function missingTools(install)
    local needed = { "curl" }
    if install then needed[2] = isWindows() and "powershell" or "unzip" end
    local missing = {}
    for _, name in ipairs(needed) do
        if not hasTool(name) then missing[#missing + 1] = name end
    end
    return missing
end

-- MESSAGES ---------------------------------------------------------------------------------------------

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
    for _, tool in ipairs(missing) do
        local hint = string.format("update.tool.%s.%s", tool, isWindows() and "windows" or "linux")
        local lang = nil
        if type(requester) == "number" then
            local player = services_players.players:find(function(p) return p.playerID == requester end)
            lang = player and player.lang
        end
        reply(requester, "update.toolMissing", {
            action = services_lang.get(install and "update.action.install" or "update.action.check", lang),
            tool = tool,
            hint = services_lang.get(hint, lang),
        }, true)
    end
end

-- VERSIONS -------------------------------------------------------------------------------------------

---@return string
local function currentVersion()
    local file = io.open(BJSPluginPath .. "/version", "r")
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

---@param requester integer|string|nil
---@param onLatest fun(latest: {version: string, assetUrl: string?})? called with a newer release
local function check(requester, onLatest)
    if M.job then return reply(requester, "update.busy", nil, true) end
    local missing = missingTools(false)
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
    local api = string.format("https://api.github.com/repos/%s/releases/latest", M.REPO)
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
        local release
        if status == "ok" then
            local file = io.open(paths().work .. "/latest.json", "r")
            local raw = file and file:read("*a")
            if file then file:close() end
            local ok, data = pcall(utils_json.parse, raw)
            if ok and type(data) == "table" and parseVersion(data.tag_name) then
                release = { version = tostring(data.tag_name):gsub("^v", "") }
                local want = string.format("BeamJoy-Revived-%s.zip", release.version)
                -- only this repository's own downloads, with nothing a shell would read
                local prefix = string.format("https://github.com/%s/releases/download/", M.REPO)
                for _, asset in ipairs(type(data.assets) == "table" and data.assets or {}) do
                    local url = type(asset) == "table" and asset.browser_download_url
                    if asset.name == want and type(url) == "string" and url:sub(1, #prefix) == prefix and
                        url:match("^[%w%.%-_/:]+$") then
                        release.assetUrl = url
                    end
                end
            end
        end
        if not release then
            return reply(requester, "update.checkFailed", nil, true)
        end
        M.latest = release
        local current = currentVersion()
        if isNewer(release.version, current) then
            if onLatest then return onLatest(release) end
            -- an automatic check : the console hears it (owners online, see tellOwners)
            local key = type(requester) == "number" and "update.available" or "update.availableConsole"
            reply(requester or CONSOLE, key, { version = release.version, current = current })
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

--- swaps the extracted release in : each current copy goes to the backup folder first, and if a
--- step fails, everything moved so far goes back
---@param release {version: string}
---@return boolean ok, string? reason
local function applyUpdate(release)
    local p = paths()
    local extracted = p.work .. "/extract"
    local new = {
        server = extracted .. "/Server/BeamJoyServer",
        hooks = extracted .. "/Server/BeamJoyServerHooks",
        clientZip = extracted .. "/Client/BJ.zip",
    }
    if not isFile(new.server .. "/BeamJoyServer.lua") or not isFile(new.clientZip) then
        return false, "the package doesn't have Server/BeamJoyServer and Client/BJ.zip"
    end
    local file = io.open(new.server .. "/version", "r")
    local newVersion = file and file:read("*a"):gsub("%s", "")
    if file then file:close() end
    if newVersion ~= release.version then
        return false, string.format("the package holds version %s, not %s", tostring(newVersion), release.version)
    end

    local backup = string.format("%s/backup-%s-%d", p.work, currentVersion(), GetCurrentTime())
    FS.CreateDirectory(backup)
    if not FS.Exists(p.clientZip:match("^(.*)/[^/]+$")) then
        FS.CreateDirectory(p.clientZip:match("^(.*)/[^/]+$"))
    end
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
---@param release {version: string, assetUrl: string?}
local function download(requester, release)
    if not release.assetUrl then
        return reply(requester, "update.noPackage", { version = release.version }, true)
    end
    reply(requester, "update.downloading", { version = release.version })
    local curl = "curl -s -L --fail --max-time 300 -o pkg.zip " .. q(release.assetUrl)
    runJob({
        "if exist extract rmdir /s /q extract",
        "if exist pkg.zip del /q pkg.zip",
        curl,
        "if errorlevel 1 (echo download> job.done & exit /b)",
        WINDOWS_UNZIP,
        "if errorlevel 1 (echo extract> job.done & exit /b)",
        "echo ok> job.done",
    }, {
        "rm -rf extract pkg.zip",
        "if ! " .. curl .. "; then echo download > job.done; exit 0; fi",
        "mkdir extract",
        "if ! unzip -q -o pkg.zip -d extract; then echo extract > job.done; exit 0; fi",
        "echo ok > job.done",
    }, M.INSTALL_TIMEOUT, function(status)
        if status ~= "ok" then
            local key = ({ download = "update.downloadFailed", extract = "update.extractFailed",
                timeout = "update.timeout" })[status] or "update.downloadFailed"
            return reply(requester, key, { version = release.version }, true)
        end
        local ok, info = applyUpdate(release)
        if not ok then
            return reply(requester, "update.installFailed", { version = release.version, reason = info }, true)
        end
        M.installed = release.version
        local vars = { version = release.version, backup = info }
        reply(requester, "update.installed", vars)
        if requester ~= CONSOLE then reply(CONSOLE, "update.installed", vars) end
        -- every owner online hears it, not only the one who asked
        services_players.players:forEach(function(p)
            if p.group == "owner" and p.playerID ~= requester then reply(p.playerID, "update.installed", vars) end
        end)
    end)
end

---@param requester integer|string
local function install(requester)
    if M.installed then
        return reply(requester, "update.restartNeeded", { version = M.installed }, true)
    end
    if M.job then return reply(requester, "update.busy", nil, true) end
    local missing = missingTools(true)
    if #missing > 0 then return reportMissingTools(requester, missing, true) end
    reply(requester, "update.checking")
    check(requester, function(release) download(requester, release) end)
end

-- COMMANDS --------------------------------------------------------------------------------------------

---@param requester integer|string
---@param arg string?
local function command(requester, arg)
    arg = arg and arg:lower()
    if arg == "check" then
        if M.installed then return reply(requester, "update.restartNeeded", { version = M.installed }, true) end
        reply(requester, "update.checking")
        check(requester)
    elseif arg == nil or arg == "install" then
        install(requester)
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
    command(ctxt.senderID, args[1])
end

---@param args string[]
local function consoleCommand(args)
    command(CONSOLE, args[1])
end

-- HOOKS -------------------------------------------------------------------------------------------------

--- owners online (and joining) hear about a newer release once each
local function tellOwners()
    if not M.latest or M.installed or not isNewer(M.latest.version, currentVersion()) then return end
    services_players.players:forEach(function(p)
        if p.group == "owner" and p.ready and M.told[p.playerName] ~= M.latest.version then
            M.told[p.playerName] = M.latest.version
            reply(p.playerID, "update.available", { version = M.latest.version, current = currentVersion() })
        end
    end)
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

M.isNewer = isNewer
M.command = command

return M
