// Drag strip overlay, top right (beamjoy/dragRun.lua, BJDragHud) : shown while this game's car is in
// a lane of one of the game's drag strips. Each mark fills in as the car passes it, with the gap to
// this player's best on the strip at that mark ; the other lane's player (paired by the server) is
// compared on reaction + time. "Open timeslip" opens windows/dragTimeslip.
angular.module("beamjoy").factory("beamjoyDragFormat", function ($filter) {
    const translate = $filter("translate");
    const fill = (key, vars) => {
        let s = translate(key);
        Object.keys(vars || {}).forEach((k) => (s = s.split(`{${k}}`).join(vars[k])));
        return s;
    };
    const num = (v) => typeof v === "number" && isFinite(v);
    const secs = (v, d = 3) => (num(v) ? v.toFixed(d) : "—");
    const speedUnit = (imperial) => (imperial ? "mph" : "km/h");
    const speed = (ms, imperial, d = 1) => (num(ms) ? (ms * (imperial ? 2.23694 : 3.6)).toFixed(d) : "—");
    // "+0.014" / "-0.031" (a real minus) : time and reaction lower is better, speed higher
    const delta = (v, best, kind, imperial) => {
        if (!num(v) || !num(best)) return null;
        let d = v - best;
        if (kind === "speed") d *= imperial ? 2.23694 : 3.6;
        const text = (d > 0 ? "+" : d < 0 ? "−" : "±") + Math.abs(d).toFixed(kind === "speed" ? 1 : 3);
        const better = kind === "speed" ? d > 0 : d < 0;
        return { text, better, same: d === 0 };
    };
    const markLabel = (m, imperial) => {
        if (m.kind === "reaction") return translate("beamjoy.drag.mark.reaction");
        if (m.kind === "speed") return fill("beamjoy.drag.mark.speed", { mark: m.label });
        return m.label;
    };
    // reaction + time at a mark : who'd be ahead there had both trees dropped together
    const packageAt = (values, marks, id) => {
        const rt = marks.find((m) => m.kind === "reaction");
        const r = rt ? values[rt.id] : 0;
        if (!num(r)) return null;
        if (rt && id === rt.id) return r;
        return num(values[id]) ? r + values[id] : null;
    };
    const ordinal = (n) => {
        const key = n % 100 >= 11 && n % 100 <= 13 ? "th" : { 1: "st", 2: "nd", 3: "rd" }[n % 10] || "th";
        return fill(`beamjoy.drag.ordinal.${key}`, { n });
    };
    return { translate, fill, num, secs, speed, speedUnit, delta, markLabel, packageAt, ordinal };
});

