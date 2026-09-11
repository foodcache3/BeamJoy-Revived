--- Freeroam bus-line runner. Client-only, solo, no server round-trip and no rewards / XP (BJS
--- dropped that whole system). Drive a server-defined line (see services/busLines.lua +
--- ui/busLineEditor.lua) stop-to-stop with native GPS guidance; hold briefly inside each stop's
--- radius to advance; the last stop finishes, or loops if the line is `loopable`.
---
--- Entry points (both):
---   - a Big Map POI per line (onBJRequestBigmapPOIs -> bigmap.lua), and
---   - a drive-up "Start line" prompt at each line's first stop (onGetRawPoiListForLevel +
---     onActivityAcceptGatherData), exactly the path beamjoy_stations uses.
---
--- Any bus works - "is a bus" is the game's own test, `Body Style == 'Bus'` (citybus, schoolbus,
--- bus mods). If the player isn't in one, their current vehicle is deleted (matching
--- raceRunner/hunterRunner's own established vehicle-pool steering convention) and the vehicle
--- selector opens pre-filtered to buses via the onBJRequestCanSpawnVehicle authorization hook.
---
--- Known quirk (user-confirmed with five live BeamNG.log repros, including two clean controls),
--- root cause CONFIRMED: a pure native BeamNG engine bug, unrelated to BJS or filtering. Nailed
--- down by wrapping ui_router.navigate to log a stack trace on every call to "menu.vehiclesnew":
--- a SECOND navigate to that same route, fired when the player clicks into a grid item that has
--- its own sub-path (a brand/model folder, or a bus's own config list) - confirmed from the
--- unminified Vue source (ui/ui-vue/src/modules/vehicleselect/views/VehicleSelector.vue's
--- onGridNavigateRequest). Unlike the pause-menu selector, "menu.vehiclesnew" has no CHILD route
--- to drill into (checked its route definition - no `children` table), so that click re-navigates
--- the SAME root route with an updated `path` param instead of going to a separate screen. That
--- second navigate occasionally loses its own race against the router's internal 1-second
--- "routerStart" phase budget (`Transition timeout ... reason: route_navigation_not_started`) and
--- gets force-cancelled by the router itself, which - confirmed by reading router.lua's own
--- cancellation path - never issues any follow-up navigate to fall back to. The player is left
--- exactly where the broken attempt stopped (`RouteScopeValidator` "not found/wrong parent"
--- warnings are just the downstream symptom).
---
--- CONTROL TEST (decisive): `extensions.ui_vehicleSelector_general.openVehicleSelectorForFreeroam()`
--- run directly from BeamNG's own dev console - same route, zero BJS involvement (M.needBus never
--- set, so onBJRequestCanSpawnVehicle never restricts anything) - reproduced the IDENTICAL failure
--- on the same click-into-configs interaction. This rules BJS's own filter-hook cost in/out
--- definitively: it's not the cause. "Only happens the first time" really means "only the first
--- time this specific no-child-route click path gets exercised in the session at all" - which for
--- most players coincides with their first bus-line attempt simply because BJS's freeroam
--- selector opens are likely the only thing that ever targets "menu.vehiclesnew" directly (normal
--- vehicle switching goes through the pause menu's OWN selector, a different route with a real
--- child route, so it never touches this code path).
---
--- ACTUAL FIX: M.startLine opens `pause.vehicleSelector` (via `openFromPause()`) instead of the
--- freeroam `menu.vehiclesnew`. Its own route definition (ui/router/routes/pause.lua) DOES have a
--- real `children` entry ("pause.vehicleSelector.vehicle") for viewing a vehicle's configs, so
--- clicking into one navigates to a genuinely different route instead of re-navigating the same
--- one - the exact condition this whole bug needs to exist. Vehicle filtering is unaffected:
--- `passesFilters`/`onBJRequestCanSpawnVehicle` gate every tile at the grid-selector level
--- regardless of which route opened it, not per-route. This is also the exact route the player's
--- own client already uses for every normal (non-BJS) vehicle change all session - every single
--- one of those, including picks that drilled into a vehicle's configs first, mounted and
--- resolved cleanly in every capture, never once showing this failure. One real, minor UX
--- difference: cancelling without picking a bus lands in the general pause menu (`backTarget =
--- "pause"`) instead of straight back to driving, since that's pause.vehicleSelector's own
--- default exit, unlike the freeroam route's.
---
--- Recovery (M.routeChangeCancelled below) is kept regardless, as a defensive safety net - no
--- failure has ever been observed on pause.vehicleSelector, but there's no proof one never can be,
--- and the mechanism costs nothing when idle. It used to be a blind, timer-based, multi-round
--- retry ; a "don't touch anything" control test exposed a real flaw in that design: it could only
--- check "still on the selector's route", not "actually broken", so it kept forcing needless
--- reopens on a perfectly fine grid the player simply hadn't picked from yet. Replaced with a
--- listener on BeamNG's own `routeChangeCancelled` router hook (ui/router.lua's
--- cancelActiveTransition fires it on every cancelled transition, timeout included) - recovery now
--- only ever fires when the router itself confirms a selector transition actually got cancelled,
--- instantly, instead of guessing at a delay. Ruled out along the way: vehicle-delete/camera
--- timing, subclustering, a duplicate BJS-side open call (onSelectorRoute() still guards
--- M.startLine against that specifically).
---
--- Freeroam only: refuses to start and auto-stops during a Race / Hunter / Infected round, and the
--- POIs disappear then too (locked() guards every contribution hook).

