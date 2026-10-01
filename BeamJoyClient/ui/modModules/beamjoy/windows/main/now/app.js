// Main window > Happening now : everything you could jump into right now, in one list. Races,
// hunts and infected games still forming (Join) or running (Spectate, races only), the activity
// you're already in (Open takes you to its Activities section), and delivery convoys forming
// (Open jobs). The lists come from the runners' existing pushes (BJRaceOpenSessions,
// BJHunterOpenSessions, BJInfectedOpenSessions and their *SessionStatus), kept by the
// beamjoyNow service for the whole session so the rail's Now badge can count joinable lobbies
// while this panel is closed.
angular.module("beamjoy").service("beamjoyNow", function ($rootScope, beamjoyStore) {
    const asList = (v) => (Array.isArray(v) ? v : []);
    this.races = [];
    this.hunts = [];
    this.infected = [];
    this.derbies = [];
    // delivery convoys forming anywhere on the map (beamjoy/delivery.lua BJDeliveryConvoys)
    this.convoys = [];
    this.status = { race: null, hunter: null, infected: null, derby: null, convoy: null, delivery: null, bus: null };
    // a race's start form being filled in, kept while the Activities panel and the full window
    // swap (both mount their own copy of the races component)
    this.raceDraft = null;

    $rootScope.$on("BJRaceOpenSessions", (_, list) => (this.races = asList(list)));
    $rootScope.$on("BJHunterOpenSessions", (_, list) => (this.hunts = asList(list)));
    $rootScope.$on("BJInfectedOpenSessions", (_, list) => (this.infected = asList(list)));
    $rootScope.$on("BJDerbyOpenSessions", (_, list) => (this.derbies = asList(list)));
    $rootScope.$on("BJDeliveryConvoys", (_, list) => (this.convoys = asList(list)));
    $rootScope.$on("BJRaceSessionStatus", (_, s) => (this.status.race = s || null));
    $rootScope.$on("BJHunterSessionStatus", (_, s) => (this.status.hunter = s || null));
    $rootScope.$on("BJInfectedSessionStatus", (_, s) => (this.status.infected = s || null));
    $rootScope.$on("BJDerbySessionStatus", (_, s) => (this.status.derby = s || null));
    $rootScope.$on("BJDeliveryLobby", (_, d) => (this.status.convoy = d && d.open ? d : null));
    $rootScope.$on("BJDeliveryHud", (_, d) => (this.status.delivery = d && d.active ? d : null));
    $rootScope.$on("BJBusHud", (_, d) => (this.status.bus = d && d.active ? d : null));

    this.refresh = () => {
        [
            "BJRaceOpenSessionsRequest",
            "BJHunterOpenSessionsRequest",
            "BJInfectedOpenSessionsRequest",
            "BJDerbyOpenSessionsRequest",
            "BJRaceSessionStatusRequest",
            "BJHunterSessionStatusRequest",
            "BJInfectedSessionStatusRequest",
            "BJDerbySessionStatusRequest",
            "BJDeliveryLobbyRequest",
            "BJDeliveryConvoysRequest",
        ].forEach((event) => beamjoyStore.send(event));
    };

    // one activity at a time : you're either in one of these or free to join
    this.busy = () => !!this.activeSection();
    // something actually under way (not a lobby) : a key that changes when a new one starts
    this.runningKey = () => {
        const s = this.status;
        if (s.race && (s.race.state === "COUNTDOWN" || s.race.state === "RACE")) return `race:${s.race.id}`;
        if (s.hunter && (s.hunter.state === "COUNTDOWN" || s.hunter.state === "HUNT")) return `hunter:${s.hunter.id}`;
        if (s.infected && (s.infected.state === "COUNTDOWN" || s.infected.state === "GAME")) return `infected:${s.infected.id}`;
        if (s.derby && (s.derby.state === "COUNTDOWN" || s.derby.state === "GAME")) return `derby:${s.derby.id}`;
        if (s.delivery) return "delivery";
        if (s.bus) return "bus";
        return null;
    };
    // the Activities section that manages what you're in, or null when you're free
    this.activeSection = () => {
        const s = this.status;
        if (s.race) return "races";
        if (s.hunter) return "hunter";
        if (s.infected) return "infected";
        if (s.derby) return "derby";
        if (s.convoy || s.delivery) return "jobs";
        if (s.bus) return "busLines";
        return null;
    };
    const lobby = (s) => (s.state === "GRID" || s.state === "LOBBY") && s.joinable;
    this.joinableCount = () =>
        this.busy()
            ? 0
            : this.races.filter(lobby).length +
              this.hunts.filter(lobby).length +
              this.infected.filter(lobby).length +
              this.derbies.filter(lobby).length +
              this.convoys.filter((c) => c.count < c.max).length;
});

