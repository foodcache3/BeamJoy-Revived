angular.module("beamjoy").component("bjMainSettings", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/settings/app.html",
    controller: function ($scope, $rootScope, beamjoyStore) {
        this.resetValues = angular.copy(beamjoyStore.settings.defaults);
        this.settings = angular.copy(beamjoyStore.settings.data);
        $rootScope.$on("BJUserSettings", () => {
           this.settings = angular.copy(beamjoyStore.settings.data)
        });

        // Real, confirmed bug: this "About" section's version display never worked and its
        // GitHub link (a plain `<a href>`) never opened a browser - CEF's `local://` UI scheme has
        // nothing for a plain anchor navigation to hand off to an external browser with. Removed
        // per direct request ; both moved to the ImGui top menu bar's own "About" dropdown instead
        // (imgui/menu.lua), where a "copy link" action via `ui_imgui.SetClipboardText` actually
        // works, and the version is already correctly shown there too.

        $scope.$watch(
            () => this.settings,
            () => {
                beamjoyStore.settings.save(this.settings);
            },
            true
        );
    },
});
