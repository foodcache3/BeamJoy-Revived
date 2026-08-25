local M = {
    ---@type {active: boolean, creatorName: string?, targetName: string?, secondsLeft: integer?,
    ---threshold: integer?, voterNames: string[]}
    data = { active = false },
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)

    beamjoy_communications_ui.addHandler("BJKickVoteJoin", function()
        beamjoy_communications.send("voteKickVote")
    end)
    beamjoy_communications_ui.addHandler("BJKickVoteCancel", function()
        beamjoy_communications.send("voteKickStop")
    end)
    -- UI entry point for starting a vote directly (picking from the connected-players list),
    -- alongside the pre-existing "/votekick <name>" chat command
    ---@param targetPlayerID integer
    beamjoy_communications_ui.addHandler("BJKickVoteStart", function(targetPlayerID)
        beamjoy_communications.send("voteKickStart", targetPlayerID)
    end)
end

local function retrieveCache(caches)
    if caches.kickVote then
        M.data = caches.kickVote
        beamjoy_communications_ui.send("BJKickVoteUpdate", M.data)
    end
end

M.onInit = onInit
M.retrieveCache = retrieveCache

return M
