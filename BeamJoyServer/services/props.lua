--- Placed props, as races and the Hunter, Infected and Derby arenas carry them (`props`) : each
--- client spawns them itself (the client's beamjoy_props), the server only keeps them well-formed
--- when they're saved. Shared by services/races.lua and the arenas' services (direct request :
--- props in every activity with an arena).

local M = {
    --- the most props a race or an arena may hold (a line counts each of its props), mirrors the
    --- client's beamjoy_props.MAX_PROPS
    MAX = 1000,
}
local MAX_PROPS = M.MAX

---@param v any
---@return {x: number, y: number, z: number}?
local function sanePoint(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = tonumber(v.x), tonumber(v.y), tonumber(v.z)
    if not x or not y or not z or x ~= x or y ~= y or z ~= z or
        math.abs(x) > 1e6 or math.abs(y) > 1e6 or math.abs(z) > 1e6 then
        return nil
    end
    return { x = x, y = y, z = z }
end

--- a mesh from the game's own art only (clients skip one that isn't installed), never a path
--- climbing out of it
---@param shape any
---@return boolean
local function saneShape(shape)
    return type(shape) == "string" and #shape <= 200 and not shape:find("..", 1, true) and
        (shape:find("^/art/") or shape:find("^/assets/") or shape:find("^/levels/")) ~= nil and
        (shape:lower():find("%.dae$") or shape:lower():find("%.cdae$")) ~= nil
end

--- a prop's own lift (metres, mesh units) : set by the editor for a mesh it tuned itself (one
--- outside its catalog), so every player stands it at the same height
---@param v any
---@return number?
local function saneStretch(v)
    local p = sanePoint(v)
    if not p then return nil end
    return { x = math.clamp(p.x, .05, 20), y = math.clamp(p.y, .05, 20), z = math.clamp(p.z, .05, 20) }
end

local function saneLift(v)
    local lift = tonumber(v)
    if not lift or lift ~= lift then return nil end
    return math.clamp(lift, -50, 50)
end

-- a prefab prop's own meshes besides its first (see the client's beamjoy/props.lua `parts`)
local MAX_PROP_PARTS = 16
-- metres from the prop's own mesh, at most
local MAX_PART_OFFSET = 100

