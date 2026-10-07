// every race time on screen goes through here (leaderboards, race HUD, race info, the finished
// popup) : lap times, gaps and "set N days ago"
angular.module("beamjoy").factory("beamjoyLeaderboardFormat", function ($filter) {
    const translate = $filter("translate");
    const fill = (key, values) =>
        Object.keys(values).reduce((s, k) => s.split(`{${k}}`).join(values[k]), translate(key));

    // 1:48.21, or 31:02:15.40 from an hour up. Rounded to hundredths BEFORE splitting into
    // minutes and seconds : rounding the seconds on their own turned 1:59.996 into "1:60.00"
    const time = (ms) => {
        if (typeof ms !== "number" || ms < 0) return "-";
        const cs = Math.round(ms / 10);
        const h = Math.floor(cs / 360000);
        const m = Math.floor(cs / 6000) % 60;
        const sec = ((cs % 6000) / 100).toFixed(2).padStart(5, "0");
        return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
    };
    // a gap or a sector time, unsigned : seconds under a minute ("1.46"), a clock time past it
    // (endurance-race gaps run into minutes and hours, "2700.31" read as nothing useful)
    const gap = (ms) => {
        const abs = Math.abs(ms);
        return Math.round(abs / 10) < 6000 ? (abs / 1000).toFixed(2) : time(abs);
    };
    // the same, with the "s" unit when it's in plain seconds ("1.46s", "1:05.20")
    const gapS = (ms) => (Math.round(Math.abs(ms) / 10) < 6000 ? `${gap(ms)}s` : gap(ms));

    // unix seconds -> "Just now", "3 hours ago", "2 weeks ago"
    const ago = (unixSeconds) => {
        if (typeof unixSeconds !== "number") return "";
        const sec = Math.max(0, Date.now() / 1000 - unixSeconds);
        const n = (x) => String(Math.max(1, Math.floor(x)));
        if (sec < 120) return translate("beamjoy.leaderboard.when.justNow");
        if (sec < 3600) return fill("beamjoy.leaderboard.when.minutes", { n: n(sec / 60) });
        if (sec < 86400) return fill("beamjoy.leaderboard.when.hours", { n: n(sec / 3600) });
        if (sec < 172800) return translate("beamjoy.leaderboard.when.yesterday");
        if (sec < 86400 * 14) return fill("beamjoy.leaderboard.when.days", { n: n(sec / 86400) });
        if (sec < 86400 * 60) return fill("beamjoy.leaderboard.when.weeks", { n: n(sec / 604800) });
        return fill("beamjoy.leaderboard.when.months", { n: n(sec / 2592000) });
    };

    return { fill, time, gap, gapS, ago };
});

