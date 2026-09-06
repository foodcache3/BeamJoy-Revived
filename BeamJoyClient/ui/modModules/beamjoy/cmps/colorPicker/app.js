const hsvToHex = (h, s, v) => {
    let f = (n, k = (n + h / 60) % 6) =>
        v - v * s * Math.max(Math.min(k, 4 - k, 1), 0);
    let r = Math.round(f(5) * 255);
    let g = Math.round(f(3) * 255);
    let b = Math.round(f(1) * 255);
    return "#" + [r, g, b].map((x) => x.toString(16).padStart(2, "0")).join("");
};
const hexToHsv = (hex) => {
    let bigint = parseInt(hex.slice(1), 16);
    let r = (bigint >> 16) & 255,
        g = (bigint >> 8) & 255,
        b = bigint & 255;
    r /= 255;
    g /= 255;
    b /= 255;
    let max = Math.max(r, g, b),
        min = Math.min(r, g, b);
    let h,
        s,
        v = max;
    let d = max - min;
    s = max == 0 ? 0 : d / max;
    if (max == min) h = 0;
    else {
        switch (max) {
            case r:
                h = (g - b) / d + (g < b ? 6 : 0);
                break;
            case g:
                h = (b - r) / d + 2;
                break;
            case b:
                h = (r - g) / d + 4;
                break;
        }
        h *= 60;
    }
    return { h, s, v };
};

