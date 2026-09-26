// Main window > Activities > Jobs (Phase 3). The whole delivery side of the main window, which used
// to be two standalone windows :
//   * your convoy's lobby while you're in one (was windows/deliveryLobby) : same layout as the
//     race lobby. Ready, Start now (leader), Invite a player (a player picker), Leave.
//   * every depot on the map (was windows/deliveryJobs) : nearest first, distance, open jobs,
//     what it sends, convoys forming there. Filter, set GPS, join a convoy.
// The leaderboards moved to the full window's Leaderboards tab. Data from beamjoy/delivery.lua :
// BJDeliveryLobby (pushed on its slow tick) and BJDeliveryJobs (pushed every second while this
// section is shown : BJDeliveryJobsOpenWindow on mount, BJDeliveryJobsClose on unmount). Pad : the
// main window's own navigation ; A lands on Ready, X invites, Y starts now (leader).
angular.module("beamjoy").component("bjMainJobs", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/activities/jobs/app.html",
    controller: function ($rootScope, $scope, $element, $filter, $interval, beamjoyStore, beamjoyDelivery) {
        const translate = $filter("translate");
        this.fmt = beamjoyDelivery;
        const offs = [];
        const on = (event, fn) => offs.push($rootScope.$on(event, fn));

        // CONVOY LOBBY ------------------------------------------------------------------------
        this.l = null;
        this.slots = [];
        on("BJDeliveryLobby", (_, data) => {
            data = data || {};
            if (!data.open) {
                this.l = null;
                this.slots = [];
                return;
            }
            this.l = data;
            // built once per push (a fresh array per digest never settles)
            const members = data.members || [];
            const slots = members.map((m, i) => ({ key: `m${i}`, num: i + 1, member: m }));
            for (let i = members.length; i < (data.max || 0); i++) slots.push({ key: `o${i}`, num: i + 1, open: true });
            this.slots = slots;
        });
        this.me = () => ((this.l && this.l.members) || []).find((m) => m.you) || {};
        this.headerLine = () =>
            translate(this.l.isLeader ? "beamjoy.delivery.lobby.yours" : "beamjoy.delivery.lobby.theirs")
                .replace("{1}", ((this.l.members || []).find((m) => m.leader) || {}).name || "?")
                .replace("{2}", translate(`beamjoy.delivery.kindLong.${this.l.kind}`).toLowerCase());
        this.subLine = () =>
            translate("beamjoy.delivery.lobby.route")
                .replace("{1}", beamjoyDelivery.formatDistance(this.l.meters))
                .replace("{2}", beamjoyDelivery.formatTime(this.l.targetSec));
        this.hint = () => {
            if (!this.l.atDepot) return translate("beamjoy.delivery.lobby.away").replace("{1}", this.l.depotName);
            return translate(`beamjoy.delivery.lobby.hint.${this.l.kind}`);
        };
        this.memberDetail = (m) => {
            if (this.l.kind === "vehicles" && this.l.vehicle) return this.l.vehicle.label;
            return "";
        };
        this.inviteeStatus = (p) => {
            if (p.invited) return translate("beamjoy.delivery.lobby.inviteSent");
            if (p.busy) return translate("beamjoy.delivery.lobby.busy");
            return translate("beamjoy.delivery.lobby.free");
        };
        this.canInvite = (p) => p && !p.busy && !p.invited;
        this.toggleReady = () => beamjoyStore.send("BJDeliveryLobbyReady", [!this.me().ready]);
        this.startNow = () => {
            if (this.l && this.l.isLeader) beamjoyStore.send("BJDeliveryLobbyStartNow");
        };
        this.leave = () => beamjoyStore.send("BJDeliveryLobbyLeave");
        this.setInviting = (open) => beamjoyStore.send("BJDeliveryLobbyInviting", [open]);
        this.invite = (p) => {
            if (this.canInvite(p)) beamjoyStore.send("BJDeliveryLobbyInvite", [p.playerID]);
        };

        // DEPOTS ------------------------------------------------------------------------------
        this.FILTERS = ["all", "packages", "vehicles"];
        this.filter = "all";
        this.data = { depots: [], loading: true };
        this.rows = [];
        this.selected = 0;
        // built once per push (a fresh array per digest never settles) ; the selected depot stays
        // selected across the once-a-second refresh
        const rebuild = () => {
            const previous = this.rows[this.selected];
            this.rows = (this.data.depots || []).filter(
                (d) =>
                    this.filter === "all" ||
                    (this.filter === "packages" && d.sendsPackages) ||
                    (this.filter === "vehicles" && d.sendsVehicles)
            );
            const kept = previous ? this.rows.findIndex((r) => r.id === previous.id) : -1;
            this.selected = kept >= 0 ? kept : Math.min(this.selected, Math.max(0, this.rows.length - 1));
        };
        this.current = () => this.rows[this.selected];
        // a click selects, a click on the selected row sets GPS (the pad : its cursor selects the
        // row it lands on, so A sets GPS)
        this.rowClick = (index) => {
            if (index === this.selected) this.gps(this.rows[index]);
            else this.selected = index;
        };
        const offPad = (e) => {
            const row = e.target && e.target.getAttribute && e.target.getAttribute("data-row");
            if (row === null || row === undefined) return;
            $scope.$applyAsync(() => (this.selected = Number(row)));
        };
        $element[0].addEventListener("bjrpadfocus", offPad);
        this.countLine = () =>
            translate(this.rows.length === 1 ? "beamjoy.delivery.jobs.countOne" : "beamjoy.delivery.jobs.count")
                .replace("{1}", this.rows.length);
        this.cycleFilter = () => this.setFilter(this.FILTERS[(this.FILTERS.indexOf(this.filter) + 1) % this.FILTERS.length]);
        on("BJDeliveryJobs", (_, data) => {
            data = data || {};
            if (!data.open) return;
            this.data = data;
            rebuild();
        });
        this.setFilter = (f) => {
            this.filter = f;
            rebuild();
        };
        this.modes = (d) =>
            [d.sendsPackages && translate("beamjoy.delivery.kind.packages"),
                d.sendsVehicles && translate("beamjoy.delivery.kind.vehicles")]
                .filter(Boolean)
                .join(translate("beamjoy.delivery.jobs.and"));
        this.jobCount = (d) => {
            if (d.packages == null) return "";
            if (this.filter === "packages") return d.packages;
            if (this.filter === "vehicles") return d.vehicles;
            return d.packages + d.vehicles;
        };
        this.openConvoy = (d) => (d && (d.convoys || []).find((c) => c.count < c.max)) || null;
        this.convoyLabel = (d) => {
            const c = (d.convoys || [])[0];
            if (!c) return translate("beamjoy.delivery.jobs.noConvoy");
            let label = translate("beamjoy.delivery.convoy.ofLeader").replace("{1}", c.leaderName);
            label += `, ${c.count}/${c.max}`;
            if (d.convoys.length > 1) {
                label += " " + translate("beamjoy.delivery.jobs.moreConvoys").replace("{1}", d.convoys.length - 1);
            }
            return label;
        };
        this.joinLabel = (d) => {
            const c = this.openConvoy(d);
            return c ? translate("beamjoy.delivery.convoy.joinNamed").replace("{1}", c.leaderName) : "";
        };
        this.gps = (d) => {
            if (d) beamjoyStore.send("BJDeliveryJobsGps", [d.id]);
        };
        this.join = (d) => {
            const c = this.openConvoy(d);
            if (c && !this.data.busy) beamjoyStore.send("BJDeliveryJobsJoin", [c.id]);
        };

        this.$onInit = () => {
            beamjoyStore.send("BJDeliveryLobbyRequest");
            beamjoyStore.send("BJDeliveryJobsOpenWindow");
        };
        // the convoy's invite picker : an unanswered invite lapses after 15 s, keep it fresh
        const inviteRefresh = $interval(() => {
            if (this.l && this.l.inviting) beamjoyStore.send("BJDeliveryLobbyInviteRefresh");
        }, 3000);
        $scope.$on("$destroy", () => $interval.cancel(inviteRefresh));
        $scope.$on("$destroy", () => {
            offs.forEach((off) => off());
            $element[0].removeEventListener("bjrpadfocus", offPad);
            beamjoyStore.send("BJDeliveryJobsClose");
        });
    },
});
