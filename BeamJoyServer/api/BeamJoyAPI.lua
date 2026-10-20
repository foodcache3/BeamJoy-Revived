--[[
BeamJoyAPI.lua : a helper for BeamMP server plugins reading BeamJoy's data, through BeamJoy's
plugin API (see README.md next to this file for every method and event).

It ships with BeamJoy, in Resources/Server/BeamJoyServer/api/. Load it from there, so it's always
the one that matches the BeamJoy installed (each plugin gets its own copy of it in memory) :

    -- Resources/Server/MyPlugin/main.lua
    local here = debug.getinfo(1).source:gsub("^@", ""):gsub("\\", "/")
    local BJ = dofile(here:match("^(.*)/[^/]+/[^/]+$") .. "/BeamJoyServer/api/BeamJoyAPI.lua")

    function onInit()
        BJ.init("MyPlugin")
        BJ.onReady(function(info)
            print("BeamJoy " .. info.beamjoy.version .. " is up, map " .. info.map.name)
            BJ.call("races.list", {}, function(ok, result)
                if not ok then return print("races.list failed : " .. result.message) end
                for _, race in ipairs(result.races) do print(race.id, race.name) end
            end)
        end)
        BJ.on("LeaderboardChanged", function(data)
            print("new time on " .. data.raceName .. " by " .. data.change.name)
        end)
    end

Calls made before BeamJoy is up wait for it. Answers come back later (BeamMP plugins only talk
through events), so every call takes a callback : callback(true, result) or callback(false,
{code, message}). A call with no answer after `timeout` seconds (default 10) gets
callback(false, {code = "timeout"}).

Hooks are BeamJoy's questions (a racer readying up, the grid's order) : BJ.hook(name, fn) answers
one, with whatever fn returns :

    BJ.hook("raceReady", function(q)
        if q.racer.identity == "guest" then return { allow = false, reason = "Pick a nickname first" } end
        return { allow = true }
    end)

Plugins can add to BeamJoy's own windows too : options in the race start menu and race editor
(BJ.raceOptions), a tab in the config window (BJ.configTab), pages in the main window and its rail
(BJ.page), labels on results and leaderboard entries (the results.setFields and
leaderboard.setFields methods) :

    BJ.raceOptions({ { id = "league", title = "League", options = {
        { id = "class", type = "select", label = "Class", choices = { "GT3", "GT4", "Street" }, field = true },
    } } })
    BJ.configTab({ title = "League", sections = { { id = "main", title = "Website", options = {
        { id = "url", type = "text", label = "Address" },
    } } } }, function(values) print("website : " .. values.url) end)
    BJ.page({ id = "league", title = "League", icon = "trophy", blocks = {
        { type = "heading", text = "Standings" },
        { type = "buttons", items = { { id = "refresh", label = "Refresh" } } },
    } })
    BJ.onPageAction(function(page, action, values, by) print(by.name .. " clicked " .. action) end)

Public domain JSON code below : json.lua by Tyler Neylon, as BeamJoy itself ships it.
]]

