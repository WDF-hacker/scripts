--[[
    HUSH TP 测试工具（仅小号测试）
    - 按 T：向相机朝向跳 15 studs（可改）
    - 冷却 2.5 秒（落在 move.snap_far 的 30 + 27/s 额度内）
    - 落地前向下 raycast 找地面，避免卡进模型
    - 记录 hush_tp.log：时间 / 距离 / 起止坐标 / 冷却
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LOG = "hush_tp.log"
if not isfile(LOG) then writefile(LOG, "") end
local function log(s) pcall(function() appendfile(LOG, s .. "\n") end) end

local lp = Players.LocalPlayer
local DIST = 15
local COOLDOWN = 2.5
local lastAt = 0

local function findGround(pos)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local f = {}
    if lp.Character then f[#f + 1] = lp.Character end
    params.FilterDescendantsInstances = f
    local hit = workspace:Raycast(pos + Vector3.new(0, 60, 0), Vector3.new(0, -160, 0), params)
    if hit then return hit.Position end
    return nil
end

local function hop(dist)
    dist = tonumber(dist) or DIST
    local ch = lp.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    local cam = workspace.CurrentCamera
    if not hrp or not cam then return "no character" end
    local now = os.clock()
    if now - lastAt < COOLDOWN then
        return string.format("冷却中 %.1fs", COOLDOWN - (now - lastAt))
    end
    local look = cam.CFrame.LookVector
    look = Vector3.new(look.X, 0, look.Z)
    if look.Magnitude < 0.01 then return "camera look invalid" end
    look = look.Unit
    local target = hrp.Position + look * dist
    local ground = findGround(target)
    if not ground then
        log(string.format("%s FAIL no ground dist=%.0f target=%.1f,%.1f,%.1f",
            os.date("!%H:%M:%S"), dist, target.X, target.Y, target.Z))
        return "no ground"
    end
    local from = hrp.Position
    local dest = ground + Vector3.new(0, 3.2, 0)
    -- 检查落点是否被占：向上试几个高度
    local ok = false
    for i = 0, 4 do
        local try = dest + Vector3.new(0, i * 2, 0)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local f = { ch }
        params.FilterDescendantsInstances = f
        local blocked = workspace:GetPartBoundsInBox(CFrame.new(try), Vector3.new(2, 4, 2), params)
        if #blocked == 0 then
            dest = try
            ok = true
            break
        end
    end
    if not ok then
        log(string.format("%s FAIL blocked dist=%.0f", os.date("!%H:%M:%S"), dist))
        return "blocked"
    end
    hrp.CFrame = CFrame.new(dest) * CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
    lastAt = now
    local moved = (dest - from).Magnitude
    log(string.format("%s HOP dist=%.1f from=%.1f,%.1f,%.1f to=%.1f,%.1f,%.1f moved=%.1f",
        os.date("!%H:%M:%S"), dist, from.X, from.Y, from.Z, dest.X, dest.Y, dest.Z, moved))
    return string.format("TP %.0f studs", moved)
end

_G.HUSH_TP = hop

UIS.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.T then
        local ok, res = pcall(hop, DIST)
        log("KEY T -> " .. tostring(ok and res or res))
    end
end)

log(string.format("# SESSION %s user=%s dist=%d cd=%.1f",
    os.date("!%Y-%m-%dT%H:%M:%S"), lp.Name, DIST, COOLDOWN))
print("[HUSH-TP] loaded: press T to hop " .. DIST .. " studs")
