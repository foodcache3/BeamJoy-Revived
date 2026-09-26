// Full window > Leaderboards : delivery totals (packages / vehicles, the same board as the Jobs
// window's) beside per-race best times (pick a race, its board shows through bj-race-leaderboard).
angular.module("beamjoy").component("bjMainLeaderboards", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/leaderboards/app.html",
    controller: function ($rootScope, $scope, $filter, $interval, beamjoyStore) {
        const translate = $filter("translate");
        const offs = [];
        const on = (event, fn) => offs.push($rootScope.$on(event, fn));
        // standings move : ask again every 15 s while shown, and when a delivery just finished
        const refresh = $interval(() => beamjoyStore.send("BJDeliveryLeaderboardRequest"), 15000);
        on("BJDeliveryResults", () => beamjoyStore.send("BJDeliveryLeaderboardRequest"));
        $scope.$on("$destroy", () => {
            offs.forEach((off) => off());
            $interval.cancel(refresh);
        });

        this.KINDS = ["packages", "vehicles"];
        this.kind = "packages";
        this.board = null;
        on("BJDeliveryLeaderboard", (_, data) => (this.board = data || null));
        this.lb = () => (this.board && this.board[this.kind]) || { rows: [], players: 0 };
        this.mineOutside = () => {
            const lb = this.lb();
            return lb.mine && !lb.rows.some((r) => r.you) ? lb.mine : null;
        };
        this.mineLine = () => {
            const mine = this.lb().mine;
            if (!mine) return translate(`beamjoy.delivery.jobs.lbNone.${this.kind}`);
            return translate("beamjoy.delivery.jobs.lbMine")
                .replace("{1}", mine.rank)
                .replace("{2}", this.lb().players)
                .replace("{3}", (mine.total || 0).toLocaleString());
        };

        // grid races only, like the Activities list
        this.races = [];
        this.raceId = null;
        on("BJEditorRaceList", (_, races) => {
            this.races = (Array.isArray(races) ? races : []).filter((r) => r.mode === "grid");
            if (!this.races.some((r) => r.id === this.raceId)) {
                this.raceId = this.races.length > 0 ? this.races[0].id : null;
            }
        });
        this.pickRace = (race) => (this.raceId = race.id);

        this.$onInit = () => {
            beamjoyStore.send("BJDeliveryLeaderboardRequest");
            beamjoyStore.send("BJEditorRaceListRequest");
        };
    },
});