local M = {
    dependencies = { "beamjoy_lang", "beamjoy_busLines", "beamjoy_context", "beamjoy_vehicles" },

    ---@type { line: table, nextStop: integer, holdUntil: integer? }?
    run = nil,

    --- waiting for the player to get into a bus so `pendingLine` can start ; `needBusUntil` is a
    --- hard deadline so a closed-without-picking selector never leaves vehicle spawning stuck on
    --- "buses only" forever
    needBus = false,
    needBusUntil = 0,
    ---@type table?
    pendingLine = nil,

    --- true while ui/freeroamEditor.lua is open (it draws its own line markers) - reuses the
    --- station editor's own onBJStationEditorState hook
    editorOpen = false,

    ---@type table<string, table> POI id -> line, for onActivityAcceptGatherData
    lineById = {},

    lastTargetKey = nil,
    lastLocked = nil,
}

local HOLD_DEFAULT = 3

local function locked()
    return beamjoy_context.isScenarioLocked()
end

---@return integer seconds
local function holdSeconds()
    local fr = (beamjoy_config and beamjoy_config.data and beamjoy_config.data.Freeroam) or {}
    return math.max(0, tonumber(fr.BusStopHoldDuration) or HOLD_DEFAULT)
end

-- BUS DETECTION ----------------------------------------------------------------------------

