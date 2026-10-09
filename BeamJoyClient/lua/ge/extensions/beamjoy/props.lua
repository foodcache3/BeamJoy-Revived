--- Placed props : static meshes from the game's own art (barriers, cones, signs, flags...) that an
--- activity carries in its data (`race.props` for now) and that each client spawns for itself as
--- TSStatic objects. Nothing goes through BeamMP : they're never synced, owned or knocked about,
--- every client just builds the same objects from the same data. Solid to cars once the game's
--- static collision is rebuilt (`be:reloadCollision`, debounced below), which is done for a running
--- race but not for the editor's preview : the editor's ground snapping raycasts the physics
--- collision, and props it can't see there can't be snapped onto by mistake.
---
--- Entries (see services/races.lua's sanitizeProps for the server-side checks) :
---   { kind = "static", shape, pos, dir, up, scale, stretch, lift, solid }
---   { kind = "line", shape, a, b, mid, count, yaw, scale, followGround, heights }
--- A line is saved as itself and spread out here : `count` props evenly from `a` to `b` (both ends
--- included), each facing along the line turned by `yaw` degrees round its own vertical axis.
--- `mid` (optional) bends it : the line runs as a smooth curve from `a` through `mid` to `b`, its
--- props spaced evenly along the curve and each facing along it there.
--- Optional on both : `stretch` {x, y, z} scales a mesh unevenly (on top of `scale` : a map's own
--- race props, imported by beamjoy/mapRaces, are often stretched barriers), `lift` stands it that
--- much higher (mesh units), `solid = false` lets cars drive through it whatever its mesh.
--- `heights` (one ground height per prop, measured by the editor) is what makes it follow the
--- ground ; without it the props sit on the straight line from `a` to `b`.
---
--- Lamps : a catalog entry with a `light` casts it, through a SpotLight of its own at the mesh's lamp
--- head (`offset`, mesh units from its origin, turned and scaled with it), shining along `aim`. On at
--- night only, as the map's own lamps are (core_environment's night window), never casting shadows,
--- and no more than MAX_LIGHTS of them at once. A map's own props on the same mesh light up too.
---
--- Sets : each consumer shows its props under its own key (`show(key, props, opts)`), so a race and
--- anything later (hunter arenas, passive zones) never clear each other's.

