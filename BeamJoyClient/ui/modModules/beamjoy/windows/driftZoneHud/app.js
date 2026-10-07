// A drift zone's panel, top right (beamjoy/driftZones.lua, BJDriftZoneHud) : the zone, the score so
// far (the drift still going included) and its combo while it runs, then the score, or why the run
// ended, for a few seconds after.
angular.module("beamjoy").component("bjDriftZoneHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/driftZoneHud/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore) {
        const translate = $filter("translate");
        this.h = { active: false };

        $rootScope.$on("BJDriftZoneHud", (_, data) => {
            $scope.$applyAsync(() => {
                this.h = data && data.active ? data : { active: false };
            });
        });
        this.$onInit = () => beamjoyStore.send("BJDriftZoneHudRequest");

        // 12,480 : grouped thousands, the way the game's drift app shows points
        this.points = (n) => (typeof n === "number" ? Math.floor(n).toLocaleString("en-US") : "0");
        this.combo = () => `x${(Number(this.h.combo) || 1).toFixed(1)}`;
        this.stateText = () => {
            if (this.h.state === "done") return translate("beamjoy.driftZones.hud.done");
            if (this.h.state === "failed") return this.h.reason || translate("beamjoy.driftZones.hud.failed");
            if (typeof this.h.outFor === "number") {
                return translate("beamjoy.driftZones.hud.out").replace("{n}", this.h.outFor.toFixed(1));
            }
            return translate("beamjoy.driftZones.hud.running");
        };
    },
});
