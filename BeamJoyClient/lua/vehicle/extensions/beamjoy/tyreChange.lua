-- The experimental pit tyre changes (the server's RacePits.ExperimentalTyres), vehicle side : new
-- tyres with the damage kept ("tyres"), or a repair with the old tyres kept ("repair"). Loaded on the
-- player's own car for one stop (beamjoy_pits.serviceCar, GE side, for a pit stop or `/bjtyretest`),
-- unloaded when it's done.
--
-- A reset is the only way the game gives a car fresh tyres or a repair, and it does both. The
-- game's own vehicle save (beamstate.save / load : node positions, beam rest lengths, broken beams)
-- is taken in memory before the reset and put back DURING it : the car's onReset is the first step
-- of the game's reset (vehicle main.lua's onVehicleReset), before beamstate and the latch
-- controllers reset. The shape's commitLoad drops the car's latches (direct report : doors, hood
-- and trunk opened and never caught again when it ran after the reset), so here it runs before
-- they're armed, and the reset arms them the normal way.
-- The reset's beamstate.reset then clears the damage record (dents, breaks, flats) : written again
-- a moment later, only for what the record doesn't hold yet.
--
-- Other players : BeamMP only tells them "this car reset" (their copy turns pristine) and passes on
-- break groups, never dents. The change is kept as a plan (the shape's moved nodes in the car's own
-- axes, mm ; beam lengths ; breaks ; dents), sent through the BeamJoy server, and each other
-- player's copy is reset with the plan put back the same way (armRemote, then their GE's reset).

local M = {}

-- an armed snapshot lasts this long without a reset, then it's dropped
local ARMED_TIMEOUT_S = 5
-- after the reset, the record is written this much later (the break callbacks have landed)
local RECORD_DELAY_S = 0.25
-- nodes the old shape has under this far from the fresh one are left alone
local MOVE_M = 0.005

---@type {mode: string, nodes: table, beams: table, deflated: table, wheelNode: table, dir: vec3, up: vec3}?
local snap = nil
-- another player's copy : the plan received, armed for its reset
local remotePlan = nil
local armedFor = 0
-- after the reset : the record step's countdown, the work's figures, the breaks the record saw
local recordIn = nil
local applied = nil
local applying = false
local brokeLost, brokeSeen = {}, {}
-- the old breaks' callbacks : during the reset step (lost), after it before the record (the game
-- counted them), refired by the record, and after the refire (counted twice)
local refired, refiring = {}, false
local breakStats = { lost = 0, counted = 0, late = 0 }
-- after the record : the car settles this long, its new breaks counted, before the answer
local SETTLE_S = 1
---@type {s: table, shape: table, rec: table, breaks: table, left: number}?
local settling = nil

-- the latch pairs (advancedCouplerControl : doors, hood, trunk), by group : their gap at the
-- snapshot, right after the shape went back, and at the end, and their attach / detach events
---@type table<integer, string> node cid -> group name
local latchNode = {}
local latchEvents = {}
local resetClock = nil

