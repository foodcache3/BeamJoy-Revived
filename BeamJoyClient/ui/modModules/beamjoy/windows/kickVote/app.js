angular.module("beamjoy").component("bjKickVote", {
    templateUrl: "/ui/modModules/beamjoy/windows/kickVote/app.html",
    controller: function ($rootScope, $scope, beamjoyStore, beamjoyDelivery) {
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

        // FOCUS : see windows/mapVote for the full note - same behaviour, except the Vote button
        // is also absent for the player being voted on (canVote), so both buttons are optional.
        this.focused = false;
        this.cursor = 0;
        this.buttons = () => {
            const list = [];
            if (this.canVote()) list.push("vote");
            if (this.canCancel()) list.push("cancel");
            return list;
        };
        this.indexOf = (id) => this.buttons().indexOf(id);
        $rootScope.$on("BJKickVoteFocus", (_, data) => {
            $rootScope.$applyAsync(() => {
                this.focused = !!(data && data.active);
                this.cursor = 0;
                beamjoyDelivery.setNavOwner("kickVote", this.focused);
            });
        });
        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.focused || !rising || beamjoyDelivery.otherNavOwner("kickVote")) return;
            $scope.$applyAsync(() => {
                const buttons = this.buttons();
                if (name === "focus_l" || name === "focus_u") this.cursor = Math.max(0, this.cursor - 1);
                else if (name === "focus_r" || name === "focus_d") this.cursor = Math.min(buttons.length - 1, this.cursor + 1);
                else if (name === "ok") {
                    const picked = buttons[this.cursor];
                    if (picked === "cancel") this.cancel();
                    else if (picked === "vote") this.toggleVote();
                } else if (name === "back") beamjoyStore.send("BJKickVoteRelease");
            });
        });
        $scope.$on("$destroy", () => {
            offNav();
            beamjoyDelivery.setNavOwner("kickVote", false);
        });
    },
});
