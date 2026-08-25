local M = {
    dependencies = { "dao_main" },
    path = "vehiclePresets.json",
}

local function get()
    return dao_main.get(M.path)
end

local function save(data)
    return dao_main.save(M.path, data)
end

M.get = get
M.save = save

return M
