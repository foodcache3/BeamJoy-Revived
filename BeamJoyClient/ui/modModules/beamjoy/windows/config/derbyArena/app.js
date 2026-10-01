// Config > Arenas > Derby : the map's derby arenas, one edited at a time (ui/derbyEditor.lua).
// Picking another arena, making a new one or leaving with unsaved changes goes through the shared
// unsaved-changes guard, the same confirmation as switching config tabs.
angular.module("beamjoy").component("bjConfigDerbyArena", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/derbyArena/app.html",
    controller: function ($rootScope, $scope, $timeout, $filter, beamjoyStore, beamjoyNavGuard, beamjoyConfirm) {
        const translate = $filter("translate");

        this.SECTIONS = ["settings", "positions"];
        this.activeSection = "settings";
        this.changeSection = (event, section) => {
            event.stopPropagation();
            this.activeSection = section;
        };

        this.pointLists = [
            { key: "startPositions", labelKey: "beamjoy.window.config.tabs.derbyArena.startPosition", min: 2 },
            { key: "zone", labelKey: "beamjoy.window.config.tabs.derbyArena.zone", hasRadius: true, max: 1 },
        ];
        this.pointListEvents = {
            listsUpdate: "BJEditorDerbyArenaListsUpdate",
            activeUpdate: "BJEditorDerbyArenaActiveUpdate",
            select: "BJEditorDerbyArenaSelect",
            create: "BJEditorDerbyArenaCreate",
            delete: "BJEditorDerbyArenaDelete",
            setToVehicle: "BJEditorDerbyArenaSetToVehicle",
            teleportTo: "BJEditorDerbyArenaTeleportTo",
            setRadius: "BJEditorDerbyArenaSetWaypointRadius",
            snapToGround: "BJEditorDerbyArenaSnapToGround",
            snapMethod: "BJEditorDerbyArenaSnapMethod",
            setSnapToGround: "BJEditorDerbyArenaSetSnapToGround",
            setSnapMethod: "BJEditorDerbyArenaSetSnapMethod",
            requestState: "BJEditorDerbyArenaRequestState",
        };

        this.meta = { arenas: [], blank: true };
        this.pickedId = null;
        this.arenaOptions = [];
        this.name = "";
        this.enabled = false;
        this.floorDepth = 10;
        this.defaults = {};
        this.hasZone = false;
        this.startCount = 0;
        // the sumo zone's shape : a circle's size is the radius box in its point row, a
        // rectangle's or ellipse's is width and length here (and it turns with the gizmo's rotate tool)
        this.zone = { shape: "circle", width: 80, length: 80 };
        this.zoneShapeOptions = [
            { value: "circle", label: "beamjoy.window.config.tabs.derbyArena.zoneShapes.circle" },
            { value: "rect", label: "beamjoy.window.config.tabs.derbyArena.zoneShapes.rect" },
            { value: "ellipse", label: "beamjoy.window.config.tabs.derbyArena.zoneShapes.ellipse" },
        ];
        let zoneSent = null;
        const zoneList = this.pointLists.find((l) => l.key === "zone");
        const syncRadiusBox = () => {
            zoneList.hasRadius = this.zone.shape === "circle";
        };
        // the last values Lua sent : a watch only sends what the user changed
        let sent = null;

        const offMeta = $rootScope.$on("BJEditorDerbyArenaMetaUpdate", (_, meta) => {
            meta = meta || {};
            meta.arenas = Array.isArray(meta.arenas) ? meta.arenas : [];
            this.meta = meta;
            this.pickedId = meta.arenaId ?? null;
            this.arenaOptions = meta.arenas.map((a) => ({
                value: a.id,
                label: a.enabled ? a.name : `${a.name} (${translate("beamjoy.window.config.tabs.derbyArena.disabled")})`,
            }));
            this.name = meta.name || "";
            this.enabled = meta.enabled === true;
            this.floorDepth = meta.floorDepth ?? 10;
            this.defaults = angular.copy(meta.defaults || {});
            sent = { name: this.name, enabled: this.enabled, floorDepth: this.floorDepth, defaults: angular.copy(this.defaults) };
        });
        const offLists = $rootScope.$on("BJEditorDerbyArenaListsUpdate", (_, lists) => {
            lists = lists || {};
            this.hasZone = Array.isArray(lists.zone) && lists.zone.length > 0;
            this.startCount = Array.isArray(lists.startPositions) ? lists.startPositions.length : 0;
            const z = this.hasZone ? lists.zone[0] : null;
            if (z) {
                const side = Math.round((z.radius || 40) * 2);
                this.zone = {
                    shape: z.shape === "rect" || z.shape === "ellipse" ? z.shape : "circle",
                    width: Math.round(z.width ?? side),
                    length: Math.round(z.length ?? side),
                };
                zoneSent = angular.copy(this.zone);
                syncRadiusBox();
            }
            if (!this.hasZone && this.defaults.mode === "sumo") this.defaults.mode = "lms";
        });

        this.dirty = false;
        const offDirty = $rootScope.$on("BJEditorDirty", (_, state) => {
            this.dirty = state === true;
        });

        const dirtyCheck = () => this.dirty;
        beamjoyNavGuard.set(dirtyCheck, translate("beamjoy.window.config.tabs.derbyArena.confirmDiscard"));
        this.$onInit = () => {
            beamjoyStore.send("BJVehiclePresetListRequest");
            beamjoyStore.send("BJEditorDerbyArenaOpen");
        };
        $scope.$on("$destroy", () => {
            beamjoyNavGuard.clear(dirtyCheck);
            beamjoyStore.send("BJEditorDerbyArenaClose");
            [offMeta, offLists, offDirty, offPresets].forEach((off) => off());
            timeouts.forEach((t) => $timeout.cancel(t));
        });

        // ARENA LIST -----------------------------------------------------------------------------
        this.pickArena = (value) => {
            const target = value;
            // the picker shows the arena being edited until the switch really happens
            this.pickedId = this.meta.arenaId ?? null;
            if (target === this.meta.arenaId) return;
            beamjoyNavGuard.check(() => beamjoyStore.send("BJEditorDerbyArenaPick", [target]));
        };
        this.newArena = (event) => {
            event.stopPropagation();
            beamjoyNavGuard.check(() => beamjoyStore.send("BJEditorDerbyArenaNew"));
        };
        this.deleteArena = (event) => {
            event.stopPropagation();
            const message = translate("beamjoy.window.config.tabs.derbyArena.confirmDelete").replace("{name}", this.name || "?");
            beamjoyConfirm.ask(message, () => beamjoyStore.send("BJEditorDerbyArenaRemove"));
        };
        this.save = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorDerbyArenaSave");
        };

        // SETTINGS -------------------------------------------------------------------------------
        this.modeOptions = [];
        const buildModeOptions = () => {
            this.modeOptions = ["lms", "timed", "sumo"]
                .filter((m) => m !== "sumo" || this.hasZone)
                .map((m) => ({ value: m, label: `beamjoy.window.main.tabs.derby.modes.${m}` }));
        };
        buildModeOptions();
        $scope.$watch(() => this.hasZone, buildModeOptions);

        this.vehiclePresetOptions = [];
        const offPresets = $rootScope.$on("BJVehiclePresetList", (_, presets) => {
            const list = Array.isArray(presets) ? presets : [];
            this.vehiclePresetOptions = [
                { value: null, label: "beamjoy.window.main.tabs.derby.anyVehicle" },
                ...list.map((p) => ({ value: p.id, label: p.name })),
            ];
        });

        // edits go to Lua a moment after the last change (a slider drag is one send)
        const DEBOUNCE_MS = 150;
        const timeouts = [];
        let metaTimeout = null;
        let defaultsTimeout = null;
        $scope.$watchGroup([() => this.name, () => this.enabled, () => this.floorDepth], () => {
            if (!sent) return;
            if (this.name === sent.name && this.enabled === sent.enabled && this.floorDepth === sent.floorDepth) return;
            sent.name = this.name;
            sent.enabled = this.enabled;
            sent.floorDepth = this.floorDepth;
            if (metaTimeout) $timeout.cancel(metaTimeout);
            metaTimeout = $timeout(() => {
                beamjoyStore.send("BJEditorDerbyArenaSetMeta", [{ name: this.name, enabled: this.enabled, floorDepth: this.floorDepth }]);
            }, DEBOUNCE_MS);
            timeouts.push(metaTimeout);
        });
        $scope.$watch(() => this.defaults, (val) => {
            if (!sent || angular.equals(val, sent.defaults)) return;
            sent.defaults = angular.copy(val);
            if (defaultsTimeout) $timeout.cancel(defaultsTimeout);
            defaultsTimeout = $timeout(() => {
                beamjoyStore.send("BJEditorDerbyArenaSetDefaults", [angular.copy(this.defaults)]);
            }, DEBOUNCE_MS);
            timeouts.push(defaultsTimeout);
        }, true);

        let zoneTimeout = null;
        $scope.$watch(() => this.zone, (val) => {
            if (!zoneSent || angular.equals(val, zoneSent)) return;
            zoneSent = angular.copy(val);
            syncRadiusBox();
            if (zoneTimeout) $timeout.cancel(zoneTimeout);
            zoneTimeout = $timeout(() => {
                beamjoyStore.send("BJEditorDerbyArenaSetZoneShape", [angular.copy(this.zone)]);
            }, DEBOUNCE_MS);
            timeouts.push(zoneTimeout);
        }, true);

        this.cannotEnable = () => this.enabled && this.startCount < 2;
    },
});
