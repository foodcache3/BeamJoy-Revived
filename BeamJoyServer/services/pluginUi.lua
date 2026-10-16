--- What server plugins add to BeamJoy's own windows (the plugin API, direct request : modular
--- plugins with categories and options of their own) :
--- - race options : sections of settings in the race start menu and the race editor ("Class :
---   GT3 / GT4 / Street"). The values chosen travel with the race session (settings.plugins), the
---   race editor's are the race's own defaults (defaults.plugins), and plugins see both
--- - fields : labels on a racer's result and their leaderboard entry ("GT3", "Team Red"). One entry
---   per player stays one entry : a field describes the run that set it
--- - config tabs : a tab of the plugin's own settings in BeamJoy's config window, stored by BeamJoy
---   (BeamJoyData/db/pluginConfig.json), for staff holding EditPluginConfig
--- Plugins only ever describe these : BeamJoy draws them, as plain text, and checks every value
--- that comes back against the description.

local M = {
    dependencies = { "services_players", "services_permissions", "services_pluginOverlay", "services_lang",
        "dao_main", "communications_tx", "communications_rx" },

    ---@type table<string, table[]> plugin -> its race option sections, in order
    raceSections = {},
    ---@type table<string, table> plugin -> its config tab
    configTabs = {},
    ---@type table<string, table>? plugin -> its stored config values (loaded on first use)
    configValues = nil,

    CONFIG_FILE = "pluginConfig.json",
}

local ID_PATTERN = "^%a[%w_%-]*$"
local MAX_RACE_SECTIONS = 4
local MAX_SECTION_OPTIONS = 16
local MAX_CONFIG_SECTIONS = 8
local MAX_CONFIG_OPTIONS = 40
local MAX_CHOICES = 24
local MAX_FIELDS = 8
local TEXT_MAX_DEFAULT = 100
local TEXT_MAX = 500
--- where a race option shows : both (its value set per race in the editor, changeable at start),
--- only the start menu, or only the editor (fixed per race)
local WHERE = { both = true, start = true, editor = true }

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

---@param v any
local function absent(v)
    return v == nil or (type(v) == "table" and next(v) == nil)
end

-- ---------------------------------------------------------------------------------------------
-- describing options

--- a choice of a select : "GT3", or {value = "gt3", label = "GT3"}
---@param c any
---@return {value: string, label: string}?
local function choice(c)
    if type(c) == "table" then
        local value = text(c.value, 48)
        if not value then return nil end
        return { value = value, label = text(c.label, 48) or value }
    end
    local value = text(c, 48)
    return value and { value = value, label = value } or nil
end

---@param o any an option as a plugin describes it
---@param where "race"|"config"|"page" (a field on a plugin's page : services/pluginPages.lua)
---@return table? option, string? why not
local function option(o, where)
    if type(o) ~= "table" then return nil, "an option must be an object" end
    local oid = id(o.id)
    if not oid then return nil, "an option's id must be a word (letters first, then letters, digits, _ or -, 32 at most)" end
    local label = text(o.label, 48)
    if not label then return nil, string.format("option %s needs a label", oid) end
    local out = { id = oid, type = o.type, label = label, tooltip = text(o.tooltip, 200) }
    if o.type == "toggle" then
        out.default = o.default == true
    elseif o.type == "select" then
        out.choices = {}
        if type(o.choices) == "table" then
            for _, c in ipairs(o.choices) do
                if #out.choices >= MAX_CHOICES then break end
                local ch = choice(c)
                if ch and not table.find(out.choices, function(x) return x.value == ch.value end) then
                    out.choices[#out.choices + 1] = ch
                end
            end
        end
        if #out.choices == 0 then return nil, string.format("option %s needs choices", oid) end
        local default = text(o.default, 48)
        out.default = default and table.find(out.choices, function(x) return x.value == default end) and default or
            out.choices[1].value
    elseif o.type == "number" then
        local min, max = tonumber(o.min) or 0, tonumber(o.max) or 100
        if min ~= min or max ~= max or max <= min then
            return nil, string.format("option %s : max must be above min", oid)
        end
        local step = tonumber(o.step) or 1
        if step ~= step or step <= 0 then step = 1 end
        out.min, out.max, out.step = min, max, step
        out.unit = text(o.unit, 12)
        out.default = math.clamp(tonumber(o.default) or min, min, max)
    elseif o.type == "text" then
        out.maxLength = math.clamp(math.floor(tonumber(o.maxLength) or TEXT_MAX_DEFAULT), 1, TEXT_MAX)
        out.placeholder = text(o.placeholder, 100)
        out.default = text(o.default, out.maxLength) or ""
        -- a password, an API key : never sent to a player's game (config tabs only)
        if where == "config" and o.secret == true then
            out.secret = true
            out.default = ""
        end
    elseif o.type == "button" and where == "config" then
        -- no value : a click goes to the plugin (ConfigAction)
        out.confirm = text(o.confirm, 200)
    else
        return nil, string.format("option %s : type must be %s", oid,
            where == "config" and "toggle, select, number, text or button" or "toggle, select, number or text")
    end
    if where == "race" then
        out.where = WHERE[o.where] and o.where or "both"
        -- its value shown on results and leaderboard entries, like a field
        out.field = o.field == true or nil
    end
    return out
end

---@param s any a section as a plugin describes it
---@param where "race"|"config"
---@param maxOptions integer
---@return table? section, string? why not
local function section(s, where, maxOptions)
    if type(s) ~= "table" then return nil, "a section must be an object" end
    local sid = id(s.id)
    if not sid then return nil, "a section's id must be a word (letters first, then letters, digits, _ or -)" end
    local out = { id = sid, title = text(s.title, 48) or sid, note = text(s.note, 300), options = {} }
    if type(s.options) ~= "table" or #s.options == 0 then
        return nil, string.format("section %s needs options", sid)
    end
    for _, o in ipairs(s.options) do
        if #out.options >= maxOptions then
            return nil, string.format("section %s : %d options at most", sid, maxOptions)
        end
        local opt, why = option(o, where)
        if not opt then return nil, why end
        if table.find(out.options, function(x) return x.id == opt.id end) then
            return nil, string.format("section %s : option %s twice", sid, opt.id)
        end
        out.options[#out.options + 1] = opt
    end
    return out
end

---@param sections any
---@param where "race"|"config"
---@param maxSections integer
---@param maxOptions integer how many options in all
---@return table[]? sections, string? why not
local function sectionsOf(sections, where, maxSections, maxOptions)
    if type(sections) ~= "table" or #sections == 0 then return nil, "sections must be a list" end
    if #sections > maxSections then return nil, string.format("%d sections at most", maxSections) end
    local out, ids, count = {}, {}, 0
    for _, s in ipairs(sections) do
        local sec, why = section(s, where, MAX_SECTION_OPTIONS)
        if not sec then return nil, why end
        for _, o in ipairs(sec.options) do
            if ids[o.id] then return nil, string.format("option %s twice (option ids are the plugin's, across sections)", o.id) end
            ids[o.id] = true
        end
        count = count + #sec.options
        if count > maxOptions then return nil, string.format("%d options at most", maxOptions) end
        out[#out + 1] = sec
    end
    return out
end

--- every option of a plugin's sections, by id
---@param sections table[]
---@return table<string, table>
local function optionsById(sections)
    local byId = {}
    for _, s in ipairs(sections or {}) do
        for _, o in ipairs(s.options) do byId[o.id] = o end
    end
    return byId
end

--- a value checked against its option : nil when it doesn't fit
---@param o table
---@param v any
---@return any
local function valueFor(o, v)
    if o.type == "toggle" then
        if type(v) == "boolean" then return v end
    elseif o.type == "select" then
        if type(v) == "string" and table.find(o.choices, function(c) return c.value == v end) then return v end
    elseif o.type == "number" then
        v = tonumber(v)
        if not v or v ~= v then return nil end
        v = math.clamp(v, o.min, o.max)
        -- on the step, from min
        v = o.min + math.floor((v - o.min) / o.step + .5) * o.step
        return math.clamp(v, o.min, o.max)
    elseif o.type == "text" then
        if type(v) == "string" then return text(v, o.maxLength) or "" end
    end
end

-- ---------------------------------------------------------------------------------------------
-- definitions to the players

---@return table what every player's game gets : the race sections, the config tabs (without values)
local function clientShape()
    local race, config = {}, {}
    local plugins = {}
    for plugin in pairs(M.raceSections) do plugins[#plugins + 1] = plugin end
    table.sort(plugins)
    for _, plugin in ipairs(plugins) do
        for _, s in ipairs(M.raceSections[plugin]) do
            local copy = table.clone(s)
            copy.plugin = plugin
            race[#race + 1] = copy
        end
    end
    plugins = {}
    for plugin in pairs(M.configTabs) do plugins[#plugins + 1] = plugin end
    table.sort(plugins)
    for _, plugin in ipairs(plugins) do
        local copy = table.clone(M.configTabs[plugin])
        copy.plugin = plugin
        config[#config + 1] = copy
    end
    return { race = race, config = config }
end

local function pushDefinitions()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "pluginUi", clientShape())
end

-- ---------------------------------------------------------------------------------------------
-- race options

---@param plugin string
---@param params table raceOptions.register's params
---@return boolean ok, string? why not
local function registerRaceOptions(plugin, params)
    local sections, why = sectionsOf(params.sections, "race", MAX_RACE_SECTIONS, MAX_RACE_SECTIONS * MAX_SECTION_OPTIONS)
    if not sections then return false, why end
    M.raceSections[plugin] = sections
    pushDefinitions()
    return true
end

---@param plugin string
local function unregisterRaceOptions(plugin)
    if not M.raceSections[plugin] then return end
    M.raceSections[plugin] = nil
    pushDefinitions()
end

--- a race's own values (the editor's) as they're saved : checked for the plugins running now,
--- kept as they were for plugins that aren't (a plugin restarting, or removed for a while, doesn't
--- wipe every race's settings)
---@param values any race.defaults.plugins as the editor sent it
---@return table
local function raceDefaults(values)
    local out = {}
    if type(values) ~= "table" then return out end
    local count = 0
    for plugin, v in pairs(values) do
        if type(plugin) == "string" and plugin:find("^[%w_%-]+$") and #plugin <= 64 and type(v) == "table" then
            local defs = M.raceSections[plugin]
            local kept = {}
            if defs then
                for oid, o in pairs(optionsById(defs)) do
                    if o.where ~= "start" then
                        local checked = valueFor(o, v[oid])
                        if checked ~= nil then kept[oid] = checked end
                    end
                end
            else
                local n = 0
                for k, x in pairs(v) do
                    if n >= MAX_RACE_SECTIONS * MAX_SECTION_OPTIONS then break end
                    if id(k) and (type(x) == "boolean" or type(x) == "number" or
                            (type(x) == "string" and #x <= TEXT_MAX)) then
                        kept[k] = x
                        n = n + 1
                    end
                end
            end
            if next(kept) then
                out[plugin] = kept
                count = count + 1
                if count >= 32 then break end
            end
        end
    end
    return out
end

--- a session's values : what the starter chose, else the race's own, else the option's default.
--- Editor-only options always take the race's ; start-only ones never do
---@param raceValues any race.defaults.plugins
---@param chosen any the start menu's
---@return table plugin -> option -> value, for the plugins running now
local function sessionValues(raceValues, chosen)
    raceValues = type(raceValues) == "table" and raceValues or {}
    chosen = type(chosen) == "table" and chosen or {}
    local out = {}
    for plugin, sections in pairs(M.raceSections) do
        local fromRace = type(raceValues[plugin]) == "table" and raceValues[plugin] or {}
        local fromStart = type(chosen[plugin]) == "table" and chosen[plugin] or {}
        local values = {}
        for oid, o in pairs(optionsById(sections)) do
            local v
            if o.where ~= "editor" then v = valueFor(o, fromStart[oid]) end
            if v == nil and o.where ~= "start" then v = valueFor(o, fromRace[oid]) end
            if v == nil then v = o.default end
            values[oid] = v
        end
        out[plugin] = values
    end
    return out
end

-- ---------------------------------------------------------------------------------------------
-- fields

---@param f any {label?, value, color?, showLabel?} or the value alone
---@param key string
---@param order integer
---@return table?
local function field(f, key, order)
    if type(f) ~= "table" then f = { value = f } end
    local value = f.value
    if type(value) == "boolean" then value = value and "✓" or nil end
    value = text(value, 48)
    if not value then return nil end
    return {
        label = text(f.label, 24) or key,
        value = value,
        color = services_pluginOverlay.cleanColor(f.color),
        showLabel = f.showLabel == true or nil,
        order = order,
    }
end

--- a plugin's fields as it sends them : a list of {key, label?, value, color?, showLabel?}, or an
--- object of key -> value or {label?, value, ...}. A key sent with no value (empty, null) goes
---@param input any
---@return table<string, table|false>? key -> field, or false to remove ; nil, why when it's wrong
---@return string? why not
local function fieldsOf(input)
    if type(input) ~= "table" then return nil, "fields must be a list or an object" end
    local out, n = {}, 0
    local function add(key, f, order)
        key = id(key)
        if not key then return "a field's key must be a word (letters first, then letters, digits, _ or -)" end
        local checked = field(f, key, order)
        if checked then
            n = n + 1
            if n > MAX_FIELDS then return string.format("%d fields at most", MAX_FIELDS) end
        end
        out[key] = checked or false
    end
    if #input > 0 then
        for i, f in ipairs(input) do
            if type(f) ~= "table" then return nil, "each field in a list must be {key, value, ...}" end
            local why = add(f.key, f, i)
            if why then return nil, why end
        end
    else
        local keys = {}
        for k in pairs(input) do
            if type(k) ~= "string" then return nil, "fields must be a list or an object" end
            keys[#keys + 1] = k
        end
        table.sort(keys)
        for i, k in ipairs(keys) do
            local f = input[k]
            if absent(f) or f == "" then f = nil end
            local why = add(k, f, i)
            if why then return nil, why end
        end
    end
    return out
end

--- applies a plugin's fields onto a holder's (a participant's, an entry's) : its own replace what
--- it had (`replace`), or are merged into them
---@param holder table<string, table>? plugin -> key -> field
---@param plugin string
---@param fields table<string, table|false>
---@param replace boolean?
---@return table<string, table>? the holder's fields, nil when none are left
local function applyFields(holder, plugin, fields, replace)
    holder = holder or {}
    local mine = (not replace and holder[plugin]) and table.clone(holder[plugin]) or {}
    for key, f in pairs(fields) do mine[key] = f or nil end
    local count = 0
    for _ in pairs(mine) do count = count + 1 end
    while count > MAX_FIELDS do
        -- the last ones in order go
        local last, lastOrder
        for key, f in pairs(mine) do
            if not lastOrder or f.order > lastOrder then last, lastOrder = key, f.order end
        end
        mine[last] = nil
        count = count - 1
    end
    holder[plugin] = next(mine) and mine or nil
    return next(holder) and holder or nil
end

--- the race options marked `field`, as fields : a session's values shown on its results
---@param values table? settings.plugins
---@return table<string, table>? plugin -> key -> field
local function optionFields(values)
    if type(values) ~= "table" then return nil end
    local out
    for plugin, sections in pairs(M.raceSections) do
        local vals = values[plugin]
        if type(vals) == "table" then
            local order = 0
            for _, s in ipairs(sections) do
                for _, o in ipairs(s.options) do
                    order = order + 1
                    local v = vals[o.id]
                    if o.field and v ~= nil then
                        local shown
                        if o.type == "toggle" then
                            -- a toggle shows its name while on
                            shown = v == true and { label = o.label, value = o.label } or nil
                        elseif o.type == "select" then
                            local c = table.find(o.choices, function(x) return x.value == v end)
                            shown = c and { label = o.label, value = c.label } or nil
                        elseif o.type == "number" then
                            shown = { label = o.label, value = tostring(v) .. (o.unit and (" " .. o.unit) or ""),
                                showLabel = true }
                        elseif type(v) == "string" and #v > 0 then
                            shown = { label = o.label, value = v }
                        end
                        local f = shown and field(shown, o.id, order)
                        if f then
                            out = out or {}
                            out[plugin] = out[plugin] or {}
                            out[plugin][o.id] = f
                        end
                    end
                end
            end
        end
    end
    return out
end

--- a racer's fields : the session's option fields, then their own on top (the plugin's own key
--- wins)
---@param session table BJRaceSession
---@param p table BJRaceParticipant
---@return table<string, table>? plugin -> key -> field
local function racerFields(session, p)
    local out = optionFields(session.settings and session.settings.plugins)
    for plugin, fields in pairs(p.pluginFields or {}) do
        out = out or {}
        out[plugin] = out[plugin] and table.assign(table.clone(out[plugin]), fields) or table.clone(fields)
    end
    return out
end

--- fields as a list, the way they're shown : by plugin, then in the plugin's order
---@param fields table<string, table>? plugin -> key -> field
---@return table[] {plugin, key, label, value, color, showLabel}
local function fieldList(fields)
    local list = {}
    if type(fields) ~= "table" then return list end
    for plugin, mine in pairs(fields) do
        if type(mine) == "table" then
            for key, f in pairs(mine) do
                if type(f) == "table" and f.value then
                    list[#list + 1] = { plugin = plugin, key = key, label = f.label or key, value = f.value,
                        color = f.color, showLabel = f.showLabel, order = f.order or 0 }
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.plugin ~= b.plugin then return a.plugin < b.plugin end
        if a.order ~= b.order then return a.order < b.order end
        return a.key < b.key
    end)
    for _, f in ipairs(list) do f.order = nil end
    return list
end

-- ---------------------------------------------------------------------------------------------
-- config tabs

local function loadConfigValues()
    if M.configValues then return end
    local stored = dao_main.get(M.CONFIG_FILE)
    M.configValues = type(stored) == "table" and stored or {}
end

local function saveConfigValues()
    dao_main.save(M.CONFIG_FILE, M.configValues)
end

--- a plugin's config : its stored values, its defaults for the rest
---@param plugin string
---@param masked boolean? secrets left out (for a player's game) : `set` says whether they are
---@return table values, table<string, boolean>? secretsSet
local function configOf(plugin, masked)
    loadConfigValues()
    local stored = type(M.configValues[plugin]) == "table" and M.configValues[plugin] or {}
    local tab = M.configTabs[plugin]
    local values, secrets = {}, nil
    if not tab then
        for k, v in pairs(stored) do values[k] = v end
        return values
    end
    for oid, o in pairs(optionsById(tab.sections)) do
        if o.type ~= "button" then
            local v = valueFor(o, stored[oid])
            if v == nil then v = o.default end
            if o.secret and masked then
                secrets = secrets or {}
                secrets[oid] = type(v) == "string" and #v > 0
                v = ""
            end
            values[oid] = v
        end
    end
    return values, secrets
end

---@param plugin string
---@param params table config.register's params
---@return boolean ok, string? why not
local function registerConfigTab(plugin, params)
    local sections, why = sectionsOf(params.sections, "config", MAX_CONFIG_SECTIONS, MAX_CONFIG_OPTIONS)
    if not sections then return false, why end
    M.configTabs[plugin] = { title = text(params.title, 32) or plugin, sections = sections }
    loadConfigValues()
    pushDefinitions()
    return true
end

---@param plugin string
local function unregisterConfigTab(plugin)
    if not M.configTabs[plugin] then return end
    M.configTabs[plugin] = nil
    pushDefinitions()
end

--- sets a plugin's config values : the ones given that fit, the rest stay
---@param plugin string
---@param values table option id -> value
---@param keepEmptySecrets boolean? a secret sent empty keeps the one stored (the config tab never
---gets them, so it sends them empty unless someone typed a new one)
---@return table<string, any> what changed
local function setConfig(plugin, values, keepEmptySecrets)
    loadConfigValues()
    local tab = M.configTabs[plugin]
    local stored = type(M.configValues[plugin]) == "table" and M.configValues[plugin] or {}
    local changed = {}
    for oid, o in pairs(optionsById(tab and tab.sections)) do
        local v = valueFor(o, values[oid])
        if v ~= nil and not (o.secret and keepEmptySecrets and v == "") and stored[oid] ~= v then
            stored[oid] = v
            changed[oid] = v
        end
    end
    M.configValues[plugin] = stored
    if next(changed) then saveConfigValues() end
    return changed
end

---@param playerID integer
---@return boolean
local function canEditConfig(playerID)
    return services_permissions.hasAllPermissions(playerID, BJ_PERMISSIONS.EditPluginConfig)
end

--- one plugin's values, to the staff who asked (the config tab, opening)
---@param ctxt BJSContext
---@param plugin string
local function onConfigValuesRequest(ctxt, plugin)
    if not ctxt.sender or type(plugin) ~= "string" or not M.configTabs[plugin] then return end
    if not canEditConfig(ctxt.senderID) then return end
    local values, secrets = configOf(plugin, true)
    communications_tx.sendToPlayer(ctxt.senderID, "pluginConfigValues", plugin, values, secrets or {})
end

---@param ctxt BJSContext
---@param plugin string
---@param values table
local function onConfigSave(ctxt, plugin, values)
    if not ctxt.sender or type(plugin) ~= "string" or not M.configTabs[plugin] or type(values) ~= "table" then
        return
    end
    if not canEditConfig(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.insufficientPermissions", ctxt.sender.lang))
    end
    local changed = setConfig(plugin, values, true)
    if next(changed) and services_api then
        local keys = {}
        for k in pairs(changed) do keys[#keys + 1] = k end
        table.sort(keys)
        services_api.configChanged(plugin, configOf(plugin), keys, ctxt.sender.playerName)
    end
    communications_tx.sendToPlayer(ctxt.senderID, "toast", "success",
        services_lang.get("pluginConfig.saved", ctxt.sender.lang):var({ name = M.configTabs[plugin].title }))
    -- everyone with the tab open sees the new values
    local masked, secrets = configOf(plugin, true)
    services_players.players:forEach(function(p)
        if canEditConfig(p.playerID) then
            communications_tx.sendToPlayer(p.playerID, "pluginConfigValues", plugin, masked, secrets or {})
        end
    end)
end

---@param ctxt BJSContext
---@param plugin string
---@param action string a button's id
local function onConfigAction(ctxt, plugin, action)
    if not ctxt.sender or type(plugin) ~= "string" or not M.configTabs[plugin] then return end
    if not canEditConfig(ctxt.senderID) then return end
    local o = optionsById(M.configTabs[plugin].sections)[action]
    if not o or o.type ~= "button" then return end
    if services_api then
        services_api.configAction(plugin, action, { id = ctxt.senderID, name = ctxt.sender.playerName })
    end
end

-- ---------------------------------------------------------------------------------------------

local function onInit()
    communications_rx.addHandler("pluginConfigValuesRequest", onConfigValuesRequest)
    communications_rx.addHandler("pluginConfigSave", onConfigSave)
    communications_rx.addHandler("pluginConfigAction", onConfigAction)
end

local function onBJRequestCache(caches)
    caches.pluginUi = clientShape()
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache

M.registerRaceOptions = registerRaceOptions
M.unregisterRaceOptions = unregisterRaceOptions
M.raceDefaults = raceDefaults
M.sessionValues = sessionValues
M.fieldsOf = fieldsOf
M.applyFields = applyFields
M.racerFields = racerFields
M.fieldList = fieldList
M.registerConfigTab = registerConfigTab
M.unregisterConfigTab = unregisterConfigTab
M.configOf = configOf
M.setConfig = setConfig
-- the same checks, for the fields on plugins' pages (services/pluginPages.lua)
M.cleanOption = option
M.valueFor = valueFor
M.onConfigValuesRequest = onConfigValuesRequest
M.onConfigSave = onConfigSave
M.onConfigAction = onConfigAction

return M
