// The pit menu (PIT_SYSTEM_PLAN.md §7) : this racer's pit stop plan, what their next stop in their box
// does. Opened from the race HUD's Pit button, and shown on the HUD's left, as wide as it (direct
// request) ; all state comes from beamjoy/racePits.lua
// (BJRacePitMenu), and kept for the race. What's changed here only goes to Lua (BJRacePitSetPlan)
// when it's confirmed ; cancelling closes the menu without it.
// Pad-first, and the D-pad only (direct request : the face buttons stay the car's) : while it's open
// racePits.lua lends it the D-pad (beamjoy/uiNav.lua). One row is selected at a time (the delivery
// board's orange) : up / down between the rows (the fuel amount skipped while refuelling is off),
// a tap on left / right changes the row (when it's let go), right held 0.5 s confirms, left held 0.5 s
// cancels. The mouse clicks any row, arrow or button (Confirm, the ✕ cancels) ; with the window
// focused the arrow keys, Enter and Esc work too.
// The fuel's in the player's own unit (the game's volume setting : litres or US gallons), a
// battery's in kWh. The plan keeps a share of the tank (racePits.lua's plan.fuelAdd, 1 : fill up).
// The Tyres row only shows with the server's experimental tyre changes on (and the race allowing
// them) : Keep or a new set, or Keep and each of the server's plugins' sets (plan.tyres : false, true,
// or "plugin:id"), or Keep and the sets a plugin left this racer (the API's tyres.setAvailable).
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
            const t = status.tank;
            // more than the room left (the tank read) : it fills up
            const fills = plan.fuelAdd >= 1 || (t && t.capacity > 0 && typeof t.stored === "number"
                && plan.fuelAdd * t.capacity >= t.capacity - t.stored);
            if (fills) parts.push(translate("beamjoy.race.pitMenu.planFill"));
            else if (status.tank && status.tank.capacity > 0) parts.push(`+${this.amount(plan.fuelAdd * status.tank.capacity, status.tank, status.gallons)}`);
            else parts.push(`+${Math.round(plan.fuelAdd * 100)}%`);
        }
        if (status.tyres && plan.tyres) {
            parts.push(status.tyreLabel ? translate("beamjoy.race.pitMenu.planTyresSet").replace("{name}", status.tyreLabel)
                : translate("beamjoy.race.pitMenu.planTyres"));
        }
        if (status.repair && plan.repair) parts.push(translate("beamjoy.race.pitMenu.planRepair"));
        return parts.length > 0 ? parts.join(", ") : translate("beamjoy.race.pitMenu.planNothing");
    };
});

