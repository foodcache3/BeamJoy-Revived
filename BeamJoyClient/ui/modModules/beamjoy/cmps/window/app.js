// Persists per-window position/size (keyed by window-id) and hands out an
// incrementing z-index so the last-interacted window renders on top. Also
// consulted by windows/main and windows/config's app.js to skip re-applying
// the Lua-driven default placement once a player has manually moved/resized.
angular.module("beamjoy").service("beamjoyWindowRect", function () {
    const STORAGE_PREFIX = "beamjoy.windowRect.";
    let topZIndex = 10;

    this.get = (windowId) => {
        if (!windowId) return null;
        let raw;
        try {
            raw = localStorage.getItem(STORAGE_PREFIX + windowId);
        } catch (e) {
            return null;
        }
        if (!raw) return null;
        try {
            const rect = JSON.parse(raw);
            if (
                typeof rect.top === "number" &&
                typeof rect.left === "number" &&
                typeof rect.width === "number" &&
                typeof rect.height === "number"
            ) {
                return rect;
            }
        } catch (e) {}
        return null;
    };

    this.set = (windowId, rect) => {
        if (!windowId) return;
        try {
            localStorage.setItem(STORAGE_PREFIX + windowId, JSON.stringify(rect));
        } catch (e) {}
    };

    this.bringToFront = (element) => {
        if (!element) return;
        topZIndex += 1;
        element.style.zIndex = topZIndex;
    };
});

angular.module("beamjoy").component("bjWindow", {
    bindings: {
        windowId: "@",
        label: "@",
        visible: "<",
        minimizable: "<",
        closable: "<",
        onClose: "&?",
        background: "<",
    },
    transclude: true,
    templateUrl: "/ui/modModules/beamjoy/cmps/window/app.html",
    controller: function ($element, beamjoyWindowRect) {
        const MIN_WIDTH = 250;
        const MIN_HEIGHT = 150;

        this.minimized = false;
        this.toggleMinimized = () => {
            this.minimized = !this.minimized;
        };

        // the absolutely-positioned wrapper one level up (#beamjoy-main etc.) -
        // this component doesn't own its own position, that div does
        let container;
        let drag = null;
        let resize = null;

        const clampPosition = (top, left, width) => {
            const minVisible = 60; // keep at least this much of the header reachable
            return {
                top: Math.min(Math.max(top, 0), Math.max(window.innerHeight - minVisible, 0)),
                left: Math.min(
                    Math.max(left, minVisible - width),
                    Math.max(window.innerWidth - minVisible, 0)
                ),
            };
        };

        const saveRect = () => {
            if (!this.windowId || !container) return;
            beamjoyWindowRect.set(this.windowId, {
                top: container.offsetTop,
                left: container.offsetLeft,
                width: container.offsetWidth,
                height: container.offsetHeight,
            });
        };

        this.focus = () => {
            beamjoyWindowRect.bringToFront(container);
        };

        const onDragMove = ($event) => {
            if (!drag) return;
            const dx = $event.clientX - drag.startX;
            const dy = $event.clientY - drag.startY;
            const { top, left } = clampPosition(
                drag.startTop + dy,
                drag.startLeft + dx,
                container.offsetWidth
            );
            container.style.top = top + "px";
            container.style.left = left + "px";
        };
        const onDragEnd = () => {
            drag = null;
            document.removeEventListener("mousemove", onDragMove);
            document.removeEventListener("mouseup", onDragEnd);
            saveRect();
        };
        this.startDrag = ($event) => {
            if ($event.button !== 0 || !container) return;
            // ignore drags starting on the minimize/close buttons
            if ($event.target.closest(".window-header-buttons")) return;
            this.focus();
            drag = {
                startX: $event.clientX,
                startY: $event.clientY,
                startTop: container.offsetTop,
                startLeft: container.offsetLeft,
            };
            document.addEventListener("mousemove", onDragMove);
            document.addEventListener("mouseup", onDragEnd);
            $event.preventDefault();
        };

        const onResizeMove = ($event) => {
            if (!resize) return;
            const dx = $event.clientX - resize.startX;
            const dy = $event.clientY - resize.startY;
            const maxWidth = Math.max(window.innerWidth - container.offsetLeft, MIN_WIDTH);
            const maxHeight = Math.max(window.innerHeight - container.offsetTop, MIN_HEIGHT);
            container.style.width =
                Math.min(Math.max(resize.startWidth + dx, MIN_WIDTH), maxWidth) + "px";
            container.style.height =
                Math.min(Math.max(resize.startHeight + dy, MIN_HEIGHT), maxHeight) + "px";
        };
        const onResizeEnd = () => {
            resize = null;
            document.removeEventListener("mousemove", onResizeMove);
            document.removeEventListener("mouseup", onResizeEnd);
            saveRect();
        };
        this.startResize = ($event) => {
            if ($event.button !== 0 || !container) return;
            this.focus();
            resize = {
                startX: $event.clientX,
                startY: $event.clientY,
                startWidth: container.offsetWidth,
                startHeight: container.offsetHeight,
            };
            document.addEventListener("mousemove", onResizeMove);
            document.addEventListener("mouseup", onResizeEnd);
            $event.preventDefault();
            $event.stopPropagation();
        };

        this.$onInit = () => {
            container = $element.parent()[0];
            if (container) {
                const saved = beamjoyWindowRect.get(this.windowId);
                if (saved) {
                    container.style.top = saved.top + "px";
                    container.style.left = saved.left + "px";
                    container.style.width = saved.width + "px";
                    container.style.height = saved.height + "px";
                }
            }
        };

        this.$onDestroy = () => {
            document.removeEventListener("mousemove", onDragMove);
            document.removeEventListener("mouseup", onDragEnd);
            document.removeEventListener("mousemove", onResizeMove);
            document.removeEventListener("mouseup", onResizeEnd);
        };
    },
});
