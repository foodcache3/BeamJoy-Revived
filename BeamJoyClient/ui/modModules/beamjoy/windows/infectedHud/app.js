angular.module("beamjoy").component("bjInfectedHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/infectedHud/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.active = false;
        this.role = null;
        this.gameElapsedMs = 0;
        this.roundSecondsLeft = null;
        this.survivorsLeft = 0;
        this.infectedCount = 0;
        this.tagCount = null;

        $rootScope.$on("BJInfectedHud", (_, data) => {
            this.active = !!data.active;
            if (!this.active) return;
            this.role = data.role || null;
            this.gameElapsedMs = data.gameElapsedMs || 0;
            this.roundSecondsLeft = data.roundSecondsLeft ?? null;
            this.survivorsLeft = data.survivorsLeft || 0;
            this.infectedCount = data.infectedCount || 0;
            this.tagCount = data.tagCount ?? null;
        });

        this.$onInit = () => {
            beamjoyStore.send("BJInfectedHudRequest");
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
