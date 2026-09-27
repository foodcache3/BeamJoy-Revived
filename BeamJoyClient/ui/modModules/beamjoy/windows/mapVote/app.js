angular.module("beamjoy").component("bjMapVote", {
    templateUrl: "/ui/modModules/beamjoy/windows/mapVote/app.html",
    controller: function ($rootScope, $scope, beamjoyStore, beamjoyDelivery) {
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

        // FOCUS : the Focus control while a vote is running (beamjoy/mainNav.lua) gives this
        // overlay the pad, so Vote / Cancel can be reached without a mouse ; B (or the control
        // again) lets go. The overlay itself stays visible either way - unlike the run HUDs,
        // nothing here is hidden, this only adds the cursor and the button presses.
        this.focused = false;
        this.cursor = 0;
        // Cancel only exists for staff / whoever started it, so the list length varies
        this.buttons = () => (this.canCancel() ? ["vote", "cancel"] : ["vote"]);
        this.indexOf = (id) => this.buttons().indexOf(id);
        $rootScope.$on("BJMapVoteFocus", (_, data) => {
            $rootScope.$applyAsync(() => {
                this.focused = !!(data && data.active);
                this.cursor = 0;
                beamjoyDelivery.setNavOwner("mapVote", this.focused);
            });
        });
        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.focused || !rising || beamjoyDelivery.otherNavOwner("mapVote")) return;
            $scope.$applyAsync(() => {
                const n = this.buttons().length;
                if (name === "focus_l" || name === "focus_u") this.cursor = Math.max(0, this.cursor - 1);
                else if (name === "focus_r" || name === "focus_d") this.cursor = Math.min(n - 1, this.cursor + 1);
                else if (name === "ok") {
                    if (this.buttons()[this.cursor] === "cancel") this.cancel();
                    else this.toggleVote();
                } else if (name === "back") beamjoyStore.send("BJMapVoteRelease");
            });
        });
        $scope.$on("$destroy", () => {
            offNav();
            beamjoyDelivery.setNavOwner("mapVote", false);
        });
    },
});
