angular.module("beamjoy").component("bjConfigInfectedArena", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/infectedArena/app.html",
    controller: function (
        $rootScope,
        $scope,
        $timeout,
        $filter,
        beamjoyStore,
        beamjoyNavGuard
    ) {
        const translate = $filter("translate");

        // config for the shared <bj-point-list-editor>; see cmps/pointListEditor/ for what each
        // field means ; color/hasDir are Lua-only rendering concerns and live in
        // ui/infectedEditor.lua's own list specs instead, not duplicated here
        this.pointLists = [
            { key: "survivorSpawns", labelKey: "beamjoy.window.config.tabs.infectedArena.survivorSpawn", min: 2 },
            { key: "infectedSpawns", labelKey: "beamjoy.window.config.tabs.infectedArena.infectedSpawn", min: 1 },
        ];
        this.pointListEvents = {
            listsUpdate: "BJEditorInfectedArenaListsUpdate",
            activeUpdate: "BJEditorInfectedArenaActiveUpdate",
            select: "BJEditorInfectedArenaSelect",
            create: "BJEditorInfectedArenaCreate",
            delete: "BJEditorInfectedArenaDelete",
            setToVehicle: "BJEditorInfectedArenaSetToVehicle",
            teleportTo: "BJEditorInfectedArenaTeleportTo",
            setRadius: "BJEditorInfectedArenaSetWaypointRadius",
            snapToGround: "BJEditorInfectedArenaSnapToGround",
            snapMethod: "BJEditorInfectedArenaSnapMethod",
            setSnapToGround: "BJEditorInfectedArenaSetSnapToGround",
            setSnapMethod: "BJEditorInfectedArenaSetSnapMethod",
        };

        this.$onInit = () => {
            beamjoyStore.send("BJEditorInfectedArenaOpen");
        };

        // registers with the shared nav guard so switching config tabs or closing the whole
        // config window while this editor has unsaved changes asks first, same as the hunter
        // arena editor's own registration
        const dirtyCheck = () => this.dirty;
        beamjoyNavGuard.set(
            dirtyCheck,
            translate("beamjoy.window.config.tabs.infectedArena.confirmDiscard")
        );
        $scope.$on("$destroy", () => {
            beamjoyNavGuard.clear(dirtyCheck);
            beamjoyStore.send("BJEditorInfectedArenaClose");
        });

        // enabled + gameplay defaults: genuinely Infected-specific, not part of the shared point-
        // list editor at all (see ui/infectedEditor.lua's own pushMeta)
        this.enabled = false;
        this.defaults = {};
        let previousEnabled = null;
        let previousDefaults = null;
        $rootScope.$on("BJEditorInfectedArenaMetaUpdate", (_, meta) => {
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
            beamjoyStore.send("BJEditorInfectedArenaSave");
        };

        // simple debounced watches (not a full diff) : the Lua side just replaces its own field
        // wholesale, so there's nothing to diff per-key here; collapses a burst of rapid slider
        // drags into one send, same 150ms window the hunter arena editor established for the same
        // reason
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
                    beamjoyStore.send("BJEditorInfectedArenaSetEnabled", [val]);
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
                    beamjoyStore.send("BJEditorInfectedArenaSetDefaults", [val]);
                }, DEBOUNCE_MS);
            },
            true
        );
        $scope.$on("$destroy", () => {
            if (enabledTimeout) $timeout.cancel(enabledTimeout);
            if (defaultsTimeout) $timeout.cancel(defaultsTimeout);
        });
    },
});
