// Drag timeslip (beamjoy/dragRun.lua, BJDragTimeslip) : the last run on a drag strip, printed the
// way the tower prints it (both lanes, every mark, dial-in, who won), next to what it means on this
// server (your best, the strip's record, where you gained or lost against your old best, the strip's
// board). Opened from the drag overlay ; B or Close shuts it.
angular.module("beamjoy").component("bjDragTimeslip", {
    templateUrl: "/ui/modModules/beamjoy/windows/dragTimeslip/app.html",
    controller: function ($rootScope, $scope, beamjoyStore, beamjoyDelivery, beamjoyDragFormat) {
        const f = beamjoyDragFormat;
        this.open = false;
        this.s = null;
        let cache = null;

        $rootScope.$on("BJDragTimeslip", (_, data) => {
            $scope.$applyAsync(() => {
                this.open = !!(data && data.open && data.slip);
                this.s = (data && data.slip) || this.s;
                cache = null;
                beamjoyDelivery.setNavOwner("dragTimeslip", this.open);
            });
        });
        this.$onInit = () => beamjoyStore.send("BJDragTimeslipRequest");

        const imperial = () => !!(this.s && this.s.imperial);
        const unitLabel = () => (imperial() ? "MPH" : "KM/H");

        // the lanes as printed : left lane on the left when the strip names them
        this.columns = () => {
            const lanes = ((this.s && this.s.lanes) || []).filter((l) => l);
            if (lanes.length === 2) {
                const isLeft = (l) => String(l.laneName || "").toLowerCase().startsWith("left");
                if (isLeft(lanes[1]) || (!isLeft(lanes[0]) && lanes[1].lane < lanes[0].lane)) lanes.reverse();
            }
            return lanes;
        };
        const marks = () => (this.s && this.s.marks) || [];
        const mainId = () => this.s && this.s.mainId;
        const pkg = (lane) => (lane && !lane.dq ? f.packageAt(lane.values || {}, marks(), mainId()) : null);

        // who won : lower reaction + time, a disqualified lane loses
        this.winner = () => {
            const cols = this.columns();
            if (cols.length < 2) return null;
            const [a, b] = cols;
            if (a.dq && !b.dq) return { index: 1, by: null };
            if (b.dq && !a.dq) return { index: 0, by: null };
            const pa = pkg(a), pb = pkg(b);
            if (pa === null || pb === null) return null;
            return { index: pa <= pb ? 0 : 1, by: Math.abs(pa - pb) };
        };

        // the printed rows
        this.rows = () => {
            if (cache) return cache;
            const cols = this.columns();
            const win = this.winner();
            const cell = (lane, m) => {
                const v = lane && lane.values ? lane.values[m.id] : null;
                if (!f.num(v)) return "—";
                return m.kind === "speed" ? f.speed(v, imperial(), 2) : f.secs(v);
            };
            const rows = [];
            rows.push({
                key: "dial", label: "DIAL", bold: false,
                cells: cols.map((l) => ({ text: f.num(l.dial) && l.dial > 0 ? f.secs(l.dial, 2) : "—" })),
            });
            let afterMain = false;
            marks().forEach((m) => {
                const isMain = m.id === mainId();
                const label = m.kind === "reaction" ? "R/T" : m.kind === "speed" ? unitLabel() : m.label;
                const bold = isMain || (afterMain && m.kind === "speed");
                rows.push({
                    key: m.id, label, bold,
                    cells: cols.map((l, i) => ({ text: cell(l, m), win: isMain && win && win.index === i })),
                });
                afterMain = isMain;
            });
            rows.push({
                key: "diff", label: "DIFF", bold: false,
                cells: cols.map((l) => {
                    const et = l.values ? l.values[mainId()] : null;
                    if (!f.num(l.dial) || l.dial <= 0 || !f.num(et)) return { text: "—" };
                    const d = et - l.dial;
                    return { text: (d >= 0 ? "+" : "−") + Math.abs(d).toFixed(3) };
                }),
            });
            cache = rows;
            return rows;
        };
        this.laneHead = (l) => String(l.laneName || l.lane || "").toUpperCase();

        this.footLine = () => {
            const cols = this.columns();
            const dq = cols.find((l) => l.dq);
            if (cols.length < 2) return f.translate("beamjoy.drag.slip.solo");
            const win = this.winner();
            if (!win) {
                const other = cols.find((l) => !l.you);
                return f.fill("beamjoy.drag.slip.waiting", { name: (other && other.name) || "" }).toUpperCase();
            }
            const lane = this.laneHead(cols[win.index]);
            if (win.by === null) return f.fill("beamjoy.drag.slip.winnerDq", { lane, reason: dq ? dq.dq : "" }).toUpperCase();
            return f.fill("beamjoy.drag.slip.winner", { lane, n: win.by.toFixed(3) }).toUpperCase();
        };
        this.noteLine = () => {
            const anyDial = this.columns().some((l) => f.num(l.dial) && l.dial > 0);
            return f.translate(anyDial ? "beamjoy.drag.slip.dialed" : "beamjoy.drag.slip.headsUp").toUpperCase();
        };
        this.conditions = () => {
            if (!this.s) return "";
            const t = f.num(this.s.tempC) ? `${Math.round(this.s.tempC)} C` : "";
            const g = f.num(this.s.gravity) ? `GRAVITY ${this.s.gravity.toFixed(2)}` : "";
            return [t, g].filter((x) => x).join("  ");
        };
        this.treeText = () => f.translate(`beamjoy.drag.tree.${(this.s && this.s.tree) || "sportsman"}`).toUpperCase();

        // ON THIS SERVER
        const me = () => this.columns().find((l) => l.you) || null;
        const myEt = () => (me() && me().values ? me().values[mainId()] : null);
        this.bestCard = () => {
            const r = this.s && this.s.result;
            const old = this.s && this.s.best;
            const et = myEt();
            if (!f.num(et)) return null;
            if (r && r.saved === false) return { title: f.translate("beamjoy.drag.slip.notKept"), line: f.translate("beamjoy.drag.result.guest"), sub: "", value: f.secs(et), cls: "" };
            if (r && r.best) {
                return {
                    title: f.translate("beamjoy.drag.slip.newBest"),
                    line: old && f.num(old.et) ? f.fill("beamjoy.drag.slip.faster", { n: (old.et - et).toFixed(3) }) : f.translate("beamjoy.drag.slip.firstTime"),
                    sub: old && f.num(old.et) ? f.fill("beamjoy.drag.slip.was", { time: f.secs(old.et) }) : "",
                    value: f.secs(et), cls: "good",
                };
            }
            return {
                title: f.translate("beamjoy.drag.yourBest"),
                line: old && f.num(old.et) ? f.fill("beamjoy.drag.slip.slower", { n: (et - old.et).toFixed(3) }) : "",
                sub: f.fill("beamjoy.drag.slip.thisRun", { time: f.secs(et) }),
                value: old && f.num(old.et) ? f.secs(old.et) : f.secs(et), cls: "me",
            };
        };
        const board = () => (this.s && this.s.board) || null;
        this.recordCard = () => {
            const b = board();
            const rec = b && b.rows && b.rows[0];
            if (!rec) return null;
            const et = myEt();
            const off = f.num(et) && et > rec.et ? f.fill("beamjoy.drag.slip.offRecord", { n: (et - rec.et).toFixed(3) })
                : f.translate("beamjoy.drag.slip.holdRecord");
            return { name: rec.vehicle ? `${rec.name}, ${rec.vehicle}` : rec.name, value: f.secs(rec.et), line: off };
        };

        // where this run gained or lost against your old best, mark by mark
        this.splits = () => {
            const old = this.s && this.s.best && this.s.best.splits;
            const mine = me() && me().values;
            if (!old || !mine) return [];
            const SCALE = 0.08;
            return marks().filter((m) => m.kind !== "speed" && f.num(old[m.id]) && f.num(mine[m.id])).map((m) => {
                const d = mine[m.id] - old[m.id];
                const half = Math.min(1, Math.abs(d) / SCALE) * 50;
                return {
                    key: m.id,
                    label: m.kind === "reaction" ? f.translate("beamjoy.drag.mark.reaction") : m.label,
                    text: (d > 0 ? "+" : d < 0 ? "−" : "±") + Math.abs(d).toFixed(3),
                    cls: d > 0 ? "slow" : "good",
                    left: d < 0 ? `${50 - half}%` : "50%",
                    width: `${half}%`,
                };
            });
        };

        // the strip's board : the top four, and your row if you're further down
        this.boardRows = () => {
            const b = board();
            if (!b || !b.rows) return [];
            const rows = b.rows.slice(0, 4);
            if (b.mine && b.mine.rank > 4) rows.push(b.mine);
            return rows.map((r) => ({
                key: `${r.rank}`, rank: r.rank, name: r.name, car: r.vehicle || "", time: f.secs(r.et),
                you: !!r.you, rec: r.rank === 1,
            }));
        };
        this.driversText = () => f.fill("beamjoy.drag.drivers", { n: (board() && board().players) || 0 });

        this.close = () => beamjoyStore.send("BJDragTimeslipClose");
        this.openLeaderboard = () => {
            $rootScope.bjChallengeSpot = this.s && this.s.stripId;
            $rootScope.$broadcast("BJMainOpenLeaderboards", "drag");
            this.close();
        };

        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.open || !rising) return;
            $scope.$applyAsync(() => {
                if (name === "back") this.close();
            });
        });
        $scope.$on("$destroy", () => {
            offNav();
            beamjoyDelivery.setNavOwner("dragTimeslip", false);
        });
    },
});
