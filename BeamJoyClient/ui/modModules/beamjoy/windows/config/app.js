await import(`/ui/modModules/beamjoy/windows/config/general/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/safeZones/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/permissions/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/maps/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/core/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/database/app.js`);

angular.module("beamjoy").component("bjConfig", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/app.html",
    controller: function ($rootScope, beamjoyStore, $timeout, beamjoyWindowRect) {
        this.visible = false;
        this.onClose = () => {
            this.visible = false;
            beamjoyStore.send("BJCloseWindow", ["config"]);
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

        this.tabsData = {
            general: {
                id: "general",
                order: 1,
                title: "beamjoy.window.config.tabs.general.title",
                visible: true,
                closable: false,
                template: "<bj-config-general></bj-config-general>",
            },
            safeZones: {
                id: "safeZones",
                order: 2,
                title: "beamjoy.window.config.tabs.safeZones.title",
                visible: true,
                closable: false,
                template: "<bj-config-safe-zones></bj-config-safe-zones>",
            },
            permissions: {
                id: "permissions",
                order: 3,
                title: "beamjoy.window.config.tabs.permissions.title",
                visible: false,
                closable: false,
                template: "<bj-config-permissions></bj-config-permissions>",
                permissions: ["SetPermissions"],
            },
            maps: {
                id: "maps",
                order: 4,
                title: "beamjoy.window.config.tabs.maps.title",
                visible: false,
                closable: false,
                template: "<bj-config-maps></bj-config-maps>",
                permissions: ["SetMaps"],
            },
            core: {
                id: "core",
                order: 5,
                title: "beamjoy.window.config.tabs.core.title",
                visible: false,
                closable: false,
                template: "<bj-config-core></bj-config-core>",
                permissions: ["SetCore"],
            },
            database: {
                id: "database",
                order: 6,
                title: "beamjoy.window.config.tabs.database.title",
                visible: false,
                closable: false,
                template: "<bj-config-database></bj-config-database>",
                permissions: ["DatabasePlayers"],
            },
        };
        this.tabs = [];
        const onTabListUpdated = () => {
            const reset = () => {
                this.activeTabIndex = 0;
                this.activeTabId = this.tabs[0].id;
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
            this.activeTabIndex = 0;
            this.activeTabId = this.tabs[this.activeTabIndex].id;
        };
        this.onTabChange = (tabId) => {
            const index = this.tabs.indexOf(
                this.tabs.find((tab) => tab.id === tabId)
            );
            if (index > -1 && this.tabs[index].visible) {
                this.activeTabIndex = index;
                this.activeTabId = this.tabs[index].id;
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
