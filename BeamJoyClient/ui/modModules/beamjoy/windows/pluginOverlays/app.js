// Activity overlays from the server's plugins (BeamJoy's plugin API : overlay.show, checked by the
// server's services/pluginOverlay.lua, kept by beamjoy/pluginOverlays.lua). Two layouts :
//   default : the race HUD's own look, filled with the plugin's values (title, position plate,
//             gaps, lap + running timer, segments, standings, a footer line)
//   custom  : the plugin's own arrangement of blocks (text, rows, timers, bars, a table...)
// Everything is drawn as plain text. Styles and "your row" are worked out once per push (never in
// template getters : fresh objects per digest break ng-repeat) ; only running timers tick.
// An overlay can stand in for BeamJoy's race HUD while it's up (hides : ["race"], see raceHud).
angular.module("beamjoy").component("bjPluginOverlays", {
    templateUrl: "/ui/modModules/beamjoy/windows/pluginOverlays/app.html",
    controller: function ($rootScope, $scope, $interval, beamjoyStore, beamjoyLeaderboardFormat) {
        const f = beamjoyLeaderboardFormat;
        const POSITIONS = ["top-right", "top-left", "bottom-right", "bottom-left", "top", "bottom", "left", "right"];
        // the plugin API's colour names : the race HUD's own tokens
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
        const asList = (v) => (Array.isArray(v) ? v : v && typeof v === "object" ? Object.values(v) : []);
        // cells come as {text, ...} ; plain text too
        const cellsOf = (v) => asList(v).map((c) => (c && typeof c === "object" ? c : { text: String(c) }));

        this.positions = POSITIONS;
        this.groups = {};
        let list = [];

        const selfID = () => {
            const s = beamjoyStore.players.self;
            return s && s.playerID !== undefined && s.playerID !== null ? String(s.playerID) : null;
        };
        const isYou = (row, me) =>
            !!row.you || (me !== null && row.playerId !== undefined && row.playerId !== null && String(row.playerId) === me);
        const cellStyle = (c, column) => {
            const style = {};
            if (c.color) style.color = color(c.color);
            const align = c.align || (column && column.align);
            if (align) style["text-align"] = align;
            return style;
        };

        // one push's overlay, made ready to draw
        const prepare = (entry) => {
            const o = entry.overlay || {};
            const me = selfID();
            o._anchor = Date.now() - (entry.ageMs || 0);
            o._expiresAt = typeof o.remainingMs === "number" ? o._anchor + o.remainingMs : null;
            o._accent = color(o.accent);
            if (o.layout === "custom") {
                o.blocks = asList(o.blocks);
                o._style = {};
                if (o.width) o._style.width = `${o.width}em`;
                if (o.background) o._style.background = color(o.background);
                o.blocks.forEach((b) => {
                    b._style = {};
                    if (b.color) b._style.color = color(b.color);
                    if (b.align) b._style["text-align"] = b.align;
                    if (b.type === "row") {
                        b.cells = cellsOf(b.cells);
                        b.cells.forEach((c) => (c._style = cellStyle(c)));
                    } else if (b.type === "bar") {
                        b._fill = { width: `${Math.round(b.value * 100)}%` };
                        if (b.color || o.accent) b._fill.background = color(b.color || o.accent);
                    } else if (b.type === "plate") {
                        b._plate = b.color || o.accent ? { background: color(b.color || o.accent) } : {};
                    } else if (b.type === "segments") {
                        b.items = asList(b.items);
                    } else if (b.type === "table") {
                        b.columns = asList(b.columns);
                        b.rows = asList(b.rows);
                        b.rows.forEach((r) => {
                            r.cells = cellsOf(r.cells);
                            r._you = isYou(r, me);
                            r._style = r.color ? { color: color(r.color) } : {};
                            r.cells.forEach((c, i) => (c._style = cellStyle(c, b.columns[i])));
                        });
                    }
                });
            } else {
                o.lines = asList(o.lines);
                o.segments = asList(o.segments);
                o.rows = asList(o.rows);
                o.rows.forEach((r) => {
                    r._you = isYou(r, me);
                    r._style = r.color ? { color: color(r.color) } : {};
                });
                if (o.plate) o.plate._style = o.plate.color ? { background: color(o.plate.color) } : {};
                o._bar = typeof o.bar === "number" ? { width: `${Math.round(o.bar * 100)}%` } : null;
            }
            return o;
        };

        const regroup = () => {
            const now = Date.now();
            list = list.filter((o) => !o._expiresAt || o._expiresAt > now);
            const groups = {};
            POSITIONS.forEach((p) => (groups[p] = []));
            list.forEach((o) => (groups[POSITIONS.includes(o.position) ? o.position : "top-right"] || groups["top-right"]).push(o));
            this.groups = groups;
            // BeamJoy overlays one of these stands in for (raceHud listens)
            const hides = {};
            list.forEach((o) => asList(o.hides).forEach((h) => (hides[h] = true)));
            $rootScope.$broadcast("BJPluginHides", hides);
        };

        $rootScope.$on("BJPluginOverlays", (_, data) => {
            list = asList(data).map(prepare);
            regroup();
        });
        // your own row follows who you are
        $rootScope.$on("BJUpdateSelf", () => {
            const me = selfID();
            list.forEach((o) => {
                asList(o.rows).forEach((r) => (r._you = isYou(r, me)));
                asList(o.blocks).forEach((b) => asList(b.rows).forEach((r) => (r._you = isYou(r, me))));
            });
        });

        // a running timer's value now ("up" counts on from the plugin's value, "down" counts it down)
        this.timerText = (t, o) => {
            if (!t || typeof t.ms !== "number") return "";
            const elapsed = Date.now() - o._anchor;
            if (t.mode === "up") return f.time(t.ms + elapsed);
            if (t.mode === "down") return f.time(Math.max(0, t.ms - elapsed));
            return f.time(t.ms);
        };

        // the digest that moves running timers along, and takes down overlays whose time is up
        const ticking = () =>
            list.some(
                (o) =>
                    o._expiresAt ||
                    (o.timer && o.timer.mode !== "static") ||
                    asList(o.blocks).some((b) => b.type === "timer" && b.mode !== "static")
            );
        // invokeApply off : nothing to redraw (no digest) while nothing's running
        const tick = $interval(
            () => {
                if (!ticking()) return;
                if (list.some((o) => o._expiresAt && o._expiresAt <= Date.now())) regroup();
                $scope.$applyAsync();
            },
            100,
            0,
            false
        );

        this.$onInit = () => beamjoyStore.send("BJPluginOverlaysRequest");
        $scope.$on("$destroy", () => $interval.cancel(tick));
    },
});
