--- Delivery jobs, client side (Phase 3). Server side : services/deliveries.lua (boards, jobs,
--- scoring) on top of services/deliveryPoints.lua (points, synced here by beamjoy_deliveryPoints).
---
---   - **Depots** are native POIs (missionMarker + drive-up prompt, the same path beamjoy_stations
---     uses) with a "View jobs" button, plus Big Map pins under their own "Delivery depots" group.
---   - **Job board** : a controller-driven window listing the depot's offers (d-pad to browse,
---     X to start solo, B to close ; see beamjoy_uiNav). Closes itself if you drive off.
---   - **The run** : GPS to the drop-off, a ground disc on the zone, a HUD with the timer against
---     the target. Hold inside the zone for Deliveries.HoldDuration seconds and the server checks
---     your position and scores it. The job is tied to the vehicle it started in : switching
---     vehicles, deleting it or teleporting ends the job. Resets become in-place recoveries
---     (beamjoy_recoveryPolicy), and reposition/reload/walking are blocked.
---   - **Ghosting** : any of your own vehicles inside any delivery point's zone is ghosted (reason
---     "delivery"), whatever the collisions mode, so nobody can block a depot or a drop-off.
---   - **Results** : a controller-driven panel with the score breakdown and your total for the
---     cargo type ; A opens the destination's own board when it's a depot too.
---
---   - **Convoys** : A on the board opens a convoy lobby (a HUD panel : A ready, Y start now for
---     the leader, X invite, B leave) ; others join from the depot prompt, the board's "Convoys
---     forming here" or an invite (a panel that expires). Pad buttons : the lobby panel takes them
---     while you're parked at the depot ; an invite, or the lobby while you're away from the depot,
---     only after BJS's own "Focus notification" control focuses it (Controls > BeamJoy ; RB + X
---     on a pad, Shift + J on a keyboard by default), so they never steal shifting (A/X) or
---     anything else mid-drive.
---     When it leaves, every member is brought to the depot (vehicle convoys : their delivery
---     vehicle spawns on their start slot ; package convoys : their own car is moved there) and
---     runs their own job ; the results table fills in as the others deliver.
---   - **Multi-stop** package jobs : 2-3 drop-offs in a row ; each held stop is checked by the
---     server (`deliveryLegArrive`), which answers with the next one (`deliveryLeg`).
---   - **Jobs window** : every depot with distance, open jobs and convoys forming (A GPS, X join,
---     Y filter, B close), plus the two leaderboards. Opened from a depot prompt's "All depots"
---     (pad-driven) or the main window's Activities > Jobs section (a summary + "Open jobs",
---     mouse-driven ; the main window itself stays mouse-driven until its redesign).
---   - **Unstuck** (vehicle jobs) : HUD button that puts the vehicle back on the nearest road,
---     keeping its damage ; only when nearly stopped, with a cooldown.
---   - **Vehicle jobs** : the delivered vehicle replaces your own car at the first free start slot
---     of the depot (convoy member i takes slot i ; you keep it afterwards). Its part conditions are initialised fresh at spawn
---     (freeroam vehicles have none until something does, see the game's vehicle/partCondition.lua)
---     so broken parts can be counted at the drop-off for the condition score. No repairs : the
---     pause-menu repair and garages are refused for the whole job (refuelling stays allowed).
---     The server starts a vehicle job's clock a few seconds late (VEHICLE_SYNC_SEC) so every
---     freshly spawned vehicle has synced to the other players : the vehicle stays frozen and the
---     HUD counts down until then.
---
--- Freeroam only : no job starts during a Race / Hunter / Infected round or a bus run, and a
--- running job ends if one of those locks.

local M = {
    dependencies = { "beamjoy_lang", "beamjoy_deliveryPoints", "beamjoy_context", "beamjoy_vehicles",
        "beamjoy_recoveryPolicy", "beamjoy_uiNav", "beamjoy_inputs" },

    MARKER_ICON = "poi_delivery_round",
    DEFAULT_HOLD = 3,
    -- a board closes once you're this far outside its depot's zone
    BOARD_LEAVE_SLACK = 25,
    -- metres a job vehicle may move between two slow ticks (~250 ms) before it counts as a
    -- teleport rather than driving (about 2000 km/h)
    TELEPORT_JUMP = 150,
    -- how long a spawned delivery vehicle may take to register before the job gives up
    SPAWN_TIMEOUT_MS = 20000,
    -- a start slot counts as taken when any vehicle sits this close to it
    SLOT_CLEARANCE = 3.5,
    -- Unstuck : only below this speed (m/s), and once per cooldown
    UNSTUCK_MAX_SPEED = 2,
    UNSTUCK_COOLDOWN_MS = 30000,
    -- package convoy members without a start slot are placed around the depot this far apart
    CONVOY_SPACING = 6,

    ---@type {depotId: integer, depotName: string, offers: table[]?}?
    board = nil,
    ---@type table? active job, see beginJob
    job = nil,
    ---@type table? last result, while the results panel is open
    result = nil,
    ---@type table[] convoy lobbies forming anywhere (server "deliveryConvoys")
    convoys = {},
    ---@type table? the lobby you're in, see onServerLobby
    lobby = nil,
    ---@type table? pending convoy invite, see onServerInvite
    invite = nil,
    ---@type table<integer, table> convoyId -> latest results table from the server
    convoyResults = {},
    --- Jobs section state : open (mounted), pad (driven by the pad), counts (server, by depot id)
    jobsUi = { open = false, pad = false, counts = nil, lastPush = 0, lastRequest = 0 },
    JOBS_REFRESH_MS = 15000,

    --- true while the Freeroam editor is open (reuses the stations editor's hook)
    editorOpen = false,
    ---@type table<string, BJDeliveryPoint> POI id -> depot
    depotById = {},
    ---@type table<integer, true> own vids currently ghosted for being in a zone
    ghosted = {},
    lastLocked = nil,
}

-- HELPERS ---------------------------------------------------------------------------------------

local function locked()
    return beamjoy_context.isScenarioLocked()
end

---@return integer seconds
local function holdSeconds()
    local d = beamjoy_config and beamjoy_config.data and beamjoy_config.data.Deliveries
    return math.max(0, tonumber(d and d.HoldDuration) or M.DEFAULT_HOLD)
end

---@param p BJDeliveryPoint
---@return boolean
local function sendsPackages(p)
    return type(p.provides) == "table" and table.includes(p.provides, "packages")
end

---@param p BJDeliveryPoint
---@return boolean
local function sendsVehicles(p)
    return type(p.provides) == "table" and table.includes(p.provides, "vehicles") and
        type(p.slots) == "table" and #p.slots > 0
end

---@return BJDeliveryPoint[] depots that currently offer jobs
local function depots()
    local list = {}
    for _, p in ipairs(beamjoy_deliveryPoints.data.points or {}) do
        if p.id and (sendsPackages(p) or sendsVehicles(p)) then list[#list + 1] = p end
    end
    return list
end

---@param pos table {x,y,z}
---@return vec3
local function v3(pos) return vec3(pos.x, pos.y, pos.z) end

---@param a vec3
---@param point table {pos, radius}
---@return number horizontal distance to the zone center
local function distTo(a, point)
    return math.horizontalDistance(a, v3(point.pos))
end

---@param key string
---@return string
local function t(key) return beamjoy_lang.translate(key) end

--- what the HUD / toasts call the cargo : the vehicle's own name, or the package type
---@param kind string
---@param cargo string?
---@param vehicle table?
---@return string
local function cargoTitle(kind, cargo, vehicle)
    if kind == "vehicles" and vehicle then return vehicle.label or vehicle.model end
    return t("beamjoy.delivery.cargo." .. tostring(cargo))
end

local function refreshPOIs()
    if bigmap and bigmap.updatePOIs then
        bigmap.updatePOIs()
    elseif extensions.gameplay_rawPois then
        extensions.gameplay_rawPois.clear()
    end
end

---@return boolean
local function contributionsSuppressed()
    return M.job ~= nil or M.editorOpen or locked()
end

-- NATIVE POI CONTRIBUTION -----------------------------------------------------------------------

---@param level string
---@param elements table[]
local function onGetRawPoiListForLevel(level, elements)
    table.clear(M.depotById)
    if contributionsSuppressed() then return end
    local rot = quat(0, 0, 0, 1)
    for _, depot in ipairs(depots()) do
        local id = "bjDepot_" .. tostring(depot.id)
        M.depotById[id] = depot
        elements[#elements + 1] = {
            id = id,
            -- date : the game sorts overlapping mission markers by data.date (see stations.lua)
            data = { type = "bjDeliveryDepot", id = id, date = 0 },
            markerInfo = {
                missionMarker = { pos = v3(depot.pos), rot = rot, icon = M.MARKER_ICON },
            },
        }
    end
end

--- same per-frame touch-up as beamjoy_stations : the missionMarker's own trigger radius is
--- hardcoded (~1.2 m), so apply the depot's zone radius and drop the ground ring
local function touchUpMarkers()
    local pm = extensions.gameplay_playmodeMarkers
    if not pm or not pm.getPlaymodeClusters or not next(M.depotById) then return end
    local ok, clusters = pcall(pm.getPlaymodeClusters)
    if not ok or type(clusters) ~= "table" then return end
    for _, cluster in ipairs(clusters) do
        if cluster.containedIdsLookup then
            for cid in pairs(cluster.containedIdsLookup) do
                local depot = M.depotById[cid]
                if depot then
                    local marker = pm.getMarkerForCluster(cluster)
                    if marker then
                        marker.radius = math.max(1, tonumber(depot.radius) or 8)
                        if marker.groundDecalData then marker.groundDecalData = nil end
                    end
                    break
                end
            end
        end
    end
end

---@param elemData table[]
---@param activityData table[]
local function onActivityAcceptGatherData(elemData, activityData)
    if contributionsSuppressed() then return end
    for _, elem in ipairs(elemData) do
        if elem.type == "bjDeliveryDepot" then
            local depot = M.depotById[elem.id]
            if depot then
                activityData[#activityData + 1] = {
                    icon = M.MARKER_ICON,
                    heading = depot.name,
                    preheadings = { t("beamjoy.delivery.depot") },
                    buttonLabel = t("beamjoy.delivery.viewJobs"),
                    buttonSoundClass = "bng_hover_generic",
                    sorting = { type = elem.type, id = elem.id },
                    buttonFun = function() M.openBoard(depot.id) end,
                }
                activityData[#activityData + 1] = {
                    icon = M.MARKER_ICON,
                    heading = depot.name,
                    preheadings = { t("beamjoy.delivery.jobs.promptSub") },
                    buttonLabel = t("beamjoy.delivery.jobs.allDepots"),
                    buttonSoundClass = "bng_hover_generic",
                    sorting = { type = elem.type, id = elem.id .. "_zall" },
                    buttonFun = function() M.openJobs() end,
                }
                for _, c in ipairs(M.convoys) do
                    if c.depotId == depot.id and c.count < c.max and not M.lobby then
                        activityData[#activityData + 1] = {
                            icon = M.MARKER_ICON,
                            heading = depot.name,
                            preheadings = { string.var(t("beamjoy.delivery.convoy.forming"),
                                { cargoTitle(c.kind, c.cargo, c.vehicle), c.destName, c.count, c.max }) },
                            buttonLabel = string.var(t("beamjoy.delivery.convoy.joinNamed"), { c.leaderName }),
                            buttonSoundClass = "bng_hover_generic",
                            sorting = { type = elem.type, id = elem.id .. "_c" .. tostring(c.id) },
                            buttonFun = function() M.joinConvoy(c.id) end,
                        }
                    end
                end
            end
        end
    end
end

---@param POIS table<string, table>
local function onBJRequestBigmapPOIs(POIS)
    if M.editorOpen or locked() then return end
    for _, depot in ipairs(depots()) do
        POIS["bjDepot_" .. tostring(depot.id)] = {
            name = depot.name,
            description = t("beamjoy.delivery.depot"),
            icon = "deliveryTruck",
            mapIcon = M.MARKER_ICON,
            groupType = "other",
            customGroupTags = { "bjDeliveryDepots" },
            pos = v3(depot.pos),
        }
    end
end

-- JOB BOARD -------------------------------------------------------------------------------------

local function pushBoard()
    local b = M.board
    if not b then
        beamjoy_communications_ui.send("BJDeliveryBoard", { open = false })
        return
    end
    beamjoy_communications_ui.send("BJDeliveryBoard", {
        open = true,
        depotId = b.depotId,
        depotName = b.depotName,
        loading = b.offers == nil,
        offers = b.offers or {},
        convoys = b.convoys or {},
    })
end

---@param notifyServer boolean?
local function closeBoard(notifyServer)
    if not M.board then return end
    M.board = nil
    beamjoy_uiNav.release("deliveryBoard")
    if notifyServer ~= false then beamjoy_communications.send("deliveryBoardClose") end
    pushBoard()
end

---@param depotId integer
function M.openBoard(depotId)
    local depot = beamjoy_deliveryPoints.getPoint(tonumber(depotId))
    if not depot or M.job or M.lobby then return end
    if locked() then
        toast.warn(t("beamjoy.delivery.blocked"), nil, 4)
        return
    end
    M.board = { depotId = depot.id, depotName = depot.name, offers = nil }
    beamjoy_uiNav.acquire("deliveryBoard")
    beamjoy_communications.send("deliveryBoardOpen", depot.id)
    pushBoard()
end

---@param data table {depotId, depotName, offers}
local function onServerBoard(data)
    if not M.board or type(data) ~= "table" or data.depotId ~= M.board.depotId then return end
    M.board.depotName = data.depotName or M.board.depotName
    M.board.offers = table.isArray(data.offers) and data.offers or {}
    M.board.convoys = table.isArray(data.convoys) and data.convoys or {}
    pushBoard()
end

--- the own vehicle a job can start from, or nil (with a toast saying why)
---@return BJVehicle?
local function startVehicle()
    if M.job then return nil end
    if locked() or (beamjoy_busRun and beamjoy_busRun.run) then
        toast.warn(t("beamjoy.delivery.blocked"), nil, 4)
        return nil
    end
    local own = beamjoy_vehicles.getCurrentOwn()
    if not own or own.isAi or own.jbeam == beamjoy_vehicles.WALKING then
        toast.warn(t("beamjoy.delivery.needVehicle"), nil, 4)
        return nil
    end
    return own
end

---@param offerId integer
local function onStartSolo(offerId)
    if not M.board then return end
    local own = startVehicle()
    if own then beamjoy_communications.send("deliveryStart", tonumber(offerId), own.serverVID) end
end

---@param offerId integer
local function onStartConvoy(offerId)
    if not M.board then return end
    local own = startVehicle()
    if own then beamjoy_communications.send("deliveryConvoyCreate", tonumber(offerId), own.serverVID) end
end

---@param convoyId integer
function M.joinConvoy(convoyId)
    if M.lobby then return end
    local own = startVehicle()
    if own then beamjoy_communications.send("deliveryConvoyJoin", tonumber(convoyId), own.serverVID) end
end

---@param reason string
local function onStartRefused(reason)
    toast.warn(t("beamjoy.delivery.refused." .. tostring(reason)), nil, 5)
end

-- THE RUN ---------------------------------------------------------------------------------------

local function pushHud()
    local j = M.job
    if not j then
        beamjoy_communications_ui.send("BJDeliveryHud", { active = false })
        return
    end
    local now = GetCurrentTimeMillis()
    local elapsed = (now - j.startMs) / 1000
    local unstuck
    if j.kind == "vehicles" and elapsed >= 0 then
        local cooldown = j.unstuckReadyAt and math.ceil((j.unstuckReadyAt - now) / 1000) or 0
        if cooldown > 0 then
            unstuck = { state = "cooldown", seconds = cooldown }
        elseif (j.speed or 0) > M.UNSTUCK_MAX_SPEED then
            unstuck = { state = "moving" }
        else
            unstuck = { state = "ready" }
        end
    end
    local convoy
    if j.convoy then
        convoy = {
            size = j.convoy.size,
            firstName = j.convoy.firstName,
            graceLeft = j.convoy.graceEndsAtMs and math.max(0, math.ceil((j.convoy.graceEndsAtMs - now) / 1000)) or nil,
        }
    end
    beamjoy_communications_ui.send("BJDeliveryHud", {
        active = true,
        kind = j.kind,
        title = cargoTitle(j.kind, j.cargo, j.vehicle),
        toName = j.to.name,
        distance = j.distance,
        elapsedSec = math.max(0, math.floor(elapsed)),
        startsIn = elapsed < 0 and math.ceil(-elapsed) or nil,
        targetSec = j.targetSec,
        deadlineSec = j.deadlineSec,
        holding = j.holdUntil ~= nil,
        confirming = j.arriving == true,
        unstuck = unstuck,
        convoy = convoy,
        stop = j.stops and j.leg or nil,
        stopCount = j.stops and #j.stops or nil,
    })
end

--- GPS + a flat disc on the drop-off zone (same look as bus stops)
local function drawTarget()
    local j = M.job
    shape.reset()
    if extensions.core_groundMarkers then
        extensions.core_groundMarkers.setPath(j and v3(j.to.pos) or nil)
    end
    if not j then return end
    local pos = v3(j.to.pos)
    local radius = math.max(1, tonumber(j.to.radius) or 8)
    shape.addCylinder(pos - vec3(0, 0, .05), pos + vec3(0, 0, .05), radius, BJColor(1, .45, 0, .35))
end

--- the first start slot with no vehicle parked on it (any slot if all are taken : the spawn is
--- ghosted by the depot zone / respawn protection anyway)
---@param slots table[]
---@return table?
local function freeSlot(slots)
    if type(slots) ~= "table" or #slots == 0 then return nil end
    local vehs = getAllVehicles and getAllVehicles() or {}
    for _, slot in ipairs(slots) do
        local pos = v3(slot.pos)
        local taken = false
        for _, veh in ipairs(vehs) do
            if veh:getPosition():distance(pos) < M.SLOT_CLEARANCE then
                taken = true
                break
            end
        end
        if not taken then return slot end
    end
    return slots[1]
end

--- replaces the player's own car with the delivery vehicle at a free start slot
---@param j table the job
---@return boolean spawned
local function spawnDeliveryVehicle(j)
    local slots = j.from and j.from.slots
    -- convoy member i takes start slot i (the server caps a vehicle convoy at the slot count)
    local slot = j.convoy and type(slots) == "table" and slots[j.convoy.slot] or freeSlot(slots)
    if not slot or not j.vehicle then return false end
    local pos = v3(slot.pos)
    local dir = vec3(slot.dir.x, slot.dir.y, 0)
    if dir:length() < 1e-4 then dir = vec3(1, 0, 0) end
    dir = dir:normalized()
    if beamjoy_vehicles.getCurrentOwn() then beamjoy_vehicles.deleteCurrentOwnVehicle() end
    local newVeh = core_vehicles.spawnNewVehicle(j.vehicle.model, {
        pos = pos,
        -- spawn.spawnVehicle turns the rotation 180 degrees itself, so no dir * -1 here
        -- (unlike setVehiclePositionRotation's raw setPosRot)
        rot = quatFromDir(dir, vec3(0, 0, 1)),
        config = j.vehicle.config,
    })
    if not newVeh then return false end
    be:enterVehicle(0, newVeh)
    if camera.getCamera() == camera.CAMERAS.FREE then camera.toggleFreeCam() end
    -- fresh conditions (odometer 0, intact, clean), so broken parts can be counted at the drop-off
    newVeh:queueLuaCommand("if partCondition and not partCondition.getConditions() then " ..
        "partCondition.initConditions(nil, 0, 1, 1) end")
    j.vid = newVeh:getID()
    j.spawnDeadline = GetCurrentTimeMillis() + M.SPAWN_TIMEOUT_MS
    return true
end

--- package convoys : the member's own car is moved to the depot as the convoy leaves (start slot
--- i when the depot has one, else spread around its center) ; skipped when already inside
---@param j table the job
local function bringToDepot(j)
    local own = beamjoy_vehicles.getCurrentOwn()
    local from = j.from
    if not own or not from or not from.pos then return end
    if distTo(own.veh:getPosition(), from) <= (tonumber(from.radius) or 8) then return end
    local i = j.convoy.slot or 1
    local slot = type(from.slots) == "table" and from.slots[i]
    local pos, dir
    if slot then
        pos = v3(slot.pos)
        dir = vec3(slot.dir.x, slot.dir.y, 0)
    else
        local s = M.CONVOY_SPACING
        pos = v3(from.pos) + vec3(((i - 1) % 2) * s - s / 2, math.floor((i - 1) / 2) * s - s / 2, 0)
    end
    if dir and dir:length() > 1e-4 then dir = dir:normalized() else dir = nil end
    beamjoy_vehicles.setVehiclePositionRotation(own.veh, pos, dir, dir and vec3(0, 0, 1) or nil)
    if camera.getCamera() == camera.CAMERAS.FREE then camera.toggleFreeCam() end
    j.jumpGraceUntil = GetCurrentTimeMillis() + 3000
end

---@param payload table from services/deliveries.lua jobPayload
local function beginJob(payload)
    if type(payload) ~= "table" or type(payload.to) ~= "table" then return end
    closeBoard(false)
    M.closeLobby()
    local own = beamjoy_vehicles.getCurrentOwn()
    M.job = {
        kind = payload.kind,
        cargo = payload.cargo,
        vehicle = payload.vehicle,
        meters = payload.meters,
        targetSec = payload.targetSec,
        deadlineSec = payload.deadlineSec,
        startMs = GetCurrentTimeMillis() - (tonumber(payload.elapsedSec) or 0) * 1000,
        from = payload.from,
        to = payload.to,
        vid = own and own.vid,
        serverVID = own and own.serverVID,
        lastPos = own and own.veh:getPosition() or nil,
        distance = nil,
        holdUntil = nil,
        arriving = false,
        stops = table.isArray(payload.stops) and #payload.stops > 1 and payload.stops or nil,
        leg = tonumber(payload.leg) or 1,
        convoy = type(payload.convoy) == "table" and {
            id = payload.convoy.id,
            size = tonumber(payload.convoy.size) or 1,
            slot = tonumber(payload.convoy.slot) or 1,
            graceEndsAtMs = payload.convoy.graceEndsIn and
                GetCurrentTimeMillis() + payload.convoy.graceEndsIn * 1000 or nil,
        } or nil,
    }
    local j = M.job
    if j.kind == "vehicles" and not payload.resumed then
        j.vid, j.serverVID, j.lastPos = nil, nil, nil
        if not spawnDeliveryVehicle(j) then
            M.job = nil
            beamjoy_communications.send("deliveryAbandon", "spawnFailed")
            toast.error(t("beamjoy.delivery.ended.spawnFailed"), nil, 6)
            return
        end
    end
    if j.kind ~= "vehicles" and j.convoy and not payload.resumed then bringToDepot(j) end
    -- resets become in-place recoveries (no teleporting ahead) ; a package job still allows
    -- repairs (damage doesn't count there), a vehicle job doesn't
    beamjoy_recoveryPolicy.claim("delivery", { blockRepair = j.kind == "vehicles" })
    if beamjoy_restrictions then beamjoy_restrictions.update() end
    refreshPOIs()
    drawTarget()
    pushHud()
    if not payload.resumed then
        toast.info(string.var(t("beamjoy.delivery.started"), { payload.to.name }), nil, 5)
    end
end

---@param data table {firstName, graceEndsIn}
local function onConvoyGrace(data)
    local j = M.job
    if not j or not j.convoy or type(data) ~= "table" then return end
    j.convoy.firstName = data.firstName
    j.convoy.graceEndsAtMs = GetCurrentTimeMillis() + (tonumber(data.graceEndsIn) or 0) * 1000
    toast.info(string.var(t("beamjoy.delivery.convoy.graceStarted"),
        { data.firstName, beamjoy_lang.formatTime and beamjoy_lang.formatTime(data.graceEndsIn) or
            string.format("%d:%02d", math.floor((data.graceEndsIn or 0) / 60), (data.graceEndsIn or 0) % 60) }), nil, 6)
    pushHud()
end

--- Unstuck (vehicle jobs) : back onto the nearest road the vehicle recently drove on, keeping
--- its damage. The pause menu's own "recover to road" call, unwrapped (the recovery claim denies
--- RECOVER_LAST_ROAD everywhere else) ; resetVehicle false, so nothing is repaired.
local function onUnstuck()
    local j = M.job
    if not j or j.kind ~= "vehicles" or j.spawnDeadline or j.arriving then return end
    local now = GetCurrentTimeMillis()
    if now < j.startMs then return end
    if j.unstuckReadyAt and now < j.unstuckReadyAt then return end
    if (j.speed or 0) > M.UNSTUCK_MAX_SPEED then
        toast.warn(t("beamjoy.delivery.hud.unstuckMoving"), nil, 3)
        return
    end
    local jobVeh = j.vid and beamjoy_vehicles.getVehicle(j.vid, true)
    if not jobVeh or not jobVeh.veh then return end
    local base = beamjoy_inputs.baseFunctions and beamjoy_inputs.baseFunctions.extensions.spawn
    local teleport = base and base.teleportToLastRoad
    if not teleport then return end
    teleport(jobVeh.veh, { resetVehicle = false })
    j.unstuckReadyAt = now + M.UNSTUCK_COOLDOWN_MS
    -- the jump can be long : skip the teleport check until it has landed
    j.jumpGraceUntil = now + 3000
    j.holdUntil = nil
    pushHud()
end

--- local teardown ; the server already knows (it ended the job, or we're telling it)
local function clearJob()
    local j = M.job
    if not j then return end
    if j.syncFrozen and j.vid then beamjoy_vehicles.setFreeze(j.vid, false) end
    M.job = nil
    beamjoy_recoveryPolicy.release("delivery")
    if beamjoy_restrictions then beamjoy_restrictions.update() end
    if extensions.core_groundMarkers then extensions.core_groundMarkers.setPath(nil) end
    shape.reset()
    refreshPOIs()
    pushHud()
end

--- ends the job from this side (vehicle changed, teleported, scenario lock, player abandoned)
---@param reason string
local function abandonJob(reason)
    if not M.job then return end
    beamjoy_communications.send("deliveryAbandon")
    clearJob()
    toast.warn(t("beamjoy.delivery.ended." .. reason), nil, 6)
end

---@param reason string from the server : abandoned|timedOut|pointRemoved|mapChanged
local function onServerEnded(reason)
    if not M.job then return end
    clearJob()
    if reason ~= "abandoned" then
        toast.warn(t("beamjoy.delivery.ended." .. tostring(reason)), nil, 6)
    end
end

--- multi-stop : the server accepted a stop ; drive on to the next one
---@param data table {leg, doneName, to}
local function onServerLeg(data)
    local j = M.job
    if not j or type(data) ~= "table" or type(data.to) ~= "table" then return end
    j.leg = tonumber(data.leg) or j.leg + 1
    j.to = data.to
    j.arriving = false
    j.holdUntil = nil
    j.distance = nil
    drawTarget()
    toast.success(string.var(t("beamjoy.delivery.stopDone"),
        { data.doneName or "?", j.leg - 1, #j.stops, data.to.name }), nil, 5)
    pushHud()
end

local function onArriveRefused()
    if not M.job then return end
    M.job.arriving = false
    M.job.condDeadline = nil
    M.job.holdUntil = nil
    toast.warn(t("beamjoy.delivery.arriveRefused"), nil, 5)
    pushHud()
end

-- RESULTS ---------------------------------------------------------------------------------------

local function pushResults()
    if not M.result then
        beamjoy_communications_ui.send("BJDeliveryResults", { open = false })
        return
    end
    local r = table.clone(M.result)
    r.open = true
    beamjoy_communications_ui.send("BJDeliveryResults", r)
end

---@param payload table
local function onServerResult(payload)
    clearJob()
    if type(payload) ~= "table" then return end
    M.result = payload
    local convoyId = type(payload.convoy) == "table" and payload.convoy.id
    if convoyId and M.convoyResults[convoyId] then payload.convoyTable = M.convoyResults[convoyId] end
    beamjoy_uiNav.acquire("deliveryResults")
    pushResults()
end

--- the convoy's results table, re-sent every time a member delivers, fails or leaves
---@param data table {convoyId, size, targetSec, graceSec, rows}
local function onConvoyResults(data)
    if type(data) ~= "table" or not data.convoyId then return end
    local selfName = MPConfig and MPConfig.getNickname and MPConfig.getNickname()
    for _, row in ipairs(table.isArray(data.rows) and data.rows or {}) do
        row.you = row.name == selfName
    end
    M.convoyResults[data.convoyId] = data
    if M.result and type(M.result.convoy) == "table" and M.result.convoy.id == data.convoyId then
        M.result.convoyTable = data
        pushResults()
    end
end

local function closeResults()
    if not M.result then return end
    M.result = nil
    beamjoy_uiNav.release("deliveryResults")
    pushResults()
end
M.closeResults = closeResults

local function onResultsNext()
    local r = M.result
    closeResults()
    if r and r.toIsDepot and r.toId then M.openBoard(r.toId) end
end

-- CONVOY LOBBY ----------------------------------------------------------------------------------

---@return boolean own vehicle inside the lobby's depot zone (plus the board's slack)
local function atLobbyDepot()
    local l = M.lobby
    if not l or not l.depotPos then return false end
    local own = beamjoy_vehicles.getCurrentOwn()
    return own ~= nil and distTo(own.veh:getPosition(), { pos = l.depotPos }) <=
        (tonumber(l.depotRadius) or 8) + M.BOARD_LEAVE_SLACK
end

local function pushLobby()
    local l = M.lobby
    if not l then
        beamjoy_communications_ui.send("BJDeliveryLobby", { open = false })
        return
    end
    local payload = table.clone(l)
    payload.open = true
    payload.title = cargoTitle(l.kind, l.cargo, l.vehicle)
    payload.startsIn = math.max(0, math.ceil((l.startsAtMs - GetCurrentTimeMillis()) / 1000))
    payload.atDepot = l.atDepot == true
    payload.padActive = l.padActive == true
    payload.focusable = false
    payload.inviting = l.inviting == true
    payload.invitees = l.invitees or {}
    payload.startsAtMs = nil
    beamjoy_communications_ui.send("BJDeliveryLobby", payload)
end

--- the convoy lobby lives in the main window (Activities > Jobs). Arriving at the depot brings the
--- main window up there with the pad (beamjoy/mainNav.lua autoFocus) ; away from it, the Focus
--- notification control opens the same place.
local function updateLobbyPad()
    local l = M.lobby
    local want = l ~= nil and l.atDepot == true and M.result == nil
    if l then l.padActive = false end
    if beamjoy_mainNav then beamjoy_mainNav.autoFocus("lobby", want, "play", "jobs") end
end

---@param at boolean
local function setLobbyAtDepot(at)
    local l = M.lobby
    if not l then return end
    l.atDepot = at
    -- arriving hands the pad over anyway ; leaving drops a focus taken at the depot
    l.focused = nil
end

--- local teardown only (the server already dropped us, or is about to start the job)
function M.closeLobby()
    if not M.lobby then return end
    M.lobby = nil
    if beamjoy_mainNav then beamjoy_mainNav.autoFocus("lobby", false) end
    refreshPOIs()
    pushLobby()
end

---@param data table see services/deliveries.lua sendLobbyTo
local function onServerLobby(data)
    if type(data) ~= "table" then return end
    local wasOpen = M.lobby ~= nil
    local keep = M.lobby and M.lobby.id == data.id and M.lobby or {}
    M.lobby = data
    M.lobby.startsAtMs = GetCurrentTimeMillis() + (tonumber(data.startsIn) or 0) * 1000
    M.lobby.inviting = keep.inviting
    M.lobby.invitees = keep.invitees
    M.lobby.focused = keep.focused
    M.lobby.atDepot = keep.atDepot
    if M.lobby.atDepot == nil then setLobbyAtDepot(atLobbyDepot()) end
    if not wasOpen then
        closeBoard()
        -- the lobby replaces an open results panel
        if M.result then
            M.result = nil
            beamjoy_uiNav.release("deliveryResults")
            pushResults()
        end
        refreshPOIs()
    end
    updateLobbyPad()
    pushLobby()
end

---@param reason string left|disbanded|notAtDepot|pointRemoved|mapChanged
local function onServerLobbyClosed(reason)
    if not M.lobby then return end
    M.closeLobby()
    if reason ~= "left" then
        toast.warn(t("beamjoy.delivery.convoy.closed." .. tostring(reason)), nil, 6)
    end
end

---@param list table[]
local function onServerConvoys(list)
    M.convoys = table.isArray(list) and list or {}
    if M.jobsUi.open then M.pushJobs() end
end

---@param list table[] {playerID, name, busy, invited}
local function onServerInviteList(list)
    if not M.lobby then return end
    M.lobby.invitees = table.isArray(list) and list or {}
    pushLobby()
end

---@param ready boolean
local function onLobbyReady(ready)
    if not M.lobby then return end
    local own = beamjoy_vehicles.getCurrentOwn()
    beamjoy_communications.send("deliveryConvoyReady", ready == true, own and own.serverVID or nil)
end

---@param open boolean
local function onLobbyInviting(open)
    if not M.lobby then return end
    M.lobby.inviting = open == true
    if M.lobby.inviting then
        M.lobby.invitees = nil
        beamjoy_communications.send("deliveryConvoyInviteList")
    end
    pushLobby()
end

local function tickLobby()
    local l = M.lobby
    if not l then return end
    if locked() then
        beamjoy_communications.send("deliveryConvoyLeave")
        M.closeLobby()
        return
    end
    local at = atLobbyDepot()
    if at ~= l.atDepot then setLobbyAtDepot(at) end
    -- every tick : the results panel closing hands the pad back too
    updateLobbyPad()
    pushLobby()
end

-- CONVOY INVITE ---------------------------------------------------------------------------------

local function pushInvite()
    local i = M.invite
    if not i then
        beamjoy_communications_ui.send("BJDeliveryInvite", { open = false })
        return
    end
    local payload = table.clone(i)
    payload.open = true
    payload.title = cargoTitle(i.kind, i.cargo, i.vehicle)
    payload.expiresIn = math.max(0, (i.expiresAtMs - GetCurrentTimeMillis()) / 1000)
    payload.padActive = i.padActive == true
    payload.expiresAtMs = nil
    beamjoy_communications_ui.send("BJDeliveryInvite", payload)
end

local function closeInvite()
    if not M.invite then return end
    M.invite = nil
    beamjoy_uiNav.release("deliveryInvite")
    pushInvite()
end

---@param data table see services/deliveries.lua deliveryConvoyInvite
local function onServerInvite(data)
    if type(data) ~= "table" or not data.convoyId then return end
    if M.job or M.lobby or locked() then
        beamjoy_communications.send("deliveryConvoyInviteReply", data.convoyId, false)
        return
    end
    M.invite = data
    M.invite.expiresAtMs = GetCurrentTimeMillis() + (tonumber(data.expiresIn) or 20) * 1000
    pushInvite()
end

---@param convoyId integer
local function onServerInviteClosed(convoyId)
    if M.invite and M.invite.convoyId == convoyId then closeInvite() end
end

---@param accept boolean
local function onInviteReply(accept)
    local i = M.invite
    if not i then return end
    closeInvite()
    local own = accept and startVehicle() or nil
    if accept and not own then accept = false end
    beamjoy_communications.send("deliveryConvoyInviteReply", i.convoyId, accept == true,
        own and own.serverVID or nil)
end

--- the invite takes the pad's A/B only once focused with the Focus notification control (see
--- beamjoy/mainNav.lua) and while no other delivery window has the pad
local function tickInvite()
    local i = M.invite
    if not i then return end
    if GetCurrentTimeMillis() >= i.expiresAtMs or M.job or M.lobby then
        return closeInvite()
    end
    local want = i.focused == true and not M.board and not M.result
    if want ~= (i.padActive == true) then
        i.padActive = want
        if want then beamjoy_uiNav.acquire("deliveryInvite") else beamjoy_uiNav.release("deliveryInvite") end
    end
    pushInvite()
end

-- JOBS SECTION ----------------------------------------------------------------------------------

local function pushJobs()
    local ui = M.jobsUi
    if not ui.open then return end
    ui.lastPush = GetCurrentTimeMillis()
    local own = beamjoy_vehicles.getCurrentOwn()
    local from = own and own.veh:getPosition() or (core_camera and core_camera.getPosition())
    local rows = {}
    for _, depot in ipairs(depots()) do
        local counts = ui.counts and ui.counts[depot.id]
        local convoys = {}
        for _, c in ipairs(M.convoys) do
            if c.depotId == depot.id then
                convoys[#convoys + 1] = {
                    id = c.id,
                    leaderName = c.leaderName,
                    count = c.count,
                    max = c.max,
                    kind = c.kind,
                    title = cargoTitle(c.kind, c.cargo, c.vehicle),
                    destName = c.destName,
                }
            end
        end
        rows[#rows + 1] = {
            id = depot.id,
            name = depot.name,
            sendsPackages = sendsPackages(depot),
            sendsVehicles = sendsVehicles(depot),
            distance = from and math.round(distTo(from, depot)) or nil,
            packages = counts and counts.packages or nil,
            vehicles = counts and counts.vehicles or nil,
            convoys = convoys,
        }
    end
    table.sort(rows, function(a, b) return (a.distance or 0) < (b.distance or 0) end)
    beamjoy_communications_ui.send("BJDeliveryJobs", {
        open = true,
        depots = rows,
        pad = ui.pad,
        loading = ui.counts == nil,
        busy = M.job ~= nil or M.lobby ~= nil,
    })
end

local function requestJobsData()
    M.jobsUi.lastRequest = GetCurrentTimeMillis()
    beamjoy_communications.send("deliveryDepotsRequest")
end

--- the main window's Activities > Jobs section (windows/main/jobs) : open while it's shown, for the
--- live distances and job counts. The pad there is the main window's own (beamjoy/mainNav.lua).
function M.openJobsWindow()
    local ui = M.jobsUi
    local wasOpen = ui.open
    ui.open = true
    ui.pad = false
    if not wasOpen then
        requestJobsData()
        beamjoy_communications.send("deliveryLeaderboardRequest")
    end
    pushJobs()
end

function M.closeJobsWindow()
    local ui = M.jobsUi
    if not ui.open then return end
    ui.open = false
    beamjoy_communications_ui.send("BJDeliveryJobs", { open = false })
end

--- a depot prompt's "All depots" : the main window's Jobs section, driven by the pad
function M.openJobs()
    closeBoard()
    if M.result then M.closeResults() end
    if beamjoy_mainNav then beamjoy_mainNav.focusOn("play", "jobs") end
end

local function onJobsRequest()
    if M.jobsUi.open then
        pushJobs()
    else
        beamjoy_communications_ui.send("BJDeliveryJobs", { open = false })
    end
end

---@param depotId integer
local function onJobsGps(depotId)
    local depot = beamjoy_deliveryPoints.getPoint(tonumber(depotId))
    if not depot then return end
    if M.job then
        toast.warn(t("beamjoy.delivery.jobs.gpsDuringJob"), nil, 4)
        return
    end
    if extensions.core_groundMarkers then extensions.core_groundMarkers.setPath(v3(depot.pos)) end
    toast.info(string.var(t("beamjoy.delivery.jobs.gpsSet"), { depot.name }), nil, 4)
end

---@param list table[] {id, sendsPackages, sendsVehicles, packages, vehicles}
local function onServerDepots(list)
    local counts = {}
    for _, d in ipairs(table.isArray(list) and list or {}) do counts[d.id] = d end
    M.jobsUi.counts = counts
    pushJobs()
end

---@param payload table {packages = {rows, players, mine}, vehicles = ...}
local function onServerLeaderboard(payload)
    if type(payload) == "table" then beamjoy_communications_ui.send("BJDeliveryLeaderboard", payload) end
end

--- the main window's Activities > Jobs section : a short summary and an "Open jobs" button
local function pushJobsSummary()
    local ui = M.jobsUi
    if not ui.summaryOpen then return end
    ui.lastSummary = GetCurrentTimeMillis()
    local own = beamjoy_vehicles.getCurrentOwn()
    local from = own and own.veh:getPosition() or (core_camera and core_camera.getPosition())
    local list = depots()
    local nearest, best
    for _, depot in ipairs(list) do
        local d = from and distTo(from, depot)
        if d and (not best or d < best) then nearest, best = depot, d end
    end
    beamjoy_communications_ui.send("BJDeliveryJobsSummary", {
        depots = #list,
        convoys = #M.convoys,
        nearestName = nearest and nearest.name or nil,
        nearestDistance = best and math.round(best) or nil,
    })
end

M.pushJobs = pushJobs

local function tickJobs()
    local ui = M.jobsUi
    local now = GetCurrentTimeMillis()
    if ui.summaryOpen and now - (ui.lastSummary or 0) >= 1000 then pushJobsSummary() end
    if not ui.open then return end
    if now - ui.lastRequest >= M.JOBS_REFRESH_MS then requestJobsData() end
    if now - ui.lastPush >= 1000 then pushJobs() end
end

--- BJS's "Focus notification" control (core/input/actions/beamjoy.json bjFocusNotification,
--- listed under BeamJoy in the game's Controls menu ; RB + X / Shift + J by default) is handled by
--- beamjoy/mainNav.lua, which puts notifications first and the main window after them. These
--- three are its view of delivery's one notification, a convoy invite ; only a focused one takes
--- the pad's buttons (the convoy lobby is part of the main window now).
---@return "invite"|nil
local function focusTarget()
    if M.invite and not M.board and not M.result then return "invite" end
    return nil
end

---@return boolean
local function notificationFocusable()
    return focusTarget() ~= nil
end

---@return boolean
local function notificationFocused()
    local target = focusTarget()
    if target == "invite" then return M.invite.focused == true end
    return false
end

---@param focused boolean
local function setNotificationFocus(focused)
    local target = focusTarget()
    if target == "invite" then
        M.invite.focused = focused
        tickInvite()
    end
end

-- TICK ------------------------------------------------------------------------------------------

--- ghosts the local player's own vehicles inside any delivery point zone
local function updateZoneGhosts()
    local points = beamjoy_deliveryPoints.data.points or {}
    beamjoy_vehicles.vehicles:forEach(function(v)
        if not v.isLocal or v.isAi or v.jbeam == beamjoy_vehicles.WALKING then return end
        local inside = false
        if #points > 0 then
            local pos = v.veh:getPosition()
            for _, p in ipairs(points) do
                if distTo(pos, p) <= (tonumber(p.radius) or 8) then
                    inside = true
                    break
                end
            end
        end
        if inside ~= (M.ghosted[v.vid] == true) then
            M.ghosted[v.vid] = inside or nil
            beamjoy_vehicles.setGhostReason(v.vid, "delivery", inside)
        end
    end)
    for vid in pairs(M.ghosted) do
        if not beamjoy_vehicles.vehicles[vid] then M.ghosted[vid] = nil end
    end
end

local function tickBoard()
    if not M.board then return end
    local depot = beamjoy_deliveryPoints.getPoint(M.board.depotId)
    local own = beamjoy_vehicles.getCurrentOwn()
    if not depot or locked() or (own and distTo(own.veh:getPosition(), depot) >
            (tonumber(depot.radius) or 8) + M.BOARD_LEAVE_SLACK) then
        closeBoard()
    end
end

local function tickJob()
    local j = M.job
    if not j then return end
    if locked() then return abandonJob("blocked") end

    local jobVeh = j.vid and beamjoy_vehicles.getVehicle(j.vid, true)
    if j.spawnDeadline then
        -- a freshly spawned delivery vehicle registers asynchronously ; wait for it
        if not jobVeh or not jobVeh.veh then
            if GetCurrentTimeMillis() > j.spawnDeadline then return abandonJob("spawnFailed") end
            return pushHud()
        end
        j.spawnDeadline = nil
        j.serverVID = jobVeh.serverVID
        j.lastPos = jobVeh.veh:getPosition()
        -- the server samples convoy cohesion from this vehicle
        beamjoy_communications.send("deliveryVehicleReady", j.serverVID)
    end
    if not jobVeh or not jobVeh.veh then return abandonJob("vehicleLost") end
    j.serverVID = j.serverVID or jobVeh.serverVID
    local current = beamjoy_vehicles.getCurrentOwn()
    if current and current.vid ~= j.vid then return abandonJob("vehicleChanged") end

    local pos = jobVeh.veh:getPosition()
    local vel = jobVeh.veh:getVelocity()
    j.speed = vel and vel:length() or 0
    if j.jumpGraceUntil and GetCurrentTimeMillis() < j.jumpGraceUntil then
        j.lastPos = nil
    elseif j.lastPos and pos:distance(j.lastPos) > M.TELEPORT_JUMP then
        return abandonJob("teleported")
    else
        j.jumpGraceUntil = nil
    end
    j.lastPos = pos

    -- vehicle jobs : frozen until the server's clock starts (the other players' copies sync)
    if GetCurrentTimeMillis() < j.startMs then
        if not j.syncFrozen then
            beamjoy_vehicles.setFreeze(j.vid, true)
            j.syncFrozen = true
        end
        return pushHud()
    elseif j.syncFrozen then
        beamjoy_vehicles.setFreeze(j.vid, false)
        j.syncFrozen = nil
        toast.success(t("beamjoy.delivery.go"), nil, 3)
    end

    if j.condDeadline and GetCurrentTimeMillis() > j.condDeadline then
        j.condDeadline = nil
        beamjoy_communications.send("deliveryArrive", j.serverVID)
    end

    local dist = distTo(pos, j.to)
    j.distance = math.round(dist)
    local inside = dist <= math.max(1, tonumber(j.to.radius) or 8)
    local now = GetCurrentTimeMillis()
    if inside and not j.arriving then
        if not j.holdUntil then
            j.holdUntil = now + holdSeconds() * 1000
        elseif now >= j.holdUntil then
            j.arriving = true
            if j.stops and j.leg < #j.stops then
                -- a stop on the way : the server checks it and sends the next one
                beamjoy_communications.send("deliveryLegArrive", j.serverVID)
            elseif j.kind == "vehicles" then
                -- if the vehicle never answers (no condition interface), tickJob delivers without it
                j.condDeadline = now + 3000
                -- broken parts (integrity 0) out of all parts, the same count career's own vehicle
                -- delivery uses (career/modules/valueCalculator getNumberOfBrokenParts) ; nil when
                -- the game can't tell, which the server scores as untouched
                core_vehicleBridge.requestValue(jobVeh.veh, function(res)
                    if M.job ~= j or not j.condDeadline then return end
                    j.condDeadline = nil
                    local conditions = res and res.result
                    local cond
                    if type(conditions) == "table" and next(conditions) then
                        local broken, total = 0, 0
                        for _, info in pairs(conditions) do
                            total = total + 1
                            if type(info) == "table" and info.integrityValue == 0 then broken = broken + 1 end
                        end
                        cond = { broken = broken, total = total }
                    end
                    beamjoy_communications.send("deliveryArrive", j.serverVID, cond)
                end, 'getPartConditions')
            else
                beamjoy_communications.send("deliveryArrive", j.serverVID)
            end
        end
    elseif not inside then
        j.holdUntil = nil
    end
    pushHud()
end

local function onUpdate()
    touchUpMarkers()
end

local function onSlowUpdate()
    local isLocked = locked()
    if M.lastLocked ~= nil and isLocked ~= M.lastLocked then refreshPOIs() end
    M.lastLocked = isLocked
    updateZoneGhosts()
    tickBoard()
    tickJob()
    tickLobby()
    tickInvite()
    tickJobs()
end

-- HOOKS -----------------------------------------------------------------------------------------

---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    if not M.job then return end
    restrictions:addAll(beamjoy_recoveryPolicy.REPOSITION_ACTIONS, true)
    -- walking away swaps the controlled vehicle, which would end the job
    restrictions:addAll({ "toggleWalkingMode" }, true)
end

--- garages are refused for the whole of a vehicle job (a repair would erase the condition score) ;
--- refuelling stays allowed, and package jobs don't restrict either
---@param req RequestAuthorization
---@param kind "refuel"|"repair"|nil
local function onBJRequestStationInteraction(req, kind)
    if M.job and M.job.kind == "vehicles" and kind == "repair" then req.state = false end
end

local function onBJDeliveryPointsChanged()
    refreshPOIs()
    if M.board and not beamjoy_deliveryPoints.getPoint(M.board.depotId) then closeBoard() end
end

local function onBJScenarioChanged()
    if M.job and locked() then abandonJob("blocked") end
    if M.board and locked() then closeBoard() end
    if locked() then
        if M.lobby then
            beamjoy_communications.send("deliveryConvoyLeave")
            M.closeLobby()
        end
        if M.invite then onInviteReply(false) end
    end
    refreshPOIs()
end

---@param active boolean
local function onBJStationEditorState(active)
    M.editorOpen = active == true
    refreshPOIs()
    -- the editor clears the shared shape buffer when it closes ; put the drop-off disc back
    if not M.editorOpen and M.job then drawTarget() end
end

local function onBJClientReady()
    refreshPOIs()
    -- a Lua reload mid-job keeps the server-side job ; pick it back up
    beamjoy_communications.send("deliveryStateRequest")
end

local function onInit()
    beamjoy_communications.addHandler("deliveryBoard", onServerBoard)
    beamjoy_communications.addHandler("deliveryStartRefused", onStartRefused)
    beamjoy_communications.addHandler("deliveryJob", beginJob)
    beamjoy_communications.addHandler("deliveryEnded", onServerEnded)
    beamjoy_communications.addHandler("deliveryArriveRefused", onArriveRefused)
    beamjoy_communications.addHandler("deliveryResult", onServerResult)
    beamjoy_communications.addHandler("deliveryConvoyResults", onConvoyResults)
    beamjoy_communications.addHandler("deliveryLeg", onServerLeg)
    beamjoy_communications.addHandler("deliveryDepots", onServerDepots)
    beamjoy_communications.addHandler("deliveryLeaderboard", onServerLeaderboard)
    beamjoy_communications.addHandler("deliveryConvoyGrace", onConvoyGrace)
    beamjoy_communications.addHandler("deliveryConvoys", onServerConvoys)
    beamjoy_communications.addHandler("deliveryLobby", onServerLobby)
    beamjoy_communications.addHandler("deliveryLobbyClosed", onServerLobbyClosed)
    beamjoy_communications.addHandler("deliveryInviteList", onServerInviteList)
    beamjoy_communications.addHandler("deliveryInvite", onServerInvite)
    beamjoy_communications.addHandler("deliveryInviteClosed", onServerInviteClosed)

    beamjoy_communications_ui.addHandler("BJDeliveryBoardRequest", pushBoard)
    beamjoy_communications_ui.addHandler("BJDeliveryBoardClose", function() closeBoard() end)
    beamjoy_communications_ui.addHandler("BJDeliveryStartSolo", onStartSolo)
    beamjoy_communications_ui.addHandler("BJDeliveryStartConvoy", onStartConvoy)
    beamjoy_communications_ui.addHandler("BJDeliveryJoinConvoy", function(convoyId) M.joinConvoy(convoyId) end)
    beamjoy_communications_ui.addHandler("BJDeliveryUnstuck", onUnstuck)
    beamjoy_communications_ui.addHandler("BJDeliveryLobbyRequest", pushLobby)
    beamjoy_communications_ui.addHandler("BJDeliveryLobbyReady", onLobbyReady)
    beamjoy_communications_ui.addHandler("BJDeliveryLobbyStartNow", function()
        beamjoy_communications.send("deliveryConvoyStartNow")
    end)
    beamjoy_communications_ui.addHandler("BJDeliveryLobbyLeave", function()
        beamjoy_communications.send("deliveryConvoyLeave")
    end)
    beamjoy_communications_ui.addHandler("BJDeliveryLobbyInviting", onLobbyInviting)
    beamjoy_communications_ui.addHandler("BJDeliveryLobbyInvite", function(playerID)
        beamjoy_communications.send("deliveryConvoyInvite", tonumber(playerID))
    end)
    beamjoy_communications_ui.addHandler("BJDeliveryInviteRequest", pushInvite)
    beamjoy_communications_ui.addHandler("BJDeliveryJobsRequest", onJobsRequest)
    beamjoy_communications_ui.addHandler("BJDeliveryJobsOpenWindow", function() M.openJobsWindow() end)
    beamjoy_communications_ui.addHandler("BJDeliveryJobsClose", function() M.closeJobsWindow() end)
    beamjoy_communications_ui.addHandler("BJDeliveryJobsSummaryRequest", function()
        M.jobsUi.summaryOpen = true
        pushJobsSummary()
    end)
    beamjoy_communications_ui.addHandler("BJDeliveryJobsSummaryClosed", function()
        M.jobsUi.summaryOpen = false
    end)
    beamjoy_communications_ui.addHandler("BJDeliveryJobsGps", onJobsGps)
    beamjoy_communications_ui.addHandler("BJDeliveryJobsJoin", function(convoyId) M.joinConvoy(convoyId) end)
    beamjoy_communications_ui.addHandler("BJDeliveryLeaderboardRequest", function()
        beamjoy_communications.send("deliveryLeaderboardRequest")
    end)
    beamjoy_communications_ui.addHandler("BJDeliveryInviteReply", onInviteReply)
    beamjoy_communications_ui.addHandler("BJDeliveryHudRequest", pushHud)
    beamjoy_communications_ui.addHandler("BJDeliveryAbandon", function() abandonJob("abandoned") end)
    beamjoy_communications_ui.addHandler("BJDeliveryResultsRequest", pushResults)
    beamjoy_communications_ui.addHandler("BJDeliveryResultsClose", closeResults)
    beamjoy_communications_ui.addHandler("BJDeliveryResultsNext", onResultsNext)
end

local function onExtensionUnloaded()
    beamjoy_uiNav.release("deliveryBoard")
    beamjoy_uiNav.release("deliveryResults")
    beamjoy_uiNav.release("deliveryLobby")
    beamjoy_uiNav.release("deliveryInvite")
    beamjoy_uiNav.release("deliveryJobs")
    beamjoy_recoveryPolicy.release("delivery")
end

M.onInit = onInit
M.onExtensionUnloaded = onExtensionUnloaded
M.onBJClientReady = onBJClientReady
M.onUpdate = onUpdate
M.onSlowUpdate = onSlowUpdate

M.notificationFocusable = notificationFocusable
M.notificationFocused = notificationFocused
M.setNotificationFocus = setNotificationFocus

M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.onBJRequestBigmapPOIs = onBJRequestBigmapPOIs
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onBJRequestStationInteraction = onBJRequestStationInteraction

M.onBJDeliveryPointsChanged = onBJDeliveryPointsChanged
M.onBJScenarioChanged = onBJScenarioChanged
M.onBJStationEditorState = onBJStationEditorState

return M
