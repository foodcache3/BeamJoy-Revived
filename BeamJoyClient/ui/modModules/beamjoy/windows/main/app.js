await import(`/ui/modModules/beamjoy/windows/main/main/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/settings/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/races/app.js`);
// hunter/app.js and infected/app.js are imported by activities/app.js now - both gamemodes moved
// under the Activities tab, no longer separate top-level tabs (see that file's own comment)
await import(`/ui/modModules/beamjoy/windows/main/activities/app.js`);

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
            races: {
                id: "races",
                order: 2,
                title: "beamjoy.window.main.tabs.races.title",
                visible: true,
                closable: false,
                // was <bj-main-races> directly ; now a section-switching wrapper hosting it
                // alongside <bj-main-bus-lines>/<bj-main-hunter>/<bj-main-infected> (see
                // windows/main/activities/app.js) - the tab id/title ("Activities") are
                // unchanged, only its content is split per gamemode now. Hunter and Infected used
                // to be their own top-level tabs here (order 3/4) - folded in as sections instead.
                template: "<bj-main-activities></bj-main-activities>",
            },
            settings: {
                id: "settings",
                order: 5,
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
