--- Placed props : static meshes from the game's own art (barriers, cones, signs, flags...) that an
--- activity carries in its data (a race's, a Hunter, Infected or Derby arena's `props`) and that each client spawns for itself as
--- TSStatic objects. Nothing goes through BeamMP : they're never synced, owned or knocked about,
--- every client just builds the same objects from the same data. Solid to cars once the game's
--- static collision is rebuilt (`be:reloadCollision`, debounced below), which is done for a running
--- game but not for the editor's preview : the editor's ground snapping raycasts the physics
--- collision, and props it can't see there can't be snapped onto by mistake.
---
--- Entries (see the server's services/props.lua sanitize for its checks) :
---   { kind = "static", shape, pos, dir, up, scale, stretch, lift, solid, group }
---   { kind = "line", shape, a, b, nodes, mid, count, gap, yaw, scale, followGround, heights, alt, altYaw, altLift, group }
--- A line is saved as itself and spread out here : `count` props evenly from `a` to `b` (both ends
--- included), each facing along the line turned by `yaw` degrees round its own vertical axis. With
--- a `gap` (metres), one every `gap` from `a` instead, `count` being as many as its length takes.
--- `group` (optional, a number) : props of the same group are selected and moved together in the
--- editor, nothing more.
--- `nodes` (optional, a list of points) bend it (direct request : as many as the game's own spline
--- editor takes) : the line runs as a smooth curve from `a` through each node in turn to `b`, its
--- props spaced evenly along the curve and each facing along it there (linePath).
--- `mid` (optional, older lines : their single bend, before nodes) : the curve from `a` through
--- `mid` to `b` as it always was ; the editor makes it the line's first node once it's edited.
--- Optional on both : `stretch` {x, y, z} scales a mesh unevenly (on top of `scale` : a map's own
--- race props, imported by beamjoy/mapRaces, are often stretched barriers), `lift` stands it that
--- much higher (mesh units), `solid = false` lets cars drive through it whatever its mesh, `true`
--- makes it solid though its mesh has no collision of its own (collisionOf).
--- `alt` (optional, a line's) : every other prop of it is that mesh instead (the 2nd, 4th...), turned
--- `altYaw` degrees more and lifted `altLift` (mesh units) instead of `lift` : red and white barriers
--- in turn.
--- `parts` (optional) : more meshes that go with each prop (a prefab : a gazebo's frame and cover, a
--- billboard's stand and boards), each `{ shape, pos, dir?, up? }` relative to the prop's own mesh
--- (in its own axes and scale : `pos` from its origin, `dir` / `up` its facing and up there, the
--- prop's own by default). Moved, turned, scaled and deleted with it ; every part counts as a prop.
--- `heights` (one ground height per prop, measured by the editor) is what makes it follow the
--- ground ; without it the props sit on the straight line from `a` to `b`. `normals` (one per prop,
--- measured with them, {x, y} : the ground's up there, its z following) tilts each prop as the
--- ground under it ; a single prop's tilt is its own `up`.
--- `capA` / `capB` (optional, a line's) : a mesh at its first / last end, butting against the
--- line's end prop and facing out of the line, turned `capAYaw` / `capBYaw` degrees (its tuning
--- yaw, plus a quarter turn each time it was turned) and lifted `capALift` / `capBLift` (mesh units).
---
--- Curbs and walls : `{ kind = "sweep", profile, a, b, nodes, mid, count, followGround, heights, group }`,
--- a cross-section swept along a line's path into one mesh (SWEEPS below).
--- Painted lines : `{ kind = "paint", paint, a, b, nodes, mid, count, width, followGround, heights, group }`,
--- a decal of the game's road paint laid along a line's path (PAINTS below), never solid.
---
--- Lamps : a mesh named in LAMPS (by its file name, so every map's copy of it, picked from the
--- catalog or from any map's meshes) casts light, through a light of its own at each of its lamp
--- heads, turned and scaled with it. On at night only, as the map's own lamps are
--- (core_environment's night window), its bulb glowing then as theirs do ; never casting shadows ;
--- no more than MAX_LIGHTS heads lit at once, the nearest the camera. They're kept apart from the
--- map's own lamps : unnamed, never saved, in this module's own group, and without any of the fields
--- core_environment's night lights manager picks lamps up by (`nightLight`, `dayIntensity`,
--- `nightIntensity` on a light, `nightEmissive` or `child` on a mesh), so it never switches them and
--- they never switch anything of the map's.
---
--- Sets : each consumer shows its props under its own key (`show(key, props, opts)`), so the
--- activity's props (SYNC below), the editor's placing ghost and anything later never clear each
--- other's.

local M = {
    -- raised from 200 (direct request) : the static collision rebuild a race's props cost is the
    -- map's own collision far more than theirs (0.201 s with 217 instances, 0.203 s with 17, logged
    -- 2026-10-08). Raised again to 1000 (direct request) : the biggest stock races ship more than
    -- 500 (driver_training's ArdenteExperience 712, industrial's Track rally 531). A race's or an
    -- arena's. Mirrored by the server's services/props.lua MAX
    MAX_PROPS = 1000,

    --- the props offered in the editors, in the prop picker's categories (`cat`), with a few English
    --- `tags` its search also matches. `yaw` (degrees) turns the mesh so its long side follows the
    --- direction it's placed facing (a mesh's own +Y is that direction, quatFromDir) ; `length` is
    --- the gap between props on a new line ; `zOffset` (mesh units, scaled) lifts a mesh whose origin
    --- isn't at its base. Those three were tuned by hand on the first props ; one without them is
    --- tuned from its measured size (tuning() below : beamjoy_propPicker measures a mesh the first
    --- time it's previewed or armed). `xOffset` (mesh units, scaled) : a mesh standing to one side of
    --- its origin is moved that much along its own x when it's placed alone, so it's centred where
    --- it's placed as the others are (the flip ramps : their origin is a corner). `collision` is the
    --- TSStatic collision type : "None" for the decorative ones cars should drive through (tape,
    --- flags) ; a mesh with no collision of its own is passable anyway (checked against its .dae, see
    --- meshHasCollision) ; `invisible` ones are drawn
    --- as a panel by the editor, since nothing of them shows in the world. A mesh under /levels/<map>/
    --- has its materials defined by that map only : ensureMaterials() brings them along elsewhere.
    --- How its picture is made (beamjoy_propPicker), where the view from its size doesn't suit it :
    --- `thumbTurn` (degrees) turns the camera round it (from the back of a sign to its face),
    --- `thumbLying` pictures a mesh the preview draws lying on its back, its top toward its own +y
    --- (its file stands it up with an axis or node rotation the preview doesn't apply, the world does).
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
        { id = "metalFence", cat = "fences", tags = "mesh wire", shape = "/art/shapes/objects/s_metal_fence.dae", thumbLying = true },
        { id = "scrapFence", cat = "fences", tags = "corrugated sheet", shape = "/art/shapes/objects/s_scrap_fence_35_a.dae" },
        { id = "scrapFenceLong", cat = "fences", tags = "corrugated sheet", shape = "/art/shapes/objects/s_scrap_fence_5.dae" },
        { id = "brickWall", cat = "fences", tags = "masonry", shape = "/assets/meshes/architecture/modular/architectural_elements/fences/stone/s_brick_wall_001_300x400.dae" },
        { id = "concreteWall", cat = "fences", tags = "masonry", shape = "/assets/meshes/architecture/modular/architectural_elements/fences/stone/s_conc_wall_001_400x400.dae" },
        -- cones and markers
        { id = "cone", cat = "markers", tags = "pylon traffic", shape = "/art/shapes/garage_and_dealership/Clutter/road_cone.DAE", yaw = 0, length = 2.5 },
        { id = "raceCone", cat = "markers", tags = "pylon autocross", shape = "/art/shapes/race/cone.dae" },
        { id = "bollard", cat = "markers", tags = "post yellow", shape = "/art/shapes/objects/bollard_yellow.dae", yaw = 0, length = 1.5 },
        { id = "steelBollard", cat = "markers", tags = "post", shape = "/art/shapes/garage_and_dealership/Clutter/si_bollard.DAE" },
        { id = "foamBlock", cat = "markers", tags = "drag strip reflector", shape = "/art/shapes/race/dragstrip/dragStrip_FoamBlockReflector.dae", yaw = 0, length = 1.6 },
        { id = "flagMarker", cat = "markers", tags = "pole", shape = "/art/shapes/race/flagMarker.dae", collision = "None", thumbLying = true },
        { id = "flagMarkerOrange", cat = "markers", tags = "pole", shape = "/art/shapes/race/flagMarkerOrange.dae", collision = "None", thumbLying = true },
        { id = "cornerMarker", cat = "markers", tags = "rally post", shape = "/art/shapes/race/rally/rally_assets/s_corner_marker.dae", collision = "None" },
        -- signs
        { id = "arrowSignLeft", cat = "signs", tags = "direction turn", shape = "/art/shapes/objects/race_arrowsign_1_L.dae", yaw = 0, length = 3.1 },
        { id = "arrowSignRight", cat = "signs", tags = "direction turn", shape = "/art/shapes/objects/race_arrowsign_1_R.dae", yaw = 0, length = 3.1 },
        -- turned by hand (direct report : a quarter turn counterclockwise) : their box is about
        -- square, so the size-based guess couldn't tell their face from their side
        { id = "arrowBoardLeft", cat = "signs", tags = "roadworks direction", shape = "/art/shapes/objects/arrowboard_L.dae", yaw = -90 },
        { id = "arrowBoardRight", cat = "signs", tags = "roadworks direction", shape = "/art/shapes/objects/arrowboard_R.dae", yaw = -90 },
        -- pictured from their face (direct report : the preview showed their back)
        { id = "constructionSign", cat = "signs", tags = "roadworks warning", shape = "/art/shapes/objects/construction_sign_big_a.DAE", yaw = 0, length = 2.6, thumbTurn = 180 },
        { id = "constructionSignB", cat = "signs", tags = "roadworks warning", shape = "/art/shapes/objects/construction_sign_big_b.DAE" },
        { id = "constructionSignC", cat = "signs", tags = "roadworks warning", shape = "/art/shapes/objects/construction_sign_big_c.DAE" },
        { id = "signboardStart", cat = "signs", tags = "rally board", shape = "/art/shapes/race/rally/rally_assets/s_rally_signboard_start.dae", collision = "None" },
        { id = "signboardFinish", cat = "signs", tags = "rally board end", shape = "/art/shapes/race/rally/rally_assets/s_rally_signboard_finish.dae", collision = "None" },
        { id = "signboardStop", cat = "signs", tags = "rally board", shape = "/art/shapes/race/rally/rally_assets/s_rally_signboard_stop.dae", collision = "None" },
        { id = "signboardTimeControl", cat = "signs", tags = "rally board", shape = "/art/shapes/race/rally/rally_assets/s_rally_signboard_time_control.dae", collision = "None" },
        { id = "cornerLeft", cat = "signs", tags = "rally pacenote turn", shape = "/art/shapes/race/rally/rally_assets/s_corner_dir_left.dae", collision = "None", thumbTurn = 180 },
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
        { id = "arrowFlag", cat = "start", tags = "pennant", shape = "/art/shapes/race/arrowFlag_01.dae", collision = "None" },
        { id = "arrowFlagB", cat = "start", tags = "pennant", shape = "/art/shapes/race/arrowFlag_02.dae", collision = "None" },
        { id = "flagFeather", cat = "start", tags = "banner", shape = "/art/shapes/garage_and_dealership/s_flag_floor_feather_01.dae", yaw = 0, length = 4, collision = "None" },
        { id = "flagTeardrop", cat = "start", tags = "banner", shape = "/art/shapes/garage_and_dealership/s_flag_floor_teardrop_01.dae", yaw = 0, length = 4, collision = "None" },
        -- its tower starts 6.86 m above its origin (its concrete footing) : stood on the ground
        { id = "timerBoard", cat = "start", tags = "scoreboard clock drag timing", shape = "/art/shapes/race/dragstrip/timerboard.dae", zOffset = -6.86 },
        -- East Coast's rally gates (direct request). Stood on their origin, as the map places them :
        -- their concrete feet are sunk 2.30 m into the ground (the measured lift, 3.26 m, raised
        -- them out of it, and their collision mesh reaches lower still)
        { id = "rallyGate", cat = "start", tags = "arch gantry banner hirochi gripall", shape = "/levels/east_coast_usa/art/shapes/race/race_rally_gate.dae", yaw = 0, length = 12, zOffset = 0 },
        { id = "rallyGateFinish", cat = "start", tags = "arch gantry banner finish line", shape = "/levels/east_coast_usa/art/shapes/race/race_rally_gate_finish.dae", yaw = 0, length = 12, zOffset = 0 },
        -- ramps and obstacles
        { id = "rampLarge", cat = "ramps", tags = "jump kicker", shape = "/art/shapes/objects/ramp_massive.dae" },
        { id = "crossRampHr", cat = "ramps", tags = "jump derby", shape = "/levels/hirochi_raceway/art/shapes/buildings/derby_crossramp.dae" },
        -- (direct report) centred where they're placed as the other ramps are : their origin is a
        -- corner, the ramp 2 m (4 m) to its -x. The square one pictured from the side as the others
        -- (its box about square, the view from its size looked up its slope)
        { id = "flipRamp2x2", cat = "ramps", tags = "jump kicker", shape = "/levels/gridmap_v2/art/shapes/grid/s_gm_flip_ramp_2x2_1.dae", xOffset = 1, thumbTurn = 90 },
        { id = "flipRamp4x2Mild", cat = "ramps", tags = "jump kicker", shape = "/levels/gridmap_v2/art/shapes/grid/s_gm_flip_ramp_4x2_mild.dae", xOffset = 1 },
        { id = "flipRamp4x2Heavy", cat = "ramps", tags = "jump kicker", shape = "/levels/gridmap_v2/art/shapes/grid/s_gm_flip_ramp_4x2_heavy.dae", xOffset = 1 },
        { id = "flipRamp4x4", cat = "ramps", tags = "jump kicker", shape = "/levels/gridmap_v2/art/shapes/grid/s_gm_flip_ramp_4x4.dae", xOffset = 2 },
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
        -- lamps : their light is LAMPS' (below)
        { id = "lightPole", cat = "scenery", tags = "street lamp light", shape = "/art/shapes/objects/pole_light_single.dae" },
        -- the same arm and head on a bridge railing mount, and one each side
        { id = "lightPoleBridge", cat = "scenery", tags = "street lamp light railing", shape = "/art/shapes/objects/pole_light_bridge.dae" },
        { id = "lightPoleDouble", cat = "scenery", tags = "street lamp light twin", shape = "/art/shapes/objects/pole_light_double.dae" },
        { id = "standingLight", cat = "scenery", tags = "flood lamp light", shape = "/art/shapes/objects/s_standinglight_01.dae" },
        -- raised a little (direct request) : its bracket's lowest point is 0.08 m under its origin
        { id = "spotlight", cat = "scenery", tags = "flood lamp light", shape = "/art/shapes/objects/s_spotlight_01.dae", zOffset = .2 },
        { id = "foldTable", cat = "scenery", tags = "pit", shape = "/art/shapes/race/rally/rally_assets/s_rally_fold_table_01.dae" },
        { id = "foldChair", cat = "scenery", tags = "pit seat", shape = "/art/shapes/race/rally/rally_assets/s_rally_fold_chair_01.dae", collision = "None", thumbTurn = 180 },
        { id = "tireHr", cat = "scenery", tags = "tyre wheel giant", shape = "/levels/hirochi_raceway/art/shapes/buildings/hr_tire.DAE" },
        { id = "wheelbarrow", cat = "scenery", tags = "construction", shape = "/art/shapes/objects/s_wheelbarrow.dae" },
        { id = "tree", cat = "scenery", tags = "forest beech", shape = "/assets/meshes/foliage/trees_library/beech/tree_beech_large_b.dae" },
        { id = "bush", cat = "scenery", tags = "shrub hedge beech", shape = "/assets/meshes/foliage/trees_library/beech/tree_beech_bush_a.dae", collision = "None" },
        { id = "deadTree", cat = "scenery", tags = "forest bare beech", shape = "/assets/meshes/foliage/trees_library/beech/tree_beech_dead_a.dae" },
        -- utility
        { id = "invisibleWall", cat = "utility", tags = "collision blocker hidden", shape = "/assets/meshes/props/misc/invisible_wall_1m.dae", yaw = 0, length = 1, zOffset = .5, invisible = true },
    },

    --- the picker's categories, in order
    CATEGORIES = { "barriers", "fences", "markers", "signs", "start", "ramps", "scenery", "utility" },

    --- prefabs (the drawer's Prefabs tab, direct request) : several meshes placed as one prop (see
    --- `parts` at the top of this file). The game's own layouts (its art/prefabs files : the rally
    --- gazebos, the billboards on stands), `shape` the mesh at their origin, `thumb` the mesh the
    --- drawer pictures them by, `lift` (mesh units) how high they stand once placed (the entry's own
    --- lift). Filled below
    ---@type table[]
    PREFABS = {},
    PREFAB_CATEGORIES = { "gazebos", "billboards", "fences", "pits", "scenery" },

    --- meshes measured by beamjoy_propPicker (their object box, unscaled) : shape (lower case) ->
    --- { x, y, z, minZ }
    ---@type table<string, {x: number, y: number, z: number, minZ: number}>
    meta = {},

    ---@type table<string, {signature: string?, objects: table[], entries: table[], collision: boolean, pending: table<integer, true>}>
    sets = {},

    -- ms of a frame spent creating props : a race's whole set at once froze the game for a frame
    -- (110 ms measured, 2026-10-08), so they come in a few per frame (at least one a frame)
    SPAWN_BUDGET_MS = 3,

    -- a curb's or a wall's segments (SWEEPS below), at most : about one a metre, so 400 m in one
    -- piece. Mirrored by the server's services/props.lua
    SWEEP_MAX_SEGMENTS = 400,
    -- a curb or a wall counts as one prop every this many segments (metres) toward MAX_PROPS : one
    -- object, but its mesh and collision grow with it. Mirrored by the server and the props list
    SWEEP_WEIGHT_SEGMENTS = 20,
    -- a painted line's segments (PAINTS below), at most : about one every 2 m, so 400 m in one
    -- piece. It weighs as a curb does, one prop every SWEEP_WEIGHT_SEGMENTS segments (so every
    -- 40 m : a decal costs far less than a mesh). Mirrored by the server's services/props.lua
    PAINT_MAX_SEGMENTS = 200,
    -- a painted line's width (metres), within these. Mirrored by the server and the props list
    PAINT_WIDTH_MIN = .05,
    PAINT_WIDTH_MAX = 12,
}

-- the rally gazebos (art/prefabs/p_rally_gazebo_mod_<colour>_3x3 / _3x6) : a 3 x 3 m frame and its
-- cover at the same origin ; 3 x 6, the long cover in the middle with the frame 1.5 m to one side
-- and the frame's add-on 1.5 m to the other
do
    local RALLY = "/art/shapes/race/rally/rally_assets/s_rally_gazebo_mod_"
    for _, colour in ipairs({ "dkblue", "ngrc", "rotopad", "blastr" }) do
        table.insert(M.PREFABS, { id = "gazebo3x3" .. colour, cat = "gazebos", size = "3x3", colour = colour,
            shape = RALLY .. "frame_3x3.dae", thumb = RALLY .. "cover_" .. colour .. "_3x3.dae",
            parts = { { shape = RALLY .. "cover_" .. colour .. "_3x3.dae", pos = { 0, 0, 0 } } } })
        table.insert(M.PREFABS, { id = "gazebo3x6" .. colour, cat = "gazebos", size = "3x6", colour = colour,
            shape = RALLY .. "cover_" .. colour .. "_3x6.dae", thumb = RALLY .. "cover_" .. colour .. "_3x6.dae",
            parts = { { shape = RALLY .. "frame_addon_3x3.dae", pos = { 1.5, 0, 0 } },
                { shape = RALLY .. "frame_3x3.dae", pos = { -1.5, 0, 0 } } } })
    end
end
-- the billboards on stands (art/prefabs/p_billboard_<metal|wood>_stand_0<n>.prefab) : the stand at
-- the origin, its boards stacked on it
for _, p in ipairs({
    { id = "billboardMetal1", cat = "billboards", kind = "metal", n = 1, shape = "/art/shapes/garage_and_dealership/s_billboard_metal_stand_01.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_metal_03.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_metal_03.dae", pos = { 0, 0, 3.8 } } } },
    { id = "billboardMetal2", cat = "billboards", kind = "metal", n = 2, shape = "/art/shapes/garage_and_dealership/s_billboard_metal_stand_01.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_metal_02.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_metal_01.dae", pos = { 0, 0, 3.3 } }, { shape = "/art/shapes/garage_and_dealership/s_billboard_metal_02.dae", pos = { 0, 0, 4.095 } } } },
    { id = "billboardMetal3", cat = "billboards", kind = "metal", n = 3, shape = "/art/shapes/garage_and_dealership/s_billboard_metal_stand_01.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_metal_02.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_metal_02.dae", pos = { 0, 0, 3.547 } } } },
    { id = "billboardMetal4", cat = "billboards", kind = "metal", n = 4, shape = "/art/shapes/garage_and_dealership/s_billboard_metal_stand_03.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_04.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_04.dae", pos = { 0, -0.07, 1.366 } } } },
    { id = "billboardMetal5", cat = "billboards", kind = "metal", n = 5, shape = "/art/shapes/garage_and_dealership/s_billboard_metal_stand_03.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_08.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_08.dae", pos = { 0, -0.059, 1.529 } } } },
    { id = "billboardMetal6", cat = "billboards", kind = "metal", n = 6, shape = "/art/shapes/garage_and_dealership/s_billboard_metal_stand_02.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_03.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_03.dae", pos = { 0, -0.013, 3 } }, { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_07.dae", pos = { 0, -0.013, 1.9 } } } },
    { id = "billboardMetal7", cat = "billboards", kind = "metal", n = 7, shape = "/art/shapes/garage_and_dealership/s_billboard_metal_stand_02.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_02.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_02.dae", pos = { 0, -0.011, 2.9 } }, { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_08.dae", pos = { 0, -0.011, 1.9 } } } },
    { id = "billboardMetal8", cat = "billboards", kind = "metal", n = 8, shape = "/art/shapes/garage_and_dealership/s_billboard_metal_stand_02.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_09.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_09.dae", pos = { 0, -0.013, 3.4 } }, { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_01.dae", pos = { 0, -0.013, 2.3 } } } },
    { id = "billboardMetal9", cat = "billboards", kind = "metal", n = 9, shape = "/art/shapes/garage_and_dealership/s_billboard_metal_stand_02.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_metal_01.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_metal_01.dae", pos = { 0, 0, 3.389 } }, { shape = "/art/shapes/garage_and_dealership/s_billboard_hang_02.dae", pos = { 0, -0.007, 2.766 }, dir = { 0, 0.999, 0.053 }, up = { 0, -0.053, 0.999 } } } },
    { id = "billboardWood1", cat = "billboards", kind = "wood", n = 1, shape = "/art/shapes/garage_and_dealership/s_billboard_wood_stand_01.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_03.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_03.dae", pos = { 0, 0, 3.3 } }, { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_01.dae", pos = { 0, 0, 2.3 } } } },
    { id = "billboardWood2", cat = "billboards", kind = "wood", n = 2, shape = "/art/shapes/garage_and_dealership/s_billboard_wood_stand_01.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_02.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_02.dae", pos = { 0, 0, 3.5 } } } },
    { id = "billboardWood3", cat = "billboards", kind = "wood", n = 3, shape = "/art/shapes/garage_and_dealership/s_billboard_wood_pole_02.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_03.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_03.dae", pos = { 0, -0.1, 3.4 } } } },
    { id = "billboardWood4", cat = "billboards", kind = "wood", n = 4, shape = "/art/shapes/garage_and_dealership/s_billboard_wood_pole_02.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_02.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_02.dae", pos = { 0, -0.059, 3.4 } }, { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_0.5m_04.dae", pos = { 0, -0.041, 2.7 } } } },
    { id = "billboardWood5", cat = "billboards", kind = "wood", n = 5, shape = "/art/shapes/garage_and_dealership/s_billboard_wood_pole_02.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_01.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_3m_01.dae", pos = { 0, -0.06, 3.642 } }, { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_0.5m_05.dae", pos = { 0, -0.057, 3.1 } } } },
    { id = "billboardWood6", cat = "billboards", kind = "wood", n = 6, shape = "/art/shapes/garage_and_dealership/s_billboard_wood_pole_01.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_02.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_02.dae", pos = { 0, -0.046, 3.4 } }, { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_0.5m_03.dae", pos = { 0, -0.038, 2.4 } } } },
    { id = "billboardWood7", cat = "billboards", kind = "wood", n = 7, shape = "/art/shapes/garage_and_dealership/s_billboard_wood_pole_01.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_06.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_06.dae", pos = { 0, -0.045, 3.7 } }, { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_0.5m_01.dae", pos = { 0, -0.039, 2.9 } } } },
    { id = "billboardWood8", cat = "billboards", kind = "wood", n = 8, shape = "/art/shapes/garage_and_dealership/s_billboard_wood_pole_01.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_0.5m_02.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_0.5m_02.dae", pos = { 0, -0.042, 3.657 } } } },
    { id = "billboardWood9", cat = "billboards", kind = "wood", n = 9, shape = "/art/shapes/garage_and_dealership/s_billboard_wood_pole_01.dae", thumb = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_05.dae",
        parts = { { shape = "/art/shapes/garage_and_dealership/s_billboard_wood_1.5m_05.dae", pos = { 0, -0.049, 3.723 } } } },
}) do
    table.insert(M.PREFABS, p)
