angular.module("beamjoy").component("bjMainSettings", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/settings/app.html",
    controller: function ($scope, $rootScope, beamjoyStore, beamjoyPluginUi, beamjoyOverlayAnchor) {
        this.resetValues = angular.copy(beamjoyStore.settings.defaults);
        this.settings = angular.copy(beamjoyStore.settings.data);
        $rootScope.$on("BJUserSettings", () => {
           this.settings = angular.copy(beamjoyStore.settings.data)
        });
        // the vehicle settings saved on this PC (automatic lights, dust and particles) : until they
        // arrive the page's own defaults stand in
        beamjoyStore.send("BJRequestVehicleSettings");

        // Real, confirmed bug: this "About" section's version display never worked and its
        // GitHub link (a plain `<a href>`) never opened a browser - CEF's `local://` UI scheme has
        // nothing for a plain anchor navigation to hand off to an external browser with. Removed
        // per direct request ; both moved to the ImGui top menu bar's own "About" dropdown instead
        // (imgui/menu.lua), where a "copy link" action via `ui_imgui.SetClipboardText` actually
        // works, and the version is already correctly shown there too.

        // the rail hides until you need it (windows/main/app.js) : a per-player UI preference,
        // kept in the UI's own storage like the rail's position
        this.railAutoHide = false;
        try {
            this.railAutoHide = localStorage.getItem("beamjoy.rail.autoHide") === "1";
        } catch (e) {
            // storage unavailable : off
        }
        // the race HUD's layout (windows/raceHud/app.js), kept the same way
        this.raceHudLayouts = [
            { value: "standard", label: "beamjoy.window.main.tabs.settings.sections.menu.raceHud.standard" },
            { value: "compact", label: "beamjoy.window.main.tabs.settings.sections.menu.raceHud.compact" },
            { value: "full", label: "beamjoy.window.main.tabs.settings.sections.menu.raceHud.full" },
            { value: "off", label: "beamjoy.window.main.tabs.settings.sections.menu.raceHud.off" },
        ];
        this.raceHudLayout = "standard";
        try {
            const saved = localStorage.getItem("beamjoy.raceHud.layout");
            if (this.raceHudLayouts.some((o) => o.value === saved)) this.raceHudLayout = saved;
        } catch (e) {
            // storage unavailable : standard
        }
        // where the activity overlays sit (overlay-anchor.js) : one corner and one pair of edge
        // gaps for the whole cluster - the race, bus, drag, derby, hunter, infected, delivery and
        // drift zone panels, the pit menu beside the race HUD, and plugin panels with no corner of
        // their own. Written straight to CSS custom properties, so it applies as it's dragged
        this.overlayCorners = [
            { value: "top-right", label: "beamjoy.window.main.tabs.settings.sections.menu.overlays.topRight" },
            { value: "top-left", label: "beamjoy.window.main.tabs.settings.sections.menu.overlays.topLeft" },
            { value: "bottom-right", label: "beamjoy.window.main.tabs.settings.sections.menu.overlays.bottomRight" },
            { value: "bottom-left", label: "beamjoy.window.main.tabs.settings.sections.menu.overlays.bottomLeft" },
        ];
        //
        // Reported: picking a corner moved the overlays to it and then straight back to the one
        // before. The cause was not here but in how the corner was applied - Angular Material puts
        // back its own copy of the html element's style attribute when a dropdown closes, undoing
        // it (see overlay-anchor.js, which writes a stylesheet now). These are three plain values
        // rather than the one object they started as, like the race HUD layout setting just above:
        // bj-select's pick reaches its own `ngModel` first and is copied into the bound property
        // later in the digest (cmps/select's own note says so), so an object swapped out from under
        // the binding would have let the select's stale copy win the next reconcile. The corner
        // comes from the select's own ng-change for the same reason, and nothing is reassigned from
        // inside a watcher
        const saved = beamjoyOverlayAnchor.get();
        this.overlayCorner = saved.corner;
        this.overlayX = saved.x;
        this.overlayY = saved.y;
        this.overlayLimit = beamjoyOverlayAnchor.LIMIT;
        /** @param corner bj-select's freshly picked value, not $ctrl.overlayCorner (still the old one) */
        this.setOverlayCorner = (corner) => beamjoyOverlayAnchor.set({ corner });
        this.resetOverlays = () => {
            beamjoyOverlayAnchor.reset();
            const back = beamjoyOverlayAnchor.get();
            this.overlayCorner = back.corner;
            this.overlayX = back.x;
            this.overlayY = back.y;
        };
        // the two offsets : bj-slider has no change callback of its own, so they're watched as one
        // joined string, the pattern used for it everywhere else here
        $scope.$watch(
            () => `${this.overlayX}|${this.overlayY}`,
            (now, before) => {
                if (now === before) return;
                beamjoyOverlayAnchor.set({ x: this.overlayX, y: this.overlayY });
            }
        );

        // server plugins' labels beside racers' names on the race HUD (cmps/pluginOptions)
        this.hudLabels = beamjoyPluginUi.labelsShown();
        $scope.$watch(
            () => this.hudLabels,
            (on, old) => {
                if (on === old) return;
                beamjoyPluginUi.setLabelsShown(on);
            }
        );
        $scope.$watch(
            () => this.raceHudLayout,
            (layout, old) => {
                if (layout === old) return;
                try {
                    localStorage.setItem("beamjoy.raceHud.layout", layout);
                } catch (e) {
                    // not remembered, still applied for this session
                }
                $rootScope.$broadcast("BJRaceHudLayout", layout);
            }
        );

        $scope.$watch(
            () => this.railAutoHide,
            (on, old) => {
                if (on === old) return;
                try {
                    localStorage.setItem("beamjoy.rail.autoHide", on ? "1" : "0");
                } catch (e) {
                    // not remembered, still applied for this session
                }
                $rootScope.$broadcast("BJRailAutoHide", on);
            }
        );

        // Real bug: this used to save on the watch's first run too, when nothing had changed,
        // sending the page's own defaults before the saved values had even arrived : opening
        // Settings put every saved vehicle setting back to its default
        $scope.$watch(
            () => this.settings,
            (value, old) => {
                if (value === old) return;
                beamjoyStore.settings.save(this.settings);
            },
            true
        );
    },
});
