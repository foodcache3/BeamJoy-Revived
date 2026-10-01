angular.module("beamjoy").component("bjHunterHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/hunterHud/app.html",
    controller: function ($rootScope, $interval, beamjoyStore) {
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
            if (!this.active) {
                this.cancelUnstuckHold();
                return;
            }
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

        // rounded to whole seconds BEFORE splitting into minutes : rounding the seconds on their
        // own turned 0:59.6 into "0:60"
        this.formatTime = (ms) => {
            if (typeof ms !== "number" || ms < 0) return "-";
            const totalSec = Math.round(ms / 1000);
            const min = Math.floor(totalSec / 60);
            const sec = String(totalSec % 60).padStart(2, "0");
            return `${min}:${sec}`;
        };

        // Hold-to-confirm Unstuck button: see infectedHud/app.js's own identical mechanism for the
        // full "why" (hunterRunner.lua's own onUnstuckRequest is the receiving end here).
        const UNSTUCK_HOLD_MS = 5000;
        const UNSTUCK_STEP_MS = 100;
        this.unstuckHoldMs = 0;
        this.unstuckHolding = false;
        let unstuckInterval = null;

        this.unstuckProgressPercent = () => Math.min(100, (this.unstuckHoldMs / UNSTUCK_HOLD_MS) * 100);

        this.startUnstuckHold = () => {
            if (this.unstuckHolding) return;
            this.unstuckHolding = true;
            this.unstuckHoldMs = 0;
            unstuckInterval = $interval(() => {
                this.unstuckHoldMs += UNSTUCK_STEP_MS;
                if (this.unstuckHoldMs >= UNSTUCK_HOLD_MS) {
                    this.cancelUnstuckHold();
                    beamjoyStore.send("BJHunterUnstuck");
                }
            }, UNSTUCK_STEP_MS);
        };

        this.cancelUnstuckHold = () => {
            this.unstuckHolding = false;
            this.unstuckHoldMs = 0;
            if (unstuckInterval) {
                $interval.cancel(unstuckInterval);
                unstuckInterval = null;
            }
        };

        this.$onDestroy = () => {
            this.cancelUnstuckHold();
        };
    },
});
