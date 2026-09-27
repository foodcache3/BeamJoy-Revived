// Full window > Leaderboards : Races (every race with its record and your place, the picked one's
// board through bj-race-leaderboard) or Deliveries (packages / vehicles, ranked by points, jobs,
// success rate, distance or, for packages, fewest resets).
angular.module("beamjoy").component("bjMainLeaderboards", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/leaderboards/app.html",
    controller: function ($rootScope, $scope, $filter, $interval, beamjoyStore, beamjoyDelivery, beamjoyLeaderboardFormat) {
        const translate = $filter("translate");
        const f = beamjoyLeaderboardFormat;
        const offs = [];
        const on = (event, fn) => offs.push($rootScope.$on(event, fn));

        this.section = "races";
        this.setSection = (section) => (this.section = section);

        // RACES ------------------------------------------------------------------------------
        // grid races only, like the Activities list
        this.races = [];
        this.raceId = null;
        this.query = "";
        this.summary = {};
        on("BJEditorRaceList", (_, races) => {
            this.races = (Array.isArray(races) ? races : []).filter((r) => r.mode === "grid");
            if (!this.races.some((r) => r.id === this.raceId)) {
                this.raceId = this.races.length > 0 ? this.races[0].id : null;
            }
        });
        on("BJRaceLeaderboardSummary", (_, list) => {
            const map = {};
            (Array.isArray(list) ? list : []).forEach((s) => (map[s.raceId] = s));
            this.summary = map;
        });
        this.pickRace = (race) => (this.raceId = race.id);
        this.race = () => this.races.find((r) => r.id === this.raceId) || null;
        this.shownRaces = () => {
            const q = this.query.trim().toLowerCase();
            return q ? this.races.filter((r) => String(r.name || "").toLowerCase().includes(q)) : this.races;
        };
        this.raceLine = (race) => {
            const s = this.summary[race.id];
            if (!s || !s.players) return translate("beamjoy.leaderboard.race.noLaps");
            return `${f.time(s.recordTime)}, ${s.recordName}`;
        };
        this.myRank = (race) => {
            const s = this.summary[race.id];
            return s && s.myRank ? s.myRank : null;
        };

        // DELIVERIES -------------------------------------------------------------------------
        this.KINDS = ["packages", "vehicles"];
        this.kind = "packages";
        this.sort = "total";
        this.near = false;
        this.board = null;
        const request = () => beamjoyStore.send("BJDeliveryLeaderboardRequest", [this.sort]);
        on("BJDeliveryLeaderboard", (_, data) => {
            // another window's points request : not what this board is ranked by right now
            if (!data || (data.sort || "total") !== this.sort) return;
            this.board = data;
        });
        // standings move : ask again every 15 s while shown, and when a delivery just finished
        const refresh = $interval(() => {
            request();
            beamjoyStore.send("BJRaceLeaderboardSummaryRequest");
        }, 15000);
        on("BJDeliveryResults", () => request());

        this.pickKind = (kind) => {
            this.kind = kind;
            this.near = false;
            // the vehicle board has no resets
            if (kind === "vehicles" && this.sort === "resets") this.setSort("total");
        };
        this.setSort = (sort) => {
            if (this.sort === sort) return;
            this.sort = sort;
            this.board = null;
            request();
        };

        const EMPTY = { rows: [], players: 0, around: [] };
        this.COLUMNS = {
            packages: ["count", "rate", "meters", "resets", "vehicle", "total"],
            vehicles: ["count", "rate", "meters", "total"],
        };
        this.sortable = (col) => col !== "vehicle";

        this.lb = (kind) => (this.board && this.board[kind || this.kind]) || EMPTY;

        const rate = (r) => {
            const tries = (r.count || 0) + (r.failed || 0);
            return tries > 0 ? r.count / tries : null;
        };
        const pct = (x) => (x === null ? "-" : `${Math.round(x * 100)}%`);
        const dist = (m) => (m > 0 ? beamjoyDelivery.formatDistance(m) : "-");
        const perJob = (r) => (r.count > 0 && typeof r.resets === "number" ? r.resets / r.count : null);

        // the value a board is ranked by, as shown on the leader and you cards
        this.value = (r) => {
            if (!r) return "";
            switch (this.sort) {
                case "count": return (r.count || 0).toLocaleString();
                case "rate": return pct(rate(r));
                case "meters": return dist(r.meters);
                case "resets": return perJob(r) === null ? "-" : perJob(r).toFixed(2);
                default: return (r.total || 0).toLocaleString();
            }
        };
        this.unit = () => translate(`beamjoy.leaderboard.delivery.unit.${this.sort}`);
        this.rankedBy = () => f.fill("beamjoy.leaderboard.delivery.rankedBy", {
            what: translate(`beamjoy.leaderboard.delivery.by.${this.sort}`),
        });
        this.driversText = () => f.fill("beamjoy.leaderboard.drivers", { n: this.lb().players });

        const toRow = (r) => ({
            key: `r${r.rank}`,
            rank: r.rank,
            name: r.name,
            you: !!r.you,
            count: (r.count || 0).toLocaleString(),
            rate: pct(rate(r)),
            ratePct: rate(r) === null ? 0 : Math.round(rate(r) * 100),
            low: rate(r) !== null && rate(r) < 0.85,
            meters: dist(r.meters),
            resets: typeof r.resets === "number" ? r.resets.toLocaleString() : "-",
            vehicle: r.vehicle || "-",
            total: (r.total || 0).toLocaleString(),
        });
        const cut = (key, n, keyText) => ({ key, cut: true, text: f.fill(keyText, { n }) });
        // cached per board so ng-repeat keeps its rows between digests
        let rowsCache = { board: null, kind: null, near: null, rows: [] };
        this.rows = () => {
            if (rowsCache.board === this.board && rowsCache.kind === this.kind && rowsCache.near === this.near) {
                return rowsCache.rows;
            }
            const lb = this.lb();
            const rows = [];
            if (this.near && lb.mine && Array.isArray(lb.around) && lb.around.length > 0) {
                const first = lb.around[0];
                const last = lb.around[lb.around.length - 1];
                if (first.rank > 1 && lb.rows[0]) rows.push(toRow(lb.rows[0]));
                if (first.rank > 2) rows.push(cut("above", first.rank - 2, "beamjoy.leaderboard.more"));
                lb.around.forEach((r) => rows.push(toRow(r)));
                if (last.rank < lb.players) rows.push(cut("below", lb.players - last.rank, "beamjoy.leaderboard.more"));
            } else {
                lb.rows.forEach((r) => rows.push(toRow(r)));
                if (lb.players > lb.rows.length) {
                    rows.push(cut("rest", lb.players - lb.rows.length, "beamjoy.leaderboard.moreNotShown"));
                }
            }
            rowsCache = { board: this.board, kind: this.kind, near: this.near, rows };
            return rows;
        };
        this.mineRow = () => {
            const lb = this.lb();
            return lb.mine ? toRow(lb.mine) : null;
        };
        // your row under the list when the list doesn't hold it
        this.pinMine = () => {
            const lb = this.lb();
            return !!lb.mine && !this.rows().some((r) => r.you);
        };

        this.leader = () => {
            const top = this.lb().rows[0];
            if (!top) return null;
            return {
                name: top.name,
                value: this.value(top),
                line: f.fill("beamjoy.leaderboard.delivery.leaderLine", {
                    jobs: (top.count || 0).toLocaleString(),
                    rate: pct(rate(top)),
                }),
            };
        };
        this.mine = () => {
            const lb = this.lb();
            const me = lb.mine;
            if (!me) return null;
            let behind = translate("beamjoy.leaderboard.delivery.leadBoard");
            if (me.rank > 1) {
                const above = (lb.around || []).concat(lb.rows || []).find((r) => r.rank === me.rank - 1);
                if (above) {
                    let n;
                    switch (this.sort) {
                        case "count": n = ((above.count || 0) - (me.count || 0)).toLocaleString(); break;
                        case "rate": n = String(Math.round(((rate(above) || 0) - (rate(me) || 0)) * 100)); break;
                        case "meters": n = dist((above.meters || 0) - (me.meters || 0)); break;
                        case "resets": n = ((perJob(me) || 0) - (perJob(above) || 0)).toFixed(2); break;
                        default: n = ((above.total || 0) - (me.total || 0)).toLocaleString();
                    }
                    behind = f.fill(`beamjoy.leaderboard.delivery.behind.${this.sort}`, { n, rank: me.rank - 1 });
                } else behind = "";
            }
            const r = rate(me);
            return {
                rank: me.rank,
                value: this.value(me),
                behind,
                rate: pct(r),
                failed: f.fill("beamjoy.leaderboard.delivery.failed", { n: me.failed || 0 }),
                meters: dist(me.meters),
                count: (me.count || 0).toLocaleString(),
                total: (me.total || 0).toLocaleString(),
                resets: typeof me.resets === "number" ? me.resets.toLocaleString() : "-",
                perJob: perJob(me) === null ? "" : f.fill("beamjoy.leaderboard.delivery.perJob", { n: perJob(me).toFixed(2) }),
                vehicle: me.vehicle || "-",
            };
        };

        // the kinds list : each board's leader and your place
        this.kindLine = (kind) => {
            const top = this.lb(kind).rows[0];
            return top ? `${top.name}, ${this.value(top)}` : translate(`beamjoy.delivery.jobs.lbEmpty.${kind}`);
        };
        this.kindRank = (kind) => {
            const mine = this.lb(kind).mine;
            return mine ? mine.rank : null;
        };

        // both kinds together
        this.allMine = () => {
            const mines = this.KINDS.map((k) => this.lb(k).mine).filter((m) => m);
            if (mines.length === 0) return null;
            const sum = (field) => mines.reduce((a, m) => a + (m[field] || 0), 0);
            const tries = sum("count") + sum("failed");
            return {
                count: sum("count").toLocaleString(),
                rate: tries > 0 ? `${Math.round((sum("count") / tries) * 100)}%` : "-",
                meters: dist(sum("meters")),
                total: sum("total").toLocaleString(),
            };
        };

        this.$onInit = () => {
            request();
            beamjoyStore.send("BJEditorRaceListRequest");
            beamjoyStore.send("BJRaceLeaderboardSummaryRequest");
        };
        $scope.$on("$destroy", () => {
            offs.forEach((off) => off());
            $interval.cancel(refresh);
        });
    },
});
