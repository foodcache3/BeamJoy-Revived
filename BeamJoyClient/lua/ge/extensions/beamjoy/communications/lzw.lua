--- LZW, for the big messages a client sends (direct report : "zlib uncompress() failed, trying
--- with a larger buffer size" all over the server log on a map race import). BeamMP compresses
--- every packet and its server unpacks one into a buffer 5 times its compressed size, retrying with
--- 30 MB when that's short (BeamMP-Server src/Common.cpp DeComp) : a race's props, the same mesh
--- paths and field names hundreds of times over, pack 6 to 8 times. Packed here first, a message
--- is about 4 times smaller and what's left barely packs again (1.5 times), well within that.
---
--- The same file on both sides (Client/BJ/lua/ge/extensions/beamjoy/communications/lzw.lua and
--- Server/BeamJoyServer/communications/lzw.lua). Codes up to 65536 : the table starts over once full,
--- so a long message keeps adapting to what it holds further on. Each code written as 3 characters of a URL-safe base 64 (no quote, backslash or slash : a
--- JSON string carries them as they are). Plain arithmetic, no bit library : LuaJIT and Lua 5.3.

local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local MAX_CODES = 65536

local DIGIT, VALUE = {}, {}
for i = 1, #ALPHABET do
    DIGIT[i - 1] = ALPHABET:sub(i, i)
    VALUE[ALPHABET:byte(i)] = i - 1
end

---@return table<string, integer>
local function freshEncodeDict()
    local dict = {}
    for i = 0, 255 do dict[string.char(i)] = i end
    return dict
end

---@return table<integer, string>
local function freshDecodeDict()
    local dict = {}
    for i = 0, 255 do dict[i] = string.char(i) end
    return dict
end

---@param s string any bytes
---@return string
function M.encode(s)
    local dict = freshEncodeDict()
    local nextCode = 256
    local out, n = {}, 0
    local function emit(code)
        n = n + 1
        out[n] = DIGIT[math.floor(code / 4096)] .. DIGIT[math.floor(code / 64) % 64] .. DIGIT[code % 64]
    end
    local w = ""
    for i = 1, #s do
        local c = s:sub(i, i)
        local wc = w .. c
        if dict[wc] then
            w = wc
        else
            emit(dict[w])
            dict[wc] = nextCode
            nextCode = nextCode + 1
            if nextCode == MAX_CODES then
                -- full : over again (the decoder does the same at the same code)
                dict, nextCode = freshEncodeDict(), 256
            end
            w = c
        end
    end
    if w ~= "" then emit(dict[w]) end
    return table.concat(out)
end

---@param t string M.encode's output
---@param maxBytes integer? errors past this many bytes decoded (a hostile message can't grow
---without end)
---@return string
function M.decode(t, maxBytes)
    if #t % 3 ~= 0 then error("lzw: bad length") end
    local dict = freshDecodeDict()
    local nextCode = 256
    local out, n, size = {}, 0, 0
    local prev
    for i = 1, #t, 3 do
        local a, b, c = VALUE[t:byte(i)], VALUE[t:byte(i + 1)], VALUE[t:byte(i + 2)]
        if not a or not b or not c then error("lzw: bad character") end
        local code = a * 4096 + b * 64 + c
        if prev and nextCode == MAX_CODES - 1 then
            -- the encoder's table filled with its last phrase and started over : so does this one,
            -- that phrase never used
            dict, nextCode, prev = freshDecodeDict(), 256, nil
        end
        local entry = dict[code]
        if not entry then
            -- the code being defined by this very step (a phrase followed by its own first char)
            if code ~= nextCode or not prev then error("lzw: bad code") end
            entry = prev .. prev:sub(1, 1)
        end
        size = size + #entry
        if maxBytes and size > maxBytes then error("lzw: too large") end
        n = n + 1
        out[n] = entry
        if prev then
            dict[nextCode] = prev .. entry:sub(1, 1)
            nextCode = nextCode + 1
        end
        prev = entry
    end
    return table.concat(out)
end

return M
