// Shared "a few named point-lists, edited via gizmo/world-click + this sidebar" UI: the Angular
// half of `ui/pointListEditor.lua`'s toolkit. Deliberately scoped to just the point-list sections
// themselves : the enabled toggle, gameplay defaults, and the Save button are all genuinely
// per-mode content and stay in each host component's own template, wrapped around this one. The
// translate/rotate/ground-snap toolbar used to live here too, split out into its own
// bjPointListEditorToolbar component instead (per direct request: hosting it separately lets a
// host template pin it above a separately-scrolling list, races/editor's own already-established
// layout, instead of it scrolling away with the rows). Both stay in sync purely through the same
// $rootScope broadcasts (BJEditorChangeTool is a shared, already-generic event name every editor
// in this codebase uses as-is), no direct coupling between the two components at all.
angular.module("beamjoy").component("bjPointListEditor", {
    bindings: {
        // [{key, labelKey, min, hasRadius, hasName, hasTypes, typeOptions}]: color/hasDir/
        // defaultRadius are Lua-only rendering concerns, not needed here. typeOptions is
        // [{key, labelKey}], only meaningful when hasTypes.
        lists: "<",
        // {listsUpdate, activeUpdate, select, create, duplicate, delete, setToVehicle, setRadius?,
        //  setName?, setTypes?, snapToGround, snapMethod, setSnapToGround, setSnapMethod}
        events: "<",
    },
    templateUrl: "/ui/modModules/beamjoy/cmps/pointListEditor/app.html",
    controller: function ($rootScope, $timeout, $filter, beamjoyStore) {
        const translate = $filter("translate");

        this.data = {};
        (this.lists || []).forEach((l) => {
            this.data[l.key] = [];
        });
        $rootScope.$on(this.events.listsUpdate, (_, lists) => {
            this.data = lists || {};
            // Lua can't distinguish an empty table from an empty object, so an emptied-out list
            // can arrive as `{}` instead of `[]`; `{}.length` is undefined, not 0, which showed up
            // as the literal text "undefined" in the count label. Normalize at the boundary, same
            // fix already established elsewhere in this codebase for the same ambiguity.
            (this.lists || []).forEach((l) => {
                if (!Array.isArray(this.data[l.key])) this.data[l.key] = [];
            });
        });

        this.activeList = null;
        this.activeIndex = null;
        // beamjoy_communications_ui.send only ever takes one payload: Lua sends a single
        // {list, index} object here, not two separate broadcast args
        $rootScope.$on(this.events.activeUpdate, (_, active) => {
            active = active || {};
            this.activeList = active.list || null;
            this.activeIndex = active.index ? active.index - 1 : null;
            // Lua is the source of truth for selection and broadcasts this same event whether the
            // point was picked via its sidebar row or by clicking it in the 3D world, so scrolling
            // here covers both. $timeout so this runs after the digest that applies the "active"
            // class has actually happened.
            if (this.activeList && this.activeIndex !== null) {
                $timeout(() => {
                    const el = document.getElementById(
                        `point-list-row-${this.activeList}-${this.activeIndex}`
                    );
                    if (el) el.scrollIntoView({ behavior: "smooth", block: "nearest" });
                });
            }
        });

        this.select = (event, list, index) => {
            event.stopPropagation();
            beamjoyStore.send(this.events.select, [list, index + 1]);
        };
        this.teleportTo = (event, list, index) => {
            event.stopPropagation();
            beamjoyStore.send(this.events.teleportTo, [list, index + 1]);
        };
        this.remove = (event, list, index) => {
            event.stopPropagation();
            beamjoyStore.send(this.events.delete, [list, index + 1]);
        };
        this.create = (event, list) => {
            event.stopPropagation();
            beamjoyStore.send(this.events.create, [list]);
        };
        this.setToVehicle = (event, list, index) => {
            event.stopPropagation();
            beamjoyStore.send(this.events.setToVehicle, [list, index + 1]);
        };
        this.setRadius = (list, index, radius) => {
            if (!this.events.setRadius) return;
            beamjoyStore.send(this.events.setRadius, [list, index + 1, Number(radius)]);
        };
        this.setName = (list, index, name) => {
            if (!this.events.setName) return;
            beamjoyStore.send(this.events.setName, [list, index + 1, name || ""]);
        };
        this.hasType = (point, typeKey) => Array.isArray(point.types) && point.types.includes(typeKey);
        // real, confirmed bug: only the first fuel type ever clicked stayed selected - every
        // click read `point.types` fresh, but nothing ever mutated it locally, only the Lua
        // round-trip echo did. If that echo hadn't landed yet by the next click (which it
        // usually hadn't - same missing-optimistic-update issue as the loopable button), `current`
        // was always stale/empty, so every click effectively computed "just this one type"
        // instead of adding to what was already picked, overwriting the previous selection
        // instead of extending it. Mutate `point.types` directly here too, same as every
        // ng-model-bound field already does, instead of waiting on the round trip.
        this.toggleType = (event, list, index, point, typeKey) => {
            event.stopPropagation();
            if (!this.events.setTypes) return;
            const current = Array.isArray(point.types) ? point.types : [];
            const types = current.includes(typeKey)
                ? current.filter((t) => t !== typeKey)
                : [...current, typeKey];
            point.types = types;
            beamjoyStore.send(this.events.setTypes, [list, index + 1, types]);
        };

        // Real bug: this component gets torn down and recreated every time its host switches away
        // from and back to the tab/section it lives in (an ng-if, not ng-show - see e.g.
        // infectedArena/app.html's own Settings<->Spawns split), losing whatever `this.data` it
        // had. Lua only ever pushes listsUpdate on an actual mutation (or the original open()), so
        // a freshly remounted instance sat empty in the 3D world's own world-space markers still
        // rendered fine, since those come from Lua's own separate renderAll(), unrelated to this
        // component) until the player happened to move a point and trigger a fresh push. Asking
        // for a re-push on mount (same fix as windows/versionCheck's own BJVersionRequest) fixes
        // it regardless of mount timing.
        if (this.events.requestState) {
            beamjoyStore.send(this.events.requestState);
        }

        // "(1)" once at/above the list's own minimum, "(0 - minimum 2)" while under it: the bare
        // slash version this was built from read like a cap/maximum, not a minimum-to-enable
        this.countLabel = (list) => {
            const count = (this.data[list.key] || []).length;
            const min = list.min || 0;
            if (count < min) {
                return `(${count} - ${translate("beamjoy.window.config.editor.pointList.minimumOf")} ${min})`;
            }
            return `(${count})`;
        };
    },
});
