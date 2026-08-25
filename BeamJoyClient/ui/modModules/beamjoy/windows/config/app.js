await import(`/ui/modModules/beamjoy/windows/config/general/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/safeZones/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/races/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/vehiclePresets/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/hunterArena/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/permissions/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/maps/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/core/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/database/app.js`);

angular.module("beamjoy").component("bjConfig", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/app.html",
    controller: function (
        $rootScope,
        beamjoyStore,
        $timeout,
        beamjoyWindowRect,
        beamjoyNavGuard
    ) {
        this.visible = false;
        // routed through the shared nav guard : the currently-mounted race editor (if any) may
        // have unsaved changes and asks to confirm before actually closing, same as switching
        // tabs below (see cmps/confirm/app.js for why this can't just be a $destroy check)
        this.onClose = () => {
            beamjoyNavGuard.check(() => {
                this.visible = false;
                beamjoyStore.send("BJCloseWindow", ["config"]);
            });
        };
        $rootScope.$on("BJSendAppsSizesAndPositions", (_, data) => {
            const el = data["beamjoy-config"];
            const dom = document.querySelector("#beamjoy-config");
            // skip the Lua-driven default once the player has manually moved/resized
            if (el && dom && !beamjoyWindowRect.get("config")) {
                dom.style.width = el.width;
                dom.style.height = el.height;
                dom.style.top = el.top;
                dom.style.left = el.left;
            }
        });
        $rootScope.$on("BJUpdateWindowSettings", (_, data) => {
            const el = data["beamjoy-config"];
            if (el) {
                $rootScope.$applyAsync(() => {
                    this.visible = el.visible;
                });
            }
        });
        // the native ImGui "Toggle Config" menu item can't reach this.dirty (Angular-side state)
        // to decide safely on its own, so closing that way asks Lua to ask US instead, routing
        // through the exact same guarded onClose the in-window X button already uses
        $rootScope.$on("BJRequestCloseWindow", (_, windowName) => {
            if (windowName === "config") this.onClose();
        });

        this.tabsData = {
            general: {
                id: "general",
                order: 1,
                title: "beamjoy.window.config.tabs.general.title",
                visible: true,
                closable: false,
                template: "<bj-config-general></bj-config-general>",
                // every accordion inside this tab individually gates on one of these three (see
                // windows/config/general/app.js's own updateDisplayAndPermissions): hide the
                // whole tab rather than showing an entry point to a page with nothing visible on it
                permissions: ["SetConfig", "Whitelist", "SetEnvironment"],
            },
            safeZones: {
                id: "safeZones",
                order: 2,
                title: "beamjoy.window.config.tabs.safeZones.title",
                visible: true,
                closable: false,
                template: "<bj-config-safe-zones></bj-config-safe-zones>",
                permissions: ["EditSafeZones"],
            },
            races: {
                id: "races",
                order: 3,
                title: "beamjoy.window.config.tabs.races.title",
                visible: false,
                closable: false,
                template: "<bj-config-races></bj-config-races>",
                permissions: ["EditRaces"],
            },
            vehiclePresets: {
                id: "vehiclePresets",
                order: 4,
                title: "beamjoy.window.config.tabs.vehiclePresets.title",
                visible: false,
                closable: false,
                template: "<bj-config-vehicle-presets></bj-config-vehicle-presets>",
                permissions: ["EditVehiclePresets"],
            },
            hunterArena: {
                id: "hunterArena",
                order: 5,
                title: "beamjoy.window.config.tabs.hunterArena.title",
                visible: false,
                closable: false,
                template: "<bj-config-hunter-arena></bj-config-hunter-arena>",
                permissions: ["EditHunterArenas"],
            },
            permissions: {
                id: "permissions",
                order: 6,
                title: "beamjoy.window.config.tabs.permissions.title",
                visible: false,
                closable: false,
                template: "<bj-config-permissions></bj-config-permissions>",
                permissions: ["SetPermissions"],
            },
            maps: {
                id: "maps",
                order: 7,
                title: "beamjoy.window.config.tabs.maps.title",
                visible: false,
                closable: false,
                template: "<bj-config-maps></bj-config-maps>",
                permissions: ["SetMaps"],
            },
            core: {
                id: "core",
                order: 8,
                title: "beamjoy.window.config.tabs.core.title",
                visible: false,
                closable: false,
                template: "<bj-config-core></bj-config-core>",
                // SetCore is the real gate on the identity-fields form below ; EditHunterArenas/
                // EditRaces (and any future importable mode's own permission) are included here
                // too so each one's own row in the Legacy Import accordion stays reachable for a
                // mod-rank holder who isn't also owner-rank SetCore, matching the access those
                // buttons had in their old homes
                permissions: ["SetCore", "EditHunterArenas", "EditRaces"],
            },
            database: {
                id: "database",
                order: 9,
                title: "beamjoy.window.config.tabs.database.title",
                visible: false,
                closable: false,
                template: "<bj-config-database></bj-config-database>",
                permissions: ["DatabasePlayers"],
            },
        };
        this.tabs = [];
        const onTabListUpdated = () => {
            // real, confirmed crash fixed here (captured live log) : an account with no permission
            // matching ANY tab (e.g. a fresh guest with nothing granted) ends up with an EMPTY
            // this.tabs, and this used to unconditionally index tabs[0] regardless, throwing from
            // INSIDE Angular's own synchronous component-linking phase ($onInit, called from
            // nodeLinkFn while this whole template is still being linked), not some isolated async
            // handler elsewhere. That's a much more plausible way to leave the rest of the page's
            // Angular/Vue state quietly corrupted for the remainder of the session than either of
            // the two independent chat-related bugs already fixed this round.
            const reset = () => {
                this.activeTabIndex = this.tabs.length > 0 ? 0 : -1;
                this.activeTabId = this.tabs.length > 0 ? this.tabs[0].id : null;
            };
            if (!this.tabs.some((tab) => tab.id === this.activeTabId)) {
                reset();
            } else {
                this.activeTabIndex = this.tabs.indexOf(
                    this.tabs.find((tab) => tab.id === this.activeTabId)
                );
                if (this.activeTabIndex === -1) reset();
            }
        };
        const updateTabs = () => {
            let tabListChanged = false;
            this.tabs = Object.entries(this.tabsData)
                .filter(([k, v]) => {
                    if (
                        beamjoyStore.permissions.hasAnyPermission &&
                        Array.isArray(v.permissions) &&
                        v.permissions.length > 0 &&
                        (v.visible || !v.closable)
                    ) {
                        const wasVisible = v.visible;
                        this.tabsData[k].visible =
                            beamjoyStore.permissions.hasAnyPermission(
                                null,
                                ...v.permissions
                            );
                        if (wasVisible !== this.tabsData[k].visible) {
                            tabListChanged = true;
                        }
                    }
                    return this.tabsData[k].visible;
                })
                .map(([k, v]) => v)
                .sort((a, b) => a.order - b.order);
            if (tabListChanged) onTabListUpdated();
        };
        this.$onInit = () => {
            updateTabs();
            this.activeTabIndex = this.tabs.length > 0 ? 0 : -1;
            this.activeTabId = this.tabs.length > 0 ? this.tabs[this.activeTabIndex].id : null;
        };
        this.onTabChange = (tabId) => {
            const index = this.tabs.indexOf(
                this.tabs.find((tab) => tab.id === tabId)
            );
            if (index > -1 && this.tabs[index].visible && index !== this.activeTabIndex) {
                beamjoyNavGuard.check(() => {
                    this.activeTabIndex = index;
                    this.activeTabId = this.tabs[index].id;
                });
            }
        };
        this.onTabClose = (tabId) => {
            const index = this.tabs.indexOf(
                this.tabs.find((tab) => tab.id === tabId)
            );
            if (
                index > -1 &&
                this.tabs[index] &&
                this.tabs[index].visible &&
                this.tabs[index].closable
            ) {
                this.tabs[index].visible = false;
                updateTabs();
                onTabListUpdated();
            }
        };
        $rootScope.$on("BJOpenTab", (_, tabId) => {
            if (this.tabsData[tabId]) {
                if (!this.tabsData[tabId].visible) {
                    this.tabsData[tabId].visible = true;
                    updateTabs();
                }
                this.onTabChange(tabId);
            }
        });
        $rootScope.$on("BJCloseTab", (_, tabId) => {
            this.onTabClose(tabId);
        });

        ["BJUpdateGroups", "BJUpdatePermissions", "BJUpdateSelf"].forEach(
            (eventName) => {
                $rootScope.$on(eventName, updateTabs);
            }
        );
    },
});
