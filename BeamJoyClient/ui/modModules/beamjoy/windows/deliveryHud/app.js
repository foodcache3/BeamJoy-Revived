// Delivery run HUD (Phase 3). Driven by beamjoy/delivery.lua (BJDeliveryHud, pushed on its slow
// tick while a job runs) : cargo, destination, distance left, time against the target, the drop-off
// hold state, the convoy's grace clock, Unstuck (vehicle jobs) and Abandon. Shared styles (.bj-dlv) live in the job board's template.
angular.module("beamjoy").component("bjDeliveryHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/deliveryHud/app.html",
    controller: function ($rootScope, $scope, $interval, $filter, beamjoyStore, beamjoyDelivery) {
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
        // FOCUS : the Focus control during a delivery job (beamjoy/mainNav.lua) gives this HUD the
        // pad and shows its Unstuck / Abandon buttons ; B (or the control again) lets go. Same
        // hidden-until-focused behaviour the race HUD has always had (windows/raceHud), per direct
        // request - these used to sit there permanently.
        this.focused = false;
        this.cursor = 0;
        // Unstuck only exists for vehicle jobs, so Abandon's index moves
        this.buttons = () => (this.data.unstuck ? ["unstuck", "abandon"] : ["abandon"]);
        this.indexOf = (id) => this.buttons().indexOf(id);

        // Abandon is destructive and A is easy to fumble, so it's a hold rather than a press -
        // mirroring the race HUD's own Retire button exactly (which replaced a confirm dialog for
        // the same reason: a modal the pad can't drive is worse than no modal).
        const ABANDON_HOLD_MS = 5000;
        this.abandonProgress = 0;
        let holdStart = null;
        let holdTick = null;
        const cancelAbandon = () => {
            $interval.cancel(holdTick);
            holdTick = null;
            holdStart = null;
            this.abandonProgress = 0;
        };
        this.startAbandon = () => {
            if (holdStart !== null) return;
            holdStart = Date.now();
            holdTick = $interval(() => {
                this.abandonProgress = Math.min(1, (Date.now() - holdStart) / ABANDON_HOLD_MS);
                if (this.abandonProgress >= 1) {
                    cancelAbandon();
                    beamjoyStore.send("BJDeliveryAbandon");
                }
            }, 50);
        };
        this.stopAbandon = () => cancelAbandon();
        this.abandonFill = () => ({ width: `${Math.round(this.abandonProgress * 100)}%` });

        $rootScope.$on("BJDeliveryHudFocus", (_, data) => {
            $rootScope.$applyAsync(() => {
                this.focused = !!(data && data.active);
                this.cursor = 0;
                cancelAbandon();
                beamjoyDelivery.setNavOwner("deliveryHud", this.focused);
            });
        });
        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            // letting go of A ends an Abandon hold, whatever else is going on
            if (name === "ok" && Number(value) <= 0.5 && holdStart !== null) {
                $scope.$applyAsync(() => cancelAbandon());
                return;
            }
            if (!this.focused || !rising || beamjoyDelivery.otherNavOwner("deliveryHud")) return;
            $scope.$applyAsync(() => {
                const n = this.buttons().length;
                if (name === "focus_l" || name === "focus_u") {
                    cancelAbandon();
                    this.cursor = Math.max(0, this.cursor - 1);
                } else if (name === "focus_r" || name === "focus_d") {
                    cancelAbandon();
                    this.cursor = Math.min(n - 1, this.cursor + 1);
                } else if (name === "ok") {
                    if (this.buttons()[this.cursor] === "abandon") this.startAbandon();
                    else this.unstuck();
                } else if (name === "back") beamjoyStore.send("BJDeliveryHudRelease");
            });
        });
        $scope.$on("$destroy", () => {
            offNav();
            cancelAbandon();
            beamjoyDelivery.setNavOwner("deliveryHud", false);
        });
    },
});
