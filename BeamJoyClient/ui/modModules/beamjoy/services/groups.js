const M = {
    data: [],
    defaultGroups: [],
};
let parent;
M.init = function (beamjoyStore) {
    parent = beamjoyStore;
};

M.set = function (payload) {
    M.data = payload.groups;
    M.defaultGroups = payload.defaultGroups;
    M.data.forEach((group) => {
        group.permissions = Array.isArray(group.permissions)
            ? group.permissions
            : [];
    });
};
M.getPrevious = function (groupName) {
    const groupIndex = M.getGroupIndex(groupName);
    if (typeof groupIndex  !== "number") return;
    let prevName, prevLevel;
    M.data.forEach((cgroup, index) => {
        if (
            index < groupIndex &&
            (!prevLevel || index > prevLevel)
        ) {
            prevName = cgroup.name;
            prevLevel = index;
        }
    });
    return prevName;
};

M.getNext = function (groupName) {
    const groupIndex = M.getGroupIndex(groupName);
    if (typeof groupIndex  !== "number") return;
    let nextName, nextLevel;
    M.data.forEach((cgroup, index) => {
        if (
            index > groupIndex &&
            (!nextLevel || index < nextLevel)
        ) {
            nextName = cgroup.name;
            nextLevel = index;
        }
    });
    return nextName;
};

// case-insensitive, matching services/groups.lua's own getGroupIndex exactly. A player's stored
// `group` field and a group's registered `name` are supposed to always agree in case (setGroup
// re-stamps the canonical name on assignment), but this side staying case-SENSITIVE while the
// server side never was is a real, silent way for the two to drift out of sync (e.g. a DB record
// written before that normalization existed, or edited by hand) : the server would keep treating
// such a player as their real group correctly (case-insensitive), while every client-side
// isStaff()/hasAllPermissions() check quietly failed to find their group at all and denied
// everything gated behind it, persistently, not just as a load/remount timing glitch.
M.getGroupIndex = (groupName) => {
    if (typeof groupName !== "string") return null;
    const index = M.data.findIndex(
        (g) => g.name.toLowerCase() === groupName.toLowerCase()
    );
    return typeof index === "number" && index > -1 ? index : null;
};

M.getGroup = (groupName) => {
    const index = M.getGroupIndex(groupName);
    return typeof index === "number" ? M.data[index] : null;
};

export default M;
