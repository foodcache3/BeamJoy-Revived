local M = {
    ---@type BJCConfig
    data = {}, --- @diagnostic disable-line
    core = nil,
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)

    beamjoy_communications_ui.addHandler("BJRequestConfigData", M.sendConfigToUI)
    beamjoy_communications_ui.addHandler("BJRequestModelsBlacklist", M.sendModelBlacklistToUI)
    beamjoy_communications_ui.addHandler("BJRequestWhitelistData", M.sendWhitelistToUI)
    beamjoy_communications_ui.addHandler("BJRequestCoreData", M.sendCoreToUI)
    beamjoy_communications_ui.addHandler("BJRequestBroadcastsData", M.sendBroadcastToUI)
end

---@param req RequestAuthorization
---@param model string
---@param config string?
local function onBJRequestCanSpawnVehicle(req, model, config)
    if beamjoy_permissions.isStaff() or
        beamjoy_permissions.hasAllPermissions(nil,
            BJ_PERMISSIONS.BypassModelBlacklist) then
        return
    end
    if table.includes(M.data.ModelBlacklist, model) then
        req.state = false
    end
end

---@param caches table
local function retrieveCache(caches)
    if caches.config then
        M.data = caches.config
        M.sendConfigToUI()
        M.sendModelBlacklistToUI()
        M.sendWhitelistToUI()
        M.sendBroadcastToUI()
        -- proactive, not request-gated like sendConfigToUI (BJRequestConfigData/BJSendConfigData,
        -- only ever fetched by the admin-only General config tab) : the race browse list filter and
        -- canManage/canEdit checks need these values on every client, not just whoever happens to
        -- have that tab open, so they're pushed straight through on every cache update instead
        beamjoy_communications_ui.send("BJRaceSettings", {
            authorshipRestriction = M.data.RaceAuthorshipRestriction == true,
            editorShowOnlyEditable = M.data.RaceEditorShowOnlyEditable == true,
        })
    end
    if caches.core then
        M.core = caches.core
        M.sendCoreToUI()
    end
end

local function sendConfigToUI()
    beamjoy_communications_ui.send("BJSendConfigData", {
        AllowClientMods = M.data.AllowClientMods,
        RaceAuthorshipRestriction = M.data.RaceAuthorshipRestriction,
        RaceEditorShowOnlyEditable = M.data.RaceEditorShowOnlyEditable,
        ForceHud = M.data.ForceHud,
        ShowHudAtStart = M.data.ShowHudAtStart,
        -- real root cause of "toggling Freeroam/Voting settings visually reverts itself": both
        -- accordions' own $on("BJSendConfigData", ...) handlers fall back to `data.Freeroam || {}`
        -- / `data.Voting || {}` whenever their own key is missing from this payload, silently
        -- resetting every field back to its own hardcoded UI default (not the real saved value).
        -- This broadcast fires after ANY successful setConfig call anywhere on the server (M.set's
        -- success path pushes a full sendCache to every player unconditionally), not just a
        -- Freeroam/Voting one, so the reset could be triggered by something completely unrelated.
        -- Neither key was ever actually included here despite both accordions expecting to read
        -- them from this exact broadcast.
        Freeroam = M.data.Freeroam,
        Voting = M.data.Voting,
    })
end

local function sendModelBlacklistToUI()
    extensions.core_jobsystem.create(function(job)
        beamjoy_communications_ui.send("BJModelsBlacklist", {
            list = M.data.ModelBlacklist,
            models = table.map(beamjoy_vehicles.getAllVehicleConfigs(job,
                        { cars = true, trucks = true, trailers = true, props = true }),
                    function(model, modelKey)
                        return {
                            key = modelKey,
                            label = model.label,
                        }
                    end):values()
                :sort(function(a, b) return a.label < b.label end),
        })
    end)
end

local function sendWhitelistToUI()
    beamjoy_communications_ui.send("BJSendWhitelistData", {
        state = M.data.Whitelist ~= nil and M.data.Whitelist.Enabled,
        list = M.data.Whitelist and M.data.Whitelist.PlayerNames or {},
    })
end

local function sendCoreToUI()
    beamjoy_communications_ui.send("BJSendCoreData", M.core)
end

local function sendBroadcastToUI()
    beamjoy_communications_ui.send("BJSendBroadcastsData", { data = M.data.Broadcasts, langs = beamjoy_lang.langs })
end


M.onInit = onInit
M.onBJRequestCanSpawnVehicle = onBJRequestCanSpawnVehicle

M.retrieveCache = retrieveCache
M.sendConfigToUI = sendConfigToUI
M.sendModelBlacklistToUI = sendModelBlacklistToUI
M.sendWhitelistToUI = sendWhitelistToUI
M.sendCoreToUI = sendCoreToUI
M.sendBroadcastToUI = sendBroadcastToUI

return M