// One race's best-lap board : the record and your best on top, then the top 100 (or the places
// around yours), with your row pinned underneath while it's out of sight. Shown in the info panel
// (from a race's results, or the Races list) and in the full window's Leaderboards tab.
angular.module("beamjoy").component("bjRaceLeaderboard", {
    templateUrl: "/ui/modModules/beamjoy/windows/raceLeaderboard/app.html",
    bindings: {
        // "@" (string, no {{}} interpolation) deliberately: this tab's template string is built
        // with the real race id already substituted in via a JS template literal (see
        // windows/main/races/app.js's openLeaderboard), not Angular interpolation; using a "<"
        // expression binding with {{}} in the attribute is the exact bj-slider "max" bug from
        // earlier this project (a one-way expression binding takes the raw attribute text
        // literally, {{}} braces included, and throws a parse error). Never repeat that here.
        raceId: "@",
    },
    controller: function ($rootScope, $scope, $element, $timeout, beamjoyStore, beamjoyLeaderboardFormat) {
        const f = beamjoyLeaderboardFormat;
        // a best set this recently still says "New best" (right after the race it came from)
        const FRESH_SEC = 15 * 60;

        this.loaded = false;
        this.entries = [];
        this.around = [];
        this.selfEntry = null;
        this.players = 0;
        this.near = false;
        this.rows = [];
        this.selfVisible = false;

        // "grid" : the race's grid races ; "freeroam" : its freeroam runs (a rolling start, its own
        // board). The switch only shows for a race that has freeroam runs
        this.board = "grid";
        this.hasFreeroam = false;
        const request = () => beamjoyStore.send("BJRaceLeaderboardRequest", [Number(this.raceId), this.board]);
        this.$onInit = request;
        this.setBoard = (board) => {
            if (this.board === board) return;
            this.board = board;
            this.loaded = false;
            this.near = false;
            request();
        };

        const off = $rootScope.$on("BJRaceLeaderboard", (_, data) => {
            if (Number(data.raceId) !== Number(this.raceId)) return;
            if ((data.board || "grid") !== this.board) return;
            this.hasFreeroam = data.freeroam === true;
            this.entries = Array.isArray(data.entries) ? data.entries : [];
            this.around = Array.isArray(data.around) ? data.around : [];
            this.selfEntry = data.selfEntry || null;
            this.players = Number(data.players) || this.entries.length;
            this.loaded = true;
            build();
        });
        $scope.$on("$destroy", off);

        const isSelf = (e) => this.selfEntry && e.playerName === this.selfEntry.playerName;
        const record = () => this.entries[0];

        const toRow = (e) => {
            const rec = record();
            return {
                key: `r${e.rank}`,
                rank: e.rank,
                name: e.playerName,
                vehicle: e.model || "",
                time: f.time(e.time),
                gap: e.rank === 1 || !rec ? "" : `+${f.gap(e.time - rec.time)}`,
                when: f.ago(e.date),
                self: isSelf(e),
                cls: { me: isSelf(e) },
                plateCls: { rec: e.rank === 1, me: e.rank !== 1 && isSelf(e) },
                timeCls: { fast: e.rank === 1, pbt: e.rank !== 1 && isSelf(e) },
            };
        };
        const cut = (key, text) => ({ key, cut: true, text });

        const build = () => {
            const rows = [];
            if (this.near && this.selfEntry && this.around.length > 0) {
                // the record stays on top, then five places either side of yours
                const first = this.around[0];
                const last = this.around[this.around.length - 1];
                if (first.rank > 1 && record()) rows.push(toRow(record()));
                if (first.rank > 2) {
                    rows.push(cut("above", f.fill("beamjoy.leaderboard.more", { n: first.rank - 2 })));
                }
                this.around.forEach((e) => rows.push(toRow(e)));
                if (last.rank < this.players) {
                    rows.push(cut("below", f.fill("beamjoy.leaderboard.more", { n: this.players - last.rank })));
                }
            } else {
                this.entries.forEach((e) => rows.push(toRow(e)));
                if (this.players > this.entries.length) {
                    rows.push(cut("rest", f.fill("beamjoy.leaderboard.moreNotShown", {
                        n: this.players - this.entries.length,
                    })));
                }
            }
            this.rows = rows;
            this.driversText = f.fill("beamjoy.leaderboard.drivers", { n: this.players });
            this.recordCard = record() ? {
                name: record().playerName,
                line: [record().model, f.ago(record().date)].filter((x) => x).join(", "),
                time: f.time(record().time),
            } : null;
            this.meCard = this.selfEntry ? meCard() : null;
            this.selfRow = this.selfEntry ? toRow(this.selfEntry) : null;
            $timeout(checkSelfVisible, 50);
        };

        const meCard = () => {
            const me = this.selfEntry;
            const rec = record();
            let toNext = f.fill("beamjoy.leaderboard.race.holdRecord", {});
            if (me.rank > 1) {
                const above = this.around.concat(this.entries).find((e) => e.rank === me.rank - 1);
                toNext = above
                    ? f.fill("beamjoy.leaderboard.race.toNext", {
                        gap: f.gap(me.time - above.time),
                        rank: me.rank - 1,
                        rec: rec ? f.gap(me.time - rec.time) : "-",
                    })
                    : "";
            }
            let fresh = null;
            if (typeof me.date === "number" && Date.now() / 1000 - me.date < FRESH_SEC) {
                const from = Number(me.fromRank);
                if (!from) fresh = f.fill("beamjoy.leaderboard.race.newBestFirst", {});
                else if (from > me.rank) {
                    fresh = f.fill(from - me.rank === 1
                        ? "beamjoy.leaderboard.race.newBestUp1"
                        : "beamjoy.leaderboard.race.newBestUp", { n: from - me.rank });
                } else fresh = f.fill("beamjoy.leaderboard.race.newBest", {});
            }
            return { rank: me.rank, time: f.time(me.time), toNext, fresh };
        };

        this.setNear = (near) => {
            if (this.near === near) return;
            this.near = near;
            build();
            // your rows are the point of this view : start the list at the top
            $timeout(() => {
                const list = $element[0].querySelector(".rlb-scroll");
                if (list) list.scrollTop = 0;
            });
        };

        // your row pinned under the list while it isn't in sight
        const checkSelfVisible = () => {
            const list = $element[0].querySelector(".rlb-scroll");
            const row = list && list.querySelector(".rlb-row.me");
            let visible = false;
            if (row) {
                const a = list.getBoundingClientRect();
                const b = row.getBoundingClientRect();
                visible = b.bottom > a.top + 4 && b.top < a.bottom - 4;
            }
            if (visible !== this.selfVisible) $scope.$applyAsync(() => (this.selfVisible = visible));
        };
        this.onScroll = () => checkSelfVisible();
    },
});

// the list's scroll : the pinned row checks whether yours came into sight
angular.module("beamjoy").directive("bjOnScroll", function () {
    return {
        restrict: "A",
        link: (scope, el, attrs) => {
            const handler = () => scope.$eval(attrs.bjOnScroll);
            el[0].addEventListener("scroll", handler, { passive: true });
            scope.$on("$destroy", () => el[0].removeEventListener("scroll", handler));
        },
    };
});
