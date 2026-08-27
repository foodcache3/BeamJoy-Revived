local M = {
    init = false,
    dbPath = "",
}

local function init()
    M.dbPath = BJSPluginPath:gsub("BeamJoyServer", "BeamJoyData/db")
    if not FS.Exists(M.dbPath) then FS.CreateDirectory(M.dbPath) end
    M.init = true
end

---@param filePath string
---@return any?
local function get(filePath)
    if not M.init then init() end
    local file, err = io.open(M.dbPath .. "/" .. filePath, "r")
    if file and not err then
        local data = file:read("*a")
        file:close()
        -- Real, confirmed risk: utils_json.parse errors (a real Lua `error()`, not a nil return)
        -- on malformed JSON, e.g. a single stray trailing comma. Left unguarded, that propagates
        -- all the way up through whatever caller chain led here ; for a caller like
        -- services_races.seedBundledRaces (itself called synchronously from services_races.onInit,
        -- before that same function's own loadData() call), an uncaught error there aborts the
        -- rest of onInit too, so the current map's actual races silently never load at all, not
        -- just the one broken bundled file. pcall here contains that to just this one file.
        local ok, parsed = pcall(utils_json.parse, data)
        if not ok then
            LogError(string.format("dao_main.get: failed to parse JSON in %s : %s", filePath, parsed))
            return nil
        end
        return parsed or data
    end
end

---@param filePath string
---@param data any
local function save(filePath, data)
    if not M.init then init() end
    if data == nil or data == "" then
        if FS.Exists(M.dbPath .. "/" .. filePath) then
            FS.Remove(M.dbPath .. "/" .. filePath)
        end
        return
    end
    filePath = M.dbPath .. "/" .. filePath
    local tmpFilePath = filePath .. ".tmp"
    local file, err = io.open(tmpFilePath, "w")
    if file and not err then
        file:write(utils_json.stringify(data))
        file:close()

        if FS.Exists(filePath) then
            FS.Remove(filePath)
        end
        FS.Rename(tmpFilePath, filePath)
    end
end

M.get = get
M.save = save

return M
