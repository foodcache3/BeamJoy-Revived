--- Live derby games (LOBBY -> COUNTDOWN -> GAME -> FINISHED), separate from services/derby.lua
--- (the arena definitions), the same split as infected.lua / infectedGrid.lua. Several games can run
--- at once, each on its own arena.
---
--- Three modes :
---   - lms ("last man standing") : wrecked with no lives left and you're out ; the last car running
---     wins.
---   - timed : a wrecked car respawns (only forfeiting puts you out) ; most wrecks when the clock
---     runs out wins.
---   - sumo : like lms, but the arena zone shrinks in steps.
--- In every mode, staying outside the arena zone (when the arena has one) or falling below its floor
--- is a wreck.
---
--- Wrecks are self-reported by the wrecked player's own client (beamjoy/derbyRunner.lua), with the
--- player who hit them last as the credited attacker : the same accepted trust model as Infected's
--- tags and Hunter's checkpoints. Damage dealt is reported the same way, in batches.
---
--- A player who leaves or disconnects mid-game is kept in the results (placed as eliminated at
--- that moment) : `session.departed`, never `participants`, since BeamMP reuses player ids.

---@alias BJDerbyState "LOBBY"|"COUNTDOWN"|"GAME"|"FINISHED"
---@alias BJDerbyMode "lms"|"timed"|"sumo"
---@alias BJDerbyWreckReason "wreck"|"engine"|"stuck"|"zone"|"fell"|"reset"|"forfeit"|"left"

---@class BJDerbyParticipant
---@field playerID integer
---@field playerName string
---@field scoreKey string? who the leaderboard credits ; nil for a guest without a nickname
---@field ready boolean
---@field vehicleModel string?
---@field startIndex integer?
---@field spawnPos {x: number, y: number, z: number}?
---@field spawnDir {x: number, y: number, z: number}?
---@field lives integer lives left (lms / sumo)
---@field wrecks integer wrecks credited to this player
---@field deaths integer times this player was wrecked
---@field damage integer damage dealt to other players
---@field eliminated boolean?
---@field eliminatedAtMs integer? ms into the game
---@field left boolean? left or disconnected mid-game
---@field lastDownAt number? server time of the last wreck report, to drop a duplicate one
---@field place integer? set once the game is FINISHED

---@class BJDerbySession
---@field id string
---@field starterID integer
---@field joinable boolean
---@field arenaId integer
---@field arenaSnapshot BJDerbyArena
---@field settings table see buildSettings
---@field state BJDerbyState
---@field createdAt number
---@field allReadyAt number?
---@field startedAt number?
---@field roundDeadlineAt number? timed only
---@field participants tablelib<integer, BJDerbyParticipant> index playerID
---@field departed BJDerbyParticipant[]
---@field feed {seq: integer, attacker: string?, victim: string, reason: string, out: boolean?}[]
---@field feedSeq integer
---@field standings table[]? FINISHED only
---@field dirty boolean? damage changed since the last push
---@field debugSolo boolean?

local M = {
    dependencies = { "services_derby", "services_vehiclePresets", "utils_async", "services_identity" },

    ---@type tablelib<string, BJDerbySession>
    sessions = Table(),
    ---@type tablelib<integer, string> playerID -> sessionId
    spectators = Table(),

    SCORES_FILE = "derbyScores.json",
    LEADERBOARD_SIZE = 50,
    FEED_SIZE = 6,
    -- a second report within this many seconds is a duplicate (the same wreck seen twice)
    DOWN_DEBOUNCE_SEC = 1.5,
    MAX_DAMAGE_REPORT = 10000000,
    ---@type table<string, {games: integer, wins: integer, wrecks: integer, deaths: integer, damage: integer}>
    scores = {},
}

local REASONS = { "wreck", "engine", "stuck", "zone", "fell", "reset", "forfeit" }
-- a reason that never credits anyone : you did it to yourself
local SELF_REASONS = { reset = true, forfeit = true }

---@param playerID integer
---@return BJDerbySession?
local function findSessionByParticipant(playerID)
    return M.sessions:find(function(s) return s.participants[playerID] ~= nil end)
end

---@param playerID integer
---@param fallbackName string
---@return string
local function resolveDisplayName(playerID, fallbackName)
    return services_identity.getIdentityKey(playerID) or fallbackName
end

---@param session BJDerbySession
---@param playerID integer
---@param playerName string
local function addParticipant(session, playerID, playerName)
    local player = services_players.players:find(function(p) return p.playerID == playerID end)
    local scoreKey = services_identity.getIdentityKey(playerID) or playerName
    if player and player.guest and not player.identityNickname then scoreKey = nil end
    session.participants[playerID] = {
        playerID = playerID,
        playerName = playerName,
        scoreKey = scoreKey,
        ready = false,
        lives = session.settings.lives,
        wrecks = 0,
        deaths = 0,
        damage = 0,
    }
