--[[
BJRaceDirector : an example plugin for BeamJoy's plugin API, running races of its own and
stewarding them. Meant to be read, then copied and changed.

- A race every EVERY_MIN minutes : a lobby on RACE_ID (race.open), "Open race" for everyone, held
  OPEN_S seconds (holdStart), then started with whoever's ready. Nobody ready : it closes by
  itself. None opens while the last one is still open or running.
- Resets : FREE_RESETS per racer in each phase, then a RESET_PENALTY_MS penalty each
  (race.penalize, with a reason the racer sees), from RacerReset. Counted by racer key, so a
  racer who disconnects and comes back keeps their count.
- The lead : whoever takes it is told on their own HUD (hud.message to one player), from
  RacePositionsChanged.

What it shows : race.open, race control, racer keys, RacerReset, RacePositionsChanged and
hud.message to one player.

Install : copy this whole folder into Resources/Server/ (next to BeamJoyServer), set RACE_ID to one
of your races (races.list, or the race editor), restart the server.
]]

-- this file's own path : Resources/Server/BJRaceDirector/main.lua
local here = debug.getinfo(1).source:gsub("^@", ""):gsub("\\", "/")
local folder = here:match("^(.*)/[^/]*$") or "."
local BJ = dofile((folder:match("^(.*)/[^/]+$") or "..") .. "/BeamJoyServer/api/BeamJoyAPI.lua")

local NAME = "BJRaceDirector"
--- the race it runs, on the server's map
local RACE_ID = 1
local LAPS = 3
local EVERY_MIN = 30
--- how long its lobby stays open
local OPEN_S = 120
local FREE_RESETS = 2
local RESET_PENALTY_MS = 5000

local function log(msg) print("[" .. NAME .. "] " .. msg) end

---@type table<string, {resets: table<string, integer>}> sessionId -> its resets, "phase:racerKey" -> count
local races = {}
--- os.time() of the next lobby
local nextOpenAt = nil

local function openRace()
    BJ.call("race.open", { raceId = RACE_ID, name = "Open race", holdStart = true,
        options = { laps = LAPS, gridTimeout = OPEN_S } }, function(ok, r)
        if not ok then return log("race.open failed : " .. tostring(r.message)) end
        races[r.sessionId] = { resets = {} }
        log(string.format("opened %s on %s for %ds", r.sessionId, r.raceName, OPEN_S))
    end)
end

-- every second (BeamMP's timer) : time for the next race ?
function BJRaceDirector_tick()
    if not nextOpenAt or os.time() < nextOpenAt then return end
    nextOpenAt = os.time() + EVERY_MIN * 60
    if next(races) then return end -- the last one's still on
    openRace()
end

function onInit()
    BJ.init(NAME)
    MP.RegisterEvent("BJRaceDirector_tick", "BJRaceDirector_tick")
    MP.CreateEventTimer("BJRaceDirector_tick", 1000)

    -- the first one a minute after BeamJoy's up ; BeamJoy started again : its lobbies are gone
    BJ.onReady(function()
        races = {}
        nextOpenAt = os.time() + 60
    end)

    BJ.on("RacerReset", function(d)
        local race = races[d.sessionId]
        if not race then return end
        local key = d.phaseIndex .. ":" .. d.racer.racerKey
        race.resets[key] = (race.resets[key] or 0) + 1
        local n = race.resets[key]
        if n <= FREE_RESETS then return end
        BJ.call("race.penalize", { sessionId = d.sessionId, racerKey = d.racer.racerKey, ms = RESET_PENALTY_MS,
            reason = string.format("reset %d, %d free", n, FREE_RESETS) }, function(ok, err)
            if not ok then log("race.penalize failed : " .. tostring(err.message)) end
        end)
    end)

    BJ.on("RacePositionsChanged", function(d)
        if not races[d.sessionId] then return end
        for _, c in ipairs(d.changes) do
            -- `id` is left out while a racer is away (disconnected)
            if c.to == 1 and c.racer.id then
                BJ.call("hud.message", { playerId = c.racer.id, text = "You're leading", color = "good", durationS = 3 })
            end
        end
    end)

    local function done(d) races[d.sessionId] = nil end
    BJ.on("RaceFinished", done)
    BJ.on("RaceClosed", done)
end
