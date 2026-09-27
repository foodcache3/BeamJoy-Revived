// Bus-line run HUD. Driven entirely by ui-comms from beamjoy/busRun.lua (BJBusHud). Solo, local -
// no server data. Shows the line name, stop progress, an "approaching" cue while holding in a
// stop's radius, and a Stop button. Modelled on hunterHud.
angular.module("beamjoy").component("bjBusHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/busHud/app.html",
    controller: function ($rootScope, $scope, beamjoyStore, beamjoyDelivery) {
        this.active = false;
        this.lineName = "";
        this.stopIndex = 0;
        this.totalStops = 0;
        this.stopName = "";
        this.loopable = false;
        this.holding = false;
        // strict-stops only : "kneel"|"doors"|"kneelAndDoors" while in a stop's radius but not yet
        // satisfying strict mode - null once satisfied (holding takes over), non-strict, or out of
        // radius. Mutually exclusive with holding (busRun.lua only ever sets one at a time).
        this.pending = null;

        $rootScope.$on("BJBusHud", (_, data) => {
            data = data || {};
            this.active = !!data.active;
            if (!this.active) return;
            this.lineName = data.lineName || "";
            this.stopIndex = data.stopIndex || 0;
            this.totalStops = data.totalStops || 0;
            this.stopName = data.stopName || "";
            this.loopable = !!data.loopable;
            this.holding = !!data.holding;
            this.pending = data.pending || null;
        });

        this.$onInit = () => {
            beamjoyStore.send("BJBusHudRequest");
        };

        this.progressPercent = () => {
            if (!this.totalStops) return 0;
            return Math.max(0, Math.min(100, ((this.stopIndex - 1) / this.totalStops) * 100));
        };

        this.stop = () => {
            beamjoyStore.send("BJBusHudStop");
        };

        // FOCUS : the Focus control during a bus run (beamjoy/mainNav.lua) gives this HUD the pad
        // and shows its Stop button ; B (or the control again) lets go. Same hidden-until-focused
        // behaviour the race HUD has always had (windows/raceHud), per direct request - the button
        // used to sit there permanently.
        this.focused = false;
        this.cursor = 0;
        this.buttons = () => ["stop"];
        $rootScope.$on("BJBusHudFocus", (_, data) => {
            $rootScope.$applyAsync(() => {
                this.focused = !!(data && data.active);
                this.cursor = 0;
                beamjoyDelivery.setNavOwner("busHud", this.focused);
            });
        });
        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.focused || !rising || beamjoyDelivery.otherNavOwner("busHud")) return;
            $scope.$applyAsync(() => {
                const n = this.buttons().length;
                if (name === "focus_l" || name === "focus_u") this.cursor = Math.max(0, this.cursor - 1);
                else if (name === "focus_r" || name === "focus_d") this.cursor = Math.min(n - 1, this.cursor + 1);
                else if (name === "ok") this.stop();
                else if (name === "back") beamjoyStore.send("BJBusHudRelease");
            });
        });
        $scope.$on("$destroy", () => {
            offNav();
            beamjoyDelivery.setNavOwner("busHud", false);
        });
    },
});
