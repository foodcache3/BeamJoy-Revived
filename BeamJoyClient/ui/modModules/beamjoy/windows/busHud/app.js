// Bus-line run HUD. Driven entirely by ui-comms from beamjoy/busRun.lua (BJBusHud). Solo, local -
// no server data. Shows the line name, stop progress, an "approaching" cue while holding in a
// stop's radius, and a Stop button. Modelled on hunterHud.
angular.module("beamjoy").component("bjBusHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/busHud/app.html",
    controller: function ($rootScope, beamjoyStore) {
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
    },
});
