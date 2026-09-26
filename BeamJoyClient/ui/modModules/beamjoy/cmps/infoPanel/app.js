// Generic reusable "info panel" primitive: a centered modal (title + tabs + close), intended as
// a framework for any future read-only info/results display, not just races (this session's own
// first and only consumer so far). Deliberately just chrome : callers build their own tab content
// as separate components and hand in a `tabs` array shaped exactly like bj-tabs already expects
// ({id, title, template}), the same pattern windows/config/app.js already uses for its own tabs.
// bj-tabs itself does the actual tab-bar/content-switching, this only adds the modal
// backdrop/title/close around it. Same singleton-service-backed-by-one-root-mounted-component
// shape as beamjoyConfirm/bj-confirm, so any component can call `beamjoyInfoPanel.open(...)`
// without needing a reference to this one.
angular.module("beamjoy").service("beamjoyInfoPanel", function () {
    this.state = {
        visible: false,
        title: "",
        tabs: [],
        activeTabIndex: 0,
    };

    // views opened on top of another (a race's leaderboard from its results) : closing goes back
    const stack = [];
    const show = (title, tabs, startTabId) => {
        this.state.visible = true;
        this.state.title = title;
        this.state.tabs = tabs || [];
        const startIndex = startTabId
            ? this.state.tabs.findIndex((t) => t.id === startTabId)
            : -1;
        this.state.activeTabIndex = startIndex > -1 ? startIndex : 0;
    };
    // tabs : [{id, title, template}], same shape bj-tabs itself expects
    this.open = (title, tabs, startTabId) => {
        stack.length = 0;
        show(title, tabs, startTabId);
    };
    // on top of what's showing : closing (B) comes back to it
    this.push = (title, tabs, startTabId) => {
        if (this.state.visible) {
            const cur = this.state.tabs[this.state.activeTabIndex];
            stack.push({ title: this.state.title, tabs: this.state.tabs, startTabId: cur && cur.id });
        }
        show(title, tabs, startTabId);
    };

    // back to the view underneath, or closed
    this.close = () => {
        const prev = stack.pop();
        if (prev) return show(prev.title, prev.tabs, prev.startTabId);
        this.state.visible = false;
    };
    this.closeAll = () => {
        stack.length = 0;
        this.state.visible = false;
    };
});

