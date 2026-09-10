BJ_PERMISSIONS = {
    SendPrivateMessage = "SendPrivateMessage",
    TeleportTo = "TeleportTo",
    SpawnTrailers = "SpawnTrailers",
    BypassModelBlacklist = "BypassModelBlacklist",
    SpawnProps = "SpawnProps",
    TeleportFrom = "TeleportFrom",
    EditRaces = "EditRaces",
    EditSafeZones = "EditSafeZones",
    EditVehiclePresets = "EditVehiclePresets",
    EditHunterArenas = "EditHunterArenas",
    EditInfectedArenas = "EditInfectedArenas",
    EditFreeroamData = "EditFreeroamData",
    DeleteVehicle = "DeleteVehicle",
    Kick = "Kick",
    Mute = "Mute",
    Whitelist = "Whitelist",
    SetGroup = "SetGroup",
    TempBan = "TempBan",
    FreezePlayers = "FreezePlayers",
    EnginePlayers = "EnginePlayers",
    SetConfig = "SetConfig",
    Ban = "Ban",
    DatabasePlayers = "DatabasePlayers",
    SetEnvironment = "SetEnvironment",
    SwitchMap = "SwitchMap",
    SetMaps = "SetMaps",
    VoteMap = "VoteMap",
    VoteKick = "VoteKick",
    SetPermissions = "SetPermissions",
    SetCore = "SetCore",
    SetCEN = "SetCEN",
}

local M = {
    ---@class BJPermissions
    data = {
        SendPrivateMessage = "default",

        TeleportTo = "player",
        VoteMap = "player",
        VoteKick = "player",

        SpawnTrailers = "vip",

        BypassModelBlacklist = "mod",
        SpawnProps = "mod",
        TeleportFrom = "mod",
        EditRaces = "mod",
        EditSafeZones = "mod",
        EditVehiclePresets = "mod",
        EditHunterArenas = "mod",
        EditInfectedArenas = "mod",
        EditFreeroamData = "mod",
        DeleteVehicle = "mod",
        Kick = "mod",
        Mute = "mod",
        Whitelist = "mod",
        SetGroup = "mod",
        TempBan = "mod",
        FreezePlayers = "mod",
        EnginePlayers = "mod",
        SwitchMap = "mod",

        SetConfig = "admin",
        Ban = "admin",
        DatabasePlayers = "admin",
        SetEnvironment = "admin",
        SetMaps = "admin",

        SetPermissions = "owner",
        SetCore = "owner",
        SetCEN = "owner",
    },
    default = nil,
}

local function onInit()
    M.default = table.clone(M.data)
    M.data = table.assign(M.data, dao_permissions.get() or {})
    if table.any(M.data, function(v) return type(v) ~= "string" end) then
        M.data = M.default
    end
    M.PERMISSIONS = table.map(M.data, function(_, k) return k end)

    communications_rx.addHandler("savePermissions", M.save)
end

---@param caches table
---@param targetID integer?
---@param forced true?
local function onBJRequestCache(caches, targetID, forced)
    caches.permissions = M.data
    if forced or (targetID and services_permissions.hasAllPermissions(targetID,
            BJ_PERMISSIONS.SetPermissions)) then
        caches.permissionsDefault = M.default
    end
end

---@param playerID integer
---@param ... string permissions
---@return boolean
local function hasAllPermissions(playerID, ...)
    local player = services_players.players[MP.GetPlayerName(playerID)]
    if not player then return false end

    local groupIndex = services_groups.getGroupIndex(player.group)
    local group = services_groups.data[groupIndex or -1]
    if not group then return false end

    return table.filter({ ... }, function(v)
        return M.data[v] ~= nil
    end):every(function(permName)
        local permGroupIndex = services_groups.getGroupIndex(M.data[permName])
        if not groupIndex or not permGroupIndex then return false end
        return permGroupIndex <= groupIndex or
            table.includes(group.permissions, permName)
    end)
end

---@param playerID integer
---@param ... string permissions
---@return boolean
local function hasAnyPermission(playerID, ...)
    local player = services_players.players[MP.GetPlayerName(playerID)]
    if not player then return false end

    local groupIndex = services_groups.getGroupIndex(player.group)
    local group = services_groups.data[groupIndex or -1]
    if not group then return false end

    return table.filter({ ... }, function(v)
        return M.data[v] ~= nil
    end):any(function(permName)
        local permGroupIndex = services_groups.getGroupIndex(M.data[permName])
        if not groupIndex or not permGroupIndex then return false end
        return permGroupIndex <= groupIndex or
            table.includes(group.permissions, permName)
    end)
end

---@param playerID integer
---@param minimumGroupName string
---@return boolean
local function hasMinimumGroup(playerID, minimumGroupName)
    local minGroupIndex = services_groups.getGroupIndex(minimumGroupName)
    if not minGroupIndex then return true end

    local player = services_players.players[MP.GetPlayerName(playerID)]
    if not player then return false end

    local groupIndex = services_groups.getGroupIndex(player.group)
    if not groupIndex then return false end

    return groupIndex >= minGroupIndex
end

---@param playerName string
---@return boolean
local function isStaff(playerName)
    local target = services_players.players[playerName]
    if not target then return false end

    local groupIndex = services_groups.getGroupIndex(target.group)
    local group = services_groups.data[groupIndex or -1]
    if not group then return false end

    return group.staff
end

---@param ctxt BJSContext
---@param perms BJPermissions
local function save(ctxt, perms)
    if ctxt.sender and
        not M.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.SetPermissions) then
        return
    end
    table.forEach(M.data, function(_, k)
        if perms[k] == nil and
            M.default[k] ~= nil then
            perms[k] = M.default[k]
        end
        M.data[k] = perms[k]
    end)
    dao_permissions.save(M.data)

    local caches = {}
    M.onBJRequestCache(caches)
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache", caches)
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache

M.hasAllPermissions = hasAllPermissions
M.hasAnyPermission = hasAnyPermission
M.hasMinimumGroup = hasMinimumGroup
M.isStaff = isStaff
M.save = save

return M
