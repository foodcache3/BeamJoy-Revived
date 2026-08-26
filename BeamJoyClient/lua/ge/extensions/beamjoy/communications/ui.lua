local M = {
    preloadedDependencies = { "ui_apps", "ui_appLayouts", "core_gamestate" },
    dependencies = {},
    APP_SIZES = {
        {
            name = "beamjoy-main",
            -- must be kept in sync with ui/modules/apps/BeamJoy-Main/app.json's own css.top:
            -- that file's own css block is NOT what actually drives the rendered default position,
            -- this table is (sendWindowsSizesAndPositions below reads app.defaultTop, never
            -- app.json at all). A previous round changed app.json alone, which was a complete
            -- no-op for the real position because this duplicate never got updated to match.
            defaultTop = "60vh",
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

--- Also used for the version-mismatch check (windows/versionCheck): that component requests
--- this itself on mount rather than relying solely on the one-time push below, since a component
--- mounted after this push already fired (a real, observed race, see its own file comment) would
--- otherwise miss it entirely and never detect a real mismatch.
local function sendVersion()
    M.send("BJVersion", { version = beamjoy_main.VERSION, build = beamjoy_main.BUILD })
end

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
        -- one-time push for the Settings tab's About section (version/build display + GitHub link)
        sendVersion()
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
    M.addHandler("BJRequestOpenWindow", M.requestOpenWindow)
    M.addHandler("BJReady", onUIReady)
    M.addHandler("BJVersionRequest", sendVersion)

    M.addHandler("BJRequestIntroPanelData", M.getIntroPanelData)
    M.addHandler("BJSaveIntroPanelData", M.saveIntroPanelData)
    M.addHandler("BJOpenIntroPanel", M.openIntroPanel)
    M.addHandler("BJResetIntroPanelData", M.saveIntroPanelData)
    M.addHandler("BJRequestIntroPanelImagesInFolder", M.listIntroPanelImagesInFolder)
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

--- true whenever the main window should be forced open and non-closable for the CURRENT player:
--- staff always have this (regardless of config), or every player does when the host has
--- turned on ForceHud (services_config.data.ForceHud, default on). One place for this so
--- onBJUpdateSelf/initWindows/toggleWindow can't drift out of sync with each other the way the
--- COUNTDOWN/RACE restriction checks did earlier.
---@return boolean
local function isMainForced()
    return beamjoy_permissions.isStaff() or beamjoy_config.data.ForceHud == true
end

local function onBJUpdateSelf()
    local forced = isMainForced()
    -- config window visibility is gated on canOpenConfig() (isStaff OR any config-tab permission,
    -- see permissions.lua), NOT isStaff alone. Gating on isStaff alone used to force-close/hide the
    -- config window for anyone not ranked "staff" even if they'd been individually granted e.g.
    -- EditRaces (the real bug behind "non-staff players with EditRaces can't open the config
    -- menu"; imgui/menu.lua's menu item had the identical bug and is fixed the same way).
    -- "main" stays forced-specific on purpose: every player gets that window regardless of
    -- permissions when isMainForced() is true, staff/ForceHud just can't close theirs.
    local canOpenConfig = beamjoy_permissions.canOpenConfig()
    if not canOpenConfig then
        M.windowStates.config = false
    end
    M.send("BJUpdateWindowSettings", {
        ["beamjoy-main"] = {
            visible = forced or M.windowStates.main,
            closable = not forced,
        },
        ["beamjoy-config"] = {
            visible = canOpenConfig and M.windowStates.config,
            closable = true,
        },
    })
end

local function initWindows()
    local forced = isMainForced()
    -- host-configurable, default on (services_config.data.ShowHudAtStart): opens the main window
    -- automatically on connect even when it isn't forced-non-closable. Moot when isMainForced()
    -- is already true (that already implies visible from the start); matters when it's off, so a
    -- host can choose "starts open, but players may still close it" as a middle ground between
    -- always-forced and the original "closed until manually opened" default.
    if forced or beamjoy_config.data.ShowHudAtStart == true then
        M.windowStates.main = true
    end
    M.send("BJUpdateWindowSettings", {
        ["beamjoy-main"] = {
            visible = forced or M.windowStates.main,
            closable = not forced,
        },
        ["beamjoy-config"] = {
            visible = false,
            closable = true,
        },
    })
end

local function toggleWindow(windowName)
    -- closing "config" specifically (not opening it) has to go through Angular's own guarded
    -- close flow (the same one the in-window X button already uses) instead of being forced
    -- shut directly from here, since the race editor may have unsaved changes, which is purely
    -- Angular-side state this module has no visibility into. This ImGui menu item was the one
    -- remaining way to close the window that bypassed the discard-changes confirm entirely (the
    -- in-window X button and BJCloseWindow already round-trip through it correctly).
    if windowName == "config" and M.windowStates.config then
        M.send("BJRequestCloseWindow", "config")
        return
    end
    M.windowStates[windowName] = not M.windowStates[windowName]
    local visible, closable
    if windowName == "main" then
        if isMainForced() then
            M.windowStates[windowName] = true
            visible = true
            closable = false
        else
            visible = M.windowStates[windowName]
            closable = true
        end
    elseif windowName == "config" then
        closable = true
        -- see onBJUpdateSelf's own comment above: canOpenConfig(), not isStaff alone
        visible = beamjoy_permissions.canOpenConfig() and M.windowStates[windowName] or false
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

--- Angular-initiated "make sure this window is open" (e.g. an in-window shortcut button), as
--- opposed to toggleWindow's blind flip (fine for the ImGui menu item, which already knows the
--- window's current state from its own checkbox). Idempotent: does nothing if already open,
--- rather than closing it. Permission gating for "config" specifically still goes through
--- toggleWindow's own canOpenConfig() check either way, this is just the open/no-op decision.
---@param windowName string
local function requestOpenWindow(windowName)
    if M.windowStates[windowName] == false then
        M.toggleWindow(windowName)
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

local INTRO_PANEL_IMAGE_EXTENSIONS = { "jpg", "jpeg", "png", "gif", "webp", "bmp" }

--- Lists image files sitting in a folder within the game's own merged virtual filesystem -- this
--- includes files delivered by any currently-active mod (including a BeamMP server's own
--- Resources/Client/ resource, the same mechanism that already delivers BJ.zip itself), so an
--- admin can point this at a folder from their own custom-image resource zip and pick a file from
--- a list instead of typing its exact path by hand. Non-recursive (folderPath's own direct
--- contents only, matching FS:findFiles' 3-arg call convention already used by lang.lua elsewhere
--- in this codebase) -- a subfolder isn't walked into, keeping the returned list flat and simple.
---@param folderPath string a root-relative folder path, e.g. "/myWelcomeStuff"
local function listIntroPanelImagesInFolder(folderPath)
    local images = {}
    if type(folderPath) == "string" and folderPath ~= "" then
        if folderPath:sub(1, 1) ~= "/" then
            folderPath = "/" .. folderPath
        end
        for _, ext in ipairs(INTRO_PANEL_IMAGE_EXTENSIONS) do
            local found = FS:findFiles(folderPath, "*." .. ext, 0) or {}
            for _, f in ipairs(found) do
                table.insert(images, f)
            end
        end
        table.sort(images)
    end
    M.send("BJSendIntroPanelImagesInFolder", { folderPath = folderPath, images = images })
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
M.isMainForced = isMainForced
M.closeWindow = closeWindow
M.requestOpenWindow = requestOpenWindow
M.getIntroPanelData = getIntroPanelData
M.saveIntroPanelData = saveIntroPanelData
M.listIntroPanelImagesInFolder = listIntroPanelImagesInFolder
M.openIntroPanel = openIntroPanel
M.uiBroadcast = broadcast

return M

-- if stuck in loading screen
-- core_gamestate.requestExitLoadingScreen("serverConnection")
-- if stuck in infinite load
-- guihooks.trigger("app:waiting", false)
