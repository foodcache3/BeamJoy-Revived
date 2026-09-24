angular.module("beamjoy").component("bjConfigGeneralEnvironment", {
    templateUrl:
        "/ui/modModules/beamjoy/windows/config/general/environment/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.data = {
            timeSync: false,
            gravitySync: false,
        };
        this.default = {};
        this.init = false;
        this.dirty = false;
        const updateDirty = () => {
            this.dirty = !angular.equals(this.data, this.default);
        };
        $rootScope.$watch(
            () => this.data,
            () => {
                if (this.init) {
                    updateDirty();
                }
            },
            true
        );

        $rootScope.$on("BJEnvironment", (_, payload) => {
            this.default = {
                timeSync: payload.timeSync,
                gravitySync: payload.gravitySync,
            };
            if (!this.dirty) {
                this.data = angular.copy(this.default);
            }
            updateDirty();
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
