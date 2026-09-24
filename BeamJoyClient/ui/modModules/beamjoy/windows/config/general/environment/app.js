angular.module("beamjoy").component("bjConfigGeneralEnvironment", {
    templateUrl:
        "/ui/modModules/beamjoy/windows/config/general/environment/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.data = {
            timeSync: false,
            gravitySync: false,
            nightScale: 2,
        };
        this.default = {};
        // read-only inputs to the full-cycle readout and slider range, kept out of `data` so they
        // never count toward the dirty/save state (all computed Lua-side by envClock, the same
        // shared math the synced clock itself runs on - dayLength comes from the vanilla panel)
        this.dayLength = 1800;
        this.dayScale = 1;
        this.dayFraction = 0.5;
        this.nightScaleMin = 0.1;
        this.nightScaleMax = 10;
        this.cycle = null;
        this.init = false;
        this.dirty = false;
        const updateDirty = () => {
            this.dirty = !angular.equals(this.data, this.default);
        };

        // "1h 05m", "22m 30s", "45s"
        const formatDuration = (totalSec) => {
            totalSec = Math.round(totalSec);
            const h = Math.floor(totalSec / 3600);
            const m = Math.floor((totalSec % 3600) / 60);
            const s = totalSec % 60;
            if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`;
            if (m > 0) return s > 0 ? `${m}m ${String(s).padStart(2, "0")}s` : `${m}m`;
            return `${s}s`;
        };
        // Mirrors envClock.advance (lua/envClock.lua, shared with the server): the day part of the
        // cycle (real sunrise to sunset, `dayFraction` of it) runs at dayLength / dayScale, the
        // night part at dayLength / nightScale. The vanilla panel's own "day length" is the full
        // cycle at 1x for both, so it stops matching once night speed != 1x - this is the real
        // length players will actually see (at normal simulation speed). The slider's own range
        // already keeps nightScale within what the game's day length bounds allow (see
        // envClock.scaleBounds), so no further clamping is needed here.
        const updateCycle = () => {
            const dayLength = Number(this.dayLength);
            const dayScale = Number(this.dayScale) || 1;
            const nightScale = Number(this.data.nightScale);
            const dayFraction = Math.min(1, Math.max(0, Number(this.dayFraction)));
            if (!(dayLength > 0) || !(nightScale > 0) || Number.isNaN(dayFraction)) {
                this.cycle = null;
                return;
            }
            const day = (dayLength * dayFraction) / dayScale;
            const night = (dayLength * (1 - dayFraction)) / nightScale;
            this.cycle = {
                total: formatDuration(day + night),
                day: formatDuration(day),
                night: formatDuration(night),
            };
        };

        $rootScope.$watch(
            () => this.data,
            () => {
                if (this.init) {
                    updateDirty();
                }
                updateCycle();
            },
            true
        );

        $rootScope.$on("BJEnvironment", (_, payload) => {
            this.dayLength = payload.dayLength ?? 1800;
            this.dayScale = payload.dayScale ?? 1;
            this.dayFraction = payload.dayFraction ?? 0.5;
            this.nightScaleMin = payload.nightScaleMin ?? 0.1;
            this.nightScaleMax = payload.nightScaleMax ?? 10;
            // shown (and saved) as the value actually in effect: at a short day length a stored
            // night speed above what the game's 5-minute minimum allows is limited to it anyway.
            // Clamped here, not left to bj-slider's own clamp, which would otherwise rewrite the
            // model after load and make the panel look unsaved before anything was touched.
            const nightScale = Math.min(this.nightScaleMax,
                Math.max(this.nightScaleMin, Number(payload.nightScale ?? 2)));
            this.default = {
                timeSync: payload.timeSync,
                gravitySync: payload.gravitySync,
                nightScale: Math.round(nightScale * 10) / 10,
            };
            if (!this.dirty) {
                this.data = angular.copy(this.default);
            }
            updateDirty();
            updateCycle();
            this.init = true;
        });
        this.$onInit = () => beamjoyStore.send("BJRequestEnv");

        this.openSettings = () => {
            // "menu.environment" was BeamNG's pre-0.39 environment settings route (legacy
            // Angular state, ui/modules/environment/environment.html). 0.39 moved the real
            // environment panel to its new ui-vue-based Pause menu, under "pause.environment"
            // (see ui-vue/src/modules/pause/routes.js) - "menu.environment" is now dead in the
            // new unified router, but the OLD Angular state definition for it is still
            // registered too, so it fell back to rendering that vestigial old panel instead.
            //
            // Under "pause.environment", "pause.environment.simulation" (label
            // ui.pause.environment.simulation) is the gravity/sim-speed/tire-marks tab, NOT
            // this one - the actual Time Of Day + Weather tab is the sibling route
            // "pause.environment.weather" (label ui.pause.environment.timeWeather).
            $rootScope.$broadcast("ChangeState", {
                state: "pause.environment.weather",
            });
        };

        this.save = () => {
            beamjoyStore.send("BJSetEnvironment", [
                {
                    timeSync: this.data.timeSync,
                    gravitySync: this.data.gravitySync,
                    nightScale: this.data.nightScale,
                },
            ]);
            this.dirty = false;
        };
        this.cancel = () => {
            this.data = angular.copy(this.default);
            updateDirty();
        };
    },
});
