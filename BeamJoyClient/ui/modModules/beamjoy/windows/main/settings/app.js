angular.module("beamjoy").component("bjMainSettings", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/settings/app.html",
    controller: function ($scope, $rootScope, beamjoyStore) {
        this.resetValues = angular.copy(beamjoyStore.settings.defaults);
        this.settings = angular.copy(beamjoyStore.settings.data);
        $rootScope.$on("BJUserSettings", () => {
           this.settings = angular.copy(beamjoyStore.settings.data)
        });

        this.githubUrl = "https://github.com/foodcache3/BeamJoy-sandbox";
        this.version = null;
        this.build = null;
        $rootScope.$on("BJVersion", (_, data) => {
            this.version = data.version;
            this.build = data.build;
        });

        $scope.$watch(
            () => this.settings,
            () => {
                beamjoyStore.settings.save(this.settings);
            },
            true
        );
    },
});