end
-- more of the game's own layouts (direct request) : the rally fences with their sponsor banners
-- (art/shapes/race/rally/rally_assets/p_metal_fence_branding_*), Industrial's walls topped with
-- mesh fence, West Coast's branded fuel pumps, Johnson Valley's trailer with its tent, Utah's
-- barrels under a tarp, East Coast's cafe tables, a brick pallet ; the lowest mesh of each is the
-- prop's own (it stands on the ground). The container stacks are laid out with the game's own
-- container spacing (Cliff's ind_containers_2x2x2 : 2.5 m apart, 2.61 m high), its own stacks
-- being made for a slope. Named by `beamjoy.props.prefabs.name.<id>`
for _, p in ipairs({
    { id = "fenceBannerBlastr", cat = "fences", shape = "/art/shapes/objects/s_metal_fence.dae", thumb = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_blastr.dae", tags = "fence banner sponsor advert rally blastr",
        parts = { { shape = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_blastr.dae", pos = { 0, 0, 0 } } } },
    { id = "fenceBannerNgrc", cat = "fences", shape = "/art/shapes/objects/s_metal_fence.dae", thumb = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_ngrc.dae", tags = "fence banner sponsor advert rally ngrc",
        parts = { { shape = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_ngrc.dae", pos = { 0, 0, 0 } } } },
    { id = "fenceBannerRotopad", cat = "fences", shape = "/art/shapes/objects/s_metal_fence.dae", thumb = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_rotopad.dae", tags = "fence banner sponsor advert rally rotopad",
        parts = { { shape = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_rotopad.dae", pos = { 0, 0, 0 } } } },
    -- the game has no prefab of the APM one : laid as the other three are
    { id = "fenceBannerApm", cat = "fences", shape = "/art/shapes/objects/s_metal_fence.dae", thumb = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_apm.dae", tags = "fence banner sponsor advert rally apm",
        parts = { { shape = "/art/shapes/race/rally/rally_assets/s_metal_fence_branding_apm.dae", pos = { 0, 0, 0 } } } },
    { id = "wallFence2m", cat = "fences", shape = "/levels/Industrial/art/shapes/buildings/ind_mesh_fence_2m.dae", thumb = "/levels/Industrial/art/shapes/buildings/ind_conc_wall_2m.dae", tags = "wall concrete fence mesh industrial",
        parts = { { shape = "/levels/Industrial/art/shapes/buildings/ind_conc_wall_2m.dae", pos = { 0, 0, 1 } } } },
    { id = "wallFence4m", cat = "fences", shape = "/levels/Industrial/art/shapes/buildings/ind_mesh_fence_4m.dae", thumb = "/levels/Industrial/art/shapes/buildings/ind_conc_wall_4m.dae", tags = "wall concrete fence mesh industrial",
        parts = { { shape = "/levels/Industrial/art/shapes/buildings/ind_conc_wall_4m.dae", pos = { 0, 0, 1 } } } },
    { id = "fuelPumpNodeoline", cat = "pits", shape = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2000.dae", thumb = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2000.dae", tags = "fuel pump petrol gas station pit nodeoline",
        parts = { { shape = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2000_nodeoline.dae", pos = { 0, 0, 0 } } } },
    { id = "fuelPumpTyranos", cat = "pits", shape = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2000.dae", thumb = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2000.dae", tags = "fuel pump petrol gas station pit tyranos",
        parts = { { shape = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2000_tyranos.dae", pos = { 0, 0, 0 } } } },
    { id = "fuelPumpApex", cat = "pits", shape = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2015.dae", thumb = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2015.dae", tags = "fuel pump petrol gas station pit apex",
        parts = { { shape = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2015_apex.dae", pos = { 0, 0, 0 } } } },
    { id = "fuelPumpTrilobite", cat = "pits", shape = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2015.dae", thumb = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2015.dae", tags = "fuel pump petrol gas station pit trilobite",
        parts = { { shape = "/levels/west_coast_usa/art/shapes/buildings/s_fuel_pump_2015_trilobite.dae", pos = { 0, 0, 0 } } } },
    { id = "truckTent", cat = "pits", shape = "/levels/johnson_valley/art/shapes/building/s_semi_trailer_tent.dae", thumb = "/levels/johnson_valley/art/shapes/building/s_semi_trailer_tent.dae", tags = "truck trailer tent hospitality paddock team",
        parts = { { shape = "/levels/johnson_valley/art/shapes/building/s_semi_trailer.dae", pos = { 1.341, -9.23, 0 }, dir = { 0, -1, 0 } } } },
    { id = "barrelsTarp", cat = "pits", shape = "/levels/Utah/art/shapes/clutter/clutter_barrels_white.dae", thumb = "/levels/Utah/art/shapes/clutter/clutter_barrels_tarp_group_a300.dae", tags = "barrels oil drums tarp clutter pit",
        parts = { { shape = "/levels/Utah/art/shapes/clutter/clutter_barrels_red.dae", pos = { 0.542, 0.215, 0 }, dir = { -0.068, 0.9977, 0 } },
            { shape = "/levels/Utah/art/shapes/clutter/clutter_barrels_red.dae", pos = { 0.076, 0.594, 0 }, dir = { 0.9999, 0.0145, 0 } },
            { shape = "/levels/Utah/art/shapes/clutter/clutter_barrels_white.dae", pos = { 0.601, 0.815, 0 }, dir = { -0.4639, -0.8859, 0 } },
            { shape = "/levels/Utah/art/shapes/clutter/clutter_barrels_white.dae", pos = { 1.121, 0.581, 0 }, dir = { -0.7514, 0.6599, 0 } },
            { shape = "/levels/Utah/art/shapes/clutter/clutter_barrels_red.dae", pos = { 0.683, 0.549, 0.862 }, dir = { -0.068, 0.9977, 0 } },
            { shape = "/levels/Utah/art/shapes/clutter/clutter_barrels_red.dae", pos = { 0.24, 0.171, 0.862 }, dir = { -0.068, 0.9977, 0 } },
            { shape = "/levels/Utah/art/shapes/clutter/clutter_barrels_tarp_group_a300.dae", pos = { 0.269, 0.303, -0.002 }, dir = { -0.83, -0.5577, 0 } } } },
    { id = "cafeTable", cat = "pits", shape = "/levels/east_coast_usa/art/shapes/clutter/clutter_city_wood_stool.dae", thumb = "/levels/east_coast_usa/art/shapes/clutter/clutter_city_wood_table.dae", tags = "table stools seats spectators cafe",
        parts = { { shape = "/levels/east_coast_usa/art/shapes/clutter/clutter_city_wood_stool.dae", pos = { 0.177, 1.082, 0 }, dir = { 0.0676, -0.9977, 0 } },
            { shape = "/levels/east_coast_usa/art/shapes/clutter/clutter_city_wood_stool.dae", pos = { -0.342, 0.675, 0 }, dir = { -0.8326, -0.5539, 0 } },
            { shape = "/levels/east_coast_usa/art/shapes/clutter/clutter_city_wood_table.dae", pos = { 0.066, 0.492, -0.002 }, dir = { -0.8083, -0.5887, 0 } } } },
    { id = "cafeTableSmall", cat = "pits", shape = "/levels/east_coast_usa/art/shapes/clutter/clutter_city_wood_stool.dae", thumb = "/levels/east_coast_usa/art/shapes/clutter/clutter_city_wood_table_small.dae", tags = "table stools seats spectators cafe small",
        parts = { { shape = "/levels/east_coast_usa/art/shapes/clutter/clutter_city_wood_stool.dae", pos = { -0.395, 0.592, 0 }, dir = { -0.8997, -0.4365, 0 } },
            { shape = "/levels/east_coast_usa/art/shapes/clutter/clutter_city_wood_table_small.dae", pos = { -0.183, 0.282, -0.006 }, dir = { 0.8375, 0.5464, 0 } } } },
    { id = "brickPallet", cat = "scenery", shape = "/art/shapes/garage_and_dealership/Clutter/wood_pallet.DAE", thumb = "/art/shapes/objects/s_brickpallet.dae", tags = "bricks pallet construction",
        parts = { { shape = "/art/shapes/objects/s_brickpallet.dae", pos = { 0, 0, 0.126 }, dir = { -1, 0, 0 } } } },
    -- West Coast's scaffolding (levels/west_coast_usa/art/prefabs/p_scaffold_short) : three bays of
    -- 3 m, three levels of 2.3 m, its closed side at the origin
    { id = "scaffold", cat = "scenery", shape = "/art/shapes/objects/s_scaffold_base_side_close.dae", thumb = "/art/shapes/objects/s_scaffold_side_close.dae", tags = "scaffolding construction frame platform",
        parts = (function()
            local S = "/art/shapes/objects/s_scaffold_"
            local parts = {}
            local function add(name, x, z) parts[#parts + 1] = { shape = S .. name .. ".dae", pos = { x, 0, z } } end
            add("platform", 0, 0)
            add("base_side_open", -3, 0)
            add("base_side_open", -6, 0)
            add("platform", -3, 0)
            for _, z in ipairs({ 2.3, 4.6 }) do
                add("support", 0, z)
                add("support", -3, z)
                add("side_close", 0, z)
                add("side_open", -3, z)
                add("side_open", -6, z)
            end
            add("platform", 0, 2.3)
            add("platform", -3, 2.3)
            return parts
        end)() },
    -- a guardrail section with its posts, as West Coast lays them (its rails 2 m apart, a post at
    -- each joint, 1 m either side of the rail's middle, 0.14 m behind it, 0.95 m under its origin).
    -- Stood 0.5 m up (direct request : its rail, its origin at its middle, was half in the ground),
    -- its posts' feet sunk 0.45 m
    { id = "guardrail", cat = "fences", shape = "/art/shapes/objects/guardrail1.dae", thumb = "/art/shapes/objects/guardrail1.dae", tags = "guardrail armco rail steel post barrier", length = 2, lift = .5,
        parts = { { shape = "/art/shapes/objects/guardrailpost.dae", pos = { -1, 0.14, -0.95 } },
            { shape = "/art/shapes/objects/guardrailpost.dae", pos = { 1, 0.14, -0.95 } } } },
    -- the drag strip's time display (Gridmap's) on its stand (direct request) : no map puts them
    -- together, so it sits on the stand's top (4.51 m above the stand's origin, the display 2.12 m
    -- high round its own), facing the same way
    { id = "dragTimeStand", cat = "billboards", shape = "/art/shapes/race/dragstrip/s_gm_dragstrip_timestand.dae", thumb = "/art/shapes/race/dragstrip/s_gm_dragstrip_time.dae", tags = "drag strip time display board stand scoreboard timing",
        parts = { { shape = "/art/shapes/race/dragstrip/s_gm_dragstrip_time.dae", pos = { 0, 0, 5.57 } } } },
    -- the garage's ceiling light (direct request), off and on (LAMPS lights the lit one) : its case
    -- and its tube share their origin, as the garage hangs them, the tube at the case's bottom and
    -- the case's rod 2.5 m up to the ceiling
    { id = "ceilingLightOff", cat = "scenery", shape = "/levels/garage_v2/art/shapes/garage/s_ceiling_light_case.dae", thumb = "/levels/garage_v2/art/shapes/garage/s_ceiling_light_case.dae", tags = "ceiling light lamp tube garage hanging off",
        parts = { { shape = "/levels/garage_v2/art/shapes/garage/s_ceiling_light_light_off.dae", pos = { 0, 0, 0 } } } },
    { id = "ceilingLightOn", cat = "scenery", shape = "/levels/garage_v2/art/shapes/garage/s_ceiling_light_case.dae", thumb = "/levels/garage_v2/art/shapes/garage/s_ceiling_light_case.dae", tags = "ceiling light lamp tube garage hanging on lit",
        parts = { { shape = "/levels/garage_v2/art/shapes/garage/s_ceiling_light_light_on.dae", pos = { 0, 0, 0 } } } },
    { id = "containers2High", cat = "scenery", shape = "/levels/Industrial/art/shapes/misc/container_01_a.dae", thumb = "/levels/Industrial/art/shapes/misc/container_01_a.dae", tags = "containers shipping stack port wall",
        parts = { { shape = "/levels/Industrial/art/shapes/misc/container_01_b.dae", pos = { 0, 0, 2.61 } } } },
    { id = "containers2x2", cat = "scenery", shape = "/levels/Industrial/art/shapes/misc/container_01_a.dae", thumb = "/levels/Industrial/art/shapes/misc/container_01_a.dae", tags = "containers shipping stack port wall",
        parts = { { shape = "/levels/Industrial/art/shapes/misc/container_01_b.dae", pos = { 2.5, 0, 0 } },
            { shape = "/levels/Industrial/art/shapes/misc/container_01_b.dae", pos = { 0, 0, 2.61 } },
            { shape = "/levels/Industrial/art/shapes/misc/container_01_a.dae", pos = { 2.5, 0, 2.61 } } } },
    { id = "containers3Pyramid", cat = "scenery", shape = "/levels/Industrial/art/shapes/misc/container_01_a.dae", thumb = "/levels/Industrial/art/shapes/misc/container_01_a.dae", tags = "containers shipping stack port wall",
        parts = { { shape = "/levels/Industrial/art/shapes/misc/container_01_b.dae", pos = { 2.5, 0, 0 } },
            { shape = "/levels/Industrial/art/shapes/misc/container_01_a.dae", pos = { 5, 0, 0 } },
            { shape = "/levels/Industrial/art/shapes/misc/container_01_b.dae", pos = { 1.25, 0, 2.61 } },
            { shape = "/levels/Industrial/art/shapes/misc/container_01_a.dae", pos = { 3.75, 0, 2.61 } } } },
}) do
    table.insert(M.PREFABS, p)
end

local prefabById = {}
for _, p in ipairs(M.PREFABS) do prefabById[p.id] = p end

---@param id string
---@return table?
function M.getPrefab(id) return prefabById[id] end

---@param v number[]? {x, y, z}
---@return table? {x, y, z}
local function xyzOf(v) return v and { x = v[1], y = v[2], z = v[3] } or nil end

--- a new prop of a prefab, placed nowhere yet : its own mesh and its parts (copies), its lift
---@param id string
---@return {shape: string, parts: table[], prefab: string, lift: number?}?
function M.prefabEntry(id)
    local p = prefabById[id]
    if not p then return nil end
    return {
        shape = p.shape,
        prefab = p.id,
        lift = p.lift,
        parts = table.map(p.parts, function(part)
            return { shape = part.shape, pos = xyzOf(part.pos), dir = xyzOf(part.dir), up = xyzOf(part.up) }
        end),
    }
end

--- how a prefab is laid down in a line (direct request : prefabs in a line), as tuning() does a
--- mesh : `yaw` its long side along the line, `length` the gap from one to the next. The prefab's
--- own `length` where it's set (a guardrail section : its rails 2 m apart), else measured from
--- its meshes' sizes where they sit (beamjoy_propPicker measures them when it's armed)
---@param id string
---@return {yaw: number, length: number}
function M.prefabTuning(id)
    local p = prefabById[id]
    if not p then return { yaw = 0, length = 2 } end
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    local function add(shape, pos)
        local m = M.meta[shape:lower()]
        local hx, hy = (m and m.x or 1) / 2, (m and m.y or 1) / 2
        local x, y = pos and pos[1] or 0, pos and pos[2] or 0
        minX, maxX = math.min(minX, x - hx), math.max(maxX, x + hx)
        minY, maxY = math.min(minY, y - hy), math.max(maxY, y + hy)
    end
    add(p.shape)
    for _, part in ipairs(p.parts) do add(part.shape, part.pos) end
    local x, y = maxX - minX, maxY - minY
    local yaw = p.yaw or ((x > y * 1.15) and 90 or 0)
    return { yaw = yaw, length = p.length or math.max(.3, math.max(x, y) + .05) }
end

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
--
-- That folder isn't always where a mesh's materials are (direct report : props from other maps
-- saved in a race on Italy came with no material after the game's cache was cleared, when they'd
-- been fine before only because the drawer had loaded the right folders by chance). Hirochi's
-- objects take hr_bld_metal_trim from its buildings folder ; Industrial's buildings ask for
-- ind_bld__2__concrete, which only Utah, Derby and Small Island define ; Jungle Rock Island's ask
-- for East Coast's eca_bld_metalbeams. So what a mesh asks for, read from its .dae (the engine maps
-- a material by its name there, its id less "-material" when it has none ; direct report :
-- "Unable to find material mapping to: m_ind_beech_leaves", the id being beech_leaves), is looked
-- up wherever it's defined, when the current map has nothing mapped to it : the shared meshes'
-- usual sources first (MATERIAL_SOURCES), then the mesh's own map, then every other map, each map's
-- material files read once a session only when it's needed. Those materials only : by that name,
-- else by the id, then as a copy of its own (bj_<name>) mapped to the name, so nothing of the map's
-- changes (no map maps the shared beech meshes' names : their own trees are copies named
-- otherwise).
--
-- A copy loaded from /temp keeps its textures : a texture named by its file alone is looked for
-- beside its material file, so it's given its source folder (372 of the stock maps' are).
--
-- A material's `class` is "Material" in most files and "material" in some (Automation Test Track's
-- plasterboard, 14 of Utah's buildings') : both are materials (isMaterial). A material object whose
-- mapTo is "unmapped_mat" maps nothing (a map's, once its level is gone) : it doesn't count as the
-- name being mapped, and a copy borrowed under that name takes a name of its own (direct report :
-- the barrels under a tarp had no "tarpaulin" on East Coast).

local MATERIALS_TEMP_DIR = "/temp/bjPropMaterials/"
-- folders (lower case) already looked at on this map
local materialDirs = {}
-- material files the shared meshes' materials are borrowed from first, the first defining one wins
local MATERIAL_SOURCES = {
    -- beech_trunk, beech_branch_01, beech_leaves, beech_blocker
    "/levels/east_coast_usa/art/shapes/trees/trees_beech/main.materials.json",
    -- leaves_strong
    "/levels/east_coast_usa/art/shapes/trees/main.materials.json",
    -- brick_plain
    "/levels/west_coast_usa/art/shapes/buildings/main.materials.json",
    -- balustrades
    "/levels/derby/art/shapes/buildings/main.materials.json",
    -- architraves
    "/art/shapes/common/materials/main.materials.json",
}
-- shared meshes some maps give a material of their own made for an older mesh of the same name
-- (direct report : the road barriers looked wrong on East Coast, whose concrete_road_barrier_a
-- material is its own old texture for its own older copy of the mesh, laid out differently). Their
-- shared material is mapped again, under a name of its own, before such a mesh is first loaded :
-- it's the one then bound to it, while the map's own copy, loaded with the map, keeps the map's
-- shape (lower case) -> {mapTo, from (a material file)}
local SHARED_MATERIALS = {
    ["/art/shapes/garage_and_dealership/clutter/concrete_road_barrier_a.dae"] = { mapTo = "concrete_road_barrier_a", from = "/art/shapes/race/main.materials.json" },
    ["/art/shapes/garage_and_dealership/clutter/concrete_road_barrier_b.dae"] = { mapTo = "concrete_road_barrier_a", from = "/art/shapes/race/main.materials.json" },
}
-- mapTo names mapped again this map
local sharedDone = {}
-- the current map's mapTo names (lower case -> true), gathered on first need
local mapped = nil
-- borrowed copies named on their own (their name was taken), this session
local renamed = 0

---@param mat any a material file's entry
---@return boolean
local function isMaterial(mat)
    return type(mat) == "table" and type(mat.class) == "string" and mat.class:lower() == "material"
end
-- shapes (lower case) already looked at on this map
local materialShapes = {}
-- shape (lower case) -> what its .dae asks for, read once a session
local meshMaterialsOf = {}
-- where materials are defined, read once a session : the sources' (`sources`), and each map's
-- (lower case), once it's needed ; mapTo (lower case) -> {file, key}
local materialIndex = {}
-- every map's material files, by map (lower case), listed once a session
local levelMaterialFiles = nil

---@return table<string, boolean>
local function mappedNames()
    if mapped then return mapped end
    mapped = {}
    local set = Sim.getMaterialSet()
    for i = 0, set:size() - 1 do
        local mat = set:at(i)
        if mat then
            local to = mat:getField("mapTo", 0)
            if type(to) == "string" and to ~= "" and to ~= "unmapped_mat" then
                mapped[to:lower()] = true
            elseif to ~= "unmapped_mat" then
                -- no mapTo : mapped by its name
                mapped[mat:getName():lower()] = true
            end
        end
    end
    return mapped
end

---@param files string[]
---@return table<string, {file: string, key: string}>
local function indexFiles(files)
    local index = {}
    for _, file in ipairs(files) do
        local ok, data = pcall(jsonReadFile, file)
        for key, mat in pairs(ok and type(data) == "table" and data or {}) do
            if isMaterial(mat) then
                local to = type(mat.mapTo) == "string" and mat.mapTo ~= "" and mat.mapTo or mat.name or key
                if type(to) == "string" and not index[to:lower()] then
                    index[to:lower()] = { file = file, key = key }
                end
            end
        end
    end
    return index
end

---@return table<string, string[]>
local function materialFilesByLevel()
    if levelMaterialFiles then return levelMaterialFiles end
    levelMaterialFiles = {}
    for _, file in ipairs(FS:findFiles("/levels/", "*materials.json", -1, true, false) or {}) do
        local level = file:lower():match("^/levels/([^/]+)/")
        if level then
            levelMaterialFiles[level] = levelMaterialFiles[level] or {}
            table.insert(levelMaterialFiles[level], file)
        end
    end
    return levelMaterialFiles
end

---@param which string "sources", or a map (lower case)
---@return table<string, {file: string, key: string}>
local function indexOf(which)
    if not materialIndex[which] then
        materialIndex[which] = indexFiles(which == "sources" and MATERIAL_SOURCES or
            (materialFilesByLevel()[which] or {}))
    end
    return materialIndex[which]
end

--- where a material is defined : the sources, the mesh's own map, then the other maps in turn
---@param names string[] what it may be mapped to (lower case), in order
---@param level string? the mesh's own map (lower case)
---@return {file: string, key: string, mapTo: string}?
local function findMaterial(names, level)
    local order = { "sources" }
    if level then order[#order + 1] = level end
    local others = {}
    for l in pairs(materialFilesByLevel()) do
        if l ~= level then others[#others + 1] = l end
    end
    table.sort(others)
    for _, l in ipairs(others) do order[#order + 1] = l end
    for _, which in ipairs(order) do
        local index = indexOf(which)
        for _, name in ipairs(names) do
            local found = index[name]
            if found then return { file = found.file, key = found.key, mapTo = name } end
        end
    end
    return nil
end

local IMAGE_EXT = { dds = true, png = true, jpg = true, jpeg = true, tga = true, bmp = true }

--- a copy of a material, its textures named by their file alone given their source folder (a copy
--- is loaded from /temp, where they wouldn't be found)
---@param mat table
---@param dir string the source material file's folder, with its last /
---@return table
local function rebased(mat, dir)
    local out = {}
    for k, v in pairs(mat) do
        if type(v) == "table" then
            out[k] = rebased(v, dir)
        elseif type(v) == "string" and not v:find("/", 1, true) and IMAGE_EXT[(v:match("%.(%w+)$") or ""):lower()] then
            out[k] = dir .. v
        elseif type(v) == "string" and v:sub(1, 2) == "./" then
            out[k] = dir .. v:sub(3)
        else
            out[k] = v
        end
    end
    return out
end

--- the materials a mesh's .dae asks for : its id (less "-material") and its name
---@param shape string
---@return {id: string, need: string}[]
local function meshMaterials(shape)
    local key = shape:lower()
    if meshMaterialsOf[key] then return meshMaterialsOf[key] end
    local dae = shape:gsub("%.[cC][dD][aA][eE]$", ".dae")
    local out, seen = {}, {}
    meshMaterialsOf[key] = out
    if not FS:fileExists(dae) then return out end
    for tag in (readFile(dae) or ""):gmatch("<material%s[^>]*>") do
        local id = tag:match('id="([^"]+)"')
        if id then
            id = id:gsub("%-material$", "")
            if not seen[id] then
                seen[id] = true
                local name = tag:match('name="([^"]+)"')
                out[#out + 1] = { id = id, need = name or id }
            end
        end
    end
    return out
end

--- borrows what the current map has no material for, of what the mesh asks for, from wherever
--- it's defined
---@param shape string
local function borrowMaterials(shape)
    local key = shape:lower()
    local level = M.shapeLevel(shape)
    -- the game's own art has its materials everywhere, and a map's own meshes on it
    if materialShapes[key] or key:find("^/art/") or (level and level == currentLevel()) then return end
    materialShapes[key] = true
    local ok, err = pcall(function()
        local have = mappedNames()
        local add, count, missing = {}, 0, {}
        local files = {}
        for _, m in ipairs(meshMaterials(shape)) do
            local need = m.need:lower()
            if not have[need] then
                local src = findMaterial({ need, m.id:lower() }, level)
                if src then
                    files[src.file] = files[src.file] or jsonReadFile(src.file)
                    local data = files[src.file]
                    local found = type(data) == "table" and data[src.key]
                    if type(found) == "table" then
                        local mat = rebased(found, src.file:match("^(.*/)[^/]*$") or "/")
                        local name = mat.name or src.key
                        if src.mapTo ~= need then
                            -- the source maps the id : a copy of its own, mapped to the name the
                            -- mesh uses
                            name = "bj_" .. m.need
                        end
                        if scenetree.findObject(name) then
                            -- the name is taken (by a material that maps nothing now, since the
                            -- mesh's name isn't mapped) : a copy under a name of its own
                            renamed = renamed + 1
                            name = string.format("bj_%s_%d", m.need, renamed)
                        end
                        mat.name, mat.mapTo, mat.internalName, mat.persistentId = name, m.need, nil, nil
                        add[name] = mat
                        count = count + 1
                    end
                else
                    missing[#missing + 1] = m.need
                end
                have[need] = true
            end
        end
        if #missing > 0 then
            LogWarn(string.format("beamjoy_props: %s : no map defines %s", shape, table.concat(missing, ", ")))
        end
        if count == 0 then return end
        local copy = MATERIALS_TEMP_DIR .. "borrowed" .. shape:gsub("[^%w]+", "_") .. ".materials.json"
        jsonWriteFile(copy, add, true)
        loadJsonMaterialsFile(copy)
        log("I", "beamjoy_props", string.format("%d materials borrowed for %s", count, shape))
    end)
    if not ok then LogWarn(string.format("beamjoy_props: materials of %s not borrowed: %s", shape, tostring(err))) end
end

--- maps a shared mesh's own material again, ahead of a map's one of the same name
---@param shape string
local function ensureSharedMaterial(shape)
    local s = SHARED_MATERIALS[shape:lower()]
    if not s or sharedDone[s.mapTo] then return end
    sharedDone[s.mapTo] = true
    local ok, err = pcall(function()
        local data = jsonReadFile(s.from)
        for _, mat in pairs(type(data) == "table" and data or {}) do
            if isMaterial(mat) and mat.mapTo == s.mapTo then
                local copy = rebased(mat, s.from:match("^(.*/)[^/]*$") or "/")
                local name = "bj_shared_" .. s.mapTo
                copy.name, copy.persistentId, copy.internalName = name, nil, nil
                if scenetree.findObject(name) then return end
                local file = MATERIALS_TEMP_DIR .. "shared_" .. s.mapTo .. ".materials.json"
                jsonWriteFile(file, { [name] = copy }, true)
                loadJsonMaterialsFile(file)
                return
            end
        end
    end)
    if not ok then LogWarn(string.format("beamjoy_props: %s not mapped again: %s", s.mapTo, tostring(err))) end
end

---@param shape string
function M.ensureMaterials(shape)
    if type(shape) ~= "string" then return end
    ensureSharedMaterial(shape)
    local level = M.shapeLevel(shape)
    local dir = shape:match("^(.*/)[^/]*$")
    if level and level ~= currentLevel() and dir and not materialDirs[dir:lower()] then
        materialDirs[dir:lower()] = true
        M.ensureFolderMaterials(dir)
        -- what the map has changed
        mapped = nil
    end
    borrowMaterials(shape)
end

--- a map's own mesh folder : its material files' materials the current map hasn't got
---@param dir string
function M.ensureFolderMaterials(dir)
    local ok, err = pcall(function()
        local missing, count = {}, 0
        for _, file in ipairs(FS:findFiles(dir, "*materials.json", 0, true, false) or {}) do
            local data = jsonReadFile(file)
            local from = file:match("^(.*/)[^/]*$") or dir
            for key, mat in pairs(type(data) == "table" and data or {}) do
                local name = isMaterial(mat) and (mat.name or key) or nil
                if type(name) == "string" and not scenetree.findObject(name) then
                    mat = rebased(mat, from)
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
    -- the curbs and walls : the drawer's Curbs & walls tab (SWEEPS)
    for _, s in ipairs(M.sweepsForUI()) do out[#out + 1] = s end
    -- the painted lines : the drawer's Paint tab (PAINTS)
    for _, s in ipairs(M.paintsForUI()) do out[#out + 1] = s end
    -- the prefabs : the drawer's Prefabs tab, named here (their names are built from parts)
    local tr = function(key) return beamjoy_lang and beamjoy_lang.translate(key) or key end
    for _, p in ipairs(M.PREFABS) do
        local installed = FS:fileExists(p.shape)
        for _, part in ipairs(p.parts) do installed = installed and FS:fileExists(part.shape) end
        if installed then
            local name
            if p.cat == "gazebos" then
                name = tr("beamjoy.props.prefabs.gazebo"):gsub("{size}", p.size == "3x6" and "3 x 6" or "3 x 3")
                    :gsub("{colour}", tr("beamjoy.props.prefabs.colour." .. p.colour))
            elseif p.cat == "billboards" and p.kind then
                name = tr("beamjoy.props.prefabs.billboard." .. p.kind):gsub("{n}", tostring(p.n))
            else
                name = tr("beamjoy.props.prefabs.name." .. p.id)
            end
            out[#out + 1] = {
                id = p.id,
                prefab = p.id,
                shape = p.shape,
                thumb = p.thumb,
                name = name,
                cat = p.cat,
                tags = p.tags or (p.cat == "gazebos" and "tent canopy pit marquee" or "sign sponsor advert banner board"),
                solid = M.solidByDefault({ shape = p.shape, parts = p.parts }),
                parts = #p.parts + 1,
                size = M.meta[(p.thumb or p.shape):lower()],
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
    -- a curb, a wall or a painted line : one object, weighed by its length (one per
    -- SWEEP_WEIGHT_SEGMENTS segments)
    if entry.kind == "sweep" or entry.kind == "paint" then
        return math.max(1, math.ceil((tonumber(entry.count) or 1) / M.SWEEP_WEIGHT_SEGMENTS))
    end
    -- each prop and every part of it
    local each = 1 + (type(entry.parts) == "table" and #entry.parts or 0)
    if entry.kind ~= "line" then return each end
    -- and a line's end caps
    local caps = (type(entry.capA) == "string" and 1 or 0) + (type(entry.capB) == "string" and 1 or 0)
    return lineCount(entry) * each + caps
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
-- points each span of a line between two of its nodes is drawn with, at least
local SPAN_SAMPLES = 8
-- a line's nodes, at most (mirrors the server's services/props.lua MAX_LINE_NODES)
M.MAX_LINE_NODES = 50

--- a line's nodes (see `nodes` at the top of this file), in order from `a` to `b`
---@param line table
---@return vec3[]
function M.lineNodes(line)
    local out = {}
    if type(line.nodes) == "table" then
        for _, n in ipairs(line.nodes) do
            local p = v3(n)
            if p then out[#out + 1] = p end
        end
    end
    return out
end

--- the curve through a line's ends and nodes (`knots`, three at least) : each span between two of
--- them a cubic, its way at a node along the chord from the knot before to the knot after
--- (Catmull-Rom, scaled to the spans' lengths : a short span beside a long one doesn't loop), at an
--- end the way a parabola through that end and its neighbour takes. A single node as far from both
--- ends draws the very curve an older line's `mid` does
---@param knots vec3[]
---@param samples integer points on the whole curve, about
---@return vec3[] points, integer[] knotAt each knot's index in the points
local function splinePath(knots, samples)
    local n = #knots
    local d = {}
    for i = 1, n - 1 do d[i] = math.max(knots[i + 1]:distance(knots[i]), 1e-3) end
    -- each knot's way, per metre along the chord
    local tan = {}
    for i = 2, n - 1 do tan[i] = (knots[i + 1] - knots[i - 1]) * (1 / (d[i - 1] + d[i])) end
    tan[1] = (knots[2] - knots[1]) * (2 / d[1]) - tan[2]
    tan[n] = (knots[n] - knots[n - 1]) * (2 / d[n - 1]) - tan[n - 1]
    local per = math.max(SPAN_SAMPLES, math.ceil(samples / (n - 1)))
    local pts, knotAt = { knots[1] }, { 1 }
    for i = 1, n - 1 do
        local p0, p1 = knots[i], knots[i + 1]
        local m0, m1 = tan[i] * d[i], tan[i + 1] * d[i]
        for k = 1, per do
            local t = k / per
            local t2, t3 = t * t, t * t * t
            pts[#pts + 1] = k == per and p1 or
                p0 * (2 * t3 - 3 * t2 + 1) + m0 * (t3 - 2 * t2 + t) + p1 * (3 * t2 - 2 * t3) + m1 * (t3 - t2)
        end
        knotAt[i + 1] = #pts
    end
    return pts, knotAt
end

--- a line's path : the straight segment from a to b, the curve through its `nodes` (splinePath),
--- or an older line's curve through `mid` (a quadratic Bezier whose control point puts its halfway
--- point exactly on `mid`)
---@param line table
---@param samples integer? points on a curve (a straight line is its two ends)
---@return vec3[]? points, integer[]? knotAt where its ends and nodes are in the points (an older
---line's `mid` as its one node)
function M.linePath(line, samples)
    local a, b = v3(line.a), v3(line.b)
    if not a or not b then return nil end
    local nodes = M.lineNodes(line)
    if #nodes > 0 then
        local knots = { a }
        for _, p in ipairs(nodes) do knots[#knots + 1] = p end
        knots[#knots + 1] = b
        return splinePath(knots, samples or CURVE_SAMPLES)
    end
    local mid = v3(line.mid)
    if not mid then return { a, b }, { 1, 2 } end
    local ctrl = mid * 2 - (a + b) * .5
    local n = samples or CURVE_SAMPLES
    local pts = {}
    for k = 0, n do
        local t = k / n
        local u = 1 - t
        pts[k + 1] = a * (u * u) + ctrl * (2 * u * t) + b * (t * t)
    end
    return pts, { 1, math.floor(n / 2) + 1, n + 1 }
end

--- a line's length along its path (metres)
---@param line table
---@return number
function M.lineLength(line)
    local pts = M.linePath(line)
    if not pts then return 0 end
    local total = 0
    for k = 2, #pts do total = total + pts[k]:distance(pts[k - 1]) end
    return total
end

--- how many props a line with a fixed gap holds : one every `gap` metres from its first end, as
--- many as its length takes
---@param line table
---@param gap number metres
---@return integer
function M.gapCount(line, gap)
    if not gap or gap <= 0 then return lineCount(line) end
    return math.floor(M.lineLength(line) / gap + 1e-6) + 1
end

-- a tilt no steeper than this (the ground's x and y slope, each), so a probe landing on a wall
-- can't lay a prop on its side
local MAX_TILT = .7

--- a prop's up from a tilt kept on its line (`normals`, the ground's up there : its x and y, its z
--- following), straight up without one
---@param n table? {x, y}
---@return vec3
local function tiltOf(n)
    local x, y = n and tonumber(n.x), n and tonumber(n.y)
    if not x or not y then return vec3(0, 0, 1) end
    x, y = math.max(-MAX_TILT, math.min(x, MAX_TILT)), math.max(-MAX_TILT, math.min(y, MAX_TILT))
    return vec3(x, y, math.sqrt(math.max(.01, 1 - x * x - y * y))):normalized()
end
M.tiltOf = tiltOf
M.MAX_TILT = MAX_TILT

--- an entry's scale on each of its mesh's axes (`scale`, times `stretch`)
---@param e table
---@return vec3
local function scalesOf(e)
    local scale = math.max(.1, math.min(tonumber(e.scale) or 1, 10))
    local stretch = v3(e.stretch)
    local function axisScale(k)
        return scale * (stretch and math.max(.05, math.min(stretch[k], 20)) or 1)
    end
    return vec3(axisScale("x"), axisScale("y"), axisScale("z"))
end

--- how far a mesh reaches behind and ahead of its origin along the way it's laid (its +Y turned
--- back by `yaw`), scaled : its box's span on that way. Measured once a session per mesh, the same
--- on every player's game ; nil when it can't be
---@param shape string?
---@param yaw number degrees
---@param scales vec3
---@return number? back, number? ahead
local function reachAlong(shape, yaw, scales)
    if type(shape) ~= "string" then return nil end
    local m = M.meta[shape:lower()]
    if (not m or m.minX == nil) and beamjoy_propPicker and beamjoy_propPicker.measure then
        m = beamjoy_propPicker.measure(shape)
    end
    if not m or m.minX == nil then return nil end
    -- the way, in the mesh's own axes
    local way = turn(vec3(0, 1, 0), -yaw)
    local back, ahead = math.huge, -math.huge
    for _, x in ipairs({ m.minX * scales.x, m.maxX * scales.x }) do
        for _, y in ipairs({ m.minY * scales.y, m.maxY * scales.y }) do
            local d = x * way.x + y * way.y
            back, ahead = math.min(back, d), math.max(ahead, d)
        end
    end
    if ahead - back < .05 then return nil end
    return back, ahead
end

--- the gap that lays a line's props end to end, none between them (direct request : a fixed gap
--- starts there) : its mesh's reach along the line, scaled (the two meshes' average when every
--- other is another) ; a prefab's own length (prefabTuning). nil for a mesh not measured
---@param line table
---@return number?
function M.gaplessGap(line)
    local scales = scalesOf(line)
    if type(line.prefab) == "string" and type(line.parts) == "table" then
        local t = M.prefabTuning(line.prefab)
        return t.length * (tonumber(line.scale) or 1)
    end
    local yaw = tonumber(line.yaw) or 0
    local back, ahead = reachAlong(line.shape, yaw, scales)
    if not back then return nil end
    local span = ahead - back
    local alt = type(line.alt) == "string" and line.alt ~= line.shape and line.alt or nil
    if alt then
        local altBack, altAhead = reachAlong(alt, yaw + (tonumber(line.altYaw) or 0), scales)
        if altBack then span = (span + altAhead - altBack) / 2 end
    end
    return span
end

---@param pts vec3[]
---@param lens number[] length along the path at each point
---@param s number length along the path, past either end continuing its end segment's way
---@return vec3 point, integer segment (from pts[k] to pts[k + 1])
local function pathAt(pts, lens, s)
    local n = #pts
    if s <= 0 or s >= lens[n] then
        local k = s <= 0 and 1 or n - 1
        local seg = pts[k + 1] - pts[k]
        local len = seg:length()
        local from, over = s <= 0 and pts[1] or pts[n], s <= 0 and s or s - lens[n]
        return len > 1e-6 and from + seg * (over / len) or from, k
    end
    local k = 1
    while k < n - 1 and lens[k + 1] < s do k = k + 1 end
    local seg = lens[k + 1] - lens[k]
    local f = seg > 1e-6 and (s - lens[k]) / seg or 0
    return pts[k] + (pts[k + 1] - pts[k]) * f, k
end

--- the point on the path, ahead of `from` (on it, in segment k), exactly `reach` metres from it
--- across the ground (x, y) : where a rigid mesh that long, its back end at `from`, has its front
--- end on the path too. Past the path's end, its last segment's way on
---@param pts vec3[]
---@param from vec3
---@param k integer
---@param reach number
---@return vec3
local function chordEnd(pts, from, k, reach)
    local n = #pts
    for j = k, n - 1 do
        local p, q = j == k and from or pts[j], pts[j + 1]
        local dx, dy = q.x - p.x, q.y - p.y
        local last = j == n - 1
        local qx, qy = q.x - from.x, q.y - from.y
        if last or qx * qx + qy * qy >= reach * reach then
            -- |p + t (q - p) - from| = reach, the far root
            local wx, wy = p.x - from.x, p.y - from.y
            local a = dx * dx + dy * dy
            if a > 1e-12 then
                local b = 2 * (wx * dx + wy * dy)
                local c = wx * wx + wy * wy - reach * reach
                local t = (-b + math.sqrt(math.max(0, b * b - 4 * a * c))) / (2 * a)
                return p + (q - p) * t
            end
        end
    end
    return from
end

--- the props of a line, as single placements : `count` of them spread evenly from end to end, or
--- with a `gap` (direct request : guardrails chained on a line), one every `gap` metres from its
--- first end, so lengthening it adds props instead of spreading them out.
--- On a curve each prop is a rigid mesh laid on it as the game's own spline tools lay theirs
--- (editor/toolUtilities/geom ribbonIntervalFrame, direct report : fences and tarps on a bend
--- didn't join) : its back end where it stands on the curve, its front end where the curve is
--- exactly its length further across the ground, facing from one to the other (the chord), so
--- neighbours meet end to end instead of each sticking out along the curve's way at its own
--- point. A straight line is the same either way. A mesh not measured faces the curve's way there
---@param line table (with its `shape`, `alt`, `yaw`, `altYaw`, `scale` and `stretch` : the meshes'
---reach along it)
---@return {pos: vec3, dir: vec3, up: vec3}[]
function M.linePlacements(line)
    local pts = M.linePath(line)
    if not pts then return {} end
    local count = lineCount(line)
    local gap = tonumber(line.gap)
    if gap and gap <= 0 then gap = nil end
    local yaw = tonumber(line.yaw) or 0
    local heights = line.followGround ~= false and type(line.heights) == "table" and #line.heights == count and
        line.heights or nil
    local normals = line.followGround ~= false and type(line.normals) == "table" and #line.normals == count and
        line.normals or nil
    -- length along the path, point to point
    local lens = { 0 }
    for k = 2, #pts do lens[k] = lens[k - 1] + pts[k]:distance(pts[k - 1]) end
    local total = lens[#lens]
    local a, b, mid = v3(line.a), v3(line.b), v3(line.mid)
    local hasNodes = #M.lineNodes(line) > 0
    local bent = mid ~= nil or hasNodes
    -- each mesh's reach along the line (a line's every other prop may be its `alt` mesh)
    local reaches = {}
    do
        local scales = scalesOf(line)
        reaches[1] = { reachAlong(line.shape, yaw, scales) }
        local alt = type(line.alt) == "string" and line.alt ~= line.shape and line.alt or nil
        reaches[2] = alt and { reachAlong(alt, yaw + (tonumber(line.altYaw) or 0), scales) } or reaches[1]
    end
    local out = {}
    for i = 1, count do
        local s
        if gap then
            s = math.min(total, (i - 1) * gap)
        else
            s = count == 1 and total / 2 or total * (i - 1) / (count - 1)
        end
        local p, k = pathAt(pts, lens, math.max(0, math.min(total, s)))
        local along
        local reach = reaches[i % 2 == 0 and 2 or 1]
        local back, ahead
        if reach and reach[1] then back, ahead = reach[1], reach[2] end
        if bent and back then
            local from, kb = pathAt(pts, lens, s + back)
            local to = chordEnd(pts, from, kb, ahead - back)
            along = vec3(to.x - from.x, to.y - from.y, 0)
            if along:length() > 1e-4 then
                along = along:normalized()
                -- its origin, `back` behind its back end along the chord
                p = vec3(from.x - along.x * back, from.y - along.y * back, p.z)
            end
        elseif mid and not hasNodes then
            -- the curve's own direction there (its derivative), not the sampled segment's
            local f = lens[k + 1] - lens[k] > 1e-6 and (math.max(0, math.min(total, s)) - lens[k]) / (lens[k + 1] - lens[k]) or 0
            local t = (k - 1 + f) / (#pts - 1)
            local ctrl = mid * 2 - (a + b) * .5
            local d = (ctrl - a) * (2 * (1 - t)) + (b - ctrl) * (2 * t)
            along = vec3(d.x, d.y, 0)
        else
            along = vec3(pts[k + 1].x - pts[k].x, pts[k + 1].y - pts[k].y, 0)
        end
        if along:length() < 1e-3 then along = vec3(pts[#pts].x - pts[1].x, pts[#pts].y - pts[1].y, 0) end
        if along:length() < 1e-3 then along = vec3(0, 1, 0) end
        if heights and tonumber(heights[i]) then p = vec3(p.x, p.y, heights[i]) end
        along = along:normalized()
        -- tilted as the ground under it (direct request) : its dir kept square to its up
        local up = tiltOf(normals and normals[i])
        local dir = turn(along, yaw)
        if up.z < .9999 then dir = (dir - up * dir:dot(up)):normalized() end
        -- `way` (flat, along the line there) and `back` / `ahead` (how far the mesh reaches along
        -- it, when it's measured) : where the editor measures the ground under it
        out[i] = { pos = p, dir = dir, up = up, way = along, back = back, ahead = ahead }
    end
    return out
end

--- a line's end caps (see `capA` / `capB` at the top of this file), as single placements : each
--- with its back end on the line's own end (its end prop's back end at the first, front end at the
--- last), facing out of the line, tilted as that end prop is
---@param line table
---@param placements table[] M.linePlacements(line)
---@return {shape: string, pos: vec3, dir: vec3, up: vec3, lift: number?, yaw: number}[]
function M.lineCaps(line, placements)
    local out = {}
    local n = #placements
    if n == 0 then return out end
    local scales = scalesOf(line)
    for _, k in ipairs({ "A", "B" }) do
        local shape = line["cap" .. k]
        if type(shape) == "string" and shape ~= "" then
            local first = k == "A"
            local pl = placements[first and 1 or n]
            local up = pl.up or vec3(0, 0, 1)
            local way = pl.way or vec3(0, 1, 0)
            local function onTilt(v)
                local t = v - up * v:dot(up)
                return t:length() > 1e-6 and t:normalized() or v
            end
            -- the line's own end, then the cap's back end on it, facing out
            local anchor = pl.pos + onTilt(way) * ((first and pl.back or pl.ahead) or 0)
            local outward = first and -way or way
            local yaw = tonumber(line["cap" .. k .. "Yaw"]) or 0
            local back = reachAlong(shape, yaw, scales)
            out[#out + 1] = {
                shape = shape,
                pos = anchor - onTilt(outward) * (back or 0),
                dir = onTilt(turn(outward, yaw)),
                up = up,
                yaw = yaw,
                lift = tonumber(line["cap" .. k .. "Lift"]),
            }
        end
    end
    return out
end

-- COLLISION -----------------------------------------------------------------------------------

-- Torque's collision in a mesh : a "collision-N" detail, its meshes "Colmesh" (or a ColBox,
-- ColSphere... made of them). A TSStatic's "Collision Mesh" is nothing without one (direct
-- report : the showroom's backdrops, the small grid's ground, said solid and weren't) ; the maps
-- give those "Visible Mesh Final" instead
local COLLISION_NODES = { "^collision%-%d", "^colmesh", "^colbox", "^colsphere", "^colcapsule", "^colconvex" }
local meshCollision = {}

---@param shape string
---@return boolean false when its .dae has no collision ; true when it has, or can't be read (a
---compiled .cdae alone : as it was taken before)
local function readCollision(shape)
    local ok, text = pcall(readFile, shape)
    if not ok or type(text) ~= "string" or text == "" then return true end
    for name in text:gmatch('<node[^>]-%sname="([Cc][Oo][Ll][^"]*)"') do
        local node = name:lower()
        for _, pattern in ipairs(COLLISION_NODES) do
            if node:find(pattern) then return true end
        end
    end
    return false
end

--- whether a mesh brings a collision of its own : read from its .dae once, kept with its size
--- (beamjoy_propPicker's meta, saved) once it's measured
---@param shape string
---@return boolean
function M.meshHasCollision(shape)
    if type(shape) ~= "string" then return false end
    local key = shape:lower()
    local meta = M.meta[key]
    if meta and meta.col ~= nil then return meta.col end
    if meshCollision[key] == nil then meshCollision[key] = readCollision(shape) end
    if meta then meta.col = meshCollision[key] end
    return meshCollision[key]
end

--- cars hit the mesh as it comes : a catalog entry's own say (tape and flags aren't), else its own
--- collision
---@param shape string
---@return boolean
local function solidMesh(shape)
    local c = M.catalogForShape(shape)
    if c then return c.collision ~= "None" end
    return M.meshHasCollision(shape)
end

--- the TSStatic collision type of one of an entry's meshes : `solid` false, none ; nothing said, the
--- mesh's own (solidMesh) ; true, solid whatever the mesh : its collision where it has one, else
--- its visible mesh's, as the maps give their backdrops and ground planes
---@param shape string
---@param solid boolean?
---@return string
local function collisionOf(shape, solid)
    if solid == false then return "None" end
    if solidMesh(shape) then return "Collision Mesh" end
    if solid ~= true then return "None" end
    return M.meshHasCollision(shape) and "Collision Mesh" or "Visible Mesh Final"
end

--- an entry's meshes : its own, a line's other one and caps, a prefab's parts
---@param e table
---@return string[]
local function meshesOf(e)
    local out = {}
    for _, s in ipairs({ e.shape, e.kind == "line" and e.alt or nil, e.kind == "line" and e.capA or nil,
        e.kind == "line" and e.capB or nil }) do
        if type(s) == "string" then out[#out + 1] = s end
    end
    for _, part in ipairs(type(e.parts) == "table" and e.parts or {}) do
        if type(part.shape) == "string" then out[#out + 1] = part.shape end
    end
    return out
end

--- cars hit an entry when nothing is said of it : one of its meshes is solid as it comes (a curb
--- or a wall always is : see SWEEPS)
---@param e table
---@return boolean
function M.solidByDefault(e)
    if e.kind == "sweep" then return true end
    if e.kind == "paint" then return false end
    for _, s in ipairs(meshesOf(e)) do
        if solidMesh(s) then return true end
    end
    return false
end

--- whether cars hit an entry (its `solid`, else its meshes')
---@param e table
---@return boolean
function M.isSolid(e)
    if e.kind == "sweep" then return true end
    -- a painted line : a decal, nothing to hit
    if e.kind == "paint" then return false end
    if e.solid == false or e.solid == true then return e.solid end
    return M.solidByDefault(e)
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
            local scales = scalesOf(e)
            -- an entry's own lift (set when it was placed, so every player stands it the same) ;
            -- else the catalog's
            local lift = (tonumber(e.lift) or (cat and cat.zOffset) or 0) * scales.z
            -- a line's other mesh, every other prop (see the top of this file)
            local alt = e.kind == "line" and type(e.alt) == "string" and e.alt ~= e.shape and e.alt or nil
            local altCat = alt and M.catalogForShape(alt)
            local altLift = alt and (tonumber(e.altLift) or (altCat and altCat.zOffset) or 0) * scales.z
            local altYaw = tonumber(e.altYaw) or 0
            local placements
            if e.kind == "line" then
                placements = M.linePlacements(e)
            else
                local pos, dir, up = v3(e.pos), v3(e.dir), v3(e.up) or vec3(0, 0, 1)
                placements = (pos and dir) and { { pos = pos, dir = dir, up = up } } or {}
            end
            for k, p in ipairs(placements) do
                if #out >= M.MAX_PROPS then return out end
                if p.dir:length() > 1e-4 and p.up:length() > 1e-4 then
                    local other = alt ~= nil and k % 2 == 0
                    local dir = other and turn(p.dir, altYaw) or p.dir
                    -- on tilted ground : the turned one kept square to its up, lifted along it
                    if other and p.up.z < .9999 then dir = (dir - p.up * dir:dot(p.up)):normalized() end
                    local pos = p.pos + p.up * (other and altLift or lift)
                    local rot = quatFromDir(dir, p.up)
                    table.insert(out, {
                        shape = other and alt or e.shape,
                        pos = pos,
                        dir = dir:normalized(),
                        up = p.up:normalized(),
                        rot = rot,
                        scale = scale,
                        scales = scales,
                        collision = collisionOf(other and alt or e.shape, e.solid),
                        entry = i,
                    })
                    -- a prefab's other meshes, where they sit on this one
                    for _, part in ipairs(type(e.parts) == "table" and e.parts or {}) do
                        local off = v3(part.pos)
                        if type(part.shape) == "string" and off then
                            if #out >= M.MAX_PROPS then return out end
                            local pdir = rot * (v3(part.dir) or vec3(0, 1, 0))
                            local pup = rot * (v3(part.up) or vec3(0, 0, 1))
                            table.insert(out, {
                                shape = part.shape,
                                pos = pos + rot * vec3(off.x * scales.x, off.y * scales.y, off.z * scales.z),
                                dir = pdir:normalized(),
                                up = pup:normalized(),
                                rot = quatFromDir(pdir, pup),
                                scale = scale,
                                scales = scales,
                                collision = collisionOf(part.shape, e.solid),
                                entry = i,
                            })
                        end
                    end
                end
            end
            -- a line's end caps
            if e.kind == "line" then
                for _, c in ipairs(M.lineCaps(e, placements)) do
                    if #out >= M.MAX_PROPS then return out end
                    local cc = M.catalogForShape(c.shape)
                    local capLift = (c.lift or (cc and cc.zOffset) or 0) * scales.z
                    table.insert(out, {
                        shape = c.shape,
                        pos = c.pos + c.up * capLift,
                        dir = c.dir,
                        up = c.up,
                        rot = quatFromDir(c.dir, c.up),
                        scale = scale,
                        scales = scales,
                        collision = collisionOf(c.shape, e.solid),
                        entry = i,
                    })
                end
            end
        end
    end
    return out
end

-- SWEEPS (curbs and walls, direct request) ------------------------------------------------------
-- A cross-section swept along a line's path into one ProceduralMesh, as the game's Track Builder
-- makes its borders and walls (util/trackBuilder/segmentToProceduralMesh.lua) : one piece, so no
-- joints on a bend, and one object for a whole run of kerb. An entry :
--   { kind = "sweep", profile, a, b, mid, count, followGround, heights, group }
-- `profile` one of M.SWEEPS (a client without it skips the entry) ; `a`, `b`, `mid` its path, as a
-- line's ; `count` the segments it's cut into (about one a metre, set by the editor : sweepCount),
-- the profile stood square to the path at each of their `count + 1` ends ; `heights` (one per end,
-- measured by the editor) is what makes it follow the ground, as a line's.
--
-- A profile is a closed outline across the path (x to its right, z up, metres, counterclockwise
-- seen from behind), reaching SKIRT under the ground so a slope across the path never shows under
-- it. A painted one changes material every `stripe` metres (about : a stripe is a whole number of
-- segments). Its materials are made here at runtime, as the game's own core.lua makes Track
-- Builder's : a plain colour over the game's white texture, or its concrete-like track base.
--
-- A ProceduralMesh has no collision switch (its only field is its material) : it's solid once the
-- static collision is rebuilt. The editor's preview and the placing ghost mustn't be, so they're
-- taken out of the scene for every rebuild done here and made again right after (reloadCollision).

local SKIRT = -.4
local WHITE_MAP = "core/art/white.color.dds"
local BASE_MAP = "core/art/trackBuilder/track_editor_base_d.dds"
-- the materials' colours (linear, as the engine takes them) and, for the drawer's swatches, CSS
local SWEEP_COLOURS = {
    red = { colour = "0.62 0.03 0.02 1", map = WHITE_MAP, css = "#c8211b" },
    white = { colour = "0.9 0.9 0.88 1", map = WHITE_MAP, css = "#eeeeea" },
    blue = { colour = "0.03 0.12 0.55 1", map = WHITE_MAP, css = "#1f4fc0" },
    yellow = { colour = "0.92 0.62 0.02 1", map = WHITE_MAP, css = "#f2c418" },
    concrete = { colour = "0.85 0.85 0.82 1", map = BASE_MAP, css = "#a9a9a4" },
}
-- a jersey barrier's outline : its foot, the shallow slope, the steep face, its top
local JERSEY = { { -.3, SKIRT }, { .3, SKIRT }, { .3, .08 }, { .19, .33 }, { .1, .81 }, { -.1, .81 },
    { -.19, .33 }, { -.3, .08 } }

M.SWEEPS = {
    -- a raised kerb, bevelled on both sides
    { id = "curb", cat = "curbs", tags = "kerb rumble strip red white", stripe = 1, colours = { "red", "white" },
        ground = "RUMBLE_STRIP",
        outline = { { -.5, SKIRT }, { .5, SKIRT }, { .5, 0 }, { .32, .06 }, { -.32, .06 }, { -.5, 0 } } },
    { id = "curbBlue", cat = "curbs", tags = "kerb rumble strip blue white", stripe = 1, colours = { "blue", "white" },
        ground = "RUMBLE_STRIP",
        outline = { { -.5, SKIRT }, { .5, SKIRT }, { .5, 0 }, { .32, .06 }, { -.32, .06 }, { -.5, 0 } } },
    -- painted on the track, barely raised
    { id = "curbFlat", cat = "curbs", tags = "kerb painted flat red white", stripe = 1, colours = { "red", "white" },
        ground = "ASPHALT",
        outline = { { -.6, SKIRT }, { .6, SKIRT }, { .6, .015 }, { .55, .025 }, { -.55, .025 }, { -.6, .015 } } },
    -- a sausage kerb : a rounded hump that unsettles a car cutting a chicane
    { id = "sausage", cat = "curbs", tags = "kerb hump chicane yellow", colours = { "yellow" }, ground = "RUMBLE_STRIP",
        outline = { { -.18, SKIRT }, { .18, SKIRT }, { .18, 0 }, { .14, .08 }, { .06, .13 }, { -.06, .13 },
            { -.14, .08 }, { -.18, 0 } } },
    { id = "barrier", cat = "walls", tags = "concrete jersey barrier low wall", colours = { "concrete" },
        ground = "ASPHALT", outline = JERSEY },
    { id = "barrierStriped", cat = "walls", tags = "concrete jersey barrier low wall painted red white", stripe = 2,
        colours = { "red", "white" }, ground = "ASPHALT", outline = JERSEY },
    { id = "wall", cat = "walls", tags = "concrete wall tall pit", colours = { "concrete" }, ground = "ASPHALT",
        outline = { { -.2, SKIRT }, { .2, SKIRT }, { .2, 1.45 }, { .15, 1.5 }, { -.15, 1.5 }, { -.2, 1.45 } } },
}
M.SWEEP_CATEGORIES = { "curbs", "walls" }

local sweepById = {}
for _, s in ipairs(M.SWEEPS) do sweepById[s.id] = s end

---@param id string
---@return table?
function M.getSweep(id) return type(id) == "string" and sweepById[id] or nil end

-- metres a segment, about
local SWEEP_STEP = 1
-- texture repeat (metres) along and across the concrete-like base map
local SWEEP_UV_METRES = 2

--- how many segments a sweep's path is cut into : about one a metre
---@param entry table
---@return integer
function M.sweepCount(entry)
    return math.max(1, math.min(math.ceil(M.lineLength(entry) / SWEEP_STEP - 1e-6), M.SWEEP_MAX_SEGMENTS))
end

---@param entry table
---@return integer
local function sweepSegments(entry)
    return math.max(1, math.min(math.floor(tonumber(entry.count) or 1), M.SWEEP_MAX_SEGMENTS))
end

--- where a sweep's profile stands : `count + 1` points evenly along its path, each with the path's
--- flat way there. On its `heights` when it follows the ground (unless `bare` : where the editor
--- measures them), else at the path's own height
---@param entry table
---@param bare boolean?
---@return {pos: vec3, way: vec3}[]
function M.sweepPoints(entry, bare)
    local count = sweepSegments(entry)
    local pts = M.linePath(entry, math.max(CURVE_SAMPLES, count * 2))
    if not pts then return {} end
    local lens = { 0 }
    for k = 2, #pts do lens[k] = lens[k - 1] + pts[k]:distance(pts[k - 1]) end
    local total = lens[#lens]
    local heights = not bare and entry.followGround ~= false and type(entry.heights) == "table" and
        #entry.heights == count + 1 and entry.heights or nil
    local out = {}
    for i = 0, count do
        local p = pathAt(pts, lens, total * i / count)
        if heights and tonumber(heights[i + 1]) then p = vec3(p.x, p.y, heights[i + 1]) end
        out[i + 1] = { pos = p }
    end
    -- the way at each : from the point before to the point after (at an end, its neighbour)
    local whole = vec3(pts[#pts].x - pts[1].x, pts[#pts].y - pts[1].y, 0)
    if whole:length() < 1e-4 then whole = vec3(0, 1, 0) end
    for i = 1, #out do
        local from, to = out[math.max(1, i - 1)].pos, out[math.min(#out, i + 1)].pos
        local way = vec3(to.x - from.x, to.y - from.y, 0)
        out[i].way = (way:length() > 1e-4 and way or whole):normalized()
    end
    return out
end

--- a sweep's material for one of its colours (made the first time it's needed ; the ground model
--- is the profile's : a kerb rumbles)
---@param colour string
---@param ground string
---@return string the material's name
local function sweepMaterial(colour, ground)
    local name = string.format("bj_sweep_%s_%s", colour, ground:lower())
    if scenetree.findObject(name) then return name end
    local spec = SWEEP_COLOURS[colour] or SWEEP_COLOURS.concrete
    local mat = createObject("Material")
    mat.mapTo = name
    mat.canSave = false
    mat:setField("diffuseColor", 0, spec.colour)
    mat:setField("colorMap", 0, spec.map)
    mat:setField("specularPower", 0, "8")
    mat:setField("specular", 0, "0.1 0.1 0.1 1")
    -- seen from either side whatever way its faces wind (its normals are its own)
    mat:setField("doubleSided", 0, "1")
    mat:setField("translucentBlendOp", 0, "None")
    mat:setField("materialTag0", 0, "beamng")
    mat:setField("groundType", 0, ground)
    mat:registerObject(name)
    return name
end

--- a sweep's meshes, as ProceduralMesh:createMesh takes one detail level : one submesh per
--- material, its faces { v, n, u } indexing its verts, normals and uvs from 0. Laid out from its
--- first point (the object stands there), so the vertex positions keep their precision
---@param entry table
---@return table[]? submeshes, vec3? origin
function M.sweepMeshes(entry)
    local profile = sweepById[entry.profile]
    if not profile then return nil end
    local pts = M.sweepPoints(entry)
    if #pts < 2 then return nil end
    local origin = pts[1].pos
    local outline = profile.outline
    local n = #outline
    local up = vec3(0, 0, 1)

    -- length along the path at each point (the textures' v), and the segments a stripe takes
    local along = { 0 }
    for i = 2, #pts do along[i] = along[i - 1] + pts[i].pos:distance(pts[i - 1].pos) end
    local segLen = math.max(1e-3, along[#along] / (#pts - 1))
    local per = profile.stripe and math.max(1, math.floor(profile.stripe / segLen + .5)) or math.huge
    -- the outline's length round to each corner (the textures' u)
    local round = { 0 }
    for j = 1, n do
        local o0, o1 = outline[j], outline[j % n + 1]
        round[j + 1] = round[j] + math.sqrt((o1[1] - o0[1]) ^ 2 + (o1[2] - o0[2]) ^ 2)
    end

    local subs, order = {}, {}
    local function sub(colour)
        if not subs[colour] then
            subs[colour] = { verts = {}, normals = {}, uvs = {}, faces = {},
                material = sweepMaterial(colour, profile.ground or "ASPHALT") }
            order[#order + 1] = colour
        end
        return subs[colour]
    end
    ---@param s table
    ---@param pos vec3
    ---@param normal vec3
    ---@param u number
    ---@param v number
    ---@return integer its index (from 0)
    local function vert(s, pos, normal, u, v)
        local k = #s.verts
        s.verts[k + 1] = { x = pos.x, y = pos.y, z = pos.z }
        s.normals[k + 1] = { x = normal.x, y = normal.y, z = normal.z }
        s.uvs[k + 1] = { u = u, v = v }
        return k
    end
    local function tri(s, a, b, c)
        local f = s.faces
        f[#f + 1] = { v = a, n = a, u = a }
        f[#f + 1] = { v = b, n = b, u = b }
        f[#f + 1] = { v = c, n = c, u = c }
    end
    ---@param p table a point
    ---@param o number[] an outline corner
    ---@return vec3
    local function at(p, o)
        local right = vec3(p.way.y, -p.way.x, 0)
        return p.pos - origin + right * o[1] + up * o[2]
    end

    local colours = profile.colours
    for i = 1, #pts - 1 do
        local s = sub(colours[(math.floor((i - 1) / per) % #colours) + 1])
        local p0, p1 = pts[i], pts[i + 1]
        local r0, r1 = vec3(p0.way.y, -p0.way.x, 0), vec3(p1.way.y, -p1.way.x, 0)
        local v0, v1 = along[i] / SWEEP_UV_METRES, along[i + 1] / SWEEP_UV_METRES
        for j = 1, n do
            local o0, o1 = outline[j], outline[j % n + 1]
            local dx, dz = o1[1] - o0[1], o1[2] - o0[2]
            local len = math.sqrt(dx * dx + dz * dz)
            if len > 1e-6 then
                -- the edge's outward normal (a counterclockwise outline : (dz, -dx))
                local nx, nz = dz / len, -dx / len
                local n0, n1 = r0 * nx + up * nz, r1 * nx + up * nz
                local u0, u1 = round[j] / SWEEP_UV_METRES, round[j + 1] / SWEEP_UV_METRES
                local a = vert(s, at(p0, o0), n0, u0, v0)
                local b = vert(s, at(p0, o1), n0, u1, v0)
                local c = vert(s, at(p1, o1), n1, u1, v1)
                local d = vert(s, at(p1, o0), n1, u0, v1)
                -- wound as the game's own procedural meshes are (util/trackBuilder/
                -- proceduralPrimitives.lua : clockwise seen from the side they face)
                tri(s, a, b, c)
                tri(s, a, c, d)
            end
        end
    end

    -- its two ends closed : a fan round the outline's middle (every profile is convex enough)
    local cx, cz = 0, 0
    for _, o in ipairs(outline) do cx, cz = cx + o[1], cz + o[2] end
    local centre = { cx / n, cz / n }
    for _, which in ipairs({ 1, #pts }) do
        local p = pts[which]
        local first = which == 1
        local segment = first and 0 or #pts - 2
        local s = sub(colours[(math.floor(segment / per) % #colours) + 1])
        local normal = first and -p.way or p.way
        local mid = vert(s, at(p, centre), normal, 0, 0)
        local corners = {}
        for j = 1, n do
            corners[j] = vert(s, at(p, outline[j]), normal, (outline[j][1] - centre[1]) / SWEEP_UV_METRES,
                (outline[j][2] - centre[2]) / SWEEP_UV_METRES)
        end
        for j = 1, n do
            local k = j % n + 1
            if first then tri(s, mid, corners[k], corners[j]) else tri(s, mid, corners[j], corners[k]) end
        end
    end

    local out = {}
    for _, colour in ipairs(order) do out[#out + 1] = subs[colour] end
    return out, origin
end

--- what a sweep's mesh is made from, to tell when it has to be made again
---@param e table
---@return string
local function sweepSignature(e)
    local parts = { tostring(e.profile), tostring(e.count), tostring(e.followGround ~= false) }
    for _, key in ipairs({ "a", "b", "mid" }) do
        local p = e[key]
        parts[#parts + 1] = type(p) == "table" and
            string.format("%.4f,%.4f,%.4f", tonumber(p.x) or 0, tonumber(p.y) or 0, tonumber(p.z) or 0) or "-"
    end
    for _, p in ipairs(M.lineNodes(e)) do
        parts[#parts + 1] = string.format("%.4f,%.4f,%.4f", p.x, p.y, p.z)
    end
    if type(e.heights) == "table" then
        for _, h in ipairs(e.heights) do parts[#parts + 1] = string.format("%.3f", tonumber(h) or 0) end
    end
    return table.concat(parts, "|")
end

--- the drawer's Curbs & walls tab : each profile with its name, category and colours
---@return table[]
function M.sweepsForUI()
    local tr = function(key) return beamjoy_lang and beamjoy_lang.translate(key) or key end
    return table.map(M.SWEEPS, function(s)
        local top = 0
        for _, o in ipairs(s.outline) do top = math.max(top, o[2]) end
        local width = 0
        for _, o in ipairs(s.outline) do width = math.max(width, math.abs(o[1]) * 2) end
        return {
            id = s.id,
            sweep = s.id,
            name = tr("beamjoy.props.sweeps.name." .. s.id),
            cat = s.cat,
            tags = s.tags,
            solid = true,
            stripe = s.stripe,
            swatch = table.map(s.colours, function(c) return (SWEEP_COLOURS[c] or SWEEP_COLOURS.concrete).css end),
            -- the drawer pictures it by its outline
            outline = s.outline,
            height = math.floor(top * 100 + .5) / 100,
            width = math.floor(width * 100 + .5) / 100,
        }
    end)
end

-- PAINTS (painted lines, direct request) --------------------------------------------------------
-- One DecalRoad along a line's path, made as the game's own procedural tracks make their painted
-- route (util/procTrack.lua : its fields set, its nodes given as "x y z width", then registered).
-- An entry :
--   { kind = "paint", paint, a, b, mid, count, width, followGround, heights, group }
-- `paint` one of M.PAINTS (a client without it skips the entry) ; `a`, `b`, `mid` its path, as a
-- line's ; `count` the segments it's cut into (about one every PAINT_STEP metres, set by the
-- editor : paintCount), a node at each of their `count + 1` ends (sweepPoints, as a curb's) ;
-- `width` metres (the paint's own when none) ; `heights` its nodes' ground heights, as a curb's.
--
-- Only the game's own materials that every map has : the common road paint
-- (art/shapes/common/decalroads) and the race paint (art/shapes/race), whose textures are all in
-- the shared /assets (a map's copies are links to them). Drawn over objects too (a map's mesh
-- roads, a bridge), out of the AI's road network (`drivability` -1), never saved with the map, and
-- under nothing of the map's own paint but over its asphalt (a low `renderPriority` draws last).
-- No collision : never in the static collision, nothing to rebuild for it.

-- metres a segment, about (a node at each end : the decal's own spline smooths between them)
local PAINT_STEP = 2
-- drawn after (over) the map's own decal roads, a tyre mark under a painted line
local PAINT_PRIORITY, MARK_PRIORITY = 1, 2

-- `texLength` : metres of road one repeat of its texture covers ; `aspect` instead : that many
-- times its width (a pattern that keeps its proportions, the checkers square). `look` pictures it
-- in the drawer : a pattern its CSS draws (propDrawer paintPicture) and its colours
M.PAINTS = {
    { id = "white", cat = "lines", tags = "white line edge road marking solid", material = "m_line_white",
        width = .2, texLength = 7, look = { pattern = "solid", colours = { "#f2f2ee" } } },
    { id = "yellow", cat = "lines", tags = "yellow line edge road marking solid", material = "m_line_yellow",
        width = .2, texLength = 8, look = { pattern = "solid", colours = { "#efc94a" } } },
    { id = "whiteDashed", cat = "lines", tags = "white line dashed broken road marking",
        material = "m_line_white_discontinue", width = .2, texLength = 7,
        look = { pattern = "dashed", colours = { "#f2f2ee" } } },
    { id = "whiteDashedShort", cat = "lines", tags = "white line dashed short broken road marking",
        material = "line_dashed_short", width = .2, texLength = 3,
        look = { pattern = "dashedShort", colours = { "#f2f2ee" } } },
    { id = "yellowDouble", cat = "lines", tags = "yellow double line centre center road marking",
        material = "m_line_yellow_double", width = .4, texLength = 10,
        look = { pattern = "double", colours = { "#efc94a" } } },
    { id = "hazard", cat = "lines", tags = "yellow black hazard stripes warning", material = "line_yellowblack",
        width = .6, texLength = 12, look = { pattern = "hazard", colours = { "#f2c418", "#1c1c1c" } } },
    { id = "chevrons", cat = "lines", tags = "white chevrons arrows marking", material = "road_chevrons",
        width = 1, texLength = 7, look = { pattern = "chevron", colours = { "#f2f2ee" } } },
    { id = "zebra", cat = "lines", tags = "white zebra crossing stripes grid box", material = "crossing_white",
        width = 3, texLength = 6, look = { pattern = "zebra", colours = { "#f2f2ee" } } },
    { id = "checkered", cat = "race", tags = "checkered chequered start finish line flag black white",
        material = "checkered_line", width = 1, aspect = 5, look = { pattern = "checker", colours = { "#f2f2ee" } } },
    { id = "chalk", cat = "race", tags = "chalk line white marking", material = "ChaulkLine", width = .35,
        texLength = 3, look = { pattern = "soft", colours = { "#efebef" } } },
    { id = "sprayWhite", cat = "race", tags = "spray paint white marking", material = "spraypaint_mark",
        width = .3, aspect = 4, look = { pattern = "soft", colours = { "#f7f7f7" } } },
    { id = "sprayOrange", cat = "race", tags = "spray paint orange marking", material = "spraypaint_mark_orange",
        width = .3, aspect = 4, look = { pattern = "soft", colours = { "#ff8100" } } },
    { id = "sprayGreen", cat = "race", tags = "spray paint green marking", material = "spraypaint_mark_green",
        width = .3, aspect = 4, look = { pattern = "soft", colours = { "#22b04c" } } },
    { id = "rubber", cat = "marks", tags = "rubber racing line tyre tire marks skid asphalt",
        material = "road_rubber_double", width = 3.5, texLength = 6, priority = MARK_PRIORITY,
        look = { pattern = "tread", colours = { "#2a2a2a" } } },
    { id = "dirtTracks", cat = "marks", tags = "dirt tyre tire tracks ruts gravel", material = "m_dirt_tiretracks",
        width = 3.5, texLength = 16, priority = MARK_PRIORITY, look = { pattern = "tread", colours = { "#5b4631" } } },
}
M.PAINT_CATEGORIES = { "lines", "race", "marks" }

local paintById = {}
for _, s in ipairs(M.PAINTS) do paintById[s.id] = s end

---@param id string
---@return table?
function M.getPaint(id) return type(id) == "string" and paintById[id] or nil end

--- how many segments a painted line's path is cut into : about one every PAINT_STEP metres
---@param entry table
---@return integer
function M.paintCount(entry)
    return math.max(1, math.min(math.ceil(M.lineLength(entry) / PAINT_STEP - 1e-6), M.PAINT_MAX_SEGMENTS))
end

--- a curb's, a wall's or a painted line's segments for its length (sweepCount, paintCount)
---@param entry table
---@return integer
function M.pathCount(entry)
    if entry.kind == "paint" then return M.paintCount(entry) end
    return M.sweepCount(entry)
end

--- a painted line's width (metres) : its own, else its paint's
---@param entry table
---@return number
function M.paintWidth(entry)
    local paint = paintById[entry.paint]
    local w = tonumber(entry.width) or (paint and paint.width) or .2
    if w ~= w then w = .2 end
    return math.max(M.PAINT_WIDTH_MIN, math.min(w, M.PAINT_WIDTH_MAX))
end

--- a painted line's decal made : nil when its paint isn't known or its path is too short
---@param entry table
---@return table? obj a DecalRoad
local function makePaint(entry)
    local paint = paintById[entry.paint]
    if not paint then return nil end
    local count = math.max(1, math.min(math.floor(tonumber(entry.count) or 1), M.PAINT_MAX_SEGMENTS))
    local pts = M.sweepPoints({ a = entry.a, b = entry.b, mid = entry.mid, nodes = entry.nodes, count = count,
        followGround = entry.followGround, heights = entry.heights })
    if #pts < 2 then return nil end
    local width = M.paintWidth(entry)
    local texLength = paint.aspect and width * paint.aspect or paint.texLength or 5
    local road = createObject("DecalRoad")
    road.canSave = false
    road:setField("material", 0, paint.material)
    road:setField("textureLength", 0, string.format("%.3f", math.max(.1, texLength)))
    road:setField("renderPriority", 0, tostring(paint.priority or PAINT_PRIORITY))
    road:setField("improvedSpline", 0, "1")
    road:setField("overObjects", 0, "1")
    road:setField("drivability", 0, "-1")
    road:setField("startEndFade", 0, "0 0")
    for _, p in ipairs(pts) do
        road:setField("Node", 0, string.format("%f %f %f %f", p.pos.x, p.pos.y, p.pos.z, width))
    end
    road:registerObject("")
    if not simObjectExists(road) then return nil end
    return road
end

--- what a painted line's decal is made from, to tell when it has to be made again
---@param e table
---@return string
local function paintSignature(e)
    local parts = { tostring(e.paint), tostring(e.count), tostring(e.followGround ~= false),
        string.format("%.3f", M.paintWidth(e)) }
    for _, key in ipairs({ "a", "b", "mid" }) do
        local p = e[key]
        parts[#parts + 1] = type(p) == "table" and
            string.format("%.4f,%.4f,%.4f", tonumber(p.x) or 0, tonumber(p.y) or 0, tonumber(p.z) or 0) or "-"
    end
    for _, p in ipairs(M.lineNodes(e)) do
        parts[#parts + 1] = string.format("%.4f,%.4f,%.4f", p.x, p.y, p.z)
    end
    if type(e.heights) == "table" then
        for _, h in ipairs(e.heights) do parts[#parts + 1] = string.format("%.3f", tonumber(h) or 0) end
    end
    return table.concat(parts, "|")
end

--- the drawer's Paint tab : each paint with its name, category, width and look
---@return table[]
function M.paintsForUI()
    local tr = function(key) return beamjoy_lang and beamjoy_lang.translate(key) or key end
    return table.map(M.PAINTS, function(s)
        return {
            id = s.id,
            paint = s.id,
            name = tr("beamjoy.props.paints.name." .. s.id),
            cat = s.cat,
            tags = s.tags,
            solid = false,
            width = s.width,
            pattern = s.look.pattern,
            colours = s.look.colours,
        }
    end)
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
        if next(set.pending) or next(set.sweepPending) then return true end
    end
    return false
end

--- the static collision rebuilt now. A set that mustn't be solid (the editor's preview, the placing
--- ghost) has its curbs and walls taken out of the scene first and made again right after : a
--- ProceduralMesh can't be told to stay out of it (see SWEEPS)
local function reloadCollision()
    for _, set in pairs(M.sets) do
        if not set.collision then
            for i, s in pairs(set.sweeps) do
                -- a painted line (PAINTS) has no collision : it stays
                if s.obj and s.solid then
                    if simObjectExists(s.obj) then s.obj:delete() end
                    s.obj = nil
                    set.sweepPending[i] = true
                end
            end
        end
    end
    be:reloadCollision()
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

--- lamp heads lit at once, at most, the nearest the camera : each is a light the renderer pays for
--- every frame
local MAX_LIGHTS = 40
-- ms between two looks at the time of day and at which heads are nearest
local LAMP_CHECK_MS = 500
-- a lit head keeps its light against an unlit one up to this much nearer (no handing a light back
-- and forth between two heads about as far)
local KEEP_BIAS = .85

--- the lamps : a mesh's file name (lower case, without its extension : every map's copy of it) -> how
--- it shines. `heads` : where its lights are, mesh units from its origin, each {x, y, z} or
--- {x, y, z, aimX, aimY, aimZ} ; a `spot` lamp's shine along that aim (else `aim`, else down) in a cone
--- (`inner` / `outer`, degrees) `range` metres long, the others all round, `range` their radius.
--- `brightness` is the engine's own render value (the light's intensity follows from it), `color`
--- its colour. `glow` (0-255) : what the maps light the mesh's bulb with at night (their
--- `nightEmissiveColor`), black by day as theirs are ; none for a bulb whose material glows all the
--- time, on the maps too. `always` : lit day and night (the showroom's).
--- Taken from where the maps put their lights on these meshes (the same offsets on every copy), and
--- for those no map lights (lamp1, s_wh_lamp, substation_lightning, deco_lightpoles, the red and
--- green marker lights) from where the mesh's bulb glows (its emissive texture under its UVs)
local DOWN = { 0, 0, -1 }
local LAMPS = {
    -- West Coast's street lights (the first three are /art/shapes/objects/ too)
    pole_light_single = { spot = true, heads = { { 5.19, 0, 12.33 } }, range = 45, inner = 25, outer = 150,
        color = { .742, .881, 1 }, brightness = 1, glow = { 189, 225, 255 } },
    pole_light_double = { spot = true, heads = { { 5.2, 0, 12.31 }, { -5.2, 0, 12.31 } }, range = 70, inner = 25,
        outer = 160, color = { .778, 1, .896 }, brightness = .69, glow = { 218, 254, 255 } },
    pole_light_bridge = { spot = true, heads = { { 5.2, 0, 12.33 } }, range = 45, inner = 25, outer = 150,
        color = { 1, .268, .007 }, brightness = 1, glow = { 255, 95, 17 } },
    light_city = { spot = true, heads = { { 0, 2.53, .47 } }, range = 45, inner = 25, outer = 150,
        color = { 1, .281, .008 }, brightness = 1, glow = { 255, 101, 21 } },
    ceiling_light_tunnel = { spot = true, heads = { { .02, .01, -.33 } }, range = 12, inner = 80, outer = 160,
        color = { 1, .562, .263 }, brightness = 2.2, glow = { 255, 54, 0 } },
    -- floodlight masts : two banks facing either side, the tall one's single bank
    pole_lighting1 = { spot = true, heads = { { .8, 1.75, 18.8, .45, .62, -.64 }, { .8, -1.75, 18.8, .45, -.62, -.64 } },
        range = 80, inner = 50, outer = 130, color = { .906, .89, 1 }, brightness = 1, glow = { 231, 227, 255 } },
    pole_lighting2 = { spot = true, heads = { { 1.8, 0, 34.23, .86, 0, -.51 } }, range = 150, inner = 25, outer = 140,
        color = { .855, .996, 1 }, brightness = 5, glow = { 218, 254, 255 } },
    -- the airport's mast (Italy's, and West Coast's copy) : four of its eight lamps, as the maps light it
    italy_airport_lightpole = { spot = true, heads = { { 1.3, 0, 30, .5, 0, -.87 }, { -1.3, 0, 30, -.5, 0, -.87 },
        { 0, 1.23, 30, 0, .5, -.87 }, { 0, -1.23, 30, 0, -.5, -.87 } }, range = 55, inner = 75, outer = 130,
        color = { .774, .807, 1 }, brightness = 1, glow = { 195, 205, 255 } },
    -- four floodlights at its corners, facing out
    substation_lightning = { spot = true, heads = { { -.77, .63, 10.17, -.66, .66, -.36 },
        { .77, -.63, 10.17, .66, -.66, -.36 }, { -.77, -.64, 10.17, -.66, -.66, -.36 },
        { .76, .65, 10.17, .66, .66, -.36 } }, range = 40, inner = 40, outer = 120, color = { .906, .89, 1 },
        brightness = 1, glow = { 231, 227, 255 } },
    -- a lantern, glazed both sides
    lamp1 = { heads = { { 0, 0, 7.53 } }, range = 15, color = { 1, .85, .6 }, brightness = .6, glow = { 255, 200, 140 } },
    -- West Coast's warehouse and garage lights (their bulbs glow all the time)
    s_wh_lamp = { spot = true, heads = { { 0, 0, 5.62 } }, range = 20, inner = 40, outer = 140, color = { 1, .9, .75 },
        brightness = 1.5 },
    s_long_light_hanging = { spot = true, heads = { { 0, .1, -.25 } }, range = 8, inner = 60, outer = 170,
        color = { .986, .833, .614 }, brightness = 2 },
    s_long_light_roof = { spot = true, heads = { { 0, .03, -.85 } }, range = 45, inner = 25, outer = 150,
        color = { .742, .881, 1 }, brightness = .22 },
    s_small_light_hanging = { spot = true, heads = { { 0, .04, -.06 } }, range = 20, inner = 80, outer = 170,
        color = { .742, .881, 1 }, brightness = .24 },
    -- the garage's ceiling light, its lit tube (the prefab "on") : lit day and night as there
    s_ceiling_light_light_on = { spot = true, heads = { { 0, 0, -.05 } }, range = 20, inner = 70, outer = 130,
        color = { 1, .951, .865 }, brightness = 2, always = true },
    -- West Coast's road marker lights (the map lights its amber ones only)
    marker_light_amber = { heads = { { 0, 0, .17 } }, range = 10, color = { 1, .498, 0 }, brightness = .1 },
    marker_light_red = { heads = { { 0, 0, .14 } }, range = 10, color = { 1, .05, .02 }, brightness = .1 },
    marker_light_green = { heads = { { 0, 0, .14 } }, range = 10, color = { .1, 1, .2 }, brightness = .1 },
    -- Driver Training's poles
    s_light_pole = { spot = true, heads = { { 0, -.42, 11.92 } }, range = 20, inner = 45, outer = 100,
        color = { .674, .74, 1 }, brightness = 2.4 },
    s_light_pole_high_mast = { spot = true, heads = { { 0, -.44, 17.89, .02, -.65, -.75 },
        { -.39, .21, 17.89, -.56, .31, -.75 }, { .39, .21, 17.89, .58, .27, -.75 } }, range = 80, inner = 45,
        outer = 95, color = { 1, .944, .993 }, brightness = 2.4 },
    -- Industrial's yard light
    big_lightpole = { spot = true, heads = { { 0, .5, 9.2, 0, .75, -.66 } }, range = 75, inner = 40, outer = 120,
        color = { 1, .908, .728 }, brightness = .6 },
    -- East Coast's lamppost (Italy's and Johnson Valley's too)
    eca_lamppost = { heads = { { 2.7, .02, 7.86 } }, range = 20, color = { 1, .915, .798 }, brightness = .7 },
    -- Utah's
    ut_lampost_camp = { heads = { { 0, .69, 3.52 } }, range = 15, color = { 1, .882, .439 }, brightness = .6 },
    -- the string of bulbs between two poles : three lights along its eleven bulbs
    deco_lightpoles = { heads = { { 0, -2.6, 3.82 }, { 0, -5.71, 3.42 }, { 0, -9.04, 3.52 } }, range = 6,
        color = { 1, .85, .55 }, brightness = .25 },
    deco_lightpoles_a = { heads = { { .05, -2.6, 3.63 }, { .05, -5.71, 3.07 }, { .05, -9.04, 3.29 } }, range = 6,
        color = { 1, .85, .55 }, brightness = .25 },
    -- Small Island's wind vane : the red beacon on its top
    si_wind_vane = { heads = { { 0, -.12, 6.24 } }, range = 4, color = { 1, 0, 0 }, brightness = .5 },
    -- the showroom's panel and neon tubes : lit day and night, as there (and glowing all the time)
    lightplane_a = { heads = { { 0, 0, .5 } }, range = 12, color = { 1, 1, 1 }, brightness = 2, always = true },
    lighttube_a = { heads = { { 0, 0, 0 } }, range = 6, color = { 1, 1, 1 }, brightness = .5, always = true },
    lighttube_b = { heads = { { 0, 0, 1.12 } }, range = 6, color = { 1, 1, 1 }, brightness = .5, always = true },
    -- the catalog's flood lights, facing their own +X
    s_standinglight_01 = { spot = true, heads = { { .1, 0, 1.51, 1, 0, -.25 } }, range = 30, inner = 40, outer = 110,
        color = { .9, .95, 1 }, brightness = 1.2 },
    s_spotlight_01 = { spot = true, heads = { { .06, 0, .03, 1, 0, .15 } }, range = 30, inner = 20, outer = 70,
        color = { .9, .95, 1 }, brightness = 1.2 },
}

---@param shape string?
---@return table? the mesh's lamp (LAMPS), nil for one that isn't
function M.lampForShape(shape)
    if type(shape) ~= "string" then return nil end
    local file = shape:match("([^/\\]+)$")
    return file and LAMPS[(file:lower():gsub("%.c?dae$", ""))] or nil
end

---@type table<userdata, {spec: table, p: table, lights: table<integer, userdata>}> a lamp prop's object -> it
local lamps = {}
---@type boolean? the bulbs' state (nil : not looked yet)
local lampsNight = nil
local nextLampCheck = 0

---@return boolean the map's own night lights are on (or would be)
local function isNight()
    local ok, state = pcall(function() return core_environment.getLightState() end)
    return ok and type(state) == "table" and state.isNight == true
end

--- where a head is and, a spot's, the way it shines
---@param spec table a LAMPS entry
---@param i integer the head
---@param p table an expand() entry
---@return vec3 pos, vec3? aim
local function headOf(spec, i, p)
    local h = spec.heads[i]
    local s = p.scales or vec3(p.scale, p.scale, p.scale)
    local pos = p.pos + p.rot * vec3(h[1] * s.x, h[2] * s.y, h[3] * s.z)
    if not spec.spot then return pos, nil end
    local a = h[4] and h or spec.aim or DOWN
    local o = h[4] and 3 or 0
    return pos, (p.rot * vec3(a[o + 1], a[o + 2], a[o + 3])):normalized()
end

---@param light userdata
---@param spec table
---@param i integer
---@param p table
local function placeLight(light, spec, i, p)
    local pos, aim = headOf(spec, i, p)
    local rot = quat(0, 0, 0, 1)
    if aim then
        -- a SpotLight shines along its own +Y
        rot = quatFromDir(aim, math.abs(aim.z) > .98 and (p.rot * vec3(0, 1, 0)) or vec3(0, 0, 1))
    end
    light:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
end

---@param spec table
---@return userdata?
local function createLight(spec)
    local light = createObject(spec.spot and "SpotLight" or "PointLight")
    if not light then return nil end
    light.canSave = false
    local c = spec.color
    light:setField("color", 0, string.format("%g %g %g 1", c[1], c[2], c[3]))
    light:setField(spec.spot and "range" or "radius", 0, tostring(spec.range))
    if spec.spot then
        light:setField("innerAngle", 0, tostring(spec.inner))
        light:setField("outerAngle", 0, tostring(spec.outer))
    end
    light:setField("brightness", 0, tostring(spec.brightness))
    -- the shadow maps' room is the map's own lamps'
    light:setField("castShadows", 0, "false")
    light:registerObject("")
    if not simObjectExists(light) then return nil end
    group():addObject(light)
    return light
end

--- the bulb lit at night, dark by day, as the maps' are
---@param obj userdata
---@param l table
---@param night boolean
local function setGlow(obj, l, night)
    local g = l.spec.glow
    if not g or not simObjectExists(obj) then return end
    obj:setField("instanceColor", 0, night and string.format("%g %g %g 1", g[1] / 255, g[2] / 255, g[3] / 255) or "0 0 0 1")
    if obj.updateInstanceRenderData then obj:updateInstanceRenderData() end
end

---@param l table
local function deleteLights(l)
    for i, light in pairs(l.lights) do
        if simObjectExists(light) then light:delete() end
        l.lights[i] = nil
    end
end

---@param obj userdata the prop's own object
---@param p table an expand() entry
local function addLamp(obj, p)
    local spec = M.lampForShape(p.shape)
    if not spec then return end
    local l = { spec = spec, p = p, lights = {} }
    lamps[obj] = l
    if lampsNight == nil then lampsNight = isNight() end
    setGlow(obj, l, lampsNight)
    -- its lights are handed out on the next update
    nextLampCheck = 0
end

---@param obj userdata
local function removeLamp(obj)
    local l = obj and lamps[obj]
    if not l then return end
    lamps[obj] = nil
    deleteLights(l)
end

--- every lit lamp's heads, the nearest the camera first, get a light, MAX_LIGHTS at most ; the
--- bulbs follow dusk and dawn
local function updateLamps()
    if not next(lamps) then
        lampsNight = nil
        return
    end
    local now = GetCurrentTimeMillis()
    if now < nextLampCheck then return end
    nextLampCheck = now + LAMP_CHECK_MS
    local night = isNight()
    local nightChanged = night ~= lampsNight
    lampsNight = night
    local cam = core_camera and core_camera.getPosition()
    local heads = {}
    for obj, l in pairs(lamps) do
        if not simObjectExists(obj) then
            -- gone some other way
            lamps[obj] = nil
            deleteLights(l)
        else
            if nightChanged then setGlow(obj, l, night) end
            if night or l.spec.always then
                for i in ipairs(l.spec.heads) do
                    local d = cam and headOf(l.spec, i, l.p):squaredDistance(cam) or 0
                    if l.lights[i] then d = d * KEEP_BIAS * KEEP_BIAS end
                    heads[#heads + 1] = { l = l, i = i, d = d }
                end
            end
        end
    end
    table.sort(heads, function(a, b) return a.d < b.d end)
    local wanted = {}
    for k = 1, math.min(#heads, MAX_LIGHTS) do
        local h = heads[k]
        wanted[h.l] = wanted[h.l] or {}
        wanted[h.l][h.i] = true
    end
    for _, l in pairs(lamps) do
        for i, light in pairs(l.lights) do
            if not (wanted[l] and wanted[l][i]) then
                if simObjectExists(light) then light:delete() end
                l.lights[i] = nil
            end
        end
    end
    for l, is in pairs(wanted) do
        for i in pairs(is) do
            if not l.lights[i] then
                local light = createLight(l.spec)
                if light then
                    placeLight(light, l.spec, i, l.p)
                    l.lights[i] = light
                end
            end
        end
    end
end

local function place(obj, p)
    obj:setPosRot(p.pos.x, p.pos.y, p.pos.z, p.rot.x, p.rot.y, p.rot.z, p.rot.w)
    obj:setScale(p.scales or vec3(p.scale, p.scale, p.scale))
    local l = lamps[obj]
    if l then
        l.p = p
        for i, light in pairs(l.lights) do
            if simObjectExists(light) then placeLight(light, l.spec, i, p) end
        end
    end
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
    addLamp(obj, p)
    return obj
end

local function deleteObject(obj)
    removeLamp(obj)
    if obj and simObjectExists(obj) then obj:delete() end
end

--- a curb's or a wall's mesh made (again) on its object, stood at its first point
---@param obj table a ProceduralMesh
---@param entry table
---@return boolean
local function buildSweep(obj, entry)
    local ok, meshes, origin = pcall(M.sweepMeshes, entry)
    if not ok then
        LogWarn("beamjoy_props: a curb or a wall couldn't be built: " .. tostring(meshes))
        return false
    end
    if not meshes or #meshes == 0 then return false end
    obj:createMesh({ meshes })
    obj:setPosition(origin)
    return true
end

---@param entry table a sweep or a paint entry
---@return table? obj
local function spawnSweep(entry)
    if entry.kind == "paint" then
        local road = makePaint(entry)
        if road then group():addObject(road) end
        return road
    end
    if not M.getSweep(entry.profile) then return nil end
    local obj = createObject("ProceduralMesh")
    obj.canSave = false
    obj:registerObject("")
    if not simObjectExists(obj) then return nil end
    group():addObject(obj)
    if not buildSweep(obj, entry) then
        obj:delete()
        return nil
    end
    return obj
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
    set = set or { objects = {}, entries = {}, collision = false, pending = {}, sweeps = {}, sweepPending = {} }
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

    -- the curbs and walls (SWEEPS) and the painted lines (PAINTS) : one object each, by the
    -- entry's place in the list, made again only when something of it changed. A curb's mesh is
    -- made again in place on its object (no new object while an end is dragged) ; a painted line's
    -- decal is made anew at once (cheap, and an end dragged keeps up with the mouse). New ones are
    -- created in onUpdate, with the props. Only the curbs and walls change the static collision
    local kept = {}
    for i, e in ipairs(type(props) == "table" and props or {}) do
        local kind = type(e) == "table" and (
            (e.kind == "sweep" and M.getSweep(e.profile) and "sweep") or
            (e.kind == "paint" and M.getPaint(e.paint) and "paint")) or nil
        if kind then
            kept[i] = true
            local solid = kind == "sweep"
            local sig = kind .. ":" .. (solid and sweepSignature(e) or paintSignature(e))
            local s = set.sweeps[i]
            if not s or s.sig ~= sig then
                local obj = s and s.obj
                if solid and s and s.solid and obj and simObjectExists(obj) and buildSweep(obj, e) then
                    set.sweeps[i] = { obj = obj, sig = sig, entry = e, solid = true }
                else
                    if obj and simObjectExists(obj) then obj:delete() end
                    local made = not solid and obj and spawnSweep(e) or nil
                    set.sweeps[i] = { obj = made, sig = sig, entry = e, solid = solid }
                    if not made then set.sweepPending[i] = true end
                end
                if solid or (s and s.solid) then changed = true end
            else
                s.entry = e
            end
        end
    end
    for i, s in pairs(set.sweeps) do
        if not kept[i] then
            if s.obj and simObjectExists(s.obj) then s.obj:delete() end
            set.sweeps[i], set.sweepPending[i] = nil, nil
            if s.solid then changed = true end
        end
    end

    local wasSolid = set.collision
    set.collision = collision
    set.signature = opts.signature
    if wasSolid and not collision then
        -- solid props going (the editor's collision switch off for an edit) : rebuilt now, not
        -- once things settle, or the gizmo's snapping and cars meet their old collision while the
        -- edit goes on. Their objects are already deleted, the new ones aren't solid (its curbs
        -- and walls are taken out for the rebuild)
        reloadCollision()
    elseif (changed and collision) or collision ~= wasSolid then
        scheduleCollisionReload()
    end
end

---@param key string
function M.hide(key)
    local set = M.sets[key]
    if not set then return end
    for _, obj in pairs(set.objects) do deleteObject(obj) end
    local sweeps = false
    for _, s in pairs(set.sweeps) do
        if s.obj and simObjectExists(s.obj) then s.obj:delete() end
        sweeps = sweeps or s.solid == true
    end
    if set.collision and (#set.entries > 0 or sweeps) then scheduleCollisionReload() end
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
        for i in pairs(set.sweepPending) do
            if spawned > 0 and (os.clock() - started) * 1000 >= M.SPAWN_BUDGET_MS then return true end
            set.sweepPending[i] = nil
            local s = set.sweeps[i]
            if s and not s.obj then s.obj = spawnSweep(s.entry) end
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
        reloadCollision()
    end
end

-- SYNC -----------------------------------------------------------------------------------------
-- The activity's props, one set ("activity") : the race or arena being edited (a preview, no
-- collision unless the editor's collision switch is on), else the race, Hunter, Infected or Derby
-- game you're in or watching, from its lobby until it ends. Only one of those at a time.

local propEditor = require("ge/extensions/beamjoy/ui/propEditor")
local SET = "activity"

--- the game you're in or watching that has props : its props and what identifies them (the game,
--- and the arena's data as last received : an arena saved meanwhile shows its new props)
---@return table[]? props, string? signature
local function sessionProps()
    local function own(list)
        return type(list) == "table" and #list > 0 and list or nil
    end
    local runner = beamjoy_raceRunner
    local session = runner and (runner.session or runner.spectatingSession)
    if session and beamjoy_races then
        local race = table.find(beamjoy_races.data, function(r) return r.id == session.raceId end)
        local list = race and own(race.props)
        if list then return list, string.format("race:%s:%s", session.id, race.id) end
        return nil
    end
    runner = beamjoy_hunterRunner
    session = runner and (runner.session or runner.spectatingSession)
    if session then
        local list = beamjoy_hunter and beamjoy_hunter.data and own(beamjoy_hunter.data.props)
        if list then return list, string.format("hunter:%s:%s", session.id, tostring(list)) end
        return nil
    end
    runner = beamjoy_infectedRunner
    session = runner and (runner.session or runner.spectatingSession)
    if session then
        local list = beamjoy_infected and beamjoy_infected.data and own(beamjoy_infected.data.props)
        if list then return list, string.format("infected:%s:%s", session.id, tostring(list)) end
        return nil
    end
    runner = beamjoy_derbyRunner
    session = runner and (runner.session or runner.spectatingSession)
    if session and beamjoy_derby then
        local arena = table.find(beamjoy_derby.data or {}, function(a) return a.id == session.arenaId end)
        local list = arena and own(arena.props)
        if list then return list, string.format("derby:%s:%s", session.id, tostring(list)) end
    end
    return nil
end

local function sync()
    local editing = propEditor.editing()
    if editing then
        local signature = "editor:" .. tostring(propEditor.propsRevision)
        if propEditor.testCollision then
            -- solid as when played (direct request) : any edit turns it back off
            -- (propEditor.onEdit), so none ever moves or goes while its collision is built
            return M.show(SET, editing, { signature = signature .. ":solid" })
        end
        -- no collision at all, not only no reload : a reload asked by anything else (the game's
        -- own set leaving solid props behind as the editor opens, another set) took the editor's
        -- props into the static collision, and one deleted afterwards stayed there, invisible,
        -- for cars and the editor's own ground snapping until the race was next started (direct
        -- report). Clicks pick props by their handles (propEditor.pick), not collision
        return M.show(SET, editing, { signature = signature, collision = false, collisionType = "None" })
    end
    local list, signature = sessionProps()
    if list then return M.show(SET, list, { signature = signature }) end
    M.hide(SET)
end

-- games are joined, watched and left through each runner's own updates : looked at again every so
-- often too, as well as on the hooks below (a spectated game fires none of its own)
local SYNC_EVERY_MS = 1000
local nextSync = 0

local function cleanup()
    hideAll()
    M.sets = {}
    -- any lamp whose prop went some other way
    for _, l in pairs(lamps) do deleteLights(l) end
    lamps, lampsNight = {}, nil
    -- a new map, its own materials : looked at again
    materialDirs, materialShapes, mapped, sharedDone = {}, {}, nil, {}
    if collisionReloadAt then
        collisionReloadAt = nil
        if be then reloadCollision() end
    end
end

M.onUpdate = function()
    onUpdate()
    local now = GetCurrentTimeMillis()
    if now >= nextSync then
        nextSync = now + SYNC_EVERY_MS
        sync()
    end
end
M.onBJRaceMarkersRefresh = sync
M.onBJEditorPropsRefresh = sync
M.onBJScenarioChanged = sync
M.onBJHunterArenaChanged = sync
M.onBJInfectedArenaChanged = sync
M.onBJDerbyArenasChanged = sync
M.onServerLeave = cleanup
M.onClientEndMission = cleanup
M.onExtensionUnloaded = cleanup
M.onPreExit = cleanup

return M
