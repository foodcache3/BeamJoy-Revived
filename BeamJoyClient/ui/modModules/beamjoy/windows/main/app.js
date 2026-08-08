await import(`/ui/modModules/beamjoy/windows/main/main/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/settings/app.js`);

angular.module("beamjoy").component("bjMain", {
    templateUrl: "/ui/modModules/beamjoy/windows/main/app.html",
    controller: function ($rootScope, beamjoyStore, beamjoyWindowRect) {
        this.visible = false;
        this.closable = false;
        this.closeWindow = () => {
            this.visible = false;
            beamjoyStore.send("BJCloseWindow", ["main"]);
        };
        this.onClose = null;
        $rootScope.$on("BJSendAppsSizesAndPositions", (_, data) => {
            const el = data["beamjoy-main"];
            const dom = document.querySelector("#beamjoy-main");
            // skip the Lua-driven default once the player has manually moved/resized
            if (el && dom && !beamjoyWindowRect.get("main")) {
                dom.style.width = el.width;
                dom.style.height = el.height;
                dom.style.top = el.top;
                dom.style.left = el.left;
            }
        });
        $rootScope.$on("BJUpdateWindowSettings", (_, data) => {
            const el = data["beamjoy-main"];
            if (el) {
                $rootScope.$applyAsync(() => {
                    this.visible = el.visible;
                    this.closable = el.closable;
                    this.onClose = this.closable ? this.closeWindow : undefined;
                });
            }
        });

        this.tabsData = {
            main: {
                id: "main",
                order: 1,
                title: "beamjoy.window.main.tabs.main.title",
                visible: true,
                closable: false,
                template: "<bj-main-main></bj-main-main>",
            },
            settings: {
                id: "settings",
                order: 2,
                title: "beamjoy.window.main.tabs.settings.title",
                visible: false,
                closable: true,
                template: "<bj-main-settings></bj-main-settings>",
            },
        };
        this.tabs = [];
        const updateTabs = () => {
            this.tabs = Object.values(this.tabsData)
                .filter((tab) => tab.visible)
                .sort((a, b) => a.order - b.order);
        };
        updateTabs();
        this.activeTabIndex = 0;
        this.activeTabId = this.tabs[this.activeTabIndex].id;
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
            if (index > -1 && this.tabs[index].closable) {
                this.tabs[index].visible = false;
                updateTabs();
                if (this.activeTabId === tabId) {
                    this.activeTabIndex = 0;
                    this.activeTabId = this.tabs[0].id;
                } else {
                    this.activeTabIndex = this.tabs.indexOf(
                        this.tabs.find((tab) => tab.id === this.activeTabId)
                    );
                }
                if (this.activeTabIndex === -1) {
                    this.activeTabIndex = 0;
                    this.activeTabId = this.tabs[0].id;
                }
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
    },
});
