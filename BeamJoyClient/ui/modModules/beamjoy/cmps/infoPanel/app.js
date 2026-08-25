// Generic reusable "info panel" primitive: a centered modal (title + tabs + close), intended as
// a framework for any future read-only info/results display, not just races (this session's own
// first and only consumer so far). Deliberately just chrome : callers build their own tab content
// as separate components and hand in a `tabs` array shaped exactly like bj-tabs already expects
// ({id, title, template}), the same pattern windows/config/app.js already uses for its own tabs.
// bj-tabs itself does the actual tab-bar/content-switching, this only adds the modal
// backdrop/title/close around it. Same singleton-service-backed-by-one-root-mounted-component
// shape as beamjoyConfirm/bj-confirm, so any component can call `beamjoyInfoPanel.open(...)`
// without needing a reference to this one.
angular.module("beamjoy").service("beamjoyInfoPanel", function () {
    this.state = {
        visible: false,
        title: "",
        tabs: [],
        activeTabIndex: 0,
    };

    // tabs : [{id, title, template}], same shape bj-tabs itself expects
    this.open = (title, tabs, startTabId) => {
        this.state.visible = true;
        this.state.title = title;
        this.state.tabs = tabs || [];
        const startIndex = startTabId
            ? this.state.tabs.findIndex((t) => t.id === startTabId)
            : -1;
        this.state.activeTabIndex = startIndex > -1 ? startIndex : 0;
    };

    this.close = () => {
        this.state.visible = false;
    };
});

angular.module("beamjoy").component("bjInfoPanel", {
    templateUrl: "/ui/modModules/beamjoy/cmps/infoPanel/app.html",
    controller: function (beamjoyInfoPanel) {
        this.state = beamjoyInfoPanel.state;

        this.selectTab = (tabId) => {
            const index = this.state.tabs.findIndex((t) => t.id === tabId);
            if (index > -1) this.state.activeTabIndex = index;
        };

        this.close = () => beamjoyInfoPanel.close();
    },
});
