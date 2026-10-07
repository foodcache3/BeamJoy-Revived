--- Leaderboards for the game's own freeroam challenges : drift spots and drag strips (direct
--- request). The game runs both entirely on each player's own game and keeps scores only there ;
--- each player's BeamJoy client reports a finished drift spot (its score) or drag run (its times,
--- see beamjoy/freeroamChallenges.lua) and this keeps every player's best per spot / strip, per
--- map, for the Leaderboards window's Drift and Drag sections.
---
--- Results come from the player's own game : the server can't check a drift score or a drag time
--- the way it checks race gates against car positions. They're checked for being numbers in a
--- possible range, and a player can't send more than one every few seconds.

local M = {
    dependencies = { "dao_main", "services_core", "services_identity", "services_players",
        "communications_rx", "communications_tx" },

    SCORES_FILE = "freeroamChallenges.json",
    LEADERBOARD_SIZE = 50,
    --- seconds between two results from the same player (a drift spot or a drag run takes longer)
    MIN_SUBMIT_SECONDS = 4,

    --- kind ("drift"/"drag") -> map -> spot or strip id -> leaderboard key -> best run
    ---@type table<string, table<string, table<string, table<string, table>>>>
    data = { drift = {}, drag = {} },
    ---@type table<string, integer> "<playerName>" -> GetCurrentTime() of their last result
    lastSubmit = {},
}

---@param v any
---@param min number
---@param max number
---@return number?
local function num(v, min, max)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge or v < min or v > max then return nil end
    return v
end

---@param v any
---@param maxLen integer
---@return string?
local function str(v, maxLen)
    if type(v) ~= "string" then return nil end
    v = v:sub(1, maxLen)
    if #v == 0 or v:find("%c") then return nil end
    return v
end

--- a drag run's marks : timer id -> number, at most 16, ids up to 24 plain characters
---@param splits any
---@return table<string, number>?
function M.cleanSplits(splits)
    if type(splits) ~= "table" then return nil end
    local out, n = {}, 0
    for id, v in pairs(splits) do
        if type(id) == "string" and #id <= 24 and id:match("^[%w_]+$") then
            local value = num(v, -5, 250)
            if value then
                out[id] = value
                n = n + 1
                if n >= 16 then break end
            end
        end
    end
    return n > 0 and out or nil
end

--- per kind : what a run keeps, which of two runs is better, and the value a board is ranked by
local KINDS = {
    drift = {
        --- higher score first
        better = function(a, b) return a.score > b.score end,
        ---@return table?
        clean = function(r)
            local score = num(r.score, 1, 2000000) -- a gold target is ~14k : room for anything real
            if not score then return nil end
            return { score = math.floor(score) }
        end,
        value = function(e) return e.score end,
    },
    drag = {
        --- lower elapsed time first
        better = function(a, b) return a.et < b.et end,
        clean = function(r)
            local et = num(r.et, 1, 120)
            if not et then return nil end
            return {
                et = et,
                reaction = num(r.reaction, -5, 10),
                sixty = num(r.sixty, 0.3, 60),
                trap = num(r.trap, 0, 250), -- m/s
                timer = str(r.timer, 24), -- what the strip times, "1/4 mile"
                dial = num(r.dial, 0, 120),
                -- every mark of the run (timer id -> seconds, or m/s for speeds) : the drag
                -- overlay compares the next run with this one mark by mark
                splits = M.cleanSplits(r.splits),
            }
        end,
        value = function(e) return e.et end,
    },
}

local function load()
    local saved = dao_main.get(M.SCORES_FILE)
    M.data = { drift = {}, drag = {} }
    if type(saved) == "table" then
        for kind in pairs(KINDS) do
            if type(saved[kind]) == "table" then M.data[kind] = saved[kind] end
        end
    end
end

local function save()
    dao_main.save(M.SCORES_FILE, M.data)
end

--- the boards of the current map for a kind
---@param kind string
---@return table<string, table<string, table>>
local function mapBoards(kind)
    local map = services_core.getCurrentMap()
    M.data[kind][map] = M.data[kind][map] or {}
    return M.data[kind][map]
end

--- a board's runs, best first, as rows
---@param kind string
---@param board table<string, table>
---@return table[]
local function ranked(kind, board)
    local def = KINDS[kind]
    local rows = {}
    for name, e in pairs(board) do
        local row = table.clone(e)
        row.name = name
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b)
        if def.value(a) ~= def.value(b) then return def.better(a, b) end
        -- tied : whoever got there first
        if (a.date or 0) ~= (b.date or 0) then return (a.date or 0) < (b.date or 0) end
        return a.name:lower() < b.name:lower()
    end)
    return rows
