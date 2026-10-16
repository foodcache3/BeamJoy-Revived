--- Activity overlays from plugins (the plugin API's overlay.show / overlay.hide, direct request) :
--- a plugin running an activity of its own shows players an overlay where BeamJoy's race HUD goes,
--- either in BeamJoy's own race HUD look (layout "default" : the plugin sends the values, BeamJoy
--- draws them) or laid out by the plugin itself (layout "custom" : blocks of text, rows, timers,
--- bars, tables). Never HTML : everything a plugin sends is checked here and drawn as plain text by
--- the client (windows/pluginOverlays).
---
--- Kept here as well as sent, so a player joining later (or whose UI reloads) gets the overlays
--- meant for them with their caches. A running timer is sent as its value at the moment it goes
--- out, and the client counts from there.

local M = {
    dependencies = { "services_players", "services_clockSync", "communications_tx" },

    ---@type table<string, table> "<plugin>/<id>" -> {plugin, id, spec, audience, anchorMs, expiresAtMs, seq}
    overlays = {},
    seq = 0,

    MAX_PER_PLUGIN = 8,
    MAX_ENCODED = 24000,
}

local POSITIONS = { ["top-right"] = true, ["top-left"] = true, ["bottom-right"] = true,
    ["bottom-left"] = true, top = true, bottom = true, left = true, right = true }
--- BeamJoy's own colours, by name (windows/pluginOverlays maps them), as well as #rgb / #rrggbb(aa)
local COLOR_TOKENS = { accent = true, muted = true, good = true, bad = true, warn = true,
    purple = true, white = true }
--- BeamJoy overlays a plugin's own can stand in for while it's up
local HIDEABLE = { race = true }
local SEGMENTS = { done = true, best = true, live = true, [""] = true }
local SIZES = { s = true, m = true, l = true, xl = true }
local ALIGNS = { left = true, center = true, right = true }