--- "Body Style" is very often a per-CONFIG field, not a model-level one : `citybus`'s own base
--- info.json declares it directly (every config of it is a bus), but `md_series` (the truck
--- platform behind the schoolbus/prisonbus/derbybus configs) does NOT - only each of THOSE
--- configs' own `info_md_*.json` sidecar sets `"Body Style":"Bus"`. A model-level-only check
--- (`getModel(model).model`) is exactly what native's own `isBus(vehId)` uses too, but that
--- quietly misses every config-level bus like the school bus.
---
--- FIRST attempt at this fix used `getModel(model).configs[config]` as a direct table index -
--- WRONG, confirmed by reading core_vehicles.getConfig's own body: it does NOT index `.configs`
--- by the bare config key at all, it `pairs()`-iterates every entry matching on that entry's own
--- `.key` field. Whatever `.configs` is actually keyed by, a raw `[config]` index into it isn't
--- guaranteed to land on the right entry - so the first fix silently kept resolving to the base
--- model (still missing Body Style for md_series) and nothing actually changed. `getConfig(model,
--- config)` is the real accessor - it's what native's OWN "busRoute" vehicle-selector restriction
--- mode (ui/vehicleSelector/general.lua's vehiclePassesFilters, activeRestrictionMode ==
--- "busRoute" - a real, purpose-built native filter for exactly "buses for a route") resolves a
--- config through, so this now matches that exactly instead of guessing at the table shape.
---
--- Native's own "busRoute" mode additionally requires `Commercial Class == "Transit Bus"`, which
--- would (correctly, by BeamNG's own vehicle data) exclude the school/prison/derby bus configs
--- too (they're `Class 7 Truck`) - deliberately NOT adopted here since the user explicitly asked
--- for "any bus type", broader than native's own transit-route-only definition.
---
--- SECOND bug in this same check, found from live testing : after the getConfig() fix above, only
--- the school bus showed and citybus stopped showing - the exact opposite failure. The fallback
--- here picked the config's WHOLE data table over the model's whenever getConfig() found
--- anything at all, rather than falling back field-by-field. citybus's own default "city" config
--- entry doesn't carry its own "Body Style" (it's just a livery, inheriting that from the base
--- model), so `resolved["Body Style"]` came out nil for it - wrongly excluding citybus, which
--- DOES declare it at the model level. Each md_series bus config's own info_md_*.json happens to
--- be a full standalone blob that repeats "Body Style" itself, so those kept passing, hiding the
--- bug. Native's OWN "busRoute" filter never made this mistake - re-read it again and it's a
--- field-level fallback: `configOrModel['Body Style'] or model['Body Style']`. Matched exactly
--- now instead of an object-level one.
---@param model string?
---@param config string?
---@return boolean
local function isBusModelConfig(model, config)
    if type(model) ~= "string" then return false end
    local md = core_vehicles.getModel(model)
    if not md then return false end
    local resolvedConfig = config and core_vehicles.getConfig(model, config)
    local bodyStyle = (resolvedConfig and resolvedConfig["Body Style"]) or (md.model and md.model["Body Style"])
    return bodyStyle == "Bus"
end

---@return boolean
local function currentIsBus()
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or not own.veh then return false end
    local details = core_vehicles.getVehicleDetails(own.veh:getID())
    local current = details and details.current
    if not current or not current.key then return false end
    -- same real accessor + same field-level fallback as isBusModelConfig, not getVehicleDetails'
    -- own `.configs` field (untrusted for the same reason the first fix's `.configs[key]` index
    -- was: unverified whether its own resolution actually matches getConfig()'s)
    local resolvedConfig = current.config_key and core_vehicles.getConfig(current.key, current.config_key)
    local bodyStyle = (resolvedConfig and resolvedConfig["Body Style"]) or (details.model and details.model["Body Style"])
    return bodyStyle == "Bus"
end

--- true while the vehicle selector's own route is the current UI route. Used to tell "the earlier
--- open attempt is still genuinely showing, don't touch it" apart from "it already ended (however
--- that happened) and a fresh attempt is safe" - see M.startLine's own comment for why this
--- matters more than it sounds like it should.
---@return boolean
local function onSelectorRoute()
    if not extensions.ui_router or not extensions.ui_router.getCurrent then return false end
    local ok, current = pcall(extensions.ui_router.getCurrent)
    local name = ok and current ~= nil and current.request ~= nil and current.request.name
    return name == "pause.vehicleSelector" or name == "pause.vehicleSelector.vehicle"
end

--- Automated version of the player's own proven manual workaround (leave, then retry - always
--- works) - see M.onRouteChangeCancelled below for what actually triggers this now.
local lastRecoverAt = 0
local RECOVER_DEBOUNCE_MS = 500

local function recoverSelector()
    local now = GetCurrentTimeMillis()
    if now - lastRecoverAt < RECOVER_DEBOUNCE_MS then return end -- already reacting to this
    lastRecoverAt = now
    if extensions.ui_router and extensions.ui_router.back then
        extensions.ui_router.back()
    end
    async.delayTask(function()
        if not M.needBus then return end -- resolved while backing out (bus picked, locked, ...)
        if extensions.ui_vehicleSelector_general
            and extensions.ui_vehicleSelector_general.openFromPause then
            extensions.ui_vehicleSelector_general.openFromPause("pause.vehicleSelector")
        end
    end, 250, "BJBusSelectorRecoverReopen")
end

