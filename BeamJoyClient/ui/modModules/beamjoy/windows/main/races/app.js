await import(`/ui/modModules/beamjoy/windows/main/races/paintPicker/app.js`);

angular.module("beamjoy").component("bjMainRaces", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/races/app.html",
    controller: function (
        $rootScope,
        $filter,
        $timeout,
        beamjoyStore,
        beamjoyInfoPanel,
        beamjoyConfirm,
        $scope,
        beamjoyNow
    ) {
        const translate = $filter("translate");
        this.RESPAWN_STRATEGIES = ["all", "norespawn", "lastcheckpoint", "flipupright", "lastroad"];
        // what a reset costs : the car held for the penalty, or the penalty added to the race time
        this.RESET_PENALTY_MODES = ["hold", "time"];
        // mirrors races.lua's PLACEMENT_MODES: how grid slots get assigned at countdown time
        // ("deterministic" = lobby join order, "random" = shuffled, "manual" = host-assigned)
        this.PLACEMENT_MODES = ["deterministic", "random", "manual"];
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
        // a race marker's "Open race" in the world (lua beamjoy/races.lua) : that race's start form
        const openPendingStart = () => {
            const pending = beamjoyStore.pendingActivityStart;
            if (!pending || pending.kind !== "race") return;
            const race = this.races.find((r) => r.id === pending.id);
            if (!race) return;
            beamjoyStore.pendingActivityStart = null;
            if (this.startingId !== race.id) this.openStart({ stopPropagation: () => {} }, race);
        };
        // Real bug: this listener was never removed, so every earlier copy of this component (the
        // section is rebuilt on each open, the side panel and the full window each have one) kept
        // receiving the list. The oldest leftover got it first and used up a marker's "Open race"
        // request, leaving the copy on screen with nothing : it worked the first time only
        $scope.$on("$destroy", $rootScope.$on("BJEditorRaceList", (_, races) => {
            this.races = (races || []).filter((r) => r.mode === "grid");
            openPendingStart();
        }));
        $scope.$on("$destroy", $rootScope.$on("BJOpenActivityStart", openPendingStart));
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
            // Real bug: Lua can't distinguish an empty table from an empty object, so an
            // emptied-out preset list can arrive as `{}` instead of `[]` - truthy, so `presets ||
            // []` kept it as-is, and `{}.map`/`{}.find` isn't a function. Same fix already
            // established elsewhere in this codebase (see cmps/pointListEditor/app.js's own
            // listsUpdate handler).
            this.vehiclePresets = Array.isArray(presets) ? presets : [];
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
            // "manual" placement: the host's per-player slot dropdown, one option per grid slot.
            // bj-select needs a {value, label}[] shape (same CEF native-<select> limitation as
            // the vehicle preset dropdown above). The list itself is also kept sorted by slot so
            // it reads top-to-bottom as the actual grid order being built
            this.gridSlotOptions = [];
            if (this.status && this.status.placementMode === "manual") {
                for (let slot = 1; slot <= (this.status.maxParticipants || 0); slot++) {
                    this.gridSlotOptions.push({ value: slot, label: `${slot}` });
                }
                if (Array.isArray(this.status.participants)) {
                    // 9999 (not Infinity) as the "no slot" sink: Infinity - Infinity is NaN,
                    // which a sort comparator must never return
                    this.status.participants.sort(
                        (a, b) => (a.gridSlot || 9999) - (b.gridSlot || 9999)
                    );
                }
            }
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

        // the start-options panel, open for at most one race at a time. Kept in beamjoyNow while
        // it's open, so switching between the side panel and the full window (each mounts its
        // own copy of this component) doesn't lose what you were setting up
        const draft = beamjoyNow.raceDraft;
        this.startingId = draft ? draft.startingId : null;
        this.startOptions = draft ? draft.startOptions : null;
        // the same form, opened from the lobby by its leader to change the settings
        this.editing = draft ? !!draft.editing : false;
        $scope.$watch(
            () => this.startingId,
            () => {
                if (!this.startingId) this.editing = false;
                beamjoyNow.raceDraft = this.startingId
                    ? { startingId: this.startingId, startOptions: this.startOptions, showAdvanced: this.showAdvanced, editing: this.editing }
                    : null;
            }
        );
        this.openStart = (event, race) => {
            event.stopPropagation();
            this.startingId = race.id;
            this.editing = false;
            this.showAdvanced = false;
            // seed from the race's own saved defaults (host-configurable per the plan; these
            // are just the starting point, not fixed), not generic hardcoded values
            const d = race.defaults || {};
            this.startOptions = {
                laps: d.laps || 3,
                respawnStrategy: d.respawnStrategy || "lastcheckpoint",
                placementMode: this.PLACEMENT_MODES.includes(d.placementMode)
                    ? d.placementMode
                    : "random",
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
                rejoinGraceMinutes: d.rejoinGraceMinutes ?? 10,
                resetPenaltyEnabled: d.resetPenaltyEnabled === true,
                resetPenaltySeconds: d.resetPenaltySeconds || 5,
                resetPenaltyMode: d.resetPenaltyMode === "time" ? "time" : "hold",
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
                waypointBeams: d.waypointBeams !== false,
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

        // CHANGE SETTINGS : the leader reopens the start form on the open lobby, filled with what
        // it runs now. Saving sends everyone back to not ready (services/raceGrid.lua)
        this.canEditSettings = () =>
            !!this.status && this.status.isStarter && this.status.state === "GRID" && !!this.status.startOptions &&
            this.races.some((r) => r.id === this.status.raceId);
        this.openEdit = (event) => {
            const race = this.races.find((r) => this.status && r.id === this.status.raceId);
            if (!race) return;
            this.openStart(event, race);
            Object.assign(this.startOptions, this.status.startOptions);
            this.editing = true;
            if (beamjoyNow.raceDraft) beamjoyNow.raceDraft.editing = true;
        };
        this.saveEdit = (event, race) => {
            event.stopPropagation();
            if (this.startBlocked()) return;
            const options = this.startOptions;
            const doSave = () => {
                beamjoyStore.send("BJRaceUpdateSettings", [options]);
                this.startingId = null;
                this.startOptions = null;
            };
            const anticheatDisabled = ANTICHEAT_KEYS.some((k) => options[k] !== true) ||
                (!!race.vehicleRestrictionMode && race.vehicleRestrictionMode !== "free" &&
                    options.vehicleRestrictionMode !== "raceDefined");
            if (anticheatDisabled) {
                beamjoyConfirm.ask(translate("beamjoy.window.main.tabs.races.confirmStartAnticheatWarning"), doSave);
            } else {
                doSave();
            }
        };
        // the lobby started or closed while the leader was still editing : drop the form
        $scope.$watch(
            () => this.editing && (!this.status || this.status.state !== "GRID"),
            (gone) => {
                if (gone) {
                    this.startingId = null;
                    this.startOptions = null;
                }
            }
        );

        // redesigned start : laps / vehicles / respawns up front, everything else folded under
        // Advanced settings ; two ways to go instead of a "joinable" toggle, X starts alone and A
        // opens a lobby others can join (a one-slot race only has the solo start)
        this.showAdvanced = draft ? draft.showAdvanced : false;
        this.toggleAdvanced = () => {
            this.showAdvanced = !this.showAdvanced;
            if (beamjoyNow.raceDraft) beamjoyNow.raceDraft.showAdvanced = this.showAdvanced;
        };
        this.startSolo = (event, race) => {
            this.startOptions.joinable = false;
            this.startOptions.private = false;
            this.confirmStart(event, race);
        };
        this.startLobby = (event, race) => {
            if (race.startPositions <= 1) return this.startSolo(event, race);
            this.startOptions.joinable = true;
            this.startOptions.private = false;
            this.confirmStart(event, race);
        };
        // a private lobby : invite only, never listed or announced ; while nobody else is in it,
        // it starts like a solo run as soon as you're ready (services/raceGrid.lua)
        this.startPrivate = (event, race) => {
            if (race.startPositions <= 1) return this.startSolo(event, race);
            this.startOptions.joinable = true;
            this.startOptions.private = true;
            this.confirmStart(event, race);
        };
        this.startBlocked = () =>
            !!this.startOptions &&
            this.startOptions.vehicleRestrictionMode === "pool" &&
            !this.startOptions.vehicleRestrictionPoolPresetId;
        this.raceMeta = (race) =>
            [
                `${race.startPositions} ${translate("beamjoy.window.main.tabs.races.slots")}`,
                this.formatDistance(race.distance),
                `${translate("beamjoy.window.config.tabs.races.author")} ${race.author || translate("beamjoy.window.config.tabs.races.unknownAuthor")}`,
            ].join(", ");

        // lobby panel helpers
        this.formatSeconds = (sec) => {
            sec = Math.max(0, Math.round(Number(sec) || 0));
            const m = Math.floor(sec / 60);
            const s = sec % 60;
            return `${m}:${s < 10 ? "0" : ""}${s}`;
        };
        // the one timer that matters right now : the start countdown, the all-ready countdown, or
        // how long the lobby stays open
        // the same object while nothing changed : ng-if watches it by reference, and a fresh object
        // every call never settles the digest (infdig, thousands of errors a second)
        let timerCache = null;
        const timer = (label, value) => {
            if (!timerCache || timerCache.label !== label || timerCache.value !== value) timerCache = { label, value };
            return timerCache;
        };
        this.lobbyTimer = () => {
            const s = this.status;
            if (!s) return null;
            if (s.state === "COUNTDOWN" && this.countdownSeconds !== null) {
                return timer("beamjoy.window.main.tabs.races.startingIn", `${this.countdownSeconds}`);
            }
            if (s.state === "GRID" && this.allReady && s.gridReadySecondsLeft != null) {
                return timer("beamjoy.window.main.tabs.races.startingIn", this.formatSeconds(s.gridReadySecondsLeft));
            }
            if (s.state === "GRID" && s.gridTimeoutSecondsLeft != null) {
                return timer("beamjoy.window.main.tabs.races.lobbyClosesIn", this.formatSeconds(s.gridTimeoutSecondsLeft));
            }
            return null;
        };
        this.vehicleChip = () => {
            const s = this.status;
            if (!s) return "";
            if (s.vehicleRestrictionMode === "single") return s.vehicleRestrictionLabel || "";
            if (s.vehicleRestrictionMode === "pool") return `${s.vehicleRestrictionPoolLabel} (${s.vehicleRestrictionPoolCount})`;
            return translate("beamjoy.window.main.tabs.races.noVehicleRestrictions");
        };
        this.isLeader = (player) => !!this.status && String(player.playerID) === String(this.status.starterID);
        // your own row follows the status push's own ready flag (the participant list can lag
        // a push behind it)
        this.isReady = (player) => {
            const s = this.status;
            const self = beamjoyStore.players.self;
            // ids can arrive as numbers or strings depending on the push : compare loosely
            const isSelf =
                (self && String(player.playerID) === String(self.playerID)) ||
                (s && s.isStarter && String(player.playerID) === String(s.starterID));
            if (s && isSelf) return !!s.ready;
            return player.ready === true || player.ready === 1 || player.ready === "true";
        };
        this.inviting = false;
        this.setInviting = (open) => (this.inviting = open);
        this.startNow = (event) => {
            event.stopPropagation();
            if (this.status && this.status.isStarter) beamjoyStore.send("BJRaceStartNow");
        };
        // the grid as the lobby shows it : players by slot, then ONE row saying how many slots are
        // free (a row per free slot made big grids far too long). Built once per status push (a
        // fresh array per digest never settles)
        this.slots = [];
        const buildSlots = () => {
            const s = this.status;
            if (!s) return (this.slots = []);
            const rows = (s.participants || []).map((p, i) => ({ key: `p${p.playerID}`, num: p.gridSlot || i + 1, player: p, ready: this.isReady(p) }));
            const free = Math.max(0, (s.maxParticipants || 0) - rows.length);
            if (free > 0) {
                rows.push({
                    key: "open",
                    num: "+",
                    open: true,
                    text: translate(free === 1 ? "beamjoy.window.main.tabs.races.openSlotsOne" : "beamjoy.window.main.tabs.races.openSlots")
                        .replace("{n}", free),
                });
            }
            this.slots = rows;
        };
        $scope.$watch(() => this.status, buildSlots);
        $scope.$watch(() => this.status && this.status.ready, buildSlots);
        this.lobbyLine = () => {
            const s = this.status;
            if (!s) return "";
            if (!s.joinable) return translate("beamjoy.window.main.tabs.races.soloLine");
            if (s.private && s.isStarter) {
                return translate("beamjoy.window.main.tabs.races.privateLobby")
                    .replace("{count}", s.participantCount || 0)
                    .replace("{max}", s.maxParticipants || 0);
            }
            const leader = (s.participants || []).find((p) => p.playerID === s.starterID);
            return translate(s.isStarter ? "beamjoy.window.main.tabs.races.yourLobby" : "beamjoy.window.main.tabs.races.theirLobby")
                .replace("{name}", leader ? leader.displayName || leader.playerName : "?")
                .replace("{count}", s.participantCount || 0)
                .replace("{max}", s.maxParticipants || 0);
        };
        this.openStatusLeaderboard = (event) => {
            const race = this.races.find((r) => this.status && r.name === this.status.raceName);
            if (race) this.openLeaderboard(event, race);
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

        // race control, staff watching a race (services/raceGrid.lua's raceStaffAction)
        // the half second : a light touch, for a cut corner or a nudge
        this.PENALTY_STEPS = [0.5, 5, 10];
        const penText = (ms) => {
            const s = Math.round(ms / 100) / 10;
            return Number.isInteger(s) ? String(s) : s.toFixed(1);
        };
        const fillIn = (key, values) =>
            Object.entries(values).reduce((text, [k, v]) => text.replace(`{${k}}`, v), translate(key));
        this.penaltyTag = (seconds) => fillIn("beamjoy.race.penaltyTag", { seconds });
        this.penaltySeconds = (r) => penText(r.penaltyMs);
        this.penaltyText = (r) =>
            fillIn("beamjoy.window.main.tabs.races.raceControl.penalty", { seconds: penText(r.penaltyMs) });
        this.racerState = (r) =>
            translate(
                r.disqualified ? "beamjoy.window.main.tabs.races.raceControl.disqualified"
                    : r.dnf ? "beamjoy.window.main.tabs.races.raceControl.retired"
                    : r.disconnected ? "beamjoy.window.main.tabs.races.raceControl.disconnected"
                    : r.finished ? "beamjoy.window.main.tabs.races.raceControl.finished"
                    : "beamjoy.window.main.tabs.races.raceControl.racing"
            );
        this.staffAction = (event, r, action, seconds) => {
            event.stopPropagation();
            beamjoyStore.send("BJRaceStaffAction", [r.playerID, action, seconds]);
        };
        this.disqualify = (event, r) => {
            event.stopPropagation();
            beamjoyConfirm.ask(
                fillIn("beamjoy.window.main.tabs.races.raceControl.confirmDisqualify", { name: r.name }),
                () => beamjoyStore.send("BJRaceStaffAction", [r.playerID, "disqualify"])
            );
        };

        this.setReady = (event, state) => {
            event.stopPropagation();
            beamjoyStore.send("BJRaceReady", [state]);
        };
        // "manual" placement: host assigns a participant's grid slot from the player list.
        // `slot` comes from bj-select's ng-change locals (the freshly picked value), NOT read
        // back off player.gridSlot: at ng-change time the two-way binding write-back hasn't run
        // yet, so player.gridSlot still holds the OLD slot. Reading it here sent the old value,
        // which the server correctly no-op'd (target already on that slot), and the next lobby
        // status tick then visually reverted the pick: the original "can't actually set manual
        // grid slots" bug. The authoritative state (including the swapped occupant's slot) comes
        // right back via the next session update push either way.
        this.setGridSlot = (player, slot) => {
            beamjoyStore.send("BJRaceSetGridSlot", [player.playerID, slot]);
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
