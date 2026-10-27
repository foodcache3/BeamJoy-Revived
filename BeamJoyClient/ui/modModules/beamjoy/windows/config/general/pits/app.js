// Config > General > Pits (PIT_SYSTEM_PLAN.md) : the server's RacePits table. Same wholesale-replace
// convention as the Deliveries panel : setConfig replaces the whole table, so any single edit sends
// the complete current set. Kept in sync with services/config.lua's RacePits defaults and bounds.
// ExperimentalTyres (off by default) : tyre changes in the pit menu, apart from repairs.
angular.module("beamjoy").component("bjConfigGeneralPits", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/general/pits/app.html",
    controller: function ($scope, beamjoyStore) {
        const DEFAULTS = {
            // seconds for crossing PIT IN faster than the lane's limit plus the tolerance ; 0 off
            EntrySpeedPenalty: 5,
            SpeedTolerance: 5,
            ExperimentalTyres: false,
        };
        this.init = false;
        this.default = {};
        this.data = angular.copy(DEFAULTS);

        $scope.$watch(
            () => this.data,
            () => {
                if (!this.init) return;
                if (angular.equals(this.data, this.default)) return;
                const payload = {};
                Object.keys(DEFAULTS).forEach((k) => (payload[k] = typeof DEFAULTS[k] === "boolean" ? this.data[k] === true : Number(this.data[k])));
                beamjoyStore.send("BJDirectSend", ["setConfig", "RacePits", payload]);
            },
            true
        );
        $scope.$on("BJSendConfigData", (_, data) => {
            const d = data.RacePits || {};
            const next = {};
            Object.keys(DEFAULTS).forEach((k) => (next[k] = d[k] ?? DEFAULTS[k]));
            this.data = next;
            this.default = angular.copy(next);
            this.init = true;
        });
    },
});
