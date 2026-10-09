--- Read-only mirror of this mod's OWN bundled default content (races, hunter arenas, and
--- whatever future activity type follows the same pattern), kept entirely separate from
--- `activities/` (an admin's own live, editable data) so shipping/updating bundled content can
--- never interfere with an existing installation's custom races/arenas, and a fresh install never
--- needs any manual step to get it, per direct request.
---
--- Source of truth is `Server/BeamJoyServer/bundledContent/activities/<mapName>_<activityType>.json`,
--- shipped as part of the mod package itself (plain files, the exact same array-of-race/arena
--- schema `BeamJoyData/db/activities/` already uses, no conversion needed unlike the Legacy Import
--- path, which parses a different, older BJI schema). `sync()` mirrors that folder into
--- `BeamJoyData/db/bundled/` on every boot (always fully overwritten, never meant to be admin-
--- edited), so :
---   - it survives independently of wherever the mod happens to be installed (BJSPluginPath),
---   - an admin can inspect exactly what the current mod version ships, right under their own
---     BeamJoyData folder, without digging into the plugin's own install directory,
---   - and a later mod update just adds more files to bundledContent/activities/ ; the next boot
---     picks them up automatically, no migration step of any kind.
---
--- Each service that owns an activity type (services/races.lua, services/hunter.lua) is
--- responsible for actually seeding bundled entries into its own live data (via dao_activity),
--- this module only provides the raw bundled files plus a seeded-tracking ledger, so a given
--- bundled entry is auto-imported at most once, ever, regardless of whether an admin later edits
--- or deletes their own copy of it, or the server restarts a thousand times.
local M = {
    dependencies = { "dao_main" },
    path = "bundled",
    LEDGER_FILE = "bundledSeedLedger.json",
    ---@type string absolute path to the mod's own shipped bundledContent/activities folder
    sourcePath = "",
}

---@type table<string, boolean>?
local ledgerCache = nil
local function loadLedger()
    if not ledgerCache then
        ledgerCache = dao_main.get(M.LEDGER_FILE) or {}
    end
    return ledgerCache
end

---@param mapName string
---@param activityType string
---@param itemName string
---@return string
local function ledgerKey(mapName, activityType, itemName)
    return mapName .. "|" .. activityType .. "|" .. itemName
end

--- whether this bundled entry has already been auto-seeded (successfully inserted, or skipped
--- because a same-named entry already existed) into live data before, on any previous boot
---@param mapName string
---@param activityType string
---@param itemName string
---@return boolean
local function isSeeded(mapName, activityType, itemName)
    return loadLedger()[ledgerKey(mapName, activityType, itemName)] == true
end

--- marks a bundled entry as handled so it's never reconsidered again, regardless of whether an
--- admin later renames, edits, or deletes their own copy of it
---@param mapName string
---@param activityType string
---@param itemName string
local function markSeeded(mapName, activityType, itemName)
    local ledger = loadLedger()
    ledger[ledgerKey(mapName, activityType, itemName)] = true
    dao_main.save(M.LEDGER_FILE, ledger)
end

local sync

-- Real, confirmed bug (direct report : a fresh install came up without any bundled races, its
-- Hunter arenas seeded fine). The server fires onInit in pairs() order over the extensions table, a
-- hash Lua 5.3 shuffles every boot, so a service seeding from the bundled mirror (services_races,
-- services_hunter, ...) could run before this module's own onInit had made it. On a fresh install
-- the mirror didn't exist yet : that service saw no maps and seeded nothing (later boots found the
-- previous boot's mirror). The mirror is now made by whichever comes first, this module's onInit or
-- the first read of it, once per boot.
local synced = false
local function ensureSynced()
    if synced then return end
    synced = true
    M.sourcePath = BJSPluginPath .. "/bundledContent/activities"
    sync()
end

---@return string BeamJoyData/db/bundled
local function destPath()
    return dao_main.getDbPath() .. "/" .. M.path
end

---@param mapName string
---@param activityType string
---@return table? raw bundled array for this map/type, same shape as dao_activity.get's own
local function get(mapName, activityType)
    ensureSynced()
    return dao_main.get(M.path .. "/" .. mapName .. "_" .. activityType .. ".json")
end

--- every map name that has bundled content for the given activity type, discovered straight from
--- the (already-synced) BeamJoyData/db/bundled/ mirror, not the package source directly : keeps
--- every caller working off the one already-established "current bundled content" location
---@param activityType string
---@return string[]
local function listMapsForType(activityType)
    ensureSynced()
    local dest = destPath()
    local maps = {}
    if FS.Exists(dest) then
        local pattern = "^(.+)_" .. activityType .. "%.json$"
        for _, filename in pairs(FS.ListFiles(dest)) do
            local mapName = filename:match(pattern)
            if mapName then table.insert(maps, mapName) end
        end
    end
    return maps
end

--- mirrors every file from the mod's own shipped bundledContent/activities folder into
--- BeamJoyData/db/bundled/, fully overwriting the destination first : this folder is never meant
--- to be admin-edited, treat it as a pure reflection of whatever's currently installed, including
--- a file a newer mod version removed entirely (mirrored deletion, same "the package IS the
--- truth" convention this codebase's own BJ.zip client deploy already follows)
function sync()
    local dest = destPath()
    if FS.Exists(dest) then
        for _, filename in pairs(FS.ListFiles(dest)) do
            FS.Remove(dest .. "/" .. filename)
        end
    else
        FS.CreateDirectory(dest)
    end
    if not FS.Exists(M.sourcePath) then return end
    for _, filename in pairs(FS.ListFiles(M.sourcePath)) do
        FS.Copy(M.sourcePath .. "/" .. filename, dest .. "/" .. filename)
    end
end

local function onInit()
    ensureSynced()
end

M.onInit = onInit
M.sync = sync
M.get = get
M.listMapsForType = listMapsForType
M.isSeeded = isSeeded
M.markSeeded = markSeeded

return M
