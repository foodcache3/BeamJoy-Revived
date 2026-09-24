await import(`/ui/modModules/beamjoy/windows/main/activities/busLines/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/hunter/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/infected/app.js`);

// The Main window's "Activities" tab (id "races", titled "Activities" - see
// beamjoy.window.main.tabs.races.title) used to be races-only; its own header comment already
// anticipated more activity types slotting in later. Splits it into one sub-tab per gamemode
// instead of piling everything into one list : "Races" and "Bus Lines" are its own two
// components (bj-main-races/bj-main-bus-lines, both untouched) ; "Hunter" and "Infected" were
// previously their own separate top-level Main window tabs (bj-main-hunter/bj-main-infected,
// also untouched - only which parent mounts them changed) and got folded in here too, so every
// gamemode lives under one "Activities" tab instead of each claiming its own top-level slot.
// Same section-bar pattern as Config > Freeroam's Stations & Garages / Bus Lines split.
angular.module("beamjoy").component("bjMainActivities", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/activities/app.html",
    controller: function () {
        this.SECTIONS = ["races", "busLines", "hunter", "infected"];
        this.activeSection = "races";
        this.changeSection = (event, section) => {
            event.stopPropagation();
            this.activeSection = section;
        };
    },
});
