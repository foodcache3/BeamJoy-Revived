// The race editor's props drawer (direct request) : the prop picker that replaced the editor's
// small dropdown. It slides out beside the config window, over the game view (or covers the
// window when there's no room beside it), and folds to a slim strip while a prop is armed.
//
// Two lists : the curated catalog (beamjoy_props.CATALOG, sent as BJEditorPropCatalog, with
// categories and hand-written tags) and every mesh the game has (beamjoy_propPicker's index, its
// names and tags made from each file path). Search matches every word against a prop's name,
// tags and category, synonyms folded in. Favourites and Recent are this PC's own (localStorage).
//
// Thumbnails are rendered on demand by beamjoy_propPicker (one at a time, the hovered tile first,
// then the tiles in view) ; the grid only builds the tiles in view, so the few thousand game
// meshes scroll as smoothly as the curated hundred.
//
// Picking a tile arms it (BJEditorRaceArmProp) : the race editor's placing mode takes the mouse
// over the world (ui/raceEditor.lua PLACING) and tells back what it's doing (BJEditorRacePlacing).
// With a placed prop in "swap" (the editor's "Swap mesh"), picking a tile gives it that mesh.

const FAV_KEY = "beamjoy.propDrawer.favourites";
// where the player moved the drawer (fractions of the screen), none while it sits by the window
const POSITION_KEY = "beamjoy.propDrawer.position";
const RECENT_KEY = "beamjoy.propDrawer.recent";
const RECENT_MAX = 16;
const KEEP_KEY = "beamjoy.propDrawer.keepPlacing";

// search words folded onto the word the props use
const SYNONYMS = {
    tyre: "tire",
    tyres: "tire",
    tires: "tire",
    pylon: "cone",
    pylons: "cone",
    arch: "truss",
    gantry: "truss",
    gate: "truss",
    ribbon: "tape",
    box: "crate",
    boxes: "crate",
    drum: "barrel",
    kicker: "ramp",
    jump: "ramp",
    lamp: "light",
    trash: "bin",
    rubbish: "bin",
    armco: "guardrail",
    wall: "barrier",
    sponsor: "banner",
    plant: "bush",
};

// a mesh file's name and tags, from its path : folders that say nothing, and the art team's
// prefixes, left out
const SKIP_DIRS = new Set(["art", "shapes", "assets", "meshes", "levels", "garage_and_dealership"]);
const NAME_PREFIX = /^(s_|ind_|hr_|ut_|eca_|si_|ak_|clutter_|italy_|bld_|gm_)/i;

const readList = (key) => {
    try {
        const list = JSON.parse(localStorage.getItem(key) || "[]");
        return Array.isArray(list) ? list.filter((s) => typeof s === "string") : [];
    } catch (e) {
        return [];
    }
};
const writeList = (key, list) => {
    try {
        localStorage.setItem(key, JSON.stringify(list));
    } catch (e) {
        // storage refused (restricted CEF context) : kept for this session only
    }
};

const fileWords = (shape) => {
    let file = String(shape).split("/").pop().replace(/\.c?dae$/i, "");
    let prev;
    do {
        prev = file;
        file = file.replace(NAME_PREFIX, "");
    } while (file !== prev);
    return file
        .replace(/([a-z])([A-Z])/g, "$1 $2")
        .split(/[_\-\s]+/)
        .filter((w) => w && !/^0\d+$/.test(w));
};
const meshName = (shape) => {
    const name = fileWords(shape).join(" ");
    return name ? name.charAt(0).toUpperCase() + name.slice(1) : String(shape).split("/").pop();
};
const meshTags = (shape) =>
    String(shape)
        .split("/")
        .slice(1, -1)
        .filter((d) => !SKIP_DIRS.has(d.toLowerCase()))
        .join(" ")
        .replace(/_/g, " ")
        .toLowerCase();
const meshGroup = (shape) => {
    const s = String(shape).toLowerCase();
    if (s.startsWith("/levels/")) return "map";
    if (s.startsWith("/assets/")) return "assets";
    return "art";
};

