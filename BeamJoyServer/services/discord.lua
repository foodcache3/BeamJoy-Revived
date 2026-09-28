--- Posts server activity straight to Discord webhooks, no companion plugin needed. A server can
--- set up several (a results channel, a staff channel...), each with its own choice of posts.
---
--- BeamMP's plugin Lua has no HTTP client, so each post is handed to `curl` (built into Windows 10
--- 1803+ and virtually every Linux distribution) as a detached background process: the server
--- thread never waits on Discord. The JSON body goes through a small file (never the command line,
--- so no quoting or codepage issues), and the webhook URL is validated against Discord's own shape
--- before it's ever saved, which is also what keeps it safe to put on that command line.
---
--- Posts are queued and spaced out per webhook (Discord allows about 30 a minute per webhook), and
--- each queue is capped so a burst can't pile up forever.

local M = {
    dependencies = { "services_config", "services_lang" },

    ---@type table<string, {items: table[], nextSendAt: integer}> webhook URL -> pending bodies
    queues = {},
    fileSlot = 0,
    ---@type boolean? nil = not checked yet
    curlAvailable = nil,
}

local SEND_SPACING_SEC = 2
local QUEUE_MAX = 40
local WEBHOOKS_MAX = 10
-- what each webhook can post, and the default for a new one. Activity posts added later default
-- off, so a webhook saved before they existed doesn't suddenly start posting them
local TOGGLES = {
    RaceFinishes = true, RacePBsOnly = false, Votes = true, JoinLeave = false, Chat = false,
    Deliveries = false, Hunter = false, Infected = false, BusLines = false,
}
-- files are reused round-robin: by the time a slot comes back around (FILE_SLOTS * SEND_SPACING_SEC
-- seconds later) the curl that read it has long finished
local FILE_SLOTS = 32
local CURL_TIMEOUT_SEC = 15

local COLORS = {
    RECORD = 0xF2B632,
    PB = 0x3FB950,
    FINISH = 0x4C8DFF,
    VOTE = 0x9B7BFF,
    JOIN = 0x5C6470,
    DELIVERY = 0x2EB8A6,
    HUNTER = 0xE8743B,
    INFECTED = 0x8BC34A,
    BUS = 0xF5C518,
}

local WEBHOOK_HOSTS = {
    "discord.com", "ptb.discord.com", "canary.discord.com", "discordapp.com",
}

