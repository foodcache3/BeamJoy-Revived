--- Client-side cache mirror for the current map's Hunter arenas (a list, one entry per arena
--- since server build 2504 ; see services/hunter.lua) ; mirrors derby.lua's own shape.

local M = {
    dependencies = {},

    ---@type BJHunterArena[]
    data = {},
}

-- the server's own minimums (services/hunter.lua) : an arena under any of them can't be hunted on,
-- whatever its own "enabled" tick says
local MIN_HUNTER_SPAWNS, MIN_PREY_SPAWNS, MIN_WAYPOINTS = 2, 2, 2

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJHunterArenaInfoRequest", M.pushArenaInfo)

    -- legacy BeamJoy Free (BJI) arena import: see services/hunter.lua's own doc comment for the
    -- full design. Preview is relayed straight through to Angular (the confirm dialog is an
    -- Angular-only concept, see beamjoyConfirm); "done" is just toasted directly here, no need to
    -- round-trip through Angular for a one-shot result summary.
    beamjoy_communications_ui.addHandler("BJHunterLegacyImportPreviewRequest", M.requestLegacyImportPreview)
    beamjoy_communications_ui.addHandler("BJHunterLegacyImportConfirm", M.confirmLegacyImport)
    beamjoy_communications.addHandler("hunterLegacyImportPreviewResult", M.onLegacyImportPreviewResult)
    beamjoy_communications.addHandler("hunterLegacyImportDone", M.onLegacyImportDone)
end

local function requestLegacyImportPreview()
    beamjoy_communications.send("hunterLegacyImportPreview")
end

---@param results table[]
local function onLegacyImportPreviewResult(results)
    beamjoy_communications_ui.send("BJHunterLegacyImportPreview", results or {})
end

--- `selection` : the keys ticked in the import checklist
local function confirmLegacyImport(selection)
    beamjoy_communications.send("hunterLegacyImportConfirm", selection)
end

---@param imported integer
---@param failed integer
local function onLegacyImportDone(imported, failed)
    if failed and failed > 0 then
        toast.warn(string.format("Hunter import : %d map(s) imported, %d failed (see server console)",
            imported or 0, failed), nil, 8)
    else
        toast.warn(string.format("Hunter import : %d map(s) imported", imported or 0), nil, 6)
    end
end

--- one trimmed row per arena for the Activities tab's start panel (which arenas can be hunted on
--- at all, and each one's own saved defaults to seed the start-options form) : the full arena
--- geometry (spawns/waypoints) is only ever needed by the in-world editor itself
local function pushArenaInfo()
    local list = {}
    for _, a in ipairs(M.data or {}) do
        table.insert(list, {
            id = a.id,
            name = a.name,
            -- playable, not merely ticked : the server refuses a start under its own minimums
            enabled = a.enabled == true and
                #(a.hunterSpawns or {}) >= MIN_HUNTER_SPAWNS and
                #(a.preySpawns or {}) >= MIN_PREY_SPAWNS and
                #(a.waypoints or {}) >= MIN_WAYPOINTS,
            -- the fugitive plus one hunter per hunter spawn : the lobby's own capacity
            places = 1 + #(a.hunterSpawns or {}),
            waypointCount = #(a.waypoints or {}),
            -- just a count, not the full geometry (that's the in-world editor's own job): lets the
            -- start-options panel hide the "Respawn hubs" strategy option when none are placed,
            -- same as the editor itself does from its own live list data
            respawnHubCount = #(a.respawnHubs or {}),
            defaults = a.defaults or {},
        })
    end
    beamjoy_communications_ui.send("BJHunterArenaInfo", { arenas = list })
end

---@param caches table
local function retrieveCache(caches)
    if caches.hunterArenas ~= nil then
        M.data = type(caches.hunterArenas) == "table" and caches.hunterArenas or {}
        -- the hook's name is the one every listener already uses (the editor, the props sync) :
        -- what changed is the shape of the data behind it, not the event
        extensions.hook("onBJHunterArenaChanged")
        pushArenaInfo()
    end
end

---@param id integer?
---@return BJHunterArena?
local function getArena(id)
    for _, a in ipairs(M.data or {}) do
        if a.id == id then return a end
    end
end

---@param arena BJHunterArena
local function save(arena)
    beamjoy_communications.send("hunterArenaSave", arena)
end

M.onInit = onInit
M.retrieveCache = retrieveCache
M.pushArenaInfo = pushArenaInfo
M.getArena = getArena
M.save = save
M.requestLegacyImportPreview = requestLegacyImportPreview
M.onLegacyImportPreviewResult = onLegacyImportPreviewResult
M.confirmLegacyImport = confirmLegacyImport
M.onLegacyImportDone = onLegacyImportDone

return M
