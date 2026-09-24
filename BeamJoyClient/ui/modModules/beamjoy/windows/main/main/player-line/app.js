angular.module("beamjoy").component("bjPlayerLine", {
    bindings: {
        player: "<",
    },
    templateUrl:
        "/ui/modModules/beamjoy/windows/main/main/player-line/app.html",
    controller: function ($scope, beamjoyStore, $filter) {
        const translate = $filter("translate");

        this.actions = {};
        this.groupLabel = "";
        const updatePlayer = () => {
            this.actions = {};
            const self = beamjoyStore.players.self;

            let canFocus = true;
            let currentVehicleOwner = this.player.currentVehicle
                ? beamjoyStore.players.players.find((p) => {
                      return (
                          Array.isArray(p.vehicles) &&
                          p.vehicles.some(
                              (v) => v.vid === this.player.currentVehicle
                          )
                      );
                  })
                : null;
            currentVehicleOwner = currentVehicleOwner ? currentVehicleOwner.playerName : null;
            if (!this.player.currentVehicle) {
                // no current vehicle
                canFocus = false;
            } else if (!currentVehicleOwner) {
                // vehicle is not registered yet or invalid
                canFocus = false;
            } else if (
                self.playerName === this.player.playerName &&
                currentVehicleOwner === self.playerName
            ) {
                // self and the current vehicle is mine
                canFocus = false;
            } else if (
                self.playerName !== this.player.playerName &&
                self.currentVehicle === this.player.currentVehicle
            ) {
                // not self and the current vehicle is my current one
                canFocus = false;
            } else if (this.player.replay) {
                // player is in replay mode
                canFocus = false;
            }
            this.actions.focus = canFocus;

            const isSelf = self.playerName === this.player.playerName;

            const selfGroupIndex = beamjoyStore.groups.getGroupIndex(
                self.group
            );
            const selfGroup =
                typeof selfGroupIndex === "number"
                    ? beamjoyStore.groups.data[selfGroupIndex]
                    : null;
            const groupIndex = beamjoyStore.groups.getGroupIndex(
                this.player.group
            );
            const group =
                typeof groupIndex === "number"
                    ? beamjoyStore.groups.data[groupIndex]
                    : null;

            if (selfGroup && selfGroup.staff && selfGroupIndex > groupIndex) {
                this.actions.freeze = true;
                this.actions.engine = true;
                if (this.player.vehicles.length > 0) this.actions.delete = true;
            }
            // Unlike freeze/engine/delete, not permission-gated at all: restoring a player's own
            // deleted vehicle isn't a punitive/administrative action against them, just a local,
            // harmless request-respawn (restorePlayerVehicle is a no-op if there's nothing deleted
            // to bring back), so every player can use it on anyone, staff or not. Only shown for a
            // player that actually has something to restore (players.deletedVehiclePlayers, pushed
            // client-locally by players.lua - see its own doc comment for why this can't come from
            // the server like every other player-list field) - and never on yourself, since a
            // player already has their own native UI/keybind for their own vehicles.
            if (!isSelf && beamjoyStore.players.deletedVehiclePlayers[this.player.playerName]) {
                this.actions.restore = true;
            }

            if (
                !isSelf &&
                this.player.currentVehicle &&
                beamjoyStore.permissions.hasAllPermissions(null, "TeleportTo")
            ) {
                this.actions.teleportTo = true;
            }
            if (
                !isSelf &&
                this.player.currentVehicle &&
                self.currentVehicle !== this.player.currentVehicle &&
                beamjoyStore.permissions.hasAllPermissions(null, "TeleportFrom")
            ) {
                this.actions.teleportFrom = true;
            }

            if (group && selfGroup && group.staff && !selfGroup.staff) {
                this.groupLabel = translate("beamjoy.groups.staffMark");
            } else {
                const key = "beamjoy.groups." + this.player.group;
                this.groupLabel = translate(key);
                if (this.groupLabel === key) {
                    // custom group
                    this.groupLabel = this.player.group;
                }
            }
        };
        updatePlayer();
        $scope.$watch(() => this.player, updatePlayer, true);
        $scope.$watch(() => beamjoyStore.players.self, updatePlayer, true);
        $scope.$watch(() => beamjoyStore.players.deletedVehiclePlayers, updatePlayer, true);

        this.action = (evt, action) => {
            evt.stopPropagation();
            if (this.actions[action]) {
                beamjoyStore.send("BJPlayerAction", [
                    this.player.playerName,
                    action,
                ]);
            }
        };
    },
});
