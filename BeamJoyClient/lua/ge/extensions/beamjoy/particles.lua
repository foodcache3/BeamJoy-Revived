--- Settings > Vehicle > "Dust and particles" : how much of the dust, gravel, mud, sparks and tyre
--- smoke vehicles throw up, 0-100 %. The game has no setting for it ; every one of those comes from
--- a single vehicle-Lua function, `particlefilter.nodeCollision` (called by the vehicle's main.lua
--- on each ground contact, looked up on the table every call), so each vehicle gets that function
--- wrapped to let through only the chosen share of emissions. 100 % puts the original back. Fire,
--- glass and breaking-part effects are separate and untouched. Applies to every vehicle on this
--- client (own, other players', traffic), and is this player's own preference, kept across servers.

local M = {
    ---@type number 0-100, the value last applied
    amount = 100,
}

--- the vehicle-Lua side : idempotent, keeps the original function aside the first time
---@param amount number 0-100
---@return string
local function command(amount)
    local share = math.max(0, math.min(1, amount / 100))
    return string.format([[
if particlefilter then
    local orig = particlefilter.__bjOrig or particlefilter.nodeCollision
    particlefilter.__bjOrig = orig
    local share = %.3f
    if share >= 0.999 then
        particlefilter.nodeCollision = orig
    elseif share <= 0 then
        particlefilter.nodeCollision = function() end
    else
        local random = math.random
        particlefilter.nodeCollision = function(p)
            if random() < share then orig(p) end
        end
    end
end]], share)
end

local function applyAll()
    be:queueAllObjectLua(command(M.amount))
end

--- the settings page shows what's saved on this PC (the page's own defaults otherwise stand in)
local function sendToUI()
    beamjoy_communications_ui.send("BJUserSettings", {
        vehicle = {
            automaticLights = localStorage.get(localStorage.GLOBAL_VALUES.AUTOMATIC_LIGHTS) == true,
            particleAmount = M.amount,
        },
    })
end

local function onInit()
    M.amount = tonumber(localStorage.get(localStorage.GLOBAL_VALUES.PARTICLE_AMOUNT)) or 100
    beamjoy_communications_ui.addHandler("BJRequestVehicleSettings", sendToUI)
    beamjoy_communications_ui.addHandler("BJUserSettings", function(newSettings)
        local amount = type(newSettings) == "table" and type(newSettings.vehicle) == "table" and
            tonumber(newSettings.vehicle.particleAmount)
        if not amount then return end
        amount = math.max(0, math.min(100, math.floor(amount + .5)))
        if amount == M.amount then return end
        M.amount = amount
        localStorage.set(localStorage.GLOBAL_VALUES.PARTICLE_AMOUNT, amount)
        applyAll()
    end)
    -- vehicles already in the world when the mod loads
    if M.amount < 100 then applyAll() end
end

--- every vehicle spawned on this client, including other players' and traffic
---@param vid integer
local function onVehicleSpawned(vid)
    if M.amount >= 100 then return end
    local veh = be:getObjectByID(vid)
    if veh then veh:queueLuaCommand(command(M.amount)) end
end

M.onInit = onInit
M.onVehicleSpawned = onVehicleSpawned
-- a vehicle's Lua reloads on a full reset (Ctrl+R) and loses the wrapper : put it back
M.onVehicleResetted = onVehicleSpawned

return M
