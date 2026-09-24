--- Freeroam bus-line runner. Client-only, solo, no server round-trip and no rewards / XP (BJS
--- dropped that whole system). Drive a server-defined line (see services/busLines.lua +
--- ui/busLineEditor.lua) stop-to-stop with native GPS guidance; hold briefly inside each stop's
--- radius to advance; the last stop finishes, or loops if the line is `loopable`. Whether stop 1
--- itself counts as a real target depends on how the run started - see beginRun's own comment.
---
--- Entry points (both):
---   - a Big Map POI per line (onBJRequestBigmapPOIs -> bigmap.lua), and
---   - a drive-up "Start line" prompt at each line's first stop (onGetRawPoiListForLevel +
---     onActivityAcceptGatherData), exactly the path beamjoy_stations uses.
---
--- Any bus works - "is a bus" is the game's own test, `Body Style == 'Bus'` (citybus, schoolbus,
--- bus mods). If the player isn't in one, the vehicle selector opens pre-filtered to buses via the
--- onBJRequestCanSpawnVehicle authorization hook, WITHOUT deleting their current vehicle first -
--- see M.startLine's own comment for why that matters.
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
    --- whether the pending line, once a bus is picked, should start counting stop 1 as a real
    --- target - carried alongside pendingLine across the (possibly async) "wait for a bus" gap,
    --- consumed by beginRun. See M.startLine's own comment for why this exists.
    pendingFromActivity = false,

    --- true while ui/freeroamEditor.lua is open (it draws its own line markers) - reuses the
    --- station editor's own onBJStationEditorState hook
    editorOpen = false,

    ---@type table<string, table> POI id -> line, for onActivityAcceptGatherData
    lineById = {},

    lastTargetKey = nil,
    lastLocked = nil,

    --- Other players' currently-running lines, as last reported through the server relay (see
    --- services/busRuns.lua) - playerName -> {lineId, stopIndex}. Used to mirror the destination
    --- sign / next-stop screen onto their vehicles for as long as this client can see them; see the
    --- REMOTE MIRRORING section below.
    ---@type table<string, {lineId: integer, stopIndex: integer}>
    remoteRuns = {},
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

---@return boolean
local function strictStopsEnabled()
    local fr = (beamjoy_config and beamjoy_config.data and beamjoy_config.data.Freeroam) or {}
    return fr.StrictBusStops == true
end

-- STRICT STOPS (doors + kneel) --------------------------------------------------------------

