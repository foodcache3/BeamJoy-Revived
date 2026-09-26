// The race HUD, in one of three layouts chosen in Settings > Menu (stored per player, like the
// rail's position) :
//   standard : position, the gaps to the cars either side, lap + running timer, the sector strip,
//              and a short standings list (the leader, then the cars around you)
//   compact  : the essentials only, the old HUD's information in the new style
//   full     : every racer with their gap to the leader, for broadcasting / spectating
// Everything shown is built once per BJRaceHud push (~20/s while racing, see raceRunner.lua's
// pushHud), never in template getters : fresh arrays per digest break ng-repeat.
const RACE_HUD_LAYOUT_KEY = "beamjoy.raceHud.layout";
const RACE_HUD_LAYOUTS = ["standard", "compact", "full"];

angular.module("beamjoy").component("bjRaceHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/raceHud/app.html",
    controller: function ($rootScope, $scope, $filter, $interval, beamjoyStore, beamjoyDelivery, beamjoyInfoPanel) {
        const translate = (key) => $filter("translate")(key);
        const fill = (key, values) =>
            Object.entries(values).reduce((text, [k, v]) => text.replace(`{${k}}`, v), translate(key));

        this.active = false;
        this.v = null;

        this.layout = "standard";
        try {
            const saved = localStorage.getItem(RACE_HUD_LAYOUT_KEY);
            if (RACE_HUD_LAYOUTS.includes(saved)) this.layout = saved;
        } catch (e) {
            // storage unavailable : the standard layout
        }
        $rootScope.$on("BJRaceHudLayout", (_, layout) => {
            if (RACE_HUD_LAYOUTS.includes(layout)) this.layout = layout;
        });

        // 1:48.21 for lap times and clocks
        const clock = (ms) => {
            if (typeof ms !== "number" || ms < 0) return "-";
            const totalSec = ms / 1000;
            const min = Math.floor(totalSec / 60);
            return `${min}:${(totalSec % 60).toFixed(2).padStart(5, "0")}`;
        };
        // a gap as a number and its unit, direction left to the arrows : {num: "2.31", unit: "s"}
        const gapParts = (desc) => {
            if (!desc) return null;
            if (typeof desc.lapsDiff === "number" && desc.lapsDiff !== 0) {
                const n = Math.abs(desc.lapsDiff);
                return { num: String(n), unit: ` ${translate(n > 1 ? "beamjoy.raceHud.laps" : "beamjoy.raceHud.lap")}` };
            }
            if (typeof desc.gapMs === "number") return { num: (Math.abs(desc.gapMs) / 1000).toFixed(2), unit: "s" };
            return { num: "", unit: "" };
        };
        // "+4.28" / "+1 lap" behind the leader
        const leaderGap = (row) => {
            if (typeof row.leaderLapsDiff === "number" && row.leaderLapsDiff !== 0) {
                const n = Math.abs(row.leaderLapsDiff);
                return `+${n} ${translate(n > 1 ? "beamjoy.raceHud.laps" : "beamjoy.raceHud.lap")}`;
            }
            if (typeof row.leaderGapMs === "number") return `+${(Math.abs(row.leaderGapMs) / 1000).toFixed(2)}`;
            return "";
        };
        const nameOf = (row) => (row && (row.displayName || row.playerName)) || "";

        const build = (data) => {
            const self = data.self || {};
            const laps = data.totalLaps || 1;
            const sectors = data.totalSectors || 0;
            const standings = Array.isArray(data.standings) ? data.standings : [];
            const v = {
                raceName: data.raceName,
                spectating: data.spectatingPlayerName
                    ? fill("beamjoy.raceHud.spectating", { name: nameOf(self) })
                    : null,
                multi: typeof data.position === "number" && standings.length > 1,
                pos: data.position,
                count: data.totalRacers,
                finishedCount: data.finishedCount || 0,
                finished: !!self.finished,
                dnf: !!self.dnf,
            };
            v.ofCount = fill("beamjoy.raceHud.ofCount", { n: v.count });
            v.finishedText = fill("beamjoy.raceHud.finishedCount", { n: v.finishedCount });

            // where you are : the lap on a multi-lap race, else the sector (or gate) of the stage
            v.progressOf = "";
            if (self.finished) v.progress = translate("beamjoy.raceHud.finished");
            else if (self.dnf) v.progress = translate("beamjoy.raceHud.retired");
            else if (laps > 1 && self.currentLap >= laps) v.progress = translate("beamjoy.raceHud.finalLap");
            else if (laps > 1) {
                v.progress = fill("beamjoy.raceHud.lapN", { n: self.currentLap });
                v.progressOf = `/${laps}`;
            } else if (sectors > 1) {
                v.progress = fill("beamjoy.raceHud.sectorN", { n: self.currentSector });
                v.progressOf = `/${sectors}`;
            } else {
                v.progress = fill("beamjoy.raceHud.gateN", { n: self.currentGate });
                v.progressOf = `/${data.totalGates}`;
            }

            // running clock : this lap on a multi-lap race, the whole run otherwise
            v.timer = clock(laps > 1 ? self.currentLapElapsedMs : data.elapsedMs);
            if (typeof self.liveDeltaMs === "number" && !self.finished && !self.dnf) {
                v.delta = `${self.liveDeltaMs <= 0 ? "-" : "+"}${(Math.abs(self.liveDeltaMs) / 1000).toFixed(2)}`;
                v.deltaCls = self.liveDeltaMs <= 0 ? "faster" : "slower";
            } else v.delta = null;
            v.showLaps = laps > 1 && typeof self.lastLapMs === "number";
            v.last = clock(self.lastLapMs);
            v.best = clock(self.bestLapMs);

            // this lap's sectors : done, fastest anyone has set (purple), the one you're in
            v.secs = [];
            if (sectors > 1 && !self.finished && !self.dnf) {
                const own = self.lapSectors || {};
                const fastest = data.fastestSectorMs || {};
                for (let s = 1; s <= sectors; s++) {
                    const ms = own["s" + s];
                    if (s < self.currentSector) v.secs.push(typeof ms === "number" && ms === fastest["s" + s] ? "best" : "done");
                    else if (s === self.currentSector) v.secs.push("live");
                    else v.secs.push("");
                }
            }

            // the cars either side of you
            v.ahead = null;
            v.behind = null;
            if (v.multi) {
                if (data.ahead) v.ahead = { ...gapParts(data.ahead), name: nameOf(data.ahead), fin: !!data.ahead.finished };
                if (data.behind && !data.behind.dnf) v.behind = { ...gapParts(data.behind), name: nameOf(data.behind), fin: !!data.behind.finished };
            }

            // the standings, one row per racer
            const rowOf = (row, i) => {
                const lead = i === 0;
                let gap = "";
                if (row.dnf) gap = translate("beamjoy.raceHud.out");
                else if (lead) gap = row.finished ? clock(row.totalMs) : "";
                else gap = leaderGap(row);
                return {
                    kind: "car",
                    pos: row.dnf ? "-" : String(i + 1),
                    plateCls: row.dnf ? "out" : lead ? "p1" : "",
                    rowCls: row.playerName === self.playerName ? "you" : row.dnf ? "out" : "",
                    name: nameOf(row),
                    fin: !!row.finished,
                    gap,
                    gapCls: row.dnf ? "soft" : "",
                };
            };
            v.full = standings.map(rowOf);

            // standard layout's short list : the leader, then the cars around you, the rest folded
            // (a folded group says how many in it have finished, so no flag goes unseen)
            v.short = [];
            if (v.multi) {
                const me = Math.max(0, (data.position || 1) - 1);
                const fold = (from, to) => {
                    const n = standings.slice(from, to + 1).filter((r) => r.finished).length;
                    const range = from === to ? `P${from + 1}` : fill("beamjoy.raceHud.range", { from: from + 1, to: to + 1 });
                    return { kind: "fold", text: n > 0 ? fill("beamjoy.raceHud.foldFinished", { range, n }) : range };
                };
                const lo = Math.max(1, me - 1);
                const hi = Math.min(standings.length - 1, me + 1);
                v.short.push(v.full[0]);
                if (lo > 1) v.short.push(fold(1, lo - 1));
                for (let i = lo; i <= hi; i++) v.short.push(v.full[i]);
                if (hi < standings.length - 1) v.short.push(fold(hi + 1, standings.length - 1));
            }

            // full layout's header : the leader's lap, and how far through the race they are
            const leadRow = standings[0];
            const leadLap = leadRow ? Math.min(laps, leadRow.currentLap || 1) : self.currentLap || 1;
            v.fullLap = laps > 1 && leadLap < laps ? fill("beamjoy.raceHud.lapN", { n: leadLap }) : laps > 1 ? translate("beamjoy.raceHud.finalLap") : "";
            v.fullLapOf = laps > 1 && leadLap < laps ? `/${laps}` : "";
            const gates = data.totalGates || 1;
            const done = leadRow
                ? leadRow.finished ? 1 : ((Math.max(1, leadRow.currentLap || 1) - 1) * gates + (leadRow.currentGate || 0)) / (laps * gates)
                : 0;
            v.progressPct = `${Math.round(Math.min(1, Math.max(0, done)) * 100)}%`;
            v.fastestLap = data.fastestLap
                ? { name: nameOf(data.fastestLap), time: clock(data.fastestLap.ms) }
                : null;
            return v;
        };

        $rootScope.$on("BJRaceHud", (_, data) => {
            this.active = !!data.active;
            this.v = this.active ? build(data) : null;
            if (this.v) {
                // Retire only for your own run, while it's still going
                this.v.canRetire = !data.spectatingPlayerName && !this.v.finished && !this.v.dnf;
                if (!this.v.canRetire && this.cursor > 0) this.cursor = 0;
            }
        });

        // FOCUS : the Focus control during a race (beamjoy/mainNav.lua) gives the HUD the pad and
        // shows its Race info / Retire buttons ; B (or the control again) lets go
        this.focused = false;
        this.cursor = 0;
        $rootScope.$on("BJRaceHudFocus", (_, data) => {
            $rootScope.$applyAsync(() => {
                this.focused = !!(data && data.active);
                this.cursor = 0;
                cancelRetire();
                beamjoyDelivery.setNavOwner("raceHud", this.focused);
            });
        });
        this.openRaceInfo = () => {
            beamjoyInfoPanel.open((this.v && this.v.raceName) || "", [
                { id: "live", title: "beamjoy.window.main.tabs.races.raceInfo.live", template: "<bj-race-info-live></bj-race-info-live>" },
                { id: "results", title: "beamjoy.window.main.tabs.races.raceInfo.results", template: "<bj-race-info-results></bj-race-info-results>" },
            ], "live");
        };
        // a stray press mid-race mustn't end your run : Retire is a 5 s hold (A, or the mouse),
        // letting go early cancels. retireProgress (0..1) fills the button
        const RETIRE_HOLD_MS = 5000;
        this.retireProgress = 0;
        let holdStart = null;
        let holdTick = null;
        const cancelRetire = () => {
            $interval.cancel(holdTick);
            holdTick = null;
            holdStart = null;
            this.retireProgress = 0;
        };
        this.startRetire = () => {
            if (!this.v || !this.v.canRetire || holdStart !== null) return;
            holdStart = Date.now();
            holdTick = $interval(() => {
                this.retireProgress = Math.min(1, (Date.now() - holdStart) / RETIRE_HOLD_MS);
                if (this.retireProgress >= 1) {
                    cancelRetire();
                    beamjoyStore.send("BJRaceRetire");
                }
            }, 50);
        };
        this.stopRetire = () => cancelRetire();
        this.retireFill = () => ({ width: `${Math.round(this.retireProgress * 100)}%` });
        this.buttons = () => (this.v && this.v.canRetire ? ["info", "retire"] : ["info"]);
        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            // letting go of A ends a Retire hold, whatever else is going on
            if (name === "ok" && Number(value) <= 0.5 && holdStart !== null) {
                $scope.$applyAsync(() => cancelRetire());
                return;
            }
            // the race info overlay opened from here has the pad while it's up
            if (!this.focused || !rising || beamjoyDelivery.otherNavOwner("raceHud")) return;
            $scope.$applyAsync(() => {
                const n = this.buttons().length;
                if (name === "focus_l" || name === "focus_u") {
                    cancelRetire();
                    this.cursor = Math.max(0, this.cursor - 1);
                } else if (name === "focus_r" || name === "focus_d") {
                    cancelRetire();
                    this.cursor = Math.min(n - 1, this.cursor + 1);
                } else if (name === "ok") {
                    if (this.buttons()[this.cursor] === "retire") this.startRetire();
                    else this.openRaceInfo();
                } else if (name === "back") beamjoyStore.send("BJRaceHudRelease");
            });
        });
        $scope.$on("$destroy", () => {
            offNav();
            cancelRetire();
            beamjoyDelivery.setNavOwner("raceHud", false);
        });
    },
});
