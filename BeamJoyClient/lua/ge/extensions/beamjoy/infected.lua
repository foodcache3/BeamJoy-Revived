--- Client-side cache mirror for the current map's Infected arenas (a list since server build
--- 2504, same as hunter.lua's own mirror) ; mirrors its retrieveCache/save shape exactly.

local M = {
    dependencies = {},

    ---@type BJInfectedArena[]
    data = {},
}

-- the server's own minimums (services/infected.lua)
local MIN_SURVIVOR_SPAWNS, MIN_INFECTED_SPAWNS = 2, 1

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJInfectedArenaInfoRequest", M.pushArenaInfo)

    -- legacy BeamJoy Free (BJI) arena import: see services/infected.lua's own doc comment (the same
    -- <map>_hunter.json files Hunter's own importer reads, just the other half of the data)
    beamjoy_communications_ui.addHandler("BJInfectedLegacyImportPreviewRequest", M.requestLegacyImportPreview)
    beamjoy_communications_ui.addHandler("BJInfectedLegacyImportConfirm", M.confirmLegacyImport)
    beamjoy_communications.addHandler("infectedLegacyImportPreviewResult", M.onLegacyImportPreviewResult)
    beamjoy_communications.addHandler("infectedLegacyImportDone", M.onLegacyImportDone)
end

local function requestLegacyImportPreview()
    beamjoy_communications.send("infectedLegacyImportPreview")
end

---@param results table[]
local function onLegacyImportPreviewResult(results)
    beamjoy_communications_ui.send("BJInfectedLegacyImportPreview", results or {})
end

--- `selection` : the keys ticked in the import checklist
local function confirmLegacyImport(selection)
    beamjoy_communications.send("infectedLegacyImportConfirm", selection)
end

---@param imported integer
---@param failed integer
local function onLegacyImportDone(imported, failed)
    if failed and failed > 0 then
        toast.warn(string.format("Infected import : %d map(s) imported, %d failed (see server console)",
            imported or 0, failed), nil, 8)
    else
        toast.warn(string.format("Infected import : %d map(s) imported", imported or 0), nil, 6)
    end
end

--- one trimmed row per arena for the Activities tab's start panel, same reasoning as hunter.lua's
--- own pushArenaInfo : the full arena geometry (spawns) is only ever needed by the in-world editor
local function pushArenaInfo()
    local list = {}
    for _, a in ipairs(M.data or {}) do
        table.insert(list, {
            id = a.id,
            name = a.name,
            -- playable, not merely ticked : the server refuses a start under its own minimums
            enabled = a.enabled == true and
                #(a.survivorSpawns or {}) >= MIN_SURVIVOR_SPAWNS and
                #(a.infectedSpawns or {}) >= MIN_INFECTED_SPAWNS,
            -- a survivor slot each, plus however many of the initial infected the infected-spawn
            -- pool can hold : the same upper bound the server's own capacity check uses
            places = #(a.survivorSpawns or {}) + #(a.infectedSpawns or {}),
            defaults = a.defaults or {},
        })
    end
    beamjoy_communications_ui.send("BJInfectedArenaInfo", { arenas = list })
end

---@param caches table
local function retrieveCache(caches)
    if caches.infectedArenas ~= nil then
        M.data = type(caches.infectedArenas) == "table" and caches.infectedArenas or {}
        -- the hook's name is the one every listener already uses : the shape behind it changed,
        -- the event didn't
        extensions.hook("onBJInfectedArenaChanged")
        pushArenaInfo()
    end
end

---@param id integer?
---@return BJInfectedArena?
local function getArena(id)
    for _, a in ipairs(M.data or {}) do
        if a.id == id then return a end
    end
end

---@param arena BJInfectedArena
local function save(arena)
    beamjoy_communications.send("infectedArenaSave", arena)
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