end

---@param session BJDerbySession
---@return integer ms since the game started (0 before it)
local function elapsedMs(session)
    if not session.startedAt then return 0 end
    return math.floor((GetCurrentTime() - session.startedAt) * 1000)
end

---@param session BJDerbySession
---@return integer
local function aliveCount(session)
    local n = 0
    session.participants:forEach(function(p)
        if not p.eliminated then n = n + 1 end
    end)
    return n
end

--- every start position gets at most one player, in a random order
---@param session BJDerbySession
local function assignSpawns(session)
    local starts = session.arenaSnapshot.startPositions
    local free = {}
    for i = 1, #starts do free[#free + 1] = i end
    session.participants:forEach(function(p)
        local index = #free > 0 and table.remove(free, math.random(#free)) or math.random(#starts)
        p.startIndex = index
        p.spawnPos, p.spawnDir = starts[index].pos, starts[index].dir
    end)
end

---@param session BJDerbySession
---@return table
local function summarize(session)
    local starter = session.participants[session.starterID]
    return {
        id = session.id,
        starterName = starter and resolveDisplayName(starter.playerID, starter.playerName) or "?",
        joinable = session.joinable,
        -- the Activities list shows each arena's game on its card
        arenaId = session.arenaId,
        participantCount = session.participants:length(),
        maxParticipants = #session.arenaSnapshot.startPositions,
        state = session.state,
        -- the lobby's title in notices and Happening now
        raceName = session.arenaSnapshot.name,
        mode = session.settings.mode,
    }
end

---@param p BJDerbyParticipant
---@return table
local function publicParticipant(p)
    local c = table.clone(p)
    c.lastDownAt = nil
    c.scoreKey = nil
    c.displayName = p.left and p.playerName or resolveDisplayName(p.playerID, p.playerName)
    return c
end

---@param session BJDerbySession
---@return table
local function buildBasePayload(session)
    local payload = {
        id = session.id,
        starterID = session.starterID,
        joinable = session.joinable,
        arenaId = session.arenaId,
        arenaSnapshot = session.arenaSnapshot,
        settings = session.settings,
        state = session.state,
        feed = session.feed,
        feedSeq = session.feedSeq,
        standings = session.standings,
        participants = table.map(session.participants:values(), publicParticipant),
        departed = table.map(session.departed, publicParticipant),
        minParticipants = services_derby.MINIMUM_PARTICIPANTS,
    }
    if session.state == "GAME" or session.state == "FINISHED" then
        -- the preset's vehicles (whole part trees) only matter up to the countdown ; the game's
        -- frequent pushes go without them
        local settings = {}
        for k, v in pairs(session.settings) do
            if k ~= "vehiclePool" then settings[k] = v end
        end
        payload.settings = settings
    end
    if (session.state == "GAME" or session.state == "FINISHED") and session.startedAt then
        -- a duration, not a timestamp : the server's clock means nothing on a client
        payload.gameElapsedMs = elapsedMs(session)
    end
    if session.state == "GAME" and session.roundDeadlineAt then
        payload.roundSecondsLeft = math.max(0, math.ceil(session.roundDeadlineAt - GetCurrentTime()))
    end
    if session.state == "LOBBY" and session.joinable then
        payload.gridReadySecondsLeft = session.allReadyAt and
            math.max(0, math.ceil(session.settings.gridReadyTimeout - (GetCurrentTime() - session.allReadyAt)))
            or nil
        payload.gridTimeoutSecondsLeft = math.max(0,
            math.ceil(session.settings.gridTimeout - (GetCurrentTime() - session.createdAt)))
    end
    return payload
end

---@param session BJDerbySession
local function pushSessionUpdate(session)
    session.dirty = false
    local base = buildBasePayload(session)
    session.participants:forEach(function(_, playerID)
        communications_tx.sendToPlayer(playerID, "derbySessionUpdate", base)
    end)
    M.spectators:forEach(function(sessionId, playerID)
        if sessionId == session.id then
            communications_tx.sendToPlayer(playerID, "derbySpectateUpdate", base)
        end
    end)
end

local function pushOpenSessionsList()
    local visible = M.sessions:filter(function(s)
        return (s.state == "LOBBY" and s.joinable) or s.state == "COUNTDOWN" or s.state == "GAME"
    end):map(summarize):values()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "derbySessionsList", visible)
end

---@param session BJDerbySession
local function removeSession(session)
    for _, suffix in ipairs({ "readyTimeout", "gridTimeout", "countdown", "roundTimeout", "cleanup" }) do
        utils_async.removeTask("BJDerbyGrid-" .. session.id .. "-" .. suffix)
    end
    session.participants:forEach(function(_, playerID)
        communications_tx.sendToPlayer(playerID, "derbySessionRemoved", session.id)
    end)
    M.spectators:forEach(function(sessionId, playerID)
        if sessionId == session.id then
            communications_tx.sendToPlayer(playerID, "derbySpectateRemoved", session.id)
            M.spectators[playerID] = nil
        end
    end)
    M.sessions[session.id] = nil
    pushOpenSessionsList()
