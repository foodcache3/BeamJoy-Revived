angular.module("beamjoy").component("bjMainSettings", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/settings/app.html",
    controller: function ($scope, $rootScope, beamjoyStore) {
        this.resetValues = angular.copy(beamjoyStore.settings.defaults);
        this.settings = angular.copy(beamjoyStore.settings.data);
        $rootScope.$on("BJUserSettings", () => {
           this.settings = angular.copy(beamjoyStore.settings.data)
        });
        // the vehicle settings saved on this PC (automatic lights, dust and particles) : until they
        // arrive the page's own defaults stand in
        beamjoyStore.send("BJRequestVehicleSettings");

        // Real, confirmed bug: this "About" section's version display never worked and its
        // GitHub link (a plain `<a href>`) never opened a browser - CEF's `local://` UI scheme has
        // nothing for a plain anchor navigation to hand off to an external browser with. Removed
        // per direct request ; both moved to the ImGui top menu bar's own "About" dropdown instead
        // (imgui/menu.lua), where a "copy link" action via `ui_imgui.SetClipboardText` actually
        // works, and the version is already correctly shown there too.

        // the rail hides until you need it (windows/main/app.js) : a per-player UI preference,
        // kept in the UI's own storage like the rail's position
        this.railAutoHide = false;
        try {
            this.railAutoHide = localStorage.getItem("beamjoy.rail.autoHide") === "1";
        } catch (e) {
            // storage unavailable : off
        }
        // the race HUD's layout (windows/raceHud/app.js), kept the same way
        this.raceHudLayouts = [
            { value: "standard", label: "beamjoy.window.main.tabs.settings.sections.menu.raceHud.standard" },
            { value: "compact", label: "beamjoy.window.main.tabs.settings.sections.menu.raceHud.compact" },
            { value: "full", label: "beamjoy.window.main.tabs.settings.sections.menu.raceHud.full" },
        ];
        this.raceHudLayout = "standard";
        try {
            const saved = localStorage.getItem("beamjoy.raceHud.layout");
            if (this.raceHudLayouts.some((o) => o.value === saved)) this.raceHudLayout = saved;
        } catch (e) {
            // storage unavailable : standard
        }
        $scope.$watch(
            () => this.raceHudLayout,
            (layout, old) => {
                if (layout === old) return;
                try {
                    localStorage.setItem("beamjoy.raceHud.layout", layout);
                } catch (e) {
                    // not remembered, still applied for this session
                }
                $rootScope.$broadcast("BJRaceHudLayout", layout);
            }
        );

        $scope.$watch(
            () => this.railAutoHide,
            (on, old) => {
                if (on === old) return;
                try {
                    localStorage.setItem("beamjoy.rail.autoHide", on ? "1" : "0");
                } catch (e) {
                    // not remembered, still applied for this session
                }
                $rootScope.$broadcast("BJRailAutoHide", on);
            }
        );

        // Real bug: this used to save on the watch's first run too, when nothing had changed,
        // sending the page's own defaults before the saved values had even arrived : opening
        // Settings put every saved vehicle setting back to its default
        $scope.$watch(
            () => this.settings,
            (value, old) => {
                if (value === old) return;
                beamjoyStore.settings.save(this.settings);
            },
            true
        );
    },
});
