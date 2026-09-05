local M = {
    dependencies = {
        "beamjoy_communications_ui"
    },
    state = {},

    ---@type table<string, string>
    tagNames = {},

    ---@type table<integer, boolean> vid -> true, for trailers currently attached to a vehicle
    towedTrailerVids = {},
}

local function updateState()
    local state = {
        hideNameTags = settings.getValue("hideNameTags", false),
        showSpectators = settings.getValue("showSpectators", true),
        nameTagsHideBehindObjects = settings.getValue("nameTagsHideBehindObjects", false),
        nameTagFadeEnabled = settings.getValue("nameTagFadeEnabled", true),
        nameTagFadeDistance = settings.getValue("nameTagFadeDistance", 40),
        nameTagFadeInvert = settings.getValue("nameTagFadeInvert", false),
        nameTagDontFullyHide = settings.getValue("nameTagDontFullyHide", true),
        shortenNametags = settings.getValue("shortenNametags", false),
        nametagCharLimit = settings.getValue("nametagCharLimit", 50),
        nameTagShowDistance = settings.getValue("nameTagShowDistance", true),
        playerColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_PLAYER_TEXT),
        playerBgColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_PLAYER_BG),
        idleColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_IDLE_TEXT),
        idleBgColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_IDLE_BG),
        specColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_SPEC_TEXT),
        specBgColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_SPEC_BG),
    }
    if not table.compare(M.state, state) then
        M.state = state
        beamjoy_communications_ui.send("BJNametagsState", M.state)
        extensions.hook("onNametagsSettingsChanged")
    end
end

local function onInit()
    updateState()

    beamjoy_communications_ui.addHandler("BJRequestNametagsState", function()
        beamjoy_communications_ui.send("BJNametagsState", M.state)
    end)
    beamjoy_communications_ui.addHandler("BJToggleNametagsHideState", function(newState)
        if newState == nil then newState = not M.state.hideNameTags end
        settings.setValue("hideNameTags", newState)
        M.state.hideNameTags = newState
        beamjoy_communications_ui.send("BJNametagsState", M.state)
    end)
    beamjoy_communications_ui.addHandler("BJUpdateNametagsState", function(newState)
        for k in pairs(newState) do
            if M.state[k] ~= nil then
                settings.setValue(k, newState[k])
            end
        end
    end)
    beamjoy_communications_ui.addHandler("BJUserSettings", function(newSettings)
        -- TODO check why color change does not update on the fly ?
        if not table.compare(M.state, newSettings.nametags) then
            settings.setValue("hideNameTags", newSettings.nametags.hideNameTags)
            settings.setValue("showSpectators", newSettings.nametags.showSpectators)
            settings.setValue("nameTagsHideBehindObjects", newSettings.nametags.nameTagsHideBehindObjects)
            settings.setValue("nameTagFadeEnabled", newSettings.nametags.nameTagFadeEnabled)
            settings.setValue("nameTagFadeDistance", newSettings.nametags.nameTagFadeDistance)
            settings.setValue("nameTagFadeInvert", newSettings.nametags.nameTagFadeInvert)
            settings.setValue("nameTagDontFullyHide", newSettings.nametags.nameTagDontFullyHide)
            settings.setValue("shortenNametags", newSettings.nametags.shortenNametags)
            settings.setValue("nametagCharLimit", newSettings.nametags.nametagCharLimit)
            settings.setValue("nameTagShowDistance", newSettings.nametags.nameTagShowDistance)
            localStorage.set(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_PLAYER_TEXT, newSettings.nametags.playerColor)
            localStorage.set(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_PLAYER_BG, newSettings.nametags.playerBgColor)
            localStorage.set(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_IDLE_TEXT, newSettings.nametags.idleColor)
            localStorage.set(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_IDLE_BG, newSettings.nametags.idleBgColor)
            localStorage.set(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_SPEC_TEXT, newSettings.nametags.specColor)
            localStorage.set(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_SPEC_BG, newSettings.nametags.specBgColor)

            extensions.hook("onNametagsSettingsChanged")
        end
    end)
end

---@param v BJVehicle
local function _isTowingVehicle(v)
    return not table.includes({
        beamjoy_vehicles.TYPES.TRAILER,
        beamjoy_vehicles.TYPES.PROP
    }, v.type)
end

local function updateTowedTrailers()
    table.clear(M.towedTrailerVids)
    beamjoy_vehicles.vehicles:forEach(function(v) ---@param v BJVehicle
        if _isTowingVehicle(v) then
            table.forEach(beamjoy_vehicles.getAttachedTrailers(v.vid), function(avid)
                M.towedTrailerVids[avid] = true
            end)
        end
    end)
