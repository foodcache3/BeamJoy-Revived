--- In-world live waypoint marker for the fugitive during an active Hunter round: a single tall
--- column beacon at their own current target waypoint, visible from a distance to guide them there.
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

local COLUMN_COLOR, SPHERE_COLOR, TEXT_COLOR, TEXT_BG_COLOR

-- tall enough to be visible well over most terrain/foliage from a distance, matching BJI's own
-- "big column" convention per direct request
local COLUMN_HEIGHT = 60
local COLUMN_RADIUS = .6

local M = {
    dependencies = { "shape", "beamjoy_hunterRunner" },

    visible = false,
}

local function onInit()
    -- BJColor() is only ever called from inside functions elsewhere in this codebase (never at
    -- file-top-level), since it's a "game util" global not guaranteed initialized yet while
    -- extensions are still being loaded, same reasoning raceMarkers.lua's own onInit gives
    COLUMN_COLOR = BJColor(1, .8, 0, .5)
    SPHERE_COLOR = BJColor(1, .8, 0, .85)
    TEXT_COLOR = BJColor(1, 1, 1, .9)
    TEXT_BG_COLOR = BJColor(0, 0, 0, .4)
end

local function render()
    shape.reset()
    local hasContent = false

    local session = beamjoy_hunterRunner.session
    if session and session.state == "HUNT" and session.route then
        local selfName = MPConfig.getNickname()
        local participant = table.find(session.participants, function(p) return p.playerName == selfName end)
        if participant and participant.role == "hunted" and not participant.eliminated then
            local nextIndex = participant.waypointsReached + 1
            local waypoint = session.route[nextIndex]
            if waypoint then
                local pos = vec3(waypoint.pos.x, waypoint.pos.y, waypoint.pos.z)
                local top = pos + vec3(0, 0, COLUMN_HEIGHT)
                shape.addCylinder(pos, top, COLUMN_RADIUS, COLUMN_COLOR)
                shape.addSphere(top, 2, SPHERE_COLOR)
                shape.addText(string.format("Waypoint %d/%d", nextIndex, #session.route),
                    top + vec3(0, 0, 3), TEXT_COLOR, TEXT_BG_COLOR)
                hasContent = true
            end
        end
    end

    M.visible = hasContent
end

local function hide()
    shape.reset()
    M.visible = false
end

M.onInit = onInit
M.render = render
M.hide = hide

-- refresh hook, fired by beamjoy_hunterRunner on every session update: see the note at the top of
-- this file for why this rebuilds on change, not per frame
M.onBJHunterMarkersRefresh = render

return M
