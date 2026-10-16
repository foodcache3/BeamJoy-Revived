// One page from a server plugin, in the main window's side panel or full window (BeamJoy's plugin
// API, pages.* : checked by the server's services/pluginPages.lua, kept by beamjoy/pluginPages.lua,
// listed by windows/main). The plugin describes blocks ; they're drawn here, as plain text : the
// overlays' blocks (text, rows, timers, bars, plates, a table), headings, input fields and buttons.
// A button sends the plugin a click with the page's fields as they're set (PageAction).
// Blocks are made ready to draw once per push (never in template getters : fresh objects per
// digest break ng-repeat) ; only running timers tick.
angular.module("beamjoy").component("bjPluginPage", {
    templateUrl: "/ui/modModules/beamjoy/cmps/pluginPage/app.html",
    bindings: {
        // a page as windows/main keeps it : the server's, plus _anchor (when its timers were read)
        page: "<",
    },
    controller: function ($scope, $interval, $timeout, beamjoyStore, beamjoyPluginUi, beamjoyLeaderboardFormat, beamjoyConfirm) {
        const ui = beamjoyPluginUi;
        const f = beamjoyLeaderboardFormat;
        const asList = ui.asList;
        const cellsOf = (v) => asList(v).map((c) => (c && typeof c === "object" ? c : { text: String(c) }));
        const cellStyle = (c, column) => {
            const style = {};
            if (c.color) style.color = ui.color(c.color);
            const align = c.align || (column && column.align);
            if (align) style["text-align"] = align;
            return style;
        };
        const selfID = () => {
            const s = beamjoyStore.players.self;
            return s && s.playerID !== undefined && s.playerID !== null ? String(s.playerID) : null;
        };
        const isYou = (row, me) =>
            !!row.you || (me !== null && row.playerId !== undefined && row.playerId !== null && String(row.playerId) === me);

        this.blocks = [];
        // the page's fields, as this player sets them : field id -> value. Kept across updates of
        // the same page (a plugin refreshing it doesn't wipe what you picked) while they still fit
        this.values = {};
        this.busy = {};
        let pageKey = null;
        let hasTimer = false;

        const fits = (o, v) => {
            if (v === undefined || v === null) return false;
            if (o.type === "toggle") return typeof v === "boolean";
            if (o.type === "select") return o.choices.some((c) => c.value === v);
            if (o.type === "number") return !isNaN(Number(v));
            return typeof v === "string";
        };

        const prepare = () => {
            const page = this.page || {};
            if (page.key !== pageKey) {
                pageKey = page.key;
                this.values = {};
            }
            const me = selfID();
            const seen = {};
            hasTimer = false;
            this.blocks = asList(page.blocks).map((raw) => {
                const b = Object.assign({}, raw);
                b._style = {};
                if (b.color) b._style.color = ui.color(b.color);
                if (b.align) b._style["text-align"] = b.align;
                if (b.type === "row") {
                    b.cells = cellsOf(b.cells);
                    b.cells.forEach((c) => (c._style = cellStyle(c)));
                } else if (b.type === "bar") {
                    b._fill = { width: `${Math.round(b.value * 100)}%` };
                    if (b.color) b._fill.background = ui.color(b.color);
                } else if (b.type === "plate") {
                    b._plate = b.color ? { background: ui.color(b.color) } : {};
                } else if (b.type === "segments") {
                    b.items = asList(b.items);
                } else if (b.type === "table") {
                    b.columns = asList(b.columns);
                    b.rows = asList(b.rows).map((r) => {
                        const row = Object.assign({}, r);
                        row.cells = cellsOf(r.cells);
                        row._you = isYou(row, me);
                        row._style = row.color ? { color: ui.color(row.color) } : {};
                        row.cells.forEach((c, i) => (c._style = cellStyle(c, b.columns[i])));
                        return row;
                    });
                } else if (b.type === "timer") {
                    if (b.mode !== "static") hasTimer = true;
                } else if (b.type === "buttons") {
                    b.items = asList(b.items);
                } else if (b.type === "field") {
                    const o = Object.assign({}, b.option || {});
                    if (o.type === "select") {
                        o.choices = asList(o.choices);
                        // a few : side by side buttons ; more : a dropdown
                        o.seg = o.choices.length <= 5;
                        o.selectOptions = o.choices.map((c) => ({ value: c.value, label: c.label }));
                    }
                    b.option = o;
                    seen[o.id] = true;
                    if (!fits(o, this.values[o.id])) this.values[o.id] = o.default;
                    else if (o.type === "number") this.values[o.id] = Number(this.values[o.id]);
                }
                return b;
            });
            // fields the page no longer has
            Object.keys(this.values).forEach((id) => {
                if (!seen[id]) delete this.values[id];
            });
        };
        this.$onChanges = prepare;

        this.pick = (o, value) => (this.values[o.id] = value);

        // a running timer's value now ("up" counts on from the plugin's value, "down" counts it down)
        this.timerText = (t) => {
            if (!t || typeof t.ms !== "number") return "";
            const elapsed = Date.now() - ((this.page && this.page._anchor) || Date.now());
            if (t.mode === "up") return f.time(t.ms + elapsed);
            if (t.mode === "down") return f.time(Math.max(0, t.ms - elapsed));
            return f.time(t.ms);
        };

        // a click : the page's fields go with it (numbers as numbers)
        this.click = (item) => {
            if (!item || item.disabled || this.busy[item.id] || !this.page) return;
            const run = () => {
                const values = {};
                this.blocks.forEach((b) => {
                    if (b.type !== "field") return;
                    const o = b.option;
                    values[o.id] = o.type === "number" ? Number(this.values[o.id]) : this.values[o.id];
                });
                beamjoyStore.send("BJPluginPageAction", [this.page.plugin, this.page.id, item.id, values]);
                // one click at a time : a double click is one action
                this.busy[item.id] = true;
                $timeout(() => delete this.busy[item.id], 600);
            };
            if (item.confirm) beamjoyConfirm.ask(item.confirm, run);
            else run();
        };

        // the digest that moves running timers along (none while nothing's running)
        const tick = $interval(
            () => {
                if (hasTimer) $scope.$applyAsync();
            },
            100,
            0,
            false
        );
        $scope.$on("$destroy", () => $interval.cancel(tick));
    },
});
