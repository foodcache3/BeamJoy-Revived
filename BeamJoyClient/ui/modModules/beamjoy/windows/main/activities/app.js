await import(`/ui/modModules/beamjoy/windows/main/activities/busLines/app.js`);

// The Main window's "Activities" tab (id "races", titled "Activities" - see
// beamjoy.window.main.tabs.races.title) used to be races-only; its own header comment already
// anticipated more activity types slotting in later. Splits it into one sub-tab per gamemode
// instead of piling everything into one list : "Races" is the existing bj-main-races component,
// completely untouched ; "Bus Lines" is the new player-facing browse/start list below. Same
// section-bar pattern as Config > Freeroam's Stations & Garages / Bus Lines split.
angular.module("beamjoy").component("bjMainActivities", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/activities/app.html",
    controller: function () {
        this.SECTIONS = ["races", "busLines"];
        this.activeSection = "races";
        this.changeSection = (event, section) => {
            event.stopPropagation();
            this.activeSection = section;
        };
    },
});
