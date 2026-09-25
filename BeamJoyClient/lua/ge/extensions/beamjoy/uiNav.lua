--- Controller navigation for BJS's own controller-driven windows (Phase 3's job board and delivery
--- results ; the older BJS windows stay mouse-driven until their redesign).
---
--- The game's menu inputs (d-pad, A, B, X, Y on a pad) are "MenuIndependent" actions : each has its
--- own action map (`MenuIndependent_<action>ActionMap`) that, while enabled, takes that button away
--- from driving and fires `guihooks.trigger('UINavigation', <name>, value)` into the UI instead
--- (core/input/actions/menu.json). The Vue UI enables them per action while one of its menus needs
--- them (ui-vue services/uiNavTracker.js) ; a BJS window does the same while it's open, through
--- `acquire(owner)` / `release(owner)`, and its Angular side listens for `UINavigation`.
---
--- The Vue tracker turns off action maps it isn't tracking whenever its own menu state resyncs
--- (e.g. opening and closing the pause menu), so while anything is acquired this re-asserts the
--- maps on a short timer. Release only turns off the maps this module itself turned on.

local M = {
    -- pad : up/down/left/right = d-pad (and left stick), select = A, back = B, cui_action_2 = X,
    -- cui_context = Y (settings/inputmaps/xidevice.json)
    ACTIONS = {
        "menu_item_up", "menu_item_down", "menu_item_left", "menu_item_right",
        "menu_item_select", "menu_item_back", "cui_action_2", "cui_context",
    },
    REASSERT_MS = 300,

    ---@type table<string, true>
    owners = {},
    --- actions this module enabled (and so may disable again on release)
    ---@type table<string, true>
    enabledByUs = {},
    lastReassert = 0,
}

---@param action string
---@return table? action map
local function actionMap(action)
    local prefix = extensions.core_input_actions and extensions.core_input_actions.menuIndependentPrefix
        or "MenuIndependent_"
    return scenetree[prefix .. action .. "ActionMap"]
end

---@param action string
---@param enabled boolean
local function setAction(action, enabled)
    local bindings = extensions.core_input_bindings
    if not bindings or not bindings.setMenuActionEnabled then return end
    pcall(bindings.setMenuActionEnabled, enabled, action)
end

local function assertAll()
    for _, action in ipairs(M.ACTIONS) do
        local am = actionMap(action)
        if am and not am.enabled then
            setAction(action, true)
            M.enabledByUs[action] = true
        end
    end
end

---@param owner string
local function acquire(owner)
    M.owners[owner] = true
    assertAll()
end

---@param owner string
local function release(owner)
    if not M.owners[owner] then return end
    M.owners[owner] = nil
    if next(M.owners) then return end
    for action in pairs(M.enabledByUs) do setAction(action, false) end
    M.enabledByUs = {}
end

local function onUpdate()
    if not next(M.owners) then return end
    local now = GetCurrentTimeMillis()
    if now - M.lastReassert < M.REASSERT_MS then return end
    M.lastReassert = now
    assertAll()
end

local function onServerLeave()
    for owner in pairs(M.owners) do release(owner) end
end

M.acquire = acquire
M.release = release
M.onUpdate = onUpdate
M.onServerLeave = onServerLeave
M.onExtensionUnloaded = onServerLeave

return M
