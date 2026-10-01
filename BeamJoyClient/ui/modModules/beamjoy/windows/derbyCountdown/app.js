// the derby's big centre-screen numbers : the countdown, then the winner once it's over
angular.module("beamjoy").component("bjDerbyCountdown", {
    templateUrl: "/ui/modModules/beamjoy/windows/derbyCountdown/app.html",
    controller: function ($rootScope, $scope, beamjoyStore) {
        this.active = false;
        this.seconds = null;
        this.finished = false;
        this.winnerName = null;

        const off = $rootScope.$on("BJDerbyCountdown", (_, data) => {
            data = data || {};
            this.active = !!data.active;
            if (!this.active) {
                this.finished = false;
                return;
            }
            this.finished = !!data.finished;
            if (this.finished) {
                this.winnerName = data.winnerName || null;
                return;
            }
            this.seconds = data.seconds;
        });
        $scope.$on("$destroy", off);
        this.$onInit = () => beamjoyStore.send("BJDerbyCountdownRequest");
    },
});
