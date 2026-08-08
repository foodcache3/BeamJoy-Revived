const createSpanNode = (text, color, bold) => {
    const node = document.createElement("span");
    node.appendChild(document.createTextNode(text));
    if (color)
        node.style.color = `rgb(${Math.round(color[0] * 255)}, ${Math.round(
            color[1] * 255
        )}, ${Math.round(color[2] * 255)})`;
    if (bold) node.classList.add("bold");
    return node;
};

const generateTimeStr = () => {
    const now = new Date();
    let hour = now.getHours();
    let minute = now.getMinutes();
    let second = now.getSeconds();
    if (hour < 10) hour = "0" + hour;
    if (minute < 10) minute = "0" + minute;
    if (second < 10) second = "0" + second;
    return hour + ":" + minute + ":" + second;
};

const addMessageOverride = (rawMsg, time = generateTimeStr()) => {
    let payload;
    try {
        payload = JSON.parse(rawMsg);
    } catch (e) {
        // invalid json, do not print
        console.warn("Invalid chat message", rawMsg, e);
        return;
    }

    // Create the message node
    const chatMessageNode = document.createElement("li");
    chatMessageNode.className = "chat-message";
    fadeNode(chatMessageNode);

    // create node for the timestamp
    const messageTimestampNode = createSpanNode(time);
    messageTimestampNode.className = "chat-message-timestamp";
    chatMessageNode.appendChild(messageTimestampNode);

    if (payload.sender) {
        if (payload.sender.tag) {
            chatMessageNode.appendChild(createSpanNode("[", null, true));
            chatMessageNode.appendChild(
                createSpanNode(
                    payload.sender.tag,
                    payload.sender.tagColor,
                    true
                )
            );
            chatMessageNode.appendChild(createSpanNode("]", null, true));
        }
        chatMessageNode.appendChild(
            createSpanNode(
                payload.sender.text + ": ",
                payload.sender.color,
                true
            )
        );
    }
    chatMessageNode.appendChild(
        createSpanNode(payload.message.text, payload.message.color)
    );

    // create text for the message itself, add it to chat message list
    const chatList = document.getElementById("chat-list");
    chatList.appendChild(chatMessageNode);
    // Delete oldest chat message if more than 70 messages exist
    if (chatList.children.length > 70) {
        chatList.removeChild(chatList.children[0]);
    }
    scrollToLastMessage();
};

angular.module("beamjoy").service("bjChat", function ($rootScope) {
    // addMessage and related chat functions were removed in BeamNG 0.39.
    // The BJChat event still works via the Vue chat system directly.
    $rootScope.$on("BJChat", (_, message) => {
        // Messages are handled by the BeamJoy Vue frontend via the BJChat event.
    });
    $rootScope.$on("BJUnload", () => {
        if (typeof Storage !== "undefined") {
            localStorage.setItem("chatMessages", []);
        }
    });
});
