--[[
BJClasses : an example plugin for BeamJoy's plugin API, adding race classes. It uses the parts of
the API that add to BeamJoy's own windows. Meant to be read, then copied and changed.

- Race options : a "Classes" section in the race editor and the race start menu. The editor sets a
  race's class, the start menu can change it for one race. The class shows on the results and on
  the leaderboard entry of the run (`field`). "League points" is set in the editor only.
- Config tab : a "Classes" tab in BeamJoy's config window (staff with EditPluginConfig), with the
  cars allowed in each class. BeamJoy stores what's set there.
- Ready check : a car that isn't in the race's class can't ready up, with the reason shown.
- Fields : league points on each finisher's result, and on their leaderboard entry when the race
  set it (25, 18, 15...).
- Page : a "League" page in the main window (a rail button and a tab in the full window) with the
  standings since the server started. Opening it gives each player their own version (their
  place), and a class picked there with "Show" narrows it down for them.

Install : copy this whole folder into Resources/Server/ (next to BeamJoyServer), restart the
server, then fill in the cars in the config window's Classes tab.
]]

-- this file's own path : Resources/Server/BJClasses/main.lua
local here = debug.getinfo(1).source:gsub("^@", ""):gsub("\\", "/")
local folder = here:match("^(.*)/[^/]*$") or "."
local BJ = dofile((folder:match("^(.*)/[^/]+$") or "..") .. "/BeamJoyServer/api/BeamJoyAPI.lua")

local NAME = "BJClasses"
local CLASSES = { { value = "gt", label = "GT" }, { value = "touring", label = "Touring" },
    { value = "street", label = "Street" } }
local POINTS = { 25, 18, 15, 12, 10, 8, 6, 4, 2, 1 }

local function log(msg) print("[" .. NAME .. "] " .. msg) end

--- the config tab's values (BeamJoy keeps them ; they come with every change)
local config = {}
--- league points since the server started : class -> player name -> points
local standings = {}
--- players with their own League page : player ID -> {name, class} (the class picked, or "all")
local viewers = {}

--- "ETK 800 Series, Sunburst" -> { ["etk 800 series"] = true, sunburst = true }
local function carList(text)
    local set, any = {}, false
    for name in tostring(text or ""):gmatch("[^,]+") do
        name = name:match("^%s*(.-)%s*$"):lower()
        if #name > 0 then set[name], any = true, true end
    end
    return any and set or nil
end

local function classLabel(value)
    for _, c in ipairs(CLASSES) do
        if c.value == value then return c.label end
    end
    return value
end

