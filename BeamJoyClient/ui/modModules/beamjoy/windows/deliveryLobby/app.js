// Convoy lobby (Phase 3). A HUD panel shown while you're in a convoy that hasn't left yet ; all
// state comes from beamjoy/delivery.lua (BJDeliveryLobby, pushed on its slow tick for the
// countdown). Controller-driven while you're at the depot, or away from it once the game's
// "interact" chord (RB + Y, Shift + E) focuses it (delivery.lua lends it the pad's buttons then) :
// A ready / not ready, Y start now (leader), X invite a player, B leave.
// Inviting swaps the member list for a player picker : d-pad to pick, A invites, B goes back.
// Mouse and keyboard always work. Shared styles (.bj-dlv) live in the job board's template.
angular.module("beamjoy").component("bjDeliveryLobby", {
    templateUrl: "/ui/modModules/beamjoy/windows/deliveryLobby/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyDelivery) {
        const translate = $filter("translate");
        this.fmt = beamjoyDelivery;
        this.open = false;
        this.l = {};
        this.picked = 0;

        $rootScope.$on("BJDeliveryLobby", (_, data) => {
            data = data || {};
            this.open = !!data.open;
            beamjoyDelivery.setNavOwner("lobby", this.open && !!data.padActive);
            if (!this.open) return;
            const wasInviting = this.l.inviting;
            this.l = data;
            // built once per push (a fresh array per digest never settles, see the job board)
            const members = data.members || [];
            this.slotList = members.map((m, i) => Object.assign({ num: i + 1 }, m));
            for (let i = members.length; i < (data.max || 0); i++) this.slotList.push({ num: i + 1, open: true });
            if (!data.inviting || !wasInviting) this.picked = 0;
            const count = (data.invitees || []).length;
            if (this.picked >= count) this.picked = Math.max(0, count - 1);
        });

        this.$onInit = () => beamjoyStore.send("BJDeliveryLobbyRequest");

        this.me = () => (this.l.members || []).find((m) => m.you) || {};
        this.slotList = [];
        this.memberDetail = (m) => {
            const parts = [];
            if (m.leader) parts.push(translate("beamjoy.delivery.lobby.leader"));
            if (this.l.kind === "vehicles" && this.l.vehicle) parts.push(this.l.vehicle.label);
            return parts.join(". ");
        };
        this.headerLine = () =>
            translate(this.l.isLeader ? "beamjoy.delivery.lobby.yours" : "beamjoy.delivery.lobby.theirs")
                .replace("{1}", ((this.l.members || []).find((m) => m.leader) || {}).name || "?")
                .replace("{2}", translate(`beamjoy.delivery.kindLong.${this.l.kind}`).toLowerCase());
        this.subLine = () =>
            translate("beamjoy.delivery.lobby.route")
                .replace("{1}", beamjoyDelivery.formatDistance(this.l.meters))
                .replace("{2}", beamjoyDelivery.formatTime(this.l.targetSec));
        this.hint = () => {
            if (this.l.inviting) return translate("beamjoy.delivery.lobby.inviteHint");
            if (!this.l.atDepot) return translate("beamjoy.delivery.lobby.away").replace("{1}", this.l.depotName);
            return translate(`beamjoy.delivery.lobby.hint.${this.l.kind}`);
        };
        this.inviteeStatus = (p) => {
            if (p.invited) return translate("beamjoy.delivery.lobby.inviteSent");
            if (p.busy) return translate("beamjoy.delivery.lobby.busy");
            return translate("beamjoy.delivery.lobby.free");
        };
        this.canInvite = (p) => p && !p.busy && !p.invited;

        this.toggleReady = () => beamjoyStore.send("BJDeliveryLobbyReady", [!this.me().ready]);
        this.startNow = () => {
            if (this.l.isLeader) beamjoyStore.send("BJDeliveryLobbyStartNow");
        };
        this.leave = () => beamjoyStore.send("BJDeliveryLobbyLeave");
        this.setInviting = (open) => beamjoyStore.send("BJDeliveryLobbyInviting", [open]);
        this.invite = (p) => {
            if (this.canInvite(p)) beamjoyStore.send("BJDeliveryLobbyInvite", [p.playerID]);
        };
        this.pick = (index) => {
            const count = (this.l.invitees || []).length;
            if (index >= 0 && index < count) this.picked = index;
        };

        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.open || !this.l.padActive || !rising) return;
            $scope.$applyAsync(() => {
                if (this.l.inviting) {
                    if (name === "focus_u") this.pick(this.picked - 1);
                    else if (name === "focus_d") this.pick(this.picked + 1);
                    else if (name === "ok") this.invite((this.l.invitees || [])[this.picked]);
                    else if (name === "back") this.setInviting(false);
                    return;
                }
                if (name === "ok") this.toggleReady();
                else if (name === "context") this.startNow();
                else if (name === "action_2") this.setInviting(true);
                else if (name === "back") this.leave();
            });
        });
        $scope.$on("$destroy", offNav);
    },
});
