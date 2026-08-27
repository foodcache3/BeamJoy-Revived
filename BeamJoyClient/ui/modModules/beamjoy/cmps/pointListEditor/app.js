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
        // [{key, labelKey, min, hasRadius}]: color/hasDir/defaultRadius are Lua-only rendering
        // concerns, not needed here
        lists: "<",
        // {listsUpdate, activeUpdate, select, create, duplicate, delete, setToVehicle, setRadius?,
        //  snapToGround, snapMethod, setSnapToGround, setSnapMethod}
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
