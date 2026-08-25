await import(`/ui/modModules/beamjoy/windows/main/races/paintPicker/app.js`);

angular.module("beamjoy").component("bjMainRaces", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/races/app.html",
    controller: function (
        $rootScope,
        $filter,
        $timeout,
        beamjoyStore,
        beamjoyInfoPanel,
        beamjoyConfirm
    ) {
        const translate = $filter("translate");
        this.RESPAWN_STRATEGIES = ["all", "norespawn", "lastcheckpoint", "stand"];
        // mirrors raceGrid.lua's own trySubmitTime gate exactly (all three must be enabled for a
        // time to count at all). Used here only to decide whether to warn before starting, not to
        // enforce anything; the server remains the real source of truth for that. Slow-mo/pause
        // isn't in this list: it's no longer a toggle at all, always forced off for every race, so
        // there's nothing to warn about for it.
        const ANTICHEAT_KEYS = [
            "disableNodegrabber", "disableCameras", "disableGravityChange",
        ];

        // shortcut for non-staff editors : previously the only way to reach the race editor was
        // digging through the Config window's own tab list by hand. hasAllPermissions is rank-
        // based (a group qualifies if its own rank sits at/above whatever rank EditRaces is
        // configured to require), so staff/owner naturally sees this too in any normal setup, not
        // just accounts explicitly granted EditRaces.
        this.canEditRaces = () =>
            beamjoyStore.permissions.hasAllPermissions(undefined, "EditRaces");
        this.openRaceEditor = (event) => {
            event.stopPropagation();
            // opens (idempotent, no-ops if already open) the Config window from here rather than
            // requiring the player to already have it open. The Races tab switch below works
            // regardless of the window's own visibility, so ordering between these two doesn't
            // matter
            beamjoyStore.send("BJRequestOpenWindow", ["config"]);
            $rootScope.$broadcast("BJOpenTab", "races");
        };

        // same shortcut, for vehicle pool presets shown alongside a race here (browse list summary,
        // start options' pool picker), per direct request: an edit button next to a preset for
        // whoever can actually manage them. Mirrors openRaceEditor exactly: lands on the Vehicle
        // Presets browse list (not a specific preset's own editor), same as clicking "Edit Races"
        // above doesn't drill into a specific race either. Keeps this a simple, low-risk shortcut
        // rather than needing to synchronize a specific-item-open request across two independently
        // mounted windows.
        this.canEditVehiclePresets = () =>
            beamjoyStore.permissions.hasAllPermissions(undefined, "EditVehiclePresets");
        this.openVehiclePresets = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRequestOpenWindow", ["config"]);
            $rootScope.$broadcast("BJOpenTab", "vehiclePresets");
        };

        // passive races aren't listed here: there's no ambient/drive-up discovery built yet, so
        // there'd be nothing meaningful for a "Start" button on one to actually do
        this.races = [];
        $rootScope.$on("BJEditorRaceList", (_, races) => {
            this.races = (races || []).filter((r) => r.mode === "grid");
        });
        this.sessions = [];
        $rootScope.$on("BJRaceOpenSessions", (_, sessions) => {
            this.sessions = sessions || [];
        });
        // shared vehicle pool presets (see services/vehiclePresets.lua), resolved here purely for
        // display (the race's own "pool" summary line, and the start-time preset dropdown below);
        // actual enforcement never reads this list, it always goes through the session/race data.
        // Real root cause of "the preset doesn't show up in the dropdown", confirmed via console
        // diagnostics: this used a native <select>, whose dropdown popup doesn't render in
        // BeamNG's off-screen-rendered CEF UI (see the matching comment in the race editor's own
        // app.js for the full explanation). bj-select (cmps/select) needs a {value, label}[] shape.
        this.vehiclePresets = [];
        this.vehiclePresetOptions = [];
        const rebuildVehiclePresetOptions = () => {
            this.vehiclePresetOptions = [
                { value: null, label: "beamjoy.window.config.tabs.races.vehicleRestriction.pool.select" },
                ...this.vehiclePresets.map((p) => ({ value: p.id, label: p.name })),
            ];
        };
        $rootScope.$on("BJVehiclePresetList", (_, presets) => {
            this.vehiclePresets = presets || [];
            rebuildVehiclePresetOptions();
        });
        this.presetById = (id) => this.vehiclePresets.find((p) => p.id === id);
        this.status = null;
        this.showPlayers = false;
        // whether the "Starting in Ns" lobby badge (vs. the plain "Lobby closes in Ns" hint) is
        // the right thing to show: gridReadySecondsLeft only actually completes once everyone's
        // ready (see raceGrid.lua's tryStartFromGrid), so showing it as an imminent-start promise
        // before that's true would be misleading
        this.allReady = false;
        $rootScope.$on("BJRaceSessionStatus", (_, status) => {
            this.status = status || null;
            if (!this.status) {
                this.showPlayers = false;
                this.showPaint = false;
            }
            this.allReady =
                !!this.status &&
                Array.isArray(this.status.participants) &&
                this.status.participants.length > 0 &&
                this.status.participants.every((p) => p.ready);
        });
        // pure non-participant spectating, entirely separate from this.status above (a spectator
        // was never a participant); driven by its own push (raceRunner.lua's pushSpectateStatus)
        this.spectateStatus = null;
        $rootScope.$on("BJRaceSpectateStatus", (_, status) => {
            this.spectateStatus = status || null;
        });
        // ticking countdown number, shown inline in the status panel once the session moves from
        // GRID to COUNTDOWN: the same broadcast the big centered countdown overlay already reacts
        // to (raceRunner.lua's updateCountdown, re-sent every time the whole-second value changes),
        // reused here rather than adding a second, separate countdown channel. "mode" also covers
        // the finished/dnf big-popup reuse of this same event (see bjRaceCountdown's own comment);
        // only treat it as a countdown tick when it's actually one.
        this.countdownSeconds = null;
        $rootScope.$on("BJRaceCountdown", (_, data) => {
            if (data.active && (!data.mode || data.mode === "countdown")) {
                this.countdownSeconds = data.seconds;
            } else if (!data.active) {
                this.countdownSeconds = null;
            }
        });
        this.togglePlayers = (event) => {
            event.stopPropagation();
            this.showPlayers = !this.showPlayers;
        };
        // streamlined in-lobby paint picker, shown for any single-config/pool vehicle-restricted
        // attempt. Collapsed by default, same reasoning the player list already collapses by
        // default: this is a narrow sidebar panel, not worth showing every optional section at once.
        this.showPaint = false;
        this.togglePaint = (event) => {
            event.stopPropagation();
            this.showPaint = !this.showPaint;
        };
        // the reusable info-panel framework's first consumer: "Live" shows every current
        // participant's best lap/sector splits (fastest-of-race highlighted), "Results" shows
        // final classification + a selected player's lap-by-lap breakdown once the race is over.
        // Both tabs independently request/listen for BJRaceInfo themselves (bj-tabs only ever
        // compiles the active tab, so there's no shared parent state to hand down here); this
        // just has to build the tabs array and open the panel.
        this.openRaceInfoPanel = (raceName, startTabId) => {
            beamjoyInfoPanel.open(raceName || "", [
                {
                    id: "live",
                    title: "beamjoy.window.main.tabs.races.raceInfo.live",
                    template: "<bj-race-info-live></bj-race-info-live>",
                },
                {
                    id: "results",
                    title: "beamjoy.window.main.tabs.races.raceInfo.results",
                    template: "<bj-race-info-results></bj-race-info-results>",
                },
            ], startTabId);
        };
        // per-race PB/record leaderboard, independent of any live session: opens for any race in
        // the browse list at any time, not just while it's actually running. race.id is baked into
        // the template string directly (a JS template literal, not {{}} interpolation) since the
        // tab content is compiled fresh with no access to this component's own scope/race object.
        this.openLeaderboard = (event, race) => {
            event.stopPropagation();
            beamjoyInfoPanel.open(race.name || "", [
                {
                    id: "leaderboard",
                    title: "beamjoy.window.main.tabs.races.leaderboard.title",
                    template: `<bj-race-leaderboard race-id="${race.id}"></bj-race-leaderboard>`,
                },
            ], "leaderboard");
        };
        this.openRaceInfo = (event) => {
            event.stopPropagation();
            this.openRaceInfoPanel(this.status ? this.status.raceName : "", "live");
        };
        // fired once, server-side, the moment the whole race (every participant, not just this
        // one) actually finishes: auto-surfaces the results instead of requiring a manual click.
        // Delayed a few seconds per direct request, since popping the panel open the INSTANT the
        // race ends collides visually with the "Finished!"/"DNF" popup that's also on screen right then.
        $rootScope.$on("BJRaceInfoAutoOpen", (_, data) => {
            $timeout(() => {
                this.openRaceInfoPanel(data && data.raceName, "results");
            }, 3000);
        });
        // real, confirmed bug: this used to show a hardcoded "not implemented yet" line
        // regardless of the actual session, a leftover from before vehicle restrictions existed
        // as a feature at all. Now reflects the CURRENT session's own effective restriction
        // (raceRunner.lua's pushSessionStatus, itself sourced from activeVehicleRestriction()).
        this.statusInfoText = () => {
            if (!this.status) return "";
            let vehicleLine;
            if (this.status.vehicleRestrictionMode === "single") {
                vehicleLine = `${translate("beamjoy.window.main.tabs.races.vehicleRestriction.required")} ${this.status.vehicleRestrictionLabel}`;
            } else if (this.status.vehicleRestrictionMode === "pool") {
                vehicleLine = `${translate("beamjoy.window.main.tabs.races.vehicleRestriction.pool")} ${this.status.vehicleRestrictionPoolLabel} (${this.status.vehicleRestrictionPoolCount})`;
            } else {
                vehicleLine = translate("beamjoy.window.main.tabs.races.noVehicleRestrictions");
            }
            return [
                `${translate("beamjoy.window.config.tabs.races.laps")}: ${this.status.laps || 1}`,
                `${translate("beamjoy.window.config.tabs.races.respawnStrategy")}: ${translate(
                    "beamjoy.window.config.tabs.races.respawnStrategies." +
                        this.status.respawnStrategy
                )}`,
                vehicleLine,
            ].join("\n");
        };

        this.$onInit = () => {
            beamjoyStore.send("BJEditorRaceListRequest");
            beamjoyStore.send("BJVehiclePresetListRequest");
            // bj-tabs destroys/recreates this component on every tab switch (see cmps/tabs/
            // app.html), and pushSessionStatus is only ever sent reactively on an actual session
            // update. With nobody else doing anything in the lobby meanwhile, a freshly remounted
            // tab had no way to learn it was still in a session, and looked like it had silently
            // left. Re-request the current status immediately, same pattern the race-info panel's
            // own BJRaceInfoRequest already uses.
            beamjoyStore.send("BJRaceSessionStatusRequest");
            // same remount gap, for the open/joinable sessions list : a session that started
            // while this tab was closed was otherwise invisible until some unrelated session
            // event (another join/leave) happened to trigger a fresh broadcast.
            beamjoyStore.send("BJRaceOpenSessionsRequest");
            beamjoyStore.send("BJRaceSpectateStatusRequest");
            // same remount gap, for the live countdown number : without this, a tab reopened
            // mid-countdown shows nothing until the next whole-second tick happens to fire
            beamjoyStore.send("BJRaceCountdownRequest");
        };

        // the start-options panel, open for at most one race at a time
        this.startingId = null;
        this.startOptions = null;
        this.openStart = (event, race) => {
            event.stopPropagation();
            this.startingId = race.id;
            // "Mandatory stop" only means anything if the race actually has a gate flagged for
            // it; offering it otherwise would just be a no-op option
            this.availableRespawnStrategies = this.RESPAWN_STRATEGIES.filter(
                (s) => s !== "stand" || race.hasStandGate
            );
            // seed from the race's own saved defaults (host-configurable per the plan; these
            // are just the starting point, not fixed), not generic hardcoded values
            const d = race.defaults || {};
            this.startOptions = {
                laps: d.laps || 3,
                respawnStrategy: d.respawnStrategy || "lastcheckpoint",
                // a single-slot race can never actually be joined by anyone else (raceStart
                // already forces this server-side too ; matched here so the panel doesn't seed a
                // now-hidden toggle to a stale "true" default)
                joinable: d.joinable === true && race.startPositions > 1,
                autoSpectateOnFinish: d.autoSpectateOnFinish !== false,
                countdown: d.countdown ?? 10,
                gridReadyTimeout: d.gridReadyTimeout ?? 10,
                gridTimeout: d.gridTimeout ?? 180,
                dnfEnabled: d.dnfEnabled !== false,
                dnfTimeout: d.dnfTimeout || 30,
                resetPenaltyEnabled: d.resetPenaltyEnabled === true,
                resetPenaltySeconds: d.resetPenaltySeconds || 5,
                disableNodegrabber: d.disableNodegrabber !== false,
                disableCameras: d.disableCameras !== false,
                disableGravityChange: d.disableGravityChange !== false,
                // default to honoring the race's own authored restriction when it has one,
                // otherwise there's nothing to default to but "free". The starter can always
                // switch to "single" (a fresh start-time capture) or back to "free" themselves
                vehicleRestrictionMode: race.vehicleRestrictionMode !== "free" ? "raceDefined" : "free",
                // only meaningful once the starter actually picks "pool" as their own start-time
                // choice (not "raceDefined"): seeded to the race's own preset (if it has one) as a
                // convenience starting point, same reasoning "raceDefined" itself already defaults to
                vehicleRestrictionPoolPresetId: race.vehicleRestrictionPoolPresetId || null,
                ghostOnCountdown: d.ghostOnCountdown !== false,
                disableCollisions: d.disableCollisions === true,
                ghostBackmarkers: d.ghostBackmarkers === true,
                showGateNametags: d.showGateNametags === true,
                limitVisibleGates: d.limitVisibleGates !== false,
                visibleGateCount: d.visibleGateCount || 2,
                // only meaningful while vehicleRestrictionMode above isn't "free"; see
                // BJRaceDefaults.allowTuning's own doc for what this actually gates
                allowTuning: d.allowTuning !== false,
            };
        };

        // per direct request: hovering the pool count (browse list and start-options panel
        // alike) shows every allowed vehicle, not just the bare number. Resolved through the
        // shared preset list (races only store a presetId reference now, see
        // services/vehiclePresets.lua), not an inline pool on the race itself anymore
        this.poolTooltip = (presetId) => {
            const preset = this.presetById(presetId);
            return preset ? preset.entries.map((v) => v.label).join("\n") : "";
        };
        this.poolLabel = (presetId) => {
            const preset = this.presetById(presetId);
            return preset ? preset.name : "?";
        };
        this.poolCount = (presetId) => {
            const preset = this.presetById(presetId);
            return preset ? preset.entries.length : 0;
        };

        this.formatDistance = (meters) => {
            if (typeof meters !== "number" || meters <= 0) return "-";
            return meters >= 1000
                ? `${(meters / 1000).toFixed(1)} km`
                : `${meters} m`;
        };
        this.cancelStart = (event) => {
            event.stopPropagation();
            this.startingId = null;
            this.startOptions = null;
        };
        this.confirmStart = (event, race) => {
            event.stopPropagation();
            const options = this.startOptions;
            const doStart = () => {
                beamjoyStore.send("BJRaceStart", [race.id, options]);
                this.startingId = null;
                this.startOptions = null;
            };
            // a cancelled confirm deliberately leaves the start panel open (startingId/startOptions
            // untouched) rather than closing it, so the player can just flip the option(s) back on
            // and try again without re-opening the panel from scratch. The vehicle restriction
            // start-mode choice only actually matters for a race that has an AUTHORED restriction
            // to begin with: picking anything other than "raceDefined" there means the race's own
            // design isn't being honored (raceGrid.lua's trySubmitTime gates on exactly this);
            // for a "free" race, no start-mode choice changes anything server-side, so it's not
            // worth warning about there either.
            // race.vehicleRestrictionMode truthy-checked, not just !== "free": defense in depth
            // against a race whose data predates this field entirely (undefined, not "free") being
            // misread as "has a restriction" and triggering this warning for every single start
            // regardless of the real anticheat toggle state. The actual bug is fixed at the
            // source (races.lua's loadData now backfills every race to a real "free" on load), but
            // this costs nothing and holds up even against stale client data mid-transition.
            const anticheatDisabled = ANTICHEAT_KEYS.some((k) => options[k] !== true) ||
                (!!race.vehicleRestrictionMode && race.vehicleRestrictionMode !== "free" &&
                    options.vehicleRestrictionMode !== "raceDefined");
            if (anticheatDisabled) {
                beamjoyConfirm.ask(
                    translate("beamjoy.window.main.tabs.races.confirmStartAnticheatWarning"),
                    doStart
                );
            } else {
                doStart();
            }
        };

        this.joinSession = (event, session) => {
            event.stopPropagation();
            beamjoyStore.send("BJRaceJoin", [session.id]);
        };
        this.spectateSession = (event, session) => {
            event.stopPropagation();
            beamjoyStore.send("BJRaceSpectate", [session.id]);
        };
        this.stopSpectating = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRaceStopSpectate");
        };

        this.setReady = (event, state) => {
            event.stopPropagation();
            beamjoyStore.send("BJRaceReady", [state]);
        };
        this.leaveSession = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRaceLeave");
        };
        // "retire and spectate": a voluntary DNF, distinct from Leave. Stays a tracked
        // participant (still sees the leaderboard/HUD) and auto-focuses another still-racing
        // player's vehicle, instead of exiting the session entirely like Leave does
        this.retire = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRaceRetire");
        };
        this.cancelSession = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRaceCancel");
        };
    },
});
