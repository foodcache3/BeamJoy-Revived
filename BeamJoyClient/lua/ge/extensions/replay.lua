local M = {
    baseFunctions = {},

    ---@type table<string, true> index playerName
    replayPlayers = {},
}

local function loadFile(...)
    local check = {
        state = true,
        reasons = {},
    }
    extensions.hook("onRequestCanStartReplay", check)
    if not check.state then
        if check.reasons[1] then
            uiHelpers.toastError(check.reasons[1], 5000)
        end
        return
    end
    M.baseFunctions.core_replay.loadFile(...)
end

local function toggleRecording(autoplayAfterStopping, ...)
    if extensions.core_replay.getState() == "recording" then
        local check = CreateRequestAuthorization(true)
        extensions.hook("onBJRequestCanStartReplay", check)
        if not check.state then
            autoplayAfterStopping = false
        end
    end

    M.baseFunctions.core_replay.toggleRecording(autoplayAfterStopping, ...)
end

local function onInit()
    M.baseFunctions = {
        core_replay = {
            loadFile = extensions.core_replay.loadFile,
            toggleRecording = extensions.core_replay.toggleRecording,
        }
    }

    extensions.core_replay.loadFile = loadFile
    extensions.core_replay.toggleRecording = toggleRecording
end

local function onExtensionUnloaded()
    RollBackNGFunctionsWrappers(M.baseFunctions)
end

local previousState = "inactive"
---@param data table
local function onReplayStateChanged(data)
    if previousState ~= data.state then
        if data.state == "playback" then
            extensions.hook("onReplayStarted")
        elseif data.state == "inactive" and previousState == "playback" then
            extensions.hook("onReplayStopped")
        end
        previousState = data.state
    end
end

---@return boolean
local function isOn()
    return extensions.core_replay.getState() == "playback"
end

M.onInit = onInit
M.onExtensionUnloaded = onExtensionUnloaded
M.onPreExit = onExtensionUnloaded
M.onReplayStateChanged = onReplayStateChanged

M.isOn = isOn

-- DEBUG
---@param req RequestAuthorization
M.onBJRequestCanStartReplay = function(req)
    if true then return end
    req.state = false
    table.insert(req.reasons, "DEBUG REPLAY NOT ALLOWED")
end

return M
