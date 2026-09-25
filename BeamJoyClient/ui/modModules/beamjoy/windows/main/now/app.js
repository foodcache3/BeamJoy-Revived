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
    this.status = { race: null, hunter: null, infected: null, convoy: null, delivery: null, bus: null };
    // a race's start form being filled in, kept while the Activities panel and the full window
    // swap (both mount their own copy of the races component)
    this.raceDraft = null;

    $rootScope.$on("BJRaceOpenSessions", (_, list) => (this.races = asList(list)));
    $rootScope.$on("BJHunterOpenSessions", (_, list) => (this.hunts = asList(list)));
    $rootScope.$on("BJInfectedOpenSessions", (_, list) => (this.infected = asList(list)));
    $rootScope.$on("BJRaceSessionStatus", (_, s) => (this.status.race = s || null));
    $rootScope.$on("BJHunterSessionStatus", (_, s) => (this.status.hunter = s || null));
    $rootScope.$on("BJInfectedSessionStatus", (_, s) => (this.status.infected = s || null));
    $rootScope.$on("BJDeliveryLobby", (_, d) => (this.status.convoy = d && d.open ? d : null));
    $rootScope.$on("BJDeliveryHud", (_, d) => (this.status.delivery = d && d.active ? d : null));
    $rootScope.$on("BJBusHud", (_, d) => (this.status.bus = d && d.active ? d : null));

    this.refresh = () => {
        [
            "BJRaceOpenSessionsRequest",
            "BJHunterOpenSessionsRequest",
            "BJInfectedOpenSessionsRequest",
            "BJRaceSessionStatusRequest",
            "BJHunterSessionStatusRequest",
            "BJInfectedSessionStatusRequest",
            "BJDeliveryLobbyRequest",
        ].forEach((event) => beamjoyStore.send(event));
    };

    // one activity at a time : you're either in one of these or free to join
    this.busy = () => !!this.activeSection();
    // the Activities section that manages what you're in, or null when you're free
    this.activeSection = () => {
        const s = this.status;
        if (s.race) return "races";
        if (s.hunter) return "hunter";
        if (s.infected) return "infected";
        if (s.convoy || s.delivery) return "jobs";
        if (s.bus) return "busLines";
        return null;
    };
    const lobby = (s) => (s.state === "GRID" || s.state === "LOBBY") && s.joinable;
    this.joinableCount = () =>
        this.busy()
            ? 0
            : this.races.filter(lobby).length + this.hunts.filter(lobby).length + this.infected.filter(lobby).length;
});

angular.module("beamjoy").component("bjMainNow", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/now/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyNow, beamjoyDelivery) {
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

        // the activity you're in, as one card ; section is the Activities sub-tab that manages it
        this.mine = () => {
            const s = beamjoyNow.status;
            if (s.race) {
                return {
                    section: "races",
                    title: s.race.raceName || translate("beamjoy.window.main.now.kind.race"),
                    line: fill(`beamjoy.window.main.now.mine.${s.race.state === "GRID" ? "lobby" : "running"}`,
                        { count: s.race.participantCount || 0, max: s.race.maxParticipants || 0 }),
                };
            }
            if (s.hunter) {
                return {
                    section: "hunter",
                    title: translate("beamjoy.window.main.now.kind.hunter"),
                    line: fill(`beamjoy.window.main.now.mine.${s.hunter.state === "LOBBY" ? "lobby" : "running"}`,
                        { count: s.hunter.participantCount || 0, max: s.hunter.maxParticipants || 0 }),
                };
            }
            if (s.infected) {
                return {
                    section: "infected",
                    title: translate("beamjoy.window.main.now.kind.infected"),
                    line: fill(`beamjoy.window.main.now.mine.${s.infected.state === "LOBBY" ? "lobby" : "running"}`,
                        { count: s.infected.participantCount || 0, max: s.infected.maxParticipants || 0 }),
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
            const mineId = (beamjoyNow.status.race || beamjoyNow.status.hunter || beamjoyNow.status.infected || {}).id;
            const key = [beamjoyNow.races, beamjoyNow.hunts, beamjoyNow.infected, mineId];
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
            rows.sort((a, b) => Number(b.forming) - Number(a.forming));
            cacheRows = rows;
            return rows;
        };

        this.canJoin = (row) => row.forming && !beamjoyNow.busy();
        this.canSpectate = (row) => !row.forming && row.kind === "race" && !beamjoyNow.busy();
        this.join = (row) => {
            const event = { race: "BJRaceJoin", hunter: "BJHunterJoin", infected: "BJInfectedJoin" }[row.kind];
            beamjoyStore.send(event, [row.session.id]);
        };
        this.spectate = (row) => beamjoyStore.send("BJRaceSpectate", [row.session.id]);
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
