angular
    .module("beamjoy")
    .directive("ngDragstart", function ($rootScope) {
        return {
            restrict: "A",
            link: function (scope, element, attrs) {
                const onRelease = ($event) => {
                    if (attrs.ngDragend) {
                        scope.$eval(attrs.ngDragend, { $event });
                    }
                    const group = element.parent().attr("group");
                    const dest = $event.target.closest(
                        `bj-sort-separator[group="${group}"]`
                    );
                    const value = dest ? dest.getAttribute("value") : undefined;
                    if (dest && value !== undefined) {
                        $rootScope.$broadcast("BJSortableDrop", group, value);
                    }
                    document.removeEventListener("mouseup", onRelease);
                };
                element.on("mousedown", ($event) => {
                    if (attrs.draggable) {
                        scope.$eval(attrs.ngDragstart, { $event });
                        document.addEventListener("mouseup", onRelease);
                    }
                });
                scope.$on("$destroy", () => {
                    document.removeEventListener("mouseup", onRelease);
                });
            },
        };
    })
    .service("beamjoySortable", function ($rootScope, $timeout) {
        this.dragged = null;
        this.startDrag = (draggableCmp) => {
            this.dragged = draggableCmp;
            $rootScope.$broadcast("BJSortableStartDrag", this.dragged.group);
        };
        const stopDrag = () => {
            if (this.dragged) {
                $rootScope.$broadcast("BJSortableEndDrag");
                this.dragged = null;
            }
        };
        this.endDrag = (draggableCmp) => {
            if (draggableCmp === this.dragged) {
                $timeout(stopDrag, 100);
            }
        };
        this.onDrop = (separatorCmp) => {
            if (this.dragged && this.dragged.group === separatorCmp.group) {
                this.dragged.updateOrder(separatorCmp.value);
                stopDrag();
            }
        };
    })
    .component("bjSortDraggable", {
        bindings: {
            group: "@",
            ngUpdate: "&",
            horizontal: "<?",
        },
        templateUrl: "/ui/modModules/beamjoy/cmps/sortable/draggable.html",
        controller: function (beamjoySortable) {
            this.updateOrder = (newValue) => {
                // bjSortSeparator's `value` is bound via `@` (a plain HTML attribute), which is
                // always a string, so it's coerced here, at the one place every consumer's ng-update
                // receives it, rather than leaving each consumer to accidentally rely on
                // JS operators that happen to coerce strings (`-`, `>`) while others (`+`, string
                // concatenation) silently corrupt it. Confirmed as a real bug via the race
                // editor's own `newIndex + 1` producing a garbled string index, which then threw
                // a Lua error comparing a string against a number server-side.
                this.ngUpdate({ newValue: Number(newValue) });
            };
            this.startDrag = () => {
                beamjoySortable.startDrag(this);
            };
            this.endDrag = () => {
                beamjoySortable.endDrag(this);
            };
        },
    })
    .component("bjSortSeparator", {
        bindings: {
            group: "@",
            value: "@",
        },
        transclude: true,
        templateUrl: "/ui/modModules/beamjoy/cmps/sortable/separator.html",
        controller: function ($rootScope, beamjoySortable) {
            this.active = false;
            $rootScope.$on("BJSortableStartDrag", (_, group) => {
                if (group === this.group) {
                    this.active = true;
                }
            });
            $rootScope.$on("BJSortableDrop", (_, group, value) => {
                if (
                    this.active &&
                    group === this.group &&
                    value === this.value
                ) {
                    beamjoySortable.onDrop(this);
                }
            });
            $rootScope.$on("BJSortableEndDrag", () => {
                this.active = false;
            });
        },
    });
