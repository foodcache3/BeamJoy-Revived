// The derby's results panel (the info-panel framework, like the race and infected results) :
// the standings once it's over, the order so far while it runs.
angular.module("beamjoy").component("bjDerbyInfoResults", {
    templateUrl: "/ui/modModules/beamjoy/windows/derbyInfo/results/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore) {
        const translate = $filter("translate");
        this.active = false;
        this.finished = false;
        this.mode = "lms";
        this.arenaName = null;
        this.standings = [];

        const off = $rootScope.$on("BJDerbyInfo", (_, data) => {
            data = data || {};
            this.active = !!data.active;
            if (!this.active) return;
            this.finished = data.state === "FINISHED";
            this.mode = data.mode || "lms";
            this.arenaName = data.arenaName || null;
            this.standings = Array.isArray(data.standings) ? data.standings : [];
        });
        $scope.$on("$destroy", off);
        this.$onInit = () => beamjoyStore.send("BJDerbyInfoRequest");

        this.modeLabel = () => translate(`beamjoy.window.main.tabs.derby.modes.${this.mode}`);
        // what the last column says : still running, out, or left
        this.statusOf = (row) => {
            if (row.left) return translate("beamjoy.window.main.tabs.derby.results.left");
            if (this.mode === "timed") return "";
            if (row.eliminated) return translate("beamjoy.window.main.tabs.derby.out");
            return translate("beamjoy.window.main.tabs.derby.results.running");
        };
        this.formatDamage = (value) => {
            value = Number(value) || 0;
            if (value >= 1000000) return `${(value / 1000000).toFixed(1)}M`;
            if (value >= 1000) return `${Math.round(value / 1000)}k`;
            return `${Math.round(value)}`;
        };
    },
});
