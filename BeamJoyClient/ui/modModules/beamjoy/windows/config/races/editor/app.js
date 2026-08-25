angular.module("beamjoy").component("bjConfigRacesEditor", {
    bindings: {
        raceId: "<",
        onClose: "&",
    },
    templateUrl: "/ui/modModules/beamjoy/windows/config/races/editor/app.html",
    controller: function (
        $rootScope,
        $scope,
        $timeout,
        $filter,
        beamjoyStore,
        beamjoyConfirm,
        beamjoyNavGuard
    ) {
        const translate = $filter("translate");
        // "passive" (ambient, drive-up-discovered) mode is a designed-but-not-yet-built race type
        // (see the project plan's "Explicitly NOT built" list), so it's left out of the picker entirely
        // rather than shown and silently no-op'ing if picked. Add back once it's actually
        // implemented.
        this.MODES = ["grid"];
        // matches services/races.lua's own sanitizeRace truncation; see its comment for why a
        // limit exists at all
        this.NAME_MAX_LENGTH = 40;
        this.RESPAWN_STRATEGIES = ["all", "norespawn", "lastcheckpoint", "stand"];
        // "Mandatory stop" only means anything once at least one gate is actually flagged for
        // it; offering it otherwise would just be a no-op option. Computed live (not cached)
        // since gate.stand toggles are edited right here in the same session.
        this.availableRespawnStrategies = () =>
            this.RESPAWN_STRATEGIES.filter(
                (s) => s !== "stand" || (this.race && this.race.gates.some((g) => g.stand))
            );
        this.SECTIONS = ["info", "waypoints", "starts", "settings"];
        this.activeSection = "info";

        // registers/unregisters with the shared nav guard so switching config tabs or closing
        // the whole config window while this editor has unsaved changes asks first, same as the
        // editor's own "Back to list" button already does (see cmps/confirm/app.js for why this
        // has to be a shared guard rather than just reacting in $destroy)
        const dirtyCheck = () => this.dirty;
        beamjoyNavGuard.set(
            dirtyCheck,
            translate("beamjoy.window.config.tabs.races.confirmDiscard")
        );
        $scope.$on("$destroy", () => {
            beamjoyNavGuard.clear(dirtyCheck);
        });

        this.tool = "";
        $rootScope.$on("BJEditorChangeTool", (_, tool) => {
            this.tool = tool;
        });

        // mirrors the server's own gate in services/races.lua's raceSave : while
        // RaceAuthorshipRestriction is off (the default), always editable by anyone who got this
        // far ; while it's on, staff or the race's own author may save changes, via a
        // proactively-disabled Save button instead of letting a non-owner edit for a while only to
        // be told no after the fact with a toast. A race with no `id` yet (still being created) or
        // no `author` yet has nobody to conflict with, so it's always editable regardless. Only an
        // *existing* race with a real, different author is ever blocked, and only while the
        // restriction is actually on.
        this.canEdit = () =>
            !this.race ||
            !this.race.id ||
            !beamjoyStore.raceSettings.authorshipRestriction ||
            beamjoyStore.permissions.isStaff() ||
            this.race.author === beamjoyStore.players.self.playerName;

        this.race = null;
        this.activeGate = null; // 0-indexed, for ng-repeat/track-by convenience
        this.activeStart = null;
        this.dirty = false;
        this.snapToGroundEnabled = true;
        $rootScope.$on("BJEditorRaceSnapToGround", (_, state) => {
            this.snapToGroundEnabled = state === true;
        });
        // which ground-height source snapping uses when enabled. See the Lua-side M.snapMethod
        // comment (ui/raceEditor.lua) for the full tradeoff : "terrain" (default) reads the raw
        // heightmap, immune to trees/props but wrong on a map whose real ground isn't terrain at
        // all (Gridmap's own visible grid is a static mesh, confirmed by a live report of gates
        // snapping to whatever's under the map) ; "raycast" hits whatever's physically there
        // instead, correct on a map like that at the cost of being snaggable on a tree/prop again.
        this.snapMethod = "terrain";
        $rootScope.$on("BJEditorRaceSnapMethod", (_, method) => {
            this.snapMethod = method === "raycast" ? "raycast" : "terrain";
        });
        // single button cycles all three states rather than two separate controls, per direct
        // request : off -> terrain (on) -> raycast (on) -> off
        this.cycleSnapMode = () => {
            if (!this.snapToGroundEnabled) {
                beamjoyStore.send("BJEditorRaceSetSnapToGround", [true]);
                beamjoyStore.send("BJEditorRaceSetSnapMethod", ["terrain"]);
            } else if (this.snapMethod !== "raycast") {
                beamjoyStore.send("BJEditorRaceSetSnapMethod", ["raycast"]);
            } else {
                beamjoyStore.send("BJEditorRaceSetSnapToGround", [false]);
            }
        };

        // Lua is the source of truth (mirrors the safe-zone editor's architecture): gate/start
        // position+direction only ever change through the gizmo and are never diffed/sent back
        // from here. Every other field (name/mode/loopable/defaults/gate width-height-lap-stand)
        // is free-edited locally via ng-model, then a deep watch below diffs against the last
        // known state and sends only what actually changed.
        let previous = null;

        $rootScope.$on("BJEditorRaceUpdate", (_, race) => {
            // Lua can't distinguish an EMPTY table from an empty object, so a brand-new race's
            // initially-empty gates/startPositions can arrive here as {} instead of []: a real,
            // confirmed crash : "(race.gates || []).forEach is not a function" (the || [] fallback
            // only catches null/undefined, not a truthy-but-non-array {}). Normalized once here,
            // at the boundary, so every consumer (the deep-watch below, availableRespawnStrategies,
            // any future one) can safely assume real arrays without its own defensive check.
            if (race) {
                if (!Array.isArray(race.gates)) race.gates = [];
                if (!Array.isArray(race.startPositions)) race.startPositions = [];
            }
            // Merge the echo into the existing race object instead of replacing `this.race`
            // wholesale (the original approach here, and separately the root cause of a real
            // "typing a name sometimes drops the last character" bug) : a keystroke (or a slider
            // drag) can land in the round-trip window between performDiff sending a diff and this
            // echo arriving for it. An echo can only ever reflect whatever was already sent, never
            // anything typed/dragged since, so blindly overwriting `this.race` here silently
            // clobbered that in-progress edit the instant the echo happened to land mid-keystroke.
            // A field only takes the echoed value if the LOCAL value still matches the last diff
            // baseline (`previous`, i.e. no newer unsent edit sitting on top of it) ; anything
            // that's moved since keeps its local value and rides the next diff cycle instead,
            // the same "diff against an accurate baseline" mechanism the "every other update" fix
            // below already established for *sending* diffs, extended here to what's *displayed*.
            if (this.race && race && this.race.id === race.id && previous) {
                ["name", "mode", "loopable", "sectorCount", "manualSectors", "branchingEnabled", "vehicleRestrictionMode", "vehicleRestrictionPoolPresetId"].forEach((k) => {
                    if (angular.equals(this.race[k], previous[k])) this.race[k] = race[k];
                });
                if (angular.equals(this.race.defaults, previous.defaults)) {
                    this.race.defaults = race.defaults;
                }
                if (
                    this.race.gates.length === race.gates.length &&
                    previous.gates.length === race.gates.length
                ) {
                    race.gates.forEach((echoedGate, i) => {
                        const localGate = this.race.gates[i];
                        const prevGate = previous.gates[i];
                        ["width", "height", "stand", "sector", "parents", "isFinish"].forEach((k) => {
                            if (angular.equals(localGate[k], prevGate[k])) localGate[k] = echoedGate[k];
                        });
                        // pos/dir/step are never locally edited via this diff path: pos/dir
                        // because the gizmo is the sole source of truth for them (same as
                        // startPositions below), step because it's derived server/Lua-side from
                        // `parents` now (see races.lua's deriveStepsFromParents; a real bug fix,
                        // an independently-editable step an author had to keep manually in sync
                        // with parents was too easy to forget once a branch alternate was created
                        // later than its siblings). All three are always taken from the echo
                        // unconditionally, otherwise a live gizmo drag (or a fresh derivation)
                        // would stop updating the moment this merge path replaced the old
                        // wholesale-replace behavior
                        localGate.pos = echoedGate.pos;
                        localGate.dir = echoedGate.dir;
                        localGate.step = echoedGate.step;
                    });
                } else {
                    // gate count changed (added/removed via the in-world gizmo): no local
                    // index-by-index merge is meaningful, Lua is authoritative for structure anyway
                    this.race.gates = race.gates;
                }
                // everything else (id, author, gate/start positions+directions, startPositions) is
                // never locally edited via this diff path at all: Lua/the gizmo is the sole
                // source of truth for it, so it's always safe (and necessary, to pick up e.g. a
                // gate moved via the gizmo) to take wholesale from the echo
                this.race.author = race.author;
                this.race.startPositions = race.startPositions;
                // never locally edited either, only ever set via the "single" mode capture action
                // (BJEditorRaceCaptureVehicleRestriction), a Lua-side mutation with no local
                // optimistic value to protect, same reasoning as above. "pool" mode's own
                // vehicleRestrictionPoolPresetId IS locally edited (a plain dropdown value), so it's
                // merged above with the other diffed meta fields instead of taken wholesale here.
                this.race.vehicleRestrictionModel = race.vehicleRestrictionModel;
                this.race.vehicleRestrictionParts = race.vehicleRestrictionParts;
                this.race.vehicleRestrictionVars = race.vehicleRestrictionVars;
                this.race.vehicleRestrictionPaints = race.vehicleRestrictionPaints;
                this.race.vehicleRestrictionLabel = race.vehicleRestrictionLabel;
            } else {
                this.race = race;
            }
            previous = race ? angular.copy(this.race) : null;
            rebuildParentOptions();
        });
        $rootScope.$on("BJEditorRaceActiveGate", (_, idx) => {
            this.activeGate = idx ? idx - 1 : null;
            // Lua is the source of truth for selection and broadcasts this same event whether the
            // gate was picked by clicking its sidebar row or by clicking it in the 3D world, so
            // scrolling here covers both, not just the world-click case it was asked for. $timeout
            // (not requestAnimationFrame) so this runs after Angular's own digest has actually
            // expanded the gate-detail panel via ng-if, otherwise the row's height/position isn't
            // final yet and scrollIntoView would target the wrong spot.
            if (this.activeGate !== null) {
                $timeout(() => {
                    const el = document.getElementById(`race-gate-row-${this.activeGate}`);
                    if (el) el.scrollIntoView({ behavior: "smooth", block: "nearest" });
                });
            }
            rebuildParentOptions();
        });
        $rootScope.$on("BJEditorRaceActiveStart", (_, idx) => {
            this.activeStart = idx ? idx - 1 : null;
        });
        $rootScope.$on("BJEditorDirty", (_, state) => {
            this.dirty = state === true;
        });
        $rootScope.$on("BJEditorRaceSavedAsNew", (_, newId) => {
            this.raceId = newId;
        });

        // Debounced (not sent on every single digest) : purely a rate-limiting nicety now that
        // the echo-handler above keeps `previous` accurate on its own; collapses a burst of
        // rapid edits (e.g. holding a number box's spinner arrow) into one outgoing message with
        // the net change, instead of one BJEditorRaceSetGate/echo round trip per click. 150ms
        // matches the existing throttle already used for the in-world edge-handle drag sync in
        // ui/raceEditor.lua, for consistency. (This alone was tried first and did NOT fix the
        // "every other update" bug: the echo handler unconditionally replacing `this.race` was
        // never actually racing the debounced send, it was stomping the *diff baseline* itself;
        // see the comment above for the fix that actually mattered.)
        const DIFF_DEBOUNCE_MS = 150;
        let diffTimeout = null;

        const performDiff = () => {
            diffTimeout = null;
            const race = this.race;
            if (!race || !previous) return;

            const metaPartial = {};
            ["name", "mode", "loopable", "sectorCount", "manualSectors", "branchingEnabled", "vehicleRestrictionMode", "vehicleRestrictionPoolPresetId"].forEach((k) => {
                if (!angular.equals(race[k], previous[k])) {
                    // same reasoning as gate width/height below : bj-slider's typable number-box
                    // can hand back a string in this CEF build, which silently breaks arithmetic
                    // server-side (sectorCount gets clamped via tonumber() there, but sending a
                    // string also means angular.equals() below would never see it as "changed
                    // back" after a round trip that normalizes it to a number). The preset
                    // dropdown's own value is a plain number already, but coerced anyway for the
                    // same defense-in-depth reasoning, unless nothing is selected (null)
                    if (k === "sectorCount") {
                        metaPartial[k] = Number(race[k]);
                    } else if (k === "vehicleRestrictionPoolPresetId") {
                        metaPartial[k] = race[k] == null ? null : Number(race[k]);
                    } else {
                        metaPartial[k] = race[k];
                    }
                }
            });
            if (!angular.equals(race.defaults, previous.defaults)) {
                metaPartial.defaults = race.defaults;
            }
            if (Object.keys(metaPartial).length > 0) {
                beamjoyStore.send("BJEditorRaceSetMeta", [metaPartial]);
            }

            (race.gates || []).forEach((gate, i) => {
                const prevGate = previous.gates && previous.gates[i];
                if (!prevGate) return;
                const partial = {};
                // "step" deliberately excluded: it's derived Lua-side from "parents" now, never
                // locally edited (see the echo-merge comment above for why)
                ["width", "height", "stand", "sector", "parents", "isFinish"].forEach((k) => {
                    if (!angular.equals(gate[k], prevGate[k])) {
                        let v = gate[k] === undefined ? null : gate[k];
                        // the typable number-box on bj-slider can hand back a string in this
                        // CEF build (a live error confirmed it: "3.5" reaching Lua rather
                        // than 3.5, which broke arithmetic against a native vec3 downstream) ;
                        // coerce numeric fields explicitly rather than trusting ngModel's type
                        if ((k === "width" || k === "height") && v !== null) v = Number(v);
                        partial[k] = v;
                    }
                });
                if (Object.keys(partial).length > 0) {
                    beamjoyStore.send("BJEditorRaceSetGate", [i + 1, partial]);
                }
            });

            previous = angular.copy(race);
        };

        $scope.$watch(
            () => this.race,
            (race) => {
                if (!race) {
                    if (diffTimeout) {
                        $timeout.cancel(diffTimeout);
                        diffTimeout = null;
                    }
                    return;
                }
                if (!previous) {
                    previous = angular.copy(race);
                    return;
                }

                if (diffTimeout) $timeout.cancel(diffTimeout);
                diffTimeout = $timeout(performDiff, DIFF_DEBOUNCE_MS);
            },
            true
        );
        $scope.$on("$destroy", () => {
            if (diffTimeout) $timeout.cancel(diffTimeout);
        });

        this.$onInit = () => {
            beamjoyStore.send("BJEditorRaceOpen", [
                this.raceId === "new" ? null : this.raceId,
            ]);
            beamjoyStore.send("BJVehiclePresetListRequest");
        };

        this.changeSection = (event, section) => {
            event.stopPropagation();
            this.activeSection = section;
        };

        this.changeTool = (event, tool) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorChangeTool", [tool]);
        };

        this.selectGate = (event, idx) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceSelectGate", [
                this.activeGate === idx ? null : idx + 1,
            ]);
        };
        this.createGate = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceCreateGate");
        };
        this.deleteGate = (event, idx) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceDeleteGate", [idx + 1]);
        };
        this.setGateToVehicle = (event, idx) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceSetGateToVehicle", [idx + 1]);
        };
        this.teleportToGate = (event, idx) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceTeleportToGate", [idx + 1]);
        };
        this.resetGate = (event, idx) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceResetGate", [idx + 1]);
        };
        this.sortUpdate = (index, newIndex) => {
            beamjoyStore.send("BJEditorRaceReorderGates", [index + 1, newIndex + 1]);
        };
        this.reverseGates = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceReverseGates");
        };
        this.captureVehicleRestriction = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceCaptureVehicleRestriction");
        };
        // "pool" mode now references a shared, reusable BJVehiclePreset by id instead of an inline
        // list authored per-race (see services/vehiclePresets.lua). The picker below just needs
        // the list of presets to populate a dropdown ; vehicleRestrictionPoolPresetId itself is a
        // plain field on this.race, diffed/sent through the normal performDiff path above like
        // vehicleRestrictionMode already is, no dedicated send needed here.
        // real root cause of "the preset doesn't show up in the dropdown", confirmed via console
        // diagnostics (the data itself was arriving correctly): this used a native <select>, the
        // only place in the whole codebase that did. Everywhere else uses the custom bj-select
        // component (cmps/select), specifically because a native <select>'s dropdown POPUP doesn't
        // render in BeamNG's off-screen-rendered CEF UI (an OS-native widget layer the OSR pipeline
        // never captures) ; bj-select wraps Angular Material's md-select instead, which draws its
        // options as real in-page DOM rather than a native popup. options needs a {value, label}[]
        // shape (bj-select's own template translates opt.label itself), rebuilt from the raw preset
        // list plus a leading "nothing selected" placeholder entry.
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
        this.openVehiclePresets = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJRequestOpenWindow", ["config"]);
            $rootScope.$broadcast("BJOpenTab", "vehiclePresets");
        };
        // a loopable race's own gate 1 physically doubles as the finish line too (the closing
        // last-gate -> gate-1 segment is real drivable track, see raceMarkers.lua's drawPath, and
        // raceGrid.lua's lap-boundary detection matches : a lap completes on *re*-crossing gate 1,
        // not on reaching the last placed gate) ; a non-loopable (point-to-point) race has no
        // closing segment, so start and finish are two distinct gates instead. Same rule as
        // raceMarkers.lua's own gateRole(), kept in sync by hand (small enough not to warrant a
        // shared module for a Lua/JS split codebase).
        this.gateRole = (index) => {
            if (!this.race) return null;
            const total = this.race.gates.length;
            if (total <= 0) return null;
            const gate = this.race.gates[index];

            if (this.race.branchingEnabled) {
                const isStart = gate.step === 1;
                if (this.race.loopable) return isStart ? "startfinish" : null;
                const isFinish = gate.isFinish === true;
                if (isStart && isFinish) return "startfinish";
                if (isStart) return "start";
                if (isFinish) return "finish";
                return null;
            }

            if (index === 0 && index === total - 1) return "startfinish";
            if (this.race.loopable) return index === 0 ? "startfinish" : null;
            if (index === 0) return "start";
            if (index === total - 1) return "finish";
            return null;
        };

        // parent/child linking, per direct request ("flat option... adds parent/child buttons to
        // the waypoint screen like in beamjoyfree"): no graph/tree visualization, just a plain
        // chip list of this gate's own `parents` (each removable) plus a picker to add another.
        // 0 is the reserved "reachable from the start/grid" sentinel (never a real gate index),
        // shown as "Start" rather than a gate number.
        this.parentLabel = (parentIdx) =>
            parentIdx === 0
                ? translate("beamjoy.window.config.tabs.races.branching.start")
                : `${translate("beamjoy.window.config.tabs.races.gate")} ${parentIdx}`;

        // Precomputed (not called inline from the template): bj-select's own `options` binding is
        // one-way ("<"), and every other working usage of it in this codebase always passes a
        // plain, already-built array property, never a live function call. Matching that
        // established, proven convention here instead of risking whatever subtlety made the
        // function-call form come up empty. Only ever needs to exist for the currently-open gate's
        // detail panel, so it's rebuilt on exactly the handful of events that could change it
        // (opening a different gate, an echo bringing in a fresh race, adding/removing a parent)
        // rather than continuously recomputed.
        this.parentOptions = [];
        const rebuildParentOptions = () => {
            if (!this.race || this.activeGate === null || !this.race.gates[this.activeGate]) {
                this.parentOptions = [];
                return;
            }
            const index = this.activeGate;
            const gate = this.race.gates[index];
            const existing = Array.isArray(gate.parents) ? gate.parents : [];
            const options = [{ value: 0, label: this.parentLabel(0) }];
            this.race.gates.forEach((_, i) => {
                const gateNum = i + 1;
                if (gateNum !== index + 1) {
                    options.push({ value: gateNum, label: this.parentLabel(gateNum) });
                }
            });
            this.parentOptions = options.filter((o) => !existing.includes(o.value));
        };

        // scratch model for the per-gate "add a parent" bj-select, keyed by gate index. bj-select
        // has no working ng-change of its own (confirmed: no other usage in this codebase relies
        // on it, every one instead pairs it with an explicit Add button reading the bound value,
        // see e.g. windows/config/general/modelBlacklist/app.js's identical pattern), so this is
        // read explicitly by confirmAddParent below rather than applied automatically on selection.
        this.pendingParent = {};
        this.confirmAddParent = (index) => {
            const value = Number(this.pendingParent[index]);
            if (Number.isNaN(value)) return;
            const gate = this.race.gates[index];
            if (!Array.isArray(gate.parents)) gate.parents = [];
            if (!gate.parents.includes(value)) gate.parents = [...gate.parents, value];
            this.pendingParent[index] = null;
            rebuildParentOptions();
        };
        this.removeParent = (index, parentIdx) => {
            const gate = this.race.gates[index];
            if (!Array.isArray(gate.parents)) return;
            gate.parents = gate.parents.filter((p) => p !== parentIdx);
            rebuildParentOptions();
        };

        // which sector (1-based) this gate closes under manual sector boundaries: the Nth
        // flagged gate (in index order) closes sector N; the final gate always implicitly closes
        // the last sector even if not itself flagged (matches raceGrid.lua's own sectorEndGates,
        // which appends the last gate unconditionally). null when manual sectors are off or this
        // gate isn't a boundary at all.
        this.sectorNumber = (index) => {
            if (!this.race || !this.race.manualSectors) return null;
            const gates = this.race.gates;
            const isBoundary = gates[index] && (gates[index].sector || index === gates.length - 1);
            if (!isBoundary) return null;
            let n = 0;
            for (let i = 0; i <= index; i++) {
                if (gates[i].sector || i === gates.length - 1) n++;
            }
            return n;
        };

        this.selectStart = (event, idx) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceSelectStart", [
                this.activeStart === idx ? null : idx + 1,
            ]);
        };
        this.createStart = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceCreateStart");
        };
        this.deleteStart = (event, idx) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceDeleteStart", [idx + 1]);
        };
        this.setStartToVehicle = (event, idx) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceSetStartToVehicle", [idx + 1]);
        };
        this.teleportToStart = (event, idx) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceTeleportToStart", [idx + 1]);
        };
        this.resetStart = (event, idx) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorRaceResetStart", [idx + 1]);
        };

        this.save = (event) => {
            event.stopPropagation();
            const doSave = () => beamjoyStore.send("BJEditorRaceSave");
            if (this.raceId !== "new") {
                // saving an existing race always wipes its recorded times server-side (see
                // services/races.lua's raceSave: gates/layout can change under a saved race, so
                // old times are never assumed still valid/comparable), per direct request. Only
                // worth calling out in the confirm text when there's actually something to lose;
                // leaderboardCount comes from the trimmed race cache (races.lua's onBJRequestCache;
                // the real per-player leaderboard itself is never synced client-side at all).
                const recordCount = this.race.leaderboardCount || 0;
                const message =
                    recordCount > 0
                        ? translate(
                              "beamjoy.window.config.tabs.races.confirmOverwriteWithRecords"
                          )
                              .replace("{name}", this.race.name)
                              .replace("{count}", recordCount)
                        : translate(
                              "beamjoy.window.config.tabs.races.confirmOverwrite"
                          ).replace("{name}", this.race.name);
                beamjoyConfirm.ask(message, doSave);
            } else {
                doSave();
            }
        };
        // replaces the old "Duplicate" button: that one auto-appended " (copy)" to the name with
        // no uniqueness check of its own, so re-duplicating the same race (or any name collision)
        // silently failed server-side validation with no visible link back to the click, which is
        // the likely reason it kept getting reported as "doesn't function" despite the Lua
        // round-trip itself working correctly. Prompting for an explicit name up front means the
        // existing server-side duplicate-name rejection (raceSave -> sanitizeRace) now surfaces as
        // a toast clearly tied to *this* attempt, and the player can just retype a different name.
        this.saveAsNew = (event) => {
            event.stopPropagation();
            beamjoyConfirm.askForInput(
                translate("beamjoy.window.config.tabs.races.saveAsNewPrompt"),
                this.race.name + " (copy)",
                translate("beamjoy.window.config.tabs.races.name"),
                (name) => {
                    if (!name) return;
                    beamjoyStore.send("BJEditorRaceSaveAsNew", [name]);
                },
                undefined,
                this.NAME_MAX_LENGTH
            );
        };
        this.deleteRace = (event) => {
            event.stopPropagation();
            beamjoyConfirm.ask(
                translate("beamjoy.window.config.tabs.races.confirmDelete").replace(
                    "{name}",
                    this.race.name
                ),
                () => {
                    beamjoyStore.send("BJDirectSend", ["raceDelete", this.raceId]);
                    beamjoyStore.send("BJEditorRaceClose");
                    this.onClose();
                }
            );
        };
        this.close = (event) => {
            event.stopPropagation();
            beamjoyNavGuard.check(() => {
                beamjoyStore.send("BJEditorRaceClose");
                this.onClose();
            });
        };
    },
});
