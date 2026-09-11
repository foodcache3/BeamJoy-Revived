// Player-facing Bus Lines browse list, in the Main window's Activities tab (see
// windows/main/activities/app.js). Until now the only way to start a line was the Big Map POI or
// the drive-up prompt at its first stop ; this is a third, always-reachable entry point. Purely a
// list + Start/Stop - the actual run (vehicle check, GPS, hold-to-advance) all lives in
// beamjoy/busRun.lua exactly as it does for the other two entry points, this just calls
// M.startLine by line id over the wire (BJMainStartBusLine) and reuses the existing HUD stop
// event (BJBusHudStop) so there's only one "stop a run" code path.
angular.module("beamjoy").component("bjMainBusLines", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/activities/busLines/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.lines = [];
        $rootScope.$on("BJEditorBusLinesData", (_, data) => {
            // same Lua-can't-distinguish-{}-from-[] normalization every other list push in this
            // codebase needs (see cmps/pointListEditor/app.js's own listsUpdate handler)
            this.lines = Array.isArray(data && data.lines) ? data.lines : [];
        });

        this.runActive = false;
        this.runLineName = "";
        $rootScope.$on("BJBusHud", (_, data) => {
            this.runActive = !!(data && data.active);
            this.runLineName = (data && data.lineName) || "";
        });

        this.$onInit = () => {
            beamjoyStore.send("BJEditorBusLinesDataRequest");
            beamjoyStore.send("BJBusHudRequest");
        };

        this.lineLabel = (line, index) =>
            (line.name && line.name.length > 0) ? line.name : `${index + 1}`;

        this.startLine = (event, line) => {
            event.stopPropagation();
            beamjoyStore.send("BJMainStartBusLine", [line.id]);
        };
        this.stopRun = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJBusHudStop");
        };
    },
});
