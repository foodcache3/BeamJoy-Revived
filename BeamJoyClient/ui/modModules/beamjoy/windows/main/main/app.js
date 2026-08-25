await import(`/ui/modModules/beamjoy/windows/main/main/players-list/app.js`);

angular.module("beamjoy").component("bjMainMain", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/main/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.openSettings = () => {
            $rootScope.$broadcast("BJOpenTab", "settings");
        };

        this.stateNametags = !beamjoyStore.settings.data.nametags.hideNameTags;
        this.toggleNametags = () => {
            this.stateNametags = !this.stateNametags;
            beamjoyStore.send("BJToggleNametagsHideState");
        };
        $rootScope.$on("BJNametagsState", (_, data) => {
            this.stateNametags = !data.hideNameTags;
        });

        // "Start Vote": a small in-place picker (choice -> map/player list), not a new modal
        // framework. This is the only place either vote type is startable from the UI (both
        // votes previously only had a chat-command front door, "/votemap <name>"/"/votekick
        // <name>"), so a lightweight inline panel is enough.
        this.canVoteMap = () => beamjoyStore.permissions.hasAllPermissions(undefined, "VoteMap");
        this.canVoteKick = () => beamjoyStore.permissions.hasAllPermissions(undefined, "VoteKick");
        this.canStartVote = () => this.canVoteMap() || this.canVoteKick();

        // null | "choice" | "map" | "kick"
        this.voteMenu = null;
        this.voteSearch = "";
        this.maps = [];

        this.toggleVoteMenu = () => {
            this.voteMenu = this.voteMenu ? null : "choice";
            this.voteSearch = "";
        };
        this.closeVoteMenu = () => {
            this.voteMenu = null;
            this.voteSearch = "";
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

        $rootScope.$on("BJSendMapsData", (_, data) => {
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
    },
});