local function latchPairs()
    local pairsOut = {}
    latchNode = {}
    for _, c in ipairs(controller.getControllersByType("advancedCouplerControl")) do
        local data = v.data[c.name]
        if data and data.couplerNodes then
            for _, row in ipairs(tableFromHeaderTable(data.couplerNodes)) do
                local cid2 = type(row.cid2) == "table" and row.cid2[1] or row.cid2
                local a, b = beamstate.nodeNameMap[row.cid1], beamstate.nodeNameMap[cid2]
                if a and b then
                    pairsOut[#pairsOut + 1] = { name = c.name, a = a, b = b }
                    latchNode[a], latchNode[b] = c.name, c.name
                end
            end
        end
    end
    return pairsOut
end

---@return table<string, number> group -> its widest pair's gap (m)
local function latchGaps()
    local gaps = {}
    for _, lp in ipairs(latchPairs()) do
        local d = obj:nodeLength(lp.a, lp.b)
        gaps[lp.name] = math.max(gaps[lp.name] or 0, d)
    end
    return gaps
end

local function latchEvent(nodeId, obj2id, kind, force)
    if not resetClock or obj2id ~= obj:getId() then return end
    local name = latchNode[nodeId]
    if not name then return end
    latchEvents[name] = latchEvents[name] or {}
    local list = latchEvents[name]
    if #list < 6 then
        list[#list + 1] = string.format("%s %.2fs%s", kind, resetClock, force and string.format(" f%.0f", force) or "")
    end
end

-- "own" : the player's own car's change ; "remote" : another player's copy, the plan received
local role = "own"

local function reply(step, err, info)
    obj:queueGameEngineLua(string.format("beamjoy_pits.%s(%d, %q, %q, %q)",
        role == "remote" and "onTyreRemoteStep" or "onTyreStep", obj:getId(), step, err or "", info or ""))
end

-- the plan's sanity bounds (a remote plan comes from another player) : node coordinates (mm, from
-- the ref node), beam lengths (m). A copy collides with this player's car in their own physics, so
-- a node can't go further than a crash bends it from where the copy has it, nor weigh much more
-- than it was built to (a modified game could otherwise send its car as a 30 m, 100 t spike)
local PLAN_MAX_MM = 30000
local PLAN_MAX_REST_M = 30
local PLAN_MAX_MOVE_MM = 5000
local PLAN_MAX_MASS_FACTOR, PLAN_MAX_MASS_ADDED = 2, 200

--- the snapshot, then GE resets the car
---@param mode "tyres"|"repair"
local function prepare(mode)
    local ok, err = pcall(function()
        local wheelNode = {}
        for _, n in pairs(v.data.nodes) do
            if n.wheelID ~= nil then wheelNode[n.cid] = n.wheelID end
        end
        local s = { mode = mode, nodes = {}, beams = {}, deflated = {}, wheelNode = wheelNode,
            dir = vec3(obj:getDirectionVector()), up = vec3(obj:getDirectionVectorUp()) }
        for _, n in pairs(v.data.nodes) do
            local mass = obj:getNodeMass(n.cid)
            s.nodes[n.cid] = { pos = vec3(obj:getNodePosition(n.cid)),
                mass = math.abs(obj:getOriginalNodeMass(n.cid) - mass) > 0.1 and mass or nil }
        end
        -- only the beams the crash touched (the game's own tracker, or broken) : every beam's length
        -- (direct report) broke the hinges and latches
        local tracked = beamstate.deformedBeams or {}
        for _, b in pairs(v.data.beams) do
            local broken = obj:beamIsBroken(b.cid)
            local deform = tracked[b.cid]
            if broken or (deform and deform > 0) then
                s.beams[b.cid] = { rest = obj:getBeamRestLength(b.cid), broken = broken, deform = deform or 0,
                    wheel = wheelNode[b.id1] ~= nil or wheelNode[b.id2] ~= nil }
            end
        end
        for id, wd in pairs(wheels.wheels) do
            if wd.isTireDeflated then s.deflated[id] = true end
        end
        -- the latch groups shut now (doors, hood, trunk), to tell after which ones the change opened
        s.shutBefore = {}
        for _, c in ipairs(controller.getControllersByType("advancedCouplerControl")) do
            if c.getGroupState() == "attached" then s.shutBefore[c.name] = true end
        end
        s.gaps = latchGaps()
        snap = s
        armedFor = ARMED_TIMEOUT_S
    end)
    reply("snapshot", ok and "" or tostring(err))
end

--- the plan from the snapshot, during the reset (the fresh car's shape to compare) : positions are
--- relative to the ref node in world axes, carried over in the car's own axes (the reset can turn
--- it a little). Tyres : the bodywork's nodes and
--- beams, each fresh wheel moved with its axle (node1 / node2) to where the old shape holds it.
--- Repair : the wheels' beams (rest lengths and breaks, not their nodes : the repaired suspension
--- holds them now)
---@param s table
local function buildPlan(s)
    local repair = s.mode == "repair"
    local function axes(dir, up)
        local f = dir:normalized()
        local r = f:cross(up):normalized()
        return r, f, r:cross(f)
    end
    local r0, f0, u0 = axes(s.dir, s.up)
    local r1, f1, u1 = axes(vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp()))
    -- the car's up : each wheel's fit below has an u1 of its own
    local carUp = u1
    local function carried(p) return r1 * p:dot(r0) + f1 * p:dot(f0) + u1 * p:dot(u0) end
    -- the plan, in the car's axes now (local mm), carried back to world axes by applyPlan
    local plan = { mode = s.mode, n = {}, m = {}, b = {}, k = {}, d = {}, f = {} }
    local function put(cid, to)
        local n = plan.n
        n[#n + 1] = cid
        n[#n + 1] = math.floor(to:dot(r1) * 1000 + 0.5)
        n[#n + 1] = math.floor(to:dot(f1) * 1000 + 0.5)
        n[#n + 1] = math.floor(to:dot(carUp) * 1000 + 0.5)
    end
    if not repair then
        -- each fresh wheel follows its axle into the old shape : moved AND turned to the bent axle's
        -- angle (direct report : moved only, its hub tore off the bent suspension, the wheel fell off)
        local fit = {}
        for k, w in pairs(v.data.wheels) do
            local id = w.wheelID ~= nil and w.wheelID or k
            if id ~= nil and w.node1 and w.node2 and s.nodes[w.node1] and s.nodes[w.node2] then
                local a1, b1 = obj:getNodePosition(w.node1), obj:getNodePosition(w.node2)
                local a0, b0 = carried(s.nodes[w.node1].pos), carried(s.nodes[w.node2].pos)
                local u1, u0 = (b1 - a1):normalized(), (b0 - a0):normalized()
                local axis = u1:cross(u0)
                local sin = axis:length()
                local f = { from = (a1 + b1) * 0.5, to = (a0 + b0) * 0.5 }
                if sin > 1e-6 then
                    f.k, f.sin, f.cos = axis * (1 / sin), sin, u1:dot(u0)
                end
                fit[id] = f
            end
        end
        -- Rodrigues : p turned about the unit axis k
        local function fitted(f, p)
            local d = p - f.from
            if f.k then
                d = d * f.cos + f.k:cross(d) * f.sin + f.k * (f.k:dot(d) * (1 - f.cos))
            end
            return f.to + d
        end
        for cid, n in pairs(s.nodes) do
            local wid = s.wheelNode[cid]
            if wid == nil then
                local to = carried(n.pos)
                if (to - obj:getNodePosition(cid)):length() > MOVE_M then put(cid, to) end
                if n.mass then
                    plan.m[#plan.m + 1] = cid
                    plan.m[#plan.m + 1] = n.mass
                end
            elseif fit[wid] then
                local now = obj:getNodePosition(cid)
                local to = fitted(fit[wid], now)
                if (to - now):length() > MOVE_M then put(cid, to) end
            end
        end
    end
    for cid, b in pairs(s.beams) do
        if b.wheel == repair then
            plan.b[#plan.b + 1] = cid
            plan.b[#plan.b + 1] = math.floor(b.rest * 10000 + 0.5)
            if b.broken then
                plan.k[#plan.k + 1] = cid
            elseif b.deform > 0 then
                plan.d[#plan.d + 1] = cid
                plan.d[#plan.d + 1] = math.floor(b.deform * 1000 + 0.5)
            end
        end
    end
    if repair then
        for id in pairs(s.deflated) do plan.f[#plan.f + 1] = id end
    end
    return plan
end

--- a plan's checks : the car's own nodes and beams, bounded figures (a remote plan comes from
--- another player)
---@param plan table
local function checkPlan(plan)
    if type(plan) ~= "table" then error("plan : not a table") end
    if plan.mode ~= "tyres" and plan.mode ~= "repair" then error("plan : bad mode") end
    for _, key in ipairs({ "n", "m", "b", "k", "d", "f" }) do
        if type(plan[key]) ~= "table" then error("plan : no " .. key) end
        for _, x in ipairs(plan[key]) do
            if type(x) ~= "number" or x ~= x then error("plan : bad number in " .. key) end
        end
    end
    local n = plan.n
    if #n % 4 ~= 0 or #plan.m % 2 ~= 0 or #plan.b % 2 ~= 0 or #plan.d % 2 ~= 0 then
        error("plan : bad lengths")
    end
    -- the copy's own axes, as applyPlan puts the plan in
    local f = vec3(obj:getDirectionVector()):normalized()
    local r = f:cross(vec3(obj:getDirectionVectorUp())):normalized()
    local u = r:cross(f)
    for i = 1, #n, 4 do
        if not v.data.nodes[n[i]] then error("plan : unknown node") end
        for j = 1, 3 do
            if math.abs(n[i + j]) > PLAN_MAX_MM then error("plan : node out of bounds") end
        end
        local now = obj:getNodePosition(n[i])
        local dx, dy, dz = n[i + 1] - now:dot(r) * 1000, n[i + 2] - now:dot(f) * 1000, n[i + 3] - now:dot(u) * 1000
        if dx * dx + dy * dy + dz * dz > PLAN_MAX_MOVE_MM * PLAN_MAX_MOVE_MM then error("plan : node moved too far") end
    end
    for i = 1, #plan.m, 2 do
        local cid, mass = plan.m[i], plan.m[i + 1]
        if not v.data.nodes[cid] or mass <= 0 then error("plan : bad mass") end
        local original = obj:getOriginalNodeMass(cid)
        if mass > math.max(original * PLAN_MAX_MASS_FACTOR, original + PLAN_MAX_MASS_ADDED) then
            error("plan : node too heavy")
        end
    end
    for i = 1, #plan.b, 2 do
        local rest = plan.b[i + 1] / 10000
        if not v.data.beams[plan.b[i]] or rest <= 0 or rest > PLAN_MAX_REST_M then error("plan : bad beam") end
    end
    for _, cid in ipairs(plan.k) do
        if not v.data.beams[cid] then error("plan : unknown broken beam") end
    end
    for i = 1, #plan.d, 2 do
        if not v.data.beams[plan.d[i]] then error("plan : unknown dented beam") end
    end
    for _, id in ipairs(plan.f) do
        if not wheels.wheels[id] then error("plan : unknown wheel") end
    end
end

--- the plan put back, physics only (during the reset, before the latches arm), in the car's own
--- axes now
---@param plan table
local function applyPlan(plan)
    local f = vec3(obj:getDirectionVector()):normalized()
    local r = f:cross(vec3(obj:getDirectionVectorUp())):normalized()
    local u = r:cross(f)
    local n = plan.n
    for i = 1, #n, 4 do
        obj:setNodePosition(n[i], r * (n[i + 1] / 1000) + f * (n[i + 2] / 1000) + u * (n[i + 3] / 1000))
    end
    for i = 1, #plan.m, 2 do obj:setNodeMass(plan.m[i], plan.m[i + 1]) end
    brokeLost, brokeSeen = {}, {}
    refired, breakStats = {}, { lost = 0, counted = 0, late = 0 }
    for i = 1, #plan.b, 2 do obj:setBeamLength(plan.b[i], plan.b[i + 1] / 10000) end
    applying = true
    for _, cid in ipairs(plan.k) do obj:breakBeam(cid) end
    applying = false
    if #n > 0 or #plan.b > 0 then obj:commitLoad() end
    return { nodes = #n / 4, beams = #plan.b / 2, broken = #plan.k }
end

--- the damage record the reset cleared, written again : dents, the breaks the record didn't see
--- after its reset (a break's callback during the reset step is wiped with it), and, for a repair,
--- the old punctures
---@param plan table
local function writeRecord(plan)
    local dents, breaks, flats = 0, 0, 0
    for _, cid in ipairs(plan.k) do
        if not brokeSeen[cid] or brokeLost[cid] then
            -- the game's own callback chain (vehicle main.lua) : beamstate, wheels, powertrain,
            -- energy storage, controllers
            refired[cid] = true
            refiring = true
            local ok, err = pcall(onBeamBroke, cid, 0)
            refiring = false
            if not ok then error(err) end
            breaks = breaks + 1
        end
    end
    for i = 1, #plan.d, 2 do
        onBeamDeformed(plan.d[i], plan.d[i + 1] / 1000)
        dents = dents + 1
    end
    for _, id in ipairs(plan.f) do
        if wheels.wheels[id] and not wheels.wheels[id].isTireDeflated then beamstate.deflateTire(id) end
        flats = flats + 1
    end
    return { dents = dents, breaks = breaks, flats = flats }
end

local function onBeamBrokeHook(id)
    if refiring then return end
    if applying then
        breakStats.lost = breakStats.lost + 1
    elseif refired[id] then
        breakStats.late = breakStats.late + 1
    elseif not brokeSeen[id] then
        breakStats.counted = breakStats.counted + 1
    end
    if applying then
        -- during the reset step : beamstate.reset wipes it right after
        brokeLost[id] = true
    end
    brokeSeen[id] = true
    -- a beam the old shape had whole, broken while the car settles after the record : damage the
    -- change itself caused
    if settling and not settling.planBroken[id] then
        settling.breaks[id] = true
    end
end

local function onReset()
    if not snap and not remotePlan then return end
    local s, plan = snap, remotePlan
    snap, remotePlan = nil, nil
    local ok, res = pcall(function()
        plan = plan or buildPlan(s)
        return applyPlan(plan)
    end)
    applying = false
    if not ok then
        return reply("restore", tostring(res))
    end
    applied = { s = s, plan = plan, shape = res, gaps = latchGaps() }
    latchEvents, resetClock = {}, 0
    recordIn = RECORD_DELAY_S
    -- the shape is in : a copy's GE stops waiting to reset it ; the own car's plan goes out now,
    -- not after the record and the settling (direct report : the other players' copies lagged)
    reply("applied")
    if role == "own" then reply("shape", "", jsonEncode(plan)) end
end

local function updateGFX(dt)
    if resetClock then resetClock = resetClock + dt end
    if snap or remotePlan then
        armedFor = armedFor - dt
        if armedFor <= 0 then
            snap, remotePlan = nil, nil
            reply("restore", "no reset came")
        end
    end
    if recordIn then
        recordIn = recordIn - dt
        if recordIn <= 0 then
            recordIn = nil
            local a = applied
            applied = nil
            local ok, rec = pcall(writeRecord, a.plan)
            if not ok then return reply("restore", tostring(rec)) end
            local planBroken = {}
            for _, cid in ipairs(a.plan.k) do planBroken[cid] = true end
            settling = { s = a.s or { shutBefore = {}, gaps = {} }, plan = a.plan, planBroken = planBroken,
                shape = a.shape, gaps = a.gaps, rec = rec, breaks = {}, left = SETTLE_S }
        end
    end
    if settling then
        settling.left = settling.left - dt
        if settling.left <= 0 then
            local st = settling
            settling = nil
            local latched, opened, open = 0, {}, 0
            for _, c in ipairs(controller.getControllersByType("advancedCouplerControl")) do
                if c.getGroupState() == "attached" then
                    latched = latched + 1
                elseif st.s.shutBefore[c.name] then
                    opened[#opened + 1] = c.name
                else
                    open = open + 1
                end
            end
            table.sort(opened)
            -- every latch group that isn't shut now, or wasn't before : gaps (mm) snapshot -> shape
            -- back -> now, and its events since the reset
            local endGaps = latchGaps()
            local latchLines = {}
            for name, g1 in pairs(endGaps) do
                local shutNow = false
                for _, c in ipairs(controller.getControllersByType("advancedCouplerControl")) do
                    if c.name == name then shutNow = c.getGroupState() == "attached" end
                end
                if not shutNow or not st.s.shutBefore[name] then
                    latchLines[#latchLines + 1] = string.format("%s %s->%s gap %.0f/%.0f/%.0f mm [%s]", name,
                        st.s.shutBefore[name] and "shut" or "open", shutNow and "shut" or "open",
                        (st.s.gaps[name] or -1) * 1000, (st.gaps[name] or -1) * 1000, g1 * 1000,
                        table.concat(latchEvents[name] or {}, ", "))
                end
            end
            table.sort(latchLines)
            resetClock = nil
            -- the change's own breaks, by part
            local count, byPart = 0, {}
            for id in pairs(st.breaks) do
                count = count + 1
                local b = v.data.beams[id]
                local part = b and (b.partOrigin or b.partPath) or "?"
                byPart[part] = (byPart[part] or 0) + 1
            end
            local parts = {}
            for part, n in pairs(byPart) do parts[#parts + 1] = string.format("%s %d", part, n) end
            table.sort(parts)
            reply("restore", "", string.format(
                "%d nodes moved, %d beams (%d broken) · record : %d dents, %d breaks, %d flats · latch groups : %d shut, %d open before too, %d opened by the change%s · %d new breaks settling%s · old breaks' callbacks : %d in the reset, %d after it, %d after the refire (twice) · latches : %s",
                st.shape.nodes, st.shape.beams, st.shape.broken, st.rec.dents, st.rec.breaks, st.rec.flats,
                latched, open, #opened, #opened > 0 and (" (" .. table.concat(opened, ", ") .. ")") or "",
                count, count > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "",
                breakStats.lost, breakStats.counted, breakStats.late,
                #latchLines > 0 and table.concat(latchLines, " ; ") or "all as before"))
        end
    end
end

--- another player's copy : the plan their change made (json), armed for the reset their GE does
--- right after the answer
---@param json string
local function armRemote(json)
    role = "remote"
    local ok, err = pcall(function()
        local plan = jsonDecode(json)
        checkPlan(plan)
        remotePlan = plan
        armedFor = ARMED_TIMEOUT_S
    end)
    reply("armed", ok and "" or tostring(err))
end

M.prepare = prepare
M.armRemote = armRemote
M.onReset = onReset
M.onBeamBroke = onBeamBrokeHook
M.updateGFX = updateGFX
M.onCouplerAttached = function(nodeId, obj2id) latchEvent(nodeId, obj2id, "attach") end
M.onCouplerDetached = function(nodeId, obj2id, _, breakForce) latchEvent(nodeId, obj2id, "detach", breakForce) end

return M
