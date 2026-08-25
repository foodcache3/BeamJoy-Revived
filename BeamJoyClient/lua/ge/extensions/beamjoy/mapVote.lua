local M = {
    ---@type {active: boolean, creatorName: string?, targetMap: string?, targetMapLabel: string?,
    ---endsAt: integer?, threshold: integer?, voterNames: string[]}
    data = { active = false },
}

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)

    beamjoy_communications_ui.addHandler("BJMapVoteJoin", function()
        beamjoy_communications.send("voteMapVote")
    end)
    beamjoy_communications_ui.addHandler("BJMapVoteCancel", function()
        beamjoy_communications.send("voteMapStop")
    end)
    -- UI entry point for starting a vote directly (picking from the map list), alongside the
    -- pre-existing "/votemap <name>" chat command. Same underlying server-side start(), just an
    -- exact map key instead of free-text fuzzy matching, since a picker offers real options
    ---@param mapName string exact key
    beamjoy_communications_ui.addHandler("BJMapVoteStart", function(mapName)
        beamjoy_communications.send("voteMapStart", mapName)
    end)
end

local function retrieveCache(caches)
    if caches.mapVote then
        M.data = caches.mapVote
        beamjoy_communications_ui.send("BJMapVoteUpdate", M.data)
    end
end

M.onInit = onInit
M.retrieveCache = retrieveCache

return M
