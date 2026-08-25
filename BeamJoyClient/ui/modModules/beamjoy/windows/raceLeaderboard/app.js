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
    controller: function ($rootScope, beamjoyStore) {
        this.loaded = false;
        this.entries = [];
        this.selfEntry = null;

        this.$onInit = () => {
            beamjoyStore.send("BJRaceLeaderboardRequest", [Number(this.raceId)]);
        };

        $rootScope.$on("BJRaceLeaderboard", (_, data) => {
            if (Number(data.raceId) !== Number(this.raceId)) return;
            this.entries = data.entries || [];
            this.selfEntry = data.selfEntry || null;
            this.loaded = true;
        });

        this.selfInTop = () =>
            this.selfEntry &&
            this.entries.some((e) => e.playerName === this.selfEntry.playerName);

        this.formatTime = (ms) => {
            if (typeof ms !== "number" || ms < 0) return "-";
            const totalSec = ms / 1000;
            const min = Math.floor(totalSec / 60);
            const sec = (totalSec % 60).toFixed(2);
            return `${min}:${sec.padStart(5, "0")}`;
        };

        this.formatDate = (unixSeconds) => {
            if (typeof unixSeconds !== "number") return "";
            return new Date(unixSeconds * 1000).toLocaleDateString();
        };
    },
});
