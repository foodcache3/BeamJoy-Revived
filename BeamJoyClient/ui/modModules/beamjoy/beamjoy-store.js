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
            $rootScope.$on("BJEvent", (_, data) => {
                if (this[data.event]) {
                    this[data.event](data.payload);
                }
                $rootScope.$broadcast(data.event, data.payload);
            });
            $timeout(() => {
                this.send("BJReady");
                this.send("BJRequestNametagsState");
                this.send("BJRequestUserSettings");
            }, 500);
        }
    });