angular
    .module("beamjoy")
    .service("colorPicker", function ($document) {
        let h = 0,
            s = 0,
            v = 0;
        this.ctrl = null;

        let pickerWrapper;
        const setPosition = (element) => {
            const parent = element.getBoundingClientRect();
            const viewport = {
                x: window.innerWidth,
                y: window.innerHeight,
            };
            const parentCenter = {
                x: parent.left + parent.width / 2,
                y: parent.top + parent.height / 2,
            };
            pickerWrapper.style.inset = "unset";
            pickerWrapper.style.left = "unset";
            pickerWrapper.style.right = "unset";
            pickerWrapper.style.top = "unset";
            pickerWrapper.style.bottom = "unset";
            if (parentCenter.y < viewport.y / 2) {
                pickerWrapper.style.top = `${parent.top}px`;
            } else {
                pickerWrapper.style.bottom = `${viewport.y - parent.bottom}px`;
            }
            if (parentCenter.x < viewport.x / 2) {
                pickerWrapper.style.left = `${parent.right}px`;
            } else {
                pickerWrapper.style.right = `${viewport.x - parent.left}px`;
            }
        };

        const startSV = (evt) => {
            moveSV(evt);
            $document.on("mousemove", moveSV);
            $document.on("mouseup", stopSV);
        };
        const moveSV = (evt) => {
            const svFrame = evt.target.closest(".sv-picker");
            if (svFrame) {
                const rect = svFrame.getBoundingClientRect();
                const x = Math.min(
                    Math.max(evt.clientX - rect.left, 0),
                    rect.width
                );
                const y = Math.min(
                    Math.max(evt.clientY - rect.top, 0),
                    rect.height
                );
                s = x / rect.width;
                v = 1 - y / rect.height;
                this.ctrl.update(hsvToHex(h, s, v));
                updatePicker();
            }
        };
        const stopSV = () => {
            $document.off("mousemove", moveSV);
            $document.off("mouseup", stopSV);
        };

        const startHue = (evt) => {
            moveHue(evt);
            $document.on("mousemove", moveHue);
            $document.on("mouseup", stopHue);
        };
        const moveHue = (evt) => {
            const hueFrame = evt.target.closest(".hue-picker");
            if (hueFrame) {
                const rect = hueFrame.getBoundingClientRect();
                const y = Math.min(
                    Math.max(evt.clientY - rect.top, 0),
                    rect.height
                );
                h = (y / rect.height) * 360;
                this.ctrl.update(hsvToHex(h, s, v));
                updatePicker();
            }
        };
        const stopHue = () => {
            $document.off("mousemove", moveHue);
            $document.off("mouseup", stopHue);
        };

        const setColor = (hexColor) => {
            const hsv = hexToHsv(hexColor || "#FF0000");
            h = hsv.h;
            s = hsv.s;
            v = hsv.v;
        };

        const updatePicker = () => {
            const sv = pickerWrapper.querySelector(".sv-picker");
            sv.style.backgroundColor = `hsl(${h},100%,50%)`;
            const svCursor = sv.querySelector(".sv-cursor");
            svCursor.style.left = `${s * 100}%`;
            svCursor.style.top = `${(1 - v) * 100}%`;
            const hueCursor = pickerWrapper.querySelector(".hue-cursor");
            hueCursor.style.top = `${(h / 360) * 100}%`;
        };

        const createListeners = () => {
            const sv = pickerWrapper.querySelector(".sv-picker");
            sv.addEventListener("mousedown", startSV);
            const hue = pickerWrapper.querySelector(".hue-picker");
            hue.addEventListener("mousedown", startHue);
        };

        this.update = (ctrl) => {
            if (!pickerWrapper) {
                pickerWrapper = document.querySelector("beamjoy-color-picker");
                createListeners();
            }
            if (ctrl) {
                setPosition(ctrl.el);
                setColor(ctrl.ngModel);
                updatePicker();
                pickerWrapper.classList.add("show");
                this.ctrl = ctrl;
            } else if (this.ctrl) {
                this.ctrl.onClose();
                pickerWrapper.classList.remove("show");
                this.ctrl = null;
            }
        };
    })
    .component("bjColorPicker", {
        bindings: {
            ngModel: "=",
            disabled: "<?",
        },
        templateUrl: "/ui/modModules/beamjoy/cmps/colorPicker/app.html",
        controller: function (
            $scope,
            $element,
            $document,
            $timeout,
            colorPicker
        ) {
            const checkClickOutside = (evt) => {
                if (!evt.target.closest("beamjoy-color-picker")) {
                    close();
                }
            };
            this.onClose = () => {
                $document.off("click", checkClickOutside);
            };
            const close = () => {
                if (colorPicker.ctrl !== this) return;
                colorPicker.update(null);
                this.onClose();
            };
            const open = () => {
                if (colorPicker.ctrl === this) return;
                colorPicker.update(this);
                $timeout(() => {
                    $document.on("click", checkClickOutside);
                }, 100);
            };
            this.onToggle = () => {
                this.el = $element[0];
                if (this.disabled) return;
                if (colorPicker.ctrl === this) {
                    close();
                } else {
                    open();
                }
            };
            // Real gap: no way to go back to "no color set" (free paint choice for that role)
            // once one had been picked, short of editing the saved data directly.
            this.clear = (event) => {
                event.stopPropagation();
                if (this.disabled) return;
                if (colorPicker.ctrl === this) close();
                this.ngModel = null;
                $scope.$applyAsync();
            };
            $scope.$watch(
                () => this.ngModel,
                () => {
                    if (colorPicker.ctrl === this) {
                        open();
                    }
                }
            );
            $scope.$watch(
                () => this.disabled,
                () => {
                    if (this.disabled && colorPicker.ctrl === this) {
                        close();
                    }
                }
            );
            this.update = (newColor) => {
                if (this.disabled) return;
                this.ngModel = newColor;
                $scope.$applyAsync();
            };
            this.$onDestroy = () => {
                if (colorPicker.ctrl === this) {
                    close();
                }
            };
        },
    })
    .run(function ($rootScope) {
        if (document.querySelector("beamjoy-color-picker")) return;

        const picker = document.createElement("beamjoy-color-picker");
        picker.innerHTML = `
            <div class="sv-picker">
                <div class="sv-cursor"></div>
            </div>
            <div class="hue-picker">
                <div class="hue-cursor"></div>
            </div>
        `;
        document.body.prepend(picker);

        $rootScope.$on("BJUnload", () => {
            document.querySelector("beamjoy-color-picker").remove();
        });
    });
