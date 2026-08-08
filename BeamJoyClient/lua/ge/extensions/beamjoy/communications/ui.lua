local M = {
    preloadedDependencies = { "ui_apps", "ui_appLayouts", "core_gamestate" },
    dependencies = {},
    APP_SIZES = {
        {
            name = "beamjoy-main",
            defaultTop = "4vh",
            defaultLeft = ".5vw",
            defaultWidth = "21vw",
            defaultHeight = "30vh",
        },
        {
            name = "beamjoy-hud",
            defaultTop = "10vh",
            defaultLeft = "22vw",
            defaultWidth = "56vw",
            defaultHeight = "15vh",
        },
        {
            name = "beamjoy-config",
            defaultTop = "15vh",
            defaultLeft = "65vw",
            defaultWidth = "34.5vw",
            defaultHeight = "60vh",
        },
    },

    windowStates = {
        main = false,
        config = false,
    },

    EVENT = "BJEvent",
    handlers = Table(),
}
AddPreloadedDependencies(M)

local function onUIReady()
    beamjoy_lang.initLang()
    beamjoy_communications.send("clientConnection", beamjoy_lang.lang)
    core_jobsystem.create(function(job)
        job.sleep(2)
        while not beamjoy_cache.loaded do
            job.sleep(.01)
        end
        M.initWindows()
        M.sendWindowsSizesAndPositions()
        extensions.core_gamestate.requestExitLoadingScreen("serverConnection")
        uiHelpers.hideGameMenu()

        if beamjoy_config.data.IntroPanel.enabled then
            async.delayTask(function()
                local self
                while not self do
                    self = beamjoy_players.getSelf()
                    job.sleep(.2)
                end
                if not beamjoy_config.data.IntroPanel.onlyFirstConnection or
                    self.firstConnection then
                    M.openIntroPanel()
                end
            end, 500, "BJJoinIntroPanel")
        end
    end)
end

local function onInit()
    InitPreloadedDependencies(M)
    M.addHandler("BJRequestWindowsSizesAndPositions", M.sendWindowsSizesAndPositions)
    M.addHandler("BJCloseWindow", M.closeWindow)
    M.addHandler("BJReady", onUIReady)

    M.addHandler("BJRequestIntroPanelData", M.getIntroPanelData)
    M.addHandler("BJSaveIntroPanelData", M.saveIntroPanelData)
    M.addHandler("BJOpenIntroPanel", M.openIntroPanel)
    M.addHandler("BJResetIntroPanelData", M.saveIntroPanelData)
    beamjoy_communications.addHandler("sendCache", function(caches)
        if caches.config then
            async.delayTask(M.getIntroPanelData, 0)
        end
    end)
    beamjoy_communications.addHandler("UISend", function(event, payload)
        M.send(event, payload)
    end)
    beamjoy_communications.addHandler("uiBroadcast", M.uiBroadcast)
end

local function onBJClientReady()
    core_jobsystem.create(function(job)
        extensions.core_gamestate.requestExitLoadingScreen("serverConnection")
        uiHelpers.hideGameMenu()
        job.sleep(1)
        reloadUI()
    end)
end

local function onServerLeave()
    M.send("BJUnload")
end

---@param key string
---@param payload any
local function send(key, payload)
    guihooks.trigger(M.EVENT, { event = key, payload = payload })
end

---@param key string
---@param callback fun(...)
---@return string
local function addHandler(key, callback)
    local id = UUID()
    M.handlers[id] = { key = key, callback = callback }
    return id
end

--- Entry point for UI calls
---@param key string
---@param payload any
local function dispatch(key, payload)
    local result
    M.handlers:filter(function(h)
        return h.key == key
    end):forEach(function(h)
        result = h.callback(table.unpack(payload or {}, 1, 20)) or result
    end)
    return result
end

local function sendWindowsSizesAndPositions()
    local layout = table.filter((extensions.ui_appLayouts and extensions.ui_appLayouts.getAvailableLayouts and extensions.ui_appLayouts.getAvailableLayouts()) or {}, function(l)
        return l.type == extensions.core_gamestate.state.appLayout
    end)[1]
    local res = {}
    for _, app in ipairs(M.APP_SIZES) do
        local existing = table.find(layout and layout.apps or {}, function(el)
            return el.appName == app.name
        end)
        if not existing then
            res[app.name] = {
                top = app.defaultTop,
                left = app.defaultLeft,
                width = app.defaultWidth,
                height = app.defaultHeight
            }
        else
            res[app.name] = {}
            if existing.placement.top == 0 and
                existing.placement.bottom == 0 then
                res[app.name].top = string.format("calc(50vh - (%s / 2))", existing.placement.height)
            elseif type(existing.placement.top) == "string" and
                #existing.placement.top > 0 then
                res[app.name].top = existing.placement.top
            else
                res[app.name].top = string.format("calc(100vh - %s - %s)",
                    existing.placement.bottom, existing.placement.height)
            end

            if existing.placement.left == 0 and
                existing.placement.right == 0 then
                res[app.name].left = string.format("calc(50vw - (%s / 2))", existing.placement.width)
            elseif type(existing.placement.left) == "string" and
                #existing.placement.left > 0 then
                res[app.name].left = existing.placement.left
            else
                res[app.name].left = string.format("calc(100vw - %s - %s)",
                    existing.placement.right, existing.placement.width)
            end
            res[app.name].width = existing.placement.width
            res[app.name].height = existing.placement.height
        end
    end
    M.send("BJSendAppsSizesAndPositions", res)
    return res