--- Per direct request: an optional server toggle that makes a stop also require the bus's own
--- doors open AND (when the bus actually supports it) kneeling active before it counts as
--- "arrived" - matching how a real, vanilla scripted bus stop actually behaves - instead of
--- proximity alone. GE-Lua has no synchronous way to read a vehicle's own VE-side electrics, so
--- this polls it explicitly: a small VE-side snippet reads them fresh and calls back into GE via
--- `queueGameEngineLua` - the same "call back into GE" pattern `bus.lua`'s own `geCallback` already
--- uses for its gameplay events.
---
--- Real, confirmed bug (direct report, a stock md_series school bus): checking a fixed field name
--- like `electrics.values.dooropen` only works for citybus - its own "bus" controller is what
--- actually computes and publishes that field, by reading a door controller it looks up by the
--- FIXED name "doors". The school/prison/derby bus configs register their doors under different
--- names ("doorsF" per its own jbeam), so the "bus" controller's lookup silently finds nothing and
--- `dooropen` never updates at all. First fix attempt: scan `electrics.values` itself for any key
--- case-insensitively matching "door"+"open" (generic, no fixed key name) - this still DIDN'T fix
--- the school bus, and reading its actual jbeam + the installed game's own
--- `controller/pneumatics/actuators.lua` explains why: the school bus's door input action
--- ("toggle_doors", see its own keyboard inputmap) calls that controller's own
--- `toggleBeamGroupValveState`, which flips `beamGroups[name].valveState` directly - it NEVER
--- writes to `electrics.values` at all. `valveStateElectricsName` (e.g. "frontDoorOpenValve") is
--- only an OPTIONAL external-override input the controller reads, not something it publishes to -
--- so that key sits unused/nil forever during ordinary keyboard-toggle play, and the scan above can
--- never find real data there no matter what pattern it looks for.
---
--- There genuinely is no fixed field name OR fixed group name that works across vehicles here
--- (`getAveragePressure`/`getValveState` both need the exact beam-group name up front, and that
--- name is different per vehicle/mod). What IS available on every "pneumatics/actuators" instance,
--- confirmed by reading the installed game's own `powertrain.lua` doing the exact same thing to
--- read its own private state: `debug.getupvalue` on any of the controller's own exposed functions
--- (`getValveState` here) reaches its `beamGroups` upvalue directly - the controller's real internal
--- state, with no name known in advance. So the fallback below (only runs when the electrics scan
--- above found nothing, i.e. citybus is untouched and still uses the cheap fast path): enumerate
--- every "pneumatics/actuators" controller whose OWN instance name mentions "door" (`controller.
--- getControllersByType`, needs no name either), pull its real group table via that upvalue trick,
--- and look at whichever group's NAME mentions "open" vs "close".
---
--- Real, confirmed bug (direct report): checking the "open" group's `valveState > 0` in isolation
--- worked for the very first stop, then stayed stuck reading "open" for every stop after, even
--- with the door visibly closed again - fixed by comparing the two paired open/close groups
--- directly instead of reading one in isolation (whichever was toggled more recently/dominantly
--- wins). **Direct re-report: the same symptom still persisted after that fix too.** Root cause
--- confirmed via a temporary diagnostic build that logged the raw state to `BeamNG.log` (see
--- CHANGELOG for the full capture and story): `electrics.doorsF_state` (a clean 0/1 flag - not
--- published by `pneumatics/actuators` itself, some other, unidentified but reliable generic
--- mechanism) correlated perfectly with the real door state throughout. The actual bug was the
--- fuzzy "door"+"open" scan matching the WRONG key: `doorsF_frontDoorsOpen_pressure_avg` also
--- contains both substrings, and it's continuous pressure telemetry, not a boolean flag - after the
--- door is first opened, residual pressure in that line lingers at tiny-but-nonzero values for a
--- very long time rather than ever cleanly settling back to exactly 0, and the old `nv>0` check
--- treated any of that residue as "still open" - permanently, from the first open onward. Fixed
--- (confirmed working live) by checking three tiers in order, each only tried if the previous found
--- nothing: (1) any key containing "door" and ending "_state" (a clean flag, this vehicle's own
--- `doorsF_state` and presumably the same convention on others) ; (2) the original fuzzy
--- "door"+"open" scan, now excluding any key that also contains "pressure" (continuous telemetry
--- can't safely answer a boolean "is it open" question at all, on any vehicle) ; (3) the
--- `debug.getupvalue`/`valveState` controller introspection from the previous build, kept as a last
--- resort for a vehicle with neither of the above.
local REQUEST_STOP_STATE_CMD = [[
local dr,dr1,kn,ck=false,false,false,false
for k,v in pairs(electrics.values) do
  local lk=tostring(k):lower()
  local nv=tonumber(v) or 0
  if lk:find('door') and lk:find('_state') and nv>0 then dr1=true end
  if lk:find('kneel') then ck=true if nv>0 then kn=true end end
end
if not dr1 then
  for k,v in pairs(electrics.values) do
    local lk=tostring(k):lower()
    local nv=tonumber(v) or 0
    if lk:find('door') and lk:find('open') and not lk:find('pressure') and nv>0 then dr1=true end
  end
end
dr=dr1
if not dr1 then
  local function upval(fn,name)
    if type(fn)~='function' then return nil end
    local i=1
    while true do
      local n,val=debug.getupvalue(fn,i)
      if not n then return nil end
      if n==name then return val end
      i=i+1
    end
  end
  local ok,ctrls=pcall(controller.getControllersByType,'pneumatics/actuators')
  if ok and type(ctrls)=='table' then
    for _,c in ipairs(ctrls) do
      if c.name and tostring(c.name):lower():find('door') and c.getValveState then
        local groups=upval(c.getValveState,'beamGroups')
        if type(groups)=='table' then
          local openVal,closeVal
          for gname,g in pairs(groups) do
            local lg=tostring(gname):lower()
            if type(g)=='table' then
              local vs=g.valveState or 0
              if lg:find('open') and not lg:find('close') then
                openVal=math.max(openVal or -math.huge,vs)
              elseif lg:find('close') and not lg:find('open') then
                closeVal=math.max(closeVal or -math.huge,vs)
              end
            end
          end
          if openVal then
            if closeVal then
              if openVal>closeVal then dr=true end
            elseif openVal>0 then
              dr=true
            end
          end
        end
      end
    end
  end
end
obj:queueGameEngineLua(string.format("extensions.hook('onBJBusStopElectrics', %s, %s, %s)",
  tostring(dr), tostring(kn), tostring(ck)))
]]

local doorOpen = false
local kneeling = false
local canKneel = false

--- Strict-stops only: what's still missing before an in-radius stop counts as arrived - "kneel",
--- "doors", or "kneelAndDoors" - nil once satisfied, non-strict, or out of radius entirely. Set by
--- onSlowUpdate each tick, read by pushHud() so the HUD can tell the driver what to actually do
--- instead of just staying silent until they happen to get it right.
local pendingRequirement = nil

---@param veh NGVehicle?
local function requestStopState(veh)
    if not veh then return end
    veh:queueLuaCommand(REQUEST_STOP_STATE_CMD)
end

---@param isDoorOpen boolean
---@param isKneeling boolean
---@param kneelCapable boolean
local function onBJBusStopElectrics(isDoorOpen, isKneeling, kneelCapable)
    doorOpen = isDoorOpen == true
    kneeling = isKneeling == true
    canKneel = kneelCapable == true
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
--- Icon: "poi_dealer_1_round" (a car with a roof rack) - the user's own pick, from a rendered
--- gallery of every real candidate (see TODO.md's own writeup for this round). Confirmed (by
--- reading the real icon atlas directly - `gameengine.zip` -> `core/art/gui/images/iconAtlas.json`,
--- the manifest `gameplay/playmodeMarkers.lua`'s `createIconRenderer()` actually loads) : there is
--- NO bus icon in the `poi_*_round` set at all. "poi_bus_round" (a guess) doesn't exist in the
--- atlas, which is why the marker went blank - confirmed root cause, not a guess. "poi_dropoff_round"
--- and "poi_parking_round" (earlier attempts) both exist but read as delivery/cargo and plain
--- parking respectively, per direct reports.
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
                        icon = "poi_dealer_1_round" },
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
                    icon = "poi_dealer_1_round",
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
        -- per direct request : the HUD only ever showed "Stop N / total", never which stop that
        -- actually is by name
        local stop = r.line.stops[r.nextStop]
        local stopName = stop and type(stop.name) == "string" and #stop.name > 0 and stop.name
            or beamjoy_lang.translate("beamjoy.buslines.stop") .. " " .. tostring(r.nextStop)
        beamjoy_communications_ui.send("BJBusHud", {
            active = true,
            lineName = (type(r.line.name) == "string" and #r.line.name > 0) and r.line.name or "",
            stopIndex = r.nextStop,
            totalStops = #r.line.stops,
            stopName = stopName,
            loopable = r.line.loopable == true,
            holding = r.holdUntil ~= nil,
            pending = pendingRequirement,
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
    -- a flat ground disc (a very short, wide cylinder), not a floating glowing sphere - per
    -- direct request for "that clean vanilla look" closer to how native GPS/POI ring markers
    -- read. shape.lua has no dedicated ring/annulus primitive, so this is the simplest available
    -- approximation ; a filled disc, not a hollow ring outline.
    local radius = math.max(1, tonumber(stop.radius) or 3)
    shape.addCylinder(pos - vec3(0, 0, .05), pos + vec3(0, 0, .05), radius, BJColor(1, .85, 0, .35))
end

-- BUS DISPLAYS -------------------------------------------------------------------------

--- Drives BOTH physical bus displays real bus vehicles carry (citybus and likely the
--- md_series-platform school/prison/derby bus configs - same "bus" vlua controller backs all of
--- them), confirmed from the game's own vehicle source (`vehicles/citybus/lua/controller/bus.lua`):
--- the exterior front/side/rear destination sign (`bus_onRouteChange`, an HTML-rendered texture),
--- and the interior next-stop/route screen (`bus_onDepartedStop`, driven off the vehicle's own
--- internal `currentLine.tasklist` waypoint model). Both otherwise just sit on their jbeam-authored
--- defaults forever, which is what a BJS bus run showed until now. `controller.onGameplayEvent`
--- (the vlua-side dispatcher, `lua/vehicle/controller.lua`) broadcasts to every controller module
--- defining a handler for that event name, so all of this is harmless (a silent no-op) on any
--- vehicle without the "bus" controller - no need to gate any of these calls on isBusModelConfig.
---
--- The vehicle's own `currentLine.tasklist` is normally fed by real BeamNG level trigger volumes as
--- a native scripted bus drives past them (`core/busRouteManager.lua`) - BJS's own stop detection
--- is purely proximity-based and never touches a real trigger, so the "trigger" keys used here are
--- synthetic, unique per line/stop, and never compared against anything outside this vehicle's own
--- tasklist.

---@param line table
---@param index integer
---@return string
local function stopKey(line, index)
    return "bjstop_" .. tostring(line.id or "0") .. "_" .. index
end

---@param line table
---@return table[] {key, name, {x,y,z}}[]
local function buildTasklist(line)
    local list = {}
    for i, stop in ipairs(line.stops) do
        list[i] = { stopKey(line, i), stop.name or ("Stop " .. i), { stop.pos.x, stop.pos.y, stop.pos.z } }
    end
    return list
end

---@param line table
---@return string
local function lineDirection(line)
    local last = line.stops[#line.stops]
    return (last and type(last.name) == "string" and #last.name > 0) and last.name or lineLabel(line)
end

---@param veh NGVehicle?
---@param direction string
---@param routeID string
---@param tasklist table[]
local function sendLineInfo(veh, direction, routeID, tasklist)
    if not veh then return end
    -- `bus_setLineInfo` is the vehicle's OWN "load a whole route" entry point - it populates
    -- currentLine.tasklist and auto-fires bus_onRouteChange itself, updating the destination sign
    -- in the same call (see bus.lua's own onGameplayEvent handler). `serialize` (native BeamNG
    -- global, `common/utils.lua`) is what produces a valid re-parseable Lua table-literal string
    -- for queueLuaCommand, rather than hand-building one field by field.
    -- [BJBusDebug] temporary : this RESETS the vehicle's own curWaypoint back to 1 (see bus.lua's
    -- bus_setLineInfo handler, it calls reset() first) - logged so a mid-run reset showing up here
    -- unexpectedly (this should only ever fire once, at run start) is immediately visible against a
    -- real bug report of the interior screen lagging behind the tracked stop.
    LogInfo(string.format("beamjoy_busRun: [BJBusDebug] sendLineInfo (RESET) veh=%s direction=%s tasklist=%d stop(s)",
        tostring(veh:getID()), tostring(direction), #tasklist))
    veh:queueLuaCommand(string.format(
        "if controller.onGameplayEvent then controller.onGameplayEvent('bus_setLineInfo', " ..
        "{direction=%q, routeID=%q, tasklist=%s}) end",
        direction, routeID, serialize(tasklist)))
end

---@param veh NGVehicle?
---@param triggerKey string
local function sendDepartedStop(veh, triggerKey)
    if not veh then return end
    -- [BJBusDebug] temporary : confirms the GE side actually attempted to send this - if the
    -- interior screen still lags behind despite a log line appearing for every real stop, the drop
    -- is happening on the vehicle's own VE side (bus.lua rejecting it), not here.
    LogInfo(string.format("beamjoy_busRun: [BJBusDebug] sendDepartedStop veh=%s key=%s",
        tostring(veh:getID()), triggerKey))
    veh:queueLuaCommand(string.format(
        "if controller.onGameplayEvent then controller.onGameplayEvent('bus_onDepartedStop', " ..
        "{triggerName=%q}) end",
        triggerKey))
end

--- Full (re)apply: sends the whole tasklist, then replays `bus_onDepartedStop` once per
--- already-passed stop, in order, to catch the interior screen up to `stopIndex` (1-based, same
--- convention as busRun.lua's own `nextStop`) instead of leaving it on stop 1. Needed whenever a
--- vehicle is only just being set up - a fresh run start, or this client only just starting to
--- track a remote player's already-in-progress run.
---@param veh NGVehicle?
---@param line table
---@param stopIndex integer
local function applyBusDisplays(veh, line, stopIndex)
    if not veh then return end
    local tasklist = buildTasklist(line)
    sendLineInfo(veh, lineDirection(line), tostring(line.id or ""), tasklist)
    for i = 1, math.min(stopIndex, #tasklist) - 1 do
        sendDepartedStop(veh, tasklist[i][1])
    end
end

--- Incremental version of the above, for a single real advance (one stop further) instead of a
--- full catch-up - avoids resending the whole tasklist (and the door/kneel reset `bus_setLineInfo`
--- triggers via the vehicle's own `reset()`) on every single stop.
---@param veh NGVehicle?
---@param line table
---@param justLeftIndex integer 1-based index of the stop just departed
local function advanceBusDisplays(veh, line, justLeftIndex)
    if not veh then return end
    sendDepartedStop(veh, stopKey(line, justLeftIndex))
end

---@param veh NGVehicle?
local function resetBusDisplays(veh)
    if not veh then return end
    -- matches citybus_signs.jbeam's own out-of-the-box default exactly, same "off duty" state a
    -- real transit sign/screen shows between routes
    veh:queueLuaCommand(
        "if controller.onGameplayEvent then controller.onGameplayEvent('bus_setLineInfo', " ..
        "{direction='Not in Service', routeID='[BUS]', " ..
        "tasklist={{'bjstop_reset', 'Not in Service', {0,0,0}}}}) end")
end

--- Real, confirmed bug (direct report): "if you start a bus line but have to choose a bus, the
--- sign does not apply." queueLuaCommand can be sent before the freshly spawned/replaced vehicle's
--- own vlua VM (and its "bus" controller specifically) has actually finished loading, silently
--- dropping the command - harmless/instant for a vehicle that's been around a while (already
--- driving it, or a long-since-registered remote vehicle), this only bites a just-spawned one.
--- veh:isReady() is the real native signal for "this vehicle has actually finished initializing" -
--- the same API the engine's own vehicle-spawn step helper polls for exactly this reason (see
--- stepHandler.lua's taskVehicleSpawnStep) - so poll that instead of guessing a fixed delay.
---@param veh NGVehicle
---@param stillValid fun(): boolean re-checked after the wait, in case whatever this was for (the
---run, the tracked remote state, ...) moved on while it waited
---@param apply fun()
local function whenVehicleReady(veh, stillValid, apply)
    core_jobsystem.create(function(job)
        local waitedMs = 0
        while not veh:isReady() and waitedMs < 10000 do
            job.sleep(.1)
            waitedMs = waitedMs + 100
        end
        if stillValid() then apply() end
    end)
end

--- Local driver's own vehicle : full (re)apply against the CURRENT M.run.nextStop, gated on the
--- vehicle actually being ready. Used at run start and whenever the running line's own data
--- changes underneath it (an editor save mid-run).
---@param line table
local function updateBusDisplaysForLine(line)
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or not own.veh then return end
    local veh = own.veh
    whenVehicleReady(veh,
        function()
            if not M.run or M.run.line ~= line then return false end
            local stillOwn = beamjoy_vehicles.getCurrentOwn()
            return stillOwn ~= nil and stillOwn.veh == veh
        end,
        function() applyBusDisplays(veh, line, M.run and M.run.nextStop or 1) end)
end

-- REMOTE MIRRORING ---------------------------------------------------------------------

--- Cross-client sync doesn't exist natively in BeamMP for this (a queueLuaCommand only ever
--- executes on the sender's own local copy of a vehicle) - there IS an open, unmerged upstream PR
--- for it (BeamMP/BeamMP#884, a generic "synced controller" mechanism), but depending on it would
--- mean every server needs a non-stock BeamMP build. This relays the driver's own state through
--- BJS's own server instead (see services/busRuns.lua): every other client mirrors the SAME two
--- calls onto their own local copy of that remote vehicle - for a bystander outside it (the sign),
--- and for a passenger riding inside it (BeamMP does support riding along in someone else's
--- vehicle, not just spectating it - the interior screen). Only `bus_onRouteChange` (via
--- `bus_setLineInfo`) and `bus_onDepartedStop` are ever relayed - every other `bus_*` gameplay
--- event this controller defines is either purely internal bookkeeping or a hook for native's own
--- scripted-mission system, with no display/UI output at all, so there's nothing else worth
--- syncing (checked against the actual controller source, not assumed).

---@param playerName string
---@return table? mpVeh
local function findRemoteVehicle(playerName)
    return beamjoy_vehicles.vehicles:find(function(v) return v.ownerName == playerName end)
end

--- Real, confirmed bug (a bystander's own BeamNG.log, not the driver's): applyRemoteRun used to
--- always do a FULL applyBusDisplays (reset + replay every already-passed stop from scratch) on
--- EVERY relayed update, including a routine single-stop advance - the log showed each of those
--- replayed steps rendering its own intermediate frame on the physical screen, so a bystander's
--- display was flickering through the whole route history on every stop instead of taking one
--- clean incremental step like the driver's own client does (advanceBusDisplays). Tracks what's
--- actually been applied to each remote vehicle so a routine +1 advance can use the same lightweight
--- path; anything else (first sighting of this player's run, a different line, a different vehicle
--- instance, or a jump/rewind) still gets the full catch-up apply.
---@type table<string, {lineId: integer, stopIndex: integer, veh: NGVehicle}>
local remoteApplied = {}

---@param playerName string
---@param lineId integer?
---@param stopIndex integer?
local function applyRemoteRun(playerName, lineId, stopIndex)
    local mpVeh = findRemoteVehicle(playerName)
    if not mpVeh or not mpVeh.veh then return end -- not registered on this client yet - onBJVehicleInstantiated below catches it up once it is
    local veh = mpVeh.veh
    local stillValid = function()
        local nowVeh = findRemoteVehicle(playerName)
        return nowVeh ~= nil and nowVeh.veh == veh
    end
    if lineId == nil then
        remoteApplied[playerName] = nil
        whenVehicleReady(veh, stillValid, function() resetBusDisplays(veh) end)
        return
    end
    local line
    for _, l in ipairs(allLines()) do
        if l.id == lineId then
            line = l
            break
        end
    end
    if not line then return end
    stopIndex = stopIndex or 1

    local applied = remoteApplied[playerName]
    if applied and applied.veh == veh and applied.lineId == lineId and applied.stopIndex == stopIndex then
        return -- duplicate of what's already applied, nothing to do
    end
    if applied and applied.veh == veh and applied.lineId == lineId and stopIndex == applied.stopIndex + 1 then
        local justLeftIndex = applied.stopIndex
        remoteApplied[playerName] = { lineId = lineId, stopIndex = stopIndex, veh = veh }
        whenVehicleReady(veh, stillValid, function() advanceBusDisplays(veh, line, justLeftIndex) end)
        return
    end

    remoteApplied[playerName] = { lineId = lineId, stopIndex = stopIndex, veh = veh }
    whenVehicleReady(veh, stillValid, function() applyBusDisplays(veh, line, stopIndex) end)
end

---@param playerName string
---@param lineId integer?
---@param stopIndex integer?
local function onBusRunUpdate(playerName, lineId, stopIndex)
    if playerName == MPConfig.getNickname() then return end -- our own broadcast - already applied locally
    lineId = tonumber(lineId)
    stopIndex = tonumber(stopIndex)
    if lineId == nil then
        M.remoteRuns[playerName] = nil
    else
        M.remoteRuns[playerName] = { lineId = lineId, stopIndex = stopIndex or 1 }
    end
    applyRemoteRun(playerName, lineId, stopIndex)
end

---@param caches table
local function retrieveCache(caches)
    if not caches.activeBusRuns then return end
    local selfName = MPConfig.getNickname()
    for _, run in pairs(caches.activeBusRuns) do
        if run.playerName and run.playerName ~= selfName then
            -- seeded, applied lazily : this early in the join sequence the vehicle almost
            -- certainly isn't registered on this client yet - onBJVehicleInstantiated is what
            -- actually applies it, once that player's vehicle is ready to receive commands
            M.remoteRuns[run.playerName] = { lineId = run.lineId, stopIndex = run.stopIndex }
        end
    end
end

---@param vid integer
local function onBJVehicleInstantiated(vid)
    local mpVeh = beamjoy_vehicles.getVehicle(vid, true)
    if not mpVeh or mpVeh.isLocal or not mpVeh.ownerName then return end
    local run = M.remoteRuns[mpVeh.ownerName]
    if not run then return end
    applyRemoteRun(mpVeh.ownerName, run.lineId, run.stopIndex)
end

-- RUN LIFECYCLE ------------------------------------------------------------------------

--- Whether stop 1 counts as a real target depends on HOW the run started - per direct request,
--- these are genuinely different situations, not one bug with one universal fix:
---   - Drive-up "Start line" prompt (accepted AT stop 1) : the player is already there (that's how
---     they got the prompt at all), so stop 1 is skipped - the first real target is stop 2. Also
---     sidesteps a real reported annoyance : the player is often already stopped right on top of
---     / just past the stop 1 trigger by the time they accept, so the run's own "arrived + held"
---     check could fail to naturally fire there, forcing an awkward, easy-to-miss back-up.
---   - Main window's Activities list / Big Map (`fromActivity` true) : the player did NOT just
---     drive to stop 1 - they could be anywhere on the map - so stop 1 legitimately still needs to
---     be a real, driven-to target, same as every other stop. No teleport either way (a jarring,
---     separately-reported problem with an earlier version of this fix) - the run just starts
---     targeting stop 1 from wherever the player already is.
--- A loopable line always visits stop 1 for real once the loop comes back around regardless.
---@param line table
---@param fromActivity boolean? true when NOT starting from having driven up to stop 1 (Activities
---list / Big Map) - see above. The drive-up prompt never passes this.
local function beginRun(line, fromActivity)
    M.needBus = false
    M.pendingLine = nil
    M.run = { line = line, nextStop = fromActivity and 1 or 2, holdUntil = nil }
    M.lastTargetKey = nil
    pendingRequirement = nil
    refreshPOIs() -- the start POIs stand down while a run is active
    if beamjoy_restrictions then beamjoy_restrictions.update() end
    setTarget()
    pushHud()
    updateBusDisplaysForLine(line)
    beamjoy_communications.send("busRunStarted", line.id, M.run.nextStop)
    toast.info(beamjoy_lang.translate("beamjoy.buslines.play.started"), nil, 4)
end

---@param reason "finish"|"blocked"|"stopped"
local function stopRun(reason)
    if not M.run then return end
    M.run = nil
    M.lastTargetKey = nil
    pendingRequirement = nil
    if extensions.core_groundMarkers then extensions.core_groundMarkers.setPath(nil) end
    shape.reset()
    refreshPOIs()
    if beamjoy_restrictions then beamjoy_restrictions.update() end
    pushHud()
    -- real transit displays go back to "off duty" once the bus comes out of service, not just
    -- freeze on whatever the last run's destination/next-stop happened to be
    local own = beamjoy_vehicles.getCurrentOwn()
    if own then resetBusDisplays(own.veh) end
    beamjoy_communications.send("busRunStopped")
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
    pendingRequirement = nil
    local own = beamjoy_vehicles.getCurrentOwn()
    local veh = own and own.veh
    local justLeftIndex = r.nextStop
    if r.nextStop >= #r.line.stops then
        if r.line.loopable then
            r.nextStop = 1
            setTarget()
            pushHud()
            toast.info(beamjoy_lang.translate("beamjoy.buslines.play.loop"), nil, 3)
            -- curWaypoint can only ever move FORWARD via bus_onDepartedStop (there's no "rewind"
            -- event) - looping back to stop 1 needs the whole tasklist re-sent, same as a fresh
            -- run start, not a single incremental advance
            updateBusDisplaysForLine(r.line)
            beamjoy_communications.send("busRunAdvanced", r.nextStop)
        else
            stopRun("finish") -- already resets the displays and sends busRunStopped
        end
    else
        r.nextStop = r.nextStop + 1
        setTarget()
        pushHud()
        -- [BJBusDebug] temporary : correlates against sendDepartedStop's own log - confirms advance()
        -- itself actually reached this branch and attempted the call, vs. never getting here at all
        LogInfo(string.format(
            "beamjoy_busRun: [BJBusDebug] advance() departing stop %d, veh=%s, new nextStop=%d",
            justLeftIndex, tostring(veh and veh:getID()), r.nextStop))
        advanceBusDisplays(veh, r.line, justLeftIndex)
        beamjoy_communications.send("busRunAdvanced", r.nextStop)
    end
end

--- public : called from the drive-up prompt and the Main window's Activities > Bus Lines browse
--- list (onMainStartBusLine below)
---@param line table
---@param fromActivity boolean? see beginRun's own comment - onMainStartBusLine always passes
---true, the drive-up prompt never passes this
function M.startLine(line, fromActivity)
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
        M.needBus, M.pendingLine, M.pendingFromActivity = false, nil, false
    end

    if locked() then
        toast.warn(beamjoy_lang.translate("beamjoy.buslines.play.blocked"), nil, 4)
        return
    end
    if type(line) ~= "table" or type(line.stops) ~= "table" or #line.stops < 2 then return end

    if currentIsBus() then
        beginRun(line, fromActivity)
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
        async.delayTask(function() M.startLine(line, fromActivity) end, 500, "BJBusModelListWait")
        return
    end

    M.needBus = true
    M.needBusUntil = GetCurrentTimeMillis() + 30000
    M.pendingLine = line
    M.pendingFromActivity = fromActivity == true
    -- world marker / prompt for every line stands down immediately (contributionsSuppressed now
    -- includes M.needBus) - force a POI regen so the floating icon at this stop doesn't linger
    -- stale until some other, unrelated trigger happens to refresh it
    refreshPOIs()
    -- Real, confirmed bug (direct user report): this used to deleteCurrentOwnVehicle() before
    -- opening the filtered selector, copying raceRunner/hunterRunner's own convention - but THOSE
    -- callers immediately spawnNewVehicle()+enterVehicle() themselves in the same tick, with no
    -- gap. Here the player is left with no controlled vehicle for as long as they take to pick one
    -- from the selector, and BeamNG's own engine auto-reassigns `be:getPlayerVehicle(0)` (the
    -- "current" vehicle slot) to some other nearby vehicle the instant theirs disappears -
    -- including a TRAFFIC vehicle. The native selector's own pick logic then routes through
    -- core_vehicles.replaceVehicle "when a vehicle already exists" (see vehicleSelector.lua) -
    -- which by then means replacing whatever random vehicle the engine latched onto, not a fresh
    -- spawn : the reported symptom ("spawns next to that car", or outright replaces/deletes a
    -- traffic vehicle, leaving it undrivable) is exactly that. Fix: don't delete anything here at
    -- all. The player's own current (non-bus) vehicle stays put and stays "current" the whole time
    -- the selector is open, so replaceVehicle always has the right target to swap out regardless
    -- of nearby traffic ; cancelling out of the selector now simply leaves the player in the
    -- vehicle they already had, same as a normal (non-BJS) vehicle-selector cancel. No teleport
    -- happens afterward either (see beginRun's own comment - stop 1 is always skipped as a
    -- target), so nothing here depends on spawn position at all.
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
            local line, fromActivity = M.pendingLine, M.pendingFromActivity
            M.needBus, M.pendingLine, M.pendingFromActivity = false, nil, false
            if not isLocked and line then beginRun(line, fromActivity) end
        elseif isLocked or GetCurrentTimeMillis() >= M.needBusUntil then
            M.needBus, M.pendingLine, M.pendingFromActivity = false, nil, false
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

    local strict = strictStopsEnabled()
    if strict then requestStopState(own.veh) end
    local kneelOK = not canKneel or kneeling -- never required on a bus that can't kneel at all
    local inRadius = dist <= radius
    local arrived = inRadius and (not strict or (doorOpen and kneelOK))

    -- What's still missing, strict mode only, only while actually in range - matches the actual
    -- ask: don't nag about kneeling/doors from halfway across the map, only once it's actionable.
    -- Real, confirmed bug (direct report): the HUD only ever showed anything once BOTH were already
    -- satisfied (the "holding" transition below) - a driver sitting in the circle with the doors
    -- still shut had no indication anything was expected of them at all.
    local newPending = nil
    if strict and inRadius and not arrived then
        if not kneelOK and not doorOpen then newPending = "kneelAndDoors"
        elseif not kneelOK then newPending = "kneel"
        elseif not doorOpen then newPending = "doors"
        end
    end
    if newPending ~= pendingRequirement then
        pendingRequirement = newPending
        pushHud()
    end

    if arrived then
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
            M.startLine(line, true)
            return
        end
    end
end

local function onInit()
    beamjoy_communications_ui.addHandler("BJBusHudRequest", pushHud)
    beamjoy_communications_ui.addHandler("BJBusHudStop", function() stopRun("stopped") end)
    beamjoy_communications_ui.addHandler("BJMainStartBusLine", onMainStartBusLine)
    beamjoy_communications.addHandler("busRunUpdate", M.busRunUpdate)
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
end

local function onBJClientReady()
    refreshPOIs()
end

--- a fresh bus-lines cache landed (an editor save, a map change, ...)
local function onBJBusLinesChanged()
    if M.run then
        -- [BJBusDebug] temporary : this whole branch does a FULL re-apply (updateBusDisplaysForLine
        -- -> applyBusDisplays -> sendLineInfo), which resets the vehicle's own curWaypoint back to 1
        -- before fast-forwarding it again - should only ever be reached from a genuine data change
        -- (an editor save, a map change), never just from driving. If this log shows up mid-run
        -- against a report of the interior screen lagging, an unexpected re-trigger racing a real
        -- advance() (async whenVehicleReady vs. this call's own async re-apply) is a live suspect.
        LogInfo(string.format(
            "beamjoy_busRun: [BJBusDebug] onBJBusLinesChanged fired mid-run (line=%s, nextStop=%s)",
            tostring(M.run.line and M.run.line.id), tostring(M.run.nextStop)))
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
        updateBusDisplaysForLine(found)
        beamjoy_communications.send("busRunAdvanced", M.run.nextStop)
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
M.onBJVehicleInstantiated = onBJVehicleInstantiated
M.onBJBusStopElectrics = onBJBusStopElectrics

M.busRunUpdate = onBusRunUpdate
M.retrieveCache = retrieveCache

M.pushHud = pushHud
M.stopRun = stopRun

return M
