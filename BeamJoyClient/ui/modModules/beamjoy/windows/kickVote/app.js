angular.module("beamjoy").component("bjKickVote", {
    templateUrl: "/ui/modModules/beamjoy/windows/kickVote/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.active = false;
        this.creatorName = null;
        this.targetName = null;
        this.secondsLeft = null;
        this.threshold = 0;
        this.voterNames = [];

        this.hasVoted = () =>
            this.voterNames.includes(beamjoyStore.players.self.playerName);
        this.canCancel = () =>
            beamjoyStore.permissions.isStaff() ||
            this.creatorName === beamjoyStore.players.self.playerName;
        this.canVote = () =>
            this.targetName !== beamjoyStore.players.self.playerName;

        $rootScope.$on("BJKickVoteUpdate", (_, data) => {
            this.active = !!data.active;
            this.creatorName = data.creatorName || null;
            this.targetName = data.targetName || null;
            this.secondsLeft = data.secondsLeft ?? null;
            this.threshold = data.threshold || 0;
            this.voterNames = data.voterNames || [];
        });

        this.toggleVote = () => {
            beamjoyStore.send("BJKickVoteJoin");
        };
        this.cancel = () => {
            beamjoyStore.send("BJKickVoteCancel");
        };
    },
});