angular.module("beamjoy").component("bjDragHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/dragHud/app.html",
    controller: function ($rootScope, $scope, beamjoyStore, beamjoyDragFormat) {
        const f = beamjoyDragFormat;
        this.h = { active: false };
        this.live = { elapsed: 0, speed: 0 };

        $rootScope.$on("BJDragHud", (_, data) => {
            $scope.$applyAsync(() => {
                this.h = data && data.active ? data : { active: false };
                this.live = { elapsed: this.h.elapsed || 0, speed: this.h.speed || 0 };
                this.rowsCache = null;
            });
        });
        $rootScope.$on("BJDragHudLive", (_, data) => {
            $scope.$applyAsync(() => (this.live = data || this.live));
        });
        this.$onInit = () => beamjoyStore.send("BJDragHudRequest");

        const h = () => this.h;
        const values = () => h().values || {};
        const marks = () => h().marks || [];
        const imperial = () => !!h().imperial;
        this.unit = () => f.speedUnit(imperial());

        this.stateText = () => {
            const s = h().state;
            if (s === "dq") return f.fill("beamjoy.drag.state.dq", { reason: h().dqText || "" });
            if (s === "finished") {
                const r = h().result;
                return f.translate(r && r.best ? "beamjoy.drag.state.finishedBest" : "beamjoy.drag.state.finished");
            }
            return f.translate(`beamjoy.drag.state.${s}`);
        };
        this.stateClass = () => {
            const s = h().state;
            if (s === "finished") return h().result && h().result.best ? "good" : "done";
            return s;
        };
        this.laneLine = () => f.fill("beamjoy.drag.laneLine", {
            lane: h().lane || "",
            tree: f.translate(`beamjoy.drag.tree.${h().tree || "sportsman"}`),
            distance: h().mainLabel || f.translate("beamjoy.drag.defaultDistance"),
        });
        this.laneLetter = () => String(h().lane || "?").charAt(0).toUpperCase();

        // the big number : your best before the run, the clock during it, your time after
        this.big = () => {
            const s = h().state;
            const main = h().mainId;
            if (s === "running") return { value: f.secs(this.live.elapsed, 2), unit: "s", cls: "live" };
            if (s === "finished") return { value: f.secs(values()[main]), unit: "s", cls: h().result && h().result.best ? "good" : "" };
            if (s === "dq") return { value: "DQ", unit: "", cls: "bad" };
            const best = h().best;
            return { value: best ? f.secs(best.et) : "—", unit: best ? "s" : "", cls: "muted" };
        };
        this.side = () => {
            const s = h().state;
            if (s === "running") return { label: f.translate("beamjoy.drag.speed"), value: `${f.speed(this.live.speed, imperial(), 0)} ${this.unit()}` };
            if (s === "finished") {
                const trap = marks().filter((m) => m.kind === "speed").pop();
                return trap ? { label: f.translate("beamjoy.drag.trap"), value: `${f.speed(values()[trap.id], imperial())} ${this.unit()}` } : null;
            }
            const best = h().best;
            return best ? { label: f.translate("beamjoy.drag.yourBest"), value: f.num(best.trap) ? `${f.speed(best.trap, imperial())} ${this.unit()}` : "" }
                : { label: f.translate("beamjoy.drag.noTimeYet"), value: "" };
        };

        // the marks : set ones show their time and the gap to your best there, the next is lit
        this.rows = () => {
            if (this.rowsCache) return this.rowsCache;
            const v = values();
            const best = (h().best && h().best.splits) || {};
            const lit = h().state === "running" || h().state === "tree";
            const next = lit ? marks().findIndex((m) => !f.num(v[m.id])) : -1;
            this.rowsCache = marks().map((m, i) => {
                const set = f.num(v[m.id]);
                const d = set ? f.delta(v[m.id], best[m.id], m.kind, imperial()) : null;
                return {
                    key: m.id,
                    label: f.markLabel(m, imperial()),
                    value: !set ? "—" : m.kind === "speed" ? f.speed(v[m.id], imperial()) : f.secs(v[m.id]),
                    unit: !set ? "" : m.kind === "speed" ? this.unit() : "s",
                    delta: d ? d.text : "",
                    deltaCls: d ? (d.same ? "" : d.better ? "good" : "slow") : "",
                    set,
                    main: !!m.main,
                    next: i === next,
                };
            });
            return this.rowsCache;
        };

        // the other lane
        this.opp = () => h().opponent || null;
        this.oppStatus = () => {
            const o = this.opp();
            if (!o) return null;
            if (o.dq) return { text: f.fill("beamjoy.drag.opp.dq", { reason: o.dq }), cls: "" };
            // the last mark both have : who's ahead on reaction + time
            const ids = marks().filter((m) => m.kind !== "speed").map((m) => m.id);
            for (let i = ids.length - 1; i >= 0; i--) {
                const mine = f.packageAt(values(), marks(), ids[i]);
                const theirs = f.packageAt(o.splits || {}, marks(), ids[i]);
                if (mine !== null && theirs !== null) {
                    const d = mine - theirs;
                    if (d === 0) return { text: f.translate("beamjoy.drag.opp.even"), cls: "" };
                    return d < 0
                        ? { text: f.fill("beamjoy.drag.opp.ahead", { n: Math.abs(d).toFixed(3) }), cls: "good" }
                        : { text: f.fill("beamjoy.drag.opp.behind", { n: d.toFixed(3) }), cls: "slow" };
                }
            }
            if (o.finished && f.num((o.splits || {})[h().mainId])) {
                return { text: f.fill("beamjoy.drag.opp.ran", { name: o.name, time: f.secs(o.splits[h().mainId]) }), cls: "" };
            }
            return { text: f.translate("beamjoy.drag.opp.lined"), cls: "" };
        };

        // after the run
        this.outcome = () => {
            const o = this.opp();
            if (!o) return null;
            const mine = f.packageAt(values(), marks(), h().mainId);
            if (o.dq) return f.fill("beamjoy.drag.outcome.oppDq", { name: o.name });
            const theirs = f.packageAt(o.splits || {}, marks(), h().mainId);
            if (mine === null) return null;
            if (theirs === null) return f.fill("beamjoy.drag.outcome.waiting", { name: o.name });
            const d = Math.abs(mine - theirs).toFixed(3);
            return mine <= theirs
                ? f.fill("beamjoy.drag.outcome.won", { n: d })
                : f.fill("beamjoy.drag.outcome.lost", { name: o.name, n: d });
        };
        this.resultLine = () => {
            const r = h().result;
            if (!r) return { text: f.translate("beamjoy.drag.result.saving"), cls: "" };
            if (!r.saved) return { text: f.translate("beamjoy.drag.result.guest"), cls: "slow" };
            const et = values()[h().mainId];
            const old = h().best && h().best.et;
            if (r.record) return { text: f.fill("beamjoy.drag.result.record", { rank: f.ordinal(1), players: r.players }), cls: "rec" };
            if (r.best) {
                const by = f.num(old) && f.num(et) ? (old - et).toFixed(3) : null;
                return {
                    text: f.fill(by ? "beamjoy.drag.result.best" : "beamjoy.drag.result.first", { n: by, rank: f.ordinal(r.rank || 1), players: r.players || 1 }),
                    cls: "good",
                };
            }
            return { text: f.fill("beamjoy.drag.result.notBest", { best: f.secs(old) }), cls: "" };
        };

        this.board = () => h().board || null;
        this.recordTime = () => {
            const rec = this.board() && this.board().record;
            return rec ? f.secs(rec.et) : "—";
        };
        this.recordName = () => {
            const rec = this.board() && this.board().record;
            return rec ? rec.name : f.translate("beamjoy.drag.noRecord");
        };
        this.rankText = () => {
            const b = this.board();
            return b && b.rank ? f.ordinal(b.rank) : "—";
        };
        this.playersText = () => f.fill("beamjoy.drag.ofDrivers", { n: (this.board() && this.board().players) || 0 });

        this.openTimeslip = () => beamjoyStore.send("BJDragTimeslipOpen");
    },
});
