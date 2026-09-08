angular.module("beamjoy").component("bjConfigHunterArena", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/hunterArena/app.html",
    controller: function (
        $rootScope,
        $scope,
        $timeout,
        $filter,
        beamjoyStore,
        beamjoyNavGuard
    ) {
        const translate = $filter("translate");

        // Real gap: settings, spawn placement, and waypoints used to live scrolled together in
        // one long view. Split into tabs, mirroring the race editor's own already-established
        // section split (windows/config/races/editor/app.js's own SECTIONS/activeSection/
        // changeSection).
        this.SECTIONS = ["settings", "spawns", "waypoints"];
        this.activeSection = "settings";
        this.changeSection = (event, section) => {
            event.stopPropagation();
            this.activeSection = section;
        };

        // config for the shared <bj-point-list-editor>; see cmps/pointListEditor/ for what each
        // field means ; color/hasDir/defaultRadius are Lua-only rendering concerns and live in
        // ui/hunterEditor.lua's own list specs instead, not duplicated here. Split across the
        // Spawns/Waypoints tabs above (bjPointListEditor only ever renders whichever list keys are
        // actually in the array passed to it - see that component's own comment - so this split is
        // purely which keys each tab's own instance is handed, nothing else changes).
        this.spawnPointLists = [
            { key: "hunterSpawns", labelKey: "beamjoy.window.config.tabs.hunterArena.hunterSpawn", min: 2 },
            { key: "preySpawns", labelKey: "beamjoy.window.config.tabs.hunterArena.preySpawn", min: 2 },
            // no minimum : entirely optional, only consulted when hunterRespawnStrategy === "hubs"
            { key: "respawnHubs", labelKey: "beamjoy.window.config.tabs.hunterArena.respawnHub" },
        ];
        this.waypointPointLists = [
            { key: "waypoints", labelKey: "beamjoy.window.config.tabs.hunterArena.waypoint", min: 2, hasRadius: true },
        ];
        this.pointListEvents = {
            listsUpdate: "BJEditorHunterArenaListsUpdate",
            activeUpdate: "BJEditorHunterArenaActiveUpdate",
            select: "BJEditorHunterArenaSelect",
            create: "BJEditorHunterArenaCreate",
            delete: "BJEditorHunterArenaDelete",
            setToVehicle: "BJEditorHunterArenaSetToVehicle",
            teleportTo: "BJEditorHunterArenaTeleportTo",
            setRadius: "BJEditorHunterArenaSetWaypointRadius",
            snapToGround: "BJEditorHunterArenaSnapToGround",
            snapMethod: "BJEditorHunterArenaSnapMethod",
            setSnapToGround: "BJEditorHunterArenaSetSnapToGround",
            setSnapMethod: "BJEditorHunterArenaSetSnapMethod",
            requestState: "BJEditorHunterArenaRequestState",
        };

        // per direct request : the "Respawn hubs" strategy button is greyed out (not hidden) with
        // an explanatory tooltip while the list itself is empty. This listens to the SAME
        // broadcast <bj-point-list-editor> itself already receives (a full {key -> item[]}
        // snapshot, see pointListEditor.lua's own pushListsUpdate), just to read the one count this
        // file needs.
        this.respawnHubsCount = 0;
        $rootScope.$on("BJEditorHunterArenaListsUpdate", (_, lists) => {
            this.respawnHubsCount = ((lists && lists.respawnHubs) || []).length;
        });

        this.$onInit = () => {
            beamjoyStore.send("BJEditorHunterArenaOpen");
            beamjoyStore.send("BJVehiclePresetListRequest");
        };

        // registers with the shared nav guard so switching config tabs or closing the whole
        // config window while this editor has unsaved changes asks first, same as the race
        // editor's own registration
        const dirtyCheck = () => this.dirty;
        beamjoyNavGuard.set(
            dirtyCheck,
            translate("beamjoy.window.config.tabs.hunterArena.confirmDiscard")
        );
        $scope.$on("$destroy", () => {
            beamjoyNavGuard.clear(dirtyCheck);
            beamjoyStore.send("BJEditorHunterArenaClose");
        });

        // enabled + gameplay defaults: genuinely Hunter-specific, not part of the shared point-
        // list editor at all (see ui/hunterEditor.lua's own pushMeta)
        this.enabled = false;
        this.defaults = {};
        let previousEnabled = null;
        let previousDefaults = null;
        $rootScope.$on("BJEditorHunterArenaMetaUpdate", (_, meta) => {
            this.enabled = meta.enabled === true;
            this.defaults = meta.defaults || {};
            previousEnabled = this.enabled;
            previousDefaults = angular.copy(this.defaults);
        });

        this.dirty = false;
        $rootScope.$on("BJEditorDirty", (_, state) => {
            this.dirty = state === true;
        });

        this.save = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorHunterArenaSave");
        };

        // simple debounced watches (not a full diff like the race editor's own performDiff) : both
        // handlers on the Lua side just replace their own field wholesale, so there's nothing to
        // diff per-key here; collapses a burst of rapid slider drags into one send, same 150ms
        // window the race editor established for the same reason
        const DEBOUNCE_MS = 150;
        let enabledTimeout = null;
        let defaultsTimeout = null;
        $scope.$watch(
            () => this.enabled,
            (val) => {
                if (previousEnabled === null) {
                    previousEnabled = val;
                    return;
                }
                if (val === previousEnabled) return;
                previousEnabled = val;
                if (enabledTimeout) $timeout.cancel(enabledTimeout);
                enabledTimeout = $timeout(() => {
                    beamjoyStore.send("BJEditorHunterArenaSetEnabled", [val]);
                }, DEBOUNCE_MS);
            }
        );
        $scope.$watch(
            () => this.defaults,
            (val) => {
                if (!previousDefaults) {
                    previousDefaults = angular.copy(val);
                    return;
                }
                if (angular.equals(val, previousDefaults)) return;
                previousDefaults = angular.copy(val);
                if (defaultsTimeout) $timeout.cancel(defaultsTimeout);
                defaultsTimeout = $timeout(() => {
                    beamjoyStore.send("BJEditorHunterArenaSetDefaults", [val]);
                }, DEBOUNCE_MS);
            },
            true
        );
        $scope.$on("$destroy", () => {
            if (enabledTimeout) $timeout.cancel(enabledTimeout);
            if (defaultsTimeout) $timeout.cancel(defaultsTimeout);
        });

        this.vehiclePresets = [];
        this.vehiclePresetOptions = [];
        const rebuildVehiclePresetOptions = () => {
            this.vehiclePresetOptions = [
                { value: null, label: "beamjoy.window.config.tabs.hunterArena.vehiclePool.none" },
                ...this.vehiclePresets.map((p) => ({ value: p.id, label: p.name })),
            ];
        };
        $rootScope.$on("BJVehiclePresetList", (_, presets) => {
            this.vehiclePresets = presets || [];
            rebuildVehiclePresetOptions();
        });
        this.openVehiclePresets = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRequestOpenWindow", ["config"]);
            $rootScope.$broadcast("BJOpenTab", "vehiclePresets");
        };
    },
});
