local M = {
    ---@type string[]
    langs = {},

    lang = nil,
}

-- COMMUNITY TRANSLATIONS (the Translations mod) ------------------------------------------------
-- A language the game has no translation of its own for (Italian, and a second "community" entry
-- beside several official ones) comes from that mod, in a folder of its own ("it", "eses_com",
-- "ruru_com") holding one legacy <id>.json. core_locales reads that legacy file ONLY while the
-- folder holds no *.translation.json at all (loadLocaleFiles), so BeamJoy's own file alone would
-- take the whole language down with it. The mod's file is copied beside ours as a translation file
-- of its own instead, so core loads both rather than neither.
--
-- Only ever for the language actually selected, and the copy is made again at every load and every
-- language change, straight from the mod's own file, which is never written over : an update of
-- theirs is a restart away, never masked for good. Our two files are taken back out of a folder
-- the moment it stops being the language in use, so at most one is ever touched. Nothing is copied
-- into a folder that already holds a real translation file : the mod shipping 0.40-style files is
-- the case where core reads it by itself and a copy of ours could only hold it back.
local LOCALES_DIR = "/locales/translations/"
local COMMUNITY_OWN = "beamjoy.translation.json"
local COMMUNITY_COPY = "beamjoy_community_copy.translation.json"

--- a locale folder's letters alone, to compare ids across the two namings : "eses_com" and
--- "es_ES" are both "eses", "ru_community" is "ru", "zh_Hans" is "zhhans"
---@param id string
---@return string
local function localeKey(id)
    return (id:lower():gsub("_community$", ""):gsub("_com$", ""):gsub("[^%a]", ""))
end