// Controller : while open the overlay has the pad (Lua : mainNav.lua's BJInfoPanelPad borrows the
// menu buttons and LB / RB) and the main window steps aside (beamjoyDelivery's nav owners). The
// d-pad moves a cursor between the overlay's buttons, and scrolls the list it's in when there's
// nothing further that way ; A presses, LB / RB switch tabs, B closes.
angular.module("beamjoy").component("bjInfoPanel", {
    templateUrl: "/ui/modModules/beamjoy/cmps/infoPanel/app.html",
    controller: function ($rootScope, $scope, $element, $timeout, beamjoyInfoPanel, beamjoyStore, beamjoyDelivery) {
        this.state = beamjoyInfoPanel.state;
        // a pad was used here : show the button hints
        this.padUsed = false;

        this.selectTab = (tabId) => {
            const index = this.state.tabs.findIndex((t) => t.id === tabId);
            if (index > -1) this.state.activeTabIndex = index;
            // the new tab's content replaces the old : start again from its first control
            $timeout(() => enter(), 60);
        };

        this.close = () => beamjoyInfoPanel.close();
        this.closeAll = () => beamjoyInfoPanel.closeAll();

        // PAD --------------------------------------------------------------------------------
        const PAD_CLASS = "ip-pad-focus";
        let padEl = null;
        const box = () => $element[0].querySelector(".info-panel-box");
        const setPadEl = (el) => {
            if (padEl) padEl.classList.remove(PAD_CLASS);
            padEl = el || null;
            if (padEl && this.padUsed) {
                padEl.classList.add(PAD_CLASS);
                if (padEl.scrollIntoView) padEl.scrollIntoView({ block: "nearest" });
            }
        };
        // the tab content's controls, then the header's close button last
        const focusables = () => {
            const b = box();
            if (!b) return [];
            const content = [...b.querySelectorAll(".tab-content button, .tab-content [ng-click]")];
            return content
                .concat([...b.querySelectorAll(".info-panel-header button")])
                .filter((el) => el.offsetParent !== null && !el.disabled && !content.some((o) => o !== el && el.contains(o)));
        };
        const enter = () => setPadEl(focusables()[0]);
        const DIRS = { up: [0, -1], down: [0, 1], left: [-1, 0], right: [1, 0] };
        // same rule as the main window : past the current element's edge, sideways drift costs more
        const findDir = (from, dir) => {
            const [dx, dy] = DIRS[dir];
            const a = from.getBoundingClientRect();
            const ax = a.left + a.width / 2;
            const ay = a.top + a.height / 2;
            let best = null;
            let bestScore = Infinity;
            focusables().forEach((el) => {
                if (el === from) return;
                const r = el.getBoundingClientRect();
                const bx = r.left + r.width / 2;
                const by = r.top + r.height / 2;
                if (dx > 0 && r.left < a.right - 2) return;
                if (dx < 0 && r.right > a.left + 2) return;
                if (dy > 0 && r.top < a.bottom - 2) return;
                if (dy < 0 && r.bottom > a.top + 2) return;
                const ahead = dx !== 0 ? Math.abs(bx - ax) : Math.abs(by - ay);
                const side = dx !== 0
                    ? Math.max(0, r.top - a.bottom, a.top - r.bottom)
                    : Math.max(0, r.left - a.right, a.left - r.right);
                const score = ahead + side * 4 + (dx !== 0 ? Math.abs(by - ay) : Math.abs(bx - ax)) * 0.1;
                if (score < bestScore) {
                    bestScore = score;
                    best = el;
                }
            });
            return best;
        };
        // nothing further that way : scroll the list the cursor is in (or the content's first list)
        const scrollBy = (dy) => {
            const b = box();
            if (!b) return;
            let el = padEl && padEl.parentElement;
            while (el && el !== b) {
                const st = getComputedStyle(el);
                if ((st.overflowY === "auto" || st.overflowY === "scroll") && el.scrollHeight > el.clientHeight) break;
                el = el.parentElement;
            }
            if (!el || el === b) {
                el = [...b.querySelectorAll(".tab-content *")].find((c) => {
                    const st = getComputedStyle(c);
                    return (st.overflowY === "auto" || st.overflowY === "scroll") && c.scrollHeight > c.clientHeight;
                });
            }
            if (el) el.scrollTop += dy;
        };
        const move = (dir) => {
            if (!padEl || !document.contains(padEl)) return enter();
            const next = findDir(padEl, dir);
            if (next) setPadEl(next);
            else if (dir === "up" || dir === "down") scrollBy(dir === "up" ? -80 : 80);
        };
        const switchTab = (step) => {
            const tabs = this.state.tabs;
            if (tabs.length < 2) return;
            const i = (this.state.activeTabIndex + step + tabs.length) % tabs.length;
            this.selectTab(tabs[i].id);
        };

        // open / close : take the pad from the main window, give it back
        $scope.$watch(
            () => this.state.visible,
            (visible, was) => {
                if (visible === was && !visible) return;
                beamjoyDelivery.setNavOwner("infoPanel", !!visible);
                beamjoyStore.send("BJInfoPanelPad", [!!visible]);
                if (visible) $timeout(() => enter(), 120);
                else setPadEl(null);
            }
        );

        // another view in the same window (the leaderboard, back to the results) : start again
        $scope.$watch(
            () => this.state.tabs,
            (tabs, was) => {
                if (tabs !== was && this.state.visible) $timeout(() => enter(), 120);
            }
        );

        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.state.visible || !rising) return;
            $scope.$applyAsync(() => {
                if (!this.padUsed) {
                    // first press : show the cursor where it already is
                    this.padUsed = true;
                    if (padEl && document.contains(padEl)) {
                        setPadEl(padEl);
                        return;
                    }
                }
                if (name === "focus_u") move("up");
                else if (name === "focus_d") move("down");
                else if (name === "focus_l") move("left");
                else if (name === "focus_r") move("right");
                else if (name === "tab_l") switchTab(-1);
                else if (name === "tab_r") switchTab(1);
                else if (name === "back") this.close();
                else if (name === "ok" && padEl && document.contains(padEl)) {
                    const el = padEl;
                    setTimeout(() => {
                        el.click();
                        // the pressed control may be re-rendered : keep a cursor
                        $timeout(() => {
                            if (!document.contains(padEl)) enter();
                        }, 80);
                    });
                }
            });
        });
        $scope.$on("$destroy", () => {
            offNav();
            beamjoyDelivery.setNavOwner("infoPanel", false);
            beamjoyStore.send("BJInfoPanelPad", [false]);
        });
    },
});
