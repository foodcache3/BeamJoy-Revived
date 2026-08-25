angular.module("beamjoy").component("bjMapVote", {
    templateUrl: "/ui/modModules/beamjoy/windows/mapVote/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.active = false;
        this.creatorName = null;
        this.targetMapLabel = null;
        this.secondsLeft = null;
        this.threshold = 0;
        this.voterNames = [];

        this.hasVoted = () =>
            this.voterNames.includes(beamjoyStore.players.self.playerName);
        this.canCancel = () =>
            beamjoyStore.permissions.isStaff() ||
            this.creatorName === beamjoyStore.players.self.playerName;

        $rootScope.$on("BJMapVoteUpdate", (_, data) => {
            this.active = !!data.active;
            this.creatorName = data.creatorName || null;
            this.targetMapLabel = data.targetMapLabel || null;
            this.secondsLeft = data.secondsLeft ?? null;
            this.threshold = data.threshold || 0;
            this.voterNames = data.voterNames || [];
        });

        this.toggleVote = () => {
            beamjoyStore.send("BJMapVoteJoin");
        };
        this.cancel = () => {
            beamjoyStore.send("BJMapVoteCancel");
        };
    },
});
