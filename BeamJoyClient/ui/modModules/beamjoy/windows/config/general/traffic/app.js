angular.module("beamjoy").component("bjConfigGeneralTraffic", {
    templateUrl:
        "/ui/modModules/beamjoy/windows/config/general/traffic/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.init = false;
        this.dirty = false;
        this.data = {
            enabled: false,
            amount: 0,
            maxPerPlayer: 0,
            models: ["simple_traffic"],
            smartSelection: false,
            parkedAmount: 0,
            parkedMaxPerPlayer: 0,
        };
        this.modelLabels = {};
        this.selectedModel = null;
        this.modelOptions = [{ value: "simple_traffic", label: "Traffic" }];
        this.hideModels = true;
        this.hideRemoveModel = false;
        this.showSmartSelection = false;
        this.default = {};

        const updateDirty = () => {
            this.dirty = !angular.equals(this.data, this.default);
        };
        // Population/region-weighted picking (native's own "Smart Selection" traffic setting)
        // only makes sense when every candidate config actually carries that metadata, which is
        // only guaranteed for stock simple_traffic, not vehGroups or other custom models.
        const updateShowSmartSelection = () => {
            this.showSmartSelection =
                this.data.models.length === 1 &&
                this.data.models[0] === "simple_traffic";
            if (!this.showSmartSelection) this.data.smartSelection = false;
        };
        const updateModelOptions = () => {
            this.modelOptions = Object.entries(this.modelLabels)
                .filter(([k, v]) => !this.data.models.includes(k))
                .map(([k, v]) => ({ value: k, label: v }))
                .sort((a, b) => a.label.localeCompare(b.label));
            if (
                this.modelOptions[0] &&
                !this.modelOptions.some((o) => o.value === this.selectedModel)
            ) {
                // set selected model if invalid
                this.selectedModel = this.modelOptions[0].value;
            } else if (
                this.selectedModel &&
                (this.modelOptions.length === 0 ||
                    !this.modelOptions.some(
                        (o) => o.value === this.selectedModel
                    ))
            ) {
                this.selectedModel = null;
            }
            if (this.data.models.length === 0) {
                this.data.models.push("simple_traffic");
                this.hideRemoveModel = true;
            } else {
                this.hideRemoveModel =
                    this.data.models.length === 1 &&
                    this.data.models[0] === "simple_traffic";
            }
        };
        beamjoyStore.send("BJRequestTrafficSettings");
        $rootScope.$on("BJTrafficSettings", (_, payload) => {
            this.default = payload.data;
            if (!Array.isArray(this.default.models)) this.default.models = [];
            this.modelLabels = payload.models;
            this.hideModels = Object.values(payload.models).length <= 1;
            if (!this.dirty) {
                // apply form data if not dirty
                this.data = angular.copy(this.default);
            }
            if (this.data.models.some((m) => payload.models[m] === undefined)) {
                // sanitize invalid traffic models
                this.data.models = this.data.models.filter((m) => {
                    return payload.models[m] !== undefined;
                });
                this.save();
            }
            updateModelOptions();
            updateShowSmartSelection();
            updateDirty();
            this.init = true;
        });
        $rootScope.$watch(
            () => this.data,
            () => {
                if (!this.init) return;
                updateShowSmartSelection();
                updateDirty();
            },
            true
        );
        this.addModel = (evt) => {
            evt.stopPropagation();
            this.data.models.push(this.selectedModel);
            updateModelOptions();
            updateShowSmartSelection();
        };
        this.removeModel = (evt, model) => {
            evt.stopPropagation();
            this.data.models = this.data.models.filter((m) => m !== model);
            updateModelOptions();
            updateShowSmartSelection();
        };
        this.save = () => {
            this.dirty = false;
            this.data.amount = Number(this.data.amount);
            this.data.maxPerPlayer = Number(this.data.maxPerPlayer);
            this.data.parkedAmount = Number(this.data.parkedAmount);
            this.data.parkedMaxPerPlayer = Number(this.data.parkedMaxPerPlayer);
            beamjoyStore.send("BJTrafficSettings", [this.data]);
        };
        this.cancel = () => {
            this.data = Object.assign({}, this.default);
        };
    },
});
