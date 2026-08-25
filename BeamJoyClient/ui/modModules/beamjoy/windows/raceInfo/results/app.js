angular.module("beamjoy").component("bjRaceInfoResults", {
    templateUrl: "/ui/modModules/beamjoy/windows/raceInfo/results/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.active = false;
        this.finished = false;
        this.raceName = null;
        this.sectorCount = 1;
        this.sectors = [];
        this.classification = [];
        this.selectedPlayerName = null;
        this.selectedLaps = [];
        this.fastestSectorMs = {};
        // race-wide fastest lap for the classification table's own "Best" column purple highlight.
        // The Live tab already had this (isFastestLap there), Results never did at all
        this.fastestLapMs = null;

        const buildClassification = (participants) => {
            // finished (by total time) first, then still-racing/dnf keep the server's own
            // leaderboard order (already sorted "most progress first"); matches how a results
            // screen reads even before every last straggler has actually finished or dnf'd
            const withTotals = participants.map((p) => {
                let totalMs = null;
                if (p.finished && Array.isArray(p.lapTimes)) {
                    totalMs = p.lapTimes.reduce((a, b) => a + b, 0);
                }
                return { ...p, totalMs };
            });
            const finishedSorted = withTotals
                .filter((p) => p.totalMs !== null)
                .sort((a, b) => a.totalMs - b.totalMs);
            const rest = withTotals.filter((p) => p.totalMs === null);
            const ordered = finishedSorted.concat(rest);
            const winnerMs = finishedSorted.length > 0 ? finishedSorted[0].totalMs : null;
            return ordered.map((p) => ({
                ...p,
                gapMs: p.totalMs !== null && winnerMs !== null ? p.totalMs - winnerMs : null,
            }));
        };

        const rebuild = (data) => {
            this.active = !!data.active;
            if (!this.active) return;
            this.raceName = data.raceName;
            this.finished = data.state === "FINISHED";
            this.sectorCount = data.sectorCount;
            this.sectors = Array.from({ length: this.sectorCount }, (_, i) => i + 1);
            this.classification = buildClassification(data.participants || []);

            this.fastestLapMs = null;
            (data.participants || []).forEach((p) => {
                if (typeof p.bestLapMs === "number") {
                    if (this.fastestLapMs === null || p.bestLapMs < this.fastestLapMs) {
                        this.fastestLapMs = p.bestLapMs;
                    }
                }
            });

            // race-wide fastest sector, for highlighting a selected player's own splits against
            // the best anyone actually posted that sector; same "purple" convention as the live
            // tab
            this.fastestSectorMs = {};
            (data.participants || []).forEach((p) => {
                this.sectors.forEach((s) => {
                    // bestSectorMs is keyed "s1"/"s2"/... , not plain numbers: see keyify() in
                    // raceRunner.lua. A table keyed by small positive integers is indistinguishable
                    // from an array to both this codebase's JSON encoder and the engine's Lua->UI
                    // bridge, so it would otherwise arrive here as a 0-indexed JS array instead of
                    // an object keyed by sector number
                    const v = p.bestSectorMs && p.bestSectorMs["s" + s];
                    if (typeof v === "number") {
                        if (
                            this.fastestSectorMs[s] === undefined ||
                            v < this.fastestSectorMs[s]
                        ) {
                            this.fastestSectorMs[s] = v;
                        }
                    }
                });
            });

            if (
                !this.selectedPlayerName ||
                !this.classification.some((p) => p.playerName === this.selectedPlayerName)
            ) {
                this.selectedPlayerName =
                    this.classification.length > 0 ? this.classification[0].playerName : null;
            }
            this.rebuildSelectedLaps();
        };

        $rootScope.$on("BJRaceInfo", (_, data) => rebuild(data));

        this.$onInit = () => {
            beamjoyStore.send("BJRaceInfoRequest");
        };

        this.selectPlayer = (playerName) => {
            this.selectedPlayerName = playerName;
            this.rebuildSelectedLaps();
        };

        this.rebuildSelectedLaps = () => {
            const p = this.classification.find(
                (row) => row.playerName === this.selectedPlayerName
            );
            if (!p || !Array.isArray(p.lapTimes)) {
                this.selectedLaps = [];
                return;
            }
            // lapSectorHistory is keyed "lap1"/"lap2"/... (each value itself keyed "s1"/"s2"/...)
            // rather than plain numbers; see keyifyLapSectorHistory() in raceRunner.lua, same
            // array-vs-object ambiguity keyify() works around
            this.selectedLaps = p.lapTimes.map((lapMs, i) => {
                const raw = (p.lapSectorHistory && p.lapSectorHistory["lap" + (i + 1)]) || {};
                const sectors = {};
                this.sectors.forEach((s) => {
                    if (raw["s" + s] !== undefined) sectors[s] = raw["s" + s];
                });
                return { lap: i + 1, lapMs, sectors };
            });
        };

        this.formatTime = (ms) => {
            if (typeof ms !== "number" || ms < 0) return "-";
            const totalSec = ms / 1000;
            const min = Math.floor(totalSec / 60);
            const sec = (totalSec % 60).toFixed(2);
            return `${min}:${sec.padStart(5, "0")}`;
        };

        this.formatGap = (ms) => {
            if (typeof ms !== "number") return "-";
            if (ms === 0) return "-";
            return `+${(ms / 1000).toFixed(2)}s`;
        };

        this.isFastestSector = (sector, ms) =>
            typeof ms === "number" && this.fastestSectorMs[sector] === ms;

        this.isFastestLap = (p) =>
            this.fastestLapMs !== null && p.bestLapMs === this.fastestLapMs;

        // sum of a player's own best sector times; see the Live tab's identical helper for why
        // this is undefined (shown as "-") rather than a partial sum until every sector has a
        // best time recorded at least once. Real, confirmed bug fixed here: with zero sectors
        // (a branching race, see computeSectorCount's own comment), the loop below never ran at
        // all, so `sum` stayed at its initial 0 and got returned as a real value instead of
        // undefined, showing a bogus "0:00.00" Theoretical time for every participant rather than
        // "-". Explicit empty-sectors guard now returns undefined the same as any other
        // no-real-data case.
        this.theoreticalBest = (p) => {
            if (!p.bestSectorMs || this.sectors.length === 0) return undefined;
            let sum = 0;
            for (const s of this.sectors) {
                const v = p.bestSectorMs["s" + s];
                if (typeof v !== "number") return undefined;
                sum += v;
            }
            return sum;
        };
    },
});
