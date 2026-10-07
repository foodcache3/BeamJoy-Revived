--- In-world live waypoint marker for the fugitive during an active Hunter round, at their own
--- current target waypoint : a ring round its reach radius (the derby sumo zone's look) and the
--- game's GPS-style beam, visible from a distance and gone within 50 m where the ring takes over.
--- The same waypoint is drawn on the minimap (onDrawOnMinimap).
--- Mirrors raceMarkers.lua's own render-on-change pattern (shape.reset() + rebuild the whole buffer
--- whenever the underlying data changes, not per-frame draw calls) exactly.
---
--- Deliberately narrower in scope than raceMarkers.lua: arena AUTHORING preview (hunter/prey spawns,
--- the full waypoint pool) is a separate concern already handled by ui/pointListEditor.lua while the
--- Config editor is open. This module only ever draws during an actual live HUNT, and only ever for
--- the fugitive's OWN client. session.route (and therefore the target this beacon points at) is
--- already stripped from every other participant/spectator's own copy of the session payload
--- server-side (see hunterGrid.lua's withHuntedPrivateFields), so hunters/spectators simply have
--- nothing here to ever draw; this module doesn't need its own extra privacy check on top of that.

local RING_COLOR

local M = {
    dependencies = { "shape", "beamjoy_hunterRunner" },

    visible = false,
    ---@type vec3? the waypoint drawn now, for the minimap
    target = nil,
}

local function onInit()
    -- BJColor() is only ever called from inside functions elsewhere in this codebase (never at
    -- file-top-level), since it's a "game util" global not guaranteed initialized yet while
    -- extensions are still being loaded, same reasoning raceMarkers.lua's own onInit gives
    RING_COLOR = BJColor(1, .8, 0)
end

local function render()
    shape.reset()
    M.target = nil

    local session = beamjoy_hunterRunner.session
    if session and session.state == "HUNT" and session.route then
        local selfName = MPConfig.getNickname()
        local participant = table.find(session.participants, function(p) return p.playerName == selfName end)
        if participant and participant.role == "hunted" and not participant.eliminated then
            local waypoint = session.route[participant.waypointsReached + 1]
            if waypoint then
                local pos = vec3(waypoint.pos.x, waypoint.pos.y, waypoint.pos.z)
                shape.addRing(pos, math.max(1, tonumber(waypoint.radius) or 5), RING_COLOR)
                shape.addBeam(pos)
                M.target = pos
            end
        end
    end

    M.visible = M.target ~= nil
end

local function hide()
    shape.reset()
    M.visible = false
    M.target = nil
end

local MINIMAP_FILL, MINIMAP_STROKE
--- the fugitive's next waypoint on the game's minimap (a pointer on its edge when off the map)
local function onDrawOnMinimap()
    if not M.target or not ui_apps_minimap_utils then return end
    MINIMAP_FILL = MINIMAP_FILL or color(255, 204, 0, 255)
    MINIMAP_STROKE = MINIMAP_STROKE or color(255, 255, 255, 192)
    ui_apps_minimap_utils.simpleCircleWithEdgePointer(M.target, MINIMAP_FILL, MINIMAP_STROKE)
end

M.onInit = onInit
M.render = render
M.hide = hide
M.onDrawOnMinimap = onDrawOnMinimap

-- refresh hook, fired by beamjoy_hunterRunner on every session update: see the note at the top of
-- this file for why this rebuilds on change, not per frame
M.onBJHunterMarkersRefresh = render

return M
