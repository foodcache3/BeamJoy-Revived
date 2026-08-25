angular.module("beamjoy").component("bjVehicleLine", {
    bindings: {
        vehicle: "<",
        owner: "<",
    },
    templateUrl:
        "/ui/modModules/beamjoy/windows/main/main/vehicle-line/app.html",
    controller: function ($rootScope, $scope, beamjoyStore) {
        this.actions = {};
        const updateActions = () => {
            this.actions = {
                focus: false,
            };

            if (beamjoyStore.players.self.currentVehicle !== this.vehicle.vid) {
                this.actions.focus = true;
            }

            const selfGroup = beamjoyStore.groups.getGroup(
                beamjoyStore.players.self.group
            );
            if (selfGroup && selfGroup.staff) {
                this.actions.freeze = true;
                this.actions.engine = true;
                this.actions.delete = true;
                this.actions.explode = true;
                this.actions.launch = true;
            }
        };
        updateActions();
        $scope.$watch(() => this.vehicle, updateActions, true);
        $scope.$watch(() => this.owner, updateActions, true);
        $scope.$watch(() => beamjoyStore.players.self, updateActions, true);

        this.action = (evt, action) => {
            evt.preventDefault();
            if (this.actions[action]) {
                beamjoyStore.send("BJVehicleAction", [
                    this.owner.playerName,
                    this.vehicle.vid,
                    action,
                ]);
            }
        };
    },
});
