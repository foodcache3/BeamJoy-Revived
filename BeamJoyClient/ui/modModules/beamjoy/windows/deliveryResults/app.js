// Delivery results panel (Phase 3). Opened by beamjoy/delivery.lua when the server scores a
// delivery (BJDeliveryResults). Controller-driven like the job board : A opens the destination's
// own job board when it's a depot too, B closes. Convoy deliveries add the convoy and "driving
// together" lines and a table of every member, which fills in as the others deliver (delivery.lua
// re-pushes it). Shared styles (.bj-dlv) live in the job board's template.
angular.module("beamjoy").component("bjDeliveryResults", {
    templateUrl: "/ui/modModules/beamjoy/windows/deliveryResults/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyDelivery) {
        const translate = $filter("translate");
        this.fmt = beamjoyDelivery;
        this.open = false;
        this.r = {};

        $rootScope.$on("BJDeliveryResults", (_, data) => {
            data = data || {};
            this.open = !!data.open;
            beamjoyDelivery.setNavOwner("results", this.open);
            if (this.open) this.r = data;
        });

        this.$onInit = () => beamjoyStore.send("BJDeliveryResultsRequest");

        this.cargoLabel = () =>
            this.r.vehicle ? this.r.vehicle.label : translate(`beamjoy.delivery.cargo.${this.r.cargo}`);
        this.conditionLine = () => {
            const c = this.r.condition;
            if (!c) return "";
            return translate("beamjoy.delivery.results.condition")
                .replace("{1}", translate(`beamjoy.delivery.condition.${c.band}`))
                .replace("{2}", c.broken)
                .replace("{3}", c.total);
        };
        this.hasTotal = () => this.r.total != null;
        this.stopsLine = () => translate("beamjoy.delivery.results.stops").replace("{1}", this.r.stops);
        this.convoy = () => this.r.convoy || null;
        this.table = () => (this.r.convoyTable && this.r.convoyTable.rows) || [];
        this.sizeLine = () => {
            const c = this.convoy();
            const key = c.onTime ? "beamjoy.delivery.results.convoyOnTime" : "beamjoy.delivery.results.convoyLate";
            return translate(key).replace("{1}", c.size);
        };
        this.cohesionLine = () =>
            translate(
                this.convoy().onTime
                    ? "beamjoy.delivery.results.cohesion"
                    : "beamjoy.delivery.results.cohesionLate"
            ).replace("{1}", Math.round((this.convoy().cohesionShare || 0) * 100));
        this.statusLine = () => {
            const c = this.convoy();
            if (!c || c.size < 2) return "";
            const grace = beamjoyDelivery.formatTime(c.graceSec);
            if (c.first) return translate("beamjoy.delivery.results.firstIn").replace("{1}", grace);
            if (c.onTime) return translate("beamjoy.delivery.results.inGrace").replace("{1}", grace);
            return translate("beamjoy.delivery.results.afterGrace").replace("{1}", grace);
        };
        this.rowTime = (row) => (row.actualSec != null ? beamjoyDelivery.formatTime(row.actualSec) : "");
        this.rowCondition = (row) => (row.band ? translate(`beamjoy.delivery.condition.${row.band}`) : "");
        this.rowCohesion = (row) => (row.cohesion != null ? `${Math.round(row.cohesion * 100)}%` : "");
        this.rowStatus = (row) => translate(`beamjoy.delivery.results.status.${row.status}`);
        this.close = () => beamjoyStore.send("BJDeliveryResultsClose");
        this.next = () => {
            if (this.r.toIsDepot) beamjoyStore.send("BJDeliveryResultsNext");
        };
        this.timeLine = () =>
            translate("beamjoy.delivery.results.time")
                .replace("{1}", beamjoyDelivery.formatTime(this.r.actualSec))
                .replace("{2}", beamjoyDelivery.formatTime(this.r.targetSec));
        this.baseLine = () =>
            translate("beamjoy.delivery.results.base").replace(
                "{1}",
                beamjoyDelivery.formatDistance(this.r.meters)
            );
        this.totalLine = () =>
            translate(`beamjoy.delivery.results.total.${this.r.kind}`)
                .replace("{1}", (this.r.total || 0).toLocaleString())
                .replace("{2}", this.r.rank || 1)
                .replace("{3}", this.r.players || 1);

        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.open || !rising) return;
            $scope.$applyAsync(() => {
                if (name === "ok") this.next();
                else if (name === "back") this.close();
            });
        });
        $scope.$on("$destroy", offNav);
    },
});