end

local function onBJUpdateSelf()
    local staff = beamjoy_permissions.isStaff()
    if not staff then
        M.windowStates.config = false
    end
    M.send("BJUpdateWindowSettings", {
        ["beamjoy-main"] = {
            visible = staff or M.windowStates.main,
            closable = not staff,
        },
        ["beamjoy-config"] = {
            visible = staff and M.windowStates.config,
            closable = true,
        },
    })
end

local function initWindows()
    local staff = beamjoy_permissions.isStaff()
    M.send("BJUpdateWindowSettings", {
        ["beamjoy-main"] = {
            visible = staff,
            closable = not staff,
        },
        ["beamjoy-config"] = {
            visible = false,
            closable = true,
        },
    })
end

local function toggleWindow(windowName)
    M.windowStates[windowName] = not M.windowStates[windowName]
    local visible, closable
    if windowName == "main" then
        local staff = beamjoy_permissions.isStaff()
        if staff then
            M.windowStates[windowName] = true
            visible = true
            closable = false
        else
            visible = M.windowStates[windowName]
            closable = true
        end
    elseif windowName == "config" then
        closable = true
        local staff = beamjoy_permissions.isStaff()
        visible = staff and M.windowStates[windowName] or false
    else
        return -- invalid window
    end
    M.send("BJUpdateWindowSettings", {
        ["beamjoy-" .. windowName] = {
            visible = visible,
            closable = closable,
        }
    })
    if visible then -- refresh on first drawn
        M.sendWindowsSizesAndPositions()
    end
end

local function closeWindow(windowName)
    if M.windowStates[windowName] ~= nil then
        M.windowStates[windowName] = false
        guihooks.trigger("BJUpdateWindowSettings", {
            ["beamjoy-" .. windowName] = {
                visible = false,
                closable = false,
            }
        })
    end
end

local function getIntroPanelData()
    local payload = {
        settings = beamjoy_config.data.IntroPanel,
        images = table.map(uiHelpers.PANEL_IMAGES, function(v, k)
            return {
                value = v,
                label = tostring(k):gsub("_", " "):capitalizeWords(),
            }
        end):values():sort(function(a, b) return a.label < b.label end),
    }
    payload.settings.image = payload.settings.image or uiHelpers.PANEL_IMAGES.WELCOME
    M.send("BJSendIntroPanelData", payload)
    return payload
end

---@param data table
local function saveIntroPanelData(data)
    if beamjoy_permissions.isStaff() then
        beamjoy_communications.send("setConfig", "IntroPanel", data)
    end
end

---@param title string?
---@param content string?
---@param image string?
local function openIntroPanel(title, content, image)
    uiHelpers.openPanel(title or beamjoy_config.data.IntroPanel.title,
        content or beamjoy_config.data.IntroPanel.content,
        image or beamjoy_config.data.IntroPanel.image)
end

---@param message string label or key
---@param messageParams table?
---@param color string? cssColor default white
---@param durationSecs number? default infinite
local function broadcast(message, messageParams, color, durationSecs)
    local finalMsg = string.var(beamjoy_lang.translate(message, message),
        table.map(messageParams or {}, function(v)
            return beamjoy_lang.translate(v, v)
        end))
    M.send("BJHUDText", {
        message = finalMsg,
        color = color,
        duration = durationSecs and durationSecs * 1000 or nil,
    })
end

M.onInit = onInit
M.onBJClientReady = onBJClientReady
M.onServerLeave = onServerLeave
M.onLayoutsChanged = sendWindowsSizesAndPositions
M.onBJUpdateSelf = onBJUpdateSelf

M.send = send
M.addHandler = addHandler
M.dispatch = dispatch
M.sendWindowsSizesAndPositions = sendWindowsSizesAndPositions
M.initWindows = initWindows
M.toggleWindow = toggleWindow
M.closeWindow = closeWindow
M.getIntroPanelData = getIntroPanelData
M.saveIntroPanelData = saveIntroPanelData
M.openIntroPanel = openIntroPanel
M.uiBroadcast = broadcast

return M

-- if stuck in loading screen
-- core_gamestate.requestExitLoadingScreen("serverConnection")
-- if stuck in infinite load
-- guihooks.trigger("app:waiting", false)
