// Freeroam config tab : the in-world editor for energy stations + garages. Deliberately minimal -
// two radius-only point lists, no enabled toggle, no gameplay defaults - so it's mostly just the
// shared <bj-point-list-editor> plus its toolbar and a Save button. Mirrors config/infectedArena's
// wiring (nav guard, dirty tracking, open/close/save events) without the sections/defaults.
angular.module("beamjoy").component("bjConfigFreeroam", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/freeroam/app.html",
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyNavGuard) {
        const translate = $filter("translate");

        this.pointLists = [
            { key: "energyStations", labelKey: "beamjoy.window.config.tabs.freeroam.station", min: 0, hasRadius: true, hasName: true },
            { key: "garages", labelKey: "beamjoy.window.config.tabs.freeroam.garage", min: 0, hasRadius: true, hasName: true },
        ];
        this.pointListEvents = {
            listsUpdate: "BJEditorFreeroamListsUpdate",
            activeUpdate: "BJEditorFreeroamActiveUpdate",
            select: "BJEditorFreeroamSelect",
            create: "BJEditorFreeroamCreate",
            delete: "BJEditorFreeroamDelete",
            setToVehicle: "BJEditorFreeroamSetToVehicle",
            teleportTo: "BJEditorFreeroamTeleportTo",
            setRadius: "BJEditorFreeroamSetRadius",
            setName: "BJEditorFreeroamSetName",
            snapToGround: "BJEditorFreeroamSnapToGround",
            snapMethod: "BJEditorFreeroamSnapMethod",
            setSnapToGround: "BJEditorFreeroamSetSnapToGround",
            setSnapMethod: "BJEditorFreeroamSetSnapMethod",
            requestState: "BJEditorFreeroamRequestState",
        };

        this.$onInit = () => {
            beamjoyStore.send("BJEditorFreeroamOpen");
        };

        const dirtyCheck = () => this.dirty;
        beamjoyNavGuard.set(
            dirtyCheck,
            translate("beamjoy.window.config.tabs.freeroam.confirmDiscard")
        );
        $scope.$on("$destroy", () => {
            beamjoyNavGuard.clear(dirtyCheck);
            beamjoyStore.send("BJEditorFreeroamClose");
        });

        this.dirty = false;
        $rootScope.$on("BJEditorDirty", (_, state) => {
            this.dirty = state === true;
        });

        this.save = (event) => {
            event.stopPropagation();
            beamjoyStore.send("BJEditorFreeroamSave");
        };
    },
});
