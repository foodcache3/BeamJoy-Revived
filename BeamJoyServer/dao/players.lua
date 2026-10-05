local M = {
    dependencies = { "dao_main" },
    path = "players",
}

local function onInit()
    if not FS.Exists(dao_main.dbPath .. "/" .. M.path) then
        FS.CreateDirectory(dao_main.dbPath .. "/" .. M.path)
    end
end

--- Hardening : a player name becomes a file name here, and staff actions pass names straight from
--- the client. Anything that could leave the players folder is refused : a path separator, a drive
--- colon, or a name that is "." or ".." itself (".." inside a name, as in "John..Doe", can't leave
--- the folder without a separator, so it's allowed)
---@param playerName any
---@return boolean
local function isSafeName(playerName)
    return type(playerName) == "string" and #playerName > 0 and #playerName <= 64 and
        not playerName:find("[/\\:%c]") and playerName ~= "." and playerName ~= ".."
end

---@param playerName string
---@return BJSPlayerSaved?
local function get(playerName)
    if not isSafeName(playerName) then return nil end
    return dao_main.get(M.path .. "/" .. playerName .. ".json")
end

---@return table<string, BJSPlayerSaved>
local function getAll()
    local res = {}
    for _, fileName in pairs(FS.ListFiles(dao_main.dbPath .. "/" .. M.path)) do
        if fileName:endswith(".json") then
            local playerName = fileName:gsub(".json$", "")
            res[playerName] = get(playerName)
        end
    end
    return res
end

---@param playerName string
---@param data BJSPlayerSaved
local function save(playerName, data)
    if not isSafeName(playerName) then
        return LogError(string.format("dao_players.save : refused the name %s", tostring(playerName)))
    end
    return dao_main.save(M.path .. "/" .. playerName .. ".json", data)
end

M.onInit = onInit

M.get = get
M.getAll = getAll
M.save = save

return M