end

--- who a player's runs count for : their nickname, else their name. A guest without a nickname
--- has a throwaway name (a new one each launcher start) : nothing to keep
---@param ctxt BJSContext
---@return string?
local function scoreKey(ctxt)
    if ctxt.sender.guest and not ctxt.sender.identityNickname then return nil end
    return services_identity.getIdentityKey(ctxt.senderID) or ctxt.sender.playerName
end

--- a finished drift spot or drag run from a player's game
---@param ctxt BJSContext
---@param kind string "drift" | "drag"
---@param spotId string the drift spot or drag strip
---@param result table
local function challengeResult(ctxt, kind, spotId, result)
    if not ctxt.sender then return end
    local def = KINDS[kind]
    spotId = str(spotId, 96)
    if not def or not spotId or type(result) ~= "table" then return end
    local now = GetCurrentTime()
    local last = M.lastSubmit[ctxt.sender.playerName]
    if last and now - last < M.MIN_SUBMIT_SECONDS then return end
    M.lastSubmit[ctxt.sender.playerName] = now

    local key = scoreKey(ctxt)
    if not key then
        return communications_tx.sendToPlayer(ctxt.senderID, "challengeResultSaved",
            { kind = kind, spot = spotId, saved = false, reason = "guest" })
    end
    local run = def.clean(result)
    if not run then return end
    run.vehicle = str(result.vehicle, 64)
    run.date = os.time()

    local boards = mapBoards(kind)
    boards[spotId] = boards[spotId] or {}
    local board = boards[spotId]
    local entry = board[key]
    local improved = not entry or def.better(run, entry)
    if improved then
        run.runs = (entry and entry.runs or 0) + 1
        board[key] = run
    else
        entry.runs = (entry.runs or 0) + 1
    end
    save()

    local rows = ranked(kind, board)
    local rank
    for i, row in ipairs(rows) do
        if row.name == key then rank = i break end
    end
    communications_tx.sendToPlayer(ctxt.senderID, "challengeResultSaved", {
        kind = kind,
        spot = spotId,
        saved = true,
        best = improved,
        first = entry == nil,
        -- a better run that's now first : a new server record (theirs or someone else's before)
        record = improved and rank == 1,
        rank = rank,
        players = #rows,
        value = def.value(run),
    })
end

