angular.module("beamjoy").component("bjMainInfected", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/infected/app.html",
    controller: function ($rootScope, $timeout, $filter, beamjoyStore, beamjoyInfoPanel) {
        const translate = $filter("translate");

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

        // Reusable info-panel framework (see cmps/infoPanel/app.js and races' own identical first
        // consumer, windows/main/races/app.js's openRaceInfoPanel): a single "results" tab showing
        // time survived + tagCount per participant, longest survival first.
        this.openInfectedInfoPanel = () => {
            beamjoyInfoPanel.open(translate("beamjoy.window.main.tabs.infected.title"), [
                {
                    id: "results",
                    title: "beamjoy.window.main.tabs.infected.results.title",
                    template: "<bj-infected-info-results></bj-infected-info-results>",
                },
            ], "results");
        };
        this.openResults = (event) => {
            event.stopPropagation();
            this.openInfectedInfoPanel();
        };
        // fired once, server-side, the moment the round actually finishes: auto-surfaces the
        // results instead of requiring a manual click. Delayed a few seconds per the same reasoning
        // as races' own identical BJRaceInfoAutoOpen handler - popping the panel open the INSTANT
        // the round ends collides visually with the "Round over!"/winner popup also on screen then.
        $rootScope.$on("BJInfectedInfoAutoOpen", () => {
            $timeout(() => this.openInfectedInfoPanel(), 3000);
        });

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
                disableResets: d.disableResets === true,
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
