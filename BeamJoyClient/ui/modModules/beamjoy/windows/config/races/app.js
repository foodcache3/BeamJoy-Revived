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

        // every race this player may see, as pushed ; `shown` is that put through the search box,
        // the filter and the sort below. Kept as a field rather than worked out in the template so
        // the repeat isn't rebuilding a list on every digest, the same way the race picker in the
        // main window does it (windows/main/races) - which is also where this toolbar's shape,
        // its search toggle and its sort cycle come from, deliberately: the two lists of races a
        // player meets should not behave differently.
        this.races = [];
        this.shown = [];
        this.search = "";
        this.searchOpen = false;
        // what a race can be narrowed down to. Every one of these reads a field the summary
        // actually carries (beamjoy/races.lua's pushListToUI) - a filter on a field that isn't
        // there matches nothing and looks like the races vanished.
        this.FILTERS = [
            { value: "all", label: "beamjoy.window.config.tabs.races.filters.all" },
            { value: "mine", label: "beamjoy.window.config.tabs.races.filters.mine" },
            { value: "grid", label: "beamjoy.window.config.tabs.races.filters.grid" },
            { value: "passive", label: "beamjoy.window.config.tabs.races.filters.passive" },
            { value: "loopable", label: "beamjoy.window.config.tabs.races.filters.loopable" },
            { value: "freeroam", label: "beamjoy.window.config.tabs.races.filters.freeroam" },
            { value: "pits", label: "beamjoy.window.config.tabs.races.filters.pits" },
            { value: "props", label: "beamjoy.window.config.tabs.races.filters.props" },
            { value: "times", label: "beamjoy.window.config.tabs.races.filters.times" },
        ];
        this.filter = "all";
        const MATCHES = {
            all: () => true,
            mine: (r) => r.author === beamjoyStore.players.self.playerName,
            grid: (r) => r.mode === "grid",
            passive: (r) => r.mode === "passive",
            loopable: (r) => r.loopable === true,
            freeroam: (r) => r.freeroam === true,
            pits: (r) => r.pits === true,
            props: (r) => (r.props || 0) > 0,
            times: (r) => (r.leaderboardCount || 0) > 0,
        };
        // "name" A to Z, "newest" / "oldest" by when the race was made : there's no authored date
        // on a race, but ids are handed out in order (services/races.lua), so the id IS that order
        this.SORTS = ["name", "newest", "oldest"];
        this.sort = "name";
        const applyList = () => {
            const needle = (this.search || "").trim().toLowerCase();
            const matches = MATCHES[this.filter] || MATCHES.all;
            const list = (this.races || []).filter(
                (r) =>
                    matches(r) &&
                    (!needle ||
                        (r.name || "").toLowerCase().includes(needle) ||
                        (r.author || "").toLowerCase().includes(needle))
            );
            list.sort((a, b) =>
                this.sort === "name"
                    ? (a.name || "").localeCompare(b.name || "", undefined, { sensitivity: "base" })
                    : this.sort === "oldest"
                        ? (a.id || 0) - (b.id || 0)
                        : (b.id || 0) - (a.id || 0)
            );
            this.shown = list;
        };
        this.refreshList = applyList;
        this.toggleSearch = (event) => {
            event.stopPropagation();
            this.searchOpen = !this.searchOpen;
            // closing it clears what it was filtering by : a hidden box still narrowing the list
            // reads as races having gone missing
            if (!this.searchOpen && this.search) this.search = "";
            applyList();
        };
        this.cycleSort = (event) => {
            event.stopPropagation();
            this.sort = this.SORTS[(this.SORTS.indexOf(this.sort) + 1) % this.SORTS.length];
            applyList();
        };
        this.sortLabel = () =>
            translate("beamjoy.window.config.tabs.races.sorts." + this.sort);
        // nothing matched, as against nothing on the map at all : two different things to say
        this.narrowed = () => (this.search || "").trim() !== "" || this.filter !== "all";

        $rootScope.$on("BJEditorRaceList", (_, races) => {
            let list = races || [];
            // host-configurable, default off (RaceEditorShowOnlyEditable) : trims the browse list
            // down to races this player can actually do something with, instead of listing every
            // race on the map regardless of who can touch it
            if (beamjoyStore.raceSettings.editorShowOnlyEditable) {
                list = list.filter((r) => this.canManage(r));
            }
            this.races = list;
            applyList();
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

        // the races this map comes with (its time trials and quickraces), read and converted by
        // beamjoy/mapRaces.lua : a checklist of them, the ticked ones are added as new races
        this.mapScanning = false;
        this.importMapRaces = (event) => {
            event.stopPropagation();
            this.mapScanning = true;
            beamjoyStore.send("BJMapRacesScanRequest");
        };
        $rootScope.$on("BJMapRacesScan", (_, result) => {
            this.mapScanning = false;
            const rows = (result && Array.isArray(result.rows)) ? result.rows : [];
            if (rows.length === 0) {
                beamjoyConfirm.info(translate(result && result.error
                    ? "beamjoy.mapRaces.failed" : "beamjoy.mapRaces.none"));
                return;
            }
            // what the ticked races bring (direct request) : everything, their gates and grid only, or
            // only their props, added to the races of the same name this server already has
            const usable = (mode) => rows.some((r) => {
                const own = r.modes && r.modes[mode];
                return !(own && own.disabled !== undefined ? own.disabled : r.disabled);
            });
            const modes = ["all", "gates", "props"].map((key) => ({
                key,
                label: translate(`beamjoy.mapRaces.mode.${key}`),
                hint: translate(`beamjoy.mapRaces.mode.${key}.hint`),
            }));
            const first = modes.find((m) => usable(m.key));
            if (!first) {
                beamjoyConfirm.info(
                    `${translate("beamjoy.mapRaces.noneImportable")}\n\n` +
                        rows.map((r) => `${r.label} (${r.tag})`).join("\n")
                );
                return;
            }
            beamjoyConfirm.askChecklist(
                translate("beamjoy.mapRaces.pick"),
                rows,
                (keys, mode) => beamjoyStore.send("BJMapRacesImport", [keys, mode || "all"]),
                undefined,
                { modes, mode: first.key }
            );
        });

        this.formatDistance = (meters) => {
            if (typeof meters !== "number" || meters <= 0) return "-";
            return meters >= 1000
                ? `${(meters / 1000).toFixed(1)} km`
                : `${meters} m`;
        };
    },
});