local json = (function()
--[[ json.lua
A compact pure-Lua JSON library.
The main functions are: json.stringify, json.parse.
## json.stringify:
This expects the following to be true of any tables being encoded:
 * They only have string or number keys. Number keys must be represented as
   strings in json; this is part of the json spec.
 * They are not recursive. Such a structure cannot be specified in json.
A Lua table is considered to be an array if and only if its set of keys is a
consecutive sequence of positive integers starting at 1. Arrays are encoded like
so: `[2, 3, false, "hi"]`. Any other type of Lua table is encoded as a json
object, encoded like so: `{"key1": 2, "key2": false}`.
Because the Lua nil value cannot be a key, and as a table value is considered
equivalent to a missing key, there is no way to express the json "null" value in
a Lua table. The only way this will output "null" is if your entire input obj is
nil itself.
An empty Lua table, {}, could be considered either a json object or array -
it's an ambiguous edge case. We choose to treat this as an object as it is the
more general type.
To be clear, none of the above considerations is a limitation of this code.
Rather, it is what we get when we completely observe the json specification for
as arbitrary a Lua object as json is capable of expressing.
## json.parse:
This function parses json, with the exception that it does not pay attention to
\u-escaped unicode code points in strings.
It is difficult for Lua to return null as a value. In order to prevent the loss
of keys with a null value in a json string, this function uses the one-off
table value json.null (which is just an empty table) to indicate null values.
This way you can check if a value is null with the conditional
`val == json.null`.
If you have control over the data and are using Lua, I would recommend just
avoiding null values in your data to begin with.
--]]

local json = {}

-- Internal functions.

local function kind_of(obj)
    if type(obj) ~= 'table' then return type(obj) end
    local i = 1
    for _ in pairs(obj) do
        if obj[i] ~= nil then i = i + 1 else return 'table' end
    end
    if i == 1 then return 'table' else return 'array' end
end

local function escape_str(s)
    local in_char  = { '\\', '"', '/', '\b', '\f', '\n', '\r', '\t' }
    local out_char = { '\\', '"', '/', 'b', 'f', 'n', 'r', 't' }
    for i, c in ipairs(in_char) do
        s = s:gsub(c, '\\' .. out_char[i])
    end
    return s
end

-- Returns pos, did_find; there are two cases:
-- 1. Delimiter found: pos = pos after leading space + delim; did_find = true.
-- 2. Delimiter not found: pos = pos after leading space;     did_find = false.
-- This throws an error if err_if_missing is true and the delim is not found.
local function skip_delim(str, pos, delim, err_if_missing)
    pos = pos + #str:match('^%s*', pos)
    if str:sub(pos, pos) ~= delim then
        if err_if_missing then
            error('Expected ' .. delim .. ' near position ' .. pos)
        end
        return pos, false
    end
    return pos + 1, true
end

-- Expects the given pos to be the first character after the opening quote.
-- Returns val, pos; the returned pos is after the closing quote character.
local function parse_str_val(str, pos, val)
    val = val or ''
    local early_end_error = 'End of input found while parsing string.'
    if pos > #str then error(early_end_error) end
    local c = str:sub(pos, pos)
    if c == '"' then return val, pos + 1 end
    if c ~= '\\' then return parse_str_val(str, pos + 1, val .. c) end
    -- We must have a \ character.
    local esc_map = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
    local nextc = str:sub(pos + 1, pos + 1)
    if not nextc then error(early_end_error) end
    return parse_str_val(str, pos + 2, val .. (esc_map[nextc] or nextc))
end

-- Returns val, pos; the returned pos is after the number's final character.
local function parse_num_val(str, pos)
    local num_str = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
    local val = tonumber(num_str)
    if not val then error('Error parsing number at position ' .. pos .. '.') end
    return val, pos + #num_str
end

--- returns true if obj is a table with all integer indices, min index 1 (it can have missing indices)
--- returns also the real max index if the object respects all conditions
---@param obj any
---@return boolean isArray, integer? maxIndex
local function isJsonArray(obj)
    if type(obj) ~= "table" then
        return false
    end
    local max = 0
    for k in pairs(obj) do
        local numK = tonumber(k)
        if not numK or math.floor(numK) ~= numK then
            return false
        end
        if numK < 1 then
            return false
        end
        if numK > max then
            max = numK
        end
    end
    return true, max
end

-- Public values and functions.

---@param obj any
---@param key integer|string?
---@param pretty boolean?
---@param level integer?
function json.stringify(obj, key, pretty, level)
    if not level then
        level = 0
    end

    local s = {}

    local indent = pretty and string.rep(" ", level * 4) or ""
    local lineBreak = pretty and "\n" or ""

    s[#s + 1] = indent
    if key then
        s[#s + 1] = "\"" .. key .. "\":" .. (pretty and " " or "")
    end
    -- plain loops and table.concat throughout : this runs for every message the server sends and
    -- every file it saves. The Table/Range helpers it used before allocated wrapper objects for
    -- every value and joined strings by repeated concatenation (slower the bigger the output), which
    -- made big payloads (race session updates) cost tens of ms each. Same output, byte for byte.
    local t = type(obj)
    if t == "number" and (obj ~= obj or obj == math.huge or obj == -math.huge) then
        -- JSON has no infinity or NaN : written as-is ("inf"), it made the whole message unreadable
        -- to the client (a race's last update, direct report)
        s[#s + 1] = "null"
    elseif t == "boolean" or t == "number" then
        s[#s + 1] = tostring(obj)
    elseif t == "string" then
        s[#s + 1] = "\"" .. escape_str(obj) .. "\""
    elseif t == "nil" then
        s[#s + 1] = "null"
    elseif t == "table" then
        local isArray, maxIndex = isJsonArray(obj)
        if isArray then
            s[#s + 1] = "[" .. lineBreak
            if maxIndex >= 1 then
                local items = {}
                for i = 1, maxIndex do
                    items[i] = obj[i] and json.stringify(obj[i], nil, pretty, level + 1) or "null"
                end
                s[#s + 1] = table.concat(items, "," .. lineBreak)
            end
            s[#s + 1] = lineBreak
            s[#s + 1] = indent
            s[#s + 1] = "]"
        else
            s[#s + 1] = "{" .. lineBreak
            local keys = {}
            for k in pairs(obj) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local items = {}
            for i, k in ipairs(keys) do
                items[i] = json.stringify(obj[k], k, pretty, level + 1)
            end
            s[#s + 1] = table.concat(items, "," .. lineBreak)
            s[#s + 1] = lineBreak
            s[#s + 1] = indent
            s[#s + 1] = "}"
        end
    end

    return table.concat(s)
end

json.null = "JSON_NULL_VALUE" -- This is a one-off value to represent the null value.

function json.parse(str, pos, end_delim)
    pos = pos or 1
    if pos > #str then error('Reached unexpected end of input.') end
    pos = pos + #str:match('^%s*', pos) -- Skip whitespace.
    local first = str:sub(pos, pos)
    if first == '{' then                -- Parse an object.
        local obj, key, delim_found = {}, true, true
        pos = pos + 1
        while true do
            key, pos = json.parse(str, pos, '}')
            if key == nil then return obj, pos end
            if not delim_found then error('Comma missing between object items.') end
            pos = skip_delim(str, pos, ':', true) -- true -> error if missing.
            local finalKey = tonumber(key) or key
            obj[finalKey], pos = json.parse(str, pos)
            if obj[finalKey] == json.null then obj[finalKey] = nil end
            pos, delim_found = skip_delim(str, pos, ',')
        end
    elseif first == '[' then -- Parse an array.
        local val; val = true
        local arr, delim_found = {}, true
        pos = pos + 1
        while true do
            val, pos = json.parse(str, pos, ']')
            if val == nil then
                -- not more array values, sanitize null values
                for i, v in pairs(arr) do
                    if v == json.null then
                        arr[i] = nil
                    end
                end
                return arr, pos
            end
            if not delim_found then error('Comma missing between array items.') end
            arr[#arr + 1] = val
            pos, delim_found = skip_delim(str, pos, ',')
        end
    elseif first == '"' then                      -- Parse a string.
        return parse_str_val(str, pos + 1)
    elseif first == '-' or first:match('%d') then -- Parse a number.
        return parse_num_val(str, pos)
    elseif first == end_delim then                -- End of an object or array.
        return nil, pos + 1
    else                                          -- Parse true, false, or null.
        local literals = { ['true'] = true, ['false'] = false, ['null'] = json.null }
        for lit_str, lit_val in pairs(literals) do
            local lit_end = pos + #lit_str - 1
            if str:sub(pos, lit_end) == lit_str then
                return lit_val, lit_end + 1
            end
        end
        local pos_info_str = 'position ' .. pos .. ': ' .. str:sub(pos, pos + 10)
        error('Invalid json syntax starting at ' .. pos_info_str)
    end
end

return json
end)()

local BJ = {
    json = json,
    API_VERSION = 1,
    --- seconds before a call with no answer fails with "timeout"
    timeout = 10,
    name = nil,
    ready = false,
    --- the BeamJoy server run this plugin last saw (BeamJoy's `instance`)
    instance = nil,
    info = nil,
}

local pending = {}  -- id -> {callback, deadline}
local queued = {}   -- calls made before BeamJoy was up
local handlers = {} -- event name -> {fn...}
local readyFns = {}
local hooks = {}    -- hook name -> {fn, timeoutMs}
local hookEventRegistered = false
local raceOptions = nil -- what BJ.raceOptions registered (again after BeamJoy restarts)
local configTab = nil   -- what BJ.configTab registered, and its callback
local pages = {}        -- id -> what BJ.page registered (with BJ.updatePage's latest blocks)
local pageOrder = {}    -- their ids, in the order they were first registered
local counter = 0
local lastPing = 0
local PING_EVERY = 10

local function now() return os.time() end

local function send(method, params, callback)
    counter = counter + 1
    local id = BJ.name .. ":" .. counter
    pending[id] = { callback = callback, deadline = now() + BJ.timeout }
    MP.TriggerGlobalEvent("BJAPI_Request", json.stringify({
        id = id, from = BJ.name, method = method, params = params or {},
    }))
end

--- tells BeamJoy this plugin answers a hook (again after BeamJoy restarts : it forgets)
local function registerHook(name)
    local h = hooks[name]
    if not h then return end
    send("hooks.register", { hook = name, timeoutMs = h.timeoutMs }, function(ok, err)
        if not ok then print("[BeamJoyAPI] couldn't register the " .. name .. " hook : " .. tostring(err.message)) end
    end)
end

local function registerRaceOptions()
    if not raceOptions then return end
    send("raceOptions.register", { sections = raceOptions }, function(ok, err)
        if not ok then print("[BeamJoyAPI] couldn't add the race options : " .. tostring(err.message)) end
    end)
end

local function registerConfigTab()
    if not configTab then return end
    send("config.register", configTab.tab, function(ok, result)
        if not ok then return print("[BeamJoyAPI] couldn't add the config tab : " .. tostring(result.message)) end
        if configTab.onChange then
            local done, err = pcall(configTab.onChange, result.values, nil, nil)
            if not done then print("[BeamJoyAPI] the config callback failed : " .. tostring(err)) end
        end
    end)
end

local function registerPage(pageId)
    local page = pages[pageId]
    if not page then return end
    send("pages.register", page, function(ok, err)
        if not ok then print("[BeamJoyAPI] couldn't add the " .. pageId .. " page : " .. tostring(err.message)) end
    end)
end

local function becomeReady(info)
    if BJ.ready and info.instance == BJ.instance then return end
    BJ.ready, BJ.instance, BJ.info = true, info.instance, info
    for name in pairs(hooks) do registerHook(name) end
    registerRaceOptions()
    registerConfigTab()
    for _, pageId in ipairs(pageOrder) do registerPage(pageId) end
    for _, fn in ipairs(readyFns) do
        local ok, err = pcall(fn, info)
        if not ok then print("[BeamJoyAPI] an onReady callback failed : " .. tostring(err)) end
    end
    local calls = queued
    queued = {}
    for _, c in ipairs(calls) do send(c.method, c.params, c.callback) end
end

local function ping()
    lastPing = now()
    send("server.info", {}, function(ok, info)
        if ok then becomeReady(info) end
    end)
end

--- BeamJoy's messages are JSON strings. A player's game can trigger these events too
--- (TriggerServerEvent), but BeamMP then passes the sender's ID first, a number : ignored
local function decode(raw)
    if type(raw) ~= "string" then return end
    local ok, msg = pcall(json.parse, raw)
    if ok and type(msg) == "table" then return msg end
end

--- every plugin gets every answer : only ours are decoded
function _G.__BJAPI_onResponse(raw)
    if type(raw) ~= "string" or not raw:find('"' .. BJ.name .. ':', 1, true) then return end
    local msg = decode(raw)
    local call = msg and pending[msg.id]
    if not call then return end
    pending[msg.id] = nil
    if call.callback then
        local ok, err = pcall(call.callback, msg.ok == true, msg.ok and msg.result or msg.error)
        if not ok then print("[BeamJoyAPI] a callback failed : " .. tostring(err)) end
    end
end

function _G.__BJAPI_onReady(raw)
    local msg = decode(raw)
    if msg and type(msg.data) == "table" then becomeReady(msg.data) end
end

--- a question from BeamJoy : asked to the plugins in its `plugins` list, answered once
function _G.__BJAPI_onHook(raw)
    local msg = decode(raw)
    local q = msg and msg.data
    if type(q) ~= "table" or type(q.hookId) ~= "string" then return end
    local h = hooks[q.hook]
    if not h then return end
    local asked = false
    for _, name in ipairs(q.plugins or {}) do
        if name == BJ.name then asked = true end
    end
    if not asked then return end
    local answered = false
    local function answer(result)
        if answered then return end
        answered = true
        local params = {}
        if type(result) == "table" then
            for k, v in pairs(result) do params[k] = v end
        end
        params.hookId = q.hookId
        send("hooks.answer", params, nil)
    end
    local ok, result = pcall(h.fn, q.data, answer)
    if not ok then
        print("[BeamJoyAPI] the " .. tostring(q.hook) .. " hook failed : " .. tostring(result))
        return answer({}) -- BeamJoy goes on as if this plugin had no opinion
    end
    if result ~= nil then answer(result) end
end

function _G.__BJAPI_onTick()
    local t = now()
    for id, call in pairs(pending) do
        if t >= call.deadline then
            pending[id] = nil
            if call.callback then
                pcall(call.callback, false, { code = "timeout", message = "BeamJoy didn't answer" })
            end
        end
    end
    if not BJ.ready and t - lastPing >= PING_EVERY then ping() end
end

--- starts the helper : call it once, from your plugin's onInit
---@param pluginName string your plugin's name : the answers meant for it carry it
function BJ.init(pluginName)
    assert(type(pluginName) == "string" and pluginName:find("^[%w_%-]+$"),
        "BeamJoyAPI.init needs your plugin's name (letters, digits, _ and - only)")
    BJ.name = pluginName
    MP.RegisterEvent("BJAPI_Response", "__BJAPI_onResponse")
    MP.RegisterEvent("BJAPI_Ready", "__BJAPI_onReady")
    local tick = "BJAPI_Tick_" .. pluginName
    MP.RegisterEvent(tick, "__BJAPI_onTick")
    MP.CreateEventTimer(tick, 1000)
    -- BeamJoy may already be running (it then answers), or start after this plugin (it then
    -- sends BJAPI_Ready)
    ping()
end

--- answers one of BeamJoy's hooks : `fn(question, answer)` returns its answer (a table), or
--- returns nothing and calls `answer(table)` itself later (within the hook's time : `timeoutMs`,
--- default 2000, at most 10000). An error in fn answers with nothing
---@param name string "raceReady" or "gridOrder"
---@param fn function
---@param opts {timeoutMs: integer?}?
function BJ.hook(name, fn, opts)
    assert(BJ.name, "call BeamJoyAPI.init first")
    assert(type(name) == "string" and type(fn) == "function", "BeamJoyAPI.hook needs a hook name and a function")
    hooks[name] = { fn = fn, timeoutMs = opts and opts.timeoutMs or nil }
    if not hookEventRegistered then
        hookEventRegistered = true
        MP.RegisterEvent("BJAPI_Hook", "__BJAPI_onHook")
    end
    if BJ.ready then registerHook(name) end
end

--- stops answering a hook
---@param name string
function BJ.unhook(name)
    if not hooks[name] then return end
    hooks[name] = nil
    if BJ.ready then send("hooks.unregister", { hook = name }, nil) end
end

--- runs `fn(info)` once BeamJoy is up (server.info's result), and again if it starts again
---@param fn function
function BJ.onReady(fn)
    readyFns[#readyFns + 1] = fn
    if BJ.ready then fn(BJ.info) end
end

--- calls one of BeamJoy's methods ; the answer comes back later, to `callback(ok, resultOrError)`
---@param method string like "races.leaderboard"
---@param params table?
---@param callback function?
function BJ.call(method, params, callback)
    assert(BJ.name, "call BeamJoyAPI.init first")
    if not BJ.ready then
        queued[#queued + 1] = { method = method, params = params, callback = callback }
        return
    end
    send(method, params, callback)
end

--- runs `fn(data, message)` whenever BeamJoy sends this event (like "LeaderboardChanged")
---@param event string
---@param fn function
function BJ.on(event, fn)
    assert(type(event) == "string" and event:find("^%w+$"), "BeamJoyAPI.on needs an event name")
    if not handlers[event] then
        handlers[event] = {}
        local global = "__BJAPI_event_" .. event
        _G[global] = function(raw)
            local msg = decode(raw)
            if not msg then return end
            for _, f in ipairs(handlers[event]) do
                local ok, err = pcall(f, msg.data, msg)
                if not ok then print("[BeamJoyAPI] a " .. event .. " handler failed : " .. tostring(err)) end
            end
        end
        MP.RegisterEvent("BJAPI_" .. event, global)
    end
    table.insert(handlers[event], fn)
end

--- adds sections of options to BeamJoy's race start menu and race editor (again whenever BeamJoy
--- starts again). Replaces the ones this plugin added before. Each option : {id, type = "toggle" |
--- "select" | "number" | "text", label, default, ...} ; `where` = "both" (default), "start" or
--- "editor" ; `field = true` shows its value on results and leaderboard entries. The values chosen
--- come with the race : `options[yourPlugin][optionId]` in race events and hooks
---@param sections table[] {id, title, note?, options}
function BJ.raceOptions(sections)
    assert(BJ.name, "call BeamJoyAPI.init first")
    raceOptions = sections
    if BJ.ready then registerRaceOptions() end
end

--- adds a tab of this plugin's settings to BeamJoy's config window, for staff with
--- EditPluginConfig. BeamJoy stores the values ; `onChange(values, changed, by)` gets them once
--- registered (changed and by nil then) and whenever someone saves the tab. Options as in
--- BJ.raceOptions, plus `secret = true` on a text (never sent to a game) and type "button" (a
--- click comes to BJ.onConfigAction)
---@param tab {title: string, sections: table[]}
---@param onChange function?
function BJ.configTab(tab, onChange)
    assert(BJ.name, "call BeamJoyAPI.init first")
    local first = configTab == nil
    configTab = { tab = tab, onChange = onChange }
    if first then
        BJ.on("ConfigChanged", function(data)
            if data.plugin ~= BJ.name or not configTab.onChange then return end
            -- the event leaves secrets out (every plugin gets it) : the values, secrets included,
            -- come from config.get
            BJ.call("config.get", {}, function(ok, result)
                if not ok or not configTab.onChange then return end
                local done, err = pcall(configTab.onChange, result.values, data.changed, data.by)
                if not done then print("[BeamJoyAPI] the config callback failed : " .. tostring(err)) end
            end)
        end)
    end
    if BJ.ready then registerConfigTab() end
end

--- runs `fn(action, by)` when someone clicks one of this plugin's config tab buttons (`action` :
--- the button's id ; `by` : {id, name})
---@param fn function
function BJ.onConfigAction(fn)
    BJ.on("ConfigAction", function(data)
        if data.plugin == BJ.name then fn(data.action, data.by) end
    end)
end

--- adds a page to BeamJoy's main window (again whenever BeamJoy starts again), or replaces this
--- plugin's page with the same id : `{id, title, label?, icon?, where = "both" | "rail" | "full",
--- order?, wide?, staffOnly?, players?, blocks}`. See README.md's Pages for the blocks
---@param page table
function BJ.page(page)
    assert(BJ.name, "call BeamJoyAPI.init first")
    assert(type(page) == "table" and type(page.id) == "string", "BeamJoyAPI.page needs {id, title, ...}")
    local copy = {}
    for k, v in pairs(page) do copy[k] = v end
    if not pages[copy.id] then pageOrder[#pageOrder + 1] = copy.id end
    pages[copy.id] = copy
    if BJ.ready then registerPage(copy.id) end
end

--- a page's content : everyone's (`players` nil), or the content of the players given (a list of
--- player IDs) ; `blocks` nil with `players` puts those players back on everyone's content
---@param pageId string
---@param blocks table[]?
---@param players integer[]?
---@param callback function? callback(ok, result)
function BJ.updatePage(pageId, blocks, players, callback)
    if players == nil and pages[pageId] then pages[pageId].blocks = blocks end
    BJ.call("pages.update", { id = pageId, blocks = blocks, players = players }, callback)
end

--- takes a page away (all of this plugin's when `pageId` is nil)
---@param pageId string?
function BJ.removePage(pageId)
    if pageId then
        pages[pageId] = nil
        for i, id in ipairs(pageOrder) do
            if id == pageId then table.remove(pageOrder, i) break end
        end
    else
        pages, pageOrder = {}, {}
    end
    BJ.call("pages.unregister", { id = pageId }, nil)
end

--- runs `fn(pageId, by)` when a player opens one of this plugin's pages (`by` : {id, name}) : the
--- moment to give them their own content (BJ.updatePage with players = { by.id })
---@param fn function
function BJ.onPageOpened(fn)
    BJ.on("PageOpened", function(data)
        if data.plugin == BJ.name then fn(data.page, data.by) end
    end)
end

--- runs `fn(pageId, action, values, by)` when a player clicks a button on one of this plugin's
--- pages (`action` : the button's id ; `values` : the page's fields as that player set them)
---@param fn function
function BJ.onPageAction(fn)
    BJ.on("PageAction", function(data)
        if data.plugin == BJ.name then fn(data.page, data.action, data.values or {}, data.by) end
    end)
end

return BJ
