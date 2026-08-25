angular.module("beamjoy").component("bjConfigGeneralRaceEditor", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/general/raceEditor/app.html",
    controller: function ($scope, beamjoyStore) {
        this.init = false;
        this.default = {};
        this.data = {
            RaceAuthorshipRestriction: false,
            RaceEditorShowOnlyEditable: false,
        };

        ["RaceAuthorshipRestriction", "RaceEditorShowOnlyEditable"].forEach((key) => {
            $scope.$watch(
                () => this.data[key],
                () => {
                    if (!this.init) return;
                    if (this.data[key] === this.default[key]) return;
                    beamjoyStore.send("BJDirectSend", ["setConfig", key, this.data[key]]);
                }
            );
        });
        // same BJSendConfigData broadcast the parent General tab's own top-level toggles read;
        // it already includes these two keys (services/config.lua's onBJRequestCache), just picked
        // out here instead of duplicating the request
        $scope.$on("BJSendConfigData", (_, data) => {
            this.data = {
                RaceAuthorshipRestriction: data.RaceAuthorshipRestriction,
                RaceEditorShowOnlyEditable: data.RaceEditorShowOnlyEditable,
            };
            this.default = angular.copy(this.data);
            this.init = true;
        });
    },
});
