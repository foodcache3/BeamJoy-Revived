angular.module("beamjoy").component("bjConfigVehiclePresetsEditor", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/vehiclePresets/editor/app.html",
    bindings: {
        presetId: "<",
        onClose: "&",
    },
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyConfirm) {
        const translate = $filter("translate");
        this.NAME_MAX_LENGTH = 40;
        // a shared build's name (services/vehiclePresets.lua checks the same)
        this.BUILD_NAME_MIN = 3;
        this.BUILD_NAME_MAX = 32;

        // no Lua-side editing session needed here (unlike the race editor, which needs one for its
        // in-world gizmo): a preset is plain data, so this just edits a local copy and sends the
        // whole thing on Save, same shape as the maps config tab.
        this.allPresets = [];
        // the server's shared builds : {id, model, name, author, photo}, for names already taken
        this.builds = [];
        let original = null;

        const seed = () => {
            let found = null;
            if (this.presetId !== "new") {
                found = this.allPresets.find((p) => p.id === this.presetId);
            }
            this.preset = found
                ? angular.copy(found)
                : { id: null, name: "", entries: [], showInSelector: true };
            // older presets : shown
            if (this.preset.showInSelector === undefined) this.preset.showInSelector = true;
            original = angular.copy(this.preset);
        };

        $rootScope.$on("BJVehiclePresetList", (_, presets) => {
            // Real bug: Lua can't distinguish an empty table from an empty object, so an
            // emptied-out preset list can arrive as `{}` instead of `[]` - truthy, so `presets ||
            // []` kept it as-is. Same fix already established elsewhere in this codebase (see
            // cmps/pointListEditor/app.js's own listsUpdate handler).
            this.allPresets = Array.isArray(presets) ? presets : [];
            // an existing preset being edited elsewhere (or by this same save round-tripping back)
            // shouldn't reset in-progress local edits; only seed once, on first data arrival
            if (!original) seed();
        });
        $rootScope.$on("BJVehicleBuildList", (_, builds) => {
            this.builds = Array.isArray(builds) ? builds : [];
        });
        $rootScope.$on("BJVehiclePresetCapturedVehicle", (_, identity) => {
            if (!this.preset) return;
            this.preset.entries.push(identity);
        });
        // a retaken photo : still the same entry at that place
        $rootScope.$on("BJVehiclePresetPhoto", (_, data) => {
            if (!this.preset || !data) return;
            const entry = this.preset.entries[data.index];
            if (!entry || !this.isBuild(entry) || entry.model !== data.model) return;
            if (data.buildId !== undefined && data.buildId !== null && entry.buildId !== data.buildId) return;
            entry.photo = data.photo;
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

        // a shared build : one already on the server (buildId) or one just captured (pc)
        this.isBuild = (entry) => entry.buildId !== undefined || entry.pc !== undefined;
        const nameKey = (name) => String(name || "").replace(/\s+/g, " ").trim().toLowerCase();
        // why a shared build's name can't be saved, as typed : its length, or another build of
        // the same vehicle (on the server or in this preset) already has it
        this.buildNameProblem = (entry, index) => {
            const name = String(entry.name || "").replace(/\s+/g, " ").trim();
            if (name.length < this.BUILD_NAME_MIN || name.length > this.BUILD_NAME_MAX) {
                return translate("beamjoy.window.config.tabs.vehiclePresets.buildNameLength")
                    .replace("{min}", this.BUILD_NAME_MIN)
                    .replace("{max}", this.BUILD_NAME_MAX);
            }
            const key = nameKey(name);
            const taken = this.builds.find(
                (b) => b.model === entry.model && b.id !== entry.buildId && nameKey(b.name) === key
            );
            if (taken) {
                return translate("beamjoy.window.config.tabs.vehiclePresets.buildNameTaken").replace(
                    "{author}",
                    taken.author || "?"
                );
            }
            const twin = this.preset.entries.some(
                (other, i) =>
                    i !== index &&
                    this.isBuild(other) &&
                    other.model === entry.model &&
                    // the same build twice is one build (the server keeps it once)
                    (entry.buildId === undefined || other.buildId !== entry.buildId) &&
                    nameKey(other.name) === key
            );
            if (twin) return translate("beamjoy.window.config.tabs.vehiclePresets.buildNameTwice");
            return null;
        };
        // its photo : a new one, not saved yet, else the one this game holds for the build
        this.photoSrc = (entry) => {
            if (entry.photo) return "data:image/jpeg;base64," + entry.photo;
            if (entry.buildId === undefined) return null;
            const build = this.builds.find((b) => b.id === entry.buildId);
            return build && build.photo ? `/vehicles/${build.model}/bjs_${build.id}.jpg` : null;
        };
        // a new photo of the car you're in, when it's this build
        this.retakePhoto = (event, entry, index) => {
            event.stopPropagation();
            beamjoyStore.send("BJVehiclePresetRetakePhoto", [
                { model: entry.model, buildId: entry.buildId, pc: entry.pc },
                index,
            ]);
        };

        // renaming a build renames it in every preset that has it
        this.renamesElsewhere = (entry) => {
            if (entry.buildId === undefined) return false;
            const build = this.builds.find((b) => b.id === entry.buildId);
            if (!build || nameKey(build.name) === nameKey(entry.name)) return false;
            return this.allPresets.some(
                (p) => p.id !== this.preset.id && (p.entries || []).some((e) => e.buildId === entry.buildId)
            );
        };

        this.valid = () =>
            !!this.preset &&
            this.preset.name.trim().length >= 3 &&
            this.preset.entries.length > 0 &&
            this.preset.entries.every((e, i) => !this.isBuild(e) || !this.buildNameProblem(e, i));

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
