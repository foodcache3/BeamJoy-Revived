// UI cache/version mismatch detector. GE-Lua's own version/buildversion are always read fresh
// from disk every session (see main.lua's loadVersion, and communications/ui.lua's onUIReady,
// which already broadcasts them once via the "BJVersion" event for the Settings tab's About
// section). The UI itself runs inside CEF and can keep serving a stale, cached bundle after a mod
// update. Stale code can't reliably detect its own staleness, so the fix is baking a copy of the
// current build number into the UI source, then comparing it against the value Lua just reported.
//
// IMPORTANT: bump UI_BUILD to match Client/BJ/lua/ge/extensions/beamjoy/buildversion at every
// release, or every player looks permanently out of date. See CLAUDE.md's Versioning section.
const UI_BUILD = 2290;

angular.module("beamjoy").component("bjVersionCheck", {
    templateUrl: "/ui/modModules/beamjoy/windows/versionCheck/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.mismatched = false;
        this.dismissed = false;
        this.uiBuild = UI_BUILD;
        this.luaBuild = null;

        $rootScope.$on("BJVersion", (_, data) => {
            const luaBuild = Number(data && data.build);
            if (!Number.isFinite(luaBuild)) return;
            this.luaBuild = luaBuild;
            this.mismatched = luaBuild !== UI_BUILD;
        });

        this.dismiss = () => {
            this.dismissed = true;
        };

        // No in-session fix exists for this. Two attempts (reloadUI, a query-string cache-busted
        // navigation) were both live-tested and failed: BeamNG serves its UI through a custom
        // `local://` CEF scheme, not real HTTP, so ordinary cache-busting has nothing to bust.
        // Even BeamNG's own native "Clear cache" tool (Help menu) only schedules a cleanup for the
        // next launch. The message below tells the player what actually works instead.

        // communications/ui.lua's own one-time "BJVersion" push fires as soon as UI-side cache
        // finishes loading, which can easily happen before this root singleton is even mounted
        // (beamjoy.js mounts every root component together, ~1s after connect, independent of how
        // fast that push resolves); actively requesting it here instead of only ever listening
        // guarantees this component gets a real value regardless of mount timing.
        this.$onInit = () => {
            beamjoyStore.send("BJVersionRequest");
        };
    },
});
