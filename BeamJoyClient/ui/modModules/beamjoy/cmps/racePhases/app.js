// An event's phases (the server's services/racePhases.lua) : practice, qualifying, the race, a
// sprint then a feature race on a reversed grid, heats, a knockout, two runs summed... Each phase has
// its own start (together from the grid, one at a time, or open runs), length (laps or runs, time,
// or both), ranking, grid and rules. The formats are ready-made phase lists, edited
// freely once picked. Used by the race start form and the race editor's defaults.

// formats, a phase's defaults, and the phases as the server takes them
angular.module("beamjoy").factory("beamjoyRacePhases", function ($filter) {
    const translate = (key) => $filter("translate")(key);
    const name = (key) => translate(`beamjoy.racePhases.names.${key}`);
    const MAX_PHASES = 20;

    // `key` names the phase in the player's language when the format is picked
    const FORMATS = [
        { id: "race", phases: [{ ranking: "position" }] },
        {
            id: "qualiRace",
            phases: [
                { key: "qualifying", start: "open", ranking: "best", lengthMode: "time", timeLimitMin: 10, afterTime: "own", countsToEvent: false },
                { key: "race", ranking: "position", order: { from: "phase", phase: 1, reverse: 0 } },
            ],
        },
        {
            id: "practiceQualiRace",
            phases: [
                { key: "practice", start: "open", ranking: "best", lengthMode: "time", timeLimitMin: 10, afterTime: "own", countsToEvent: false, lateJoin: true },
                { key: "qualifying", start: "open", ranking: "best", lengthMode: "time", timeLimitMin: 10, afterTime: "own", countsToEvent: false },
                { key: "race", ranking: "position", order: { from: "phase", phase: 2, reverse: 0 } },
            ],
        },
        {
            id: "sprintFeature",
            phases: [
                { key: "sprint", ranking: "position", countsToEvent: false },
                { key: "feature", ranking: "position", order: { from: "phase", phase: 1, reverse: 8 } },
            ],
        },
        {
            id: "timeAttack",
            phases: [{ key: "timeAttack", start: "open", ranking: "best", lengthMode: "time", timeLimitMin: 15, afterTime: "own", lateJoin: true }],
        },
        {
            id: "knockout",
            phases: [
                { key: "q1", start: "open", ranking: "best", lengthMode: "time", timeLimitMin: 8, afterTime: "own", countsToEvent: false },
                { key: "q2", start: "open", ranking: "best", lengthMode: "time", timeLimitMin: 6, afterTime: "own", countsToEvent: false, takes: { from: 1, top: 10 } },
                { key: "race", ranking: "position", order: { from: "phase", phase: 2, reverse: 0 } },
            ],
        },
        {
            // a hill climb, a rally stage : one at a time, two runs, the times added up
            id: "twoRuns",
            result: "sum",
            phases: [
                { key: "run1", start: "individual", intervalS: 30, ranking: "total", laps: 1 },
                { key: "run2", start: "individual", intervalS: 30, ranking: "total", laps: 1, order: { from: "phase", phase: 1, reverse: -1 } },
            ],
        },
    ];
    // "individual" is the editor's "Time offset" (a start every few seconds, several on track),
    // "sequential" its "One at a time" (each racer's whole phase before the next is released)
    const STARTS = ["grid", "individual", "sequential", "open"];
    // the rules a phase's editor sets over the event's ; the pits' too (services/races.lua PIT_SETTINGS,
    // a race with usable pits only)
    const PIT_RULES = ["pitStart", "pitGhost", "pitStops", "pitMissingPenaltyS", "pitRefuel", "pitFuelRatePct",
        "startFuelPct", "pitRepair", "pitRepairMaxS", "pitTow", "pitTowSpeed", "pitReturn"];
    const RULES = ["respawnStrategy", "disableCollisions", "dnfEnabled", "resetPenaltyEnabled", ...PIT_RULES];

    // a phase as edited : every setting there, the length's laps and minutes kept while switched off
    const newPhase = (base, laps) => {
        const p = Object.assign(
            {
                name: "",
                plugins: {},
                start: "grid",
                intervalS: 10,
                // one at a time : the others watch (one car on track, all from the first slot), or
                // wait on their slots
                waiting: "watch",
                lateJoin: false,
                ranking: "position",
                lengthMode: "laps",
                laps: laps || 3,
                timeLimitMin: 10,
                afterTime: null,
                order: { from: "lobby", phase: 1, reverse: 0 },
                takes: null,
                leaderboard: true,
                countsToEvent: true,
                breakS: 30,
                rules: {},
            },
            angular.copy(base || {})
        );
        if (base && base.key) p.name = name(base.key);
        delete p.key;
        p.order = Object.assign({ from: "lobby", phase: 1, reverse: 0 }, p.order);
        // each rule its dropdown shows, null ("as the event") when the phase doesn't set it : an
        // undefined one matched no option, and the dropdown showed empty (reported)
        p.rules = Object.assign({}, p.rules);
        RULES.forEach((k) => {
            if (p.rules[k] === undefined) p.rules[k] = null;
        });
        if (!p.afterTime) p.afterTime = p.ranking === "position" ? "leader" : "own";
        return p;
    };

    // a format's phases, for a race (`laps` : its own lap count, for the race phases). A
    // point-to-point track (a sprint) : one run each, unless the format says otherwise (direct request)
    const formatPhases = (id, loopable, laps) => {
        const f = FORMATS.find((x) => x.id === id) || FORMATS[0];
        return f.phases.map((p) => {
            const phase = newPhase(p, p.laps || (loopable ? laps : 1));
            // a point-to-point track raced from the grid together : one run
            if (!loopable && phase.start === "grid") {
                phase.lengthMode = "laps";
                phase.laps = 1;
            }
            return phase;
        });
    };
    const formatResult = (id) => (FORMATS.find((x) => x.id === id) || {}).result || "last";

    // the phases a race starts with : as given before (a lobby's own, a race's defaults), back in
    // the editor's shape
    const fromServer = (list) =>
        (Array.isArray(list) ? list : []).map((p) => {
            const phase = newPhase(p);
            const hasLaps = typeof p.laps === "number";
            const hasTime = typeof p.timeLimitMin === "number";
            phase.lengthMode = hasLaps && hasTime ? "both" : hasTime ? "time" : "laps";
            if (!hasLaps) phase.laps = 3;
            if (!hasTime) phase.timeLimitMin = 10;
            return phase;
        });

    // the phases as the server takes them (racePhases.sanitize checks them again)
    const toServer = (phases) =>
        (phases || []).map((p, i) => {
            const out = {
                name: (p.name || "").trim() || undefined,
                start: p.start || "grid",
                intervalS: p.start === "individual" ? Number(p.intervalS) || 10 : undefined,
                waiting: p.start === "sequential" ? (p.waiting === "grid" ? "grid" : "watch") : undefined,
                lateJoin: p.lateJoin === true,
                ranking: p.ranking,
                laps: p.lengthMode !== "time" ? Number(p.laps) || 1 : undefined,
                timeLimitMin: p.lengthMode !== "laps" ? Number(p.timeLimitMin) || 1 : undefined,
                afterTime: p.afterTime,
                order: i > 0 && p.order && p.order.from !== "lobby"
                    ? { from: p.order.from, phase: p.order.phase, reverse: Number(p.order.reverse) || 0 }
                    : { from: "lobby" },
                takes: i > 0 && p.takes ? { from: p.takes.from || undefined, top: Number(p.takes.top) || 1 } : undefined,
                leaderboard: p.leaderboard !== false,
                countsToEvent: p.countsToEvent !== false,
                breakS: Number(p.breakS) || 30,
                rules: {},
                // plugins' own options for this phase
                plugins: p.plugins && Object.keys(p.plugins).length > 0 ? angular.copy(p.plugins) : undefined,
            };
            Object.entries(p.rules || {}).forEach(([k, v]) => {
                if (v !== null && v !== undefined && v !== "") out.rules[k] = v;
            });
            return out;
        });

    // "Q2", "Phase 2"
    const phaseLabel = (p, i) => (p && p.name) || translate("beamjoy.racePhases.phaseN").replace("{n}", i + 1);

    return { MAX_PHASES, FORMATS, STARTS, newPhase, formatPhases, formatResult, fromServer, toServer, phaseLabel };
});

