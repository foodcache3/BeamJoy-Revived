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
        // LOBBY (shared layout with races / convoys) ---------------------------------------
        // the grid as the lobby shows it : players, then the free slots. Built once per status
        // push (a fresh array per digest never settles)
        this.slots = [];
        const buildSlots = () => {
            const s = this.status;
            if (!s) return (this.slots = []);
            const rows = (s.participants || []).map((p, i) => ({ key: `p${p.playerID}`, num: i + 1, player: p, ready: this.isReady(p) }));
            for (let i = rows.length; i < (s.maxParticipants || 0); i++) rows.push({ key: `o${i}`, num: i + 1, open: true });
            this.slots = rows;
        };
        $rootScope.$on("BJHunterSessionStatus", () => buildSlots());
        this.isLeader = (player) => !!this.status && String(player.playerID) === String(this.status.starterID);
        // your own row follows the status push's own ready flag
        this.isReady = (player) => {
            const s = this.status;
            const self = beamjoyStore.players.self;
            // ids can arrive as numbers or strings depending on the push : compare loosely
            const isSelf =
                (self && String(player.playerID) === String(self.playerID)) ||
                (s && s.isStarter && String(player.playerID) === String(s.starterID));
            if (s && isSelf) return !!s.ready;
            return player.ready === true || player.ready === 1 || player.ready === "true";
        };
        const formatSeconds = (sec) => {
            sec = Math.max(0, Math.round(Number(sec) || 0));
            const m = Math.floor(sec / 60);
            const r = sec % 60;
            return `${m}:${r < 10 ? "0" : ""}${r}`;
        };
        // the same object while nothing changed : ng-if watches it by reference, and a fresh object
        // every call never settles the digest (infdig, thousands of errors a second)
        let timerCache = null;
        const timer = (label, value) => {
            if (!timerCache || timerCache.label !== label || timerCache.value !== value) timerCache = { label, value };
            return timerCache;
        };
        this.lobbyTimer = () => {
            const s = this.status;
            if (!s) return null;
            if (s.state === "COUNTDOWN" && this.countdownSeconds !== null) {
                return timer("beamjoy.window.main.tabs.hunter.startingIn", `${this.countdownSeconds}`);
            }
            if (s.state === "LOBBY" && this.allReady && s.gridReadySecondsLeft != null) {
                return timer("beamjoy.window.main.tabs.hunter.startingIn", formatSeconds(s.gridReadySecondsLeft));
            }
            if (s.state === "LOBBY" && s.gridTimeoutSecondsLeft != null) {
                return timer("beamjoy.window.main.tabs.hunter.lobbyClosesIn", formatSeconds(s.gridTimeoutSecondsLeft));
            }
            return null;
        };
        this.lobbyLine = () => {
            const s = this.status;
            if (!s) return "";
            const leader = (s.participants || []).find((p) => p.playerID === s.starterID);
            return translate(s.isStarter ? "beamjoy.window.main.tabs.hunter.yourLobby" : "beamjoy.window.main.tabs.hunter.theirLobby")
                .replace("{name}", leader ? leader.displayName || leader.playerName : "?")
                .replace("{count}", s.participantCount || 0)
                .replace("{max}", s.maxParticipants || 0);
        };
        this.inviting = false;
        this.setInviting = (open) => (this.inviting = open);
        this.startNow = (event) => {
            event.stopPropagation();
            if (this.status && this.status.isStarter) beamjoyStore.send("BJHunterStartNow");
        };

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
                revealProximityDistance: d.revealProximityDistance || 500,
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
        this.presetsPicked = () =>
            !!this.startOptions &&
            !!this.presetById(this.startOptions.huntedVehiclePresetId) &&
            !!this.presetById(this.startOptions.huntersVehiclePresetId);
        this.confirmStart = (event) => {
            event.stopPropagation();
            if (!this.presetsPicked()) return;
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
