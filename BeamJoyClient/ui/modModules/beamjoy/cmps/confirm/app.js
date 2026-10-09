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
        // askChecklist's rows ; null for every other kind of dialog
        checklist: null,
        onConfirm: null,
        onCancel: null,
    };

    this.ask = (message, onConfirm, onCancel) => {
        this.state.checklist = null;
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
        this.state.checklist = null;
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
        this.state.checklist = null;
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

    // same modal, with a list of rows the player ticks before confirming (the legacy importers :
    // which races, arenas, maps go ahead). items : {key, label, detail?, group?, tag?, disabled?,
    // checked?} ; rows start ticked unless `checked === false`, and a disabled row (something
    // that can't be imported, `tag` says why) can't be ticked at all. Rows sharing a `group` sit
    // under one heading that ticks or unticks the whole group. onConfirm receives the ticked keys ;
    // confirm stays disabled while nothing is ticked.
    // options.modes (optional) : [{key, label, hint?}], buttons over the list choosing what the
    // ticked rows do (the map race importer : everything, gates only, props only) ; a row's own
    // `modes[key]` ({disabled, tag, checked}) replaces its state in that mode. onConfirm then also
    // receives the chosen mode's key. options.mode : the one chosen first.
    this.askChecklist = (message, items, onConfirm, onCancel, options) => {
        this.state.checklistModes = (options && Array.isArray(options.modes) && options.modes.length)
            ? options.modes : null;
        this.state.checklistMode = null;
        this.state.visible = true;
        this.state.message = message;
        this.state.showInput = false;
        this.state.inputValue = "";
        this.state.dangerous = false;
        this.state.infoOnly = false;
        const rows = (items || []).map((item) =>
            Object.assign({}, item, { checked: !item.disabled && item.checked !== false })
        );
        const groups = [];
        rows.forEach((row) => {
            let group = groups.find((g) => g.name === (row.group || ""));
            if (!group) {
                group = { name: row.group || "", rows: [] };
                groups.push(group);
            }
            group.rows.push(row);
        });
        this.state.checklist = groups;
        this.state.onConfirm = onConfirm;
        this.state.onCancel = onCancel;
        if (this.state.checklistModes) {
            this.setChecklistMode((options && options.mode) || this.state.checklistModes[0].key);
        }
    };

    // a mode's own rows : each row as that mode has it, ticks back to that mode's defaults
    this.setChecklistMode = (key) => {
        if (!this.state.checklist || !this.state.checklistModes) return;
        this.state.checklistMode = key;
        this.state.checklist.forEach((group) => group.rows.forEach((row) => {
            if (!row.base) row.base = { disabled: row.disabled, tag: row.tag, checked: row.checked };
            const own = (row.modes && row.modes[key]) || {};
            row.disabled = own.disabled !== undefined ? own.disabled : row.base.disabled;
            row.tag = own.tag !== undefined ? own.tag : row.base.tag;
            row.checked = !row.disabled && (own.checked !== undefined ? own.checked !== false : row.base.checked);
        }));
    };

    this.resolve = (confirmed) => {
        const { onConfirm, onCancel, showInput, inputValue, checklist, checklistMode } = this.state;
        const picked = checklist
            ? checklist.flatMap((g) => g.rows.filter((r) => r.checked).map((r) => r.key))
            : undefined;
        this.state.checklist = null;
        this.state.checklistModes = null;
        this.state.checklistMode = null;
        this.state.visible = false;
        this.state.message = "";
        this.state.showInput = false;
        this.state.inputValue = "";
        this.state.inputMaxLength = null;
        this.state.infoOnly = false;
        this.state.onConfirm = null;
        this.state.onCancel = null;
        if (confirmed && onConfirm) {
            if (checklist) onConfirm(picked, checklistMode || undefined);
            else onConfirm(showInput ? inputValue.trim() : undefined);
        }
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
    controller: function (beamjoyConfirm, $filter) {
        const translate = $filter("translate");
        this.state = beamjoyConfirm.state;
        this.confirm = (event) => {
            event.stopPropagation();
            if (this.state.showInput && !this.state.inputValue.trim()) return;
            if (this.state.checklist && this.checkedCount() === 0) return;
            beamjoyConfirm.resolve(true);
        };

        // CHECKLIST
        const rows = () => (this.state.checklist || []).flatMap((g) => g.rows);
        this.checkedCount = () => rows().filter((r) => r.checked).length;
        this.selectableCount = () => rows().filter((r) => !r.disabled).length;
        this.countText = () => translate("beamjoy.confirm.checklist.count")
            .replace("{count}", this.checkedCount())
            .replace("{total}", this.selectableCount());
        this.toggleRow = (row, event) => {
            if (event) event.stopPropagation();
            if (!row.disabled) row.checked = !row.checked;
        };
        const setAll = (list, value) => list.forEach((r) => {
            if (!r.disabled) r.checked = value;
        });
        // a heading ticks the whole group, or unticks it once every row in it is ticked
        this.toggleGroup = (group, event) => {
            if (event) event.stopPropagation();
            const selectable = group.rows.filter((r) => !r.disabled);
            setAll(group.rows, !selectable.every((r) => r.checked));
        };
        this.groupState = (group) => {
            const selectable = group.rows.filter((r) => !r.disabled);
            const ticked = selectable.filter((r) => r.checked).length;
            return ticked === 0 ? "none" : ticked === selectable.length ? "all" : "some";
        };
        this.selectAll = (value, event) => {
            if (event) event.stopPropagation();
            setAll(rows(), value);
        };
        this.setMode = (key, event) => {
            if (event) event.stopPropagation();
            beamjoyConfirm.setChecklistMode(key);
        };
        this.modeHint = () => {
            const mode = (this.state.checklistModes || []).find((m) => m.key === this.state.checklistMode);
            return mode && mode.hint;
        };
        this.cancel = (event) => {
            event.stopPropagation();
            beamjoyConfirm.resolve(false);
        };
    },
});