---@param s string
---@param max integer
---@return string cut to `max` bytes without splitting a UTF-8 character
local function cut(s, max)
    if #s <= max then return s end
    local i = max
    while i > 0 do
        local b = s:byte(i + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return s:sub(1, i)
end

---@param v any
---@param max integer
---@param keepEmpty boolean? a table cell : a blank one keeps the columns lined up
---@return string? nil when there's no text
local function text(v, max, keepEmpty)
    if type(v) == "number" then v = tostring(v) end
    if type(v) ~= "string" then return nil end
    v = cut((v:gsub("%c", " ")), max)
    if #v == 0 and not keepEmpty then return nil end
    return v
end

---@param v any
---@return string?
local function color(v)
    if type(v) ~= "string" then return nil end
    if COLOR_TOKENS[v] then return v end
    if v:find("^#%x%x%x$") or v:find("^#%x%x%x%x$") or v:find("^#%x%x%x%x%x%x$") or
        v:find("^#%x%x%x%x%x%x%x%x$") then
        return v
    end
end

---@param v any
---@param set table<string, true>
---@return string?
local function oneOf(v, set)
    if type(v) == "string" and set[v] then return v end
end

---@param v any
---@return boolean?
local function flag(v)
    if v == true then return true end
end

---@param v any
---@return number?
local function fraction(v)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    return math.clamp(v, 0, 1)
end

---@param list any
---@param max integer
---@param fn fun(item: any): any
---@return table[]? the items fn kept, at most `max` ; nil when none (an empty list would go out as
---JSON's {} as easily as [])
local function listOf(list, max, fn)
    if type(list) ~= "table" then return nil end
    local out = {}
    for _, item in ipairs(list) do
        if #out >= max then break end
        local v = fn(item)
        if v ~= nil then out[#out + 1] = v end
    end
    return #out > 0 and out or nil
end

---@param t any {mode: "up"|"down"|"static", ms}
---@return table?
local function timer(t)
    if type(t) ~= "table" or not tonumber(t.ms) then return nil end
    local mode = oneOf(t.mode, { up = true, down = true, static = true }) or "static"
    return { mode = mode, ms = math.max(0, math.floor(tonumber(t.ms))) }
end

--- a table cell, or a row cell : plain text, or {text, color, align, bold, grow, size}
local function cell(c)
    if type(c) ~= "table" then
        local t = text(c, 60, true)
        return t and { text = t } or nil
    end
    local t = text(c.text, 60, true)
    if not t then return nil end
    return { text = t, color = color(c.color), align = oneOf(c.align, ALIGNS), bold = flag(c.bold),
        grow = flag(c.grow), size = oneOf(c.size, SIZES) }
end

---@param p any
---@return table?
local function plate(p)
    if type(p) ~= "table" then return nil end
    local t = text(p.text, 8)
    if not t then return nil end
    return { text = t, sub = text(p.sub, 24), color = color(p.color) }
end

local function defaultSpec(s)
    local out = {
        eyebrow = text(s.eyebrow, 40),
        title = text(s.title, 60),
        plate = plate(s.plate),
        lines = listOf(s.lines, 3, function(l)
            if type(l) ~= "table" then return nil end
            local value = text(l.value, 16)
            if not value then return nil end
            return { arrow = oneOf(l.arrow, { up = true, down = true }), value = value,
                unit = text(l.unit, 8), label = text(l.label, 40), soft = flag(l.soft) }
        end),
        timer = timer(s.timer),
        segments = listOf(s.segments, 20, function(v) return oneOf(v, SEGMENTS) end),
        rows = listOf(s.rows, 30, function(r)
            if type(r) ~= "table" then return nil end
            local name = text(r.name, 40)
            if not name then return nil end
            return { pos = text(r.pos, 6), name = name, value = text(r.value, 20),
                playerId = tonumber(r.playerId), you = flag(r.you), out = flag(r.out),
                flag = flag(r.flag), pen = text(r.pen, 8), color = color(r.color) }
        end),
        bar = fraction(s.bar),
    }
    if type(s.progress) == "table" and text(s.progress.text, 24) then
        out.progress = { text = text(s.progress.text, 24), of = text(s.progress.of, 12) }
    end
    if type(s.delta) == "table" and text(s.delta.text, 16) then
        out.delta = { text = text(s.delta.text, 16),
            kind = oneOf(s.delta.kind, { faster = true, slower = true, neutral = true }) or "neutral" }
    end
    if type(s.info) == "table" and (s.info.left or s.info.right) then
        out.info = { left = text(s.info.left, 40), right = text(s.info.right, 40) }
    end
    if type(s.footer) == "table" and text(s.footer.label, 30) then
        out.footer = { label = text(s.footer.label, 30), name = text(s.footer.name, 30),
            value = text(s.footer.value, 20) }
    end
    return out
end

local BLOCKS = {
    text = function(b)
        local t = text(b.text, 200)
        if not t then return nil end
        return { text = t, size = oneOf(b.size, SIZES), color = color(b.color), align = oneOf(b.align, ALIGNS),
            bold = flag(b.bold), italic = flag(b.italic), display = flag(b.display) }
    end,
    row = function(b)
        local cells = listOf(b.cells, 6, cell)
        if not cells or #cells == 0 then return nil end
        return { cells = cells }
    end,
    timer = function(b)
        local t = timer(b)
        if not t then return nil end
        t.size, t.color, t.align = oneOf(b.size, SIZES), color(b.color), oneOf(b.align, ALIGNS)
        return t
    end,
    bar = function(b)
        local v = fraction(b.value)
        if not v then return nil end
        return { value = v, color = color(b.color) }
    end,
    segments = function(b)
        local items = listOf(b.items, 20, function(v) return oneOf(v, SEGMENTS) end)
        if not items or #items == 0 then return nil end
        return { items = items }
    end,
    divider = function() return {} end,
    plate = function(b) return plate(b) end,
    table = function(b)
        local rows = listOf(b.rows, 30, function(r)
            if type(r) ~= "table" then return nil end
            local cells = listOf(r.cells, 6, cell)
            if not cells or #cells == 0 then return nil end
            return { cells = cells, playerId = tonumber(r.playerId), you = flag(r.you), color = color(r.color) }
        end)
        if not rows then return nil end
        return {
            columns = listOf(b.columns, 6, function(c)
                if type(c) ~= "table" then return nil end
                return { label = text(c.label, 24) or "", align = oneOf(c.align, ALIGNS) }
            end),
            rows = rows,
        }
    end,
}

local function customSpec(s)
    return {
        width = tonumber(s.width) and math.clamp(tonumber(s.width), 8, 40) or nil,
        background = color(s.background),
        accent = color(s.accent),
        blocks = listOf(s.blocks, 40, function(b)
            if type(b) ~= "table" or type(b.type) ~= "string" or not BLOCKS[b.type] then return nil end
            local out = BLOCKS[b.type](b)
            if out then out.type = b.type end
            return out
        end) or {},
    }
end

---@param players any
---@return table<integer, true>?, string? error
local function audienceOf(players)
    if players == nil or (type(players) == "table" and next(players) == nil) then return nil end
    if type(players) ~= "table" then return nil, "players must be a list of player IDs" end
    local set = {}
    for _, id in ipairs(players) do
        id = tonumber(id)
        if not id then return nil, "players must be a list of player IDs" end
        set[math.floor(id)] = true
    end
    return set
end

---@param audience table<integer, true>?
---@return integer[]? nil : everyone
local function audienceList(audience)
    if not audience then return nil end
    local list = {}
    for id in pairs(audience) do list[#list + 1] = id end
    table.sort(list)
    return list
end

--- what the client gets : the spec, with running timers worked out to this moment
---@param o table
---@return table
local function clientShape(o)
    local shape = table.clone(o.spec)
    local elapsed = services_clockSync.nowMs() - o.anchorMs
    local function advance(t)
        if not t then return end
        if t.mode == "up" then t.ms = t.ms + elapsed
        elseif t.mode == "down" then t.ms = math.max(0, t.ms - elapsed) end
    end
    advance(shape.timer)
    for _, b in ipairs(shape.blocks or {}) do
        if b.type == "timer" then advance(b) end
    end
    shape.key = o.key
    shape.plugin = o.plugin
    shape.seq = o.seq
    shape.remainingMs = o.expiresAtMs and math.max(0, o.expiresAtMs - services_clockSync.nowMs()) or nil
    return shape
end

---@param audience integer[]? nil : everyone
local function sendTo(audience, ...)
    if audience then
        if #audience > 0 then communications_tx.sendToPlayers(audience, ...) end
    else
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, ...)
    end
end

---@param plugin string
---@param params table overlay.show's params
---@return boolean ok, string? why not
local function show(plugin, params)
    local id = params.id
    if type(id) ~= "string" or not id:find("^[%w_%-%.]+$") or #id > 64 then
        return false, "id must be a name of your own for this overlay (letters, digits, _ - .)"
    end
    local layout = params.layout or "default"
    if layout ~= "default" and layout ~= "custom" then return false, "layout must be \"default\" or \"custom\"" end
    local audience, err = audienceOf(params.players)
    if err then return false, err end
    local key = plugin .. "/" .. id
    local previous = M.overlays[key]
    if not previous then
        local count = 0
        for _, o in pairs(M.overlays) do
            if o.plugin == plugin then count = count + 1 end
        end
        if count >= M.MAX_PER_PLUGIN then
            return false, string.format("a plugin can show %d overlays at once : hide one first", M.MAX_PER_PLUGIN)
        end
    end

    local spec = layout == "custom" and customSpec(params) or defaultSpec(params)
    spec.layout = layout
    spec.position = oneOf(params.position, POSITIONS) or "top-right"
    spec.hides = listOf(params.hides, 4, function(v) return oneOf(v, HIDEABLE) end)
    local okJson, encoded = pcall(utils_json.stringifyRaw, spec)
    if not okJson or not encoded then return false, "the overlay couldn't be encoded" end
    if #encoded > M.MAX_ENCODED then
        return false, string.format("the overlay is too big (%d bytes, %d at most)", #encoded, M.MAX_ENCODED)
    end

    M.seq = M.seq + 1
    local now = services_clockSync.nowMs()
    local durationS = tonumber(params.durationS)
    local o = {
        key = key,
        plugin = plugin,
        id = id,
        spec = spec,
        audience = audience,
        anchorMs = now,
        expiresAtMs = durationS and durationS > 0 and now + math.floor(durationS * 1000) or nil,
        -- the first one shown stays first in its corner, however often it's updated
        seq = previous and previous.seq or M.seq,
    }
    M.overlays[key] = o

    -- whoever saw the previous version but isn't meant to see this one
    if previous and previous.audience then
        local gone = {}
        for pid in pairs(previous.audience) do
            if audience and not audience[pid] then gone[#gone + 1] = pid end
        end
        if #gone > 0 then sendTo(gone, "pluginOverlay", "hide", key) end
    elseif previous and audience then
        local gone = {}
        services_players.players:forEach(function(p)
            if not audience[p.playerID] then gone[#gone + 1] = p.playerID end
        end)
        if #gone > 0 then sendTo(gone, "pluginOverlay", "hide", key) end
    end
    sendTo(audienceList(audience), "pluginOverlay", "show", clientShape(o))
    return true
end

---@param key string
local function remove(key)
    local o = M.overlays[key]
    if not o then return end
    M.overlays[key] = nil
    sendTo(audienceList(o.audience), "pluginOverlay", "hide", key)
end

---@param plugin string
---@param params table overlay.hide's params
---@return boolean ok, string? why not
local function hide(plugin, params)
    if type(params.id) ~= "string" then return false, "id is needed" end
    local key = plugin .. "/" .. params.id
    local o = M.overlays[key]
    if not o then return true end -- already gone
    local players, err = audienceOf(params.players)
    if err then return false, err end
    if not players then
        remove(key)
        return true
    end
    -- hidden for some : everyone else keeps it
    if not o.audience then
        o.audience = {}
        services_players.players:forEach(function(p) o.audience[p.playerID] = true end)
    end
    local gone = {}
    for pid in pairs(players) do
        if o.audience[pid] then
            o.audience[pid] = nil
            gone[#gone + 1] = pid
        end
    end
    if #gone > 0 then sendTo(gone, "pluginOverlay", "hide", key) end
    if next(o.audience) == nil then M.overlays[key] = nil end
    return true
end

---@param plugin string
---@return integer how many were removed
local function clear(plugin)
    local keys = {}
    for key, o in pairs(M.overlays) do
        if o.plugin == plugin then keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do remove(key) end
    return #keys
end

local MESSAGE_COLORS = { accent = "#ff8955", muted = "#a7aebf", good = "#73eb9d", bad = "#ff9a8f",
    warn = "#ffc768", purple = "#ba68f8", white = "#ffffff" }

--- the line of text across BeamJoy's own HUD
---@param params {text: string, color: string?, durationS: number?, players: integer[]?}
---@return boolean ok, string? why not
local function message(params)
    local audience, err = audienceOf(params.players)
    if err then return false, err end
    local c = color(params.color)
    c = c and (MESSAGE_COLORS[c] or c) or nil
    local duration = math.clamp(tonumber(params.durationS) or 5, 1, 30)
    sendTo(audienceList(audience), "uiBroadcast", text(params.text, 200), nil, c, duration)
    return true
end

---@param target integer
---@return table[] the overlays this player should see
local function visibleTo(target)
    local now = services_clockSync.nowMs()
    local list = {}
    for _, o in pairs(M.overlays) do
        if (not o.expiresAtMs or o.expiresAtMs > now) and (not o.audience or o.audience[target]) then
            list[#list + 1] = clientShape(o)
        end
    end
    table.sort(list, function(a, b) return a.seq < b.seq end)
    return list
end

local function onBJRequestCache(caches, targetID)
    if targetID then caches.pluginOverlays = visibleTo(targetID) end
end

local function onPlayerDisconnect(playerID)
    for key, o in pairs(M.overlays) do
        if o.audience and o.audience[playerID] then
            o.audience[playerID] = nil
            if next(o.audience) == nil then M.overlays[key] = nil end
        end
    end
end

local function onSlowUpdate()
    local now = services_clockSync.nowMs()
    for key, o in pairs(M.overlays) do
        -- the client takes it down itself at the same moment
        if o.expiresAtMs and o.expiresAtMs <= now then M.overlays[key] = nil end
    end
end

M.onBJRequestCache = onBJRequestCache
M.onPlayerDisconnect = onPlayerDisconnect
M.onSlowUpdate = onSlowUpdate

M.show = show
M.hide = hide
M.clear = clear
M.message = message
M.visibleTo = visibleTo
-- the same checks, for services/pluginUi.lua and services/pluginPages.lua
M.cleanText = text
M.cleanColor = color
--- one of the custom layout's blocks, checked (nil when it isn't one)
---@param b any
---@return table?
M.cleanBlock = function(b)
    if type(b) ~= "table" or type(b.type) ~= "string" or not BLOCKS[b.type] then return nil end
    local out = BLOCKS[b.type](b)
    if out then out.type = b.type end
    return out
end

return M
