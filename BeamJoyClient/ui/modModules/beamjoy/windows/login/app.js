// Nickname "login" workaround, shown before the rest of the mod's UI unlocks (see
// communications/ui.lua's own onUIReady/proceedAfterLogin gating for the full story). Purely a
// display identity from here on (nametags, player roster, race leaderboard rows - see
// services/identity.lua's own doc comment server-side) : explicitly NOT password-protected, NOT
// tied to permissions/bans in any way. Skippable - this is a convenience, not a requirement.
angular.module("beamjoy").component("bjLogin", {
    templateUrl: "/ui/modModules/beamjoy/windows/login/app.html",
    controller: function ($rootScope, beamjoyStore) {
        const STORAGE_KEY = "beamjoy.login.nickname";

        this.visible = false;
        this.nickname = "";
        this.error = null;
        this.submitting = false;

        try {
            const remembered = localStorage.getItem(STORAGE_KEY);
            if (remembered) this.nickname = remembered;
        } catch (e) {
            // localStorage can throw in some CEF contexts (private/restricted storage) - a blank
            // input is a fine fallback, this is only ever a convenience prefill
        }

        // also reopened mid-session from the full window's "Change nickname" ({change: true}) :
        // same prompt, but Cancel just closes it instead of continuing as a guest
        this.changing = false;
        $rootScope.$on("BJLoginShow", (_, data) => {
            this.changing = !!(data && data.change);
            this.error = null;
            this.submitting = false;
            if (this.changing) {
                const self = beamjoyStore.players.self;
                this.nickname = (self && (self.displayName || self.playerName)) || this.nickname;
            }
            this.visible = true;
        });

        $rootScope.$on("BJLoginResult", (_, data) => {
            this.submitting = false;
            if (data && data.success) {
                try {
                    localStorage.setItem(STORAGE_KEY, this.nickname.trim());
                } catch (e) {
                    // non-fatal, see above
                }
                this.visible = false;
            } else {
                this.error =
                    "beamjoy.window.login.error." + ((data && data.reason) || "unknown");
            }
        });

        this.submit = (event) => {
            event.stopPropagation();
            const clean = (this.nickname || "").trim();
            if (!clean || this.submitting) return;
            this.error = null;
            this.submitting = true;
            beamjoyStore.send("BJLoginSubmit", [clean]);
        };

        this.skip = (event) => {
            event.stopPropagation();
            this.visible = false;
            if (this.changing) {
                this.changing = false;
                return;
            }
            beamjoyStore.send("BJLoginSkip");
        };

        // versionCheck/app.js's own established fix for the exact same class of race (a one-time
        // Lua->Angular push landing before this component even exists to hear it, see beamjoy.js's
        // own 1000ms child-mount delay vs. beamjoyStore's own 500ms "BJReady" timer) : ask for the
        // current state on mount rather than relying solely on a push that may have already fired.
        this.$onInit = () => {
            beamjoyStore.send("BJLoginRequestState");
        };
    },
});