---@return string[] the languages BeamJoy ships, by their file's id
local function bjLocaleIds()
    local ids = {}
    for _, filePath in ipairs(FS:findFiles('/beamjoy_locales/', '*.json', 0) or {}) do
        ids[#ids + 1] = filePath:gsub('/beamjoy_locales/', ''):gsub('%.json$', '')
    end
    return ids
end

--- the BeamJoy language a community folder's id stands for, nil where there's none. A language on
--- its own ("it", "pl") takes the one whose region repeats it (it_IT, pl_PL) and nothing else, so
--- "pt" never silently picks between pt_BR and pt_PT by load order
---@param folderId string
---@param ids string[] bjLocaleIds()
---@return string?
local function bjLocaleFor(folderId, ids)
    local key = localeKey(folderId)
    if #key < 2 then return nil end
    for _, id in ipairs(ids) do
        if localeKey(id) == key then return id end
    end
    if #key == 2 then
        for _, id in ipairs(ids) do
            if localeKey(id) == key .. key then return id end
        end
    end
    return nil
end

---@param path string
local function removeIfPresent(path)
    if FS:fileExists(path) then pcall(function() FS:removeFile(path) end) end
end

---@param name string
---@return boolean core_locales would read a file of this name (isTranslationFile)
local function isTranslationFile(name)
    name = name:lower()
    return name:find("%.translation%.json$") ~= nil or name:find("%.translations%.json$") ~= nil
end

--- the folder holds a translation file that isn't one of ours : core reads it, the legacy file is
--- out of the picture, and nothing of theirs needs copying
---@param dir string
---@return boolean
local function hasOwnTranslationFile(dir)
    for _, filePath in ipairs(FS:findFiles(dir, "*.json", 0) or {}) do
        local name = tostring(filePath):gsub("\\", "/"):match("([^/]+)$") or ""
        if name ~= COMMUNITY_OWN and name ~= COMMUNITY_COPY and isTranslationFile(name) then
            return true
        end
    end
    return false
end

--- our files out of every community folder but `keep`'s. A folder we copied into is one holding
--- COMMUNITY_COPY : the game's own language folders never do, so theirs are left alone
---@param keep string? the folder id to leave as it is
local function clearOtherCommunityFolders(keep)
    local changed = {}
    for _, folderPath in ipairs(FS:directoryList(LOCALES_DIR, false, true) or {}) do
        local id = tostring(folderPath):gsub("\\", "/"):match("([^/]+)/?$")
        if id and id ~= keep then
            local copyPath = LOCALES_DIR .. id .. "/" .. COMMUNITY_COPY
            if FS:fileExists(copyPath) then
                local ownPath = LOCALES_DIR .. id .. "/" .. COMMUNITY_OWN
                removeIfPresent(copyPath)
                removeIfPresent(ownPath)
                changed[#changed + 1] = { filename = copyPath }
                changed[#changed + 1] = { filename = ownPath }
            end
        end
    end
    if extensions.core_locales and #changed > 0 then
        extensions.core_locales.onFilesChanged(changed)
    end
end

--- BeamJoy's strings into the community translation the game is set to, the block above. Called at
--- load and at every language change
local function syncCommunityLocale()
    local lang = Lua:getSelectedLanguage()
    if type(lang) ~= "string" or lang == "" then return end
    local ids = bjLocaleIds()
    for _, id in ipairs(ids) do
        -- a language BeamJoy ships under this very id : its folder is the game's own, written at load
        if id == lang then return clearOtherCommunityFolders(nil) end
    end
    local dir = LOCALES_DIR .. lang
    local bjId = bjLocaleFor(lang, ids)
    if not bjId or not FS:directoryExists(dir) then return clearOtherCommunityFolders(nil) end
    clearOtherCommunityFolders(lang)

    local ownPath, copyPath = dir .. "/" .. COMMUNITY_OWN, dir .. "/" .. COMMUNITY_COPY
    local changed = {}
    if hasOwnTranslationFile(dir) then
        removeIfPresent(copyPath)
        changed[#changed + 1] = { filename = copyPath }
    else
        local legacyPath = dir .. "/" .. lang .. ".json"
        local legacy = FS:fileExists(legacyPath) and jsonReadFile(legacyPath) or nil
        if type(legacy) ~= "table" then
            -- nothing of theirs to stand in for : ours alone would leave the language with only
            -- BeamJoy's own strings translated, so it keeps out altogether
            removeIfPresent(ownPath)
            removeIfPresent(copyPath)
            LogDebug(string.format("BeamJoy : community locale '%s' has no %s.json to keep, left alone", lang, lang))
            return
        end
        jsonWriteFile(copyPath, legacy, true)
        changed[#changed + 1] = { filename = copyPath }
    end

    local mine = jsonReadFile("/beamjoy_locales/" .. bjId .. ".json")
    if type(mine) == "table" then
        jsonWriteFile(ownPath, mine, true)
        changed[#changed + 1] = { filename = ownPath }
        LogDebug(string.format("BeamJoy locale '%s' added to the community translation '%s'", bjId, lang))
    end
    if extensions.core_locales and #changed > 0 then
        extensions.core_locales.onFilesChanged(changed)
    end
end

local function onExtensionLoaded()
    -- Since BeamNG 0.39, core_locales no longer reads a single flat /locales/<lang>.json file
    -- (which is what this used to merge into) : it reads the files under
    -- /locales/translations/<lang>/ and merges them. Since 0.40 it reads only the ones NAMED
    -- *.translation.json or *.translations.json (lua/ge/extensions/core/locales.lua,
    -- isTranslationFile), so the beamjoy.json this wrote until then was simply never loaded and
    -- every language quietly fell back to English (direct report : Italian and Spanish both
    -- changing nothing). Any beamjoy.json an older build left behind is removed on the way past.
    --
    -- A language the game has only as a community translation (the Translations mod, its own
    -- folder ids : "it", "eses_com", holding one legacy <id>.json) can't be written to this way :
    -- loadLocaleFiles falls back to that legacy file ONLY while the folder holds no
    -- *.translation.json at all, so dropping ours in would take the whole language down with it.
    -- syncCommunityLocale above handles those, for the language in use.
    local bjLocales = FS:findFiles('/beamjoy_locales/', '*.json', 0) or {}
    for _, filePath in ipairs(bjLocales) do
        local loc = filePath:gsub('/beamjoy_locales/', '')
        local langId = loc:gsub('%.json$', '')
        local langDir = "/locales/translations/" .. langId
        local targetPath = langDir .. "/beamjoy.translation.json"
        if FS:directoryExists(langDir) then
            local legacyPath = langDir .. "/beamjoy.json"
            if FS:fileExists(legacyPath) then
                pcall(function() FS:removeFile(legacyPath) end)
            end
            jsonWriteFile(targetPath, jsonReadFile(filePath), true)
            if extensions.core_locales then
                -- force a cache refresh for languages core already loaded (e.g. the
                -- fallback language, loaded eagerly at core_locales' own onExtensionLoaded)
                extensions.core_locales.onFilesChanged({ { filename = targetPath } })
            end
        else
            -- expected : BeamJoy ships languages the game doesn't (Italian, which the game has as
            -- a community translation under its own folder id, never as it_IT)
            LogDebug(string.format("BeamJoy locale '%s' has no matching core locale folder (%s), skipping", langId, targetPath))
        end
    end
    syncCommunityLocale()
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
end

local function onSlowUpdate()
    local lang = Lua:getSelectedLanguage()
    if M.lang ~= lang then
        beamjoy_communications.send("changeLang", lang)
        M.lang = lang
        syncCommunityLocale()
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
    -- uses the same locale data (including our own beamjoy.translation.json, see
    -- onExtensionLoaded above) as the Angular UI's $translate, so ImGui-side text (e.g. the top menu bar)
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
