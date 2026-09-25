// Config > General > Deliveries (Phase 3). Same wholesale-replace convention as the Voting panel :
// setConfig replaces the whole Deliveries table, so any single edit sends the complete current set.
// Kept in sync with services/config.lua's Deliveries defaults and bounds.
angular.module("beamjoy").component("bjConfigGeneralDeliveries", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/general/deliveries/app.html",
    controller: function ($rootScope, $scope, beamjoyStore) {
        const DEFAULTS = {
            MinRouteDistance: 500,
            MaxRouteDistance: 8000,
            ReferenceSpeed: 40,
            OffersPerDepot: 4,
            OfferRotation: 5,
            HoldDuration: 3,
            LobbyDuration: 180,
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
                Object.keys(DEFAULTS).forEach((k) => (payload[k] = Number(this.data[k])));
                // the server refuses a max below the min ; keep them ordered as you drag
                if (payload.MaxRouteDistance < payload.MinRouteDistance) {
                    payload.MaxRouteDistance = payload.MinRouteDistance;
                }
                beamjoyStore.send("BJDirectSend", ["setConfig", "Deliveries", payload]);
            },
            true
        );
        // vehicle-delivery pool (beamjoy/deliveryPool.lua) : what the server can hand out, built from
        // an admin's installed vehicles, plus the delivery-only blacklist : a whole model (which also
        // covers configs a later refresh adds), or single configs from the model's expanded list
        this.pool = { count: 0, cars: 0, trucks: 0, models: [] };
        this.poolBuilding = false;
        this.poolFilter = "";
        this.expanded = {};
        $rootScope.$on("BJDeliveryPool", (_, pool) => {
            this.pool = pool || { count: 0, models: [] };
            if (!Array.isArray(this.pool.models)) this.pool.models = [];
        });
        $rootScope.$on("BJDeliveryPoolBuilding", (_, building) => {
            this.poolBuilding = building === true;
        });
        this.$onInit = () => beamjoyStore.send("BJDeliveryPoolRequest");
        this.refreshPool = () => beamjoyStore.send("BJDeliveryPoolRefresh");
        this.toggleModel = (row) => {
            row.blacklisted = !row.blacklisted; // optimistic, the server echo confirms
            beamjoyStore.send("BJDeliveryPoolBlacklist", [row.model, row.blacklisted]);
        };
        this.toggleConfig = (row, cfg) => {
            if (row.blacklisted) return; // the whole model is off : its configs follow it
            cfg.blacklisted = !cfg.blacklisted;
            row.blocked = (row.blocked || 0) + (cfg.blacklisted ? 1 : -1);
            beamjoyStore.send("BJDeliveryPoolBlacklist", [row.model, cfg.blacklisted, cfg.config]);
        };
        this.toggleExpanded = (row, $event) => {
            if ($event) $event.stopPropagation();
            this.expanded[row.model] = !this.expanded[row.model];
        };
        // "3 of 5 on" when some configs are blocked
        this.configsLine = (row) => {
            const on = row.configs - (row.blocked || 0);
            return on === row.configs ? `${row.configs}` : `${on} / ${row.configs}`;
        };
        this.matches = (text, f) => (text || "").toLowerCase().includes(f);
        // a search hit on a config name shows its model expanded to that config
        this.filteredModels = () => {
            const f = (this.poolFilter || "").toLowerCase();
            return f ? this.pool.models.filter((m) =>
                this.matches(m.label, f) || this.matches(m.model, f) ||
                (m.list || []).some((c) => this.matches(c.label, f))) : this.pool.models;
        };
        this.visibleConfigs = (row) => {
            const f = (this.poolFilter || "").toLowerCase();
            const list = row.list || [];
            if (!f || this.matches(row.label, f) || this.matches(row.model, f)) return list;
            return list.filter((c) => this.matches(c.label, f));
        };
        this.isExpanded = (row) => {
            const f = (this.poolFilter || "").toLowerCase();
            return this.expanded[row.model] ||
                (f && !this.matches(row.label, f) && !this.matches(row.model, f));
        };

        $scope.$on("BJSendConfigData", (_, data) => {
            const d = data.Deliveries || {};
            const next = {};
            Object.keys(DEFAULTS).forEach((k) => (next[k] = d[k] ?? DEFAULTS[k]));
            this.data = next;
            this.default = angular.copy(next);
            this.init = true;
        });
    },
});
