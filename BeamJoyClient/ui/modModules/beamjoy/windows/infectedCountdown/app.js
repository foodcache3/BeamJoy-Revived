angular.module("beamjoy").component("bjInfectedCountdown", {
    templateUrl: "/ui/modModules/beamjoy/windows/infectedCountdown/app.html",
    controller: function ($rootScope) {
        this.active = false;
        this.seconds = null;
        this.finished = false;
        this.winner = null;

        $rootScope.$on("BJInfectedCountdown", (_, data) => {
            this.active = !!data.active;
            if (!this.active) {
                this.finished = false;
                return;
            }
            this.finished = !!data.finished;
            if (this.finished) {
                this.winner = data.winner || null;
                return;
            }
            this.seconds = data.seconds;
        });
    },
});
