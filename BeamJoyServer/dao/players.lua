local M = {
    dependencies = { "dao_main" },
    path = "players",
}

local function onInit()
    -- getDbPath, not dbPath : dao_main may not be set up yet when this runs (onInit order is a hash's)
    local dir = dao_main.getDbPath() .. "/" .. M.path
    if not FS.Exists(dir) then FS.CreateDirectory(dir) end
end

---@param playerName string
---@return BJSPlayerSaved?
local function get(playerName)
    return dao_main.get(M.path .. "/" .. playerName .. ".json")
end

---@return table<string, BJSPlayerSaved>
local function getAll()
    local res = {}
    for _, fileName in pairs(FS.ListFiles(dao_main.getDbPath() .. "/" .. M.path)) do
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
    return dao_main.save(M.path .. "/" .. playerName .. ".json", data)
end

M.onInit = onInit

M.get = get
M.getAll = getAll
M.save = save

return M