--- every spot or strip of the current map with a board : its leader and the sender's place
---@param ctxt BJSContext
---@param kind string
local function challengeSummaryRequest(ctxt, kind)
    if not ctxt.sender or not KINDS[kind] then return end
    local me = scoreKey(ctxt)
    local list = {}
    for spotId, board in pairs(mapBoards(kind)) do
        local rows = ranked(kind, board)
        local myRank
        for i, row in ipairs(rows) do
            if row.name == me then myRank = i break end
        end
        if rows[1] then
            list[#list + 1] = { spot = spotId, leader = rows[1], myRank = myRank, players = #rows }
        end
    end
    communications_tx.sendToPlayer(ctxt.senderID, "challengeSummary", { kind = kind, spots = list })
end

--- one spot's or strip's board : the top LEADERBOARD_SIZE, the sender's run and five places either
--- side of it (the "Around you" view)
---@param ctxt BJSContext
---@param kind string
---@param spotId string
local function challengeBoardRequest(ctxt, kind, spotId)
    if not ctxt.sender or not KINDS[kind] or type(spotId) ~= "string" then return end
    local me = scoreKey(ctxt)
    local rows = ranked(kind, mapBoards(kind)[spotId] or {})
    local top, mine = {}, nil
    for i, row in ipairs(rows) do
        row.rank = i
        if me and row.name == me then
            row.you = true
            mine = row
        end
        if i <= M.LEADERBOARD_SIZE then top[#top + 1] = row end
    end
    local around = {}
    if mine then
        for i = math.max(1, mine.rank - 5), math.min(#rows, mine.rank + 5) do around[#around + 1] = rows[i] end
    end
    communications_tx.sendToPlayer(ctxt.senderID, "challengeBoard", {
        kind = kind, spot = spotId, rows = top, players = #rows, mine = mine, around = around,
        size = M.LEADERBOARD_SIZE,
    })
end

-- DRAG LANES ------------------------------------------------------------------------------------
-- In freeroam the game runs a drag for this game's own car only : two players lined up side by
-- side each run their own tree and timers, and neither game knows about the other. Each client
-- reports where it's lined up and its run as it happens (beamjoy/dragRun.lua) ; two players in
-- opposite lanes of the same strip are paired, and each gets the other's run (every mark as it's
-- set) for its overlay and timeslip. Who won is worked out on each side from reaction + time, which
-- is who would have crossed first had both trees dropped together.

M.LANE_MSGS_PER_SECOND = 12
--- playerID -> where they're lined up and their run so far
---@type table<integer, table>
M.lanes = {}
--- playerID -> {second, count} : message rate
M.laneRate = {}
--- playerID -> the opponent state last sent to them (encoded), to skip repeats
M.laneSent = {}

---@param playerID integer
---@return table? the state of whoever is lined up against this player
local function opponentOf(playerID)
    local me = M.lanes[playerID]
    if not me then return nil end
    local best
    for pid, s in pairs(M.lanes) do
        if pid ~= playerID and s.map == me.map and s.strip == me.strip and s.lane ~= me.lane then
            if not best or s.since > best.since then best = s end
        end
    end
    return best
end

--- tells everyone lined up on `strip` (of `map`) who's against them, when that changed
---@param map string
---@param strip string
local function pushStrip(map, strip)
    for pid, s in pairs(M.lanes) do
        if s.map == map and s.strip == strip then
            local opp = opponentOf(pid)
            local payload = opp and {
                name = opp.name, car = opp.car, lane = opp.lane, phase = opp.phase,
                splits = opp.splits, dial = opp.dial, dq = opp.dq, finished = opp.finished,
                run = opp.run,
            } or false
            local encoded = utils_json.stringify(payload)
            if M.laneSent[pid] ~= encoded then
                M.laneSent[pid] = encoded
                communications_tx.sendToPlayer(pid, "dragOpponent", payload)
            end
        end
    end
end

---@param playerID integer
local function leaveLane(playerID)
    local s = M.lanes[playerID]
    M.lanes[playerID] = nil
    M.laneSent[playerID] = nil
    if s then pushStrip(s.map, s.strip) end
end

--- a player's drag : lined up (strip, lane), its phase, and every mark set so far ; nil when they
--- left the strip
---@param ctxt BJSContext
---@param state table?
local function dragState(ctxt, state)
    if not ctxt.sender then return end
    local pid = ctxt.senderID
    local now = GetCurrentTime()
    local rate = M.laneRate[pid]
    if not rate or rate.second ~= now then
        rate = { second = now, count = 0 }
        M.laneRate[pid] = rate
    end
    rate.count = rate.count + 1
    if rate.count > M.LANE_MSGS_PER_SECOND then return end

    if type(state) ~= "table" then return leaveLane(pid) end
    local strip = str(state.strip, 96)
    local lane = tonumber(state.lane)
    if not strip or not lane or lane < 1 or lane > 8 or lane % 1 ~= 0 then return leaveLane(pid) end
    local map = services_core.getCurrentMap()
    local previous = M.lanes[pid]
    if previous and (previous.strip ~= strip or previous.map ~= map) then leaveLane(pid) end
    M.lanes[pid] = {
        map = map,
        strip = strip,
        lane = lane,
        since = previous and previous.strip == strip and previous.since or now,
        name = services_identity.getIdentityKey(pid) or ctxt.sender.playerName,
        car = str(state.car, 64),
        phase = str(state.phase, 16),
        splits = M.cleanSplits(state.splits),
        dial = num(state.dial, 0, 120),
        dq = str(state.dq, 96),
        finished = state.finished == true,
        -- counts this player's runs on the strip : a new run clears the other side's view
        run = math.floor(num(state.run, 0, 1e6) or 0),
    }
    pushStrip(map, strip)
end

local function onPlayerDisconnect(playerID)
    local name = MP.GetPlayerName(playerID)
    if name then M.lastSubmit[name] = nil end
    M.laneRate[playerID] = nil
    leaveLane(playerID)
end

local function onInit()
    load()
    communications_rx.addHandler("challengeResult", M.challengeResult)
    communications_rx.addHandler("challengeSummaryRequest", M.challengeSummaryRequest)
    communications_rx.addHandler("challengeBoardRequest", M.challengeBoardRequest)
    communications_rx.addHandler("dragState", M.dragState)
end

M.onInit = onInit
M.onPlayerDisconnect = onPlayerDisconnect
M.challengeResult = challengeResult
M.challengeSummaryRequest = challengeSummaryRequest
M.challengeBoardRequest = challengeBoardRequest
M.dragState = dragState
--- a map change : nobody is lined up anymore
M.onMapChanged = function()
    M.lanes, M.laneSent = {}, {}
end

return M