---@param v any
---@return table[]? a prop's parts, kept as they're well-formed
local function saneParts(v)
    if type(v) ~= "table" then return nil end
    local out = {}
    for _, part in ipairs(v) do
        if #out >= MAX_PROP_PARTS then break end
        local pos = type(part) == "table" and sanePoint(part.pos)
        if pos and saneShape(part.shape) and math.abs(pos.x) <= MAX_PART_OFFSET and
            math.abs(pos.y) <= MAX_PART_OFFSET and math.abs(pos.z) <= MAX_PART_OFFSET then
            out[#out + 1] = { shape = part.shape, pos = pos, dir = sanePoint(part.dir), up = sanePoint(part.up) }
        end
    end
    return #out > 0 and out or nil
end

--- a line's fixed gap between its props (metres), or none (its props spread from end to end)
---@param v any
---@return number?
local function saneGap(v)
    local gap = tonumber(v)
    if not gap or gap ~= gap or gap <= 0 then return nil end
    return math.clamp(gap, .2, 100)
end

--- the editor's group a prop belongs to (props selected and moved together), or none
---@param v any
---@return integer?
local function saneGroup(v)
    local g = tonumber(v)
    if not g or g ~= g or g < 1 or g > 1000000 then return nil end
    return math.floor(g)
end

---@param v any
---@return string? a prefab's id (what the editor names the prop by)
local function sanePrefabId(v)
    return type(v) == "string" and #v <= 40 and v:match("^[%w_]+$") and v or nil
end

--- a prop's collision against its mesh's own : `false` cars drive through it, `true` solid though its
--- mesh has no collision of its own (a ground plane, a backdrop : its visible mesh then), none as its
--- mesh has it. Not `v == false and false or nil`, which is always nil (passable props were saved
--- solid)
---@param v any
---@return boolean?
local function passable(v)
    if v == false or v == true then return v end
    return nil
end

--- an activity's props (a race's, an arena's ; see the client's beamjoy_props for what each entry
--- is) : only the known fields of well-formed entries are kept, malformed ones are dropped
---@param props any
---@param holder string? what holds them, in the limit's error ("A race", "An arena")
---@return table[]? props, string? err
local function sanitize(props, holder)
    if props == nil then return {} end
    if type(props) ~= "table" then return nil, "Invalid prop data" end
    local out, total = {}, 0
    for _, p in ipairs(props) do
        local entry
        if type(p) == "table" and saneShape(p.shape) then
            local scale = math.clamp(tonumber(p.scale) or 1, .1, 10)
            if p.kind == "line" then
                local a, b = sanePoint(p.a), sanePoint(p.b)
                local count = math.floor(tonumber(p.count) or 0)
                if a and b and count >= 1 then
                    entry = {
                        kind = "line",
                        shape = p.shape,
                        a = a,
                        b = b,
                        -- bends the line through it (optional)
                        mid = sanePoint(p.mid),
                        count = count,
                        gap = saneGap(p.gap),
                        group = saneGroup(p.group),
                        yaw = math.clamp(tonumber(p.yaw) or 0, -360, 360),
                        scale = scale,
                        followGround = p.followGround ~= false,
                        lift = saneLift(p.lift),
                        stretch = saneStretch(p.stretch),
                        solid = passable(p.solid),
                    }
                    -- every other prop of the line another mesh (optional), turned and lifted as
                    -- that mesh is laid down
                    if saneShape(p.alt) and p.alt ~= p.shape then
                        entry.alt = p.alt
                        entry.altYaw = tonumber(p.altYaw) and math.clamp(tonumber(p.altYaw), -360, 360) or nil
                        entry.altLift = saneLift(p.altLift)
                    end
                    if entry.followGround and type(p.heights) == "table" and #p.heights == count and
                        table.every(p.heights, function(h) return tonumber(h) ~= nil end) then
                        entry.heights = table.map(p.heights, function(h) return tonumber(h) end)
                    end
                    -- one tilt per prop, the ground's up under it ({x, y}, its z following), kept
                    -- within a 45 degree slope
                    if entry.heights and type(p.normals) == "table" and #p.normals == count and
                        table.every(p.normals, function(n)
                            return type(n) == "table" and tonumber(n.x) ~= nil and tonumber(n.y) ~= nil
                        end) then
                        entry.normals = table.map(p.normals, function(n)
                            return { x = math.clamp(tonumber(n.x), -.7, .7), y = math.clamp(tonumber(n.y), -.7, .7) }
                        end)
                    end
                    -- a mesh at either end (optional), facing out of the line
                    local caps = 0
                    for _, k in ipairs({ "A", "B" }) do
                        local cap = p["cap" .. k]
                        if saneShape(cap) then
                            entry["cap" .. k] = cap
                            local yaw = tonumber(p["cap" .. k .. "Yaw"])
                            entry["cap" .. k .. "Yaw"] = yaw and math.clamp(yaw, -360, 360) or nil
                            entry["cap" .. k .. "Lift"] = saneLift(p["cap" .. k .. "Lift"])
                            caps = caps + 1
                        end
                    end
                    entry.parts = saneParts(p.parts)
                    entry.prefab = entry.parts and sanePrefabId(p.prefab) or nil
                    total = total + count * (1 + (entry.parts and #entry.parts or 0)) + caps
                end
            else
                local pos, dir, up = sanePoint(p.pos), sanePoint(p.dir), sanePoint(p.up)
                if pos and dir then
                    entry = {
                        kind = "static",
                        shape = p.shape,
                        pos = pos,
                        dir = dir,
                        up = up or { x = 0, y = 0, z = 1 },
                        scale = scale,
                        lift = saneLift(p.lift),
                        stretch = saneStretch(p.stretch),
                        solid = passable(p.solid),
                        group = saneGroup(p.group),
                    }
                    entry.parts = saneParts(p.parts)
                    entry.prefab = entry.parts and sanePrefabId(p.prefab) or nil
                    total = total + 1 + (entry.parts and #entry.parts or 0)
                end
            end
        end
        if entry then table.insert(out, entry) end
    end
    if total > MAX_PROPS then
        return nil, string.format("%s can hold up to %d props", holder or "This", MAX_PROPS)
    end
    return out
end

--- a copy of an arena without its props : a game's own snapshot of its arena (hunterGrid,
--- infectedGrid, derbyGrid) never needs them, the clients spawning them from their own copy of the
--- arena, and a derby game's goes to every client with each of its updates
---@param arena table
---@return table
local function withoutProps(arena)
    local copy = table.clone(arena)
    copy.props = nil
    return copy
end

M.sanePoint = sanePoint
M.sanitize = sanitize
M.withoutProps = withoutProps

return M