end

local function onSlowUpdate()
    updateState()
    if not M.state.hideNameTags then
        updateTowedTrailers()
    end
end

---@param playerName string
---@return string
local function updateTagName(playerName)
    -- getSelf() is nil for a short window right after connecting, before the server's player-list
    -- push has landed (M.players[MPConfig.getNickname()] isn't populated yet), while nametags for
    -- OTHER players' vehicles can already be drawing every frame. Treat "self not loaded yet" as
    -- "not self" rather than indexing nil, which used to spam a FATAL LUA ERROR every frame during
    -- that window.
    local self = beamjoy_players.getSelf()
    if self and playerName == self.playerName then
        M.tagNames[playerName] = beamjoy_lang.translate("beamjoy.nametags.you")
        return M.tagNames[playerName]
    end
    if M.state.shortenNametags then
        M.tagNames[playerName] = string.sub(playerName, 1, M.state.nametagCharLimit)
        if M.tagNames[playerName] ~= playerName then
            M.tagNames[playerName] = M.tagNames[playerName] .. "..."
        end
    else
        M.tagNames[playerName] = playerName
    end
    return M.tagNames[playerName]
end

local function onNametagsSettingsChanged()
    table.forEach(M.tagNames, function(_, playerName)
        updateTagName(tostring(playerName))
    end)
end

---@param mpVeh BJVehicle
---@param orig vec3
local function drawNametag(mpVeh, orig)
    local textColor, bgColor
    -- see updateTagName's comment: getSelf() can be nil briefly right after connecting.
    local self = beamjoy_players.getSelf()
    local tag = M.tagNames[mpVeh.ownerName] or updateTagName(mpVeh.ownerName)
    if mpVeh.type == beamjoy_vehicles.TYPES.TRAILER then
        if self and mpVeh.ownerID == self.playerID then
            tag = beamjoy_lang.translate("beamjoy.nametags.yourTrailer")
        else
            tag = beamjoy_lang.translate("beamjoy.nametags.othersTrailer")
                :var({ playerName = mpVeh.ownerName })
        end
    elseif mpVeh.isAi then
        if beamjoy_pursuit.fugitives[mpVeh.vid] ~= nil and
            beamjoy_pursuit.isPolice then
            tag = beamjoy_lang.translate("beamjoy.pursuit.fugitiveTag")
            textColor = BJColor()
            bgColor = BJColor(1)
        else
            tag = string.format("[AI] %d-%d", mpVeh.ownerID, mpVeh.vid)
        end
    else
        -- Infected mode: a participant's nametag is unconditionally colored by their current role
        -- (green survivor / red infected by default, host-overridable), same forced-override
        -- mechanism as the Pursuit fugitive tag above, just for a normal (non-AI, non-trailer)
        -- player vehicle instead. A no-op (isParticipant false) whenever there's no active Infected
        -- round, or this vehicle's owner isn't currently a participant in it.
        local isParticipant, infTextColor, infBgColor = beamjoy_infectedRunner.infectedNametagColor(mpVeh)
        if isParticipant then
            textColor, bgColor = infTextColor, infBgColor
        end
    end

    local dist = math.round(orig:distance(mpVeh.position) or 0)
    local distSuffix = ""
    if M.state.nameTagShowDistance then
        if dist > 10 then
            distSuffix = string.format(" %dm", dist)
        end
    end

    local alpha = 1
    if M.state.nameTagFadeEnabled then
        alpha = math.scale(dist, M.state.nameTagFadeDistance, 0, 0, 1, true)
        if camera.getCamera() ~= camera.CAMERAS.FREE and M.state.nameTagFadeInvert then
            alpha = 1 - alpha
        end
        if M.state.nameTagDontFullyHide then
            alpha = math.clamp(alpha, .3)
        end
    end
    -- Hunter mode: an additional distance fade for hunter-role nametags specifically (see
    -- hunterRunner.lua's own hunterNametagAlpha), on top of whatever the generic fade above already
    -- did. A no-op (returns 1) whenever there's no active hunt or the arena's own
    -- hunterNametagFadeDistance is 0/unset, so this has zero effect outside Hunter.
    alpha = alpha * beamjoy_hunterRunner.hunterNametagAlpha(mpVeh, dist)

    if mpVeh.spectators[mpVeh.ownerName] then
        textColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_PLAYER_TEXT)
        bgColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_PLAYER_BG)
    elseif not textColor then
        textColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_IDLE_TEXT)
        bgColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_IDLE_BG)
    end
    textColor.a = alpha
    bgColor.a = alpha / 2

    local pos = mpVeh.position + vec3(0, 0, mpVeh.height)
    shape.Text(string.format("%s%s", tag, distSuffix), pos, textColor, bgColor, false,
        M.state.nameTagsHideBehindObjects)

    if M.state.showSpectators then
        mpVeh.spectators
            :filter(function(_, playerName)
                return playerName ~= mpVeh.ownerName and
                    not replay.replayPlayers[playerName] and
                    (camera.getCamera() == camera.CAMERAS.FREE or
                        not self or playerName ~= self.playerName)
            end)
            :forEach(function(_, specName, specs)
                specName = M.tagNames[specName] or
                    updateTagName(tostring(specName))

                textColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_SPEC_TEXT)
                bgColor = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_SPEC_BG)
                textColor.a = alpha
                bgColor.a = alpha / 2

                pos = pos + vec3(0, 0, -math.max(mpVeh.height / specs:length(), .3))
                shape.Text(specName, pos, textColor, bgColor,
                    false, M.state.nameTagsHideBehindObjects)
            end)
    end
