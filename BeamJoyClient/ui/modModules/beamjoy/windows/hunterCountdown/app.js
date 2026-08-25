angular.module("beamjoy").component("bjHunterCountdown", {
    templateUrl: "/ui/modModules/beamjoy/windows/hunterCountdown/app.html",
    controller: function ($rootScope) {
        this.active = false;
        this.seconds = null;
        this.waiting = false;
        this.choosingOwn = false;
        this.finished = false;
        this.winner = null;

        $rootScope.$on("BJHunterCountdown", (_, data) => {
            this.active = !!data.active;
            if (!this.active) {
                this.waiting = false;
                this.choosingOwn = false;
                this.finished = false;
                return;
            }
            this.finished = !!data.finished;
            if (this.finished) {
                this.waiting = false;
                this.choosingOwn = false;
                this.winner = data.winner || null;
                return;
            }
            this.waiting = !!data.waiting;
            this.choosingOwn = !!data.choosingOwn;
            this.seconds = (this.waiting || this.choosingOwn) ? null : data.seconds;
        });
    },
});
