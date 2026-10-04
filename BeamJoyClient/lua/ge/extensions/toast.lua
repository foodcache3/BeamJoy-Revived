local M = {
    TYPES = {
        SUCCESS = "success",
        INFO = "info",
        WARN = "warn",
        ERROR = "error",
    },
    DEFAULT_TITLES = {
        success = "Success",
        info = "Info",
        warn = "Warning",
        error = "Error",
    }
}

--- Hardening : the game's toasts and messages run their text through Angular's template
--- interpolation (an unknown text goes through $translate.instant), so a "{{" coming from a player's
--- name or a crew name would be evaluated as an expression. A zero-width space between the two
--- braces keeps it plain text
---@param s any
---@return any
local function noTemplate(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("{{", "{\226\128\139{"))
end

---@param typeToast string
---@param msg string
---@param title string?
---@param fadeSecs number? 0-N
M.show = function(typeToast, msg, title, fadeSecs)
    local finalType = table.includes(M.TYPES, typeToast) and typeToast or M.TYPES.INFO
    local finalTime = fadeSecs
    if not finalTime then
        if finalType ~= M.TYPES.ERROR then
            finalTime = 5000
        else
            finalTime = -1
        end
    else
        finalTime = finalTime * 1000
    end
    guihooks.trigger("toastrMsg", {
        type = finalType,
        title = noTemplate(title or M.DEFAULT_TITLES[finalType]),
        msg = noTemplate(msg),
        config = { timeOut = finalTime },
    })
end

---@param msg string
---@param title string?
---@param fadeSecs number? 0-N
M.success = function(msg, title, fadeSecs)
    M.show(M.TYPES.SUCCESS, msg, title, fadeSecs)
end

---@param msg string
---@param title string?
---@param fadeSecs number? 0-N
M.info = function(msg, title, fadeSecs)
    M.show(M.TYPES.INFO, msg, title, fadeSecs)
end

---@param msg string
---@param title string?
---@param fadeSecs number? 0-N
M.warn = function(msg, title, fadeSecs)
    M.show(M.TYPES.WARN, msg, title, fadeSecs)
end

---@param msg string
---@param title string?
---@param fadeSecs number? 0-N
M.error = function(msg, title, fadeSecs)
    M.show(M.TYPES.ERROR, msg, title, fadeSecs)
end

return M
