// Race info > Results : the top three, the classification, and one driver's laps (you by
// default). Each lap is a row with a strip of its sectors, coloured against that driver's own best
// sector (green), the race's fastest (purple), a small loss (light grey) or a big one (amber). A lap
// opens to show its sector times. Any number of laps is just a longer list. Built once per push /
// selection (never in template getters : fresh arrays per digest break ng-repeat).
// An event of several phases (services/racePhases.lua) : a tab per phase run so far, and the
// event's standings ; each phase classified by its own ranking (race order, best lap, total time).
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
        // the tab : "live" (the phase under way), "p1", "p2"... (a phase run), "event" ; null : the
        // latest
        this.view = null;
        this.views = [];
        let data = null;

        // shared race time formats (hours from an hour up), see beamjoyLeaderboardFormat
        const f = beamjoyLeaderboardFormat;
        const clock = f.time;
        const secs = (ms) => (typeof ms === "number" ? f.gap(ms) : "-");
        const plus = (ms) => `+${f.gap(ms)}`;
        const plusS = (ms) => `+${f.gapS(ms)}`;
        const nameOf = (p) => p.displayName || p.playerName;
        // a racer's staff time penalty in seconds, for the penalty box ("5", "0.5") ; null : none to show
        const penText = (ms) => {
            const s = Math.round(ms / 100) / 10;
            return Number.isInteger(s) ? String(s) : s.toFixed(1);
        };
        const penOf = (p) => (p.penaltyMs > 0 && !p.disqualified ? penText(p.penaltyMs) : null);

        // a race under way : finished (by race time : laps plus staff penalties) first, then still
        // racing in race order, then retired, then disqualified. Its `score` is that race time
        const classify = (participants) => {
            const withTotals = participants.map((p) => ({
                ...p,
                totalMs: p.finished && !p.disqualified && Array.isArray(p.lapTimes)
                    ? p.lapTimes.reduce((a, b) => a + b, p.penaltyMs || 0)
                    : null,
            }));
            withTotals.forEach((p) => (p.score = p.totalMs));
            const done = withTotals.filter((p) => p.totalMs !== null).sort((a, b) => a.totalMs - b.totalMs);
            const racing = withTotals.filter((p) => p.totalMs === null && !p.dnf && !p.disqualified);
            const out = withTotals.filter((p) => p.totalMs === null && p.dnf && !p.disqualified);
            const dsq = withTotals.filter((p) => p.disqualified);
            return done.concat(racing, out, dsq);
        };
        // already in order (the server's standings, a phase's results) : placed by best lap, or by
        // their time ; `score` is what they're placed by, null without a place
        const ordered = (rows, ranking, done) =>
            rows.map((p) => {
                const best = ranking === "best";
                // a plugin's ranking : its scores, shown as it writes them ("86 pts")
                const plugin = ranking === "plugin";
                const hasScore = p.score !== undefined && p.score !== null;
                const placed = done ? p.position != null : best ? typeof p.bestLapMs === "number" && !p.disqualified
                    : plugin ? (p.scoreKey !== undefined && p.scoreKey !== null) && !p.disqualified
                    : p.finished && !p.disqualified;
                const totalMs = typeof p.totalMs === "number" ? p.totalMs
                    : Array.isArray(p.lapTimes) && p.lapTimes.length > 0 ? p.lapTimes.reduce((a, b) => a + b, p.penaltyMs || 0) : null;
                return {
                    ...p,
                    totalMs: best || plugin ? null : placed ? totalMs : null,
                    score: placed ? (best ? p.bestLapMs : plugin ? (hasScore ? p.score : 0) : totalMs) : null,
                    text: plugin && placed ? p.scoreDisplay || (hasScore ? String(p.score) : "") : null,
                };
            });

        // what the tab shows : its racers, how they're ranked, whether it's over, its phase
        const viewData = () => {
            const phases = Array.isArray(data.phases) ? data.phases : [];
            const results = data.phaseResults || {};
            if (this.view === "event" && Array.isArray(data.eventStandings)) {
                let ranking = "total";
                if (data.eventResult !== "sum") {
                    // the latest phase counted
                    for (let i = phases.length; i >= 1; i--) {
                        if (results["p" + i] && phases[i - 1].countsToEvent !== false) {
                            ranking = phases[i - 1].ranking || "position";
                            break;
                        }
                    }
                }
                return { rows: ordered(data.eventStandings, ranking, true), ranking, done: true, event: true,
                    index: Math.max(0, ...Object.keys(results).map((k) => Number(k.slice(1)) || 0)) };
            }
            const m = /^p(\d+)$/.exec(this.view || "");
            if (m && results[this.view]) {
                const phase = phases[Number(m[1]) - 1] || {};
                const ranking = phase.ranking || "position";
                return { rows: ordered(results[this.view], ranking, true), ranking, done: true, phase, index: Number(m[1]) };
            }
            const ranking = data.ranking || "position";
            const live = data.participants || [];
            return {
                rows: ranking === "position" ? classify(live) : ordered(live, ranking, false),
                ranking,
                done: data.state === "FINISHED" || data.state === "BREAK",
                phase: phases[(data.phaseIndex || 1) - 1] || null,
                index: data.phaseIndex || 1,
            };
        };
        // a knockout (direct request) : the first phase after this one taking only the top n of its
        // result (of the event's standings, for that tab) ; null when none does
        const cutFor = (vd) => {
            const phases = Array.isArray(data.phases) ? data.phases : [];
            for (let j = vd.index + 1; j <= phases.length; j++) {
                const takes = phases[j - 1].takes;
                if (!takes || typeof takes.top !== "number") continue;
                const fromHere = vd.event ? !takes.from : takes.from === vd.index;
                if (fromHere) {
                    const name = phases[j - 1].name || fill("beamjoy.racePhases.phaseN", { n: j });
                    return { top: takes.top, label: fill("beamjoy.raceInfo.cutLine", { top: takes.top, phase: name }) };
                }
            }
            return null;
        };
        // the tabs : every phase run so far, the one under way, the event (several phases only)
        const buildViews = () => {
            const phases = Array.isArray(data.phases) ? data.phases : [];
            const results = data.phaseResults || {};
            const label = (p, i) => (p && p.name) || translate("beamjoy.racePhases.phaseN").replace("{n}", i + 1);
            const views = [];
            phases.forEach((p, i) => {
                if (results["p" + (i + 1)]) views.push({ id: "p" + (i + 1), label: label(p, i) });
            });
            const index = data.phaseIndex || 1;
            const running = data.state === "RACE" || data.state === "COUNTDOWN";
            if (running && !results["p" + index]) views.push({ id: "live", label: label(phases[index - 1], index - 1) });
            if (phases.length > 1 && Array.isArray(data.eventStandings)) {
                views.push({ id: "event", label: translate("beamjoy.raceInfo.eventTab") });
            }
            this.views = views.length > 1 ? views : [];
            // the one picked while it's there, else the latest : the phase under way, or the last run
            if (this.pickedView && views.some((v) => v.id === this.pickedView)) this.view = this.pickedView;
            else if (running) this.view = "live";
            else {
                const run = views.filter((v) => v.id !== "event");
                this.view = run.length > 0 ? run[run.length - 1].id : "live";
            }
        };
        this.pickedView = null;
        this.setView = (id) => {
            if (id === this.view) return;
            this.pickedView = id;
            this.view = id;
            this.openLap = null;
            render();
        };

        // the selected driver's card : their penalty (the box), and their race time with it once
        // finished, else when it applies
        const selected = (sel, summary) => {
            const pen = penOf(sel);
            const lapsMs = Array.isArray(sel.lapTimes) ? sel.lapTimes.reduce((a, b) => a + b, 0) : 0;
            const done = sel.totalMs !== null;
            return {
                name: nameOf(sel),
                fields: Array.isArray(sel.fields) && sel.fields.length > 0 ? sel.fields : null,
                summary,
                pen,
                raceTime: pen && done ? clock(sel.totalMs) : "",
                penNote: !pen ? "" : done
                    ? fill("beamjoy.raceInfo.penaltyNote", { laps: clock(lapsMs) })
                    : translate("beamjoy.raceInfo.penaltyPending"),
            };
        };

        const render = () => {
            if (!data || !data.active) {
                this.v = null;
                return;
            }
            buildViews();
            const vd = viewData();
            const best = vd.ranking === "best";
            const sectors = data.sectorCount || 0;
            const sectorList = Array.from({ length: sectors }, (_, i) => i + 1);
            const order = vd.rows;
            const winner = order.find((p) => p.score !== null && p.score !== undefined);
            const placed = (p) => p.score !== null && p.score !== undefined;
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

            // a knockout : the ones going through (the first n placed ; while it runs, the first n
            // still in it), a line under the last of them, the others out
            const cut = cutFor(vd);
            const through = (p, i) => !!cut && i < cut.top && !p.disqualified && !(p.dnf && !placed(p)) && (placed(p) || !vd.done);
            const lastThrough = cut ? order.reduce((last, p, i) => (through(p, i) ? i : last), -1) : -1;
            const rows = order.map((p, i) => ({
                playerName: p.playerName,
                cutAfter: lastThrough >= 0 && i === lastThrough && i < order.length - 1,
                pos: p.disqualified ? "DSQ" : placed(p) ? String(i + 1) : p.dnf ? "DNF" : String(i + 1),
                plateCls: p.disqualified ? "dsq" : p.dnf && !placed(p) ? "out" : i === 0 && placed(p) ? "p1" : "",
                rowCls: (p.playerName === this.selectedPlayerName ? "sel" : "") + ((p.dnf && !placed(p)) || p.disqualified ? " out" : "") +
                    (p.disqualified ? " dsq" : "") + (cut ? (through(p, i) ? " adv" : " elim") : ""),
                selected: p.playerName === this.selectedPlayerName,
                name: nameOf(p),
                pen: penOf(p),
                car: p.vehicleModel || "",
                // server plugins' labels on this racer (cmps/pluginOptions bj-plugin-fields)
                fields: Array.isArray(p.fields) && p.fields.length > 0 ? p.fields : null,
                // their place's time : race time, or best lap (practice, qualifying)
                total: placed(p)
                    ? p.text || clock(p.score)
                    : translate(p.disqualified ? "beamjoy.raceInfo.disqualified" : best && !p.dnf ? "beamjoy.raceInfo.noTime"
                        : p.dnf || vd.done ? "beamjoy.raceInfo.retired" : "beamjoy.raceInfo.racing"),
                gap: placed(p) && winner && p !== winner && !p.text ? plusS(p.score - winner.score) : "",
                best: clock(p.bestLapMs),
                bestCls: typeof p.bestLapMs === "number" && p.bestLapMs === fastestLap ? "fast" : "",
            }));
            const podium = multi
                ? order.filter(placed).slice(0, 3).map((p, i) => ({
                    pos: String(i + 1),
                    name: nameOf(p),
                    line: p.text || (i === 0 ? clock(p.score) : plusS(p.score - winner.score)),
                    pen: penOf(p),
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
                if (placed(sel) && bestIdx > -1) {
                    summary = fill(multi ? "beamjoy.raceInfo.summary" : "beamjoy.raceInfo.summarySolo", {
                        pos: place,
                        time: clock(sel.bestLapMs),
                        lap: bestIdx + 1,
                    });
                } else if (placed(sel)) summary = sel.text || clock(sel.score);
                else summary = translate(sel.disqualified ? "beamjoy.raceInfo.disqualified" : sel.dnf ? "beamjoy.raceInfo.retired" : "beamjoy.raceInfo.racing");
            }

            const chips = [];
            chips.push(vd.done
                ? { text: translate("beamjoy.raceInfo.finished"), cls: "ok" }
                : { text: translate("beamjoy.raceInfo.stillRacing") });
            // the phase's length : laps, minutes, or both
            const phase = vd.phase || {};
            const lapsTotal = vd.phase ? phase.laps : data.totalLaps || 1;
            const minutes = vd.phase ? phase.timeLimitMin : null;
            if (vd.event) chips.push({ text: translate(data.eventResult === "sum" ? "beamjoy.racePhases.results.sum" : "beamjoy.racePhases.results.last") });
            else if (typeof minutes === "number") {
                const time = fill("beamjoy.racePhases.minutesN", { n: minutes });
                chips.push({ text: typeof lapsTotal === "number" ? `${time} / ${fill("beamjoy.raceInfo.lapCount", { n: lapsTotal })}` : time });
            } else chips.push({ text: lapsTotal > 1 ? fill("beamjoy.raceInfo.lapCount", { n: lapsTotal }) : translate("beamjoy.raceInfo.pointToPoint") });
            if (best && !vd.event) chips.push({ text: translate("beamjoy.racePhases.rankings.best") });
            if (sectors > 1) chips.push({ text: fill("beamjoy.raceInfo.sectorCount", { n: sectors }) });
            chips.push({ text: fill(order.length === 1 ? "beamjoy.raceInfo.racerCountOne" : "beamjoy.raceInfo.racerCount", { n: order.length }) });

            this.v = {
                chips,
                podium,
                rows,
                cut,
                views: this.views,
                // anyone penalised : the Total column widens for the box
                hasPen: rows.some((r) => r.pen),
                sel: sel ? selected(sel, summary) : null,
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
