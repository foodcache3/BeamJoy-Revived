angular.module("beamjoy").component("bjConfigVehiclePresetsEditor", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/vehiclePresets/editor/app.html",
    bindings: {
        presetId: "<",
        onClose: "&",
    },
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyConfirm) {
        const translate = $filter("translate");
        this.NAME_MAX_LENGTH = 40;

        // no Lua-side editing session needed here (unlike the race editor, which needs one for its
        // in-world gizmo): a preset is plain data, so this just edits a local copy and sends the
        // whole thing on Save, same shape as the maps config tab.
        this.allPresets = [];
        let original = null;

        const seed = () => {
            let found = null;
            if (this.presetId !== "new") {
                found = this.allPresets.find((p) => p.id === this.presetId);
            }
            this.preset = found
                ? angular.copy(found)
                : { id: null, name: "", entries: [] };
            original = angular.copy(this.preset);
        };

        $rootScope.$on("BJVehiclePresetList", (_, presets) => {
            this.allPresets = presets || [];
            // an existing preset being edited elsewhere (or by this same save round-tripping back)
            // shouldn't reset in-progress local edits; only seed once, on first data arrival
            if (!original) seed();
        });
        $rootScope.$on("BJVehiclePresetCapturedVehicle", (_, identity) => {
            if (!this.preset) return;
            this.preset.entries.push(identity);
        });

        this.$onInit = () => {
            beamjoyStore.send("BJVehiclePresetListRequest");
        };

        this.dirty = false;
        $scope.$watch(
            () => this.preset,
            () => {
                this.dirty = !!original && !angular.equals(this.preset, original);
            },
            true
        );

        this.addCurrentVehicle = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJVehiclePresetCaptureVehicle", [this.preset.entries]);
        };
        this.removeEntry = (event, index) => {
            event.stopPropagation();
            this.preset.entries.splice(index, 1);
        };

        this.valid = () =>
            !!this.preset &&
            this.preset.name.trim().length >= 3 &&
            this.preset.entries.length > 0;

        this.save = () => {
            if (!this.valid()) return;
            beamjoyStore.send("BJDirectSend", ["vehiclePresetSave", this.preset]);
            this.onClose();
        };
        this.cancel = (event) => {
            if (event) event.stopPropagation();
            this.onClose();
        };
        this.deletePreset = (event) => {
            event.stopPropagation();
            beamjoyConfirm.ask(
                translate("beamjoy.window.config.tabs.vehiclePresets.confirmDelete").replace(
                    "{name}",
                    this.preset.name
                ),
                () => {
                    beamjoyStore.send("BJDirectSend", ["vehiclePresetDelete", this.preset.id]);
                    this.onClose();
                }
            );
        };
    },
});
