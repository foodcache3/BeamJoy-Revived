// The derby's in-game panel : the clock, cars left, your lives and wrecks, the sumo zone, the
// warnings that come before you're wrecked (stuck, dead engine, outside the zone), the kill
// feed, and Forfeit once you're on your last life. Fed by beamjoy/derbyRunner.lua (BJDerbyHud).
angular.module("beamjoy").component("bjDerbyHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/derbyHud/app.html",
    controller: function ($rootScope, $scope, $interval, $filter, beamjoyStore) {
        const translate = $filter("translate");
        this.hud = { active: false };

        const off = $rootScope.$on("BJDerbyHud", (_, data) => {
            this.hud = data && data.active ? data : { active: false };
            if (!this.hud.canForfeit) this.cancelHold();
            if (!Array.isArray(this.hud.feed)) this.hud.feed = [];
        });
        this.$onInit = () => beamjoyStore.send("BJDerbyHudRequest");

        this.formatTime = (ms) => {
            if (typeof ms !== "number" || ms < 0) return "-";
            const totalSec = Math.floor(ms / 1000);
            return `${Math.floor(totalSec / 60)}:${String(totalSec % 60).padStart(2, "0")}`;
        };
        this.clock = () => {
            if (this.hud.mode === "timed" && this.hud.roundSecondsLeft != null) {
                return this.formatTime(this.hud.roundSecondsLeft * 1000);
            }
            return this.formatTime(this.hud.gameElapsedMs);
        };
        this.modeLabel = () => translate(`beamjoy.window.main.tabs.derby.modes.${this.hud.mode || "lms"}`);

        const REASONS = {
            stuck: "beamjoy.window.derbyHud.feed.stuck",
            engine: "beamjoy.window.derbyHud.feed.engine",
            zone: "beamjoy.window.derbyHud.feed.zone",
            fell: "beamjoy.window.derbyHud.feed.fell",
            reset: "beamjoy.window.derbyHud.feed.reset",
            forfeit: "beamjoy.window.derbyHud.feed.forfeit",
            left: "beamjoy.window.derbyHud.feed.left",
            wreck: "beamjoy.window.derbyHud.feed.wreck",
        };
        this.feedText = (entry) => {
            const key = entry.attacker ? "beamjoy.window.derbyHud.feed.wrecked" : REASONS[entry.reason] || REASONS.wreck;
            let text = translate(key)
                .replace("{attacker}", entry.attacker || "")
                .replace("{victim}", entry.victim || "?");
            if (entry.out && entry.reason !== "left") text += ` ${translate("beamjoy.window.derbyHud.feed.out")}`;
            return text;
        };

        // Forfeit : held for a few seconds so it can't happen by accident
        const HOLD_MS = 3000;
        const STEP_MS = 100;
        this.holdMs = 0;
        this.holding = false;
        let holdInterval = null;
        this.holdPercent = () => Math.min(100, (this.holdMs / HOLD_MS) * 100);
        this.startHold = () => {
            if (this.holding) return;
            this.holding = true;
            this.holdMs = 0;
            holdInterval = $interval(() => {
                this.holdMs += STEP_MS;
                if (this.holdMs >= HOLD_MS) {
                    this.cancelHold();
                    beamjoyStore.send("BJDerbyForfeit");
                }
            }, STEP_MS);
        };
        this.cancelHold = () => {
            this.holding = false;
            this.holdMs = 0;
            if (holdInterval) {
                $interval.cancel(holdInterval);
                holdInterval = null;
            }
        };
        $scope.$on("$destroy", () => {
            off();
            this.cancelHold();
        });
    },
});
