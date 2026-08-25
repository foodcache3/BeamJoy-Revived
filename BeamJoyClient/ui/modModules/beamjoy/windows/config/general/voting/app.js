angular.module("beamjoy").component("bjConfigGeneralVoting", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/general/voting/app.html",
    controller: function ($scope, beamjoyStore) {
        this.init = false;
        this.default = {};
        this.data = {
            MapVoteThresholdPercent: 51,
            MapVoteTimeout: 30,
            KickVoteThresholdPercent: 51,
            KickVoteTimeout: 30,
        };

        // setConfig replaces the whole Voting table at once (same wholesale-replace convention as
        // every other nested config value, e.g. Freeroam's own accordion), hence a deep watch on
        // $ctrl.data as a whole, rather than one $watch per field, so any single edit sends the
        // complete current set
        $scope.$watch(
            () => this.data,
            () => {
                if (!this.init) return;
                if (angular.equals(this.data, this.default)) return;
                beamjoyStore.send("BJDirectSend", ["setConfig", "Voting", this.data]);
            },
            true
        );
        $scope.$on("BJSendConfigData", (_, data) => {
            const voting = data.Voting || {};
            this.data = {
                MapVoteThresholdPercent: voting.MapVoteThresholdPercent ?? 51,
                MapVoteTimeout: voting.MapVoteTimeout ?? 30,
                KickVoteThresholdPercent: voting.KickVoteThresholdPercent ?? 51,
                KickVoteTimeout: voting.KickVoteTimeout ?? 30,
            };
            this.default = angular.copy(this.data);
            this.init = true;
        });
    },
});
