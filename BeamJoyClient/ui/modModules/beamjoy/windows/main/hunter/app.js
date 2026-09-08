angular.module("beamjoy").component("bjMainHunter", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/hunter/app.html",
    controller: function ($rootScope, beamjoyStore, beamjoyConfirm, $filter) {
        const translate = $filter("translate");

        this.canEditArena = () =>
            beamjoyStore.permissions.hasAllPermissions(undefined, "EditHunterArenas");
        this.isStaff = () => beamjoyStore.permissions.isStaff(undefined);
        this.forceFugitive = (event, participant) => {
            event.stopPropagation();
            beamjoyStore.send("BJHunterForceFugitive", [participant.playerID]);
        };
        this.openArenaEditor = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRequestOpenWindow", ["config"]);
            $rootScope.$broadcast("BJOpenTab", "hunterArena");
        };

        this.arena = { enabled: false, defaults: {} };
        $rootScope.$on("BJHunterArenaInfo", (_, info) => {
            this.arena = info || { enabled: false, defaults: {} };
        });

        this.vehiclePresets = [];
        this.vehiclePresetOptions = [];
        const rebuildVehiclePresetOptions = () => {
            this.vehiclePresetOptions = [
                { value: null, label: "beamjoy.window.config.tabs.races.vehicleRestriction.pool.select" },
                ...this.vehiclePresets.map((p) => ({ value: p.id, label: p.name })),
            ];
        };
        $rootScope.$on("BJVehiclePresetList", (_, presets) => {
            // Real bug: Lua can't distinguish an empty table from an empty object, so an
            // emptied-out preset list can arrive as `{}` instead of `[]` - truthy, so `presets ||
            // []` kept it as-is, and `{}.map`/`{}.find` isn't a function. Same fix already
            // established elsewhere in this codebase (see cmps/pointListEditor/app.js's own
            // listsUpdate handler).
            this.vehiclePresets = Array.isArray(presets) ? presets : [];
            rebuildVehiclePresetOptions();
        });
        this.presetById = (id) => this.vehiclePresets.find((p) => p.id === id);
        this.poolLabel = (presetId) => {
            const preset = this.presetById(presetId);
            return preset ? preset.name : "?";
        };

        this.sessions = [];
        $rootScope.$on("BJHunterOpenSessions", (_, sessions) => {
            this.sessions = sessions || [];
        });

        this.status = null;
        this.showPlayers = false;
        this.allReady = false;
        $rootScope.$on("BJHunterSessionStatus", (_, status) => {
            this.status = status || null;
            if (!this.status) {
                this.showPlayers = false;
                this.showSettings = false;
            }
            this.allReady =
                !!this.status &&
                Array.isArray(this.status.participants) &&
                this.status.participants.length > 0 &&
                this.status.participants.every((p) => p.ready);
        });
        this.togglePlayers = (event) => {
            event.stopPropagation();
            this.showPlayers = !this.showPlayers;
        };

        // per direct request : lobby/countdown/hunt participants can see what vehicles/settings
        // actually apply to this round, not just when starting a fresh hunt
        this.showSettings = false;
        this.toggleSettings = (event) => {
            event.stopPropagation();
            this.showSettings = !this.showSettings;
        };

        this.countdownSeconds = null;
        this.countdownWaiting = false;
        this.countdownChoosingOwn = false;
        $rootScope.$on("BJHunterCountdown", (_, data) => {
            if (!data.active) {
                this.countdownSeconds = null;
                this.countdownWaiting = false;
                this.countdownChoosingOwn = false;
                return;
            }
            this.countdownWaiting = !!data.waiting;
            this.countdownChoosingOwn = !!data.choosingOwn;
            this.countdownSeconds = (this.countdownWaiting || this.countdownChoosingOwn) ? null : data.seconds;
        });

        this.$onInit = () => {
            beamjoyStore.send("BJHunterArenaInfoRequest");
            beamjoyStore.send("BJVehiclePresetListRequest");
            beamjoyStore.send("BJHunterSessionStatusRequest");
            beamjoyStore.send("BJHunterOpenSessionsRequest");
            beamjoyStore.send("BJHunterCountdownRequest");
        };

        this.starting = false;
        this.startOptions = null;
        this.openStart = (event) => {
            event.stopPropagation();
            const d = this.arena.defaults || {};
            this.starting = true;
            this.startOptions = {
                winCondition: d.winCondition || "waypoints",
                timedModeDuration: d.timedModeDuration ?? 10,
                waypointCount: d.waypointCount || 5,
                huntedStuckTimeout: d.huntedStuckTimeout || 10,
                huntedStuckDistance: d.huntedStuckDistance || 0.5,
                huntedStartDelay: d.huntedStartDelay ?? 0,
                huntersStartDelay: d.huntersStartDelay ?? 5,
                huntersRespawnDelay: d.huntersRespawnDelay ?? 10,
                revealProximityDistance: d.revealProximityDistance || 50,
                revealResetDuration: d.revealResetDuration ?? 5,
                revealOnFinalWaypoint: d.revealOnFinalWaypoint !== false,
                hunterNametagFadeDistance: d.hunterNametagFadeDistance ?? 0,
                huntedResetDistanceThreshold: d.huntedResetDistanceThreshold ?? 150,
                huntedVehiclePresetId: d.huntedVehiclePresetId || null,
                huntersVehiclePresetId: d.huntersVehiclePresetId || null,
                randomizeVehiclePool: d.randomizeVehiclePool === true,
                respawnPenaltyIncrement: d.respawnPenaltyIncrement ?? 0,
                hunterRespawnStrategy: d.hunterRespawnStrategy || "nearestSpawn",
                gridTimeout: d.gridTimeout || 180,
                gridReadyTimeout: d.gridReadyTimeout ?? 10,
                countdown: d.countdown ?? 10,
                vehicleConfirmTimeout: d.vehicleConfirmTimeout ?? 20,
            };
        };
        this.cancelStart = (event) => {
            event.stopPropagation();
            this.starting = false;
            this.startOptions = null;
        };
        this.confirmStart = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJHunterStart", [this.startOptions]);
            this.starting = false;
            this.startOptions = null;
        };

        this.joinSession = (event, session) => {
            event.stopPropagation();
            beamjoyStore.send("BJHunterJoin", [session.id]);
        };
        this.setReady = (event, state) => {
            event.stopPropagation();
            beamjoyStore.send("BJHunterReady", [state]);
        };
        this.leaveSession = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJHunterLeave");
        };
        this.cancelSession = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJHunterCancel");
        };
    },
});