end

-- SCORES ----------------------------------------------------------------------------------------

local function loadScores()
    local saved = dao_main.get(M.SCORES_FILE)
    M.scores = type(saved) == "table" and type(saved.players) == "table" and saved.players or {}
end

local function saveScores()
    dao_main.save(M.SCORES_FILE, { players = M.scores })
end

---@param session BJDerbySession
---@param standings BJDerbyParticipant[]
local function recordScores(session, standings)
    if session.debugSolo then return end
    for _, p in ipairs(standings) do
        if p.scoreKey then
            local entry = M.scores[p.scoreKey] or { games = 0, wins = 0, wrecks = 0, deaths = 0, damage = 0 }
            entry.games = (entry.games or 0) + 1
            entry.wrecks = (entry.wrecks or 0) + (p.wrecks or 0)
            entry.deaths = (entry.deaths or 0) + (p.deaths or 0)
            entry.damage = (entry.damage or 0) + (p.damage or 0)
            if p.place == 1 then entry.wins = (entry.wins or 0) + 1 end
            M.scores[p.scoreKey] = entry
        end
    end
    saveScores()
end

--- what the board can be ranked by, higher first ; ties go to more wins, more wrecks, then fewer
--- games played for them
local SORTS = {
    wins = function(r) return r.wins end,
    rate = function(r) return r.games > 0 and r.wins / r.games or 0 end,
    wrecks = function(r) return r.wrecks end,
    damage = function(r) return r.damage end,
    games = function(r) return r.games end,
}
local SORT_ORDER = { "wins", "rate", "wrecks", "damage", "games" }

---@param rows table[]
---@param sort string
local function rankBy(rows, sort)
    local value = SORTS[sort]
    table.sort(rows, function(a, b)
        local va, vb = value(a), value(b)
        if va ~= vb then return va > vb end
        if a.wins ~= b.wins then return a.wins > b.wins end
        if a.wrecks ~= b.wrecks then return a.wrecks > b.wrecks end
        if a.games ~= b.games then return a.games < b.games end
        return a.name:lower() < b.name:lower()
    end)
end

