--- Shared "a reset becomes an in-place recovery" policy, used by Infected and deliveries so the
--- rule lives in one place instead of being copied per mode.
---
--- While a mode holds a claim (and its `active()` says it applies right now) :
---   - reset_physics / reset_all_physics (R, the quick-access Reset, anything calling the global
---     resetGameplay) are denied and replaced with an in-place recovery : the vehicle is put back
---     on its wheels where it stands. The mode's optional `allowRecovery()` gate can refuse even
---     that (Infected's speed / relock gate).
---   - every reset that moves the vehicle somewhere else or rebuilds it is denied : reload,
---     recover-to-alt/last-road, go home, drop at camera.
---   - `blockRepair` claims (vehicle deliveries) keep the damage through all of it : the in-place
---     recovery is keepDamageRecovery, the pause menu's Repair is denied, and hold-to-rewind
---     (which repairs when released) becomes the same keep-damage recovery. Other claims use the
---     vehicle's own recovery.recoverInPlace(), which repairs like recover_vehicle does.
--- Flip-upright stays available (it never repairs).
---
--- Works at `beamjoy_inputs`' own onBJRequestCurrentVehicleReset hook, which every reset path
--- already funnels through (inputs.lua overrides the global resetGameplay, reload, drop-at-camera
--- and the pause menu's safeTeleport repair/flip), so nothing global needs swapping here.

---@class BJRecoveryClaim
---@field active (fun(): boolean)? whether the claim applies right now (default: always)
---@field allowRecovery (fun(): boolean)? whether the in-place recovery may run right now
---@field vehicle (fun(): BJVehicle?)? the vehicle to recover (default: the current own vehicle)
---@field blockRepair boolean?

local M = {
    dependencies = { "beamjoy_inputs", "beamjoy_vehicles" },

    --- input actions that reposition or rebuild the vehicle, for a mode's own restriction list.
    --- switch_next/previous_vehicle also close the pause menu's Reset/Repair/Clone/Delete panel
    --- (see raceRunner.lua's restriction comments).
    REPOSITION_ACTIONS = {
        "recover_vehicle_alt", "recover_to_last_road", "loadHome", "reload_vehicle", "recoverVehicle",
        "dropPlayerAtCamera", "dropPlayerAtCameraNoReset",
        "switch_next_vehicle", "switch_previous_vehicle",
    },

    ---@type table<string, BJRecoveryClaim>
    claims = {},
}

---@param name string
---@param claim BJRecoveryClaim
local function claim(name, claim_)
    M.claims[name] = claim_ or {}
end

---@param name string
local function release(name)
    M.claims[name] = nil
end

--- upright where it stands, keeping its damage (blockRepair claims). The vehicle's own recovery.recoverInPlace() is NOT
--- this : it calls spawn.safeTeleport without a resetVehicle flag, which defaults to true and
--- repairs. This is career's flip-in-place call (career/modules/playerDriving.lua), resetVehicle
--- false, on the unwrapped safeTeleport so inputs.lua's repair/flip fingerprint doesn't re-hook it.
---@param veh userdata
local function keepDamageRecovery(veh)
    local teleport = beamjoy_inputs.baseFunctions and beamjoy_inputs.baseFunctions.extensions.spawn.safeTeleport or
        spawn.safeTeleport
    local dir = veh:getDirectionVector()
    dir = vec3(dir.x, dir.y, 0)
    if dir:length() < 1e-4 then dir = vec3(0, 1, 0) end
    teleport(veh, veh:getPosition(), quatFromDir(dir:normalized()), nil, nil, nil, nil, false)
end

---@return BJRecoveryClaim?
local function activeClaim()
    for _, c in pairs(M.claims) do
        if not c.active or c.active() then return c end
    end
end

---@return boolean
local function isActive()
    return activeClaim() ~= nil
end

---@param req RequestAuthorization
---@param resetType string
local function onBJRequestCurrentVehicleReset(req, resetType)
    local c = activeClaim()
    if not c then return end
    local R = beamjoy_inputs.RESET
    if resetType == R.RESET_PHYSICS or resetType == R.RESET_ALL_PHYSICS or
        (resetType == R.RECOVER and c.blockRepair) then
        req.state = false
        if not c.allowRecovery or c.allowRecovery() then
            local veh = c.vehicle and c.vehicle() or beamjoy_vehicles.getCurrentOwn()
            if veh and veh.veh then
                if c.blockRepair then
                    keepDamageRecovery(veh.veh)
                else
                    veh.veh:queueLuaCommand("recovery.recoverInPlace()")
                end
            end
        end
    elseif resetType == R.RELOAD or resetType == R.RELOAD_ALL or resetType == R.RECOVER_ALT or
        resetType == R.RECOVER_LAST_ROAD or resetType == R.LOAD_HOME or
        resetType == R.DROP_AT_CAMERA or resetType == R.DROP_AT_CAMERA_NO_RESET then
        req.state = false
    elseif resetType == R.REPAIR and c.blockRepair then
        req.state = false
    end
end

M.claim = claim
M.release = release
M.isActive = isActive
M.onBJRequestCurrentVehicleReset = onBJRequestCurrentVehicleReset

return M
