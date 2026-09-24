const M = {
    self: {
        playerID: 0,
        playerName: "",
        group: "default",
        currentVehicle: null,
    },
    players: [],
    // Client-local only (see players.lua's own pushDeletedVehiclePlayers doc comment): playerName
    // -> true for every player this client's own BeamMP layer currently remembers as having a
    // deleted vehicle. Never server-synced, unlike everything else on `players` - drives the
    // "Queue deleted vehicles" button's visibility (see player-line/app.js).
    deletedVehiclePlayers: {},
};
let parent;
M.init = function (beamjoyStore) {
    parent = beamjoyStore;
};

function parse() {
    M.players = M.players.sort((a, b) => {
        return a.playerName
            .toLocaleLowerCase()
            .localeCompare(b.playerName.toLocaleLowerCase());
    });
    M.players.forEach((p) => {
        p.vehicles = Object.values(p.vehicles).sort((a, b) => {
            return a.vehicleID - b.vehicleID;
        });
    });
}

M.set = function (players) {
    M.players = players;
    parse();
};

M.updatePlayer = function (playerName, data) {
    let found = false;
    M.players.forEach((p, i) => {
        if (found) return;
        if (p.playerName == playerName) {
            if (data) {
                M.players[i] = data;
            } else {
                M.players.splice(i, 1);
            }
            found = true;
        }
    });
    if (data && !found) M.players.push(data);
    parse();
    if (M.self.playerName == playerName) {
        // self update
        M.self = M.players.find((p) => p.playerName == playerName);
    }
};

export default M;
