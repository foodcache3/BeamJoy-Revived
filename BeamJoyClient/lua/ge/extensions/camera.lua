local M = {
    preloadedDependencies = { "beamjoy_communications_ui" },
    dependencies = {},
    DEFAULT_FREECAM_FOV = 65,
    DEFAULT_FREECAM_SPEED = 30,
    CAMERAS = {
        ORBIT = "orbit",
        BIG_MAP = "bigMap",
        EXTERNAL = "external",
        DRIVER = "driver",
        PASSENGER = "passenger",
        FREE = "free",
    },

    forcedCameras = Table(),
    ---@type PosRot?
    forceFreeCamPosRot = nil,

    state = {
        smooth = false,
        fov = 65,
        speed = 70,
    }
}
AddPreloadedDependencies(M)

---@return string
local function getCamera()
    return core_camera.getActiveCamName()
end

---@param cameraName string
---@param withTransition boolean?
local function setCamera(cameraName, withTransition)
    if withTransition == nil then
        withTransition = true
    end

    core_camera.setByName(0, cameraName, withTransition)
    if M.NEED_RESET[cameraName] then
        core_camera.resetCamera(0)
    end
end

---@param keepOrientation boolean? default true
---@return vec3 pos, vec3 dir, vec3 up
local function getPositionRotation(keepOrientation)
    keepOrientation = keepOrientation ~= false
    local pos = core_camera.getPosition()
    local dir = core_camera.getForward() ---@type vec3
    local up ---@type vec3
    if not keepOrientation then
        dir.z = 0
        dir:normalize()
        up = vec3(0, 0, 1)
    else
        up = core_camera.getUp()
    end
    return pos, dir, up
end

---@param pos vec3?
---@param dir vec3?
local function setPositionRotation(pos, dir)
    if not pos then
        pos = M.getPositionRotation()
    end
    if not dir then
        dir = ({ M.getPositionRotation() })[2]
    end

    if pos and dir then
        if M.getCamera() ~= M.CAMERAS.FREE then
            M.toggleFreeCam()
        end
        local rotQ = quatFromDir(dir)
        core_camera.setPosRot(0, pos.x, pos.y, pos.z,
            rotQ.x, rotQ.y, rotQ.z, rotQ.w)
    end
end

---@return { pos: vec3, object: userdata, distance: number, face: integer, normal: vec3 }?
local function getWorldPositionFromCursor()
    local res = cameraMouseRayCast()
    if res and not (
            ui_imgui.IsAnyItemHovered() or
            ui_imgui.IsWindowHovered(ui_imgui.HoveredFlags_AnyWindow)) then
        local camPos = M.getPositionRotation()
        local pos = vec3(res.pos.x, res.pos.y, camPos.z + 1000)
        pos.z = be:getSurfaceHeightBelow(pos)
        return {
            pos = pos,
            distance = res.distance,
            face = res.face,
            normal = vec3(res.normal),
            object = res.object,
            origin = {
                pos = camPos,
                rot = vec3(pos - camPos):normalized(),
            }
        }
    end
end

---@return boolean isNowFreeCam
local function toggleFreeCam()
    commands.toggleCamera()
    return M.getCamera() == M.CAMERAS.FREE
end

---@param ... string cameraNames
local function forceCamera(...)
    M.forcedCameras:clear()
    M.forcedCameras:addAll({ ... }, true)
    if not M.forcedCameras:includes(M.getCamera()) then
        M.next()
    end
    -- todo update restrictions
end

---@param pos vec3
---@param rot vec3
local function forcePositionRotation(pos, rot)
    M.setPositionRotation(pos, rot)
    pos, rot = M.getPositionRotation()
    M.forceFreeCamPosRot = { pos = pos, rot = rot }
    -- todo update restrictions
end

local function stopForcedCameras()
    M.forcedCameras:clear()
    M.forceFreeCamPosRot = nil
    -- todo update restrictions
end

local function next()
    core_camera.setVehicleCameraByIndexOffset(0, 1)
end

---@return boolean
local function isFreeCamSmooth()
    local infos = core_camera.getGlobalCameras().free

    return infos.angularForce == 150 and
        infos.angularDrag == 2.5 and
        infos.mass == 10 and
        infos.translationForce == 600 and
        infos.translationDrag == 2
end

---@param state boolean
local function setFreeCamSmooth(state)
    core_camera.setSmoothedCam(0, state)
end

---@return number
local function getFOV()
    return core_camera.getFovDeg()
end

---@param deg number? 10-120
local function setFOV(deg)
    if not deg then
        deg = M.DEFAULT_FREECAM_FOV
    elseif type(deg) ~= "number" then
        return
    end

    core_camera.setFOV(0, math.clamp(deg, 10, 120))
end

---@return number
local function getSpeed()
    return core_camera.getSpeed()
end

---@param value number? 2-100
local function setSpeed(value)
    if not value then
        value = M.DEFAULT_FREECAM_SPEED
    elseif type(value) ~= "number" then
        return
    end

    core_camera.setSpeed(math.clamp(value, 2, 100))
end

