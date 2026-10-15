--[[
BJLeaderboardExport : an example plugin for BeamJoy's plugin API.

Keeps one JSON file per map, export/<map>.json in this plugin's folder, with every race's
leaderboards (only nicknamed players : see NICKNAMES_ONLY), written again whenever a time changes.
A website can read those files, or this plugin can be the start of one that uploads them.

Install : copy this whole folder into Resources/Server/ (next to BeamJoyServer), restart the
server.
]]

-- this file's own path : Resources/Server/BJLeaderboardExport/main.lua
local here = debug.getinfo(1).source:gsub("^@", ""):gsub("\\", "/")
local folder = here:match("^(.*)/[^/]*$") or "."

-- the helper, from BeamJoy's own folder (Resources/Server/BeamJoyServer/api) : always the one
-- matching the BeamJoy installed
local BJ = dofile((folder:match("^(.*)/[^/]+$") or "..") .. "/BeamJoyServer/api/BeamJoyAPI.lua")

--- leave out the times of players who never picked a BeamJoy nickname (BeamMP names, guests, and
--- times saved before BeamJoy recorded which kind of name it was)
local NICKNAMES_ONLY = true

local exportFolder = folder .. "/export"

---@type table<string, table> map -> its export
local maps = {}

local function log(msg) print("[BJLeaderboardExport] " .. msg) end

--- the entries kept, ranked again among themselves
local function keep(entries)
    local out = {}
    for _, e in ipairs(entries or {}) do
        if not NICKNAMES_ONLY or e.identity == "nickname" then
            out[#out + 1] = {
                rank = #out + 1,
                name = e.name,
                timeMs = e.timeMs,
                vehicle = e.model,
                date = e.date,
            }
        end
    end
    return out
end

local function write(map)
    local export = maps[map]
    if not export then return end
    export.updatedAt = os.time()
    if not FS.Exists(exportFolder) then FS.CreateDirectory(exportFolder) end
    local path = exportFolder .. "/" .. map .. ".json"
    local file = io.open(path .. ".tmp", "w")
    if not file then return log("couldn't write " .. path) end
    file:write(BJ.json.stringify(export, nil, true))
    file:close()
    os.remove(path)
    os.rename(path .. ".tmp", path)
end

--- a map's races and leaderboards, fetched whole
local function fetchMap(map)
    BJ.call("races.leaderboards", { map = map }, function(ok, result)
        if not ok then return log("races.leaderboards " .. map .. " failed : " .. tostring(result.message)) end
        local export = { map = map, races = {} }
        for _, race in ipairs(result.races) do
            export.races[#export.races + 1] = {
                raceId = race.raceId,
                raceName = race.raceName,
                grid = keep(race.boards.grid and race.boards.grid.entries),
                freeroam = keep(race.boards.freeroam and race.boards.freeroam.entries),
            }
        end
        -- no file for a map that never had races
        local had = maps[map] ~= nil
        maps[map] = export
        if #export.races == 0 and not had then return end
        write(map)
        log(string.format("%s : %d races exported", map, #export.races))
    end)
end

function onInit()
    BJ.init("BJLeaderboardExport")

    -- BeamJoy is up (at server start, or this plugin started after it) : everything, fresh
    BJ.onReady(function(info)
        log("BeamJoy " .. tostring(info.beamjoy.version) .. " (build " .. tostring(info.beamjoy.build) ..
            ") found, exporting every map's leaderboards")
        BJ.call("maps.list", {}, function(ok, result)
            if not ok then return log("maps.list failed : " .. tostring(result.message)) end
            for _, map in ipairs(result.maps) do fetchMap(map.name) end
        end)
    end)

    -- a time added or put back : that race's board comes whole with the event
    BJ.on("LeaderboardChanged", function(data)
        local export = maps[data.map]
        if not export then return fetchMap(data.map) end
        for _, race in ipairs(export.races) do
            if race.raceId == data.raceId then
                race[data.board] = keep(data.entries)
                write(data.map)
                return
            end
        end
        fetchMap(data.map) -- a race this plugin hadn't seen yet
    end)

    -- races added, edited (their times are cleared then), deleted or imported
    BJ.on("RacesChanged", function(data) fetchMap(data.map) end)

    BJ.on("RaceFinished", function(data)
        local winner = data.results[1]
        if winner and winner.finished then
            log(string.format("%s finished, won by %s", data.raceName, winner.name))
        end
    end)
end
