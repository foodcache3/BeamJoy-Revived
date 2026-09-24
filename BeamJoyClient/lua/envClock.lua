--- The synced day/night clock's math, shared VERBATIM by the client (Client/BJ/lua/envClock.lua,
--- `require("lua/envClock")`) and the server (Server/BeamJoyServer/utils/envClock.lua,
--- `require("utils/envClock")`). Both copies MUST stay byte-identical: the server and every client
--- compute the same clock independently from one shared epoch, so any difference between them is
--- a desync. Plain Lua only (runs on both LuaJIT and BeamMP's Lua 5.4), no engine calls.
---
--- Time of day uses the engine's own convention: a 0-1 day fraction with NOON at 0 (so 0.25 =
--- 18:00, 0.5 = midnight, 0.75 = 06:00). Internally the day/night split is worked out in "u", the
--- fraction of the day since local midnight (u = (time - 0.5) % 1), where a day is one contiguous
--- [0, 1) span.
---
--- The night window comes from the same astronomy the game itself uses to split day from night (a
--- line-for-line port of core_solarTimeOfDay's getSolarNightWindow: sunrise/sunset from the level's
--- latitude/longitude/UTC offset/DST rule and the date, rounded to whole minutes), so BJS's night
--- speed kicks in at the real sunset, matching the vanilla environment panel's own day/night split.
local C = {}

