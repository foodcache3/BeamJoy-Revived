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

--- the colours tags are drawn in, read when they change instead of twice per tag per rendered
--- frame. localStorage.get() builds a closure, pcalls it against every stored key to find the one
--- it was handed, and then hands back a deep clone of the value : nothing at all on an event, real
--- money sixty times a second times every car on screen (see drawNametag). Our own clones, so
--- nothing else can see them ; still never written to, the draw copies out of them
local colors = {}
local function refreshColors()
    colors.playerText = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_PLAYER_TEXT)
    colors.playerBg = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_PLAYER_BG)
    colors.idleText = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_IDLE_TEXT)
    colors.idleBg = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_IDLE_BG)
    colors.specText = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_SPEC_TEXT)
    colors.specBg = localStorage.get(localStorage.GLOBAL_VALUES.NAMETAGS_COLOR_SPEC_BG)
end

local function updateState()
    refreshColors()
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
        playerColor = colors.playerText,
        playerBgColor = colors.playerBg,
        idleColor = colors.idleText,
        idleBgColor = colors.idleBg,
        specColor = colors.specText,
        specBgColor = colors.specBg,
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

---@param playerName string raw connection name : used as both the cache key and the identity
---this looks up against (self-check, and the login-nickname fallback below), never itself
---overridden by a chosen nickname - only the RENDERED text can be
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
    -- login workaround (see services/identity.lua's own doc comment): a player who's logged in
    -- with a chosen nickname is rendered by that instead of their raw, possibly-volatile BeamMP
    -- name, everywhere this function is the one building the rendered text - the vehicle's own
    -- real ownerName (used above for the self-check, and everywhere else in this file/codebase
    -- for identity comparisons) is completely untouched by this, this only changes what gets drawn
    local displayName = playerName
    local player = beamjoy_players.players[playerName]
    if player and player.displayName then
        displayName = player.displayName
    end
    if M.state.shortenNametags then
        M.tagNames[playerName] = string.sub(displayName, 1, M.state.nametagCharLimit)
        if M.tagNames[playerName] ~= displayName then
            M.tagNames[playerName] = M.tagNames[playerName] .. "..."
        end
    else
        M.tagNames[playerName] = displayName
    end
    return M.tagNames[playerName]
end

local function onNametagsSettingsChanged()
    -- a colour picked in the UI used to reach the next drawn frame because every drawn frame read
    -- it back out of localStorage. The cached copy takes its place here instead
    refreshColors()
    table.forEach(M.tagNames, function(_, playerName)
        updateTagName(tostring(playerName))
    end)
end

--- a player's data came again (direct report : a nickname chosen didn't reach the nametags, the
--- tag built with the raw name before it was kept) : their tag is built again next draw
---@param player table
local function onBJUpdatePlayer(player)
    if player and player.playerName then M.tagNames[player.playerName] = nil end
end

--- the two colour slots every tag is drawn in : filled here, handed to shape.Text (which reads
--- their four fields into a ColorF/ColorI and is done with them) and filled again by the next tag
local tagText = { r = 1, g = 1, b = 1, a = 1 }
local tagBg = { r = 0, g = 0, b = 0, a = 1 }

--- where the text goes, likewise reused : the position of the tag being drawn, then of each
--- spectator line under it (the debug drawer takes the point by value, exactly as the game's own
--- map.lua relies on when it walks its graph with one vector)
local tagPos = vec3()

--- " 42m", built once per whole metre rather than once per tag per frame : a distance is only ever
--- drawn rounded, so there are only ever as many of these as there are whole metres two cars on
--- the map can be apart - a few thousand very short strings at the very worst, and in practice the
--- handful of distances actually on screen
---@type table<integer, string>
local distSuffixes = {}

--- the forced colours of a fugitive's tag, built once : BJColor() is a table, a table of eight
--- closures and a metatable for it, eleven allocations a call, and these two are constants
local FUGITIVE_TEXT, FUGITIVE_BG = BJColor(), BJColor(1)

---@param out table the slot above
---@param src table? whatever colour was chosen for this tag
local function setColor(out, src)
    out.r, out.g, out.b = src and src.r or 0, src and src.g or 0, src and src.b or 0
end

--- whether this spectator's own name is drawn under the car they're watching
---@param specName string
---@param mpVeh BJVehicle
---@param cam string the active camera, read once for the frame
---@param self table? this client's own player, likewise
---@return boolean
local function drawsSpectator(specName, mpVeh, cam, self)
    return specName ~= mpVeh.ownerName and
        not replay.replayPlayers[specName] and
        (cam == camera.CAMERAS.FREE or not self or specName ~= self.playerName)
end

