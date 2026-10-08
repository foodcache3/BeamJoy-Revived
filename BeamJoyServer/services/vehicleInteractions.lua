--- Using the interactive buttons on other players' cars : door handles, the hood and trunk, light
--- switches, the horn, every trigger the game lets you click on a car. Clicking one on someone else's
--- car does nothing in plain BeamMP : the click runs on this player's own copy of that car, which
--- BeamMP doesn't send anywhere (and it blocks latches on such copies outright). So the client sends
--- the click here instead (beamjoy/vehicleInteractions.lua), this checks it and passes it to the
--- car's owner, whose client presses that same trigger on their own car ; BeamMP then shows the
--- result to everyone like any change the owner makes.
---
--- A player can lock their vehicles (Settings > Vehicle) : nobody but their crew can use them then.
---
--- Wire : vehicleLocked(locked) from each client (on join and on change) ;
--- vehicleTriggerRequest(serverVID, triggerId, actionNumber, value, ownServerVID) -> the owner gets
--- vehicleTrigger(serverVID, triggerId, actionNumber, value, requesterName), or the requester a
--- toast when it's refused (a press only, never its release).
---
--- Latch state for late joiners : BeamMP sends a door opening or closing as it happens, never the
--- state itself, so a player who joins (or whose game spawns the car later) sees every door closed.
--- Each owner reports their cars' open / broken latches (vehicleLatches(serverVID, latches)) ;
--- this keeps them and hands them out in the join cache (vehicleLatches) and to everyone on change,
--- and each client applies them to a car when it appears.
---
--- Electrics for late joiners : BeamMP only sends a car's electrics as they change. A client that
--- sees another player's car appear asks for them (vehicleResyncRequest(serverVIDs)) ; this passes
--- each car on to its owner (vehicleResync(serverVIDs)), whose game makes BeamMP send them all again.
--- Nothing is kept here.

local M = {
    -- between the requester's own vehicle and the car, by BeamMP's copy of their positions :
    -- generous, those positions lag behind and are each vehicle's origin, not the button (a bus is
    -- long)
    RANGE = 20,
    -- m/s : a car moving faster than this can't be used
    MAX_SPEED = 2,
    -- requests a player can make in one second (a press and its release are two)
    MAX_PER_SECOND = 10,
    --- playerName -> true, players who locked their vehicles (kept until the server restarts)
    ---@type table<string, true>
    locked = {},
    --- playerID -> { second, count }
    ---@type table<integer, {second: integer, count: integer}>
    rate = {},
    --- serverVID ("<playerID>-<vehicleID>") -> { advanced coupler group name -> state }, only the
    --- groups that aren't latched (a car spawns with every one latched)
    ---@type table<string, table<string, string>>
    latches = {},
    -- the latch states a client may report, and how many groups (a bus has a lot of doors)
    LATCH_STATES = { detached = true, broken = true },
    MAX_LATCH_GROUPS = 64,

    -- the most cars one resync request may name, and requests a player may make in a second (a
    -- joining player's game asks for every car on the server, in a few batched messages)
    MAX_RESYNC_CARS = 50,
    MAX_RESYNC_PER_SECOND = 5,
    --- playerID -> { second, count }
    ---@type table<integer, {second: integer, count: integer}>
    resyncRate = {},
}

---@param serverVID any "<playerID>-<vehicleID>"
---@return integer? ownerID, integer? vehicleID
local function parseServerVID(serverVID)
    local ownerID, vid = tostring(serverVID or ""):match("^(%d+)%-(%d+)$")
    return tonumber(ownerID), tonumber(vid)
end

--- BeamMP's own copy of a vehicle's position and velocity, or nil when it can't tell us (that check
--- is then skipped rather than blocking a legitimate player)
---@param ownerID integer
---@param vid integer?
---@return {pos: number[], vel: number[]?}?
local function rawPosition(ownerID, vid)
    if not vid or not MP.GetPositionRaw then return nil end
    local ok, raw, err = pcall(MP.GetPositionRaw, ownerID, vid)
    if not ok or err or type(raw) ~= "table" or type(raw.pos) ~= "table" then return nil end
    return raw
end

---@param ctxt BJSContext
---@param key string
---@param vars table?
local function refuse(ctxt, key, vars)
    local text = services_lang.get(key, ctxt.sender.lang)
    if vars then text = text:var(vars) end
    communications_tx.sendToPlayer(ctxt.senderID, "toast", "warning", text)
end

---@param playerID integer
---@return boolean
local function withinRate(playerID)
    local now = GetCurrentTime()
    local r = M.rate[playerID]
    if not r or r.second ~= now then
        M.rate[playerID] = { second = now, count = 1 }
        return true
    end
    r.count = r.count + 1
    return r.count <= M.MAX_PER_SECOND
end

---@param ctxt BJSContext
---@param locked boolean
local function vehicleLocked(ctxt, locked)
    if not ctxt.sender then return end
    M.locked[ctxt.sender.playerName] = locked == true or nil
end

