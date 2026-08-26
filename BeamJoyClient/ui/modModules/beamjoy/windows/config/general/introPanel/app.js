angular.module("beamjoy").component("bjConfigGeneralIntropanel", {
    templateUrl:
        "/ui/modModules/beamjoy/windows/config/general/introPanel/app.html",
    controller: function ($rootScope, beamjoyStore) {
        this.imageOptions = [];
        this.default = {};
        this.data = {
            enabled: false,
            title: "",
            content: "",
            image: null,
            onlyFirstConnection: false,
        };

        this.init = false;
        this.dirty = false;
        this.updateDirty = () => {
            this.dirty =
                this.dirty ||
                JSON.stringify(this.data) !== JSON.stringify(this.default);
        };

        // a custom image is a root-relative local path (e.g. "/ui/myAssets/image.jpg") to an
        // image delivered to clients via the server's own Resources/Client/ folder -- matches
        // uiHelpers.lua's own openPanel detection ; a live http(s):// URL is deliberately not
        // supported here, since BeamNG's engine blocks cross-origin loads for almost every domain
        // ; anything else is treated as one of the bundled native option keys from imageOptions
        this.isCustomImage = () =>
            typeof this.data.image === "string" && this.data.image.startsWith("/");
        this.toggleCustomImage = () => {
            if (this.isCustomImage()) {
                this.data.image =
                    this.imageOptions.length > 0
                        ? this.imageOptions[0].value
                        : null;
            } else {
                this.data.image = "/";
            }
        };
        this.imagePreviewUrl = () =>
            this.isCustomImage()
                ? this.data.image
                : `../../../gameplay/tutorials/pages/${this.data.image}/image.jpg`;

        // folder-browse assist for the custom-image path : lets an admin list whatever image
        // files are actually sitting in a folder (from their own server-delivered resource, or
        // anywhere else in the game's merged mod filesystem) instead of typing the exact filename
        this.browseFolder = "";
        this.folderImages = [];
        this.folderImagesRequested = false;
        this.listFolderImages = () => {
            this.folderImagesRequested = false;
            beamjoyStore.send("BJRequestIntroPanelImagesInFolder", [
                this.browseFolder,
            ]);
        };
        $rootScope.$on("BJSendIntroPanelImagesInFolder", (_, data) => {
            $rootScope.$applyAsync(() => {
                this.browseFolder = data.folderPath;
                // bj-select expects {value, label} entries, matching imageOptions' own shape ;
                // the label just shows the filename (after the last "/") instead of the full path,
                // since the folder itself is already known/fixed from the input above
                this.folderImages = data.images.map((img) => ({
                    value: img,
                    label: img.split("/").pop(),
                }));
                this.folderImagesRequested = true;
            });
        });

        const updateData = (data) => {
            data.settings.content = data.settings.content
                .replaceAll("<br/>", "\n")
                .replaceAll("%%", "%");
            this.default = angular.copy(data.settings);
            this.imageOptions = data.images;
            if (!this.dirty) {
                this.data = data.settings;
            }
            if (!this.init) {
                $rootScope.$watch(() => this.data, this.updateDirty, true);
                this.init = true;
            }
        };
        $rootScope.$on("BJSendIntroPanelData", (_, data) => {
            $rootScope.$applyAsync(() => updateData(data));
        });
        this.preview = () => {
            beamjoyStore.send("BJOpenIntroPanel", [
                this.data.title,
                this.data.content
                    .replaceAll("\n", "<br/>")
                    .replaceAll("%", "%%"),
                this.data.image,
            ]);
        };
        this.save = () => {
            const payload = angular.copy(this.data);
            payload.content = payload.content
                .replaceAll("\n", "<br/>")
                .replaceAll("%", "%%");
            beamjoyStore.send("BJSaveIntroPanelData", [payload]);
            this.dirty = false;
        };
        this.cancel = () => {
            this.dirty = false;
            beamjoyStore.send("BJRequestIntroPanelData");
        };
        this.reset = () => {
            this.dirty = false;
            beamjoyStore.send("BJResetIntroPanelData");
        };

        this.$onInit = () => {
            beamjoyStore.send("BJRequestIntroPanelData");
        };
    },
});
