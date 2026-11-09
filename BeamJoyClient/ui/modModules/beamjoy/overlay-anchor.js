// Where the activity overlays sit on screen (direct request). The race, bus, drag, derby, hunter,
// infected, delivery and drift zone panels each hardcoded the same `top: 2vh; right: 1vw` in their
// own rule, with the pit menu pinned one panel's width further in from that same corner and the
// plugin overlays' default stack sitting on top of them. All of them read the corner from the CSS
// custom properties written here instead, so the one setting in Settings > Menu moves the whole
// cluster together rather than needing a switch per overlay.
//
// Kept in the UI's own localStorage, like the sidebar's position and the race HUD's layout: it's a
// preference of this PC's, not something the server has an opinion about. Every rule that reads
// these also carries the shipped value as its own var() fallback, so an overlay still lands in the
// top-right corner it always had if this never runs - CEF with site data blocked, or a UI bundle
// cached from before this existed.

// the corners a panel can hug. The names are the plugin overlay API's own
// (windows/pluginOverlays), so a plugin panel that never asked for a corner can simply join
// whichever stack the player has picked
const BJ_OV_CORNERS = ["top-right", "top-left", "bottom-right", "bottom-left"];
const BJ_OV_DEFAULTS = { corner: "top-right", x: 1, y: 2 };
// as far as a typed offset may go, in vw/vh. The sliders offer less than this (0-20) ; a value
// typed past that is still kept, the way bj-slider's hardMax works everywhere else
const BJ_OV_LIMIT = 40;
// how far in the pit menu sits from the panel beside it: the race HUD's own width. This has to
// agree with windows/pitControl/app.html, whose own fallback says the same
const BJ_OV_BESIDE = "22.5em";
const BJ_OV_KEY = "beamjoy.overlays.anchor";

const bjOvOffset = (value, fallback) =>
    typeof value === "number" && isFinite(value) ? Math.min(BJ_OV_LIMIT, Math.max(0, value)) : fallback;

// `base` is what an unreadable field falls back to: the anchor in force for a change, the
// shipped defaults when there's nothing yet. It matters that a change keeps what's there -
// bj-slider blanks its own model while a value is being typed into it (see its note on that), so
// a default here would snap the offset back mid-keystroke
const bjOvSanitize = (a, base) => {
    const from = base || BJ_OV_DEFAULTS;
    return {
        corner: a && BJ_OV_CORNERS.indexOf(a.corner) !== -1 ? a.corner : from.corner,
        x: bjOvOffset(a && a.x, from.x),
        y: bjOvOffset(a && a.y, from.y),
    };
};

const bjOvRead = () => {
    try {
        return bjOvSanitize(JSON.parse(localStorage.getItem(BJ_OV_KEY) || "null"));
    } catch (e) {
        // storage unavailable, or holding something unparseable: the corner it ships in
        return Object.assign({}, BJ_OV_DEFAULTS);
    }
};

const bjOvWrite = (a) => {
    try {
        localStorage.setItem(BJ_OV_KEY, JSON.stringify(a));
    } catch (e) {
        // not remembered for next time, still applied for this session
    }
};

// Put on :root through a stylesheet of our own, NOT on the document element's inline style, which
// is where this started and is the whole of the reported bug: Angular Material takes a copy of
// `<html>`'s entire style attribute when a dropdown menu opens and writes that copy straight back
// when the menu closes (disableScrollAround / disableBodyScroll in angular-material.js, which the
// game ships). Anything written to the inline style while a bj-select was open therefore survived
// only as long as the menu did - picking a corner moved the overlays and then put them back where
// they were, with no second write of our own anywhere in sight. The sliders never showed it,
// because a slider opens no menu. A stylesheet is out of reach of that copy.
const BJ_OV_SHEET_ID = "bj-overlay-anchor";
let bjOvSheet = null;

const bjOvApply = (a) => {
    const x = `${a.x}vw`;
    const y = `${a.y}vh`;
    const top = a.corner.indexOf("top-") === 0;
    const right = a.corner.indexOf("-right") !== -1;
    const vars = {
        // the gap from whichever edges a panel hugs. The plugin stacks each hug a corner named by
        // the plugin, so they take these two and work out their own sides from their class
        "--bj-ov-x": x,
        "--bj-ov-y": y,
        // the chosen corner resolved for a panel that just wants to be put somewhere: two real
        // distances and two `auto`s, which is what lets one rule cover all four corners
        "--bj-ov-top": top ? y : "auto",
        "--bj-ov-bottom": top ? "auto" : y,
        "--bj-ov-right": right ? x : "auto",
        "--bj-ov-left": right ? "auto" : x,
        // the pit menu, one panel's width further in from the same side
        "--bj-ov-beside-right": right ? `calc(${x} + ${BJ_OV_BESIDE})` : "auto",
        "--bj-ov-beside-left": right ? "auto" : `calc(${x} + ${BJ_OV_BESIDE})`,
    };

    const root = document.documentElement;
    // an inline declaration outranks the stylesheet, and nothing writes one any more - but a
    // leftover from a build that did would quietly pin every overlay to wherever it last pointed,
    // so clear it the once before the sheet goes in
    if (root && root.style) Object.keys(vars).forEach((name) => root.style.removeProperty(name));

    if (!bjOvSheet || !bjOvSheet.parentNode) {
        bjOvSheet = document.getElementById(BJ_OV_SHEET_ID);
        if (!bjOvSheet) {
            bjOvSheet = document.createElement("style");
            bjOvSheet.id = BJ_OV_SHEET_ID;
        }
        (document.head || root).appendChild(bjOvSheet);
    }
    bjOvSheet.textContent =
        ":root {\n" +
        Object.keys(vars)
            .map((name) => `    ${name}: ${vars[name]};`)
            .join("\n") +
        "\n}\n";
};

angular.module("beamjoy").factory("beamjoyOverlayAnchor", function ($rootScope) {
    let anchor = bjOvRead();
    bjOvApply(anchor);

    const publish = () => {
        bjOvApply(anchor);
        // CSS covers every panel that names its own side ; this is for the one thing a stylesheet
        // can't do - the plugin panels with no corner of their own have to be regrouped into the
        // stack the player picked (windows/pluginOverlays)
        $rootScope.$broadcast("BJOverlayAnchor", Object.assign({}, anchor));
    };

    return {
        CORNERS: BJ_OV_CORNERS,
        DEFAULTS: Object.assign({}, BJ_OV_DEFAULTS),
        LIMIT: BJ_OV_LIMIT,
        get: () => Object.assign({}, anchor),
        corner: () => anchor.corner,
        /** @param patch {corner?: string, x?: number, y?: number} */
        set: (patch) => {
            const next = bjOvSanitize(Object.assign({}, anchor, patch || {}), anchor);
            if (next.corner === anchor.corner && next.x === anchor.x && next.y === anchor.y) return;
            anchor = next;
            bjOvWrite(anchor);
            publish();
        },
        reset: () => {
            anchor = Object.assign({}, BJ_OV_DEFAULTS);
            bjOvWrite(anchor);
            publish();
        },
    };
});

angular.module("beamjoy").run(function (beamjoyOverlayAnchor) {
    // instantiated at startup, so the saved corner is applied before the first overlay is drawn
    // rather than only once somebody opens the settings page
});
