// Notification stack, beside the main window's rail (or its open panel ; never on top of the panel
// you're using). Holds the convoy invite (bj-delivery-invite, beamjoy/delivery.lua) and the lobby
// notices from beamjoy/notices.lua : invites into a race, hunter or infected lobby, and new lobbies
// opening (what used to be the centre-screen "X started a race" text). Each has Join and Dismiss.
// The pad answers only once the Focus notification control focuses the stack (A joins the top
// one, B dismisses it) ; its hint shows the player's own binding (BJFocusBinding, from
// beamjoy/mainNav.lua), kept on $rootScope.bjFocusLabel for every hint in the UI.
angular.module("beamjoy").component("bjNotices", {
    templateUrl: "/ui/modModules/beamjoy/windows/notices/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyDelivery) {
        const translate = $filter("translate");
        this.items = [];
        this.padActive = false;

        $rootScope.$on("BJNotices", (_, data) => {
            data = data || {};
            this.items = Array.isArray(data.items) ? data.items : [];
            this.padActive = !!data.padActive && this.items.length > 0;
            beamjoyDelivery.setNavOwner("notices", this.padActive);
        });
        $rootScope.$on("BJFocusBinding", (_, data) => {
            data = data || {};
            $rootScope.bjFocusLabel = data.pad || data.key || null;
        });
        this.$onInit = () => {
            beamjoyStore.send("BJNoticesRequest");
            beamjoyStore.send("BJFocusBindingRequest");
        };

        const KIND = {
            race: "beamjoy.notices.kind.race",
            hunter: "beamjoy.notices.kind.hunter",
            infected: "beamjoy.notices.kind.infected",
        };
        this.heading = (n) =>
            translate(`beamjoy.notices.${n.type}.title`)
                .replace("{name}", n.fromName || "?")
                .replace("{kind}", translate(KIND[n.kind] || KIND.race));
        this.body = (n) => {
            const parts = [];
            if (n.title) parts.push(n.title);
            if (n.max) parts.push(translate("beamjoy.notices.slots").replace("{count}", n.count || 0).replace("{max}", n.max));
            return parts.join(", ");
        };
        this.progress = (n) => `${Math.max(0, Math.min(100, ((n.expiresIn || 0) / (n.total || 1)) * 100))}%`;
        this.reply = (n, accept) => beamjoyStore.send("BJNoticeReply", [n.id, accept]);
        // the main window has the pad : the stack steps back until it's focused again
        this.dimmed = () => !this.padActive && $rootScope.bjMainPadActive === true;

        // where the stack sits : beside the rail, on the side away from the screen edge, past an
        // open panel ; over the full window's top corner ; top right when the rail is hidden
        this.position = () => {
            const l = $rootScope.bjMainLayout;
            if (!l || !l.rail || !l.railRect) return { right: "1vw", top: "2vh" };
            const r = l.railRect;
            const gap = 12;
            const panel = l.panelEm ? ` + ${l.panelEm}em + ${gap}px` : "";
            const top = l.full ? "8vh" : `${r.top}px`;
            if (l.side === "left") {
                return { left: l.full ? `calc(${r.right + gap}px + 1.5em)` : `calc(${r.right + gap}px${panel})`, top };
            }
            const fromRight = window.innerWidth - r.left + gap;
            return { right: l.full ? `calc(${fromRight}px + 1.5em)` : `calc(${fromRight}px${panel})`, top };
        };

        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.padActive || !rising || this.items.length === 0) return;
            $scope.$applyAsync(() => {
                if (name === "ok") this.reply(this.items[0], true);
                else if (name === "back") this.reply(this.items[0], false);
            });
        });
        $scope.$on("$destroy", offNav);
    },
});
