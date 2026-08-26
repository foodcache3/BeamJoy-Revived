--- In-world gate/start markers for races. Used by the test builder (`beamjoy_races.testBuilder`) while
--- building, and the currently-attempted race (`beamjoy_raceRunner.session`) while racing.
---
--- Follows the exact rebuild-on-change pattern already used by
--- `ui/activityEditorSafeZone.lua` (`shape.reset()` + rebuild the whole buffer from current data
--- whenever that data changes) rather than issuing draw calls every frame from here. `shape.lua`
--- already redraws its buffer every frame on its own, so this module's job is only to keep the
--- buffer's *contents* correct, not to re-issue `addX` calls per frame itself (the exact class of
--- per-frame-rebuild mistake flagged earlier in this project's own research on BJI's editor lag).

-- BJColor() is only ever called from inside functions elsewhere in this codebase (never at
-- file-top-level), since it's a "game util" global not guaranteed initialized yet while
-- extensions are still being loaded. Colors are built lazily here for the same reason.
local GATE_COLOR, GATE_NEXT_COLOR, GATE_SELECTED_COLOR, START_COLOR, START_SELECTED_COLOR,
TEXT_COLOR, TEXT_BG_COLOR, PATH_COLOR, HANDLE_COLOR

-- shares the same cached module table `ui/activityEditor.lua` holds in its `editors` list (Lua's
-- `require` caches by resolved path) rather than needing raceEditor registered as its own global
-- extension just to be readable from here
local raceEditor = require("ge/extensions/beamjoy/ui/raceEditor")

local M = {
    dependencies = { "shape", "beamjoy_races", "beamjoy_raceRunner" },

    visible = false,
}

local function onInit()
    GATE_COLOR = BJColor(1, .8, 0, .35)
    GATE_NEXT_COLOR = BJColor(0, 1, 0, .45)
    GATE_SELECTED_COLOR = BJColor(1, 1, 1, .55)
    START_COLOR = BJColor(0, .6, 1, .5)
    START_SELECTED_COLOR = BJColor(1, 1, 1, .7)
    TEXT_COLOR = BJColor(1, 1, 1, .9)
    TEXT_BG_COLOR = BJColor(0, 0, 0, .4)
    PATH_COLOR = BJColor(1, 1, 1, .35)
    HANDLE_COLOR = BJColor(0, 1, 1, .9)
end

--- straight-line path connecting the gates in crossing order. A simple polyline (via shape.lua's
--- existing addLine), not a real curve/spline. The gates already ARE the shape of the route; this
--- is just a visual aid to see the sequence at a glance, not a preview of the actual driving line,
--- so a curve wouldn't add real information.
---@param a BJRaceGate
---@param b BJRaceGate
local function drawPathSegment(a, b)
    shape.addLine(
        vec3(a.pos.x, a.pos.y, a.pos.z + a.height + 1),
        .15,
        vec3(b.pos.x, b.pos.y, b.pos.z + b.height + 1),
        .15,
        PATH_COLOR)
end

