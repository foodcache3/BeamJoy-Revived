angular.module("beamjoy").component("bjRaceCountdown", {
    templateUrl: "/ui/modModules/beamjoy/windows/raceCountdown/app.html",
    controller: function ($rootScope) {
        this.active = false;
        this.seconds = null;
        this.raceName = null;
        // "countdown" (ticks + the "GO!" flash, seconds===0) is the default/only mode every
        // existing send already uses ; "finished"/"dnf" reuse this same overlay as a generic
        // "big transient message" primitive for the finish-line feedback a solo racer otherwise
        // never gets at all (the leaderboard HUD only sends once there's >1 participant)
        this.mode = "countdown";
        this.timeMs = null;
        this.isBestLap = false;
        this.isNewPB = false;
        this.isNewRecord = false;

        $rootScope.$on("BJRaceCountdown", (_, data) => {
            this.active = !!data.active;
            if (!this.active) return;
            this.mode = data.mode || "countdown";
            this.seconds = data.seconds;
            this.timeMs = data.timeMs ?? null;
            this.isBestLap = data.isBestLap ?? false;
            // record implies PB too, but shown as its own, higher-priority badge in the template
            // rather than stacking both; see app.html
            this.isNewPB = data.isNewPB ?? false;
            this.isNewRecord = data.isNewRecord ?? false;
            if (data.raceName) {
                this.raceName = data.raceName;
            }
        });

        this.formatTime = (ms) => {
            if (typeof ms !== "number" || ms < 0) return "-";
            const totalSec = ms / 1000;
            const min = Math.floor(totalSec / 60);
            const sec = (totalSec % 60).toFixed(2);
            return `${min}:${sec.padStart(5, "0")}`;
        };
    },
});
