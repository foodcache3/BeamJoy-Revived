// Race info > Results : the top three, the classification, and one driver's laps (you by
// default). Each lap is a row with a strip of its sectors, coloured against that driver's own best
// sector (green), the race's fastest (purple), a small loss (light grey) or a big one (amber). A lap
// opens to show its sector times. Any number of laps is just a longer list. Built once per push /
// selection (never in template getters : fresh arrays per digest break ng-repeat).
angular.module("beamjoy").component("bjRaceInfoResults", {
    templateUrl: "/ui/modModules/beamjoy/windows/raceInfo/results/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyInfoPanel, beamjoyLeaderboardFormat) {
        const translate = (key) => $filter("translate")(key);
        const fill = (key, values) =>
            Object.entries(values).reduce((text, [k, v]) => text.replace(`{${k}}`, v), translate(key));

        this.active = false;
        this.v = null;
        this.selectedPlayerName = null;
        this.openLap = null; // null : the selected driver's best lap ; -1 : none open
        let data = null;

        // shared race time formats (hours from an hour up), see beamjoyLeaderboardFormat
        const f = beamjoyLeaderboardFormat;
        const clock = f.time;
        const secs = (ms) => (typeof ms === "number" ? f.gap(ms) : "-");
        const plus = (ms) => `+${f.gap(ms)}`;
        const plusS = (ms) => `+${f.gapS(ms)}`;
        const nameOf = (p) => p.displayName || p.playerName;

        // finished (by total time) first, then still racing in race order, then retired
        const classify = (participants) => {
            const withTotals = participants.map((p) => ({
                ...p,
                totalMs: p.finished && Array.isArray(p.lapTimes) ? p.lapTimes.reduce((a, b) => a + b, 0) : null,
            }));
            const done = withTotals.filter((p) => p.totalMs !== null).sort((a, b) => a.totalMs - b.totalMs);
            const racing = withTotals.filter((p) => p.totalMs === null && !p.dnf);
            const out = withTotals.filter((p) => p.totalMs === null && p.dnf);
            return done.concat(racing, out);
        };

        const render = () => {
            if (!data || !data.active) {
                this.v = null;
                return;
            }
            const sectors = data.sectorCount || 0;
            const sectorList = Array.from({ length: sectors }, (_, i) => i + 1);
            const order = classify(data.participants || []);
            const winner = order.find((p) => p.totalMs !== null);
            const multi = order.length > 1;

            // race-wide bests (purple)
            let fastestLap = null;
            const fastestSector = {};
            order.forEach((p) => {
                if (typeof p.bestLapMs === "number" && (fastestLap === null || p.bestLapMs < fastestLap)) fastestLap = p.bestLapMs;
                sectorList.forEach((s) => {
                    const ms = p.bestSectorMs && p.bestSectorMs["s" + s];
                    if (typeof ms === "number" && (fastestSector[s] === undefined || ms < fastestSector[s])) fastestSector[s] = ms;
                });
            });

            if (!this.selectedPlayerName || !order.some((p) => p.playerName === this.selectedPlayerName)) {
                const self = order.find((p) => p.playerName === data.selfPlayerName);
                this.selectedPlayerName = (self || order[0] || {}).playerName || null;
                this.openLap = null;
            }

            const rows = order.map((p, i) => ({
                playerName: p.playerName,
                pos: p.totalMs !== null ? String(i + 1) : p.dnf ? "DNF" : String(i + 1),
                plateCls: p.dnf ? "out" : i === 0 && p.totalMs !== null ? "p1" : "",
                rowCls: (p.playerName === this.selectedPlayerName ? "sel" : "") + (p.dnf ? " out" : ""),
                selected: p.playerName === this.selectedPlayerName,
                name: nameOf(p),
                car: p.vehicleModel || "",
                total: p.totalMs !== null ? clock(p.totalMs) : translate(p.dnf ? "beamjoy.raceInfo.retired" : "beamjoy.raceInfo.racing"),
                gap: p.totalMs !== null && winner && p !== winner ? plusS(p.totalMs - winner.totalMs) : "",
                best: clock(p.bestLapMs),
                bestCls: typeof p.bestLapMs === "number" && p.bestLapMs === fastestLap ? "fast" : "",
            }));
            const podium = multi
                ? order.filter((p) => p.totalMs !== null).slice(0, 3).map((p, i) => ({
                    pos: String(i + 1),
                    name: nameOf(p),
                    line: i === 0 ? clock(p.totalMs) : plusS(p.totalMs - winner.totalMs),
                    cls: i === 0 ? "first" : "",
                    plateCls: i === 0 ? "p1" : "",
                }))
                : [];

            // the selected driver's laps
            const sel = order.find((p) => p.playerName === this.selectedPlayerName);
            let laps = [];
            let ideal = null;
            let summary = "";
            if (sel) {
                const lapTimes = Array.isArray(sel.lapTimes) ? sel.lapTimes : [];
                const pb = {};
                sectorList.forEach((s) => {
                    const ms = sel.bestSectorMs && sel.bestSectorMs["s" + s];
                    if (typeof ms === "number") pb[s] = ms;
                });
                const heat = (ms, s) => {
                    if (typeof ms !== "number") return "";
                    if (ms === fastestSector[s]) return "fast";
                    if (ms === pb[s]) return "pb";
                    const loss = ms - pb[s];
                    return loss >= 500 ? "slow" : loss <= 200 ? "near" : "ok";
                };
                const bestIdx = typeof sel.bestLapMs === "number" ? lapTimes.indexOf(sel.bestLapMs) : -1;
                const openIdx = this.openLap === null ? bestIdx : this.openLap;
                laps = lapTimes.map((t, l) => {
                    const own = (sel.lapSectorHistory && sel.lapSectorHistory["lap" + (l + 1)]) || {};
                    const d = bestIdx > -1 ? t - lapTimes[bestIdx] : 0;
                    return {
                        idx: l,
                        n: l + 1,
                        time: clock(t),
                        tCls: t === fastestLap ? "fast" : l === bestIdx ? "pbt" : d >= 1000 ? "slowt" : "",
                        delta: l === bestIdx ? translate("beamjoy.raceInfo.best") : plus(d),
                        cells: sectorList.map((s) => heat(own["s" + s], s)),
                        open: sectors > 1 && l === openIdx,
                        detail: sectorList.map((s) => {
                            const ms = own["s" + s];
                            const h = heat(ms, s);
                            const lost = typeof ms === "number" && fastestSector[s] !== undefined ? ms - fastestSector[s] : null;
                            return {
                                n: s,
                                time: secs(ms),
                                delta: lost === null ? "" : lost === 0 ? translate("beamjoy.raceInfo.fastest") : plus(lost),
                                cls: h === "fast" ? "fast" : h === "pb" ? "pbt" : h === "slow" ? "slowt" : "",
                            };
                        }),
                    };
                });
                // best possible lap : your best in every sector, once each has one
                if (sectors > 1 && sectorList.every((s) => pb[s] !== undefined) && lapTimes.length > 0) {
                    const sum = sectorList.reduce((a, s) => a + pb[s], 0);
                    ideal = {
                        time: clock(sum),
                        delta: typeof sel.bestLapMs === "number" ? `-${f.gap(Math.max(0, sel.bestLapMs - sum))}` : "",
                        cells: sectorList.map((s) => (pb[s] === fastestSector[s] ? "fast" : "pb")),
                    };
                }
                const place = order.indexOf(sel) + 1;
                if (sel.totalMs !== null && bestIdx > -1) {
                    summary = fill(multi ? "beamjoy.raceInfo.summary" : "beamjoy.raceInfo.summarySolo", {
                        pos: place,
                        time: clock(sel.bestLapMs),
                        lap: bestIdx + 1,
                    });
                } else if (sel.totalMs !== null) summary = clock(sel.totalMs);
                else summary = translate(sel.dnf ? "beamjoy.raceInfo.retired" : "beamjoy.raceInfo.racing");
            }

            const chips = [];
            chips.push(data.state === "FINISHED"
                ? { text: translate("beamjoy.raceInfo.finished"), cls: "ok" }
                : { text: translate("beamjoy.raceInfo.stillRacing") });
            const lapsTotal = data.totalLaps || 1;
            chips.push({ text: lapsTotal > 1 ? fill("beamjoy.raceInfo.lapCount", { n: lapsTotal }) : translate("beamjoy.raceInfo.pointToPoint") });
            if (sectors > 1) chips.push({ text: fill("beamjoy.raceInfo.sectorCount", { n: sectors }) });
            chips.push({ text: fill(order.length === 1 ? "beamjoy.raceInfo.racerCountOne" : "beamjoy.raceInfo.racerCount", { n: order.length }) });

            this.v = {
                chips,
                podium,
                rows,
                sel: sel ? { name: nameOf(sel), summary } : null,
                laps,
                ideal,
                sectors,
                raceId: data.raceId,
            };
        };

        const off = $rootScope.$on("BJRaceInfo", (_, d) => {
            this.active = !!d.active;
            data = d;
            render();
        });
        $scope.$on("$destroy", off);
        this.$onInit = () => beamjoyStore.send("BJRaceInfoRequest");

        this.selectPlayer = (playerName) => {
            if (playerName === this.selectedPlayerName) return;
            this.selectedPlayerName = playerName;
            this.openLap = null;
            render();
        };
        this.toggleLap = (lap) => {
            this.openLap = lap.open ? -1 : lap.idx;
            render();
        };
        this.close = () => beamjoyInfoPanel.close();
        // the race's all-time leaderboard, in the same window
        this.openLeaderboard = () => {
            const raceId = this.v ? Number(this.v.raceId) : NaN;
            if (!Number.isFinite(raceId)) return;
            beamjoyInfoPanel.push(data.raceName || "", [
                {
                    id: "leaderboard",
                    title: "beamjoy.window.main.tabs.races.leaderboard.title",
                    template: `<bj-race-leaderboard race-id="${raceId}"></bj-race-leaderboard>`,
                },
            ], "leaderboard");
        };
    },
});
