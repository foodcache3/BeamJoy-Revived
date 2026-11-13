angular.module("beamjoy").component("bjRaceCountdown", {
    templateUrl: "/ui/modModules/beamjoy/windows/raceCountdown/app.html",
    controller: function ($rootScope, $filter, beamjoyLeaderboardFormat) {
        const translate = (key) => $filter("translate")(key);
        const fill = (key, values) =>
            Object.entries(values).reduce((text, [k, v]) => text.replace(`{${k}}`, v), translate(key));
        this.active = false;
        this.seconds = null;
        this.raceName = null;
        // "countdown" (ticks + the "GO!" flash, seconds===0) is the default/only mode every
        // existing send already uses ; "finished"/"dnf" reuse this same overlay as a generic
        // "big transient message" primitive for the finish-line feedback a solo racer otherwise
        // never gets at all (the leaderboard HUD only sends once there's >1 participant)
        this.mode = "countdown";
        // "lights" : the start gantry (BJRaceDefaults.startLights). How many of the five are lit,
        // whether they've gone out (the green), and whether this racer jumped it
        this.lights = 0;
        this.green = false;
        this.jumped = false;
        this.LIGHTS = [1, 2, 3, 4, 5];
        this.timeMs = null;
        this.isBestLap = false;
        this.isNewPB = false;
        this.isNewRecord = false;

        $rootScope.$on("BJRaceCountdown", (_, data) => {
            this.active = !!data.active;
            if (!this.active) return;
            this.mode = data.mode || "countdown";
            this.lights = typeof data.lights === "number" ? data.lights : 0;
            this.green = data.green === true;
            this.jumped = data.jumped === true;
            this.seconds = data.seconds;
            this.timeMs = data.timeMs ?? null;
            this.isBestLap = data.isBestLap ?? false;
            // record implies PB too, but shown as its own, higher-priority badge in the template
            // rather than stacking both; see app.html
            this.isNewPB = data.isNewPB ?? false;
            this.isNewRecord = data.isNewRecord ?? false;
            // staff time penalties at the finish, in seconds ("5", "0.5" ; null : none, nothing shown)
            this.penaltySeconds = data.penaltyMs > 0 ? penText(data.penaltyMs) : null;
            // the place they finished in (racing others), "so far" while others are still out there
            this.place = typeof data.place === "number" ? data.place : null;
            this.placeText = this.place !== null && data.placeOf
                ? fill(data.provisional ? "beamjoy.race.placeSoFar" : "beamjoy.race.place", { place: this.place, of: data.placeOf })
                : null;
            // the phase over (its final place, big) : "of 12" under it
            this.placeOfText = data.placeOf ? fill("beamjoy.race.placeOf", { of: data.placeOf }) : null;
            // a knockout (a later phase takes only the top n) : through to it, or out
            const ko = data.knockout;
            this.knockout = ko
                ? {
                    through: !!ko.through,
                    text: fill(
                        ko.through
                            ? data.provisional ? "beamjoy.race.knockout.throughSoFar" : "beamjoy.race.knockout.through"
                            : data.provisional ? "beamjoy.race.knockout.outSoFar" : "beamjoy.race.knockout.out",
                        { phase: ko.phaseName || fill("beamjoy.racePhases.phaseN", { n: ko.phaseNumber }), top: ko.top }
                    ),
                }
                : null;
            if (data.raceName) {
                this.raceName = data.raceName;
                // an event's phase starting (practice, qualifying, the race...), when it has several
                this.phaseName = data.phaseName || null;
            }
        });

        const penText = (ms) => {
            const s = Math.round(ms / 100) / 10;
            return Number.isInteger(s) ? String(s) : s.toFixed(1);
        };

        // a gantry light is lit until they all go out together : that moment IS the green, so
        // nothing is lit from then on (see raceRunner.lua's lightsTiming)
        this.lit = (i) => !this.green && i <= this.lights;

        // shared race time format (hours from an hour up), see beamjoyLeaderboardFormat
        this.formatTime = beamjoyLeaderboardFormat.time;
    },
});