angular.module("beamjoy").component("bjMainNow", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/now/app.html",
    controller: function ($rootScope, $scope, $filter, $timeout, beamjoyStore, beamjoyNow, beamjoyDelivery) {
        const translate = $filter("translate");
        this.now = beamjoyNow;
        this.jobs = null;

        const offJobs = $rootScope.$on("BJDeliveryJobsSummary", (_, data) => {
            this.jobs = data || null;
        });
        this.$onInit = () => {
            beamjoyNow.refresh();
            beamjoyStore.send("BJDeliveryJobsSummaryRequest");
        };
        $scope.$on("$destroy", () => {
            offJobs();
            beamjoyStore.send("BJDeliveryJobsSummaryClosed");
        });

        const fill = (key, values) =>
            Object.entries(values).reduce((text, [k, v]) => text.replace(`{${k}}`, v), translate(key));

        // the activity you're in, as one card ; section is the Activities sub-tab that manages it.
        // The same object while its text is unchanged : ng-if watches it by reference, and a fresh
        // object every call never settles the digest
        let mineCache = null;
        this.mine = () => {
            const next = buildMine();
            if (!next) return (mineCache = null);
            if (!mineCache || mineCache.section !== next.section || mineCache.title !== next.title || mineCache.line !== next.line
                || mineCache.timer !== next.timer) {
                mineCache = next;
            }
            return mineCache;
        };
        // a forming lobby's clock : the start once everyone's ready, before that the lobby closing
        const mm = (sec) => `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, "0")}`;
        const lobbyTimer = (st, lobbyState) => {
            if (!st || st.state !== lobbyState) return null;
            if (st.gridReadySecondsLeft != null) return `${translate("beamjoy.window.main.tabs.races.startingIn")} ${mm(st.gridReadySecondsLeft)}`;
            if (st.gridTimeoutSecondsLeft != null) return `${translate("beamjoy.window.main.tabs.races.lobbyClosesIn")} ${mm(st.gridTimeoutSecondsLeft)}`;
            return null;
        };
        const buildMine = () => {
            const s = beamjoyNow.status;
            if (s.race) {
                return {
                    section: "races",
                    title: s.race.raceName || translate("beamjoy.window.main.now.kind.race"),
                    line: fill(`beamjoy.window.main.now.mine.${s.race.state === "GRID" ? "lobby" : "running"}`,
                        { count: s.race.participantCount || 0, max: s.race.maxParticipants || 0 }),
                    timer: lobbyTimer(s.race, "GRID"),
                };
            }
            if (s.hunter) {
                return {
                    section: "hunter",
                    title: translate("beamjoy.window.main.now.kind.hunter"),
                    line: fill(`beamjoy.window.main.now.mine.${s.hunter.state === "LOBBY" ? "lobby" : "running"}`,
                        { count: s.hunter.participantCount || 0, max: s.hunter.maxParticipants || 0 }),
                    timer: lobbyTimer(s.hunter, "LOBBY"),
                };
            }
            if (s.infected) {
                return {
                    section: "infected",
                    title: translate("beamjoy.window.main.now.kind.infected"),
                    line: fill(`beamjoy.window.main.now.mine.${s.infected.state === "LOBBY" ? "lobby" : "running"}`,
                        { count: s.infected.participantCount || 0, max: s.infected.maxParticipants || 0 }),
                    timer: lobbyTimer(s.infected, "LOBBY"),
                };
            }
            if (s.derby) {
                return {
                    section: "derby",
                    title: s.derby.arenaName || translate("beamjoy.window.main.now.kind.derby"),
                    line: fill(`beamjoy.window.main.now.mine.${s.derby.state === "LOBBY" ? "lobby" : "running"}`,
                        { count: s.derby.participantCount || 0, max: s.derby.maxParticipants || 0 }),
                    timer: lobbyTimer(s.derby, "LOBBY"),
                };
            }
            if (s.convoy) {
                return {
                    section: "jobs",
                    title: `${s.convoy.title || ""} ${translate("beamjoy.delivery.toLower")} ${s.convoy.destName || ""}`.trim(),
                    line: fill("beamjoy.window.main.now.mine.convoy", {
                        count: (s.convoy.members || []).length,
                        max: s.convoy.max || 0,
                    }),
                };
            }
            if (s.delivery) {
                return {
                    section: "jobs",
                    title: s.delivery.title || translate("beamjoy.window.main.now.jobs.title"),
                    line: translate("beamjoy.window.main.now.mine.delivery"),
                };
            }
            if (s.bus) {
                return {
                    section: "busLines",
                    title: s.bus.lineName || translate("beamjoy.window.main.tabs.races.sections.busLines"),
                    line: translate("beamjoy.window.main.now.mine.bus"),
                };
            }
            return null;
        };

        // every other session, lobbies first. Built per call but only read by ng-repeat through
        // `rows`, refreshed on each digest from a stable cache keyed on the source lists (see the
        // job board for why a fresh array per digest is a problem)
        let cacheKey = null;
        let cacheRows = [];
        this.rows = () => {
            const mineId = (beamjoyNow.status.race || beamjoyNow.status.hunter || beamjoyNow.status.infected ||
                beamjoyNow.status.derby || {}).id;
            const convoyId = beamjoyNow.status.convoy ? beamjoyNow.status.convoy.id : null;
            const key = [beamjoyNow.races, beamjoyNow.hunts, beamjoyNow.infected, beamjoyNow.derbies, beamjoyNow.convoys,
                mineId, convoyId];
            if (cacheKey && key.every((v, i) => v === cacheKey[i])) return cacheRows;
            cacheKey = key;
            const rows = [];
            const add = (kind, s, title) => {
                if (s.id === mineId) return;
                const forming = (s.state === "GRID" || s.state === "LOBBY") && s.joinable;
                rows.push({
                    id: `${kind}:${s.id}`,
                    kind,
                    session: s,
                    forming,
                    title,
                    line: fill(`beamjoy.window.main.now.row.${forming ? "lobby" : "running"}`, {
                        name: s.starterName || "?",
                        count: s.participantCount || 0,
                        max: s.maxParticipants || 0,
                    }),
                });
            };
            beamjoyNow.races.forEach((s) => add("race", s, s.raceName || translate("beamjoy.window.main.now.kind.race")));
            beamjoyNow.hunts.forEach((s) => add("hunter", s, translate("beamjoy.window.main.now.kind.hunter")));
            beamjoyNow.infected.forEach((s) => add("infected", s, translate("beamjoy.window.main.now.kind.infected")));
            beamjoyNow.derbies.forEach((s) => add("derby", s, s.raceName || translate("beamjoy.window.main.now.kind.derby")));
            beamjoyNow.convoys.forEach((c) => {
                if (c.id === convoyId) return;
                const open = c.count < c.max;
                rows.push({
                    id: `convoy:${c.id}`,
                    kind: "convoy",
                    session: c,
                    forming: open,
                    title: `${c.title || ""} ${translate("beamjoy.delivery.toLower")} ${c.destName || ""}`.trim(),
                    line: fill(`beamjoy.window.main.now.row.${open ? "convoy" : "convoyFull"}`, {
                        name: c.leaderName || "?",
                        count: c.count || 0,
                        max: c.max || 0,
                        depot: c.depotName || "?",
                    }),
                });
            });
            rows.sort((a, b) => Number(b.forming) - Number(a.forming));
            cacheRows = rows;
            return rows;
        };

        this.canJoin = (row) => row.forming && !beamjoyNow.busy();
        this.canSpectate = (row) => !row.forming && row.kind === "race" && !beamjoyNow.busy();
        this.join = (row) => {
            // joining a convoy works from anywhere : you're brought to the depot when it leaves
            if (row.kind === "convoy") return beamjoyStore.send("BJDeliveryJobsJoin", [row.session.id]);
            const event = { race: "BJRaceJoin", hunter: "BJHunterJoin", infected: "BJInfectedJoin", derby: "BJDerbyJoin" }[row.kind];
            beamjoyStore.send(event, [row.session.id]);
        };
        this.spectate = (row) => beamjoyStore.send("BJRaceSpectate", [row.session.id]);
        // staff : cancel anyone's race, hunt or infected game (the server checks staff again)
        this.cancelArmed = null;
        let disarm = null;
        this.canCancel = (row) => row.kind !== "convoy" && beamjoyStore.permissions.isStaff();
        this.cancel = (row) => {
            $timeout.cancel(disarm);
            if (this.cancelArmed !== row.id) {
                this.cancelArmed = row.id;
                disarm = $timeout(() => (this.cancelArmed = null), 4000);
                return;
            }
            this.cancelArmed = null;
            beamjoyStore.send("BJStaffSessionCancel", [row.kind, row.session.id]);
        };
        $scope.$on("$destroy", () => $timeout.cancel(disarm));
        this.open = (section) => $rootScope.$broadcast("BJMainOpenPanel", "play", section);
        this.startActivity = () => $rootScope.$broadcast("BJMainOpenPanel", "play");

        this.jobsLine = () => {
            if (!this.jobs || !this.jobs.depots) return "";
            const parts = [];
            if (this.jobs.nearestName) {
                parts.push(fill("beamjoy.window.main.now.jobs.nearest", {
                    name: this.jobs.nearestName,
                    distance: beamjoyDelivery.formatDistance(this.jobs.nearestDistance),
                }));
            }
            parts.push(fill(this.jobs.convoys === 1 ? "beamjoy.window.main.now.jobs.convoysOne" : "beamjoy.window.main.now.jobs.convoys",
                { count: this.jobs.convoys || 0 }));
            return parts.join(". ");
        };
        this.openJobs = () => $rootScope.$broadcast("BJMainOpenPanel", "play", "jobs");
    },
});
