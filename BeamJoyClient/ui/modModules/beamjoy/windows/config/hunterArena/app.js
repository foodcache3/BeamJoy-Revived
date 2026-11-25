angular.module("beamjoy").component("bjConfigHunterArena", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/hunterArena/app.html",
    controller: function (
        $rootScope,
        $scope,
        $timeout,
        $filter,
        beamjoyStore,
        beamjoyNavGuard,
        beamjoyConfirm,
        beamjoyPropEditor
    ) {
        const translate = $filter("translate");

        // ARENA LIST ----------------------------------------------------------------------------
        // the map's hunter arenas, one edited at a time. Picking another, making a new one or
        // deleting one all go through the shared unsaved-changes guard, the same confirmation as
        // switching config tabs (windows/config/derbyArena/app.js is the same list).
        this.meta = { arenas: [], blank: true };
        this.pickedId = null;
        this.arenaOptions = [];
        this.name = "";
        this.pickArena = (value) => {
            const target = value;
            // the picker shows the arena being edited until the switch really happens
            this.pickedId = this.meta.arenaId ?? null;
            if (target === this.meta.arenaId) return;
            beamjoyNavGuard.check(() => beamjoyStore.send("BJEditorHunterArenaPick", [target]));
        };
        this.newArena = (event) => {
            event.stopPropagation();
            beamjoyNavGuard.check(() => beamjoyStore.send("BJEditorHunterArenaNew"));
        };
        this.deleteArena = (event) => {
            event.stopPropagation();
            const message = translate("beamjoy.window.config.tabs.hunterArena.confirmDelete")
                .replace("{name}", this.name || "?");
            beamjoyConfirm.ask(message, () => beamjoyStore.send("BJEditorHunterArenaRemove"));
        };

        // Real gap: settings, spawn placement, and waypoints used to live scrolled together in
        // one long view. Split into tabs, mirroring the race editor's own already-established
        // section split (windows/config/races/editor/app.js's own SECTIONS/activeSection/
        // changeSection).
        this.SECTIONS = ["settings", "spawns", "waypoints", "props"];
        this.activeSection = "settings";
        this.changeSection = (event, section) => {
            event.stopPropagation();
            this.activeSection = section;
            // the Props section's snapping button : the list editor's state, told again (no point
            // list is shown there to have asked)
            if (section === "props") beamjoyStore.send(this.pointListEvents.requestState);
        };
        // the arena's props : the props editor's list and toolbar (cmps/propEditor), shared with
        // the race editor ; read here for the Props tab's count
        this.props = beamjoyPropEditor;

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

        // name + enabled + gameplay defaults: genuinely Hunter-specific, not part of the shared
        // point-list editor at all (see ui/hunterEditor.lua's own pushMeta)
        this.enabled = false;
        this.defaults = {};
        let previousMeta = null;
        let previousDefaults = null;
        $rootScope.$on("BJEditorHunterArenaMetaUpdate", (_, meta) => {
            meta = meta || {};
            meta.arenas = Array.isArray(meta.arenas) ? meta.arenas : [];
            this.meta = meta;
            this.pickedId = meta.arenaId ?? null;
            this.arenaOptions = meta.arenas.map((a) => ({
                value: a.id,
                label: a.enabled
                    ? a.name
                    : `${a.name} (${translate("beamjoy.window.config.tabs.hunterArena.disabled")})`,
            }));
            this.name = meta.name || "";
            this.enabled = meta.enabled === true;
            this.defaults = meta.defaults || {};
            // an arena saved before the per-role station settings existed has neither field, which
            // would leave both dropdowns blank : filled in with the value the server sanitizes a
            // missing one to anyway, so what's shown is what's actually in force. Set before
            // previousDefaults is snapshotted, so this never marks the editor dirty on its own.
            if (!this.defaults.stationRefuelRoles) this.defaults.stationRefuelRoles = "both";
            if (!this.defaults.stationRepairRoles) this.defaults.stationRepairRoles = "both";
            previousMeta = { name: this.name, enabled: this.enabled };
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
        let metaTimeout = null;
        let defaultsTimeout = null;
        $scope.$watchGroup([() => this.name, () => this.enabled], () => {
            if (!previousMeta) return;
            if (this.name === previousMeta.name && this.enabled === previousMeta.enabled) return;
            previousMeta = { name: this.name, enabled: this.enabled };
            if (metaTimeout) $timeout.cancel(metaTimeout);
            metaTimeout = $timeout(() => {
                beamjoyStore.send("BJEditorHunterArenaSetMeta", [
                    { name: this.name, enabled: this.enabled },
                ]);
            }, DEBOUNCE_MS);
        });
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
            if (metaTimeout) $timeout.cancel(metaTimeout);
            if (defaultsTimeout) $timeout.cancel(defaultsTimeout);
        });

        this.vehiclePresets = [];
        // who an open station/garage is open to, per interaction kind. "both" is the default and is
        // exactly what "Allow fuel stations & garages" did on its own, so an arena saved before
        // these existed keeps behaving the same way.
        this.stationRoleOptions = [
            { value: "both", label: "beamjoy.window.config.tabs.hunterArena.stationRoles.both" },
            { value: "hunted", label: "beamjoy.window.config.tabs.hunterArena.stationRoles.hunted" },
            { value: "hunters", label: "beamjoy.window.config.tabs.hunterArena.stationRoles.hunters" },
            { value: "none", label: "beamjoy.window.config.tabs.hunterArena.stationRoles.none" },
        ];

        this.vehiclePresetOptions = [];
        const rebuildVehiclePresetOptions = () => {
            this.vehiclePresetOptions = [
                { value: null, label: "beamjoy.window.config.tabs.hunterArena.vehiclePool.none" },
                ...this.vehiclePresets.map((p) => ({ value: p.id, label: p.name })),
            ];
        };
        $rootScope.$on("BJVehiclePresetList", (_, presets) => {
            // Real bug: Lua can't distinguish an empty table from an empty object, so an
            // emptied-out preset list can arrive as `{}` instead of `[]` - truthy, so `presets ||
            // []` kept it as-is, and `{}.map` isn't a function. Same fix already established
            // elsewhere in this codebase for the identical ambiguity (see
            // cmps/pointListEditor/app.js's own listsUpdate handler).
            this.vehiclePresets = Array.isArray(presets) ? presets : [];
            rebuildVehiclePresetOptions();
        });
        this.openVehiclePresets = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRequestOpenWindow", ["config"]);
            $rootScope.$broadcast("BJOpenTab", "vehiclePresets");
        };
    },
});
