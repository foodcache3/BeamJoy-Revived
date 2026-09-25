// Delivery run HUD (Phase 3). Driven by beamjoy/delivery.lua (BJDeliveryHud, pushed on its slow
// tick while a job runs) : cargo, destination, distance left, time against the target, the drop-off
// hold state, the convoy's grace clock, Unstuck (vehicle jobs) and Abandon. Shared styles (.bj-dlv) live in the job board's template.
angular.module("beamjoy").component("bjDeliveryHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/deliveryHud/app.html",
    controller: function ($rootScope, $filter, beamjoyStore, beamjoyDelivery, beamjoyConfirm) {
        const translate = $filter("translate");
        this.fmt = beamjoyDelivery;
        this.active = false;
        this.data = {};

        $rootScope.$on("BJDeliveryHud", (_, data) => {
            data = data || {};
            this.active = !!data.active;
            if (this.active) this.data = data;
        });

        this.$onInit = () => beamjoyStore.send("BJDeliveryHudRequest");

        this.cargoLabel = () => this.data.title || translate(`beamjoy.delivery.cargo.${this.data.cargo}`);
        this.overTarget = () => (this.data.elapsedSec || 0) > (this.data.targetSec || 0);
        this.convoyLine = () => {
            const c = this.data.convoy;
            if (!c) return "";
            return translate("beamjoy.delivery.hud.convoy").replace("{1}", c.size);
        };
        this.graceLine = () => {
            const c = this.data.convoy;
            if (!c || c.graceLeft == null) return "";
            if (c.graceLeft <= 0) return translate("beamjoy.delivery.hud.graceOver");
            return translate("beamjoy.delivery.hud.grace")
                .replace("{1}", c.firstName || "?")
                .replace("{2}", beamjoyDelivery.formatTime(c.graceLeft));
        };
        this.unstuckLabel = () => {
            const u = this.data.unstuck;
            if (!u) return "";
            if (u.state === "cooldown") return translate("beamjoy.delivery.hud.unstuckCooldown").replace("{1}", u.seconds);
            if (u.state === "moving") return translate("beamjoy.delivery.hud.unstuckMovingShort");
            return translate("beamjoy.delivery.hud.unstuck");
        };
        this.unstuck = () => {
            if (this.data.unstuck && this.data.unstuck.state === "ready") beamjoyStore.send("BJDeliveryUnstuck");
        };
        this.abandon = () => {
            beamjoyConfirm.ask(translate("beamjoy.delivery.hud.abandonConfirm"), () =>
                beamjoyStore.send("BJDeliveryAbandon")
            );
        };
    },
});