end

local ctxt, orig, veh, mpVeh, ray
local drawn = {}
local lastHoverVid, lastHoverCheckMs = nil, 0
-- Confirmed via live profiling: the native cameraMouseRayCast() call below (used only for the
-- hover-reveal below) can cost several milliseconds on its own against a complex/modded vehicle,
-- dwarfing every other extension's entire onUpdate combined. A throttle alone (an earlier attempt)
-- just spreads that same cost out over time rather than removing it, which still reads as
-- intermittent stutter. Since this hover-reveal is a minor cosmetic nicety, not anything
-- gameplay-critical, it's now opt-in only: held Alt (unbound by default in BeamNG's own
-- keyboard.json) gates the raycast entirely, so idle/normal play never pays this cost at all.
-- Still throttled while Alt is actually held, so sweeping the camera across a crowd of vehicles
-- with Alt down doesn't reintroduce a steady per-frame cost either.
local HOVER_RAYCAST_THROTTLE_MS = 150
local altKeyIdx = ui_imgui.GetKeyIndex(ui_imgui.Key_ModAlt)
local function onUpdate()
    MPVehicleGE.hideNicknames(true)
    if replay.isOn() then return end

    ctxt = beamjoy_context.get()
    orig = camera.getPositionRotation()
    if ctxt.mpVeh and ctxt.camera ~= camera.CAMERAS.FREE then
        orig = beamjoy_vehicles.getVehiclePositionRotation(ctxt.mpVeh.veh)
    end

    table.clear(drawn)
    if not M.state.hideNameTags then
        -- draw all
        --
        -- Real bug: this used to be beamjoy_vehicles.vehicles:filter(fn):forEach(fn), i.e. two
        -- function-literal closures re-allocated fresh every single call (this runs every render
        -- frame), table.filter() building and returning a whole new intermediate array on top of
        -- that AND running every element through pcall(). Profiling during a real multiplayer
        -- session (more vehicles in play, several from traffic) showed this exact function as by
        -- far the single largest per-frame GC allocator in the whole mod, which reads as the
        -- "massive lag while moving the mouse" / intermittent stutter players reported : a bigger
        -- vehicle count means a bigger throwaway array plus more pcall'd closure calls, EVERY
        -- frame, and the resulting GC pressure is what actually stalls the frame. A plain loop
        -- with the exact same branching (isAi still short-circuits every later check, matching the
        -- old filter callback's early returns) does zero allocation here regardless of vehicle
        -- count.
        for vid, v in pairs(beamjoy_vehicles.vehicles) do ---@type integer, BJVehicle
            local include = true
            if v.isAi then
                include = DEBUG ~= nil or
                    (beamjoy_pursuit.fugitives[v.vid] ~= nil and beamjoy_pursuit.isPolice)
            else
                if v.type == beamjoy_vehicles.TYPES.PROP and
                    v.jbeam ~= beamjoy_vehicles.WALKING then
                    include = false
                elseif v.type == beamjoy_vehicles.TYPES.TRAILER then
                    -- see updateTagName's comment: getSelf() can be nil briefly right after connecting.
                    local self = beamjoy_players.getSelf()
                    if not self or v.ownerName ~= self.playerName then
                        include = false -- not own trailer
                    elseif M.towedTrailerVids[v.vid] then
                        include = false -- some vehicle is tracting it
                    end
                end
                if include and ctxt.camera ~= camera.CAMERAS.FREE and
                    ctxt.mpVeh and ctxt.mpVeh.isLocal and
                    ctxt.mpVeh.vid == v.vid then
                    include = false
                end
                if include and replay.replayPlayers[v.ownerName] then
                    include = false
                end
                -- Hunter mode: the currently-hunted fugitive's real nametag is suppressed for every
                -- OTHER client until a reveal trigger fires (proximity / near-final-waypoint /
                -- post-reset, see hunterRunner.lua's own isHiddenFugitiveVehicle). Never hidden on
                -- the fugitive's own client, which already doesn't see its own tag while driving
                -- normally via the ctxt.mpVeh check just above.
                if include and beamjoy_hunterRunner.isHiddenFugitiveVehicle(v) then
                    include = false
                end
            end
            if include then
                drawn[vid] = true
                drawNametag(beamjoy_vehicles.getVehicle(vid) or {}, orig)
            end
        end
    else
        -- Nametags globally disabled for this viewer, but Hunter's reveal mechanic is core
        -- gameplay (how a hunter actually spots the fugitive once revealed), not cosmetic. Don't
        -- let it silently stop working just because this player turned nametags off for unrelated
        -- reasons. Deliberately narrow: this is the ONLY tag force-drawn here, every other vehicle
        -- stays hidden exactly per the viewer's own preference. Same allocation-avoidance as above.
        for vid, v in pairs(beamjoy_vehicles.vehicles) do ---@type integer, BJVehicle
            if beamjoy_hunterRunner.isRevealedFugitiveVehicle(v) then
                drawn[vid] = true
                drawNametag(beamjoy_vehicles.getVehicle(vid) or {}, orig)
            end
        end
    end

    -- Mouse hover nametag: disableCollision()/enableCollision() here is purely to keep the
    -- player's own current vehicle out of the raycast hit-test (so you can't "hover" your own
    -- nametag). Done unconditionally for ANY current vehicle, including the unicycle while
    -- walking. That means every single frame spent walking around (not in free cam) toggles
    -- collision off-then-on on the walking character's own vehicle object, every frame, for as
    -- long as you're walking. A real suspect for the "unicycle randomly gets removed by local
    -- player" investigation (BeamMP's own client code, MPVehicleGE.lua, owns that object's
    -- lifecycle, and flapping its collision state every frame is exactly the kind of thing that
    -- could race whatever BeamMP does internally, which would explain why the delay before it
    -- happens is different every time rather than a fixed duration). Skipped for the walking
    -- vehicle specifically. Hovering your own nametag while walking is a non-issue either way,
    -- since there's nothing else drawing over it.
    if not ui_imgui.IsKeyDown(altKeyIdx) then
        lastHoverVid = nil
    elseif ctxt.now - lastHoverCheckMs >= HOVER_RAYCAST_THROTTLE_MS then
        lastHoverCheckMs = ctxt.now
        lastHoverVid = nil
        ray = nil
        if ctxt.camera ~= camera.CAMERAS.FREE and ctxt.mpVeh and
            ctxt.mpVeh.jbeam ~= beamjoy_vehicles.WALKING then
            ctxt.mpVeh.veh:disableCollision()
            ray = cameraMouseRayCast(true, ui_imgui.flags(SOTVehicle), 200)
            ctxt.mpVeh.veh:enableCollision()
        else
            ray = cameraMouseRayCast(true, ui_imgui.flags(SOTVehicle), 200)
        end
        if ray then
            ---@type NGVehicle?
            veh = ray.object
            if veh then
                mpVeh = beamjoy_vehicles.getVehicle(veh:getID())
                if mpVeh and not mpVeh.isAi and
                    (beamjoy_permissions.isStaff() or
                        mpVeh.type ~= beamjoy_vehicles.TYPES.PROP or
                        mpVeh.jbeam == beamjoy_vehicles.WALKING) then
                    lastHoverVid = veh:getID()
                end
            end
        end
    end
    if lastHoverVid and not drawn[lastHoverVid] then
        mpVeh = beamjoy_vehicles.getVehicle(lastHoverVid)
        if mpVeh then
            drawn[lastHoverVid] = true
            drawNametag(mpVeh, orig)
        else
            lastHoverVid = nil
        end
    end
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate
M.onNametagsSettingsChanged = onNametagsSettingsChanged
M.onUpdate = onUpdate

return M