--- the League page's blocks : the standings for a class (or "all"), with `you` (a name) marked
local function leagueBlocks(class, you)
    local totals = {}
    for c, names in pairs(standings) do
        if class == "all" or class == c then
            for name, points in pairs(names) do totals[name] = (totals[name] or 0) + points end
        end
    end
    local list = {}
    for name, points in pairs(totals) do list[#list + 1] = { name = name, points = points } end
    table.sort(list, function(a, b)
        if a.points ~= b.points then return a.points > b.points end
        return a.name < b.name
    end)

    local choices = { { value = "all", label = "All" } }
    for _, c in ipairs(CLASSES) do choices[#choices + 1] = c end
    local blocks = {
        { type = "heading", text = "Standings", sub = class == "all" and "Every class, since the server started"
            or (classLabel(class) .. " class, since the server started") },
        { type = "field", control = "select", id = "class", label = "Class", choices = choices, default = class },
        { type = "buttons", items = { { id = "show", label = "Show", style = "primary" } } },
        { type = "divider" },
    }
    if #list == 0 then
        blocks[#blocks + 1] = { type = "text", text = "No points yet : finish a race with League points on.",
            color = "muted" }
        return blocks
    end
    if you then
        for i, row in ipairs(list) do
            if row.name == you then
                blocks[#blocks + 1] = { type = "plate", text = tostring(i), sub = row.points .. " pts : your place" }
            end
        end
    end
    local rows = {}
    for i, row in ipairs(list) do
        if i > 20 then break end
        rows[#rows + 1] = { cells = { tostring(i), row.name, { text = row.points .. " pts", align = "right" } },
            you = row.name == you or nil }
    end
    blocks[#blocks + 1] = { type = "table", columns = { { label = "#" }, { label = "Driver" },
        { label = "Points", align = "right" } }, rows = rows }
    return blocks
end

--- the League page as one player sees it (their own content)
local function showLeague(id)
    local v = viewers[id]
    if v then BJ.updatePage("league", leagueBlocks(v.class, v.name), { id }) end
end

function onInit()
    BJ.init(NAME)

    -- the race editor and the race start menu
    BJ.raceOptions({
        {
            id = "classes",
            title = "Classes",
            note = "Which cars may race : the cars of each class are set in the config window's Classes tab.",
            options = {
                { id = "class", type = "select", label = "Class", choices = CLASSES, default = "street",
                    field = true, tooltip = "Shown on the results and the leaderboard" },
                { id = "points", type = "toggle", label = "League points", where = "editor", default = true,
                    tooltip = "Finishers get league points on their result" },
            },
        },
    })

    -- the config window
    local options = {}
    for _, c in ipairs(CLASSES) do
        options[#options + 1] = { id = "cars_" .. c.value, type = "text", label = c.label .. " cars", maxLength = 400,
            placeholder = "Vehicle names, separated by commas (empty : any car)" }
    end
    options[#options + 1] = { id = "enforce", type = "toggle", label = "Refuse other cars", default = true }
    options[#options + 1] = { id = "show", type = "button", label = "Print the classes in the server console" }
    BJ.configTab({ title = "Classes", sections = { { id = "cars", title = "Cars per class", options = options } } },
        function(values, changed, by)
            config = values
            if by then log("classes changed by " .. tostring(by)) end
        end)
    BJ.onConfigAction(function(action, by)
        if action ~= "show" then return end
        for _, c in ipairs(CLASSES) do
            log(string.format("%s : %s", c.label, config["cars_" .. c.value] ~= "" and config["cars_" .. c.value] or "any car"))
        end
        log("(asked by " .. tostring(by and by.name) .. ")")
    end)

    -- a car outside the race's class can't ready up
    BJ.hook("raceReady", function(q)
        local mine = q.session.options and q.session.options[NAME] or {}
        local class = mine.class
        local allowed = class and carList(config["cars_" .. class])
        if not allowed or config.enforce == false then return { allow = true } end
        if not allowed[tostring(q.racer.vehicle or ""):lower()] then
            return { allow = false, reason = string.format("This is a %s race : your car isn't in the %s class",
                classLabel(class), classLabel(class)) }
        end
        return { allow = true }
    end)

    -- the League page : a rail button and a full window tab ; everyone's content is the
    -- standings, each player gets their own once they open it
    BJ.page({ id = "league", title = "League", icon = "trophy", blocks = leagueBlocks("all") })
    BJ.onPageOpened(function(pageId, by)
        if pageId ~= "league" then return end
        viewers[by.id] = viewers[by.id] or { name = by.name, class = "all" }
        showLeague(by.id)
    end)
    BJ.onPageAction(function(pageId, action, values, by)
        if pageId ~= "league" or action ~= "show" then return end
        viewers[by.id] = { name = by.name, class = values.class }
        showLeague(by.id)
    end)
    BJ.on("PlayerLeft", function(data) viewers[data.id] = nil end)

    -- league points, on the result (and the leaderboard entry, when this run set it)
    BJ.on("RacerFinished", function(data)
        -- every race event carries the race's options
        local mine = data.options and data.options[NAME] or {}
        if mine.points == false or not data.racer.id then return end
        local points = POINTS[data.finishOrder] or 0
        -- the standings, and the League page for everyone (and whoever has their own)
        local class = mine.class or "street"
        standings[class] = standings[class] or {}
        standings[class][data.racer.name] = (standings[class][data.racer.name] or 0) + points
        BJ.updatePage("league", leagueBlocks("all"))
        for id in pairs(viewers) do showLeague(id) end
        BJ.call("results.setFields", {
            sessionId = data.sessionId,
            playerId = data.racer.id,
            fields = { { key = "points", label = "Points", value = points .. " pts", color = "accent" } },
        }, function(ok, err)
            if not ok then log("results.setFields failed : " .. tostring(err.message)) end
        end)
    end)
end
