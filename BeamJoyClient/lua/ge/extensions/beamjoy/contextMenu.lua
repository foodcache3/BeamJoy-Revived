---@class BJCContextMenu
---@field position point
---@field targetID integer
---@field actions {text: string, callback: fun()}[]

local M = {
    ---@type BJCContextMenu?
    current = nil,

    max_dist = 200,
}

local function onInit()
    --beamjoy_communications_ui.addHandler("ContextMenuClosed", M.onContextMenuClosed)
    beamjoy_communications_ui.addHandler("ContextMenuClicked", M.onContextMenuClicked)
end

local function notifyUI()
    beamjoy_communications_ui.send("BJContextMenu", {
        position = M.current and {
            x = M.current.position.x,
            y = M.current.position.y
        } or nil,
        actions = M.current and table.map(M.current.actions, function(a)
            return a.text
        end) or nil,
    })
end

---@param type string
---@param data onBJClickData
local function onBJClick(type, data)
    if not data.mpVeh or data.mpVeh.isAi then return end
    if type == "right" and data.distance <= M.max_dist then
        local mousePos = ui_imgui.GetMousePos()
        local viewport = ui_imgui.GetWindowViewport()
        mousePos = ImVec2(
            (mousePos.x - viewport.Pos.x) / viewport.Size.x * 100,
            (mousePos.y - viewport.Pos.y) / viewport.Size.y * 100
        )
        M.current = { position = mousePos, targetID = data.mpVeh.vid, actions = {} }

        -- FOCUS
        table.insert(M.current.actions, {
            text = "beamjoy.window.main.playerlist.actions.focus",
            callback = function()
                if beamjoy_vehicles.vehicles[data.mpVeh.vid] and data.mpVeh.veh.playerUsable then
                    beamjoy_vehicles.focusVehicle(data.mpVeh.vid)
                end
            end
        })

        local owner = beamjoy_players.players
            :find(function(p) return p.playerID == data.mpVeh.ownerID end)
        local cacheVeh = owner and owner.vehicles[data.mpVeh.serverVID] or nil
        if owner and cacheVeh and beamjoy_permissions.isStaff() then
            -- FREEZE
            table.insert(M.current.actions, {
                text = "beamjoy.window.main.playerlist.actions." ..
                    (cacheVeh.froze and "unfreeze" or "freeze"),
                callback = function()
                    if beamjoy_vehicles.vehicles[data.mpVeh.vid] then
                        beamjoy_communications.send("toggleFreeze", owner.playerName, data.mpVeh.remoteVID)
                    end
                end
            })

            -- ENGINE
            table.insert(M.current.actions, {
                text = "beamjoy.window.main.playerlist.actions." ..
                    (cacheVeh.shut and "start" or "stop"),
                callback = function()
                    if beamjoy_vehicles.vehicles[data.mpVeh.vid] then
                        beamjoy_communications.send("toggleEngine", owner.playerName, data.mpVeh.remoteVID)
                    end
                end
            })

            -- DELETE
            table.insert(M.current.actions, {
                text = "beamjoy.window.main.playerlist.actions.delete",
                callback = function()
                    if beamjoy_vehicles.vehicles[data.mpVeh.vid] then
                        beamjoy_communications.send("deleteVehicle", owner.playerName, data.mpVeh.remoteVID)
                    end
                end
            })

            -- EXPLODE
            table.insert(M.current.actions, {
                text = "beamjoy.window.main.playerlist.actions.explode",
                callback = function()
                    if beamjoy_vehicles.vehicles[data.mpVeh.vid] then
                        beamjoy_communications.send("explodeVehicle", data.mpVeh.remoteVID)
                    end
                end
            })

            -- LAUNCH
            table.insert(M.current.actions, {
                text = "beamjoy.window.main.playerlist.actions.launch",
                callback = function()
                    if beamjoy_vehicles.vehicles[data.mpVeh.vid] then
                        beamjoy_communications.send("launchVehicle", data.mpVeh.remoteVID)
                    end
                end
            })
        end

        notifyUI()
    end
end

local function onSlowUpdate()
    if M.current then
        local pos = camera.getPositionRotation()
        local target = be:getObjectByID(M.current.targetID)
        local targetPos = target and beamjoy_vehicles.getVehiclePositionRotation(target) or nil
        if target and targetPos then
            if pos:distance(targetPos) > M.max_dist then
                M.current = nil
                notifyUI()
            end
        end
    end
end

local function onUpdate()
    if M.current and ui_imgui.IsKeyPressed(ui_imgui.GetKeyIndex(ui_imgui.Key_Escape)) then
        LogWarn("Escaped")
        M.current = nil
        notifyUI()
    end
end

---@param vid integer
local function onVehicleDestroyed(vid)
    if M.current and M.current.targetID == vid then
        M.current = nil
        notifyUI()
    end
end

local function onContextMenuClosed()
    M.current = nil
    notifyUI()
end

local function onContextMenuClicked(indexAction)
    if M.current then
        if M.current.actions[indexAction + 1] then
            M.current.actions[indexAction + 1].callback()
        end
    end
    M.current = nil
    notifyUI()
end


M.onInit = onInit
M.onBJClick = onBJClick
M.onSlowUpdate = onSlowUpdate
M.onUpdate = onUpdate
M.onVehicleDestroyed = onVehicleDestroyed
M.onContextMenuClosed = onContextMenuClosed
M.onContextMenuClicked = onContextMenuClicked

return M
