// Infected's own results panel, mirroring raceInfo/results/app.js's shape (same beamjoyInfoPanel
// framework, same auto-open-after-finish convention) but trimmed to Infected's simpler stats: no
// laps/sectors, just time survived + how many others each participant personally infected.
angular.module("beamjoy").component("bjInfectedInfoResults", {
    templateUrl: "/ui/modModules/beamjoy/windows/infectedInfo/results/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.active = false;
        this.finished = false;
        this.winner = null;
        this.participants = [];

        // longest survival first, matching a standard results leaderboard rather than plain join
        // order. Participants without a survivedMs yet (state !== FINISHED, e.g. this panel opened
        // manually while the round is still running) sort last instead of crashing the compare.
        const buildRanking = (participants) => {
            return participants
                .slice()
                .sort((a, b) => (b.survivedMs ?? -1) - (a.survivedMs ?? -1));
        };

        const rebuild = (data) => {
            this.active = !!data.active;
            if (!this.active) return;
            this.finished = data.state === "FINISHED";
            this.winner = data.winner || null;
            this.participants = buildRanking(data.participants || []);
        };

        $rootScope.$on("BJInfectedInfo", (_, data) => rebuild(data));

        this.$onInit = () => {
            beamjoyStore.send("BJInfectedInfoRequest");
        };

        this.formatTime = (ms) => {
            if (typeof ms !== "number" || ms < 0) return "-";
            const totalSec = ms / 1000;
            const min = Math.floor(totalSec / 60);
            const sec = (totalSec % 60).toFixed(0).padStart(2, "0");
            return `${min}:${sec}`;
        };
    },
});