--- the board ranked by `sort` (wins by default, see SORTS) : the top LEADERBOARD_SIZE, the sender's
--- own row and the places around it, and for every ranking its leader and the sender's place (the
--- Leaderboards window lists them all)
---@param ctxt BJSContext
---@param sort string?
local function derbyLeaderboardRequest(ctxt, sort)
    if not ctxt.sender then return end
    sort = SORTS[sort] and sort or "wins"
    local me = services_identity.getIdentityKey(ctxt.senderID) or ctxt.sender.playerName
    local rows = {}
    for name, e in pairs(M.scores) do
        rows[#rows + 1] = {
            name = name,
            games = e.games or 0,
            wins = e.wins or 0,
            wrecks = e.wrecks or 0,
            deaths = e.deaths or 0,
            damage = e.damage or 0,
        }
    end
    local rankings = {}
    for _, key in ipairs(SORT_ORDER) do
        rankBy(rows, key)
        local leader = rows[1]
        local myRank
        for i, row in ipairs(rows) do
            if row.name == me then myRank = i end
        end
        rankings[key] = {
            leader = leader and { name = leader.name, wins = leader.wins, wrecks = leader.wrecks,
                damage = leader.damage, games = leader.games } or nil,
            myRank = myRank,
        }
    end
    rankBy(rows, sort)
    local top, mine = {}, nil
    for i, row in ipairs(rows) do
        row.rank = i
        if row.name == me then
            row.you = true
            mine = row
        end
        if i <= M.LEADERBOARD_SIZE then top[#top + 1] = row end
    end
    -- five places either side of the sender (the "Around you" view), from the full list
    local around = {}
    if mine then
        for i = math.max(1, mine.rank - 5), math.min(#rows, mine.rank + 5) do around[#around + 1] = rows[i] end
    end
    communications_tx.sendToPlayer(ctxt.senderID, "derbyLeaderboard", {
        sort = sort, rows = top, players = #rows, mine = mine, around = around, rankings = rankings,
        size = M.LEADERBOARD_SIZE,
    })
end

-- ENDING ----------------------------------------------------------------------------------------

---@param session BJDerbySession
---@return BJDerbyParticipant[] everyone who played, best first
local function computeStandings(session)
    local all = {}
    session.participants:forEach(function(p) all[#all + 1] = p end)
    for _, p in ipairs(session.departed) do all[#all + 1] = p end
    local mode = session.settings.mode
    table.sort(all, function(a, b)
        if mode == "timed" then
            if a.wrecks ~= b.wrecks then return a.wrecks > b.wrecks end
            if a.deaths ~= b.deaths then return a.deaths < b.deaths end
            if a.damage ~= b.damage then return a.damage > b.damage end
        else
            -- still running beats out, then whoever lasted longer
            local aOut, bOut = a.eliminated == true, b.eliminated == true
            if aOut ~= bOut then return not aOut end
            if aOut and a.eliminatedAtMs ~= b.eliminatedAtMs then
                return (a.eliminatedAtMs or 0) > (b.eliminatedAtMs or 0)
            end
            if a.lives ~= b.lives then return a.lives > b.lives end
            if a.damage ~= b.damage then return a.damage > b.damage end
        end
        return a.playerName:lower() < b.playerName:lower()
    end)
    return all
end

---@param session BJDerbySession
local function endGame(session)
    if session.state == "FINISHED" then return end
    utils_async.removeTask("BJDerbyGrid-" .. session.id .. "-roundTimeout")
    local durationMs = elapsedMs(session)
    session.state = "FINISHED"
    local standings = computeStandings(session)
    for i, p in ipairs(standings) do p.place = i end
    session.standings = table.map(standings, function(p)
        return {
            playerID = p.playerID,
            displayName = p.left and p.playerName or resolveDisplayName(p.playerID, p.playerName),
            place = p.place,
            wrecks = p.wrecks,
            deaths = p.deaths,
            damage = p.damage,
            lives = p.lives,
            eliminated = p.eliminated == true,
            eliminatedAtMs = p.eliminatedAtMs,
            left = p.left == true,
        }
    end)
    pushSessionUpdate(session)
    utils_async.delayTask(function() removeSession(session) end,
        session.settings.endTimeout, "BJDerbyGrid-" .. session.id .. "-cleanup")

    recordScores(session, standings)
    if not session.debugSolo and services_discord and services_discord.onDerbyEnd then
        pcall(services_discord.onDerbyEnd, {
            mode = session.settings.mode,
            arenaName = session.arenaSnapshot.name,
            durationSec = math.floor(durationMs / 1000),
            standings = session.standings,
        })
    end
end

--- lms / sumo : one car (or none) left running ends it. Timed : fewer than two players left ends it
---@param session BJDerbySession
local function checkEnd(session)
    if session.state ~= "GAME" then return end
    -- timed included : one car left (the others forfeited or left) has nobody to wreck
    local alive = aliveCount(session)
    if alive == 0 or (alive <= 1 and not session.debugSolo) then endGame(session) end
end

---@param session BJDerbySession
---@param entry table
local function addFeed(session, entry)
    session.feedSeq = session.feedSeq + 1
    entry.seq = session.feedSeq
    table.insert(session.feed, entry)
    while #session.feed > M.FEED_SIZE do table.remove(session.feed, 1) end
end

--- someone left the game while it's running (leave, disconnect) : out, and kept for the results
---@param session BJDerbySession
---@param playerID integer
local function depart(session, playerID)
    local p = session.participants[playerID]
    if not p then return end
    session.participants[playerID] = nil
    if session.state == "GAME" then
        p.left = true
        if not p.eliminated then
            p.eliminated = true
            p.eliminatedAtMs = elapsedMs(session)
            addFeed(session, { victim = p.playerName, reason = "left", out = true })
        end
        table.insert(session.departed, p)
    end
end

-- SETTINGS / FLOW -------------------------------------------------------------------------------

---@param arena BJDerbyArena
---@param overrides table?
---@return table
local function buildSettings(arena, overrides)
    overrides = type(overrides) == "table" and overrides or {}
    local merged = table.clone(arena.defaults or {})
    for k, v in pairs(overrides) do
        if v ~= nil then merged[k] = v end
    end
    local s = services_derby.sanitizeDefaults(merged)
    if s.mode == "sumo" and not arena.zone then s.mode = "lms" end

    -- a vehicle preset everyone drives (resolved once here, never re-read live)
    local presetId = tonumber(overrides.vehiclePresetId)
    if overrides.vehiclePresetId == nil then presetId = tonumber(arena.defaults and arena.defaults.vehiclePresetId) end
    s.vehiclePresetId = nil
    if presetId then
        local preset = services_vehiclePresets.getById(presetId)
        if preset and table.isArray(preset.entries) and #preset.entries > 0 then
            s.vehiclePresetId = presetId
            s.vehiclePool = preset.entries
            s.vehicleLabel = preset.name
        end
    end
    s.randomizeVehiclePool = s.vehiclePool ~= nil and s.randomizeVehiclePool == true
    if s.mode == "timed" then s.lives = 0 end
    return s
end

---@param session BJDerbySession
local function beginCountdown(session)
    session.state = "COUNTDOWN"
    assignSpawns(session)
    session.participants:forEach(function(p) p.lives = session.settings.lives end)
    pushSessionUpdate(session)
    pushOpenSessionsList()
    utils_async.delayTask(function() M.beginGame(session.id) end,
        session.settings.countdown, "BJDerbyGrid-" .. session.id .. "-countdown")
end

---@param sessionId string
local function beginGame(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "COUNTDOWN" then return end
    session.state = "GAME"
    session.startedAt = GetCurrentTime()
    if session.settings.mode == "timed" then
        session.roundDeadlineAt = GetCurrentTime() + session.settings.roundDuration * 60
        utils_async.delayTask(function() M.onRoundTimeout(session.id) end,
            session.settings.roundDuration * 60, "BJDerbyGrid-" .. session.id .. "-roundTimeout")
    end
    pushSessionUpdate(session)
    pushOpenSessionsList()
end

---@param sessionId string
local function onRoundTimeout(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "GAME" then return end
    endGame(session)
end

local tryStartFromLobby

--- when everyone became ready together, cleared when that stops being true : the start floor
--- (gridReadyTimeout) counts from that moment, same as the other lobbies
---@param session BJDerbySession
local function updateAllReadyState(session)
    local allReady = session.participants:length() > 0 and
        session.participants:every(function(p) return p.ready end)
    local key = "BJDerbyGrid-" .. session.id .. "-readyTimeout"
    if allReady and not session.allReadyAt then
        session.allReadyAt = GetCurrentTime()
        utils_async.delayTask(function() tryStartFromLobby(session) end,
            session.settings.gridReadyTimeout, key)
    elseif not allReady and session.allReadyAt then
        session.allReadyAt = nil
        utils_async.removeTask(key)
    end
end

---@param session BJDerbySession
tryStartFromLobby = function(session)
    if session.state ~= "LOBBY" then return end
    if session.participants:length() < services_derby.MINIMUM_PARTICIPANTS and not session.debugSolo then
        return
    end
    if not session.participants:every(function(p) return p.ready end) then return end
    updateAllReadyState(session)
    if not session.debugSolo and
        not (session.allReadyAt and GetCurrentTime() - session.allReadyAt >= session.settings.gridReadyTimeout) then
        return
    end
    beginCountdown(session)
end

---@param sessionId string
local function onGridTimeout(sessionId)
    local session = M.sessions[sessionId]
    if not session or session.state ~= "LOBBY" then return end
    local kicked = session.participants:filter(function(p) return not p.ready end):values()
    session.participants = session.participants:filter(function(p) return p.ready end, true)
    table.forEach(kicked, function(p)
        communications_tx.sendToPlayer(p.playerID, "derbySessionRemoved", session.id)
    end)
    if session.participants:length() < services_derby.MINIMUM_PARTICIPANTS and not session.debugSolo then
        return removeSession(session)
    end
    if not session.participants[session.starterID] then
        session.starterID = session.participants:keys()[1]
    end
    beginCountdown(session)
end

-- HANDLERS --------------------------------------------------------------------------------------

---@param ctxt BJSContext
---@param sessionId string
local function derbyStartNow(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "LOBBY" or session.starterID ~= ctxt.senderID then return end
    local leader = session.participants[ctxt.senderID]
    if leader then leader.ready = true end
    utils_async.removeTask("BJDerbyGrid-" .. session.id .. "-gridTimeout")
    onGridTimeout(session.id)
end

---@param ctxt BJSContext
---@param opts table? {arenaId, mode, lives, roundDuration, stuckSeconds, ...} see buildSettings
---@return string? sessionId
local function derbyStart(ctxt, opts)
    if not ctxt.sender then return end
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.derby.alreadyInSession", ctxt.sender.lang))
    end
    opts = type(opts) == "table" and opts or {}
    local arena = services_derby.getArena(opts.arenaId)
    if not services_derby.isPlayable(arena) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.derby.arenaUnavailable", ctxt.sender.lang))
    end
    ---@cast arena BJDerbyArena
    -- one game per arena : two would share the same ground and start positions
    if M.sessions:find(function(s) return s.arenaId == arena.id and s.state ~= "FINISHED" end) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.derby.arenaBusy", ctxt.sender.lang))
    end

    ---@type BJDerbySession
    local session = {
        id = UUID(),
        starterID = ctxt.senderID,
        joinable = true,
        arenaId = arena.id,
        arenaSnapshot = table.clone(arena),
        settings = buildSettings(arena, opts),
        state = "LOBBY",
        createdAt = ctxt.time,
        participants = Table(),
        departed = {},
        feed = {},
        feedSeq = 0,
        -- only ever via the staff-gated "/derby debug start" command, never trusted from the UI
        debugSolo = opts.debugSolo == true and services_permissions.isStaff(ctxt.sender.playerName),
    }
    addParticipant(session, ctxt.senderID, ctxt.sender.playerName)
    M.sessions[session.id] = session

    utils_async.delayTask(function() onGridTimeout(session.id) end,
        session.settings.gridTimeout, "BJDerbyGrid-" .. session.id .. "-gridTimeout")

    pushSessionUpdate(session)
    pushOpenSessionsList()
    services_crews.pullIn(ctxt.senderID, "derby", session.id)
    return session.id
end

---@param ctxt BJSContext
---@param sessionId string
local function derbyJoin(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "LOBBY" or not session.joinable then return end
    -- the arena was disabled or removed after the lobby opened : no new players
    if not services_derby.isPlayable(services_derby.getArena(session.arenaId)) then return end
    if session.participants[ctxt.senderID] then return end
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.derby.alreadyInSession", ctxt.sender.lang))
    end
    if session.participants:length() >= #session.arenaSnapshot.startPositions then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.derby.arenaFull", ctxt.sender.lang))
    end

    addParticipant(session, ctxt.senderID, ctxt.sender.playerName)
    updateAllReadyState(session)
    pushSessionUpdate(session)
    pushOpenSessionsList()
end

---@param ctxt BJSContext
---@param sessionId string
local function derbySpectate(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state == "LOBBY" or session.state == "FINISHED" then return end
    if findSessionByParticipant(ctxt.senderID) then
        return communications_tx.sendToPlayer(ctxt.senderID, "toast", "error",
            services_lang.get("error.derby.alreadyInSession", ctxt.sender.lang))
    end
    M.spectators[ctxt.senderID] = sessionId
    communications_tx.sendToPlayer(ctxt.senderID, "derbySpectateUpdate", buildBasePayload(session))
end

---@param ctxt BJSContext
local function derbyStopSpectate(ctxt)
    if not ctxt.sender then return end
    local sessionId = M.spectators[ctxt.senderID]
    if not sessionId then return end
    M.spectators[ctxt.senderID] = nil
    communications_tx.sendToPlayer(ctxt.senderID, "derbySpectateRemoved", sessionId)
end

--- a player leaves (the button, a disconnect...) : in LOBBY they're simply gone, once the game is
--- running they're placed as out
---@param session BJDerbySession
---@param playerID integer
local function removeParticipant(session, playerID)
    if session.state == "COUNTDOWN" or session.state == "GAME" then
        depart(session, playerID)
    else
        session.participants[playerID] = nil
    end
    if session.participants:length() == 0 then
        return removeSession(session)
    end
    if playerID == session.starterID then
        session.starterID = session.participants:keys()[1]
    end
    if session.state == "LOBBY" then
        tryStartFromLobby(session)
    elseif session.state == "COUNTDOWN" then
        if session.participants:length() < services_derby.MINIMUM_PARTICIPANTS and not session.debugSolo then
            return removeSession(session)
        end
    elseif session.state == "GAME" then
        checkEnd(session)
    end
    if M.sessions[session.id] then
        pushSessionUpdate(session)
        pushOpenSessionsList()
    end
end

---@param ctxt BJSContext
---@param sessionId string
local function derbyLeave(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or not session.participants[ctxt.senderID] then return end
    communications_tx.sendToPlayer(ctxt.senderID, "derbySessionRemoved", sessionId)
    removeParticipant(session, ctxt.senderID)
end

--- the leader or staff : closes the game at once, no results
---@param ctxt BJSContext
---@param sessionId string
local function derbyCancel(ctxt, sessionId)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session then return end
    if session.starterID ~= ctxt.senderID and not services_permissions.isStaff(ctxt.sender.playerName) then
        return
    end
    if session.starterID ~= ctxt.senderID then
        session.participants:forEach(function(_, playerID)
            local player = services_players.players:find(function(p) return p.playerID == playerID end)
            communications_tx.sendToPlayer(playerID, "toast", "info",
                services_lang.get("derby.cancelledByStaff", player and player.lang)
                :var({ name = ctxt.sender.playerName }))
        end)
    end
    removeSession(session)
end

---@param ctxt BJSContext
---@param sessionId string
---@param ready boolean
---@param model string? the vehicle being readied with
local function derbyReady(ctxt, sessionId, ready, model)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "LOBBY" then return end
    local participant = session.participants[ctxt.senderID]
    if not participant then return end
    participant.ready = ready == true
    if participant.ready and type(model) == "string" and model ~= "" then
        participant.vehicleModel = model
    end
    if participant.ready then
        tryStartFromLobby(session)
    else
        updateAllReadyState(session)
    end
    if M.sessions[sessionId] then pushSessionUpdate(session) end
end

--- a readied player changed their vehicle : not ready any more (same rule as the other lobbies)
---@param playerID integer
local function unreadyOnVehicleChange(playerID)
    local session = findSessionByParticipant(playerID)
    if not session or session.state ~= "LOBBY" then return end
    local participant = session.participants[playerID]
    if not participant or not participant.ready then return end
    participant.ready = false
    updateAllReadyState(session)
    pushSessionUpdate(session)
end

--- the sender's car was wrecked (or they reset / forfeited) : credits the attacker, costs a life or
--- puts them out. The sender's own client already respawned them when a life remained
---@param ctxt BJSContext
---@param sessionId string
---@param reason BJDerbyWreckReason
---@param attackerID integer? whoever hit them last
local function derbyWrecked(ctxt, sessionId, reason, attackerID)
    if not ctxt.sender then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "GAME" then return end
    local p = session.participants[ctxt.senderID]
    if not p or p.eliminated then return end
    if not table.includes(REASONS, reason) then reason = "wreck" end
    local now = GetCurrentTime()
    if p.lastDownAt and now - p.lastDownAt < M.DOWN_DEBOUNCE_SEC and reason ~= "forfeit" then return end
    p.lastDownAt = now

    local attacker = not SELF_REASONS[reason] and session.participants[tonumber(attackerID)] or nil
    if attacker and attacker.playerID == p.playerID then attacker = nil end

    if reason ~= "forfeit" then p.deaths = p.deaths + 1 end
    if attacker then attacker.wrecks = attacker.wrecks + 1 end

    -- forfeiting puts you out in every mode, timed included ; otherwise only running out of lives
    local out = reason == "forfeit"
    if not out and session.settings.mode ~= "timed" then
        if p.lives > 0 then p.lives = p.lives - 1 else out = true end
    end
    if out then
        p.eliminated = true
        p.eliminatedAtMs = elapsedMs(session)
    end
    addFeed(session, {
        attacker = attacker and resolveDisplayName(attacker.playerID, attacker.playerName) or nil,
        victim = resolveDisplayName(p.playerID, p.playerName),
        reason = reason,
        out = out or nil,
    })

    checkEnd(session)
    if M.sessions[sessionId] and session.state == "GAME" then pushSessionUpdate(session) end
end

--- a batch of damage the sender's car took, per player who dealt it
---@param ctxt BJSContext
---@param sessionId string
---@param dealt table<string|integer, number> attacker playerID -> damage
local function derbyDamage(ctxt, sessionId, dealt)
    if not ctxt.sender or type(dealt) ~= "table" then return end
    local session = M.sessions[sessionId]
    if not session or session.state ~= "GAME" then return end
    if not session.participants[ctxt.senderID] then return end
    for id, amount in pairs(dealt) do
        local attacker = session.participants[tonumber(id)]
        amount = tonumber(amount)
        if attacker and attacker.playerID ~= ctxt.senderID and amount and amount > 0 then
            attacker.damage = attacker.damage + math.floor(math.min(amount, M.MAX_DAMAGE_REPORT))
            session.dirty = true
        end
    end
end

-- DEBUG -----------------------------------------------------------------------------------------

--- "/derby debug start [arena id] [mode]" : a staff member alone can walk through a whole game
---@param ctxt BJSContext
---@param args string[]
local function chatDerbyDebug(ctxt, args)
    if not services_permissions.isStaff(ctxt.sender.playerName) then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.derby.debug.staffOnly", ctxt.sender.lang), services_chat.COLORS.ERROR)
    end
    local sub = args[2] and args[2]:lower()
    if sub == "start" then
        if findSessionByParticipant(ctxt.senderID) then
            return services_chat.directSend(ctxt.senderID,
                services_lang.get("error.derby.alreadyInSession", ctxt.sender.lang), services_chat.COLORS.ERROR)
        end
        local arenaId = tonumber(args[3])
        if not arenaId then
            local first = table.find(services_derby.data, function(a) return services_derby.isPlayable(a) end)
            arenaId = first and first.id
        end
        local mode = services_derby.isMode(args[4]) and args[4] or nil
        local sessionId = M.derbyStart(ctxt, { arenaId = arenaId, mode = mode, debugSolo = true })
        if not sessionId then
            return services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.derby.debug.startFailed", ctxt.sender.lang), services_chat.COLORS.ERROR)
        end
        M.derbyReady(ctxt, sessionId, true)
        return services_chat.directSend(ctxt.senderID, services_lang.get("chat.command.derby.debug.started", ctxt.sender.lang))
    elseif sub == "finish" then
        local session = findSessionByParticipant(ctxt.senderID)
        if not session or session.state ~= "GAME" then
            return services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.derby.debug.notActive", ctxt.sender.lang), services_chat.COLORS.ERROR)
        end
        return endGame(session)
    end
    services_chat.directSend(ctxt.senderID,
        services_lang.get("chat.command.derby.debug.usage", ctxt.sender.lang), services_chat.COLORS.ERROR)
end

--- "/derby <join|leave|ready|cancel>" acts on the first open lobby / the game you're in
---@param ctxt BJSContext
---@param args string[]
---@param command BJChatCommand
local function chatDerby(ctxt, args, command)
    local sub = args[1] and args[1]:lower()
    if sub == "debug" then return chatDerbyDebug(ctxt, args) end
    if not table.includes({ "join", "leave", "ready", "cancel" }, sub) then
        return services_chat.directSend(ctxt.senderID,
            string.format("%s : %s -> %s",
                services_lang.get("chat.command.usage", ctxt.sender.lang),
                services_lang.get(command.commandKey, ctxt.sender.lang),
                services_lang.get(command.descKey, ctxt.sender.lang)),
            services_chat.COLORS.ERROR)
    end

    if sub == "join" then
        local open = M.sessions:find(function(s) return s.state == "LOBBY" and s.joinable end)
        if not open then
            return services_chat.directSend(ctxt.senderID,
                services_lang.get("chat.command.derby.noneOpen", ctxt.sender.lang), services_chat.COLORS.ERROR)
        end
        return M.derbyJoin(ctxt, open.id)
    end

    local session = findSessionByParticipant(ctxt.senderID)
    if not session then
        return services_chat.directSend(ctxt.senderID,
            services_lang.get("chat.command.derby.notInSession", ctxt.sender.lang), services_chat.COLORS.ERROR)
    end
    if sub == "leave" then
        M.derbyLeave(ctxt, session.id)
        services_chat.directSend(ctxt.senderID, services_lang.get("chat.command.derby.left", ctxt.sender.lang))
    elseif sub == "ready" then
        local nowReady = not session.participants[ctxt.senderID].ready
        M.derbyReady(ctxt, session.id, nowReady)
        services_chat.directSend(ctxt.senderID,
            services_lang.get(nowReady and "chat.command.derby.readyOn" or "chat.command.derby.readyOff", ctxt.sender.lang))
    elseif sub == "cancel" then
        local sessionId = session.id
        M.derbyCancel(ctxt, sessionId)
        services_chat.directSend(ctxt.senderID, services_lang.get(M.sessions[sessionId] and
            "chat.command.error.noPermission" or "chat.command.derby.cancelled", ctxt.sender.lang))
    end
end

local function onInit()
    loadScores()
    communications_rx.addHandler("derbyStart", M.derbyStart)
    communications_rx.addHandler("derbyStartNow", M.derbyStartNow)
    communications_rx.addHandler("derbyJoin", M.derbyJoin)
    communications_rx.addHandler("derbyLeave", M.derbyLeave)
    communications_rx.addHandler("derbyCancel", M.derbyCancel)
    communications_rx.addHandler("derbyReady", M.derbyReady)
    communications_rx.addHandler("derbyWrecked", M.derbyWrecked)
    communications_rx.addHandler("derbyDamage", M.derbyDamage)
    communications_rx.addHandler("derbySpectate", M.derbySpectate)
    communications_rx.addHandler("derbyStopSpectate", M.derbyStopSpectate)
    communications_rx.addHandler("derbyLeaderboardRequest", M.derbyLeaderboardRequest)

    services_chatCommands.addCommand("derby", "chat.command.derby.desc", M.chatDerby,
        { commandKey = "chat.command.derby.command" })
end

--- damage totals ride along on the next push instead of one push per report
local function onSlowUpdate()
    M.sessions:forEach(function(session)
        if session.dirty and session.state == "GAME" then pushSessionUpdate(session) end
    end)
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.spectators[playerID] = nil
    M.sessions:forEach(function(session)
        if session.participants[playerID] then removeParticipant(session, playerID) end
    end)
end

--- the map changed : every game on the old map is over
local function onMapChanged()
    M.sessions:forEach(function(session) removeSession(session) end)
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate
M.onPlayerDisconnect = onPlayerDisconnect
M.onMapChanged = onMapChanged

M.findSessionByParticipant = findSessionByParticipant
M.summarize = summarize
M.derbyStart = derbyStart
M.derbyStartNow = derbyStartNow
M.derbyJoin = derbyJoin
M.derbyLeave = derbyLeave
M.derbyCancel = derbyCancel
M.derbyReady = derbyReady
M.derbyWrecked = derbyWrecked
M.derbyDamage = derbyDamage
M.derbySpectate = derbySpectate
M.derbyStopSpectate = derbyStopSpectate
M.derbyLeaderboardRequest = derbyLeaderboardRequest
M.unreadyOnVehicleChange = unreadyOnVehicleChange
M.beginGame = beginGame
M.onRoundTimeout = onRoundTimeout
M.chatDerby = chatDerby

return M