local M = {
    -- raised from 200 (direct request) : the static collision rebuild a race's props cost is the
    -- map's own collision far more than theirs (0.201 s with 217 instances, 0.203 s with 17, logged
    -- 2026-10-08)
    MAX_PROPS = 500,

    --- the props offered in the editors, in the prop picker's categories (`cat`), with a few English
    --- `tags` its search also matches. `yaw` (degrees) turns the mesh so its long side follows the
    --- direction it's placed facing (a mesh's own +Y is that direction, quatFromDir) ; `length` is
    --- the gap between props on a new line ; `zOffset` (mesh units, scaled) lifts a mesh whose origin
    --- isn't at its base. Those three were tuned by hand on the first props ; one without them is
    --- tuned from its measured size (tuning() below : beamjoy_propPicker measures a mesh the first
    --- time it's previewed or armed). `collision` is the TSStatic collision type : "None" for the
    --- decorative ones cars should drive through (tape, flags, banners) ; `invisible` ones are drawn
    --- as a panel by the editor, since nothing of them shows in the world. A mesh under /levels/<map>/
    --- has its materials defined by that map only : ensureMaterials() brings them along elsewhere.
    CATALOG = {
        -- barriers
        { id = "concreteBarrier", cat = "barriers", tags = "concrete jersey wall race", shape = "/art/shapes/race/s_concrete_race_barrier.dae", yaw = 90, length = 3.1 },
        { id = "concreteArrowBarrier", cat = "barriers", tags = "concrete chevron arrow wall", shape = "/art/shapes/race/s_concrete_arrow_barrier.dae", yaw = 90, length = 3.1 },
        { id = "roadBarrier", cat = "barriers", tags = "concrete jersey wall", shape = "/art/shapes/garage_and_dealership/Clutter/concrete_road_barrier_a.dae", yaw = 90, length = 3.1 },
        { id = "roadBarrierB", cat = "barriers", tags = "concrete jersey wall", shape = "/art/shapes/garage_and_dealership/Clutter/concrete_road_barrier_b.dae" },
        { id = "jerseyBarrier", cat = "barriers", tags = "concrete wall", shape = "/art/shapes/objects/jerseybarrier_3m.dae", yaw = 0, length = 3.2 },
        { id = "jerseyBarrierEnd", cat = "barriers", tags = "concrete end cap", shape = "/art/shapes/objects/jerseybarrier_end.dae", yaw = 0, length = 3.4 },
        { id = "precastBlock", cat = "barriers", tags = "concrete cube block", shape = "/art/shapes/objects/s_precast_block.dae", yaw = 90, length = 2 },
        { id = "plasticBarrier", cat = "barriers", tags = "water filled red white", shape = "/art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier.DAE", yaw = 90, length = 1.5 },
        { id = "plasticBarrierRed", cat = "barriers", tags = "water filled", shape = "/art/shapes/garage_and_dealership/Clutter/hr_plasticbarrier_red.DAE", yaw = 90, length = 1.5 },
        { id = "raceBarricade", cat = "barriers", tags = "crowd fence metal", shape = "/art/shapes/race/ut_race_mesh_barricade_.DAE" },
        { id = "raceBarricadeCurve", cat = "barriers", tags = "crowd fence metal bend", shape = "/art/shapes/race/ut_race_mesh_barricade_curve.DAE" },
        { id = "raceBarricadeCurveB", cat = "barriers", tags = "crowd fence metal bend", shape = "/art/shapes/race/ut_race_mesh_barricade_curve_b.DAE" },
        { id = "safetyCushion", cat = "barriers", tags = "crash impact attenuator", shape = "/art/shapes/race/rally/rally_assets/s_safety_cushion_01.dae" },
        { id = "constructionBarrier", cat = "barriers", tags = "roadworks arrows", shape = "/art/shapes/objects/constructionbarrier_arrows.dae", yaw = 0, length = 2 },
        { id = "guardrail", cat = "barriers", tags = "armco rail steel", shape = "/art/shapes/objects/guardrail1.dae" },
        { id = "guardrailPost", cat = "barriers", tags = "armco post", shape = "/art/shapes/objects/guardrailpost.dae" },
        { id = "guardrailItaly", cat = "barriers", tags = "armco rail steel italy", shape = "/art/shapes/objects/italy_guardrails_common_section.dae" },
        { id = "tireStackAtt", cat = "barriers", tags = "tyre wall", shape = "/levels/automation_test_track/art/shapes/objects/tirestack.dae" },
        { id = "tireStackAttBlue", cat = "barriers", tags = "tyre wall", shape = "/levels/automation_test_track/art/shapes/objects/tirestack_blue.dae" },
        { id = "tireWallAtt", cat = "barriers", tags = "tyre stack", shape = "/levels/automation_test_track/art/shapes/objects/tirewall.dae" },
        { id = "tireStackHr", cat = "barriers", tags = "tyre wall", shape = "/levels/hirochi_raceway/art/shapes/objects/hr_tirestack.dae" },
        { id = "tireStackHrGreen", cat = "barriers", tags = "tyre wall", shape = "/levels/hirochi_raceway/art/shapes/objects/hr_tirestack_green.dae" },
        { id = "tireStackHrWhite", cat = "barriers", tags = "tyre wall", shape = "/levels/hirochi_raceway/art/shapes/objects/hr_tirestack_white.dae" },
        -- fences and tape
        { id = "tape6", cat = "fences", tags = "police ribbon closure", shape = "/art/shapes/race/rally/rally_assets/s_tape_road_closure_6m.dae", collision = "None" },
        { id = "tape8", cat = "fences", tags = "police ribbon closure", shape = "/art/shapes/race/rally/rally_assets/s_tape_road_closure_8m.dae", collision = "None" },
        { id = "tape10", cat = "fences", tags = "police ribbon closure", shape = "/art/shapes/race/rally/rally_assets/s_tape_road_closure_10m.dae", collision = "None" },
        { id = "spectatorTape", cat = "fences", tags = "crowd ribbon", shape = "/art/shapes/race/rally/rally_assets/s_spectator_tape_5m.dae", collision = "None" },
        { id = "spectatorTapeBig", cat = "fences", tags = "crowd ribbon", shape = "/art/shapes/race/rally/rally_assets/s_spectator_tape_big_a.dae", collision = "None" },
        { id = "spectatorGrid", cat = "fences", tags = "crowd barrier mesh", shape = "/art/shapes/race/rally/rally_assets/s_spectator_grid_a_2m.dae" },
        { id = "spectatorTarp", cat = "fences", tags = "screen sheet", shape = "/art/shapes/race/rally/rally_assets/s_spectator_tarp_4m.dae", collision = "None" },
        { id = "metalFence", cat = "fences", tags = "mesh wire", shape = "/art/shapes/objects/s_metal_fence.dae" },
        { id = "scrapFence", cat = "fences", tags = "corrugated sheet", shape = "/art/shapes/objects/s_scrap_fence_35_a.dae" },
        { id = "scrapFenceLong", cat = "fences", tags = "corrugated sheet", shape = "/art/shapes/objects/s_scrap_fence_5.dae" },
        { id = "brickWall", cat = "fences", tags = "masonry", shape = "/assets/meshes/architecture/modular/architectural_elements/fences/stone/s_brick_wall_001_300x400.dae" },
        { id = "concreteWall", cat = "fences", tags = "masonry", shape = "/assets/meshes/architecture/modular/architectural_elements/fences/stone/s_conc_wall_001_400x400.dae" },
        { id = "woodFence", cat = "fences", tags = "planks rural", shape = "/assets/meshes/props/assembly_kit/ak_wood_fence_001/ak_bridge_fence_board_001.dae" },
        -- cones and markers
        { id = "cone", cat = "markers", tags = "pylon traffic", shape = "/art/shapes/garage_and_dealership/Clutter/road_cone.DAE", yaw = 0, length = 2.5 },
        { id = "raceCone", cat = "markers", tags = "pylon autocross", shape = "/art/shapes/race/cone.dae" },
        { id = "bollard", cat = "markers", tags = "post yellow", shape = "/art/shapes/objects/bollard_yellow.dae", yaw = 0, length = 1.5 },
        { id = "steelBollard", cat = "markers", tags = "post", shape = "/art/shapes/garage_and_dealership/Clutter/si_bollard.DAE" },
        { id = "foamBlock", cat = "markers", tags = "drag strip reflector", shape = "/art/shapes/race/dragstrip/dragStrip_FoamBlockReflector.dae", yaw = 0, length = 1.6 },
        { id = "flagMarker", cat = "markers", tags = "pole", shape = "/art/shapes/race/flagMarker.dae", collision = "None" },
        { id = "flagMarkerOrange", cat = "markers", tags = "pole", shape = "/art/shapes/race/flagMarkerOrange.dae", collision = "None" },
        { id = "cornerMarker", cat = "markers", tags = "rally post", shape = "/art/shapes/race/rally/rally_assets/s_corner_marker.dae", collision = "None" },
        { id = "chevron", cat = "markers", tags = "bend arrow", shape = "/art/shapes/race/chevron_x1.dae" },
        { id = "chevronTriple", cat = "markers", tags = "bend arrow", shape = "/art/shapes/race/chevron_x3.dae" },
        -- signs
        { id = "arrowSignLeft", cat = "signs", tags = "direction turn", shape = "/art/shapes/objects/race_arrowsign_1_L.dae", yaw = 0, length = 3.1 },
        { id = "arrowSignRight", cat = "signs", tags = "direction turn", shape = "/art/shapes/objects/race_arrowsign_1_R.dae", yaw = 0, length = 3.1 },
        { id = "arrowBoardLeft", cat = "signs", tags = "roadworks direction", shape = "/art/shapes/objects/arrowboard_L.dae" },
        { id = "arrowBoardRight", cat = "signs", tags = "roadworks direction", shape = "/art/shapes/objects/arrowboard_R.dae" },
        { id = "constructionSign", cat = "signs", tags = "roadworks warning", shape = "/art/shapes/objects/construction_sign_big_a.DAE", yaw = 0, length = 2.6 },
        { id = "constructionSignB", cat = "signs", tags = "roadworks warning", shape = "/art/shapes/objects/construction_sign_big_b.DAE" },
        { id = "constructionSignC", cat = "signs", tags = "roadworks warning", shape = "/art/shapes/objects/construction_sign_big_c.DAE" },
        { id = "signboardStart", cat = "signs", tags = "rally board", shape = "/art/shapes/race/rally/rally_assets/s_rally_signboard_start.dae", collision = "None" },
        { id = "signboardFinish", cat = "signs", tags = "rally board end", shape = "/art/shapes/race/rally/rally_assets/s_rally_signboard_finish.dae", collision = "None" },
        { id = "signboardStop", cat = "signs", tags = "rally board", shape = "/art/shapes/race/rally/rally_assets/s_rally_signboard_stop.dae", collision = "None" },
        { id = "signboardTimeControl", cat = "signs", tags = "rally board", shape = "/art/shapes/race/rally/rally_assets/s_rally_signboard_time_control.dae", collision = "None" },
        { id = "cornerLeft", cat = "signs", tags = "rally pacenote turn", shape = "/art/shapes/race/rally/rally_assets/s_corner_dir_left.dae", collision = "None" },
        { id = "cornerRight", cat = "signs", tags = "rally pacenote turn", shape = "/art/shapes/race/rally/rally_assets/s_corner_dir_right.dae", collision = "None" },
        { id = "cornerStraight", cat = "signs", tags = "rally pacenote", shape = "/art/shapes/race/rally/rally_assets/s_corner_dir_straight.dae", collision = "None" },
        { id = "checkpointSign", cat = "signs", tags = "gate", shape = "/art/shapes/race/sign_checkpoint.dae" },
        { id = "finishSign", cat = "signs", tags = "end", shape = "/art/shapes/race/sign_finish.dae" },
        { id = "driftSign", cat = "signs", tags = "drift zone", shape = "/art/shapes/objects/s_sign_drift.dae" },
        -- start and finish
        { id = "startTree", cat = "start", tags = "lights christmas countdown", shape = "/art/shapes/race/rally/rally_assets/s_rally_start_tree.dae", yaw = 0, length = 1 },
        { id = "startSensor", cat = "start", tags = "timing beam", shape = "/art/shapes/race/rally/rally_assets/s_rally_start_sensor.dae", collision = "None" },
        { id = "truss1", cat = "start", tags = "gantry arch gate", shape = "/art/shapes/race/rally/rally_assets/s_trusssystem_01.dae" },
        { id = "truss2", cat = "start", tags = "gantry arch gate", shape = "/art/shapes/race/rally/rally_assets/s_trusssystem_02.dae" },
        { id = "truss3", cat = "start", tags = "gantry arch gate", shape = "/art/shapes/race/rally/rally_assets/s_trusssystem_03.dae" },
        { id = "truss4", cat = "start", tags = "gantry arch gate", shape = "/art/shapes/race/rally/rally_assets/s_trusssystem_04.dae" },
        { id = "truss5", cat = "start", tags = "gantry arch gate", shape = "/art/shapes/race/rally/rally_assets/s_trusssystem_05.dae" },
        { id = "truss6", cat = "start", tags = "gantry arch gate", shape = "/art/shapes/race/rally/rally_assets/s_trusssystem_06.dae" },
        { id = "banner", cat = "start", tags = "sponsor fence branding ngrc", shape = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_ngrc.dae", yaw = 0, length = 2.6, collision = "None" },
        { id = "bannerApm", cat = "start", tags = "sponsor fence branding", shape = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_apm.dae", collision = "None" },
        { id = "bannerBlastr", cat = "start", tags = "sponsor fence branding", shape = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_blastr.dae", collision = "None" },
        { id = "bannerRotopad", cat = "start", tags = "sponsor fence branding", shape = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_rotopad.dae", collision = "None" },
        { id = "arrowFlag", cat = "start", tags = "pennant", shape = "/art/shapes/race/arrowFlag_01.dae", collision = "None" },
        { id = "arrowFlagB", cat = "start", tags = "pennant", shape = "/art/shapes/race/arrowFlag_02.dae", collision = "None" },
        { id = "flagFeather", cat = "start", tags = "banner", shape = "/art/shapes/garage_and_dealership/s_flag_floor_feather_01.dae", yaw = 0, length = 4, collision = "None" },
        { id = "flagTeardrop", cat = "start", tags = "banner", shape = "/art/shapes/garage_and_dealership/s_flag_floor_teardrop_01.dae", yaw = 0, length = 4, collision = "None" },
        { id = "timerBoard", cat = "start", tags = "scoreboard clock drag timing", shape = "/art/shapes/race/dragstrip/timerboard.dae" },
        { id = "timeStand", cat = "start", tags = "scoreboard drag timing", shape = "/art/shapes/race/dragstrip/s_gm_dragstrip_timestand.dae" },
        -- ramps and obstacles
        { id = "rampLarge", cat = "ramps", tags = "jump kicker", shape = "/art/shapes/objects/ramp_massive.dae" },
        { id = "crossRampHr", cat = "ramps", tags = "jump derby", shape = "/levels/hirochi_raceway/art/shapes/buildings/derby_crossramp.dae" },
        { id = "tireHr", cat = "ramps", tags = "tyre wheel", shape = "/levels/hirochi_raceway/art/shapes/buildings/hr_tire.DAE" },
        { id = "flipRamp2x2", cat = "ramps", tags = "jump kicker", shape = "/levels/gridmap_v2/art/shapes/grid/s_gm_flip_ramp_2x2_1.dae" },
        { id = "flipRamp4x2Mild", cat = "ramps", tags = "jump kicker", shape = "/levels/gridmap_v2/art/shapes/grid/s_gm_flip_ramp_4x2_mild.dae" },
        { id = "flipRamp4x2Heavy", cat = "ramps", tags = "jump kicker", shape = "/levels/gridmap_v2/art/shapes/grid/s_gm_flip_ramp_4x2_heavy.dae" },
        { id = "flipRamp4x4", cat = "ramps", tags = "jump kicker", shape = "/levels/gridmap_v2/art/shapes/grid/s_gm_flip_ramp_4x4.dae" },
        -- scenery
        { id = "woodCrate", cat = "scenery", tags = "box", shape = "/art/shapes/objects/s_wood_crate_closed.dae", yaw = 0, length = 3 },
        { id = "crateStack", cat = "scenery", tags = "boxes", shape = "/art/shapes/garage_and_dealership/Clutter/crate_stack.DAE" },
        { id = "palletStack", cat = "scenery", tags = "cargo", shape = "/art/shapes/garage_and_dealership/Clutter/pallet_stack.DAE" },
        { id = "brickPallet", cat = "scenery", tags = "cargo bricks", shape = "/art/shapes/objects/s_brickpallet.dae" },
        { id = "barrel", cat = "scenery", tags = "drum oil red", shape = "/art/shapes/garage_and_dealership/Clutter/clutter_barrels_red.dae", yaw = 0, length = 1 },
        { id = "barrelWhite", cat = "scenery", tags = "drum oil", shape = "/art/shapes/garage_and_dealership/Clutter/clutter_barrels_white.dae" },
        { id = "metalDrum", cat = "scenery", tags = "barrel oil", shape = "/art/shapes/garage_and_dealership/Clutter/metal_drum_a.DAE" },
        { id = "dumpster", cat = "scenery", tags = "skip trash", shape = "/art/shapes/garage_and_dealership/Clutter/ind_dumpster_full.DAE" },
        { id = "cityBin", cat = "scenery", tags = "trash", shape = "/art/shapes/garage_and_dealership/Clutter/clutter_city_bin_round.dae" },
        { id = "scaffold", cat = "scenery", tags = "construction frame", shape = "/art/shapes/objects/s_scaffold_side_open.dae" },
        -- the lamps' heads measured on their meshes (their glass and bulb) : the pole's hangs at the end of
        -- its arm, the two flood lights face their own +X
        { id = "lightPole", cat = "scenery", tags = "street lamp light", shape = "/art/shapes/objects/pole_light_single.dae",
            light = { offset = { 5.0, 0, 12.55 }, aim = { 0, 0, -1 }, range = 35, innerAngle = 50, outerAngle = 150,
                color = { 1, .8, .6 }, intensity = 8000 } },
        { id = "standingLight", cat = "scenery", tags = "flood lamp light", shape = "/art/shapes/objects/s_standinglight_01.dae",
            light = { offset = { .1, 0, 1.51 }, aim = { 1, 0, -.25 }, range = 30, innerAngle = 40, outerAngle = 110,
                color = { .9, .95, 1 }, intensity = 6000 } },
        { id = "spotlight", cat = "scenery", tags = "flood lamp light", shape = "/art/shapes/objects/s_spotlight_01.dae",
            light = { offset = { .06, 0, .03 }, aim = { 1, 0, .15 }, range = 30, innerAngle = 20, outerAngle = 70,
                color = { .9, .95, 1 }, intensity = 6000 } },
        { id = "foldTable", cat = "scenery", tags = "pit", shape = "/art/shapes/race/rally/rally_assets/s_rally_fold_table_01.dae" },
        { id = "foldChair", cat = "scenery", tags = "pit seat", shape = "/art/shapes/race/rally/rally_assets/s_rally_fold_chair_01.dae", collision = "None" },
        { id = "tireRack", cat = "scenery", tags = "tyre pit", shape = "/art/shapes/garage_and_dealership/garage/s_tire_rack.dae" },
        { id = "wheelbarrow", cat = "scenery", tags = "construction", shape = "/art/shapes/objects/s_wheelbarrow.dae" },
        { id = "tarp", cat = "scenery", tags = "sheet cover", shape = "/art/shapes/objects/s_tarp_thrown_01.dae", collision = "None" },
        { id = "tree", cat = "scenery", tags = "forest beech", shape = "/assets/meshes/foliage/trees_library/beech/tree_beech_large_b.dae" },
        { id = "bush", cat = "scenery", tags = "shrub hedge beech", shape = "/assets/meshes/foliage/trees_library/beech/tree_beech_bush_a.dae", collision = "None" },
        { id = "deadTree", cat = "scenery", tags = "forest bare beech", shape = "/assets/meshes/foliage/trees_library/beech/tree_beech_dead_a.dae" },
        -- utility
        { id = "invisibleWall", cat = "utility", tags = "collision blocker hidden", shape = "/assets/meshes/props/misc/invisible_wall_1m.dae", yaw = 0, length = 1, zOffset = .5, invisible = true },
    },

    --- the picker's categories, in order
    CATEGORIES = { "barriers", "fences", "markers", "signs", "start", "ramps", "scenery", "utility" },

    --- meshes measured by beamjoy_propPicker (their object box, unscaled) : shape (lower case) ->
    --- { x, y, z, minZ }
    ---@type table<string, {x: number, y: number, z: number, minZ: number}>
    meta = {},

    ---@type table<string, {signature: string?, objects: table[], entries: table[], collision: boolean, pending: table<integer, true>}>
    sets = {},

    -- ms of a frame spent creating props : a race's whole set at once froze the game for a frame
    -- (110 ms measured, 2026-10-08), so they come in a few per frame (at least one a frame)
    SPAWN_BUDGET_MS = 3,
}

local GROUP_NAME = "BJPropsGroup"
-- the game rebuilds its whole static collision on a reload, a hitch on a big map : one reload
-- after a burst of changes, not one per change
local COLLISION_RELOAD_DELAY_MS = 300

local catalogById, catalogByShape = {}, {}
for _, c in ipairs(M.CATALOG) do
    c.collision = c.collision or "Collision Mesh"
    catalogById[c.id] = c
    catalogByShape[c.shape:lower()] = c
end

---@param id string
---@return table?
function M.getCatalogEntry(id) return catalogById[id] end

---@param shape string
---@return table? the catalog entry for a mesh path (case-insensitive), nil for one not offered
function M.catalogForShape(shape)
    return type(shape) == "string" and catalogByShape[shape:lower()] or nil
end

--- the map a mesh ships with, from its path (/levels/<map>/...), nil for a shared one
---@param shape string
---@return string?
function M.shapeLevel(shape)
    return type(shape) == "string" and shape:lower():match("^/levels/([^/]+)/") or nil
end

---@return string? the map being played, lower case
local function currentLevel()
    local ok, level = pcall(function() return getCurrentLevelIdentifier and getCurrentLevelIdentifier() end)
    return ok and type(level) == "string" and level ~= "" and level:lower() or nil
end

-- MATERIALS ------------------------------------------------------------------------------------
-- A map's own meshes (/levels/<map>/...) take their materials from that map's material files,
-- loaded with the map only : elsewhere they showed the game's "no material" texture (direct report :
-- Automation Test Track's tire stacks). Their folder's material files are loaded here before such a
-- mesh is first shown, the way the game loads a car's own materials when it's spawned
-- (core/vehicle/manager.lua). Only the materials the current map doesn't already have are added
-- (from a copy of the file under /temp), so nothing of the map itself changes.

local MATERIALS_TEMP_DIR = "/temp/bjPropMaterials/"
-- folders (lower case) already looked at on this map
local materialDirs = {}

---@param shape string
function M.ensureMaterials(shape)
    local level = M.shapeLevel(shape)
    if not level or level == currentLevel() then return end
    local dir = shape:match("^(.*/)[^/]*$")
    if not dir or materialDirs[dir:lower()] then return end
    materialDirs[dir:lower()] = true
    local ok, err = pcall(function()
        local missing, count = {}, 0
        for _, file in ipairs(FS:findFiles(dir, "*materials.json", 0, true, false) or {}) do
            local data = jsonReadFile(file)
            for key, mat in pairs(type(data) == "table" and data or {}) do
                local name = type(mat) == "table" and mat.class == "Material" and (mat.name or key) or nil
                if type(name) == "string" and not scenetree.findObject(name) then
                    mat.persistentId = nil
                    missing[key] = mat
                    count = count + 1
                end
            end
        end
        if count == 0 then return end
        local copy = MATERIALS_TEMP_DIR .. dir:gsub("[^%w]+", "_") .. "materials.json"
        jsonWriteFile(copy, missing, true)
        loadJsonMaterialsFile(copy)
        log("I", "beamjoy_props", string.format("%d materials of %s loaded for its props", count, dir))
    end)
    if not ok then LogWarn(string.format("beamjoy_props: materials of %s not loaded: %s", dir, tostring(err))) end
end

--- the catalog as the editors' pickers need it : only what's installed, with its category, tags,
--- collision, the map it comes from when it's this one, and once measured its size
---@return table[]
function M.catalogForUI()
    local out = {}
    for _, c in ipairs(M.CATALOG) do
        if FS:fileExists(c.shape) then
            out[#out + 1] = {
                id = c.id,
                shape = c.shape,
                label = "beamjoy.props.catalog." .. c.id,
                cat = c.cat,
                tags = c.tags,
                solid = c.collision ~= "None",
                invisible = c.invisible,
                map = M.shapeLevel(c.shape) == currentLevel() and M.shapeLevel(c.shape) or nil,
                length = c.length,
                size = M.meta[c.shape:lower()],
            }
        end
    end
    return out
end

--- how a mesh is laid down : `yaw` (degrees, its long side along the way it faces), `length`
--- (metres between props on a line) and `lift` (mesh units, to stand its base on the ground). The
--- hand-tuned catalog values where there are some ; else from the mesh's measured box : turned a
--- quarter when it's longer across (x) than deep (y), spaced by its longer side, lifted by how far
--- it reaches below its origin ; else defaults
---@param shape string
---@return {yaw: number, length: number, lift: number, measured: boolean}
function M.tuning(shape)
    local cat = M.catalogForShape(shape)
    local meta = type(shape) == "string" and M.meta[shape:lower()] or nil
    local yaw, length, lift = 0, 2, 0
    if meta then
        yaw = (meta.x > meta.y * 1.15) and 90 or 0
        length = math.max(.3, math.max(meta.x, meta.y) + .05)
        lift = (meta.minZ < -.02) and -meta.minZ or 0
    end
    if cat then
        if cat.yaw ~= nil then yaw = cat.yaw end
        if cat.length ~= nil then length = cat.length end
        if cat.zOffset ~= nil then lift = cat.zOffset end
    end
    return { yaw = yaw, length = length, lift = lift, measured = meta ~= nil }
end

---@param v table? {x, y, z}
---@return vec3?
local function v3(v)
    if type(v) ~= "table" or not tonumber(v.x) or not tonumber(v.y) or not tonumber(v.z) then return nil end
    return vec3(v.x, v.y, v.z)
end

---@param dir vec3
---@param degrees number
---@return vec3 dir turned round the vertical axis
local function turn(dir, degrees)
    local a = math.rad(degrees or 0)
    local c, s = math.cos(a), math.sin(a)
    return vec3(dir.x * c - dir.y * s, dir.x * s + dir.y * c, dir.z)
end
M.turn = turn

---@param line table
---@return integer
local function lineCount(line)
    return math.max(1, math.floor(tonumber(line.count) or 1))
end

--- how many props an entry stands for (a line counts each of its props)
---@param entry table
---@return integer
function M.weight(entry)
    return entry.kind == "line" and lineCount(entry) or 1
end

---@param props table[]?
---@return integer
function M.total(props)
    local n = 0
    for _, e in ipairs(type(props) == "table" and props or {}) do n = n + M.weight(e) end
    return n
end

-- points a curved line's length is measured over (its props are spaced evenly along it)
local CURVE_SAMPLES = 48

--- a line's path : the straight segment from a to b, or the curve through `mid` (a quadratic
--- Bezier whose control point puts its halfway point exactly on `mid`)
---@param line table
---@param samples integer? points on a curve (a straight line is its two ends)
---@return vec3[]? points
function M.linePath(line, samples)
    local a, b = v3(line.a), v3(line.b)
    if not a or not b then return nil end
    local mid = v3(line.mid)
    if not mid then return { a, b } end
    local ctrl = mid * 2 - (a + b) * .5
    local n = samples or CURVE_SAMPLES
    local pts = {}
    for k = 0, n do
        local t = k / n
        local u = 1 - t
        pts[k + 1] = a * (u * u) + ctrl * (2 * u * t) + b * (t * t)
    end
    return pts
end

--- the props of a line, as single placements
---@param line table
---@return {pos: vec3, dir: vec3, up: vec3}[]
function M.linePlacements(line)
    local pts = M.linePath(line)
    if not pts then return {} end
    local count = lineCount(line)
    local yaw = tonumber(line.yaw) or 0
    local heights = line.followGround ~= false and type(line.heights) == "table" and #line.heights == count and
        line.heights or nil
    -- length along the path, point to point
    local lens = { 0 }
    for k = 2, #pts do lens[k] = lens[k - 1] + pts[k]:distance(pts[k - 1]) end
    local total = lens[#lens]
    local out = {}
    local k = 1
    for i = 1, count do
        local s = count == 1 and total / 2 or total * (i - 1) / (count - 1)
        while k < #pts - 1 and lens[k + 1] < s do k = k + 1 end
        local seg = lens[k + 1] - lens[k]
        local f = seg > 1e-6 and math.max(0, math.min(1, (s - lens[k]) / seg)) or 0
        local p = pts[k] + (pts[k + 1] - pts[k]) * f
        local along = vec3(pts[k + 1].x - pts[k].x, pts[k + 1].y - pts[k].y, 0)
        local a, b, mid = v3(line.a), v3(line.b), v3(line.mid)
        if mid then
            -- the curve's own direction there (its derivative), not the sampled segment's
            local t = (k - 1 + f) / (#pts - 1)
            local ctrl = mid * 2 - (a + b) * .5
            local d = (ctrl - a) * (2 * (1 - t)) + (b - ctrl) * (2 * t)
            along = vec3(d.x, d.y, 0)
        end
        if along:length() < 1e-3 then along = vec3(pts[#pts].x - pts[1].x, pts[#pts].y - pts[1].y, 0) end
        if along:length() < 1e-3 then along = vec3(0, 1, 0) end
        if heights and tonumber(heights[i]) then p = vec3(p.x, p.y, heights[i]) end
        out[i] = { pos = p, dir = turn(along:normalized(), yaw), up = vec3(0, 0, 1) }
    end
    return out
end

--- every prop to spawn for a list of entries, in order, each with what spawning it needs
---@param props table[]?
---@return {shape: string, pos: vec3, dir: vec3, up: vec3, rot: table, scale: number, collision: string, entry: integer}[]
function M.expand(props)
    local out = {}
    for i, e in ipairs(type(props) == "table" and props or {}) do
        local cat = M.catalogForShape(e.shape)
        if type(e.shape) == "string" then
            local scale = math.max(.1, math.min(tonumber(e.scale) or 1, 10))
            local stretch = v3(e.stretch)
            local function axisScale(k)
                return scale * (stretch and math.max(.05, math.min(stretch[k], 20)) or 1)
            end
            local scales = vec3(axisScale("x"), axisScale("y"), axisScale("z"))
            -- an entry's own lift (set when it was placed, so every player stands it the same) ;
            -- else the catalog's
            local lift = (tonumber(e.lift) or (cat and cat.zOffset) or 0) * scales.z
            local placements
            if e.kind == "line" then
                placements = M.linePlacements(e)
            else
                local pos, dir, up = v3(e.pos), v3(e.dir), v3(e.up) or vec3(0, 0, 1)
                placements = (pos and dir) and { { pos = pos, dir = dir, up = up } } or {}
            end
            for _, p in ipairs(placements) do
                if #out >= M.MAX_PROPS then return out end
                if p.dir:length() > 1e-4 and p.up:length() > 1e-4 then
                    table.insert(out, {
                        shape = e.shape,
                        pos = p.pos + vec3(0, 0, lift),
                        dir = p.dir:normalized(),
                        up = p.up:normalized(),
                        rot = quatFromDir(p.dir, p.up),
                        scale = scale,
                        scales = scales,
                        collision = e.solid == false and "None" or (cat and cat.collision or "Collision Mesh"),
                        entry = i,
                    })
                end
            end
        end
    end
    return out
end

-- OBJECTS -------------------------------------------------------------------------------------

local collisionReloadAt = nil

local function scheduleCollisionReload()
    collisionReloadAt = GetCurrentTimeMillis() + COLLISION_RELOAD_DELAY_MS
end

--- props still to be created, in any set
---@return boolean
local function anyPending()
    for _, set in pairs(M.sets) do
        if next(set.pending) then return true end
    end
    return false
end

local function group()
    local g = scenetree.findObject(GROUP_NAME)
    if not g then
        g = createObject("SimGroup")
        g:registerObject(GROUP_NAME)
        g.canSave = false
    end
    return g
end

local missingShapes = {}

---@param shape string
---@return boolean
local function shapeExists(shape)
    if missingShapes[shape] == nil then
        missingShapes[shape] = not FS:fileExists(shape)
        if missingShapes[shape] then
            LogWarn(string.format("beamjoy_props: %s isn't installed, its props are skipped", shape))
        end
    end
    return not missingShapes[shape]
end

-- LAMPS : see the top of this file

--- lamps lit at once, at most : each is a light the renderer pays for every frame
local MAX_LIGHTS = 40
-- ms between two looks at the time of day
local NIGHT_CHECK_MS = 1000

---@type table<integer, userdata> a prop object's id -> its light
local lightOf = {}
local lightCount = 0
---@type boolean? the lamps' state (nil : not looked yet)
local lampsOn = nil
local nextNightCheck = 0

---@return boolean the map's own night lights are on (or would be)
local function isNight()
    local ok, state = pcall(function() return core_environment.getLightState() end)
    return ok and type(state) == "table" and state.isNight == true
end

---@param light userdata
---@param on boolean
local function setLightOn(light, on)
    if light.setLightEnabled then
        light:setLightEnabled(on)
    else
        light:setField("isEnabled", 0, on and "true" or "false")
        if light.postApply then light:postApply() end
    end
end

--- the light where the lamp's head is, shining the way it faces
---@param light userdata
---@param spec table the catalog's `light`
---@param p table an expand() entry
local function placeLight(light, spec, p)
    local scales = p.scales or vec3(p.scale, p.scale, p.scale)
    local o = spec.offset
    local pos = p.pos + p.rot * vec3(o[1] * scales.x, o[2] * scales.y, o[3] * scales.z)
    local aim = (p.rot * vec3(spec.aim[1], spec.aim[2], spec.aim[3])):normalized()
    local up = math.abs(aim.z) > .98 and (p.rot * vec3(0, 1, 0)) or vec3(0, 0, 1)
    local rot = quatFromDir(aim, up)
    light:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
end

---@param obj userdata the prop's own object
---@param p table an expand() entry
local function addLight(obj, p)
    local cat = M.catalogForShape(p.shape)
    local spec = cat and cat.light
    if not spec or lightCount >= MAX_LIGHTS then return end
    local light = createObject("SpotLight")
    if not light then return end
    light.canSave = false
    local c = spec.color
    light:setField("color", 0, string.format("%g %g %g 1", c[1], c[2], c[3]))
    light:setField("range", 0, tostring(spec.range))
    light:setField("innerAngle", 0, tostring(spec.innerAngle))
    light:setField("outerAngle", 0, tostring(spec.outerAngle))
    light:setField("intensity", 0, tostring(spec.intensity))
    light:setField("castShadows", 0, "false")
    light:setField("useColorTemperature", 0, "false")
    light:registerObject("")
    if not simObjectExists(light) then return end
    group():addObject(light)
    placeLight(light, spec, p)
    if lampsOn == nil then lampsOn = isNight() end
    setLightOn(light, lampsOn)
    lightOf[obj:getID()] = { light = light, spec = spec }
    lightCount = lightCount + 1
end

---@param obj userdata
local function removeLight(obj)
    local id = obj and simObjectExists(obj) and obj:getID()
    local l = id and lightOf[id]
    if not l then return end
    lightOf[id] = nil
    lightCount = lightCount - 1
    if simObjectExists(l.light) then l.light:delete() end
end

--- dusk and dawn : every lamp on or off
local function updateLamps()
    local now = GetCurrentTimeMillis()
    if now < nextNightCheck then return end
    nextNightCheck = now + NIGHT_CHECK_MS
    if lightCount == 0 then
        lampsOn = nil
        return
    end
    local night = isNight()
    if night == lampsOn then return end
    lampsOn = night
    for _, l in pairs(lightOf) do
        if simObjectExists(l.light) then setLightOn(l.light, night) end
    end
end

local function place(obj, p)
    obj:setPosRot(p.pos.x, p.pos.y, p.pos.z, p.rot.x, p.rot.y, p.rot.z, p.rot.w)
    obj:setScale(p.scales or vec3(p.scale, p.scale, p.scale))
    local l = lightOf[obj:getID()]
    if l and simObjectExists(l.light) then placeLight(l.light, l.spec, p) end
end

---@param p table an expand() entry
---@return table? obj
local function spawn(p)
    if not shapeExists(p.shape) then return nil end
    M.ensureMaterials(p.shape)
    local obj = createObject("TSStatic")
    obj:setField("shapeName", 0, p.shape)
    obj:setField("collisionType", 0, p.collision)
    obj:setField("decalType", 0, p.collision)
    obj.canSave = false
    obj:registerObject("")
    if not simObjectExists(obj) then return nil end
    group():addObject(obj)
    place(obj, p)
    addLight(obj, p)
    return obj
end

local function deleteObject(obj)
    removeLight(obj)
    if obj and simObjectExists(obj) then obj:delete() end
end

---@param a table expand() entry
---@param b table expand() entry
---@return boolean same mesh in the same place
local function samePlacement(a, b)
    local sa, sb = a.scales or vec3(a.scale, a.scale, a.scale), b.scales or vec3(b.scale, b.scale, b.scale)
    return a.shape == b.shape and a.collision == b.collision and sa:distance(sb) < 1e-4 and
        a.pos:distance(b.pos) < 1e-3 and
        math.abs(a.rot.x - b.rot.x) + math.abs(a.rot.y - b.rot.y) + math.abs(a.rot.z - b.rot.z) +
        math.abs(a.rot.w - b.rot.w) < 1e-5
end

--- shows a set of props, replacing what that set showed before. Objects are reused where the mesh
--- is the same (moved if needed), so dragging one prop in the editor only touches that one
---@param key string the set
---@param props table[]? entries (see the top of this file)
---@param opts {signature: string?, collision: boolean?, collisionType: string?}? `signature` :
---nothing is done while it's the one the set already shows ; `collision` (default true) : cars hit
---them (a static collision reload follows any change) ; `collisionType` : every object's, whatever
---its mesh (the editor's placing ghost is "None", never in the static collision)
function M.show(key, props, opts)
    opts = opts or {}
    local set = M.sets[key]
    if set and opts.signature and set.signature == opts.signature then return end
    set = set or { objects = {}, entries = {}, collision = false, pending = {} }
    M.sets[key] = set
    local collision = opts.collision ~= false

    local wanted = M.expand(props)
    if opts.collisionType then
        for _, p in ipairs(wanted) do p.collision = opts.collisionType end
    end
    local changed = false
    for i, p in ipairs(wanted) do
        local old, obj = set.entries[i], set.objects[i]
        if old and obj and simObjectExists(obj) and old.shape == p.shape and old.collision == p.collision then
            if not samePlacement(old, p) then
                place(obj, p)
                changed = true
            end
        else
            -- created in onUpdate, a few a frame
            deleteObject(obj)
            set.objects[i] = nil
            set.pending[i] = true
            changed = true
        end
        set.entries[i] = p
    end
    for i = #set.entries, #wanted + 1, -1 do
        deleteObject(set.objects[i])
        set.objects[i], set.entries[i], set.pending[i] = nil, nil, nil
        changed = true
    end

    if (changed and collision) or collision ~= set.collision then
        scheduleCollisionReload()
    end
    set.collision = collision
    set.signature = opts.signature
end

---@param key string
function M.hide(key)
    local set = M.sets[key]
    if not set then return end
    for _, obj in pairs(set.objects) do deleteObject(obj) end
    if set.collision and #set.entries > 0 then scheduleCollisionReload() end
    M.sets[key] = nil
end

local function hideAll()
    for key in pairs(table.clone(M.sets)) do M.hide(key) end
end

--- creates waiting props within the frame's budget ; true when some are still waiting
---@return boolean
local function spawnPending()
    local started = os.clock()
    local spawned = 0
    for _, set in pairs(M.sets) do
        for i in pairs(set.pending) do
            if spawned > 0 and (os.clock() - started) * 1000 >= M.SPAWN_BUDGET_MS then return true end
            set.pending[i] = nil
            local p = set.entries[i]
            if p and not set.objects[i] then set.objects[i] = spawn(p) end
            spawned = spawned + 1
        end
    end
    return false
end

--- props come in a few per frame ; then the static collision catches up with them (debounced, see
--- scheduleCollisionReload : it waits for the last prop)
local function onUpdate()
    updateLamps()
    if anyPending() then
        if spawnPending() then
            if collisionReloadAt then scheduleCollisionReload() end
            return
        end
        if collisionReloadAt then scheduleCollisionReload() end
    end
    if collisionReloadAt and GetCurrentTimeMillis() >= collisionReloadAt then
        collisionReloadAt = nil
        be:reloadCollision()
    end
end

-- RACES ---------------------------------------------------------------------------------------

local raceEditor = require("ge/extensions/beamjoy/ui/raceEditor")

--- a race's props : the race being edited (a preview, no collision), else the race you're in or
--- watching, from its grid until it ends. Follows the same refresh hook as the race markers
local function syncRace()
    if raceEditor.race then
        return M.show("race", raceEditor.race.props,
            { signature = "editor:" .. tostring(raceEditor.propsRevision), collision = false })
    end
    local session = beamjoy_raceRunner and (beamjoy_raceRunner.session or beamjoy_raceRunner.spectatingSession)
    local race = session and beamjoy_races and
        table.find(beamjoy_races.data, function(r) return r.id == session.raceId end)
    if race and type(race.props) == "table" and #race.props > 0 then
        return M.show("race", race.props, { signature = string.format("session:%s:%s", session.id, race.id) })
    end
    M.hide("race")
end

local function cleanup()
    hideAll()
    M.sets = {}
    -- any lamp whose prop went some other way
    for _, l in pairs(lightOf) do
        if simObjectExists(l.light) then l.light:delete() end
    end
    lightOf, lightCount, lampsOn = {}, 0, nil
    -- a new map, its own materials : looked at again
    materialDirs = {}
    if collisionReloadAt then
        collisionReloadAt = nil
        if be then be:reloadCollision() end
    end
end

M.onUpdate = onUpdate
M.onBJRaceMarkersRefresh = syncRace
M.onServerLeave = cleanup
M.onClientEndMission = cleanup
M.onExtensionUnloaded = cleanup
M.onPreExit = cleanup

return M
