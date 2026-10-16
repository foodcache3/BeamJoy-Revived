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

    -- league points, on the result (and the leaderboard entry, when this run set it)
    BJ.on("RacerFinished", function(data)
        -- every race event carries the race's options
        local mine = data.options and data.options[NAME] or {}
        if mine.points == false or not data.racer.id then return end
        local points = POINTS[data.finishOrder] or 0
        BJ.call("results.setFields", {
            sessionId = data.sessionId,
            playerId = data.racer.id,
            fields = { { key = "points", label = "Points", value = points .. " pts", color = "accent" } },
        }, function(ok, err)
            if not ok then log("results.setFields failed : " .. tostring(err.message)) end
        end)
    end)
end
