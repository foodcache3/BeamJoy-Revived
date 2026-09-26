// "Invite a player" for a race, hunter or infected lobby (the convoy has its own, same look).
// Lists everyone not in the lobby with whether they're free, busy in another activity or already
// invited ; Invite sends it (services/lobbyInvites.lua through beamjoy/notices.lua). The list
// refreshes after each invite. `onBack` closes the picker (the lobby's Back / pad B).
angular.module("beamjoy").component("bjLobbyInvite", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/lobbyInvite/app.html",
    bindings: {
        kind: "@",
        onBack: "&",
    },
    controller: function ($rootScope, $scope, $filter, $interval, beamjoyStore) {
        const translate = $filter("translate");
        this.players = null;
        const off = $rootScope.$on("BJLobbyInviteList", (_, data) => {
            if (!data || data.kind !== this.kind) return;
            this.players = Array.isArray(data.players) ? data.players : [];
        });
        // an unanswered invite lapses after 15 s (services/lobbyInvites.lua) : keep the list fresh
        const refresh = $interval(() => beamjoyStore.send("BJLobbyInviteList", [this.kind]), 3000);
        $scope.$on("$destroy", () => {
            off();
            $interval.cancel(refresh);
        });
        this.$onInit = () => beamjoyStore.send("BJLobbyInviteList", [this.kind]);

        this.status = (p) => {
            if (p.invited) return translate("beamjoy.delivery.lobby.inviteSent");
            if (p.busy) return translate("beamjoy.delivery.lobby.busy");
            return translate("beamjoy.delivery.lobby.free");
        };
        this.canInvite = (p) => !p.busy && !p.invited;
        this.invite = (p) => {
            if (this.canInvite(p)) beamjoyStore.send("BJLobbyInvite", [this.kind, p.playerID]);
        };
    },
});
