// The pit menu (PIT_SYSTEM_PLAN.md §7) : this racer's pit stop plan, what their next stop in their box
// does. Opened from the race HUD's Pit button, and shown on the HUD's left, as wide as it (direct
// request) ; all state comes from beamjoy/racePits.lua
// (BJRacePitMenu), saved there as it's changed (BJRacePitSetPlan) and kept for the race.
// Pad-first : while it's open racePits.lua lends it the pad's menu buttons (beamjoy/uiNav.lua). One
// row is selected at a time (the delivery board's orange) : D-pad up / down between the rows (the
// fuel amount skipped while refuelling is off), left / right changes the row (held on the amount,
// it repeats and speeds up), A toggles, fills up on the amount, closes on Done, B closes. Only the
// D-pad, A and B : LB is the clutch. The mouse clicks any row, arrow or button ; with the window
// focused the arrow keys, Enter and Esc work too.
// The fuel's in the player's own unit (the game's volume setting : litres or US gallons), a
// battery's in kWh. The plan keeps a share of the tank (racePits.lua's plan.fuelAdd, 1 : fill up).
const PIT_GALLON_L = 3.785411784;

angular.module("beamjoy").service("beamjoyPitFormat", function () {
    // a volume (litres, or kWh a battery) in the player's unit : "25.0 L", "6.6 gal", "12.4 kWh"
    this.amount = (value, tank, gallons, digits = 1) => {
        const v = Number(value) || 0;
        if (tank && tank.kind === "battery") return `${v.toFixed(digits)} kWh`;
        return gallons ? `${(v / PIT_GALLON_L).toFixed(digits)} gal` : `${v.toFixed(digits)} L`;
    };
    // the plan, short (the HUD's pit line) : "+25.0 L, repair", "fill up", "+40%"
    this.planText = (plan, status, translate) => {
        if (!plan || !status) return "";
        const parts = [];
        if (status.refuel && plan.refuel && plan.fuelAdd > 0) {
            if (plan.fuelAdd >= 1) parts.push(translate("beamjoy.race.pitMenu.planFill"));
            else if (status.tank && status.tank.capacity > 0) parts.push(`+${this.amount(plan.fuelAdd * status.tank.capacity, status.tank, status.gallons)}`);
            else parts.push(`+${Math.round(plan.fuelAdd * 100)}%`);
        }
        if (status.repair && plan.repair) parts.push(translate("beamjoy.race.pitMenu.planRepair"));
        return parts.length > 0 ? parts.join(", ") : translate("beamjoy.race.pitMenu.planNothing");
    };
});

