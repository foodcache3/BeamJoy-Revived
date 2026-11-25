// Persists per-window position/size and background opacity (keyed by window-id) and hands out
// an incrementing z-index so the last-interacted window renders on top. Also
// consulted by windows/main and windows/config's app.js to skip re-applying
// the Lua-driven default placement once a player has manually moved/resized.
angular.module("beamjoy").service("beamjoyWindowRect", function () {
    const STORAGE_PREFIX = "beamjoy.windowRect.";
    const OPACITY_PREFIX = "beamjoy.windowOpacity.";
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

    // how solid this window's background is, 0 to 1, or null when the player has never said.
    // Per window and per player, in the same browser localStorage as the rect above rather than
    // Lua's own localStorage : it's the same kind of state (where I like my windows), it's read
    // while the component builds, and nothing outside this UI ever needs to know it.
    this.getOpacity = (windowId) => {
        if (!windowId) return null;
        let raw;
        try {
            raw = localStorage.getItem(OPACITY_PREFIX + windowId);
        } catch (e) {
            return null;
        }
        const value = parseFloat(raw);
        return isNaN(value) || value < 0 || value > 1 ? null : value;
    };

    this.setOpacity = (windowId, value) => {
        if (!windowId) return;
        try {
            localStorage.setItem(OPACITY_PREFIX + windowId, String(value));
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
        // The original theory for "scrolling feels unresponsive" was that this CEF build's native
        // wheel-scroll delta is just small (a couple pixels per tick), fixed by multiplying it.
        // But that multiplier was applied to `.window-content` specifically, and it turns out
        // `.window-content` usually isn't the element that's actually scrolling. `bj-config`'s
        // content is `bj-tabs`, which is itself `height:100%; overflow:hidden` with its OWN
        // `.tab-content` child doing the real scrolling (and, for the race editor specifically,
        // there's now a THIRD level down, `.section-panel`, doing the real scrolling instead of
        // `.tab-content`). `.window-content` never actually overflows in any of these cases, so
        // multiplying its scrollTop was a no-op: the real, untouched, un-accelerated browser
        // default wheel-scroll on whichever nested element actually has the overflow is what the
        // user was feeling (its own native easing reads as "delayed" compared to instant/direct
        // scrolling elsewhere). Walking up from the actual wheel target to find whichever ancestor
        // is truly scrollable, rather than hardcoding a specific nesting depth/class name, keeps
        // this correct regardless of how many scroll levels any given window/tab/panel ends up
        // with.
        const WHEEL_SCROLL_MULTIPLIER = 4;

        // How solid the window's background is. 0.2 is what it has always been and stays the
        // default ; the rest are the same step up and down, per direct request ("an opacity button
        // that cycles the transparency in 20% increments"). 0 is no background at all, which is
        // the point for anyone who wants to see the road through the panel.
        //
        // Only drawn for a window that has a background to begin with (`background`), which today
        // is the config window alone - but it belongs here rather than there, because any window
        // that gains a background gets the control with it instead of needing its own copy.
        const OPACITY_STEPS = [0.2, 0.4, 0.6, 0.8, 1, 0];
        this.opacity = OPACITY_STEPS[0];
        // a CSS custom property on OUR OWN element, which the two background rules read. Never on
        // documentElement : an md-select closing restores that element's whole inline style and
        // would silently wipe it (the same trap the HUD hit).
        const applyOpacity = () => {
            $element[0].style.setProperty(
                "--bj-window-bg",
                "rgba(0, 0, 0, " + this.opacity + ")"
            );
        };
        this.opacityPercent = () => Math.round(this.opacity * 100);
        this.cycleOpacity = ($event) => {
            if ($event) $event.stopPropagation();
            const at = OPACITY_STEPS.indexOf(this.opacity);
            this.opacity = OPACITY_STEPS[(at + 1) % OPACITY_STEPS.length];
            applyOpacity();
            beamjoyWindowRect.setOpacity(this.windowId, this.opacity);
        };

        this.minimized = false;
        this.toggleMinimized = () => {
            this.minimized = !this.minimized;
        };

        // the absolutely-positioned wrapper one level up (#beamjoy-main etc.) -
        // this component doesn't own its own position, that div does
        let container;
        let drag = null;
        let resize = null;
        let content;
        const findScrollTarget = (el) => {
            while (el && el !== content.parentElement) {
                if (el instanceof Element) {
                    const style = window.getComputedStyle(el);
                    const scrollableY = style.overflowY === "auto" || style.overflowY === "scroll";
                    if (scrollableY && el.scrollHeight > el.clientHeight) return el;
                }
                el = el.parentElement;
            }
            return content;
        };
        const onContentWheel = (evt) => {
            const target = findScrollTarget(evt.target);
            target.scrollTop += evt.deltaY * WHEEL_SCROLL_MULTIPLIER;
            evt.preventDefault();
        };

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
            const savedOpacity = beamjoyWindowRect.getOpacity(this.windowId);
            // an exact step, or the nearest one : a value from an older build (or a hand-edited
            // one) still has to leave the cycle somewhere it can continue from
            if (savedOpacity !== null) {
                this.opacity = OPACITY_STEPS.reduce((best, step) =>
                    Math.abs(step - savedOpacity) < Math.abs(best - savedOpacity) ? step : best
                );
            }
            applyOpacity();

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
            content = $element[0].querySelector(".window-content");
            if (content) {
                content.addEventListener("wheel", onContentWheel, { passive: false });
            }
        };

        this.$onDestroy = () => {
            if (content) content.removeEventListener("wheel", onContentWheel);
            document.removeEventListener("mousemove", onDragMove);
            document.removeEventListener("mouseup", onDragEnd);
            document.removeEventListener("mousemove", onResizeMove);
            document.removeEventListener("mouseup", onResizeEnd);
        };
    },
});