-- The vanilla environment panel's own day length bounds (ui-vue TodControl:
-- MIN_PHASE_LENGTH_SECONDS = 5 * 60, MAX_PHASE_LENGTH_SECONDS = 24h). The engine's TimeOfDay is
-- handed `dayLength / scale` for whichever phase is current, and that value is never allowed
-- outside these, whatever the day length / speed combination.
C.MIN_DAY_LENGTH = 300
C.MAX_DAY_LENGTH = 86400
-- requested day/night speed multiplier range (the config slider's own range)
C.MIN_SCALE = 0.1
C.MAX_SCALE = 10

-- fallback split when the level has no solar data: BJS's historical fixed 06:00-18:00 day
local FALLBACK_SUNRISE_U, FALLBACK_SUNSET_U = 0.25, 0.75

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

---@param dayLength number?
---@return number seconds, within the game's own bounds
function C.clampDayLength(dayLength)
    return clamp(tonumber(dayLength) or 1800, C.MIN_DAY_LENGTH, C.MAX_DAY_LENGTH)
end

---@param scale number? requested multiplier
---@param dayLength number?
---@return number the multiplier actually used: the requested one (0.1-10), further limited so the
---engine's per-phase dayLength (dayLength / scale) stays within MIN/MAX_DAY_LENGTH
function C.effectiveScale(scale, dayLength)
    dayLength = C.clampDayLength(dayLength)
    scale = clamp(tonumber(scale) or 1, C.MIN_SCALE, C.MAX_SCALE)
    return clamp(scale, dayLength / C.MAX_DAY_LENGTH, dayLength / C.MIN_DAY_LENGTH)
end

---@param dayLength number?
---@return number min, number max the multiplier range actually reachable at this day length,
---rounded inward to the slider's 0.1 step
function C.scaleBounds(dayLength)
    dayLength = C.clampDayLength(dayLength)
    local lo = math.max(C.MIN_SCALE, math.ceil(dayLength / C.MAX_DAY_LENGTH * 10 - 1e-9) / 10)
    local hi = math.min(C.MAX_SCALE, math.floor(dayLength / C.MIN_DAY_LENGTH * 10 + 1e-9) / 10)
    return lo, hi
end

---@param scale number? requested multiplier of the current phase
---@param dayLength number?
---@return number the dayLength to hand the engine for that phase, so its own free-running advance
---moves at exactly that phase's synced rate
function C.nativeDayLength(scale, dayLength)
    dayLength = C.clampDayLength(dayLength)
    return clamp(dayLength / C.effectiveScale(scale, dayLength), C.MIN_DAY_LENGTH, C.MAX_DAY_LENGTH)
end

------------------------------------------------------------------------------------------------
-- Solar window: port of core_solarTimeOfDay (lua/ge/extensions/core/solarTimeOfDay.lua)
------------------------------------------------------------------------------------------------

local RAD = math.pi / 180
local MINUTES_PER_DAY = 1440

local function isFinite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function toFiniteNumber(value)
    local number = tonumber(value)
    return isFinite(number) and number or nil
end

local function mod(a, m)
    return ((a % m) + m) % m
end

local function normalizeMinutes(minutes)
    return mod(math.floor(minutes + 0.5), MINUTES_PER_DAY)
end

local function julianDay(year, month, day)
    local a = math.floor((14 - month) / 12)
    local y = year + 4800 - a
    local m = month + 12 * a - 3
    local jdn = day + math.floor((153 * m + 2) / 5) + 365 * y + math.floor(y / 4) - math.floor(y / 100) +
        math.floor(y / 400) - 32045
    return jdn - 0.5
end

local function solarDeclEqTime(year, month, day)
    local T = (julianDay(year, month, day) - 2451545.0) / 36525
    local L0 = 280.46646 + T * (36000.76983 + T * 0.0003032)
    local M = 357.52911 + T * (35999.05029 - T * 0.0001537)
    local ecc = 0.016708634 - T * (0.000042037 + T * 0.0000001267)
    local Mr = M * RAD
    local Cc = math.sin(Mr) * (1.914602 - T * (0.004817 + T * 0.000014)) +
        math.sin(2 * Mr) * (0.019993 - T * 0.000101) +
        math.sin(3 * Mr) * 0.000289
    local omega = (125.04 - 1934.136 * T) * RAD
    local lambda = (L0 + Cc - 0.00569 - 0.00478 * math.sin(omega)) * RAD
    local eps = (23 + (26 + (21.448 - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60) / 60 +
        0.00256 * math.cos(omega)) * RAD
    local decl = math.asin(math.sin(eps) * math.sin(lambda)) / RAD
    local y = math.tan(eps / 2) ^ 2
    local L0r = L0 * RAD
    local eqTime = 4 / RAD * (y * math.sin(2 * L0r) - 2 * ecc * math.sin(Mr) +
        4 * ecc * y * math.sin(Mr) * math.cos(2 * L0r) -
        0.5 * y * y * math.sin(4 * L0r) - 1.25 * ecc * ecc * math.sin(2 * Mr))
    return decl, eqTime
end

-- returns sunriseUtcMinutes, sunsetUtcMinutes, polar ("day"/"night") ; sunrise/sunset nil if polar
local function sunTimesUtcMinutes(year, month, day, lat, lon)
    local decl, eqTime = solarDeclEqTime(year, month, day)
    local latR = lat * RAD
    local declR = decl * RAD
    local cosH = math.cos(90.833 * RAD) / (math.cos(latR) * math.cos(declR)) - math.tan(latR) * math.tan(declR)
    local noon = 720 - 4 * lon - eqTime

    if cosH < -1 then return nil, nil, "day" end
    if cosH > 1 then return nil, nil, "night" end

    local ha = math.acos(cosH) / RAD
    return noon - 4 * ha, noon + 4 * ha, nil
end

local DOW_T = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
local function dow(year, month, day)
    local y = year
    if month < 3 then y = y - 1 end
    return mod(y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + DOW_T[month] + day, 7)
end

local function lastSunday(year, month)
    local last = (month == 4 or month == 9 or month == 11) and 30 or 31
    return last - dow(year, month, last)
end

local function firstSunday(year, month)
    return 1 + mod(7 - dow(year, month, 1), 7)
end

local function dstActive(rule, year, month, day)
    if rule == "eu" then
        if month < 3 or month > 10 then return false end
        if month > 3 and month < 10 then return true end
        return (month == 3 and day >= lastSunday(year, 3)) or (month == 10 and day < lastSunday(year, 10))
    end
    if rule == "us" then
        if month < 3 or month > 11 then return false end
        if month > 3 and month < 11 then return true end
        return (month == 3 and day >= firstSunday(year, 3) + 7) or (month == 11 and day < firstSunday(year, 11))
    end
    if rule == "au" then
        if month > 4 and month < 10 then return false end
        if month < 4 or month > 10 then return true end
        return (month == 4 and day < firstSunday(year, 4)) or (month == 10 and day >= firstSunday(year, 10))
    end
    return false
end

local function civilOffsetHours(observer, lat, lon, year, month, day)
    local explicitOffset = toFiniteNumber(observer.utcOffset)
    if explicitOffset then return explicitOffset end

    local rule = observer.dstRule or "auto"
    if rule == "auto" then
        if lat <= -30 then
            rule = "au"
        elseif lat >= 30 then
            rule = lon > -170 and lon < -30 and "us" or "eu"
        else
            rule = "none"
        end
    end

    return math.floor(lon / 15 + 0.5) + (dstActive(rule, year, month, day) and 1 or 0)
end

---@param observer table|false|nil { latitude, longitude, utcOffset?, dstRule? } (the level's own
---TimeOfDay fields, synced per map)
---@param year integer?
---@param month integer?
---@param day integer?
---@return number? sunriseU, number? sunsetU (fractions of the day since local midnight, whole
---minutes like the engine's own), string? polar ("day"/"night") ; all nil if there's no solar data
function C.solarWindow(observer, year, month, day)
    if type(observer) ~= "table" then return nil end
    local lat = toFiniteNumber(observer.latitude)
    local lon = toFiniteNumber(observer.longitude)
    year, month, day = toFiniteNumber(year), toFiniteNumber(month), toFiniteNumber(day)
    if not lat or not lon or not year or not month or not day then return nil end
    if month < 1 or month > 12 then return nil end
    local offset = civilOffsetHours(observer, lat, lon, year, month, day)

    local sunrise, sunset, polar = sunTimesUtcMinutes(year, month, day, lat, lon)
    if polar then return nil, nil, polar end
    return normalizeMinutes(sunrise + offset * 60) / MINUTES_PER_DAY,
        normalizeMinutes(sunset + offset * 60) / MINUTES_PER_DAY, nil
end

------------------------------------------------------------------------------------------------
-- Day/night segments and the clock itself
------------------------------------------------------------------------------------------------

-- single-entry cache: the observer (per map) and the date change rarely, and recomputing the
-- window is the only part of this module that does real work (trig). Keyed on the observer
-- table's identity plus the date, so a fresh observer table (a new cache arrival) recomputes once.
local cachedObserver, cachedDateKey, cachedSegments = nil, nil, nil

--- The day, midnight to midnight, as up to 3 contiguous [startU, endU) spans, each flagged day or
--- night: { { startU, endU, isNight }, ... } covering exactly [0, 1).
local function segments(observer, year, month, day)
    local dateKey = (year and month and day) and (year * 10000 + month * 100 + day) or -1
    if cachedSegments and cachedObserver == observer and cachedDateKey == dateKey then
        return cachedSegments
    end

    local rise, set, polar = C.solarWindow(observer, year, month, day)
    local segs
    if polar == "day" then
        segs = { { 0, 1, false } }
    elseif polar == "night" then
        segs = { { 0, 1, true } }
    else
        if not rise or not set or rise == set then
            rise, set = FALLBACK_SUNRISE_U, FALLBACK_SUNSET_U
        end
        local function nightAt(u)
            if rise < set then return u < rise or u >= set end
            return u >= set and u < rise -- odd time zone putting sunset before sunrise past midnight
        end
        local points = { 0, math.min(rise, set), math.max(rise, set), 1 }
        segs = {}
        for i = 1, 3 do
            local s, e = points[i], points[i + 1]
            if e > s then segs[#segs + 1] = { s, e, nightAt((s + e) / 2) } end
        end
    end

    cachedObserver, cachedDateKey, cachedSegments = observer, dateKey, segs
    return segs
end

local function segmentAt(segs, u)
    for i = 1, #segs do
        if u < segs[i][2] then return segs[i] end
    end
    return segs[#segs]
end

local function toU(time)
    local u = ((tonumber(time) or 0) - 0.5) % 1
    if u >= 1 then u = 0 end -- float residue from % on a tiny negative
    return u
end

---@param observer table|false|nil
---@param year integer?
---@param month integer?
---@param day integer?
---@param time number engine time of day (noon = 0)
---@return boolean whether `time` falls in that date's night
function C.isNight(observer, year, month, day, time)
    return segmentAt(segments(observer, year, month, day), toU(time))[3]
end

---@return number fraction of that date's full cycle (in time-of-day, not real time) that is day
function C.dayFraction(observer, year, month, day)
    local total = 0
    for _, seg in ipairs(segments(observer, year, month, day)) do
        if not seg[3] then total = total + (seg[2] - seg[1]) end
    end
    return total
end

---@param t0 number engine time of day at the start of the elapsed window (noon = 0)
---@param dtSec number real seconds elapsed since t0 (negative treated as 0)
---@param p { dayLength: number, dayScale: number, nightScale: number, simSpeed: number, observer: table|false|nil, year: integer?, month: integer?, day: integer? }
---@return number time of day now
--- Walks the day/night segments at each one's own rate (effectiveScale * simSpeed / dayLength,
--- the exact rate the engine free-runs at once handed nativeDayLength for that phase). The date
--- does not roll over at midnight (yet), so every cycle is identical and whole cycles are skipped
--- with a modulo up front: the walk itself never crosses more than a handful of segments, however
--- long the elapsed window. No allocations on the hot path (segments are cached), since clients
--- call this every frame.
function C.advance(t0, dtSec, p)
    dtSec = tonumber(dtSec) or 0
    local simSpeed = tonumber(p.simSpeed) or 1
    if dtSec <= 0 or simSpeed <= 0 then return (tonumber(t0) or 0) % 1 end

    local dayLength = C.clampDayLength(p.dayLength)
    local dayRate = C.effectiveScale(p.dayScale, dayLength) * simSpeed / dayLength
    local nightRate = C.effectiveScale(p.nightScale, dayLength) * simSpeed / dayLength
    local segs = segments(p.observer, p.year, p.month, p.day)

    local cycleSec = 0
    for i = 1, #segs do
        local seg = segs[i]
        cycleSec = cycleSec + (seg[2] - seg[1]) / (seg[3] and nightRate or dayRate)
    end
    local remaining = dtSec % cycleSec

    local u = toU(t0)
    for _ = 1, 2 * #segs + 2 do
        local seg = segmentAt(segs, u)
        local rate = seg[3] and nightRate or dayRate
        local toEnd = (seg[2] - u) / rate
        if toEnd > remaining then
            u = u + remaining * rate
            break
        end
        remaining = remaining - toEnd
        u = seg[2]
        if u >= 1 then u = 0 end
    end
    return (u + 0.5) % 1
end

return C
