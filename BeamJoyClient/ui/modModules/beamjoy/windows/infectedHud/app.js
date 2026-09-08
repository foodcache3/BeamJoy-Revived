angular.module("beamjoy").component("bjInfectedHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/infectedHud/app.html",
    controller: function ($rootScope, $interval, beamjoyStore) {
        this.active = false;
        this.role = null;
        this.gameElapsedMs = 0;
        this.roundSecondsLeft = null;
        this.survivorsLeft = 0;
        this.infectedCount = 0;
        this.tagCount = null;
        this.holdSecondsLeft = null;

        $rootScope.$on("BJInfectedHud", (_, data) => {
            this.active = !!data.active;
            if (!this.active) {
                this.cancelUnstuckHold();
                return;
            }
            this.role = data.role || null;
            this.gameElapsedMs = data.gameElapsedMs || 0;
            this.roundSecondsLeft = data.roundSecondsLeft ?? null;
            this.survivorsLeft = data.survivorsLeft || 0;
            this.infectedCount = data.infectedCount || 0;
            this.tagCount = data.tagCount ?? null;
            this.holdSecondsLeft = data.holdSecondsLeft ?? null;
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

        // Hold-to-confirm Unstuck button: 5s of held mousedown teleports the local vehicle to the
        // last known road (infectedRunner.lua's own onUnstuckRequest, a controlled stand-in for
        // recover_to_last_road, which is otherwise unconditionally blocked while a round is active).
        // The hold itself is the anti-abuse gate here (can't be held while actively evading/chasing),
        // so unlike the native reset actions this needs no separate speed/relock check.
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
                    beamjoyStore.send("BJInfectedUnstuck");
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