angular.module("beamjoy").component("bjPitControl", {
    templateUrl: "/ui/modModules/beamjoy/windows/pitControl/app.html",
    controller: function ($rootScope, $scope, $filter, $interval, beamjoyStore, beamjoyDelivery, beamjoyPitFormat) {
        const translate = (key) => $filter("translate")(key);
        const fill = (key, values) =>
            Object.entries(values).reduce((text, [k, v]) => text.replace(`{${k}}`, v), translate(key));
        const fmt = beamjoyPitFormat;

        this.open = false;
        this.d = null;
        // the plan as edited here (sent when it's confirmed) : taken from Lua once, when the menu opens
        this.plan = { refuel: true, fuelAdd: 1, repair: true, tyres: false };
        // the rows : refuel (0), the amount (1), tyres (4), repair (2), Done (3)
        this.cursor = 0;
        // what's shown, built once per change (never in template getters)
        this.v = null;

        const tank = () => (this.d && this.d.tank) || null;
        const battery = () => !!tank() && tank().kind === "battery";
        // a step on the amount (in the tank's own unit : litres or kWh) : 1 L, 0.25 gal, 1 kWh with the
        // mouse or the keyboard ; a pad's tap 5 L, 1 gal, 5 kWh (no held count with the pad)
        const unitStep = (pad) => (battery() ? (pad ? 5 : 1)
            : this.d && this.d.gallons ? (pad ? 1 : 0.25) * PIT_GALLON_L : pad ? 5 : 1);
        const refuelOn = () => !!this.d && this.d.refuelAllowed && this.plan.refuel;
        // the plugins' tyre sets ({key, label, seconds?}) ; an empty list comes from Lua as {}
        const tyreOptions = () => (this.d && Array.isArray(this.d.tyreOptions) ? this.d.tyreOptions : []);
        // what the Tyres row steps through : Keep, then a new set or each plugin's set ; the sets a
        // plugin left this racer only when it chose them (tyreRestricted : none, Keep alone)
        const tyreChoices = () => {
            const options = tyreOptions();
            if (this.d && this.d.tyreRestricted) return [false, ...options.map((o) => o.key)];
            return options.length > 0 ? [false, ...options.map((o) => o.key)] : [false, true];
        };
        // the plan's tyres as this racer can have them (a set no longer theirs : Keep)
        const tyresPick = () => (this.d && this.d.tyreRestricted && !tyreChoices().includes(this.plan.tyres) ? false : this.plan.tyres);
        // the rows the cursor stops on
        const rows = () => {
            const out = [];
            if (this.d && this.d.refuelAllowed) out.push(0);
            if (refuelOn()) out.push(1);
            if (this.d && this.d.tyresAllowed) out.push(4);
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
                tyresOn: !!d.tyresAllowed && !!tyresPick(),
            };
            // the fuel : what's in, what this stop adds (capped at the room left), how long
            const add = refuelOn() ? Math.max(0, Math.min(1, this.plan.fuelAdd)) : 0;
            if (t && t.capacity > 0) {
                const now = Math.max(0, Math.min(1, t.stored / t.capacity));
                const added = Math.min(add, 1 - now);
                v.tankText = `${fmt.amount(t.stored, t, gal)} / ${fmt.amount(t.capacity, t, gal)}`;
                // a plan bigger than the room (kept from before the last stop) : it fills the tank
                v.addText = !refuelOn() ? "—" : add >= 1 - now ? translate("beamjoy.race.pitMenu.full") : `+${fmt.amount(add * t.capacity, t, gal)}`;
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
            // the tyres : the set, its time, the flats, a wheel torn off (new tyres don't put it back)
            const pick = tyresPick();
            const option = typeof pick === "string" ? tyreOptions().find((o) => o.key === pick) : null;
            v.tyreText = !pick ? translate("beamjoy.race.pitMenu.tyresKeep")
                : option ? option.label : translate("beamjoy.race.pitMenu.tyresNew");
            v.tyreS = v.tyresOn ? Number(option && option.seconds != null ? option.seconds : d.tyreS) || 0 : 0;
            v.tyreSText = `+${v.tyreS.toFixed(1)} s`;
            const flats = dmg ? Number(dmg.flatTyres) || 0 : 0;
            v.tyreSide = !dmg ? translate("beamjoy.race.pitMenu.reading")
                : flats > 0 ? fill(flats === 1 ? "beamjoy.race.pitMenu.flatTyre" : "beamjoy.race.pitMenu.flatTyres", { n: flats })
                : translate("beamjoy.race.pitMenu.noFlats");
            v.tyreFlat = flats > 0;
            const off = dmg ? Number(dmg.brokenWheels) || 0 : 0;
            v.tyreChips = off > 0 ? [{ key: "off", warn: true, text: fill(off === 1 ? "beamjoy.race.pitMenu.wheelOff" : "beamjoy.race.pitMenu.wheelsOff", { n: off }) }] : [];
            v.damageText = dmg ? fill("beamjoy.race.pitMenu.damage", { n: Math.round((Number(dmg.share) || 0) * 100) })
                : d.repairAllowed ? translate("beamjoy.race.pitMenu.reading") : "";
            v.chips = [];
            if (dmg) {
                // an empty list comes from Lua as {} : no parts then
                (Array.isArray(dmg.parts) ? dmg.parts : []).forEach((p, i) => v.chips.push({ key: `p${i}`, text: `${p.name} ${p.pct}%` }));
                // tyres apart : the flats are the Tyres row's
                if (dmg.flatTyres > 0 && !d.tyresAllowed) {
                    v.chips.push({ key: "tyres", warn: true, text: fill(dmg.flatTyres === 1 ? "beamjoy.race.pitMenu.flatTyre" : "beamjoy.race.pitMenu.flatTyres", { n: dmg.flatTyres }) });
                }
                if (dmg.fault) v.chips.push({ key: "fault", warn: true, text: translate("beamjoy.race.pitMenu.fault") });
                if (v.chips.length === 0) v.chips.push({ key: "none", text: translate("beamjoy.race.pitMenu.noDamage") });
            }
            v.totalS = (v.fuelS || 0) + v.tyreS + v.repairS;
            v.fuelSText = `+${(v.fuelS || 0).toFixed(1)} s`;
            v.repairSText = `+${v.repairS.toFixed(1)} s`;
            v.doneText = fill("beamjoy.race.pitMenu.doneTime", { n: v.totalS.toFixed(1) });
            // the footer's hints follow the row
            v.lrHint = translate(this.cursor === 1 ? "beamjoy.race.pitMenu.hints.amount" : this.cursor === 4 ? "beamjoy.race.pitMenu.hints.tyres"
                : this.cursor === 3 ? "beamjoy.race.pitMenu.hints.none" : "beamjoy.race.pitMenu.hints.onOff");
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
                    if (this.plan.tyres === undefined) this.plan.tyres = false;
                    this.cursor = rows()[0];
                    place();
                    placeTick = $interval(place, 500);
                }
                if (!this.open) {
                    endHold();
                    stopPlacing();
                }
                beamjoyDelivery.setNavOwner("pitControl", this.open);
                build();
            });
        });
        this.$onInit = () => beamjoyStore.send("BJRacePitMenuRequest");

        // a change : shown at once, kept here until it's confirmed
        const save = () => build();
        // Confirm (right held, the button, Enter on it) : the plan to Lua, then closed ; Cancel (left
        // held, the ✕, Esc) : closed, Lua's plan as it was (the next open starts from it)
        this.confirm = () => {
            beamjoyStore.send("BJRacePitSetPlan", [angular.copy(this.plan)]);
            beamjoyStore.send("BJRacePitMenuClose");
        };
        this.cancel = () => beamjoyStore.send("BJRacePitMenuClose");
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
        // `dir` steps through the tyre choices (a set no plugin offers any more : from Keep)
        this.cycleTyres = (dir) => {
            if (!this.d || !this.d.tyresAllowed) return;
            const list = tyreChoices();
            const at = Math.max(0, list.indexOf(this.plan.tyres));
            this.plan.tyres = list[(at + dir + list.length) % list.length];
            this.cursor = 4;
            save();
        };
        this.fillUp = () => {
            if (!refuelOn()) return;
            this.plan.fuelAdd = 1;
            this.cursor = 1;
            save();
        };
        // `dir` steps of the amount (a pad's tap : its bigger step), onto the step's grid, never past the
        // room left in the tank (direct report : +50 L offered on a nearly full one) : reaching it reads
        // as Fill up, and stepping down from Fill up starts from the room
        this.step = (dir, pad = false) => {
            if (!refuelOn()) return;
            this.cursor = 1;
            const t = tank();
            if (!t || !(t.capacity > 0)) {
                const parts = pad ? 10 : 20;
                this.plan.fuelAdd = Math.max(0, Math.min(1, Math.round((this.plan.fuelAdd * parts) + dir) / parts));
            } else {
                const s = unitStep(pad);
                const room = Math.max(0, t.capacity - (Number(t.stored) || 0));
                const cur = Math.min(room, this.plan.fuelAdd * t.capacity) / s;
                const q = dir > 0 ? Math.floor(cur + 1e-6) + dir : Math.ceil(cur - 1e-6) + dir;
                this.plan.fuelAdd = q * s >= room - 1e-6 ? 1 : Math.max(0, (q * s) / t.capacity);
            }
            save();
        };

        // one input, from the pad (`pad`) or the keyboard
        const press = (name, pad = false) => {
            const list = rows();
            const at = Math.max(0, list.indexOf(this.cursor));
            if (name === "focus_u") this.select(list[Math.max(0, at - 1)]);
            else if (name === "focus_d") this.select(list[Math.min(list.length - 1, at + 1)]);
            else if (name === "focus_l" || name === "focus_r") {
                const dir = name === "focus_l" ? -1 : 1;
                if (this.cursor === 0) this.toggleFuel();
                else if (this.cursor === 1) this.step(dir, pad);
                else if (this.cursor === 4) this.cycleTyres(dir);
                else if (this.cursor === 2) this.toggleRepair();
            } else if (name === "ok") {
                if (this.cursor === 0) this.toggleFuel();
                else if (this.cursor === 1) this.fillUp();
                else if (this.cursor === 4) this.cycleTyres(1);
                else if (this.cursor === 2) this.toggleRepair();
                else this.confirm();
            } else if (name === "back") this.cancel();
        };

        // left / right on the pad : a tap acts when it's let go ; held, right confirms (half a second,
        // direct request : quicker) and left cancels (as quick, direct request) instead. padHold ("confirm" /
        // "cancel") and padHoldProgress (0..1) fill the bar under the rows once it's held past a tap
        // (TAP_MS : let go before, it's a tap)
        const PAD_HOLD_MS = { focus_r: 500, focus_l: 500 };
        const TAP_MS = 200;
        this.padHold = null;
        this.padHoldProgress = 0;
        let held = null;
        let holdTick = null;
        const endHold = () => {
            $interval.cancel(holdTick);
            holdTick = null;
            held = null;
            this.padHold = null;
            this.padHoldProgress = 0;
        };
        const startHold = (name) => {
            endHold();
            const hold = { name, start: Date.now() };
            held = hold;
            holdTick = $interval(() => {
                // a tick already queued when the hold ended (seen in game : held was null)
                if (held !== hold) return;
                const elapsed = Date.now() - hold.start;
                const progress = Math.min(1, elapsed / PAD_HOLD_MS[name]);
                this.padHoldProgress = progress;
                this.padHold = elapsed >= TAP_MS ? (name === "focus_r" ? "confirm" : "cancel") : null;
                if (progress >= 1) {
                    const confirm = name === "focus_r";
                    endHold();
                    if (confirm) this.confirm();
                    else this.cancel();
                }
            }, 50);
        };
        this.holdFill = () => ({ width: `${Math.round(this.padHoldProgress * 100)}%` });

        const isRising = beamjoyDelivery.pressTracker();
        const offNav = $rootScope.$on("UINavigation", (_, name, value) => {
            const rising = isRising(name, value);
            const side = name === "focus_l" || name === "focus_r";
            // let go : a tap if it was pressed here (not the hold that opened the menu) and let go before
            // its bar showed ; a hold let go early does nothing
            if (side && Number(value) <= 0.5) {
                if (held && held.name === name) {
                    $scope.$applyAsync(() => {
                        const tap = this.padHold === null;
                        endHold();
                        if (tap && this.open) press(name, true);
                    });
                }
                return;
            }
            if (!this.open || !rising) return;
            $scope.$applyAsync(() => {
                if (side) startHold(name);
                else press(name, true);
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
            endHold();
            stopPlacing();
            window.removeEventListener("keydown", onKey, true);
            beamjoyDelivery.setNavOwner("pitControl", false);
        });
    },
});
