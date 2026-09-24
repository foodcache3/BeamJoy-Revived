angular.module("beamjoy").component("bjConfigGeneralFreeroam", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/general/freeroam/app.html",
    controller: function ($scope, beamjoyStore) {
        this.init = false;
        this.default = {};
        this.data = {
            CollisionsMode: "ghosts",
            RespawnGhostTimeoutEnabled: true,
            RespawnGhostTimeout: 10,
            RespawnGhostDistance: 0,
            StrictBusStops: false,
            PreserveFuelOnReset: false,
            EmergencyRefuelCooldown: 300,
        };
        // preserved verbatim on save : not editable from this accordion, but setConfig replaces
        // the whole Freeroam table at once, so it has to be sent back along with everything else
        this.teleportDelay = 30;

        // bj-select's own template translates opt.label itself (one-time {{::opt.label|translate}}
        // binding), so these are passed as raw locale keys here, not pre-translated text, same as every other
        // correctly-localized bj-select usage
        this.collisionsModeOptions = ["forced", "disabled", "ghosts"].map((value) => ({
            value,
            label: "beamjoy.window.config.tabs.general.freeroam.collisionsModes." + value,
        }));

        $scope.$watch(
            () => ({
                CollisionsMode: this.data.CollisionsMode,
                RespawnGhostTimeoutEnabled: this.data.RespawnGhostTimeoutEnabled,
                RespawnGhostTimeout: this.data.RespawnGhostTimeout,
                RespawnGhostDistance: this.data.RespawnGhostDistance,
                StrictBusStops: this.data.StrictBusStops,
                PreserveFuelOnReset: this.data.PreserveFuelOnReset,
                EmergencyRefuelCooldown: this.data.EmergencyRefuelCooldown,
            }),
            (current) => {
                if (!this.init) return;
                if (
                    current.CollisionsMode === this.default.CollisionsMode &&
                    current.RespawnGhostTimeoutEnabled === this.default.RespawnGhostTimeoutEnabled &&
                    current.RespawnGhostTimeout === this.default.RespawnGhostTimeout &&
                    current.RespawnGhostDistance === this.default.RespawnGhostDistance &&
                    current.StrictBusStops === this.default.StrictBusStops &&
                    current.PreserveFuelOnReset === this.default.PreserveFuelOnReset &&
                    current.EmergencyRefuelCooldown === this.default.EmergencyRefuelCooldown
                )
                    return;
                beamjoyStore.send("BJDirectSend", [
                    "setConfig",
                    "Freeroam",
                    {
                        TeleportDelay: this.teleportDelay,
                        CollisionsMode: current.CollisionsMode,
                        RespawnGhostTimeoutEnabled: current.RespawnGhostTimeoutEnabled,
                        // bj-slider's typable number-box can hand back a string in this CEF
                        // build (same recurring quirk already coerced around for gate width/
                        // height/sectorCount elsewhere), and sending one here fails the server's
                        // strict type(...) == "number" check and silently rejects this WHOLE
                        // Freeroam save, including CollisionsMode/RespawnGhostTimeoutEnabled
                        // bundled in the same call, which is what actually looked like "toggling
                        // those doesn't stick."
                        RespawnGhostTimeout: Number(current.RespawnGhostTimeout),
                        RespawnGhostDistance: Number(current.RespawnGhostDistance),
                        StrictBusStops: current.StrictBusStops,
                        PreserveFuelOnReset: current.PreserveFuelOnReset,
                        // same string-vs-number coercion note as RespawnGhostTimeout/Distance above
                        EmergencyRefuelCooldown: Number(current.EmergencyRefuelCooldown),
                    },
                ]);
            },
            true
        );
        // same BJSendConfigData broadcast the parent General tab's own top-level toggles read;
        // it already includes Freeroam (services/config.lua's onBJRequestCache), just picked out
        // here instead of duplicating the request
        $scope.$on("BJSendConfigData", (_, data) => {
            const freeroam = data.Freeroam || {};
            this.teleportDelay = freeroam.TeleportDelay ?? 30;
            this.data = {
                CollisionsMode: freeroam.CollisionsMode || "ghosts",
                RespawnGhostTimeoutEnabled: freeroam.RespawnGhostTimeoutEnabled !== false,
                RespawnGhostTimeout: freeroam.RespawnGhostTimeout ?? 10,
                RespawnGhostDistance: freeroam.RespawnGhostDistance ?? 0,
                StrictBusStops: freeroam.StrictBusStops === true,
                PreserveFuelOnReset: freeroam.PreserveFuelOnReset === true,
                EmergencyRefuelCooldown: freeroam.EmergencyRefuelCooldown ?? 300,
            };
            this.default = angular.copy(this.data);
            this.init = true;
        });
    },
});
