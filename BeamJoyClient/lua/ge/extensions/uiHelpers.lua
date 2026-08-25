local M = {
    loadingCallbackDelay = .5,
    ---@type fun(ctxt: TickContext)?
    loadingCallback = nil,

    popupCallbacks = {},

    TOAST_TYPES = {
        SUCCESS = "success",
        INFO = "info",
        WARNING = "warning",
        ERROR = "error"
    },
    TOAST_DEFAULT_TITLES = {
        success = "Success",
        info = "Info",
        warning = "Warning",
        error = "ERROR"
    },

    PANEL_IMAGES = {
        BIGMAP = "bigmap",
        COMPUTER = "computer",
        CRASH_RECOVER = "crashRecover",
        DEALERSHIP = "dealership",
        DELIVERY_CARGO_CONTAINER = "delivery/cargoContainerHowTo",
        DELIVERY_CARGO_DELIVERED = "delivery/cargoDelivered",
        DELIVERY_CARGO_SCREEN = "delivery/cargoScreen",
        DELIVERY_INTRO = "delivery/intro",
        DELIVERY_LOANER = "delivery/loanerHelp",
        DELIVERY_MATERIALS = "delivery/materialsDeliveryHelp",
        DELIVERY_MY_CARGO = "delivery/myCargo",
        DELIVERY_PARCEL = "delivery/parcelDeliveryHelp",
        DELIVERY_POST_DELIVERY_TAXI = "delivery/postDeliveryTaxi",
        DELIVERY_TRAILER = "delivery/trailerDeliveryHelp",
        DELIVERY_VEHICLE = "delivery/vehicleDeliveryHelp",
        DRIFT_SPOTS = "driftSpots",
        DRIVING = "driving",
        FINISHING = "finishing",
        INSURANCE = "insurance",
        LEAGUES = "leagues",
        LOGBOOK = "logbook",
        MILESTONES = "milestones",
        MISSIONS = "missions",
        ONBOARDING = "onboarding/deliveryGameplayAwaits",
        PART_SHOPPING = "partShopping",
        PERFORMANCE_INDEX = "performanceIndex",
        POST_MISSION = "postMission",
        PROGRESS = "progress",
        REFUELING = "refueling",
        TRAILER_DELIVERY_UNLOCKED = "trailerDeliveryUnlocked",
        TUNING = "tuning",
        VEHICLE_DELIVERY_UNLOCKED = "vehicleDeliveryUnlocked",
        VEHICLE_PAINTING = "vehiclePainting",
        WELCOME = "welcome",
        WELCOME_NO_TUTORIAL = "welcomeNoTutorial",
    },
}

local function onInit()
    beamjoy_communications.addHandler("toast", M.toast)
end

local function onUILayoutLoaded(layoutName)
    async.removeTask("BJPostLayoutUpdate")
    async.delayTask(function()
        -- TODO update UI apps data (dashboard, objectives, etc)
    end, 100, "BJPostLayoutUpdate")
end

---@param keepMenuBar? boolean
local function hideGameMenu(keepMenuBar)
    guihooks.trigger('MenuHide', keepMenuBar == true)
end

---@param state boolean
---@param callback? fun(ctxt: TickContext)
local function applyLoading(state, callback)
    local apply = function()
        guihooks.trigger('app:waiting', state)
    end
    if type(callback) == "function" then
        ---@param job NGJob
        core_jobsystem.create(function(job)
            apply()
            job.sleep(M.loadingCallbackDelay)
            job.setExitCallback(function()
                callback(beamjoy_context.get())
            end)
        end)
    else
        apply()
    end
end

---@param callback fun()
---@return string key
local function createPopupCallback(callback)
    local key = UUID()
    M.popupCallbacks[key] = function()
        if type(callback) == "function" then
            pcall(callback)
        end
        M.popupClose()
        table.clear(M.popupCallbacks)
    end
    return key
end

---@param text string
---@param callback fun()?
---@return PopupButton
local function popupButton(text, callback)
    return {
        text = text,
        callback = callback,
    }
end

