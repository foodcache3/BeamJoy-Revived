--- Estimates the server's own millisecond clock (services_clockSync.nowMs, server-side) so timed
--- moments can be scheduled on one shared clock instead of "whenever the message arrived". Used
--- by races for a shared green light : every player's car unfreezes and their timer starts at
--- the same instant, instead of each one starting whenever the server's RACE push reached them
--- (later for players with more ping, which skewed every split between two players by the
--- difference in their latencies).
---
--- NTP-style : ping the server with the local send time, the server replies with its own clock,
--- and the reply is assumed to have spent half the round trip in each direction. A burst of
--- samples is taken and only the one with the smallest round trip is kept (the least queued, so
--- the least asymmetric). Local time is os.clockhp() (the engine's monotonic high-precision
--- timer) rather than the wall clock, so an OS time adjustment can't shift the estimate.
local M = {
    dependencies = { "beamjoy_communications" },

    ---@type number? serverMs - localMs, from the best sample of the latest burst
    offsetMs = nil,
    ---@type number? round trip of the sample offsetMs came from
    rttMs = nil,
    ---@type number? local ms the current offsetMs was adopted at
    adoptedAtMs = nil,

    ---@type integer pings still to send in the current burst
    burstLeft = 0,
    ---@type {offset: number, rtt: number}[] samples of the current burst
    burstSamples = {},
    ---@type number? local ms the last burst started at
    lastBurstMs = nil,
    ---@type integer last ping number sent
    pingSeq = 0,
    ---@type table<integer, number> ping number -> local ms it was sent at. Kept here rather than
    ---sent on the wire, so only a small integer makes the round trip.
    pingsSent = {},
}

local BURST_SIZE = 8
-- a busy server answers late : the ping waits in its event queue before the reply is stamped, an
-- unknown and one-sided delay that shifts the estimate by half of it. A resync whose best round
-- trip is much worse than the one the current estimate came from was measured under load, so it
-- is ignored rather than adopted (mid-race that would shift this player's times by that error)
local MAX_RTT_FACTOR = 2
local RTT_SLACK_MS = 30
-- unless the current estimate is getting old : a genuinely slower connection (new route, other
-- traffic) must still be adopted eventually, or slow clock drift would never be corrected
local MAX_ESTIMATE_AGE_MS = 15 * 60 * 1000
-- wall clocks and the server's timer drift apart by only a few ms per hour, so this mostly
-- covers a bad first burst (joined during a lag spike) rather than real drift
local RESYNC_INTERVAL_MS = 5 * 60 * 1000

--- local monotonic clock, ms
---@return number
local function localMs()
    return os.clockhp() * 1000
end

---@return boolean
local function isSynced()
    return M.offsetMs ~= nil
end

--- the estimated current server clock, ms. nil until the first sample came back
---@return number?
local function serverNowMs()
    return M.offsetMs and (localMs() + M.offsetMs) or nil
end

local function startBurst()
    M.burstLeft = BURST_SIZE
    M.burstSamples = {}
    M.pingsSent = {} -- a reply that never came back shouldn't linger forever
    M.lastBurstMs = localMs()
end

---@param seq integer
---@param serverMs number
local function onReply(seq, serverMs)
    seq, serverMs = tonumber(seq), tonumber(serverMs)
    local clientSentMs = seq and M.pingsSent[seq]
    if not clientSentMs or not serverMs then return end
    M.pingsSent[seq] = nil
    local now = localMs()
    local rtt = now - clientSentMs
    if rtt < 0 then return end
    table.insert(M.burstSamples, { offset = serverMs + rtt / 2 - now, rtt = rtt })
    -- the best sample of THIS burst replaces the old estimate as soon as it's known, so a burst
    -- also recovers from a bad earlier one (a lag spike at join) instead of only ever improving
    local best
    for _, s in ipairs(M.burstSamples) do
        if not best or s.rtt < best.rtt then best = s end
    end
    local adopt = not M.offsetMs or
        best.rtt <= M.rttMs * MAX_RTT_FACTOR + RTT_SLACK_MS or
        now - M.adoptedAtMs >= MAX_ESTIMATE_AGE_MS
    if adopt then
        M.offsetMs, M.rttMs, M.adoptedAtMs = best.offset, best.rtt, now
    end
end

local function onSlowUpdate()
    if not M.lastBurstMs or localMs() - M.lastBurstMs >= RESYNC_INTERVAL_MS then
        startBurst()
    end
    -- one ping per slow tick (~250ms) rather than all at once, so they don't queue behind each
    -- other and inflate each other's round trips
    if M.burstLeft > 0 then
        M.burstLeft = M.burstLeft - 1
        M.pingSeq = M.pingSeq + 1
        M.pingsSent[M.pingSeq] = localMs()
        beamjoy_communications.send("clockSync", M.pingSeq)
    end
end

local function onInit()
    beamjoy_communications.addHandler("clockSync", onReply)
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate

M.localMs = localMs
M.isSynced = isSynced
M.serverNowMs = serverNowMs

return M
