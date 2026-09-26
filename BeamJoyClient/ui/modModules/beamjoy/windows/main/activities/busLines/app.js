// Player-facing Bus Lines browse list, in the Main window's Activities tab (see
// windows/main/activities/app.js). Until now the only way to start a line was the Big Map POI or
// the drive-up prompt at its first stop ; this is a third, always-reachable entry point. Purely a
// list + Start/Stop (laid out like Jobs' depot table) - the actual run (vehicle check, GPS, hold-to-advance) all lives in
// beamjoy/busRun.lua exactly as it does for the other two entry points, this just calls
// M.startLine by line id over the wire (BJMainStartBusLine) and reuses the existing HUD stop
// event (BJBusHudStop) so there's only one "stop a run" code path. Bus lines are solo : Start
// starts the run directly, no lobby.
angular.module("beamjoy").component("bjMainBusLines", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/activities/busLines/app.html",
    controller: function ($rootScope, $scope, $element, $filter, beamjoyStore) {
        const translate = $filter("translate");
        const offs = [];
        const on = (event, fn) => offs.push($rootScope.$on(event, fn));
        $scope.$on("$destroy", () => offs.forEach((off) => off()));

        // the line table (laid out like Jobs' depot table), built once per push : a fresh array
        // per digest never settles
        this.rows = [];
        this.selected = 0;
        this.countLine = "";
        const rebuild = (lines) => {
            const previous = this.rows[this.selected];
            this.rows = lines.map((line, index) => {
                const stops = Array.isArray(line.stops) ? line.stops : [];
                const first = stops[0] && stops[0].name;
                const last = stops.length > 1 && stops[stops.length - 1].name;
                return {
                    key: line.id !== undefined ? line.id : `i${index}`,
                    id: line.id,
                    name: line.name && line.name.length > 0 ? line.name : `${translate("beamjoy.buslines.line")} ${index + 1}`,
                    kind: translate(line.loopable ? "beamjoy.buslines.kind.loop" : "beamjoy.buslines.kind.oneWay"),
                    stops: stops.length,
                    route: first && last
                        ? translate("beamjoy.buslines.routeFromTo").replace("{from}", first).replace("{to}", last)
                        : translate("beamjoy.buslines.edit.minStops"),
                    startable: stops.length >= 2,
                };
            });
            const kept = previous ? this.rows.findIndex((r) => r.key === previous.key) : -1;
            this.selected = kept >= 0 ? kept : Math.min(this.selected, Math.max(0, this.rows.length - 1));
            this.countLine = translate(this.rows.length === 1 ? "beamjoy.buslines.countOne" : "beamjoy.buslines.count")
                .replace("{n}", this.rows.length);
        };
        on("BJEditorBusLinesData", (_, data) => {
            // same Lua-can't-distinguish-{}-from-[] normalization every other list push in this
            // codebase needs (see cmps/pointListEditor/app.js's own listsUpdate handler)
            rebuild(Array.isArray(data && data.lines) ? data.lines : []);
        });
        this.current = () => this.rows[this.selected];
        // a click selects, a click on the selected row starts it (the pad : its cursor selects the
        // row it lands on, so A starts it)
        this.rowClick = (index) => {
            if (index === this.selected) this.start(this.rows[index]);
            else this.selected = index;
        };
        const onPadFocus = (e) => {
            const row = e.target && e.target.getAttribute && e.target.getAttribute("data-row");
            if (row === null || row === undefined) return;
            $scope.$applyAsync(() => (this.selected = Number(row)));
        };
        $element[0].addEventListener("bjrpadfocus", onPadFocus);
        $scope.$on("$destroy", () => $element[0].removeEventListener("bjrpadfocus", onPadFocus));

        this.runActive = false;
        this.runLineName = "";
        on("BJBusHud", (_, data) => {
            this.runActive = !!(data && data.active);
            this.runLineName = (data && data.lineName) || "";
        });

        this.$onInit = () => {
            beamjoyStore.send("BJEditorBusLinesDataRequest");
            beamjoyStore.send("BJBusHudRequest");
        };

        this.start = (row) => {
            if (!row || !row.startable) return;
            beamjoyStore.send("BJMainStartBusLine", [row.id]);
            // the run may start with the game's own vehicle picker : get out of its way
            $rootScope.$broadcast("BJMainClose");
        };
        this.stopRun = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJBusHudStop");
        };
    },
});
