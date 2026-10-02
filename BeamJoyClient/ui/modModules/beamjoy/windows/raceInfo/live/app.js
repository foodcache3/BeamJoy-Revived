// Race info > Live : one row per racer, in race order. Each row's sector strip is this lap's
// progress (purple : the fastest anyone has set in that sector, orange : the sector they're in) ;
// a finished racer shows the chequered flag and their time instead. On a single-lap stage the Lap
// column counts sectors and Last lap becomes Last sector. Built once per BJRaceInfo push (never in
// template getters : fresh arrays per digest break ng-repeat).
angular.module("beamjoy").component("bjRaceInfoLive", {
    templateUrl: "/ui/modModules/beamjoy/windows/raceInfo/live/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyInfoPanel, beamjoyLeaderboardFormat) {
        const translate = (key) => $filter("translate")(key);
        const fill = (key, values) =>
            Object.entries(values).reduce((text, [k, v]) => text.replace(`{${k}}`, v), translate(key));

        this.active = false;
        this.v = null;

        // shared race time formats (hours from an hour up), see beamjoyLeaderboardFormat
        const f = beamjoyLeaderboardFormat;
        const clock = f.time;
        const secs = (ms) => (typeof ms === "number" ? f.gap(ms) : "-");
        // generic {gapMs, lapsDiff} gap : both columns come worked out by the server (raceGrid.lua's
        // gapBetween, passed on by raceRunner.lua's pushRaceInfo), each against a different racer
        const gap = (gapMs, lapsDiff) => {
            if (typeof lapsDiff === "number" && lapsDiff !== 0) {
                const n = Math.abs(lapsDiff);
                return `+${n} ${translate(n > 1 ? "beamjoy.raceHud.laps" : "beamjoy.raceHud.lap")}`;
            }
            if (typeof gapMs === "number" && gapMs !== 0) return `+${f.gapS(gapMs)}`;
            return "";
        };
        // the race time : laps plus staff penalties
        const total = (p) => (Array.isArray(p.lapTimes) ? p.lapTimes.reduce((a, b) => a + b, p.penaltyMs || 0) : null);
        // a racer's staff time penalty in seconds, for the penalty box ("5", "0.5") ; null : none to show
        const penText = (ms) => {
            const s = Math.round(ms / 100) / 10;
            return Number.isInteger(s) ? String(s) : s.toFixed(1);
        };
        const penOf = (p) => (p.penaltyMs > 0 && !p.disqualified ? penText(p.penaltyMs) : null);

        const rebuild = (data) => {
            this.active = !!data.active;
            if (!this.active) {
                this.v = null;
                return;
            }
            const laps = data.totalLaps || 1;
            const sectors = data.sectorCount || 0;
            const all = data.participants || [];
            // still racing / finished in race order first, retired racers, then disqualified ones
            const ordered = all
                .filter((p) => !p.dnf && !p.disqualified)
                .concat(all.filter((p) => p.dnf && !p.disqualified), all.filter((p) => p.disqualified));
            const multi = ordered.length > 1;

            // race-wide bests (purple)
            const fastestSector = {};
            let fastestLap = null;
            all.forEach((p) => {
                for (let s = 1; s <= sectors; s++) {
                    const ms = p.bestSectorMs && p.bestSectorMs["s" + s];
                    if (typeof ms === "number" && (fastestSector[s] === undefined || ms < fastestSector[s])) fastestSector[s] = ms;
                }
                if (typeof p.bestLapMs === "number" && (fastestLap === null || p.bestLapMs < fastestLap)) fastestLap = p.bestLapMs;
            });

            let finishedCount = 0;
            const rows = ordered.map((p, i) => {
                const own = p.lapSectors || {};
                if (p.finished) finishedCount++;
                const strip = [];
                if (sectors > 1) {
                    for (let s = 1; s <= sectors; s++) {
                        const ms = own["s" + s];
                        if (s < p.currentSector) strip.push(typeof ms === "number" && ms === fastestSector[s] ? "best" : "done");
                        else if (s === p.currentSector && !p.dnf) strip.push("live");
                        else strip.push("");
                    }
                }
                let lap;
                if (p.disqualified) lap = translate("beamjoy.raceInfo.dsq");
                else if (p.dnf) lap = translate("beamjoy.raceInfo.out");
                else if (p.finished) lap = translate("beamjoy.raceInfo.done");
                else if (laps > 1) lap = `${p.currentLap}/${laps}`;
                else if (sectors > 1) lap = `${p.currentSector}/${sectors}`;
                else lap = "";

                // multi-lap : the last lap ; a single-lap stage : the last sector
                let last = "-";
                let lastCls = "";
                if (laps > 1) {
                    const t = Array.isArray(p.lapTimes) && p.lapTimes.length > 0 ? p.lapTimes[p.lapTimes.length - 1] : undefined;
                    last = clock(t);
                    lastCls = typeof t === "number" && t === fastestLap ? "fast" : "";
                } else if (sectors > 1 && p.currentSector > 1) {
                    const s = p.finished ? sectors : p.currentSector - 1;
                    const t = own["s" + s];
                    last = secs(t);
                    lastCls = typeof t === "number" && t === fastestSector[s] ? "fast" : "";
                }
                return {
                    pos: p.disqualified ? "DSQ" : p.dnf ? "DNF" : String(i + 1),
                    plateCls: p.disqualified ? "dsq" : p.dnf ? "out" : i === 0 ? "p1" : p.playerName === data.selfPlayerName ? "you" : "",
                    rowCls: (p.playerName === data.selfPlayerName ? "you" : p.dnf || p.disqualified ? "out" : "") +
                        (p.disqualified ? " dsq" : ""),
                    name: p.displayName || p.playerName,
                    pen: penOf(p),
                    car: p.vehicleModel || "",
                    finished: !!p.finished && !p.disqualified,
                    total: clock(total(p)),
                    strip,
                    lap,
                    last,
                    lastCls,
                    ahead: i === 0 || p.dnf || p.disqualified ? "" : gap(p.aheadGapMs, p.aheadLapsDiff),
                    leader: i === 0 || p.dnf || p.disqualified ? "" : gap(p.gapMs, p.lapsDiff),
                    best: clock(p.bestLapMs),
                    bestCls: typeof p.bestLapMs === "number" && p.bestLapMs === fastestLap ? "fast" : "",
                };
            });

            const leader = ordered[0];
            const chips = [];
            if (data.state === "FINISHED") chips.push({ text: translate("beamjoy.raceInfo.finished"), cls: "ok" });
            else if (laps > 1 && leader) {
                const lap = Math.min(laps, leader.currentLap || 1);
                chips.push({ text: lap >= laps ? translate("beamjoy.raceHud.finalLap") : fill("beamjoy.raceInfo.lapOf", { n: lap, total: laps }) });
            } else if (laps <= 1) chips.push({ text: translate("beamjoy.raceInfo.pointToPoint") });
            if (sectors > 1) chips.push({ text: fill("beamjoy.raceInfo.sectorCount", { n: sectors }) });
            chips.push({ text: fill(ordered.length === 1 ? "beamjoy.raceInfo.racerCountOne" : "beamjoy.raceInfo.racerCount", { n: ordered.length }) });
            if (finishedCount > 0 && data.state !== "FINISHED") chips.push({ text: fill("beamjoy.raceInfo.finishedCount", { n: finishedCount }), flag: true });

            // columns : a solo run has no gaps, a single-lap stage no best lap, no sectors no strip
            const cols = ["2.75em", "minmax(0, 1fr)", "3.4em"];
            if (sectors > 1) cols.push("11em");
            cols.push("4.6em");
            if (multi) cols.push("5em", "5em");
            if (laps > 1) cols.push("4.6em");
            this.v = {
                cols: { "grid-template-columns": cols.join(" ") },
                rows,
                chips,
                multi,
                laps,
                sectors,
                lapHead: laps > 1 ? translate("beamjoy.raceInfo.lap") : sectors > 1 ? translate("beamjoy.raceInfo.sector") : "",
                lastHead: laps > 1 ? translate("beamjoy.raceInfo.lastLap") : translate("beamjoy.raceInfo.lastSector"),
                stripHead: laps > 1 ? translate("beamjoy.raceInfo.thisLap") : translate("beamjoy.raceInfo.stage"),
            };
        };

        const off = $rootScope.$on("BJRaceInfo", (_, data) => rebuild(data));
        $scope.$on("$destroy", off);
        this.$onInit = () => beamjoyStore.send("BJRaceInfoRequest");
        this.close = () => beamjoyInfoPanel.close();
    },
});
