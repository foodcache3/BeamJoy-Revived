--- The server's own millisecond clock, shared with clients (client beamjoy_clockSync estimates it
--- from round-trip pings) so timed moments like a race's green light can be scheduled on one
--- clock every player agrees on, instead of "whenever the message reached them".
--- GetCurrentTime() is whole seconds only, far too coarse for that ; math.timer() (MP.CreateTimer)
--- is a monotonic sub-second stopwatch, the same one environment.lua's ToD math uses.
local M = {}

local clock

--- milliseconds on this server's shared clock (an arbitrary epoch : only differences, and values
--- compared against clients' estimates of this same clock, mean anything)
---@return integer
local function nowMs()
    -- created lazily so MP is guaranteed to exist by the time it's first needed
    clock = clock or math.timer()
    return math.floor(clock:get())
end

---@param ctxt BJSContext
---@param seq integer the client's own ping number, echoed back so it can match the reply
local function clockSync(ctxt, seq)
    if not ctxt.sender then return end
    communications_tx.sendToPlayer(ctxt.senderID, "clockSync", seq, nowMs())
end

local function onInit()
    communications_rx.addHandler("clockSync", clockSync)
end

M.onInit = onInit

M.nowMs = nowMs

return M
