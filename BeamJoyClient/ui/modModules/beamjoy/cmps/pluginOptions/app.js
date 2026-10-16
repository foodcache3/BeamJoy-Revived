// What the server's plugins add to BeamJoy's windows (the server's services/pluginUi.lua, through
// lua beamjoy/pluginUi.lua) : race option sections (start menu, race editor), config tabs, and
// labels ("fields") on results and leaderboard entries. Plugins only describe them ; everything is
// drawn here as plain text.

// the definitions, kept on the store for every window : beamjoyStore.pluginUi
angular.module("beamjoy").factory("beamjoyPluginUi", function ($rootScope, beamjoyStore) {
    const asList = (v) => (Array.isArray(v) ? v : v && typeof v === "object" ? Object.values(v) : []);
    // a section as drawn : its options as a list, each select's choices too
    const prepareSection = (s, plugin) => {
        const out = Object.assign({}, s, { plugin: plugin || s.plugin });
        out.key = `${out.plugin}/${s.id}`;
        out.options = asList(s.options).map((o) => {
            const opt = Object.assign({}, o);
            if (opt.type === "select") {
                opt.choices = asList(opt.choices);
                // a few : side by side buttons ; more : a dropdown
                opt.seg = opt.choices.length <= 5;
                opt.selectOptions = opt.choices.map((c) => ({ value: c.value, label: c.label }));
            }
            return opt;
        });
        return out;
    };
    // a race section with only the options shown in one place ("start" or "editor")
    const forPlace = (sections, place) =>
        sections
            .map((s) => Object.assign({}, s, { options: s.options.filter((o) => !o.where || o.where === "both" || o.where === place) }))
            .filter((s) => s.options.length > 0);

    const state = { race: [], config: [], startSections: [], editorSections: [] };
    beamjoyStore.pluginUi = state;
    $rootScope.$on("BJPluginUi", (_, data) => {
        const race = asList(data && data.race).map((s) => prepareSection(s));
        const config = asList(data && data.config).map((t) => {
            const tab = Object.assign({}, t);
            tab.sections = asList(t.sections).map((s) => prepareSection(s, t.plugin));
            return tab;
        });
        Object.assign(state, {
            race,
            config,
            startSections: forPlace(race, "start"),
            editorSections: forPlace(race, "editor"),
        });
        $rootScope.$broadcast("BJPluginUiChanged");
    });

    // values filled in : what's given where it fits its option, the option's default for the rest
    const fits = (o, v) => {
        if (o.type === "toggle") return typeof v === "boolean";
        if (o.type === "select") return o.choices.some((c) => c.value === v);
        if (o.type === "number") return v !== null && v !== "" && !isNaN(Number(v));
        if (o.type === "text") return typeof v === "string";
        return false;
    };
    const seed = (sections, values) => {
        const out = {};
        asList(sections).forEach((s) => {
            const given = (values && values[s.plugin]) || {};
            out[s.plugin] = out[s.plugin] || {};
            s.options.forEach((o) => {
                if (o.type === "button") return;
                out[s.plugin][o.id] = fits(o, given[o.id]) ? (o.type === "number" ? Number(given[o.id]) : given[o.id]) : o.default;
            });
        });
        return out;
    };

    // a plugin's colour names : the race HUD's own tokens (windows/pluginOverlays)
    const COLORS = {
        accent: "#ff8955",
        muted: "#a7aebf",
        good: "#73eb9d",
        bad: "#ff9a8f",
        warn: "#ffc768",
        purple: "#ba68f8",
        white: "#ffffff",
    };
    const color = (c) => (typeof c === "string" ? COLORS[c] || c : null);

    // a session's values as lines ("Class : GT3"), for the lobby's race details
    const describe = (values) => {
        const lines = [];
        state.race.forEach((s) => {
            const mine = (values && values[s.plugin]) || {};
            s.options.forEach((o) => {
                const v = mine[o.id];
                if (v === undefined || v === null || v === "") return;
                let shown = v;
                if (o.type === "toggle") shown = v ? "✓" : "✗";
                else if (o.type === "select") {
                    const c = o.choices.find((x) => x.value === v);
                    shown = c ? c.label : v;
                } else if (o.type === "number" && o.unit) shown = `${v} ${o.unit}`;
                lines.push(`${o.label}: ${shown}`);
            });
        });
        return lines;
    };

    // ask for them once the UI's up (the Lua side keeps them across UI reloads)
    beamjoyStore.send("BJPluginUiRequest");

    return { state, asList, seed, color, describe };
});
angular.module("beamjoy").run(function (beamjoyPluginUi) {
    // instantiated at start, so the definitions are listened for before any window needs them
});

// one or more sections of a plugin's options. `holder` is the object the values live on, under
// `plugins` (plugin -> option -> value) : a race's defaults, a start menu's options, a config
// tab's values. Nothing's written there until someone changes a value, so opening the race editor
// never makes a race look edited. `layout` : "fields" (the start menu's look) or "table" (the
// editor's and config window's)
angular.module("beamjoy").component("bjPluginOptions", {
    templateUrl: "/ui/modModules/beamjoy/cmps/pluginOptions/app.html",
    bindings: {
        sections: "<",
        holder: "<",
        layout: "@",
        // config tabs : which secret options have a value stored
        secrets: "<?",
        onAction: "&?",
    },
    controller: function ($scope, beamjoyPluginUi) {
        const ui = beamjoyPluginUi;
        this.view = {};
        const current = () => (this.holder && this.holder.plugins) || {};
        const rebuild = () => {
            this.view = ui.seed(this.sections, current());
        };
        $scope.$watch(() => [this.sections, this.holder && this.holder.plugins], rebuild, true);
        $scope.$watch(
            () => this.view,
            (view, old) => {
                if (view === old || !this.holder) return;
                const seeded = ui.seed(this.sections, current());
                Object.keys(view).forEach((plugin) => {
                    if (angular.equals(view[plugin], seeded[plugin])) return;
                    const values = Object.assign({}, current()[plugin] || {}, view[plugin]);
                    // the number boxes can hand back text
                    ui.asList(this.sections).forEach((s) => {
                        if (s.plugin !== plugin) return;
                        s.options.forEach((o) => {
                            if (o.type === "number" && values[o.id] !== undefined) values[o.id] = Number(values[o.id]);
                        });
                    });
                    this.holder.plugins = Object.assign({}, current(), { [plugin]: values });
                });
            },
            true
        );
        this.pick = (s, o, value) => (this.view[s.plugin][o.id] = value);
        this.isSecretSet = (s, o) => !!(o.secret && this.secrets && this.secrets[o.id]);
        this.click = (s, o) => {
            if (this.onAction) this.onAction({ plugin: s.plugin, option: o });
        };
    },
});

// plugins' labels on a result or a leaderboard entry : a list of {label, value, color, showLabel}
angular.module("beamjoy").component("bjPluginFields", {
    template: `<span class="bj-plugin-field" ng-repeat="f in $ctrl.list track by $index" ng-style="f.style" title="{{f.title}}">{{f.text}}</span>`,
    bindings: { fields: "<" },
    controller: function (beamjoyPluginUi) {
        this.list = [];
        this.$onChanges = () => {
            this.list = beamjoyPluginUi.asList(this.fields).map((f) => {
                const c = beamjoyPluginUi.color(f.color);
                return {
                    text: f.showLabel ? `${f.label} ${f.value}` : f.value,
                    title: `${f.label}: ${f.value}`,
                    style: c ? { color: c, "border-color": c } : {},
                };
            });
        };
    },
});