angular.module("beamjoy").component("bjRacePhases", {
    bindings: {
        // edited in place
        phases: "=",
        result: "=",
        // a circuit : laps, time ; a point-to-point track raced from the grid : one run each phase
        loopable: "<",
        // the race's default lap count, for a phase added
        laps: "<?",
        // a plugin's format : what the starter can't change (true : all of it ; or a list, "phases"
        // for the list itself, else a setting of every phase)
        locked: "<?",
        // the race's pits are usable : each phase's own pit rules
        pits: "<?",
    },
    templateUrl: "/ui/modModules/beamjoy/cmps/racePhases/app.html",
    controller: function ($scope, $filter, beamjoyRacePhases, beamjoyPluginUi) {
        const translate = (key) => $filter("translate")(key);
        const fill = (key, values) =>
            Object.entries(values).reduce((text, [k, v]) => text.replace(`{${k}}`, v), translate(key));
        this.MAX = beamjoyRacePhases.MAX_PHASES;
        this.RANKINGS = ["position", "best", "total"];
        this.STARTS = beamjoyRacePhases.STARTS;
        this.WAITING = ["watch", "grid"];
        // laps or a time to repeat : a circuit, or a point-to-point track raced in runs (not from
        // the grid all together)
        this.repeats = (p) => this.loopable || p.start !== "grid";
        // a point-to-point track's laps are runs
        this.lapsWord = () => translate(this.loopable ? "beamjoy.window.config.tabs.races.laps" : "beamjoy.racePhases.runs");
        this.LENGTHS = ["laps", "time", "both"];
        this.AFTER_TIMES = ["leader", "own", "stop"];
        this.RESULTS = ["last", "sum"];
        this.RESPAWNS = ["all", "norespawn", "lastcheckpoint", "flipupright", "lastroad"];
        this.label = (p, i) => beamjoyRacePhases.phaseLabel(p, i);
        this.open = {};
        // a plugin's format : what stays as it set it (the server keeps it so too)
        this.isLocked = (key) => this.locked === true || (Array.isArray(this.locked) && this.locked.includes(key));
        // plugins' options with a value per phase (`where = "phase"`)
        this.phaseSections = beamjoyPluginUi.state.phaseSections;
        $scope.$on("BJPluginUiChanged", () => (this.phaseSections = beamjoyPluginUi.state.phaseSections));

        // the dropdowns' choices, rebuilt when the phases change (never in a template getter :
        // a fresh array per digest never settles)
        const rebuild = () => {
            const phases = this.phases || [];
            this.orderOptions = phases.map((_, i) => {
                const opts = [{ value: "lobby", label: translate("beamjoy.racePhases.orders.lobby") }];
                for (let k = 0; k < i; k++) {
                    opts.push({ value: `phase:${k + 1}`, label: fill("beamjoy.racePhases.orders.phase", { name: this.label(phases[k], k) }) });
                }
                if (i > 0) opts.push({ value: "event", label: translate("beamjoy.racePhases.orders.event") });
                return opts;
            });
            this.takesOptions = phases.map((_, i) => {
                const opts = [{ value: "all", label: translate("beamjoy.racePhases.takes.everyone") }];
                for (let k = 0; k < i; k++) {
                    opts.push({ value: `phase:${k + 1}`, label: fill("beamjoy.racePhases.takes.phase", { name: this.label(phases[k], k) }) });
                }
                if (i > 0) opts.push({ value: "event", label: translate("beamjoy.racePhases.takes.event") });
                return opts;
            });
            this.reverseOptions = [
                { value: 0, label: translate("beamjoy.racePhases.reverses.none") },
                ...[2, 3, 4, 5, 6, 8, 10, 12, 16, 20].map((n) => ({ value: n, label: fill("beamjoy.racePhases.reverses.top", { n }) })),
                { value: -1, label: translate("beamjoy.racePhases.reverses.all") },
            ];
            this.respawnOptions = [
                { value: null, label: translate("beamjoy.racePhases.rules.same") },
                ...this.RESPAWNS.map((s) => ({ value: s, label: translate(`beamjoy.window.config.tabs.races.respawnStrategies.${s}`) })),
            ];
            this.onOffOptions = [
                { value: null, label: translate("beamjoy.racePhases.rules.same") },
                { value: true, label: translate("beamjoy.common.enabled") },
                { value: false, label: translate("beamjoy.common.disabled") },
            ];
            this.collisionOptions = [
                { value: null, label: translate("beamjoy.racePhases.rules.same") },
                { value: false, label: translate("beamjoy.racePhases.rules.solid") },
                { value: true, label: translate("beamjoy.racePhases.rules.ghosted") },
            ];
            // the pits' : a choice each, as the event, or a value of its own
            const same = { value: null, label: translate("beamjoy.racePhases.rules.same") };
            const numbers = (list, key) => [same, ...list.map((n) => ({ value: n, label: fill(key, { n }) }))];
            this.pitStartOptions = [
                same,
                { value: false, label: translate("beamjoy.window.config.tabs.races.pitStartModes.grid") },
                { value: true, label: translate("beamjoy.window.config.tabs.races.pitStartModes.pits") },
            ];
            this.pitStopsOptions = numbers([0, 1, 2, 3, 4, 5], "beamjoy.racePhases.rules.n");
            this.pitPenaltyOptions = numbers([0, 10, 15, 20, 30, 45, 60, 120], "beamjoy.racePhases.rules.seconds");
            this.pitRateOptions = numbers([1, 2, 3, 5, 8, 10, 15, 20], "beamjoy.racePhases.rules.percentPerSecond");
            this.startFuelOptions = numbers([10, 20, 25, 30, 40, 50, 60, 70, 75, 80, 90, 100], "beamjoy.racePhases.rules.percent");
            this.pitRepairOptions = numbers([0, 15, 30, 45, 60, 90, 120, 180], "beamjoy.racePhases.rules.seconds");
            this.pitTowSpeedOptions = numbers([20, 30, 40, 50, 60, 80, 100, 120], "beamjoy.racePhases.rules.kmh");
            // the order and takes pickers' own values ("phase:2"), kept beside the phase's
            phases.forEach((p, i) => {
                p.orderPick = i === 0 || !p.order || p.order.from === "lobby" ? "lobby"
                    : p.order.from === "event" ? "event" : `phase:${p.order.phase}`;
                p.takesPick = i === 0 || !p.takes ? "all" : p.takes.from ? `phase:${p.takes.from}` : "event";
            });
        };
        $scope.$watch(() => (this.phases || []).map((p) => p.name).join("\u0001") + "|" + (this.phases || []).length, rebuild);

        this.setOrder = (p, value) => {
            if (value === "lobby") p.order = { from: "lobby", phase: 1, reverse: 0 };
            else if (value === "event") p.order = { from: "event", reverse: (p.order && p.order.reverse) || 0 };
            else p.order = { from: "phase", phase: Number(String(value).split(":")[1]), reverse: (p.order && p.order.reverse) || 0 };
        };
        this.setTakes = (p, value) => {
            if (value === "all") p.takes = null;
            else if (value === "event") p.takes = { from: null, top: (p.takes && p.takes.top) || 10 };
            else p.takes = { from: Number(String(value).split(":")[1]), top: (p.takes && p.takes.top) || 10 };
        };
        this.setRanking = (p, ranking) => {
            p.ranking = ranking;
            // "the leader" only means something in a race
            if (ranking !== "position" && p.afterTime === "leader") p.afterTime = "own";
        };
        this.setStart = (p, start) => {
            p.start = start;
            // alone on track, there's no leader to follow
            if (start === "sequential" && p.afterTime === "leader") p.afterTime = "own";
        };
        // "the leader" : a race, with others on track
        this.leaderMeans = (p) => p.ranking === "position" && p.start !== "sequential";

        // an order or takes pointing at a phase that moved or went : back to the lobby / everyone
        const repoint = (map) => {
            this.phases.forEach((p, i) => {
                if (p.order && p.order.from === "phase") {
                    const to = map(p.order.phase);
                    if (!to || to > i) p.order = { from: "lobby", phase: 1, reverse: 0 };
                    else p.order.phase = to;
                }
                if (p.takes && p.takes.from) {
                    const to = map(p.takes.from);
                    if (!to || to > i) p.takes = null;
                    else p.takes.from = to;
                }
                if (i === 0) {
                    p.order = { from: "lobby", phase: 1, reverse: 0 };
                    p.takes = null;
                }
            });
            rebuild();
        };
        this.add = () => {
            if (this.phases.length >= this.MAX || this.isLocked("phases")) return;
            // a point-to-point track's phase : one run to start from
            this.phases.push(beamjoyRacePhases.newPhase(null, this.loopable ? this.laps : 1));
            this.open[this.phases.length - 1] = true;
            rebuild();
        };
        this.remove = (i) => {
            if (this.phases.length <= 1 || this.isLocked("phases")) return;
            this.phases.splice(i, 1);
            this.open = {};
            // phase n (1-based) : the one removed goes, the ones after move up
            repoint((n) => (n === i + 1 ? null : n > i + 1 ? n - 1 : n));
        };
        this.move = (i, dir) => {
            const j = i + dir;
            if (j < 0 || j >= this.phases.length || this.isLocked("phases")) return;
            const a = this.phases[i];
            this.phases[i] = this.phases[j];
            this.phases[j] = a;
            this.open = {};
            repoint((n) => (n === i + 1 ? j + 1 : n === j + 1 ? i + 1 : n));
        };
        this.toggle = (i) => (this.open[i] = !this.open[i]);
        // the length, short : "5 laps", "10 min", "10 min / 5 laps"
        this.lengthText = (p) => {
            if (!this.repeats(p)) return translate("beamjoy.racePhases.oneRun");
            const laps = this.loopable
                ? fill(Number(p.laps) === 1 ? "beamjoy.racePhases.lapsOne" : "beamjoy.racePhases.lapsN", { n: p.laps })
                : fill(Number(p.laps) === 1 ? "beamjoy.racePhases.oneRun" : "beamjoy.racePhases.runsN", { n: p.laps });
            const time = fill("beamjoy.racePhases.minutesN", { n: p.timeLimitMin });
            return p.lengthMode === "time" ? time : p.lengthMode === "both" ? `${time} / ${laps}` : laps;
        };
    },
});
