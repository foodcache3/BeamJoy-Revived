local M = {
    WALKING = "unicycle",
}

---@param model string
---@return boolean
local function isAi(model)
    return type(model) == "string" and model:lower():find("traffic") ~= nil
end

local function onInit()
    communications_rx.addHandler("updateCurrentVehicle", M.updateCurrentVehicle)
    communications_rx.addHandler("deletePlayerVehicles", M.deletePlayerVehicles)
    communications_rx.addHandler("deleteVehicle", M.deleteVehicle)
    communications_rx.addHandler("explodeVehicle", M.explodeVehicle)
    communications_rx.addHandler("updateVehicleGhost", M.updateGhost)
end

---@param playerID integer
---@param vehID integer
---@param vehDataStr string
---@return 1? reject
local function onVehicleSpawn(playerID, vehID, vehDataStr)
    local s, e = vehDataStr:find('%{')
    vehDataStr = s and vehDataStr:sub(s) or ""
    local data = utils_json.parse(vehDataStr)
    ---@type ServerVehicleConfig?
    local vehData = type(data) == "table" and data or nil
    if not vehData then return 1 end

    local playerName = MP.GetPlayerName(playerID)
    ---@type BJSPlayer
    local player = services_players.players[playerName]
    if not player then return 1 end
    local groupIndex = services_groups.getGroupIndex(player.group)
    if not groupIndex then return 1 end
    local group = services_groups.data[groupIndex]

    -- TODO check permissions to spawn (policy, unicycle, vehType, AI, model blacklisted)

    local jbeam = tostring(vehData.jbm or vehData.vcf.model or vehData.vcf.mainPartName)
    if jbeam ~= M.WALKING then
        if group.vehicleCap > -1 then
            local currentCount = player.vehicles:filter(function(v) return not v.isAi end):length()
            if currentCount >= group.vehicleCap then
                return 1 -- maximum vehicles reached
            end
        end

        player.vehicles[vehID] = {
            vid = vehData.vid,
            pid = vehData.pid,
            vehicleID = vehID,
            serverVehicleID = string.format("%d-%d", vehData.pid, vehID),
            froze = false,
            shut = false,
            jbeam = jbeam,
            parts = vehData.vcf.parts,
            paints = vehData.vcf.paints,
            isAi = isAi(jbeam),
        }

        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "updatePlayer",
            playerName, player)
    else
        if not services_config.data.AllowWalking then
            return 1
        end
    end
end

---@param playerID integer
---@param vehID integer
---@param vehDataStr string
local function onVehicleReset(playerID, vehID, vehDataStr)
    local s, e = vehDataStr:find('%{')
    vehDataStr = s and vehDataStr:sub(s) or ""
    local data = utils_json.parse(vehDataStr)
    ---@type PosRot?
    local vehData = type(data) == "table" and data or nil
    if not vehData then return end
end

---@param playerID integer
---@param vehID integer
---@param vehDataStr string
---@return integer? reject
local function onVehicleEdited(playerID, vehID, vehDataStr)
    local s, e = vehDataStr:find('%{')
    vehDataStr = s and vehDataStr:sub(s) or ""
    local data = utils_json.parse(vehDataStr)
    ---@type ServerVehicleConfig?
    local vehData = type(data) == "table" and data or nil
    if not vehData then return 1 end

    local jbeam = tostring(vehData.jbm or vehData.vcf.model or vehData.vcf.mainPartName)

    local playerName = MP.GetPlayerName(playerID)
    if not services_players.players[playerName] then return 1 end

    if jbeam == M.WALKING then
        services_players.players[playerName].vehicles[vehID] = nil
        return
    end
    if not services_players.players[playerName].vehicles[vehID] then return 1 end

    local veh = services_players.players[playerName].vehicles[vehID]
    veh.jbeam = jbeam
    veh.parts = vehData.vcf.parts
    veh.paints = vehData.vcf.paints
    veh.isAi = isAi(jbeam)

    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "updatePlayer",
        playerName, services_players.players[playerName])
