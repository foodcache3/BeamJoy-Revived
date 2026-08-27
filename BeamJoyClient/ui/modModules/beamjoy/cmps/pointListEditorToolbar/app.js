// Split out of bjPointListEditor (translate/rotate/ground-snap only), per direct request: hosting
// this toolbar separately from the point-list rows themselves lets a host template place it in its
// own pinned/fixed region (see hunterArena/app.js's own template, mirroring races/editor's own
// already-established "pinned toolbar above a separately-scrolling list" split) while the list
// keeps scrolling underneath, instead of the toolbar scrolling away with the rows like before.
// State here is entirely driven by the same $rootScope broadcasts bjPointListEditor itself already
// used for this (BJEditorChangeTool is a shared, already-generic event name every editor in this
// codebase reuses as-is ; snapToGround/snapMethod are per-host event names via the `events`
// binding), so this and bjPointListEditor stay in sync automatically with no direct coupling
// between the two components at all.
angular.module("beamjoy").component("bjPointListEditorToolbar", {
    bindings: {
        // {snapToGround, snapMethod, setSnapToGround, setSnapMethod}: only the subset of
        // bjPointListEditor's own `events` binding this toolbar actually needs
        events: "<",
    },
    templateUrl: "/ui/modModules/beamjoy/cmps/pointListEditorToolbar/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.tool = "";
        $rootScope.$on("BJEditorChangeTool", (_, tool) => {
            this.tool = tool;
        });

        this.snapToGroundEnabled = true;
        $rootScope.$on(this.events.snapToGround, (_, state) => {
            this.snapToGroundEnabled = state === true;
        });
        this.snapMethod = "terrain";
        $rootScope.$on(this.events.snapMethod, (_, method) => {
            this.snapMethod = method === "raycast" ? "raycast" : "terrain";
        });
        // single button cycles all three states, per direct request on the race editor's own
        // identical control : off -> terrain (on) -> raycast (on) -> off
        this.cycleSnapMode = () => {
            if (!this.snapToGroundEnabled) {
                beamjoyStore.send(this.events.setSnapToGround, [true]);
                beamjoyStore.send(this.events.setSnapMethod, ["terrain"]);
            } else if (this.snapMethod !== "raycast") {
                beamjoyStore.send(this.events.setSnapMethod, ["raycast"]);
            } else {
                beamjoyStore.send(this.events.setSnapToGround, [false]);
            }
        };

        this.changeTool = (event, tool) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorChangeTool", [tool]);
        };
    },
});
