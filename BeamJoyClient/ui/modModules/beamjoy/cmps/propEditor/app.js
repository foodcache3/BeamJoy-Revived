// The props editor's UI, shared by every editor whose activity has props (direct request : props
// in Hunter, Infected and Derby arenas as in races) : the race editor and the arena editors drop in
// <bj-prop-editor-toolbar> (in their pinned toolbar row, beside their own gizmo and snapping
// buttons) and <bj-prop-editor> (the props list, with the props drawer). Lua's side is
// ui/propEditor.lua, attached to whichever editor is open, so the messages are the same everywhere
// (BJEditorProps*).
//
// The state lives in the beamjoyPropEditor service, not in either component : the toolbar and the
// list sit in different parts of a host's template (the pinned row, the scrolling panel) and share
// it, and a host's section switch rebuilds them without losing it. Lua is the source of truth : the
// props come back after every change (BJEditorPropsUpdate). Only PROP_FIELDS are edited here (the
// list's sliders and switches), diffed and sent like the race editor's gate fields ; everything
// else goes through Lua's own actions.

// the props' fields edited in the list (everything else about a prop is set Lua-side)
const PROP_FIELDS = ["scale", "count", "yaw", "followGround", "gap", "width"];
// a curb or a wall (beamjoy_props SWEEPS) counts as one prop every this many segments (metres), a
// painted line (PAINTS) too (its segments 2 m) : beamjoy_props.SWEEP_WEIGHT_SEGMENTS
const SWEEP_WEIGHT_SEGMENTS = 20;
// the placing switches, kept on this PC (under the drawer's former keys)
const KEEP_KEY = "beamjoy.propDrawer.keepPlacing";
const FIXED_KEY = "beamjoy.propDrawer.fixedRotation";
const DIFF_DEBOUNCE_MS = 150;
const T = (key) => "beamjoy.window.config.tabs.races.props." + key;

const readSwitch = (key) => {
    try {
        return localStorage.getItem(key) === "1";
    } catch (e) {
        return false;
    }
};
const writeSwitch = (key, on) => {
    try {
        localStorage.setItem(key, on ? "1" : "0");
    } catch (e) {
        // kept for this session only
    }
};

