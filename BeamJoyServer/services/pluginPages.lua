--- Pages from plugins in BeamJoy's main window (the plugin API's pages.*, direct request : plugins
--- adding tabs of their own to the main window and its side rail). A page is a rail button with
--- its own side panel, a tab in the full window, or both, filled with blocks the plugin describes :
--- the overlays' blocks (text, rows, tables, timers...) plus headings, buttons and input fields.
--- Never HTML : everything is checked here and drawn as plain text by the client
--- (cmps/pluginPage).
---
--- A page's content is everyone's, or one player's own (a plugin showing each player their own
--- standing), set with pages.update. A button click comes back to the plugin (PageAction) with the
--- values of the page's fields, checked against the fields that player was shown ; opening a page
--- tells the plugin too (PageOpened), so it can fill a player's own content then.
---
--- Each player's game is kept up to date by comparing what it was sent (a version per page) with
--- what it should see, on every change and every second : a player joining, a page for staff only
--- after a promotion, a player leaving all fall out of that.

local M = {
    dependencies = { "services_players", "services_permissions", "services_clockSync", "services_pluginOverlay",
        "services_pluginUi", "communications_tx", "communications_rx" },

    ---@type table<string, table> "<plugin>/<id>" -> page
    pages = {},
    ---@type table<integer, table<string, string>> playerID -> page key -> the version it was sent
    sent = {},
    ---@type table<integer, {count: integer, since: integer}> playerID -> clicks and opens lately
    rates = {},
    seq = 0,

    MAX_PER_PLUGIN = 4,
    MAX_BLOCKS = 60,
    MAX_FIELDS = 12,
    MAX_BUTTONS = 16,
    MAX_ENCODED = 32000,
    --- a player's clicks and page opens, per RATE_WINDOW_MS (more are dropped)
    RATE_MAX = 8,
    RATE_WINDOW_MS = 2000,
}

local ID_PATTERN = "^%a[%w_%-]*$"
local WHERE = { both = true, rail = true, full = true }
local BUTTON_STYLES = { primary = true, secondary = true, danger = true }

---@param v any
---@param max integer
---@return string?
local function text(v, max)
    return services_pluginOverlay.cleanText(v, max)
end

---@param v any
---@return string?
local function id(v)
    if type(v) == "string" and #v <= 32 and v:find(ID_PATTERN) then return v end
end

-- ---------------------------------------------------------------------------------------------
-- describing a page's content

