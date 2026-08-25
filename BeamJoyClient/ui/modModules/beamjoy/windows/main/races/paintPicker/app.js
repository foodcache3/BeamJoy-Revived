angular.module("beamjoy").component("bjRacePaintPicker", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/races/paintPicker/app.html",
    controller: function ($rootScope, beamjoyStore) {
        // streamlined in-lobby paint picker for single-config/pool vehicle-restricted races : the
        // full native paint list (not a curated subset), across all 3 paint slots, per direct
        // request. Purely cosmetic; never coordinates with the session/server, just applies to
        // the local vehicle directly (raceRunner.lua's setPaint).
        this.SLOTS = [1, 2, 3];
        this.options = [];
        $rootScope.$on("BJRacePaintOptions", (_, options) => {
            this.options = options || [];
        });
        this.$onInit = () => {
            beamjoyStore.send("BJRacePaintOptionsRequest");
        };

        this.swatchColor = (opt) => {
            const c = (opt && opt.baseColor) || [0.5, 0.5, 0.5, 1];
            return `rgb(${Math.round(c[0] * 255)}, ${Math.round(c[1] * 255)}, ${Math.round(
                c[2] * 255
            )})`;
        };
        this.pick = (event, slot, opt) => {
            event.stopPropagation();
            beamjoyStore.send("BJRaceSetPaint", [slot, opt.key]);
        };
    },
});
