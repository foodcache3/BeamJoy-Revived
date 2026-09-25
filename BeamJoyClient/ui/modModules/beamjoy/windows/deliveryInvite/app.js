// Convoy invite (Phase 3). Shown when another player invites you into their convoy lobby ; state
// from beamjoy/delivery.lua (BJDeliveryInvite, pushed on its slow tick for the expiry bar). It
// takes no pad buttons until BJS's "Focus notification" control (Controls > BeamJoy ; RB + X, Shift + J) focuses it, so
// driving past with an invite up changes nothing ; focused, A joins and B declines. Mouse and
// keyboard always work.
angular.module("beamjoy").component("bjDeliveryInvite", {
    templateUrl: "/ui/modModules/beamjoy/windows/deliveryInvite/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyDelivery) {
        const translate = $filter("translate");
        this.open = false;
        this.i = {};
        this.total = 20;

        $rootScope.$on("BJDeliveryInvite", (_, data) => {
            data = data || {};
            const wasOpen = this.open;
            this.open = !!data.open;
            beamjoyDelivery.setNavOwner("invite", this.open && !!data.padActive);
            if (!this.open) return;
            if (!wasOpen || data.convoyId !== this.i.convoyId) this.total = Math.max(1, data.expiresIn || 20);
            this.i = data;
        });

        this.$onInit = () => beamjoyStore.send("BJDeliveryInviteRequest");

        this.heading = () => translate("beamjoy.delivery.invite.title").replace("{1}", this.i.fromName || "?");
        this.body = () =>
            translate(`beamjoy.delivery.invite.body.${this.i.kind}`)
                .replace("{1}", this.i.title || "")
                .replace("{2}", this.i.destName || "")
                .replace("{3}", beamjoyDelivery.formatDistance(this.i.meters))
                .replace("{4}", this.i.depotName || "")
                .replace("{5}", this.i.slotsLeft || 0);
        this.progress = () => `${Math.max(0, Math.min(100, ((this.i.expiresIn || 0) / this.total) * 100))}%`;
        // beside the main window's rail, left of its open panel (never on top of it, so the panel
        // you're clicking in doesn't get covered) ; top right of the screen when the rail is hidden
        this.position = () => {
            const l = $rootScope.bjMainLayout;
            if (!l || !l.rail) return null;
            const beside = "calc(1vw + 4.75em" + (l.panelEm ? ` + ${l.panelEm + 0.75}em` : "") + ")";
            return { right: beside, top: l.full ? "8vh" : "15vh" };
        };
        // the main window has the pad : this steps back until it's focused again
        this.dimmed = () => !this.i.padActive && $rootScope.bjMainPadActive === true;
        this.accept = () => beamjoyStore.send("BJDeliveryInviteReply", [true]);
        this.decline = () => beamjoyStore.send("BJDeliveryInviteReply", [false]);

        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.open || !this.i.padActive || !rising) return;
            $scope.$applyAsync(() => {
                if (name === "ok") this.accept();
                else if (name === "back") this.decline();
            });
        });
        $scope.$on("$destroy", offNav);
    },
});
