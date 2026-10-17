--- the shared builds' photos (services/vehiclePresets.lua) : a list of {id = build id, data = JPEG as base64}.
--- Apart from vehicleBuilds.json, which every player gets whole : a photo is only sent to a
--- player whose game doesn't have it yet.
local M = {
    dependencies = { "dao_main" },
    path = "vehicleBuildPhotos.json",
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
