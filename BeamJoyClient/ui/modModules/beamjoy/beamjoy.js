// update Loading screen
(function () {
    const loadingScreenTitle = document.body.children[2]
        ? document.body.children[2].children[0]
        : null;
    if (
        loadingScreenTitle &&
        loadingScreenTitle.innerHTML.includes("Loading UI...")
    ) {
        loadingScreenTitle.innerHTML = "Loading BeamJoy...";
    }
})();

const beamjoyModule = angular.module("beamjoy", [
    "pascalprecht.translate",
    "ngSanitize",
]);

await import(`/ui/modModules/beamjoy/override/chat.js`);

await import(`/ui/modModules/beamjoy/directives/tooltip.js`);
await import(`/ui/modModules/beamjoy/directives/ngHtml.js`);
await import(`/ui/modModules/beamjoy/directives/textareaAutoheight.js`);
await import(`/ui/modModules/beamjoy/directives/fitText.js`);

await import(`/ui/modModules/beamjoy/beamjoy-store.js`);

await import(`/ui/modModules/beamjoy/cmps/beamjoy-style/app.js`);
await import(`/ui/modModules/beamjoy/cmps/icon/app.js`);
await import(`/ui/modModules/beamjoy/cmps/toggle/app.js`);
await import(`/ui/modModules/beamjoy/cmps/slider/app.js`);
await import(`/ui/modModules/beamjoy/cmps/select/app.js`);
await import(`/ui/modModules/beamjoy/cmps/colorPicker/app.js`);
await import(`/ui/modModules/beamjoy/cmps/window/app.js`);
await import(`/ui/modModules/beamjoy/cmps/tabs/app.js`);
await import(`/ui/modModules/beamjoy/cmps/accordion/app.js`);
await import(`/ui/modModules/beamjoy/cmps/fade/app.js`);
await import(`/ui/modModules/beamjoy/cmps/contextMenu/app.js`);
await import(`/ui/modModules/beamjoy/cmps/sortable/app.js`);
await import(`/ui/modModules/beamjoy/cmps/confirm/app.js`);
await import(`/ui/modModules/beamjoy/cmps/infoPanel/app.js`);
await import(`/ui/modModules/beamjoy/cmps/pointListEditorToolbar/app.js`);
await import(`/ui/modModules/beamjoy/cmps/pointListEditor/app.js`);

await import(`/ui/modModules/beamjoy/windows/versionCheck/app.js`);
await import(`/ui/modModules/beamjoy/windows/hud/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/app.js`);
await import(`/ui/modModules/beamjoy/windows/raceCountdown/app.js`);
await import(`/ui/modModules/beamjoy/windows/raceHud/app.js`);
await import(`/ui/modModules/beamjoy/windows/hunterCountdown/app.js`);
await import(`/ui/modModules/beamjoy/windows/hunterHud/app.js`);
await import(`/ui/modModules/beamjoy/windows/infectedCountdown/app.js`);
await import(`/ui/modModules/beamjoy/windows/infectedHud/app.js`);
await import(`/ui/modModules/beamjoy/windows/mapVote/app.js`);
await import(`/ui/modModules/beamjoy/windows/kickVote/app.js`);
await import(`/ui/modModules/beamjoy/windows/raceInfo/live/app.js`);
await import(`/ui/modModules/beamjoy/windows/raceInfo/results/app.js`);
await import(`/ui/modModules/beamjoy/windows/raceLeaderboard/app.js`);

beamjoyModule.component("beamjoy", {
    template: ``,
    controller: function ($rootScope, $compile, beamjoyStore, bjChat) {
        this.$onInit = () => {
            setTimeout(() => {
                const wrapper = document.querySelector("beamjoy");
                wrapper.style.position = "absolute";
                wrapper.style.zIndex = 1;
                while (wrapper.firstChild) {
                    wrapper.removeChild(wrapper.firstChild);
                }

                const el = angular.element(`
                        <bj-style></bj-style>
                        <bj-context-menu></bj-context-menu>
                        <bj-version-check></bj-version-check>

                        <bj-hud></bj-hud>
                        <bj-main></bj-main>
                        <bj-config></bj-config>
                        <bj-race-countdown></bj-race-countdown>
                        <bj-race-hud></bj-race-hud>
                        <bj-hunter-countdown></bj-hunter-countdown>
                        <bj-hunter-hud></bj-hunter-hud>
                        <bj-infected-countdown></bj-infected-countdown>
                        <bj-infected-hud></bj-infected-hud>
                        <bj-map-vote></bj-map-vote>
                        <bj-kick-vote></bj-kick-vote>
                        <bj-confirm></bj-confirm>
                        <bj-info-panel></bj-info-panel>
                    `);
                $compile(el)($rootScope);
                angular.element(wrapper).append(el);
            }, 1000);
        };

        const requestSizesAndPositions = () => {
            $rootScope.$broadcast("BJRequestWindowsSizesAndPositions");
        };
        $rootScope.$on("editApps", function (_, state) {
            const wrapper = document.querySelector("beamjoy");
            wrapper.style.zIndex = state ? "auto" : "1";
            requestSizesAndPositions();
        });
        $rootScope.$on("appContainer:addApp", requestSizesAndPositions);
        $rootScope.$on("appContainer:removeApp", requestSizesAndPositions);
        $rootScope.$on(
            "appContainer:onUIDataUpdated",
            requestSizesAndPositions
        );
        $rootScope.$on("appContainer:save", requestSizesAndPositions);
        $rootScope.$on("appContainer:resetLayout", requestSizesAndPositions);
        $rootScope.$on("appContainer:deleteLayout", requestSizesAndPositions);
        $rootScope.$on(
            "appContainer:createNewLayout",
            requestSizesAndPositions
        );
        $rootScope.$on("GameStateUpdate", requestSizesAndPositions);

        $rootScope.$on("BJUnload", () => {
            // guarded : this can now be sent twice in a row (main.lua's own onServerLeave, as a
            // fallback, plus communications/ui.lua's own independent onServerLeave hook), so
            // querySelector returns null the second time, and null.remove() would throw
            document.querySelector("beamjoy")?.remove();
        });
    },
});

// Mount the <beamjoy> element into the shared "BeamNG.ui" app instead of
// self-bootstrapping a second, isolated Angular app. Since 0.39, the core UI
// loader (ui/entrypoints/main/angularModules.js) auto-registers every
// /ui/modModules/<name>/<name>.js as a *dependency* of "BeamNG.ui" and
// bootstraps that single app itself - it never bootstraps ours. A separate
// `angular.bootstrap(container, ["beamjoy"])` call here creates a disconnected
// $rootScope that guihooks.trigger() (window.globalAngularRootScope.$broadcast,
// set once in BeamNG.ui's own .run() block) can never reach, so Lua-originated
// events (BJUpdateWindowSettings, etc.) would never arrive. Using .run() here
// instead lets Angular inject the real, shared $rootScope/$compile.
beamjoyModule.run(["$compile", "$rootScope", function ($compile, $rootScope) {
    const container = document.createElement("beamjoy");
    document.body.prepend(container);
    $compile(container)($rootScope);
}]);

export default beamjoyModule;
