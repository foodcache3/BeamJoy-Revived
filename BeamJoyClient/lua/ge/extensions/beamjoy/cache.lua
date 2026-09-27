local M = {
    dependencies = {
        "beamjoy_communications"
    },
    DEBUG = true, -- TODO find better place
    loaded = false,
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", function()
        M.loaded = true
    end)
end

local function requireCaches()
    beamjoy_communications.send("requireCaches")
end

--- a new server (or a rejoin after the launcher dropped) sends its own caches : until then nothing
--- is loaded. Left true, the UI start-up (communications/ui.lua) went ahead on the old session's
--- flag before the new session's data existed
local function onServerLeave()
    M.loaded = false
end

M.onInit = onInit
M.onServerLeave = onServerLeave

M.requireCaches = requireCaches

return M