const fmt = (n) => (Math.round(n * 10) / 10).toFixed(1);

angular.module("beamjoy").component("bjPropDrawer", {
    bindings: {
        open: "<",
        catalog: "<",
        // { index (0-based), name } while a placed prop waits for its new mesh, else null
        swap: "<",
        propTotal: "<",
        propMax: "<",
        onClose: "&",
        onSwapEnd: "&",
    },
    templateUrl: "/ui/modModules/beamjoy/windows/config/races/editor/propDrawer/app.html",
    controller: function ($rootScope, $scope, $element, $filter, $timeout, beamjoyStore) {
        const translate = $filter("translate");
        const T = (key) => translate("beamjoy.window.config.tabs.races.props.drawer." + key);
        this.T = T;

        this.CATEGORIES = ["barriers", "fences", "markers", "signs", "start", "ramps", "scenery", "utility"];
        this.GROUPS = ["art", "assets", "map"];
        this.tab = "curated";
        this.category = { curated: "all", all: "all" };
        this.query = "";
        this.curated = [];
        this.meshes = null; // the game's meshes, once indexed
        this.meshesLoading = false;
        this.favourites = readList(FAV_KEY);
        this.recent = readList(RECENT_KEY);
        this.thumbs = {}; // shape (lower case) -> { done, url }
        this.sizes = {}; // shape (lower case) -> { x, y, z, minZ }
        this.filtered = [];
        this.visible = [];
        this.offsetY = 0;
        this.totalH = 0;
        this.cols = 3;
        this.cursor = -1;
        this.hovered = null;
        this.placing = { armed: false };
        this.stripExpanded = false;
        this.pos = { mode: "hidden", panel: {}, strip: {}, preview: {}, dock: false };

        const byShape = {};
        const keyOf = (shape) => String(shape || "").toLowerCase();

        // ITEMS ------------------------------------------------------------------------------

        const finish = (item) => {
            item.catName = item.cat ? translate("beamjoy.props.categories." + item.cat) : "";
            item.hay = `${item.name} ${item.tags} ${item.catName} ${fileWords(item.shape).join(" ")}`.toLowerCase();
            return item;
        };
        const buildCurated = () => {
            this.curated = (Array.isArray(this.catalog) ? this.catalog : []).map((c) => {
                const name = translate(c.label);
                const item = finish({
                    key: keyOf(c.shape),
                    shape: c.shape,
                    name: name && name !== c.label ? name : meshName(c.shape),
                    cat: c.cat,
                    tags: c.tags || "",
                    solid: c.solid !== false,
                    map: !!c.map,
                    length: c.length,
                    curated: true,
                });
                if (c.size) this.sizes[item.key] = c.size;
                return item;
            });
            this.curated.forEach((item) => (byShape[item.key] = item));
        };
        const meshItem = (shape) =>
            finish({
                key: keyOf(shape),
                shape,
                name: meshName(shape),
                cat: null,
                group: meshGroup(shape),
                tags: meshTags(shape),
                solid: true,
                map: meshGroup(shape) === "map",
                curated: false,
            });
        // a favourite or recent prop, whichever list it's from (a game mesh before the index is in)
        const entryFor = (shape) => byShape[keyOf(shape)] || (byShape[keyOf(shape)] = meshItem(shape));

        // LIST -------------------------------------------------------------------------------

        const tokens = () =>
            this.query
                .toLowerCase()
                .split(/\s+/)
                .filter((t) => t.length > 0);
        const matches = (item, words) =>
            words.every((w) => {
                if (item.hay.includes(w)) return true;
                if (SYNONYMS[w] && item.hay.includes(SYNONYMS[w])) return true;
                return w.length > 3 && w.endsWith("s") && item.hay.includes(w.slice(0, -1));
            });
        const source = () => {
            const cat = this.category[this.tab];
            if (cat === "favourites") return this.favourites.map(entryFor);
            if (cat === "recent") return this.recent.map(entryFor);
            if (this.tab === "curated") {
                return cat === "all" ? this.curated : this.curated.filter((i) => i.cat === cat);
            }
            const meshes = this.meshes || [];
            return cat === "all" ? meshes : meshes.filter((i) => i.group === cat);
        };
        // every count shown (the rail's and the two tabs') is of what the search matches (direct
        // request)
        this.counts = {};
        this.tabCounts = { curated: 0, all: null };
        const countRail = () => {
            const words = tokens();
            const match = (i) => matches(i, words);
            const curated = this.curated.filter(match);
            const meshes = this.meshes ? this.meshes.filter(match) : null;
            const counts = {
                favourites: this.favourites.map(entryFor).filter(match).length,
                recent: this.recent.map(entryFor).filter(match).length,
            };
            if (this.tab === "curated") {
                counts.all = curated.length;
                this.CATEGORIES.forEach((c) => (counts[c] = 0));
                curated.forEach((i) => (counts[i.cat] = (counts[i.cat] || 0) + 1));
            } else {
                counts.all = (meshes || []).length;
                this.GROUPS.forEach((g) => (counts[g] = 0));
                (meshes || []).forEach((i) => (counts[i.group] = (counts[i.group] || 0) + 1));
            }
            this.counts = counts;
            this.tabCounts = { curated: curated.length, all: meshes ? meshes.length : null };
        };
        this.railItems = () => (this.tab === "curated" ? this.CATEGORIES : this.GROUPS);
        this.railName = (id) =>
            this.tab === "curated" ? translate("beamjoy.props.categories." + id) : T("groups." + id);

        const refilter = (keepScroll) => {
            const words = tokens();
            this.filtered = source().filter((i) => matches(i, words));
            if (this.cursor >= this.filtered.length) this.cursor = this.filtered.length - 1;
            countRail();
            const wrap = gridWrap();
            if (wrap && !keepScroll) wrap.scrollTop = 0;
            layoutGrid();
        };
        let searchTimer = null;
        this.onQuery = () => {
            // a short pause before filtering a few thousand meshes ; the curated list at once
            if (searchTimer) $timeout.cancel(searchTimer);
            if (this.tab === "curated") return refilter();
            searchTimer = $timeout(() => refilter(), 120);
        };
        this.clearQuery = () => {
            this.query = "";
            refilter();
        };

        this.setTab = (tab) => {
            if (this.tab === tab) return;
            this.tab = tab;
            this.cursor = -1;
            if (tab === "all" && !this.meshes && !this.meshesLoading) {
                this.meshesLoading = true;
                beamjoyStore.send("BJPropIndexRequest");
            }
            refilter();
        };
        this.setCategory = (cat) => {
            this.category[this.tab] = cat;
            this.cursor = -1;
            refilter();
        };
        this.emptyText = () => {
            const cat = this.category[this.tab];
            if (this.query) return T("empty.search").replace("{query}", this.query);
            if (cat === "favourites") return T("empty.favourites");
            if (cat === "recent") return T("empty.recent");
            if (this.tab === "all" && this.meshesLoading) return T("loadingMeshes");
            return T("empty.category");
        };

        // FAVOURITES / RECENT --------------------------------------------------------------

        this.isFavourite = (item) => this.favourites.some((s) => keyOf(s) === item.key);
        this.toggleFavourite = (event, item) => {
            event.stopPropagation();
            this.favourites = this.isFavourite(item)
                ? this.favourites.filter((s) => keyOf(s) !== item.key)
                : [item.shape].concat(this.favourites);
            writeList(FAV_KEY, this.favourites);
            if (this.category[this.tab] === "favourites") refilter(true);
            else countRail();
        };
        const remember = (item) => {
            this.recent = [item.shape].concat(this.recent.filter((s) => keyOf(s) !== item.key)).slice(0, RECENT_MAX);
            writeList(RECENT_KEY, this.recent);
            countRail();
        };

        // GRID (only the tiles in view are built) --------------------------------------------

        const root = $element[0];
        const gridWrap = () => root.querySelector(".pd-gridwrap");
        const fontPx = () => parseFloat(getComputedStyle(root).fontSize) || 14;
        // a tile and the gap under it (.pd-tile height + .pd-grid gap, in em)
        const ROW_EM = 11.6;
        const TILE_MIN_EM = 7;
        let slice = { first: -1, last: -1 };
        let gridWidth = 0;
        const layoutGrid = () => {
            const wrap = gridWrap();
            const fs = fontPx();
            const width = wrap ? wrap.clientWidth : 0;
            gridWidth = width;
            this.cols = Math.max(2, Math.floor((width - 1.6 * fs) / ((TILE_MIN_EM + 0.6) * fs)) || 3);
            this.rowH = ROW_EM * fs;
            const rows = Math.ceil(this.filtered.length / this.cols);
            this.totalH = rows * this.rowH;
            slice = { first: -1, last: -1 };
            updateSlice();
        };
        const updateSlice = () => {
            const wrap = gridWrap();
            const scrollTop = wrap ? wrap.scrollTop : 0;
            const viewH = wrap && wrap.clientHeight > 0 ? wrap.clientHeight : 600;
            const first = Math.max(0, Math.floor(scrollTop / this.rowH) - 1);
            const last = Math.ceil((scrollTop + viewH) / this.rowH) + 1;
            if (first === slice.first && last === slice.last) return false;
            slice = { first, last };
            this.visible = this.filtered.slice(first * this.cols, last * this.cols).map((item, i) => ({
                item,
                index: first * this.cols + i,
            }));
            this.offsetY = first * this.rowH;
            requestThumbs();
            return true;
        };
        const onScroll = () => {
            if (updateSlice()) $scope.$applyAsync();
        };
        const scrollToCursor = () => {
            const wrap = gridWrap();
            if (!wrap || this.cursor < 0) return;
            const top = Math.floor(this.cursor / this.cols) * this.rowH;
            if (top < wrap.scrollTop) wrap.scrollTop = top;
            else if (top + this.rowH > wrap.scrollTop + wrap.clientHeight)
                wrap.scrollTop = top + this.rowH - wrap.clientHeight;
            updateSlice();
        };

        // THUMBNAILS -------------------------------------------------------------------------

        let thumbTimer = null;
        let lastThumbRequest = "";
        const sendThumbRequest = () => {
            thumbTimer = null;
            if (!this.open) return;
            const wanted = [];
            const seen = new Set();
            const add = (item) => {
                if (!item || seen.has(item.key)) return;
                seen.add(item.key);
                const t = this.thumbs[item.key];
                if (!t || !t.done) {
                    wanted.push(item.shape);
                    this.thumbs[item.key] = { done: false };
                }
            };
            add(this.hovered);
            if (this.placing.armed) add(entryFor(this.placing.shape));
            this.visible.forEach((v) => add(v.item));
            const key = wanted.join("|");
            if (wanted.length > 0 && key !== lastThumbRequest) beamjoyStore.send("BJPropThumbsRequest", [wanted]);
            lastThumbRequest = key;
        };
        // the visible tiles settle first (scrolling sends one request, not one per frame)
        const requestThumbs = (now) => {
            if (thumbTimer) $timeout.cancel(thumbTimer);
            thumbTimer = now ? (sendThumbRequest(), null) : $timeout(sendThumbRequest, 150, false);
        };
        const takeThumb = (data) => {
            if (!data || typeof data.shape !== "string") return;
            const key = keyOf(data.shape);
            this.thumbs[key] = { done: true, url: typeof data.url === "string" ? data.url : null };
            if (data.size && typeof data.size === "object") this.sizes[key] = data.size;
        };
        $scope.$on("$destroy", $rootScope.$on("BJPropThumb", (_, data) => takeThumb(data)));
        $scope.$on(
            "$destroy",
            $rootScope.$on("BJPropThumbs", (_, list) => (Array.isArray(list) ? list : []).forEach(takeThumb))
        );
        this.thumbOf = (item) => item && this.thumbs[item.key];

        // SIZE / COLLISION TEXT --------------------------------------------------------------

        this.sizeOf = (item) => item && this.sizes[item.key];
        this.tileSize = (item) => {
            const s = this.sizeOf(item);
            if (s) return `${fmt(Math.max(s.x, s.y))} m`;
            return item.length ? `${fmt(item.length)} m` : "";
        };
        this.dims = (item) => {
            const s = this.sizeOf(item);
            return s ? `${fmt(s.x)} × ${fmt(s.y)} × ${fmt(s.z)} m` : T("preview.unmeasured");
        };

        // MESH INDEX -------------------------------------------------------------------------

        $scope.$on(
            "$destroy",
            $rootScope.$on("BJPropIndex", (_, data) => {
                const shapes = data && Array.isArray(data.shapes) ? data.shapes : [];
                this.meshes = shapes.map((shape) => {
                    const known = byShape[keyOf(shape)];
                    if (known && known.curated) {
                        // the catalog's name, grouped with the rest
                        return Object.assign({}, known, { group: meshGroup(shape) });
                    }
                    return (byShape[keyOf(shape)] = meshItem(shape));
                });
                this.meshesLoading = false;
                if (this.tab === "all") refilter(true);
            })
        );

        // PICKING ----------------------------------------------------------------------------

        this.isArmed = (item) => this.placing.armed && keyOf(this.placing.shape) === item.key;
        this.pick = (item) => {
            if (!item) return;
            if (this.swap) {
                beamjoyStore.send("BJEditorRaceSwapPropShape", [this.swap.index + 1, item.shape]);
                remember(item);
                this.onSwapEnd();
                return;
            }
            if (this.isArmed(item)) {
                beamjoyStore.send("BJEditorRaceDisarmProp");
                return;
            }
            this.stripExpanded = false;
            beamjoyStore.send("BJEditorRaceArmProp", [item.shape]);
            remember(item);
        };
        this.disarm = () => beamjoyStore.send("BJEditorRaceDisarmProp");
        // "Keep placing" (direct request) : a prop stays armed after each one placed, as with
        // Shift held, so several go down without picking it again. Kept on this PC
        this.keepPlacing = false;
        try {
            this.keepPlacing = localStorage.getItem(KEEP_KEY) === "1";
        } catch (e) {
            this.keepPlacing = false;
        }
        const sendKeepPlacing = () => beamjoyStore.send("BJEditorRaceSetKeepPlacing", [this.keepPlacing]);
        this.toggleKeepPlacing = (event) => {
            if (event) event.stopPropagation();
            this.keepPlacing = !this.keepPlacing;
            try {
                localStorage.setItem(KEEP_KEY, this.keepPlacing ? "1" : "0");
            } catch (e) {
                // kept for this session only
            }
            sendKeepPlacing();
        };
        this.expandStrip = () => {
            this.stripExpanded = true;
            $timeout(() => {
                layoutGrid();
                reposition();
            });
        };
        this.folded = () => this.placing.armed && !this.stripExpanded && !this.swap;
        this.armedItem = () => (this.placing.armed ? entryFor(this.placing.shape) : null);
        $scope.$on(
            "$destroy",
            $rootScope.$on("BJEditorRacePlacing", (_, state) => {
                const wasArmed = this.placing.armed;
                this.placing = state && typeof state === "object" ? state : { armed: false };
                if (!this.placing.armed) this.stripExpanded = false;
                if (this.placing.armed !== wasArmed) {
                    this.hovered = null;
                    $timeout(() => {
                        reposition();
                        layoutGrid();
                    });
                }
            })
        );

        // BUDGET (the race's 200 props) : what's used, and what the prop or line under the mouse
        // would add ; amber from 90 %, red once full
        this.budget = () => {
            const max = Math.max(1, Number(this.propMax) || 200);
            const used = Math.min(max, Number(this.propTotal) || 0);
            const adding =
                this.placing.armed && (this.placing.overWorld || this.placing.dragging)
                    ? Math.min(max - used, Number(this.placing.count) || 0)
                    : 0;
            const after = used + adding;
            return {
                used,
                adding,
                max,
                usedPct: (used / max) * 100,
                addingPct: (adding / max) * 100,
                level: after >= max ? "full" : after >= max * 0.9 ? "warn" : "ok",
            };
        };
        this.budgetText = () => {
            const b = this.budget();
            return b.adding > 0 ? `${b.used} + ${b.adding} / ${b.max}` : `${b.used} / ${b.max}`;
        };

        this.close = () => {
            if (this.placing.armed) this.disarm();
            if (this.swap) this.onSwapEnd();
            this.onClose();
        };
        this.cancelSwap = () => this.onSwapEnd();

        // HOVER PREVIEW ----------------------------------------------------------------------

        this.enter = (event, item) => {
            this.hovered = item;
            requestThumbs(true);
            if (!this.pos.dock && event && event.currentTarget) {
                const r = event.currentTarget.getBoundingClientRect();
                const fs = fontPx();
                const h = 20 * fs;
                const top = Math.max(0.5 * fs, Math.min(r.top - 0.5 * fs, window.innerHeight - h - 0.5 * fs));
                this.pos.preview = Object.assign({}, this.pos.preview, { top: `${top}px` });
            }
        };
        this.leave = (item) => {
            if (this.hovered === item) this.hovered = null;
        };
        // the docked preview (cover mode) shows the hovered prop, else the keyboard's one
        this.previewItem = () => this.hovered || (this.cursor >= 0 ? this.filtered[this.cursor] : null);

        // KEYBOARD ---------------------------------------------------------------------------

        this.onKey = (event) => {
            const inSearch = event.target && event.target.tagName === "INPUT";
            const count = this.filtered.length;
            const move = (delta) => {
                event.preventDefault();
                if (count === 0) return;
                this.cursor = this.cursor < 0 ? 0 : Math.max(0, Math.min(count - 1, this.cursor + delta));
                scrollToCursor();
            };
            switch (event.key) {
                case "ArrowDown":
                    return move(this.cols);
                case "ArrowUp":
                    return move(-this.cols);
                case "ArrowRight":
                    if (!inSearch) move(1);
                    return;
                case "ArrowLeft":
                    if (!inSearch) move(-1);
                    return;
                case "Enter":
                    event.preventDefault();
                    if (this.cursor >= 0) this.pick(this.filtered[this.cursor]);
                    else if (count === 1) this.pick(this.filtered[0]);
                    return;
                case "Escape":
                    event.preventDefault();
                    event.stopPropagation();
                    if (this.query) this.clearQuery();
                    else if (this.placing.armed) this.disarm();
                    else if (this.swap) this.cancelSwap();
                    else this.close();
                    return;
                case "/":
                    if (!inSearch) {
                        event.preventDefault();
                        focusSearch();
                    }
                    return;
            }
        };
        const focusSearch = () => {
            const input = root.querySelector(".pd-search input");
            if (input) input.focus();
        };
        // "/" anywhere in the UI while the drawer is open
        const onDocumentKey = (event) => {
            if (!this.open || this.folded() || event.key !== "/") return;
            const tag = event.target && event.target.tagName;
            if (tag === "INPUT" || tag === "TEXTAREA") return;
            event.preventDefault();
            focusSearch();
        };
        document.addEventListener("keydown", onDocumentKey);

        // PLACEMENT ON SCREEN ----------------------------------------------------------------
        // beside the config window, on whichever side has room (left first), over the game view ;
        // covering the window's content when neither side has. Measured from the window itself,
        // which the player can move and resize, so it's checked again a few times a second.

        let anchor = null;
        let lastPos = "";
        // moved by its header (direct request) : kept where it was left, on this PC, until docked
        let floating = null;
        try {
            const saved = JSON.parse(localStorage.getItem(POSITION_KEY) || "null");
            if (saved && Number.isFinite(saved.x) && Number.isFinite(saved.y)) floating = saved;
        } catch (e) {
            floating = null;
        }
        this.isFloating = () => floating !== null;
        this.dragging = false;
        const PANEL_EM = 36;
        const PANEL_MIN_EM = 27;
        const PREVIEW_EM = 17;
        const STRIP_EM = 5.4;
        const reposition = () => {
            if (!anchor || !this.open) return;
            const wrap = gridWrap();
            if (wrap && wrap.clientWidth > 0 && wrap.clientWidth !== gridWidth) {
                layoutGrid();
                $scope.$applyAsync();
            }
            const fs = parseFloat(getComputedStyle(anchor).fontSize) || 14;
            root.style.fontSize = `${fs}px`;
            const r = anchor.getBoundingClientRect();
            const vw = window.innerWidth;
            const gap = 0.6 * fs;
            const margin = 0.4 * fs;
            const pos = { mode: "hidden", panel: {}, strip: {}, preview: {}, dock: false };
            if (r.width > 0 && r.height > 0) {
                const top = r.top + 2.4 * fs;
                const height = Math.max(10 * fs, r.bottom - top);
                const spaceL = r.left - gap - margin;
                const spaceR = vw - r.right - gap - margin;
                let left, width;
                if (spaceL >= PANEL_MIN_EM * fs) {
                    pos.mode = "left";
                    width = Math.min(PANEL_EM * fs, spaceL);
                    left = r.left - gap - width;
                } else if (spaceR >= PANEL_MIN_EM * fs) {
                    pos.mode = "right";
                    width = Math.min(PANEL_EM * fs, spaceR);
                    left = r.right + gap;
                } else {
                    pos.mode = "cover";
                    width = r.width;
                    left = r.left;
                }
                if (floating) {
                    // anywhere on screen, kept whole on it : the default width, the window's height
                    const vh = window.innerHeight;
                    pos.mode = "float";
                    width = Math.min(PANEL_EM * fs, vw - 2 * margin);
                    const h = Math.min(Math.max(height, 20 * fs), vh - 2 * margin);
                    left = Math.min(Math.max(floating.x * vw, margin), vw - width - margin);
                    const ftop = Math.min(Math.max(floating.y * vh, margin), vh - h - margin);
                    pos.panel = { left: `${left}px`, top: `${ftop}px`, width: `${width}px`, height: `${h}px` };
                    pos.strip = { left: `${left}px`, top: `${ftop}px` };
                    const pvW = PREVIEW_EM * fs;
                    if (left - gap - pvW >= margin) pos.preview = { left: `${left - gap - pvW}px`, width: `${pvW}px` };
                    else if (left + width + gap + pvW <= vw - margin)
                        pos.preview = { left: `${left + width + gap}px`, width: `${pvW}px` };
                    else pos.dock = true;
                    if (this.pos.preview && this.pos.preview.top) pos.preview.top = this.pos.preview.top;
                    return applyPos(pos);
                }
                pos.panel = { left: `${left}px`, top: `${top}px`, width: `${width}px`, height: `${height}px` };
                const stripW = STRIP_EM * fs;
                const stripLeft =
                    pos.mode === "left"
                        ? r.left - gap - stripW
                        : pos.mode === "right"
                          ? r.right + gap
                          : r.left + 0.5 * fs;
                pos.strip = { left: `${stripLeft}px`, top: `${top + (pos.mode === "cover" ? 0.5 * fs : 0)}px` };
                const pvW = PREVIEW_EM * fs;
                if (pos.mode === "left" && left - gap - pvW >= margin) {
                    pos.preview = { left: `${left - gap - pvW}px`, width: `${pvW}px` };
                } else if (pos.mode === "right" && left + width + gap + pvW <= vw - margin) {
                    pos.preview = { left: `${left + width + gap}px`, width: `${pvW}px` };
                } else {
                    pos.dock = true;
                }
                if (this.pos.preview && this.pos.preview.top) pos.preview.top = this.pos.preview.top;
            }
            applyPos(pos);
        };
        const applyPos = (pos) => {
            const key = JSON.stringify(pos);
            if (key === lastPos) return;
            const resized = !lastPos || JSON.parse(lastPos).panel.width !== pos.panel.width;
            lastPos = key;
            this.pos = pos;
            $scope.$applyAsync(() => {
                if (resized) $timeout(layoutGrid);
            });
        };

        // dragged by its header, the panel moved straight away (no digest per mouse move) ; where
        // it lands is kept once it's let go
        let drag = null;
        const panelEl = () => root.querySelector(".pd-panel");
        const onDragMove = (event) => {
            const el = panelEl();
            if (!drag || !el) return;
            const vw = window.innerWidth;
            const vh = window.innerHeight;
            const left = Math.min(Math.max(drag.left + event.clientX - drag.x, 0), vw - drag.width);
            const top = Math.min(Math.max(drag.top + event.clientY - drag.y, 0), vh - drag.height);
            el.style.left = `${left}px`;
            el.style.top = `${top}px`;
            floating = { x: left / vw, y: top / vh };
        };
        const onDragEnd = () => {
            document.removeEventListener("mousemove", onDragMove);
            document.removeEventListener("mouseup", onDragEnd);
            if (!drag) return;
            drag = null;
            try {
                if (floating) localStorage.setItem(POSITION_KEY, JSON.stringify(floating));
            } catch (e) {
                // kept for this session only
            }
            $scope.$applyAsync(() => {
                this.dragging = false;
                lastPos = "";
                reposition();
            });
        };
        this.startDrag = (event) => {
            if (event.button !== 0 || (event.target.closest && event.target.closest("button"))) return;
            const el = panelEl();
            if (!el) return;
            const r = el.getBoundingClientRect();
            drag = { x: event.clientX, y: event.clientY, left: r.left, top: r.top, width: r.width, height: r.height };
            this.dragging = true;
            this.hovered = null;
            document.addEventListener("mousemove", onDragMove);
            document.addEventListener("mouseup", onDragEnd);
            event.preventDefault();
        };
        // back beside the config window
        this.dock = (event) => {
            if (event) event.stopPropagation();
            if (event && event.target.closest && event.type === "dblclick" && event.target.closest("button")) return;
            floating = null;
            try {
                localStorage.removeItem(POSITION_KEY);
            } catch (e) {
                // nothing saved
            }
            lastPos = "";
            reposition();
        };
        let watcher = null;
        const startWatching = () => {
            if (watcher) return;
            reposition();
            watcher = setInterval(reposition, 250);
            window.addEventListener("resize", reposition);
        };
        const stopWatching = () => {
            if (watcher) clearInterval(watcher);
            watcher = null;
            window.removeEventListener("resize", reposition);
        };

        // the same scroll step as BeamJoy's windows (cmps/window's WHEEL_SCROLL_MULTIPLIER)
        const WHEEL_SCROLL_MULTIPLIER = 4;
        const onWheel = (event) => {
            event.currentTarget.scrollTop += event.deltaY * WHEEL_SCROLL_MULTIPLIER;
            event.preventDefault();
        };

        // LIFECYCLE --------------------------------------------------------------------------

        this.$postLink = () => {
            // the window it sits beside, found before the drawer moves out of it : over the game
            // view, it can't live inside the window (its overflow and transform would clip it)
            anchor = root.parentElement && root.parentElement.closest(".window-wrapper");
            document.body.appendChild(root);
            const wrap = gridWrap();
            if (wrap) wrap.addEventListener("scroll", onScroll, { passive: true });
            root.querySelectorAll(".pd-gridwrap, .pd-rail").forEach((el) =>
                el.addEventListener("wheel", onWheel, { passive: false })
            );
            if (this.open) startWatching();
        };
        this.$onChanges = (changes) => {
            if (changes.catalog) {
                buildCurated();
                refilter(true);
            }
            if (changes.open) {
                if (this.open) {
                    sendKeepPlacing();
                    lastPos = "";
                    startWatching();
                    $timeout(() => {
                        reposition();
                        layoutGrid();
                        requestThumbs(true);
                        focusSearch();
                    });
                } else {
                    stopWatching();
                    this.hovered = null;
                }
            }
        };
        this.$onDestroy = () => {
            stopWatching();
            onDragEnd();
            root.querySelectorAll(".pd-gridwrap, .pd-rail").forEach((el) => el.removeEventListener("wheel", onWheel));
            document.removeEventListener("keydown", onDocumentKey);
            const wrap = gridWrap();
            if (wrap) wrap.removeEventListener("scroll", onScroll);
            if (root.parentNode) root.parentNode.removeChild(root);
        };
    },
});
