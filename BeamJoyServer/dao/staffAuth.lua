--- Persistence for the console-set staff/owner login passwords (services/identity.lua's own
--- chat-command workaround for granting staff/owner while BeamMP accounts aren't reliable). Only
--- ever stores SHA-256 hashes, never the plaintext password itself.

local M = {
    dependencies = { "dao_main" },
    path = "staffAuth.json",
}

---@return {staffHash: string?, ownerHash: string?}?
local function get()
    return dao_main.get(M.path)
end

---@param data {staffHash: string?, ownerHash: string?}
local function save(data)
    return dao_main.save(M.path, data)
end

M.get = get
M.save = save

return M
