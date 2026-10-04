const M = {
    data: {
        vehicle: {
            automaticLights: true,
            // 0-100 %, see lua beamjoy/particles.lua
            particleAmount: 100,
            // nobody but your crew can use your cars' buttons, see lua beamjoy/vehicleInteractions.lua
            lockVehicles: false,
        },
        // in-world markers and their prompts, see lua beamjoy/markerSettings.lua
        markers: {
            hideActivities: false,
            hideStations: false,
        },
        // ghosted vehicles drawn solid, see lua beamjoy/markerSettings.lua
        visual: {
            opaqueGhosts: false,
        },
        // police players can chase you, see lua beamjoy/playerPursuit.lua
        pursuit: {
            allowChases: true,
        },
        nametags: {
            hideNameTags: false,
            nameTagFadeEnabled: true,
            nameTagFadeDistance: 40,
            nameTagFadeInvert: false,
            nameTagDontFullyHide: true,
            shortenNametags: false,
            nametagCharLimit: 50,
            nameTagShowDistance: true,
            showSpectators: true,
            playerColor: "#ffffff",
            playerBgColor: "#000000",
            idleColor: "#ffaa00",
            idleBgColor: "#000000",
            specColor: "#aaaaff",
            specBgColor: "#000000",
        },
        freecam: {
            smooth: false,
            fov: 65,
            speed: 70,
        },
    },
    defaults: {},
};
let parent;
M.init = function (beamjoyStore) {
    parent = beamjoyStore;
    M.defaults = angular.copy(M.data);
};

M.assign = function (rawSettings) {
    Object.assign(M.data, rawSettings);
    // nametags colors
    [
        "playerColor",
        "playerBgColor",
        "idleColor",
        "idleBgColor",
        "specColor",
        "specBgColor",
    ]
        .filter(
            (key) =>
                typeof M.data.nametags[key] === "object" &&
                typeof M.data.nametags[key].r === "number"
        )
        .forEach((key) => {
            M.data.nametags[key] = parent.utils.rgbToHex(
                M.data.nametags[key]
            );
        });
};

M.save = function (newSettings) {
    M.data = newSettings;
    const payload = angular.copy(M.data);
    // nametags colors
    [
        "playerColor",
        "playerBgColor",
        "idleColor",
        "idleBgColor",
        "specColor",
        "specBgColor",
    ].forEach((key) => {
        payload.nametags[key] = parent.utils.hexToRgb(payload.nametags[key]);
    });
    parent.send("BJUserSettings", [payload]);
};

export default M;