---@param url any
---@return boolean
local function isValidWebhook(url)
    if type(url) ~= "string" then return false end
    for _, host in ipairs(WEBHOOK_HOSTS) do
        local prefix = "https://" .. host .. "/api/webhooks/"
        if url:sub(1, #prefix) == prefix and url:sub(#prefix + 1):match("^%d+/[%w_%-]+$") then
            return true
        end
    end
    return false
end

---@class BJDiscordWebhook
---@field Name string
---@field Url string
---@field RaceFinishes boolean
---@field RacePBsOnly boolean
---@field Votes boolean
---@field JoinLeave boolean
---@field Chat boolean

--- the saved webhooks. A config from before several webhooks existed held one URL and its
--- toggles directly in the Discord table : that becomes the first (only) webhook
---@return BJDiscordWebhook[]
local function webhooks()
    local d = services_config.data.Discord
    if type(d) ~= "table" then return {} end
    if type(d.Webhooks) ~= "table" then
        local list = {}
        if type(d.WebhookUrl) == "string" and #d.WebhookUrl > 0 then
            local hook = { Name = "Discord", Url = d.WebhookUrl }
            for key, default in pairs(TOGGLES) do
                if type(d[key]) == "boolean" then hook[key] = d[key] else hook[key] = default end
            end
            list[1] = hook
        end
        services_config.data.Discord = { Webhooks = list }
        d = services_config.data.Discord
    end
    return d.Webhooks
end

---@param key string
---@param vars table<string, any>?
---@return string
local function tr(key, vars)
    local text = services_lang.get(key, services_config.data.DiscordChatHookLang)
    if vars then
        -- plain function replacement: player names can hold "%", which gsub's string form mangles
        text = text:gsub("{(%w+)}", function(name)
            local v = vars[name]
            return v ~= nil and tostring(v) or nil
        end)
    end
    return text
end

--- player-supplied text : no control characters (the JSON encoder doesn't escape them all), and
--- no pinging @everyone/@here or anyone else
---@param text any
---@return string
local function clean(text)
    text = tostring(text or ""):gsub("[%z\1-\8\11\12\14-\31]", "")
    return (text:gsub("@", "@\226\128\139")) -- zero-width space after every @
end

--- BeamMP names and server names can carry ^-color codes
---@param text string
---@return string
local function stripCodes(text)
    return (tostring(text or ""):gsub("%^[%da-fk-orA-FK-OR]", ""))
end

--- Discord refuses a whole post whose webhook username holds "discord" or "clyde", or is empty
---@param name any
---@return string
local function username(name)
    name = clean(stripCodes(name)):gsub("[Dd][Ii][Ss][Cc][Oo][Rr][Dd]", "Dscrd")
        :gsub("[Cc][Ll][Yy][Dd][Ee]", "Clyd"):trim():sub(1, 80)
    return #name > 0 and name or "BeamJoy"
end

---@return string
local function serverName()
    return username(services_core and services_core.data and services_core.data.Name or "BeamJoy")
end

--- the current map's display name
---@return string
local function mapLabel()
    local map = services_core and services_core.getCurrentMap and services_core.getCurrentMap() or ""
    local entry = services_maps and services_maps.data and services_maps.data[map]
    return entry and entry.label or tostring(map)
end

--- whole seconds as "m:ss" (or "h:mm:ss")
---@param sec number
---@return string
local function formatDuration(sec)
    sec = math.max(0, math.floor(sec or 0))
    local h, m, s = math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

---@param names string[]
---@param max integer?
---@return string
local function nameList(names, max)
    max = max or 15
    local shown = {}
    for i, n in ipairs(names) do
        if i > max then
            shown[#shown + 1] = tr("beamjoy.discord.andMore", { count = #names - max })
            break
        end
        shown[#shown + 1] = clean(stripCodes(n)):sub(1, 40)
    end
    return #shown > 0 and table.concat(shown, ", ") or "-"
end

---@param ms integer
---@return string
local function formatTime(ms)
    ms = math.max(0, math.floor(ms or 0))
    local h = math.floor(ms / 3600000)
    local m = math.floor(ms / 60000) % 60
    local s = math.floor(ms / 1000) % 60
    local rest = ms % 1000
    if h > 0 then
        return string.format("%d:%02d:%02d.%03d", h, m, s, rest)
    end
    return string.format("%d:%02d.%03d", m, s, rest)
end

--- a difference between two times : "0.999s", or m:ss.mmm past a minute
---@param ms integer
---@return string
local function formatGap(ms)
    ms = math.max(0, math.floor(ms or 0))
    if ms < 60000 then
        return string.format("%d.%03ds", math.floor(ms / 1000), ms % 1000)
    end
    return formatTime(ms)
end

-- TRANSPORT

---@return boolean
local function isWindows()
    return package.config:sub(1, 1) == "\\"
end

---@return string
local function tempDir()
    return BJSPluginPath:gsub("BeamJoyServer", "BeamJoyData/discord")
end

---@return boolean
local function checkCurl()
    if M.curlAvailable == nil then
        local ok, r = pcall(os.execute, isWindows() and "curl --version >NUL 2>&1" or
            "curl --version >/dev/null 2>&1")
        M.curlAvailable = ok and (r == true or r == 0)
        if not M.curlAvailable then
            LogWarn("Discord posts need curl on the server machine's PATH, and it wasn't found")
        end
    end
    return M.curlAvailable
end

---@param body table
---@return string? path
local function writeBody(body)
    local dir = tempDir()
    if not FS.Exists(dir) then FS.CreateDirectory(dir) end
    M.fileSlot = M.fileSlot % FILE_SLOTS + 1
    local path = string.format("%s/post%d.json", dir, M.fileSlot)
    local file = io.open(path, "w")
    if not file then
        LogError("Discord: couldn't write " .. path)
        return nil
    end
    file:write(utils_json.stringifyRaw(body))
    file:close()
    return path
end

---@param path string
---@param url string
---@param extra string? additional curl arguments
---@return string
local function curlCommand(path, url, extra)
    local q = isWindows() and function(s) return '"' .. s .. '"' end or
        function(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    return string.format("curl -s --max-time %d -X POST -H %s --data-binary %s %s %s",
        CURL_TIMEOUT_SEC, q("Content-Type: application/json"), q("@" .. path), extra or "", q(url))
end

---@param url string
---@param body table
local function dispatch(url, body)
    if not isValidWebhook(url) or not checkCurl() then return end
    local path = writeBody(body)
    if not path then return end
    if isWindows() then
        os.execute('start "" /b ' .. curlCommand(path, url, "-o NUL") .. " >NUL 2>&1")
    else
        os.execute(curlCommand(path, url, "-o /dev/null") .. " >/dev/null 2>&1 &")
    end
end

--- queues one post for every webhook that wants it
---@param body table {content?, embeds?}
---@param wants fun(hook: BJDiscordWebhook): boolean
local function post(body, wants)
    body.username = body.username or serverName()
    body.allowed_mentions = { parse = {} }
    for _, hook in ipairs(webhooks()) do
        if isValidWebhook(hook.Url) and wants(hook) then
            local q = M.queues[hook.Url]
            if not q then
                q = { items = {}, nextSendAt = 0 }
                M.queues[hook.Url] = q
            end
            table.insert(q.items, body)
            while #q.items > QUEUE_MAX do table.remove(q.items, 1) end
        end
    end
end

local function onUpdate()
    local now = GetCurrentTime()
    for url, q in pairs(M.queues) do
        if #q.items > 0 and now >= q.nextSendAt then
            q.nextSendAt = now + SEND_SPACING_SEC
            dispatch(url, table.remove(q.items, 1))
        end
    end
end

-- EVENTS

local CHAT_EVENT_TOGGLES = {
    ["beamjoy.chat.event.playerJoined"] = "JoinLeave",
    ["beamjoy.chat.event.playerLeft"] = "JoinLeave",
}

--- the same server events players see in chat (votes, joins, leaves)
---@param eventKey string
---@param params table?
local function onChatEvent(eventKey, params)
    local toggle = CHAT_EVENT_TOGGLES[eventKey] or
        ((eventKey:find("Vote", 1, true)) and "Votes") or nil
    if not toggle then return end
    local vars = {}
    for k, v in pairs(params or {}) do vars[k] = clean(stripCodes(v)) end
    post({
        embeds = { {
            description = tr(eventKey, vars),
            color = toggle == "Votes" and COLORS.VOTE or COLORS.JOIN,
        } },
    }, function(hook) return hook[toggle] == true end)
end

--- a player's chat line
---@param playerName string
---@param message string
local function onPlayerChat(playerName, message)
    post({
        username = username(playerName),
        content = clean(message):sub(1, 1900),
    }, function(hook) return hook.Chat == true end)
end

---@class BJDiscordRaceResult
---@field playerName string display name (nickname when logged in)
---@field vehicle string?
---@field totalMs integer? whole-race time, nil for a DNF
---@field bestLapMs integer? nil when no lap was completed
---@field dnf boolean?
---@field counted boolean whether the run could set a leaderboard time at all
---@field isNewPB boolean?
---@field isNewRecord boolean?
---@field previousMs integer? the player's best before this run
---@field rank integer? leaderboard place after this run
---@field entries integer? leaderboard size

---@class BJDiscordRace
---@field raceName string
---@field laps integer
---@field recordMs integer? the race's record after the session
---@field recordHolder string?

--- what a result meant for the leaderboard, as a short line ; color for a solo post
---@param r BJDiscordRaceResult
---@return string text, integer color
---@param short boolean? the standings list's compact wording
local function verdict(r, short)
    if r.dnf or not r.bestLapMs then return "", COLORS.FINISH end
    if not r.counted then
        return tr(short and "beamjoy.discord.race.notCountedShort" or "beamjoy.discord.race.notCounted"),
            COLORS.FINISH
    end
    if r.isNewRecord then
        return r.previousMs and
            tr("beamjoy.discord.race.recordBeat", { gap = formatGap(r.previousMs - r.bestLapMs) }) or
            tr("beamjoy.discord.race.record"), COLORS.RECORD
    elseif r.isNewPB and r.previousMs then
        return tr("beamjoy.discord.race.pb", { gap = formatGap(r.previousMs - r.bestLapMs) }), COLORS.PB
    elseif r.isNewPB then
        return tr("beamjoy.discord.race.firstTime"), COLORS.PB
    elseif r.previousMs then
        return tr("beamjoy.discord.race.offPb", { gap = formatGap(r.bestLapMs - r.previousMs) }), COLORS.FINISH
    end
    return "", COLORS.FINISH
end

---@param race BJDiscordRace
---@param fields table[]
local function recordField(race, fields)
    if race.recordMs then
        fields[#fields + 1] = {
            name = tr("beamjoy.discord.race.record.label"),
            value = string.format("`%s` %s", formatTime(race.recordMs), clean(race.recordHolder or "")),
            inline = true,
        }
    end
end

--- one player raced alone
---@param race BJDiscordRace
---@param r BJDiscordRaceResult
--- a webhook's race toggles
---@param hook BJDiscordWebhook
---@param pb boolean the post holds a personal best or record
---@return boolean
local function wantsRace(hook, pb)
    return hook.RaceFinishes == true and (pb or hook.RacePBsOnly ~= true)
end

local function onRaceFinish(race, r)
    if r.dnf then return end
    local pb = r.isNewPB == true or r.isNewRecord == true

    local headline, color = verdict(r)
    local fields = {}
    local function field(nameKey, value)
        fields[#fields + 1] = { name = tr(nameKey), value = value, inline = true }
    end
    if r.counted and r.rank and r.entries then
        field("beamjoy.discord.race.leaderboard",
            tr("beamjoy.discord.race.rankOf", { rank = r.rank, total = r.entries }))
    end
    if race.laps > 1 then
        field("beamjoy.discord.race.bestLap", "`" .. formatTime(r.bestLapMs) .. "`")
        field("beamjoy.discord.race.laps", tostring(race.laps))
    end
    if r.vehicle and #r.vehicle > 0 then
        field("beamjoy.discord.race.vehicle", clean(r.vehicle):sub(1, 200))
    end
    if not r.isNewRecord then recordField(race, fields) end

    -- multi-lap: the big time is the whole race, the leaderboard's is the best lap
    local shownMs = race.laps > 1 and r.totalMs or r.bestLapMs
    post({
        embeds = { {
            author = { name = clean(stripCodes(r.playerName)):sub(1, 200) },
            title = clean(race.raceName):sub(1, 200),
            description = string.format("## `%s`\n%s", formatTime(shownMs), headline),
            color = color,
            fields = fields,
            footer = { text = serverName() },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        } },
    }, function(hook) return wantsRace(hook, pb) end)
end

local MEDALS = { "\240\159\165\135", "\240\159\165\136", "\240\159\165\137" } -- gold, silver, bronze

--- a race with several players ended : the whole field in one post, finishers in order then DNFs
---@param race BJDiscordRace
---@param results BJDiscordRaceResult[]
local function onRaceStandings(race, results)
    local anyPB = false
    for _, r in ipairs(results) do
        if r.isNewPB or r.isNewRecord then anyPB = true end
    end

    local lines, color, place = {}, COLORS.FINISH, 0
    for _, r in ipairs(results) do
        local name = clean(stripCodes(r.playerName)):sub(1, 60)
        local line
        if r.dnf then
            line = string.format("`DNF` **%s**", name)
        else
            place = place + 1
            local shownMs = race.laps > 1 and r.totalMs or r.bestLapMs
            line = string.format("%s **%s** `%s`", MEDALS[place] or string.format("`%d.`", place),
                name, formatTime(shownMs))
            local note = verdict(r, true)
            if r.isNewRecord then color = COLORS.RECORD elseif r.isNewPB and color ~= COLORS.RECORD then color = COLORS.PB end
            if #note > 0 then line = line .. " \194\183 " .. note end
        end
        local extra = {}
        if r.vehicle and #r.vehicle > 0 then extra[#extra + 1] = clean(r.vehicle):sub(1, 80) end
        if race.laps > 1 and r.bestLapMs and not r.dnf then
            extra[#extra + 1] = tr("beamjoy.discord.race.bestLapShort", { time = formatTime(r.bestLapMs) })
        end
        lines[#lines + 1] = #extra > 0 and (line .. "\n-# " .. table.concat(extra, " \194\183 ")) or line
    end

    local fields = {}
    if race.laps > 1 then
        fields[#fields + 1] = { name = tr("beamjoy.discord.race.laps"), value = tostring(race.laps), inline = true }
    end
    recordField(race, fields)

    post({
        embeds = { {
            title = clean(race.raceName):sub(1, 200),
            description = table.concat(lines, "\n"):sub(1, 4000),
            color = color,
            fields = fields,
            footer = { text = serverName() },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        } },
    }, function(hook) return wantsRace(hook, anyPB) end)
end

-- ACTIVITIES

---@param nameKey string
---@param value string
---@param inline boolean?
---@return table
local function fieldOf(nameKey, value, inline)
    return { name = tr(nameKey), value = value, inline = inline ~= false }
end

---@class BJDiscordDelivery
---@field playerName string
---@field kind "packages"|"vehicles"
---@field cargo string? packages : cargo type key
---@field vehicle string? vehicles : the delivered vehicle's label
---@field fromName string
---@field toName string
---@field meters integer
---@field stops integer? multi-stop jobs : how many drop-offs
---@field actualSec integer
---@field targetSec integer
---@field condition string? vehicles : Pristine / Minor / Moderate / Heavy
---@field score integer
---@field rank integer?
---@field players integer?

--- one player's delivery (a convoy posts once, when it's over : onConvoyEnd)
---@param d BJDiscordDelivery
local function onDelivery(d)
    local what
    if d.kind == "vehicles" then
        what = clean(d.vehicle or "?")
    else
        local cargo = tostring(d.cargo or "packages"):gsub("[_%-]", " ")
        what = clean(cargo:sub(1, 1):upper() .. cargo:sub(2))
    end
    local fields = {
        fieldOf("beamjoy.discord.delivery.route", string.format("%s \226\134\146 %s",
            clean(d.fromName), clean(d.toName)), false),
        fieldOf("beamjoy.discord.delivery.distance", string.format("%.1f km", (d.meters or 0) / 1000)),
        fieldOf("beamjoy.discord.delivery.time", tr("beamjoy.discord.delivery.timeOf",
            { time = formatDuration(d.actualSec), target = formatDuration(d.targetSec) })),
    }
    if d.stops then fields[#fields + 1] = fieldOf("beamjoy.discord.delivery.stops", tostring(d.stops)) end
    if d.condition then fields[#fields + 1] = fieldOf("beamjoy.discord.delivery.condition", d.condition) end
    fields[#fields + 1] = fieldOf("beamjoy.discord.delivery.score", "+" .. tostring(d.score))
    if d.rank and d.players then
        fields[#fields + 1] = fieldOf("beamjoy.discord.race.leaderboard",
            tr("beamjoy.discord.race.rankOf", { rank = d.rank, total = d.players }))
    end
    post({
        embeds = { {
            author = { name = clean(stripCodes(d.playerName)):sub(1, 200) },
            title = tr(d.kind == "vehicles" and "beamjoy.discord.delivery.vehicleTitle" or
                "beamjoy.discord.delivery.packageTitle", { what = what }):sub(1, 250),
            color = COLORS.DELIVERY,
            fields = fields,
            footer = { text = serverName() },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        } },
    }, function(hook) return hook.Deliveries == true end)
end

--- a convoy of several players is over : everyone's result in one post
---@param c {what: string, fromName: string, toName: string, meters: integer, targetSec: integer, rows: {name: string, status: string, actualSec: integer?, score: integer?}[]}
local function onConvoyEnd(c)
    local lines = {}
    for _, row in ipairs(c.rows) do
        local status = tr("beamjoy.discord.delivery.status." .. tostring(row.status))
        local line = string.format("**%s** %s", clean(stripCodes(row.name)):sub(1, 40), status)
        if row.actualSec and (row.status == "delivered" or row.status == "late") then
            line = line .. string.format(" `%s`", formatDuration(row.actualSec))
        end
        if row.score then line = line .. string.format(" +%d", row.score) end
        lines[#lines + 1] = line
    end
    post({
        embeds = { {
            title = tr("beamjoy.discord.delivery.convoyTitle", { what = clean(c.what) }):sub(1, 250),
            description = table.concat(lines, "\n"):sub(1, 4000),
            color = COLORS.DELIVERY,
            fields = {
                fieldOf("beamjoy.discord.delivery.route", string.format("%s \226\134\146 %s",
                    clean(c.fromName), clean(c.toName)), false),
                fieldOf("beamjoy.discord.delivery.distance", string.format("%.1f km", (c.meters or 0) / 1000)),
                fieldOf("beamjoy.discord.delivery.target", formatDuration(c.targetSec)),
            },
            footer = { text = serverName() },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        } },
    }, function(hook) return hook.Deliveries == true end)
end

--- a hunter round ended with a winner (a cancelled round posts nothing)
---@param h {winner: "hunted"|"hunters", fugitive: string?, fugitiveVehicle: string?, hunters: string[], waypoints: integer?, route: integer?, durationSec: integer?}
local function onHunterEnd(h)
    local fields = {
        fieldOf("beamjoy.discord.hunter.fugitive", h.fugitive and
            (clean(stripCodes(h.fugitive)) .. (h.fugitiveVehicle and ("\n-# " .. clean(h.fugitiveVehicle)) or "")) or "-"),
        fieldOf("beamjoy.discord.hunter.hunters", nameList(h.hunters)),
    }
    if h.route and h.route > 0 then
        fields[#fields + 1] = fieldOf("beamjoy.discord.hunter.waypoints",
            string.format("%d / %d", h.waypoints or 0, h.route))
    end
    if h.durationSec then fields[#fields + 1] = fieldOf("beamjoy.discord.duration", formatDuration(h.durationSec)) end
    post({
        embeds = { {
            title = tr("beamjoy.discord.hunter.title", { map = clean(mapLabel()) }),
            description = "### " .. tr(h.winner == "hunted" and "beamjoy.discord.hunter.escaped" or
                "beamjoy.discord.hunter.caught", { name = clean(stripCodes(h.fugitive or "?")) }),
            color = COLORS.HUNTER,
            fields = fields,
            footer = { text = serverName() },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        } },
    }, function(hook) return hook.Hunter == true end)
end

--- an infected round ended with a winner
---@param r {winner: "survivors"|"infected", survivors: string[], players: integer, topTagger: string?, topTags: integer?, durationSec: integer?}
local function onInfectedEnd(r)
    local fields = {
        fieldOf("beamjoy.discord.infected.survivors", #r.survivors > 0 and nameList(r.survivors) or "-", false),
        fieldOf("beamjoy.discord.infected.players", tostring(r.players)),
    }
    if r.topTagger and (r.topTags or 0) > 0 then
        fields[#fields + 1] = fieldOf("beamjoy.discord.infected.topTagger",
            tr("beamjoy.discord.infected.tags", { name = clean(stripCodes(r.topTagger)), count = r.topTags }))
    end
    if r.durationSec then fields[#fields + 1] = fieldOf("beamjoy.discord.duration", formatDuration(r.durationSec)) end
    post({
        embeds = { {
            title = tr("beamjoy.discord.infected.title", { map = clean(mapLabel()) }),
            description = "### " .. tr(r.winner == "survivors" and "beamjoy.discord.infected.survivorsWin" or
                "beamjoy.discord.infected.infectedWin"),
            color = COLORS.INFECTED,
            fields = fields,
            footer = { text = serverName() },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        } },
    }, function(hook) return hook.Infected == true end)
end

--- a bus line driven to its last stop, or once around a looping line
---@param b {playerName: string, lineName: string, stops: integer, durationSec: integer?, loop: boolean?}
local function onBusRun(b)
    local fields = { fieldOf("beamjoy.discord.bus.stops", tostring(b.stops)) }
    if b.durationSec then fields[#fields + 1] = fieldOf("beamjoy.discord.duration", formatDuration(b.durationSec)) end
    post({
        embeds = { {
            author = { name = clean(stripCodes(b.playerName)):sub(1, 200) },
            title = tr(b.loop and "beamjoy.discord.bus.loop" or "beamjoy.discord.bus.finished",
                { line = clean(b.lineName) }):sub(1, 250),
            color = COLORS.BUS,
            fields = fields,
            footer = { text = serverName() },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        } },
    }, function(hook) return hook.BusLines == true end)
end

-- SETTINGS

--- config value check for services_config's sanitizeConfigValue : {Webhooks = BJDiscordWebhook[]}
---@param value any
---@return table? value, string? error
local function sanitize(value)
    if type(value) ~= "table" or type(value.Webhooks) ~= "table" then
        return nil, "Value must be {Webhooks = [...]}"
    end
    local list = {}
    for i, hook in ipairs(value.Webhooks) do
        if i > WEBHOOKS_MAX then return nil, "At most " .. WEBHOOKS_MAX .. " webhooks" end
        if type(hook) ~= "table" then return nil, "Invalid webhook" end
        local url = type(hook.Url) == "string" and hook.Url:trim() or ""
        if #url > 0 and not isValidWebhook(url) then
            return nil, "Not a Discord webhook URL"
        end
        local name = type(hook.Name) == "string" and hook.Name:trim():sub(1, 40) or ""
        local out = { Name = #name > 0 and name or ("Webhook " .. i), Url = url }
        for key, default in pairs(TOGGLES) do
            if hook[key] == nil then
                out[key] = default
            elseif type(hook[key]) ~= "boolean" then
                return nil, key .. " must be a boolean"
            else
                out[key] = hook[key]
            end
        end
        list[#list + 1] = out
    end
    -- a removed or changed webhook's pending posts go with it
    local kept = {}
    for _, hook in ipairs(list) do kept[hook.Url] = true end
    for url in pairs(M.queues) do
        if not kept[url] then M.queues[url] = nil end
    end
    return { Webhooks = list }
end

--- Settings' "Send test post" on one webhook : the one blocking call here, so the admin hears
--- back whether Discord took it (the status code) instead of guessing
---@param ctxt BJSContext
---@param index integer 1-based, in the saved list
local function test(ctxt, index)
    if ctxt.senderID and not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.SetConfig) then
        return
    end
    local lang = ctxt.sender and ctxt.sender.lang
    local function reply(kind, key, vars)
        local text = services_lang.get(key, lang)
        if vars then text = text:gsub("{(%w+)}", function(n) return vars[n] and tostring(vars[n]) end) end
        if ctxt.senderID then
            communications_tx.sendToPlayer(ctxt.senderID, "toast", kind, text)
        else
            Log(text)
        end
    end

    local hook = webhooks()[tonumber(index) or 0]
    if not hook or not isValidWebhook(hook.Url) then return reply("error", "beamjoy.discord.test.noUrl") end
    M.curlAvailable = nil
    if not checkCurl() then return reply("error", "beamjoy.discord.test.noCurl") end

    local path = writeBody({
        username = serverName(),
        allowed_mentions = { parse = {} },
        embeds = { {
            title = tr("beamjoy.discord.test.title"),
            description = tr("beamjoy.discord.test.body", { name = clean(hook.Name) }),
            color = COLORS.FINISH,
            footer = { text = serverName() },
        } },
    })
    if not path then return reply("error", "beamjoy.discord.test.failed", { code = "file", name = hook.Name }) end

    local ok, handle = pcall(io.popen, curlCommand(path, hook.Url,
        isWindows() and '-o NUL -w "%{http_code}"' or "-o /dev/null -w '%{http_code}'"))
    local code = ok and handle and handle:read("*a") or ""
    if ok and handle then handle:close() end
    code = code:match("%d+") or "?"
    if code:sub(1, 1) == "2" then
        reply("success", "beamjoy.discord.test.sent", { name = hook.Name })
    else
        reply("error", "beamjoy.discord.test.failed", { code = code, name = hook.Name })
    end
end

local function onInit()
    webhooks() -- moves a single-URL config over to the list
    communications_rx.addHandler("discordTest", M.test)
end

M.onInit = onInit
M.onUpdate = onUpdate

M.isValidWebhook = isValidWebhook
M.sanitize = sanitize
M.test = test
M.post = post
M.onChatEvent = onChatEvent
M.onPlayerChat = onPlayerChat
M.onRaceFinish = onRaceFinish
M.onRaceStandings = onRaceStandings
M.onDelivery = onDelivery
M.onConvoyEnd = onConvoyEnd
M.onHunterEnd = onHunterEnd
M.onInfectedEnd = onInfectedEnd
M.onBusRun = onBusRun
M.formatTime = formatTime
M.webhooks = webhooks

return M
