local M = {
    ---@type string[]
    langs = {},

    lang = nil,
}

local function onExtensionLoaded()
    -- Since BeamNG 0.39, core_locales no longer reads a single flat
    -- /locales/<lang>.json file (which is what this used to merge into) - it reads
    -- every *.json file under /locales/translations/<lang>/ and merges them together
    -- (see lua/ge/extensions/core/locales.lua). So instead of merging into a file
    -- core no longer looks at, drop our own file into that per-language folder.
    local bjLocales = FS:findFiles('/beamjoy_locales/', '*.json', 0) or {}
    for _, filePath in ipairs(bjLocales) do
        local loc = filePath:gsub('/beamjoy_locales/', '')
        local langId = loc:gsub('%.json$', '')
        local targetPath = "/locales/translations/" .. langId .. "/beamjoy.json"
        if FS:directoryExists("/locales/translations/" .. langId) then
            jsonWriteFile(targetPath, jsonReadFile(filePath), true)
            FS:mount(targetPath)
            if extensions.core_locales then
                -- force a cache refresh for languages core already loaded (e.g. the
                -- fallback language, loaded eagerly at core_locales' own onExtensionLoaded)
                extensions.core_locales.onFilesChanged({ { filename = targetPath } })
            end
        else
            LogWarn(string.format("BeamJoy locale '%s' has no matching core locale folder (%s), skipping", langId, targetPath))
        end
    end
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
end

local function onSlowUpdate()
    local lang = Lua:getSelectedLanguage()
    if M.lang ~= lang then
        beamjoy_communications.send("changeLang", lang)
        M.lang = lang
    end
end

local function initLang()
    M.lang = Lua:getSelectedLanguage()
end

local function retrieveCache(caches)
    if caches.langs then
        M.langs = caches.langs
    end
end

---@param key string
---@param default string?
---@return string
local function translate(key, default)
    if not extensions.core_locales then
        return default or key
    end
    -- uses the same locale data (including our own beamjoy.json, see onExtensionLoaded
    -- above) as the Angular UI's $translate, so ImGui-side text (e.g. the top menu bar)
    -- stays in sync with the web UI instead of depending on the separate MPTranslate API
    return extensions.core_locales.translate(key, default)
end

M.onExtensionLoaded = onExtensionLoaded
M.onInit = onInit
M.onSlowUpdate = onSlowUpdate

M.initLang = initLang
M.retrieveCache = retrieveCache
M.translate = translate

return M