angular.module("beamjoy").factory("beamjoyPropEditor", function ($rootScope, $filter, beamjoyStore) {
    const translate = $filter("translate");
    const send = (event, args) => beamjoyStore.send(event, args);
    const stop = (event) => {
        if (event) event.stopPropagation();
    };

    const p = {
        // the most props a race or an arena holds (beamjoy_props.MAX_PROPS)
        MAX: 1000,
        props: [],
        // whether cars hit each prop, from Lua : its own say, else whether its mesh has a collision
        // (direct report : a backdrop or a ground plane said solid, and had none)
        solid: [],
        // as beamjoy_props.weight counts them (the limit) : every prop of a line, and every mesh of a
        // prefab. A plain number, refreshed with each update
        total: 0,
        // the selected prop (0-based), the line's handle the gizmo holds, the props selected together
        active: null,
        part: null,
        selected: [],
        catalog: [],
        // the props drawer (cmps/propDrawer) : opened from the toolbar, or by a placed prop's "Swap
        // mesh" (`swap` : that prop waits for the mesh picked next)
        drawerOpen: false,
        swap: null,
        clipboard: { entries: 0, count: 0, sameMap: false },
        // the props solid as when played, to drive into them (direct request). Lua turns it back off
        // at the next edit, since the game's collision only follows them on a rebuild
        testCollision: false,
        // the selected curb's or wall's end or node, its width (metres) as its slider edits it
        // (direct request : a curb resized at one node). `synced` the value Lua last said, so only
        // a change made here is sent
        handleWidth: null,
        keepPlacing: readSwitch(KEEP_KEY),
        fixedRotation: readSwitch(FIXED_KEY),
    };
    // the props as last received : a field only takes the received value when it wasn't edited
    // here since (a slider dragged while an update was on its way keeps its value)
    let previous = [];

    const countOf = (list) =>
        list.reduce((n, prop) => {
            if (prop.kind === "sweep" || prop.kind === "paint")
                return n + Math.max(1, Math.ceil((Number(prop.count) || 1) / SWEEP_WEIGHT_SEGMENTS));
            const each = 1 + (Array.isArray(prop.parts) ? prop.parts.length : 0);
            const caps = prop.kind === "line" ? (prop.capA ? 1 : 0) + (prop.capB ? 1 : 0) : 0;
            return n + (prop.kind === "line" ? Math.max(1, Number(prop.count) || 1) : 1) * each + caps;
        }, 0);

    // (Lua sends an empty list as {})
    $rootScope.$on("BJEditorPropsUpdate", (_, list) => {
        list = Array.isArray(list) ? list : [];
        if (p.props.length === list.length && previous.length === list.length) {
            list.forEach((echoed, i) => {
                const local = p.props[i];
                const prev = previous[i];
                Object.keys(local).forEach((k) => {
                    if (!PROP_FIELDS.includes(k) && !(k in echoed)) delete local[k];
                });
                Object.keys(echoed).forEach((k) => {
                    if (!PROP_FIELDS.includes(k)) local[k] = echoed[k];
                });
                PROP_FIELDS.forEach((k) => {
                    if (angular.equals(local[k], prev[k])) local[k] = echoed[k];
                });
            });
        } else {
            p.props = list;
        }
        previous = angular.copy(p.props);
        p.total = countOf(p.props);
        refreshHandleWidth();
    });
    $rootScope.$on("BJEditorPropsSolid", (_, list) => {
        p.solid = Array.isArray(list) ? list : [];
    });
    $rootScope.$on("BJEditorPropsActive", (_, active) => {
        p.active = active && active.index ? active.index - 1 : null;
        p.part = (active && active.part) || null;
        p.selected = active && Array.isArray(active.selected) ? active.selected.map((i) => Number(i) - 1) : [];
        refreshHandleWidth();
    });
    $rootScope.$on("BJEditorPropCatalog", (_, catalog) => {
        p.catalog = Array.isArray(catalog) ? catalog : [];
        refreshHandleWidth();
    });
    $rootScope.$on("BJEditorPropsClipboard", (_, state) => {
        p.clipboard = state && typeof state === "object" ? state : { entries: 0, count: 0 };
    });
    $rootScope.$on("BJEditorPropsTestCollision", (_, state) => {
        p.testCollision = state === true;
    });

    // the fields edited here since the last update, sent (the list debounces it)
    p.diff = () => {
        p.props.forEach((prop, i) => {
            const prev = previous[i];
            if (!prev) return;
            const partial = {};
            PROP_FIELDS.forEach((k) => {
                if (!angular.equals(prop[k], prev[k])) {
                    // numbers coerced : bj-slider's typable box can hand back a string
                    if (k === "gap" && !(Number(prop[k]) > 0)) return;
                    partial[k] = k === "followGround" ? prop[k] === true : Number(prop[k]);
                }
            });
            if (Object.keys(partial).length > 0) send("BJEditorPropsSet", [i + 1, partial]);
        });
        previous = angular.copy(p.props);
    };

    // a props panel shown (a host opened, a section switched to) : Lua tells it everything again,
    // and has this PC's placing switches
    p.announce = () => {
        send("BJEditorPropsSetKeepPlacing", [p.keepPlacing]);
        send("BJEditorPropsSetFixedRotation", [p.fixedRotation]);
        send("BJEditorPropsRequestState");
        send("BJEditorPropsClipboardRequest");
    };

    // the catalog's name for a prop's mesh, else the mesh's file name, readable (a game mesh from
    // the drawer's "All game meshes", or one no longer offered)
    p.label = (prop) => {
        // a curb or a wall : its profile's name (the drawer's Curbs & walls tab)
        if (prop && prop.kind === "sweep") {
            const sweep = p.catalog.find((c) => c.sweep === prop.profile);
            return sweep ? sweep.name : String(prop.profile || "");
        }
        // a painted line : its paint's name (the drawer's Paint tab)
        if (prop && prop.kind === "paint") {
            const paint = p.catalog.find((c) => c.paint === prop.paint);
            return paint ? paint.name : String(prop.paint || "");
        }
        // a prefab : its own name (the drawer's Prefabs tab)
        const prefab = prop && prop.prefab && p.catalog.find((c) => c.prefab === prop.prefab);
        if (prefab) return prefab.name;
        const shape = String((prop && prop.shape) || "");
        const entry = p.catalog.find(
            (c) => !c.prefab && !c.sweep && !c.paint && c.shape.toLowerCase() === shape.toLowerCase()
        );
        if (entry) return entry.label;
        const words = shape
            .split("/")
            .pop()
            .replace(/\.c?dae$/i, "")
            .replace(/^(s_|ind_|hr_|ut_|eca_|si_|ak_|clutter_|italy_|bld_|gm_)+/i, "")
            .split(/[_\-]+/)
            .filter((w) => w);
        const name = words.join(" ");
        return name ? name.charAt(0).toUpperCase() + name.slice(1) : shape;
    };

    // CURBS AND WALLS (beamjoy_props SWEEPS) : their profiles, to give a placed one another
    p.sweeps = () => p.catalog.filter((c) => c.sweep);
    p.setProfile = (event, idx, id) => {
        stop(event);
        send("BJEditorPropsSetProfile", [idx + 1, id]);
    };
    // PAINTED LINES (beamjoy_props PAINTS) : their paints, to give a placed one another
    p.paints = () => p.catalog.filter((c) => c.paint);
    p.setPaint = (event, idx, id) => {
        stop(event);
        send("BJEditorPropsSetPaint", [idx + 1, id]);
    };
    // a line's nodes (the points it bends through, beamjoy_props `nodes`), an older line's `mid` its
    // one node
    const isPoint = (v) => !!v && isFinite(v.x) && isFinite(v.y) && isFinite(v.z);
    p.nodesOf = (prop) => {
        if (prop && Array.isArray(prop.nodes) && prop.nodes.length) return prop.nodes;
        return prop && prop.mid ? [prop.mid] : [];
    };
    p.isNodePart = () => typeof p.part === "string" && /^n\d+$/.test(p.part);
    // A CURB'S WIDTH AT AN END OR A NODE (direct request) : the point's `w`, its profile's own
    // width times it (beamjoy_props.SWEEP_WIDTH_MIN / MAX), shown and set in metres
    const WIDTH_MIN = 0.25;
    const WIDTH_MAX = 4;
    const round2 = (v) => Math.round(v * 100) / 100;
    const handlePoint = (prop, part) => {
        if (!prop || typeof part !== "string") return null;
        if (part === "a" || part === "b") return prop[part] || null;
        const m = /^n(\d+)$/.exec(part);
        return m ? p.nodesOf(prop)[Number(m[1]) - 1] || null : null;
    };
    // its profile's own width (the drawer's catalog : beamjoy_props.sweepsForUI)
    const sweepBase = (prop) => {
        const sweep = prop && prop.kind === "sweep" ? p.catalog.find((c) => c.sweep === prop.profile) : null;
        return sweep && Number(sweep.width) > 0 ? Number(sweep.width) : null;
    };
    function refreshHandleWidth() {
        const prop = p.active !== null ? p.props[p.active] : null;
        const point = handlePoint(prop, p.part);
        const base = sweepBase(prop);
        if (!point || !base || p.severalSelected()) {
            p.handleWidth = null;
            return;
        }
        const w = Math.min(Math.max(Number(point.w) || 1, WIDTH_MIN), WIDTH_MAX);
        const metres = round2(base * w);
        const was = p.handleWidth;
        // a slider moved here and not sent yet keeps its value
        const editing = was && was.index === p.active && was.part === p.part && Number(was.metres) !== was.synced;
        p.handleWidth = {
            index: p.active,
            part: p.part,
            base,
            min: round2(base * WIDTH_MIN),
            max: round2(base * 3),
            hardMax: round2(base * WIDTH_MAX),
            metres: editing ? was.metres : metres,
            synced: metres,
        };
    }
    // the slider's value, sent (the list debounces it)
    p.sendHandleWidth = () => {
        const h = p.handleWidth;
        if (!h || !(Number(h.metres) > 0) || Number(h.metres) === h.synced) return;
        h.synced = Number(h.metres);
        send("BJEditorPropsSetHandleWidth", [h.index + 1, h.part, Number(h.metres) / h.base]);
    };
    p.resetHandleWidth = (event) => {
        stop(event);
        const h = p.handleWidth;
        if (!h) return;
        h.metres = round2(h.base);
        h.synced = h.metres;
        send("BJEditorPropsSetHandleWidth", [h.index + 1, h.part, 1]);
    };
    const dist = (u, v) => Math.hypot(u.x - v.x, u.y - v.y, u.z - v.z);
    // points times weights, summed : mix(p1, w1, p2, w2...)
    const mix = (...terms) => {
        const out = { x: 0, y: 0, z: 0 };
        for (let i = 0; i < terms.length; i += 2) {
            out.x += terms[i].x * terms[i + 1];
            out.y += terms[i].y * terms[i + 1];
            out.z += terms[i].z * terms[i + 1];
        }
        return out;
    };
    // its path as beamjoy_props.linePath draws it : straight, through its nodes, or an older line's
    // quadratic Bezier through `mid` halfway
    const pathPoints = (prop) => {
        const a = prop.a;
        const b = prop.b;
        const nodes = Array.isArray(prop.nodes) ? prop.nodes.filter(isPoint) : [];
        if (nodes.length) {
            const k = [a, ...nodes, b];
            const n = k.length;
            const d = [];
            for (let i = 0; i < n - 1; i++) d[i] = Math.max(dist(k[i + 1], k[i]), 1e-3);
            const tan = [];
            for (let i = 1; i < n - 1; i++) {
                const w = 1 / (d[i - 1] + d[i]);
                tan[i] = mix(k[i + 1], w, k[i - 1], -w);
            }
            tan[0] = mix(k[1], 2 / d[0], k[0], -2 / d[0], tan[1], -1);
            tan[n - 1] = mix(k[n - 1], 2 / d[n - 2], k[n - 2], -2 / d[n - 2], tan[n - 2], -1);
            const pts = [a];
            const per = 8;
            for (let i = 0; i < n - 1; i++) {
                for (let s = 1; s <= per; s++) {
                    const t = s / per;
                    const t2 = t * t;
                    const t3 = t2 * t;
                    pts.push(mix(k[i], 2 * t3 - 3 * t2 + 1, tan[i], (t3 - 2 * t2 + t) * d[i],
                        k[i + 1], 3 * t2 - 2 * t3, tan[i + 1], (t3 - t2) * d[i]));
                }
            }
            return pts;
        }
        const m = prop.mid;
        if (!isPoint(m)) return [a, b];
        const c = mix(m, 2, a, -0.5, b, -0.5);
        const pts = [];
        for (let s = 0; s <= 32; s++) {
            const t = s / 32;
            const u = 1 - t;
            pts.push(mix(a, u * u, c, 2 * u * t, b, t * t));
        }
        return pts;
    };
    // its length along its path (metres, a bent one measured along its curve)
    p.pathLength = (prop) => {
        if (!prop || !isPoint(prop.a) || !isPoint(prop.b)) return 0;
        const pts = pathPoints(prop);
        let total = 0;
        for (let k = 1; k < pts.length; k++) total += dist(pts[k], pts[k - 1]);
        return Math.round(total);
    };

    // DRAWER
    p.toggleDrawer = (event) => {
        stop(event);
        if (p.drawerOpen) p.closeDrawer();
        else p.drawerOpen = true;
    };
    p.closeDrawer = () => {
        if (p.drawerOpen) send("BJEditorPropsDisarm");
        p.drawerOpen = false;
        p.swap = null;
    };
    p.endSwap = () => {
        p.swap = null;
    };
    // a placed prop waits for a mesh picked in the drawer : its own ("Swap mesh"), its line's
    // other mesh (`alt` : red and white barriers in turn) or an end cap (`cap` : "a" or "b")
    const pickFor = (idx, extra) => {
        const prop = p.props[idx];
        if (!prop) return;
        send("BJEditorPropsDisarm");
        p.swap = Object.assign({ index: idx, name: translate(p.label(prop)) }, extra);
        p.drawerOpen = true;
    };
    p.isSwapPick = (idx) => !!(p.swap && p.swap.index === idx && !p.swap.alt && !p.swap.cap);
    p.isAltPick = (idx) => !!(p.swap && p.swap.index === idx && p.swap.alt);
    p.isCapPick = (idx, which) => !!(p.swap && p.swap.index === idx && p.swap.cap === which);
    p.swapMesh = (event, idx) => {
        stop(event);
        if (p.isSwapPick(idx)) p.swap = null;
        else pickFor(idx, {});
    };
    p.pickAlt = (event, idx) => {
        stop(event);
        if (p.isAltPick(idx)) p.swap = null;
        else pickFor(idx, { alt: true });
    };
    p.clearAlt = (event, idx) => {
        stop(event);
        send("BJEditorPropsSetAlt", [idx + 1, ""]);
    };
    p.altLabel = (prop) => (prop && prop.alt ? p.label({ shape: prop.alt }) : null);
    p.pickCap = (event, idx, which) => {
        stop(event);
        if (p.isCapPick(idx, which)) p.swap = null;
        else pickFor(idx, { cap: which });
    };
    p.clearCap = (event, idx, which) => {
        stop(event);
        send("BJEditorPropsSetCap", [idx + 1, which, ""]);
    };
    p.flipCap = (event, idx, which) => {
        stop(event);
        send("BJEditorPropsFlipCap", [idx + 1, which]);
    };
    p.capLabel = (prop, which) => {
        const shape = prop && (which === "a" ? prop.capA : prop.capB);
        return shape ? p.label({ shape }) : null;
    };
    // the eyedropper (direct request, in place of Duplicate) : that prop armed in the drawer, to
    // place more of it
    // a prop of a group (or of a selection) : all of them ; Shift : that one alone
    p.eyedrop = (event, idx) => {
        stop(event);
        p.swap = null;
        send("BJEditorPropsEyedrop", [idx + 1, !!(event && event.shiftKey)]);
        p.drawerOpen = true;
    };

    // SELECTION (direct request : multiple selection and groups) : Ctrl+click adds a prop to the
    // selection (or takes it out), Shift+click picks one of a group alone, Ctrl+Shift+click adds or
    // takes out one of a group alone ; a prop of a group brings its group. The selection moves,
    // turns, copies and deletes as one
    p.isSelected = (idx) => p.selected.includes(idx);
    p.severalSelected = () => p.selected.length > 1;
    p.selectionText = () => translate(T("selection.count")).replace("{n}", p.selected.length);
    p.selectionGrouped = () => p.selected.some((i) => p.props[i] && p.props[i].group);
    // a plain click on the selected row unselects : Lua decides, knowing the keys even when this
    // click doesn't carry them (direct report : Ctrl+click on the selected row cleared it all)
    p.select = (event, idx) => {
        stop(event);
        const ctrl = !!(event && event.ctrlKey);
        const shift = !!(event && event.shiftKey);
        const mode = ctrl && shift ? "addAlone" : ctrl ? "add" : shift ? "alone" : "";
        send("BJEditorPropsSelect", [idx + 1, "", mode]);
    };
    p.selectEnd = (event, idx, part) => {
        stop(event);
        send("BJEditorPropsSelect", [idx + 1, part]);
    };
    p.clearSelection = (event) => {
        stop(event);
        send("BJEditorPropsSelect", [null]);
    };
    p.group = (event) => {
        stop(event);
        send("BJEditorPropsGroup");
    };
    p.ungroup = (event) => {
        stop(event);
        send("BJEditorPropsUngroup");
    };
    // the selected prop alone (picked with Shift+click) out of its group
    p.ungroupOne = (event, idx) => {
        stop(event);
        if (p.active !== idx) return;
        send("BJEditorPropsUngroup");
    };
    p.deleteSelected = (event) => {
        stop(event);
        send("BJEditorPropsDeleteSelected");
    };

    // CLIPBOARD (direct request : props pasted into another race or arena) : Copy takes the
    // selection, or every prop when nothing is selected ; Paste adds them where they were. One
    // tooltip for both (direct request : it didn't follow the selection)
    p.copyTooltip = () => translate(T("copy.all"));
    p.pasteTooltip = () => {
        const clip = p.clipboard || {};
        if (!clip.entries) return translate(T("paste.empty"));
        if (!clip.sameMap) return translate(T("paste.otherMap"));
        return translate(T("paste")).replace("{n}", clip.count || clip.entries);
    };
    p.copy = (event) => {
        stop(event);
        send("BJEditorPropsCopy");
    };
    p.paste = (event) => {
        stop(event);
        send("BJEditorPropsPaste");
    };

    // PLACING SWITCHES (direct request : beside the snapping button). "Keep placing" : a prop stays
    // armed after each one placed, as with Ctrl held. "Fixed rotation" (trusses) : a prop placed
    // alone keeps the turn the wheel gave it, whichever way the camera looks
    p.toggleKeepPlacing = (event) => {
        stop(event);
        p.keepPlacing = !p.keepPlacing;
        writeSwitch(KEEP_KEY, p.keepPlacing);
        send("BJEditorPropsSetKeepPlacing", [p.keepPlacing]);
    };
    p.toggleFixedRotation = (event) => {
        stop(event);
        p.fixedRotation = !p.fixedRotation;
        writeSwitch(FIXED_KEY, p.fixedRotation);
        send("BJEditorPropsSetFixedRotation", [p.fixedRotation]);
    };
    p.toggleTestCollision = (event) => {
        stop(event);
        send("BJEditorPropsSetTestCollision", [!p.testCollision]);
    };

    // A PROP'S OWN ACTIONS
    p.isSolid = (idx) => {
        const known = p.solid[idx];
        if (known === true || known === false) return known;
        const prop = p.props[idx];
        return !!prop && prop.solid !== false;
    };
    // cars hit it, or drive through it (direct request)
    p.toggleSolid = (event, idx) => {
        stop(event);
        // a curb or a wall is always solid, a painted line never
        if (!p.props[idx] || p.props[idx].kind === "sweep" || p.props[idx].kind === "paint") return;
        send("BJEditorPropsSetSolid", [idx + 1, !p.isSolid(idx)]);
    };
    // a line's fixed gap (direct request : guardrails chained on a line) : on, a longer line takes
    // more props instead of spreading them out
    p.setFixedGap = (event, idx, on) => {
        stop(event);
        send("BJEditorPropsSet", [idx + 1, { fixedGap: on === true }]);
    };
    const action = (event, name, idx) => {
        stop(event);
        send(name, [idx + 1]);
    };
    p.straighten = (event, idx) => action(event, "BJEditorPropsStraightenLine", idx);
    p.addNode = (event, idx) => action(event, "BJEditorPropsAddNode", idx);
    p.removeNode = (event, idx) => action(event, "BJEditorPropsRemoveNode", idx);
    p.splitLine = (event, idx) => action(event, "BJEditorPropsSplitLine", idx);
    p.splitPrefab = (event, idx) => action(event, "BJEditorPropsSplitPrefab", idx);
    p.deleteProp = (event, idx) => action(event, "BJEditorPropsDelete", idx);
    p.teleportTo = (event, idx) => action(event, "BJEditorPropsTeleportTo", idx);
    p.setToVehicle = (event, idx) => action(event, "BJEditorPropsSetToVehicle", idx);

    return p;
});

