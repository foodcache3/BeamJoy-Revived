// Generic reusable confirm-dialog primitive. The race editor is its first consumer (save
// overwrite / discard changes / delete / duplicate), but nothing here is race-specific, following
// this project's own "build ambient/UI primitives generically, don't hard-wire them to the first
// feature that needs them" convention.
//
// Deliberately Angular-native, not `uiHelpers.popupConfirm` (a native BeamNG `ui_missionInfo`
// dialogue): that native popup was found to render but not actually respond to clicks in this
// mod's context, and separately couldn't block the rest of the CEF UI (closing the window /
// switching tabs underneath it) since it lives outside the Angular/CEF layer entirely. A modal
// rendered *inside* our own already-proven-working UI can do both: real clickable buttons, and a
// full-viewport backdrop that captures every click so nothing behind it is reachable while a
// decision is pending.
angular.module("beamjoy").service("beamjoyConfirm", function () {
    this.state = {
        visible: false,
        message: "",
        showInput: false,
        inputValue: "",
        inputPlaceholder: "",
        inputMaxLength: null,
        dangerous: true,
        infoOnly: false,
        onConfirm: null,
        onCancel: null,
    };

    this.ask = (message, onConfirm, onCancel) => {
        this.state.visible = true;
        this.state.message = message;
        this.state.showInput = false;
        this.state.inputValue = "";
        this.state.dangerous = true;
        this.state.infoOnly = false;
        this.state.onConfirm = onConfirm;
        this.state.onCancel = onCancel;
    };

    // pure informational popup: a single "Close" button, no Cancel/Confirm decision to make.
    // Reuses the same modal (full-viewport backdrop, scrollable message box) rather than building
    // a second primitive just for "explain something, then dismiss".
    this.info = (message, onClose) => {
        this.state.visible = true;
        this.state.message = message;
        this.state.showInput = false;
        this.state.inputValue = "";
        this.state.dangerous = false;
        this.state.infoOnly = true;
        this.state.onConfirm = onClose;
        this.state.onCancel = null;
    };

    // same modal, plus a required text input: confirm stays disabled until it's non-empty.
    // onConfirm receives the trimmed typed value. Styled non-"dangerous" (green, not red) by
    // default since this variant's first use (race "Save as New") is a creation, not a
    // destructive action, unlike every existing `ask()` caller. maxLength is optional (null/
    // undefined = unlimited, the previous behavior); pass it whenever the value being collected
    // has its own server-enforced limit (e.g. a race name), so the input can't be typed past
    // it and silently fail to save later.
    this.askForInput = (message, defaultValue, placeholder, onConfirm, onCancel, maxLength) => {
        this.state.visible = true;
        this.state.message = message;
        this.state.showInput = true;
        this.state.inputValue = defaultValue || "";
        this.state.inputPlaceholder = placeholder || "";
        this.state.inputMaxLength = maxLength || null;
        this.state.dangerous = false;
        this.state.infoOnly = false;
        this.state.onConfirm = onConfirm;
        this.state.onCancel = onCancel;
    };

    this.resolve = (confirmed) => {
        const { onConfirm, onCancel, showInput, inputValue } = this.state;
        this.state.visible = false;
        this.state.message = "";
        this.state.showInput = false;
        this.state.inputValue = "";
        this.state.inputMaxLength = null;
        this.state.infoOnly = false;
        this.state.onConfirm = null;
        this.state.onCancel = null;
        if (confirmed && onConfirm) onConfirm(showInput ? inputValue.trim() : undefined);
        if (!confirmed && onCancel) onCancel();
    };
});

// Generic "ask before leaving" guard: a child component with unsaved changes registers itself
// here; anything that navigates *away* from it (switching config tabs, closing the config window)
// routes through `check()` first instead of acting immediately, so the discard-changes confirm
// actually has a chance to block the navigation rather than just firing after the fact once the
// component's already being torn down (a real bug : the editor's own $destroy handler can ask,
// but by then Angular has already committed to destroying it, too late to stop a tab
// switch or window close in progress).
angular.module("beamjoy").service("beamjoyNavGuard", function (beamjoyConfirm) {
    let guardFn = null;
    let message = "";

    this.set = (fn, confirmMessage) => {
        guardFn = fn;
        message = confirmMessage;
    };
    this.clear = (fn) => {
        if (guardFn === fn) {
            guardFn = null;
        }
    };
    this.check = (onProceed) => {
        if (!guardFn || !guardFn()) {
            onProceed();
            return;
        }
        beamjoyConfirm.ask(message, onProceed);
    };
});

angular.module("beamjoy").component("bjConfirm", {
    templateUrl: "/ui/modModules/beamjoy/cmps/confirm/app.html",
    controller: function (beamjoyConfirm) {
        this.state = beamjoyConfirm.state;
        this.confirm = (event) => {
            event.stopPropagation();
            if (this.state.showInput && !this.state.inputValue.trim()) return;
            beamjoyConfirm.resolve(true);
        };
        this.cancel = (event) => {
            event.stopPropagation();
            beamjoyConfirm.resolve(false);
        };
    },
});
