angular.module("beamjoy").component("bjMainInfected", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/infected/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.canEditArena = () =>
            beamjoyStore.permissions.hasAllPermissions(undefined, "EditInfectedArenas");
        this.isStaff = () => beamjoyStore.permissions.isStaff(undefined);
        this.forceInfected = (event, participant) => {
            event.stopPropagation();
            beamjoyStore.send("BJInfectedForceInfected", [participant.playerID]);
        };
        this.openArenaEditor = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRequestOpenWindow", ["config"]);
            $rootScope.$broadcast("BJOpenTab", "infectedArena");
        };

        this.arena = { enabled: false, defaults: {} };
        $rootScope.$on("BJInfectedArenaInfo", (_, info) => {
            this.arena = info || { enabled: false, defaults: {} };
        });

        this.sessions = [];
        $rootScope.$on("BJInfectedOpenSessions", (_, sessions) => {
            this.sessions = sessions || [];
        });

        this.status = null;
        this.showPlayers = false;
        this.allReady = false;
        this.enoughParticipants = false;
        $rootScope.$on("BJInfectedSessionStatus", (_, status) => {
            this.status = status || null;
            if (!this.status) {
                this.showPlayers = false;
                this.showSettings = false;
            }
            if (this.status && this.status.state === "FINISHED") {
                this.showPlayers = true;
            }
            this.allReady =
                !!this.status &&
                Array.isArray(this.status.participants) &&
                this.status.participants.length > 0 &&
                this.status.participants.every((p) => p.ready);
            // Real bug: everyone ready is not, on its own, enough to actually leave LOBBY (see
            // infectedGrid.lua's tryStartFromLobby) - below minParticipants the server refuses
            // forever, but the "Starting in Xs" badge used to show and count down regardless,
            // with nothing telling the player why it never actually started.
            this.enoughParticipants =
                !!this.status &&
                (this.status.minParticipants == null || this.status.participantCount >= this.status.minParticipants);
        });
        this.togglePlayers = (event) => {
            event.stopPropagation();
            this.showPlayers = !this.showPlayers;
        };

        // FINISHED-only results ordering: longest survival first, matching a standard results
        // leaderboard rather than plain join order. Participants without a survivedMs yet (a stale
        // push mid-teardown, shouldn't really happen) sort last instead of crashing the compare.
        this.resultsParticipants = () => {
            if (!this.status || !Array.isArray(this.status.participants)) return [];
            return this.status.participants
                .slice()
                .sort((a, b) => (b.survivedMs ?? -1) - (a.survivedMs ?? -1));
        };

        this.formatTime = (ms) => {
            if (typeof ms !== "number" || ms < 0) return "-";
            const totalSec = ms / 1000;
            const min = Math.floor(totalSec / 60);
            const sec = (totalSec % 60).toFixed(0).padStart(2, "0");
            return `${min}:${sec}`;
        };

        // per the same reasoning as Hunter's own equivalent : lobby/countdown/game participants can
        // see what actually applies to this round, not just when starting a fresh one
        this.showSettings = false;
        this.toggleSettings = (event) => {
            event.stopPropagation();
            this.showSettings = !this.showSettings;
        };

        this.countdownSeconds = null;
        $rootScope.$on("BJInfectedCountdown", (_, data) => {
            this.countdownSeconds = data.active && !data.finished ? data.seconds : null;
        });

        this.$onInit = () => {
            beamjoyStore.send("BJInfectedArenaInfoRequest");
            beamjoyStore.send("BJInfectedSessionStatusRequest");
            beamjoyStore.send("BJInfectedOpenSessionsRequest");
            beamjoyStore.send("BJInfectedCountdownRequest");
        };

        this.starting = false;
        this.startOptions = null;
        this.openStart = (event) => {
            event.stopPropagation();
            const d = this.arena.defaults || {};
            this.starting = true;
            this.startOptions = {
                initialInfectedCount: d.initialInfectedCount || 1,
                roundDuration: d.roundDuration || 10,
                infectedStartDelay: d.infectedStartDelay ?? 10,
                enableColors: d.enableColors === true,
                survivorColor: d.survivorColor || null,
                infectedColor: d.infectedColor || null,
            };
        };
        this.cancelStart = (event) => {
            event.stopPropagation();
            this.starting = false;
            this.startOptions = null;
        };
        this.confirmStart = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJInfectedStart", [this.startOptions]);
            this.starting = false;
            this.startOptions = null;
        };

        this.joinSession = (event, session) => {
            event.stopPropagation();
            beamjoyStore.send("BJInfectedJoin", [session.id]);
        };
        this.setReady = (event, state) => {
            event.stopPropagation();
            beamjoyStore.send("BJInfectedReady", [state]);
        };
        this.leaveSession = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJInfectedLeave");
        };
        this.cancelSession = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJInfectedCancel");
        };
    },
});