---@param mpVeh BJVehicle
---@param orig vec3
---@param cam string the active camera, read once for the whole frame instead of once per tag and
---once more per spectator line
---@param self table? this client's own player, read once for the frame the same way (and see
---updateTagName's comment: it can be nil for a moment right after connecting)
local function drawNametag(mpVeh, orig, cam, self)
    local pos = mpVeh.position
    if not pos then return end
    local textSrc, bgSrc
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
            textSrc, bgSrc = FUGITIVE_TEXT, FUGITIVE_BG
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
            textSrc, bgSrc = infTextColor, infBgColor
        end
        -- Derby : a player who's out keeps a greyed tag over their wreck
        local isOut, derbyTextColor, derbyBgColor = beamjoy_derbyRunner.derbyNametagColor(mpVeh)
        if isOut then
            textSrc, bgSrc = derbyTextColor, derbyBgColor
        end
        -- a player chased by police players : the traffic fugitive's colors, name kept
        if beamjoy_playerPursuit and beamjoy_playerPursuit.isFugitiveVid(mpVeh.vid) then
            textSrc, bgSrc = FUGITIVE_TEXT, FUGITIVE_BG
        end
    end

    local dist = math.round(orig:distance(pos) or 0)
    local distSuffix = ""
    if M.state.nameTagShowDistance then
        if dist > 10 then
            distSuffix = distSuffixes[dist]
            if not distSuffix then
                distSuffix = string.format(" %dm", dist)
                distSuffixes[dist] = distSuffix
            end
        end
    end

    local alpha = 1
    if M.state.nameTagFadeEnabled then
        alpha = math.scale(dist, M.state.nameTagFadeDistance, 0, 0, 1, true)
        if cam ~= camera.CAMERAS.FREE and M.state.nameTagFadeInvert then
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
        textSrc, bgSrc = colors.playerText, colors.playerBg
    elseif not textSrc then
        textSrc, bgSrc = colors.idleText, colors.idleBg
    end
    setColor(tagText, textSrc)
    setColor(tagBg, bgSrc)
    tagText.a = alpha
    tagBg.a = alpha / 2

    tagPos:set(pos.x, pos.y, pos.z + mpVeh.height)
    shape.Text(distSuffix == "" and tag or tag .. distSuffix, tagPos, tagText, tagBg, false,
        M.state.nameTagsHideBehindObjects)

    if M.state.showSpectators then
        -- plain loops, for the same reason the "draw all" loop below is one : this was a pcall'd
        -- closure per spectator to filter them, a whole new table (plus a metatable for it) to hold
        -- the result, another closure to walk it, and :length() on top - a closure again, and a
        -- reduce over the list, per spectator line. Per car, per rendered frame
        local specs = mpVeh.spectators
        local count = 0
        for specName in pairs(specs) do
            if drawsSpectator(specName, mpVeh, cam, self) then count = count + 1 end
        end
        if count > 0 then
            -- the step between lines is the drawn count's, as it always was, not the whole list's
            local step = math.max(mpVeh.height / count, .3)
            setColor(tagText, colors.specText)
            setColor(tagBg, colors.specBg)
            tagText.a = alpha
            tagBg.a = alpha / 2
            for specName in pairs(specs) do
                if drawsSpectator(specName, mpVeh, cam, self) then
                    tagPos.z = tagPos.z - step
                    shape.Text(M.tagNames[specName] or updateTagName(tostring(specName)),
                        tagPos, tagText, tagBg, false, M.state.nameTagsHideBehindObjects)
                end
            end
        end
    end
end

--- a tag a game mode keeps hidden from this viewer, whichever way it would be drawn (the
--- "draw all" loop or the Alt hover below : real bug, hovering used to show it anyway)
---@param v BJVehicle
---@return boolean
local function isHiddenByMode(v)
    -- Hunter mode: the currently-hunted fugitive's real nametag is suppressed for every OTHER
    -- client through the countdown and until a reveal trigger fires (proximity /
    -- near-final-waypoint / post-reset, see hunterRunner.lua's own isHiddenFugitiveVehicle). Never
    -- hidden on the fugitive's own client, which already doesn't see its own tag while driving.
    if beamjoy_hunterRunner.isHiddenFugitiveVehicle(v) then return true end
    -- A race phase run with the other racers hidden (hideOthers, qualifying on an empty track) :
    -- their cars aren't drawn at all for this racer, so a tag floating where one would be would
    -- give away exactly what the rule is there to take away
    if beamjoy_raceRunner.isHiddenRacerVehicle(v) then return true end
    -- Infected mode, host-configurable (hideInfectedNametags, default off): an infected
    -- participant's whole nametag is hidden from a SURVIVOR viewer specifically (see
    -- infectedRunner.lua's own isHiddenInfectedVehicle for the exact scope) - staff/spectators/
    -- other infected still see it normally.
    return beamjoy_infectedRunner.isHiddenInfectedVehicle(v)
end

local ctxt, veh, mpVeh, ray
--- the point distances are measured from this frame, written into rather than replaced
local frameOrig = vec3()
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
    -- the active camera and this client's own player, read once for the whole frame and handed
    -- down : every drawn tag used to ask for both again, and once more per spectator line
    local cam = camera.getCamera()
    local self = beamjoy_players.getSelf()
    -- where the camera is, or the car it's attached to, as three numbers into the one vector :
    -- camera.getPositionRotation() and getVehiclePositionRotation() both hand back a fresh vector
    -- plus two more that nothing here reads, every frame
    if ctxt.mpVeh and ctxt.camera ~= camera.CAMERAS.FREE then
        beamjoy_vehicles.writeVehiclePosition(ctxt.mpVeh.veh, frameOrig)
    else
        frameOrig:set(core_camera.getPositionXYZ())
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
                if include and isHiddenByMode(v) then
                    include = false
                end
            end
            if include then
                drawn[vid] = true
                -- getVehicle refreshes this very table's position and spectators and hands it
                -- straight back, so there's nothing to look up twice and nothing to fall back to
                drawNametag(beamjoy_vehicles.getVehicle(vid) or v, frameOrig, cam, self)
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
                drawNametag(beamjoy_vehicles.getVehicle(vid) or v, frameOrig, cam, self)
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
        if mpVeh and isHiddenByMode(mpVeh) then
            lastHoverVid = nil
        elseif mpVeh then
            drawn[lastHoverVid] = true
            drawNametag(mpVeh, frameOrig, cam, self)
        else
            lastHoverVid = nil
        end
    end
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate
M.onNametagsSettingsChanged = onNametagsSettingsChanged
M.onBJUpdatePlayer = onBJUpdatePlayer
M.onUpdate = onUpdate

return M
