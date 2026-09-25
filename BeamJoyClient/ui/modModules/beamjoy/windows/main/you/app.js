// Full window > Home > "You" column : the car you're in (with the low fuel button), your delivery
// standings, and personal shortcuts (nametags, start a vote, change nickname, welcome screen).
angular.module("beamjoy").component("bjMainYou", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/you/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore) {
        const translate = $filter("translate");
        const offs = [];
        const on = (event, fn) => offs.push($rootScope.$on(event, fn));
        $scope.$on("$destroy", () => offs.forEach((off) => off()));

        this.carLabel = () => {
            const store = beamjoyStore.players;
            const me = store.players.find((p) => p.playerName === store.self.playerName);
            const vehicles = me && me.vehicles ? Object.values(me.vehicles) : [];
            const current = vehicles.find((v) => v.vid === store.self.currentVehicle);
            return current ? current.label : translate("beamjoy.window.main.playerlist.onFoot");
        };

        this.fuelLow = false;
        this.fuelEmpty = false;
        on("BJFuelStatus", (_, data) => {
            data = data || {};
            this.fuelLow = data.low === true;
            this.fuelEmpty = data.empty === true;
        });
        this.fuelAction = () => beamjoyStore.send(this.fuelEmpty ? "BJFuelEmergencyRefuel" : "BJFuelSetWaypoint");

        // delivery standings, from the same push as the Jobs window's leaderboard
        this.board = null;
        on("BJDeliveryLeaderboard", (_, data) => (this.board = data || null));
        this.standing = (kind) => {
            const lb = this.board && this.board[kind];
            if (!lb || !lb.mine) return translate("beamjoy.window.main.you.noStanding");
            return translate("beamjoy.window.main.you.standing")
                .replace("{rank}", lb.mine.rank)
                .replace("{total}", (lb.mine.total || 0).toLocaleString());
        };

        this.nametags = !beamjoyStore.settings.data.nametags.hideNameTags;
        on("BJNametagsState", (_, data) => (this.nametags = !(data && data.hideNameTags)));
        this.toggleNametags = () => {
            this.nametags = !this.nametags;
            beamjoyStore.send("BJToggleNametagsHideState");
        };

        this.canVote = () =>
            beamjoyStore.permissions.hasAllPermissions(undefined, "VoteMap") ||
            beamjoyStore.permissions.hasAllPermissions(undefined, "VoteKick");
        this.startVote = () => $rootScope.$broadcast("BJMainOpenPanel", "vote");
        this.changeNickname = () => $rootScope.$broadcast("BJLoginShow", { change: true });
        this.welcome = () => beamjoyStore.send("BJOpenIntroPanel");

        this.$onInit = () => beamjoyStore.send("BJDeliveryLeaderboardRequest");
    },
});
