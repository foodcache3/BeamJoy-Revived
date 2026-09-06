angular.module("beamjoy").component("bjConfigCore", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/core/app.html",
    controller: function (
        $rootScope,
        $scope,
        $filter,
        beamjoyStore,
        beamjoyConfirm
    ) {
        const translate = $filter("translate");

        // Legacy Import: one row per importable mode's legacy-data importer (Hunter, Races today,
        // see services/hunter.lua and services/races.lua's own doc comments for each design). Lives
        // here rather than on each mode's own Config tab so it has one obvious, stable home as more
        // modes gain their own importer ; each row is independently permission-gated on that mode's
        // own edit permission, not on this tab's own SetCore gate (see windows/config/app.js's own
        // comment on why Core's tab visibility itself is widened to match).
        this.canImportHunter = false;
        this.canImportInfected = false;
        this.canImportRaces = false;
        // the identity-fields form below (server name/description/max players/private/debug/
        // informationPacket) is real admin-only data - the server already withholds it entirely
        // from anyone without SetCore (see services/core.lua's own onBJRequestCache), but this
        // form used to render unconditionally the moment this tab mounted at all, regardless of
        // permission. Since the tab itself is deliberately reachable by EditHunterArenas/EditRaces
        // holders too (for the Legacy Import accordion below), that meant a mod-rank importer-only
        // account could open Config > Core and see this whole form rendered (with a real, if
        // ultimately-rejected, Save button) even though they were never meant to have any access to
        // core server config at all. Gated separately from tab visibility so a non-SetCore holder
        // only ever sees the Legacy Import accordion, never this form.
        this.canSetCore = false;
        const updateLegacyImportPermissions = () => {
            this.canImportHunter = beamjoyStore.permissions.hasAllPermissions(
                undefined,
                "EditHunterArenas"
            );
            this.canImportInfected = beamjoyStore.permissions.hasAllPermissions(
                undefined,
                "EditInfectedArenas"
            );
            this.canImportRaces = beamjoyStore.permissions.hasAllPermissions(
                undefined,
                "EditRaces"
            );
            this.canSetCore = beamjoyStore.permissions.hasAllPermissions(
                undefined,
                "SetCore"
            );
        };
        updateLegacyImportPermissions();
        ["BJUpdateGroups", "BJUpdatePermissions", "BJUpdateSelf"].forEach(
            (eventName) => {
                $rootScope.$on(eventName, updateLegacyImportPermissions);
            }
        );

        this.showLegacyImportHelp = (event) => {
            event.stopPropagation(); // don't also toggle the accordion this button lives inside
            beamjoyConfirm.info(
                translate("beamjoy.window.config.tabs.core.legacyImport.help.text")
            );
        };

        this.hunterLegacyImportStatus = null;
        this.requestHunterLegacyImport = (event) => {
            event.stopPropagation();
            this.hunterLegacyImportStatus = null;
            beamjoyStore.send("BJHunterLegacyImportPreviewRequest");
        };
        $rootScope.$on("BJHunterLegacyImportPreview", (_, results) => {
            // Real bug: an empty scan result ({} in Lua) round-trips through the GE->UI native
            // guihooks bridge (a second, separate JSON encode from BJS's own server->client one)
            // and can come out the other side as a plain object rather than []. `.length` on that
            // is undefined, not 0, so the guard below has to check real arrayness too or this
            // falls through to results.filter() on a non-array and throws.
            if (!Array.isArray(results) || results.length === 0) {
                this.hunterLegacyImportStatus = "beamjoy.window.config.tabs.core.legacyImport.hunter.none";
                return;
            }
            const conflictCount = results.filter((r) => r.conflict).length;
            const lines = results
                .map((r) => {
                    const counts = `${r.hunterSpawnCount}/${r.preySpawnCount}/${r.waypointCount}`;
                    const overwrite = r.conflict
                        ? ` (${translate("beamjoy.window.config.tabs.core.legacyImport.hunter.overwriteTag")})`
                        : "";
                    return `${r.map} · ${counts}${overwrite}`;
                })
                .join("\n");
            const header = translate("beamjoy.window.config.tabs.core.legacyImport.hunter.confirm")
                .replace("{count}", results.length)
                .replace("{conflicts}", conflictCount);
            beamjoyConfirm.ask(`${header}\n\n${lines}`, () => {
                beamjoyStore.send("BJHunterLegacyImportConfirm");
            });
        });

        // same "will overwrite" framing as Hunter's own importer above (they share the exact same
        // source <map>_hunter.json files, see services/infected.lua's own doc comment)
        this.infectedLegacyImportStatus = null;
        this.requestInfectedLegacyImport = (event) => {
            event.stopPropagation();
            this.infectedLegacyImportStatus = null;
            beamjoyStore.send("BJInfectedLegacyImportPreviewRequest");
        };
        $rootScope.$on("BJInfectedLegacyImportPreview", (_, results) => {
            // see BJHunterLegacyImportPreview's own comment above: same guihooks round-trip gap
            if (!Array.isArray(results) || results.length === 0) {
                this.infectedLegacyImportStatus = "beamjoy.window.config.tabs.core.legacyImport.infected.none";
                return;
            }
            const conflictCount = results.filter((r) => r.conflict).length;
            const lines = results
                .map((r) => {
                    const counts = `${r.survivorSpawnCount}/${r.infectedSpawnCount}`;
                    const overwrite = r.conflict
                        ? ` (${translate("beamjoy.window.config.tabs.core.legacyImport.infected.overwriteTag")})`
                        : "";
                    return `${r.map} · ${counts}${overwrite}`;
                })
                .join("\n");
            const header = translate("beamjoy.window.config.tabs.core.legacyImport.infected.confirm")
                .replace("{count}", results.length)
                .replace("{conflicts}", conflictCount);
            beamjoyConfirm.ask(`${header}\n\n${lines}`, () => {
                beamjoyStore.send("BJInfectedLegacyImportConfirm");
            });
        });

        // races' own importer is deliberately NON-DESTRUCTIVE (per direct request) : every
        // convertible race is ADDED as a brand-new race, never overwriting anything already in the
        // list; a name collision is skipped and reported instead, so this preview's own wording
        // and confirm flow differ from Hunter's own "will overwrite" framing above on purpose.
        this.raceLegacyImportStatus = null;
        this.requestRaceLegacyImport = (event) => {
            event.stopPropagation();
            this.raceLegacyImportStatus = null;
            beamjoyStore.send("BJRaceLegacyImportPreviewRequest");
        };
        $rootScope.$on("BJRaceLegacyImportPreview", (_, results) => {
            // see BJHunterLegacyImportPreview's own comment above: same guihooks round-trip gap
            if (!Array.isArray(results) || results.length === 0) {
                this.raceLegacyImportStatus = "beamjoy.window.config.tabs.core.legacyImport.races.none";
                return;
            }
            const importable = results.filter((r) => !r.conflict && !r.invalid);
            const conflictCount = results.filter((r) => r.conflict).length;
            const invalidCount = results.filter((r) => r.invalid).length;
            const lines = results
                .map((r) => {
                    const counts = `${r.gateCount} gates / ${r.startCount} starts${r.branching ? " (branching)" : ""}${r.loopable ? " (loopable)" : ""}`;
                    const tag = r.conflict
                        ? ` (${translate("beamjoy.window.config.tabs.core.legacyImport.races.skipTag")})`
                        : r.invalid
                        ? ` (${translate("beamjoy.window.config.tabs.core.legacyImport.races.invalidTag")})`
                        : "";
                    const author = r.author ? ` (by ${r.author})` : "";
                    return `${r.map} · ${r.name}${author} · ${counts}${tag}`;
                })
                .join("\n");
            if (importable.length === 0) {
                this.raceLegacyImportStatus = null;
                beamjoyConfirm.ask(
                    `${translate("beamjoy.window.config.tabs.core.legacyImport.races.noneImportable")}\n\n${lines}`,
                    () => {}
                );
                return;
            }
            const header = translate("beamjoy.window.config.tabs.core.legacyImport.races.confirm")
                .replace("{count}", importable.length)
                .replace("{skipped}", conflictCount)
                .replace("{invalid}", invalidCount);
            beamjoyConfirm.ask(`${header}\n\n${lines}`, () => {
                beamjoyStore.send("BJRaceLegacyImportConfirm");
            });
        });

        this.data = {
            Name: "",
            Description: "",
            MaxPlayers: 1,
            Private: true,
            Debug: false,
            InformationPacket: false,
        };
        this.default = {};
        this.init = false;
        this.dirty = false;
        this.valid = false;
        const updateDirty = () => {
            this.dirty = !angular.equals(this.data, this.default);
        };
        const updateValid = () => {
            this.valid = true;
            if (this.data.Name.length < 3 || this.data.Name.length > 150)
                this.valid = false;
            if (this.data.Description.length > 500) this.valid = false;
            if (!this.data.MaxPlayers) this.valid = false;
        };
        $scope.$watch(
            () => this.data,
            () => {
                if (!this.init) return;
                updateDirty();
                updateValid();
            },
            true
        );
        const replaceLineBreaksIn = (str) => {
            while (str.includes("^p")) {
                str = str.replace("^p", "\n");
            }
            return str;
        };
        $scope.$on("BJSendCoreData", (_, data) => {
            this.default = data;
            this.default.Description = replaceLineBreaksIn(
                this.default.Description
            );
            if (!this.dirty) {
                Object.assign(this.data, this.default);
            }
            updateDirty();
            updateValid();
            this.init = true;
        });
        this.$onInit = () => {
            if (this.canSetCore) beamjoyStore.send("BJRequestCoreData");
        };
        this.cancel = () => {
            this.data = angular.copy(this.default);
        };
        this.save = () => {
            if (!this.dirty) return;
            Object.keys(this.data)
                .filter(
                    (key) => !angular.equals(this.data[key], this.default[key])
                )
                .forEach((key) => {
                    let value = this.data[key];
                    if (key === "Description") {
                        while (value.includes("\n")) {
                            value = value.replace("\n", "^p");
                        }
                    }
                    beamjoyStore.send("BJDirectSend", ["setCore", key, value]);
                });
        };

        const parsePreview = (str) => {
            const colors = {
                0: "rgb(0, 0, 0)",
                1: "rgb(0, 0, 170)",
                2: "rgb(0, 170, 0)",
                3: "rgb(0, 170, 170)",
                4: "rgb(170, 0, 0)",
                5: "rgb(170, 0, 170)",
                6: "rgb(255, 170, 0)",
                7: "rgb(170, 170, 170)",
                8: "rgb(85, 85, 85)",
                9: "rgb(85, 85, 255)",
                a: "rgb(85, 255, 85)",
                b: "rgb(85, 255, 255)",
                c: "rgb(255, 85, 85)",
                d: "rgb(255, 85, 255)",
                e: "rgb(255, 255, 85)",
                f: "rgb(255, 255, 255)",
            };

            const effects = {
                n: "underline",
                l: "bold",
                m: "strike",
                o: "italic",
            };

            let segments = [];
            let current = { text: "", styles: { color: "rgb(255, 255, 255)" } };

            for (let i = 0; i < str.length; i++) {
                const char = str[i];
                if (char === "^") {
                    const code = str[++i];
                    if (code === "r") {
                        // reset
                        if (current.text) segments.push(current);
                        current = {
                            text: "",
                            styles: { color: "rgb(255, 255, 255)" },
                        };
                    } else if (colors.hasOwnProperty(code)) {
                        if (current.text) segments.push(current);
                        current = { text: "", styles: { ...current.styles } };
                        current.styles = {
                            ...current.styles,
                            color: colors[code],
                        };
                    } else if (effects.hasOwnProperty(code)) {
                        if (current.text) segments.push(current);
                        current = { text: "", styles: { ...current.styles } };
                        current.styles = {
                            ...current.styles,
                            [effects[code]]: true,
                        };
                    } else {
                        // invalid code, does not add up
                    }
                } else if (char === "\n") {
                    if (current.text) segments.push(current);
                    segments.push({ text: "\n", styles: {} });
                    current = { text: "", styles: { ...current.styles } };
                } else {
                    current.text += char;
                }
            }
            if (current.text) segments.push(current);
            return segments;
        };
        this.renderPreview = (segments) => {
            return (
                segments
                    .map((seg) => {
                        if (seg.text === "\n") return "<br>";
                        let style = "";
                        if (seg.styles.color)
                            style += `color:${seg.styles.color};`;
                        if (seg.styles.bold) style += "font-weight:bold;";
                        if (seg.styles.underline)
                            style += "text-decoration:underline;";
                        if (seg.styles.strike)
                            style += "text-decoration:line-through;";
                        if (seg.styles.italic) style += "font-style:italic;";
                        return `<span style="${style}">${seg.text}</span>`;
                    })
                    .join("") + "<hr/>"
            );
        };
        this.namePreview = null;
        this.descriptionPreview = null;
        $scope.$watch(
            () => this.data.Name,
            () => {
                if (this.data.Name.includes("^")) {
                    this.namePreview = parsePreview(
                        this.data.Name + "[OFFLINE]"
                    );
                } else this.namePreview = null;
            }
        );
        $scope.$watch(
            () => this.data.Description,
            () => {
                this.data.Description = replaceLineBreaksIn(
                    this.data.Description
                );
                if (this.data.Description.includes("^")) {
                    this.descriptionPreview = parsePreview(
                        this.data.Description
                    );
                } else this.descriptionPreview = null;
            }
        );
    },
});