local function onInit()
    InitPreloadedDependencies(M)
    M.state = {
        smooth = localStorage.get(localStorage.GLOBAL_VALUES.FREECAM_SMOOTH),
        fov = localStorage.get(localStorage.GLOBAL_VALUES.FREECAM_FOV),
        speed = localStorage.get(localStorage.GLOBAL_VALUES.FREECAM_SPEED),
    }

    if M.getCamera() == M.CAMERAS.FREE then
        if M.getFOV() ~= M.state.fov then
            M.setFOV(M.state.fov)
        end
        if M.getSpeed() ~= M.state.speed then
            M.setSpeed(M.state.speed)
        end
    end

    beamjoy_communications_ui.addHandler("BJUserSettings", function(newSettings)
        if M.state.smooth ~= newSettings.freecam.smooth then
            M.state.smooth = newSettings.freecam.smooth
            localStorage.set(localStorage.GLOBAL_VALUES.FREECAM_SMOOTH, M.state.smooth)
        end
        if M.state.fov ~= newSettings.freecam.fov then
            M.state.fov = newSettings.freecam.fov
            localStorage.set(localStorage.GLOBAL_VALUES.FREECAM_FOV, M.state.fov)
            if M.getCamera() == M.CAMERAS.FREE then
                M.setFOV(M.state.fov)
            end
        end
        if M.state.speed ~= newSettings.freecam.speed then
            M.state.speed = newSettings.freecam.speed
            localStorage.set(localStorage.GLOBAL_VALUES.FREECAM_SPEED, M.state.speed)
            if M.getCamera() == M.CAMERAS.FREE then
                M.setSpeed(M.state.speed)
            end
        end
    end)
end

---@param newCam string
local function onCameraModeChanged(newCam)
    if M.forcedCameras:length() > 0 and not M.forcedCameras:includes(newCam) then
        M.next()
    elseif M.forceFreeCamPosRot and M.getCamera() ~= M.CAMERAS.FREE then
        M.setPositionRotation(M.forceFreeCamPosRot.pos, M.forceFreeCamPosRot.rot)
    end
    if newCam == M.CAMERAS.FREE then
        M.setFOV(M.state.fov)
        M.setSpeed(M.state.speed)

        local veh = beamjoy_vehicles.getCurrentOwn()
        if veh and veh.jbeam == beamjoy_vehicles.WALKING then
            beamjoy_vehicles.delete(veh.vid)
        end
    else
        if newCam == M.CAMERAS.PASSENGER and
            beamjoy_vehicles.getCurrentOwn() then
            -- You can't be passenger in your own vehicle
            M.next()
        elseif newCam == M.CAMERAS.DRIVER and
            not beamjoy_vehicles.getCurrentOwn() then
            -- You can't be driver in another player vehicle
            M.next()
        end
    end
end

---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    if M.forcedCameras:length() > 0 then
        if not M.forcedCameras:includes(M.CAMERAS.FREE) or
            M.forcedCameras:length() == 1 then
            restrictions:addAll({
                "toggleCamera", "dropCameraAtPlayer"
            }, true)
        end
        if M.forcedCameras:length() == 1 then
            restrictions:removeAll({
                "camera_1", "camera_2", "camera_3", "camera_4",
                "camera_5", "camera_6", "camera_7", "camera_8",
                "camera_9", "camera_10", "switch_camera_next",
                "switch_camera_prev"
            }, true)
        end
    end
    if M.forceFreeCamPosRot then
        restrictions:addAll({
            "toggleCamera", "dropCameraAtPlayer", "camera_1",
            "camera_2", "camera_3", "camera_4", "camera_5",
            "camera_6", "camera_7", "camera_8", "camera_9",
            "camera_10", "center_camera", "look_back",
            "rotate_camera_down", "rotate_camera_horizontal",
            "rotate_camera_hz_mouse", "rotate_camera_left",
            "rotate_camera_right", "rotate_camera_up",
            "rotate_camera_vertical", "rotate_camera_vt_mouse",
            "switch_camera_next", "switch_camera_prev",
            "changeCameraSpeed", "movedown", "movefast",
            "moveup", "moveleft", "moveright", "moveforward",
            "movebackward", "rollAbs", "xAxisAbs", "yAxisAbs",
            "yawAbs", "zAxisAbs", "pitchAbs",
        }, true)
    end
end

local lastCam
local function onUpdate()
    local cam = M.getCamera()
    if lastCam ~= cam then
        onCameraModeChanged(cam)
        lastCam = cam
    end
    if cam == M.CAMERAS.FREE then
        if M.isFreeCamSmooth() ~= M.state.smooth then
            M.setFreeCamSmooth(M.state.smooth)
        end
        if M.getFOV() ~= M.state.fov then
            M.state.fov = M.getFOV()
            localStorage.set(localStorage.GLOBAL_VALUES.FREECAM_FOV, M.state.fov)
            beamjoy_communications_ui.send("BJUserCameraSettings", M.state)
        end
        if M.getSpeed() ~= M.state.speed then
            M.state.speed = M.getSpeed()
            localStorage.set(localStorage.GLOBAL_VALUES.FREECAM_SPEED, M.state.speed)
            beamjoy_communications_ui.send("BJUserCameraSettings", M.state)
        end
    end
end

---@param clickType string
---@param data onBJClickData
local function onBJClick(clickType, data)
    if clickType == "middle" and data.mpVeh and data.mpVeh.veh.playerUsable then
        beamjoy_vehicles.focusVehicle(data.mpVeh.vid)
    end
end

-- functions
M.getCamera = getCamera
M.setCamera = setCamera
M.getPositionRotation = getPositionRotation
M.setPositionRotation = setPositionRotation
M.getWorldPositionFromCursor = getWorldPositionFromCursor
M.setPositionRotation = setPositionRotation
M.toggleFreeCam = toggleFreeCam
M.forceCamera = forceCamera
M.forcePositionRotation = forcePositionRotation
M.stopForcedCameras = stopForcedCameras
M.next = next
M.isFreeCamSmooth = isFreeCamSmooth
M.setFreeCamSmooth = setFreeCamSmooth
M.getFOV = getFOV
M.setFOV = setFOV
M.getSpeed = getSpeed
M.setSpeed = setSpeed

-- hooks
M.onInit = onInit
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onUpdate = onUpdate
M.onBJClick = onBJClick

return M
