await import(`/ui/modModules/beamjoy/windows/config/races/editor/app.js`);

angular.module("beamjoy").component("bjConfigRaces", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/races/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyConfirm) {
        const translate = $filter("translate");

        // mirrors the server's own gate in services/races.lua's raceSave/raceDelete : while
        // RaceAuthorshipRestriction is on, staff can manage any race and everyone else only their
        // own ; while it's off (the default), anyone who can even see this list can manage any
        // race, same as before that restriction ever existed. Purely a UI convenience (hides the
        // Delete button, skips a round-trip to be told no) ; the server enforces this independently
        // regardless of what this returns.
        this.canManage = (race) =>
            !beamjoyStore.raceSettings.authorshipRestriction ||
            beamjoyStore.permissions.isStaff() ||
            race.author === beamjoyStore.players.self.playerName;

        this.races = [];
        $rootScope.$on("BJEditorRaceList", (_, races) => {
            let list = races || [];
            // host-configurable, default off (RaceEditorShowOnlyEditable) : trims the browse list
            // down to races this player can actually do something with, instead of listing every
            // race on the map regardless of who can touch it
            if (beamjoyStore.raceSettings.editorShowOnlyEditable) {
                list = list.filter((r) => this.canManage(r));
            }
            this.races = list;
        });
        this.$onInit = () => {
            beamjoyStore.send("BJEditorRaceListRequest");
        };

        // null = browsing the list ; "new" or an existing race's id = editor panel open
        this.editingId = null;
        this.openEditor = (id) => {
            this.editingId = id || "new";
        };
        this.closeEditor = () => {
            this.editingId = null;
        };
        $scope.$on("$destroy", () => {
            if (this.editingId !== null) {
                beamjoyStore.send("BJEditorRaceClose");
            }
        });

        this.deleteRace = (event, race) => {
            event.stopPropagation();
            beamjoyConfirm.ask(
                translate("beamjoy.window.config.tabs.races.confirmDelete").replace(
                    "{name}",
                    race.name
                ),
                () => beamjoyStore.send("BJDirectSend", ["raceDelete", race.id])
            );
        };

        this.formatDistance = (meters) => {
            if (typeof meters !== "number" || meters <= 0) return "-";
            return meters >= 1000
                ? `${(meters / 1000).toFixed(1)} km`
                : `${meters} m`;
        };
    },
});
