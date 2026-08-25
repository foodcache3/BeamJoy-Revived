await import(`/ui/modModules/beamjoy/windows/config/vehiclePresets/editor/app.js`);

angular.module("beamjoy").component("bjConfigVehiclePresets", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/vehiclePresets/app.html",
    controller: function ($rootScope, $filter, beamjoyStore, beamjoyConfirm) {
        const translate = $filter("translate");

        // shared, map-independent vehicle pool presets (see Server/BeamJoyServer/services/
        // vehiclePresets.lua), reusable by races' own "pool" vehicle restriction mode and, later,
        // any other gamemode (vehicle delivery, hunter, infected, ...) that needs a pickable pool
        // of vehicles ; this tab is where they're actually created/named/managed.
        this.presets = [];
        $rootScope.$on("BJVehiclePresetList", (_, presets) => {
            this.presets = presets || [];
        });
        this.$onInit = () => {
            beamjoyStore.send("BJVehiclePresetListRequest");
        };

        // null = browsing the list ; "new" or an existing preset's id = editor panel open
        this.editingId = null;
        this.openEditor = (id) => {
            this.editingId = id || "new";
        };
        this.closeEditor = () => {
            this.editingId = null;
        };

        this.deletePreset = (event, preset) => {
            event.stopPropagation();
            beamjoyConfirm.ask(
                translate("beamjoy.window.config.tabs.vehiclePresets.confirmDelete").replace(
                    "{name}",
                    preset.name
                ),
                () => beamjoyStore.send("BJDirectSend", ["vehiclePresetDelete", preset.id])
            );
        };
    },
});