---@param gates BJRaceGate[]
---@param loopable boolean? draws an extra closing segment from the last gate back to the first,
---only meaningful in the plain sequential (non-branching) case below. A branching race's own
---loop-closing edge, if any, is just another entry in some gate's own `parents` list, already
---covered by the graph-edge drawing branchingEnabled triggers instead.
---@param branchingEnabled boolean? real, confirmed gap closed here: this used to always draw one
---fixed line per consecutive ARRAY position regardless of the race's actual topology, implying
---gates are crossed in plain array order, which stops being true the instant any gate's `parents`
---diverge from "the previous array position" (the whole point of branching). Draws one line per
---real graph edge instead (gate -> each of its own real, non-"start"/0 parents), reflecting
---whatever the author has actually linked rather than array order.
local function drawPath(gates, loopable, branchingEnabled)
    if branchingEnabled then
        table.forEach(gates, function(g)
            if table.isArray(g.parents) then
                table.forEach(g.parents, function(p)
                    if p > 0 and gates[p] then
                        drawPathSegment(gates[p], g)
                    end
                end)
            end
        end)

        -- A loopable branching race's own real closing segment can never be represented as a
        -- normal `parents` edge above. deriveStepsFromParents only ever resolves a gate to step 1
        -- if it has NO real parent at all, so the real, physical approach leading up to it (e.g. an
        -- imported BJI race's own "finish" gate, reached from a genuine preceding waypoint) has
        -- nowhere to be stored without breaking that resolution. Drawn here instead, generically,
        -- for any loopable branching race: every gate nothing else lists as a real parent (a
        -- genuine dead end of the graph) gets a line straight to every step-1 gate, mirroring the
        -- plain sequential case's own unconditional "last gate -> gate 1" closing segment below.
        if loopable then
            local isParentOf = {}
            table.forEach(gates, function(g)
                table.forEach(g.parents or {}, function(p)
                    if p > 0 then isParentOf[p] = true end
                end)
            end)
            table.forEach(gates, function(g, i)
                if not isParentOf[i] then
                    table.forEach(gates, function(anchor)
                        if anchor.step == 1 and anchor ~= g then
                            drawPathSegment(g, anchor)
                        end
                    end)
                end
            end)
        end
        return
    end

    for i = 2, #gates do
        drawPathSegment(gates[i - 1], gates[i])
    end
    if loopable and #gates > 1 then
        drawPathSegment(gates[#gates], gates[1])
    end
end

---@param race BJRace
---@param index integer 1-based gate index
---@return "startfinish"|"start"|"finish"|nil
---A loopable race's own step-1 gate physically doubles as the finish line too (`drawPath` already
---draws the closing last-gate -> gate-1 segment as real track for exactly this reason, and
---`raceGrid.lua`'s lap-boundary detection matches: a lap completes on *re*-crossing step 1, not on
---reaching the last placed gate). A non-loopable (point-to-point) race has no closing segment, so
---start and finish are two distinct gates instead. Branching-aware: uses each gate's own
---`step`/`isFinish` fields once `race.branchingEnabled` is on (several gates can share step 1 as
---parallel starting alternates, and the array's last element isn't necessarily the real finish
---once a route can fork), otherwise identical to the old plain array-index check
local function gateRole(race, index)
    local total = #race.gates
    if total <= 0 then return nil end
    local gate = race.gates[index]

    if race.branchingEnabled then
        local isStart = gate.step == 1
        if race.loopable then return isStart and "startfinish" or nil end
        local isFinish = gate.isFinish == true
        if isStart and isFinish then return "startfinish" end
        if isStart then return "start" end
        if isFinish then return "finish" end
        return nil
    end

    if index == 1 and index == total then return "startfinish" end
    if race.loopable then return index == 1 and "startfinish" or nil end
    if index == 1 then return "start" end
    if index == total then return "finish" end
    return nil
end

---@param race BJRace
---@param fromIds integer[] node ids (gate indices, or 0 for "start"/nothing crossed yet) to walk
---one step forward from, using the EXACT same reachability rule raceGrid.lua's own
---raceGateCrossed validates a real crossing against: `parents` graph edges, plus the loopable
---"step 1 is always reachable" exception (see that file's own "make step 1 unconditionally
---reachable whenever the race is loopable" comment). Kept in lockstep with that rule specifically
---so a visible/highlighted gate here can never be one the server would actually reject crossing.
---@return integer[] gate indices reachable in exactly one step from any id in fromIds
local function branchingStep(race, fromIds)
    local reachable = {}
    for i, g in ipairs(race.gates) do
        local isLoopClosing = race.loopable and g.step == 1
        if isLoopClosing or table.any(fromIds, function(f) return table.includes(g.parents, f) end) then
            table.insert(reachable, i)
        end
    end
    return reachable
end

---@param expectedIndex integer? the participant's own next gate (1-based). nil disables limiting
---entirely (finished/dnf'd, or the setting is off), and every gate stays visible in that case.
---@param total integer
---@param loopable boolean?
---@param count integer how many upcoming gates (including expectedIndex itself) stay visible
---@return table<integer, true> set of visible 1-based gate indices, or nil if expectedIndex is nil
local function visibleGateSet(expectedIndex, total, loopable, count)
    if not expectedIndex or total <= 0 then return nil end
    local visible = {}
    for i = 0, count - 1 do
        local idx = expectedIndex + i
        if loopable then
            idx = ((idx - 1) % total) + 1
        elseif idx > total then
            break
        end
        visible[idx] = true
    end
    return visible
end

--- branching equivalent of visibleGateSet above : a plain "index + i" walk has no meaning once a
--- route can fork, so this walks the real `parents` graph instead, `count` levels deep via
--- branchingStep, unioning every level. Resolves the old "which branch's next N" ambiguity by
--- simply showing every alternate actually reachable within `count` steps, not picking one
--- arbitrarily : sitting right at a fork shows every branch fanning out from it.
---@param race BJRace
---@param lastCrossedGate integer participant.lastCrossedGate (0 = nothing crossed yet)
---@param count integer how many levels of the branch graph (including the immediate next level)
---stay visible ; same meaning as visibleGateSet's own `count`
---@return table<integer, true> set of visible 1-based gate indices
local function visibleGateSetBranching(race, lastCrossedGate, count)
    local visible = {}
    local frontier = { lastCrossedGate }
    for _ = 1, count do
        local nextFrontier = {}
        for _, i in ipairs(branchingStep(race, frontier)) do
            if not visible[i] then
                visible[i] = true
                table.insert(nextFrontier, i)
            end
        end
        if #nextFrontier == 0 then break end
        frontier = nextFrontier
    end
    return visible
end

---@param race BJRace
---@param index integer 1-based
---@return integer? the sector number (1-based) this gate closes under manual sector boundaries,
---nil if manual sectors are off or this gate isn't a boundary at all. The Nth flagged gate (in
---index order) closes sector N. The final gate always implicitly closes the last sector even if
---not itself flagged (matches raceGrid.lua's own sectorEndGates).
local function sectorNumberForGate(race, index)
    if not race.manualSectors then return nil end
    local gate = race.gates[index]
    local isBoundary = gate and (gate.sector or index == #race.gates)
    if not isBoundary then return nil end
    local n = 0
    for i = 1, index do
        local g = race.gates[i]
        if g.sector or i == #race.gates then n = n + 1 end
    end
    return n
end

---@param gate BJRaceGate
---@param index integer
---@param color table
---@param showDirection boolean? arrow indicating crossing direction, useful while authoring/
---previewing a track, distracting clutter once actually racing (only the editor and test-builder
---render paths pass true; the live-session path during GRID/COUNTDOWN/RACE never does)
---@param role "startfinish"|"start"|"finish"|nil labels the gate as the start/finish line, per
---gateRole() above
---@param showLabel boolean? the floating "Gate N" text above the gate, always true for the
---editor/test-builder (authoring needs the labels regardless of any race setting), gated on the
---live session's own showGateNametags setting for the racing path ; default true
---@param sectorNumber integer? appends "(Sector N)" to the label, per sectorNumberForGate() above
local function drawGate(gate, index, color, showDirection, role, showLabel, sectorNumber)
    local pos = vec3(gate.pos.x, gate.pos.y, gate.pos.z)
    local dir = vec3(gate.dir.x, gate.dir.y, gate.dir.z):normalized()
    local up = vec3(0, 0, 1)
    local right = dir:cross(up)
    local halfWidth = gate.width / 2

    local bottomLeft = pos - right * halfWidth
    local bottomRight = pos + right * halfWidth
    local topRight = bottomRight + up * gate.height
    local topLeft = bottomLeft + up * gate.height

    shape.addQuad(bottomLeft, bottomRight, topRight, topLeft, color)
    if showDirection then
        -- shape.addArrow centers its arrow ON the given pos (base = pos - dir*radius,
        -- tip = pos + dir*radius per the wrapper's own local names) rather than starting there.
        -- Passing the gate's own center directly put the flat quad right in the middle of the
        -- arrow, visually bisecting it. The first attempt at compensating shifted this position
        -- backward (-dir), which a live test showed moved it the WRONG way: the underlying
        -- debugDrawer:drawArrow(base, tip, ...) actually draws the arrowhead at its FIRST point
        -- (this wrapper's "base"), not its second ("tip"), so the wrapper's own local variable
        -- names don't match the native call's actual behavior. Shifting +dir (not -dir) is what
        -- actually lands the pointed/head end on the gate center.
        local arrowRadius = 2
        shape.addArrow(pos + up * (gate.height / 2) + dir * arrowRadius, dir, arrowRadius, color)
    end
    if showLabel ~= false then
        local roleLabel = role == "startfinish" and " (Start/Finish)"
            or role == "start" and " (Start)"
            or role == "finish" and " (Finish)"
            or ""
        local sectorLabel = sectorNumber and string.format(" (Sector %d)", sectorNumber) or ""
        shape.addText(
            string.format("Gate %d%s%s", index, roleLabel, sectorLabel),
            pos + up * (gate.height + .5), TEXT_COLOR, TEXT_BG_COLOR)
    end
end

--- highlights the left/right/top edges of the currently-selected editor gate as thicker,
--- distinctly-colored lines. These are the exact edges `raceEditor.lua`'s handle-drag system
--- hit-tests against, so the outline is what tells the author "these are grabbable", without a
--- real 3D gizmo widget sitting on top of them (per direct request: sliders/handles, not gizmos).
--- Geometry deliberately mirrors `drawGate` above exactly (same non-normalized `right` vector, same
--- corner math) so the highlighted edges line up pixel-for-pixel with the quad they're outlining.
---@param gate BJRaceGate
local function drawGateHandles(gate)
    local pos = vec3(gate.pos.x, gate.pos.y, gate.pos.z)
    local dir = vec3(gate.dir.x, gate.dir.y, gate.dir.z):normalized()
    local up = vec3(0, 0, 1)
    local right = dir:cross(up)
    local halfWidth = gate.width / 2

    local bottomLeft = pos - right * halfWidth
    local bottomRight = pos + right * halfWidth
    local topLeft = bottomLeft + up * gate.height
    local topRight = bottomRight + up * gate.height

    shape.addLine(bottomLeft, .25, topLeft, .25, HANDLE_COLOR)
    shape.addLine(bottomRight, .25, topRight, .25, HANDLE_COLOR)
    shape.addLine(topLeft, .25, topRight, .25, HANDLE_COLOR)
end

---@param startPosition {pos: {x:number,y:number,z:number}, dir: {x:number,y:number,z:number}}
---@param index integer
---@param color table
local function drawStart(startPosition, index, color)
    local pos = vec3(startPosition.pos.x, startPosition.pos.y, startPosition.pos.z)
    local dir = vec3(startPosition.dir.x, startPosition.dir.y, startPosition.dir.z):normalized()
    shape.addSphere(pos, .5, color)
    shape.addArrow(pos + vec3(0, 0, .5), dir, 2, color)
    shape.addText(string.format("Start %d", index), pos + vec3(0, 0, 1.5), TEXT_COLOR, TEXT_BG_COLOR)
end

-- Confirmed real GPU cost: onBJRaceMarkersRefresh fires on every session update, and the server
-- pushes one on every participant's gate crossing, not just the local player's own. For the live
-- session's own render branch below, nothing actually drawn depends on any OTHER participant's
-- progress (their crossings never change this player's own next-gate highlight, visible-gate
-- window, or the pure-spectate case's always-fully-visible gate set). Most of those refreshes were
-- rebuilding the exact same buffer from scratch (up to dozens of addQuad/addText/addArrow calls)
-- for no visual change at all, worse the more nearby participants are actively crossing gates.
-- This signature captures exactly the inputs that actually affect what gets drawn in the
-- live-session branch, so an unchanged signature can skip the whole rebuild. Returns nil for the
-- editor/test-builder branches (their own refresh calls already only fire on a real edit, so
-- always redraw there rather than risk a stale signature masking one).
---@return string?
local function computeRenderSignature()
    if raceEditor.race then return nil end
    local builder = beamjoy_races.testBuilder
    if builder and (#builder.gates > 0 or #builder.startPositions > 0) then return nil end

    local session = beamjoy_raceRunner.session or beamjoy_raceRunner.spectatingSession
    if not session then return "none" end
    local race = table.find(beamjoy_races.data, function(r) return r.id == session.raceId end)
    if not race then return "none" end

    local selfName = MPConfig.getNickname()
    local participant = table.find(session.participants, function(p) return p.playerName == selfName end)
    if not participant then
        -- Pure spectate (or watching a session you're not a participant of): the live-session
        -- branch never highlights a "next gate" or limits visibility without a real participant of
        -- your own, so the drawn gates are identical regardless of anyone else's progress.
        return string.format("spectate:%s:%s", session.id, session.state)
    end
    return string.format("%s:%s:%s:%s:%s:%s", session.id, session.state,
        tostring(participant.lastCrossedGate), tostring(participant.currentGate),
        tostring(participant.finished), tostring(participant.dnf))
end

local lastRenderSignature = nil

local function render()
    local signature = computeRenderSignature()
    if signature and signature == lastRenderSignature then
        return -- nothing that would change the drawn output has actually changed
    end
    lastRenderSignature = signature

    shape.reset()
    local hasContent = false

    if raceEditor.race then
        local race = raceEditor.race
        drawPath(race.gates, race.loopable, race.branchingEnabled)
        table.forEach(race.gates, function(g, i)
            local role = gateRole(race, i)
            local baseColor = role and START_COLOR or GATE_COLOR
            drawGate(g, i, i == raceEditor.activeGateIndex and GATE_SELECTED_COLOR or baseColor, true, role,
                true, sectorNumberForGate(race, i))
            if i == raceEditor.activeGateIndex then drawGateHandles(g) end
        end)
        table.forEach(race.startPositions, function(s, i)
            drawStart(s, i, i == raceEditor.activeStartIndex and START_SELECTED_COLOR or START_COLOR)
        end)
        hasContent = #race.gates > 0 or #race.startPositions > 0
    else
        local builder = beamjoy_races.testBuilder
        if builder and (#builder.gates > 0 or #builder.startPositions > 0) then
            drawPath(builder.gates)
            table.forEach(builder.gates, function(g, i) drawGate(g, i, GATE_COLOR, true) end)
            table.forEach(builder.startPositions, function(s, i) drawStart(s, i, START_COLOR) end)
            hasContent = true
        end

        -- a pure non-participant spectate (raceSpectate, no session/self-participant of your own)
        -- still wants to see the gates being raced through, just without a "self" to highlight the
        -- next gate for
        local session = beamjoy_raceRunner.session or beamjoy_raceRunner.spectatingSession
        if session then
            ---@type BJRace?
            local race = table.find(beamjoy_races.data, function(r) return r.id == session.raceId end)
            if race then
                local selfName = MPConfig.getNickname()
                ---@type BJRaceParticipant?
                local participant = table.find(session.participants, function(p) return p.playerName == selfName end)
                -- The set of gates that would actually complete the next crossing. More than one
                -- entry for a branching race (parallel alternates sharing the last-crossed gate as
                -- a parent), always exactly one for a non-branching race (identical to the old
                -- single `expectedIndex`). nil once finished/dnf, since lastCrossedGate/currentGate
                -- stay at wherever they ended, which would otherwise wrongly re-highlight
                -- something. `expectedIndex` (the plain single-index form) is only ever needed for
                -- visibleGateSet below, moot for a branching race (see visibleGateSetBranching
                -- instead). Kept separate rather than reverse-deriving a single index out of the set.
                local nextGateSet, expectedIndex
                if participant and not participant.finished and not participant.dnf then
                    if race.branchingEnabled then
                        nextGateSet = {}
                        for _, i in ipairs(branchingStep(race, { participant.lastCrossedGate })) do
                            nextGateSet[i] = true
                        end
                    else
                        expectedIndex = (participant.currentGate % #race.gates) + 1
                        nextGateSet = { [expectedIndex] = true }
                    end
                end

                local settings = session.settings or {}
                local showLabel = settings.showGateNametags == true
                -- Per direct request: the lobby (GRID, picking a slot / waiting to ready up)
                -- always shows every gate regardless of limitVisibleGates, so players can see the
                -- whole layout before committing to start. The limit only actually kicks in once
                -- COUNTDOWN/RACE begins. `nextGateSet` doubles as "is there a real current position
                -- to walk from at all" here (set exactly when the guard above would also be true),
                -- avoiding repeating that whole condition a second time.
                local visible = nil
                if settings.limitVisibleGates and session.state ~= "GRID" and nextGateSet then
                    if race.branchingEnabled then
                        visible = visibleGateSetBranching(race, participant.lastCrossedGate,
                            settings.visibleGateCount or 2)
                    else
                        visible = visibleGateSet(expectedIndex, #race.gates, race.loopable,
                            settings.visibleGateCount or 2)
                    end
                end

                table.forEach(race.gates, function(g, i)
                    if visible and not visible[i] then return end
                    local role = gateRole(race, i)
                    local baseColor = role and START_COLOR or GATE_COLOR
                    drawGate(g, i, (nextGateSet and nextGateSet[i]) and GATE_NEXT_COLOR or baseColor, false, role,
                        showLabel, sectorNumberForGate(race, i))
                end)
                -- both the connecting path and start positions only matter during GRID (picking a
                -- slot / waiting to ready up). By COUNTDOWN everyone's already been teleported to
                -- their slot and frozen, so both are just clutter sitting on top of the actual
                -- parked vehicles from that point on, same as once the race is actually running
                if session.state == "GRID" then
                    drawPath(race.gates, race.loopable, race.branchingEnabled)
                    table.forEach(race.startPositions, function(s, i) drawStart(s, i, START_COLOR) end)
                end
                hasContent = true
            end
        end
    end

    M.visible = hasContent
end

local function hide()
    shape.reset()
    M.visible = false
    lastRenderSignature = nil
end

M.onInit = onInit
M.render = render
M.hide = hide

-- refresh hook, fired by beamjoy_races (test builder mutations) and beamjoy_raceRunner (session
-- updates). See the note at the top of this file for why this rebuilds on change, not per frame
M.onBJRaceMarkersRefresh = render

return M