--- BeamNG's own router extension-hooks `Constants.RouterHooks.ROUTE_CHANGE_CANCELLED`
--- ("routeChangeCancelled") from its own `cancelActiveTransition` (ui/router.lua) every time ANY
--- transition gets cancelled, for any reason - including the router's own internal 1-second
--- "routerStart" phase timeout that's the actual, confirmed root cause here (see the top doc
--- comment). `payload.toRoute` is the raw route node being cancelled, `.name` its dotted screenId.
---
--- This REPLACES an earlier fixed-delay polling watchdog (single 1.5s shot, then a bounded
--- multi-round 2.5s-interval version) once a "don't touch anything" control test exposed a real
--- flaw in that approach: `onSelectorRoute()` can only tell "still on the selector's route", not
--- "actually broken" - so it kept firing needless reopens on a perfectly fine grid the player
--- simply hadn't picked from yet within the delay window. Reacting to the router's OWN
--- confirmation that a selector transition specifically got cancelled is precise instead of
--- guessed: it only ever fires when something genuinely broke, and reacts the instant the router
--- itself knows that, rather than waiting out an arbitrary timer. Kept as a defensive safety net
--- even after switching M.startLine to `openFromPause()` (see its own comment) - no failure has
--- ever been observed on this route in any capture, but there's no proof one never can be.
---@param payload table
local function onRouteChangeCancelled(payload)
    if not M.needBus then return end
    local routeName = payload and payload.toRoute and payload.toRoute.name
    if routeName ~= "pause.vehicleSelector" and routeName ~= "pause.vehicleSelector.vehicle" then return end
    recoverSelector()
end

-- DATA -----------------------------------------------------------------------------------

---@return table[]
local function allLines()
    return (beamjoy_busLines.data and beamjoy_busLines.data.lines) or {}
end

---@param line table
---@return string
local function lineKey(line) return "bjBusLine_" .. tostring(line.id) end