// the props' own toolbar buttons : placing switches, collision switch, the drawer, copy and paste,
// the count. Laid out inline (display: contents), as more buttons of the host's toolbar row
angular.module("beamjoy").component("bjPropEditorToolbar", {
    templateUrl: "/ui/modModules/beamjoy/cmps/propEditor/toolbar.html",
    controller: function (beamjoyPropEditor) {
        this.p = beamjoyPropEditor;
    },
});

// the props list (a selected prop's settings under its row) and the props drawer
angular.module("beamjoy").component("bjPropEditor", {
    templateUrl: "/ui/modModules/beamjoy/cmps/propEditor/app.html",
    controller: function ($rootScope, $scope, $timeout, beamjoyPropEditor) {
        const p = beamjoyPropEditor;
        this.p = p;

        this.$onInit = () => p.announce();

        // Lua says which prop is selected whether it was picked here or in the world : its row
        // scrolled into view, once its settings have opened under it
        $scope.$on(
            "$destroy",
            $rootScope.$on("BJEditorPropsActive", () => {
                if (p.active === null) return;
                $timeout(() => {
                    const el = document.getElementById(`bj-prop-row-${p.active}`);
                    if (el) el.scrollIntoView({ behavior: "smooth", block: "nearest" });
                });
            })
        );

        let widthTimeout = null;
        $scope.$watch(
            () => (p.handleWidth ? p.handleWidth.metres : null),
            () => {
                if (widthTimeout) $timeout.cancel(widthTimeout);
                widthTimeout = $timeout(() => {
                    widthTimeout = null;
                    p.sendHandleWidth();
                }, DIFF_DEBOUNCE_MS);
            }
        );

        let diffTimeout = null;
        $scope.$watch(
            () => p.props,
            () => {
                if (diffTimeout) $timeout.cancel(diffTimeout);
                diffTimeout = $timeout(() => {
                    diffTimeout = null;
                    p.diff();
                }, DIFF_DEBOUNCE_MS);
            },
            true
        );
        $scope.$on("$destroy", () => {
            // an edit still waiting goes now, to the props it was made on (the next panel may be
            // another editor's)
            if (diffTimeout) {
                $timeout.cancel(diffTimeout);
                p.diff();
            }
            if (widthTimeout) {
                $timeout.cancel(widthTimeout);
                p.sendHandleWidth();
            }
            // the drawer belongs to the props panel
            p.closeDrawer();
        });
    },
});
