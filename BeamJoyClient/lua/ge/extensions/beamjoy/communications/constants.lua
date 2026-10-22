return {
    BASE_EVENT = "BJ_Event",
    DATA_EVENT = "BJ_DataEvent",
    -- the same two, for what the server sends paced (its communications/tx.lua) : the game tells
    -- the server how much of it arrived (ACK_EVENT, the byte count as text)
    PACED_BASE_EVENT = "BJ_EventP",
    PACED_DATA_EVENT = "BJ_DataEventP",
    ACK_EVENT = "BJ_Ack",
    PAYLOAD_SIZE_THRESHOLD = 20000,
}