angular.module("beamjoy").component("bjRaceInfoLive", {
    templateUrl: "/ui/modModules/beamjoy/windows/raceInfo/live/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.active = false;
        this.raceName = null;
        this.totalLaps = 1;
        this.participants = [];
        this.fastestLapMs = null;

        const rebuild = (data) => {
            this.active = !!data.active;
            if (!this.active) return;
            this.raceName = data.raceName;
            this.totalLaps = data.totalLaps;
            this.participants = data.participants || [];

            // race-wide fastest lap, for the "purple" highlight: this is a race-wide comparison
            // across every participant's own personal best, not per-participant
            this.fastestLapMs = null;
            this.participants.forEach((p) => {
                if (typeof p.bestLapMs === "number") {
                    if (this.fastestLapMs === null || p.bestLapMs < this.fastestLapMs) {
                        this.fastestLapMs = p.bestLapMs;
                    }
                }
            });
        };

        $rootScope.$on("BJRaceInfo", (_, data) => rebuild(data));

        this.$onInit = () => {
            beamjoyStore.send("BJRaceInfoRequest");
        };

        this.formatTime = (ms) => {
            if (typeof ms !== "number" || ms < 0) return "-";
            const totalSec = ms / 1000;
            const min = Math.floor(totalSec / 60);
            const sec = (totalSec % 60).toFixed(2);
            return `${min}:${sec.padStart(5, "0")}`;
        };

        this.isFastestLap = (p) =>
            this.fastestLapMs !== null && p.bestLapMs === this.fastestLapMs;

        this.lastLapTime = (p) =>
            Array.isArray(p.lapTimes) && p.lapTimes.length > 0
                ? p.lapTimes[p.lapTimes.length - 1]
                : undefined;

        // generic {gapMs, lapsDiff}-shaped formatter, shared between the "gap to the car ahead"
        // and "gap to leader" columns; both are describeOpponent()-derived server-side (see
        // raceRunner.lua's pushRaceInfo), just measured against a different reference participant
        const formatGap = (p, gapMs, lapsDiff) => {
            if (!p) return "";
            if (p.dnf) return "DNF";
            if (typeof lapsDiff === "number" && lapsDiff !== 0) {
                const n = Math.abs(lapsDiff);
                return `${lapsDiff > 0 ? "+" : "-"}${n} lap${n > 1 ? "s" : ""}`;
            }
            if (typeof gapMs === "number" && gapMs !== 0) {
                return `+${(gapMs / 1000).toFixed(2)}s`;
            }
            return "-";
        };

        // blank (not "-") for the leader (index 0) specifically on both columns: there's nobody
        // ahead of and no gap to themselves, a dash there reads as missing/broken data rather than
        // "not applicable"
        this.aheadGapLabel = (p, index) =>
            index === 0 ? "" : formatGap(p, p.aheadGapMs, p.aheadLapsDiff);
        this.leaderGapLabel = (p, index) =>
            index === 0 ? "" : formatGap(p, p.gapMs, p.lapsDiff);

        this.multiplayer = () => this.participants.length > 1;
    },
});
