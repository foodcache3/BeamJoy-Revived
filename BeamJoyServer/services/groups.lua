local M = {
    ---@type BJGroup[]
    data = {
        {
            name = "default",
            vehicleCap = 1,
            banned = false,
            whitelisted = false,
            muted = false,
            staff = false,
            permissions = {},
            nameColor = { 1, 1, 1 },
            textColor = { 1, 1, 1 },
        },
        {
            name = "player",
            vehicleCap = 2,
            banned = false,
            whitelisted = false,
            muted = false,
            staff = false,
            permissions = {},
            nameColor = { 1, 1, 1 },
            textColor = { 1, 1, 1 },
        },
        {
            name = "vip",
            vehicleCap = 5,
            banned = false,
            whitelisted = true,
            muted = false,
            staff = false,
            permissions = {},
            nameColor = { 1, .75, 0 },
            textColor = { 1, 1, 1 },
        },
        {
            name = "mod",
            vehicleCap = 10,
            banned = false,
            whitelisted = false,
            muted = false,
            staff = true,
            permissions = {},
            nameColor = { .66, .66, 1 },
            textColor = { .66, .66, 1 },
        },
        {
            name = "admin",
            vehicleCap = -1,
            banned = false,
            whitelisted = false,
            muted = false,
            staff = true,
            permissions = {},
            nameColor = { .15, .75, 0 },
            textColor = { .15, .75, 0 },
        },
        {
            name = "owner",
            vehicleCap = -1,
            banned = false,
            whitelisted = false,
            muted = false,
            staff = true,
            permissions = {},
            nameColor = { .7, .35, .95 },
            textColor = { .7, .35, .95 },
        }
    },
    defaultGroups = nil,
}

--- the saved groups as the ordered list (lowest rank first) everything else expects. A groups.json
--- in another shape, a map keyed by group name (an older BeamJoy, a hand edit), was merged over the
--- built-in list as-is : its name keys made the groups go out as a JSON object instead of a list,
--- and every player's UI broke on it (no BeamJoy UI at all, every permission check failing). Such a
--- file is turned into a list, ordered like the built-in groups (with any rank number it carries
--- for the others), and saved back that way.
---@param saved table?
---@return table? list, boolean converted
local function savedGroupsList(saved)
    if type(saved) ~= "table" or table.isArray(saved) then return saved, false end
    local builtInOrder = {}
    for i, g in ipairs(M.data) do builtInOrder[g.name] = i end
    local list = {}
    for key, group in pairs(saved) do
        if type(group) == "table" then
            if type(group.name) ~= "string" then group.name = tostring(key) end
            list[#list + 1] = group
        end
    end
    local function rank(g)
        return builtInOrder[g.name] or tonumber(g.level) or tonumber(g.rank) or tonumber(g.index)
    end
    table.sort(list, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra and rb and ra ~= rb then return ra < rb end
        if (ra ~= nil) ~= (rb ~= nil) then return ra ~= nil end
        return a.name < b.name
    end)
    return list, true
end

local function onInit()
    M.defaultGroups = table.map(M.data, function(g) return g.name end):sort()
    local saved, converted = savedGroupsList(dao_groups.get())
    M.data = table.assign(M.data, saved or {})
    if converted then
        LogWarn("groups.json wasn't a list of groups : converted it (" ..
            table.map(M.data, function(g) return g.name end):join(", ") .. ") and saved it back")
        dao_groups.save(M.data)
    end

    communications_rx.addHandler("saveGroups", M.saveGroups)
end

local function onBJRequestCache(caches, targetID)
    caches.groups = M.data
    caches.defaultGroups = M.defaultGroups
end

---@param groupName string
---@return number?
local function getGroupIndex(groupName)
    local index
    table.find(M.data, function(g)
        return string.lower(g.name) == string.lower(groupName)
    end, function(_, i)
        index = i
    end)
    return index
end

---@return string name, integer index
local function getDefaultGroup()
    local index = getGroupIndex(services_config.data.DefaultGroup)
    if index and M.data[index] then
        return M.data[index].name, index
    else
        return M.data[0].name, 0
    end
end

---@param groupName string
---@return BJGroup group, integer index
local function getPreviousGroup(groupName)
    local currentIndex = getGroupIndex(groupName)
    if not currentIndex then
        local _, index = getDefaultGroup()
        return M.data[index], index
    end
    local index = math.max(currentIndex - 1, 0)
    return M.data[index], index
end

---@param removedGroups string[]
local function demoteGroupPlayers(removedGroups)
    local players = services_players.getAllPlayers()
    table.forEach(players, function(p, playerName)
        local updated = false
        while table.includes(removedGroups, p.group) do
            p.group = getPreviousGroup(p.group).name
            updated = true
        end
        if updated then
            local connected = services_players.players[playerName]
            if connected then
                connected.group = p.group
                communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "updatePlayer",
                    playerName, services_players.publicView(connected))
            end
            services_players.savePlayer(p)
        end
    end)
end

---@param removedGroups string[]
local function demotePermissions(removedGroups)
    local updated = false
    ---@type BJPermissions
    local newPerms = table.clone(services_permissions.data) or {}
    table.forEach(removedGroups, function(groupKey)
        local group = M.data[getGroupIndex(groupKey) or -1]
        if not group then return end
        local previousGroup
        while not previousGroup or table.includes(removedGroups, previousGroup.name) do
            previousGroup = getPreviousGroup(groupKey)
        end
        table.forEach(services_permissions.data, function(groupName, permName)
            if groupName == group.name then
                newPerms[permName] = previousGroup.name
                updated = true
            end
        end)
    end)
    if updated then
        services_permissions.save(InitContext(), newPerms)
    end
end

---@param ctxt BJSContext
---@param groupsData BJGroup[]
local function saveGroups(ctxt, groupsData)
    if not services_permissions.hasAllPermissions(ctxt.senderID,
            BJ_PERMISSIONS.SetPermissions) then
        return
    end

    if not table.isArray(groupsData) then return end

    local err
    local defaultGroupsFound = Table()
    local groupNamesFound = Table()
    local changedGroups = false
    table.forEach(groupsData, function(group, groupIndex)
        if err then return end
        if M.defaultGroups:includes(group.name) then
            defaultGroupsFound:insert(group.name)
        end
        if group.name == "default" and groupIndex ~= 1 then
            err = true
            return
        elseif group.name == "owner" and groupIndex ~= #groupsData then
            err = true
            return
        elseif groupNamesFound:includes(group.name) then
            err = true
            return
        end
        groupNamesFound:insert(group.name)
        if not table.compare(M.data[groupIndex], group) then
            changedGroups = true
        end
    end)
    if err then return end
    if not defaultGroupsFound:sort():compare(M.defaultGroups) then
        -- missing a default group
        return
    end
    local removedGroups = table.map(M.data, function(g) return g.name end)
        :filter(function(name)
            return not table.any(groupsData, function(gd)
                return gd.name == name
            end)
        end)

    local needUpdate = false
    if changedGroups then
        M.data = table.clone(groupsData)
        needUpdate = true
    end
    if removedGroups:length() > 0 then
        demoteGroupPlayers(removedGroups)
        demotePermissions(removedGroups)
        removedGroups:forEach(function(k) M.data[k] = nil end)
        needUpdate = true
    end
    if needUpdate then
        dao_groups.save(M.data)
        local caches = {}
        M.onBJRequestCache(caches)
        communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache", caches)
    end
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache

M.getGroupIndex = getGroupIndex
M.getDefaultGroup = getDefaultGroup
M.saveGroups = saveGroups

return M