angular.module("beamjoy").component("bjPitControl", {
    templateUrl: "/ui/modModules/beamjoy/windows/pitControl/app.html",
    controller: function ($rootScope, $scope, $filter, $interval, $timeout, beamjoyStore, beamjoyDelivery, beamjoyPitFormat) {
        const translate = (key) => $filter("translate")(key);
        const fill = (key, values) =>
            Object.entries(values).reduce((text, [k, v]) => text.replace(`{${k}}`, v), translate(key));
        const fmt = beamjoyPitFormat;

        this.open = false;
        this.d = null;
        // the plan as edited here (sent as it changes) : taken from Lua once, when the menu opens
        this.plan = { refuel: true, fuelAdd: 1, repair: true };
        // the rows : refuel, the amount, repair, Done
        this.cursor = 0;
        // what's shown, built once per change (never in template getters)
        this.v = null;

        const tank = () => (this.d && this.d.tank) || null;
        const battery = () => !!tank() && tank().kind === "battery";
        // a step on the amount : 1 L, 0.25 gal, 1 kWh (in the tank's own unit : litres or kWh)
        const unitStep = () => (battery() ? 1 : this.d && this.d.gallons ? 0.25 * PIT_GALLON_L : 1);
        const refuelOn = () => !!this.d && this.d.refuelAllowed && this.plan.refuel;
        // the rows the cursor stops on
        const rows = () => {
            const out = [];
            if (this.d && this.d.refuelAllowed) out.push(0);
            if (refuelOn()) out.push(1);
            if (this.d && this.d.repairAllowed) out.push(2);
            out.push(3);
            return out;
        };

        const build = () => {
            const d = this.d;
            if (!d) return (this.v = null);
            const t = tank();
            const gal = !!d.gallons;
            const rate = Math.max(1, Number(d.ratePct) || 5) / 100;
            const v = {
                eyebrow: d.slot ? fill("beamjoy.race.pitMenu.box", { n: d.slot }) : translate("beamjoy.race.pitMenu.pit"),
                stops: d.required > 0 ? fill("beamjoy.race.pitMenu.stopsRequired", { n: d.stops, of: d.required })
                    : fill("beamjoy.race.pitMenu.stopsMade", { n: d.stops }),
                fuelLabel: translate(battery() ? "beamjoy.race.pitMenu.recharge" : "beamjoy.race.pitMenu.refuel"),
                fuelOn: refuelOn(),
                repairOn: d.repairAllowed && this.plan.repair,
            };
            // the fuel : what's in, what this stop adds (capped at the room left), how long
            const add = refuelOn() ? Math.max(0, Math.min(1, this.plan.fuelAdd)) : 0;
            if (t && t.capacity > 0) {
                const now = Math.max(0, Math.min(1, t.stored / t.capacity));
                const added = Math.min(add, 1 - now);
                v.tankText = `${fmt.amount(t.stored, t, gal)} / ${fmt.amount(t.capacity, t, gal)}`;
                v.addText = !refuelOn() ? "—" : add >= 1 ? translate("beamjoy.race.pitMenu.full") : `+${fmt.amount(add * t.capacity, t, gal)}`;
                v.afterText = fmt.amount((now + added) * t.capacity, t, gal);
                v.nowPct = `${(now * 100).toFixed(1)}%`;
                v.addPct = `${(added * 100).toFixed(1)}%`;
                v.fuelS = added / rate;
            } else {
                // not read yet (or no tank) : the share of the tank
                v.tankText = translate("beamjoy.race.pitMenu.reading");
                v.addText = !refuelOn() ? "—" : add >= 1 ? translate("beamjoy.race.pitMenu.full") : `+${Math.round(add * 100)}%`;
                v.afterText = "";
                v.nowPct = "0%";
                v.addPct = `${(add * 100).toFixed(1)}%`;
                v.fuelS = add / rate;
            }
            // the repair : the damage, the parts behind its time
            const dmg = d.damage;
            v.repairS = v.repairOn && dmg ? Number(dmg.seconds) || 0 : 0;
            v.damageText = dmg ? fill("beamjoy.race.pitMenu.damage", { n: Math.round((Number(dmg.share) || 0) * 100) })
                : d.repairAllowed ? translate("beamjoy.race.pitMenu.reading") : "";
            v.chips = [];
            if (dmg) {
                // an empty list comes from Lua as {} : no parts then
                (Array.isArray(dmg.parts) ? dmg.parts : []).forEach((p, i) => v.chips.push({ key: `p${i}`, text: `${p.name} ${p.pct}%` }));
                if (dmg.flatTyres > 0) {
                    v.chips.push({ key: "tyres", warn: true, text: fill(dmg.flatTyres === 1 ? "beamjoy.race.pitMenu.flatTyre" : "beamjoy.race.pitMenu.flatTyres", { n: dmg.flatTyres }) });
                }
                if (dmg.fault) v.chips.push({ key: "fault", warn: true, text: translate("beamjoy.race.pitMenu.fault") });
                if (v.chips.length === 0) v.chips.push({ key: "none", text: translate("beamjoy.race.pitMenu.noDamage") });
            }
            v.totalS = (v.fuelS || 0) + v.repairS;
            v.fuelSText = `+${(v.fuelS || 0).toFixed(1)} s`;
            v.repairSText = `+${v.repairS.toFixed(1)} s`;
            v.doneText = fill("beamjoy.race.pitMenu.doneTime", { n: v.totalS.toFixed(1) });
            // the footer's hints follow the row
            v.lrHint = translate(this.cursor === 1 ? "beamjoy.race.pitMenu.hints.amount" : this.cursor === 3 ? "beamjoy.race.pitMenu.hints.none" : "beamjoy.race.pitMenu.hints.onOff");
            v.aHint = translate(this.cursor === 1 ? "beamjoy.race.pitMenu.hints.fillUp" : this.cursor === 3 ? "beamjoy.race.pitMenu.hints.done" : "beamjoy.race.pitMenu.hints.toggle");
            this.v = v;
        };

        // beside the race HUD (#beamjoy-race-hud) : level with its top, on its left ; app.html's own
        // spot when it isn't showing. Followed while open, the HUD changing size with its layout
        const HUD_GAP_PX = 8;
        this.placeStyle = null;
        let placeTick = null;
        const place = () => {
            const hud = document.getElementById("beamjoy-race-hud");
            const r = hud ? hud.getBoundingClientRect() : null;
            const next = r && r.width > 0
                ? { top: `${Math.round(r.top)}px`, right: `${Math.round(window.innerWidth - r.left + HUD_GAP_PX)}px` }
                : null;
            if (!angular.equals(next, this.placeStyle)) this.placeStyle = next;
        };
        const stopPlacing = () => {
            $interval.cancel(placeTick);
            placeTick = null;
        };

        $rootScope.$on("BJRacePitMenu", (_, data) => {
            $scope.$applyAsync(() => {
                const wasOpen = this.open;
                this.open = !!(data && data.open);
                this.d = this.open ? data : null;
                if (this.open && !wasOpen) {
                    if (data.plan) this.plan = angular.copy(data.plan);
                    this.cursor = rows()[0];
                    place();
                    placeTick = $interval(place, 500);
                }
                if (!this.open) {
                    stopRepeat();
                    stopPlacing();
                }
                beamjoyDelivery.setNavOwner("pitControl", this.open);
                build();
            });
        });
        this.$onInit = () => beamjoyStore.send("BJRacePitMenuRequest");

        const save = () => {
            beamjoyStore.send("BJRacePitSetPlan", [angular.copy(this.plan)]);
            build();
        };
        this.close = () => beamjoyStore.send("BJRacePitMenuClose");
        this.select = (row) => {
            if (!rows().includes(row)) return;
            this.cursor = row;
            build();
        };
        this.toggleFuel = () => {
            if (!this.d || !this.d.refuelAllowed) return;
            this.plan.refuel = !this.plan.refuel;
            this.cursor = 0;
            save();
        };
        this.toggleRepair = () => {
            if (!this.d || !this.d.repairAllowed) return;
            this.plan.repair = !this.plan.repair;
            this.cursor = 2;
            save();
        };
        this.fillUp = () => {
            if (!refuelOn()) return;
            this.plan.fuelAdd = 1;
            this.cursor = 1;
            save();
        };
        // `dir` steps of the amount (`mult` of the unit's step, a held press speeding up), snapped to
        // the unit's grid ; the whole tank reads as Fill up
        this.step = (dir, mult = 1) => {
            if (!refuelOn()) return;
            this.cursor = 1;
            const t = tank();
            if (!t || !(t.capacity > 0)) {
                this.plan.fuelAdd = Math.max(0, Math.min(1, Math.round((this.plan.fuelAdd * 20) + dir * mult) / 20));
            } else {
                const s = unitStep();
                const q = Math.round((this.plan.fuelAdd * t.capacity) / s) + dir * mult;
                this.plan.fuelAdd = Math.max(0, Math.min(1, (q * s) / t.capacity));
            }
            save();
        };

        // left / right held on the amount : repeats, faster the longer it's held (up to 5 steps)
        let repeat = null;
        let repeatDelay = null;
        const stopRepeat = () => {
            $timeout.cancel(repeatDelay);
            $interval.cancel(repeat);
            repeat = repeatDelay = null;
        };
        const startRepeat = (dir) => {
            stopRepeat();
            const started = Date.now();
            repeatDelay = $timeout(() => {
                repeat = $interval(() => {
                    const held = Date.now() - started;
                    this.step(dir, Math.min(5, 1 + Math.floor((held - 400) / 600)));
                }, 90);
            }, 400);
        };

        // one input, from the pad or the keyboard
        const press = (name) => {
            const list = rows();
            const at = Math.max(0, list.indexOf(this.cursor));
            if (name === "focus_u") this.select(list[Math.max(0, at - 1)]);
            else if (name === "focus_d") this.select(list[Math.min(list.length - 1, at + 1)]);
            else if (name === "focus_l" || name === "focus_r") {
                const dir = name === "focus_l" ? -1 : 1;
                if (this.cursor === 0) this.toggleFuel();
                else if (this.cursor === 1) this.step(dir);
                else if (this.cursor === 2) this.toggleRepair();
                return dir;
            } else if (name === "ok") {
                if (this.cursor === 0) this.toggleFuel();
                else if (this.cursor === 1) this.fillUp();
                else if (this.cursor === 2) this.toggleRepair();
                else this.close();
            } else if (name === "back") this.close();
            return 0;
        };

        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            // letting go of left / right ends a held amount
            if ((name === "focus_l" || name === "focus_r") && Number(value) <= 0.5) {
                $scope.$applyAsync(stopRepeat);
                return;
            }
            if (!this.open || !rising) return;
            $scope.$applyAsync(() => {
                const dir = press(name);
                if (dir && this.cursor === 1) startRepeat(dir);
            });
        });
        // the keyboard, while the window has it (a click on it) : the browser repeats a held key itself
        const KEYS = { ArrowUp: "focus_u", ArrowDown: "focus_d", ArrowLeft: "focus_l", ArrowRight: "focus_r", Enter: "ok", Escape: "back" };
        const onKey = (e) => {
            if (!this.open || !KEYS[e.key]) return;
            e.preventDefault();
            e.stopPropagation();
            $scope.$applyAsync(() => press(KEYS[e.key]));
        };
        window.addEventListener("keydown", onKey, true);
        $scope.$on("$destroy", () => {
            offNav();
            stopRepeat();
            stopPlacing();
            window.removeEventListener("keydown", onKey, true);
            beamjoyDelivery.setNavOwner("pitControl", false);
        });
    },
});
