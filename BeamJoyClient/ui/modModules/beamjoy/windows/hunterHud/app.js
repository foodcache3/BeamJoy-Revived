angular.module("beamjoy").component("bjHunterHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/hunterHud/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.active = false;
        this.role = null;
        this.huntElapsedMs = 0;
        this.huntersLeft = 0;
        this.huntedRevealed = false;
        this.waypointsReached = null;
        this.totalWaypoints = null;
        this.hunterResetCount = null;
        this.spectatingPlayerName = null;
        this.huntedResetLocked = false;
        this.winCondition = "waypoints";
        this.timedSecondsLeft = null;

        $rootScope.$on("BJHunterHud", (_, data) => {
            this.active = !!data.active;
            if (!this.active) return;
            this.role = data.role || null;
            this.huntElapsedMs = data.huntElapsedMs || 0;
            this.huntersLeft = data.huntersLeft || 0;
            this.huntedRevealed = !!data.huntedRevealed;
            this.waypointsReached = data.waypointsReached ?? null;
            this.totalWaypoints = data.totalWaypoints ?? null;
            this.hunterResetCount = data.hunterResetCount ?? null;
            this.spectatingPlayerName = data.spectatingPlayerName || null;
            this.huntedResetLocked = !!data.huntedResetLocked;
            this.winCondition = data.winCondition || "waypoints";
            this.timedSecondsLeft = data.timedSecondsLeft ?? null;
        });

        this.$onInit = () => {
            beamjoyStore.send("BJHunterHudRequest");
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
