await import(`/ui/modModules/beamjoy/windows/main/main/player-line/app.js`);
await import(
    `/ui/modModules/beamjoy/windows/main/main/player-moderation/app.js`
);
await import(`/ui/modModules/beamjoy/windows/main/main/vehicle-line/app.js`);

// The player list, as expandable rows : name and rank, the car they're in, and on expanding,
// their actions (bj-player-line), their vehicles for staff (bj-vehicle-line) and moderation.
// `full` is set in the full window, which also shows the staff buttons acting on all of a
// player's vehicles at once.
angular.module("beamjoy").component("bjPlayersList", {
    bindings: {
        full: "<",
    },
    templateUrl:
        "/ui/modModules/beamjoy/windows/main/main/players-list/app.html",
    controller: function ($rootScope, $scope, beamjoyStore, $filter) {
        const translate = $filter("translate");
        this.players = [];
        // the one expanded row, by playerName (kept across list refreshes) : opening another
        // closes it
        this.expanded = {};
        this.toggle = (player) => {
            const open = !this.expanded[player.playerName];
            this.expanded = {};
            if (open) this.expanded[player.playerName] = true;
        };
        this.moderationInputs = {};

        this.updateList = () => {
            if (beamjoyStore.groups.data.length == 0) return;
            if (beamjoyStore.players.players.length == 0) return;
            if (beamjoyStore.players.self.playerName.length == 0) return;

            const selfGroupIndex = beamjoyStore.groups.getGroupIndex(
                beamjoyStore.players.self.group
            );
            const selfStaff = beamjoyStore.permissions.isStaff();
            const canModerate =
                selfStaff ||
                beamjoyStore.permissions.hasAnyPermission(
                    null,
                    beamjoyStore.permissions.PERMISSIONS.Mute,
                    beamjoyStore.permissions.PERMISSIONS.Kick,
                    beamjoyStore.permissions.PERMISSIONS.Ban,
                    beamjoyStore.permissions.PERMISSIONS.TempBan
                );
            this.players = beamjoyStore.players.players.map((p) => {
                const playerGroupIndex = beamjoyStore.groups.getGroupIndex(
                    p.group
                );
                if (!this.moderationInputs[p.playerName]) {
                    this.moderationInputs[p.playerName] = {
                        kickReason: "",
                        banReason: "",
                        tempBanDuration: 300,
                        muteReason: "",
                    };
                }

                // prettier-ignore
                const res = Object.assign(
                    {
                        showModeration:
                            selfGroupIndex > playerGroupIndex &&
                            canModerate,
                        showVehicles:
                            selfStaff &&
                            Object.keys(p.vehicles).length > 0 &&
                            (selfGroupIndex > playerGroupIndex ||
                                p.playerID ==
                                    beamjoyStore.players.self.playerID),
                    }, p);
                res.vehicles = Object.values(p.vehicles).filter((v) => !v.isAi);
                res.isSelf = p.playerName === beamjoyStore.players.self.playerName;
                const current = Object.values(p.vehicles).find((v) => v.vid === p.currentVehicle);
                res.currentLabel = current ? current.label : "";
                // staff show as "staff" to non-staff, their real rank otherwise ; custom groups
                // have no translation and show their own name
                const group = beamjoyStore.groups.getGroup(p.group);
                if (group && group.staff && !selfStaff) {
                    res.rankLabel = translate("beamjoy.groups.staffMark");
                } else {
                    const key = "beamjoy.groups." + p.group;
                    res.rankLabel = translate(key);
                    if (res.rankLabel === key) res.rankLabel = p.group;
                }
                const countTraffic = Object.values(p.vehicles).filter(
                    (v) => v.isAi
                ).length;
                if (res.vehicles.length + countTraffic > 0) {
                    const parts = [];
                    if (res.vehicles.length > 0) {
                        parts.push(String(res.vehicles.length));
                    }
                    if (countTraffic > 0) {
                        parts.push(
                            translate(
                                "beamjoy.window.main.playerlist.vehicles.trafficCount"
                            ).replace("{count}", countTraffic)
                        );
                    }
                    res.vehicleInfo = `(${parts.join(" + ")})`;
                }
                return res;
            });
        };
        this.updateList();
        [
            "BJUpdatePlayers",
            "BJUpdatePlayer",
            "BJUpdateGroups",
            "BJUpdateSelf",
        ].forEach((event) => {
            $scope.$on("$destroy", $rootScope.$on(event, this.updateList));
        });
    },
});
