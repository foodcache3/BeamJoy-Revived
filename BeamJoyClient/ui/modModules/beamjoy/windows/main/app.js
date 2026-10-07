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
await import(`/ui/modModules/beamjoy/windows/main/lobbyInvite/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/crew/app.js`);

// Main window, redesigned (edge rail). A slim rail (right edge by default, draggable by its logo
// anywhere on screen) ; each of its buttons opens a small panel beside it, on the side away from
// the screen edge (Happening now, Activities, Players, Vote, Settings), and "Full" opens the big
// window with the same content in tabs. Mockups (revision 3 page):
// https://claude.ai/artifact/CGvMdFLWjZdj1J2nTNe18C. Visibility still comes from
// communications/ui.lua (BJUpdateWindowSettings "beamjoy-main") : when it's forced open (staff,
// or the host's ForceHud) the rail can't be hidden, otherwise the F4 menu toggles it and the
// rail's own Hide button closes it.
angular.module("beamjoy").component("bjMain", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/app.html",
    controller: function ($rootScope, $scope, $element, $timeout, beamjoyStore, beamjoyNow, beamjoyDelivery, beamjoyCrew) {
        this.visible = false;
        this.closable = false;
        // null or one of PANELS : the small panel open beside the rail
        this.panel = null;
        this.full = false;
        this.fullTab = "home";
        this.FULL_TABS = ["home", "activities", "crew", "players", "leaderboards", "settings"];

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

        // a second press on the open panel's button closes it. Opening one with the mouse also
        // hands the pad over (from that rail button) until the panel closes again
        this.togglePanel = (id) => {
            this.full = false;
            this.panel = this.panel === id ? null : id;
            if (this.panel && !this.pad) beamjoyStore.send("BJMainPadFocus", [this.panel]);
        };
        this.clickFull = () => {
            if (this.full) return this.shrink();
            this.openFull();
            if (!this.pad) beamjoyStore.send("BJMainPadFocus", ["full"]);
        };
        this.openFull = (tab) => {
            this.fullTab = tab || this.fullFor(this.panel);
            this.panel = null;
            this.full = true;
        };
        // shrinking goes back to the panel matching the tab you were on
        this.shrink = () => {
            const back = { home: "now", activities: "play", crew: "crew", players: "players", leaderboards: "now", settings: "settings" };
            this.full = false;
            this.panel = back[this.fullTab] || "now";
        };
        this.fullFor = (panel) =>
            ({ now: "home", play: "activities", crew: "crew", players: "players", settings: "settings" })[panel] || "home";
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
        // an activity's Leaderboard button : the full window's Leaderboards, on that activity
        // (read on init by the Leaderboards component, which may not be mounted yet)
        $rootScope.$on("BJMainOpenLeaderboards", (_, section) => {
            $rootScope.$applyAsync(() => {
                $rootScope.bjLeaderboardsSection = section || null;
                $rootScope.$broadcast("BJLeaderboardsSection", section);
                this.openFull("leaderboards");
                if (!this.pad) beamjoyStore.send("BJMainPadFocus", ["full"]);
            });
        });
        // something needs the screen (a bus line's vehicle picker) : close the menu, let go of the pad
        $rootScope.$on("BJMainClose", () => {
            $rootScope.$applyAsync(() => {
                this.panel = null;
                this.full = false;
                if (this.pad) this.releasePad();
            });
        });
        // a player row's Moderate button (side panel, Home) : the full Players tab, that player open
        $rootScope.$on("BJMainModerate", (_, playerName) => {
            $rootScope.$applyAsync(() => {
                $rootScope.bjPlayersExpand = playerName;
                this.panel = null;
                this.full = true;
                this.fullTab = "players";
                if (this.pad) {
                    this.padLevel = "full";
                    enterContent();
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
        // players asking to join your crew (you lead it)
        this.crewCount = () => beamjoyCrew.requestCount();
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
        const PANEL_IDS = ["now", "play", "crew", "players", "vote", "settings"];
        const SELECTOR =
            'button, a[href], input[type="range"], input[type="text"], input[type="number"], md-select, [ng-click]';
        let padEl = null;

        const root = () => $element[0];
        const railIds = () =>
            [...root().querySelectorAll(".bjr-rail [data-rail]")].map((el) => el.getAttribute("data-rail"));
        // where the cursor last was : when its element goes away (Start opened a form in its
        // place, a lobby replaced the list) the cursor lands near there, not back at the top
        let padRect = null;
        const setPadEl = (el) => {
            if (padEl) padEl.classList.remove(PAD_CLASS);
            padEl = el || null;
            if (padEl) {
                padRect = padEl.getBoundingClientRect();
                padEl.classList.add(PAD_CLASS);
                if (padEl.scrollIntoView) padEl.scrollIntoView({ block: "nearest" });
                // lets a list follow the cursor (the Jobs depot table selects the focused row)
                padEl.dispatchEvent(new CustomEvent("bjrpadfocus", { bubbles: true }));
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
            // a dropdown counts as one target (never its inner parts)
            const all = [...c.querySelectorAll(SELECTOR)].filter(
                (el) =>
                    el.offsetParent !== null &&
                    !isDisabled(el) &&
                    (el.tagName === "MD-SELECT" || !el.parentElement || !el.parentElement.closest("md-select"))
            );
            return all.filter(
                (el) => el.tagName === "MD-SELECT" || !all.some((other) => other !== el && el.contains(other))
            );
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
            // up / down : the nearest row first, then the closest thing in it. Scoring sideways
            // drift against distance skipped a control sitting at the far end of its row (a
            // toggle right of its label) for a full-width one further down
            if (dy !== 0) {
                const rows = [];
                focusables().forEach((el) => {
                    if (el === from || from.contains(el) || el.contains(from)) return;
                    const b = el.getBoundingClientRect();
                    const gap = dy > 0 ? b.top - a.bottom : a.top - b.bottom;
                    if (gap < -2) return;
                    rows.push({ el, gap, off: Math.abs(b.left + b.width / 2 - ax), b });
                });
                if (rows.length === 0) return null;
                const nearest = Math.min(...rows.map((r) => r.gap));
                rows.filter((r) => r.gap <= nearest + 8).forEach((r) => {
                    // overlapping sideways counts as straight ahead
                    const overlap = r.b.right > a.left && r.b.left < a.right ? 0 : 1;
                    const score = overlap * 10000 + r.off;
                    if (score < bestScore) {
                        bestScore = score;
                        best = r.el;
                    }
                });
                return best;
            }
            focusables().forEach((el) => {
                if (el === from || from.contains(el) || el.contains(from)) return;
                const b = el.getBoundingClientRect();
                const bx = b.left + b.width / 2;
                const by = b.top + b.height / 2;
                // sideways, a slanted neighbour (the Crew tab's skewed seats) has a box that
                // overlaps this one's edge a little : its centre being well past ours counts too
                const pastX = (d) => (d > 0 ? bx - ax : ax - bx) > Math.min(a.width, b.width) * 0.6;
                if (dx > 0 && b.left < a.right - 2 && !pastX(1)) return;
                if (dx < 0 && b.right > a.left + 2 && !pastX(-1)) return;
                if (dy > 0 && b.top < a.bottom - 2) return;
                if (dy < 0 && b.bottom > a.top + 2) return;
                const ahead = dx !== 0 ? Math.abs(bx - ax) : Math.abs(by - ay);
                // sideways : the gap between the two boxes' spans (0 when they overlap)
                const side =
                    dx !== 0
                        ? Math.max(0, b.top - a.bottom, a.top - b.bottom)
                        : Math.max(0, b.left - a.right, a.left - b.right);
                // tie-break by how far the centres are out of line : slanted neighbours' boxes
                // overlap sideways, so straight below and diagonally below can both have side 0
                const offAxis = dx !== 0 ? Math.abs(by - ay) : Math.abs(bx - ax);
                const score = ahead + side * 4 + offAxis * 0.1;
                if (score < bestScore) {
                    bestScore = score;
                    best = el;
                }
            });
            return best;
        };
        // the cursor's element went away : the view's main action if it has one (a lobby's I'm
        // ready), otherwise the first control at or below where the cursor was (a start form's
        // first option), otherwise the top
        // `before` : what was there before a press ; controls that just appeared (a start form's
        // options) come first, so the race's own Leaderboard button beside Start isn't picked
        const landAfterLoss = (before) => {
            const list = focusables();
            const main = list.find((el) => el.hasAttribute("data-pad-a"));
            if (main) return setPadEl(main);
            const fresh = before ? list.filter((el) => !before.has(el)) : [];
            const pool = fresh.length > 0 ? fresh : list;
            if (padRect) {
                let best = null;
                let bestScore = Infinity;
                pool.forEach((el) => {
                    const r = el.getBoundingClientRect();
                    if (r.bottom < padRect.top - 2) return;
                    const score = Math.abs(r.top - padRect.top) * 2 + Math.abs(r.left - padRect.left);
                    if (score < bestScore) {
                        bestScore = score;
                        best = el;
                    }
                });
                if (best) return setPadEl(best);
            }
            setPadEl(pool[0]);
        };
        // true when it moved
        const moveDir = (dir) => {
            if (!padEl || !document.contains(padEl)) {
                landAfterLoss();
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
        // a lobby's I'm ready showing up under the pad (the Focus control taking you to your
        // lobby, joining one, its status arriving after the panel opened, back from the invite
        // list) : the cursor goes to it (direct request : it took scrolling down to the button).
        // Only when it appears, so moving off it afterwards sticks
        const readyEl = () => {
            if (!this.pad || this.padLevel === "rail") return null;
            const c = container();
            const el = c && c.querySelector("[data-pad-ready]");
            return el && el.offsetParent !== null && !isDisabled(el) ? el : null;
        };
        $scope.$watch(readyEl, (el, prev) => {
            if (!el || el === prev || el === padEl) return;
            $timeout(() => {
                if (readyEl() === el) setPadEl(el);
            });
        });
        // a bj-select dropdown under the cursor : step to the previous / next option
        const cycleSelect = (el, step) => {
            const host = el.closest("bj-select");
            const ctrl = host && angular.element(host).controller("bjSelect");
            const options = (ctrl && ctrl.options) || [];
            if (options.length === 0) return;
            const i = options.findIndex((o) => o.value === ctrl.ngModel);
            const next = options[(Math.max(i, 0) + step + options.length) % options.length];
            $rootScope.$applyAsync(() => {
                ctrl.ngModel = next.value;
                // the parent's copy of the model updates on this digest ; handleChange passes the
                // new value along itself
                $timeout(() => ctrl.handleChange());
            });
        };
        const isSelect = (el) => !!el && el.tagName === "MD-SELECT";
        // A on a dropdown : its options as a list the pad can move through (the dropdown's own
        // popup renders outside the panel, out of the pad's reach). Up / down pick, A chooses, B
        // closes ; the mouse works on it too
        this.picker = null;
        const openPicker = (el) => {
            const host = el.closest("bj-select");
            const ctrl = host && angular.element(host).controller("bjSelect");
            const options = (ctrl && ctrl.options) || [];
            if (options.length === 0) return;
            const r = el.getBoundingClientRect();
            $rootScope.$applyAsync(() => {
                this.picker = {
                    ctrl,
                    options,
                    index: Math.max(0, options.findIndex((o) => o.value === ctrl.ngModel)),
                    style: {
                        left: `${r.left}px`,
                        top: `${Math.min(r.bottom + 4, window.innerHeight * 0.6)}px`,
                        minWidth: `${Math.max(r.width, 200)}px`,
                    },
                };
            });
        };
        this.pickOption = (index) => {
            const p = this.picker;
            if (!p) return;
            const option = p.options[index];
            this.picker = null;
            if (!option) return;
            p.ctrl.ngModel = option.value;
            $timeout(() => p.ctrl.handleChange());
        };
        this.closePicker = () => (this.picker = null);
        // ng-click runs its own $apply : press outside of Angular's digest
        const press = (el) => {
            if (!el) return;
            if (isSelect(el)) return openPicker(el);
            setTimeout(() => {
                if (el.tagName === "INPUT" && (el.type === "text" || el.type === "number")) {
                    el.focus();
                    return;
                }
                const before = new Set(focusables());
                el.click();
                // the pressed button may be gone (a form opened, a card closed) : keep a cursor,
                // near where it was
                $timeout(() => {
                    if (!document.contains(padEl)) landAfterLoss(before);
                }, 80);
            });
        };
        const nudge = (dir) => {
            if (isSelect(padEl)) {
                cycleSelect(padEl, dir);
                return true;
            }
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
                    if (data.panel === "full") {
                        // the rail's Full button, clicked : stay in the full window
                        this.full = true;
                        this.padLevel = "full";
                        enterContent();
                    } else if (data.panel) {
                        if (this.full && data.panel !== "vote") {
                            this.fullTab = this.fullFor(data.panel);
                            this.padLevel = "full";
                            enterContent();
                        } else {
                            openPanel(data.panel);
                        }
                        // the Focus control, or a click on the rail : the cursor starts on the
                        // panel's rail button
                        if (data.cursor === "rail" && !this.full) {
                            $timeout(() => {
                                setPadEl(null);
                                this.padLevel = "rail";
                                this.railCursor = data.panel;
                            }, 70);
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
                // a dropdown's list is open : it has the pad
                if (this.picker) {
                    const p = this.picker;
                    if (name === "focus_u") p.index = Math.max(0, p.index - 1);
                    else if (name === "focus_d") p.index = Math.min(p.options.length - 1, p.index + 1);
                    else if (name === "ok") this.pickOption(p.index);
                    else if (name === "back") this.closePicker();
                    return;
                }
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
                    if (shortcut("b")) return;
                    if (full) toggleFull();
                    else toRail();
                } else if (full && name === "tab_l") switchTab(-1);
                else if (full && name === "tab_r") switchTab(1);
            });
        });
        $scope.$on("$destroy", offNav);

        // RAIL POSITION ----------------------------------------------------------------------
        // Dragged by its logo, remembered per player (localStorage, as fractions of the screen so
        // it survives a resolution change). The side it's on decides where panels open : towards
        // the middle of the screen. Default : right edge, low enough to clear the race overlay.
        // HIDE WHEN IDLE (Settings > Menu) : with nothing open and the pad elsewhere, the rail
        // fades down to a small handle ; hovering it, the Focus binding or any panel brings it back
        this.autoHide = false;
        try {
            this.autoHide = localStorage.getItem("beamjoy.rail.autoHide") === "1";
        } catch (e) {
            // storage unavailable : always shown
        }
        $rootScope.$on("BJRailAutoHide", (_, on) => (this.autoHide = !!on));
        this.railHover = false;
        let hoverOff = null;
        this.hoverRail = (inside) => {
            $timeout.cancel(hoverOff);
            if (inside) this.railHover = true;
            // a short grace so moving onto a panel or a notice doesn't flicker it away
            else hoverOff = $timeout(() => (this.railHover = false), 700);
        };
        this.railTucked = () => this.autoHide && !this.panel && !this.full && !this.pad && !this.railHover && !drag;

        const STORE_KEY = "beamjoy.rail.position";
        const GAP = 12;
        this.railPos = null;
        try {
            const saved = JSON.parse(localStorage.getItem(STORE_KEY) || "null");
            if (saved && typeof saved.x === "number" && typeof saved.y === "number") this.railPos = saved;
        } catch (e) {
            // storage can be unavailable in CEF : the default position is fine
        }
        const railSize = () => {
            const rail = root().querySelector(".bjr-rail");
            return { w: rail ? rail.offsetWidth : 64, h: rail ? rail.offsetHeight : 420 };
        };
        this.railRect = () => {
            const { w, h } = railSize();
            const W = window.innerWidth;
            const H = window.innerHeight;
            let left = this.railPos ? this.railPos.x * W : W - w - W * 0.01;
            let top = this.railPos ? this.railPos.y * H : H * 0.3;
            left = Math.max(4, Math.min(W - w - 4, left));
            top = Math.max(4, Math.min(H - Math.min(h, H - 8) - 4, top));
            return { left, top, right: left + w, bottom: top + h, width: w };
        };
        this.side = () => {
            const r = this.railRect();
            return r.left + r.width / 2 < window.innerWidth / 2 ? "left" : "right";
        };
        this.railStyle = () => {
            const r = this.railRect();
            return { left: `${r.left}px`, top: `${r.top}px` };
        };
        this.panelStyle = () => {
            const r = this.railRect();
            const style = { top: `${r.top}px`, maxHeight: `calc(100vh - ${r.top}px - 2vh)` };
            if (this.side() === "left") style.left = `${r.right + GAP}px`;
            else style.right = `${window.innerWidth - r.left + GAP}px`;
            return style;
        };
        this.fullStyle = () => {
            const r = this.railRect();
            return this.side() === "left"
                ? { left: `${r.right + GAP + 8}px`, right: "6vw" }
                : { left: "6vw", right: `${window.innerWidth - r.left + GAP + 8}px` };
        };
        let drag = null;
        let lastDown = 0;
        this.startDrag = (event) => {
            if (event.button !== 0) return;
            event.preventDefault();
            // a second press within 400 ms : back to the default position
            const now = Date.now();
            if (now - lastDown < 400) {
                lastDown = 0;
                drag = null;
                return this.resetRail();
            }
            lastDown = now;
            const r = this.railRect();
            drag = { dx: event.clientX - r.left, dy: event.clientY - r.top, x: event.clientX, y: event.clientY, moved: false };
        };
        const onMove = (event) => {
            if (!drag) return;
            if (!drag.moved && Math.abs(event.clientX - drag.x) + Math.abs(event.clientY - drag.y) < 5) return;
            drag.moved = true;
            $scope.$applyAsync(() => {
                this.railPos = {
                    x: (event.clientX - drag.dx) / window.innerWidth,
                    y: (event.clientY - drag.dy) / window.innerHeight,
                };
            });
        };
        const onUp = () => {
            if (!drag) return;
            const moved = drag.moved;
            drag = null;
            if (!moved) return;
            try {
                localStorage.setItem(STORE_KEY, JSON.stringify(this.railPos));
            } catch (e) {
                // not remembered this time, still moved
            }
        };
        const onResize = () => $scope.$applyAsync();
        window.addEventListener("mousemove", onMove);
        window.addEventListener("mouseup", onUp);
        window.addEventListener("resize", onResize);
        $scope.$on("$destroy", () => {
            window.removeEventListener("mousemove", onMove);
            window.removeEventListener("mouseup", onUp);
            window.removeEventListener("resize", onResize);
        });
        this.resetRail = () => {
            this.railPos = null;
            try {
                localStorage.removeItem(STORE_KEY);
            } catch (e) {
                // nothing stored
            }
        };

        // where the rail and its panel are, for the notification stack (windows/notices) : it sits
        // beside them, never on top of the panel you're using
        const PANEL_WIDTH_EM = { play: 28, settings: 28 };
        $scope.$watch(() => {
            const r = this.railRect();
            return [this.visible, this.panel, this.full, Math.round(r.left), Math.round(r.top), window.innerWidth].join("|");
        }, () => {
            $rootScope.bjMainLayout = {
                rail: !!this.visible,
                full: !!this.full,
                side: this.side(),
                railRect: this.railRect(),
                panelEm: this.visible && this.panel && !this.full ? PANEL_WIDTH_EM[this.panel] || 22 : 0,
            };
        });

        // closing the panel (mouse, or its own close button) lets go of the pad it took
        $scope.$watchGroup([() => this.panel, () => this.full], () => {
            if (this.pad && !this.panel && !this.full) this.releasePad();
        });
        // an activity getting under way (a race counting down, a hunt, a delivery...) : the menu
        // gets out of the way
        $scope.$watch(() => beamjoyNow.runningKey(), (key, previous) => {
            if (!key || key === previous) return;
            this.panel = null;
            this.full = false;
            if (this.pad) this.releasePad();
        });
    },
});