---@param line table
---@return string
local function lineLabel(line)
    return (type(line.name) == "string" and #line.name > 0) and line.name
        or beamjoy_lang.translate("beamjoy.buslines.markerLine")
end

-- POI REFRESH --------------------------------------------------------------------------

local function refreshPOIs()
    if bigmap and bigmap.updatePOIs then
        bigmap.updatePOIs() -- also clears gameplay_rawPois + rebuilds the Big Map set
    elseif extensions.gameplay_rawPois then
        extensions.gameplay_rawPois.clear()
    end
end

---@return boolean
local function contributionsSuppressed()
    -- M.needBus included : real, confirmed bug (BeamNG.log capture) - re-showing/re-clicking the
    -- "Start line" prompt while ALREADY waiting on a bus pick let M.startLine below re-enter and
    -- call openVehicleSelectorForFreeroam() a SECOND time while the first was still active. That
    -- second navigate raced the router already sitting on the same route ("menu.vehiclesnew"
    -- transition started again ~2.7s after the first one had already completed, nothing else
    -- logged in between), which is what actually broke the selector's Vue mounting
    -- (RouteScopeValidator "targetScope not found") and made it disappear on the next click.
    return M.run ~= nil or M.needBus or M.editorOpen or locked()
end

-- NATIVE POI CONTRIBUTION -------------------------------------------------------------

--- a startable missionMarker POI at each line's first stop
---@param level string
---@param elements table[]
local function onGetRawPoiListForLevel(level, elements)
    table.clear(M.lineById)
    if contributionsSuppressed() then return end
    local rot = quat(0, 0, 0, 1)
    for _, line in ipairs(allLines()) do
        local s1 = line.stops and line.stops[1]
        if line.id and s1 then
            local id = lineKey(line)
            M.lineById[id] = line
            elements[#elements + 1] = {
                id = id,
                data = { type = "bjBusLineStart", id = id },
                markerInfo = {
                    missionMarker = { pos = vec3(s1.pos.x, s1.pos.y, s1.pos.z), rot = rot,
                        icon = "poi_parking_round" },
                },
            }
        end
    end
end

--- the "Start line" button on the drive-up activity-accept prompt
---@param elemData table[]
---@param activityData table[]
local function onActivityAcceptGatherData(elemData, activityData)
    if contributionsSuppressed() then return end
    for _, elem in ipairs(elemData) do
        if elem.type == "bjBusLineStart" then
            local line = M.lineById[elem.id]
            if line and line.stops and #line.stops >= 2 then
                activityData[#activityData + 1] = {
                    icon = "poi_parking_round",
                    heading = lineLabel(line),
                    preheadings = {
                        beamjoy_lang.translate("beamjoy.buslines.markerLine"),
                        string.format("%d %s", #line.stops,
                            beamjoy_lang.translate("beamjoy.buslines.edit.stops")),
                    },
                    buttonLabel = beamjoy_lang.translate("beamjoy.buslines.play.start"),
                    buttonSoundClass = "bng_hover_generic",
                    sorting = { type = elem.type, id = elem.id },
                    buttonFun = function() M.startLine(line) end,
                }
            end
        end
    end
end

---@param POIS table<string, table>
local function onBJRequestBigmapPOIs(POIS)
    if contributionsSuppressed() then return end
    for _, line in ipairs(allLines()) do
        local s1 = line.stops and line.stops[1]
        if line.id and s1 then
            POIS[lineKey(line)] = {
                name = (type(line.name) == "string" and #line.name > 0) and line.name
                    or "beamjoy.buslines.markerLine",
                description = string.format("%d %s", #line.stops,
                    beamjoy_lang.translate("beamjoy.buslines.edit.stops")),
                icon = "bus",
                groupType = "other",
                -- no native vueBigMap type fits "bus line", so it always also lands in the "Other"
                -- catch-all (see bigmap.lua's own getRawPOIs comment) - but this additionally
                -- surfaces it under its own "Bus Lines" group (bigmap.lua's onBigmapBuildGroupData
                -- + onBigmapBuildCustomGroupStructures), instead of ONLY sitting in "Other".
                customGroupTags = { "bjBusLines" },
                pos = vec3(s1.pos.x, s1.pos.y, s1.pos.z),
            }
        end
    end
end

-- HUD ------------------------------------------------------------------------------------

local function pushHud()
    local r = M.run
    if r then
        beamjoy_communications_ui.send("BJBusHud", {
            active = true,
            lineName = (type(r.line.name) == "string" and #r.line.name > 0) and r.line.name or "",
            stopIndex = r.nextStop,
            totalStops = #r.line.stops,
            loopable = r.line.loopable == true,
            holding = r.holdUntil ~= nil,
        })
    else
        beamjoy_communications_ui.send("BJBusHud", { active = false })
    end
end

-- GPS + TARGET RING -------------------------------------------------------------------

--- (re)point native GPS + draw the target ring, only when the target actually changes
local function setTarget()
    local r = M.run
    if not r then
        if extensions.core_groundMarkers then extensions.core_groundMarkers.setPath(nil) end
        shape.reset()
        M.lastTargetKey = nil
        return
    end
    local stop = r.line.stops[r.nextStop]
    if not stop then return end
    local key = tostring(r.nextStop)
    if key == M.lastTargetKey then return end
    M.lastTargetKey = key
    local pos = vec3(stop.pos.x, stop.pos.y, stop.pos.z)
    if extensions.core_groundMarkers then
        extensions.core_groundMarkers.setPath(pos)
    end
    shape.reset()
    shape.addSphere(pos, math.max(1, tonumber(stop.radius) or 3), BJColor(1, .85, 0, .25))
end

-- RUN LIFECYCLE ------------------------------------------------------------------------

---@param line table
local function beginRun(line)
    M.needBus = false
    M.pendingLine = nil
    M.run = { line = line, nextStop = 1, holdUntil = nil }
    M.lastTargetKey = nil
    refreshPOIs() -- the start POIs stand down while a run is active
    if beamjoy_restrictions then beamjoy_restrictions.update() end
    setTarget()
    pushHud()
    toast.info(beamjoy_lang.translate("beamjoy.buslines.play.started"), nil, 4)
end

---@param reason "finish"|"blocked"|"stopped"
local function stopRun(reason)
    if not M.run then return end
    M.run = nil
    M.lastTargetKey = nil
    if extensions.core_groundMarkers then extensions.core_groundMarkers.setPath(nil) end
    shape.reset()
    refreshPOIs()
    if beamjoy_restrictions then beamjoy_restrictions.update() end
    pushHud()
    local key = ({
        finish = "beamjoy.buslines.play.finished",
        blocked = "beamjoy.buslines.play.blocked",
    })[reason] or "beamjoy.buslines.play.stopped"
    toast.info(beamjoy_lang.translate(key), nil, 4)
end

local function advance()
    local r = M.run
    if not r then return end
    r.holdUntil = nil
    if r.nextStop >= #r.line.stops then
        if r.line.loopable then
            r.nextStop = 1
            setTarget()
            pushHud()
            toast.info(beamjoy_lang.translate("beamjoy.buslines.play.loop"), nil, 3)
        else
            stopRun("finish")
        end
    else
        r.nextStop = r.nextStop + 1
        setTarget()
        pushHud()
    end
end

--- public : called from the Big Map POI, the drive-up prompt, and the Main window's Activities >
--- Bus Lines browse list (onMainStartBusLine below)
---@param line table
function M.startLine(line)
    if M.run then return end

    -- User confirmed (with a live repro) the glitch is NOT about vehicle deletion/camera timing
    -- at all - it's specifically the FIRST time the filtered selector is opened ; retrying (a
    -- second open) reliably works. So this must never fully block a retry, only an ACTUAL double
    -- navigation while the earlier attempt is still genuinely showing. onSelectorRoute() tells
    -- the two apart: if the router is still sitting on the selector's own route, a real, live
    -- attempt is presumably still in progress - leave it alone. If it's moved off that route
    -- (however the earlier attempt ended : picked something, cancelled itself, or the glitch's own
    -- eventual auto-cancel), the stale M.needBus is safe to discard and this call proceeds as a
    -- fresh attempt - which per the user's own report just works.
    if M.needBus then
        if onSelectorRoute() then return end
        M.needBus, M.pendingLine = false, nil
    end

    if locked() then
        toast.warn(beamjoy_lang.translate("beamjoy.buslines.play.blocked"), nil, 4)
        return
    end
    if type(line) ~= "table" or type(line.stops) ~= "table" or #line.stops < 2 then return end

    if currentIsBus() then
        beginRun(line)
        return
    end

    -- Defensive fallback for vehicleSelector.lua's own onBJClientReady prewarm (see its comment
    -- for the full root-cause writeup): that prewarm should always have finished long before the
    -- player can drive to a bus stop, but if it somehow hasn't, opening the filtered selector
    -- right now would deterministically hit the exact cold-load snapshot-drop race it exists to
    -- avoid. Kick the load (safe/no-op if already in flight or already done) and retry shortly
    -- instead of opening into a known-bad window.
    if core_vehicles.isModelsDataLoaded and not core_vehicles.isModelsDataLoaded() then
        if extensions.util_asyncBulkLoader and extensions.util_asyncBulkLoader.loadVehicles then
            pcall(extensions.util_asyncBulkLoader.loadVehicles)
        end
        async.delayTask(function() M.startLine(line) end, 500, "BJBusModelListWait")
        return
    end

    M.needBus = true
    M.needBusUntil = GetCurrentTimeMillis() + 30000
    M.pendingLine = line
    -- world marker / prompt for every line stands down immediately (contributionsSuppressed now
    -- includes M.needBus) - force a POI regen so the floating icon at this stop doesn't linger
    -- stale until some other, unrelated trigger happens to refresh it
    refreshPOIs()
    -- raceRunner/hunterRunner's own identical vehicle-pool steering always
    -- deleteCurrentOwnVehicle() before opening the filtered selector too (a normal tile
    -- pick/double-click routes through core_vehicles.replaceVehicle specifically "when a vehicle
    -- already exists" per vehicleSelector.lua's own comments - a different native path than
    -- picking with nothing there), so this matches that established convention regardless of
    -- whether it turns out to matter for the glitch itself.
    local own = beamjoy_vehicles.getCurrentOwn()
    if own then beamjoy_vehicles.deleteCurrentOwnVehicle() end
    toast.info(beamjoy_lang.translate("beamjoy.buslines.play.pickBus"), nil, 6)
    -- pause.vehicleSelector, not the freeroam menu.vehiclesnew - see the top doc comment. Real
    -- vehicle-picking behavior is identical (passesFilters/onBJRequestCanSpawnVehicle gate every
    -- tile regardless of which route asked), the only user-visible difference is cancelling
    -- without picking lands in the general pause menu instead of straight back to driving.
    if extensions.ui_vehicleSelector_general
        and extensions.ui_vehicleSelector_general.openFromPause then
        extensions.ui_vehicleSelector_general.openFromPause("pause.vehicleSelector")
    end
end

-- TICK ---------------------------------------------------------------------------------

local function onSlowUpdate()
    local isLocked = locked()
    if M.lastLocked ~= nil and isLocked ~= M.lastLocked then
        refreshPOIs()
    end
    M.lastLocked = isLocked

    -- waiting for a bus to start a pending line
    if M.needBus then
        if currentIsBus() then
            local line = M.pendingLine
            M.needBus, M.pendingLine = false, nil
            if not isLocked and line then beginRun(line) end
        elseif isLocked or GetCurrentTimeMillis() >= M.needBusUntil then
            M.needBus, M.pendingLine = false, nil
            -- no beginRun (which itself refreshes) on this path : the window lapsed or the
            -- scenario locked before a bus was ever picked, so the POIs/prompt need to come back
            -- on their own instead of staying suppressed until some unrelated refresh happens by
            refreshPOIs()
        end
        return
    end

    if not M.run then return end
    if isLocked then
        stopRun("blocked")
        return
    end

    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or not own.veh or not currentIsBus() then
        stopRun("stopped")
        return
    end

    local r = M.run
    local stop = r.line.stops[r.nextStop]
    if not stop then
        stopRun("stopped")
        return
    end

    local dist = math.horizontalDistance(own.veh:getPosition(), vec3(stop.pos.x, stop.pos.y, stop.pos.z))
    local radius = math.max(1, tonumber(stop.radius) or 3)
    local now = GetCurrentTimeMillis()

    if dist <= radius then
        if not r.holdUntil then
            r.holdUntil = now + holdSeconds() * 1000
            pushHud()
        elseif now >= r.holdUntil then
            advance()
        end
    elseif r.holdUntil then
        r.holdUntil = nil
        pushHud()
    end
end

-- HOOKS ------------------------------------------------------------------------------

--- keep the bus-filtered vehicle selector honest while we're waiting for the player to pick one
---@param req RequestAuthorization
---@param model string
local function onBJRequestCanSpawnVehicle(req, model, config, action)
    if M.needBus and not isBusModelConfig(model, config) then
        req.state = false
    end
end

---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    if not M.run then return end
    -- blocking switch_next/previous_vehicle also closes the ESC-menu vehicle panel (Repair /
    -- Reset / Clone / Delete), same as race/hunter/infected. toggleWalkingMode stops "get out
    -- and walk away from the bus".
    restrictions:addAll({ "switch_next_vehicle", "switch_previous_vehicle", "toggleWalkingMode" }, true)
end

--- Main window's Activities > Bus Lines browse list : "Start" only ever sends a line id (the
--- Angular side doesn't hold full line objects worth re-validating), so resolve it against the
--- live synced list same as onBJBusLinesChanged already does for a running line.
---@param lineId integer
local function onMainStartBusLine(lineId)
    lineId = tonumber(lineId)
    for _, line in ipairs(allLines()) do
        if line.id == lineId then
            M.startLine(line)
            return
        end
    end
end

local function onInit()
    beamjoy_communications_ui.addHandler("BJBusHudRequest", pushHud)
    beamjoy_communications_ui.addHandler("BJBusHudStop", function() stopRun("stopped") end)
    beamjoy_communications_ui.addHandler("BJMainStartBusLine", onMainStartBusLine)
end

local function onBJClientReady()
    refreshPOIs()
end

--- a fresh bus-lines cache landed (an editor save, a map change, ...)
local function onBJBusLinesChanged()
    if M.run then
        -- re-resolve the running line against the new data by id ; stop if it's gone
        local found
        for _, line in ipairs(allLines()) do
            if line.id == M.run.line.id then found = line end
        end
        if not found or not found.stops or #found.stops < 2 then
            stopRun("stopped")
            return
        end
        M.run.line = found
        if M.run.nextStop > #found.stops then M.run.nextStop = #found.stops end
        M.lastTargetKey = nil
        setTarget()
        pushHud()
    end
    refreshPOIs()
end

local function onBJScenarioChanged()
    if M.run and locked() then
        stopRun("blocked")
        return
    end
    refreshPOIs()
end

---@param active boolean
local function onBJStationEditorState(active)
    M.editorOpen = active == true
    refreshPOIs()
end

M.onInit = onInit
M.onBJClientReady = onBJClientReady
M.onSlowUpdate = onSlowUpdate
M.routeChangeCancelled = onRouteChangeCancelled

M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.onBJRequestBigmapPOIs = onBJRequestBigmapPOIs

M.onBJRequestCanSpawnVehicle = onBJRequestCanSpawnVehicle
M.onBJRequestRestrictions = onBJRequestRestrictions

M.onBJBusLinesChanged = onBJBusLinesChanged
M.onBJScenarioChanged = onBJScenarioChanged
M.onBJStationEditorState = onBJStationEditorState

M.pushHud = pushHud
M.stopRun = stopRun

return M
