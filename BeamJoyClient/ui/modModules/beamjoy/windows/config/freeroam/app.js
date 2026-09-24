// Config > Freeroam tab. Two sections, one shown at a time (like infectedArena's settings/spawns
// split): "Stations & Garages" (the nested <bj-config-stations> below) and "Bus Lines" (the nested
// <bj-config-bus-lines> below). The Lua host is ui/freeroamEditor.lua - it owns the one
// activityEditor slot for this whole tab and only lets the live section mutate. Switching sections
// is blocked while there are unsaved changes, so Save just saves whichever section is live.
//
// Stations & Garages used to be the shared <bj-point-list-editor> ; moved to its own dedicated
// component (mirroring Bus Lines' own split) once stations gained per-pump sub-lists - see
// ui/stationsEditor.lua's own file header for why that needed a dedicated Lua module too, not just
// a dedicated Angular one.

angular.module("beamjoy").component("bjConfigFreeroam", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/freeroam/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyNavGuard, beamjoyConfirm) {
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

        // "Stations & Garages" section: the nested component below wires its own
        // BJEditorStations* events ; it just needs its own snap toolbar wired here
        this.stationsSnapEvents = {
            snapToGround: "BJEditorStationsSnapToGround",
            snapMethod: "BJEditorStationsSnapMethod",
            setSnapToGround: "BJEditorStationsSetSnapToGround",
            setSnapMethod: "BJEditorStationsSetSnapMethod",
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
        // re-open the current section fresh, throwing away unsaved edits - confirmed first, same
        // message + pattern as every other destructive action in this codebase (beamjoyConfirm.ask)
        this.discard = (event) => {
            event.stopPropagation();
            beamjoyConfirm.ask(
                translate("beamjoy.window.config.tabs.freeroam.confirmDiscard"),
                () => beamjoyStore.send("BJEditorFreeroamOpen")
            );
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
        // real, confirmed bug: the button's own color didn't update until some UNRELATED action
        // (adding/removing a line) forced a full list refresh from Lua. Unlike name/radius
        // (ng-model, so the view is authoritative locally the instant you type/drag), this button
        // never mutated `line` itself - only the round-trip echo from Lua ever changed what
        // `ng-class` reads, so the view stayed stale until something else happened to trigger
        // that echo's own re-render. Mutate `line.loopable` directly here too, same as every
        // ng-model-bound field already does, instead of waiting on the round trip.
        this.toggleLoopable = (line, li, value) => {
            line.loopable = value === true;
            send("BJEditorBusLinesSetLoopable", [li, value === true]);
        };

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

// Nested: the Stations & Garages editor sidebar. Two flat lists (stations, garages) ; each station
// additionally expands to its own unordered pump list (no reordering, no facing - a pump is just a
// position + radius + fuel type(s), same shape as the station itself). All state is pushed from
// ui/stationsEditor.lua ; every row action is a BJEditorStations* send with 1-based indices.
angular.module("beamjoy").component("bjConfigStations", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/freeroam/stations/app.html",
    controller: function ($rootScope, $timeout, beamjoyStore) {
        // kept in sync with services/freeroamData.lua's own M.ENERGY_TYPES ; none selected means
        // "any combustion fuel" (see BJEnergyStation's own doc there)
        this.typeOptions = [
            { key: "gasoline", labelKey: "beamjoy.window.config.tabs.freeroam.fuelType.gasoline" },
            { key: "diesel", labelKey: "beamjoy.window.config.tabs.freeroam.fuelType.diesel" },
            { key: "kerosine", labelKey: "beamjoy.window.config.tabs.freeroam.fuelType.kerosine" },
            { key: "n2o", labelKey: "beamjoy.window.config.tabs.freeroam.fuelType.n2o" },
            { key: "electricEnergy", labelKey: "beamjoy.window.config.tabs.freeroam.fuelType.electricEnergy" },
        ];

        this.stations = [];
        this.garages = [];
        this.activeList = null; // "stations"|"garages"|null
        this.activeIndex = null; // 1-based, or null
        this.activePump = null; // 1-based, or null (only meaningful when activeList === "stations")

        $rootScope.$on("BJEditorStationsListUpdate", (_, lists) => {
            lists = lists || {};
            this.stations = Array.isArray(lists.stations) ? lists.stations : [];
            this.garages = Array.isArray(lists.garages) ? lists.garages : [];
        });
        $rootScope.$on("BJEditorStationsActiveUpdate", (_, active) => {
            active = active || {};
            this.activeList = active.list || null;
            this.activeIndex = active.index || null;
            this.activePump = active.pump || null;
            if (this.activeList && this.activeIndex) {
                $timeout(() => {
                    const el = document.getElementById(
                        `station-row-${this.activeList}-${this.activeIndex}`
                    );
                    if (el) el.scrollIntoView({ behavior: "smooth", block: "nearest" });
                });
            }
        });

        this.$onInit = () => {
            beamjoyStore.send("BJEditorStationsRequestState");
        };

        const send = (event, args) => beamjoyStore.send(event, args);

        this.hasType = (item, typeKey) => Array.isArray(item.types) && item.types.includes(typeKey);
        // same optimistic-update fix already established for pointListEditor/busLines' own
        // toggle buttons : mutate the local object directly instead of only waiting on the
        // round-trip echo, so rapid clicks never read stale data
        this.toggleStationType = (event, station, si, typeKey) => {
            event.stopPropagation();
            const current = Array.isArray(station.types) ? station.types : [];
            const types = current.includes(typeKey)
                ? current.filter((t) => t !== typeKey)
                : [...current, typeKey];
            station.types = types;
            send("BJEditorStationsSetStationTypes", [si, types]);
        };
        this.togglePumpType = (event, pump, si, pi, typeKey) => {
            event.stopPropagation();
            const current = Array.isArray(pump.types) ? pump.types : [];
            const types = current.includes(typeKey)
                ? current.filter((t) => t !== typeKey)
                : [...current, typeKey];
            pump.types = types;
            send("BJEditorStationsSetPumpTypes", [si, pi, types]);
        };

        this.selectItem = (event, list, index) => {
            event.stopPropagation();
            send("BJEditorStationsSelectItem", [list, index]);
        };
        this.addItem = (event, list) => {
            event.stopPropagation();
            send("BJEditorStationsAddItem", [list]);
        };
        this.deleteItem = (event, list, index) => {
            event.stopPropagation();
            send("BJEditorStationsDeleteItem", [list, index]);
        };
        this.setItemName = (list, index, name) => send("BJEditorStationsSetItemName", [list, index, name || ""]);
        this.setItemRadius = (list, index, radius) =>
            send("BJEditorStationsSetItemRadius", [list, index, Number(radius)]);
        this.setItemToVehicle = (event, list, index) => {
            event.stopPropagation();
            send("BJEditorStationsSetItemToVehicle", [list, index]);
        };
        this.teleportToItem = (event, list, index) => {
            event.stopPropagation();
            send("BJEditorStationsTeleportToItem", [list, index]);
        };

        this.selectPump = (event, si, pi) => {
            event.stopPropagation();
            send("BJEditorStationsSelectPump", [si, pi]);
        };
        this.addPump = (event, si) => {
            event.stopPropagation();
            send("BJEditorStationsAddPump", [si]);
        };
        this.deletePump = (event, si, pi) => {
            event.stopPropagation();
            send("BJEditorStationsDeletePump", [si, pi]);
        };
        this.setPumpRadius = (si, pi, radius) => send("BJEditorStationsSetPumpRadius", [si, pi, Number(radius)]);
        this.setPumpToVehicle = (event, si, pi) => {
            event.stopPropagation();
            send("BJEditorStationsSetPumpToVehicle", [si, pi]);
        };
        this.teleportToPump = (event, si, pi) => {
            event.stopPropagation();
            send("BJEditorStationsTeleportToPump", [si, pi]);
        };

        this.countLabel = (list) => `(${(list === "stations" ? this.stations : this.garages).length})`;
    },
});
