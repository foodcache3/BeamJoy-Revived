angular.module("beamjoy").component("bjHud", {
    templateUrl: "/ui/modModules/beamjoy/windows/hud/app.html",
    controller: function ($rootScope, beamjoyStore, $timeout) {
        $rootScope.$on("BJSendAppsSizesAndPositions", (_, data) => {
            const el = data["beamjoy-hud"];
            const dom = document.querySelector("#beamjoy-hud");
            if (el && dom) {
                dom.style.width = el.width;
                dom.style.height = el.height;
                dom.style.top = el.top;
                dom.style.left = el.left;
            }
        });

        this.iconsData = [];
        $rootScope.$on("BJHUDIcon", (_, iconData) => {
            this.iconsData[iconData.pos] = iconData.state
                ? {
                      name: iconData.name,
                      color: iconData.color || "light",
                  }
                : null;
        });

        this.textData = {};
        $rootScope.$on("BJHUDText", (_, textData) => {
            if (this.textData.process) {
                $timeout.cancel(this.textData.process);
                this.textData.process = null;
            }
            if (
                textData.message &&
                textData.message !== this.textData.message
            ) {
                this.textData = textData.message
                    ? {
                          message: textData.message,
                          color: "transparent",
                      }
                    : {};
                $timeout(() => {
                    // delay for text auto-fit process to finish
                    this.textData.color = textData.color || "white";
                    this.textData.shadow = "3px 3px 5px rgba(0, 0, 0, 0.43)";
                }, 0);
            }
            if (textData.message && textData.duration) {
                this.textData.process = $timeout(() => {
                    this.textData.process = null;
                    beamjoyStore.send("BJHUDTextTimeout", [
                        this.textData.message,
                    ]);
                    this.textData = {};
                }, textData.duration);
            }
        });

        // its size and position : Lua's push at the join can come before this window exists
        this.$onInit = () => beamjoyStore.send("BJRequestWindowSettings");
    },
});
