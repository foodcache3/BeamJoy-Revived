await import(`/ui/modModules/beamjoy/windows/main/main/players-list/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/settings/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/races/app.js`);
// hunter/app.js and infected/app.js are imported by activities/app.js (both gamemodes live
// under the Activities section bar)
await import(`/ui/modModules/beamjoy/windows/main/activities/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/now/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/vote/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/you/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/leaderboards/app.js`);

// Main window, redesigned (edge rail). A slim rail sits on the right edge of the screen ; each of
// its buttons opens a small panel beside it (Happening now, Activities, Players, Vote, Settings),
// and "Full" opens the big window with the same content in tabs. Mockups (revision 3 page):
// https://claude.ai/artifact/CGvMdFLWjZdj1J2nTNe18C. Visibility still comes from
// communications/ui.lua (BJUpdateWindowSettings "beamjoy-main") : when it's forced open (staff,
// or the host's ForceHud) the rail can't be hidden, otherwise the F4 menu toggles it and the
// rail's own Hide button closes it.
angular.module("beamjoy").component("bjMain", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/app.html",
    controller: function ($rootScope, $scope, $element, $timeout, beamjoyStore, beamjoyNow, beamjoyDelivery) {
        this.visible = false;
        this.closable = false;
        // null or one of PANELS : the small panel open beside the rail
        this.panel = null;
        this.full = false;
        this.fullTab = "home";
        this.FULL_TABS = ["home", "activities", "players", "leaderboards", "settings"];

        $rootScope.$on("BJUpdateWindowSettings", (_, data) => {
            const el = data["beamjoy-main"];
            if (el) {
                $rootScope.$applyAsync(() => {
                    this.visible = el.visible;
                    this.closable = el.closable;
                    if (!this.visible) {
                        this.panel = null;
                        this.full = false;
                    }
                });
            }
        });
        this.hide = () => {
            this.panel = null;
            this.full = false;
            this.visible = false;
            if (this.pad) this.releasePad();
            beamjoyStore.send("BJCloseWindow", ["main"]);
        };

        // a second press on the open panel's button closes it
        this.togglePanel = (id) => {
            this.full = false;
            this.panel = this.panel === id ? null : id;
        };
        this.openFull = (tab) => {
            this.fullTab = tab || this.fullFor(this.panel);
            this.panel = null;
            this.full = true;
        };
        // shrinking goes back to the panel matching the tab you were on
        this.shrink = () => {
            const back = { home: "now", activities: "play", players: "players", leaderboards: "now", settings: "settings" };
            this.full = false;
            this.panel = back[this.fullTab] || "now";
        };
        this.fullFor = (panel) =>
            ({ now: "home", play: "activities", players: "players", settings: "settings" })[panel] || "home";
        this.setFullTab = (tab) => (this.fullTab = tab);

        // other components ask for a panel (Happening now's "Start an activity", an activity
        // card's "Open") ; an Activities section can be picked along the way. null closes the
        // panel (the Vote panel, once a vote started)
        $rootScope.$on("BJMainOpenPanel", (_, panel, section) => {
            $rootScope.$applyAsync(() => {
                if (!panel) {
                    this.panel = null;
                } else if (panel === "vote") {
                    // no Vote tab in the full window : back to the side for it
                    this.full = false;
                    this.panel = "vote";
                } else if (this.full) {
                    this.fullTab = this.fullFor(panel);
                } else {
                    this.panel = panel;
                }
                // the Activities component may not be mounted yet : it reads the request on init
                if (section) {
                    $rootScope.bjMainActivitiesSection = section;
                    $rootScope.$broadcast("BJMainActivitiesSection", section);
                }
            });
        });
        // the old window's "open the Settings tab" requests still land somewhere sensible
        $rootScope.$on("BJOpenTab", (_, tabId) => {
            if (tabId === "settings") {
                if (this.full) this.fullTab = "settings";
                else this.panel = "settings";
            }
        });

        this.isStaff = () => beamjoyStore.permissions.isStaff();
        this.canVote = () =>
            beamjoyStore.permissions.hasAllPermissions(undefined, "VoteMap") ||
            beamjoyStore.permissions.hasAllPermissions(undefined, "VoteKick");
        this.playerCount = () => beamjoyStore.players.players.length;
        this.openConfig = () => beamjoyStore.send("BJRequestOpenWindow", ["config"]);

        // Low fuel / emergency refuel (see stations.lua's "LOW FUEL / EMERGENCY REFUEL HUD"
        // section) : amber sets a GPS route to the nearest station while there's some left, red
        // does a free, held emergency refuel once empty
        this.fuelLow = false;
        this.fuelEmpty = false;
        $rootScope.$on("BJFuelStatus", (_, data) => {
            data = data || {};
            this.fuelLow = data.low === true;
            this.fuelEmpty = data.empty === true;
        });
        this.fuelAction = () => {
            beamjoyStore.send(this.fuelEmpty ? "BJFuelEmergencyRefuel" : "BJFuelSetWaypoint");
        };

        // how many lobbies you could join right now, as a badge on the rail's Now button while its
        // panel is closed (opening it is looking at the list)
        this.nowCount = () => beamjoyNow.joinableCount();
        this.$onInit = () => {
            beamjoyNow.refresh();
            beamjoyStore.send("BJMainPadRequest");
        };

        // CONTROLLER -------------------------------------------------------------------------
        // beamjoy/mainNav.lua hands the pad over (BJMainPad) through the Focus notification
        // control (after a convoy invite), a depot prompt's "All depots", or arriving at your
        // convoy's depot. It says which panel to land on (Happening now by default). Levels :
        //   rail  : d-pad up/down picks a button, A opens it, left goes into the open panel,
        //           Y toggles the full window, B lets go of the pad (closing the panel)
        //   panel : the d-pad moves by direction between buttons and fields (a slider takes
        //           left/right), A presses, X / Y press the panel's own X / Y action when it has
        //           one (Start solo, a convoy's Start now), otherwise Y opens the full window.
        //           Right past the last column, or B, goes back to the rail
        //   full  : the same, LB / RB switch tabs, and the rail is out of reach : B goes back to
        //           the side panel
        // Entering a panel starts on its [data-pad-a] element when it has one (I'm ready).
        // The highlighted element carries .bjr-pad-focus. A delivery window that has the pad
        // (job board, results, a focused invite) wins : this steps aside and dims meanwhile.
        this.pad = false;
        this.padLevel = "rail";
        this.railCursor = "now";
        const PAD_CLASS = "bjr-pad-focus";
        const PANEL_IDS = ["now", "play", "players", "vote", "settings"];
        const SELECTOR =
            'button, a[href], input[type="range"], input[type="text"], input[type="number"], [ng-click]';
        let padEl = null;

        const root = () => $element[0];
        const railIds = () =>
            [...root().querySelectorAll(".bjr-rail [data-rail]")].map((el) => el.getAttribute("data-rail"));
        const setPadEl = (el) => {
            if (padEl) padEl.classList.remove(PAD_CLASS);
            padEl = el || null;
            if (padEl) {
                padEl.classList.add(PAD_CLASS);
                if (padEl.scrollIntoView) padEl.scrollIntoView({ block: "nearest" });
            }
        };
        const container = () =>
            root().querySelector(this.padLevel === "full" ? ".bjr-full .full-body" : ".bjr-panel .panel-body");
        // really disabled : the control's own state. A bj-toggle's `disabled` binding attribute
        // sits on its host element whatever its value, so it can't be used as a marker.
        const isDisabled = (el) =>
            el.disabled === true ||
            el.classList.contains("disabled") ||
            (!!el.parentElement && el.parentElement.classList.contains("disabled"));
        // visible, enabled, innermost targets (a wrapper with ng-click around real buttons gives
        // way to the buttons)
        const focusables = () => {
            const c = container();
            if (!c) return [];
            const all = [...c.querySelectorAll(SELECTOR)].filter(
                (el) => el.offsetParent !== null && !isDisabled(el)
            );
            return all.filter((el) => !all.some((other) => other !== el && el.contains(other)));
        };
        // the nearest target in a direction : candidates must lie past the current element's
        // edge, and sideways drift costs more than distance ahead, so down from a race's Start
        // button is the next race's Start button, not the leaderboard button beside it
        const DIRS = { up: [0, -1], down: [0, 1], left: [-1, 0], right: [1, 0] };
        const findDir = (from, dir) => {
            const [dx, dy] = DIRS[dir];
            const a = from.getBoundingClientRect();
            const ax = a.left + a.width / 2;
            const ay = a.top + a.height / 2;
            let best = null;
            let bestScore = Infinity;
            focusables().forEach((el) => {
                if (el === from || from.contains(el) || el.contains(from)) return;
                const b = el.getBoundingClientRect();
                if (dx > 0 && b.left < a.right - 2) return;
                if (dx < 0 && b.right > a.left + 2) return;
                if (dy > 0 && b.top < a.bottom - 2) return;
                if (dy < 0 && b.bottom > a.top + 2) return;
                const bx = b.left + b.width / 2;
                const by = b.top + b.height / 2;
                const ahead = dx !== 0 ? Math.abs(bx - ax) : Math.abs(by - ay);
                // sideways : the gap between the two boxes' spans (0 when they overlap)
                const side =
                    dx !== 0
                        ? Math.max(0, b.top - a.bottom, a.top - b.bottom)
                        : Math.max(0, b.left - a.right, a.left - b.right);
                const score = ahead + side * 4;
                if (score < bestScore) {
                    bestScore = score;
                    best = el;
                }
            });
            return best;
        };
        // true when it moved
        const moveDir = (dir) => {
            if (!padEl || !document.contains(padEl)) {
                setPadEl(focusables()[0]);
                return !!padEl;
            }
            const next = findDir(padEl, dir);
            if (next) setPadEl(next);
            return !!next;
        };
        // after the content (re)renders : the panel's primary action if it has one
        const enterContent = () =>
            $timeout(() => {
                const list = focusables();
                setPadEl(list.find((el) => el.hasAttribute("data-pad-a")) || list[0]);
            }, 60);
        // ng-click runs its own $apply : press outside of Angular's digest
        const press = (el) => {
            if (!el) return;
            setTimeout(() => {
                if (el.tagName === "INPUT" && (el.type === "text" || el.type === "number")) {
                    el.focus();
                    return;
                }
                el.click();
                // the pressed button may be gone (a form opened, a card closed) : keep a cursor
                $timeout(() => {
                    if (!document.contains(padEl)) enterContent();
                }, 80);
            });
        };
        const nudge = (dir) => {
            if (!padEl || padEl.tagName !== "INPUT" || (padEl.type !== "range" && padEl.type !== "number")) {
                return false;
            }
            if (dir > 0) padEl.stepUp();
            else padEl.stepDown();
            padEl.dispatchEvent(new Event("input", { bubbles: true }));
            padEl.dispatchEvent(new Event("change", { bubbles: true }));
            return true;
        };
        const toRail = () => {
            setPadEl(null);
            this.padLevel = "rail";
            if (this.panel) this.railCursor = this.panel;
        };
        const moveRail = (step) => {
            const ids = railIds();
            if (ids.length === 0) return;
            const i = ids.indexOf(this.railCursor);
            this.railCursor = ids[i < 0 ? 0 : Math.max(0, Math.min(ids.length - 1, i + step))];
        };
        const openPanel = (id) => {
            this.full = false;
            this.panel = id;
            this.padLevel = "panel";
            enterContent();
        };
        const toggleFull = () => {
            if (this.full) {
                this.shrink();
                this.padLevel = "panel";
            } else {
                this.openFull();
                this.padLevel = "full";
            }
            enterContent();
        };
        const railPress = (id) => {
            if (PANEL_IDS.includes(id)) openPanel(id);
            else if (id === "full") toggleFull();
            else if (id === "fuel") this.fuelAction();
            else if (id === "hide") this.hide();
        };
        const switchTab = (step) => {
            const i = this.FULL_TABS.indexOf(this.fullTab);
            this.fullTab = this.FULL_TABS[(i + step + this.FULL_TABS.length) % this.FULL_TABS.length];
            enterContent();
        };
        // a panel's own X / Y action (data-pad-x / data-pad-y), if it shows one
        const shortcut = (key) => {
            const c = container();
            const el =
                c && [...c.querySelectorAll(`[data-pad-${key}]`)].find((b) => b.offsetParent !== null && !b.disabled);
            if (el) press(el);
            return !!el;
        };
        this.railPad = (id) => this.pad && this.padLevel === "rail" && this.railCursor === id;
        this.releasePad = () => beamjoyStore.send("BJMainPadRelease");
        // another window has the pad : this one dims until it's done
        this.dimmed = () => beamjoyDelivery.otherNavOwner("main");

        $rootScope.$on("BJMainPad", (_, data) => {
            $rootScope.$applyAsync(() => {
                data = data || {};
                const wasPad = this.pad;
                this.pad = !!data.active;
                $rootScope.bjMainPadActive = this.pad;
                beamjoyDelivery.setNavOwner("main", this.pad);
                if (this.pad) {
                    if (data.section) {
                        $rootScope.bjMainActivitiesSection = data.section;
                        $rootScope.$broadcast("BJMainActivitiesSection", data.section);
                    }
                    if (data.panel) {
                        if (this.full && data.panel !== "vote") {
                            this.fullTab = this.fullFor(data.panel);
                            this.padLevel = "full";
                            enterContent();
                        } else {
                            openPanel(data.panel);
                        }
                    } else if (!wasPad) {
                        // re-sync after a UI reload : keep what's open
                        this.padLevel = this.full ? "full" : this.panel ? "panel" : "rail";
                        if (this.padLevel !== "rail") enterContent();
                    }
                } else {
                    // letting go closes what the pad had open ; the rail itself stays unless
                    // mainNav.lua opened it just for the pad
                    setPadEl(null);
                    this.padLevel = "rail";
                    this.panel = null;
                    this.full = false;
                }
            });
        });

        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            if (!this.pad || !rising || !this.visible || beamjoyDelivery.otherNavOwner("main")) return;
            $rootScope.$applyAsync(() => {
                // the panel or full window went away under the cursor (mouse, a finished action)
                if (this.padLevel === "panel" && !this.panel) toRail();
                if (this.padLevel === "full" && !this.full) {
                    if (this.panel) this.padLevel = "panel";
                    else toRail();
                }

                if (this.padLevel === "rail") {
                    if (name === "focus_u") moveRail(-1);
                    else if (name === "focus_d") moveRail(1);
                    else if (name === "ok") railPress(this.railCursor);
                    else if (name === "focus_l" && this.panel) {
                        this.padLevel = "panel";
                        enterContent();
                    } else if (name === "context") toggleFull();
                    else if (name === "back") this.releasePad();
                    return;
                }
                const full = this.padLevel === "full";
                if (name === "focus_u") moveDir("up");
                else if (name === "focus_d") moveDir("down");
                else if (name === "focus_l") {
                    if (!nudge(-1)) moveDir("left");
                } else if (name === "focus_r") {
                    // the rail sits right of the side panel ; the full window keeps you inside it
                    if (!nudge(1) && !moveDir("right") && !full) toRail();
                } else if (name === "ok") press(padEl);
                else if (name === "action_2") shortcut("x");
                else if (name === "context") {
                    if (!shortcut("y")) toggleFull();
                } else if (name === "back") {
                    if (full) toggleFull();
                    else toRail();
                } else if (full && name === "tab_l") switchTab(-1);
                else if (full && name === "tab_r") switchTab(1);
            });
        });
        $scope.$on("$destroy", offNav);

        // where the rail and its panel are, for notifications that must sit beside them rather
        // than on top (the convoy invite) : an open panel never moves under your cursor
        const PANEL_WIDTH_EM = { play: 28, settings: 28 };
        $scope.$watchGroup([() => this.visible, () => this.panel, () => this.full], () => {
            $rootScope.bjMainLayout = {
                rail: !!this.visible,
                full: !!this.full,
                panelEm: this.visible && this.panel && !this.full ? PANEL_WIDTH_EM[this.panel] || 22 : 0,
            };
        });
    },
});