end

---@param playerID integer
---@param vehID integer
---@param rawPaintData string
local function onVehiclePaintChanged(playerID, vehID, rawPaintData)
    local data = utils_json.parse(rawPaintData)
    ---@type NGPaint[]? max 3 indices
    local paintData = type(data) == "table" and data or nil
end

---@param playerID integer
---@param vehID integer
local function onVehicleDeleted(playerID, vehID)
    local playerName = MP.GetPlayerName(playerID)
    if not services_players.players[playerName] then return 1 end

    if services_players.players[playerName].vehicles[vehID] then
        services_players.players[playerName].vehicles[vehID] = nil
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "updatePlayer",
            playerName, services_players.players[playerName])
    end
end

---@param ctxt BJSContext
---@param vid integer
local function updateCurrentVehicle(ctxt, vid)
    if ctxt.sender then
        ctxt.sender.currentVehicle = vid
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "updatePlayer",
            ctxt.sender.playerName, ctxt.sender)
    end
end

---@param ctxt BJSContext
---@param targetName string
local function deletePlayerVehicles(ctxt, targetName)
    if not ctxt.sender then return end
    if not services_permissions.isStaff(ctxt.sender.playerName) then return end

    local target = services_players.players[targetName]
    if not target then return end

    target.vehicles:filter(function(v)
        return not v.isAi
    end):forEach(function(v)
        communications_tx.sendToPlayer(target.playerID, "deleteVehicle", v.vid)
    end)
end

---@param ctxt BJSContext
---@param targetName string
---@param vid integer
local function deleteVehicle(ctxt, targetName, vid)
    if not ctxt.sender then return end
    if not services_permissions.isStaff(ctxt.sender.playerName) then return end

    local target = services_players.players[targetName]
    if not target then return end

    local targetVeh = target.vehicles:find(function(v) return v.vid == vid end)
    if not targetVeh then return end

    communications_tx.sendToPlayer(target.playerID, "deleteVehicle", targetVeh.vid)
end

---@param ctxt BJSContext
---@param vid integer
local function explodeVehicle(ctxt, vid)
    if not ctxt.sender then return end
    if not services_permissions.isStaff(ctxt.sender.playerName) then return end

    local targetVeh
    services_players.players:forEach(function(p)
        if targetVeh then return end
        targetVeh = table.find(p.vehicles, function(v) return v.vid == vid end)
    end)
    if not targetVeh then return end

    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "explodeVehicle", vid)
end

---@param ctxt BJSContext
---@param vid integer the sender's own vid for their own vehicle, also the cross-client-stable
---remoteVID every other client's own copy of this vehicle carries (see the client-side
---"updateVehicleGhost" handler's own comment); relaying it unmodified below is
---correct even though it's only ever looked up here against the SENDER's own vehicle list
---@param state boolean
local function updateGhost(ctxt, vid, state)
    if type(vid) ~= "number" or type(state) ~= "boolean" then
        LogError("updateGhost called with invalid parameters")
        dump({ vid = vid, state = state })
        return
    end
    if not ctxt.sender then return end
    local veh = ctxt.sender.vehicles:find(function(v) return v.vid == vid end)
    if not veh or veh.ghost == state then return end

    veh.ghost = state == true
    services_players.players:forEach(function(p)
        if p.playerID == ctxt.senderID then return end
        communications_tx.sendToPlayer(p.playerID, "updateVehicleGhost", vid, state)
    end)
end

M.onInit = onInit
M.onVehicleSpawn = onVehicleSpawn
M.onVehicleReset = onVehicleReset
M.onVehicleEdited = onVehicleEdited
M.onVehiclePaintChanged = onVehiclePaintChanged
M.onVehicleDeleted = onVehicleDeleted

M.updateCurrentVehicle = updateCurrentVehicle
M.deletePlayerVehicles = deletePlayerVehicles
M.deleteVehicle = deleteVehicle
M.explodeVehicle = explodeVehicle
M.updateGhost = updateGhost

return M
