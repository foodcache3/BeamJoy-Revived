// Main window > Vote panel : start a map vote or a kick vote (moved out of the old main tab's
// inline picker). The only UI front door for either vote ; both also have chat commands.
angular.module("beamjoy").component("bjMainVote", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/vote/app.html",
    controller: function ($rootScope, $scope, beamjoyStore) {
        // "Start Vote": a small in-place picker (choice -> map/player list), not a new modal
        // framework. This is the only place either vote type is startable from the UI (both
        // votes previously only had a chat-command front door, "/votemap <name>"/"/votekick
        // <name>"), so a lightweight inline panel is enough.
        this.canVoteMap = () => beamjoyStore.permissions.hasAllPermissions(undefined, "VoteMap");
        this.canVoteKick = () => beamjoyStore.permissions.hasAllPermissions(undefined, "VoteKick");
        this.canStartVote = () => this.canVoteMap() || this.canVoteKick();

        // "choice" | "map" | "kick"
        this.voteMenu = "choice";
        this.voteSearch = "";
        this.maps = [];

        this.closeVoteMenu = () => {
            this.voteMenu = "choice";
            this.voteSearch = "";
            $rootScope.$broadcast("BJMainOpenPanel", null);
        };
        this.chooseMapVote = () => {
            this.voteMenu = "map";
            this.voteSearch = "";
            beamjoyStore.send("BJRequestMapsData");
        };
        this.chooseKickVote = () => {
            this.voteMenu = "kick";
            this.voteSearch = "";
        };
        this.backToChoice = () => {
            this.voteMenu = "choice";
            this.voteSearch = "";
        };

        const offMaps = $rootScope.$on("BJSendMapsData", (_, data) => {
            this.maps = Object.entries(data || {})
                .map(([name, map]) => ({ name, label: map.label }))
                .sort((a, b) => a.label.localeCompare(b.label));
        });

        this.kickTargets = () =>
            beamjoyStore.players.players.filter(
                (p) => p.playerName !== beamjoyStore.players.self.playerName
            );

        this.startMapVote = (map) => {
            beamjoyStore.send("BJMapVoteStart", [map.name]);
            this.closeVoteMenu();
        };
        this.startKickVote = (player) => {
            beamjoyStore.send("BJKickVoteStart", [player.playerID]);
            this.closeVoteMenu();
        };
        $scope.$on("$destroy", offMaps);
    },
});