---@param text string
---@param buttons PopupButton[]
local function popup(text, buttons)
    if table.length(M.popupCallbacks) > 0 then
        M.popupClose()
        table.clear(M.popupCallbacks)
    end

    local btns = {}
    for i, btn in ipairs(buttons) do
        table.insert(btns, {
            action = tostring(i), -- mandatory
            text = btn.text,
            cmd = string.format("uiHelpers.popupCallbacks['%s']()", createPopupCallback(btn.callback)),
        })
    end

    ui_missionInfo.openDialogue({
        --type = "",     -- optional
        --typeName = "", -- optional
        title = text,
        buttons = btns,
    })
end

local function popupClose()
    ui_missionInfo.closeDialogue()
end

---@param text string
---@param callback fun()
local function popupConfirm(text, callback)
    M.popup(text, {
        M.popupButton(beamjoy_lang.translate("beamjoy.common.cancel")),
        M.popupButton(beamjoy_lang.translate("beamjoy.common.confirm"), callback),
    })
end

---@param text string? nil to remove category message
---@param category? string
---@param duration? number
local function message(text, category, duration)
    text = text or ""
    category = category or ""
    guihooks.trigger('Message', { ttl = duration or 1, msg = text, category = category })
end

---@param toastType string
---@param text string
---@param timeoutMs number?
---@param title string?
local function toast(toastType, text, timeoutMs, title)
    if not table.includes(M.TOAST_TYPES, toastType) then
        toastType = M.TOAST_TYPES.INFO
    end
    title = title or M.TOAST_DEFAULT_TITLES[toastType]
    if not timeoutMs then
        timeoutMs = 5000
    end
    guihooks.trigger(
        "toastrMsg",
        {
            type = toastType,
            title = title,
            msg = text,
            config = {
                timeOut = timeoutMs
            }
        }
    )
end
local function toastSuccess(text, timeoutMs, title) toast(M.TOAST_TYPES.SUCCESS, text, timeoutMs, title) end
local function toastInfo(text, timeoutMs, title) toast(M.TOAST_TYPES.INFO, text, timeoutMs, title) end
local function toastWarning(text, timeoutMs, title) toast(M.TOAST_TYPES.WARNING, text, timeoutMs, title) end
local function toastError(text, timeoutMs, title) toast(M.TOAST_TYPES.ERROR, text, timeoutMs, title) end

--- extensions/career/modules/linearTutorial.lua:introPopup():200
---@param title string
---@param content string
---@param image? string either one of M.PANEL_IMAGES' own keys (a bundled BeamNG tutorial image)
---or a real "http(s)://" URL, loaded directly by CEF's own background-image rendering the same
---way any other external image would be
local function openPanel(title, content, image)
    local isCustomURL = type(image) == "string" and image:find("^https?://") ~= nil
    if image ~= nil and not isCustomURL and not table.includes(M.PANEL_IMAGES, image) then return end

    local imageURL
    if isCustomURL then
        imageURL = image
    else
        image = image or M.PANEL_IMAGES.WELCOME
        imageURL = string.var("/gameplay/tutorials/pages/{image}/image.jpg", { image = image })
    end

    guihooks.trigger("introPopupTutorial", { {
        type = "info",
        content = string.var(
            [[<div class="bng-splash-imageonbottom" style="background-image:url('{imageURL}');"><h3>{title}</h3><div class="flex-grow"></div><div class="bng-splash-text">{content}</div></div>]],
            {
                title = title,
                content = content:var({
                    player_name = MPConfig.getNickname(),
                    server_name = GetServerInfos().name:trim(),
                    players_count = beamjoy_players.players:length(),
                }),
                imageURL = imageURL,
            }),
        flavour = "onlyOk",
        isPopup = true,
    } })
end

M.onInit = onInit
M.onUILayoutLoaded = onUILayoutLoaded

M.hideGameMenu = hideGameMenu
M.applyLoading = applyLoading
M.popupButton = popupButton
M.popup = popup
M.popupClose = popupClose
M.popupConfirm = popupConfirm
M.message = message
M.toast = toast
M.toastSuccess = toastSuccess
M.toastInfo = toastInfo
M.toastWarning = toastWarning
M.toastError = toastError
M.openPanel = openPanel

return M
