// The drag tree, big and top middle (beamjoy/dragRun.lua, BJDragTree) : BeamJoy's own strips have no
// tree in the world, so it's here, as the game's own tree app draws it. The staging bulb (blue : its
// top arc the pre-stage beam, its bottom arc the stage beam), the three ambers, the green ; a red
// light turns them all red. Under it while staging, how far the front tyres are from the line.
angular.module("beamjoy").component("bjDragTree", {
    templateUrl: "/ui/modModules/beamjoy/windows/dragTree/app.html",
    controller: function ($rootScope, $scope, beamjoyStore) {
        this.t = { active: false };

        $rootScope.$on("BJDragTree", (_, data) => {
            $scope.$applyAsync(() => (this.t = data && data.active ? data : { active: false }));
        });
        this.$onInit = () => beamjoyStore.send("BJDragTreeRequest");

        const lights = () => this.t.lights || {};
        this.red = () => !!lights().red;
        this.staging = () => !!(lights().prestage || lights().stage);
        this.prestage = () => !!lights().prestage;
        this.stage = () => !!lights().stage;
        this.amber = (i) => !this.red() && !!lights()[`a${i}`];
        this.green = () => !this.red() && !!lights().green;

        // the staging guide : metres from the line, - short of it
        const num = (v) => typeof v === "number" && isFinite(v);
        this.showDistance = () => num(this.t.distance) && Math.abs(this.t.distance) < 25;
        this.onLine = () => num(this.t.distance) && Math.abs(this.t.distance) < 0.178;
        this.distanceText = () => {
            const d = Math.abs(this.t.distance || 0);
            if (this.t.imperial) {
                const inches = d / 0.0254;
                return inches >= 36 ? `${(inches / 12).toFixed(1)} ft` : `${inches.toFixed(1)} in`;
            }
            return d >= 1 ? `${d.toFixed(2)} m` : `${(d * 100).toFixed(0)} cm`;
        };
        // arrows up : keep rolling up, arrows down : too deep, back up ; more of them the further off
        this.glyph = () => {
            if (this.onLine()) return "●";
            const d = Math.abs(this.t.distance);
            const n = d > 8 ? 3 : d > 4 ? 2 : 1;
            return Array(n).fill(this.t.distance < 0 ? "▲" : "▼").join(" ");
        };
    },
});
