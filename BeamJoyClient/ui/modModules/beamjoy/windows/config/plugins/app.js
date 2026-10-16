// one server plugin's own config tab (the plugin API's config.register : the server's
// services/pluginUi.lua stores the values). Opened by staff holding EditPluginConfig ; the values
// come on request, never with the caches, and a secret option's value never comes at all
angular.module("beamjoy").component("bjConfigPlugin", {
    templateUrl: "/ui/modModules/beamjoy/windows/config/plugins/app.html",
    bindings: {
        // "@" : the tab's template is built with the plugin's name already in it (windows/config)
        plugin: "@",
    },
    controller: function ($rootScope, $scope, $filter, beamjoyStore, beamjoyPluginUi, beamjoyConfirm) {
        const translate = $filter("translate");
        this.tab = null;
        this.loaded = false;
        // {plugins: {<plugin>: values}} : bj-plugin-options writes there
        this.holder = { plugins: {} };
        this.secrets = {};
        let saved = {};

        const findTab = () => {
            this.tab = beamjoyPluginUi.state.config.find((t) => t.plugin === this.plugin) || null;
        };
        findTab();
        $scope.$on("$destroy", $rootScope.$on("BJPluginUiChanged", findTab));

        $scope.$on("$destroy", $rootScope.$on("BJPluginConfigValues", (_, data) => {
            if (!data || data.plugin !== this.plugin) return;
            const values = data.values && typeof data.values === "object" && !Array.isArray(data.values) ? data.values : {};
            saved = angular.copy(values);
            this.holder = { plugins: { [this.plugin]: angular.copy(values) } };
            this.secrets = data.secrets && typeof data.secrets === "object" ? data.secrets : {};
            this.loaded = true;
        }));
        this.$onInit = () => beamjoyStore.send("BJPluginConfigValuesRequest", [this.plugin]);

        const values = () => (this.holder.plugins && this.holder.plugins[this.plugin]) || {};
        this.dirty = () => this.loaded && !angular.equals(values(), saved);
        this.save = () => {
            if (!this.dirty()) return;
            beamjoyStore.send("BJPluginConfigSave", [this.plugin, values()]);
        };
        this.reset = () => {
            this.holder = { plugins: { [this.plugin]: angular.copy(saved) } };
        };
        this.action = (option) => {
            const run = () => beamjoyStore.send("BJPluginConfigAction", [this.plugin, option.id]);
            if (option.confirm) beamjoyConfirm.ask(option.confirm, run);
            else run();
        };
        this.unsavedNote = () => translate("beamjoy.pluginOptions.unsaved");
    },
});
