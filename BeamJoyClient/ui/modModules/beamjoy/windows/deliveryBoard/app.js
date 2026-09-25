// Delivery job board (Phase 3). Opened from a depot's drive-up prompt ("View jobs") ; all state
// comes from beamjoy/delivery.lua (BJDeliveryBoard). Controller-driven, the first BJS window that
// is : while it's open, delivery.lua lends it the pad's menu buttons (beamjoy/uiNav.lua) and they
// arrive here as the game's own `UINavigation` event. D-pad browses jobs then the convoys forming
// here, A starts a convoy (or joins the selected one), X starts solo, B closes.
// Mouse and keyboard work too. Styled after the vanilla windows (translucent near-black surface,
// cool-grey text, #f60 selection, #c24b00 primary, Overpass titles).
angular.module("beamjoy").service("beamjoyDelivery", function () {
    // While a delivery window is open, the pad buttons it uses must not ALSO trigger the game's
    // own global UI-nav defaults : the Vue side turns every UINavigation into a DOM "ui_nav" event
    // whose body-level handler toggles the pause menu on B ("back"), the Big Map on Y ("context")
    // and lets Crossfire move focus / click on the d-pad and A (ui-vue bridge/libs/UINavEvents.js
    // handleGlobalUINavEvent). A window-level capture listener stops those events before they get
    // there ; the Angular-side UINavigation broadcast our windows listen to is separate and still
    // arrives. Start ("menu") is left alone so the pause menu still opens.
    const CONSUMED = ["ok", "back", "focus_u", "focus_d", "focus_l", "focus_r", "action_2", "context"];
    const navOwners = new Set();
    this.setNavOwner = (owner, active) => {
        if (active) navOwners.add(owner);
        else navOwners.delete(owner);
    };
    window.addEventListener(
        "ui_nav",
        (e) => {
            if (navOwners.size > 0 && e.detail && CONSUMED.includes(e.detail.name)) {
                e.stopImmediatePropagation();
                e.preventDefault();
            }
        },
        true
    );

    // shared by the board, HUD and results
    this.formatTime = (sec) => {
        sec = Math.max(0, Math.round(Number(sec) || 0));
        const m = Math.floor(sec / 60);
        const s = sec % 60;
        return `${m}:${s < 10 ? "0" : ""}${s}`;
    };
    this.formatDistance = (meters) => {
        meters = Number(meters) || 0;
        return meters < 1000 ? `${Math.round(meters)} m` : `${(meters / 1000).toFixed(1)} km`;
    };
    // UINavigation fires on press (value 1) and release (0), and the left stick fires analog
    // values : act once per press, on the rising edge. Feed it EVERY event, even while the window
    // is closed : real, confirmed bug (a button needed pressing twice) - the release of the press
    // that closed a window (X starting a job, A on the results) arrived after it closed, was
    // skipped, and left that button "held", so the next first press looked like part of it.
    this.pressTracker = () => {
        const down = {};
        return (name, value) => {
            const pressed = Number(value) > 0.5;
            const rising = pressed && !down[name];
            down[name] = pressed;
            return rising;
        };
    };
});

angular.module("beamjoy").component("bjDeliveryBoard", {
    templateUrl: "/ui/modModules/beamjoy/windows/deliveryBoard/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyDelivery) {
        const translate = $filter("translate");
        this.fmt = beamjoyDelivery;
        this.open = false;
        this.loading = false;
        this.depotName = "";
        this.offers = [];
        this.convoys = [];
        this.selected = 0;

        $rootScope.$on("BJDeliveryBoard", (_, data) => {
            data = data || {};
            const wasOpen = this.open;
            this.open = !!data.open;
            beamjoyDelivery.setNavOwner("board", this.open);
            if (!this.open) return;
            this.depotName = data.depotName || "";
            this.loading = !!data.loading;
            const previous = this.current();
            const previousKey = previous && `${previous.isConvoy ? "c" : "o"}${previous.id}`;
            this.offers = Array.isArray(data.offers) ? data.offers : [];
            this.convoys = (Array.isArray(data.convoys) ? data.convoys : []).map((c) =>
                Object.assign({}, c, { isConvoy: true })
            );
            // built once here, not in the template : an ng-repeat over an array made fresh on
            // every digest never settles (infinite digest), which froze the details panel while
            // the list highlight kept moving
            this.offers.concat(this.convoys).forEach((o) => {
                o.dropStops = this.isMulti(o) ? o.stops : [{ name: o.destName }];
            });
            // keep the same entry selected across a board refresh when it's still there
            const kept = this.items().findIndex((i) => `${i.isConvoy ? "c" : "o"}${i.id}` === previousKey);
            this.selected = wasOpen && kept >= 0 ? kept : 0;
        });

        this.$onInit = () => beamjoyStore.send("BJDeliveryBoardRequest");

        // jobs first, then the convoys forming here : one list for the d-pad
        this.items = () => this.offers.concat(this.convoys);
        this.current = () => this.items()[this.selected];
        this.convoyIndex = (i) => this.offers.length + i;
        this.convoyFull = (c) => c.count >= c.max;
        this.isMulti = (o) => Array.isArray(o.stops) && o.stops.length > 1;
        this.stopsLabel = (o) => translate("beamjoy.delivery.stops").replace("{1}", o.stops.length);

        this.convoyTitle = (c) => translate("beamjoy.delivery.convoy.ofLeader").replace("{1}", c.leaderName);
        this.playersLine = (o) =>
            translate("beamjoy.delivery.board.upTo").replace("{1}", o.maxPlayers || o.max || 1);
        this.cargoLabel = (offer) =>
            offer.kind === "vehicles" && offer.vehicle
                ? offer.vehicle.label
                : translate(`beamjoy.delivery.cargo.${offer.cargo}`);
        this.kindLabel = (offer) => translate(`beamjoy.delivery.kind.${offer.kind}`);

        this.select = (index) => {
            if (index >= 0 && index < this.items().length) this.selected = index;
        };
        this.startSolo = () => {
            const offer = this.current();
            if (offer && !offer.isConvoy) beamjoyStore.send("BJDeliveryStartSolo", [offer.id]);
        };
        // A : start a convoy on the selected job, or join the selected convoy
        this.primary = () => {
            const item = this.current();
            if (!item) return;
            if (item.isConvoy) {
                if (!this.convoyFull(item)) beamjoyStore.send("BJDeliveryJoinConvoy", [item.id]);
            } else {
                beamjoyStore.send("BJDeliveryStartConvoy", [item.id]);
            }
        };
        this.close = () => beamjoyStore.send("BJDeliveryBoardClose");

        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.open || !rising) return;
            $scope.$applyAsync(() => {
                if (name === "focus_u") this.select(this.selected - 1);
                else if (name === "focus_d") this.select(this.selected + 1);
                else if (name === "ok") this.primary();
                else if (name === "action_2") this.startSolo();
                else if (name === "back") this.close();
            });
        });
        $scope.$on("$destroy", offNav);
    },
});
