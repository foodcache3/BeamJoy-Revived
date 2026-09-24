--- Live relay: WHICH player is currently driving WHICH bus line, and how far along (current stop
--- index) - purely so every other client can mirror the driver's own destination-sign and interior
--- next-stop-screen updates onto their own local copy of that vehicle. Matters for two audiences:
--- a bystander outside the bus (the exterior sign), and a passenger riding inside it (BeamMP does
--- support riding along in someone else's vehicle as a passenger, not just spectating it). Nothing
--- here validates a run against the real line data, or even sees stop positions - same "the
--- driver's own client is the trusted source for its own drive loop" model
--- beamjoy/busRun.lua already established for the local-only case; this module is purely a relay
--- on top of that, for other clients to mirror.
---
--- Deliberately separate from services/busLines.lua, which explicitly owns only the static line
--- DEFINITIONS and never sees an actual run (see its own header comment) - mirrors the
--- hunter.lua / hunterGrid.lua static-vs-live split already established elsewhere in this codebase.

local M = {
    ---@type table<integer, {playerName: string, lineId: integer, stopIndex: integer}> playerID -> current run
    activeRuns = {},
}

---@param caches table
local function onBJRequestCache(caches)
    -- visible to every player, not staff-gated : same reasoning as busLines.lua's own cache (every
    -- client mirrors the display locally)
    caches.activeBusRuns = M.activeRuns
end

---@param ctxt BJSContext
---@param lineId integer
---@param stopIndex integer
local function busRunStarted(ctxt, lineId, stopIndex)
    if not ctxt.sender then return end
    lineId, stopIndex = tonumber(lineId), tonumber(stopIndex)
    if not lineId or not stopIndex then return end
    M.activeRuns[ctxt.senderID] = { playerName = ctxt.sender.playerName, lineId = lineId, stopIndex = stopIndex }
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "busRunUpdate",
        ctxt.sender.playerName, lineId, stopIndex)
end

---@param ctxt BJSContext
---@param stopIndex integer
local function busRunAdvanced(ctxt, stopIndex)
    if not ctxt.sender then return end
    local run = M.activeRuns[ctxt.senderID]
    if not run then return end
    stopIndex = tonumber(stopIndex)
    if not stopIndex then return end
    run.stopIndex = stopIndex
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "busRunUpdate",
        run.playerName, run.lineId, stopIndex)
end

---@param ctxt BJSContext
local function busRunStopped(ctxt)
    if not ctxt.sender then return end
    if not M.activeRuns[ctxt.senderID] then return end
    local playerName = ctxt.sender.playerName
    M.activeRuns[ctxt.senderID] = nil
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "busRunUpdate", playerName, nil, nil)
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    local run = M.activeRuns[playerID]
    if not run then return end
    M.activeRuns[playerID] = nil
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "busRunUpdate", run.playerName, nil, nil)
end

local function onInit()
    communications_rx.addHandler("busRunStarted", M.busRunStarted)
    communications_rx.addHandler("busRunAdvanced", M.busRunAdvanced)
    communications_rx.addHandler("busRunStopped", M.busRunStopped)
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onPlayerDisconnect = onPlayerDisconnect

M.busRunStarted = busRunStarted
M.busRunAdvanced = busRunAdvanced
M.busRunStopped = busRunStopped

return M
