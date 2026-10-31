--- the whitelist, a file of its own (direct request : easier to edit by hand or from another tool
--- than inside config.json). services_config re-reads it when it changes on disk
local M = {
    dependencies = { "dao_main" },
    path = "whitelist.json",
}

--- the file's text as it is on disk, nil when there's no file
---@return string?
local function read()
    local file, err = io.open(dao_main.getDbPath() .. "/" .. M.path, "r")
    if not file or err then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

---@param data {Enabled: boolean, PlayerNames: string[]}
local function save(data)
    return dao_main.save(M.path, data)
end

M.read = read
M.save = save

return M
