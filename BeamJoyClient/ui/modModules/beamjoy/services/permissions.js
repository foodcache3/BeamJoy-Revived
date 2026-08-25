const M = {
    PERMISSIONS: {},

    data: {},
};
let parent;
M.init = function (beamjoyStore) {
    parent = beamjoyStore;
};

// self is populated by its own dedicated, always-unfiltered BJUpdateSelf push (players.js's
// `self`). The general players list (players.js's `players`, from BJUpdatePlayers) is trimmed
// per-recipient server-side (services/players.lua's onBJRequestCache only sends every field to
// staff/self, a reduced summary otherwise) and can also simply arrive later or lag a step behind
// a just-changed group, since it's a second, separate async push. Re-deriving the CURRENT player's
// own group by searching that list instead of trusting the dedicated `self` push was a real bug :
// on a fresh UI mount (e.g. reopening the Config window), `self` can already reflect a staff
// promotion while `players` still holds a stale pre-promotion copy for a beat, which read as
// "the Delete button flashes on for a frame, then disappears" once the general list's own update
// landed and this function re-ran against it. Checking another player (an explicit playerName
// argument that isn't self) still has to go through the general list; there's no separate direct
// channel for anyone else.
function getGroupName(playerName) {
    if (!playerName || playerName === parent.players.self.playerName) {
        return parent.players.self.group;
    }
    const player = parent.players.players.find((p) => p.playerName == playerName);
    return player ? player.group : null;
}

M.isStaff = function (playerName) {
    const group = parent.groups.getGroup(getGroupName(playerName));
    return !!(group && group.staff);
};

M.hasAllPermissions = function (playerName, ...permissions) {
    const groupName = getGroupName(playerName);
    const groupIndex = parent.groups.getGroupIndex(groupName);
    const group = typeof groupIndex === "number" ? parent.groups.data[groupIndex] : null;
    if (!group) return false;
    return permissions.every((permName) => {
        const permGroupIndex = parent.groups.getGroupIndex(M.data[permName]);
        return (
            typeof permGroupIndex === "number" &&
            (group.permissions.includes(permName) ||
                permGroupIndex <= groupIndex)
        );
    });
};

M.hasAnyPermission = function (playerName, ...permissions) {
    const groupName = getGroupName(playerName);
    const groupIndex = parent.groups.getGroupIndex(groupName);
    const group = typeof groupIndex === "number" ? parent.groups.data[groupIndex] : null;
    if (!group) return false;
    return permissions.some((permName) => {
        const permGroupIndex = parent.groups.getGroupIndex(M.data[permName]);
        return (
            typeof permGroupIndex === "number" &&
            (group.permissions.includes(permName) ||
                permGroupIndex <= groupIndex)
        );
    });
};

export default M;