--- blocks only pages have (the rest are the overlays' : services/pluginOverlay.lua)
local PAGE_BLOCKS = {
    heading = function(b)
        local t = text(b.text, 60)
        if not t then return nil end
        return { text = t, sub = text(b.sub, 120) }
    end,
    buttons = function(b, content)
        local items = {}
        if type(b.items) ~= "table" then return nil end
        for _, item in ipairs(b.items) do
            if #items >= 4 then break end
            local bid = type(item) == "table" and id(item.id)
            local label = type(item) == "table" and text(item.label, 32)
            if bid and label and not content.buttons[bid] then
                if content.buttonCount >= M.MAX_BUTTONS then break end
                content.buttons[bid] = true
                content.buttonCount = content.buttonCount + 1
                items[#items + 1] = { id = bid, label = label,
                    style = BUTTON_STYLES[item.style] and item.style or "secondary",
                    confirm = text(item.confirm, 200), disabled = item.disabled == true or nil,
                    tooltip = text(item.tooltip, 200) }
            end
        end
        if #items == 0 then return nil end
        return { items = items }
    end,
    -- an input : the options' own description (services/pluginUi.lua), `control` being its type
    field = function(b, content)
        if content.fieldCount >= M.MAX_FIELDS then return nil end
        local def = {}
        for k, v in pairs(b) do def[k] = v end
        def.type = b.control
        local o = services_pluginUi.cleanOption(def, "page")
        if not o or content.fields[o.id] then return nil end
        content.fields[o.id] = o
        content.fieldCount = content.fieldCount + 1
        return { option = o }
    end,
}

---@param blocks any
---@return table? content {blocks, fields, buttons, anchorMs}, string? why not
local function contentOf(blocks)
    if blocks ~= nil and type(blocks) ~= "table" then return nil, "blocks must be a list" end
    local content = { blocks = {}, fields = {}, buttons = {}, fieldCount = 0, buttonCount = 0 }
    for _, b in ipairs(blocks or {}) do
        if #content.blocks >= M.MAX_BLOCKS then break end
        if type(b) == "table" and type(b.type) == "string" then
            local out
            if PAGE_BLOCKS[b.type] then
                out = PAGE_BLOCKS[b.type](b, content)
            else
                out = services_pluginOverlay.cleanBlock(b)
            end
            if out then
                out.type = b.type
                content.blocks[#content.blocks + 1] = out
            end
        end
    end
    local ok, encoded = pcall(utils_json.stringifyRaw, content.blocks)
    if not ok or not encoded then return nil, "the page couldn't be encoded" end
    if #encoded > M.MAX_ENCODED then
        return nil, string.format("the page is too big (%d bytes, %d at most)", #encoded, M.MAX_ENCODED)
    end
    content.fieldCount, content.buttonCount = nil, nil
    content.anchorMs = services_clockSync.nowMs()
    return content
end

---@param players any
---@return table<integer, true>?, string? error
local function audienceOf(players)
    if players == nil then return nil end
    if type(players) ~= "table" then return nil, "players must be a list of player IDs" end
    local set = {}
    for _, pid in ipairs(players) do
        pid = tonumber(pid)
        if not pid then return nil, "players must be a list of player IDs" end
        set[math.floor(pid)] = true
    end
    return set
end

-- ---------------------------------------------------------------------------------------------
-- who sees what

---@param p table a player
---@param page table
---@return boolean
local function canSee(p, page)
    if page.audience and not page.audience[p.playerID] then return false end
    if page.staffOnly and not services_permissions.isStaff(p.playerName) then return false end
    return true
end

---@param page table
---@param playerID integer
---@return table content, string version
local function contentFor(page, playerID)
    local own = page.own[playerID]
    if own then return own, page.version .. ":" .. own.version end
    return page.content, tostring(page.version)
end

--- what a player's game gets : the page with its content, running timers worked out to now
---@param page table
---@param content table
---@return table
local function clientShape(page, content)
    local blocks = table.clone(content.blocks)
    local elapsed = services_clockSync.nowMs() - content.anchorMs
    for _, b in ipairs(blocks) do
        if b.type == "timer" then
            if b.mode == "up" then b.ms = b.ms + elapsed
            elseif b.mode == "down" then b.ms = math.max(0, b.ms - elapsed) end
        end
    end
    return {
        key = page.key, plugin = page.plugin, id = page.id, title = page.title, label = page.label,
        icon = page.icon, where = page.where, order = page.order, wide = page.wide, seq = page.seq,
        blocks = blocks,
    }
end

--- brings one player's game up to date : pages new or changed for them, pages gone
---@param p table a player
local function sync(p)
    local pid = p.playerID
    local had = M.sent[pid] or {}
    local now = {}
    for key, page in pairs(M.pages) do
        if canSee(p, page) then
            local content, version = contentFor(page, pid)
            now[key] = version
            if had[key] ~= version then
                communications_tx.sendToPlayer(pid, "pluginPage", "set", clientShape(page, content))
            end
        end
    end
    for key in pairs(had) do
        if not now[key] then communications_tx.sendToPlayer(pid, "pluginPage", "remove", key) end
    end
    M.sent[pid] = now
end

--- every player whose game got its caches (a player still joining gets the pages with them)
local function syncAll()
    services_players.players:forEach(function(p)
        if p.playerID and M.sent[p.playerID] then sync(p) end
    end)
end

-- ---------------------------------------------------------------------------------------------
-- the plugin API's methods

---@param plugin string
---@param params table pages.register's params
---@return boolean ok, string? why not
local function register(plugin, params)
    local pageId = id(params.id)
    if not pageId then return false, "id must be a word (letters first, then letters, digits, _ or -)" end
    local title = text(params.title, 32)
    if not title then return false, "title is needed" end
    local where = params.where or "both"
    if not WHERE[where] then return false, "where must be \"both\", \"rail\" or \"full\"" end
    local audience, aerr = audienceOf(params.players)
    if aerr then return false, aerr end
    local content, why = contentOf(params.blocks)
    if not content then return false, why end

    local key = plugin .. "/" .. pageId
    local previous = M.pages[key]
    if not previous then
        local count = 0
        for _, page in pairs(M.pages) do
            if page.plugin == plugin then count = count + 1 end
        end
        if count >= M.MAX_PER_PLUGIN then
            return false, string.format("a plugin can have %d pages : remove one first", M.MAX_PER_PLUGIN)
        end
    end
    M.seq = M.seq + 1
    M.pages[key] = {
        key = key,
        plugin = plugin,
        id = pageId,
        title = title,
        -- under the rail's icon : short
        label = text(params.label, 10) or text(title, 10),
        -- one of BeamJoy's own icons (the client draws a default for any other name)
        icon = type(params.icon) == "string" and #params.icon <= 24 and params.icon:find(ID_PATTERN) and params.icon or nil,
        where = where,
        order = tonumber(params.order) and math.clamp(math.floor(tonumber(params.order)), -100, 100) or 0,
        wide = params.wide == true or nil,
        staffOnly = params.staffOnly == true or nil,
        audience = audience,
        content = content,
        -- players' own contents (pages.update with players), kept while the page is
        own = previous and previous.own or {},
        version = M.seq,
        seq = previous and previous.seq or M.seq,
    }
    syncAll()
    return true
end

---@param plugin string
---@param params table pages.update's params
---@return boolean ok, string? why not
local function update(plugin, params)
    if type(params.id) ~= "string" then return false, "id is needed" end
    local page = M.pages[plugin .. "/" .. params.id]
    if not page then return false, "no page " .. params.id .. " (pages.register first)", "notFound" end
    local players, aerr = audienceOf(params.players)
    if aerr then return false, aerr end
    if players and params.blocks == nil then
        -- those players go back to everyone's content
        for pid in pairs(players) do page.own[pid] = nil end
    else
        local content, why = contentOf(params.blocks)
        if not content then return false, why end
        M.seq = M.seq + 1
        if players then
            content.version = M.seq
            for pid in pairs(players) do page.own[pid] = content end
        else
            page.content = content
            page.version = M.seq
        end
    end
    syncAll()
    return true
end

---@param plugin string
---@param pageId any
local function unregister(plugin, pageId)
    if type(pageId) ~= "string" then return end
    if M.pages[plugin .. "/" .. pageId] then
        M.pages[plugin .. "/" .. pageId] = nil
        syncAll()
    end
end

---@param plugin string
---@return integer how many were removed
local function clear(plugin)
    local n = 0
    for key, page in pairs(M.pages) do
        if page.plugin == plugin then
            M.pages[key] = nil
            n = n + 1
        end
    end
    if n > 0 then syncAll() end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- from the players' games

--- false once a player clicks or opens pages faster than a person would (a script)
---@param playerID integer
---@return boolean
local function withinRate(playerID)
    local now = services_clockSync.nowMs()
    local r = M.rates[playerID]
    if not r or now - r.since >= M.RATE_WINDOW_MS then
        r = { count = 0, since = now }
        M.rates[playerID] = r
    end
    r.count = r.count + 1
    return r.count <= M.RATE_MAX
end

--- the page and the content a player sees, when they do
---@param ctxt BJSContext
---@param plugin any
---@param pageId any
---@return table? page, table? content
local function seenBy(ctxt, plugin, pageId)
    if not ctxt.sender or type(plugin) ~= "string" or type(pageId) ~= "string" then return nil end
    local page = M.pages[plugin .. "/" .. pageId]
    if not page or not canSee(ctxt.sender, page) then return nil end
    return page, (contentFor(page, ctxt.senderID))
end

---@param ctxt BJSContext
---@param plugin string
---@param pageId string
local function onPageOpened(ctxt, plugin, pageId)
    local page = seenBy(ctxt, plugin, pageId)
    if not page or not withinRate(ctxt.senderID) then return end
    if services_api then
        services_api.pageOpened(page.plugin, page.id, { id = ctxt.senderID, name = ctxt.sender.playerName })
    end
end

---@param ctxt BJSContext
---@param plugin string
---@param pageId string
---@param action string a button's id
---@param values table? the page's fields, as the player set them
local function onPageAction(ctxt, plugin, pageId, action, values)
    local page, content = seenBy(ctxt, plugin, pageId)
    if not page or type(action) ~= "string" or not content.buttons[action] then return end
    if not withinRate(ctxt.senderID) then return end
    -- only the fields this player was shown, each checked (its default when it doesn't fit)
    values = type(values) == "table" and values or {}
    local checked = {}
    for fid, o in pairs(content.fields) do
        local v = services_pluginUi.valueFor(o, values[fid])
        if v == nil then v = o.default end
        checked[fid] = v
    end
    if services_api then
        services_api.pageAction(page.plugin, page.id, action, checked,
            { id = ctxt.senderID, name = ctxt.sender.playerName })
    end
end

-- ---------------------------------------------------------------------------------------------

local function onInit()
    communications_rx.addHandler("pluginPageOpened", onPageOpened)
    communications_rx.addHandler("pluginPageAction", onPageAction)
end

--- the pages a player sees, with their caches (joining, a UI reload) : what they were sent is
--- that, from now on
local function onBJRequestCache(caches, targetID)
    if not targetID then return end
    local p = services_players.players:find(function(x) return x.playerID == targetID end)
    if not p then return end
    local list, sent = {}, {}
    for key, page in pairs(M.pages) do
        if canSee(p, page) then
            local content, version = contentFor(page, targetID)
            list[#list + 1] = clientShape(page, content)
            sent[key] = version
        end
    end
    table.sort(list, function(a, b) return a.seq < b.seq end)
    caches.pluginPages = list
    M.sent[targetID] = sent
end

--- staff promoted or demoted, players joining : caught up within a second
local function onSlowUpdate()
    if next(M.pages) then syncAll() end
end

local function onPlayerDisconnect(playerID)
    M.sent[playerID] = nil
    M.rates[playerID] = nil
    for _, page in pairs(M.pages) do
        page.own[playerID] = nil
        if page.audience then page.audience[playerID] = nil end
    end
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onSlowUpdate = onSlowUpdate
M.onPlayerDisconnect = onPlayerDisconnect

M.register = register
M.update = update
M.unregister = unregister
M.clear = clear
M.onPageOpened = onPageOpened
M.onPageAction = onPageAction

return M
