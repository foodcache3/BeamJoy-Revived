await import(`/ui/modModules/beamjoy/windows/main/activities/busLines/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/hunter/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/infected/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/activities/jobs/app.js`);

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
    controller: function ($rootScope, $scope, beamjoyNow) {
        this.SECTIONS = ["races", "busLines", "hunter", "infected", "jobs"];
        // while you're in something (a race lobby, a convoy, a bus run...) only its section shows
        this.sections = () => {
            const mine = beamjoyNow.activeSection();
            return mine ? [mine] : this.SECTIONS;
        };
        // the section last looked at, kept across the panel / full window swap
        this.activeSection = $rootScope.bjMainLastSection || "races";
        // Happening now's "Open", mainNav.lua or a depot prompt land on a given section
        const pick = (section) => {
            if (this.SECTIONS.includes(section)) this.activeSection = section;
            $rootScope.bjMainActivitiesSection = null;
        };
        this.$onInit = () => pick($rootScope.bjMainActivitiesSection);
        $scope.$on("$destroy", $rootScope.$on("BJMainActivitiesSection", (_, section) => pick(section)));
        $scope.$watch(() => this.activeSection, (v) => ($rootScope.bjMainLastSection = v));
        $scope.$watch(() => beamjoyNow.activeSection(), (mine) => {
            if (mine) this.activeSection = mine;
        });
        this.changeSection = (event, section) => {
            event.stopPropagation();
            this.activeSection = section;
        };
    },
});
