let initCount = 0;
angular
    .module("beamjoy")
    .service("beamjoyStore", function ($rootScope, $filter, $timeout) {
        initCount++;
        this.translate = $filter("translate");

        this.accordionStates = {};

        // SERVICES

        this.players = {};
        this.groups = {};
        this.permissions = {};
        this.settings = {};
        this.utils = {};
        // server-configurable, proactively pushed (config.lua's retrieveCache) rather than
        // request-gated like the admin-only General config tab's own data: every client needs to
        // read these, not just whoever has that tab open. Defaults here match the server's own
        // (services/config.lua) until the first real push arrives.
        this.raceSettings = { authorshipRestriction: false, editorShowOnlyEditable: false };

        // METHODS

        /**
         * Sends Lua event with sync response
         *
         * @param string event
         * @param Array? payload
         * @param function? callback
         */
        this.send = (event, payload, callback) => {
            bngApi.engineLua(
                `beamjoy_communications_ui.dispatch("${event}", ${bngApi.serializeToLua(
                    payload
                )})`,
                callback
            );
        };
        if (initCount === 1) {
            // import and init services
            ["players", "groups", "permissions", "settings", "utils"].forEach(
                (service) =>
                    import(
                        `/ui/modModules/beamjoy/services/${service}.js`
                    ).then((mod) => {
                        this[service] = mod.default;
                        this[service].init(this);
                    })
            );

            this.BJUpdateGroups = (payload) => {
                this.groups.set(payload);
            };
            this.BJUpdatePermissions = (payload) => {
                this.permissions.data = payload;
            };
            this.BJPermissionsNames = (perms) => {
                this.permissions.PERMISSIONS = perms;
            };
            this.BJUpdatePlayers = (payload) => {
                this.players.set(payload);
            };
            this.BJUpdatePlayer = (payload) => {
                this.players.updatePlayer(payload.playerName, payload.data);
            };
            this.BJUpdateSelf = (payload) => {
                this.players.self = payload;
            };
            this.BJRaceSettings = (payload) => {
                this.raceSettings = payload;
            };

            this.BJNametagsState = (data) => {
                this.settings.assign({ nametags: data });
                // settings window have reference, event is unnecessary
            };
            this.BJUserCameraSettings = (data) => {
                this.settings.freecam = data;
                // settings window have reference, event is unnecessary
            };
            this.BJUserSettings = (data) => {
                this.settings.assign(data);
                // settings window have reference, event is unnecessary
            };

            /**
             * @event BJEvent
             * @description request event from beamjoy LUA
             *
             * @param {any} evt
             * @param {event: string, payload: object?} data
             */
            // wrapped in $applyAsync : guihooks.trigger() is a native->JS call from outside
            // Angular's own digest cycle. $broadcast still runs and every $rootScope.$on(...)
            // listener downstream still updates its bound scope value, but without a digest the
            // DOM never re-renders: the view sits stale until some UNRELATED Angular action
            // (a click, a $timeout) happens to trigger the next digest on its own.
            // A couple of call sites already work around this per-handler (windows/main/app.js's
            // own BJUpdateWindowSettings listener wraps itself in $applyAsync) ; centralizing it
            // here fixes it for every current and future $rootScope.$on(eventName, ...) listener
            // at once, not just the ones that happened to notice and add their own workaround.
            // $applyAsync (not $apply) is safe to call unconditionally, whether or not this was
            // already invoked from inside a digest.
            $rootScope.$on("BJEvent", (_, data) => {
                $rootScope.$applyAsync(() => {
                    if (this[data.event]) {
                        this[data.event](data.payload);
                    }
                    $rootScope.$broadcast(data.event, data.payload);
                });
            });
            $timeout(() => {
                this.send("BJReady");
                this.send("BJRequestNametagsState");
                this.send("BJRequestUserSettings");
            }, 500);
        }
    });
