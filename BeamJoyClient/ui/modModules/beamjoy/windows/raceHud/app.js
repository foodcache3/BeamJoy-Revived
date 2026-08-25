angular.module("beamjoy").component("bjRaceHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/raceHud/app.html",
    controller: function ($rootScope) {
        this.active = false;
        this.raceName = null;
        this.totalGates = 0;
        this.totalSectors = 0;
        this.totalLaps = 1;
        this.elapsedMs = 0;
        this.self = null;
        this.position = null;
        this.totalRacers = null;
        this.ahead = null;
        this.behind = null;
        this.standings = null;
        this.spectatingPlayerName = null;
        this.expanded = false;

        $rootScope.$on("BJRaceHud", (_, data) => {
            this.active = !!data.active;
            if (!this.active) {
                this.expanded = false;
                return;
            }
            this.raceName = data.raceName;
            this.totalGates = data.totalGates;
            this.totalSectors = data.totalSectors;
            this.totalLaps = data.totalLaps;
            this.elapsedMs = data.elapsedMs;
            this.self = data.self;
            this.position = data.position ?? null;
            this.totalRacers = data.totalRacers ?? null;
            this.ahead = data.ahead ?? null;
            this.behind = data.behind ?? null;
            this.standings = data.standings ?? null;
            // set whenever this panel is following another still-active racer (own DNF/auto-
            // spectate-on-finish) instead of the local player's own now-static entry; everything
            // else in `data` already reflects THEM, this is just so the template can label it
            this.spectatingPlayerName = data.spectatingPlayerName || null;
        });

        this.toggleExpanded = () => {
            this.expanded = !this.expanded;
        };

        this.formatTime = (ms) => {
            if (typeof ms !== "number" || ms < 0) return "-";
            const totalSec = ms / 1000;
            const min = Math.floor(totalSec / 60);
            const sec = (totalSec % 60).toFixed(2);
            return `${min}:${sec.padStart(5, "0")}`;
        };

        // signed delta, always with an explicit sign so "0.00" doesn't read as blank/ambiguous
        this.formatDelta = (ms) => {
            if (typeof ms !== "number") return null;
            const sign = ms <= 0 ? "-" : "+";
            return `${sign}${(Math.abs(ms) / 1000).toFixed(2)}s`;
        };

        // opponent row -> a single display string, priority matching how most racing games order
        // this information : DNF/finished status first (a live gap is meaningless once someone's
        // done), then a lap split (a raw time diff across different laps isn't meaningful either),
        // then the actual live gap
        this.opponentLabel = (row) => {
            if (!row) return null;
            if (row.dnf) return "DNF";
            if (row.finished) {
                return typeof row.gapMs === "number" ? this.formatDelta(row.gapMs) : "Finished";
            }
            if (typeof row.lapsDiff === "number" && row.lapsDiff !== 0) {
                // same sign convention as formatDelta : positive means this opponent is behind
                const n = Math.abs(row.lapsDiff);
                return `${row.lapsDiff > 0 ? "+" : "-"}${n} lap${n > 1 ? "s" : ""}`;
            }
            return typeof row.gapMs === "number" ? this.formatDelta(row.gapMs) : "-";
        };
    },
});
