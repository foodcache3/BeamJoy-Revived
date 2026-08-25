angular.module("beamjoy").service("bjChat", function ($rootScope) {
    // Previously rebuilt the whole message DOM node by hand and appended it to #chat-list
    // directly. Broke silently after BeamNG 0.39 moved the native chat UI to a real "UI App"
    // (BeamMP-Chat/app.js) and got stubbed out to a no-op rather than fixed, meaning no BJS chat
    // message (including the player's own, echoed back by the server) ever displayed at all.
    // BeamMP-Chat/app.js's own `addMessage(msg)` is a plain global function (not Angular/Vue
    // scoped: that file is a classic non-module script, so its top-level function declarations
    // land on `window`), already handling the timestamp, fade-in, scrollback, and localStorage
    // persistence #chat-list needs, so this reuses it instead of re-deriving all of that. Its own
    // rich-formatting path only understands BeamMP's own `^`-color-code syntax for
    // "Server: "-prefixed messages, not arbitrary per-message RGB, so this only restores plain
    // text (sender tag + name + message); the old per-message custom color styling isn't
    // reproduced here.
    $rootScope.$on("BJChat", (_, rawMsg) => {
        let payload;
        try {
            payload = JSON.parse(rawMsg);
        } catch (e) {
            console.warn("Invalid chat message", rawMsg, e);
            return;
        }

        let text = "";
        if (payload.sender) {
            if (payload.sender.tag) {
                text += `[${payload.sender.tag}] `;
            }
            text += `${payload.sender.text}: `;
        }
        text += payload.message.text;

        if (typeof addMessage === "function") {
            addMessage(text);
        }
    });
    $rootScope.$on("BJUnload", () => {
        if (typeof Storage !== "undefined") {
            localStorage.setItem("chatMessages", []);
        }
    });
});