---@param ctxt BJSContext
---@param serverVID string the car
---@param triggerId integer the trigger on it
---@param actionNumber integer 0-2, which of the trigger's actions
---@param value number 1 pressed, 0 released (some triggers take values in between)
---@param ownServerVID string? the requester's own vehicle (their walker, or their car)
local function vehicleTriggerRequest(ctxt, serverVID, triggerId, actionNumber, value, ownServerVID)
    if not ctxt.sender then return end
    triggerId, actionNumber, value = tonumber(triggerId), tonumber(actionNumber), tonumber(value)
    if not triggerId or not actionNumber or actionNumber < 0 or actionNumber > 2 or
        actionNumber % 1 ~= 0 or not value then
        return
    end
    value = math.max(-1, math.min(1, value))
    local press = value ~= 0
    -- a release always goes through : a press that was let through must never stay held
    if press and not withinRate(ctxt.senderID) then return end
    local ownerID, vid = parseServerVID(serverVID)
    if not ownerID or ownerID == ctxt.senderID then return end
    local owner = services_players.players:find(function(p) return p.playerID == ownerID end)
    if not owner then return end

    if press then
        if M.locked[owner.playerName] and not services_crews.sameCrew(ctxt.senderID, ownerID) then
            return refuse(ctxt, "vehicleInteractions.locked", { owner.playerName })
        end
        local car = rawPosition(ownerID, vid)
        if car and type(car.vel) == "table" then
            local vx, vy, vz = tonumber(car.vel[1]) or 0, tonumber(car.vel[2]) or 0, tonumber(car.vel[3]) or 0
            if math.sqrt(vx * vx + vy * vy + vz * vz) > M.MAX_SPEED then
                return refuse(ctxt, "vehicleInteractions.moving")
            end
        end
        local ownOwner, ownVid = parseServerVID(ownServerVID)
        local own = ownOwner == ctxt.senderID and rawPosition(ctxt.senderID, ownVid) or nil
        if car and own then
            local dx, dy, dz = car.pos[1] - own.pos[1], car.pos[2] - own.pos[2], car.pos[3] - own.pos[3]
            if math.sqrt(dx * dx + dy * dy + dz * dz) > M.RANGE then return end
        end
    end

    communications_tx.sendToPlayer(ownerID, "vehicleTrigger", serverVID, triggerId, actionNumber, value,
        ctxt.sender.playerName)
end

---@param serverVID string
---@param latches table<string, string>?
local function setLatches(serverVID, latches)
    M.latches[serverVID] = latches
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "vehicleLatches", serverVID, latches or {})
end

--- an owner's report of one of their cars' unlatched groups (doors, hood, trunk...)
---@param ctxt BJSContext
---@param serverVID string
---@param latches table<string, string>
local function vehicleLatches(ctxt, serverVID, latches)
    if not ctxt.sender then return end
    local ownerID = parseServerVID(serverVID)
    if ownerID ~= ctxt.senderID or type(latches) ~= "table" then return end
    serverVID = tostring(serverVID)
    local clean, count = {}, 0
    for name, state in pairs(latches) do
        if type(name) == "string" and #name <= 64 and M.LATCH_STATES[state] then
            count = count + 1
            if count > M.MAX_LATCH_GROUPS then break end
            clean[name] = state
        end
    end
    setLatches(serverVID, next(clean) and clean or nil)
end

--- a client asking for other players' cars' electrics (they just appeared on its screen) : each
--- car's owner is asked to resend them
---@param ctxt BJSContext
---@param serverVIDs string[]
local function vehicleResyncRequest(ctxt, serverVIDs)
    if not ctxt.sender or type(serverVIDs) ~= "table" then return end
    local now = GetCurrentTime()
    local r = M.resyncRate[ctxt.senderID]
    if not r or r.second ~= now then
        r = { second = now, count = 0 }
        M.resyncRate[ctxt.senderID] = r
    end
    r.count = r.count + 1
    if r.count > M.MAX_RESYNC_PER_SECOND then return end

    ---@type table<integer, string[]>
    local byOwner = {}
    local count = 0
    for _, serverVID in pairs(serverVIDs) do
        count = count + 1
        if count > M.MAX_RESYNC_CARS then break end
        local ownerID = parseServerVID(serverVID)
        -- another player's car, of a player who's here
        if ownerID and ownerID ~= ctxt.senderID and
            services_players.players:find(function(p) return p.playerID == ownerID end) then
            byOwner[ownerID] = byOwner[ownerID] or {}
            table.insert(byOwner[ownerID], string.format("%d-%d", parseServerVID(serverVID)))
        end
    end
    for ownerID, list in pairs(byOwner) do
        communications_tx.sendToPlayer(ownerID, "vehicleResync", list)
    end
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.rate[playerID] = nil
    M.resyncRate[playerID] = nil
    local prefix = tostring(playerID) .. "-"
    for serverVID in pairs(M.latches) do
        if serverVID:sub(1, #prefix) == prefix then setLatches(serverVID, nil) end
    end
end

---@param playerID integer
---@param vehID integer
local function onVehicleDeleted(playerID, vehID)
    local serverVID = string.format("%d-%d", playerID, vehID)
    if M.latches[serverVID] then setLatches(serverVID, nil) end
end

--- a reset (or an edit, which respawns the car) latches every door again on every copy
---@param playerID integer
---@param vehID integer
local function onVehicleReset(playerID, vehID)
    onVehicleDeleted(playerID, vehID)
end

---@param caches table
local function onBJRequestCache(caches)
    caches.vehicleLatches = M.latches
end

local function onInit()
    communications_rx.addHandler("vehicleLocked", vehicleLocked)
    communications_rx.addHandler("vehicleTriggerRequest", vehicleTriggerRequest)
    communications_rx.addHandler("vehicleLatches", vehicleLatches)
    communications_rx.addHandler("vehicleResyncRequest", vehicleResyncRequest)
end

M.onInit = onInit
M.onPlayerDisconnect = onPlayerDisconnect
M.onVehicleDeleted = onVehicleDeleted
M.onVehicleReset = onVehicleReset
M.onBJRequestCache = onBJRequestCache
M.vehicleLatches = vehicleLatches
M.vehicleResyncRequest = vehicleResyncRequest
M.vehicleLocked = vehicleLocked
M.vehicleTriggerRequest = vehicleTriggerRequest

return M
