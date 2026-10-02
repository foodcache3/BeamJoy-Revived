// Activities > Derby : the map's arenas as a list of cards (the same layout as the race list), each
// started from its own card or, with a game on, joined from it ; then the lobby (the same layout as
// the race / infected lobbies). The leaderboard is the full window's Leaderboards > Derby. The game
// itself runs in beamjoy/derbyRunner.lua ; its HUD, countdown and results are their own windows.
angular.module("beamjoy").component("bjMainDerby", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/derby/app.html",
    controller: function ($rootScope, $scope, $timeout, $filter, beamjoyStore, beamjoyInfoPanel) {
        const translate = $filter("translate");
        const MODES = ["lms", "timed", "sumo"];

        this.canEditArenas = () => beamjoyStore.permissions.hasAllPermissions(undefined, "EditDerbyArenas");
        this.openArenaEditor = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRequestOpenWindow", ["config"]);
            $rootScope.$broadcast("BJOpenTab", "derbyArena");
        };

        // ARENAS ---------------------------------------------------------------------------------
        this.arenas = [];
        this.playable = [];
        const offArenas = $rootScope.$on("BJDerbyArenaInfo", (_, info) => {
            this.arenas = info && Array.isArray(info.arenas) ? info.arenas : [];
            // the modes each arena can host : sumo needs its zone
            this.arenas.forEach((a) => (a.modes = MODES.filter((m) => m !== "sumo" || a.hasZone)));
            this.playable = this.arenas.filter((a) => a.enabled);
            openPendingStart();
            if (this.startingId !== null && !this.playable.some((a) => a.id === this.startingId)) {
                this.startOptions = null;
                this.startingId = null;
            }
        });
        this.arenaLine = (arena) => {
            const parts = [translate("beamjoy.window.main.tabs.derby.players").replace("{n}", arena.places || 0)];
            if (arena.hasZone) parts.push(translate("beamjoy.window.main.tabs.derby.sumoZone"));
            return parts.join(", ");
        };

        // SESSIONS -------------------------------------------------------------------------------
        this.sessions = [];
        const offSessions = $rootScope.$on("BJDerbyOpenSessions", (_, sessions) => {
            this.sessions = Array.isArray(sessions) ? sessions : [];
        });
        // the game on an arena right now (one at a time, services/derbyGrid.lua derbyStart)
        this.sessionOn = (arena) => this.sessions.find((s) => s.arenaId === arena.id) || null;
        this.canJoin = (arena) => {
            const s = this.sessionOn(arena);
            return !!s && s.state === "LOBBY" && s.joinable && s.participantCount < s.maxParticipants;
        };
        this.liveLine = (arena) => {
            const s = this.sessionOn(arena);
            if (!s) return "";
            if (s.state !== "LOBBY") {
                return translate("beamjoy.window.main.tabs.derby.liveGame").replace("{mode}", this.modeLabel(s.mode));
            }
            return translate("beamjoy.window.main.tabs.derby.liveLobby")
                .replace("{name}", s.starterName || "?")
                .replace("{mode}", this.modeLabel(s.mode))
                .replace("{count}", s.participantCount || 0)
                .replace("{max}", s.maxParticipants || 0);
        };
        this.joinArena = (event, arena) => {
            event.stopPropagation();
            const s = this.sessionOn(arena);
            if (s) beamjoyStore.send("BJDerbyJoin", [s.id]);
        };

        this.status = null;
        this.slots = [];
        this.allReady = false;
        const offStatus = $rootScope.$on("BJDerbySessionStatus", (_, status) => {
            this.status = status || null;
            if (!this.status) {
                this.showSettings = false;
                this.inviting = false;
            }
            const s = this.status;
            this.allReady = !!s && Array.isArray(s.participants) && s.participants.length > 0 &&
                s.participants.every((p) => p.ready);
            buildSlots();
        });
        const buildSlots = () => {
            const s = this.status;
            if (!s) return (this.slots = []);
            const rows = (s.participants || []).map((p, i) => ({ key: `p${p.playerID}`, num: i + 1, player: p, ready: this.isReady(p) }));
            if (s.state === "LOBBY") {
                for (let i = rows.length; i < (s.maxParticipants || 0); i++) rows.push({ key: `o${i}`, num: i + 1, open: true });
            }
            this.slots = rows;
        };
        this.isLeader = (player) => !!this.status && String(player.playerID) === String(this.status.starterID);
        this.isReady = (player) => {
            const s = this.status;
            const self = beamjoyStore.players.self;
            const isSelf = self && String(player.playerID) === String(self.playerID);
            if (s && isSelf) return !!s.ready;
            return player.ready === true;
        };

        const mmss = (sec) => {
            sec = Math.max(0, Math.round(Number(sec) || 0));
            return `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, "0")}`;
        };
        // the same object while unchanged : ng-if watches it by reference
        let timerCache = null;
        const timer = (label, value) => {
            if (!timerCache || timerCache.label !== label || timerCache.value !== value) timerCache = { label, value };
            return timerCache;
        };
        this.countdownSeconds = null;
        const offCountdown = $rootScope.$on("BJDerbyCountdown", (_, data) => {
            this.countdownSeconds = data && data.active && !data.finished ? data.seconds : null;
        });
        this.lobbyTimer = () => {
            const s = this.status;
            if (!s) return null;
            if (s.state === "COUNTDOWN" && this.countdownSeconds !== null) {
                return timer("beamjoy.window.main.tabs.derby.startingIn", `${this.countdownSeconds}`);
            }
            if (s.state === "LOBBY" && this.allReady && s.gridReadySecondsLeft != null) {
                return timer("beamjoy.window.main.tabs.derby.startingIn", mmss(s.gridReadySecondsLeft));
            }
            if (s.state === "LOBBY" && s.gridTimeoutSecondsLeft != null) {
                return timer("beamjoy.window.main.tabs.derby.lobbyClosesIn", mmss(s.gridTimeoutSecondsLeft));
            }
            return null;
        };
        this.lobbyLine = () => {
            const s = this.status;
            if (!s) return "";
            const leader = (s.participants || []).find((p) => String(p.playerID) === String(s.starterID));
            return translate(s.isStarter ? "beamjoy.window.main.tabs.derby.yourLobby" : "beamjoy.window.main.tabs.derby.theirLobby")
                .replace("{name}", leader ? leader.displayName || leader.playerName : "?")
                .replace("{arena}", s.arenaName || "?")
                .replace("{count}", s.participantCount || 0)
                .replace("{max}", s.maxParticipants || 0);
        };
        this.modeLabel = (mode) => translate(`beamjoy.window.main.tabs.derby.modes.${mode || "lms"}`);
        this.livesChip = () => {
            const lives = this.status ? this.status.settings.lives || 0 : 0;
            return translate(lives === 1 ? "beamjoy.window.main.tabs.derby.extraLife" : "beamjoy.window.main.tabs.derby.extraLives")
                .replace("{lives}", lives);
        };
        // what a row shows next to the name while the game runs
        this.slotDetail = (p) => {
            const s = this.status;
            if (!s || s.state === "LOBBY") return "";
            const parts = [];
            if (s.settings.mode !== "timed") {
                parts.push(p.eliminated ? translate("beamjoy.window.main.tabs.derby.out")
                    : translate("beamjoy.window.main.tabs.derby.livesShort").replace("{lives}", p.lives || 0));
            }
            parts.push(translate("beamjoy.window.main.tabs.derby.wrecksShort").replace("{count}", p.wrecks || 0));
            return parts.join(" · ");
        };

        this.inviting = false;
        this.setInviting = (open) => (this.inviting = open);
        this.showSettings = false;
        this.toggleSettings = (event) => {
            event.stopPropagation();
            this.showSettings = !this.showSettings;
        };

        // RESULTS --------------------------------------------------------------------------------
        this.openInfoPanel = () => {
            beamjoyInfoPanel.open(translate("beamjoy.window.main.tabs.derby.title"), [
                {
                    id: "results",
                    title: "beamjoy.window.main.tabs.derby.results.title",
                    template: "<bj-derby-info-results></bj-derby-info-results>",
                },
            ], "results");
        };
        this.openResults = (event) => {
            event.stopPropagation();
            this.openInfoPanel();
        };
        // a moment after the end : the winner popup comes first
        const offAutoOpen = $rootScope.$on("BJDerbyInfoAutoOpen", () => {
            $timeout(() => this.openInfoPanel(), 3000);
        });

        // LEADERBOARD : the full window's Leaderboards > Derby (main/app.js) ----------------------
        this.openLeaderboards = (event) => {
            event.stopPropagation();
            $rootScope.$broadcast("BJMainOpenLeaderboards", "derby");
        };

        // START ----------------------------------------------------------------------------------
        this.vehiclePresetOptions = [];
        const offPresets = $rootScope.$on("BJVehiclePresetList", (_, presets) => {
            const list = Array.isArray(presets) ? presets : [];
            this.vehiclePresetOptions = [
                { value: null, label: "beamjoy.window.main.tabs.derby.anyVehicle" },
                ...list.map((p) => ({ value: p.id, label: p.name })),
            ];
        });

        // the arena whose card has its start form open
        this.startingId = null;
        this.startOptions = null;
        const optionsFor = (arena) => {
            const d = (arena && arena.defaults) || {};
            return {
                arenaId: arena ? arena.id : null,
                mode: d.mode === "sumo" && !(arena && arena.hasZone) ? "lms" : d.mode || "lms",
                lives: d.lives ?? 0,
                roundDuration: d.roundDuration || 5,
                stuckSeconds: d.stuckSeconds || 20,
                vehiclePresetId: d.vehiclePresetId ?? null,
                randomizeVehiclePool: d.randomizeVehiclePool === true,
            };
        };
        // the card's own arena, with that arena's saved defaults
        this.openStart = (event, arena) => {
            event.stopPropagation();
            this.startingId = arena.id;
            this.startOptions = optionsFor(arena);
        };
        this.cancelStart = (event) => {
            event.stopPropagation();
            this.startingId = null;
            this.startOptions = null;
        };
        this.confirmStart = (event) => {
            event.stopPropagation();
            if (!this.startOptions) return;
            beamjoyStore.send("BJDerbyStart", [this.startOptions]);
            this.startingId = null;
            this.startOptions = null;
        };
        this.setReady = (event, state) => {
            event.stopPropagation();
            beamjoyStore.send("BJDerbyReady", [state]);
        };
        this.startNow = (event) => {
            event.stopPropagation();
            if (this.status && this.status.isStarter) beamjoyStore.send("BJDerbyStartNow");
        };
        this.leaveSession = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJDerbyLeave");
        };
        this.cancelSession = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJDerbyCancel");
        };

        this.$onInit = () => {
            beamjoyStore.send("BJVehiclePresetListRequest");
            beamjoyStore.send("BJDerbyArenaInfoRequest");
            beamjoyStore.send("BJDerbySessionStatusRequest");
            beamjoyStore.send("BJDerbyOpenSessionsRequest");
            beamjoyStore.send("BJDerbyCountdownRequest");
        };
        // an arena marker's "Open derby" in the world (lua beamjoy/derby.lua) : that arena's start
        // form, unless a game is already on there (its card shows Join instead)
        // (the arena list handler above calls it too : always later, on an event)
        const openPendingStart = () => {
            const pending = beamjoyStore.pendingActivityStart;
            if (!pending || pending.kind !== "derby") return;
            const arena = (this.playable || []).find((a) => a.id === pending.id);
            if (!arena) return;
            beamjoyStore.pendingActivityStart = null;
            if (!this.sessionOn(arena) && this.startingId !== arena.id) {
                this.openStart({ stopPropagation: () => {} }, arena);
            }
        };
        const offOpenStart = $rootScope.$on("BJOpenActivityStart", openPendingStart);
        $scope.$on("$destroy", () => {
            [offArenas, offSessions, offStatus, offCountdown, offAutoOpen, offPresets, offOpenStart].forEach((off) => off());
        });
    },
});
