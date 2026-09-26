--- Crews (services/crews.lua) : keeps your crew and the crew list for the main window's Crew
--- tab, relays its actions, and hands crew invites to the notification stack (beamjoy/notices.lua).
---
--- UI wire : BJCrewRequest -> BJCrew (your crew or nil) + BJCrewList ; BJCrewCreate(name),
--- BJCrewLeave, BJCrewJoin(crewId), BJCrewRequestReply(playerName, accept), BJCrewKick(playerName),
--- BJCrewPromote(playerName), BJCrewSetOpen(open), BJCrewInviteList -> BJCrewInviteList,
--- BJCrewInvite(playerID).

local M = {
    dependencies = { "beamjoy_communications", "beamjoy_communications_ui" },
    ---@type table? your crew, as services/crews.lua's statePayload
    crew = nil,
    ---@type table[] every crew's summary
    list = {},
}

local function push()
    beamjoy_communications_ui.send("BJCrew", M.crew)
    beamjoy_communications_ui.send("BJCrewList", M.list)
end

---@param crewId any
---@return boolean the crew still exists and has room
local function joinable(crewId)
    for _, c in ipairs(M.list) do
        if c.id == crewId then return c.count < c.max end
    end
    return false
end

local function relay(uiEvent, serverEvent)
    beamjoy_communications_ui.addHandler(uiEvent, function(...)
        beamjoy_communications.send(serverEvent, ...)
    end)
end

local function onInit()
    beamjoy_communications.addHandler("crewState", function(state)
        M.crew = type(state) == "table" and state or nil
        push()
    end)
    beamjoy_communications.addHandler("crewList", function(list)
        M.list = type(list) == "table" and list or {}
        push()
    end)
    beamjoy_communications.addHandler("crewInviteList", function(data)
        beamjoy_communications_ui.send("BJCrewInviteList", data)
    end)
    beamjoy_communications.addHandler("crewInvite", function(data)
        if beamjoy_notices then beamjoy_notices.crewInvite(data) end
    end)
    beamjoy_communications.addHandler("crewPulled", function(data)
        if beamjoy_notices then beamjoy_notices.crewPulled(data) end
    end)

    beamjoy_communications_ui.addHandler("BJCrewRequest", function()
        push()
        beamjoy_communications.send("crewStateRequest")
    end)
    relay("BJCrewCreate", "crewCreate")
    relay("BJCrewLeave", "crewLeave")
    relay("BJCrewJoin", "crewJoin")
    relay("BJCrewRequestReply", "crewRequestReply")
    relay("BJCrewKick", "crewKick")
    relay("BJCrewPromote", "crewPromote")
    relay("BJCrewSetOpen", "crewSetOpen")
    relay("BJCrewInviteList", "crewInviteList")
    relay("BJCrewInvite", "crewInvite")
end

--- answering a crew invite from the notification stack
---@param crewId any
---@param accept boolean
local function inviteReply(crewId, accept)
    beamjoy_communications.send("crewInviteReply", crewId, accept == true)
end

local function onBJClientReady()
    beamjoy_communications.send("crewStateRequest")
end

local function onServerLeave()
    M.crew = nil
    M.list = {}
end

M.onInit = onInit
M.onBJClientReady = onBJClientReady
M.onServerLeave = onServerLeave
M.joinable = joinable
M.inviteReply = inviteReply

return M
