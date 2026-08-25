local M = {
    state = false,
    ---@type "translate"|"rotate"|"scale"
    tool = "translate",
    ---@type fun(updated: GizmoObject)?
    onChange = nil,
    ---@type fun(updated: GizmoObject)? fired once when a drag actually ends, not every frame
    ---during it. The native gizmo API already supports this (editor.updateAxisGizmo's begin/end
    ---callbacks), it just wasn't wired to anything before (both passed as `nop`)
    onDragEnd = nil,
    obj = {},
}

-- which transform column (and sign) corresponds to dir/up for the rotate tool, discovered
-- empirically in show() below rather than assumed from native API conventions this codebase
-- doesn't actually have documentation for (two prior attempts each guessed wrong)
local dirColumn, dirSign
local upColumn, upSign

local function onInit()
    beamjoy_communications_ui.addHandler("BJEditorChangeTool", M.setTool)
    if not editor.AxisGizmoMode_Translate then
        require("editor/api/gui").initialize(editor)
        require("editor/api/gizmo").initialize(editor)
    end
    M.setTool()
end

--- reads dir/up from the transform's own basis-vector columns, using the mapping empirically
--- discovered in show() below.
local function readRotation()
    local gizmoTransform = editor.getAxisGizmoTransform()
    if dirColumn then
        M.obj.dir = gizmoTransform:getColumn(dirColumn) * dirSign
    end
    if upColumn then
        M.obj.up = gizmoTransform:getColumn(upColumn) * upSign
    end
end

local function onDrag()
    if M.tool == "translate" then
        M.obj.pos = editor.getAxisGizmoTransform():getColumn(3)
    elseif M.tool == "rotate" then
        -- deliberately NOT read here, mid-drag. A live report showed the gate's rendering
        -- flipping 180° instantly on any rotation while the native gizmo widget itself stayed
        -- visually correct the whole time, only "flipping" once released (when raceEditor.lua's
        -- ground-snap onDragEnd rebuilds the widget FROM the by-then-corrupted stored dir). That
        -- points at getAxisGizmoTransform() itself returning something unreliable specifically
        -- mid-drag, not at a column/sign mapping bug (two earlier attempts at that both failed to
        -- fix it, consistent with the mapping never having been the actual problem). Reading it
        -- only once, at drag-end, after the native widget's own transform has settled, avoids
        -- whatever's unreliable about reading it while the interaction is still live. The native
        -- widget itself still gives the player correct, smooth visual feedback during the drag ;
        -- only the stored gate/start data (and its own rendering) updates a beat later, at release.
        return
    elseif M.tool == "scale" then
        local delta = worldEditorCppApi.getAxisGizmoScaleOffset()
        local axis = worldEditorCppApi.getAxisGizmoSelectedElement()
        if axis == editor.AxisX then
            M.obj.scales.x = M.obj.scales.x + delta.x
        elseif axis == editor.AxisY then
            M.obj.scales.y = M.obj.scales.y + delta.y
        elseif axis == editor.AxisZ then
            M.obj.scales.z = M.obj.scales.z + delta.z
        end
    end
    if M.onChange then
        M.onChange(M.obj)
    end
end

local function onUpdate()
    if M.state then
        debugDrawer:drawAxisGizmo()
        editor.updateAxisGizmo(nop, function()
            if M.tool == "rotate" then
                readRotation()
                if M.onChange then M.onChange(M.obj) end
            end
            if M.onDragEnd then M.onDragEnd(M.obj) end
        end, onDrag)
    end
end

---@param obj GizmoObject
---@param onChange fun(updated: GizmoObject)
---@param onDragEnd fun(updated: GizmoObject)?
local function show(obj, onChange, onDragEnd)
    M.state = true
    M.obj.pos = obj.pos
    M.obj.dir = obj.dir
    M.obj.up = obj.up
    M.obj.scales = obj.scales
    local rot = quatFromDir(obj.dir, obj.up)
    local transform = QuatF(rot.x, rot.y, rot.z, rot.w):getMatrix()
    transform:setPosition(obj.pos)
    worldEditorCppApi.setAxisGizmoAlignment(editor.AxisGizmoAlignment_Local)
    editor.setAxisGizmoTransform(transform, obj.scales)

    -- empirically determine which basis column (and sign) of THIS transform actually corresponds
    -- to obj.dir/obj.up, right at the one point their true values are already known, rather than
    -- assuming a specific native local-axis convention, which two earlier attempts each got wrong
    -- (per a live report : dir flipped 180° immediately on any rotation, a hard/constant mismatch,
    -- not an intermittent ambiguity). The SAME quatFromDir->getMatrix construction is what's live
    -- during a drag too, so whichever column matches here keeps matching for the rest of this
    -- selection's rotate drags.
    local dirN, upN = obj.dir:normalized(), obj.up:normalized()
    for i = 0, 2 do
        local col = transform:getColumn(i):normalized()
        local dDot = col:dot(dirN)
        local uDot = col:dot(upN)
        if math.abs(dDot) > 0.99 then
            dirColumn, dirSign = i, (dDot > 0 and 1 or -1)
        end
        if math.abs(uDot) > 0.99 then
            upColumn, upSign = i, (uDot > 0 and 1 or -1)
        end
    end

    M.onChange = onChange
    M.onDragEnd = onDragEnd

    worldEditorCppApi.setGizmoLineThicknessScale(1)
    worldEditorCppApi.setAxisGizmoRenderPlane(false)
    worldEditorCppApi.setAxisGizmoRenderPlaneHashes(false)
    worldEditorCppApi.setAxisGizmoRenderMoveGrid(false)
    worldEditorCppApi.setGridSnap(false, 0)
    worldEditorCppApi.setRotateSnap(false, 0)
    worldEditorCppApi.setScaleSnap(false, 0)
end

local function hide()
    M.state = false
    M.onChange = nil
    M.onDragEnd = nil
    M.obj = {}
    dirColumn, dirSign = nil, nil
    upColumn, upSign = nil, nil
end

---@param tool "translate"|"rotate"|"scale"? default "translate"
local function setTool(tool)
    M.tool = tool or "translate"
    local mode = editor.AxisGizmoMode_Translate
    if tool == "rotate" then
        mode = editor.AxisGizmoMode_Rotate
    elseif tool == "scale" then
        mode = editor.AxisGizmoMode_Scale
    end
    worldEditorCppApi.setAxisGizmoMode(mode)
    beamjoy_communications_ui.send("BJEditorChangeTool", M.tool)
end

M.onInit = onInit
M.onUpdate = onUpdate

M.show = show
M.hide = hide
M.setTool = setTool

return M
