// Config > Freeroam tab. Two sections, one shown at a time (like infectedArena's settings/spawns
// split): "Stations & Garages" (the shared <bj-point-list-editor>) and "Bus Lines" (the nested
// <bj-config-bus-lines> below). The Lua host is ui/freeroamEditor.lua - it owns the one
// activityEditor slot for this whole tab and only lets the live section mutate. Switching sections
// is blocked while there are unsaved changes, so Save just saves whichever section is live.

angular.module("beamjoy").component("bjConfigFreeroam", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/freeroam/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyNavGuard) {
        const translate = $filter("translate");

        this.SECTIONS = ["stations", "buslines"];
        this.activeSection = "stations";
        // switching sections while one is dirty would strand the unsaved edits (each section is a
        // separate Lua editor). The inactive tab is disabled until you Save or Discard.
        this.changeSection = (event, section) => {
            event.stopPropagation();
            if (section === this.activeSection || this.dirty) return;
            this.activeSection = section;
            beamjoyStore.send("BJEditorFreeroamSection", [section]);
        };

        // "Stations & Garages" section: config for the shared <bj-point-list-editor>
        this.pointLists = [
            { key: "energyStations", labelKey: "beamjoy.window.config.tabs.freeroam.station", min: 0, hasRadius: true, hasName: true },
            { key: "garages", labelKey: "beamjoy.window.config.tabs.freeroam.garage", min: 0, hasRadius: true, hasName: true },
        ];
        this.pointListEvents = {
            listsUpdate: "BJEditorFreeroamListsUpdate",
            activeUpdate: "BJEditorFreeroamActiveUpdate",
            select: "BJEditorFreeroamSelect",
            create: "BJEditorFreeroamCreate",
            delete: "BJEditorFreeroamDelete",
            setToVehicle: "BJEditorFreeroamSetToVehicle",
            teleportTo: "BJEditorFreeroamTeleportTo",
            setRadius: "BJEditorFreeroamSetRadius",
            setName: "BJEditorFreeroamSetName",
            snapToGround: "BJEditorFreeroamSnapToGround",
            snapMethod: "BJEditorFreeroamSnapMethod",
            setSnapToGround: "BJEditorFreeroamSetSnapToGround",
            setSnapMethod: "BJEditorFreeroamSetSnapMethod",
            requestState: "BJEditorFreeroamRequestState",
        };

        // "Bus Lines" section: the nested component below wires its own BJEditorBusLines* events;
        // it just needs its own snap toolbar wired here
        this.busSnapEvents = {
            snapToGround: "BJEditorBusLinesSnapToGround",
            snapMethod: "BJEditorBusLinesSnapMethod",
            setSnapToGround: "BJEditorBusLinesSetSnapToGround",
            setSnapMethod: "BJEditorBusLinesSetSnapMethod",
        };

        this.$onInit = () => {
            beamjoyStore.send("BJEditorFreeroamOpen");
        };

        const dirtyCheck = () => this.dirty;
        beamjoyNavGuard.set(
            dirtyCheck,
            translate("beamjoy.window.config.tabs.freeroam.confirmDiscard")
        );
        $scope.$on("$destroy", () => {
            beamjoyNavGuard.clear(dirtyCheck);
            beamjoyStore.send("BJEditorFreeroamClose");
        });

        this.dirty = false;
        $rootScope.$on("BJEditorDirty", (_, state) => {
            this.dirty = state === true;
        });

        this.save = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorFreeroamSave");
        };
        // re-open the current section fresh, throwing away unsaved edits
        this.discard = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorFreeroamOpen");
        };
    },
});

// Nested: the Bus Lines editor sidebar. 2-level - a line list, and (for the selected line) its
// ordered stop list, drag-to-reorder via cmps/sortable (same as the race editor's gate list). All
// state is pushed from ui/busLineEditor.lua ; every row action is a BJEditorBusLines* send with
// 1-based line/stop indices.
angular.module("beamjoy").component("bjConfigBusLines", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/freeroam/busLines/app.html",
    controller: function ($rootScope, $timeout, beamjoyStore) {
        this.lines = [];
        this.activeLine = null; // 1-based, or null
        this.activeStop = null; // 1-based, or null

        $rootScope.$on("BJEditorBusLinesListUpdate", (_, lines) => {
            this.lines = Array.isArray(lines) ? lines : [];
        });
        $rootScope.$on("BJEditorBusLinesActiveUpdate", (_, active) => {
            active = active || {};
            this.activeLine = active.line || null;
            this.activeStop = active.stop || null;
            if (this.activeLine && this.activeStop) {
                $timeout(() => {
                    const el = document.getElementById(
                        `bus-stop-row-${this.activeLine}-${this.activeStop}`
                    );
                    if (el) el.scrollIntoView({ behavior: "smooth", block: "nearest" });
                });
            }
        });

        this.$onInit = () => {
            beamjoyStore.send("BJEditorBusLinesRequestState");
        };

        const send = (event, args) => beamjoyStore.send(event, args);

        this.selectLine = (event, li) => {
            event.stopPropagation();
            send("BJEditorBusLinesSelectLine", [li]);
        };
        this.addLine = (event) => {
            event.stopPropagation();
            send("BJEditorBusLinesAddLine", []);
        };
        this.deleteLine = (event, li) => {
            event.stopPropagation();
            send("BJEditorBusLinesDeleteLine", [li]);
        };
        this.setLineName = (li, name) => send("BJEditorBusLinesSetLineName", [li, name || ""]);
        this.toggleLoopable = (li, value) => send("BJEditorBusLinesSetLoopable", [li, value === true]);

        this.selectStop = (event, li, si) => {
            event.stopPropagation();
            send("BJEditorBusLinesSelectStop", [li, si]);
        };
        this.addStop = (event, li) => {
            event.stopPropagation();
            send("BJEditorBusLinesAddStop", [li]);
        };
        this.deleteStop = (event, li, si) => {
            event.stopPropagation();
            send("BJEditorBusLinesDeleteStop", [li, si]);
        };
        // drag-and-drop reorder via cmps/sortable, same convention as the race editor's own
        // sortUpdate (windows/config/races/editor/app.js) : both the dragged item's index and the
        // drop separator's value arrive 0-based and get normalized to 1-based here before sending,
        // so ui/busLineEditor.lua's onMoveStop can reuse raceEditor.lua's onReorderGates algorithm
        // verbatim with no further index adjustment.
        this.sortUpdate = (li, index, newValue) => {
            send("BJEditorBusLinesMoveStop", [li, index + 1, newValue + 1]);
        };
        this.setStopName = (li, si, name) => send("BJEditorBusLinesSetStopName", [li, si, name || ""]);
        this.setStopRadius = (li, si, radius) =>
            send("BJEditorBusLinesSetStopRadius", [li, si, Number(radius)]);
        this.setStopToVehicle = (event, li, si) => {
            event.stopPropagation();
            send("BJEditorBusLinesSetStopToVehicle", [li, si]);
        };
        this.teleportToStop = (event, li, si) => {
            event.stopPropagation();
            send("BJEditorBusLinesTeleportToStop", [li, si]);
        };
    },
});
