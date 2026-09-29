// Config > Arenas : the Hunter and Infected arena editors in one tab, one section each (like the
// Freeroam tab's sections). Each section is the existing editor component, mounted only while it's
// shown, so switching sections closes one editor and opens the other in Lua exactly as switching
// config tabs used to. Each editor registers its own unsaved-changes guard (beamjoyNavGuard) ;
// switching sections goes through that same guard, so unsaved changes ask to be discarded first,
// the same confirmation as switching config tabs.
angular.module("beamjoy").component("bjConfigArenas", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/arenas/app.html",
    controller: function ($rootScope, $scope, $timeout, beamjoyStore, beamjoyNavGuard) {
        const ALL = [
            { id: "hunter", permission: "EditHunterArenas" },
            { id: "infected", permission: "EditInfectedArenas" },
        ];
        this.sections = [];
        this.activeSection = null;

        const updateSections = () => {
            const perms = beamjoyStore.permissions;
            this.sections = ALL.filter(
                (s) => !perms.hasAnyPermission || perms.hasAnyPermission(null, s.permission)
            ).map((s) => s.id);
            if (!this.sections.includes(this.activeSection)) {
                // a shortcut (Hunter / Infected menu) may have asked for a section first
                const wanted = beamjoyStore.arenasSection;
                this.activeSection = this.sections.includes(wanted) ? wanted : this.sections[0] || null;
            }
        };
        updateSections();
        ["BJUpdateSelf", "BJUpdatePermissions", "BJUpdateGroups"].forEach((event) => {
            $scope.$on(event, updateSections);
        });

        const show = (section) => {
            if (!this.sections.includes(section) || section === this.activeSection) return;
            beamjoyNavGuard.check(() => {
                // unmount the current editor first, mount the next one on the following digest :
                // both editors share Lua's one active-editor slot, and each one's Close handler
                // closes whatever editor is active, so the old one has to close before the new
                // one opens (in one digest Angular may create the new one first)
                this.activeSection = null;
                beamjoyStore.arenasSection = section;
                $timeout(() => {
                    if (this.sections.includes(section)) this.activeSection = section;
                });
            });
        };
        this.changeSection = (event, section) => {
            event.stopPropagation();
            show(section);
        };
        // the Hunter / Infected menus' "edit arena" shortcut, once this tab is already open
        $scope.$on("BJArenasSection", (_, section) => show(section));
    },
});
